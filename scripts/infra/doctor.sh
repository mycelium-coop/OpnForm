#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

root="$(infra_root)"
ansible_root="${root}/infra/ansible"

for command_name in op tofu uv docker just git curl jq restic; do
  require_command "${command_name}"
done

if ! uv lock --project "${ansible_root}" --check >/dev/null; then
  printf '%s\n' 'The uv lockfile is missing or stale. Run `just python-lock`.' >&2
  exit 1
fi

if ! uv run --project "${ansible_root}" --locked --no-sync -- ansible-playbook --version >/dev/null 2>&1; then
  printf '%s\n' 'The uv-managed Python environment is not synchronized. Run `just python-sync`.' >&2
  exit 1
fi

for collection_path in ansible/posix community/docker community/general; do
  if [[ ! -d "${ansible_root}/.collections/ansible_collections/${collection_path}" ]]; then
    printf 'The project-local Ansible collection %s is missing. Run `just python-sync`.\n' "${collection_path//\//.}" >&2
    exit 1
  fi
done

tofu_version="$(tofu version -json | jq -r '.terraform_version')"
if [[ "${tofu_version}" != 1.11.* ]]; then
  printf 'OpenTofu 1.11.x is required; found %s.\n' "${tofu_version}" >&2
  exit 1
fi

if ! docker buildx version >/dev/null 2>&1; then
  printf '%s\n' 'Docker Buildx is required for immutable image builds.' >&2
  exit 1
fi

python_version="$(uv run --project "${ansible_root}" --locked --no-sync -- python -c 'import platform; print(platform.python_version())')"
printf 'Controller prerequisites are available (OpenTofu %s, Python %s managed by uv).\n' "${tofu_version}" "${python_version}"
