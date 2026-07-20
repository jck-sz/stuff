<#
    .SYNOPSIS
    Bootstraps WinGet for use in the non-interactive SYSTEM context.

    WinGet (App Installer) is a per-user MSIX package. In a Packer build there
    is no interactive logon, so the CLI is not registered/usable out of the
    box. Microsoft's supported bootstrap for automation is the
    Microsoft.WinGet.Client PowerShell module: Repair-WinGetPackageManager
    downloads the latest App Installer + dependencies (VCLibs, UI.Xaml) and
    provisions them machine-wide (-AllUsers), after which winget.exe can be
    invoked by full path from SYSTEM.
#>
$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

Write-Host '=== Installing Microsoft.WinGet.Client PowerShell module ==='
Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope AllUsers | Out-Null
Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
Install-Module -Name Microsoft.WinGet.Client -Repository PSGallery -Scope AllUsers -Force

Write-Host '=== Bootstrapping WinGet (App Installer + dependencies, all users) ==='
Repair-WinGetPackageManager -AllUsers -Latest -Force

$winget = Get-ChildItem "$env:ProgramFiles\WindowsApps\Microsoft.DesktopAppInstaller_*_x64__8wekyb3d8bbwe\winget.exe" -ErrorAction SilentlyContinue |
    Sort-Object { [version]$_.VersionInfo.ProductVersion } |
    Select-Object -Last 1 -ExpandProperty FullName
if (-not $winget) { throw 'winget.exe not found after bootstrap.' }

Write-Host "winget resolved to: $winget"
& $winget --version

# The msstore source cannot be used in the SYSTEM context and only slows every
# call down (EULA prompts, auth). All packages in this build come from the
# community 'winget' source.
& $winget source remove msstore 2>$null
& $winget source update --disable-interactivity

Write-Host '=== WinGet bootstrap complete ==='
exit 0
