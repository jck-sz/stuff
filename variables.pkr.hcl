variable "subscription_id" {
  type        = string
  description = "Azure subscription ID used for the build and for the Compute Gallery destination."
}

variable "location" {
  type        = string
  default     = "westeurope"
  description = "Region for the temporary build VM. Also the default replication region for the image."
}

variable "vm_size" {
  type        = string
  default     = "Standard_D8s_v5"
  description = "Size of the temporary build VM. Must be Gen2 / Trusted Launch capable. Visual Studio installation is CPU/IO heavy, so a larger size shortens the build."
}

variable "source_image_sku" {
  type        = string
  default     = "win11-24h2-ent"
  description = <<-EOT
    Marketplace SKU of the Windows 11 Enterprise base image.
    List available SKUs with:
      az vm image list-skus -l westeurope -p MicrosoftWindowsDesktop -f windows-11 -o table
    (e.g. win11-23h2-ent, win11-24h2-ent, win11-25h2-ent when available in your region)
  EOT
}

variable "os_disk_size_gb" {
  type        = number
  default     = 256
  description = "OS disk size. Visual Studio + SSMS + Power BI + IDEs need well over the default 127 GB."
}

variable "gallery_resource_group" {
  type        = string
  description = "Resource group that contains the Azure Compute Gallery."
}

variable "gallery_name" {
  type        = string
  description = "Name of the Azure Compute Gallery (must already exist)."
}

variable "gallery_image_name" {
  type        = string
  default     = "win11-ent-dev"
  description = "Image definition inside the gallery (must already exist, Generalized / V2 / TrustedLaunch - see README)."
}

variable "gallery_image_version" {
  type        = string
  default     = ""
  description = <<-EOT
    Version number for the new gallery image version (Major.Minor.Patch, each
    segment a plain integer). Leave empty to auto-generate a date-based
    version: YYYYMMDD.<hhmm as integer>.0 (UTC build time).
    Pipelines should override it for guaranteed uniqueness, either via the
    environment variable PKR_VAR_gallery_image_version or -var on the CLI -
    see README "Versioning & consuming 'latest'".
  EOT
}

variable "replication_regions" {
  type        = list(string)
  default     = []
  description = "Regions to replicate the image version to. Defaults to [location] when empty."
}
