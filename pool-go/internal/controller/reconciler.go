package controller

import (
	"context"
	"fmt"
	"time"

	"github.com/go-logr/logr"
	"github.com/google/uuid"
	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	kubevirtv1 "kubevirt.io/api/core/v1"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/builder"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/event"
	"sigs.k8s.io/controller-runtime/pkg/handler"
	"sigs.k8s.io/controller-runtime/pkg/manager"
	"sigs.k8s.io/controller-runtime/pkg/predicate"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"
	"sigs.k8s.io/controller-runtime/pkg/source"

	"github.com/basil-eldho/lab-platform/pool-go/internal/config"
	"github.com/basil-eldho/lab-platform/pool-go/internal/pool"
)

// resyncInterval is how often the pool is reconciled even without VM/VMI
// events. It guarantees the pool fills from a cold (empty) start and keeps
// itself at MinSize if it drifts, without relying on incidental events.
const resyncInterval = 30 * time.Second

// PoolReconciler maintains the warm VM pool for all OS types.
//
// Design: every VM or VMI change belonging to this controller enqueues a
// reconcile of the full pool. The reconcile is idempotent — it promotes ready
// VMs and creates new ones to meet MinSize. controller-runtime's work queue
// deduplicates rapid bursts automatically.
type PoolReconciler struct {
	client.Client
	Scheme *runtime.Scheme
	Cfg    *config.Config
	Log    logr.Logger
}

// Reconcile is the main loop body. req carries the triggering object's name
// but we ignore it and reconcile the whole pool — correct for a singleton
// controller that owns all pool VMs.
func (r *PoolReconciler) Reconcile(ctx context.Context, req reconcile.Request) (reconcile.Result, error) {
	log := r.Log.WithValues("trigger", req.NamespacedName)

	for osType, spec := range r.Cfg.Pools {
		if err := r.reconcilePool(ctx, log, osType, spec); err != nil {
			log.Error(err, "pool reconcile error", "os", osType)
			// Requeue with backoff; do not block other OS types.
			return reconcile.Result{RequeueAfter: 15 * time.Second}, nil
		}
	}
	return reconcile.Result{}, nil
}

func (r *PoolReconciler) reconcilePool(ctx context.Context, log logr.Logger, osType string, spec config.PoolSpec) error {
	// ── Step 1: promote creating → warm ──────────────────────────────────────
	creating := &kubevirtv1.VirtualMachineList{}
	if err := r.List(ctx, creating,
		client.InNamespace(r.Cfg.Namespace),
		client.MatchingLabels{"pool": "creating", "pool-type": osType, "managed-by": pool.ManagedBy},
	); err != nil {
		return fmt.Errorf("list creating VMs: %w", err)
	}

	for i := range creating.Items {
		if err := r.tryPromote(ctx, log, &creating.Items[i], osType); err != nil {
			// Non-fatal: log and continue to the next VM.
			log.Error(err, "promote failed", "vm", creating.Items[i].Name)
		}
	}

	// ── Step 2: count pool depth (re-list after promotions) ──────────────────
	warm := &kubevirtv1.VirtualMachineList{}
	if err := r.List(ctx, warm,
		client.InNamespace(r.Cfg.Namespace),
		client.MatchingLabels{"pool": "warm", "pool-type": osType, "managed-by": pool.ManagedBy},
	); err != nil {
		return fmt.Errorf("list warm VMs: %w", err)
	}

	// Re-list creating after promotions to get accurate count.
	if err := r.List(ctx, creating,
		client.InNamespace(r.Cfg.Namespace),
		client.MatchingLabels{"pool": "creating", "pool-type": osType, "managed-by": pool.ManagedBy},
	); err != nil {
		return fmt.Errorf("list creating VMs (post-promote): %w", err)
	}

	total := len(warm.Items) + len(creating.Items)
	shortage := spec.MinSize - total

	log.Info("pool status", "os", osType,
		"warm", len(warm.Items), "creating", len(creating.Items), "target", spec.MinSize)

	// ── Step 3: fill shortage ─────────────────────────────────────────────────
	for i := 0; i < shortage; i++ {
		if err := r.spawnVM(ctx, log, osType, spec); err != nil {
			return fmt.Errorf("spawn VM: %w", err)
		}
	}
	return nil
}

// tryPromote checks a VMI for AgentConnected and, if true, patches the VM
// (and associated resources) from pool=creating to pool=warm.
func (r *PoolReconciler) tryPromote(ctx context.Context, log logr.Logger, vm *kubevirtv1.VirtualMachine, osType string) error {
	vmi := &kubevirtv1.VirtualMachineInstance{}
	err := r.Get(ctx, types.NamespacedName{Name: vm.Name, Namespace: vm.Namespace}, vmi)
	if apierrors.IsNotFound(err) {
		return nil // VMI not yet created by KubeVirt
	}
	if err != nil {
		return fmt.Errorf("get VMI %s: %w", vm.Name, err)
	}

	if !agentConnected(vmi) {
		return nil
	}

	// Patch the VM label. MergeFrom captures the current resourceVersion so
	// the server rejects a stale patch (safe under concurrent reconcilers).
	base := vm.DeepCopy()
	vm.Labels["pool"] = "warm"
	if err := r.Patch(ctx, vm, client.MergeFrom(base)); err != nil {
		return fmt.Errorf("patch VM label: %w", err)
	}

	// Promote the desktop Service so the API can filter on pool=warm.
	_ = r.patchLabel(ctx, &corev1.Service{}, pool.DesktopServiceName(vm.Name), vm.Namespace, "pool", "warm")

	log.Info("promoted VM to warm", "name", vm.Name, "os", osType)
	return nil
}

func (r *PoolReconciler) patchLabel(ctx context.Context, obj client.Object, name, ns, key, val string) error {
	if err := r.Get(ctx, types.NamespacedName{Name: name, Namespace: ns}, obj); err != nil {
		return err
	}
	base := obj.DeepCopyObject().(client.Object)
	labels := obj.GetLabels()
	if labels == nil {
		labels = map[string]string{}
	}
	labels[key] = val
	obj.SetLabels(labels)
	return r.Patch(ctx, obj, client.MergeFrom(base))
}

// spawnVM creates a VM and the ClusterIP Service guacd reaches its desktop on.
func (r *PoolReconciler) spawnVM(ctx context.Context, log logr.Logger, osType string, spec config.PoolSpec) error {
	prefix := map[string]string{"ubuntu": "ubu", "windows": "win"}[osType]
	name := fmt.Sprintf("%s-pool-%s", prefix, uuid.New().String()[:8])

	vm := pool.VM(name, r.Cfg.Namespace, osType, spec.DataSource, spec.DiskSize, spec.Memory, spec.Cores)
	if err := r.Create(ctx, vm); err != nil {
		return fmt.Errorf("create VM %s: %w", name, err)
	}

	if err := r.Create(ctx, pool.DesktopService(name, r.Cfg.Namespace, osType)); err != nil {
		return fmt.Errorf("create desktop service: %w", err)
	}

	log.Info("spawned VM", "name", name, "os", osType)
	return nil
}

// agentConnected returns true when the VMI has QEMU guest agent handshake.
func agentConnected(vmi *kubevirtv1.VirtualMachineInstance) bool {
	for _, c := range vmi.Status.Conditions {
		if c.Type == kubevirtv1.VirtualMachineInstanceAgentConnected &&
			c.Status == corev1.ConditionTrue {
			return true
		}
	}
	return false
}

// SetupWithManager registers this reconciler with controller-runtime.
//
// Watches:
//   - VirtualMachine (primary) — filtered to managed pool VMs
//   - VirtualMachineInstance — mapped by name to a VM reconcile request so
//     AgentConnected transitions trigger promotion without polling
func (r *PoolReconciler) SetupWithManager(mgr ctrl.Manager) error {
	managedOnly := predicate.NewPredicateFuncs(func(obj client.Object) bool {
		return obj.GetLabels()["managed-by"] == pool.ManagedBy
	})

	// Periodic trigger. The VM/VMI watches below only fire on changes to VMs
	// that already exist, so an empty pool would never reconcile — a cold-start
	// deadlock. This ticker enqueues a reconcile immediately on startup and
	// every resyncInterval after, so the pool fills from zero and self-heals.
	ticks := make(chan event.GenericEvent, 1)
	tick := event.GenericEvent{Object: &kubevirtv1.VirtualMachine{
		ObjectMeta: metav1.ObjectMeta{Name: "periodic-resync", Namespace: r.Cfg.Namespace},
	}}
	if err := mgr.Add(manager.RunnableFunc(func(ctx context.Context) error {
		t := time.NewTicker(resyncInterval)
		defer t.Stop()
		for {
			// Fire once immediately, then once per tick.
			select {
			case ticks <- tick:
			case <-ctx.Done():
				return nil
			}
			select {
			case <-t.C:
			case <-ctx.Done():
				return nil
			}
		}
	})); err != nil {
		return err
	}

	return ctrl.NewControllerManagedBy(mgr).
		For(&kubevirtv1.VirtualMachine{}, builder.WithPredicates(managedOnly)).
		Watches(
			&kubevirtv1.VirtualMachineInstance{},
			handler.EnqueueRequestsFromMapFunc(func(ctx context.Context, obj client.Object) []reconcile.Request {
				// Only react to VMIs belonging to this controller.
				if obj.GetLabels()["managed-by"] != pool.ManagedBy {
					return nil
				}
				// VMI name == VM name in KubeVirt — enqueue the owning VM.
				return []reconcile.Request{{
					NamespacedName: types.NamespacedName{
						Name:      obj.GetName(),
						Namespace: obj.GetNamespace(),
					},
				}}
			}),
		).
		WatchesRawSource(&source.Channel{Source: ticks}, &handler.EnqueueRequestForObject{}).
		Complete(r)
}
