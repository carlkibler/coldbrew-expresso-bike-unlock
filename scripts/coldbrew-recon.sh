#!/bin/bash
# Coldbrew Recon Script
# Run from console or via USB on the Expresso HD (Ubuntu 12.04)
# Collects system data and optionally sets up WiFi
# Usage: ./coldbrew-recon.sh [--wifi SSID PASSWORD] [--live]

set -e
OUTFILE="/home/expresso/coldbrew_$(date +%Y%m%d_%H%M%S).txt"
DRY=true
WIFI_SSID=""
WIFI_PASS=""

for arg in "$@"; do
  case $arg in
    --live) DRY=false ;;
    --wifi) shift; WIFI_SSID="$1"; shift; WIFI_PASS="$1" ;;
  esac
done

log() { echo "=== $1 ===" | tee -a "$OUTFILE"; }
run() { echo "$ $*" >> "$OUTFILE"; eval "$@" 2>&1 | tee -a "$OUTFILE"; echo >> "$OUTFILE"; }

echo "Coldbrew Recon - $(date)" | tee "$OUTFILE"
echo "Dry run: $DRY" | tee -a "$OUTFILE"
echo "" >> "$OUTFILE"

# --- System ---
log "IDENTITY"
run id
run uname -a
run cat /etc/lsb-release

log "NETWORK"
run ip addr
run ip route
run iwconfig

log "SERIAL DEVICES"
run ls -la /dev/ttyUSB* /dev/ttyS0 /dev/ttyS1
run lsusb
run "dmesg | grep -i 'ttyUSB\|usb.*serial\|atmel\|ftdi' | tail -20"

log "APP"
run ls /usr/local/expresso/
run cat /usr/local/expresso/conf/ef_global.conf
run "ls /usr/local/expresso/20180514001/bin/"
run cat /usr/local/expresso/20180514001/bin/incaversion.txt
run "ps aux | grep -E 'Inca|Dispenser|Launcher'"

log "LOGS"
run "tail -100 /usr/local/expresso/log/system.log"
run "tail -50 /usr/local/expresso/log/RideSummaryLog.txt"

log "AUTOSTART"
run "cat /etc/rc.local 2>/dev/null || true"
run "ls /home/expresso/.config/autostart/ 2>/dev/null || true"
run "ls /etc/init/*.conf | xargs grep -l expresso 2>/dev/null || true"

# --- WiFi setup (--live only) ---
if [ -n "$WIFI_SSID" ] && [ "$DRY" = "false" ]; then
  log "WIFI SETUP"
  echo "Configuring WiFi: $WIFI_SSID"
  sudo service network-manager stop 2>&1 | tee -a "$OUTFILE"
  sudo ifconfig wlan0 up 2>&1 | tee -a "$OUTFILE"
  wpa_passphrase "$WIFI_SSID" "$WIFI_PASS" | sudo tee /etc/wpa_supplicant/coldbrew.conf > /dev/null
  sudo wpa_supplicant -B -i wlan0 -c /etc/wpa_supplicant/coldbrew.conf 2>&1 | tee -a "$OUTFILE"
  sleep 4
  sudo dhclient wlan0 2>&1 | tee -a "$OUTFILE"
  run ip addr show wlan0
fi

# --- Serial capture (20 seconds, bike must be pedaled) ---
log "SERIAL CAPTURE (20s - pedal the bike!)"
if command -v strace > /dev/null; then
  INCA_PID=$(pgrep Inca | head -1)
  if [ -n "$INCA_PID" ]; then
    echo "Capturing from Inca PID $INCA_PID for 20s..." | tee -a "$OUTFILE"
    timeout 20 sudo strace -p "$INCA_PID" -f -e trace=read,write -xx -s 256 2>&1 \
      | grep -E '(read|write)\(2[01],' >> "$OUTFILE" || true
  fi
fi

echo "" >> "$OUTFILE"
echo "Recon complete: $OUTFILE"
