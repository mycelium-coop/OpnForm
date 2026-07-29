variable "deployment_name" {
  description = "Stable name used for state and backup bucket labels."
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{2,50}$", var.deployment_name))
    error_message = "deployment_name must be 3-51 lowercase letters, numbers, or hyphens."
  }
}

variable "cloudflare_account_id" {
  description = "Cloudflare account that owns the R2 buckets."
  type        = string
  nullable    = false
}

variable "r2_state_bucket" {
  description = "R2 bucket reserved for OpenTofu state and lock files."
  type        = string
  nullable    = false
}

variable "r2_backup_bucket" {
  description = "R2 bucket reserved for encrypted application and state snapshots."
  type        = string
  nullable    = false
}
