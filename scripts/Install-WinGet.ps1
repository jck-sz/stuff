<#
    .SYNOPSIS
    Prepares the already-provisioned WinGet (App Installer) for the
    non-interactive SYSTEM context - no download.

    Windows 11 marketplace images already ship App Installer, provisioned
    machine-wide. It just isn't directly usable from SYSTEM: no interactive
    logon has ever happened, so it has no per-account package identity/
    registration, which the Microsoft.WinGet.Client module (the documented
    repair path) depends on and which is impossible to grant to SYSTEM
    (0x80073CF9). This script does not provision or download anything - it
    only works around the identity gap for the copy already on disk:
      - installs the plain VC++ redistributable, since winget invoked
        without package identity ("full path" mode, supported since 1.6)
        can't pull its VC runtime from the normal VCLibs dependency graph
      - pre-creates winget's own per-account data folder, since without
        identity it never creates this itself and at least one operation
        (zip-archive extraction) fails immediately without it

    WinGet is a build-time tool only for this image - it is removed again
    by Remove-WinGetBootstrap.ps1 before sysprep.
#>
$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

Write-Host '=== Verifying App Installer is already provisioned on the base image ==='
$provisioned = Get-AppxProvisionedPackage -Online | Where-Object DisplayName -eq 'Microsoft.DesktopAppInstaller'
if (-not $provisioned) {
    throw 'Microsoft.DesktopAppInstaller is not provisioned on this base image. It normally ships on Windows 11 marketplace images - if the base image changed, restore the download-and-provision step this script used to have.'
}
Write-Host "Found: $($provisioned.DisplayName) $($provisioned.Version)"

Write-Host '=== Installing VC++ 2015-2022 runtime (x64) ==='
$vcRedist = Join-Path $env:TEMP 'vc_redist.x64.exe'
Invoke-WebRequest -Uri 'https://aka.ms/vs/17/release/vc_redist.x64.exe' -OutFile $vcRedist -UseBasicParsing
$proc = Start-Process $vcRedist -ArgumentList '/install', '/quiet', '/norestart' -Wait -PassThru
if ($proc.ExitCode -notin 0, 3010) { throw "vc_redist.x64.exe failed with exit code $($proc.ExitCode)" }
Remove-Item $vcRedist -Force

$winget = Get-ChildItem "$env:ProgramFiles\WindowsApps\Microsoft.DesktopAppInstaller_*_x64__8wekyb3d8bbwe\winget.exe" -ErrorAction SilentlyContinue |
    Sort-Object { [version]$_.VersionInfo.ProductVersion } |
    Select-Object -Last 1 -ExpandProperty FullName
if (-not $winget) { throw 'winget.exe not found even though the package is provisioned - unexpected layout.' }

Write-Host '=== Pre-creating WinGet per-account data folder ==='
$wingetData = Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.DesktopAppInstaller_8wekyb3d8bbwe\LocalState'
New-Item -ItemType Directory -Force -Path @(
    $wingetData
    Join-Path $wingetData 'DiagOutputDir'
    Join-Path $wingetData 'TempState'
    Join-Path $wingetData 'Settings'
) | Out-Null

Write-Host "winget resolved to: $winget"
$version = & $winget --version
if ($LASTEXITCODE -ne 0 -or -not $version) {
    throw "winget.exe is not functional (exit $LASTEXITCODE / 0x$('{0:X8}' -f $LASTEXITCODE))."
}
Write-Host "winget version: $version"

# The msstore source cannot be used in the SYSTEM context and only slows every
# call down (EULA prompts, auth). All packages in this build come from the
# community 'winget' source.
& $winget source remove msstore 2>$null
& $winget source update --disable-interactivity

Write-Host '=== WinGet bootstrap complete ==='
exit 0
