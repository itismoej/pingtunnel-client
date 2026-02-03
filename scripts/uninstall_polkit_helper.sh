#!/usr/bin/env bash
set -euo pipefail

PREFIX="${PREFIX:-/usr/local}"
LIBEXEC_DIR="${PREFIX}/libexec/pingtunnel-client"
POLICY_FILE="/usr/share/polkit-1/actions/com.pingtunnel.client.vpn.policy"

if [[ ${EUID} -ne 0 ]]; then
  echo "This uninstaller must run as root (use sudo)." >&2
  exit 1
fi

rm -f \
  "${LIBEXEC_DIR}/vpn-helper" \
  "${LIBEXEC_DIR}/vpn_up.sh" \
  "${LIBEXEC_DIR}/vpn_down.sh"

if [[ -d "${LIBEXEC_DIR}" ]] && [[ -z "$(ls -A "${LIBEXEC_DIR}")" ]]; then
  rmdir "${LIBEXEC_DIR}"
fi

rm -f "${POLICY_FILE}"

echo "Removed polkit helper and policy."
