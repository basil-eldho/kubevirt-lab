# Grounded against: https://github.com/hashicorp/packer-plugin-kubevirt
# Actual required fields from docs-partials/builder/kubevirt/iso/Config-required.mdx:
#   kube_config, name, namespace, iso_volume_name, disk_size,
#   instance_type, preference, installation_wait_timeout

# packer {
#   required_plugins {
#     kubevirt = {
#       source  = "github.com/hashicorp/kubevirt"
#       version = ">= 0.8.0"
#     }
#   }
# }
# Commented out to use local dev build — see CONTRIBUTING.md

variable "kube_config" {
  description = "Path to kubeconfig file"
  default     = "${env("KUBECONFIG")}"
}

variable "namespace" {
  default = "default"
}

variable "name" {
  description = "Output DataVolume name — this IS the golden image PVC name"
  default     = "ubuntu-golden"
}

variable "disk_size" {
  default = "20Gi"
}

variable "instance_type" {
  default = "u1.medium"   # 1 vCPU, 4Gi RAM
}

variable "preference" {
  default = "ubuntu"
}


source "kubevirt-iso" "ubuntu" {
  kube_config = var.kube_config
  name        = var.name
  namespace   = var.namespace

  iso_volume_name = "ubuntu-2404-iso"

  disk_size     = var.disk_size
  instance_type = var.instance_type
  preference    = var.preference
  os_type       = "linux"

  networks {
    name  = "default"
    pod {}
  }

  # media_files_label = "cidata": cloud-init's NoCloud datasource auto-detects
  # a disk labeled "cidata" without any kernel cmdline ds= parameter needed.
  # This is the fix contributed to the plugin — replaces the OEMDRV approach
  # which only works for Kickstart-based distros (Fedora, RHEL).
  media_files = [
    "./user-data",
    "./meta-data",
  ]
  media_files_label = "cidata"

  # boot_wait: must be shorter than Ubuntu Server GRUB auto-boot timeout (~5s).
  # No ds= parameter needed — cloud-init finds the cidata disk automatically.
  boot_wait = "15s"
  boot_command = [
    "e<wait2>",
    "<down><down><down><end>",
    " autoinstall",
    "<f10><wait>"
  ]

  installation_wait_timeout = "5m"

  # Port forwarding: plugin auto-allocates an ephemeral local port and
  # forwards it to ssh_port (22) on the VM via the Kubernetes API.
  # No ssh_host, ssh_local_port, or ssh_remote_port needed.
  communicator = "ssh"
  ssh_username = "student"
  ssh_password = "ubuntu"
  ssh_timeout  = "20m"
}

build {
  sources = ["source.kubevirt-iso.ubuntu"]

  provisioner "shell" {
    execute_command = "echo 'ubuntu' | sudo -S bash {{.Path}}"
    scripts         = ["scripts/setup-desktop.sh"]
  }

  provisioner "shell" {
    execute_command = "echo 'ubuntu' | sudo -S bash -c '{{.Vars}} bash {{.Path}}'"
    inline = [
      "cloud-init clean --logs --seed",
      "rm -rf /var/lib/cloud/instances /var/lib/cloud/data",
      "truncate -s 0 /etc/hostname",
      # Leave /etc/machine-id in place but EMPTY — never delete it. When the
      # file is missing systemd treats the boot as a first boot: it writes
      # "uninitialized\n" and overmounts the real ID, committing it to disk only
      # after first-boot-complete.target. systemd-networkd starts before that
      # and derives its DHCP DUID from the machine ID, so it aborts with
      # "Failed to configure DHCPv4 client: No such file or directory". The VM
      # then never gets a lease, enp1s0 stays IPv4-less, and x11vnc — though
      # listening on 0.0.0.0:5900 — is unreachable, so Guacamole connects to
      # guacd but shows no desktop. An empty file is the shape systemd
      # documents for images: https://systemd.io/BUILDING_IMAGES/
      "truncate -s 0 /etc/machine-id",
      "ln -sf /etc/machine-id /var/lib/dbus/machine-id",
      "sync"
    ]
  }
}
