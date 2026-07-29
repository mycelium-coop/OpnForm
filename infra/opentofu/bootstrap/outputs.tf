output "state_bucket" {
  description = "R2 bucket to use for OpenTofu state."
  value       = cloudflare_r2_bucket.state.name
}

output "backup_bucket" {
  description = "R2 bucket to use for encrypted restic backups."
  value       = cloudflare_r2_bucket.backup.name
}
