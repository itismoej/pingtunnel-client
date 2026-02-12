#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="${ROOT_DIR}/app"
DIST_DIR="${ROOT_DIR}/dist"

print_help() {
  cat <<'EOF'
Usage: ./pack.sh [--help]

Build and package Pingtunnel Client artifacts into the `dist/` directory.

Target selection is controlled with environment variables:
  BUILD_ANDROID   1|0|auto   Build Android APKs
  BUILD_LINUX     1|0|auto   Build Linux bundle and .deb/.rpm
  BUILD_WINDOWS   1|0|auto   Build Windows release bundle
  FLUTTER_BUILD_NAME          Override Flutter --build-name (e.g. 0.6.0)
  FLUTTER_BUILD_NUMBER        Override Flutter --build-number (e.g. 123)
  BUILD_GIT_SHA               Override embedded git commit hash

Defaults:
  BUILD_ANDROID=auto -> enabled
  BUILD_LINUX=auto   -> enabled on Linux hosts only
  BUILD_WINDOWS=auto -> enabled on Windows hosts only

Examples:
  ./pack.sh
  BUILD_ANDROID=1 BUILD_LINUX=0 BUILD_WINDOWS=0 ./pack.sh
  BUILD_ANDROID=0 BUILD_LINUX=1 BUILD_WINDOWS=0 ./pack.sh
  BUILD_ANDROID=0 BUILD_LINUX=0 BUILD_WINDOWS=1 ./pack.sh
EOF
}

for arg in "$@"; do
  case "${arg}" in
    -h|--help|help)
      print_help
      exit 0
      ;;
    *)
      echo "Unknown argument: ${arg}" >&2
      print_help >&2
      exit 1
      ;;
  esac
done

HOST_OS="$(uname -s)"
IS_LINUX_HOST=0
IS_WINDOWS_HOST=0
case "${HOST_OS}" in
  Linux) IS_LINUX_HOST=1 ;;
  MINGW*|MSYS*|CYGWIN*) IS_WINDOWS_HOST=1 ;;
esac

resolve_toggle() {
  local value="${1:-auto}"
  local default_value="$2"
  local var_name="$3"
  local normalized="${value,,}"
  case "${normalized}" in
    1|true|yes|on) echo 1 ;;
    0|false|no|off) echo 0 ;;
    auto|"") echo "${default_value}" ;;
    *)
      echo "Invalid value for ${var_name}: ${value} (use 0, 1, or auto)" >&2
      exit 1
      ;;
  esac
}

BUILD_ANDROID="$(resolve_toggle "${BUILD_ANDROID:-auto}" 1 BUILD_ANDROID)"
BUILD_LINUX="$(resolve_toggle "${BUILD_LINUX:-auto}" "${IS_LINUX_HOST}" BUILD_LINUX)"
BUILD_WINDOWS="$(resolve_toggle "${BUILD_WINDOWS:-auto}" "${IS_WINDOWS_HOST}" BUILD_WINDOWS)"

if [[ "${BUILD_ANDROID}" == "0" && "${BUILD_LINUX}" == "0" && "${BUILD_WINDOWS}" == "0" ]]; then
  echo "No build target selected. Enable at least one of BUILD_ANDROID, BUILD_LINUX, BUILD_WINDOWS." >&2
  exit 1
fi

if [[ ! -d "${APP_DIR}" ]]; then
  echo "Missing app directory. Run from repo root." >&2
  exit 1
fi

VERSION="$(awk -F': ' '/^version:/ {print $2; exit}' "${APP_DIR}/pubspec.yaml" || true)"
if [[ -z "${VERSION}" ]]; then
  VERSION="0.1.0+1"
fi
PUBSPEC_BUILD_NAME="${VERSION%%+*}"
PUBSPEC_BUILD_NUMBER="1"
if [[ "${VERSION}" == *"+"* ]]; then
  PUBSPEC_BUILD_NUMBER="${VERSION##*+}"
fi

BUILD_NAME="${FLUTTER_BUILD_NAME:-${PUBSPEC_BUILD_NAME}}"
BUILD_NUMBER="${FLUTTER_BUILD_NUMBER:-${PUBSPEC_BUILD_NUMBER}}"
VERSION="${BUILD_NAME}+${BUILD_NUMBER}"
VERSION_TAG="${VERSION//+/-}"
BUILD_GIT_SHA="${BUILD_GIT_SHA:-$(git -C "${ROOT_DIR}" rev-parse --short=12 HEAD 2>/dev/null || echo unknown)}"

FLUTTER_BUILD_ARGS=()
if [[ -n "${FLUTTER_BUILD_NAME:-}" ]]; then
  FLUTTER_BUILD_ARGS+=(--build-name "${FLUTTER_BUILD_NAME}")
fi
if [[ -n "${FLUTTER_BUILD_NUMBER:-}" ]]; then
  FLUTTER_BUILD_ARGS+=(--build-number "${FLUTTER_BUILD_NUMBER}")
fi
DART_DEFINE_ARGS=(
  "--dart-define=APP_VERSION=${BUILD_NAME}"
  "--dart-define=APP_BUILD=${BUILD_NUMBER}"
  "--dart-define=GIT_SHA=${BUILD_GIT_SHA}"
)

echo "Resolved app version: ${VERSION}"
echo "Resolved git commit: ${BUILD_GIT_SHA}"

echo "Bootstrapping Flutter app..."
"${ROOT_DIR}/scripts/bootstrap_flutter.sh"

if [[ "${BUILD_ANDROID}" == "1" ]]; then
  echo "Building Android APKs (release)..."
  (cd "${APP_DIR}" && flutter build apk --release "${FLUTTER_BUILD_ARGS[@]}" "${DART_DEFINE_ARGS[@]}")
  (cd "${APP_DIR}" && flutter build apk --release --split-per-abi "${FLUTTER_BUILD_ARGS[@]}" "${DART_DEFINE_ARGS[@]}")
fi

mkdir -p "${DIST_DIR}"
APK_DIR="${APP_DIR}/build/app/outputs/flutter-apk"
APK_COUNT=0
copy_apk() {
  local apk="$1"
  if [[ -f "${apk}" ]]; then
    local base
    local out
    base="$(basename "${apk}")"
    out="${DIST_DIR}/pingtunnel-client-${VERSION_TAG}-${base}"
    cp -f "${apk}" "${out}"
    echo "APK: ${out}"
    APK_COUNT=$((APK_COUNT + 1))
  fi
}

if [[ "${BUILD_ANDROID}" == "1" ]]; then
  copy_apk "${APK_DIR}/app-release.apk"
  for apk in "${APK_DIR}"/app-*-release.apk; do
    copy_apk "${apk}"
  done
  if [[ "${APK_COUNT}" -eq 0 ]]; then
    echo "No APKs found in ${APK_DIR}" >&2
    exit 1
  fi
fi

if [[ "${BUILD_LINUX}" == "1" ]]; then
  if [[ "${IS_LINUX_HOST}" != "1" ]]; then
    echo "Linux builds require a Linux host." >&2
    exit 1
  fi

  echo "Building Linux bundle (release)..."
  (cd "${APP_DIR}" && flutter build linux --release "${FLUTTER_BUILD_ARGS[@]}" "${DART_DEFINE_ARGS[@]}")

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
fi

if [[ "${BUILD_WINDOWS}" == "1" ]]; then
  if [[ "${IS_WINDOWS_HOST}" != "1" ]]; then
    echo "Windows builds require a Windows host." >&2
    exit 1
  fi

  echo "Building Windows bundle (release)..."
  (cd "${APP_DIR}" && flutter build windows --release "${FLUTTER_BUILD_ARGS[@]}" "${DART_DEFINE_ARGS[@]}")

  WINDOWS_BUILD_COUNT=0
  for win_arch in x64 arm64; do
    WIN_RELEASE_DIR="${APP_DIR}/build/windows/${win_arch}/runner/Release"
    if [[ -d "${WIN_RELEASE_DIR}" ]]; then
      OUT_DIR="${DIST_DIR}/pingtunnel-client-${VERSION_TAG}-windows-${win_arch}"
      rm -rf "${OUT_DIR}"
      mkdir -p "${OUT_DIR}"
      cp -a "${WIN_RELEASE_DIR}/." "${OUT_DIR}/"
      echo "Windows bundle: ${OUT_DIR}"
      WINDOWS_BUILD_COUNT=$((WINDOWS_BUILD_COUNT + 1))
    fi
  done

  if [[ "${WINDOWS_BUILD_COUNT}" -eq 0 ]]; then
    echo "No Windows release bundle found under ${APP_DIR}/build/windows" >&2
    exit 1
  fi
fi

echo "Done."
