provider "cloudflare" {}
provider "ovh" {}

check "vps_mode_inputs" {
  assert {
    condition     = var.vps_mode != "existing" || trimspace(var.vps_service_name) != ""
    error_message = "VPS_SERVICE_NAME is required when VPS_MODE=existing."
  }

  assert {
    condition = var.vps_mode != "create" || (
      trimspace(var.vps_subsidiary) != "" &&
      trimspace(var.vps_plan_code) != "" &&
      trimspace(var.vps_datacenter) != "" &&
      trimspace(var.vps_image_id) != "" &&
      trimspace(var.vps_public_ssh_key) != ""
    )
    error_message = "Create mode requires OVH plan, datacenter, image ID, and a deployment SSH public key."
  }
}

resource "ovh_vps" "managed" {
  count = var.vps_mode == "create" ? 1 : 0

  display_name         = var.vps_display_name
  do_not_send_password = true
  image_id             = var.vps_image_id
  ovh_subsidiary       = var.vps_subsidiary
  public_ssh_key       = var.vps_public_ssh_key

  plan = [{
    duration     = var.vps_plan_duration
    plan_code    = var.vps_plan_code
    pricing_mode = var.vps_pricing_mode
    configuration = [
      {
        label = "vps_datacenter"
        value = var.vps_datacenter
      },
      {
        label = "vps_os"
        value = var.vps_os
      },
    ]
  }]

  lifecycle {
    prevent_destroy = true
    ignore_changes  = [image_id]
  }
}

locals {
  vps_service_name = var.vps_mode == "create" ? ovh_vps.managed[0].name : var.vps_service_name
}

data "ovh_vps" "selected" {
  service_name = local.vps_service_name

  depends_on = [ovh_vps.managed]
}

locals {
  vps_ipv4 = one([
    for address in data.ovh_vps.selected.ips : address
    if length(split(".", address)) == 4
  ])
  vps_ipv6_addresses = [
    for address in data.ovh_vps.selected.ips : address
    if length(split(":", address)) > 1
  ]
  vps_ipv6 = length(local.vps_ipv6_addresses) == 0 ? null : local.vps_ipv6_addresses[0]
}

resource "cloudflare_dns_record" "opnform_ipv4" {
  zone_id = var.cloudflare_zone_id
  name    = var.opnform_hostname
  type    = "A"
  content = local.vps_ipv4
  proxied = var.cloudflare_proxied
  ttl     = var.cloudflare_proxied ? 1 : 300
  comment = "Managed by OpenTofu for ${var.deployment_name}"
}

resource "cloudflare_dns_record" "opnform_ipv6" {
  count = local.vps_ipv6 == null ? 0 : 1

  zone_id = var.cloudflare_zone_id
  name    = var.opnform_hostname
  type    = "AAAA"
  content = local.vps_ipv6
  proxied = var.cloudflare_proxied
  ttl     = var.cloudflare_proxied ? 1 : 300
  comment = "Managed by OpenTofu for ${var.deployment_name}"
}

resource "cloudflare_zone_setting" "ssl" {
  count = var.cloudflare_manage_ssl_setting ? 1 : 0

  zone_id    = var.cloudflare_zone_id
  setting_id = "ssl"
  value      = "strict"
}
