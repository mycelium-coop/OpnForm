#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

action="${1:-}"
argument="${2:-}"
[[ -n "${action}" ]] || { printf 'Usage: %s <action> [argument]\n' "$0" >&2; exit 1; }

root="$(infra_root)"
ansible_root="${root}/infra/ansible"
production_tofu="${root}/infra/opentofu/environments/production"
inventory_file="${ansible_root}/inventories/production/hosts.yml"
generated_vars="${ansible_root}/inventories/production/group_vars/all/generated.yml"

require_command uv
if [[ "${action}" != "lint" ]]; then
  load_env
fi

generate_inventory() {
  "${root}/scripts/infra/tofu.sh" production init
  local host
  host="$(tofu -chdir="${production_tofu}" output -raw ansible_host)"
  umask 077
  mkdir -p "$(dirname "${inventory_file}")" "$(dirname "${generated_vars}")"
  cat >"${inventory_file}" <<EOF
all:
  children:
    opnform:
      hosts:
        ${DEPLOYMENT_NAME}:
          ansible_host: ${host}
          ansible_user: ${ANSIBLE_SSH_USER}
          ansible_port: ${SSH_PORT}
          ansible_ssh_private_key_file: ${SSH_PRIVATE_KEY_PATH}
          ansible_ssh_common_args: '-o StrictHostKeyChecking=yes'
EOF
  cat >"${generated_vars}" <<EOF
opnform_deployment_name: ${DEPLOYMENT_NAME}
opnform_hostname: ${OPNFORM_HOSTNAME}
opnform_caddy_email: ${CADDY_EMAIL}
opnform_cloudflare_proxied: ${CLOUDFLARE_PROXIED}
opnform_caddy_origin_lockdown: ${CADDY_ORIGIN_LOCKDOWN}
opnform_docker_subnet: ${OPNFORM_DOCKER_SUBNET}
opnform_ingress_ip: ${OPNFORM_INGRESS_IP}
opnform_ssh_allowed_cidrs: ${SSH_ALLOWED_CIDRS}
opnform_deploy_user: ${DEPLOY_USER}
opnform_ssh_port: ${SSH_PORT}
opnform_caddy_service_name: ${CADDY_SERVICE_NAME}
opnform_caddy_config_path: ${CADDY_CONFIG_PATH}
opnform_caddy_snippet_dir: ${CADDY_SNIPPET_DIR}
opnform_caddy_package_version: '${CADDY_PACKAGE_VERSION}'
opnform_backup_schedule: '${BACKUP_SCHEDULE}'
opnform_backup_keep_daily: ${BACKUP_KEEP_DAILY}
opnform_backup_keep_weekly: ${BACKUP_KEEP_WEEKLY}
opnform_backup_keep_monthly: ${BACKUP_KEEP_MONTHLY}
EOF
  chmod 0600 "${inventory_file}" "${generated_vars}"
  printf 'Generated %s for %s. Verify the SSH host key before deployment.\n' "${inventory_file}" "${host}"
}

require_inventory() {
  [[ -f "${inventory_file}" ]] || generate_inventory
}

ansible_command() {
  (cd "${ansible_root}" && uv run --locked -- "$@")
}

playbook() {
  ansible_command ansible-playbook "$@"
}

case "${action}" in
  inventory)
    generate_inventory
    ;;
  lint)
    ansible_command ansible-lint --strict site.yml restore.yml roles/
    ;;
  syntax)
    require_inventory
    playbook --syntax-check site.yml
    ;;
  check)
    require_inventory
    playbook --check --diff site.yml
    ;;
  deploy)
    confirm_production
    require_inventory
    require_value RELEASE_ID
    require_value OPNFORM_API_IMAGE
    require_value OPNFORM_CLIENT_IMAGE
    playbook site.yml
    ;;
  rollback)
    confirm_production
    [[ -n "${argument}" ]] || { printf '%s\n' 'A release ID is required.' >&2; exit 1; }
    require_inventory
    RELEASE_ID="${argument}" playbook site.yml --tags opnform_release,opnform_smoke -e "opnform_rollback_release=${argument}"
    ;;
  releases)
    require_inventory
    ansible_command ansible opnform -b -m ansible.builtin.command -a 'find /opt/opnform/releases -mindepth 1 -maxdepth 1 -type d -printf %f\\n' | sort
    ;;
  status)
    require_inventory
    ansible_command ansible opnform -b -m ansible.builtin.command -a 'docker compose -f /opt/opnform/docker-compose.yml ps'
    ;;
  logs)
    require_inventory
    ansible_command ansible opnform -b -m ansible.builtin.command -a 'docker compose -f /opt/opnform/docker-compose.yml logs --tail=200'
    ;;
  ssh)
    require_inventory
    host="$(awk '/ansible_host:/ {print $2; exit}' "${inventory_file}")"
    exec ssh -i "${SSH_PRIVATE_KEY_PATH}" -p "${SSH_PORT}" "${ANSIBLE_SSH_USER}@${host}"
    ;;
  backup)
    confirm_production
    require_inventory
    ansible_command ansible opnform -b -m ansible.builtin.command -a /usr/local/sbin/opnform-backup
    ;;
  backup-check)
    require_inventory
    ansible_command ansible opnform -b -m ansible.builtin.command -a /usr/local/sbin/opnform-backup-check
    ;;
  restore)
    confirm_production
    [[ -n "${argument}" ]] || { printf '%s\n' 'A restic snapshot ID is required.' >&2; exit 1; }
    require_inventory
    CONFIRM_RESTORE="${DEPLOYMENT_NAME}" OPNFORM_RESTORE_SNAPSHOT="${argument}" playbook restore.yml
    ;;
  *)
    printf 'Unknown Ansible action: %s\n' "${action}" >&2
    exit 1
    ;;
esac
