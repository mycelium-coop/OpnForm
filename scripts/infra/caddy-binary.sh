#!/usr/bin/env bash

set -euo pipefail

# Publish and fetch the reviewed custom Caddy binary, or build the next one.
# Checksums live in the Caddy role defaults. Bytes live in the R2 backup bucket
# at caddy/<version>/linux-<arch>/<sha256>, outside the restic opnform/ prefix.
# The checksum in the key keeps an older pin reachable after a later publish.
# caddyserver.com/api/download ignores version and replaces cached builds.
#
# Set the Caddy and plugin versions in the role defaults before building.
# Record the printed checksum after the build, then publish. Publish refuses a
# binary whose embedded versions differ from those pins and does not replace an
# existing object.

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

action="${1:-}"
arch="${2:-}"
root="$(infra_root)"
defaults="${CADDY_ROLE_DEFAULTS:-${root}/infra/ansible/roles/caddy/defaults/main.yml}"
cache_dir="${CADDY_ARTIFACT_CACHE:-${root}/infra/.deploy/caddy}"
# Multi-arch index for docker.io/library/caddy:2.11.4-builder.
builder_image="docker.io/library/caddy@sha256:369218c81ca6d6af249981221b3a5c764d886dd5b058f51d144066de13f2418d"
plugin_module="github.com/caddy-dns/cloudflare"

usage() {
  printf 'Usage: %s <checksum|key|verify|fetch|publish|build> <amd64|arm64>\n' "$0" >&2
  exit 1
}

[[ -n "${action}" && -n "${arch}" ]] || usage
case "${arch}" in
  amd64|arm64) ;;
  *) usage ;;
esac

require_command python3

read_pin() {
  local field="$1"
  python3 - "${defaults}" "${arch}" "${field}" <<'PY'
import pathlib
import re
import sys

text = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
arch = sys.argv[2]
field = sys.argv[3]
version = re.search(r"^opnform_caddy_custom_version:\s*'([^']+)'", text, re.M)
plugin = re.search(r"^opnform_caddy_cloudflare_plugin_version:\s*'([^']+)'", text, re.M)
checksums = dict(re.findall(r"^  (amd64|arm64): ([0-9a-f]{64})$", text, re.M))
if version is None or plugin is None:
    sys.exit("Caddy version pins are missing from the role defaults.")
if field == "version":
    print(version.group(1))
elif field == "plugin":
    print(plugin.group(1))
elif field == "checksum":
    if arch not in checksums:
        sys.exit(f"No published Caddy checksum for {arch}.")
    print(checksums[arch])
else:
    sys.exit(f"Unknown pin {field}.")
PY
}

artifact_key() {
  local version="$1"
  local checksum="$2"
  printf 'caddy/%s/linux-%s/%s' "${version}" "${arch}" "${checksum}"
}

verify_embedded() {
  local binary="$1"
  local version="$2"
  local plugin="$3"
  python3 - "${binary}" "${version}" "${plugin}" "${plugin_module}" <<'PY'
import pathlib
import sys

blob = pathlib.Path(sys.argv[1]).read_bytes()
version = sys.argv[2].encode()
plugin = sys.argv[3].encode()
module = sys.argv[4].encode()
caddy = b"dep\tgithub.com/caddyserver/caddy/v2\t" + version + b"\t"
cloudflare = b"dep\t" + module + b"\t" + plugin + b"\t"
missing = []
if caddy not in blob:
    missing.append("Caddy " + version.decode())
if cloudflare not in blob:
    missing.append(module.decode() + "@" + plugin.decode())
if missing:
    sys.exit("Binary is missing embedded " + " and ".join(missing) + ".")
PY
}

cache_path() {
  printf '%s/caddy-linux-%s' "${cache_dir}" "${arch}"
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{ print $1 }'
  else
    shasum -a 256 "$1" | awk '{ print $1 }'
  fi
}

require_backup_credentials() {
  if [[ -n "${CADDY_S3_MIRROR:-}" ]]; then
    export R2_BACKUP_BUCKET="${R2_BACKUP_BUCKET:-mirror}"
    return 0
  fi
  load_env
  require_value R2_ACCOUNT_ID
  require_value R2_BACKUP_BUCKET
  require_value R2_BACKUP_ACCESS_KEY_ID
  require_value R2_BACKUP_SECRET_ACCESS_KEY
  export R2_S3_ENDPOINT="$(r2_s3_endpoint)"
  export AWS_ACCESS_KEY_ID="${R2_BACKUP_ACCESS_KEY_ID}"
  export AWS_SECRET_ACCESS_KEY="${R2_BACKUP_SECRET_ACCESS_KEY}"
}

s3() {
  python3 "${root}/scripts/infra/caddy_s3.py" "$@"
}

confirm_remote_bytes() {
  local key="$1"
  local expected="$2"
  local downloaded
  downloaded="$(mktemp)"
  s3 get "${R2_BACKUP_BUCKET}" "${key}" "${downloaded}"
  local actual
  actual="$(sha256_file "${downloaded}")"
  rm -f "${downloaded}"
  [[ "${actual}" == "${expected}" ]] || {
    printf 'Existing artifact %s has checksum %s, not pinned %s. Leaving it in place.\n' \
      "${key}" "${actual}" "${expected}" >&2
    return 1
  }
}

case "${action}" in
  checksum)
    read_pin checksum
    ;;
  key)
    artifact_key "$(read_pin version)" "$(read_pin checksum)"
    ;;
  verify)
    verify_embedded "$(cache_path)" "$(read_pin version)" "$(read_pin plugin)"
    ;;
  fetch)
    expected="$(read_pin checksum)"
    destination="$(cache_path)"
    mkdir -p "${cache_dir}"
    if [[ -f "${destination}" ]] && [[ "$(sha256_file "${destination}")" == "${expected}" ]]; then
      printf '%s\n' cached
      exit 0
    fi
    require_backup_credentials
    version="$(read_pin version)"
    s3 get "${R2_BACKUP_BUCKET}" "$(artifact_key "${version}" "${expected}")" "${destination}"
    actual="$(sha256_file "${destination}")"
    if [[ "${actual}" != "${expected}" ]]; then
      rm -f "${destination}"
      printf 'Downloaded Caddy artifact checksum %s did not match %s.\n' "${actual}" "${expected}" >&2
      exit 1
    fi
    chmod 755 "${destination}"
    printf '%s\n' downloaded
    ;;
  publish)
    expected="$(read_pin checksum)"
    version="$(read_pin version)"
    plugin="$(read_pin plugin)"
    source_path="$(cache_path)"
    [[ -f "${source_path}" ]] || {
      printf 'Missing %s. Build or place the reviewed binary there first.\n' "${source_path}" >&2
      exit 1
    }
    actual="$(sha256_file "${source_path}")"
    [[ "${actual}" == "${expected}" ]] || {
      printf 'Refusing to publish %s checksum %s; defaults pin %s.\n' "${arch}" "${actual}" "${expected}" >&2
      exit 1
    }
    verify_embedded "${source_path}" "${version}" "${plugin}"
    require_backup_credentials
    key="$(artifact_key "${version}" "${expected}")"
    state="$(s3 stat "${R2_BACKUP_BUCKET}" "${key}" -)"
    if [[ "${state}" == "present" ]]; then
      confirm_remote_bytes "${key}" "${expected}"
      printf 'preserved %s\n' "${key}"
      exit 0
    fi
    [[ "${state}" == "absent" ]] || {
      printf 'Unexpected artifact state %s for %s.\n' "${state}" "${key}" >&2
      exit 1
    }
    if s3 put "${R2_BACKUP_BUCKET}" "${key}" "${source_path}" >/dev/null; then
      printf 'created %s\n' "${key}"
    else
      status=$?
      if [[ "${status}" -ne 2 ]]; then
        exit "${status}"
      fi
      confirm_remote_bytes "${key}" "${expected}"
      printf 'preserved %s\n' "${key}"
    fi
    ;;
  build)
    require_command docker
    version="$(read_pin version)"
    plugin="$(read_pin plugin)"
    mkdir -p "${cache_dir}"
    destination="$(cache_path)"
    docker run --rm \
      --platform "linux/${arch}" \
      -v "${cache_dir}:/out" \
      --entrypoint xcaddy \
      "${builder_image}" \
      build "${version}" \
      --with "${plugin_module}@${plugin}" \
      --output "/out/caddy-linux-${arch}"
    chmod 755 "${destination}"
    verify_embedded "${destination}" "${version}" "${plugin}"
    runtime="$(docker run --rm \
      --platform "linux/${arch}" \
      -v "${destination}:/caddy:ro" \
      --entrypoint /caddy \
      "${builder_image}" \
      version)"
    runtime_version="${runtime%% *}"
    [[ "${runtime_version}" == "${version}" ]] || {
      printf 'Built Caddy reports %s; defaults pin %s.\n' "${runtime_version}" "${version}" >&2
      exit 1
    }
    printf '%s\n' "${runtime}"
    printf '%s  %s\n' "$(sha256_file "${destination}")" "${destination}"
    printf '%s\n' 'Set opnform_caddy_custom_checksums to this digest, then publish.'
    ;;
  *)
    usage
    ;;
esac
