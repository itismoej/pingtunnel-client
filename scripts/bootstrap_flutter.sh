#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="${ROOT_DIR}/app"

if ! command -v flutter >/dev/null 2>&1; then
  echo "Flutter is not installed. Install Flutter and re-run this script." >&2
  exit 1
fi

if [[ ! -d "${APP_DIR}" ]]; then
  flutter create app \
    --platforms=android,linux,windows,macos \
    --org com.pingtunnel.client
fi

if command -v rsync >/dev/null 2>&1; then
  rsync -a --delete "${ROOT_DIR}/templates/lib/" "${APP_DIR}/lib/"
  rsync -a --delete "${ROOT_DIR}/templates/assets/" "${APP_DIR}/assets/"
else
  rm -rf "${APP_DIR}/lib" "${APP_DIR}/assets"
  mkdir -p "${APP_DIR}"
  cp -a "${ROOT_DIR}/templates/lib" "${APP_DIR}/lib"
  cp -a "${ROOT_DIR}/templates/assets" "${APP_DIR}/assets"
fi

ANDROID_MAIN="${APP_DIR}/android/app/src/main"
if [[ -d "${ANDROID_MAIN}" ]]; then
  mkdir -p "${ANDROID_MAIN}/jniLibs/arm64-v8a"
  if [[ -f "${APP_DIR}/assets/binaries/pingtunnel/android-arm64/pingtunnel" ]]; then
    cp "${APP_DIR}/assets/binaries/pingtunnel/android-arm64/pingtunnel" \
      "${ANDROID_MAIN}/jniLibs/arm64-v8a/libpingtunnel.so"
  fi
  if [[ -f "${APP_DIR}/assets/binaries/tun2socks/android-arm64/tun2socks" ]]; then
    cp "${APP_DIR}/assets/binaries/tun2socks/android-arm64/tun2socks" \
      "${ANDROID_MAIN}/jniLibs/arm64-v8a/libtun2socks.so"
  fi

  if [[ -f "${APP_DIR}/assets/binaries/pingtunnel/android-arm/pingtunnel" ]]; then
    mkdir -p "${ANDROID_MAIN}/jniLibs/armeabi-v7a"
    cp "${APP_DIR}/assets/binaries/pingtunnel/android-arm/pingtunnel" \
      "${ANDROID_MAIN}/jniLibs/armeabi-v7a/libpingtunnel.so"
  fi
  if [[ -f "${APP_DIR}/assets/binaries/tun2socks/android-arm/tun2socks" ]]; then
    mkdir -p "${ANDROID_MAIN}/jniLibs/armeabi-v7a"
    cp "${APP_DIR}/assets/binaries/tun2socks/android-arm/tun2socks" \
      "${ANDROID_MAIN}/jniLibs/armeabi-v7a/libtun2socks.so"
  fi
fi

python - <<PY
from pathlib import Path

pubspec = Path("${APP_DIR}/pubspec.yaml")
text = pubspec.read_text()
lines = text.splitlines()

deps_idx = None
for i, line in enumerate(lines):
    if line.lstrip() == line and line.strip() == "dependencies:":
        deps_idx = i
        break

if deps_idx is None:
    raise SystemExit("pubspec.yaml missing dependencies section")

deps_end = None
for i in range(deps_idx + 1, len(lines)):
    if lines[i].lstrip() == lines[i] and lines[i].strip():
        deps_end = i
        break

deps_slice = lines[deps_idx + 1: deps_end]
if not any(line.strip().startswith("url_launcher:") for line in deps_slice):
    insert_at = deps_end if deps_end is not None else len(lines)
    lines.insert(insert_at, "  url_launcher: ^6.2.4")
    deps_end = deps_end + 1 if deps_end is not None else None

deps_slice = lines[deps_idx + 1: deps_end]
if not any(line.strip().startswith("shared_preferences:") for line in deps_slice):
    insert_at = deps_end if deps_end is not None else len(lines)
    lines.insert(insert_at, "  shared_preferences: ^2.2.3")

flutter_idx = None
for i, line in enumerate(lines):
    if line.lstrip() == line and line.strip() == "flutter:":
        flutter_idx = i
        break

if flutter_idx is None:
    raise SystemExit("pubspec.yaml missing flutter section")

assets_line_idx = None
for i in range(flutter_idx + 1, len(lines)):
    if lines[i].startswith(" ") and lines[i].strip().startswith("assets:"):
        assets_line_idx = i
        break
    if not lines[i].startswith(" ") and i > flutter_idx:
        break

asset_entries = ["    - assets/binaries/", "    - assets/scripts/"]

if assets_line_idx is None:
    insert_at = flutter_idx + 1
    lines.insert(insert_at, "  assets:")
    for entry in reversed(asset_entries):
        lines.insert(insert_at + 1, entry)
else:
    existing = set()
    for line in lines[assets_line_idx + 1:]:
        if not line.startswith("    - "):
            break
        existing.add(line.strip())
    for entry in asset_entries:
        if entry.strip() not in existing:
            lines.insert(assets_line_idx + 1, entry)
            assets_line_idx += 1

pubspec.write_text("\n".join(lines) + "\n")
PY

echo "Flutter app bootstrapped in ${APP_DIR}."
