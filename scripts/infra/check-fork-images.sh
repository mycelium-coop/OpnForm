#!/usr/bin/env bash

set -euo pipefail

# Build both fork production Dockerfiles and verify each resulting image
# starts its real application command with isolated dependencies.
# Intended for local use before merging upstream Dockerfile changes into
# infra/docker/.

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

root="$(infra_root)"
platform="${IMAGE_PLATFORM:-linux/amd64}"
api_dockerfile="${root}/infra/docker/Dockerfile.api"
client_dockerfile="${root}/infra/docker/Dockerfile.client"
api_tag="opnform-fork-check-api:local"
client_tag="opnform-fork-check-client:local"
network_name="opnform-fork-check-net"
db_name="opnform-fork-check-db"
api_name="opnform-fork-check-api"
client_name="opnform-fork-check-client"
ready_timeout_seconds="${FORK_IMAGE_READY_TIMEOUT:-120}"
# Fixed test key; only used inside ephemeral check containers.
app_key='base64:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA='

require_command docker

[[ -f "${api_dockerfile}" && -f "${client_dockerfile}" ]] || {
  printf '%s\n' 'Missing infra/docker Dockerfiles.' >&2
  exit 1
}

cleanup() {
  docker rm -f "${api_name}" "${client_name}" "${db_name}" >/dev/null 2>&1 || true
  docker network rm "${network_name}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

wait_until() {
  local description="$1"
  local deadline=$((SECONDS + ready_timeout_seconds))
  shift
  until "$@"; do
    if ((SECONDS >= deadline)); then
      printf '%s\n' "Timed out waiting for ${description} after ${ready_timeout_seconds}s." >&2
      return 1
    fi
    sleep 2
  done
}

container_running() {
  local name="$1"
  docker inspect -f '{{.State.Running}}' "${name}" 2>/dev/null | grep -qx true
}

container_log_matches() {
  local name="$1"
  local pattern="$2"
  docker logs "${name}" 2>&1 | grep -Eq "${pattern}"
}

build_image() {
  local dockerfile="$1"
  local tag="$2"
  docker buildx build \
    --platform "${platform}" \
    --load \
    --build-arg "APP_VERSION=fork-check" \
    --build-arg "VCS_REF=$(git -C "${root}" rev-parse HEAD)" \
    --build-arg "BUILD_DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --tag "${tag}" \
    --file "${dockerfile}" \
    "${root}"
}

cleanup
docker network create "${network_name}" >/dev/null

printf '%s\n' "Building ${api_dockerfile}..."
build_image "${api_dockerfile}" "${api_tag}"
printf '%s\n' "Building ${client_dockerfile}..."
build_image "${client_dockerfile}" "${client_tag}"

printf '%s\n' 'Starting Postgres for the API entrypoint...'
docker run -d \
  --name "${db_name}" \
  --network "${network_name}" \
  -e POSTGRES_DB=opnform \
  -e POSTGRES_USER=opnform \
  -e POSTGRES_PASSWORD=opnform \
  postgres:16-alpine >/dev/null

wait_until "Postgres readiness" \
  docker exec "${db_name}" pg_isready -U opnform -d opnform

printf '%s\n' 'Starting API with php-fpm...'
docker run -d \
  --name "${api_name}" \
  --network "${network_name}" \
  -e APP_ENV=production \
  -e APP_KEY="${app_key}" \
  -e APP_URL=http://localhost \
  -e DB_CONNECTION=pgsql \
  -e DB_HOST="${db_name}" \
  -e DB_PORT=5432 \
  -e DB_DATABASE=opnform \
  -e DB_USERNAME=opnform \
  -e DB_PASSWORD=opnform \
  -e CACHE_DRIVER=file \
  -e CACHE_STORE=file \
  -e SESSION_DRIVER=file \
  -e QUEUE_CONNECTION=sync \
  -e FILESYSTEM_DISK=local \
  "${api_tag}" >/dev/null

wait_until "API entrypoint to finish DB wait and start php-fpm" \
  container_log_matches "${api_name}" 'Starting server for API role'
wait_until "php-fpm process inside API container" \
  docker exec "${api_name}" sh -c "pgrep -x php-fpm >/dev/null"
container_running "${api_name}" || {
  printf '%s\n' 'API container is not running after readiness.' >&2
  docker logs "${api_name}" >&2 || true
  exit 1
}
printf '%s\n' "API image started php-fpm from ${api_dockerfile}."

printf '%s\n' 'Starting client with Nuxt server...'
docker run -d \
  --name "${client_name}" \
  --network "${network_name}" \
  -e NUXT_PUBLIC_APP_URL=http://localhost \
  -e NUXT_PUBLIC_API_BASE=/ \
  -e NUXT_PUBLIC_API_URL=http://localhost \
  -p 13000:3000 \
  "${client_tag}" >/dev/null

wait_until "Nuxt server to accept HTTP on port 3000" \
  docker exec "${client_name}" node -e "require('http').get('http://127.0.0.1:3000/', () => process.exit(0)).on('error', () => process.exit(1))"
container_running "${client_name}" || {
  printf '%s\n' 'Client container is not running after readiness.' >&2
  docker logs "${client_name}" >&2 || true
  exit 1
}
printf '%s\n' "Client image started Nuxt from ${client_dockerfile}."

printf '%s\n' 'Fork image build and startup check passed.'
