"""
Coldbrew mule orchestrator — drives the 7-stage unlock pipeline.

Stages:
  0  enumerate CH9329 serial port
  1  HID: open xterm on bike (Alt+F2 → xterm)
  2  HID: bootstrap network (WiFi preferred, Ethernet fallback)
  3  SSH handoff — wait for bike IP on port 9999, open SSH connection
  4  probe + backup (detect build dir, Inca version, pull backup tarball)
  5  payload: upload and run unlock.sh on bike
  6  verify + game-restart
  7  write results JSON

On any stage failure: call AI-assist agent for diagnosis before raising.
"""

from __future__ import annotations

import json
import os
import re
import shutil
import socket
import subprocess
import tempfile
import threading
import time
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

import serial

from mule.hid import ch9329
from mule.ai.agent import get_corrective_step

REPO_ROOT = Path(__file__).resolve().parent.parent
PAYLOAD_DIR = REPO_ROOT / "payload"
COMPAT_DIR = REPO_ROOT / "compat"
BACKUPS_DIR = REPO_ROOT / "backups"
RESULTS_DIR = REPO_ROOT / "results"

BIKE_USER = "expresso"
BIKE_PASS = "expresso"
MULE_LISTEN_PORT_PROBE = 9998  # WIFI/NOWIFI flag
MULE_LISTEN_PORT_IP    = 9999  # bike's assigned IP
NETWORK_TIMEOUT = 45  # seconds to wait for bike IP

HID_SCRIPTS = REPO_ROOT / "mule" / "hid" / "scripts"


@dataclass
class StageResult:
    stage: int
    name: str
    ok: bool
    output: str = ""
    error: str = ""
    duration_s: float = 0.0


@dataclass
class RunContext:
    hid_port: Optional[serial.Serial] = None
    bike_ip: Optional[str] = None
    build_dir: Optional[str] = None
    probe: dict = field(default_factory=dict)
    backup_path: Optional[str] = None
    wifi_ssid: str = ""
    wifi_pass: str = ""
    mule_ip: str = "10.42.42.1"
    ai_assist: bool = True
    results: list[StageResult] = field(default_factory=list)


class StageRunner:
    def __init__(self, ctx: RunContext):
        self.ctx = ctx

    def run(self) -> bool:
        stages = [
            self._stage0_enumerate,
            self._stage1_open_xterm,
            self._stage2_network,
            self._stage3_ssh_handoff,
            self._stage4_probe_backup,
            self._stage5_unlock,
            self._stage6_verify,
            self._stage7_results,
        ]
        for i, fn in enumerate(stages):
            print(f"\n[{i}/7] {fn.__doc__ or fn.__name__}")
            t0 = time.monotonic()
            try:
                fn()
                dur = time.monotonic() - t0
                sr = StageResult(stage=i, name=fn.__name__, ok=True, duration_s=round(dur, 1))
                self.ctx.results.append(sr)
                print(f"  ok ({dur:.1f}s)")
            except Exception as exc:
                dur = time.monotonic() - t0
                sr = StageResult(stage=i, name=fn.__name__, ok=False, error=str(exc), duration_s=round(dur, 1))
                self.ctx.results.append(sr)
                print(f"  FAIL: {exc}")
                if self.ctx.ai_assist:
                    self._ai_intervene(i, fn.__name__, exc)
                return False
        return True

    # ------------------------------------------------------------------ stages

    def _stage0_enumerate(self):
        """enumerate CH9329 serial port"""
        if self.ctx.hid_port is None:
            raise RuntimeError("no HID port configured — pass --hid-port")
        if not self.ctx.hid_port.is_open:
            self.ctx.hid_port.open()
        print(f"  CH9329 on {self.ctx.hid_port.port}")

    def _stage1_open_xterm(self):
        """HID: open xterm via Alt+F2"""
        script = (HID_SCRIPTS / "open_xterm.txt").read_text()
        _run_hid_script(self.ctx.hid_port, script, {})

    def _stage2_network(self):
        """HID: bootstrap network — WiFi preferred, Ethernet fallback"""
        # Listen for WIFI/NOWIFI probe on port 9998
        net_type = _listen_for_line(self.ctx.mule_ip, MULE_LISTEN_PORT_PROBE, timeout=15)
        wifi_available = net_type.strip().upper() == "WIFI"

        subs = {"MULE_IP": self.ctx.mule_ip}
        if wifi_available:
            print("  WiFi detected — using wpa_supplicant path")
            if not self.ctx.wifi_ssid:
                raise RuntimeError("WiFi available on bike but no --wifi-ssid configured")
            subs.update({"SSID": self.ctx.wifi_ssid, "PASS": self.ctx.wifi_pass})
            script = (HID_SCRIPTS / "net_wifi.txt").read_text()
        else:
            print("  No wlan0 — using Ethernet path (mule must be serving 10.42.42.0/24)")
            script = (HID_SCRIPTS / "net_eth.txt").read_text()

        _run_hid_script(self.ctx.hid_port, script, subs)

    def _stage3_ssh_handoff(self):
        """wait for bike IP, verify SSH"""
        ip_line = _listen_for_line(self.ctx.mule_ip, MULE_LISTEN_PORT_IP, timeout=NETWORK_TIMEOUT)
        # extract first IPv4 address from `ip addr show` output
        m = re.search(r'inet (\d+\.\d+\.\d+\.\d+)', ip_line)
        if not m:
            raise RuntimeError(f"could not parse IP from: {ip_line!r}")
        self.ctx.bike_ip = m.group(1)
        print(f"  bike at {self.ctx.bike_ip}")
        # verify SSH
        _ssh(self.ctx.bike_ip, "echo ssh-ok", timeout=10)

    def _stage4_probe_backup(self):
        """probe build dir + take backup"""
        probe_script = (COMPAT_DIR / "probe.sh").read_text()
        with tempfile.NamedTemporaryFile(suffix=".sh", mode='w', delete=False) as f:
            f.write(probe_script)
            tmp = f.name
        try:
            result = _scp_and_run(self.ctx.bike_ip, tmp, "/tmp/vr_probe.sh")
        finally:
            os.unlink(tmp)

        self.ctx.probe = json.loads(result)
        if "error" in self.ctx.probe:
            raise RuntimeError(self.ctx.probe["error"])
        self.ctx.build_dir = self.ctx.probe["build"]
        print(f"  build={self.ctx.build_dir} serial={self.ctx.probe.get('serial')}")

        # pull backup tarball from bike
        BACKUPS_DIR.mkdir(exist_ok=True)
        remote_backup = self.ctx.probe.get("backup_path")
        if remote_backup:
            local = BACKUPS_DIR / Path(remote_backup).name
            _scp_pull(self.ctx.bike_ip, remote_backup, str(local))
            self.ctx.backup_path = str(local)
            print(f"  backup pulled → {local.name}")

    def _stage5_unlock(self):
        """upload payload and run backup-first installer"""
        ip = self.ctx.bike_ip

        # rsync payload dir to bike
        _rsync(str(PAYLOAD_DIR) + "/", f"{BIKE_USER}@{ip}:/tmp/vr_payload/")
        result = _ssh(
            ip,
            "sudo bash /tmp/vr_payload/install-coldbrew.sh --live --with-hosts-block --with-watchdog --with-fake-server --with-branding",
            timeout=300,
        )
        # capture backup path printed by installer
        for line in result.splitlines():
            if line.startswith("BACKUP_DIR:"):
                self.ctx.probe["backup_dir"] = line[11:]
            elif line.startswith("BACKUP_TGZ:"):
                self.ctx.probe["backup_path"] = line[11:]
                break

    def _stage6_verify(self):
        """verify patches applied, restart game"""
        ip = self.ctx.bike_ip
        build = self.ctx.build_dir
        base = f"/usr/local/expresso/{build}/ME_Assets"
        conf = "/usr/local/expresso/conf/ef_global.conf"

        checks = [
            (f"grep -q 'BikeSubscription = 1' {conf}", "BikeSubscription"),
            (f"grep -q 'coldbrew:route-unlock' {base}/Scripts/GlobalFunctions.lua", "GlobalFunctions patch"),
            ("test -f /usr/local/bin/ef-watchdog.sh", "watchdog installed"),
            ("test -f /usr/local/bin/fake-server.sh", "fake server installed"),
        ]
        for cmd, label in checks:
            _ssh(ip, cmd, timeout=10)
            print(f"  {label}: ok")

        restart_cmd = (
            f"sudo killall Inca Launcher 2>/dev/null || true; sleep 2; "
            f"cd /usr/local/expresso && nohup ./{build}/bin/Launcher > /tmp/launcher.log 2>&1 < /dev/null & disown $!"
        )
        _ssh(ip, restart_cmd, timeout=15)
        time.sleep(8)
        result = _ssh(ip, "pgrep -c Inca || true", timeout=10)
        if result.strip() == "0":
            raise RuntimeError("Inca did not restart")
        print("  game restarted")

    def _stage7_results(self):
        """write results JSON"""
        RESULTS_DIR.mkdir(exist_ok=True)
        ts = datetime.now(timezone.utc).strftime("%Y%m%d_%H%M%S")
        serial_id = self.ctx.probe.get("serial", "unknown")
        path = RESULTS_DIR / f"{serial_id}_{ts}.json"
        payload = {
            "bike_serial": serial_id,
            "inca_build": self.ctx.build_dir,
            "timestamp": ts,
            "bike_ip": self.ctx.bike_ip,
            "ok": all(r.ok for r in self.ctx.results),
            "stages": [
                {"stage": r.stage, "name": r.name, "ok": r.ok,
                 "error": r.error, "duration_s": r.duration_s}
                for r in self.ctx.results
            ],
        }
        path.write_text(json.dumps(payload, indent=2))
        status = "ALL GOOD" if payload["ok"] else "FAILED"
        print(f"\n  {status} — results → {path}")

    # ------------------------------------------------------------------ AI

    def _ai_intervene(self, stage: int, name: str, exc: Exception) -> None:
        print("\n  [AI-assist] diagnosing failure...")
        context = {
            "stage": stage,
            "stage_name": name,
            "error": str(exc),
            "probe": self.ctx.probe,
            "bike_ip": self.ctx.bike_ip,
            "build_dir": self.ctx.build_dir,
        }
        try:
            suggestion = get_corrective_step(context)
            print(f"\n  AI suggestion:\n{suggestion}\n")
        except Exception as ai_exc:
            print(f"  AI-assist unavailable: {ai_exc}")


# ------------------------------------------------------------------ helpers

def _run_hid_script(port: serial.Serial, script: str, subs: dict[str, str]) -> None:
    for line in script.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        for k, v in subs.items():
            line = line.replace(f"{{{k}}}", v)

        if line == "ALT_F2":
            ch9329.alt_f2(port)
        elif line == "ENTER":
            ch9329.press_enter(port)
        elif line.startswith("WAIT "):
            ms = int(line.split()[1])
            time.sleep(ms / 1000)
        elif line.startswith("TYPE "):
            text = line[5:]
            ch9329.type_string(port, text)
            ch9329.press_enter(port)
        else:
            raise ValueError(f"unknown HID script directive: {line!r}")


def _listen_for_line(bind_ip: str, port: int, timeout: int) -> str:
    result: list[str] = []
    ready = threading.Event()

    def serve():
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            s.bind((bind_ip, port))
            s.listen(1)
            s.settimeout(timeout)
            conn, _ = s.accept()
            with conn:
                data = conn.recv(4096).decode("utf-8", errors="replace")
                result.append(data)
            ready.set()

    t = threading.Thread(target=serve, daemon=True)
    t.start()
    if not ready.wait(timeout + 2):
        raise TimeoutError(f"no connection on {bind_ip}:{port} within {timeout}s")
    return result[0] if result else ""


def _ssh(ip: str, cmd: str, timeout: int = 30) -> str:
    result = subprocess.run(
        ["sshpass", "-p", BIKE_PASS,
         "ssh", "-o", "StrictHostKeyChecking=no", "-o", "ConnectTimeout=10",
         "-o", "PreferredAuthentications=password", "-o", "PubkeyAuthentication=no",
         f"{BIKE_USER}@{ip}", cmd],
        capture_output=True, text=True, timeout=timeout,
    )
    if result.returncode != 0:
        raise RuntimeError(f"SSH command failed ({result.returncode}): {result.stderr.strip()}")
    return result.stdout


def _scp_and_run(ip: str, local_path: str, remote_path: str) -> str:
    subprocess.run(
        ["sshpass", "-p", BIKE_PASS,
         "scp", "-o", "StrictHostKeyChecking=no",
         "-o", "PreferredAuthentications=password", "-o", "PubkeyAuthentication=no",
         local_path, f"{BIKE_USER}@{ip}:{remote_path}"],
        check=True, capture_output=True,
    )
    return _ssh(ip, f"bash {remote_path}", timeout=15)


def _scp_pull(ip: str, remote_path: str, local_path: str) -> None:
    subprocess.run(
        ["sshpass", "-p", BIKE_PASS,
         "scp", "-o", "StrictHostKeyChecking=no",
         "-o", "PreferredAuthentications=password", "-o", "PubkeyAuthentication=no",
         f"{BIKE_USER}@{ip}:{remote_path}", local_path],
        check=True, capture_output=True,
    )


def _rsync(src: str, dst: str) -> None:
    subprocess.run(
        ["rsync", "-az", "--delete",
         "-e", f"sshpass -p {BIKE_PASS} ssh -o StrictHostKeyChecking=no -o PreferredAuthentications=password -o PubkeyAuthentication=no",
         src, dst],
        check=True, capture_output=True,
    )
