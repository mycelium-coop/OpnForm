#!/usr/bin/env bash

set -euo pipefail

# Fail if any upstream-owned path differs from the latest incorporated
# upstream baseline except the allowlisted edits documented in infra/FORK.md.
#
# The original fork point stays documented in infra/FORK.md. This script reads
# infra/upstream-baseline, which must be advanced to the merged upstream tip
# after each upstream update so CI only flags fork-owned drift.

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

root="$(infra_root)"
baseline_file="${root}/infra/upstream-baseline"
default_fork_point="3a1b5abd3f6327aa90ff7ba123423df756e8f66e"

if [[ -n "${FORK_UPSTREAM_BASELINE:-}" ]]; then
  baseline="${FORK_UPSTREAM_BASELINE}"
elif [[ -f "${baseline_file}" ]]; then
  baseline="$(tr -d '[:space:]' <"${baseline_file}")"
else
  baseline="${default_fork_point}"
fi

[[ -n "${baseline}" ]] || {
  printf '%s\n' "Empty upstream baseline in ${baseline_file}." >&2
  exit 1
}

allowlist=(
  AGENTS.md
  api/config/app.php
  api/app/Providers/SelfHostedOidcSanctumServiceProvider.php
  api/app/Providers/SelfHostedVersionEndpointServiceProvider.php
  api/tests/Feature/SelfHosted/SelfHostedOidcSanctumRoutesTest.php
  api/tests/Feature/SelfHosted/SelfHostedVersionEndpointTest.php
  client/components/workspaces/settings/sso/Oidc.vue
  client/nuxt.config.ts
)

is_fork_owned() {
  local path="$1"
  case "${path}" in
    infra/*|scripts/infra/*|scripts/.gitignore|scripts/migrate_form.py|scripts/cloudflare-ip-ranges.py|scripts/form-migration.env.example|scripts/tests/test_migrate_form.py|Justfile|.env.example|CLAUDE.md|.github/workflows/fork-upstream-guard.yml)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

is_allowlisted() {
  local path="$1"
  local allowed
  for allowed in "${allowlist[@]}"; do
    if [[ "${path}" == "${allowed}" ]]; then
      return 0
    fi
  done
  return 1
}

if ! git -C "${root}" cat-file -e "${baseline}^{commit}" 2>/dev/null; then
  printf '%s\n' "Missing baseline commit ${baseline}. Fetch upstream history first." >&2
  exit 1
fi

changed=()
while IFS= read -r path; do
  [[ -n "${path}" ]] || continue
  changed+=("${path}")
done < <(git -C "${root}" diff --name-only "${baseline}" --)

unexpected=()
for path in "${changed[@]}"; do
  if is_fork_owned "${path}" || is_allowlisted "${path}"; then
    continue
  fi
  unexpected+=("${path}")
done

if ((${#unexpected[@]} > 0)); then
  printf '%s\n' "Unexpected changes to upstream-owned paths (baseline ${baseline}):" >&2
  printf '  %s\n' "${unexpected[@]}" >&2
  printf '%s\n' "Move the change into a fork-owned path, or update infra/FORK.md and this script if it is intentionally allowlisted." >&2
  printf '%s\n' "After merging upstream, set infra/upstream-baseline to the incorporated upstream tip." >&2
  exit 1
fi

printf '%s\n' "Upstream allowlist check passed against ${baseline}."
