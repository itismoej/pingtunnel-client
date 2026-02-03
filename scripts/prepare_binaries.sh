#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

"${ROOT_DIR}/scripts/extract_pingtunnel.sh" "${1:-/home/moe/Projects/pingtunnel/cmd/pack}"
"${ROOT_DIR}/scripts/fetch_tun2socks.sh"

