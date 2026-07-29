#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

load_env
require_value OPNFORM_HOSTNAME

curl --fail --silent --show-error --location --max-time 30 "https://${OPNFORM_HOSTNAME}/api/healthcheck" | jq --exit-status . >/dev/null
curl --fail --silent --show-error --location --max-time 30 -o /dev/null "https://${OPNFORM_HOSTNAME}/login"
printf 'Smoke checks passed for https://%s.\n' "${OPNFORM_HOSTNAME}"
