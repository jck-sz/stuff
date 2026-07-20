<#
    .SYNOPSIS
    Removes the build-time WinGet bootstrap artifacts before sysprep.

    WinGet/App Installer itself is left in place: it ships in-box with
    Windows 11, users expect it, and removing it breaks MSIX/Store app
    servicing (the Store would reinstall it later anyway). This only cleans
    what Install-WinGet.ps1 added for the SYSTEM-context build:
      - Microsoft.WinGet.Client PowerShell module
      - winget caches/logs in the SYSTEM profile and C:\Windows\Temp
    (PowerShell 7, also installed by the bootstrap, stays - it is on the
    image's app list.)
#>
# Best-effort cleanup: a missing item must not fail the build.
$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'

Write-Host '=== Removing Microsoft.WinGet.Client module ==='
# Installed via Install-PSResource under PowerShell 7 (Scope AllUsers);
# PowerShell 7 itself stays - it is part of the image's app list.
Remove-Item "$env:ProgramFiles\PowerShell\Modules\Microsoft.WinGet.Client" -Recurse -Force -ErrorAction SilentlyContinue
# Legacy locations, in case the bootstrap ever ran under Windows PowerShell.
Remove-Item "$env:ProgramFiles\WindowsPowerShell\Modules\Microsoft.WinGet.Client" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item "$env:ProgramFiles\PackageManagement\ProviderAssemblies\NuGet" -Recurse -Force -ErrorAction SilentlyContinue

Write-Host '=== Clearing winget caches and build logs ==='
# SYSTEM profile ran all winget operations during the build.
Remove-Item 'C:\Windows\System32\config\systemprofile\AppData\Local\Packages\Microsoft.DesktopAppInstaller_8wekyb3d8bbwe' -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item 'C:\Windows\Temp\WinGet' -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item 'C:\Windows\Temp\packer-install-apps.log' -Force -ErrorAction SilentlyContinue

# If you REALLY want WinGet gone from the image (not recommended - see
# synopsis), uncomment the following. New user profiles will then get no
# winget until the Store reinstalls App Installer:
#
# Get-AppxPackage -AllUsers Microsoft.DesktopAppInstaller |
#     Remove-AppxPackage -AllUsers -ErrorAction SilentlyContinue
# Get-AppxProvisionedPackage -Online |
#     Where-Object DisplayName -eq 'Microsoft.DesktopAppInstaller' |
#     Remove-AppxProvisionedPackage -Online | Out-Null

Write-Host '=== WinGet bootstrap cleanup complete ==='
exit 0
