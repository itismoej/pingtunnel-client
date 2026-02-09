#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="pingtunnel-client"
APP_DIR="${ROOT_DIR}/app"
VERSION="${VERSION:-}"
ARCH="${ARCH:-}"
SKIP_BUILD="${SKIP_BUILD:-0}"

if [[ -z "${VERSION}" && -f "${APP_DIR}/pubspec.yaml" ]]; then
  VERSION="$(awk -F': ' '/^version:/ {print $2; exit}' "${APP_DIR}/pubspec.yaml")"
fi
if [[ -z "${VERSION}" ]]; then
  VERSION="0.1.0"
fi
VERSION="${VERSION//+/-}"

if [[ -z "${ARCH}" ]]; then
  case "$(uname -m)" in
    x86_64) ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    *) ARCH="amd64" ;;
  esac
fi

case "${ARCH}" in
  amd64) FLUTTER_ARCH="x64" ;;
  arm64) FLUTTER_ARCH="arm64" ;;
  *) FLUTTER_ARCH="x64" ;;
esac

if [[ "${SKIP_BUILD}" != "1" ]]; then
  "${ROOT_DIR}/scripts/bootstrap_flutter.sh"
  (cd "${APP_DIR}" && flutter build linux --release)
fi

BUNDLE_DIR="${APP_DIR}/build/linux/${FLUTTER_ARCH}/release/bundle"
if [[ ! -d "${BUNDLE_DIR}" ]]; then
  echo "Bundle not found: ${BUNDLE_DIR}" >&2
  exit 1
fi

STAGE_DIR="${ROOT_DIR}/dist/deb/${APP_NAME}_${VERSION}_${ARCH}"
rm -rf "${STAGE_DIR}"
install -d "${STAGE_DIR}/DEBIAN"

cat > "${STAGE_DIR}/DEBIAN/control" <<EOF
Package: ${APP_NAME}
Version: ${VERSION}
Section: net
Priority: optional
Architecture: ${ARCH}
Maintainer: Pingtunnel Client <noreply@local>
Depends: libc6, libgcc-s1, libstdc++6, libgtk-3-0, libglib2.0-0, policykit-1, libcap2-bin, libayatana-appindicator3-1 | libappindicator3-1
Description: Pingtunnel Client
 A Flutter client for pingtunnel proxy/VPN.
EOF

install -d "${STAGE_DIR}/opt/${APP_NAME}"
cp -a "${BUNDLE_DIR}/." "${STAGE_DIR}/opt/${APP_NAME}/"

install -d "${STAGE_DIR}/usr/bin"
cat > "${STAGE_DIR}/usr/bin/${APP_NAME}" <<'EOF'
#!/usr/bin/env bash
exec /opt/pingtunnel-client/app "$@"
EOF
chmod 755 "${STAGE_DIR}/usr/bin/${APP_NAME}"

install -d "${STAGE_DIR}/usr/share/applications"
install -m 644 "${ROOT_DIR}/scripts/linux/pingtunnel-client.desktop" \
  "${STAGE_DIR}/usr/share/applications/pingtunnel-client.desktop"

ICON_SRC="${APP_DIR}/macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_256.png"
if [[ -f "${ICON_SRC}" ]]; then
  install -d "${STAGE_DIR}/usr/share/icons/hicolor/256x256/apps"
  install -m 644 "${ICON_SRC}" \
    "${STAGE_DIR}/usr/share/icons/hicolor/256x256/apps/pingtunnel-client.png"
fi

install -d "${STAGE_DIR}/usr/libexec/pingtunnel-client"
install -m 755 "${ROOT_DIR}/templates/assets/scripts/linux/vpn_helper.sh" \
  "${STAGE_DIR}/usr/libexec/pingtunnel-client/vpn-helper"
install -m 755 "${ROOT_DIR}/templates/assets/scripts/linux/vpn_up.sh" \
  "${STAGE_DIR}/usr/libexec/pingtunnel-client/vpn_up.sh"
install -m 755 "${ROOT_DIR}/templates/assets/scripts/linux/vpn_down.sh" \
  "${STAGE_DIR}/usr/libexec/pingtunnel-client/vpn_down.sh"

install -d "${STAGE_DIR}/usr/libexec/pingtunnel-client/binaries/pingtunnel/linux-${ARCH}"
install -m 755 "${ROOT_DIR}/templates/assets/binaries/pingtunnel/linux-${ARCH}/pingtunnel" \
  "${STAGE_DIR}/usr/libexec/pingtunnel-client/binaries/pingtunnel/linux-${ARCH}/pingtunnel"
install -d "${STAGE_DIR}/usr/libexec/pingtunnel-client/binaries/tun2socks/linux-${ARCH}"
install -m 755 "${ROOT_DIR}/templates/assets/binaries/tun2socks/linux-${ARCH}/tun2socks" \
  "${STAGE_DIR}/usr/libexec/pingtunnel-client/binaries/tun2socks/linux-${ARCH}/tun2socks"

install -d "${STAGE_DIR}/usr/share/polkit-1/actions"
sed "s|@HELPER_PATH@|/usr/libexec/pingtunnel-client/vpn-helper|g" \
  "${ROOT_DIR}/templates/assets/scripts/linux/com.pingtunnel.client.vpn.policy.in" \
  > "${STAGE_DIR}/usr/share/polkit-1/actions/com.pingtunnel.client.vpn.policy"
chmod 644 "${STAGE_DIR}/usr/share/polkit-1/actions/com.pingtunnel.client.vpn.policy"

cat > "${STAGE_DIR}/DEBIAN/postinst" <<EOF
#!/usr/bin/env bash
set -e

BIN="/usr/libexec/pingtunnel-client/binaries/pingtunnel/linux-${ARCH}/pingtunnel"
if command -v setcap >/dev/null 2>&1 && [[ -f "\${BIN}" ]]; then
  setcap cap_net_raw+ep "\${BIN}" || true
fi
EOF
chmod 755 "${STAGE_DIR}/DEBIAN/postinst"

install -d "${ROOT_DIR}/dist"
dpkg-deb --build --root-owner-group \
  "${STAGE_DIR}" "${ROOT_DIR}/dist/${APP_NAME}_${VERSION}_${ARCH}.deb"
echo "Built ${ROOT_DIR}/dist/${APP_NAME}_${VERSION}_${ARCH}.deb"
