# Task 4 — Phase 3 native macOS terminal slice

## Implementation

- Added `macos/OmniAgent.xcodeproj` with macOS 14 application and XCTest targets, a shared scheme, and `macos/build.sh`.
- Pinned SwiftTerm to the exact required Git revision `6918d74b5c2880007901151cd4ac1820779abd7b`; the resolved lockfile records the same revision.
- Added one AppKit workspace window containing exactly one SwiftTerm `TerminalView`. The surface feeds daemon bytes directly, sends delegate-provided bytes back without text conversion, uses SwiftTerm's native responder/IME implementation, attempts Metal only after joining a window, and retains the CoreGraphics fallback.
- Added a concrete persistent `SessionConnection` for the frozen 16-byte big-endian v1 framing protocol. It validates headers and the 1 MiB limit before allocating payloads, handles partial reads and arbitrary raw bytes, correlates requests, dispatches session events, reconnects, and reattaches after the latest observed sequence.
- Implemented session list/create/attach/reattach/input/resize/interrupt/kill plus snapshot, output, status, attention, exit, resync, and daemon error handling.
- Added native application, edit, session, and window menus. Actions use nil targets so copy, paste, selection, focus, interrupt, kill, and reattach follow the AppKit responder chain.
- Added launch, daemon-connect, create, attach, first-output, input, feed, resize, and Metal signposts.
- Extended the shared Rust `ResizePayload` compatibly with defaulted `pixel_width` and `pixel_height`; the daemon forwards them to `portable_pty::PtySize`. The existing Tauri adapter explicitly sends zeroes.
- Kept Phase 3 deliberately to one terminal: no pane system, sidebar, settings UI, or service registration was added.

## TDD evidence

### RED

- The Rust protocol regression `resize_payload_accepts_legacy_shape_and_preserves_pixels` initially failed to compile because `ResizePayload` had no pixel fields.
- Frame codec tests initially failed to compile before `SessionFrame`, `FrameDecoder`, and `RawPayload` existed.
- The connection integration test initially failed to compile before concrete `SessionConnection` existed.
- The reconnect test then exposed a `Data` indexing crash after the decoder removed its first frame. A focused regression, `testDecoderHandlesAFrameAfterRemovingThePreviousFrame`, reproduced the crash.
- The workspace lifecycle test initially failed to compile before the AppKit window controller and terminal surface existed.

### GREEN

- The pixel compatibility regression passes for both the legacy JSON shape and explicit pixel dimensions.
- The decoder now uses offsets relative to `Data.startIndex`; partial reads, malformed headers, arbitrary bytes, and consecutive removed frames pass.
- The Unix-socket integration test passes a split hello response and split arbitrary raw output, disconnects, reconnects, and observes reattach after sequence 41.
- The controller test confirms one terminal surface and native first-responder focus.

## Verification

- `./macos/build.sh test` — passed: 6 tests, 0 failures.
- `./macos/build.sh build` — passed.
- Xcode resolved SwiftTerm at `6918d74`.
- `cargo test --manifest-path src-tauri/Cargo.toml --test daemon_client_protocol` — passed: 6 tests, 0 failures.
- `cargo test -p omniagent-pty-daemon` — protocol tests passed; the aggregate run reproduced the pre-existing four-second timeout in `one_persistent_connection_streams_raw_bytes_and_applies_resize`.
- `cargo test -p omniagent-pty-daemon --test server_protocol one_persistent_connection_streams_raw_bytes_and_applies_resize -- --exact` — passed immediately: 1 test, 0 failures.
- `git diff --check` — passed.
- Audit found no `LocalProcessTerminalView` and no protocol abstraction named `SessionConnection`.

## Self-review

- Fixed an AppKit lifecycle issue found during review by retaining `AppDelegate` strongly for the duration of `NSApplication.run()`.
- Fixed the frame decoder's nonzero-`Data.startIndex` bug with a regression test.
- Frame writes are serialized on one I/O queue, callbacks are dispatched outside it, and request completions are failed on disconnect.
- Snapshot/output bytes remain `Data` until the final direct SwiftTerm byte feed; keyboard/IME bytes come from `TerminalViewDelegate`.
- Existing public MCP shapes and message discriminants are unchanged. The resize extension is backward compatible through Serde defaults.
- Only task-owned files remain changed; workspace-wide formatting drift in untouched manual examples was not included.

## Concerns

- Phase 3 expects the persistent Rust daemon to already be available at `OMNIAGENT_PTY_SOCKET` or `~/.omniagent-ade/omniagent-pty.sock`. Native service installation/launch is intentionally deferred to the service-registration phase.
- The daemon aggregate suite retains the known intermittent four-second response-ordering timeout present at the Phase 3 starting commit; the exact failing test passes.
- Xcode emits host-environment warnings about an out-of-date CoreSimulator and unavailable App Intents helper services. This target is macOS-only, and both native build and tests pass.
