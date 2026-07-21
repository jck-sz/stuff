# Reusable AVD session-host template.
# Copy this file into a separate Terraform root module; do not leave it in the
# same directory as another deployment containing these resource names.

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    time = {
      source  = "hashicorp/time"
      version = ">= 0.12, < 1.0"
    }
  }
}

provider "azurerm" {
  features {}
}

variable "deployment_resource_group_name" {
  description = "Resource group to create for the AVD resources."
  type        = string
}

variable "location" {
  description = "Azure region for the AVD resources."
  type        = string
}

variable "storage_resource_group_name" {
  description = "Resource group containing the existing script storage account."
  type        = string
}

variable "storage_account_name" {
  description = "Existing storage account containing the AVD configuration ZIP."
  type        = string
}

variable "storage_container_name" {
  description = "Private blob container containing the AVD configuration ZIP."
  type        = string
}

variable "script_blob_url" {
  description = "HTTPS URL of the private Configuration_*.zip blob."
  type        = string
}

variable "host_pool_name" {
  description = "AVD host pool name."
  type        = string
}

variable "vm_name" {
  description = "Session-host VM name."
  type        = string
}

variable "computer_name" {
  description = "Windows computer name, up to 15 characters."
  type        = string
}

variable "vm_size" {
  description = "Session-host VM size, selected for the target subscription and region."
  type        = string
}

variable "admin_username" {
  description = "Local administrator username."
  type        = string
}

variable "admin_password" {
  description = "Local administrator password. Keep it in a secret variable or secret store."
  type        = string
  sensitive   = true
}

variable "vnet_address_space" {
  description = "Address space for the session-host VNet."
  type        = list(string)
  default     = ["10.40.0.0/16"]
}

variable "subnet_address_prefixes" {
  description = "Address prefixes for the session-host subnet."
  type        = list(string)
  default     = ["10.40.1.0/24"]
}

variable "maximum_sessions_allowed" {
  description = "Maximum concurrent sessions allowed on the pooled host."
  type        = number
  default     = 10
}

variable "image_publisher" {
  type    = string
  default = "MicrosoftWindowsDesktop"
}

variable "image_offer" {
  type    = string
  default = "Windows-11"
}

variable "image_sku" {
  type    = string
  default = "win11-23h2-avd"
}

variable "image_version" {
  type    = string
  default = "latest"
}

variable "registration_token_rotation_hours" {
  description = "Lifetime of the AVD registration token used during deployment."
  type        = number
  default     = 24
}

locals {
  package_name = basename(var.script_blob_url)

  registration_command = <<-POWERSHELL
    $ErrorActionPreference = 'Stop'
    $packagePath = Join-Path (Get-Location) '${local.package_name}'
    $workingDirectory = Join-Path $env:ProgramData 'AVDRegistration'
    $configurationDirectory = Join-Path $workingDirectory 'Configuration'

    New-Item -ItemType Directory -Path $workingDirectory -Force | Out-Null
    Remove-Item -Path $configurationDirectory -Recurse -Force -ErrorAction SilentlyContinue
    Expand-Archive -LiteralPath $packagePath -DestinationPath $configurationDirectory -Force
    $sessionHostConfigurationLastUpdateTime = (Get-Date).ToString('o')
    & (Join-Path $configurationDirectory 'Script-SetupSessionHost.ps1') `
      -HostPoolName '${replace(var.host_pool_name, "'", "''")}' `
      -RegistrationInfoToken '${replace(azurerm_virtual_desktop_host_pool_registration_info.this.token, "'", "''")}' `
      -AadJoin $true `
      -AadJoinPreview $false `
      -SessionHostConfigurationLastUpdateTime $sessionHostConfigurationLastUpdateTime

    if (-not $?) {
      throw 'Script-SetupSessionHost.ps1 failed.'
    }
  POWERSHELL
}

data "azurerm_storage_account" "scripts" {
  name                = var.storage_account_name
  resource_group_name = var.storage_resource_group_name
}

resource "azurerm_resource_group" "this" {
  name     = var.deployment_resource_group_name
  location = var.location
}

resource "azurerm_virtual_network" "this" {
  name                = "${var.vm_name}-vnet"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  address_space       = var.vnet_address_space
}

resource "azurerm_subnet" "session_host" {
  name                 = "session-hosts"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = var.subnet_address_prefixes
}

resource "azurerm_virtual_desktop_host_pool" "this" {
  name                     = var.host_pool_name
  location                 = azurerm_resource_group.this.location
  resource_group_name      = azurerm_resource_group.this.name
  type                     = "Pooled"
  load_balancer_type       = "BreadthFirst"
  maximum_sessions_allowed = var.maximum_sessions_allowed
  validate_environment     = true
  start_vm_on_connect      = true
  custom_rdp_properties    = "targetisaadjoined:i:1;enablerdsaadauth:i:1;"
}

resource "time_rotating" "registration" {
  rotation_hours = var.registration_token_rotation_hours
}

resource "azurerm_virtual_desktop_host_pool_registration_info" "this" {
  hostpool_id     = azurerm_virtual_desktop_host_pool.this.id
  expiration_date = time_rotating.registration.rotation_rfc3339
}

resource "azurerm_network_interface" "session_host" {
  name                = "${var.vm_name}-nic"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name

  ip_configuration {
    name                          = "primary"
    subnet_id                     = azurerm_subnet.session_host.id
    private_ip_address_allocation = "Dynamic"
  }
}

resource "azurerm_windows_virtual_machine" "session_host" {
  name                  = var.vm_name
  computer_name         = var.computer_name
  location              = azurerm_resource_group.this.location
  resource_group_name   = azurerm_resource_group.this.name
  size                  = var.vm_size
  admin_username        = var.admin_username
  admin_password        = var.admin_password
  network_interface_ids = [azurerm_network_interface.session_host.id]
  provision_vm_agent    = true
  secure_boot_enabled   = true
  vtpm_enabled          = true

  identity {
    type = "SystemAssigned"
  }

  os_disk {
    name                 = "${var.vm_name}-osdisk"
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
  }

  source_image_reference {
    publisher = var.image_publisher
    offer     = var.image_offer
    sku       = var.image_sku
    version   = var.image_version
  }
}

resource "azurerm_role_assignment" "script_reader" {
  scope                            = "${data.azurerm_storage_account.scripts.id}/blobServices/default/containers/${var.storage_container_name}"
  role_definition_name             = "Storage Blob Data Reader"
  principal_id                     = azurerm_windows_virtual_machine.session_host.identity[0].principal_id
  skip_service_principal_aad_check = true
}

resource "time_sleep" "script_reader_propagation" {
  create_duration = "60s"

  depends_on = [azurerm_role_assignment.script_reader]
}

resource "azurerm_virtual_machine_extension" "entra_join" {
  name                       = "AADLoginForWindows"
  virtual_machine_id         = azurerm_windows_virtual_machine.session_host.id
  publisher                  = "Microsoft.Azure.ActiveDirectory"
  type                       = "AADLoginForWindows"
  type_handler_version       = "1.0"
  auto_upgrade_minor_version = true
}

resource "azurerm_virtual_machine_extension" "register_with_avd" {
  name                       = "RegisterWithAVD"
  virtual_machine_id         = azurerm_windows_virtual_machine.session_host.id
  publisher                  = "Microsoft.Compute"
  type                       = "CustomScriptExtension"
  type_handler_version       = "1.10"
  auto_upgrade_minor_version = true

  protected_settings = jsonencode({
    fileUris         = [var.script_blob_url]
    commandToExecute = "powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -EncodedCommand ${textencodebase64(local.registration_command, "UTF-16LE")}"
    managedIdentity  = {}
    timestamp        = parseint(substr(sha256(local.registration_command), 0, 7), 16)
  })

  depends_on = [
    time_sleep.script_reader_propagation,
    azurerm_virtual_machine_extension.entra_join
  ]
}
