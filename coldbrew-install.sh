#!/usr/bin/env bash
# Push payload to a bike over SSH and run the backup-first coldbrew installer.
# Safe by default: dry-run unless --live is passed through.

set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
TARGET="${BIKE_TARGET:-}"
REMOTE_PAYLOAD_DIR="/tmp/coldbrew_payload"
INSTALL_ARGS=()

usage() {
  cat <<'EOF'
Usage:
  ./coldbrew-install.sh --target expresso@IP [installer options]
  ./coldbrew-install.sh --target bike --live --with-hosts-block --with-watchdog

Options:
  --target HOST    SSH target (required unless BIKE_TARGET is set)
  Anything else is passed through to payload/install-coldbrew.sh

Examples:
  ./coldbrew-install.sh --target expresso@192.168.1.100
  ./coldbrew-install.sh --target bike --live --with-branding --with-hosts-block
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --target)
      TARGET="${2:?missing value for --target}"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      INSTALL_ARGS+=("$1")
      ;;
  esac
  shift
done

[ -n "$TARGET" ] || { usage >&2; exit 1; }

rsync -az --delete -e "ssh -o StrictHostKeyChecking=no" \
  "$REPO/payload/" "$TARGET:$REMOTE_PAYLOAD_DIR/"

REMOTE_CMD=(sudo bash "$REMOTE_PAYLOAD_DIR/install-coldbrew.sh")
REMOTE_CMD+=("${INSTALL_ARGS[@]}")

ssh -o StrictHostKeyChecking=no "$TARGET" \
  "$(printf '%q ' "${REMOTE_CMD[@]}")"
