#!/bin/bash
# playnice.sh — tame Inca's CPU hunger
# Usage: playnice.sh [cpu_limit_%]  default: 60

LIMIT=${1:-60}

pid=$(pgrep -x Inca)
if [ -z "$pid" ]; then
    echo "Inca not running" >&2
    exit 1
fi

# Kill any existing cpulimit on this pid
pkill -f "cpulimit.*-p $pid" 2>/dev/null

# Pin to core 0, lower priority, cap CPU
sudo taskset -p 0x1 "$pid" > /dev/null
sudo renice 19 "$pid" > /dev/null
nohup sudo cpulimit -p "$pid" -l "$LIMIT" -z > /tmp/cpulimit.log 2>&1 &

echo "Inca pid $pid: pinned to core 0, nice 19, CPU cap ${LIMIT}%"
