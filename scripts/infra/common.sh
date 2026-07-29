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

confirm_production() {
  require_value DEPLOYMENT_NAME
  if [[ "${CONFIRM_PROD:-}" != "${DEPLOYMENT_NAME}" ]]; then
    printf 'Set CONFIRM_PROD=%q to continue.\n' "${DEPLOYMENT_NAME}" >&2
    exit 1
  fi
}

release_directory() {
  printf '%s/.deploy/releases' "$(infra_root)"
}

release_manifest() {
  local release_id="$1"
  printf '%s/%s.env' "$(release_directory)" "${release_id}"
}
