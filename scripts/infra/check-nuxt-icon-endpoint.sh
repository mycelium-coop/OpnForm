#!/usr/bin/env bash

set -euo pipefail

# Fail if client/nuxt.config.ts differs from the upstream baseline by anything
# other than the documented icon.localApiEndpoint override.

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

root="$(infra_root)"
baseline_file="${root}/infra/upstream-baseline"
default_fork_point="3a1b5abd3f6327aa90ff7ba123423df756e8f66e"
config_path="client/nuxt.config.ts"

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

if ! git -C "${root}" cat-file -e "${baseline}:${config_path}" 2>/dev/null; then
  printf '%s\n' "Missing ${config_path} at baseline ${baseline}." >&2
  exit 1
fi

diff_output="$(git -C "${root}" diff --unified=0 "${baseline}" -- "${config_path}" || true)"
if [[ -z "${diff_output}" ]]; then
  printf '%s\n' "Expected ${config_path} to set icon.localApiEndpoint to '/_nuxt_icon'." >&2
  exit 1
fi

filtered="$(
  printf '%s\n' "${diff_output}" | awk '
    /^\+\+\+ |^--- |^@@ |^diff |^index / { next }
    /^\+/ {
      line = substr($0, 2)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
      if (line == "" || line ~ /^\/\//) {
        next
      }
      if (line == "localApiEndpoint: '\''/_nuxt_icon'\'',") {
        next
      }
      print
      next
    }
    /^-/ {
      line = substr($0, 2)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
      if (line == "" || line ~ /^\/\//) {
        next
      }
      print
    }
  '
)"

if [[ -n "${filtered}" ]]; then
  printf '%s\n' "Unexpected changes in ${config_path} beyond icon.localApiEndpoint:" >&2
  printf '%s\n' "${filtered}" >&2
  printf '%s\n' "Only localApiEndpoint: '/_nuxt_icon' is allowlisted. Move other edits elsewhere or update the documented exception." >&2
  exit 1
fi

if ! grep -Eq "localApiEndpoint:[[:space:]]*'/_nuxt_icon'" "${root}/${config_path}"; then
  printf '%s\n' "Missing localApiEndpoint: '/_nuxt_icon' in ${config_path}." >&2
  exit 1
fi

printf '%s\n' "Nuxt icon endpoint check passed against ${baseline}."
