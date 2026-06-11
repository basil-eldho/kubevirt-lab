package main

import (
	"context"
	"fmt"
	"log/slog"
	"os"
	"os/signal"
	"syscall"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/runtime"
	utilruntime "k8s.io/apimachinery/pkg/util/runtime"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
	kubevirtv1 "kubevirt.io/api/core/v1"
	ctrl "sigs.k8s.io/controller-runtime"
	runtimeclient "sigs.k8s.io/controller-runtime/pkg/client"

	"github.com/basil-eldho/lab-platform/pool-go/internal/api"
	"github.com/basil-eldho/lab-platform/pool-go/internal/api/handler"
	"github.com/basil-eldho/lab-platform/pool-go/internal/config"
	"github.com/basil-eldho/lab-platform/pool-go/internal/guacamole"
	"github.com/basil-eldho/lab-platform/pool-go/internal/session"
)

var scheme = runtime.NewScheme()

func init() {
	utilruntime.Must(clientgoscheme.AddToScheme(scheme))
	utilruntime.Must(kubevirtv1.AddToScheme(scheme))
}

func main() {
	log := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelInfo}))
	slog.SetDefault(log)

	cfg, err := config.Load(config.RoleAPI)
	if err != nil {
		log.Error("config load failed", "err", err)
		os.Exit(1)
	}

	// ── Kubernetes client (direct, non-cached) ────────────────────────────────
	k8sClient, err := runtimeclient.New(ctrl.GetConfigOrDie(), runtimeclient.Options{Scheme: scheme})
	if err != nil {
		log.Error("k8s client failed", "err", err)
		os.Exit(1)
	}

	// ── Redis ─────────────────────────────────────────────────────────────────
	store := session.NewRedisStore(cfg.Redis.Addr, cfg.Redis.Password, cfg.Redis.DB)
	if err := store.Ping(context.Background()); err != nil {
		log.Error("redis unreachable", "addr", cfg.Redis.Addr, "err", err)
		os.Exit(1)
	}
	log.Info("redis connected", "addr", cfg.Redis.Addr)

	// ── Node IP ───────────────────────────────────────────────────────────────
	nodeIP, err := clusterNodeIP(context.Background(), k8sClient)
	if err != nil {
		log.Error("node IP resolution failed", "err", err)
		os.Exit(1)
	}
	log.Info("resolved node IP", "ip", nodeIP)

	// ── Dependencies ──────────────────────────────────────────────────────────
	guac := guacamole.New(
		cfg.Guacamole.InternalURL,
		cfg.Guacamole.User,
		cfg.Guacamole.Password,
		cfg.Guacamole.DataSource,
	)

	srv := api.New(":8080", api.Deps{
		Provision: &handler.ProvisionHandler{
			Client: k8sClient, Sessions: store, Guac: guac,
			Cfg: cfg, Log: log.WithGroup("provision"), NodeIP: nodeIP,
		},
		Session: &handler.SessionHandler{
			Client: k8sClient, Sessions: store, Guac: guac,
			Cfg: cfg, Log: log.WithGroup("session"),
		},
		Status: &handler.StatusHandler{
			Client: k8sClient, Sessions: store,
			Cfg: cfg, Log: log.WithGroup("status"),
		},
		Log: log,
	})

	// ── Graceful shutdown on SIGTERM / SIGINT ─────────────────────────────────
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer stop()

	if err := srv.Start(ctx); err != nil {
		log.Error("server error", "err", err)
		os.Exit(1)
	}
	log.Info("clean shutdown")
}

// clusterNodeIP returns the InternalIP of the first cluster node.
// In a single-node lab this is always the node running all workloads.
// Override with NODE_IP env var to skip the API call (useful in CI).
func clusterNodeIP(ctx context.Context, c runtimeclient.Client) (string, error) {
	if ip := os.Getenv("NODE_IP"); ip != "" {
		return ip, nil
	}
	nodes := &corev1.NodeList{}
	if err := c.List(ctx, nodes); err != nil {
		return "", fmt.Errorf("list nodes: %w", err)
	}
	if len(nodes.Items) == 0 {
		return "", fmt.Errorf("no nodes found in cluster")
	}
	for _, addr := range nodes.Items[0].Status.Addresses {
		if addr.Type == corev1.NodeInternalIP {
			return addr.Address, nil
		}
	}
	return "", fmt.Errorf("no InternalIP found on node %s", nodes.Items[0].Name)
}
