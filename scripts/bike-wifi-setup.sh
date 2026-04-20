#!/bin/bash
# Configure WiFi on an Expresso HD bike via the native Expresso mechanism.
#
# The HD stock setup is surprisingly clean:
#   1. ef_global.conf holds WirelessSSID / WirelessPassword
#   2. ~/script/start-wireless-networking.sh reads those via CLUtil
#   3. It invokes ~/script/add-wireless-connection which writes an
#      /etc/NetworkManager/system-connections/<SSID> file and restarts nmcli
#
# So to point a bike at a new access point you just:
#   - edit the two conf values
#   - run the starter script
#
# This is the preferred path. We only fell back to replacing network-manager
# with wpa_supplicant on bike 1 because we didn't yet know about this flow.
#
# Usage (run ON the bike, as the expresso user):
#   bike-wifi-setup.sh                     # prompts for SSID/PSK
#   SSID=Foo PSK=bar bike-wifi-setup.sh    # non-interactive

set -euo pipefail

CONF=/usr/local/expresso/conf/ef_global.conf
STARTER="$HOME/script/start-wireless-networking.sh"

SSID="${SSID:-}"
PSK="${PSK:-}"

[ -f "$CONF" ]     || { echo "Missing $CONF — not an Expresso bike?" >&2; exit 1; }
[ -x "$STARTER" ]  || { echo "Missing $STARTER" >&2; exit 1; }

[ -z "$SSID" ] && read -r -p "SSID: " SSID
[ -z "$PSK"  ] && read -r -s -p "PSK:  " PSK && echo

cp "$CONF" "$CONF.bak-$(date +%Y%m%d_%H%M%S)"

update_key() {
  local key="$1" value="$2"
  if grep -q "^$key " "$CONF"; then
    sed -i "s|^$key = .*|$key = $value|" "$CONF"
  else
    echo "$key = $value" >> "$CONF"
  fi
}
update_key WirelessSSID "$SSID"
update_key WirelessPassword "$PSK"

bash "$STARTER"

sleep 5
if ip addr show wlan0 2>/dev/null | grep -q 'inet '; then
  ip addr show wlan0 | grep 'inet '
  echo "WiFi configured via ef_global.conf + NetworkManager."
else
  echo "wlan0 has no IP yet. Give it a minute, or check 'nmcli dev status' and /etc/NetworkManager/system-connections/." >&2
  exit 2
fi
