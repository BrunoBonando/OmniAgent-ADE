#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
native="$root/macos/OmniAgent"
daemon="$root/crates/omniagent-pty-daemon/src/server.rs"

rg -q 'name: "Latency.KeyboardReceipt"' "$native/WorkspaceWindowController.swift"
rg -q 'name: "Latency.IPCSend"' "$native/SessionConnection.swift"
rg -q 'stage = "daemon_pty_write"' "$daemon"
rg -q 'name: "Latency.OutputReceipt"' "$native/SessionConnection.swift"
rg -q 'name: "Latency.TerminalFeed"' "$native/TerminalSurfaceView.swift"
rg -q 'name: "Latency.RendererSubmissionComplete"' "$native/TerminalSurfaceView.swift"
rg -q 'metalView.draw()' "$native/TerminalSurfaceView.swift"

echo "latency marker chain: keyboard -> IPC -> PTY -> output -> feed -> renderer submission"
