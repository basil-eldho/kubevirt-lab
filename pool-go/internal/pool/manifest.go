package pool

import (
	"fmt"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/util/intstr"
	kubevirtv1 "kubevirt.io/api/core/v1"
	cdiv1beta1 "kubevirt.io/containerized-data-importer-api/pkg/apis/core/v1beta1"
)

const ManagedBy = "pool-controller"

// Labels returns the standard label set for pool resources.
func Labels(osType, poolState, vmName string) map[string]string {
	l := map[string]string{
		"managed-by": ManagedBy,
		"pool-type":  osType,
		"pool":       poolState,
	}
	if vmName != "" {
		l["vm-name"] = vmName
	}
	return l
}

// VM builds a fully typed VirtualMachine manifest — no YAML templating.
func VM(name, namespace, osType, datasource, diskSize, memory string, cores int) *kubevirtv1.VirtualMachine {
	running := true
	sc := "standard"

	return &kubevirtv1.VirtualMachine{
		ObjectMeta: metav1.ObjectMeta{
			Name:      name,
			Namespace: namespace,
			Labels:    Labels(osType, "creating", ""),
		},
		Spec: kubevirtv1.VirtualMachineSpec{
			Running: &running,
			DataVolumeTemplates: []kubevirtv1.DataVolumeTemplateSpec{{
				ObjectMeta: metav1.ObjectMeta{Name: name + "-disk"},
				Spec: cdiv1beta1.DataVolumeSpec{
					SourceRef: &cdiv1beta1.DataVolumeSourceRef{
						Kind:      "DataSource",
						Name:      datasource,
						Namespace: &namespace,
					},
					Storage: &cdiv1beta1.StorageSpec{
						AccessModes: []corev1.PersistentVolumeAccessMode{corev1.ReadWriteOnce},
						Resources: corev1.ResourceRequirements{
							Requests: corev1.ResourceList{
								corev1.ResourceStorage: resource.MustParse(diskSize),
							},
						},
						StorageClassName: &sc,
					},
				},
			}},
			Template: &kubevirtv1.VirtualMachineInstanceTemplateSpec{
				ObjectMeta: metav1.ObjectMeta{
					// KubeVirt copies these onto the VMI. "managed-by" is required
					// for the controller's VMI watch predicate to fire, so the
					// AgentConnected transition triggers promotion immediately
					// instead of waiting for the periodic resync. The mutable
					// "pool" label is intentionally omitted — the controller
					// patches it on the VM object only, so it would go stale here.
					Labels: map[string]string{
						"kubevirt.io/vm": name,
						"managed-by":     ManagedBy,
						"pool-type":      osType,
					},
				},
				Spec: kubevirtv1.VirtualMachineInstanceSpec{
					Domain: kubevirtv1.DomainSpec{
						CPU: &kubevirtv1.CPU{
							Cores: uint32(cores),
							Model: "host-passthrough",
						},
						Resources: kubevirtv1.ResourceRequirements{
							Requests: corev1.ResourceList{
								corev1.ResourceMemory: resource.MustParse(memory),
							},
						},
						Devices: kubevirtv1.Devices{
							Disks:      buildDisks(osType),
							Interfaces: []kubevirtv1.Interface{masqueradeIface()},
						},
						Features: buildFeatures(osType),
						Firmware: &kubevirtv1.Firmware{
							Bootloader: &kubevirtv1.Bootloader{
								EFI: &kubevirtv1.EFI{SecureBoot: ptr(false)},
							},
						},
					},
					Networks: []kubevirtv1.Network{{
						Name:          "default",
						NetworkSource: kubevirtv1.NetworkSource{Pod: &kubevirtv1.PodNetwork{}},
					}},
					Volumes: buildVolumes(osType, name),
				},
			},
		},
	}
}

// Both OS types serve their desktop from a listener inside the guest — VNC on
// Ubuntu (x11vnc against the auto-logged-in XFCE session), RDP on Windows — so
// a single ClusterIP Service per VM is all guacd needs to reach either one.

// DesktopProtocol returns the Guacamole protocol name for an OS type.
func DesktopProtocol(osType string) string {
	if osType == "windows" {
		return "rdp"
	}
	return "vnc"
}

// DesktopPort returns the in-guest remote-desktop port for an OS type.
func DesktopPort(osType string) int32 {
	if osType == "windows" {
		return 3389
	}
	return 5900
}

// DesktopServiceName returns the name of a VM's remote-desktop Service.
func DesktopServiceName(vmName string) string { return "desktop-" + vmName }

// DesktopService creates the ClusterIP service Guacamole connects through to
// reach a pool VM's desktop.
func DesktopService(vmName, namespace, osType string) *corev1.Service {
	port := DesktopPort(osType)
	return &corev1.Service{
		ObjectMeta: metav1.ObjectMeta{
			Name:      DesktopServiceName(vmName),
			Namespace: namespace,
			Labels:    Labels(osType, "creating", vmName),
		},
		Spec: corev1.ServiceSpec{
			Type:     corev1.ServiceTypeClusterIP,
			Selector: map[string]string{"kubevirt.io/vm": vmName},
			Ports: []corev1.ServicePort{{
				Name:       DesktopProtocol(osType),
				Port:       port,
				TargetPort: intstr.FromInt(int(port)),
				Protocol:   corev1.ProtocolTCP,
			}},
		},
	}
}

// ── internal helpers ──────────────────────────────────────────────────────────

func masqueradeIface() kubevirtv1.Interface {
	return kubevirtv1.Interface{
		Name: "default",
		InterfaceBindingMethod: kubevirtv1.InterfaceBindingMethod{
			Masquerade: &kubevirtv1.InterfaceMasquerade{},
		},
	}
}

func buildDisks(osType string) []kubevirtv1.Disk {
	disks := []kubevirtv1.Disk{{
		Name:       "rootdisk",
		DiskDevice: kubevirtv1.DiskDevice{Disk: &kubevirtv1.DiskTarget{Bus: "virtio"}},
	}}
	switch osType {
	case "ubuntu":
		disks = append(disks, kubevirtv1.Disk{
			Name:       "cloudinitdisk",
			DiskDevice: kubevirtv1.DiskDevice{Disk: &kubevirtv1.DiskTarget{Bus: "virtio"}},
		})
	case "windows":
		disks = append(disks, kubevirtv1.Disk{
			Name:       "sysprep",
			DiskDevice: kubevirtv1.DiskDevice{CDRom: &kubevirtv1.CDRomTarget{Bus: "sata"}},
		})
	}
	return disks
}

func buildVolumes(osType, vmName string) []kubevirtv1.Volume {
	vols := []kubevirtv1.Volume{{
		Name: "rootdisk",
		VolumeSource: kubevirtv1.VolumeSource{
			DataVolume: &kubevirtv1.DataVolumeSource{Name: vmName + "-disk"},
		},
	}}
	switch osType {
	case "ubuntu":
		vols = append(vols, kubevirtv1.Volume{
			Name: "cloudinitdisk",
			VolumeSource: kubevirtv1.VolumeSource{
				CloudInitNoCloud: &kubevirtv1.CloudInitNoCloudSource{
					UserData: fmt.Sprintf("#cloud-config\nhostname: %s\n", vmName),
				},
			},
		})
	case "windows":
		vols = append(vols, kubevirtv1.Volume{
			Name: "sysprep",
			VolumeSource: kubevirtv1.VolumeSource{
				Sysprep: &kubevirtv1.SysprepSource{
					ConfigMap: &corev1.LocalObjectReference{Name: "windows-pool-unattend"},
				},
			},
		})
	}
	return vols
}

func buildFeatures(osType string) *kubevirtv1.Features {
	f := &kubevirtv1.Features{
		SMM: &kubevirtv1.FeatureState{Enabled: ptr(true)},
	}
	if osType == "windows" {
		retries := uint32(8191)
		f.Hyperv = &kubevirtv1.FeatureHyperv{
			Relaxed:   &kubevirtv1.FeatureState{Enabled: ptr(true)},
			VAPIC:     &kubevirtv1.FeatureState{Enabled: ptr(true)},
			Spinlocks: &kubevirtv1.FeatureSpinlocks{Enabled: ptr(true), Retries: &retries},
		}
	}
	return f
}

func ptr[T any](v T) *T { return &v }
