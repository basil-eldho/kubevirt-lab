# Grounded against official example:
# https://github.com/hashicorp/packer-plugin-kubevirt/blob/main/examples/builder/kubevirt-iso/windows/set-network.ps1
# Sets network profile to Private — required before WinRM can accept connections.

$profile = Get-NetConnectionProfile
Set-NetConnectionProfile -InterfaceIndex $profile.InterfaceIndex -NetworkCategory Private
