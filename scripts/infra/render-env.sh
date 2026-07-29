#!/usr/bin/env bash

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
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

op inject --in-file "${template}" --out-file "${output}" --file-mode 0600
printf 'Rendered %s with mode 0600.\n' "${output}"
