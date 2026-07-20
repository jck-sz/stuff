<#
    .SYNOPSIS
    Bootstraps WinGet for use in the non-interactive SYSTEM context.

    WinGet (App Installer) is a per-user MSIX package: on a fresh marketplace
    image no interactive logon has ever happened, so winget.exe is not
    usable from the SYSTEM account Packer provisions with. The
    Microsoft.WinGet.Client module (Repair-WinGetPackageManager) is not
    reliable headless: 1.11+ dropped Windows PowerShell support, and under
    pwsh it fails in a WinRM/SYSTEM session ("Specified method is not
    supported"). So this provisions the package machine-wide with DISM
    instead: download the latest App Installer msixbundle + dependencies
    from the official winget-cli release and Add-AppxProvisionedPackage,
    after which winget.exe can be invoked by full path from SYSTEM.

    WinGet is a build-time tool only for this image - it is removed again
    by Remove-WinGetBootstrap.ps1 before sysprep.
#>
$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

Write-Host '=== Enabling NTFS long path support ==='
# WinGet's SYSTEM-profile cache lives under a long base path
# (C:\Windows\System32\config\systemprofile\AppData\Local\...); combined with
# a nested zip entry this can exceed MAX_PATH (260 chars) and silently break
# extraction for zip-wrapped installers (e.g. Paint.NET) later in the build.
New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' `
    -Name LongPathsEnabled -Value 1 -PropertyType DWord -Force | Out-Null

$dir = Join-Path $env:TEMP 'winget-bootstrap'
New-Item -ItemType Directory -Force -Path $dir | Out-Null

Write-Host '=== Downloading latest App Installer release ==='
$release = Invoke-RestMethod 'https://api.github.com/repos/microsoft/winget-cli/releases/latest'
Write-Host "Release: $($release.tag_name)"

function Get-ReleaseAsset([string]$Pattern, [switch]$Optional) {
    $asset = $release.assets | Where-Object name -like $Pattern | Select-Object -First 1
    if (-not $asset) {
        if ($Optional) { return $null }
        throw "Release asset matching '$Pattern' not found."
    }
    $path = Join-Path $dir $asset.name
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $path -UseBasicParsing
    $path
}

$bundle  = Get-ReleaseAsset 'Microsoft.DesktopAppInstaller_*.msixbundle'
$depsZip = Get-ReleaseAsset 'DesktopAppInstaller_Dependencies.zip'
$license = Get-ReleaseAsset '*License1.xml' -Optional

Expand-Archive -Path $depsZip -DestinationPath (Join-Path $dir 'deps') -Force
$deps = Get-ChildItem (Join-Path $dir 'deps\x64\*.appx') | Select-Object -ExpandProperty FullName
if (-not $deps) { throw 'No x64 dependency packages found in DesktopAppInstaller_Dependencies.zip.' }

Write-Host '=== Provisioning App Installer machine-wide (DISM) ==='
if ($license) {
    Add-AppxProvisionedPackage -Online -PackagePath $bundle -DependencyPackagePath $deps -LicensePath $license | Out-Null
} else {
    Add-AppxProvisionedPackage -Online -PackagePath $bundle -DependencyPackagePath $deps -SkipLicense | Out-Null
}
Remove-Item $dir -Recurse -Force

Write-Host '=== Installing VC++ 2015-2022 runtime (x64) ==='
# MSIX packages cannot be registered for SYSTEM (0x80073CF9), so winget runs
# here without package identity ("full path" mode, supported since 1.6).
# Without identity its VC runtime cannot come from the VCLibs dependency
# package graph - the plain desktop VC++ redistributable must be in
# System32, and fresh Windows 11 marketplace images do not ship it. (A dev
# image wants it anyway; Visual Studio would install it later regardless.)
$vcRedist = Join-Path $env:TEMP 'vc_redist.x64.exe'
Invoke-WebRequest -Uri 'https://aka.ms/vs/17/release/vc_redist.x64.exe' -OutFile $vcRedist -UseBasicParsing
$proc = Start-Process $vcRedist -ArgumentList '/install', '/quiet', '/norestart' -Wait -PassThru
if ($proc.ExitCode -notin 0, 3010) { throw "vc_redist.x64.exe failed with exit code $($proc.ExitCode)" }
Remove-Item $vcRedist -Force

$winget = Get-ChildItem "$env:ProgramFiles\WindowsApps\Microsoft.DesktopAppInstaller_*_x64__8wekyb3d8bbwe\winget.exe" -ErrorAction SilentlyContinue |
    Sort-Object { [version]$_.VersionInfo.ProductVersion } |
    Select-Object -Last 1 -ExpandProperty FullName
if (-not $winget) { throw 'winget.exe not found after provisioning.' }

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
