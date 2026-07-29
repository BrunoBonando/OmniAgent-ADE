#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
native="$root/macos/OmniAgent"
daemon="$root/crates/omniagent-pty-daemon/src/server.rs"
resolved="$root/macos/OmniAgent.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
swiftterm_revision=6918d74b5c2880007901151cd4ac1820779abd7b

rg -q 'name: "Latency.KeyboardReceipt"' "$native/WorkspaceWindowController.swift"
rg -q 'name: "Latency.IPCSend"' "$native/SessionConnection.swift"
rg -q 'stage = "daemon_pty_write"' "$daemon"
rg -q 'name: "Latency.OutputReceipt"' "$native/SessionConnection.swift"
rg -q 'name: "Latency.TerminalFeed"' "$native/TerminalSurfaceView.swift"
rg -q 'name: "Latency.RendererDrawAttempted"' "$native/TerminalSurfaceView.swift"
rg -q 'metalView.draw()' "$native/TerminalSurfaceView.swift"
rg -q "$swiftterm_revision" "$resolved"

swiftterm_renderer=$(find "$HOME/Library/Developer/Xcode/DerivedData" \
    -path '*/SourcePackages/checkouts/SwiftTerm/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift' \
    -type f -print -quit)
if [ -z "$swiftterm_renderer" ]; then
    echo "SwiftTerm checkout unavailable; run ./macos/build.sh test first" >&2
    exit 1
fi
swiftterm_checkout=${swiftterm_renderer%/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift}
test "$(git -C "$swiftterm_checkout" rev-parse HEAD)" = "$swiftterm_revision"
rg -q 'SWIFTTERM_PROFILE.*== "1"' "$swiftterm_renderer"
rg -q 'name: "Metal.Commit"' "$swiftterm_renderer"
commit_line=$(rg -n -m1 'commandBuffer\.commit\(\)' "$swiftterm_renderer" | cut -d: -f1)
commit_marker_end_line=$(rg -n 'name: "Metal.Commit"' "$swiftterm_renderer" | tail -1 | cut -d: -f1)
test "$commit_marker_end_line" -gt "$commit_line"

echo "latency markers: keyboard -> IPC -> PTY -> output -> feed -> draw attempted"
echo "genuine Metal submit boundary: SwiftTerm Metal.Commit (run with SWIFTTERM_PROFILE=1)"
