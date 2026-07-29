output "vps_service_name" {
  description = "OVH VPS service name used by this deployment."
  value       = local.vps_service_name
}

output "vps_ipv4" {
  description = "Public IPv4 address used for the OpnForm DNS record and Ansible inventory."
  value       = local.vps_ipv4
}

output "vps_ipv6" {
  description = "Public IPv6 address when attached to the selected VPS."
  value       = local.vps_ipv6
}

output "ansible_host" {
  description = "Host address used by the generated Ansible inventory."
  value       = local.vps_ipv4
}

output "opnform_url" {
  description = "Public URL of the deployed instance."
  value       = "https://${var.opnform_hostname}"
}

output "oidc_redirect_uri" {
  description = "OIDC callback URL to register with the identity provider."
  value       = "https://${var.opnform_hostname}/auth/${var.oidc_slug}/callback"
}
