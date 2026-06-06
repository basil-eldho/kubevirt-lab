package handler

import (
	"context"
	"log/slog"
	"net/http"

	"github.com/go-chi/chi/v5"
	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	kubevirtv1 "kubevirt.io/api/core/v1"
	"sigs.k8s.io/controller-runtime/pkg/client"

	"github.com/basil-eldho/lab-platform/pool-go/internal/config"
	"github.com/basil-eldho/lab-platform/pool-go/internal/guacamole"
	"github.com/basil-eldho/lab-platform/pool-go/internal/pool"
	"github.com/basil-eldho/lab-platform/pool-go/internal/session"
)

// SessionHandler handles DELETE /session/{id}.
type SessionHandler struct {
	Client   client.Client
	Sessions session.Store
	Guac     *guacamole.Client
	Cfg      *config.Config
	Log      *slog.Logger
}

func (h *SessionHandler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	sid := chi.URLParam(r, "id")
	ctx := r.Context()

	s, err := h.Sessions.Get(ctx, sid)
	if err != nil {
		h.Log.Error("session get failed", "err", err, "id", sid)
		jsonError(w, "session store error", http.StatusInternalServerError)
		return
	}
	if s == nil {
		jsonError(w, "session not found", http.StatusNotFound)
		return
	}

	// Delete in parallel: Guacamole connection + Kubernetes resources.
	// Errors are logged but don't block the response — partial cleanup is
	// better than leaving the session open on error.
	if s.ConnID != "" {
		if err := h.Guac.DeleteConnection(ctx, s.ConnID); err != nil {
			h.Log.Warn("guacamole cleanup failed", "conn", s.ConnID, "err", err)
		}
	}

	// Deleting the account also invalidates the token in the student's URL, so a
	// bookmarked link cannot outlive the session and reach the next VM to reuse
	// this connection ID.
	if s.GuacUser != "" {
		if err := h.Guac.DeleteUser(ctx, s.GuacUser); err != nil {
			h.Log.Warn("guacamole user cleanup failed", "user", s.GuacUser, "err", err)
		}
	}

	h.deleteVMResources(ctx, s.VMName)

	if err := h.Sessions.Delete(ctx, sid); err != nil {
		h.Log.Warn("session delete failed", "err", err, "id", sid)
	}

	h.Log.Info("released session", "id", sid, "vm", s.VMName, "student", s.Student)
	writeJSON(w, map[string]string{"status": "released", "vm": s.VMName, "os_type": s.OSType})
}

func (h *SessionHandler) deleteVMResources(ctx context.Context, vmName string) {
	del := func(obj client.Object, name string) {
		obj.SetName(name)
		obj.SetNamespace(h.Cfg.Namespace)
		if err := h.Client.Delete(ctx, obj); err != nil && !apierrors.IsNotFound(err) {
			h.Log.Warn("delete resource failed", "name", name, "err", err)
		}
	}

	del(&kubevirtv1.VirtualMachine{}, vmName)
	del(&corev1.Service{}, pool.DesktopServiceName(vmName))
}
