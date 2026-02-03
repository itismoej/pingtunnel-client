#!/usr/bin/env bash
set -euo pipefail

TUN_DEV="${1:-utun2}"
STATE_DIR="/var/run/pingtunnel-client"
STATE_FILE="${STATE_DIR}/macos_state"

if [[ ${EUID} -ne 0 ]]; then
  echo "vpn_up.sh must run as root" >&2
  exit 1
fi

mkdir -p "${STATE_DIR}"
cat > "${STATE_FILE}" <<STATE
TUN_DEV=${TUN_DEV}
STATE

ifconfig "${TUN_DEV}" 198.18.0.1 198.18.0.1 up

# Split default route into /1s so local gateway still reachable
route -n add -net 0.0.0.0/1 198.18.0.1
route -n add -net 128.0.0.0/1 198.18.0.1

# IPv6 defaults
route -n add -inet6 ::/1 2000::
route -n add -inet6 8000::/1 2000::

echo "macOS VPN routes installed via ${TUN_DEV}"
