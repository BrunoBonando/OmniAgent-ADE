#!/usr/bin/env python3
"""Runs the packaged-resource smoke harness against a temporary app bundle."""

from pathlib import Path
import shutil
import subprocess
import tempfile
import json


ROOT = Path(__file__).resolve().parent.parent
HARNESS = ROOT / "scripts" / "native-macos-pty-harness.py"
DAEMON = ROOT / "target" / "debug" / "omniagent-pty-daemon"


def main() -> None:
    if not DAEMON.is_file():
        raise SystemExit(f"build {DAEMON.relative_to(ROOT)} before running this test")

    with tempfile.TemporaryDirectory() as tmp:
        resources = Path(tmp) / "OmniAgent.app" / "Contents" / "Resources"
        resources.mkdir(parents=True)
        shutil.copy2(DAEMON, resources / DAEMON.name)
        mcp = resources / "omniagent-mcp"
        mcp.write_text("#!/bin/sh\nexit 0\n")
        mcp.chmod(0o755)

        result = subprocess.run(
            ["python3", str(HARNESS), "smoke", str(resources.parents[1])],
            capture_output=True,
            text=True,
            timeout=20,
        )
        assert result.returncode == 0, result.stderr or result.stdout
        assert "packaged PTY smoke passed" in result.stdout, result.stdout

        output = Path(tmp) / "benchmark.json"
        result = subprocess.run(
            [
                "python3",
                str(HARNESS),
                "benchmark",
                str(resources.parents[1]),
                "--output",
                str(output),
                "--duration-seconds",
                "0.1",
                "--resize-count",
                "1",
            ],
            capture_output=True,
            text=True,
            timeout=30,
        )
        assert result.returncode == 0, result.stderr or result.stdout
        measured = json.loads(output.read_text())
        assert [scenario["terminals"] for scenario in measured["scenarios"]] == [1, 4, 8]
        assert all("hidden_output_rss_delta_kib" in scenario for scenario in measured["scenarios"])


if __name__ == "__main__":
    main()
