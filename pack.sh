#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="${ROOT_DIR}/app"
DIST_DIR="${ROOT_DIR}/dist"

if [[ ! -d "${APP_DIR}" ]]; then
  echo "Missing app directory. Run from repo root." >&2
  exit 1
fi

VERSION="$(awk -F': ' '/^version:/ {print $2; exit}' "${APP_DIR}/pubspec.yaml" || true)"
if [[ -z "${VERSION}" ]]; then
  VERSION="0.1.0+1"
fi
VERSION_TAG="${VERSION//+/-}"

echo "Bootstrapping Flutter app..."
"${ROOT_DIR}/scripts/bootstrap_flutter.sh"

echo "Building Android APKs (release)..."
(cd "${APP_DIR}" && flutter build apk --release)
(cd "${APP_DIR}" && flutter build apk --release --split-per-abi)

mkdir -p "${DIST_DIR}"
APK_DIR="${APP_DIR}/build/app/outputs/flutter-apk"
APK_COUNT=0
for apk in "${APK_DIR}"/app-*-release.apk; do
  if [[ -f "${apk}" ]]; then
    base="$(basename "${apk}")"
    out="${DIST_DIR}/pingtunnel-client-${VERSION_TAG}-${base}"
    cp -f "${apk}" "${out}"
    echo "APK: ${out}"
    APK_COUNT=$((APK_COUNT + 1))
  fi
done
if [[ "${APK_COUNT}" -eq 0 ]]; then
  echo "No APKs found in ${APK_DIR}" >&2
  exit 1
fi

if [[ "$(uname -s)" == "Linux" ]]; then
  echo "Building Linux bundle (release)..."
  (cd "${APP_DIR}" && flutter build linux --release)

  echo "Building Debian package(s)..."
  BUILT_DEB=0
  for flutter_arch in x64 arm64 ia32; do
    case "${flutter_arch}" in
      x64) arch="amd64" ;;
      arm64) arch="arm64" ;;
      ia32) arch="i386" ;;
      *) continue ;;
    esac
    if [[ -d "${APP_DIR}/build/linux/${flutter_arch}/release/bundle" ]]; then
      ARCH="${arch}" SKIP_BUILD=1 "${ROOT_DIR}/scripts/build_deb.sh"
      BUILT_DEB=$((BUILT_DEB + 1))
    fi
  done
  if [[ "${BUILT_DEB}" -eq 0 ]]; then
    SKIP_BUILD=1 "${ROOT_DIR}/scripts/build_deb.sh"
  fi

  if command -v rpmbuild >/dev/null 2>&1; then
    echo "Building RPM package(s)..."
    BUILT_RPM=0
    for flutter_arch in x64 arm64 ia32; do
      case "${flutter_arch}" in
        x64) arch="x86_64" ;;
        arm64) arch="aarch64" ;;
        ia32) arch="i386" ;;
        *) continue ;;
      esac
      if [[ -d "${APP_DIR}/build/linux/${flutter_arch}/release/bundle" ]]; then
        ARCH="${arch}" SKIP_BUILD=1 "${ROOT_DIR}/scripts/build_rpm.sh"
        BUILT_RPM=$((BUILT_RPM + 1))
      fi
    done
    if [[ "${BUILT_RPM}" -eq 0 ]]; then
      SKIP_BUILD=1 "${ROOT_DIR}/scripts/build_rpm.sh"
    fi
  else
    echo "rpmbuild not found; skipping RPM."
  fi
else
  echo "Skipping Linux builds; run this script on Linux to produce .deb/.rpm."
fi

echo "Done."
