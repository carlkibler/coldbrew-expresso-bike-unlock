#!/bin/bash
# standalone-inca-test.sh
#
# Test-runs a *staged* Inca binary under X without flipping the live CLUtil
# version, without starting Dispenser, without touching conf/. Useful when
# sideloading a newer build onto an older-hardware bike: answers "does this
# Inca even create a GL context on this GPU/driver?" before you commit to
# a full version flip.
#
# Setup:
#   - Rsync a newer build tree to /usr/local/expresso/<BUILD>.staging/
#     (the `.staging` suffix keeps version auto-detectors from picking it up)
#   - Edit STAGING below to point at your staging dir.
#
# The script kills the current Launcher/Dispenser/Inca for the test run, then
# restarts Launcher at the end — so the bike returns to a working state no
# matter whether the staged binary succeeds.
#
# Run ON the bike (xterm or SSH):
#     bash /tmp/standalone-inca-test.sh
#
# Exit codes:
#   0  test completed (does not imply 2018 works — read /tmp/inca2018-standalone.log)
#   2  staging dir missing
#   3  2018 Inca binary missing or not executable
set -u  # intentionally not -e: we want cleanup to run even on test failure

STAGING=/usr/local/expresso/20180514001.staging
INCA="$STAGING/bin/Inca"
LOG=/tmp/inca2018-standalone.log
CORE_DIR=/tmp/inca2018-cores
DRY_RUN=${DRY_RUN:-0}   # DRY_RUN=1 skips the actual run, prints what would happen

echo "=== Pre-flight ==="
if [[ ! -d $STAGING ]]; then
    echo "FATAL: $STAGING does not exist. Run Phase C (rsync to .staging) first." >&2
    exit 2
fi
if [[ ! -x $INCA ]]; then
    echo "FATAL: $INCA missing or not executable." >&2
    ls -la "$STAGING/bin/" >&2 | head -5
    exit 3
fi

echo "CLUtil version: $(/usr/local/expresso/bin/CLUtil -p --configuration GetVersion)"
echo "Running Inca: $INCA"
ls -la "$INCA"

echo
echo "=== Snapshotting current process state ==="
ps -eo user,pid,cmd | grep -iE "Launcher|Dispenser|/Inca" | grep -v grep > /tmp/inca2018-prestate.txt
cat /tmp/inca2018-prestate.txt

if [[ $DRY_RUN == 1 ]]; then
    echo
    echo "(DRY_RUN=1; would kill the 2013 processes, run Inca standalone, then restart Launcher.)"
    exit 0
fi

echo
echo "=== Stopping 2013 Launcher/Dispenser/Inca (keeping Xorg) ==="
# Kill child-to-parent so Launcher doesn't spawn replacements mid-kill.
sudo pkill -9 -f '/bin/Inca'      || true
sudo pkill -9 -f '/bin/Dispenser' || true
sudo pkill -9 -f '/bin/Launcher'  || true
sleep 2
ps -eo user,pid,cmd | grep -iE "Launcher|Dispenser|/Inca" | grep -v grep || echo "(all stopped)"

echo
echo "=== Running 2018 Inca standalone ==="
mkdir -p "$CORE_DIR"
cd "$STAGING" || { echo "cd failed"; exit 3; }

# env -i intentionally: we want to isolate any stray shell vars that 2013
# startup might have set (EXPRESSO_*, DISPENSER_*, etc). We re-introduce
# only what's needed for GL/X + debugging.
set +u
env -i \
    HOME=/home/expresso \
    USER=expresso \
    LOGNAME=expresso \
    DISPLAY=:0 \
    XAUTHORITY=/home/expresso/.Xauthority \
    LIBGL_DEBUG=verbose \
    LD_LIBRARY_PATH="$STAGING/lib:$STAGING/bin" \
    PATH=/usr/local/bin:/usr/bin:/bin \
    bash -c "ulimit -c unlimited; cd '$STAGING' && ./bin/Inca" \
    > "$LOG" 2>&1 &
INCA_PID=$!
set -u

echo "Inca PID=$INCA_PID — capturing 60s of output or until it exits..."
# Wait up to 60s.  If it lives past 60s, kill and declare "GL init OK, needs Dispenser".
for i in $(seq 1 60); do
    if ! kill -0 "$INCA_PID" 2>/dev/null; then
        echo "Inca exited after ${i}s"
        break
    fi
    sleep 1
done

# Clean shutdown
if kill -0 "$INCA_PID" 2>/dev/null; then
    echo "Inca still alive at 60s — sending SIGTERM (this suggests GL init succeeded)"
    kill -TERM "$INCA_PID" 2>/dev/null
    sleep 3
    kill -KILL "$INCA_PID" 2>/dev/null || true
fi

wait "$INCA_PID" 2>/dev/null || true
EXIT=$?

echo
echo "=== Inca exit status: $EXIT ==="
echo
echo "=== Log tail (last 40 lines) ==="
tail -40 "$LOG" 2>&1

echo
echo "=== Restarting Launcher (should restore bike to its working state) ==="
# start-launcher.sh execs Launcher; start it from the expresso user, backgrounded.
sudo -u expresso bash -c '/home/expresso/script/start-launcher.sh &'
sleep 3
ps -eo user,pid,cmd | grep -iE "Launcher|Dispenser|/Inca" | grep -v grep || echo "(Launcher not yet respawned — may need a full reboot)"

echo
echo "Standalone test complete. Log: $LOG"
echo "If Inca survived 60s: GL init probably OK. Next step — try with Dispenser running too."
echo "If Inca exited fast: scan $LOG for 'GLX', 'GLSL', 'undefined symbol', or 'Assertion'."
