#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PREFIX="${PREFIX:-/usr/local}"
LIBEXEC_DIR="${PREFIX}/libexec/pingtunnel-client"
POLKIT_DIR="/usr/share/polkit-1/actions"
POLICY_FILE="${POLKIT_DIR}/com.pingtunnel.client.vpn.policy"
HELPER_PATH="${LIBEXEC_DIR}/vpn-helper"

if [[ ${EUID} -ne 0 ]]; then
  echo "This installer must run as root (use sudo)." >&2
  exit 1
fi

install -d "${LIBEXEC_DIR}"
install -m 755 "${ROOT_DIR}/templates/assets/scripts/linux/vpn_helper.sh" "${HELPER_PATH}"
install -m 755 "${ROOT_DIR}/templates/assets/scripts/linux/vpn_up.sh" \
  "${LIBEXEC_DIR}/vpn_up.sh"
install -m 755 "${ROOT_DIR}/templates/assets/scripts/linux/vpn_down.sh" \
  "${LIBEXEC_DIR}/vpn_down.sh"

install -d "${POLKIT_DIR}"
sed "s|@HELPER_PATH@|${HELPER_PATH}|g" \
  "${ROOT_DIR}/templates/assets/scripts/linux/com.pingtunnel.client.vpn.policy.in" > "${POLICY_FILE}"
chmod 644 "${POLICY_FILE}"

echo "Installed polkit helper to ${HELPER_PATH}"
echo "Policy installed to ${POLICY_FILE}"
