# Runs via Packer WinRM provisioner AFTER autounattend.xml has finished.
# At this point: VirtIO drivers installed, WinRM open, OS fully set up.
# Creates the student lab user and applies lab-specific settings.
#Requires -RunAsAdministrator

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$StudentUser = "student"
$StudentPass = "Lab@2024!"

# Create student user (what pool VMs expose to students via RDP)
$SecurePass = ConvertTo-SecureString $StudentPass -AsPlainText -Force
New-LocalUser -Name $StudentUser -Password $SecurePass `
    -FullName "Lab Student" -PasswordNeverExpires -UserMayNotChangePassword
Add-LocalGroupMember -Group "Administrators" -Member $StudentUser
Add-LocalGroupMember -Group "Remote Desktop Users" -Member $StudentUser

# Allow RDP connections
Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' `
    -Name 'fDenyTSConnections' -Value 0
Enable-NetFirewallRule -DisplayGroup "Remote Desktop" -ErrorAction SilentlyContinue

# Disable Windows Update (prevents downloads during student sessions)
Stop-Service  -Name wuauserv -Force -ErrorAction SilentlyContinue
Set-Service   -Name wuauserv -StartupType Disabled

# Allow OOBE to proceed with a local account after sysprep (Windows 11 otherwise
# forces a Microsoft account when network is present).
reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE" /v BypassNRO /t REG_DWORD /d 1 /f

# Replace the Packer answer file cached in Panther with the pool OOBE answer file.
# sysprep /generalize moves (not deletes) C:\Windows\Panther\unattend.xml →
# C:\Windows\Panther\Unattend\unattend.xml. OOBE finds Panther\Unattend first,
# before scanning removable media, so this is the reliable path per MS docs.
$poolUnattend = @'
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend"
          xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-International-Core"
               processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35"
               language="neutral"
               versionScope="nonSxS">
      <InputLocale>0409:00000409</InputLocale>
      <SystemLocale>en-US</SystemLocale>
      <UILanguage>en-US</UILanguage>
      <UserLocale>en-US</UserLocale>
    </component>
    <component name="Microsoft-Windows-Shell-Setup"
               processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35"
               language="neutral"
               versionScope="nonSxS">
      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <HideLocalAccountScreen>true</HideLocalAccountScreen>
        <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
        <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
        <NetworkLocation>Work</NetworkLocation>
        <ProtectYourPC>3</ProtectYourPC>
        <SkipMachineOOBE>true</SkipMachineOOBE>
        <SkipUserOOBE>true</SkipUserOOBE>
      </OOBE>
      <AutoLogon>
        <Password>
          <Value>Lab@2024!</Value>
          <PlainText>true</PlainText>
        </Password>
        <Domain>.</Domain>
        <Username>student</Username>
        <Enabled>true</Enabled>
        <LogonCount>9999</LogonCount>
      </AutoLogon>
    </component>
  </settings>
</unattend>
'@
New-Item -Path "$env:SystemRoot\Panther" -ItemType Directory -Force | Out-Null
Set-Content -Path "$env:SystemRoot\Panther\unattend.xml" -Value $poolUnattend -Encoding UTF8

Write-Host "Lab setup complete. Student user '$StudentUser' created."

# The audit-mode sysprep dialog opens automatically on the desktop. It blocks
# the next Packer provisioner step from running sysprep on the command line
# (sysprep refuses to start a second instance). Kill it here so the
# windows-shell provisioner can run sysprep cleanly.
Write-Host "Killing audit-mode sysprep dialog if present..."
Stop-Process -Name sysprep -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2
Write-Host "setup.ps1 finished."
