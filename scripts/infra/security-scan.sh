#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

root="$(infra_root)"
for scanner in trivy checkov; do
  require_command "${scanner}"
done

trivy config "${root}/infra/opentofu"
checkov -d "${root}/infra/opentofu" --framework terraform
