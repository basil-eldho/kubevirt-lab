package handler

import (
	"log/slog"
	"net/http"
	"time"

	kubevirtv1 "kubevirt.io/api/core/v1"
	"sigs.k8s.io/controller-runtime/pkg/client"

	"github.com/basil-eldho/lab-platform/pool-go/internal/config"
	"github.com/basil-eldho/lab-platform/pool-go/internal/session"
)

// StatusHandler handles GET /status.
type StatusHandler struct {
	Client   client.Client
	Sessions session.Store
	Cfg      *config.Config
	Log      *slog.Logger
}

type statusResponse struct {
	WarmPool       map[string]int   `json:"warm_pool"`
	ActiveSessions int              `json:"active_sessions"`
	Sessions       []sessionSummary `json:"sessions"`
}

type sessionSummary struct {
	SessionID  string  `json:"session_id"`
	Student    string  `json:"student"`
	VM         string  `json:"vm"`
	OSType     string  `json:"os_type"`
	AgeMinutes float64 `json:"age_minutes"`
}

func (h *StatusHandler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()

	warm := map[string]int{"ubuntu": 0, "windows": 0}
	for osType := range h.Cfg.Pools {
		vms := &kubevirtv1.VirtualMachineList{}
		if err := h.Client.List(ctx, vms,
			client.InNamespace(h.Cfg.Namespace),
			client.MatchingLabels{"pool": "warm", "pool-type": osType, "managed-by": "pool-controller"},
		); err != nil {
			h.Log.Warn("list warm VMs failed", "os", osType, "err", err)
			continue
		}
		warm[osType] = len(vms.Items)
	}

	sessions, err := h.Sessions.List(ctx)
	if err != nil {
		h.Log.Warn("list sessions failed", "err", err)
		sessions = nil
	}

	summaries := make([]sessionSummary, 0, len(sessions))
	for _, s := range sessions {
		summaries = append(summaries, sessionSummary{
			SessionID:  s.ID,
			Student:    s.Student,
			VM:         s.VMName,
			OSType:     s.OSType,
			AgeMinutes: time.Since(s.CreatedAt).Minutes(),
		})
	}

	writeJSON(w, statusResponse{
		WarmPool:       warm,
		ActiveSessions: len(sessions),
		Sessions:       summaries,
	})
}

// HealthHandler handles GET /health — used as the liveness probe.
type HealthHandler struct{}

func (h *HealthHandler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, map[string]string{"status": "ok"})
}
