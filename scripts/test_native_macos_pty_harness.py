#!/usr/bin/env python3
"""Runs the packaged-resource smoke harness against a temporary app bundle."""

import importlib.util
from pathlib import Path
import shutil
import subprocess
import tempfile
import json


ROOT = Path(__file__).resolve().parent.parent
HARNESS = ROOT / "scripts" / "native-macos-pty-harness.py"
DAEMON = ROOT / "target" / "debug" / "omniagent-pty-daemon"
MCP = ROOT / "target" / "debug" / "omniagent-mcp"


def _load_harness_module():
    # native-macos-pty-harness.py has a hyphenated filename (not a valid
    # Python module name), hence the file-path load rather than a plain
    # import.
    spec = importlib.util.spec_from_file_location("native_macos_pty_harness", HARNESS)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main() -> None:
    if not DAEMON.is_file() or not MCP.is_file():
        raise SystemExit("build the debug daemon and MCP binaries before running this test")

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
        assert result.returncode != 0, "a non-MCP resource must fail the smoke harness"

        shutil.copy2(MCP, mcp)
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


def test_swift_bundle_layout_resolution() -> None:
    """Task 6d: find_daemon/find_mcp must accept the native Swift app's
    Contents/MacOS/omniagent-pty-daemon layout (Task 6d's Copy Files build
    phase target) in addition to the Tauri app's Contents/Resources/
    layout (Task 1), and must treat omniagent-mcp as optional -- the Swift
    app never bundles it at all.

    This exercises the resource-*resolution* functions directly rather
    than through smoke()'s full create/attach/resize session flow: that
    flow requires a live protocol round-trip over the daemon's Unix
    socket, and this harness (scripts/native-macos-pty-harness.py, from
    Task 1) still speaks Task 1's original per-request JSON-over-a-newline
    protocol, which Task 2 replaced with a persistent 16-byte-envelope
    protocol -- confirmed in the Task 6d report to already fail the same
    way against an *unmodified* copy of this harness, i.e. independent of
    anything Task 6d changed. Testing find_daemon/find_mcp directly avoids
    being blocked by that pre-existing, out-of-scope staleness."""
    harness = _load_harness_module()

    with tempfile.TemporaryDirectory() as tmp:
        app = Path(tmp) / "OmniAgent.app"

        try:
            harness.find_daemon(app)
        except RuntimeError:
            pass
        else:
            raise AssertionError("find_daemon must fail when nothing is bundled")
        assert harness.find_mcp(app) is None, "find_mcp must be None, not raise, when absent"

        # Tauri layout: Contents/Resources/, both binaries present.
        resources = app / "Contents" / "Resources"
        resources.mkdir(parents=True)
        (resources / "omniagent-pty-daemon").write_text("#!/bin/sh\n")
        (resources / "omniagent-pty-daemon").chmod(0o755)
        (resources / "omniagent-mcp").write_text("#!/bin/sh\n")
        (resources / "omniagent-mcp").chmod(0o755)
        assert harness.find_daemon(app) == resources / "omniagent-pty-daemon"
        assert harness.find_mcp(app) == resources / "omniagent-mcp"

        # Swift layout: Contents/MacOS/, no omniagent-mcp anywhere -- must
        # still resolve the daemon and report mcp as legitimately absent,
        # not as an error, once Contents/Resources/ no longer exists at all.
        shutil.rmtree(resources)
        macos_dir = app / "Contents" / "MacOS"
        macos_dir.mkdir(parents=True)
        (macos_dir / "omniagent-pty-daemon").write_text("#!/bin/sh\n")
        (macos_dir / "omniagent-pty-daemon").chmod(0o755)
        assert harness.find_daemon(app) == macos_dir / "omniagent-pty-daemon"
        assert harness.find_mcp(app) is None


if __name__ == "__main__":
    main()
    test_swift_bundle_layout_resolution()
    print("swift bundle layout resolution test passed")
