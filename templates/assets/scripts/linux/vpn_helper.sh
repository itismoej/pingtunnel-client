#!/usr/bin/env bash
set -euo pipefail

PATH="/usr/sbin:/usr/bin:/sbin:/bin"

ACTION="${1:-}"
shift || true

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

case "${ACTION}" in
  up)
    "${SCRIPT_DIR}/vpn_up.sh" "$@"
    ;;
  down)
    "${SCRIPT_DIR}/vpn_down.sh"
    ;;
  *)
    echo "Usage: $0 up <tun> <iface> | down" >&2
    exit 2
    ;;
esac
