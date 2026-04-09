# Grounded against: https://github.com/hashicorp/packer-plugin-kubevirt
# Official Windows example: examples/builder/kubevirt-iso/windows/windows.pkr.hcl
#
# Prerequisites:
#   - windows-iso DataVolume must exist (see iso-dv.yaml)
#   - virtio-win ISO mounted as a second drive (for VirtIO drivers at E:\)
#   - KubeVirt common instance types and preferences installed in the cluster

packer {
  required_plugins {
    kubevirt = {
      source  = "github.com/hashicorp/kubevirt" # NOT packer-plugin-kubevirt
      version = ">= 0.8.0"
    }
  }
}

variable "kube_config" {
  default = "${env("KUBECONFIG")}"
}

variable "namespace" {
  default = "default"
}

variable "name" {
  description = "Output DataVolume name — this IS the golden image PVC name"
  default     = "windows-golden"
}

variable "disk_size" {
  default = "64Gi"
}

variable "instance_type" {
  default = "u1.medium" # 1 vCPU, 4Gi RAM — sufficient for Win10 install
}

variable "preference" {
  # VirtualMachineClusterPreference — includes VirtIO device config for Windows
  default = "windows.10.virtio"
}

variable "winrm_password" {
  description = "Must match AdministratorPassword in autounattend.xml"
  default     = "Lab@2024!"
  sensitive   = true
}

source "kubevirt-iso" "windows" {
  kube_config = var.kube_config
  name        = var.name
  namespace   = var.namespace

  iso_volume_name = "windows-iso"

  disk_size     = var.disk_size
  instance_type = var.instance_type
  preference    = var.preference
  os_type       = "windows"

  networks {
    name = "default"
    pod {}
  }

  # media_files are stored in a ConfigMap and mounted as a KubeVirt sysprep
  # volume (F:\). autounattend.xml is NOT auto-detected by Windows 10 setup.exe
  # from the sysprep volume (Windows 10 only scans its own boot drive, D:\).
  # Fix: autounattend.xml is injected into the Windows ISO root (D:\) at build
  # time using xorriso (see Makefile prepare-windows-iso target). The ISO also
  # uses efisys_noprompt.bin so no keypress is needed on first boot. Scripts
  # (enable-winrm.ps1 etc.) remain on F:\ and are referenced by autounattend.xml.
  # On subsequent reboots, Windows installer updates EFI NVRAM to boot from the
  # installed OS on the rootdisk — the CD is no longer the active boot device.
  media_files = [
    "./autounattend.xml",
    "./enable-winrm.ps1",
    "./set-network.ps1",
    "./install-misc.ps1",
  ]

  boot_wait = "3s"
  boot_command = ["<enter>"]

  installation_wait_timeout = "5m"

  # Port forwarding: plugin auto-allocates an ephemeral local port and
  # forwards it to winrm_port (5985) on the VM via the Kubernetes API.
  # No winrm_host, winrm_local_port, or winrm_remote_port needed.
  communicator   = "winrm"
  winrm_username = "Administrator" # matches autounattend.xml AutoLogon
  winrm_password = var.winrm_password
  winrm_timeout  = "30m"
}

build {
  sources = ["source.kubevirt-iso.windows"]

  # Create student user and apply lab settings via Packer WinRM connection
  provisioner "powershell" {
    scripts = ["scripts/setup.ps1"]
  }

  # Sysprep: generalize the image so each clone gets a unique SID and hostname.
  # /mode:vm is faster than full sysprep — it skips hardware detection.
  # Remove this block if unique SIDs are not required for your lab.
  provisioner "windows-shell" {
    inline = [
      "C:\\Windows\\System32\\Sysprep\\sysprep.exe /generalize /oobe /shutdown /mode:vm"
    ]
    # WinRM drops when sysprep shuts down the VM — that is expected and not an error.
    valid_exit_codes = [0, 1115, 1116]
  }
}
