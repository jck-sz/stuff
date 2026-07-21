<#
    .SYNOPSIS
    Installs PowerShell 7 via WinGet, running as a real user (not SYSTEM).

    Microsoft.PowerShell's only winget-manifest installer is type MSIX
    (confirmed via 'winget show --installer-type msi' -> "No applicable
    installer found"). MSIX/AppX package deployment cannot run under SYSTEM
    at all - an OS-level restriction, not a winget bug or flag to work
    around - so this one package needs a real elevated user, unlike every
    other package in Install-Apps.ps1. Packer's own elevated_user mechanism
    (see win11-ent.pkr.hcl) runs this script as 'packer' for exactly that
    reason.
#>
$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

$winget = Get-ChildItem "$env:ProgramFiles\WindowsApps\Microsoft.DesktopAppInstaller_*_x64__8wekyb3d8bbwe\winget.exe" -ErrorAction SilentlyContinue |
    Sort-Object { [version]$_.VersionInfo.ProductVersion } |
    Select-Object -Last 1 -ExpandProperty FullName
if (-not $winget) { throw 'winget.exe not found. Did Install-WinGet.ps1 run?' }
Write-Host "Using winget: $winget"

& $winget install --exact --id Microsoft.PowerShell `
    --silent --disable-interactivity --scope machine `
    --accept-package-agreements --accept-source-agreements --source winget

# 1641/3010: MSI reboot initiated/required - still a success (a
# windows-restart provisioner runs later in the build).
$code = $LASTEXITCODE
if ($code -notin 0, 1641, 3010) {
    throw "Microsoft.PowerShell install failed (exit $code / 0x$('{0:X8}' -f $code))"
}
Write-Host "=== OK: Microsoft.PowerShell (exit $code) ==="
exit 0
