# Task 1 — Phase 0 report

## Implementation

- Tauri now builds and packages both `omniagent-mcp` and `omniagent-pty-daemon` into `Contents/Resources`.
- Daemon resolution uses the packaged resource path before development/PATH fallbacks; a focused Rust test covers the app-bundle layout.
- `scripts/native-macos-pty-harness.py` provides:
  - `smoke <OmniAgent.app>`: validates both installed resources, then runs create, input/output, resize, and `stty size` through the resource daemon.
  - `benchmark <OmniAgent.app> --output <file>`: records 1/4/8 terminal runs with continuous output, resize storms, input-to-snapshot latency, daemon CPU, and hidden-output RSS delta.
- `benchmarks/native-macos/reference-machine.schema.json` defines the metadata emitted with results. No result file is committed.
- Compatibility fixtures are committed under `fixtures/native-macos-compat/` for Rust session models, all five status events, session-end event, the `layout` setting (including repair), and approved pane/hole behavior. Rust and UI tests consume the fixtures.

## Files

- Modified: `src-tauri/tauri.conf.json`, `src-tauri/src/daemon.rs`, `src-tauri/src/sessions.rs`
- Added: `scripts/native-macos-pty-harness.py`, `scripts/test_native_macos_pty_harness.py`
- Added: `fixtures/native-macos-compat/*.json`, `benchmarks/native-macos/{README.md,reference-machine.schema.json}`
- Added: `src-tauri/tests/native_macos_compatibility_test.rs`, `ui/src/state/nativeMacosCompatibility.test.ts`

## TDD evidence

### RED

1. `cargo test -p omniagent-ade daemon::tests::resolves_packaged_daemon_from_app_resources`
   - Failed with `cannot find function resolve_daemon_binary_from`.
2. `cargo build -p omniagent-pty-daemon --bin omniagent-pty-daemon && python3 scripts/test_native_macos_pty_harness.py`
   - Failed because `scripts/native-macos-pty-harness.py` did not exist.
3. The same harness test then exposed Python 3.9 incompatibility from `list[str] | None`; the type hints were made Python-3.9-compatible.
4. `cargo test -p omniagent-ade --test native_macos_compatibility_test`
   - Failed because the compatibility fixture files did not exist and `CreateSessionRequest`/`SessionEndEvent` did not implement `Serialize`.

### GREEN

- `cargo test -p omniagent-ade daemon::tests::resolves_packaged_daemon_from_app_resources` — 1 passed.
- `cargo test -p omniagent-ade --test native_macos_compatibility_test` — 2 passed.
- `python3 scripts/test_native_macos_pty_harness.py` — passed; it runs smoke plus a short 1/4/8 benchmark against a temporary resource-only app layout.
- `npm --prefix ui run test -- nativeMacosCompatibility.test.ts` — 1 file, 2 tests passed.

## Build and packaging verification

- `npm --prefix ui run build` — passed.
- `cargo build --release -p mcp-server --bin omniagent-mcp` — passed.
- `cargo build --release -p omniagent-pty-daemon --bin omniagent-pty-daemon` — passed.
- `src-tauri/../ui/node_modules/.bin/tauri build --bundles app` produced `target/release/bundle/macos/OmniAgent.app`; both resource executables were verified present and executable.
- `python3 scripts/native-macos-pty-harness.py smoke target/release/bundle/macos/OmniAgent.app` — `packaged PTY smoke passed`.
- `git diff --check` — passed.

## Self-review

- Packaging uses the already-established Tauri resource mechanism and resolves resources before PATH; no dependency was added.
- The smoke command uses only the installed daemon resource and checks the installed MCP resource, so it cannot pass from a development binary on PATH.
- Benchmark values are generated only when the user runs the harness; no benchmark result or baseline is checked in.
- Fixture assertions use literal, committed expected values rather than rebuilding expectations from production helpers.
- No public MCP shape changed. The only model changes are additive `Serialize` derives to make the committed Rust compatibility fixtures executable checks.

## Concerns

- The existing full-workspace Rust baseline failure remains intentionally untouched: `crates/brain-ingest/tests/ingest_test.rs::ingest_fixture_mines_git_cochange_between_auth_and_util` requires `fixtures/sample-project/.git`, which is absent in this worktree.
- Tauri continues to warn that `com.omniagent.app` ends with `.app`, and Vite continues to warn about an existing large production chunk. Neither warning was changed in this phase.

## Review fix: packaged MCP v1 smoke

### Implementation

- `scripts/native-macos-pty-harness.py` now starts the installed `Contents/Resources/omniagent-mcp` binary with an isolated data directory and sends its existing JSON-RPC `initialize`, `notifications/initialized`, and `tools/list` requests over stdio.
- The smoke requires the existing `omniagent-mcp` server identity and the frozen v1 tool names: `get_context`, `list_projects`, `record_decision`, `record_note`, `related`, and `search_brain`.
- No MCP request or response shape changed.

### Covering test

- `scripts/test_native_macos_pty_harness.py` first installs an executable shell stub as `omniagent-mcp` and asserts that `smoke` fails. It then replaces the stub with the real built MCP binary and asserts that the smoke and short benchmark pass.

### RED

```sh
cargo build -p mcp-server --bin omniagent-mcp && python3 scripts/test_native_macos_pty_harness.py
```

Output: failed with `AssertionError: a non-MCP resource must fail the smoke harness`, proving the previous executable-presence check accepted a shell stub.

### GREEN

```sh
python3 scripts/test_native_macos_pty_harness.py
```

Output: passed (stub rejected; real MCP passes initialize/tools/list, then smoke and 1/4/8 benchmark checks pass).

```sh
python3 scripts/native-macos-pty-harness.py smoke target/release/bundle/macos/OmniAgent.app
```

Output: `packaged PTY smoke passed`.
