#!/bin/bash
# Build and run the coldbrew-mule container.
# Usage: ./docker-run.sh [discover|run|probe|hid-test|undo] [args...]
#
# Examples:
#   ./docker-run.sh discover --subnet 192.168.1.0/24
#   ./docker-run.sh run --bike 192.168.1.100
#   ./docker-run.sh probe --bike 192.168.1.100
#   ./docker-run.sh hid-test --port /dev/ttyUSB2
#
# Environment variables:
#   ANTHROPIC_API_KEY  required for AI-assist (--no-ai skips it)
#   HID_PORT           CH9329 serial device on the host [default: /dev/ttyUSB2]
#   WIFI_SSID / WIFI_PASS   for WiFi bootstrap path

set -euo pipefail

IMAGE="coldbrew-mule"
HID_PORT="${HID_PORT:-/dev/ttyUSB2}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Build if image doesn't exist or Dockerfile is newer
if ! docker image inspect "$IMAGE" &>/dev/null || \
   [ "$SCRIPT_DIR/Dockerfile" -nt <(docker image inspect "$IMAGE" --format '{{.Metadata.LastTagTime}}' 2>/dev/null || echo "") ]; then
    echo "Building $IMAGE..."
    docker build -t "$IMAGE" "$SCRIPT_DIR"
fi

# Detect if HID port exists (skip --device if not; allows running on machines without CH9329)
DEVICE_FLAGS=()
if [ -e "$HID_PORT" ]; then
    DEVICE_FLAGS=(--device "$HID_PORT:$HID_PORT")
fi

# --network host: on Linux gives full LAN access for discovery
# On macOS Docker Desktop, host networking shares the VM's interface — use --subnet
# for discovery on macOS, or run `python3 mule/cli.py` directly instead.
NETWORK_MODE="host"
if [[ "$(uname)" == "Darwin" ]]; then
    NETWORK_MODE="bridge"
    if [[ "${1:-}" == "discover" ]] && [[ "$*" != *"--subnet"* ]]; then
        echo "NOTE: On macOS, Docker uses bridge networking — auto-subnet detection"
        echo "      may not see your LAN. Pass --subnet 192.168.x.0/24 explicitly,"
        echo "      or run directly: python3 mule/cli.py discover"
    fi
fi

docker run --rm -it \
    --network "$NETWORK_MODE" \
    "${DEVICE_FLAGS[@]}" \
    -e ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}" \
    -v "$SCRIPT_DIR/backups:/app/backups" \
    -v "$SCRIPT_DIR/results:/app/results" \
    "$IMAGE" "$@"
