# Grounded against official example:
# https://github.com/hashicorp/packer-plugin-kubevirt/blob/main/examples/builder/kubevirt-iso/windows/enable-winrm.ps1
# Runs from F:\ during auditUser pass (before Packer WinRM communicator connects).

Enable-PSRemoting -Force
Enable-WSManCredSSP -Role Server -Force
Set-Item -Path WSMan:\localhost\Service\Auth\Basic -Value $true
Set-Item -Path WSMan:\localhost\Service\AllowUnencrypted -Value $true

New-NetFirewallRule -Name "WinRM_HTTP" -DisplayName "WinRM over HTTP" `
    -Protocol TCP -LocalPort 5985 -Action Allow
