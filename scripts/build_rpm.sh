#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="pingtunnel-client"
APP_DIR="${ROOT_DIR}/app"
VERSION_RAW="${VERSION:-}"
ARCH_INPUT="${ARCH:-}"
SKIP_BUILD="${SKIP_BUILD:-0}"

if [[ -z "${VERSION_RAW}" && -f "${APP_DIR}/pubspec.yaml" ]]; then
  VERSION_RAW="$(awk -F': ' '/^version:/ {print $2; exit}' "${APP_DIR}/pubspec.yaml")"
fi
if [[ -z "${VERSION_RAW}" ]]; then
  VERSION_RAW="0.1.0+1"
fi

RPM_VERSION="${VERSION_RAW%%+*}"
RPM_RELEASE="${VERSION_RAW#*+}"
if [[ "${RPM_RELEASE}" == "${VERSION_RAW}" ]]; then
  RPM_RELEASE="1"
fi
RPM_VERSION="${RPM_VERSION//-/.}"
RPM_RELEASE="${RPM_RELEASE//[^0-9A-Za-z._]/_}"
if [[ -z "${RPM_RELEASE}" ]]; then
  RPM_RELEASE="1"
fi

if [[ -z "${ARCH_INPUT}" ]]; then
  ARCH_INPUT="$(uname -m)"
fi

case "${ARCH_INPUT}" in
  x86_64|amd64)
    RPM_ARCH="x86_64"
    FLUTTER_ARCH="x64"
    ;;
  aarch64|arm64)
    RPM_ARCH="aarch64"
    FLUTTER_ARCH="arm64"
    ;;
  i386|i686|ia32)
    RPM_ARCH="i686"
    FLUTTER_ARCH="ia32"
    ;;
  *)
    RPM_ARCH="${ARCH_INPUT}"
    FLUTTER_ARCH="x64"
    ;;
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

if ! command -v rpmbuild >/dev/null 2>&1; then
  echo "rpmbuild not found; install rpm-build first." >&2
  exit 1
fi

RPM_TOPDIR="${ROOT_DIR}/dist/rpm/${RPM_ARCH}"
mkdir -p "${RPM_TOPDIR}"/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS}

SPEC_FILE="${RPM_TOPDIR}/SPECS/${APP_NAME}.spec"
ICON_SRC="${APP_DIR}/macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_256.png"
ICON_INSTALL=""
ICON_FILES_LINE=""
if [[ -f "${ICON_SRC}" ]]; then
  ICON_INSTALL=$(cat <<'EOF'
mkdir -p %{buildroot}/usr/share/icons/hicolor/256x256/apps
install -m 644 %{root_dir}/app/macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_256.png \
  %{buildroot}/usr/share/icons/hicolor/256x256/apps/pingtunnel-client.png
EOF
)
  ICON_FILES_LINE="/usr/share/icons/hicolor/256x256/apps/pingtunnel-client.png"
fi

cat > "${SPEC_FILE}" <<EOF
Name: ${APP_NAME}
Version: ${RPM_VERSION}
Release: ${RPM_RELEASE}%{?dist}
Summary: Pingtunnel Client
License: Proprietary
Requires: polkit
BuildArch: %{_arch}

%global root_dir ${ROOT_DIR}
%global bundle_dir ${BUNDLE_DIR}

%description
A Flutter client for pingtunnel proxy/VPN.

%prep

%build

%install
rm -rf %{buildroot}
mkdir -p %{buildroot}/opt/${APP_NAME}
cp -a %{bundle_dir}/. %{buildroot}/opt/${APP_NAME}/

mkdir -p %{buildroot}/usr/bin
cat > %{buildroot}/usr/bin/${APP_NAME} <<'WRAP'
#!/usr/bin/env bash
exec /opt/${APP_NAME}/app "\$@"
WRAP
chmod 755 %{buildroot}/usr/bin/${APP_NAME}

mkdir -p %{buildroot}/usr/share/applications
install -m 644 %{root_dir}/scripts/linux/pingtunnel-client.desktop \
  %{buildroot}/usr/share/applications/pingtunnel-client.desktop

${ICON_INSTALL}

mkdir -p %{buildroot}/usr/libexec/pingtunnel-client
install -m 755 %{root_dir}/templates/assets/scripts/linux/vpn_helper.sh \
  %{buildroot}/usr/libexec/pingtunnel-client/vpn-helper
install -m 755 %{root_dir}/templates/assets/scripts/linux/vpn_up.sh \
  %{buildroot}/usr/libexec/pingtunnel-client/vpn_up.sh
install -m 755 %{root_dir}/templates/assets/scripts/linux/vpn_down.sh \
  %{buildroot}/usr/libexec/pingtunnel-client/vpn_down.sh

mkdir -p %{buildroot}/usr/share/polkit-1/actions
sed "s|@HELPER_PATH@|/usr/libexec/${APP_NAME}/vpn-helper|g" \
  %{root_dir}/templates/assets/scripts/linux/com.pingtunnel.client.vpn.policy.in \
  > %{buildroot}/usr/share/polkit-1/actions/com.pingtunnel.client.vpn.policy
chmod 644 %{buildroot}/usr/share/polkit-1/actions/com.pingtunnel.client.vpn.policy

%files
/opt/${APP_NAME}
/usr/bin/${APP_NAME}
/usr/share/applications/pingtunnel-client.desktop
${ICON_FILES_LINE}
/usr/libexec/pingtunnel-client/vpn-helper
/usr/libexec/pingtunnel-client/vpn_up.sh
/usr/libexec/pingtunnel-client/vpn_down.sh
/usr/share/polkit-1/actions/com.pingtunnel.client.vpn.policy
EOF

rpmbuild -bb --define "_topdir ${RPM_TOPDIR}" --target "${RPM_ARCH}" "${SPEC_FILE}"

shopt -s nullglob
RPM_FILES=("${RPM_TOPDIR}/RPMS/${RPM_ARCH}"/*.rpm)
if [[ ${#RPM_FILES[@]} -eq 0 ]]; then
  echo "No RPMs found in ${RPM_TOPDIR}/RPMS/${RPM_ARCH}" >&2
  exit 1
fi

install -d "${ROOT_DIR}/dist"
for rpm in "${RPM_FILES[@]}"; do
  cp -f "${rpm}" "${ROOT_DIR}/dist/"
  echo "Built ${ROOT_DIR}/dist/$(basename "${rpm}")"
done
