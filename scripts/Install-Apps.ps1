<#
    .SYNOPSIS
    Installs all image software via WinGet (community 'winget' source only).

    Runs as SYSTEM so installs are machine-wide, not in the throwaway
    'packer' build user's profile. Failures do not abort mid-list: every
    package is attempted, then the script fails the build at the end if
    anything did not install, with a summary of what broke.
#>
$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

Start-Transcript -Path 'C:\Windows\Temp\packer-install-apps.log' -Append | Out-Null

function Resolve-WinGet {
    $cmd = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $exe = Get-ChildItem "$env:ProgramFiles\WindowsApps\Microsoft.DesktopAppInstaller_*_x64__8wekyb3d8bbwe\winget.exe" -ErrorAction SilentlyContinue |
        Sort-Object { [version]$_.VersionInfo.ProductVersion } |
        Select-Object -Last 1 -ExpandProperty FullName
    if ($exe) { return $exe }
    throw 'winget.exe not found. Did Install-WinGet.ps1 run?'
}
$winget = Resolve-WinGet
Write-Host "Using winget: $winget"

# Fail fast if winget cannot actually run (e.g. package not registered for
# SYSTEM -> 0xC0000135) instead of "failing" every package in the list.
$wingetVersion = & $winget --version
if ($LASTEXITCODE -ne 0 -or -not $wingetVersion) {
    Stop-Transcript | Out-Null
    throw "winget.exe is not functional (exit $LASTEXITCODE / 0x$('{0:X8}' -f $LASTEXITCODE)). Did Install-WinGet.ps1 run?"
}
Write-Host "winget version: $wingetVersion"

# Exit codes that still mean "installed OK":
#   1641 / 3010  MSI: reboot initiated / reboot required
#   0x8A150109   APPINSTALLER_CLI_ERROR_INSTALL_REBOOT_REQUIRED_TO_FINISH
#   0x8A15010B   APPINSTALLER_CLI_ERROR_INSTALL_REBOOT_INITIATED
# (a windows-restart provisioner runs after this script)
$okDecimal = @(0, 1641, 3010)
$okHex     = @('8A150109', '8A15010B')

$failures = New-Object System.Collections.Generic.List[string]

# Two guessed fixes (NTFS long paths; ENABLE_PSREMOTING=0) did not change the
# outcome for dotPDN.PaintDotNet / Microsoft.PowerShell, and the expected
# DiagOutputDir path under $env:LOCALAPPDATA turned out to hold no log at all
# - $env:LOCALAPPDATA is not reliable in Packer's elevated_user=SYSTEM
# context (a scheduled task, not a normal profile load), so winget's actual
# log location in this context is unknown. On failure, search broadly for
# whatever *.log winget just wrote instead of assuming a path.
function Write-WinGetDiagLogTail([int]$Lines = 80) {
    Write-Host "`$env:LOCALAPPDATA = '$env:LOCALAPPDATA'"
    $roots = @(
        $env:LOCALAPPDATA
        'C:\Windows\System32\config\systemprofile\AppData\Local'
        'C:\Windows\ServiceProfiles'
        'C:\ProgramData'
    ) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -Unique

    $recent = foreach ($root in $roots) {
        Get-ChildItem -Path $root -Recurse -Filter '*.log' -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -gt (Get-Date).AddMinutes(-3) }
    }
    $recent = $recent | Sort-Object LastWriteTime -Descending

    if (-not $recent) {
        Write-Host "(no .log file written in the last 3 minutes under: $($roots -join ', '))"
        return
    }
    foreach ($log in ($recent | Select-Object -First 3)) {
        Write-Host "--- tail of $($log.FullName) (modified $($log.LastWriteTime)) ---"
        Get-Content -Path $log.FullName -Tail $Lines -ErrorAction SilentlyContinue | ForEach-Object { Write-Host $_ }
        Write-Host '--- end ---'
    }
}

function Install-App {
    param(
        [Parameter(Mandatory)] [string] $Id,
        [string[]] $ExtraArgs = @()
    )
    Write-Host ''
    Write-Host "=== Installing $Id ==="
    $wingetArgs = @(
        'install', '--exact', '--id', $Id,
        '--silent', '--disable-interactivity',
        '--accept-package-agreements', '--accept-source-agreements',
        '--source', 'winget', '--verbose-logs'
    ) + $ExtraArgs
    & $winget @wingetArgs
    $code = $LASTEXITCODE
    $hex  = '{0:X8}' -f $code
    if (($okDecimal -contains $code) -or ($okHex -contains $hex)) {
        Write-Host "=== OK: $Id (exit $code) ==="
    }
    else {
        Write-Warning "FAILED: $Id (exit $code / 0x$hex)"
        Write-WinGetDiagLogTail
        $failures.Add("$Id (exit $code / 0x$hex)")
    }
}

# --- Visual Studio configuration ---------------------------------------------
# Edition: 2022 Enterprise. Alternatives:
#   Microsoft.VisualStudio.2022.Professional / .Community
#   Microsoft.VisualStudio.Enterprise (no year) = Visual Studio 2026
# NOTE: ReSharper below integrates into Visual Studio - verify JetBrains'
# VS 2026 support before switching the year.
# Without --override, winget installs only the bare VS core. --wait is
# required so winget blocks until the VS installer finishes.
$vsWorkloads = @(
    'Microsoft.VisualStudio.Workload.ManagedDesktop' # .NET desktop development
    'Microsoft.VisualStudio.Workload.NetWeb'         # ASP.NET and web development
    'Microsoft.VisualStudio.Workload.Azure'          # Azure development
    'Microsoft.VisualStudio.Workload.Data'           # Data storage and processing
) | ForEach-Object { "--add $_" }
$vsOverride = "--quiet --wait --norestart --nocache --includeRecommended $($vsWorkloads -join ' ')"

# --- Package list (order matters for the entries flagged below) --------------

# Utilities & browsers
Install-App '7zip.7zip'
Install-App 'Google.Chrome'
Install-App 'Mozilla.Firefox'
Install-App 'Notepad++.Notepad++'
Install-App 'PuTTY.PuTTY'
Install-App 'dotPDN.PaintDotNet'
Install-App 'TortoiseGit.TortoiseGit'
Install-App 'Microsoft.PowerShell' @('--custom', 'ENABLE_PSREMOTING=0') # PowerShell 7 (5.1 is in-box)
Install-App 'Microsoft.AzureCLI'

# .NET / Java / Node runtimes and SDKs - .NET 10 is the current LTS line.
# Duplicate these lines with '.8' if you also need .NET 8 (LTS until Nov 2026).
Install-App 'Microsoft.DotNet.SDK.10'                 # .NET SDK
Install-App 'Microsoft.DotNet.AspNetCore.10'          # ASP.NET Core Runtime
Install-App 'Microsoft.DotNet.DesktopRuntime.10'      # Windows Desktop Runtime
Install-App 'Microsoft.OpenJDK.21'                    # JDK (Microsoft OpenJDK; 25/17/11 also available)
Install-App 'OpenJS.NodeJS.LTS'                       # Node.js LTS

# NVM for Windows exists on winget (CoreyButler.NVMforWindows) but its
# installer is per-user: in this build it would land in the SYSTEM profile,
# invisible to real users, and nvm-windows conflicts with the machine-wide
# Node.js above (it wants to manage Node itself). Deliberately disabled -
# see README before enabling.
# Install-App 'CoreyButler.NVMforWindows'

# SQL Server / BI tooling
Install-App 'Microsoft.SQLServer.OLEDBDriver'         # MS OLE DB Driver for SQL Server
Install-App 'Microsoft.SQLServerManagementStudio.22'  # SSMS 22 (use '.21' for the 21.x line)
Install-App 'Microsoft.Azure.DataStudio'              # NOTE: retired product, last release 1.52 (Feb 2026)
Install-App 'Microsoft.PowerBI'                       # Power BI Desktop
Install-App 'Microsoft.PowerBIReportBuilder'
Install-App 'ChristianWade.PowerBIALMToolkit'         # ALM Toolkit - AFTER Power BI Desktop (External Tools integration)

# Editors & IDEs
Install-App 'Microsoft.VisualStudioCode' @('--scope', 'machine')
Install-App 'JetBrains.Rider'
Install-App 'Microsoft.VisualStudio.2022.Enterprise' @('--override', $vsOverride)
Install-App 'JetBrains.ReSharper'                     # AFTER Visual Studio (integrates into installed instances)

# --- Summary -----------------------------------------------------------------
Write-Host ''
if ($failures.Count -gt 0) {
    $summary = "The following packages failed to install:`n - " + ($failures -join "`n - ")
    Stop-Transcript | Out-Null
    throw $summary
}

Write-Host 'All packages installed successfully.'
Stop-Transcript | Out-Null
exit 0
