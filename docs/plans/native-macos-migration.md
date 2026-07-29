# OmniAgent Native macOS Migration

## Progress

- [x] Task 1 complete (Phase 0 packaging + fixtures + smoke/benchmark harnesses)
- [x] Task 2 complete (Phase 1 persistent daemon protocol)
- [x] Task 3 complete (Phase 2 Tauri compatibility client on persistent protocol)
- [x] Task 4 complete (Phase 3 native one-terminal vertical slice)
- [~] Task 5 in progress (Phase 4 AppKit pane workspace kickoff)
- [ ] Task 6 not started
- [ ] Task 7 not started

## Global constraints

- Keep Rust PTY/process ownership, SQLite/brain logic, transcripts, status detection, and the frozen MCP v1 public contract.
- Replace terminal transport with persistent Unix sockets using this 16-byte envelope: big-endian `u32 payload_length`, `u8 protocol_version = 1`, `u8 message_kind`, `u16 flags`, and `u64 request_or_sequence`.
- Reject payloads over 1 MiB, malformed frames, unsupported versions, and wrong-user peers.
- Terminal input/output payloads carry session IDs plus raw bytes; control payloads use UTF-8 JSON and existing Serde models.
- Output and snapshots use monotonic sequence numbers. Slow clients receive `ResyncRequired`; they never block PTY reads or grow memory without bound.
- Keep `vt100` for reattachment snapshots, status analysis, and 3,000 lines of bounded scrollback. Preserve transcripts separately.
- Preserve `CreateSessionRequest`, `SessionInfo`, `SessionStatus`, `SessionStatusEvent`, `SessionEndEvent`, `PersistedTab`, the `layout` setting, maximum eight panes, and current pane repair semantics.
- The native client targets macOS 14, uses AppKit for primary workspace behavior, SwiftUI only for low-frequency surfaces, and SwiftTerm for terminals.
- Do not change public MCP shapes. Do not build a custom terminal renderer.
- The initial direct-download build is not App Sandbox enabled.
- Follow TDD for behavior changes and keep changes limited to the migration.

## Task 1: Phase 0 packaging, compatibility fixtures, and smoke/benchmark harness

- Package both `omniagent-pty-daemon` and `omniagent-mcp` in the Tauri app without relying on `PATH`.
- Add a packaged-app smoke harness covering create, input/output, and resize using installed resources.
- Add committed compatibility fixtures for Rust session models, status/end events, persisted layout JSON, and pane shapes/hole repair.
- Add a reproducible benchmark harness and reference-machine metadata schema for one/four/eight terminals, continuous output, resize storms, latency, CPU, and hidden-output memory. Do not invent benchmark results.

## Task 2: Phase 1 versioned persistent daemon protocol

- Rewrite `crates/omniagent-pty-daemon` so the daemon owns the sole real PTY and streams raw output over persistent connections.
- Implement all client/server message kinds from the source plan, envelope validation, socket directory permissions, peer UID verification, sequence resume/snapshot behavior, bounded client queues, `ResyncRequired`, bounded parser scrollback, transcripts, shutdown cleanup, and registry lock release before I/O.
- Remove the attach-helper PTY, 120 ms repaint polling, base64 terminal transport, and per-request connection model.
- Add malformed/oversized frame tests, raw-byte fidelity tests, resize tests, slow-client tests, and eight-session concurrency/persistence tests.

## Task 3: Phase 2 Tauri compatibility client

- Consolidate `src-tauri/src/daemon.rs` and `src-tauri/src/pty_daemon_client.rs` into one persistent protocol client.
- Route lifecycle and terminal operations through it while preserving existing Tauri commands, events, and frontend models.
- Ensure the daemon is the sole session/process owner and delete proxy PTY/attach/polling paths.
- Share protocol contract tests with the daemon.

## Task 4: Phase 3 native one-terminal vertical slice

- Create `macos/OmniAgent.xcodeproj`, macOS 14 target, revision-pinned SwiftTerm dependency, tests, and build scripts.
- Implement the AppKit application delegate, window controller, menus/responder actions, concrete framed `SessionConnection`, one SwiftTerm-backed `TerminalSurfaceView`, create/write/resize/interrupt/kill/reattach/status, and `os_signpost` instrumentation.
- Preserve native text input, IME/marked text, native editing/Services/accessibility behavior, and allow unclaimed keys to reach the terminal.

## Task 5: Phase 4 identity-preserving AppKit pane workspace

- Implement `PaneWorkspaceView` with separate pane identity/position, direct frame calculation, live divider drag, display-refresh resize coalescing, focus restoration, native commands, drag/drop, and accessibility descriptions.
- Preserve one/two/four/six/eight shapes, maximum eight, grouping, swap, close, directional focus, and hole repair from `ui/src/state/paneGrid.ts`.
- Keep terminal instances alive across layout mutations and add focused unit/UI tests.

## Task 6: Phases 5-6 remaining native surface, persistence service, and distribution

- Add AppKit sidebar/session outline, command palette, toolbar, notifications, restoration, and SwiftUI-hosted settings/onboarding/usage/inspectors.
- Route settings/brain operations through the Rust service while preserving data/model compatibility and per-field layout repair.
- Bundle/register the service through `SMAppService` with its LaunchAgent plist, status UI, degraded app-owned mode, termination cleanup, restart-loss reporting, preview bundle/data separation, and existing production data reuse.
- Add universal build, hardened-runtime signing, notarization/stapling scripts, Gatekeeper/install smoke verification, and explicit non-sandbox entitlements. Scripts must fail clearly when credentials are absent.

## Task 7: Phase 7 cutover preparation and documentation

- Add a release-gated cutover script/checklist that refuses destructive web-hot-path deletion until two release-candidate cycles are recorded.
- After the gate is met, make the native app production, retain the Tauri rollback artifact for one release, and remove xterm.js, React Mosaic, terminal Tauri events/commands, duplicate clients, polling, proxy PTYs, and frontend terminal buffers.
- Update `AGENTS.md`, `.github/copilot-instructions.md`, `CLAUDE.md` where applicable, build scripts, and release automation together.
- Verify Rust, clippy, UI tests while retained, Xcode tests, protocol tests, and packaging smoke checks.
