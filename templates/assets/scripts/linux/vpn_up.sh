#!/usr/bin/env bash
set -euo pipefail

TUN_DEV="${1:-ptun0}"
IFACE="${2:-}"
SERVER_HOST="${3:-}"
DNS_SERVERS="${4:-}"
STATE_DIR="/var/run/pingtunnel-client"
STATE_FILE="${STATE_DIR}/linux_state"
RESOLV_BACKUP="${STATE_DIR}/resolv.conf.bak"
RESOLV_LINK=""

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
  echo "vpn_up.sh requires CAP_NET_ADMIN or root" >&2
  exit 1
fi

if [[ -z "${IFACE}" ]]; then
  IFACE="$(ip route show default 0.0.0.0/0 | awk '{print $5; exit}')"
fi

GW="$(ip route show default 0.0.0.0/0 | awk '{print $3; exit}')"
if [[ -z "${GW}" || -z "${IFACE}" ]]; then
  echo "Failed to detect default gateway or interface" >&2
  exit 1
fi

mkdir -p "${STATE_DIR}"

SERVER_IP=""
if [[ -n "${SERVER_HOST}" ]]; then
  if [[ "${SERVER_HOST}" =~ [a-zA-Z] ]]; then
    SERVER_IP="$(getent ahostsv4 "${SERVER_HOST}" | awk '{print $1; exit}')"
  else
    SERVER_IP="${SERVER_HOST}"
  fi
  if [[ -n "${SERVER_IP}" ]]; then
    ip route replace "${SERVER_IP}/32" via "${GW}" dev "${IFACE}" metric 5
  fi
fi

# Create TUN device if missing
if ! ip link show "${TUN_DEV}" >/dev/null 2>&1; then
  OWNER=""
  if [[ -n "${SUDO_USER:-}" ]]; then
    OWNER="${SUDO_USER}"
  elif [[ -n "${PKEXEC_UID:-}" ]]; then
    OWNER="$(getent passwd "${PKEXEC_UID}" | cut -d: -f1)"
  fi

  if [[ -n "${OWNER}" ]]; then
    ip tuntap add dev "${TUN_DEV}" mode tun user "${OWNER}"
  else
    ip tuntap add dev "${TUN_DEV}" mode tun
  fi
fi

ip addr add 198.18.0.1/15 dev "${TUN_DEV}" 2>/dev/null || true
ip link set "${TUN_DEV}" up

# Disable reverse path filtering to avoid drops
sysctl -w net.ipv4.conf.all.rp_filter=0 >/dev/null
sysctl -w net.ipv4.conf."${IFACE}".rp_filter=0 >/dev/null || true
sysctl -w net.ipv4.conf."${TUN_DEV}".rp_filter=0 >/dev/null || true

# Route all traffic to the TUN, keep a lower-priority fallback
ip route replace default via 198.18.0.1 dev "${TUN_DEV}" metric 1
ip route replace default via "${GW}" dev "${IFACE}" metric 10

DNS_SERVERS="$(echo "${DNS_SERVERS//,/ }" | xargs || true)"
if [[ -z "${DNS_SERVERS}" ]]; then
  DNS_SERVERS="$(awk '/^nameserver/ {print $2}' /etc/resolv.conf | grep -v '^127\\.' | xargs || true)"
fi
if [[ -z "${DNS_SERVERS}" ]]; then
  DNS_SERVERS="1.1.1.1 1.0.0.1"
fi

RESOLV_MODE="none"
if command -v resolvectl >/dev/null 2>&1; then
  if resolvectl dns "${TUN_DEV}" ${DNS_SERVERS} >/dev/null 2>&1; then
    RESOLV_MODE="resolved"
    RESOLV_LINK="${TUN_DEV}"
    resolvectl dnsovertls "${TUN_DEV}" yes >/dev/null 2>&1 || true
    resolvectl domains "${TUN_DEV}" '~.' >/dev/null 2>&1 || true
    resolvectl default-route "${TUN_DEV}" yes >/dev/null 2>&1 || true
    resolvectl default-route "${IFACE}" no >/dev/null 2>&1 || true
  else
    echo "resolvectl failed; falling back to /etc/resolv.conf" >&2
  fi
fi

if [[ "${RESOLV_MODE}" != "resolved" ]]; then
  RESOLV_MODE="resolvconf"
  if [[ -f /etc/resolv.conf ]]; then
    cp -f /etc/resolv.conf "${RESOLV_BACKUP}" || true
  fi
  {
    for ns in ${DNS_SERVERS}; do
      echo "nameserver ${ns}"
    done
    echo "options use-vc"
  } > /etc/resolv.conf || echo "Failed to update /etc/resolv.conf" >&2
fi

cat > "${STATE_FILE}" <<STATE
TUN_DEV=${TUN_DEV}
IFACE=${IFACE}
GW=${GW}
SERVER_IP=${SERVER_IP}
RESOLV_MODE=${RESOLV_MODE}
RESOLV_BACKUP=${RESOLV_BACKUP}
RESOLV_LINK=${RESOLV_LINK}
STATE

echo "Linux VPN routes installed via ${TUN_DEV}"
