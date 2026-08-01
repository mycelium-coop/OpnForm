#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

action="${1:-}"
[[ -n "${action}" ]] || {
  printf 'Usage: %s <action>\n' "$0" >&2
  exit 1
}

root="$(infra_root)"
ansible_root="${root}/infra/ansible"
inventory_file="${ansible_root}/inventories/production/hosts.yml"
DRY_RUN="${DRY_RUN:-0}"

load_env
prefer_onepassword_ssh_agent
require_inventory() {
  [[ -f "${inventory_file}" ]] || "${root}/scripts/infra/ansible.sh" inventory
}

inventory_host() {
  awk '/ansible_host:/ {print $2; exit}' "${inventory_file}"
}

ssh_base() {
  require_value SSH_PRIVATE_KEY_PATH
  require_value SSH_PORT
  require_value ANSIBLE_SSH_USER
  local host
  host="$(inventory_host)"
  [[ -n "${host}" ]] || {
    printf '%s\n' 'Missing ansible_host in inventory.' >&2
    exit 1
  }
  SSH_HOST="${host}"
  SSH_OPTS=(
    -i "${SSH_PRIVATE_KEY_PATH}"
    -p "${SSH_PORT}"
    -o BatchMode=yes
    -o IdentitiesOnly=yes
    -o PreferredAuthentications=publickey
    -o StrictHostKeyChecking=yes
    -o GlobalKnownHostsFile=/dev/null
  )
}

remote() {
  ssh_base
  if [[ "${DRY_RUN}" == "1" ]]; then
    printf 'DRY_RUN ssh %s@%s -- %s\n' "${ANSIBLE_SSH_USER}" "${SSH_HOST}" "$*"
    return 0
  fi
  ssh "${SSH_OPTS[@]}" "${ANSIBLE_SSH_USER}@${SSH_HOST}" "$@"
}

remote_sudo() {
  local script="$1"
  ssh_base
  if [[ "${DRY_RUN}" == "1" ]]; then
    printf 'DRY_RUN remote sudo bash <<EOF\n%s\nEOF\n' "${script}"
    return 0
  fi
  ssh "${SSH_OPTS[@]}" "${ANSIBLE_SSH_USER}@${SSH_HOST}" "sudo bash -s" <<<"${script}"
}

ansible_ad_hoc() {
  require_inventory
  (cd "${ansible_root}" && uv run --locked -- ansible opnform -b "$@")
}

origin_block_check_connect() {
  local addr="$1" port="$2" hostname="$3"
  local scheme="http"
  [[ "${port}" == "443" ]] && scheme="https"
  # Any completed HTTP response means the origin is still reachable.
  if curl --silent --show-error --max-time 10 \
    --resolve "${hostname}:${port}:${addr}" \
    "${scheme}://${hostname}/" \
    -o /dev/null; then
    printf 'Direct origin access SUCCEEDED to %s port %s; expected failure.\n' "${addr}" "${port}" >&2
    return 1
  fi
  printf 'Blocked as expected: %s port %s\n' "${addr}" "${port}"
  return 0
}

case "${action}" in
  install)
    confirm_production
    require_inventory
    if [[ "${DRY_RUN}" == "1" ]]; then
      printf 'DRY_RUN: ansible-playbook site.yml --tags cloudflare_origin_lock\n'
      exit 0
    fi
    (cd "${ansible_root}" && uv run --locked -- ansible-playbook site.yml --tags cloudflare_origin_lock)
    ;;
  enable)
    confirm_production
    require_inventory
    remote_sudo "$(cat <<'EOF'
set -euo pipefail
systemctl enable --now opnform-cloudflare-origin-firewall.service
/usr/local/sbin/opnform-cloudflare-origin-firewall verify
EOF
)"
    ;;
  disable)
    confirm_production
    require_inventory
    remote_sudo "$(cat <<'EOF'
set -euo pipefail
systemctl disable --now opnform-cloudflare-origin-firewall.service
/usr/local/sbin/opnform-cloudflare-origin-firewall disable
EOF
)"
    ;;
  status)
    require_inventory
    remote_sudo "$(cat <<'EOF'
set -euo pipefail
/usr/local/sbin/opnform-cloudflare-origin-firewall status
printf '\n--- sync ---\n'
/usr/local/sbin/opnform-cloudflare-ip-sync status || true
EOF
)"
    ;;
  sync-install)
    confirm_production
    require_inventory
    if [[ "${DRY_RUN}" == "1" ]]; then
      printf 'DRY_RUN: ansible-playbook site.yml --tags cloudflare_origin_lock\n'
      exit 0
    fi
    (cd "${ansible_root}" && uv run --locked -- ansible-playbook site.yml --tags cloudflare_origin_lock)
    remote_sudo "$(cat <<'EOF'
set -euo pipefail
systemctl disable --now opnform-cloudflare-ip-sync.timer || true
EOF
)"
    ;;
  sync-run)
    confirm_production
    require_inventory
    remote_sudo "$(cat <<'EOF'
set -euo pipefail
/usr/local/sbin/opnform-cloudflare-ip-sync sync
EOF
)"
    ;;
  sync-enable)
    confirm_production
    require_inventory
    remote_sudo "$(cat <<'EOF'
set -euo pipefail
systemctl enable --now opnform-cloudflare-ip-sync.timer
systemctl status --no-pager opnform-cloudflare-ip-sync.timer
EOF
)"
    ;;
  sync-disable)
    confirm_production
    require_inventory
    remote_sudo "$(cat <<'EOF'
set -euo pipefail
systemctl disable --now opnform-cloudflare-ip-sync.timer
EOF
)"
    ;;
  approve-removals)
    confirm_production
    require_inventory
    require_value CONFIRM_CLOUDFLARE_IP_ETAG
    case "${CONFIRM_CLOUDFLARE_IP_ETAG}" in
      ''|*[!A-Za-z0-9._:-]*)
        printf '%s\n' 'CONFIRM_CLOUDFLARE_IP_ETAG has invalid characters.' >&2
        exit 1
        ;;
    esac
    etag_q="$(printf '%q' "${CONFIRM_CLOUDFLARE_IP_ETAG}")"
    remote_sudo "set -euo pipefail; CONFIRM_CLOUDFLARE_IP_ETAG=${etag_q} /usr/local/sbin/opnform-cloudflare-ip-sync approve-removals"
    ;;
  rollback-ranges)
    confirm_production
    require_inventory
    remote_sudo "$(cat <<'EOF'
set -euo pipefail
/usr/local/sbin/opnform-cloudflare-ip-sync rollback
EOF
)"
    ;;
  block-check)
    require_inventory
    require_value OPNFORM_HOSTNAME
    ssh_base
    host_ipv4="${SSH_HOST}"
    mapfile -t host_ipv6 < <(remote "ip -6 -o addr show scope global up | awk '{print \$4}' | cut -d/ -f1" || true)
    if [[ "${#host_ipv6[@]}" -gt 0 && -n "${host_ipv6[0]:-}" ]]; then
      if ! ping6 -c 1 -W 2 "${host_ipv6[0]}" >/dev/null 2>&1 && ! curl -6 --max-time 5 -sS "https://[::1]/" >/dev/null 2>&1; then
        # Probe workstation IPv6 egress with a well-known address.
        if ! curl -6 --max-time 5 -sS -o /dev/null https://ipv6.google.com 2>/dev/null; then
          printf '%s\n' 'Host has global IPv6 but this workstation cannot use IPv6; aborting to avoid a false pass.' >&2
          exit 1
        fi
      fi
    fi

    failed=0
    for port in 80 443; do
      origin_block_check_connect "${host_ipv4}" "${port}" "${OPNFORM_HOSTNAME}" || failed=1
      for addr in "${host_ipv6[@]:-}"; do
        [[ -n "${addr}" ]] || continue
        origin_block_check_connect "${addr}" "${port}" "${OPNFORM_HOSTNAME}" || failed=1
      done
    done

    if ! ssh "${SSH_OPTS[@]}" -o ConnectTimeout=10 "${ANSIBLE_SSH_USER}@${SSH_HOST}" 'true'; then
      printf '%s\n' 'SSH reachability check failed; origin lock may have affected SSH.' >&2
      exit 1
    fi
    printf 'SSH reachability check passed on port %s.\n' "${SSH_PORT}"

    [[ "${failed}" -eq 0 ]] || exit 1
    ;;
  ips-refresh)
    require_command python3
    v4_file="${root}/infra/ansible/roles/cloudflare_origin_lock/files/cloudflare-ips-v4.txt"
    v6_file="${root}/infra/ansible/roles/cloudflare_origin_lock/files/cloudflare-ips-v6.txt"
    tmp="$(mktemp -d)"
    trap 'rm -rf "${tmp}"' EXIT
    python3 "${root}/scripts/cloudflare-ip-ranges.py" fetch-files \
      --v4-file "${tmp}/v4.txt" \
      --v6-file "${tmp}/v6.txt"
    if [[ "${DRY_RUN}" == "1" ]]; then
      diff -u "${v4_file}" "${tmp}/v4.txt" || true
      diff -u "${v6_file}" "${tmp}/v6.txt" || true
      exit 0
    fi
    cp "${tmp}/v4.txt" "${v4_file}"
    cp "${tmp}/v6.txt" "${v6_file}"
    printf 'Updated tracked Cloudflare fallback snapshots.\n'
    ;;
  *)
    printf 'Unknown origin-lock action: %s\n' "${action}" >&2
    exit 1
    ;;
esac
