# Windows 11 Enterprise developer image (Azure, Packer, WinGet)

Builds a generalized Windows 11 Enterprise image from the Azure Marketplace
base (`MicrosoftWindowsDesktop:windows-11:win11-24h2-ent`), installs all
software via **WinGet only**, sysprep-generalizes the VM and publishes it as a
new image version to an **Azure Compute Gallery**.

Windows 11 marketplace images are Trusted Launch by default, and a Trusted
Launch VM cannot be captured to a plain managed image — which is why the
output goes to a Compute Gallery with a TrustedLaunch image definition.

## Files

| File | Purpose |
|---|---|
| `win11-ent.pkr.hcl` | Builder (azure-arm, Trusted Launch, WinRM) + provisioning steps |
| `variables.pkr.hcl` | Input variables |
| `win11.auto.pkrvars.hcl.example` | Copy to `win11.auto.pkrvars.hcl` and fill in |
| `scripts/Install-WinGet.ps1` | Provisions the latest App Installer machine-wide via DISM (`Add-AppxProvisionedPackage`) so winget is usable from SYSTEM - the WinGet PowerShell module is not reliable headless |
| `scripts/Install-Apps.ps1` | Installs every application via `winget install` |
| `scripts/Grant-PackerBatchLogon.ps1` | Grants the `packer` user "Log on as a batch job" - required for Packer's `elevated_user` to run as a non-SYSTEM account (see [Known winget install issues](#known-winget-install-issues)) |
| `scripts/Install-PowerShell7.ps1` | Installs PowerShell 7 via winget as the `packer` user - its only winget installer is MSIX, which cannot deploy under SYSTEM |
| `scripts/Remove-WinGetBootstrap.ps1` | Removes WinGet from the image before sysprep (build-time tool only) and policy-disables App Installer for all users |

## Prerequisites

- Packer >= 1.10 (`brew tap hashicorp/tap && brew install hashicorp/tap/packer`)
- Azure CLI, logged in: `az login` (the template uses `use_azure_cli_auth`)
- Rights to create a temporary resource group / VM / Key Vault in the
  subscription, and to publish to the gallery
- One-time: a Compute Gallery and a **TrustedLaunch, Generalized, V2** image
  definition:

```bash
az group create --name rg-images --location westeurope

az sig create --resource-group rg-images --gallery-name acg_corp_images

az sig image-definition create \
  --resource-group rg-images \
  --gallery-name acg_corp_images \
  --gallery-image-definition win11-ent-dev \
  --publisher MyOrg --offer windows-11 --sku win11-ent-dev \
  --os-type Windows --os-state Generalized \
  --hyper-v-generation V2 \
  --features SecurityType=TrustedLaunch
```

## Build

```bash
cp win11.auto.pkrvars.hcl.example win11.auto.pkrvars.hcl   # then edit
packer init .
packer validate .
packer build .
```

Expect roughly 1.5–3 h; Visual Studio dominates. Provisioning logs from the
app install land in `C:\Windows\Temp\packer-install-apps.log` on the build VM
(also streamed to the Packer console).

## Versioning & consuming "latest"

Gallery image versions must be `Major.Minor.Patch` (each segment a plain
integer), and Azure orders them **numerically per segment** — so date-based
versions sort correctly and no manual "latest" tagging is ever needed:
consumers that reference the image *definition* (instead of a specific
version) automatically get the highest version number.

**Version selection in this template** (`gallery_image_version`):

- Unset (default) → auto-generated from UTC build time: `YYYYMMDD.hhmm.0`
  (e.g. `20260720.1432.0`). Unique per minute — fine for local/ad-hoc builds.
- Set via the `PKR_VAR_gallery_image_version` environment variable or
  `-var gallery_image_version=...` → used as-is. **Use this in CI** so
  parallel/same-minute builds can't collide.

### Azure DevOps

`counter()` keyed by the date gives a per-day sequence (1, 2, 3… resets each
day):

```yaml
variables:
  imageVersion: $[format('{0:yyyyMMdd}.{1}.0', pipeline.startTime, counter(format('{0:yyyyMMdd}', pipeline.startTime), 1))]

steps:
  - script: |
      packer init .
      packer build .
    displayName: Build image
    env:
      PKR_VAR_gallery_image_version: $(imageVersion)
      PKR_VAR_subscription_id: $(subscriptionId)
      # gallery_* variables via pkrvars file or more PKR_VAR_ entries
```

Produces `20260720.1.0`, `20260720.2.0`, … then `20260721.1.0` the next day.

### GitHub Actions

`run_number` increments per workflow (not per day) — still strictly unique
and date still dominates the ordering; `run_attempt` keeps re-runs unique:

```yaml
steps:
  - name: Compute image version
    run: echo "PKR_VAR_gallery_image_version=$(date -u +%Y%m%d).${{ github.run_number }}.${{ github.run_attempt }}" >> "$GITHUB_ENV"

  - name: Build image
    run: |
      packer init .
      packer build .
    env:
      PKR_VAR_subscription_id: ${{ secrets.AZURE_SUBSCRIPTION_ID }}
```

### Deployment pipeline: always take the latest version

Reference the image **definition** — not a version — and Azure resolves the
newest version at deploy time:

```bash
# az CLI - no version in the ID = latest
az vm create \
  --resource-group rg-servers --name vm-dev-01 \
  --image "/subscriptions/<sub>/resourceGroups/rg-images/providers/Microsoft.Compute/galleries/acg_corp_images/images/win11-ent-dev" \
  --security-type TrustedLaunch --enable-secure-boot true --enable-vtpm true
```

- **Bicep/ARM**: set `imageReference.id` to the image *definition* resource ID
  (no `/versions/...` suffix) — the latest version is used.
- **Terraform**: data source `azurerm_shared_image_version` with
  `name = "latest"` (or `"recent"` for most recently updated), then feed its
  ID into `source_image_id`.

### Optional: gate new versions before they become "latest"

Uncomment `shared_gallery_image_version_exclude_from_latest = true` in
`win11-ent.pkr.hcl` and the freshly built version is skipped by all
latest-resolution above. Smoke-test the explicit version, then release it:

```bash
az sig image-version update -g rg-images -r acg_corp_images \
  -i win11-ent-dev -e 20260720.1.0 \
  --set publishingProfile.excludeFromLatest=false
```

## Installed software (WinGet IDs)

| Software | WinGet ID | Notes |
|---|---|---|
| 7-Zip | `7zip.7zip` | |
| ALM Toolkit | `ChristianWade.PowerBIALMToolkit` | Installed after Power BI Desktop |
| ASP.NET Core Runtime | `Microsoft.DotNet.AspNetCore.10` | .NET 10 = current LTS; add `.8` variants if needed |
| Azure CLI | `Microsoft.AzureCLI` | |
| Azure Data Studio | `Microsoft.Azure.DataStudio` | Product retired 2026-02-28, last release 1.52; consider VS Code + MSSQL extension |
| Google Chrome | `Google.Chrome` | |
| .NET SDK | `Microsoft.DotNet.SDK.10` | |
| Mozilla Firefox | `Mozilla.Firefox` | |
| JetBrains ReSharper | `JetBrains.ReSharper` | Must install after Visual Studio |
| JetBrains Rider | `JetBrains.Rider` | |
| MS OLE DB Driver for SQL Server | `Microsoft.SQLServer.OLEDBDriver` | |
| Node.js | `OpenJS.NodeJS.LTS` | |
| Notepad++ | `Notepad++.Notepad++` | |
| Paint.NET | `dotPDN.PaintDotNet` | **Temporarily disabled** — see [Known winget install issues](#known-winget-install-issues) |
| Power BI Desktop | `Microsoft.PowerBI` | |
| Power BI Report Builder | `Microsoft.PowerBIReportBuilder` | |
| PowerShell 7 | `Microsoft.PowerShell` | Windows PowerShell 5.1 is in-box anyway; installed by a dedicated provisioner as the `packer` user — see [Known winget install issues](#known-winget-install-issues) |
| PuTTY | `PuTTY.PuTTY` | |
| TortoiseGit | `TortoiseGit.TortoiseGit` | |
| Visual Studio 2022 Enterprise | `Microsoft.VisualStudio.2022.Enterprise` | Edition/workloads configurable in `Install-Apps.ps1`; `Microsoft.VisualStudio.Enterprise` (no year) = VS 2026 |
| Visual Studio Code | `Microsoft.VisualStudioCode` | `--scope machine` |
| SQL Server Management Studio 22 | `Microsoft.SQLServerManagementStudio.22` | `.21` for the 21.x line |
| Windows Desktop Runtime | `Microsoft.DotNet.DesktopRuntime.10` | |
| JDK (Microsoft OpenJDK 21) | `Microsoft.OpenJDK.21` | `.25` (newest LTS), `.17`, `.11` also exist; swap vendor if you prefer Temurin/Oracle |

## Deliberately not installed

- **Snipping Tool** — ships with Windows 11; already in the base image,
  nothing to install.
- **SQL Toolbelt Essentials (Redgate)** — **not available via WinGet** (no
  Redgate packages in the winget repository at all). Needs a different
  installation method — intentionally left out until agreed.
- **NVM for Windows** — available as `CoreyButler.NVMforWindows` but left
  commented out in `Install-Apps.ps1`: its installer is per-user, so in a
  Packer build it would install into the SYSTEM profile where no real user
  can use it, and nvm-windows conflicts with the machine-wide Node.js LTS
  install (it expects to manage Node itself).

## Known winget install issues

WinGet has no first-class support for running as `SYSTEM` (Packer's
`elevated_user` for `Install-Apps.ps1`, chosen so software lands
machine-wide rather than in the throwaway `packer` build user's profile —
see `Install-Apps.ps1`'s header comment). SYSTEM has no MSIX package
identity, which surfaces as two distinct problems:

- **PowerShell 7 (`Microsoft.PowerShell`)** — its only winget-manifest
  installer is type MSIX (confirmed via
  `winget show --id Microsoft.PowerShell --installer-type msi` →
  "No applicable installer found" — no MSI alternative exists). MSIX/AppX
  deployment cannot run under SYSTEM at all; this is an OS-level
  restriction, not a winget bug or a flag to work around. Fixed by giving
  it its own provisioner (`scripts/Install-PowerShell7.ps1`) that runs as
  the real `packer` admin user via Packer's own `elevated_user` /
  `elevated_password = "${build.WinRMPassword}"` — the same mechanism every
  other provisioner in `win11-ent.pkr.hcl` already uses, not a hand-rolled
  credential/scheduled-task trick.
- **Paint.NET (`dotPDN.PaintDotNet`)** — **currently disabled** in
  `Install-Apps.ps1`. Its winget installer is a zip archive, and extraction
  fails under SYSTEM with `Failed to extract the contents of the archive`
  (exit `0x8A15005C`). Reproduced across multiple pipeline runs, including 3
  immediate retries in a row (`Install-App` retries transient winget
  failures automatically). On a live diagnostic VM, manually re-running the
  identical `winget install` command a few minutes after the failure
  succeeded immediately — so this looks session/timing-dependent rather
  than a hard, permanent block like PowerShell 7's, but the actual trigger
  is still unidentified. Options for a real fix, not yet tried: give it its
  own `packer`-user provisioner like PowerShell 7; or a longer/backoff retry
  delay in `Install-App`.

If you hit a new winget-under-SYSTEM failure, don't debug it live in place —
comment out the offending `Install-App` call (with a note here and in the
script), confirm the rest of the list still installs cleanly, then
investigate that one package separately.

## Notes & caveats

- WinGet installs whatever is **latest at build time**; pin with
  `--version x.y.z` per package in `Install-Apps.ps1` if you need
  reproducible images.
- App installs run as **SYSTEM** (Packer `elevated_user = "SYSTEM"`) because
  WinGet's MSIX-based CLI cannot run in a plain WinRM session;
  `Install-WinGet.ps1` provisions it machine-wide first.
- Visual Studio installs the workloads listed in `Install-Apps.ps1`
  (.NET desktop, ASP.NET/web, Azure, Data + recommended components) — adjust
  the `--add` list to your needs.
- The `msstore` source is removed during the build; every package comes from
  the community `winget` source.
- Windows Updates are *not* applied during the build. If you want that, add
  the `packer-plugin-windows-update` provisioner before the restart step.
- Rebuild the image on a schedule (e.g. monthly) rather than patching it —
  that is the point of Packer.
