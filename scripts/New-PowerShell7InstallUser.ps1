<#
    .SYNOPSIS
    Creates a dedicated local admin account for the PowerShell 7 install step.

    Packer's elevated_user for Install-PowerShell7.ps1 cannot reuse 'packer'
    itself (the WinRM communicator's own account, winrm_username in
    win11-ent.pkr.hcl): its scheduled task got stuck in "Queued" forever,
    confirmed live even after granting 'packer' the "Log on as a batch job"
    right directly - no SeDenyBatchLogonRight, no other policy conflict,
    and Task Scheduler's own event log recorded nothing, meaning the task
    never even attempted to start. The one thing different about that
    account is that it already holds the WinRM session for the whole
    build. A fresh, otherwise-idle local admin account avoids whatever
    session conflict that was.
#>
$ErrorActionPreference = 'Stop'

$password = ConvertTo-SecureString $env:PACKER_PS7_INSTALL_PWD -AsPlainText -Force
New-LocalUser -Name 'ps7installer' -Password $password -PasswordNeverExpires -AccountNeverExpires | Out-Null
Add-LocalGroupMember -Group 'Administrators' -Member 'ps7installer'

$sid = (New-Object System.Security.Principal.NTAccount('ps7installer')).Translate([System.Security.Principal.SecurityIdentifier]).Value
$cfgPath = Join-Path $env:TEMP 'ps7installer-secpol.cfg'
$dbPath  = Join-Path $env:TEMP 'ps7installer-secpol.sdb'
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

Write-Host "Created local admin 'ps7installer' with batch-logon rights"
exit 0
