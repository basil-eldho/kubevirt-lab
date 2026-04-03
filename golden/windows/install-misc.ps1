# Grounded against official example:
# https://github.com/hashicorp/packer-plugin-kubevirt/blob/main/examples/builder/kubevirt-iso/windows/install-misc.ps1
# Runs from F:\ during auditUser pass.
# VirtIO drivers and QEMU guest agent are on the virtio-win ISO at E:\

# VirtIO drivers (storage, network, balloon, etc.)
Start-Process msiexec -Wait -ArgumentList "/i E:\virtio-win-gt-x64.msi /qn /passive /norestart"

# QEMU guest agent — enables AgentConnected condition in pool controller
Start-Process msiexec -Wait -ArgumentList "/i E:\guest-agent\qemu-ga-x86_64.msi /qn /passive /norestart"

# Rename cached unattend.xml so sysprep doesn't re-apply it
if (Test-Path C:\Windows\Panther\unattend.xml) {
    Move-Item C:\Windows\Panther\unattend.xml C:\Windows\Panther\unattend.install.xml
}
