package handler

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"time"

	"github.com/google/uuid"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	kubevirtv1 "kubevirt.io/api/core/v1"
	"sigs.k8s.io/controller-runtime/pkg/client"

	"github.com/basil-eldho/lab-platform/pool-go/internal/config"
	"github.com/basil-eldho/lab-platform/pool-go/internal/guacamole"
	"github.com/basil-eldho/lab-platform/pool-go/internal/pool"
	"github.com/basil-eldho/lab-platform/pool-go/internal/session"
)

// ProvisionHandler handles POST /provision and GET /provision/stream.
type ProvisionHandler struct {
	Client   client.Client
	Sessions session.Store
	Guac     *guacamole.Client
	Cfg      *config.Config
	Log      *slog.Logger
	NodeIP   string // resolved once at startup
}

type provisionResponse struct {
	SessionID string `json:"session_id"`
	VMName    string `json:"vm_name"`
	URL       string `json:"access_url"` // Guacamole session URL, both OS types
	OSType    string `json:"os_type"`
}

// ServeHTTP handles POST /provision?student_name=X&os_type=ubuntu|windows.
// Returns immediately with the session URL if a warm VM is available,
// or 503 + Retry-After: 15 if the pool is empty.
func (h *ProvisionHandler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	student, osType, ok := parseProvisionParams(w, r)
	if !ok {
		return
	}
	ctx := r.Context()

	// Idempotent: return the existing session if one is already open.
	existing, err := h.Sessions.FindByStudent(ctx, student, osType)
	if err != nil {
		h.Log.Error("session lookup failed", "err", err)
		jsonError(w, "session store error", http.StatusInternalServerError)
		return
	}
	if existing != nil {
		writeJSON(w, provisionResponse{
			SessionID: existing.ID, VMName: existing.VMName,
			URL: existing.URL, OSType: osType,
		})
		return
	}

	resp, err := h.claimAndProvision(ctx, student, osType)
	if err == errNoWarmVM {
		w.Header().Set("Retry-After", "15")
		jsonError(w, fmt.Sprintf("no %s VMs available — pool is warming up", osType), http.StatusServiceUnavailable)
		return
	}
	if err != nil {
		h.Log.Error("provision failed", "err", err, "student", student, "os", osType)
		jsonError(w, "provision failed", http.StatusInternalServerError)
		return
	}
	writeJSON(w, resp)
}

// ServeStream handles GET /provision/stream — an SSE endpoint that waits up to
// 5 minutes for a warm VM, polling every 5 s and sending keepalive comments
// every 30 s. The portal shows a spinner instead of an error page.
func (h *ProvisionHandler) ServeStream(w http.ResponseWriter, r *http.Request) {
	student, osType, ok := parseProvisionParams(w, r)
	if !ok {
		return
	}
	flusher, ok := w.(http.Flusher)
	if !ok {
		http.Error(w, "streaming unsupported", http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("X-Accel-Buffering", "no")

	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Minute)
	defer cancel()

	sendEvent := func(event, data string) {
		fmt.Fprintf(w, "event: %s\ndata: %s\n\n", event, data)
		flusher.Flush()
	}

	sendEvent("waiting", `{"status":"waiting"}`)

	keepalive := time.NewTicker(30 * time.Second)
	poll := time.NewTicker(5 * time.Second)
	defer keepalive.Stop()
	defer poll.Stop()

	for {
		select {
		case <-ctx.Done():
			sendEvent("timeout", `{"error":"no VM became available within 5 minutes"}`)
			return
		case <-keepalive.C:
			fmt.Fprintf(w, ": keepalive\n\n")
			flusher.Flush()
		case <-poll.C:
			resp, err := h.claimAndProvision(ctx, student, osType)
			if err == errNoWarmVM {
				continue
			}
			if err != nil {
				sendEvent("error", fmt.Sprintf(`{"error":%q}`, err.Error()))
				return
			}
			b, _ := json.Marshal(resp)
			sendEvent("ready", string(b))
			return
		}
	}
}

// ── internals ─────────────────────────────────────────────────────────────────

var errNoWarmVM = fmt.Errorf("no warm VM available")

// claimAndProvision atomically claims a warm VM using optimistic locking.
// When two concurrent requests race for the same VM, the server returns 409
// Conflict on the second patch and we fall through to the next candidate.
func (h *ProvisionHandler) claimAndProvision(ctx context.Context, student, osType string) (*provisionResponse, error) {
	warm := &kubevirtv1.VirtualMachineList{}
	if err := h.Client.List(ctx, warm,
		client.InNamespace(h.Cfg.Namespace),
		client.MatchingLabels{"pool": "warm", "pool-type": osType, "managed-by": "pool-controller"},
	); err != nil {
		return nil, fmt.Errorf("list warm VMs: %w", err)
	}
	if len(warm.Items) == 0 {
		return nil, errNoWarmVM
	}

	sid := uuid.New().String()

	for i := range warm.Items {
		vm := &warm.Items[i]

		base := vm.DeepCopy()
		vm.Labels["pool"] = "assigned"
		vm.Labels["session"] = sid

		// MergeFromWithOptimisticLock embeds resourceVersion in the patch so the
		// API server rejects stale writes — the distributed mutual exclusion
		// primitive for Kubernetes resources.
		err := h.Client.Patch(ctx, vm, client.MergeFromWithOptions(base,
			client.MergeFromWithOptimisticLock{}))
		if apierrors.IsConflict(err) {
			continue // another replica claimed this VM first
		}
		if err != nil {
			return nil, fmt.Errorf("claim VM %s: %w", vm.Name, err)
		}

		conn, err := h.buildAccessURL(ctx, vm.Name, osType, sid)
		if err != nil {
			return nil, err
		}

		s := &session.Session{
			ID: sid, VMName: vm.Name, OSType: osType,
			URL: conn.URL, Student: student, ConnID: conn.ID,
			GuacUser:  conn.User,
			CreatedAt: time.Now(),
		}
		if err := h.Sessions.Set(ctx, s, h.Cfg.SessionTTL); err != nil {
			h.Log.Warn("session persist failed", "err", err)
		}

		h.Log.Info("provisioned", "student", student, "vm", vm.Name, "os", osType, "session", sid)
		return &provisionResponse{SessionID: sid, VMName: vm.Name, URL: conn.URL, OSType: osType}, nil
	}

	return nil, errNoWarmVM
}

// buildAccessURL brokers the VM's desktop through Guacamole. Ubuntu and Windows
// differ only in protocol and credentials — both are reached over the VM's
// ClusterIP desktop Service, so there is one code path for either OS.
func (h *ProvisionHandler) buildAccessURL(ctx context.Context, vmName, osType, sessionID string) (*guacamole.Connection, error) {
	user, password, err := h.desktopCredentials(osType)
	if err != nil {
		return nil, err
	}

	conn, err := h.Guac.CreateConnection(ctx, guacamole.ConnectionSpec{
		VMName:   vmName,
		Protocol: pool.DesktopProtocol(osType),
		Hostname: fmt.Sprintf("%s.%s.svc.cluster.local",
			pool.DesktopServiceName(vmName), h.Cfg.Namespace),
		Port:     pool.DesktopPort(osType),
		User:     user,
		Password: password,
	}, sessionID, h.NodeIP, h.Cfg.PortalPort)
	if err != nil {
		return nil, fmt.Errorf("guacamole: %w", err)
	}
	return conn, nil
}

func (h *ProvisionHandler) desktopCredentials(osType string) (user, password string, err error) {
	switch osType {
	case "ubuntu":
		return h.Cfg.Ubuntu.User, h.Cfg.Ubuntu.VNCPassword, nil
	case "windows":
		return h.Cfg.Windows.User, h.Cfg.Windows.Password, nil
	}
	return "", "", fmt.Errorf("unknown os type %q", osType)
}

func parseProvisionParams(w http.ResponseWriter, r *http.Request) (student, osType string, ok bool) {
	student = r.URL.Query().Get("student_name")
	osType = r.URL.Query().Get("os_type")
	if student == "" {
		jsonError(w, "student_name is required", http.StatusBadRequest)
		return "", "", false
	}
	if osType != "ubuntu" && osType != "windows" {
		jsonError(w, "os_type must be ubuntu or windows", http.StatusBadRequest)
		return "", "", false
	}
	return student, osType, true
}

func writeJSON(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(v)
}

func jsonError(w http.ResponseWriter, msg string, code int) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	json.NewEncoder(w).Encode(map[string]string{"detail": msg})
}
