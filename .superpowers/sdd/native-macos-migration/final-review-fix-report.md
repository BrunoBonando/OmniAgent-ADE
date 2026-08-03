# Final whole-branch review — fix wave report

Branch: `codex/native-macos-migration-progress`
Base of this wave: `37e0511` (the commit that recorded the final review in the ledger)
Commits added (5):

| SHA | Subject |
|---|---|
| `15fd07c` | `fix(brain): reopen brain.db when another process rebuilds it` |
| `5919b5d` | `refactor(brain): move project_label_key down into brain-core` |
| `83bd1d6` | `fix(daemon): answer a malformed control payload with Error, not a hangup` |
| `298fcaa` | `fix(macos): version wiring, release-gate split, plist channel, fixture parity` |
| `44fc41d` | `fix(macos): rename hazards, dictionary traps, state leaks, settings write gates` |

All 11 findings are fixed. Nothing was skipped, nothing is NEEDS_CONTEXT.
Three deviations from the literal instruction are called out inline below
(#2's fixture mapping, #4's version-format split, #6's dev-dependency).

---

## Important 1 — Cross-process `brain.db` rebuild orphans the other process's `Store`

**Root cause confirmed in code.** `brain_ingest::roots::rebuild_store`
(`crates/brain-ingest/src/roots.rs:614`) `unlink`s `brain.db` + its
`-wal`/`-shm`/`-journal` siblings and opens a fresh file at the same path.
`unlink` only removes the directory entry — every already-open SQLite handle
keeps working, silently, against the now-nameless inode. Before this branch
only one process held a long-lived handle and it swapped its own as part of
the rebuild; `omniagent-pty-daemon` is now a second holder.

**Fix — the mechanism lives in `brain-core`, so both processes get it:**

- `crates/brain-core/src/store.rs:5-42` — `Store` gained a private
  `origin: Option<StoreOrigin>` recording the `data_dir` it was opened from
  and the `(st_dev, st_ino)` `FileIdentity` of the `brain.db` it actually got
  (`None` for `open_in_memory`, which has no file to replace). New
  `file_identity(path)` helper via `std::os::unix::fs::MetadataExt`.
- `crates/brain-core/src/store.rs:319-...` — `Store::open` records the
  identity after the connection is live; new `pub fn was_replaced() -> bool`
  (a missing file counts as replaced: the unlink already happened) and
  `pub fn reopen_if_replaced() -> rusqlite::Result<bool>` (reopens in place,
  returns whether it did).

**Daemon wiring** — `crates/omniagent-pty-daemon/src/server.rs:668+`: new
`fn lock_store(&Mutex<Store>) -> Result<MutexGuard<Store>>` calls
`reopen_if_replaced()` before handing out the guard. All **14** call sites in
`handle_client` that previously did
`settings.lock().map_err(|error| anyhow!("settings lock poisoned: {error}"))`
now go through it. Cost is one `stat(2)` of an essentially always-cached path
per control request, which is why it is checked per-operation rather than on a
timer — no window, no background task, no extra state.

**Tauri wiring (the finding said "if it's cheap, do so" — it was)** —
`src-tauri/src/commands/mod.rs:149-167`: new
`BrainState::locked_store() -> Result<MutexGuard<Store>, String>`, the mirror
of the daemon's. All **18** production call sites converted
(`commands/mod.rs` 6, `roots.rs` 7, `feedback.rs` 3, `map_feed.rs` 2). Test
call sites (`brain.store.lock().unwrap()`) deliberately left alone — they open
a fresh store per test and never race a rebuild.

**Rebuild path itself** — `crates/brain-ingest/src/roots.rs`'s `rebuild()`
now calls `store_slot.reopen_if_replaced()?` before snapshotting
`all_settings()`. Without it, a process whose handle was already orphaned by
the *other* process's rebuild would carry a stale settings snapshot forward
and resurrect it over everything written since.

**Tests**
- `crates/brain-core/src/store.rs` `mod replacement_tests` — 4 tests:
  detection + reopen + a third-handle verification that the write landed on
  disk and did not clobber the rebuilder's rows; a **negative** test
  (`without_the_reopen_a_write_after_a_rebuild_is_silently_lost`) that pins
  the old lossy behaviour so the fix cannot be quietly reverted; deleted-and-
  not-yet-recreated; in-memory never counts as replaced. All pass.
- `crates/omniagent-pty-daemon/tests/server_protocol.rs`
  `settings_written_after_another_process_rebuilt_brain_db_land_in_the_new_file`
  — end-to-end through the socket: `SetSetting`, external rebuild (the exact
  unlink+reopen `rebuild_store` does, run from outside the daemon),
  `SetSetting` again, then read back **off the file on disk**, not through the
  daemon. **Mutation-checked**: stubbing `reopen_if_replaced` to always return
  `Ok(false)` makes it fail (`{"value": Null}` vs the rebuilder's row).
- `src-tauri/src/commands/mod.rs`
  `locked_store_reopens_after_the_other_process_rebuilt_brain_db`. Passes.

**Known residual (out of scope, noted honestly):** `brain-ingest`'s background
ingestion threads open their own short-lived `Store` per run. Within one
process a rebuild is refused while ingestion is running
(`rebuild_and_reingest`'s `if ingestion.snapshot().running { bail }`), but
that guard is per-process, so a cross-process rebuild during the *other*
process's ingest can still orphan a background thread's handle for the
remainder of that ingest. The blast radius is derived graph rows that the
next ingest regenerates, not settings — a different and much smaller problem
than the one this finding named.

---

## Important 2 — 3 of 4 Task 1 compat fixtures have no Swift test consumer

Fixtures: `fixtures/native-macos-compat/`. `pane-grid.json` was already
consumed from both TypeScript and Swift; the other three were not.

**New file:** `macos/OmniAgentTests/NativeMacosCompatibilityFixtureTests.swift`
(235 lines, 4 tests). Bundling replicates `PaneGridTests.swift` exactly: the
JSON is a `PBXFileReference` with `sourceTree = SOURCE_ROOT` pointing at
`../fixtures/native-macos-compat/<name>.json`, a `PBXBuildFile` in the test
target's Resources phase, loaded with
`Bundle(for: NativeMacosCompatibilityFixtureTests.self).url(forResource:withExtension:)`.
`macos/OmniAgent.xcodeproj/project.pbxproj` gained 4 build files, 4 file
references, 4 group entries, 3 Resources-phase entries and 1 Sources-phase
entry.

1. **`persisted-layout.json`** (prioritised, as instructed) —
   `testPersistedLayoutFixtureRoundTripsAndRepairsExactlyLikeTheWebBuild`
   mirrors `ui/src/state/nativeMacosCompatibility.test.ts` assertion for
   assertion: `SettingsKey.layout == fixture.setting_key`; clean layout
   deserializes to exactly the fixture's tabs; `corrupt_layout` deserializes
   to exactly `repaired_layout.tabs`; plus `serialize -> deserialize` is a
   fixed point. Expected `PersistedTab`s are built by hand from the raw
   dictionaries, **not** by calling the codec under test.
2. **`status-end-events.json`** — two tests.
   `testStatusEventFixtureDecodesAndReEncodesThroughSessionStatusEvent` is a
   real round trip: Swift's `SessionStatusEvent` is the exact decoder for what
   Rust's `SessionStatusEvent` serializes (`tool_execution`/
   `awaiting_approval` raw values included), so it decodes the committed bytes
   and re-encodes to key-sorted-identical JSON.
3. **`rust-session-models.json`** — `testRustSessionModelFixtureMapsOntoTheLayoutRowThisAppPersists`.

> **Deviation, deliberate.** The instruction suggested using
> `CreateSessionRequest`/`SessionExitedEvent` from `SessionConnection.swift`
> for these. They are genuinely different shapes: the fixture's
> `create_session_request` is the *Tauri* app's
> `{project, engine, cwd, briefing, restore_id}` while Swift's
> `CreateSessionRequest` is the *daemon's*
> `{id, command, cwd, env, cols, rows, transcript_path}`; the fixture's
> `session_end_event` is `{id, project, cwd, engine, transcript_path}` while
> Swift's `SessionExitedEvent` is `{id, exit_code}`. Decoding one with the
> other is not possible and faking it would assert nothing. Rather than invent
> mirror types (which the instruction explicitly forbade), those tests assert
> the contract that is genuinely shared: the `engine` value must be one this
> app's `Engine` enum accepts, the `id`/`restore_id` must pass
> `SessionIdentifier.isValid` (it is literally replayed as a `restoreId`), the
> status and end fixtures describe the same session, and a `SessionInfo` the
> Rust side describes must survive a native `PersistedLayoutCodec` save/restore
> cycle unchanged. Each test's own doc comment states this reasoning in place.
> `SessionExitedEvent` is still exercised, on the same session id, so the two
> views of "session ended" are pinned as consistent.

Result: 319 Xcode tests (was 315), 0 failures, at the point these landed.

---

## Important 3 — Release pipeline's final gate can never pass; `sign()` warn-only

**(a) `macos/dist.sh`** — `verify` no longer runs the smoke check. New
`verify-smoke` subcommand carries it, opt-in. The script header (lines 9-29)
documents why in full: the harness speaks Task 1's per-request
JSON-over-newline protocol against a daemon that has used 16-byte-envelope
framing since Task 2, confirmed pre-existing by Tasks 6d and 7; a permanently
red gate trains people to ignore the exit code, which silently voids the
bundle-structure and Gatekeeper checks in the same subcommand. **No attempt
was made to rewrite the harness's wire protocol** — that stays deferred, as
both prior tasks decided. `verify` now prints an explicit pointer to
`verify-smoke` on every run so the check is not forgotten, and prints
`verify: OK` when it actually passes.

**(b) `sign()`** — a missing `Contents/MacOS/omniagent-pty-daemon` is now a
hard `exit 1` with an actionable message (build with `./macos/build.sh
universal`; Debug deliberately skips the embed), matching the
fail-clearly posture the function already had for a missing identity or
entitlements file.

**Verified for real** (against the freshly built universal Release bundle):
- `dist.sh verify` → bundle structure passes and lists both the daemon and the
  single plist; exits 1 **only** because Gatekeeper rejects an unsigned,
  un-notarized app, which is the honest expected result and is labelled as
  such. It can now reach 0 once signed + notarized — before, it could not.
- `dist.sh verify-smoke` → exits 1 with the "EXPECTED until the harness is
  rewritten" explanation.
- `dist.sh badsub` → exits 2 (usage), with `verify-smoke` in the usage line.
- `OMNIAGENT_CODESIGN_IDENTITY="Apple Development: Bruno Bonando (…)" dist.sh
  sign /tmp/nodaemonapp` → exits 1 on the missing daemon. Confirmed it is
  reached *after* the identity checks, so the ordering is credentials-first as
  before.

---

## Important 4 — Native app has no version wiring

The real structure of `project.pbxproj` is **8** `XCBuildConfiguration`
entries, not five: project-level Debug/Release/Preview, app-target
Debug/Release/Preview, test-target Debug/Release.

- `macos/OmniAgent.xcodeproj/project.pbxproj` — `MARKETING_VERSION = 2026.8.3`
  and `CURRENT_PROJECT_VERSION = 1` added to the **three app-target**
  configurations (Debug too, not just Release/Preview — a dogfood Debug build's
  About tab should not lie either). The test target and the project-level
  configurations deliberately carry no user-visible version.
- `scripts/bump-build-version.sh` — takes `project.pbxproj` as a fourth
  argument and rewrites both keys with the same anchored-regex-on-a-known-key
  approach it already used for `Cargo.toml`, with an
  `EXPECTED_XCODE_CONFIGS = 3` count assertion that fails loudly if a build
  configuration is ever added or removed.
- `macos/OmniAgent/SettingsView.swift` — new `enum NativeAppVersion`;
  `SettingsWindowController.present` now passes `NativeAppVersion.current()`
  instead of reading `CFBundleShortVersionString` directly.

> **Deviation, deliberate.** The repo version `2026.8.3+001` is **not** a legal
> `CFBundleShortVersionString` (Apple: one to three period-separated
> integers), so seeding `MARKETING_VERSION` with it verbatim would ship a
> non-conformant Info.plist into a notarized artifact. The date triple goes in
> `MARKETING_VERSION`, the same-day counter in `CURRENT_PROJECT_VERSION`, and
> `NativeAppVersion.compose` recombines them into exactly `2026.8.3+001` for
> the About tab and for `cutover.sh record --version`. Documented in the Swift
> helper, in the bump script, and here.

**Tests** — `NativeAppVersionTests` (3 tests) in
`macos/OmniAgentTests/SettingsViewModelTests.swift` covers recombination
(`2026.8.3` + `1` → `2026.8.3+001`, and `12`/`144`), degradation to the
marketing version alone on a missing/unparseable build number, and `nil` when
there is no version at all.

**Verified with real builds** (this is the acceptance criterion the finding
asked for):
- `./macos/build.sh build` (Debug) → `CFBundleShortVersionString = 2026.8.3`,
  `CFBundleVersion = 1`. Not `1.0`.
- `./macos/build.sh universal` (Release) → same.
- Preview configuration build → same, with
  `CFBundleIdentifier = digital.bruno.omniagent.preview`.
- `bump-build-version.sh` exercised twice on a scratch copy of the four files:
  `2026.8.3+001` → `+002` → `+003`, with `CURRENT_PROJECT_VERSION` following
  to `2` then `3` on all three configurations and the other three files in
  lockstep.

---

## Minor 5 — Preview LaunchAgent plist leaks the build machine's `$HOME`

The phase is the Run Script `Embed PTY Daemon + LaunchAgent Plists (non-Debug)`
in `project.pbxproj` (not `embed-daemon.sh` — that script only *stages* both
plists, correctly).

- The script now derives `PLIST="$PRODUCT_BUNDLE_IDENTIFIER.pty-daemon.plist"`
  — the same `<bundle id>.pty-daemon` rule `DaemonPaths.resolve` /
  `DaemonLaunchAgentPlist` apply in `macos/OmniAgent/DaemonPersistence.swift` —
  and copies only that one. It also hard-errors if the channel's plist is
  missing from the stage, and `rm -f`s any plist an earlier build of the other
  channel left in an incremental build directory, so a bundle can never carry
  two.
- `inputPaths`/`outputPaths` narrowed to the same
  `$(PRODUCT_BUNDLE_IDENTIFIER)`-derived name.

**Verified on real bundles:** the universal Release bundle contains only
`digital.bruno.omniagent.pty-daemon.plist`, and
`grep -rl "$HOME" Contents/Library/LaunchAgents/` finds nothing. The Preview
build contains only `digital.bruno.omniagent.preview.pty-daemon.plist`.

---

## Minor 6 — `crates/brain-ingest` depends on `crates/mcp-server` (layering inversion)

- `project_label_key` moved from `crates/mcp-server/src/tools.rs` to
  `crates/brain-core/src/store.rs` (it names a `settings` row, which is
  `Store`'s own table), re-exported from `crates/brain-core/src/lib.rs`.
- `mcp_server::tools::project_label_key` is now `pub use
  brain_core::project_label_key` — every existing caller path
  (`src-tauri/src/roots.rs` and `mcp-server`'s own tests) is unchanged.
- `crates/brain-ingest/src/roots.rs` calls `brain_core::project_label_key`
  directly; its doc comments updated to point at the new home.

> **Deviation, deliberate.** The finding assumed `mcp-server` had exactly one
> use in `brain-ingest`. It had two: the helper, *and* one genuine cross-seam
> test (`rename_project_survives_a_simulated_reingest_that_resets_the_nodes_own_label`)
> that asserts a rename written by `brain-ingest` is what
> `mcp_server::tools::list_projects` actually renders. Deleting a real
> integration test to satisfy a Cargo.toml line would be the wrong trade, so
> `mcp-server` moved to `[dev-dependencies]` with a comment explaining exactly
> this. A dev-dependency does not propagate: `cargo tree -p
> omniagent-pty-daemon` confirms `brain-ingest` no longer pulls `mcp-server`
> in, which is the layering claim the finding was actually about.

`cargo build --workspace` clean; `cargo test -p brain-ingest` 191 pass, 1
ignored (pre-existing).

---

## Minor 7 — Malformed/empty control payloads drop the whole connection

`crates/omniagent-pty-daemon/src/server.rs`:

- New `decode_payload!` macro, defined inside the dispatch loop (so
  `macro_rules!` hygiene resolves `frame`/`request`/`writer` at its definition
  site) — on a decode error it `send_error`s on the frame's own request id and
  `continue`s to the next frame, `break`ing only if the *write* itself fails.
  This is `MessageKind::Input`'s existing pattern, applied without re-indenting
  23 arms. Applied to all **23** decode sites (15 typed + 8 `serde_json::Value`).
- `parse_json` now treats a **zero-length** payload as `{}`. There are 8
  no-argument kinds (`ListSessions`, `BrainListProjects`,
  `RootsIngestionStatus`, `RootsList`, `RootsBiggestProject`,
  `RootsPausedProjects`, `RootsStaleness`, `RootsRebuild`) — the finding said
  "roughly 15", the real count in the current code is 8.
- **Untouched, as instructed:** envelope validation (1 MiB cap,
  protocol-version byte, unknown message kinds, peer-UID check) and the Hello
  handshake all still terminate the connection.

**Tests** — the four existing tests that asserted the old hangup now assert the
`Error` frame *and* that the connection stays usable, and one is new:
- `malformed_control_json_errors_without_dropping_an_attached_connection` —
  bad `Resize` on a live attachment gets an `Error` on its own request id, and
  a subsequent valid `Resize` on the same socket gets a `Response`.
- `malformed_brain_get_context_payload_errors_without_closing_the_connection`.
- `malformed_roots_and_search_payloads_error_without_closing_the_connection` —
  now drives all six kinds down **one** connection, which is itself the
  assertion.
- **new** `no_argument_kinds_accept_an_empty_payload_and_error_on_invalid_json`
  — all 8 no-arg kinds accept a zero-length payload (7 checked on the happy
  path; `RootsRebuild` excluded there because succeeding would wipe the test
  store, but included in the invalid-JSON half), all 8 answer `{` with an
  `Error`, and the connection survives all of it.

---

## Minor 8 — Session rename: synchronous outline reload + latch bug

`macos/OmniAgent/SessionOutlineView.swift`:

- `editingEnded()` now wraps the reload in `DispatchQueue.main.async`. The
  pending reload is **re-read inside the block** rather than captured, so a
  newer reload landing in between still wins (the module's own "deferred,
  never dropped" rule), and it no-ops if something else already applied it.
  `isRenaming = false` still happens synchronously.
- `beginRename()` gates `isEditing = true` on `makeFirstResponder`'s real
  return value and rolls back the editable appearance on refusal. A row with
  **no window** is treated as "nothing to fail" — there is no window to hold a
  first responder, which is the case in every unit test (cells are driven
  directly, never installed in a window), while in production every cell
  `NSOutlineView` hands out is in one. Documented in the method's doc comment.

**Tests**
- `testAReloadWhileRenamingIsDeferredNotDroppedSoAnOpenFieldSurvives` extended:
  asserts the outline has **not** reloaded immediately after `commitRename`,
  then `flushMainQueue()`, then asserts it has.
- `testAnAbandonedRenameStillReleasesTheDeferredReload` gained the same flush.
- **new** `testTheNewestReloadWinsWhenOneArrivesWhileTheDeferredOneIsInFlight`.
- **new** `testARenameThatCannotTakeFocusIsRefusedRatherThanLatched` — uses a
  real `NSWindow` plus a `StubbornResponderView` that returns `false` from
  `resignFirstResponder()`, producing a **genuine** AppKit
  `makeFirstResponder` failure rather than a stub. Asserts both
  `beginRename()` and `beginRenamingSession(atRow:)` return false, `isRenaming`
  stays false, and a later reload applies immediately.
- New `flushMainQueue()` helper (enqueue-an-expectation-behind-it).

**Mutation-checked:** reverting the latch gate fails
`testARenameThatCannotTakeFocusIsRefusedRatherThanLatched`; reverting the
`DispatchQueue.main.async` fails
`testAReloadWhileRenamingIsDeferredNotDroppedSoAnOpenFieldSurvives`.

---

## Minor 9 — `Dictionary(uniqueKeysWithValues:)` trap inconsistency

Both remaining call sites changed to match
`WorkspaceWindowController.swift:641`'s already-applied form exactly
(`Dictionary(_, uniquingKeysWith: { _, newest in newest })` — last value wins):

- `macos/OmniAgent/SessionOutlineView.swift` `reload(panes:…)`'s `self.panes`.
- `macos/OmniAgent/CommandPalette.swift` `CommandPaletteModel.build`'s `byID`.

No new test: unreachable today (ids are unique upstream) and the existing
outline/palette suites already cover the surrounding behaviour. Covered by the
329-test suite passing.

---

## Minor 10 — Two small state-cleanup leaks

**(a)** `macos/OmniAgent/WorkspaceWindowController.swift` `closePane` now does
`lastStatus.removeValue(forKey: focused)` alongside the `readySessions` /
`sessionStatus` cleanup it already did. `lastStatus` became `private(set)` so
the test can see it.

**(b)** `macos/OmniAgent/SessionConnection.swift` — `pendingReattachSessions`
is now scoped to one reattach round. The subtlety the finding did not name:
a *successful* reattach with a non-empty snapshot produces **no frame carrying
the attach's request id** (the daemon answers with `Snapshot` frames keyed by
*sequence*, and only sends a `Response` on the empty-resume path), so there
was no request-id-keyed hook to remove on success. It is now cleared in four
places: at the start of each `helloAck` reattach round; on a `.response`
matching the request (empty resume); on a `.snapshot` for that session, found
by value since the id is not available; and wholesale in `closeConnection`
(which `disconnect()` routes through).

**Tests**
- **new** `testClosingAPaneForgetsItsLastStatusAlongWithItsOtherPerPaneState`.
- **new** `testASuccessfulReattachDoesNotAccumulateTrackingEntriesAcrossReconnects`
  — two connections, both reattaching successfully with a snapshot; asserts
  the count is 0 after, and 0 after `disconnect()`. Needed a read seam: new
  internal `SessionConnection.pendingReattachCount`, read on `ioQueue` so it
  cannot race the connection's own I/O; its doc says it exists for this test.

**Mutation-checked:** both fail when the respective fix is reverted.

---

## Minor 11 — `SettingsStore` conflates read failure with "unset"

- `macos/OmniAgent/SettingsStore.swift` — `getBool`'s completion is now
  `(Bool?) -> Void`: `.success(value?)` → the parsed bool, `.success(nil)` →
  the caller's default, `.failure` → `nil`. The old `switch try? result.get()`
  collapsed the last two.
- `macos/OmniAgent/SettingsView.swift` — `SettingsViewModel` gained
  `reviewMemoryReadFailed`, `fileTreeWidthReadFailed`,
  `codeReviewWidthReadFailed` (two separate flags because they are two
  independent reads) and a computed `panelsReadFailed`. `refreshReview` /
  `refreshPanels` set them on `.failure` and leave the displayed value alone.
  `setReviewMemory` / `commitFileTreeWidth` / `commitCodeReviewWidth` refuse
  to write while the flag is set and **retry the read instead** — the same
  re-arm-and-retry shape `WorkspaceWindowController.layoutReadFailed` uses for
  `layout` (`layoutReadDispatched = false` on failure,
  `layoutReadCompleted = true` only with the row in hand).
- The UI surfaces it rather than lying: the Review toggle and the width fields
  are `.disabled(…)` while the read failed, with a "Couldn't read this setting
  — reopen Settings once the daemon is back" caption. Deliberately **no value
  is shown**, because the control does not know one.

**Tests**
- `testGetBoolReportsAFailedReadAsNilRatherThanAsTheDefault` (both defaults).
- `testAFailedReviewReadNeverWritesTheDefaultOverTheRealRow` — asserts no
  `set` call reaches the client, the real row is untouched, the refused write
  triggers a retry that reads the real value back, and normal writes resume.
- `testAFailedPanelWidthReadNeverWritesAnEmptyWidthOverTheSavedOne` — same,
  plus asserts the row that *did* read stays independently writable.

**Mutation-checked:** both view-model tests fail with the write gates removed.

**Adjacent case considered and knowingly not changed:** `refreshAccount` reads
`auth_signed_in` through `AuthGate.resolveSignedIn(try? result.get())`, which
has the same `try?` collapse. Left as-is: `resolveSignedIn`'s rule is
`!= "false"`, so a failed read renders "signed in", and both buttons that
follow (`Log out` / `Sign in`) are *explicit user intent*, not a silent
default that a later interaction persists — the specific harm #11 names does
not apply. `resolveSignedIn` is also shared with `AuthGateState`, so changing
it would widen the blast radius well past this wave.

---

## Verification suite

All six commands from the brief, plus the UI suite for good measure.

| # | Command | Result |
|---|---|---|
| 1 | `cargo build --workspace` | **clean** — `Finished dev profile` |
| 2 | `cargo test --workspace --no-fail-fast` | 3 failures, **all three confirmed pre-existing flakes** (below) |
| 3 | `cargo clippy --all-targets --all-features` | 7 warnings, **all pre-existing**, none in changed code |
| 4 | `./macos/build.sh test` | **329 tests, 0 failures** (315 at branch start) |
| 5 | `./macos/build.sh build` | **BUILD SUCCEEDED** |
| 6 | `./macos/build.sh universal` + `dist.sh verify` | **BUILD SUCCEEDED**; verify passes structure, fails only on Gatekeeper (unsigned) |
| + | `cd ui && npm test` | 78 files, **1181 pass**, 8 skipped |

**The 3 cargo-test failures, each individually confirmed pre-existing:**

1. `omniagent-ade` `sessions::tests::codex_gets_omniagent_mcp_wiring` — passes
   100% in isolation (`cargo test -p omniagent-ade --lib codex_gets…` → ok).
   This is exactly the "sessions.rs test-isolation race on a shared real path"
   the Task 7 ledger line documents. `sessions.rs` is untouched by this wave.
2. `omniagent-pty-daemon` `one_persistent_connection_streams_raw_bytes_and_applies_resize`
3. `omniagent-pty-daemon` `roots_add_rename_pause_and_staleness_round_trip_through_the_daemon`

   Both pass in isolation and both are the documented "server_protocol.rs
   timing-tight tests under build-load contention" flake. **Verified against a
   clean baseline worktree at `37e0511`**: running
   `cargo test -p omniagent-pty-daemon --test server_protocol` four times at
   the base commit produced 3 failures out of 4 runs (`13 passed; 1 failed`,
   `ok`, `12 passed; 2 failed`, `13 passed; 1 failed`) — i.e. the baseline is
   equally flaky and this wave did not make it worse. Worktree removed
   afterwards.

**The 7 clippy warnings, all pre-existing:** 6 × `doc list item without
indentation` in `src-tauri/src/roots.rs`'s module doc (this wave's only change
to that file is 7 `brain.store.lock()` → `brain.locked_store()?` lines — `git
diff 37e0511 -- src-tauri/src/roots.rs` touches no `//` lines) and 1 ×
`type_complexity` in `brain-ingest` (reproduced at baseline via `git stash`
before any of this wave's changes).

**Also verified by hand** (findings 3–5 end to end): Debug/Release/Preview
`Info.plist` versions; single-plist-per-channel in both a Release and a
Preview bundle; no `$HOME` string in a production bundle's LaunchAgents;
`dist.sh verify`/`verify-smoke`/usage exit codes (1/1/2); `dist.sh sign`
refusing a daemon-less bundle; `bump-build-version.sh` run twice on a scratch
tree.

---

## Files changed (26)

```
crates/brain-core/src/lib.rs
crates/brain-core/src/store.rs
crates/brain-ingest/Cargo.toml
crates/brain-ingest/src/roots.rs
crates/mcp-server/src/tools.rs
crates/omniagent-pty-daemon/src/server.rs
crates/omniagent-pty-daemon/tests/server_protocol.rs
macos/OmniAgent.xcodeproj/project.pbxproj
macos/OmniAgent/CommandPalette.swift
macos/OmniAgent/SessionConnection.swift
macos/OmniAgent/SessionOutlineView.swift
macos/OmniAgent/SettingsStore.swift
macos/OmniAgent/SettingsView.swift
macos/OmniAgent/WorkspaceWindowController.swift
macos/OmniAgentTests/NativeMacosCompatibilityFixtureTests.swift   (new)
macos/OmniAgentTests/SessionConnectionTests.swift
macos/OmniAgentTests/SessionOutlineTests.swift
macos/OmniAgentTests/SettingsStoreTests.swift
macos/OmniAgentTests/SettingsViewModelTests.swift
macos/OmniAgentTests/WorkspaceWindowControllerTests.swift
macos/dist.sh
scripts/bump-build-version.sh
src-tauri/src/commands/mod.rs
src-tauri/src/feedback.rs
src-tauri/src/map_feed.rs
src-tauri/src/roots.rs
```

1587 insertions, 219 deletions.

---

## Self-review — findings and concerns

**Things I checked deliberately and am satisfied with:**

- Every behavioural fix has a test that was **confirmed to fail without the
  fix** (mutation-checked): #1 (both the brain-core and daemon tests), #7
  (implicitly — the four rewritten tests assert the opposite of the old
  behaviour), #8 both halves, #10 both halves, #11 both halves. #6 and #9 are
  pure refactors with no behaviour change; #2/#3/#4/#5 were verified against
  real builds and real script runs rather than by mutation.
- `decode_payload!`'s `macro_rules!` hygiene: it is defined *inside* the
  dispatch loop precisely so the outer `frame`/`request`/`writer` resolve.
  A definition outside the loop would not have compiled.
- The `parse_json` empty→`{}` change also reaches the Hello handshake, where an
  empty payload now fails on "missing field `client`" instead of EOF — still an
  error, still closes the connection, and
  `runtime_permissions_peer_policy_and_bad_frames_are_enforced` still passes.
- `git status` is clean; the temporary baseline worktree was removed and
  `git worktree list` shows only the repo and the pre-existing
  `OmniAgent-ADE-native-macos` worktree that was there before I started.

**Concerns worth the reviewer's attention:**

1. **`Store::reopen_if_replaced` costs a `stat(2)` per store operation.** I
   chose per-operation over a timer/lazy scheme because it has no correctness
   window and no extra state. On a hot path this would matter; these are all
   control-plane operations that go on to do SQLite work, so it does not. If
   the reviewer disagrees, the natural knob is to check only in the *write*
   paths, which is where the data loss actually happens.
2. **The `stat`-based check is a detector, not a lock.** Two processes
   rebuilding within the same instant can still interleave (both unlink, both
   create). The outcome is that both converge on whichever file won, with no
   silent divergence — strictly better than the current behaviour, but it is
   not a distributed lock and I did not build one. A shared lock file was the
   finding's alternative suggestion; it is a bigger change and, given "Rebuild
   brain" is a rare, explicit, human-initiated action, I judged the detector
   sufficient.
3. **`brain-ingest` keeps `mcp-server` as a dev-dependency.** Deliberate (see
   #6), but it is a deviation from the finding's literal wording and the
   reviewer may prefer the test deleted instead.
4. **`MARKETING_VERSION` is `2026.8.3`, not `2026.8.3+001`.** Deliberate (see
   #4) — `+001` is not a legal `CFBundleShortVersionString`. Anything that
   greps the Xcode project for the full repo version string will not find it;
   it must go through `NativeAppVersion.compose` or read both keys.
5. **`beginRename()` treats "no window" as success.** Necessary to keep the
   rename path testable headlessly (every existing test drives cells outside a
   window). The genuine-refusal case is covered by a real `NSWindow` +
   `StubbornResponderView` test, so the branch that matters is exercised.
6. **`pendingReattachCount` is production API that exists for a test.** It is
   a 1-line read-only computed property with a doc comment saying so. The
   alternative was leaving the leak fix unasserted.
7. **`dist.sh verify` still cannot reach exit 0 on this machine**, because
   `spctl --assess --type execute` requires notarization, which needs Apple's
   service. What changed is that it *can* now, once signed and notarized — the
   permanently-red blocker is gone. I could not prove the 0 case end to end
   without submitting a real notarization request, which I judged out of scope.
8. **Pre-existing daemon test flakiness is real and unaddressed.**
   `server_protocol.rs` fails ~75% of full-suite runs at the base commit. It
   is not this wave's regression (proved against a baseline worktree) and
   fixing it is a separate piece of work, but it does mean the daemon suite's
   green/red signal is currently unreliable for anyone reviewing this.
9. **Task 4's external release gate remains unrun**, exactly as the review
   said. Nothing here changes that.
