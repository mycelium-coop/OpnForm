#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

load_env
require_value OPNFORM_HOSTNAME

health="$(curl --fail --silent --show-error --location --max-time 30 "https://${OPNFORM_HOSTNAME}/api/healthcheck")"
printf '%s' "${health}" | jq --exit-status '.status == "ok"' >/dev/null

curl --fail --silent --show-error --location --max-time 30 -o /dev/null "https://${OPNFORM_HOSTNAME}/login"

version="$(curl --fail --silent --show-error --location --max-time 30 "https://${OPNFORM_HOSTNAME}/v")"
version_lines="$(printf '%s\n' "${version}" | sed '/^$/d' | wc -l | tr -d ' ')"
[[ "${version_lines}" == "2" ]] || {
  printf '%s\n' "Expected /v to return exactly two non-empty lines, got:${version_lines}"$'\n'"${version}" >&2
  exit 1
}

for path in \
  "_nuxt_icon/heroicons.json?icons=chevron-up-down-16-solid" \
  "_nuxt_icon/material-symbols.json?icons=check-box-outline-blank" \
  "api/_nuxt_icon/heroicons.json?icons=chevron-up-down-16-solid"
do
  body="$(curl --fail --silent --show-error --location --max-time 30 "https://${OPNFORM_HOSTNAME}/${path}")"
  printf '%s' "${body}" | jq --exit-status '
    (.prefix | type == "string") and
    (.icons | type == "object") and
    ([.icons[].body] | map(type == "string" and length > 0) | all)
  ' >/dev/null
done

printf 'Smoke checks passed for https://%s.\n' "${OPNFORM_HOSTNAME}"
