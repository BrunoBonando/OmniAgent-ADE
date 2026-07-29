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
- The daemon suite retains the known intermittent four-second response-ordering timeout present at the Phase 3 starting commit; it reproduced in exact runs during this work, and the final exact rerun passed.
- Xcode emits host-environment warnings about an out-of-date CoreSimulator and unavailable App Intents helper services. This target is macOS-only, and both native build and tests pass.

## Review fix — input, accessibility, and latency boundaries

### Changes

- Set SwiftTerm's `optionAsMetaKey` to `false`. The AppKit text input client now retains ownership of Option dead keys, composed characters, and non-US layout input.
- Added the missing native accessibility contract around the pinned SwiftTerm view: text-area role, `Terminal` label, lazy terminal-buffer value, and a press action that focuses the terminal. The potentially large value is generated only when accessibility requests it, never on each output frame.
- Added a six-stage latency trail:
  1. `Latency.KeyboardReceipt` in `NSWindow.sendEvent`, immediately before native responder dispatch.
  2. `Latency.IPCSend` after the complete framed input has been written to the Unix socket.
  3. `omniagent_latency` / `daemon_pty_write` after the daemon has written and flushed input to the PTY.
  4. `Latency.OutputReceipt` after a raw output frame is decoded.
  5. `Latency.TerminalFeed` at the SwiftTerm byte feed.
  6. `Latency.AppKitDisplayPassComplete` after the next application-side AppKit display pass.
- The final marker is intentionally precise: it means `displayIfNeeded()` returned. With Metal, that includes application-side draw/command submission; it does **not** claim GPU command-buffer completion, WindowServer presentation, or physical scanout. `SWIFTTERM_PROFILE=1` additionally enables the pinned renderer's native `Metal.Draw` and `Metal.Commit` signposts, which likewise measure renderer work/submission rather than scanout.
- Paint markers are coalesced to one pending main-runloop callback per terminal so output bursts do not enqueue one display pass per frame.
- Added `macos/check-latency-markers.sh` as a runnable static boundary audit.

### TDD evidence

RED:

- The focused controller tests first reported six failures: `optionAsMetaKey` remained `true`, the view was not an accessibility element, its role was `AXUnknown`, and label/value/action behavior was absent.
- The first attempted keyboard marker compile correctly failed because pinned SwiftTerm declares `keyDown` public but not open. The marker moved to the owning `NSWindow` event boundary without intercepting or transforming the event.

GREEN:

- The composed-input test sends `é` through SwiftTerm's real `NSTextInputClient` path and observes the exact UTF-8 bytes with `optionAsMetaKey == false`.
- The accessibility test observes the text-area role, label, lazy value containing real fed terminal content, and working focus action.
- Full native suite: 9 tests passed, 0 failed.

### Automated benchmark and runtime evidence

- The runnable XCTest benchmark decodes and raw-decodes 100 output frames, feeds SwiftTerm, and requests the AppKit display pass. Five samples averaged approximately 0.003 seconds per 100-frame batch (5.607% relative standard deviation). This is a repeatable application-side microbenchmark, not a claim about end-to-end display hardware latency.
- A real daemon was launched with `RUST_LOG=omniagent_latency=debug`, driven through hello/create/input over its Unix socket, and emitted:
  - `DEBUG omniagent_latency: stage="daemon_pty_write" request=3 session_id="latency-evidence" bytes=1`
- `./macos/check-latency-markers.sh` passed and reported the full keyboard → IPC → PTY → output → feed → AppKit display-pass chain.

### Verification

- `./macos/build.sh test` — 9 passed, 0 failed.
- `cargo test --manifest-path src-tauri/Cargo.toml --test daemon_client_protocol` — 6 passed, 0 failed.
- `cargo test -p omniagent-pty-daemon --test protocol` — 7 passed, 0 failed.
- The pre-existing `one_persistent_connection_streams_raw_bytes_and_applies_resize` four-second timeout reproduced in two exact attempts during this review round; the final exact rerun passed. The changed daemon marker is after the already-successful PTY write/flush and does not alter protocol ordering.
