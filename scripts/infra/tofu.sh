#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

usage() {
  printf 'Usage: %s <bootstrap|production> <init|init-local|init-remote|fmt-check|validate|plan|show|apply|snapshot|migrate>\n' "$0" >&2
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
  export TF_VAR_cloudflare_manage_ipv6_record="${CLOUDFLARE_MANAGE_IPV6_RECORD:-true}"
  export TF_VAR_cloudflare_manage_ssl_setting="${CLOUDFLARE_MANAGE_SSL_SETTING}"
fi

backend_file="${directory}/backend.hcl"
bootstrap_backend_declaration="${root}/infra/opentofu/bootstrap/backend.generated.tf"
bootstrap_backend_mode_file="${root}/infra/opentofu/bootstrap/.backend-mode"

prepare_r2_backend() {
  local backend_key endpoint
  require_value R2_STATE_BUCKET
  endpoint="$(r2_s3_endpoint)"
  export_r2_state_backend_env
  if [[ "${stack}" == "bootstrap" ]]; then
    backend_key="opnform/${DEPLOYMENT_NAME}/bootstrap.tfstate"
  else
    backend_key="opnform/${DEPLOYMENT_NAME}/production.tfstate"
  fi
  umask 077
  cat >"${backend_file}" <<EOF
bucket = "${R2_STATE_BUCKET}"
key = "${backend_key}"
region = "auto"
endpoint = "${endpoint}"
skip_credentials_validation = true
skip_metadata_api_check = true
skip_region_validation = true
skip_requesting_account_id = true
encrypt = true
use_lockfile = true
EOF
}

bootstrap_backend_mode() {
  if [[ -f "${bootstrap_backend_mode_file}" ]]; then
    tr -d '\r\n' <"${bootstrap_backend_mode_file}"
  fi
}

set_bootstrap_backend_mode() {
  local mode="$1"
  umask 077
  printf '%s\n' "${mode}" >"${bootstrap_backend_mode_file}"
}

write_bootstrap_remote_backend() {
  umask 077
  cat >"${bootstrap_backend_declaration}" <<'EOF'
terraform {
  backend "s3" {}
}
EOF
}

verify_bootstrap_state() {
  local addresses
  if ! addresses="$(tofu -chdir="${directory}" state list)"; then
    return 1
  fi
  grep -Fxq 'cloudflare_r2_bucket.state' <<<"${addresses}" &&
    grep -Fxq 'cloudflare_r2_bucket.backup' <<<"${addresses}"
}

verify_local_bootstrap_state_file() {
  local state_file="$1"
  require_command jq
  jq -e '
    [
      .resources[]?
      | select(.type == "cloudflare_r2_bucket" and (.instances | length) > 0)
      | .name
    ]
    | index("state") != null and index("backup") != null
  ' "${state_file}" >/dev/null
}

initialize_bootstrap_local() {
  local mode
  mode="$(bootstrap_backend_mode)"
  if [[ "${mode}" == "r2" || -f "${bootstrap_backend_declaration}" ]]; then
    printf '%s\n' 'Bootstrap is already configured for R2. Run `just bootstrap-plan`, or use `just bootstrap-remote-init` in a fresh checkout.' >&2
    exit 1
  fi
  tofu -chdir="${directory}" init
  set_bootstrap_backend_mode local
  printf '%s\n' 'Bootstrap is initialized with local state. Migrate it with `just bootstrap-migrate` after applying the reviewed bootstrap plan.'
}

initialize_bootstrap_remote() {
  local mode local_state
  mode="$(bootstrap_backend_mode)"
  local_state="${directory}/terraform.tfstate"
  if [[ "${mode}" == "local" || -s "${local_state}" ]]; then
    printf '%s\n' 'Local bootstrap state exists or is selected. Use `just bootstrap-migrate` instead of remote initialization.' >&2
    exit 1
  fi
  prepare_r2_backend
  write_bootstrap_remote_backend
  tofu -chdir="${directory}" init -reconfigure -backend-config="${backend_file}"
  if ! verify_bootstrap_state; then
    printf '%s\n' 'The selected R2 backend does not contain both bootstrap bucket resources. Check DEPLOYMENT_NAME and R2 backend settings before planning.' >&2
    exit 1
  fi
  set_bootstrap_backend_mode r2
  printf '%s\n' 'Bootstrap is initialized from verified R2 state.'
}

ensure_bootstrap_initialized() {
  local mode
  mode="$(bootstrap_backend_mode)"
  case "${mode}" in
    local)
      if [[ -f "${bootstrap_backend_declaration}" ]]; then
        printf '%s\n' 'Bootstrap migration is incomplete: the R2 backend declaration exists while local mode is selected. Re-run `just bootstrap-migrate`.' >&2
        exit 1
      fi
      tofu -chdir="${directory}" init
      ;;
    r2)
      prepare_r2_backend
      write_bootstrap_remote_backend
      tofu -chdir="${directory}" init -backend-config="${backend_file}"
      ;;
    *)
      printf '%s\n' 'Bootstrap backend is not selected. Run `just bootstrap-init` for the first bootstrap, or `just bootstrap-remote-init` when state already exists in R2.' >&2
      exit 1
      ;;
  esac
}

initialize_production_backend() {
  prepare_r2_backend
  tofu -chdir="${directory}" init -backend-config="${backend_file}"
}

case "${action}" in
  init)
    [[ "${stack}" == "production" ]] || usage
    initialize_production_backend
    ;;
  init-local)
    [[ "${stack}" == "bootstrap" ]] || usage
    initialize_bootstrap_local
    ;;
  init-remote)
    [[ "${stack}" == "bootstrap" ]] || usage
    initialize_bootstrap_remote
    ;;
  fmt-check)
    tofu fmt -check -recursive "${directory}"
    ;;
  validate)
    # Re-initializing with -backend=false still loads cached S3 backend
    # metadata after migration. Only initialize when providers are absent.
    if [[ ! -d "${directory}/.terraform/providers" ]]; then
      tofu -chdir="${directory}" init -backend=false
    fi
    tofu -chdir="${directory}" validate
    ;;
  plan)
    if [[ "${stack}" == "bootstrap" ]]; then
      ensure_bootstrap_initialized
    else
      initialize_production_backend
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
    export RESTIC_REPOSITORY="s3:$(r2_s3_endpoint)/${R2_BACKUP_BUCKET}/tofu-state"
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
    if [[ "$(bootstrap_backend_mode)" != "local" ]]; then
      printf '%s\n' 'Bootstrap local mode is not selected. Run `just bootstrap-init` before the first bootstrap, or use R2 initialization for an existing deployment.' >&2
      exit 1
    fi
    local_state="${directory}/terraform.tfstate"
    if [[ ! -s "${local_state}" ]] || ! verify_local_bootstrap_state_file "${local_state}"; then
      printf '%s\n' 'Local bootstrap state does not contain both R2 bucket resources. Apply the reviewed bootstrap plan before migrating.' >&2
      exit 1
    fi
    chmod 0600 "${local_state}"
    timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
    local_state_backup="${local_state}.pre-migration-${timestamp}"
    cp -p "${local_state}" "${local_state_backup}"
    chmod 0600 "${local_state_backup}"
    prepare_r2_backend
    write_bootstrap_remote_backend
    tofu -chdir="${directory}" init -migrate-state -force-copy -backend-config="${backend_file}"
    if ! verify_bootstrap_state; then
      printf 'R2 migration completed but remote verification failed. Keep %s and investigate before planning or applying.\n' "${local_state_backup}" >&2
      exit 1
    fi
    set_bootstrap_backend_mode r2
    find "${directory}" -maxdepth 1 -type f \( -name 'terraform.tfstate' -o -name 'terraform.tfstate.backup' \) -delete
    rm -f "${plan_file}"
    printf 'Bootstrap state is verified in R2. Pre-migration state backup retained at %s.\n' "${local_state_backup}"
    ;;
  apply)
    confirm_production
    [[ -f "${plan_file}" ]] || { printf 'No saved reviewed plan: %s\n' "${plan_file}" >&2; exit 1; }
    if [[ "${stack}" == "bootstrap" ]]; then
      ensure_bootstrap_initialized
      if [[ "$(bootstrap_backend_mode)" == "local" ]]; then
        umask 077
      fi
    fi
    tofu -chdir="${directory}" apply -lock-timeout=5m "${plan_file}"
    if [[ "${stack}" == "bootstrap" && "$(bootstrap_backend_mode)" == "local" ]]; then
      chmod 0600 "${directory}/terraform.tfstate"
      if [[ -f "${directory}/terraform.tfstate.backup" ]]; then
        chmod 0600 "${directory}/terraform.tfstate.backup"
      fi
    fi
    ;;
  *)
    usage
    ;;
esac
