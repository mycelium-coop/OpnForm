#!/usr/bin/env bash

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
target="${root}/.env"

if [[ ! -f "${target}" ]]; then
  printf '%s does not exist.\n' "${target}"
  exit 0
fi

if [[ "${CONFIRM_ENV_CLEAN:-}" != "${target}" ]]; then
  printf 'Set CONFIRM_ENV_CLEAN=%q to remove the generated environment file.\n' "${target}" >&2
  exit 1
fi

rm -f "${target}"
printf 'Removed %s.\n' "${target}"
