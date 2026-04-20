#!/bin/bash
# Run on the bike over SSH. Emits a JSON blob describing the build environment.
# Used by the mule orchestrator to select a compat profile and validate before patching.

set -euo pipefail

EXPRESSO_ROOT="/usr/local/expresso"
CONF="$EXPRESSO_ROOT/conf/ef_global.conf"

BUILD_DIR=$(ls -1t "$EXPRESSO_ROOT" 2>/dev/null | grep -E '^[0-9]{11}$' | head -1 || echo "")
if [ -z "$BUILD_DIR" ]; then
  echo '{"error":"no build dir found under /usr/local/expresso"}' >&2
  exit 1
fi

BASE="$EXPRESSO_ROOT/$BUILD_DIR"
WORLDS=$(ls "$BASE/ME_Assets/Worlds/" 2>/dev/null | tr '\n' ',' | sed 's/,$//' || echo "")
INCA_VER=$(cat "$BASE/bin/incaversion.txt" 2>/dev/null || echo "unknown")
SERIAL=$(grep -i 'SerialNumber' "$CONF" 2>/dev/null | cut -d= -f2 | tr -d ' \r' || echo "unknown")
SUBSCRIPTION=$(grep -i 'BikeSubscription' "$CONF" 2>/dev/null | cut -d= -f2 | tr -d ' \r' || echo "unknown")

GF="$BASE/ME_Assets/Scripts/GlobalFunctions.lua"
GF_PATCHED="false"
grep -q 'coldbrew:route-unlock' "$GF" 2>/dev/null && GF_PATCHED="true" || true

# Only scan .lua files — UPK/PAK binaries make grep hang for minutes
BRONZE_COUNT=$(grep -rl --include='*.lua' 'LEVEL_AVAILABILITY_BRONZE' "$BASE/ME_Assets/Worlds/" 2>/dev/null | wc -l | tr -d ' ') || BRONZE_COUNT=0

# Read MySQL maintenance credentials from debian.cnf (avoids auth timeout)
MYSQL_CREDS=""
if sudo -n test -f /etc/mysql/debian.cnf 2>/dev/null; then
  _U=$(sudo -n cat /etc/mysql/debian.cnf | awk -F'= *' '/^user/{print $2; exit}' | tr -d ' ')
  _P=$(sudo -n cat /etc/mysql/debian.cnf | awk -F'= *' '/^password/{print $2; exit}' | tr -d ' ')
  MYSQL_CREDS="-u${_U} -p${_P}"
fi
DB_SCHEMA=$(mysql expresso_station $MYSQL_CREDS -Ne "DESCRIBE inca_requests;" 2>/dev/null \
  | awk '{print $1}' | tr '\n' ',' | sed 's/,$//' || echo "unknown")

cat <<EOF
{
  "build": "$BUILD_DIR",
  "inca_ver": "$INCA_VER",
  "serial": "$SERIAL",
  "bike_subscription": "$SUBSCRIPTION",
  "worlds": "$WORLDS",
  "gf_patched": $GF_PATCHED,
  "bronze_worlds_remaining": $BRONZE_COUNT,
  "inca_requests_schema": "$DB_SCHEMA"
}
EOF
