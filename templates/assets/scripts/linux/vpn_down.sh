#!/usr/bin/env bash
set -euo pipefail

STATE_FILE="/var/run/pingtunnel-client/linux_state"
RESOLV_BACKUP="/var/run/pingtunnel-client/resolv.conf.bak"

has_cap_net_admin() {
  local cap_eff
  cap_eff="$(awk '/CapEff/ {print $2}' /proc/self/status 2>/dev/null || true)"
  if [[ -z "${cap_eff}" ]]; then
    return 1
  fi
  local cap_dec=$((16#${cap_eff}))
  (( cap_dec & (1 << 12) ))
}

if [[ ${EUID} -ne 0 ]] && ! has_cap_net_admin; then
  echo "vpn_down.sh requires CAP_NET_ADMIN or root" >&2
  exit 1
fi

if [[ ! -f "${STATE_FILE}" ]]; then
  echo "State file not found: ${STATE_FILE}" >&2
  exit 1
fi

# shellcheck disable=SC1090
source "${STATE_FILE}"

RESOLV_MODE="${RESOLV_MODE:-}"
if [[ "${RESOLV_MODE}" == "resolved" ]]; then
  if command -v resolvectl >/dev/null 2>&1; then
    resolvectl revert "${IFACE}" || true
  fi
elif [[ "${RESOLV_MODE}" == "resolvconf" ]]; then
  if [[ -f "${RESOLV_BACKUP}" ]]; then
    cp -f "${RESOLV_BACKUP}" /etc/resolv.conf
    rm -f "${RESOLV_BACKUP}"
  fi
fi

if [[ -n "${SERVER_IP:-}" ]]; then
  ip route del "${SERVER_IP}/32" via "${GW}" dev "${IFACE}" metric 5 2>/dev/null || true
fi

ip route del default via 198.18.0.1 dev "${TUN_DEV}" metric 1 2>/dev/null || true
ip route replace default via "${GW}" dev "${IFACE}" metric 1

ip link del "${TUN_DEV}" 2>/dev/null || true

rm -f "${STATE_FILE}"

echo "Linux VPN routes removed"
