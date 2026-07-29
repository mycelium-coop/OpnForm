terraform {
  required_version = "~> 1.11.0"

  backend "s3" {}

  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.22.0"
    }
    ovh = {
      source  = "ovh/ovh"
      version = "~> 2.18.0"
    }
  }
}
