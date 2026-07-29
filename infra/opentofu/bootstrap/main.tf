provider "cloudflare" {}

resource "cloudflare_r2_bucket" "state" {
  account_id    = var.cloudflare_account_id
  name          = var.r2_state_bucket
  jurisdiction  = "eu"
  location      = "eeur"
  storage_class = "Standard"

  lifecycle {
    prevent_destroy = true
  }
}

resource "cloudflare_r2_bucket" "backup" {
  account_id    = var.cloudflare_account_id
  name          = var.r2_backup_bucket
  jurisdiction  = "eu"
  location      = "eeur"
  storage_class = "Standard"

  lifecycle {
    prevent_destroy = true
  }
}
