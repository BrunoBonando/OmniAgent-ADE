#!/usr/bin/env python3
"""Smoke-test and benchmark the PTY daemon bundled in an installed OmniAgent.app."""

import argparse
import base64
import json
import os
from pathlib import Path
import platform
import socket
import subprocess
import tempfile
import time
from typing import Any, List, Optional, Tuple


def app_resources(app: Path) -> Tuple[Path, Path]:
    resources = app / "Contents" / "Resources"
    daemon = resources / "omniagent-pty-daemon"
    mcp = resources / "omniagent-mcp"
    for binary in (daemon, mcp):
        if not binary.is_file() or not os.access(binary, os.X_OK):
            raise RuntimeError(f"missing executable bundled resource: {binary}")
    return daemon, mcp


def request(socket_path: Path, payload: dict[str, Any]) -> dict[str, Any]:
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        client.settimeout(2)
        client.connect(str(socket_path))
        client.sendall(json.dumps(payload, separators=(",", ":")).encode() + b"\n")
        response = b""
        while not response.endswith(b"\n"):
            chunk = client.recv(65536)
            if not chunk:
                break
            response += chunk
    decoded = json.loads(response)
    if not decoded.get("success"):
        raise RuntimeError(decoded.get("error", "daemon request failed"))
    return decoded


def wait_until_ready(socket_path: Path) -> None:
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        try:
            request(socket_path, {"action": "list_sessions"})
            return
        except (OSError, ValueError, RuntimeError):
            time.sleep(0.05)
    raise RuntimeError(f"daemon did not start at {socket_path}")


def wait_for_screen(socket_path: Path, session_id: str, marker: str) -> float:
    started = time.monotonic()
    deadline = started + 5
    while time.monotonic() < deadline:
        response = request(socket_path, {"action": "attach_session", "id": session_id})
        screen = response.get("result", {}).get("screen", "")
        if marker in screen:
            return (time.monotonic() - started) * 1000
        time.sleep(0.02)
    raise RuntimeError(f"did not observe {marker!r} in {session_id} output")


class InstalledDaemon:
    def __init__(self, app: Path):
        self.daemon, self.mcp = app_resources(app)
        self.temp = tempfile.TemporaryDirectory(prefix="omniagent-phase0-")
        self.socket_path = Path(self.temp.name) / "pty.sock"
        self.process: Optional[subprocess.Popen] = None

    def __enter__(self) -> "InstalledDaemon":
        env = os.environ.copy()
        env["OMNIAGENT_PTY_SOCKET"] = str(self.socket_path)
        self.process = subprocess.Popen([str(self.daemon)], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        wait_until_ready(self.socket_path)
        return self

    def __exit__(self, *_: Any) -> None:
        if self.process is not None:
            self.process.terminate()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=5)
        self.temp.cleanup()


def create_shell(socket_path: Path, session_id: str, command: Optional[List[str]] = None) -> None:
    request(
        socket_path,
        {
            "action": "create_session",
            "id": session_id,
            "command": command or ["/bin/sh"],
            "cwd": str(Path.cwd()),
            "env": {},
            "cols": 80,
            "rows": 24,
        },
    )


def input_bytes(socket_path: Path, session_id: str, data: bytes) -> None:
    request(
        socket_path,
        {"action": "send_input", "id": session_id, "data_base64": base64.b64encode(data).decode()},
    )


def smoke(app: Path) -> None:
    with InstalledDaemon(app) as daemon:
        session_id = "phase0-smoke"
        create_shell(daemon.socket_path, session_id)
        input_bytes(daemon.socket_path, session_id, b"printf 'OMNIAGENT_PHASE0_INPUT\\n'\n")
        wait_for_screen(daemon.socket_path, session_id, "OMNIAGENT_PHASE0_INPUT")

        request(
            daemon.socket_path,
            {"action": "resize_session", "id": session_id, "cols": 132, "rows": 41},
        )
        input_bytes(daemon.socket_path, session_id, b"stty size\n")
        wait_for_screen(daemon.socket_path, session_id, "41 132")
        request(daemon.socket_path, {"action": "kill_session", "id": session_id})
    print("packaged PTY smoke passed")


def ps_value(pid: int, field: str) -> float:
    output = subprocess.check_output(["/bin/ps", "-o", f"{field}=", "-p", str(pid)], text=True).strip()
    return float(output or 0)


def sysctl(name: str) -> Optional[str]:
    try:
        return subprocess.check_output(["/usr/sbin/sysctl", "-n", name], text=True).strip() or None
    except (OSError, subprocess.CalledProcessError):
        return None


def reference_machine() -> dict[str, Any]:
    memory_bytes = None
    try:
        memory_bytes = os.sysconf("SC_PAGE_SIZE") * os.sysconf("SC_PHYS_PAGES")
    except (AttributeError, ValueError, OSError):
        pass
    return {
        "schema_version": 1,
        "collected_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "macos_version": platform.mac_ver()[0] or platform.platform(),
        "hardware_model": sysctl("hw.model"),
        "chip": sysctl("machdep.cpu.brand_string"),
        "cpu_cores": os.cpu_count(),
        "memory_bytes": memory_bytes,
    }


def benchmark_case(app: Path, terminals: int, duration_seconds: float, resize_count: int) -> dict[str, Any]:
    with InstalledDaemon(app) as daemon:
        assert daemon.process is not None
        session_ids = [f"phase0-bench-{terminals}-{i}" for i in range(terminals)]
        for session_id in session_ids:
            create_shell(daemon.socket_path, session_id, ["/bin/sh", "-c", "while :; do printf x; done"])

        baseline_rss = ps_value(daemon.process.pid, "rss")
        time.sleep(duration_seconds)
        hidden_output_rss = ps_value(daemon.process.pid, "rss")

        resize_started = time.monotonic()
        for index in range(resize_count):
            for session_id in session_ids:
                request(
                    daemon.socket_path,
                    {
                        "action": "resize_session",
                        "id": session_id,
                        "cols": 80 + index % 40,
                        "rows": 24 + index % 20,
                    },
                )
        resize_elapsed_ms = (time.monotonic() - resize_started) * 1000

        latency_id = f"phase0-latency-{terminals}"
        marker = f"OMNIAGENT_PHASE0_LATENCY_{terminals}"
        create_shell(daemon.socket_path, latency_id)
        input_bytes(daemon.socket_path, latency_id, f"printf '{marker}\\n'\n".encode())
        latency_ms = wait_for_screen(daemon.socket_path, latency_id, marker)

        return {
            "terminals": terminals,
            "continuous_output_seconds": duration_seconds,
            "resize_operations": terminals * resize_count,
            "resize_storm_elapsed_ms": resize_elapsed_ms,
            "input_to_snapshot_latency_ms": latency_ms,
            "daemon_cpu_percent": ps_value(daemon.process.pid, "%cpu"),
            "hidden_output_rss_delta_kib": hidden_output_rss - baseline_rss,
        }


def benchmark(app: Path, output: Path, duration_seconds: float, resize_count: int) -> None:
    results = {
        "schema_version": 1,
        "reference_machine": reference_machine(),
        "scenarios": [benchmark_case(app, count, duration_seconds, resize_count) for count in (1, 4, 8)],
    }
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(results, indent=2) + "\n")
    print(f"benchmark results written to {output}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    subcommands = parser.add_subparsers(dest="command", required=True)
    smoke_parser = subcommands.add_parser("smoke", help="exercise bundled create, input/output, and resize")
    smoke_parser.add_argument("app", type=Path)
    benchmark_parser = subcommands.add_parser("benchmark", help="measure bundled daemon scenarios")
    benchmark_parser.add_argument("app", type=Path)
    benchmark_parser.add_argument("--output", type=Path, required=True)
    benchmark_parser.add_argument("--duration-seconds", type=float, default=5)
    benchmark_parser.add_argument("--resize-count", type=int, default=100)
    args = parser.parse_args()
    if args.command == "smoke":
        smoke(args.app)
    else:
        benchmark(args.app, args.output, args.duration_seconds, args.resize_count)


if __name__ == "__main__":
    main()
