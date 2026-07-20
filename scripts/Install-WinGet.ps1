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

    Microsoft.WinGet.Client 1.11+ no longer supports Windows PowerShell 5.1
    (the shell Packer provisioners run in), so PowerShell 7 is installed
    first and the bootstrap runs under pwsh. PS7 is on the image's app list
    anyway, so this just front-loads it.
#>
$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

Write-Host '=== Installing PowerShell 7 (required by the WinGet PowerShell module) ==='
$release  = Invoke-RestMethod 'https://api.github.com/repos/PowerShell/PowerShell/releases/latest'
$msiAsset = $release.assets | Where-Object name -like 'PowerShell-*-win-x64.msi' | Select-Object -First 1
$msiPath  = Join-Path $env:TEMP $msiAsset.name
Invoke-WebRequest -Uri $msiAsset.browser_download_url -OutFile $msiPath -UseBasicParsing
$proc = Start-Process msiexec.exe -ArgumentList "/i `"$msiPath`" /qn /norestart" -Wait -PassThru
if ($proc.ExitCode -ne 0) { throw "PowerShell 7 MSI failed with exit code $($proc.ExitCode)" }
Remove-Item $msiPath -Force

$pwsh = "$env:ProgramFiles\PowerShell\7\pwsh.exe"
if (-not (Test-Path $pwsh)) { throw 'pwsh.exe not found after PowerShell 7 install.' }
& $pwsh -NoLogo -NoProfile -Command '$PSVersionTable.PSVersion.ToString()'

Write-Host '=== Bootstrapping WinGet (App Installer + dependencies, all users) ==='
& $pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -Command @'
$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
Install-PSResource -Name Microsoft.WinGet.Client -Scope AllUsers -TrustRepository -Quiet
Repair-WinGetPackageManager -AllUsers -Latest -Force
'@
if ($LASTEXITCODE -ne 0) { throw "WinGet bootstrap under pwsh failed with exit code $LASTEXITCODE" }

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
