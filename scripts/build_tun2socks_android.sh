#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_DIR="${1:-$HOME/Projects/tun2socks}"
OUT_BASE="${ROOT_DIR}/templates/assets/binaries/tun2socks"

if [[ ! -d "${SRC_DIR}" ]]; then
  echo "tun2socks source not found: ${SRC_DIR}" >&2
  exit 1
fi

GOPATH="${GOPATH:-/tmp/go}"
GOMODCACHE="${GOMODCACHE:-${GOPATH}/pkg/mod}"
GOCACHE="${GOCACHE:-/tmp/go-build-cache}"

mkdir -p "${GOPATH}" "${GOMODCACHE}" "${GOCACHE}"
mkdir -p "${OUT_BASE}/android-arm64" "${OUT_BASE}/android-arm"

build_one() {
  local arch="$1"
  local outdir="$2"
  echo "Building tun2socks for android/${arch}"
  (cd "${SRC_DIR}" && \
    GOPATH="${GOPATH}" GOMODCACHE="${GOMODCACHE}" GOCACHE="${GOCACHE}" \
    GOOS=android GOARCH="${arch}" CGO_ENABLED=0 \
    go build -o "${outdir}/tun2socks" .)
}

build_one arm64 "${OUT_BASE}/android-arm64"

if [[ "${BUILD_ARM32:-}" == "1" ]]; then
  if [[ -z "${ANDROID_NDK_HOME:-}" ]]; then
    echo "ANDROID_NDK_HOME is not set; arm (32-bit) build requires NDK + cgo." >&2
    exit 1
  fi
  export CGO_ENABLED=1
  export CC="${ANDROID_NDK_HOME}/toolchains/llvm/prebuilt/linux-x86_64/bin/armv7a-linux-androideabi21-clang"
  export CXX="${ANDROID_NDK_HOME}/toolchains/llvm/prebuilt/linux-x86_64/bin/armv7a-linux-androideabi21-clang++"
  build_one arm "${OUT_BASE}/android-arm"
else
  echo "Skipping android/arm build. Set BUILD_ARM32=1 and ANDROID_NDK_HOME to enable."
fi

echo "tun2socks Android binaries written to ${OUT_BASE}/android-*"
