#!/usr/bin/env python3
"""
coldbrew-mule — Expresso HD auto-unlock orchestrator CLI

Usage:
  coldbrew-mule discover [--subnet CIDR]              # find Expresso HD bikes on the network
  coldbrew-mule run   [options]                       # full 7-stage pipeline
  coldbrew-mule undo  --bike IP                       # restore latest backup via SSH
  coldbrew-mule hid-test [--port DEV]                 # smoke-test the CH9329 dongle
  coldbrew-mule bootstrap --wifi-ssid S --wifi-pass P # open xterm, set WiFi, reset SSH password
  coldbrew-mule type --text "..." [--no-enter]        # type arbitrary text via HID
  coldbrew-mule probe --bike IP                       # run probe.sh and print results

Options:
  --hid-port DEV        CH9329 serial device [default: auto-detect]
  --bike IP             skip stages 0-3, connect directly to this IP
  --wifi-ssid SSID      SSID for the mule's access point
  --wifi-pass PASS      WiFi passphrase
  --mule-ip IP          mule's IP on the bike-network interface [default: 10.42.42.1]
  --no-ai               disable AI-assist on failure
  --dry-run             print what would be done without running unlock.sh
"""

from __future__ import annotations

import argparse
import concurrent.futures
import ipaddress
import json
import socket
import subprocess
import sys
from pathlib import Path

import glob
import platform

import serial

REPO_ROOT = Path(__file__).resolve().parent.parent
HID_SCRIPTS = REPO_ROOT / "mule" / "hid" / "scripts"


def _auto_hid_port() -> str:
    if platform.system() == "Darwin":
        candidates = sorted(glob.glob("/dev/cu.usbserial-*"))
        if candidates:
            return candidates[0]
    return "/dev/ttyUSB2"

# Fingerprint check run over SSH to confirm a host is an Expresso HD bike
_FINGERPRINT_CMD = (
    "test -d /usr/local/expresso && "
    "grep -qi 'ubuntu 12' /etc/lsb-release 2>/dev/null && "
    r"uname -m | grep -q i686 && "
    "echo EXPRESSO_HD"
)


def _is_port_open(ip: str, port: int = 22, timeout: float = 0.5) -> bool:
    try:
        with socket.create_connection((ip, port), timeout=timeout):
            return True
    except OSError:
        return False


def _ssh_fingerprint(ip: str) -> dict | None:
    """Try expresso/expresso SSH; return info dict if it looks like a bike."""
    try:
        result = subprocess.run(
            ["sshpass", "-p", "expresso",
             "ssh", "-o", "StrictHostKeyChecking=no",
             "-o", "ConnectTimeout=4",
             "-o", "BatchMode=no",
             f"expresso@{ip}",
             _FINGERPRINT_CMD],
            capture_output=True, text=True, timeout=8,
        )
        if "EXPRESSO_HD" not in result.stdout:
            return None
        # grab build dir while we're connected
        build = subprocess.run(
            ["sshpass", "-p", "expresso",
             "ssh", "-o", "StrictHostKeyChecking=no", "-o", "ConnectTimeout=4",
             f"expresso@{ip}",
             "ls -1t /usr/local/expresso/ | grep -E '^[0-9]{11}$' | head -1"],
            capture_output=True, text=True, timeout=6,
        ).stdout.strip()
        return {"ip": ip, "build": build or "unknown"}
    except Exception:
        return None


def _get_local_subnets() -> list[str]:
    """Return /24 subnets for all non-loopback IPv4 interfaces (macOS + Linux)."""
    import platform
    import re
    subnets = []
    try:
        if platform.system() == "Darwin":
            out = subprocess.check_output(["ifconfig"], text=True, timeout=3)
            # inet X.X.X.X netmask 0xFFFFFF00  (hex mask)  or  255.255.255.0
            for m in re.finditer(r'inet (\d+\.\d+\.\d+\.\d+)\s+netmask\s+(0x[\da-fA-F]+|\d+\.\d+\.\d+\.\d+)', out):
                addr, mask_raw = m.group(1), m.group(2)
                if addr.startswith("127."):
                    continue
                if mask_raw.startswith("0x"):
                    mask_int = int(mask_raw, 16)
                    mask = str(ipaddress.IPv4Address(mask_int))
                else:
                    mask = mask_raw
                net = ipaddress.IPv4Interface(f"{addr}/{mask}").network.supernet(new_prefix=24)
                subnets.append(str(net))
        else:
            out = subprocess.check_output(["ip", "-4", "-o", "addr"], text=True, timeout=3)
            for line in out.splitlines():
                parts = line.split()
                if len(parts) < 4 or parts[1] == "lo":
                    continue
                net = ipaddress.IPv4Interface(parts[3]).network.supernet(new_prefix=24)
                subnets.append(str(net))
    except Exception:
        pass
    return list(dict.fromkeys(subnets))


def cmd_discover(args: argparse.Namespace) -> int:
    subnets = [args.subnet] if args.subnet else _get_local_subnets()
    if not subnets:
        print("Could not determine local subnets — pass --subnet CIDR", file=sys.stderr)
        return 1

    # Check sshpass is available
    if subprocess.run(["which", "sshpass"], capture_output=True).returncode != 0:
        print("sshpass not found — install it: apt install sshpass / brew install sshpass")
        return 1

    candidates: list[str] = []
    for subnet in subnets:
        net = ipaddress.IPv4Network(subnet, strict=False)
        hosts = [str(h) for h in net.hosts()]
        print(f"Scanning {subnet} ({len(hosts)} hosts) for port 22...")
        with concurrent.futures.ThreadPoolExecutor(max_workers=64) as ex:
            open_hosts = [ip for ip, ok in zip(hosts, ex.map(_is_port_open, hosts)) if ok]
        print(f"  {len(open_hosts)} host(s) with SSH open")
        candidates.extend(open_hosts)

    if not candidates:
        print("No SSH hosts found.")
        return 0

    print(f"Fingerprinting {len(candidates)} candidate(s) as Expresso HD...")
    found: list[dict] = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=16) as ex:
        for result in ex.map(_ssh_fingerprint, candidates):
            if result:
                found.append(result)
                print(f"  FOUND: {result['ip']}  build={result['build']}")

    if not found:
        print("No Expresso HD bikes found.")
        return 0

    print(f"\n{len(found)} bike(s) found. To unlock:")
    for b in found:
        print(f"  python3 mule/cli.py run --bike {b['ip']}")
    return 0


def cmd_run(args: argparse.Namespace) -> int:
    from mule.orchestrator import StageRunner, RunContext

    ctx = RunContext(
        wifi_ssid=args.wifi_ssid or "",
        wifi_pass=args.wifi_pass or "",
        mule_ip=args.mule_ip,
        ai_assist=not args.no_ai,
    )

    if args.hid_port and not args.bike:
        ctx.hid_port = serial.Serial(args.hid_port, baudrate=9600, timeout=1)

    if args.bike:
        # skip HID stages — jump straight to SSH
        ctx.bike_ip = args.bike
        from mule.orchestrator import StageResult
        print(f"Direct SSH mode → {args.bike}")
        runner = StageRunner(ctx)
        runner.ctx.results.append(StageResult(0, "enumerate", True, "skipped"))
        runner.ctx.results.append(StageResult(1, "open_xterm", True, "skipped"))
        runner.ctx.results.append(StageResult(2, "network", True, "skipped"))
        runner.ctx.results.append(StageResult(3, "ssh_handoff", True, output=args.bike))
        ok = True
        for fn in [runner._stage4_probe_backup, runner._stage5_unlock,
                   runner._stage6_verify, runner._stage7_results]:
            try:
                fn()
                runner.ctx.results.append(StageResult(len(runner.ctx.results), fn.__name__, True))
            except Exception as exc:
                print(f"FAIL: {exc}")
                if ctx.ai_assist:
                    runner._ai_intervene(len(runner.ctx.results), fn.__name__, exc)
                ok = False
                break
        return 0 if ok else 1

    runner = StageRunner(ctx)
    ok = runner.run()
    return 0 if ok else 1


def cmd_undo(args: argparse.Namespace) -> int:
    if not args.bike:
        print("--bike IP required", file=sys.stderr)
        return 1
    ip = args.bike
    # find latest backup on the bike
    result = subprocess.run(
        ["sshpass", "-p", "expresso",
         "ssh", "-o", "StrictHostKeyChecking=no",
         "-o", "PreferredAuthentications=password", "-o", "PubkeyAuthentication=no",
         f"expresso@{ip}",
         "ls -t /home/expresso/coldbrew_backup_*.tgz 2>/dev/null | head -1"],
        capture_output=True, text=True,
    )
    backup = result.stdout.strip()
    if not backup:
        result = subprocess.run(
            ["sshpass", "-p", "expresso",
             "ssh", "-o", "StrictHostKeyChecking=no",
             "-o", "PreferredAuthentications=password", "-o", "PubkeyAuthentication=no",
             f"expresso@{ip}",
             "ls -dt /home/expresso/coldbrew_backups/* 2>/dev/null | head -1"],
            capture_output=True, text=True,
        )
        backup = result.stdout.strip()
    if not backup:
        print("No backup found on bike", file=sys.stderr)
        return 1
    print(f"Restoring from {backup}")
    undo_script = REPO_ROOT / "payload" / "recover-coldbrew.sh"
    subprocess.run(
        ["sshpass", "-p", "expresso",
         "scp", "-o", "StrictHostKeyChecking=no",
         "-o", "PreferredAuthentications=password", "-o", "PubkeyAuthentication=no",
         str(undo_script), f"expresso@{ip}:/tmp/coldbrew_undo.sh"],
        check=True,
    )
    subprocess.run(
        ["sshpass", "-p", "expresso",
         "ssh", "-o", "StrictHostKeyChecking=no",
         "-o", "PreferredAuthentications=password", "-o", "PubkeyAuthentication=no",
         f"expresso@{ip}", f"sudo bash /tmp/coldbrew_undo.sh {backup}"],
        check=True,
    )
    return 0


def cmd_hid_test(args: argparse.Namespace) -> int:
    from mule.hid import ch9329
    import time
    port_path = args.port or _auto_hid_port()
    print(f"Opening {port_path}...")
    port = ch9329.open_port(port_path)
    print("Sending Alt+F2...")
    ch9329.alt_f2(port)
    time.sleep(1.2)
    print("Typing 'xterm'...")
    ch9329.type_string(port, "xterm")
    ch9329.press_enter(port)
    print("Done — check bike screen for xterm window.")
    port.close()
    return 0


def cmd_bootstrap(args: argparse.Namespace) -> int:
    if not args.wifi_ssid:
        print("--wifi-ssid required", file=sys.stderr)
        return 1
    from mule.hid import ch9329
    from mule.orchestrator import _run_hid_script
    port_path = args.port or _auto_hid_port()
    new_pass = args.new_passwd or "expresso"
    print(f"Bootstrap via {port_path}")
    print(f"  WiFi SSID : {args.wifi_ssid}")
    print(f"  New passwd: {'(same as current)' if new_pass == 'expresso' else '(custom)'}")
    port = ch9329.open_port(port_path)
    script = (HID_SCRIPTS / "bootstrap.txt").read_text()
    subs = {"SSID": args.wifi_ssid, "PASS": args.wifi_pass or "", "NEW_PASS": new_pass}
    _run_hid_script(port, script, subs)
    port.close()
    print("\nDone. Give it ~30s then: ssh expresso@<bike-ip>")
    return 0


def cmd_type(args: argparse.Namespace) -> int:
    from mule.hid import ch9329
    port_path = args.port or _auto_hid_port()
    port = ch9329.open_port(port_path)
    ch9329.type_string(port, args.text)
    if not args.no_enter:
        ch9329.press_enter(port)
    port.close()
    return 0


def cmd_probe(args: argparse.Namespace) -> int:
    if not args.bike:
        print("--bike IP required", file=sys.stderr)
        return 1
    probe_sh = REPO_ROOT / "compat" / "probe.sh"
    import tempfile, os
    with tempfile.NamedTemporaryFile(suffix=".sh", delete=False) as f:
        f.write(probe_sh.read_bytes())
        tmp = f.name
    try:
        subprocess.run(
            ["scp", "-o", "StrictHostKeyChecking=no", tmp, f"expresso@{args.bike}:/tmp/coldbrew_probe.sh"],
            check=True, capture_output=True,
        )
        result = subprocess.run(
            ["ssh", "-o", "StrictHostKeyChecking=no",
             f"expresso@{args.bike}", "bash /tmp/coldbrew_probe.sh"],
            capture_output=True, text=True, check=True,
        )
        data = json.loads(result.stdout)
        print(json.dumps(data, indent=2))
    finally:
        os.unlink(tmp)
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(prog="coldbrew-mule", description=__doc__)
    parser.add_argument("--hid-port", default=None, help=f"CH9329 serial device [default: auto-detect, currently {_auto_hid_port()}]")
    parser.add_argument("--bike")
    parser.add_argument("--wifi-ssid")
    parser.add_argument("--wifi-pass", default="")
    parser.add_argument("--mule-ip", default="10.42.42.1")
    parser.add_argument("--no-ai", action="store_true")
    parser.add_argument("--dry-run", action="store_true")

    sub = parser.add_subparsers(dest="command")
    sub.add_parser("run")
    sub.add_parser("undo")

    hid_test_p = sub.add_parser("hid-test")
    hid_test_p.add_argument("--port", help="serial device override")

    bootstrap_p = sub.add_parser("bootstrap", help="open xterm, set WiFi, reset SSH password")
    bootstrap_p.add_argument("--wifi-ssid", required=True)
    bootstrap_p.add_argument("--wifi-pass", default="")
    bootstrap_p.add_argument("--new-passwd", default="expresso", help="new expresso user password [default: expresso]")
    bootstrap_p.add_argument("--port", help="serial device override")

    type_p = sub.add_parser("type", help="type arbitrary text via HID keyboard")
    type_p.add_argument("--text", required=True, help="text to type")
    type_p.add_argument("--no-enter", action="store_true", help="don't press Enter after typing")
    type_p.add_argument("--port", help="serial device override")

    sub.add_parser("probe")
    discover_p = sub.add_parser("discover")
    discover_p.add_argument("--subnet", help="CIDR to scan, e.g. 192.168.1.0/24 (default: all local /24s)")

    args = parser.parse_args()

    dispatch = {
        "run": cmd_run,
        "undo": cmd_undo,
        "hid-test": cmd_hid_test,
        "bootstrap": cmd_bootstrap,
        "type": cmd_type,
        "probe": cmd_probe,
        "discover": cmd_discover,
        None: lambda a: (parser.print_help(), 1)[1],
    }
    return dispatch.get(args.command, dispatch[None])(args)


if __name__ == "__main__":
    sys.exit(main())
