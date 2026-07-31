#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

action="${1:-}"
argument="${2:-}"
[[ -n "${action}" ]] || { printf 'Usage: %s <check|build|publish|deploy|release|rollback> [release]\n' "$0" >&2; exit 1; }

load_env
root="$(infra_root)"
release_id="sha-$(git -C "${root}" rev-parse HEAD)"
api_tag="${GHCR_HOST}/${GHCR_OWNER}/${GHCR_API_REPOSITORY}:${release_id}"
client_tag="${GHCR_HOST}/${GHCR_OWNER}/${GHCR_CLIENT_REPOSITORY}:${release_id}"

check_clean_tree() {
  if [[ -n "$(git -C "${root}" status --porcelain --untracked-files=normal)" ]]; then
    printf '%s\n' 'Refusing to build a release from a dirty Git worktree.' >&2
    exit 1
  fi
}

release_check() {
  check_clean_tree
  for command_name in docker git trivy npm php; do
    require_command "${command_name}"
  done
  [[ -x "${root}/api/vendor/bin/pest" ]] || {
    printf '%s\n' 'API test runner is missing. Run: (cd api && composer install)' >&2
    exit 1
  }
  (cd "${root}/client" && npm run lint)
  # Collision/Pest are in Laravel dont-discover, so `php artisan test` is unavailable.
  # Match CI and ignore deploy .env DB vars from `just` dotenv-load / load_env.
  (
    cd "${root}/api"
    unset DB_CONNECTION DB_HOST DB_PORT DB_DATABASE DB_USERNAME DB_PASSWORD DATABASE_URL APP_ENV
    export APP_ENV=testing
    export DB_CONNECTION=sqlite
    export DB_DATABASE=:memory:
    ./vendor/bin/pest
  )
}

build_image() {
  local dockerfile="$1"
  local image_tag="$2"
  local push="$3"
  local action_args=(--platform "${IMAGE_PLATFORM}" --provenance=true --sbom=true --build-arg "APP_VERSION=${release_id}" --build-arg "VCS_REF=$(git -C "${root}" rev-parse HEAD)" --build-arg "BUILD_DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)" --tag "${image_tag}" --file "${dockerfile}")

  if [[ "${push}" == "true" ]]; then
    action_args+=(--push)
  else
    action_args+=(--load)
  fi

  docker buildx build "${action_args[@]}" "${root}"
}

build_local() {
  release_check
  build_image "${root}/docker/Dockerfile.api" "${api_tag}" false
  build_image "${root}/docker/Dockerfile.client" "${client_tag}" false
  trivy image --exit-code 1 --severity HIGH,CRITICAL "${api_tag}"
  trivy image --exit-code 1 --severity HIGH,CRITICAL "${client_tag}"
}

publish_images() {
  release_check
  require_value GHCR_PUSH_USERNAME
  require_value GHCR_PUSH_TOKEN
  require_command jq
  local docker_config
  docker_config="$(mktemp -d)"
  trap 'rm -rf "${docker_config}"' EXIT
  printf '%s' "${GHCR_PUSH_TOKEN}" | DOCKER_CONFIG="${docker_config}" docker login "${GHCR_HOST}" --username "${GHCR_PUSH_USERNAME}" --password-stdin >/dev/null
  DOCKER_CONFIG="${docker_config}" build_image "${root}/docker/Dockerfile.api" "${api_tag}" true
  DOCKER_CONFIG="${docker_config}" build_image "${root}/docker/Dockerfile.client" "${client_tag}" true

  local api_digest client_digest manifest
  api_digest="$(DOCKER_CONFIG="${docker_config}" docker buildx imagetools inspect "${api_tag}" --format '{{.Manifest.Digest}}')"
  client_digest="$(DOCKER_CONFIG="${docker_config}" docker buildx imagetools inspect "${client_tag}" --format '{{.Manifest.Digest}}')"
  [[ "${api_digest}" == sha256:* && "${client_digest}" == sha256:* ]] || { printf '%s\n' 'Could not resolve immutable registry digests.' >&2; exit 1; }
  mkdir -p "$(release_directory)"
  manifest="$(release_manifest "${release_id}")"
  umask 077
  cat >"${manifest}" <<EOF
RELEASE_ID=${release_id}
OPNFORM_API_IMAGE=${GHCR_HOST}/${GHCR_OWNER}/${GHCR_API_REPOSITORY}@${api_digest}
OPNFORM_CLIENT_IMAGE=${GHCR_HOST}/${GHCR_OWNER}/${GHCR_CLIENT_REPOSITORY}@${client_digest}
EOF
  chmod 0600 "${manifest}"
  printf 'Published %s and wrote %s.\n' "${release_id}" "${manifest}"
}

deploy_release() {
  local target_release="$1"
  local manifest
  manifest="$(release_manifest "${target_release}")"
  [[ -f "${manifest}" ]] || { printf 'Missing release manifest: %s\n' "${manifest}" >&2; exit 1; }
  confirm_production
  set -a
  # shellcheck disable=SC1090
  source "${manifest}"
  set +a
  "${root}/scripts/infra/ansible.sh" deploy
  "${root}/scripts/infra/smoke.sh"
}

case "${action}" in
  check)
    release_check
    ;;
  build)
    build_local
    ;;
  publish)
    publish_images
    ;;
  deploy)
    deploy_release "${argument:-${release_id}}"
    ;;
  release)
    publish_images
    deploy_release "${release_id}"
    ;;
  rollback)
    confirm_production
    [[ -n "${argument}" ]] || { printf '%s\n' 'A retained release ID is required.' >&2; exit 1; }
    "${root}/scripts/infra/ansible.sh" rollback "${argument}"
    "${root}/scripts/infra/smoke.sh"
    ;;
  *)
    printf 'Unknown release action: %s\n' "${action}" >&2
    exit 1
    ;;
esac
