package main

import (
	"flag"
	"os"

	"k8s.io/apimachinery/pkg/runtime"
	utilruntime "k8s.io/apimachinery/pkg/util/runtime"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
	kubevirtv1 "kubevirt.io/api/core/v1"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/healthz"
	"sigs.k8s.io/controller-runtime/pkg/log/zap"
	metricsserver "sigs.k8s.io/controller-runtime/pkg/metrics/server"

	"github.com/basil-eldho/lab-platform/pool-go/internal/config"
	poolcontroller "github.com/basil-eldho/lab-platform/pool-go/internal/controller"
)

var scheme = runtime.NewScheme()

func init() {
	utilruntime.Must(clientgoscheme.AddToScheme(scheme))
	utilruntime.Must(kubevirtv1.AddToScheme(scheme))
}

func main() {
	var (
		metricsAddr string
		probeAddr   string
		leaderElect bool
	)
	flag.StringVar(&metricsAddr, "metrics-bind-address", ":8080", "Metrics endpoint address")
	flag.StringVar(&probeAddr, "health-probe-bind-address", ":8081", "Health probe address")
	flag.BoolVar(&leaderElect, "leader-elect", true, "Enable leader election for HA deployments")
	flag.Parse()

	ctrl.SetLogger(zap.New(zap.UseDevMode(os.Getenv("DEV_MODE") == "true")))
	log := ctrl.Log.WithName("main")

	cfg, err := config.Load(config.RoleController)
	if err != nil {
		log.Error(err, "config load failed")
		os.Exit(1)
	}

	mgr, err := ctrl.NewManager(ctrl.GetConfigOrDie(), ctrl.Options{
		Scheme: scheme,
		Metrics: metricsserver.Options{
			BindAddress: metricsAddr,
		},
		HealthProbeBindAddress:        probeAddr,
		LeaderElection:                leaderElect,
		LeaderElectionID:              "pool-controller.lab-platform.io",
		LeaderElectionReleaseOnCancel: true,
	})
	if err != nil {
		log.Error(err, "manager create failed")
		os.Exit(1)
	}

	if err := (&poolcontroller.PoolReconciler{
		Client: mgr.GetClient(),
		Scheme: mgr.GetScheme(),
		Cfg:    cfg,
		Log:    ctrl.Log.WithName("pool-reconciler"),
	}).SetupWithManager(mgr); err != nil {
		log.Error(err, "reconciler setup failed")
		os.Exit(1)
	}

	if err := mgr.AddHealthzCheck("healthz", healthz.Ping); err != nil {
		log.Error(err, "healthz setup failed")
		os.Exit(1)
	}
	if err := mgr.AddReadyzCheck("readyz", healthz.Ping); err != nil {
		log.Error(err, "readyz setup failed")
		os.Exit(1)
	}

	log.Info("starting pool controller")
	if err := mgr.Start(ctrl.SetupSignalHandler()); err != nil {
		log.Error(err, "manager exited")
		os.Exit(1)
	}
}
