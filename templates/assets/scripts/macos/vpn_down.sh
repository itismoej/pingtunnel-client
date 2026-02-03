#!/usr/bin/env bash
set -euo pipefail

STATE_FILE="/var/run/pingtunnel-client/macos_state"

if [[ ${EUID} -ne 0 ]]; then
  echo "vpn_down.sh must run as root" >&2
  exit 1
fi

if [[ ! -f "${STATE_FILE}" ]]; then
  echo "State file not found: ${STATE_FILE}" >&2
  exit 1
fi

# shellcheck disable=SC1090
source "${STATE_FILE}"

route -n delete -net 0.0.0.0/1 198.18.0.1 2>/dev/null || true
route -n delete -net 128.0.0.0/1 198.18.0.1 2>/dev/null || true
route -n delete -inet6 ::/1 2000:: 2>/dev/null || true
route -n delete -inet6 8000::/1 2000:: 2>/dev/null || true

ifconfig "${TUN_DEV}" down 2>/dev/null || true

rm -f "${STATE_FILE}"

echo "macOS VPN routes removed"
