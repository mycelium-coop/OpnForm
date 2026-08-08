#!/usr/bin/env bash

set -euo pipefail

infra_root() {
  cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd
}

load_env() {
  local root
  root="$(infra_root)"

  if [[ ! -f "${root}/.env" ]]; then
    printf '%s\n' 'Missing .env. Run `just env` first.' >&2
    exit 1
  fi

  local line key value first_character last_character
  while IFS= read -r line || [[ -n "${line}" ]]; do
    case "${line}" in
      ''|'#'*) continue ;;
      *=*)
        key="${line%%=*}"
        value="${line#*=}"
        first_character="${value:0:1}"
        last_character="${value: -1}"
        if [[ ${#value} -ge 2 ]] && { [[ "${first_character}" == '"' && "${last_character}" == '"' ]] || [[ "${first_character}" == "'" && "${last_character}" == "'" ]]; }; then
          value="${value:1:${#value}-2}"
        fi
        # Keep caller/manifest exports (e.g. RELEASE_ID from deploy-release).
        # An empty .env entry must not wipe a value already set in the environment.
        if [[ -n "${!key:-}" ]]; then
          continue
        fi
        export "${key}=${value}"
        ;;
      *)
        printf 'Invalid .env line for deployment tooling: %s\n' "${line}" >&2
        exit 1
        ;;
    esac
  done <"${root}/.env"
}

require_value() {
  local variable_name="$1"
  if [[ -z "${!variable_name:-}" ]]; then
    printf 'Missing required environment variable: %s\n' "${variable_name}" >&2
    exit 1
  fi
}

require_command() {
  local command_name="$1"
  if ! command -v "${command_name}" >/dev/null 2>&1; then
    printf 'Required command is not installed: %s\n' "${command_name}" >&2
    exit 1
  fi
}

export_r2_state_backend_env() {
  require_value R2_STATE_ACCESS_KEY_ID
  require_value R2_STATE_SECRET_ACCESS_KEY
  export AWS_ACCESS_KEY_ID="${R2_STATE_ACCESS_KEY_ID}"
  export AWS_SECRET_ACCESS_KEY="${R2_STATE_SECRET_ACCESS_KEY}"
  export AWS_DEFAULT_REGION=auto
}

r2_s3_endpoint() {
  require_value R2_ACCOUNT_ID
  printf 'https://%s.eu.r2.cloudflarestorage.com' "${R2_ACCOUNT_ID}"
}

# Create ovh-ssh-password in tech-admin/opnform-secrets when missing.
# Existing values are left unchanged so break-glass credentials stay stable.
ensure_ovh_ssh_password() {
  local vault="tech-admin"
  local item="opnform-secrets"
  local field="ovh-ssh-password"
  local ref="op://${vault}/${item}/${field}"
  local password template

  require_command op
  require_command openssl
  require_command jq

  if op read "${ref}" --no-newline >/dev/null 2>&1; then
    return 0
  fi

  password="$(openssl rand -base64 24 | tr -d '\n')"
  template="$(mktemp)"
  chmod 600 "${template}"

  if ! op item get "${item}" --vault "${vault}" --format=json \
    | jq --arg label "${field}" --arg value "${password}" '
        .fields += [{
          "type": "CONCEALED",
          "label": $label,
          "value": $value
        }]
      ' >"${template}"; then
    rm -f "${template}"
    printf 'Failed to prepare the %s field for 1Password item %s/%s.\n' \
      "${field}" "${vault}" "${item}" >&2
    exit 1
  fi

  if ! op item edit "${item}" --vault "${vault}" --template="${template}" >/dev/null; then
    rm -f "${template}"
    printf 'Failed to store %s in 1Password item %s/%s.\n' \
      "${field}" "${vault}" "${item}" >&2
    exit 1
  fi

  rm -f "${template}"
  unset password
  printf 'Created %s in 1Password item %s/%s.\n' "${field}" "${vault}" "${item}"
}

# Ensure OVH_SSH_PASSWORD is present in the local .env and exported.
# Reuses a value already loaded from .env so deploy/check work offline when the
# secret is already local. Uses 1Password only for the legacy backfill path.
sync_ovh_ssh_password_env() {
  local root env_file password

  if [[ -n "${OVH_SSH_PASSWORD:-}" ]]; then
    return 0
  fi

  ensure_ovh_ssh_password
  root="$(infra_root)"
  env_file="${root}/.env"
  password="$(op read 'op://tech-admin/opnform-secrets/ovh-ssh-password' --no-newline)"

  if [[ -f "${env_file}" ]] && ! grep -q '^OVH_SSH_PASSWORD=' "${env_file}"; then
    printf 'OVH_SSH_PASSWORD=%s\n' "${password}" >>"${env_file}"
    chmod 600 "${env_file}"
    printf 'Appended OVH_SSH_PASSWORD to %s.\n' "${env_file}"
  fi

  export OVH_SSH_PASSWORD="${password}"
}

confirm_production() {
  require_value DEPLOYMENT_NAME
  if [[ "${CONFIRM_PROD:-}" != "${DEPLOYMENT_NAME}" ]]; then
    printf 'Set CONFIRM_PROD=%q to continue.\n' "${DEPLOYMENT_NAME}" >&2
    exit 1
  fi
}

# Prefer the 1Password SSH agent when present. Deploy keys are often public-key
# path stubs (*.pub) that require agent signing; Cursor/launchd SSH_AUTH_SOCK
# cannot authorize those signatures.
prefer_onepassword_ssh_agent() {
  local candidates=(
    "${HOME}/.1password/agent.sock"
    "${HOME}/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"
  )
  local candidate=""

  for candidate in "${candidates[@]}"; do
    if [[ -S "${candidate}" ]]; then
      export SSH_AUTH_SOCK="${candidate}"
      return 0
    fi
  done
}

release_directory() {
  printf '%s/.deploy/releases' "$(infra_root)"
}

release_manifest() {
  local release_id="$1"
  printf '%s/%s.env' "$(release_directory)" "${release_id}"
}
