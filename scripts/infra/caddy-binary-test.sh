#!/usr/bin/env bash

set -euo pipefail

root="$(cd -- "$(dirname "$0")/../.." && pwd)"
script="${root}/scripts/infra/caddy-binary.sh"
s3="${root}/scripts/infra/caddy_s3.py"

mkdir -p "${root}/infra/.tmp"
bash -n "${script}"
python3 -m py_compile "${s3}"

unset CADDY_ROLE_DEFAULTS CADDY_ARTIFACT_CACHE CADDY_S3_MIRROR
amd64="$(bash "${script}" checksum amd64)"
[[ "${amd64}" == "02d058c1bcd1d85700b953666dad2a28a99bc03224549ab952ef062a419ab8e4" ]]
key="$(bash "${script}" key amd64)"
[[ "${key}" == "caddy/v2.11.4/linux-amd64/${amd64}" ]]

if bash "${script}" checksum arm64 >/dev/null 2>"${root}/infra/.tmp/caddy-arm64.err"; then
  printf '%s\n' "arm64 checksum should be unpublished" >&2
  exit 1
fi
grep -q 'No published Caddy checksum for arm64' "${root}/infra/.tmp/caddy-arm64.err"
rm -f "${root}/infra/.tmp/caddy-arm64.err"

if [[ -f "${root}/infra/.deploy/caddy/caddy-linux-amd64" ]]; then
  bash "${script}" verify amd64
fi

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
fixture="${work}/fixture"
python3 - "${fixture}" <<'PY'
import pathlib
import sys

pathlib.Path(sys.argv[1]).write_bytes(
    b"dep\tgithub.com/caddy-dns/cloudflare\tv0.2.4\t"
    b"dep\tgithub.com/caddyserver/caddy/v2\tv2.11.4\t"
)
PY
fixture_sum="$(shasum -a 256 "${fixture}" | awk '{ print $1 }')"
other="${work}/other"
python3 - "${other}" <<'PY'
import pathlib
import sys

pathlib.Path(sys.argv[1]).write_bytes(
    b"dep\tgithub.com/caddy-dns/cloudflare\tv0.2.5\t"
    b"dep\tgithub.com/caddyserver/caddy/v2\tv2.12.0\t"
)
PY
other_sum="$(shasum -a 256 "${other}" | awk '{ print $1 }')"

defaults="${work}/defaults.yml"
cache="${work}/cache"
mirror="${work}/mirror"
write_defaults() {
  local version="$1"
  local plugin="$2"
  local checksum="$3"
  cat >"${defaults}" <<EOF
opnform_caddy_custom_version: '${version}'
opnform_caddy_cloudflare_plugin_version: '${plugin}'
opnform_caddy_custom_checksums:
  amd64: ${checksum}
EOF
}

export CADDY_ROLE_DEFAULTS="${defaults}"
export CADDY_ARTIFACT_CACHE="${cache}"
export CADDY_S3_MIRROR="${mirror}"
export R2_BACKUP_BUCKET="mirror"
mkdir -p "${cache}"
write_defaults v2.11.4 v0.2.4 "${fixture_sum}"
cp "${fixture}" "${cache}/caddy-linux-amd64"
isolated_key="$(bash "${script}" key amd64)"
[[ "${isolated_key}" == "caddy/v2.11.4/linux-amd64/${fixture_sum}" ]]

created="$(bash "${script}" publish amd64)"
[[ "${created}" == "created ${isolated_key}" ]]
object="${mirror}/mirror/${isolated_key}"
cmp "${fixture}" "${object}"

preserved="$(bash "${script}" publish amd64)"
[[ "${preserved}" == "preserved ${isolated_key}" ]]
cmp "${fixture}" "${object}"

rm -f "${cache}/caddy-linux-amd64"
fetched="$(bash "${script}" fetch amd64)"
[[ "${fetched}" == "downloaded" ]]
cmp "${fixture}" "${cache}/caddy-linux-amd64"
cached="$(bash "${script}" fetch amd64)"
[[ "${cached}" == "cached" ]]

printf 'changed\n' >"${object}"
if bash "${script}" publish amd64 >/dev/null 2>"${work}/overwrite.err"; then
  printf '%s\n' "publish replaced an existing artifact" >&2
  exit 1
fi
grep -q 'Leaving it in place' "${work}/overwrite.err"
[[ "$(cat "${object}")" == "changed" ]]

cp "${fixture}" "${object}"
write_defaults v2.12.0 v0.2.4 "${fixture_sum}"
if bash "${script}" publish amd64 >/dev/null 2>"${work}/version.err"; then
  printf '%s\n' "publish accepted a binary that does not embed the pinned Caddy version" >&2
  exit 1
fi
grep -q 'missing embedded Caddy v2.12.0' "${work}/version.err"
[[ -f "${mirror}/mirror/caddy/v2.11.4/linux-amd64/${fixture_sum}" ]]

write_defaults v2.12.0 v0.2.5 "${other_sum}"
cp "${other}" "${cache}/caddy-linux-amd64"
other_created="$(bash "${script}" publish amd64)"
[[ "${other_created}" == "created caddy/v2.12.0/linux-amd64/${other_sum}" ]]
[[ -f "${mirror}/mirror/caddy/v2.11.4/linux-amd64/${fixture_sum}" ]]
[[ -f "${mirror}/mirror/caddy/v2.12.0/linux-amd64/${other_sum}" ]]

printf '%s\n' "Caddy binary pin checks passed."
