#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

root="$(infra_root)"
template="${root}/.env.example"
output="${root}/.env"
vault="tech-admin"
item="opnform-secrets"

if [[ -e "${output}" ]]; then
  printf '%s already exists; refusing to overwrite it. Move it aside first.\n' "${output}" >&2
  exit 1
fi

if ! command -v op >/dev/null 2>&1; then
  printf '%s\n' '1Password CLI is required. Install it and run `op signin` first.' >&2
  exit 1
fi

require_command jq

ensure_ovh_ssh_password

if ! existing_fields="$(
  op item get "${item}" --vault "${vault}" --format=json \
    | jq -r '.fields[]? | select(.label != null and .label != "") | .label' \
    | sort -u
)"; then
  printf 'Failed to read 1Password item %s/%s. Sign in with `op signin` and confirm the item exists.\n' \
    "${vault}" "${item}" >&2
  exit 1
fi

field_exists() {
  local field="$1"
  [[ -n "${existing_fields}" ]] && printf '%s\n' "${existing_fields}" | grep -Fxq -- "${field}"
}

tmp_template="$(mktemp)"
missing_vars_file="$(mktemp)"
sed_script="$(mktemp)"
chmod 600 "${tmp_template}" "${missing_vars_file}" "${sed_script}"
trap 'rm -f "${tmp_template}" "${missing_vars_file}" "${sed_script}"' EXIT

while IFS= read -r line || [[ -n "${line}" ]]; do
  [[ "${line}" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || continue
  key="${BASH_REMATCH[1]}"
  value="${BASH_REMATCH[2]}"

  while IFS= read -r ref; do
    [[ -z "${ref}" ]] && continue
    field="${ref#\{\{ op://}"
    field="${field%" }}"}"
    field="${field##*/}"
    if field_exists "${field}"; then
      continue
    fi
    if ! grep -Fxq -- "${key}" "${missing_vars_file}"; then
      printf '%s\n' "${key}" >>"${missing_vars_file}"
    fi
    if ! grep -Fq -- "op://${vault}/${item}/${field} }}" "${sed_script}"; then
      # Field names are [A-Za-z0-9_-]+; '|' is safe as the sed delimiter.
      printf 's|{{ op://%s/%s/%s }}||g\n' "${vault}" "${item}" "${field}" >>"${sed_script}"
    fi
  done < <(grep -oE '\{\{ op://[A-Za-z0-9_-]+/[A-Za-z0-9_-]+/[A-Za-z0-9_-]+ \}\}' <<<"${value}" || true)
done <"${template}"

if [[ -s "${sed_script}" ]]; then
  sed -f "${sed_script}" "${template}" >"${tmp_template}"
else
  cp "${template}" "${tmp_template}"
fi

op inject --in-file "${tmp_template}" --out-file "${output}" --file-mode 0600

if [[ -s "${missing_vars_file}" ]]; then
  printf 'Warning: the following environment variables were not found in 1Password (%s/%s) and were left empty:\n' \
    "${vault}" "${item}" >&2
  while IFS= read -r key; do
    printf '  - %s\n' "${key}" >&2
  done <"${missing_vars_file}"
  printf 'Add the missing fields (or edit .env) before the steps that need them.\n' >&2
fi

printf 'Rendered %s with mode 0600.\n' "${output}"
