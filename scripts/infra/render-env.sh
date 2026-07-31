#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

root="$(infra_root)"
template="${root}/.env.example"
output="${root}/.env"

if [[ -e "${output}" ]]; then
  printf '%s already exists; refusing to overwrite it. Move it aside first.\n' "${output}" >&2
  exit 1
fi

if ! command -v op >/dev/null 2>&1; then
  printf '%s\n' '1Password CLI is required. Install it and run `op signin` first.' >&2
  exit 1
fi

ensure_ovh_ssh_password

op inject --in-file "${template}" --out-file "${output}" --file-mode 0600
printf 'Rendered %s with mode 0600.\n' "${output}"
