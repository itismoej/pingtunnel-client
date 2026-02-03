#!/usr/bin/env bash
set -euo pipefail

VERSION="2.6.0"
BASE_URL="https://github.com/xjasonlyu/tun2socks/releases/download/v${VERSION}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${ROOT_DIR}/templates/assets/binaries/tun2socks"
TMP_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

mkdir -p "${OUT_DIR}"

# Known assets from v2.6.0 release page and winget metadata.
ASSETS=(
  "tun2socks-darwin-amd64.zip"
  "tun2socks-darwin-arm64.zip"
  "tun2socks-linux-amd64.zip"
  "tun2socks-windows-amd64.zip"
  "tun2socks-windows-arm64.zip"
)

for asset in "${ASSETS[@]}"; do
  echo "Downloading ${asset}..."
  curl -fL "${BASE_URL}/${asset}" -o "${TMP_DIR}/${asset}"

  extract_dir="${TMP_DIR}/extract-${asset%.zip}"
  mkdir -p "${extract_dir}"
  unzip -q "${TMP_DIR}/${asset}" -d "${extract_dir}"

  bin_path="$(find "${extract_dir}" -type f -maxdepth 2 -name "tun2socks*" | head -n 1)"
  if [[ -z "${bin_path}" ]]; then
    echo "Failed to locate tun2socks binary in ${asset}" >&2
    exit 1
  fi

  case "${asset}" in
    *darwin-amd64*) target_dir="${OUT_DIR}/darwin-amd64" ;;
    *darwin-arm64*) target_dir="${OUT_DIR}/darwin-arm64" ;;
    *linux-amd64*) target_dir="${OUT_DIR}/linux-amd64" ;;
    *windows-amd64*) target_dir="${OUT_DIR}/windows-amd64" ;;
    *windows-arm64*) target_dir="${OUT_DIR}/windows-arm64" ;;
    *)
      echo "Unknown asset mapping for ${asset}" >&2
      exit 1
      ;;
  esac

  mkdir -p "${target_dir}"
  if [[ "${bin_path}" == *.exe ]]; then
    install -m 755 "${bin_path}" "${target_dir}/tun2socks.exe"
  else
    install -m 755 "${bin_path}" "${target_dir}/tun2socks"
  fi

done

echo "tun2socks binaries ready in ${OUT_DIR}."
