#!/usr/bin/env bash
# Update UFW SSH allow rules on Ubuntu. Copy this script to the VPS and run it there.
set -euo pipefail

usage() {
  printf 'Usage: %s add <IP> | remove <IP> | list\n' "$(basename "$0")" >&2
  exit 1
}

show_status() {
  sudo ufw status numbered
}

command="${1:-}"
ip="${2:-}"

case "${command}" in
  add)
    [[ -n "${ip}" ]] || usage
    sudo ufw allow from "${ip}/32" to any port 22 proto tcp
    show_status
    ;;
  remove)
    [[ -n "${ip}" ]] || usage
    sudo ufw delete allow from "${ip}/32" to any port 22 proto tcp
    show_status
    ;;
  list)
    show_status
    ;;
  *)
    usage
    ;;
esac
