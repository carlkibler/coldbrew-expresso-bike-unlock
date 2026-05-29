#!/usr/bin/env python3
"""
bootstrap-from-keyboard.py — Onboard an unconfigured Expresso HD bike via CH9329 USB keyboard.

Detects your Mac's current WiFi, pulls the password from Keychain, then drives
the bike's keyboard input to open an xterm, configure WiFi, and reset the SSH
password — all without touching the bike physically.
"""

import getpass
import glob
import json
import subprocess
import sys
import time
from pathlib import Path

REPO_ROOT  = Path(__file__).resolve().parent
CREDS_FILE = Path("/tmp/coldbrew_bootstrap_creds.json")
NEW_PASSWD = "expresso"   # reset expresso user to this; change if desired


# ── WiFi detection ────────────────────────────────────────────────────────────

def current_ssid() -> str | None:
    r = subprocess.run(["networksetup", "-getairportnetwork", "en0"],
                       capture_output=True, text=True)
    if "You are not associated" in r.stdout or r.returncode != 0:
        return None
    parts = r.stdout.strip().split(": ", 1)
    return parts[1].strip() if len(parts) == 2 else None


def preferred_networks() -> list[str]:
    r = subprocess.run(["networksetup", "-listpreferredwirelessnetworks", "en0"],
                       capture_output=True, text=True)
    lines = r.stdout.strip().splitlines()
    return [l.strip() for l in lines[1:] if l.strip()]


def keychain_password(ssid: str) -> str | None:
    r = subprocess.run(
        ["security", "find-generic-password",
         "-D", "AirPort network password", "-a", ssid, "-w"],
        capture_output=True, text=True,
    )
    return r.stdout.strip() if r.returncode == 0 and r.stdout.strip() else None


def auto_hid_port() -> str:
    candidates = sorted(glob.glob("/dev/cu.usbserial-*"))
    return candidates[0] if candidates else "/dev/ttyUSB2"


# ── UI helpers ────────────────────────────────────────────────────────────────

def ask(prompt: str, default: str = "") -> str:
    suffix = f" [{default}]" if default else ""
    val = input(f"{prompt}{suffix}: ").strip()
    return val or default


def banner(text: str) -> None:
    print(f"\n{'─' * 60}")
    print(f"  {text}")
    print(f"{'─' * 60}")


# ── Main ──────────────────────────────────────────────────────────────────────

def main() -> int:
    banner("Coldbrew keyboard bootstrap")

    # ── Detect HID port ──────────────────────────────────────────────────────
    hid_port = auto_hid_port()
    if not glob.glob("/dev/cu.usbserial-*"):
        print(f"\n  ✖  No CH9329 serial port found (expected /dev/cu.usbserial-*)")
        print("     Plug in the CH9329 dongle and try again.")
        return 1
    print(f"\n  CH9329 port : {hid_port}")

    # ── Detect WiFi ──────────────────────────────────────────────────────────
    print("\n  Detecting WiFi...")
    ssid = current_ssid()
    password = None

    if ssid:
        print(f"  Current SSID: {ssid}")
        password = keychain_password(ssid)
        if password:
            print(f"  Password     : pulled from Keychain ✓")
        else:
            print(f"  Password     : not in Keychain — will prompt")
    else:
        print("  Not currently on WiFi. Known networks:")
        known = preferred_networks()
        for i, n in enumerate(known[:8], 1):
            print(f"    {i}) {n}")
        choice = ask("\n  Pick a network (number or name)", default=known[0] if known else "")
        if choice.isdigit():
            idx = int(choice) - 1
            ssid = known[idx] if 0 <= idx < len(known) else choice
        else:
            ssid = choice
        print(f"\n  Trying Keychain for '{ssid}'...")
        password = keychain_password(ssid)
        if password:
            print(f"  Password     : pulled from Keychain ✓")
        else:
            print(f"  Password     : not in Keychain — will prompt")

    if not ssid:
        ssid = ask("  SSID")

    if not password:
        password = getpass.getpass(f"  WiFi password for '{ssid}': ")

    # ── Confirm ──────────────────────────────────────────────────────────────
    banner("Confirm settings")
    print(f"  WiFi SSID      : {ssid}")
    print(f"  WiFi password  : {'*' * len(password)} ({len(password)} chars)")
    print(f"  New SSH passwd : {NEW_PASSWD}  (expresso user)")
    print(f"  HID port       : {hid_port}")

    yn = input("\n  Proceed? [Y/n]: ").strip().lower()
    if yn == "n":
        print("  Aborted.")
        return 0

    # ── Save creds ───────────────────────────────────────────────────────────
    creds = {"ssid": ssid, "password": password, "new_passwd": NEW_PASSWD,
             "hid_port": hid_port}
    CREDS_FILE.write_text(json.dumps(creds, indent=2))
    print(f"\n  Creds saved to {CREDS_FILE}  (usable by SSH bootstrap too)")

    # ── What to watch for ────────────────────────────────────────────────────
    banner("Starting — watch the bike screen")
    print("""
  1. GNOME run dialog appears     (Alt+F2)
  2. 'xterm' typed and launched
  3. WiFi setup command executes  — takes ~20s for NetworkManager
  4. expresso password is reset
  5. Script prints the bike's new IP when done

  If the run dialog doesn't appear: bike may need focus — press a key on
  a physical keyboard first, then re-run this script.
""")

    # ── Execute ───────────────────────────────────────────────────────────────
    sys.path.insert(0, str(REPO_ROOT))
    try:
        from mule.hid import ch9329
        from mule.orchestrator import _run_hid_script
    except ImportError:
        print("  ✖  Could not import mule — run via: .venv/bin/python3 bootstrap-from-keyboard.py")
        return 1

    port = ch9329.open_port(hid_port)

    hid_script = f"""
ALT_F2
WAIT 1500
TYPE xterm
WAIT 2500
TYPE SSID={ssid} PSK={password} bash ~/script/start-wireless-networking.sh
WAIT 22000
TYPE echo 'expresso:{NEW_PASSWD}' | sudo chpasswd && echo PASSWD_OK
WAIT 1500
TYPE ip -4 addr show wlan0 | grep inet
"""

    _run_hid_script(port, hid_script, {})
    port.close()

    print("\n  Bootstrap commands sent.")
    print("  Watch the xterm for the wlan0 IP address, then:")
    print(f"    ssh expresso@<bike-ip>   (password: {NEW_PASSWD})\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
