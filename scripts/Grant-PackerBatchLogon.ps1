<#
    .SYNOPSIS
    Grants the 'packer' user the "Log on as a batch job" right.

    Packer's elevated_user mechanism runs a provisioner script via a
    one-time scheduled task. For SYSTEM this always works, but a non-SYSTEM
    account (like 'packer', used for the PowerShell 7 install - see
    win11-ent.pkr.hcl) needs SeBatchLogonRight, which local Administrators
    do not get by default on this image. Without it the task sits in
    'Queued' forever and the build hangs. Run as SYSTEM, before any
    provisioner uses elevated_user = "packer".
#>
$ErrorActionPreference = 'Stop'

$sid = (New-Object System.Security.Principal.NTAccount('packer')).Translate([System.Security.Principal.SecurityIdentifier]).Value

$cfgPath = Join-Path $env:TEMP 'packer-secpol.cfg'
$dbPath  = Join-Path $env:TEMP 'packer-secpol.sdb'
secedit /export /cfg $cfgPath /areas USER_RIGHTS | Out-Null

$lines = Get-Content $cfgPath
$found = $false
$lines = $lines | ForEach-Object {
    if ($_ -match '^\s*SeBatchLogonRight\s*=') {
        $found = $true
        if ($_ -notmatch [regex]::Escape("*$sid")) { "$_,*$sid" } else { $_ }
    } else {
        $_
    }
}
if (-not $found) { $lines += "SeBatchLogonRight = *$sid" }
$lines | Set-Content $cfgPath

secedit /configure /db $dbPath /cfg $cfgPath /areas USER_RIGHTS | Out-Null
Remove-Item $cfgPath, $dbPath -Force -ErrorAction SilentlyContinue

Write-Host "Granted 'Log on as a batch job' to packer ($sid)"
exit 0
