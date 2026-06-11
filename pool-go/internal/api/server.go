package api

import (
	"context"
	"fmt"
	"log/slog"
	"net/http"
	"time"

	"github.com/go-chi/chi/v5"
	chimiddleware "github.com/go-chi/chi/v5/middleware"

	"github.com/basil-eldho/lab-platform/pool-go/internal/api/handler"
	"github.com/basil-eldho/lab-platform/pool-go/internal/middleware"
)

// Server wraps the HTTP server and its dependencies.
type Server struct {
	http *http.Server
	log  *slog.Logger
}

// Deps groups everything the handlers need. Pass this from main.
type Deps struct {
	Provision *handler.ProvisionHandler
	Session   *handler.SessionHandler
	Status    *handler.StatusHandler
	Log       *slog.Logger
}

// New builds the chi router, wires middleware, and returns a ready Server.
func New(addr string, deps Deps) *Server {
	r := chi.NewRouter()

	// ── Middleware stack (outer → inner) ──────────────────────────────────────
	r.Use(middleware.CORS)
	r.Use(middleware.RequestID)
	r.Use(middleware.Logger(deps.Log))
	r.Use(middleware.Recoverer(deps.Log))
	r.Use(chimiddleware.Timeout(30 * time.Second))

	// ── Routes ────────────────────────────────────────────────────────────────
	r.Post("/provision", deps.Provision.ServeHTTP)
	r.Get("/provision/stream", deps.Provision.ServeStream) // SSE: waits for warm VM

	r.Delete("/session/{id}", deps.Session.ServeHTTP)

	r.Get("/status", deps.Status.ServeHTTP)
	r.Get("/health", (&handler.HealthHandler{}).ServeHTTP)

	return &Server{
		http: &http.Server{
			Addr:         addr,
			Handler:      r,
			ReadTimeout:  10 * time.Second,
			WriteTimeout: 0, // disabled: SSE streams are long-lived
			IdleTimeout:  120 * time.Second,
		},
		log: deps.Log,
	}
}

// Start begins serving and blocks until ctx is cancelled, then shuts down
// gracefully with a 30-second drain window.
func (s *Server) Start(ctx context.Context) error {
	errCh := make(chan error, 1)
	go func() {
		s.log.Info("API server listening", "addr", s.http.Addr)
		if err := s.http.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			errCh <- err
		}
	}()

	select {
	case err := <-errCh:
		return fmt.Errorf("server error: %w", err)
	case <-ctx.Done():
		s.log.Info("shutting down API server")
		shutCtx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()
		if err := s.http.Shutdown(shutCtx); err != nil {
			return fmt.Errorf("graceful shutdown: %w", err)
		}
		return nil
	}
}
