#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

action="${1:-}"
[[ -n "${action}" ]] || {
  printf 'Usage: %s <apply>\n' "$0" >&2
  exit 1
}

root="$(infra_root)"
ansible_root="${root}/infra/ansible"
inventory_file="${ansible_root}/inventories/production/hosts.yml"

require_command uv
load_env
prefer_onepassword_ssh_agent

require_inventory() {
  [[ -f "${inventory_file}" ]] || "${root}/scripts/infra/ansible.sh" inventory
}

sheets_enabled() {
  case "${GOOGLE_SHEETS_ENABLED:-false}" in
    [Tt][Rr][Uu][Ee] | [Yy][Ee][Ss] | 1 | [Oo][Nn]) return 0 ;;
    *) return 1 ;;
  esac
}

case "${action}" in
  apply)
    confirm_production
    require_inventory
    if sheets_enabled; then
      require_value GOOGLE_CLIENT_ID
      require_value GOOGLE_CLIENT_SECRET
      printf 'Applying Google Sheets integration (enabled).\n'
    else
      printf 'Applying Google Sheets integration (disabled; credentials omitted from api.env).\n'
    fi
    (cd "${ansible_root}" && uv run --locked -- ansible-playbook site.yml --tags google_sheets)
    # Public smoke can lag briefly after ingress recreate; retry a few times.
    attempt=1
    max_attempts=6
    until "${root}/scripts/infra/smoke.sh"; do
      if ((attempt >= max_attempts)); then
        printf 'Smoke checks failed after %s attempts.\n' "${max_attempts}" >&2
        exit 1
      fi
      printf 'Smoke check not ready yet (attempt %s/%s); retrying in 5s...\n' "${attempt}" "${max_attempts}"
      sleep 5
      attempt=$((attempt + 1))
    done
    ;;
  *)
    printf 'Unknown action: %s\n' "${action}" >&2
    exit 1
    ;;
esac
