#!/bin/bash
# Bring wlan0 up manually. Mirrors what we do at boot in rc.local.
# Uses /etc/wpa_supplicant/wpa_supplicant.conf (plaintext psk format).
set -e

CONF=/etc/wpa_supplicant/wpa_supplicant.conf
[[ -f "$CONF" ]] || { echo "missing $CONF — run bike-wifi-setup.sh first"; exit 1; }

sudo pkill -f 'wpa_supplicant.*wlan0' 2>/dev/null || true
sudo pkill -f 'dhclient.*wlan0'        2>/dev/null || true
sleep 1

# No -D driver hint: wpa_supplicant auto-selects. Ralink RT3290 is fiddly
# with 'nl80211,wext' combo; letting it auto-detect matches what works
# interactively.
sudo wpa_supplicant -B -i wlan0 -c "$CONF" -P /var/run/wpa_supplicant.wlan0.pid
sleep 3
sudo dhclient wlan0
ip addr show wlan0 | grep 'inet '
