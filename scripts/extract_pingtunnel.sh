#!/usr/bin/env bash
set -euo pipefail

SRC_DIR="${1:-/home/moe/Projects/pingtunnel/cmd/pack}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${ROOT_DIR}/templates/assets/binaries/pingtunnel"
TMP_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

mkdir -p "${OUT_DIR}"

ZIPS=(
  "pingtunnel_darwin_amd64.zip"
  "pingtunnel_darwin_arm64.zip"
  "pingtunnel_linux_amd64.zip"
  "pingtunnel_windows_amd64.zip"
  "pingtunnel_windows_arm64.zip"
)

for zip in "${ZIPS[@]}"; do
  src="${SRC_DIR}/${zip}"
  if [[ ! -f "${src}" ]]; then
    echo "Skipping missing ${src}" >&2
    continue
  fi

  extract_dir="${TMP_DIR}/extract-${zip%.zip}"
  mkdir -p "${extract_dir}"
  unzip -q "${src}" -d "${extract_dir}"

  bin_path="$(find "${extract_dir}" -type f -maxdepth 2 -name "pingtunnel*" | head -n 1)"
  if [[ -z "${bin_path}" ]]; then
    echo "Failed to locate pingtunnel binary in ${zip}" >&2
    exit 1
  fi

  case "${zip}" in
    *darwin_amd64*) target_dir="${OUT_DIR}/darwin-amd64" ;;
    *darwin_arm64*) target_dir="${OUT_DIR}/darwin-arm64" ;;
    *linux_amd64*) target_dir="${OUT_DIR}/linux-amd64" ;;
    *windows_amd64*) target_dir="${OUT_DIR}/windows-amd64" ;;
    *windows_arm64*) target_dir="${OUT_DIR}/windows-arm64" ;;
    *)
      echo "Unknown zip mapping for ${zip}" >&2
      exit 1
      ;;
  esac

  mkdir -p "${target_dir}"
  if [[ "${bin_path}" == *.exe ]]; then
    install -m 755 "${bin_path}" "${target_dir}/pingtunnel.exe"
  else
    install -m 755 "${bin_path}" "${target_dir}/pingtunnel"
  fi

done

echo "pingtunnel binaries ready in ${OUT_DIR}."
