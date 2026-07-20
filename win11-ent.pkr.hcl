packer {
  required_version = ">= 1.10.0"
  required_plugins {
    azure = {
      source  = "github.com/hashicorp/azure"
      version = "~> 2"
    }
  }
}

locals {
  replication_regions = length(var.replication_regions) > 0 ? var.replication_regions : [var.location]

  # Image version: explicit var wins (set PKR_VAR_gallery_image_version in the
  # pipeline); otherwise auto-generate a date-based version from the UTC build
  # time, e.g. 20260720.1432.0. Gallery version segments are plain integers,
  # so parseint strips the leading zero from morning times ("0932" -> 932) -
  # numeric per-segment ordering keeps "latest" correct either way.
  build_time    = timestamp()
  auto_version  = "${formatdate("YYYYMMDD", local.build_time)}.${parseint(formatdate("hhmm", local.build_time), 10)}.0"
  image_version = var.gallery_image_version != "" ? var.gallery_image_version : local.auto_version
}

source "azure-arm" "win11_ent" {
  # Auth: reuses your active `az login` session.
  # Swap for client_id/client_secret/tenant_id when running from a pipeline.
  use_azure_cli_auth = true
  subscription_id    = var.subscription_id

  location = var.location
  vm_size  = var.vm_size

  # Base image: Azure Marketplace Windows 11 Enterprise
  os_type         = "Windows"
  image_publisher = "MicrosoftWindowsDesktop"
  image_offer     = "windows-11"
  image_sku       = var.source_image_sku
  image_version   = "latest"

  os_disk_size_gb = var.os_disk_size_gb

  # Windows 11 marketplace images are Gen2 and default to Trusted Launch.
  # The build VM and the destination gallery image definition must both be
  # TrustedLaunch, and the output must go to a Compute Gallery (a plain
  # managed image cannot be captured from a Trusted Launch VM).
  security_type       = "TrustedLaunch"
  secure_boot_enabled = true
  vtpm_enabled        = true

  communicator   = "winrm"
  winrm_use_ssl  = true
  winrm_insecure = true
  winrm_timeout  = "40m"
  winrm_username = "packer"

  shared_image_gallery_destination {
    subscription         = var.subscription_id
    resource_group       = var.gallery_resource_group
    gallery_name         = var.gallery_name
    image_name           = var.gallery_image_name
    image_version        = local.image_version
    storage_account_type = "Standard_LRS"

    dynamic "target_region" {
      for_each = local.replication_regions
      content {
        name = target_region.value
      }
    }
  }

  # Optional gating: publish new versions as excluded from 'latest', run smoke
  # tests against the explicit version, then release it to deployments with:
  #   az sig image-version update -g <rg> -r <gallery> -i <definition> \
  #     -e <version> --set publishingProfile.excludeFromLatest=false
  # shared_gallery_image_version_exclude_from_latest = true

  azure_tags = {
    source     = "packer"
    base-image = var.source_image_sku
    version    = local.image_version
  }
}

build {
  sources = ["source.azure-arm.win11_ent"]

  # 1. Bootstrap WinGet so it is usable in the non-interactive SYSTEM context.
  provisioner "powershell" {
    script            = "${path.root}/scripts/Install-WinGet.ps1"
    elevated_user     = "SYSTEM"
    elevated_password = ""
  }

  # 2. Install all applications via WinGet. Runs as SYSTEM so everything
  #    lands machine-wide, not in the throwaway 'packer' user profile.
  provisioner "powershell" {
    script            = "${path.root}/scripts/Install-Apps.ps1"
    elevated_user     = "SYSTEM"
    elevated_password = ""
    timeout           = "3h"
  }

  # 3. Reboot to flush pending operations (Visual Studio, runtimes, OLE DB driver).
  provisioner "windows-restart" {
    restart_timeout = "30m"
  }

  # 4. Remove WinGet entirely (it is a build-time tool only, users never get
  #    it) plus all bootstrap artifacts, and policy-disable App Installer.
  provisioner "powershell" {
    script            = "${path.root}/scripts/Remove-WinGetBootstrap.ps1"
    elevated_user     = "SYSTEM"
    elevated_password = ""
  }

  # 5. Generalize the VM so Azure can create clean instances from the image.
  provisioner "powershell" {
    inline = [
      "if (Get-Service RdAgent -ErrorAction SilentlyContinue) { while ((Get-Service RdAgent).Status -ne 'Running') { Start-Sleep -s 5 } }",
      "if (Get-Service WindowsAzureGuestAgent -ErrorAction SilentlyContinue) { while ((Get-Service WindowsAzureGuestAgent).Status -ne 'Running') { Start-Sleep -s 5 } }",
      "& $env:SystemRoot\\System32\\Sysprep\\Sysprep.exe /oobe /generalize /quiet /quit /mode:vm",
      "while ($true) { $imageState = (Get-ItemProperty HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Setup\\State).ImageState; Write-Output $imageState; if ($imageState -eq 'IMAGE_STATE_GENERALIZE_RESCHEDULE_TO_OOBE') { break }; Start-Sleep -s 10 }"
    ]
  }
}
