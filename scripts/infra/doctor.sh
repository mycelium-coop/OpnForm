#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

root="$(infra_root)"
ansible_root="${root}/infra/ansible"

for command_name in op tofu uv docker just git curl jq restic npm php composer trivy; do
  require_command "${command_name}"
done

php_version="$(php -r 'echo PHP_MAJOR_VERSION . "." . PHP_MINOR_VERSION;')"
# Match the locked api/ dependencies (several packages still reject PHP 8.5+).
if [[ "${php_version}" != "8.3" && "${php_version}" != "8.4" ]]; then
  printf 'PHP 8.3 or 8.4 is required for api/composer.lock; found %s.\n' "${php_version}" >&2
  printf '%s\n' 'On macOS with Homebrew: brew install php@8.3 && brew unlink php && brew link php@8.3 --force --overwrite' >&2
  exit 1
fi

if [[ ! -x "${root}/client/node_modules/.bin/eslint" ]]; then
  printf '%s\n' 'Client Node dependencies are missing (eslint). Run: (cd client && npm install)' >&2
  exit 1
fi

if [[ ! -f "${root}/api/vendor/autoload.php" ]]; then
  printf '%s\n' 'API Composer dependencies are missing. Run: (cd api && composer install)' >&2
  exit 1
fi

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
if [[ "${tofu_version}" != "1.12.5" ]]; then
  printf 'OpenTofu 1.12.5 is required; found %s.\n' "${tofu_version}" >&2
  exit 1
fi

if ! docker buildx version >/dev/null 2>&1; then
  printf '%s\n' 'Docker Buildx is required for immutable image builds.' >&2
  exit 1
fi

python_version="$(uv run --project "${ansible_root}" --locked --no-sync -- python -c 'import platform; print(platform.python_version())')"
printf 'Controller prerequisites are available (OpenTofu %s, PHP %s, Python %s managed by uv).\n' \
  "${tofu_version}" "${php_version}" "${python_version}"
