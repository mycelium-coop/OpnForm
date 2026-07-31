variable "deployment_name" {
  description = "Stable production deployment name."
  type        = string
  nullable    = false
}

variable "vps_mode" {
  description = "Whether OpenTofu creates a VPS or only reads an existing one."
  type        = string
  nullable    = false

  validation {
    condition     = contains(["create", "existing"], var.vps_mode)
    error_message = "vps_mode must be create or existing."
  }
}

variable "vps_service_name" {
  description = "Existing OVH VPS service name; required in existing mode."
  type        = string
  default     = ""
}

variable "vps_display_name" {
  description = "Human-readable name for a newly created OVH VPS."
  type        = string
  nullable    = false
}

variable "vps_subsidiary" {
  description = "OVH subsidiary used to order a new VPS."
  type        = string
  default     = ""
}

variable "vps_plan_code" {
  description = "OVH VPS plan code used only in create mode."
  type        = string
  default     = ""
}

variable "vps_plan_duration" {
  description = "OVH product-plan duration used in create mode."
  type        = string
  default     = "P1M"
}

variable "vps_pricing_mode" {
  description = "OVH pricing mode used in create mode."
  type        = string
  default     = "default"
}

variable "vps_datacenter" {
  description = "OVH datacenter selected in create mode."
  type        = string
  default     = ""
}

variable "vps_os" {
  description = "OS catalog value selected in create mode."
  type        = string
  default     = "Ubuntu 26.04"
}

variable "vps_image_id" {
  description = "OVH image ID needed only to create a VPS with the SSH key preinstalled."
  type        = string
  default     = ""
}

variable "vps_public_ssh_key" {
  description = "Public key installed during new-VPS provisioning."
  type        = string
  default     = ""
}

variable "cloudflare_zone_id" {
  description = "Existing Cloudflare zone ID for the OpnForm hostname."
  type        = string
  nullable    = false
}

variable "cloudflare_account_id" {
  description = "Cloudflare account ID that owns the R2 buckets."
  type        = string
  nullable    = false
}

variable "r2_state_bucket" {
  description = "R2 state bucket name, retained here for inventory provenance."
  type        = string
  nullable    = false
}

variable "r2_backup_bucket" {
  description = "R2 backup bucket name, retained here for inventory provenance."
  type        = string
  nullable    = false
}

variable "opnform_hostname" {
  description = "Fully-qualified hostname for this OpnForm instance."
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^[a-z0-9.-]+$", var.opnform_hostname))
    error_message = "opnform_hostname must be a lowercase DNS hostname."
  }
}

variable "oidc_slug" {
  description = "OIDC connection slug used to calculate the identity-provider callback URI."
  type        = string
  default     = "oidc"
}

variable "cloudflare_proxied" {
  description = "Whether Cloudflare proxies the OpnForm DNS records."
  type        = bool
  default     = true
}

variable "cloudflare_manage_ipv6_record" {
  description = "Whether this stack manages an AAAA record for the VPS IPv6 address."
  type        = bool
  default     = true
}

variable "cloudflare_manage_ssl_setting" {
  description = "Whether this stack may modify the zone-wide Cloudflare SSL setting."
  type        = bool
  default     = false
}
