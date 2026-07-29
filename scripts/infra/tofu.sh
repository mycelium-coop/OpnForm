#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

usage() {
  printf 'Usage: %s <bootstrap|production> <init|fmt-check|validate|plan|show|apply|snapshot|migrate>\n' "$0" >&2
  exit 1
}

stack="${1:-}"
action="${2:-}"
[[ -n "${stack}" && -n "${action}" ]] || usage

load_env
require_command tofu

root="$(infra_root)"

export TF_VAR_deployment_name="${DEPLOYMENT_NAME}"
export TF_VAR_cloudflare_account_id="${CLOUDFLARE_ACCOUNT_ID}"
export TF_VAR_r2_state_bucket="${R2_STATE_BUCKET}"
export TF_VAR_r2_backup_bucket="${R2_BACKUP_BUCKET}"

if [[ "${stack}" == "bootstrap" ]]; then
  directory="${root}/infra/opentofu/bootstrap"
  plan_file="${directory}/bootstrap.tfplan"
else
  directory="${root}/infra/opentofu/environments/production"
  plan_file="${directory}/production.tfplan"
  export TF_VAR_vps_mode="${VPS_MODE}"
  export TF_VAR_vps_service_name="${VPS_SERVICE_NAME}"
  export TF_VAR_vps_display_name="${VPS_DISPLAY_NAME}"
  export TF_VAR_vps_subsidiary="${VPS_SUBSIDIARY}"
  export TF_VAR_vps_plan_code="${VPS_PLAN_CODE}"
  export TF_VAR_vps_plan_duration="${VPS_PLAN_DURATION}"
  export TF_VAR_vps_pricing_mode="${VPS_PRICING_MODE}"
  export TF_VAR_vps_datacenter="${VPS_DATACENTER}"
  export TF_VAR_vps_os="${VPS_OS}"
  export TF_VAR_vps_image_id="${VPS_IMAGE_ID}"
  export TF_VAR_vps_public_ssh_key="$(<"${SSH_PUBLIC_KEY_PATH}")"
  export TF_VAR_cloudflare_zone_id="${CLOUDFLARE_ZONE_ID}"
  export TF_VAR_opnform_hostname="${OPNFORM_HOSTNAME}"
  export TF_VAR_oidc_slug="${OIDC_SLUG}"
  export TF_VAR_cloudflare_proxied="${CLOUDFLARE_PROXIED}"
  export TF_VAR_cloudflare_manage_ssl_setting="${CLOUDFLARE_MANAGE_SSL_SETTING}"
fi

if [[ "${stack}" == "production" || "${action}" == "migrate" ]]; then
  require_value R2_STATE_ACCESS_KEY_ID
  require_value R2_STATE_SECRET_ACCESS_KEY
  export AWS_ACCESS_KEY_ID="${R2_STATE_ACCESS_KEY_ID}"
  export AWS_SECRET_ACCESS_KEY="${R2_STATE_SECRET_ACCESS_KEY}"
  export AWS_DEFAULT_REGION="auto"
  if [[ "${stack}" == "bootstrap" ]]; then
    backend_key="opnform/${DEPLOYMENT_NAME}/bootstrap.tfstate"
  else
    backend_key="opnform/${DEPLOYMENT_NAME}/production.tfstate"
  fi
  backend_file="${directory}/backend.hcl"
  umask 077
  cat >"${backend_file}" <<EOF
bucket = "${R2_STATE_BUCKET}"
key = "${backend_key}"
region = "auto"
endpoint = "https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"
skip_credentials_validation = true
skip_metadata_api_check = true
skip_region_validation = true
skip_requesting_account_id = true
encrypt = true
use_lockfile = true
EOF
fi

case "${action}" in
  init)
    if [[ "${stack}" == "production" ]]; then
      tofu -chdir="${directory}" init -backend-config="${backend_file}"
    else
      tofu -chdir="${directory}" init -backend=false
    fi
    ;;
  fmt-check)
    tofu fmt -check -recursive "${directory}"
    ;;
  validate)
    tofu -chdir="${directory}" validate
    ;;
  plan)
    [[ -d "${directory}/.terraform" ]] || "$0" "${stack}" init
    if [[ "${stack}" == "production" ]]; then
      "$0" "${stack}" snapshot
    fi
    rm -f "${plan_file}"
    tofu -chdir="${directory}" plan -lock-timeout=5m -out="${plan_file}"
    printf 'Reviewed plan saved to %s\n' "${plan_file}"
    ;;
  show)
    [[ -f "${plan_file}" ]] || { printf 'No saved plan: %s\n' "${plan_file}" >&2; exit 1; }
    tofu -chdir="${directory}" show "${plan_file}"
    ;;
  snapshot)
    [[ "${stack}" == "production" ]] || { printf '%s\n' 'Snapshots apply only to production state.' >&2; exit 1; }
    [[ -d "${directory}/.terraform" ]] || { printf '%s\n' 'Run just init before snapshotting state.' >&2; exit 1; }
    require_command restic
    require_value R2_BACKUP_ACCESS_KEY_ID
    require_value R2_BACKUP_SECRET_ACCESS_KEY
    require_value RESTIC_PASSWORD
    snapshot_dir="${directory}/state-snapshots"
    mkdir -p "${snapshot_dir}"
    timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
    snapshot="${snapshot_dir}/production-${timestamp}.tfstate"
    snapshot_error="${snapshot}.error"
    if ! tofu -chdir="${directory}" state pull >"${snapshot}" 2>"${snapshot_error}"; then
      if grep -q 'No state file was found' "${snapshot_error}"; then
        rm -f "${snapshot}" "${snapshot_error}"
        printf '%s\n' 'No production state exists yet; skipping the pre-plan state snapshot.'
        exit 0
      fi
      cat "${snapshot_error}" >&2
      rm -f "${snapshot_error}"
      exit 1
    fi
    rm -f "${snapshot_error}"
    chmod 0600 "${snapshot}"
    export RESTIC_REPOSITORY="s3:https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com/${R2_BACKUP_BUCKET}/tofu-state"
    export RESTIC_PASSWORD
    export AWS_ACCESS_KEY_ID="${R2_BACKUP_ACCESS_KEY_ID}"
    export AWS_SECRET_ACCESS_KEY="${R2_BACKUP_SECRET_ACCESS_KEY}"
    if ! restic cat config >/dev/null 2>&1; then
      restic init >/dev/null
    fi
    restic backup "${snapshot}" --tag tofu-state --tag "${DEPLOYMENT_NAME}"
    rm -f "${snapshot}"
    ;;
  migrate)
    [[ "${stack}" == "bootstrap" ]] || { printf '%s\n' 'Only the bootstrap stack needs state migration.' >&2; exit 1; }
    confirm_production
    tofu -chdir="${directory}" init -migrate-state -force-copy -backend-config="${backend_file}"
    tofu -chdir="${directory}" state pull >/dev/null
    find "${directory}" -maxdepth 1 -type f \( -name 'terraform.tfstate' -o -name 'terraform.tfstate.backup' \) -delete
    printf '%s\n' 'Bootstrap state is now stored in R2; local bootstrap state files were removed.'
    ;;
  apply)
    confirm_production
    [[ -f "${plan_file}" ]] || { printf 'No saved reviewed plan: %s\n' "${plan_file}" >&2; exit 1; }
    tofu -chdir="${directory}" apply -lock-timeout=5m "${plan_file}"
    ;;
  *)
    usage
    ;;
esac
