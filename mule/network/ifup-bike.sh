#!/bin/bash
# Bring up the mule's dedicated bike network interface and start dnsmasq.
# Run this BEFORE inserting the CH9329 dongle.
# Usage: sudo ./ifup-bike.sh [IFACE]
#
# Linux:  rename your USB-eth adapter first: ip link set <name> name eth-bike
# macOS:  pass the interface name as shown in `ifconfig` (e.g. en5, en6)

set -euo pipefail

IFACE="${1:-eth-bike}"
MULE_IP="10.42.42.1"
CONF="$(dirname "$0")/dnsmasq-bike.conf"
OS="$(uname -s)"

# Bring up interface with static IP
if [[ "$OS" == "Darwin" ]]; then
    ifconfig "$IFACE" "$MULE_IP" netmask 255.255.255.0 up
else
    ip link set "$IFACE" up
    ip addr replace "${MULE_IP}/24" dev "$IFACE"
fi
echo "Interface $IFACE up at $MULE_IP"

# Kill any stale dnsmasq on this interface
pkill -f "dnsmasq.*$IFACE" 2>/dev/null || true

# Sub in the actual interface name
TMPCONF=$(mktemp)
sed "s/^interface=.*/interface=$IFACE/" "$CONF" > "$TMPCONF"

if [[ "$OS" == "Darwin" ]]; then
    # macOS dnsmasq (via brew) doesn't use --pid-file the same way
    dnsmasq -C "$TMPCONF" &
    echo "dnsmasq started"
else
    dnsmasq -C "$TMPCONF" --pid-file=/tmp/dnsmasq-bike.pid &
    echo "dnsmasq started (PID $(cat /tmp/dnsmasq-bike.pid 2>/dev/null || echo '?'))"
fi
