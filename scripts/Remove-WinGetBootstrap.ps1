<#
    .SYNOPSIS
    Removes WinGet and all build-time bootstrap artifacts before sysprep.

    WinGet is used strictly as the build-time software installer for this
    image; end users must never have it. This removes:
      - the App Installer package (all users + the machine provisioning, so
        new profiles never get winget registered)
      - winget caches/logs in the SYSTEM profile and C:\Windows\Temp
    and sets the "Enable App Installer" policy to Disabled, so winget stays
    blocked for every user even if the Store ever reinstalls App Installer.
#>
# Best-effort cleanup: a missing item must not fail the build.
$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'

Write-Host '=== Clearing winget caches and build logs ==='
# SYSTEM profile ran all winget operations during the build.
Remove-Item 'C:\Windows\System32\config\systemprofile\AppData\Local\Packages\Microsoft.DesktopAppInstaller_8wekyb3d8bbwe' -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item 'C:\Windows\Temp\WinGet' -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item 'C:\Windows\Temp\packer-install-apps.log' -Force -ErrorAction SilentlyContinue

Write-Host '=== Removing WinGet / App Installer from the image ==='
Get-AppxPackage -AllUsers Microsoft.DesktopAppInstaller |
    Remove-AppxPackage -AllUsers -ErrorAction SilentlyContinue
Get-AppxProvisionedPackage -Online |
    Where-Object DisplayName -eq 'Microsoft.DesktopAppInstaller' |
    Remove-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Out-Null

Write-Host '=== Disabling App Installer by policy ==='
# Keeps winget blocked for all users even if the Store reinstalls the package.
New-Item -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppInstaller' -Force | Out-Null
Set-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppInstaller' `
    -Name EnableAppInstaller -Value 0 -Type DWord

Write-Host '=== WinGet removal + bootstrap cleanup complete ==='
exit 0
