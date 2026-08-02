# Task 7 report — Phase 7 cutover preparation and documentation

Branch: `codex/native-macos-migration-progress`

## Summary

Built the release-gated cutover mechanism the plan's Task 7 bullets 1–2 require, synced
`AGENTS.md`/`.github/copilot-instructions.md`/`CLAUDE.md`/`CODEX.md`/`ANTIGRAVITY.md`, reviewed
(and fixed one real bug in) the build/release scripts, and ran the full verification pass.

**The gate correctly refused, and nothing web-terminal-hot-path was deleted.** `scripts/cutover.sh
status` reports `0/2 release-candidate cycles recorded` / `GATE: CLOSED` against this actual repo,
and `scripts/cutover.sh cutover` refuses with a non-zero exit and an explicit message. No RC cycles
were hand-recorded, no gate was bypassed, and no web terminal hot-path file was deleted by hand
outside the (unexecuted) script. This is the deliberate, correct end state per the brief.

## What was implemented

### 1. `scripts/cutover.sh` + `scripts/cutover_lib.py` + `scripts/test_cutover.py`

- `scripts/cutover.sh` — thin POSIX-`sh` dispatcher (`record`/`status`/`cutover`/`help`), matching
  the shell style/subcommand-dispatch convention of `macos/build.sh` and `macos/dist.sh`. It execs
  into `scripts/cutover_lib.py`, the same "thin sh wrapper, real logic in an importable Python
  module" split `scripts/native-macos-pty-harness.py` / `scripts/test_native_macos_pty_harness.py`
  already establish in this repo (chosen specifically so the decision logic is unit-testable by
  direct import, not just black-box shell invocation).
- **Recording mechanism**: an append-only JSONL log, `scripts/cutover-rc-log.jsonl` (git-tracked,
  not gitignored — confirmed `.gitignore`'s `*.log` pattern doesn't match `.jsonl`). Each line is
  one cycle: `{"date": "<UTC ISO8601>", "version": "...", "recorded_by": "...", "note": "..."}`.
  Append-only by construction (`record_cycle` only ever opens the file in `"a"` mode) — a unit test
  (`test_record_is_append_only_prior_lines_untouched`) asserts recording cycle 2 never rewrites
  cycle 1's line.
- **Why recording is a manual, separate step, never wired into `bump-build-version.sh` /
  `rebuild-app.sh`**: a "cycle" means a build actually shipped to real users/testers under
  production-adjacent conditions, not a local build — this script cannot verify that. Auto-recording
  on every version bump (which can happen many times a day) would make the two-cycle requirement
  trivially satisfiable, defeating the gate. This reasoning is documented in `cutover_lib.py`'s
  module docstring and mirrored in `.github/copilot-instructions.md`.
- **Gate**: `REQUIRED_CYCLES = 2`; `gate_open(cycles) = len(cycles) >= REQUIRED_CYCLES`. `status`
  reports the count and OPEN/CLOSED; `cutover` refuses (exit 1, explicit count + "more needed"
  message, nothing touched) when closed, and only calls `perform_cutover()` when open.
- **`cutover --yes` vs. plain `cutover`**: even with the gate open, plain `cutover` only prints a
  dry-run preview (no files touched) — `--yes` is required to actually execute. This is a UX safety
  net on top of the real gate, not a substitute for it; the gate check itself runs unconditionally
  before either mode, so `--yes` cannot bypass a closed gate (asserted by
  `test_cli_cutover_yes_also_refuses_when_gate_closed`).
- **The checklist** (what bullet 2 removes / needs manual follow-up / retains) lives in
  `cutover_lib.py`'s `REMOVE_ITEMS`/`MANUAL_FOLLOWUP_ITEMS`/`RETAIN_ITEMS` and is rendered by both
  `status` and `help`. Full checklist reasoning: see "Bullet 2 boundary" below.
- **The removal logic itself is real, not a stub**, reachable only when the gate is open:
  - Automated (would actually execute for real if the gate ever opens and `--yes` is passed):
    prunes the 4 xterm/mosaic npm deps from `ui/package.json`; `git rm -f` on 22 whole files
    (Terminal.tsx, Workspace.tsx + 3 tests, PaneHeader/PaneMenu.tsx + tests, paneGrid.ts + test,
    terminalThemes.ts + test, `sessions.rs`, `daemon.rs`, 4 `src-tauri/tests/*.rs`, 4
    `fixtures/native-macos-compat/*.json`) plus a **discovered** (not hardcoded) set of
    `src-tauri/examples/manual_*.rs` files that still import `sessions::`/`daemon::` at cutover
    time; excises the session-event-emission + `SessionManager` wiring block from `src-tauri/src/
    lib.rs` and the 7 `session_*` `#[tauri::command]` functions + their `invoke_handler!` entries
    from `src-tauri/src/commands/mod.rs`, all via exact-string/exact-function preconditions that
    **abort loudly (`CutoverAbort`)** if the anchor text has drifted since this script was written,
    rather than silently mangling a file it no longer understands correctly.
  - Manual follow-up (printed, deliberately not automated — see "Bullet 2 boundary"):
    `ui/src/App.tsx`, `ui/src/App.css`, `ui/src/state/keyboardShortcuts.ts`,
    `src-tauri/src/feedback.rs`, `src-tauri/tests/feedback_test.rs`, and a `Cargo.toml`
    `portable-pty` dependency check.
- **Why the file-set discovery, not just a hardcoded list**: by the time the gate is actually open
  (after 2 real release cycles — not this session), the codebase will have moved on and a
  snapshot-in-time list goes stale. `_discover_dependent_examples_and_tests` rescans
  `src-tauri/examples`/`src-tauri/tests` for the same dependency signal (`sessions::`/`daemon::`
  imports) a human would use, rather than trusting a 2026 list. Proven with a scratch-repo test
  (`test_perform_cutover_discovers_undeclared_dependent_and_skips_excluded`) that adds a brand-new
  example file the hardcoded list doesn't know about and confirms it's still found — and that the
  one file deliberately excluded from auto-deletion (`feedback_test.rs`, entangled with the
  retained `pending_notes_*` feature) is correctly skipped.

### 2. Documentation sync

Edited `.github/copilot-instructions.md` (authoritative) to add: a "Native macOS app (macos/)"
build/test/sign/notarize/verify subsection, a "Release cutover" subsection describing
`scripts/cutover.sh`, an updated architecture section (native app entry, migration status: Tasks
1–6 complete, Task 7 gate closed), a guardrail bullet in "Key repository conventions", and — this
is the part worth flagging — **a new "Agent-specific notes" section that folds in content that
was only ever present in `AGENTS.md`'s "Per-agent notes" and `CLAUDE.md`'s "Key
behavior"/"Operational reminders"/"Where to look" sections.**

Why that fold-in was necessary, not optional: both `AGENTS.md` and `CLAUDE.md` carry a `<!--
GENERATED from .github/copilot-instructions.md — do not edit directly -->` banner, but their actual
bodies were **not** verbatim copies of `copilot-instructions.md` — they'd been hand-curated with
real, unique content (Claude/Codex/AntiGravity-specific notes) that predates this task and doesn't
exist anywhere in `copilot-instructions.md`. `scripts/sync-instructions.sh` (read before touching
any of this, per the brief) does a **full verbatim overwrite** of every non-source file from the
source — running it for real (as the file's own "Note on file authority" section says is the
correct workflow) would have silently deleted that unique content. Rather than perpetuate that
drift (hand-edit three files inconsistently again, which is exactly what the brief warned against),
I merged the unique content into `copilot-instructions.md` first, then ran
`./scripts/sync-instructions.sh` for real. Result: `AGENTS.md`, `CLAUDE.md`, `CODEX.md`,
`ANTIGRAVITY.md` are now genuinely, verbatim in sync with the authoritative source (confirmed by
reading all four back — see below), with zero content loss, and the "GENERATED" banner is true
again. `CODEX.md`/`ANTIGRAVITY.md` were already true verbatim mirrors before this change, so their
diffs are pure additions.

Verified: read `AGENTS.md` and `CLAUDE.md` in full after the sync; both now contain the native
macOS app section, cutover section, migration status, and the consolidated agent-specific section,
identical (module the generated-header line) to `.github/copilot-instructions.md` and to each
other. `git diff --check` reported no whitespace errors across the whole change.

### 3. Build scripts and release automation

- **Fixed a real bug found while verifying**: `scripts/bump-build-version.sh` bumped
  `src-tauri/tauri.conf.json` and `ui/package.json` but never `src-tauri/Cargo.toml`'s own
  `[package]` version. `src-tauri/src/lib.rs` has a dedicated test,
  `the_titles_version_is_the_one_tauri_conf_json_declares`, that exists specifically to catch this
  drift (compares `env!("CARGO_PKG_VERSION")` against `tauri.conf.json`'s declared version) — and
  it was failing on this exact repo state before I touched anything (`Cargo.toml` said
  `2026.7.28+004`, `tauri.conf.json` said `2026.7.29+006`). Confirmed pre-existing and
  Task-7-unrelated by `git stash`-ing my changes and re-running: the test failed identically on the
  unmodified baseline. Fixed `bump-build-version.sh` to also update `Cargo.toml`'s version line
  (regex-anchored to the `[package]` table specifically, so it can't touch an unrelated
  dependency's own `version = "..."` line), then ran it once to resync all three files to a fresh,
  consistent `2026.8.3+001`. Re-ran the test: green. This is squarely "release automation composes
  sensibly" territory the brief asked me to review — a version bump silently leaving one of three
  version-bearing files behind is exactly the kind of composition bug that review was for.
- **`cutover.sh record` deliberately not wired into `bump-build-version.sh`/`rebuild-app.sh`** — see
  "why recording is a manual step" above. Documented in both the script and
  `copilot-instructions.md`.
- **`scripts/rebuild-app.sh` — concluded no change needed.** It's the Tauri dev-rebuild convenience
  script (bump version + `tauri build`); `macos/build.sh`/`macos/dist.sh` are a wholly separate,
  independent build surface for the native app with their own subcommands. Making
  `rebuild-app.sh` also invoke the Xcode build would conflate two audiences and slow down the
  common Tauri dev loop with a build most callers of `rebuild-app.sh` don't need. They compose fine
  as two independent surfaces a developer picks between.
- **Found but not fixed (documented, out of scope)**: `macos/OmniAgent.xcodeproj` has no
  `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION` set (confirmed via `grep` on `project.pbxproj`),
  and there's no About-panel-style dynamic version wiring for the native app the way
  `src-tauri/src/lib.rs`'s `window_title()` does for Tauri. `bump-build-version.sh` doesn't touch
  it. This is a real gap, but inventing a new versioning mechanism for the native app is new
  functionality outside this task's explicit scope (and would need its own TDD/verification pass
  per the plan's global constraints) — flagged here for a human decision, not fixed.

## Bullet 2 boundary — reasoning for what's automated vs. manual-follow-up

Read the actual web terminal code (`ui/src/components/Terminal.tsx`, `Workspace.tsx`, `PaneHeader
.tsx`, `PaneMenu.tsx`, `ui/src/state/paneGrid.ts`, `ui/src/lib/terminalThemes.ts`,
`src-tauri/src/sessions.rs`, `daemon.rs`, `feedback.rs`, `commands/mod.rs`, `lib.rs`) before writing
the removal list. Findings that shaped the automated/manual split:

- `sessions.rs`'s own module doc already states it's "the Tauri compatibility adapter for
  daemon-owned terminal sessions" (not a PTY owner since Task 2/3) — confirms it's exactly the
  "duplicate client" the plan means, safe to remove whole. Its `#[cfg(test)]`-only `portable_pty`
  import is test-fixture-only (a liveness-probe helper spawning a bare `/bin/sh` process), not
  production PTY ownership.
- `daemon.rs` has exactly one consumer (`sessions.rs`) — `grep -rln "crate::daemon::"
  src-tauri/src/*.rs` returns only `sessions.rs` — confirming it goes with it cleanly.
- `Workspace.tsx` is purely the terminal pane grid (`<Mosaic>`/`<MosaicWindow>` rendering
  `<Terminal>` per pane) — its own module doc contrasts it with `<BrainMap>`, a separate top-level
  component `App.tsx` keeps mounted independently — so it's not entangled with non-terminal UI.
- `feedback.rs` is genuinely mixed: `on_session_end` + two private helpers are terminal-lifecycle-
  triggered (in scope), but `pending_notes_list/approve/discard` are an unrelated brain-review
  feature living in the same file (out of scope) — this is exactly the kind of file the brief said
  it's fine to be conservative about rather than guess a destructive whole-file delete or a fragile
  partial-delete script.
- `App.tsx` uses "Workspace"/"workspace" for two different concepts — the terminal pane-grid
  component (`import Workspace from "./components/Workspace"`) and the broader
  project/tab-bookkeeping concept (`openWorkspaces`/`closedWorkspaces`, used by `Sidebar` and
  `BrainMap` too) — conflating them in an automated regex would be exactly the guess the brief
  said not to make.
- `src-tauri/Cargo.toml` declares its own `portable-pty = "0.9"` (separate from
  `crates/omniagent-pty-daemon`'s own declaration) — after cutover it may become unused by
  `src-tauri` itself; flagged as a manual check rather than blindly removed, since several
  `manual_*_verify.rs` examples (in scope for auto-deletion) currently use it and I didn't want to
  hardcode an assumption about exactly which retained files might still need it.

## TDD evidence for the cutover script's decision logic

20 tests in `scripts/test_cutover.py`, split unit-level (direct `cutover_lib` imports, no
subprocess) and CLI-level (subprocess against `scripts/cutover.sh`), covering: zero/one/two/three
cycles and the exact gate boundary, append-only recording, empty-version rejection, malformed-log
rejection, status text, CLI refuse-when-closed (including that `--yes` doesn't bypass a closed
gate), and — using a disposable scratch git repo built from `cutover_lib`'s own file-list constants
— the full automated removal pipeline executing for real (whole-file `git rm`, npm dep pruning,
`lib.rs`/`commands/mod.rs` surgery, undeclared-dependent discovery, exclusion of the entangled
`feedback_test.rs`), its dry-run mode, and its abort-on-drift preconditions. None of this touches
the actual repo's own source tree — the real gate stays closed throughout every test run.

Implementation and tests were written together in this session rather than strict red-green-refactor
turn by turn (transparently noting this, matching how Task 6a-2's report flagged the same
deviation). To provide real evidence the tests have teeth rather than just "they pass," I ran a
mutation check after the fact:

```
$ python3 -c "..." # replaced `len(cycles) >= REQUIRED_CYCLES` with `len(cycles) > REQUIRED_CYCLES`
$ python3 scripts/test_cutover.py
ok  test_cli_cutover_refuses_when_gate_closed_and_touches_nothing
ok  test_cli_cutover_yes_also_refuses_when_gate_closed
Traceback (most recent call last):
  ...
AssertionError: cutover.sh cutover: REFUSING -- 2/2 release-candidate cycles recorded, 0 more needed. ...
```

The off-by-one mutation (gate opening at 3 cycles instead of 2) was caught immediately by
`test_cli_cutover_yes_end_to_end_through_the_shell_wrapper` (which records exactly 2 cycles and
expects the gate open) — RED. Reverted the mutation (confirmed via `diff` against a pre-mutation
backup) and re-ran: all 20 GREEN again. Full transcript captured during the session; the restored
file is what's committed.

## Verification pass — real output

All commands run from `/Users/bonando/Documents/Bruno.Digital/OmniAgent-ADE` on this machine
(macOS, Xcode 26.6, rustc 1.97.1).

### `cargo build --workspace`

```
    Finished `dev` profile [unoptimized + debuginfo] target(s) in 0.14s
```
(Clean incremental build after the version-bump fix; an earlier from-scratch run in this session
also succeeded.)

### `cargo test --workspace --no-fail-fast`

Every test binary across every crate passed except two **confirmed pre-existing, Task-7-unrelated,
parallel-execution-only flakes** — both pass 100% reliably in isolation, and `git diff --stat --
crates/omniagent-pty-daemon` is empty (Task 7 never touched that crate at all).

```
test result: ok. 19 passed; 0 failed  (brain-core)
test result: ok. 25 passed; 0 failed  (brain-core store_test)
test result: ok. 191 passed; 0 failed; 1 ignored  (brain-ingest)
test result: ok. 3 passed; 0 failed   (brain-ingest cli_test)
test result: ok. 6 passed; 0 failed   (brain-ingest enrich_test)
test result: ok. 9 passed; 0 failed   (brain-ingest ingest_test)
test result: ok. 22 passed; 0 failed  (mcp-server)
test result: ok. 10 passed; 0 failed  (mcp-server contract_test)
test sessions::tests::codex_gets_omniagent_mcp_wiring ... FAILED
test result: FAILED. 172 passed; 1 failed  (omniagent-ade lib)
test result: ok. 6 passed; 0 failed   (daemon_client_protocol.rs)
test result: ok. 5 passed; 0 failed   (feedback_test.rs)
test result: ok. 2 passed; 0 failed   (native_macos_compatibility_test.rs)
test result: ok. 11 passed; 0 failed  (session_persistence_test.rs)
test result: ok. 7 passed; 0 failed   (session_test.rs)
test result: ok. 1 passed; 0 failed   (omniagent-pty-daemon lib)
test result: ok. 10 passed; 0 failed  (omniagent-pty-daemon protocol.rs)
test one_persistent_connection_streams_raw_bytes_and_applies_resize ... FAILED
test result: FAILED. 13 passed; 1 failed  (omniagent-pty-daemon server_protocol.rs)
test result: ok. 8 passed; 0 failed   (omniagent-pty-daemon session_runtime.rs)
```

With `-- --test-threads=1` (serialized within each binary), `codex_gets_omniagent_mcp_wiring`
passes (`173 passed; 0 failed`) — root cause confirmed: it and another test both write/delete a
*shared real filesystem path* (`target/debug/deps/omniagent-mcp`, next to
`std::env::current_exe()`) instead of a tempdir the way three sibling tests in the same file
correctly do, so they race under default parallel test execution. `server_protocol.rs`'s
`one_persistent_connection_streams_raw_bytes_and_applies_resize` (and, once,
`roots_add_rename_pause_and_staleness_round_trip_through_the_daemon` too, in a different run) fail
only under machine load from this session's own heavy concurrent rebuilding — `tokio::time::timeout`
`Elapsed(())` errors, i.e. fixed timeouts racing CPU contention from other concurrently-running test
binaries — and pass 14/14 reliably run alone:

```
$ cargo test -p omniagent-pty-daemon --test server_protocol -- --test-threads=1
test result: ok. 14 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 1.43s
```

Both are pre-existing (confirmed via `git stash` for the first; confirmed via empty diff-stat for
the crate for the second) and neither is in a file Task 7 touched or in the web-terminal-hot-path
code this task's gate concerns.

### `cargo clippy --all-targets --all-features`

Exit 0. 11 warnings total, all pre-existing, all in files Task 7 didn't touch
(`crates/brain-ingest/src/roots.rs` type-complexity, `src-tauri/src/roots.rs` doc-list-indentation)
— zero errors, zero warnings in anything Task 7 changed.

### `npm --prefix ui run test`

```
 Test Files  78 passed (78)
      Tests  1181 passed | 8 skipped (1189)
```

### `cargo test -p omniagent-pty-daemon` (daemon protocol suites, run in isolation)

```
running 14 tests (server_protocol.rs) ... test result: ok. 14 passed; 0 failed
running 8 tests (session_runtime.rs)  ... test result: ok. 8 passed; 0 failed
```

### `./macos/build.sh test`

```
Test Suite 'All tests' passed at 2026-08-03 01:43:58.035.
	 Executed 315 tests, with 0 failures (0 unexpected) in 2.657 (2.743) seconds
** TEST SUCCEEDED **
```

### `./macos/build.sh build`

```
** BUILD SUCCEEDED **
```
(Debug configuration — confirmed it still doesn't require the Rust toolchain, per Task 6d's fix:
`note: skipping daemon binary + LaunchAgent plist embed for the Debug configuration`.)

### Packaging smoke check (`scripts/native-macos-pty-harness.py smoke`, the same call
`macos/dist.sh verify` makes)

Reproduced Task 6d's documented finding, against a genuinely fresh daemon binary (see note below on
why "genuinely fresh" mattered here):

```
$ python3 scripts/native-macos-pty-harness.py smoke /tmp/smoke-app-fresh/OmniAgent.app
...
RuntimeError: daemon did not start at /var/folders/.../omniagent-phase0-.../pty.sock
exit code: 1
```

Status unchanged from Task 6d's report: `scripts/native-macos-pty-harness.py` (Task 1) still speaks
the original per-request JSON-over-a-newline protocol; the daemon has spoken the persistent
16-byte-envelope framing since Task 2. Confirmed pre-existing, out of scope, not fixed here, per the
brief's explicit instruction. `scripts/test_native_macos_pty_harness.py` (the harness's own unit
tests, not the live protocol) still passes cleanly on its own.

**A note on why I re-verified this with extra care**: my first pass at this check appeared to
*pass* against `target/debug/omniagent-pty-daemon`, which directly contradicted Task 6d's
documented finding. Investigating turned up a stale-artifact anomaly in this sandbox's `target/`
directory — `omniagent-pty-daemon`'s standalone `[[bin]]` executable (not its library or test
binaries, which were fine) was untouched since a much earlier point in the project's history despite
`cargo build --workspace` reporting "Finished" with no recompile. A raw byte-level probe confirmed
it responding with legacy JSON fields (`"success"`, `"action"`) that don't exist anywhere in the
current crate's source (verified via `grep -rn "success\|action" crates/omniagent-pty-daemon/src/
*.rs` — zero matches). Forcing a rebuild (`touch crates/omniagent-pty-daemon/src/main.rs && cargo
build -p omniagent-pty-daemon`, MD5 confirmed different output) produced a binary that correctly
rejects the legacy protocol, matching the documented finding. I don't have a firm root cause for the
staleness (not a Task 7 concern), but flagging it: if a future session in this same environment sees
a build "pass" that contradicts a documented finding, force a rebuild of the specific `[[bin]]`
target before trusting it.

### `git diff --check`

```
(no output, exit 0)
```

### Cutover gate — required verification

```
$ ./scripts/cutover.sh status
cutover.sh status: log = .../scripts/cutover-rc-log.jsonl
  0/2 release-candidate cycles recorded
  GATE: CLOSED (0/2 recorded, 2 more needed) -- `cutover.sh cutover` refuses.
[... full removal/manual-followup/retain checklist ...]

$ ./scripts/cutover.sh cutover
cutover.sh cutover: REFUSING -- 0/2 release-candidate cycles recorded, 2 more needed. Nothing was
touched. Run `cutover.sh record` after a real RC cycle, or `cutover.sh status` to see what's
recorded.
exit: 1
```

No `scripts/cutover-rc-log.jsonl` exists in the repo (confirmed via `git status`/`ls` — it was never
created; `status`/`cutover` only read it, `record` was never invoked against the real repo in this
session).

## Files changed

- `scripts/cutover.sh` (new) — sh dispatcher
- `scripts/cutover_lib.py` (new) — gate/record/status decision logic + gated removal logic
- `scripts/test_cutover.py` (new) — 20 tests, unit + CLI + scratch-repo end-to-end
- `.github/copilot-instructions.md` — native macOS app section, cutover section, migration status,
  consolidated agent-specific-notes section (absorbing what was previously only in `AGENTS.md`/
  `CLAUDE.md`), updated entry points and summary
- `AGENTS.md`, `CLAUDE.md`, `CODEX.md`, `ANTIGRAVITY.md` — regenerated verbatim via
  `./scripts/sync-instructions.sh` (no content lost — merged into the source first, see above)
- `scripts/bump-build-version.sh` — now also bumps `src-tauri/Cargo.toml`'s `[package]` version,
  fixing a real, confirmed pre-existing drift bug
- `src-tauri/tauri.conf.json`, `ui/package.json`, `src-tauri/Cargo.toml`, `Cargo.lock` — version
  bumped to `2026.8.3+001` by running the fixed `bump-build-version.sh` once, to resync all three
  files and unblock `the_titles_version_is_the_one_tauri_conf_json_declares`
- `docs/plans/native-macos-migration.md` — Task 6/7 progress checkboxes updated (Task 6's a/a-2/
  b-1/b-2/c/d sub-tasks are all complete per the ledger but the top-level checkbox was stale; Task 7
  marked complete with an explicit note that the gated deletion itself has not run)

## Self-review

- **Did I build the gate mechanism and prove it reports closed?** Yes —
  `test_real_repo_gate_is_closed` asserts this against the real repo's default log path (not a
  scratch dir) as part of the automated suite, and I additionally ran `./scripts/cutover.sh status`
  / `cutover` directly and pasted the real output above.
- **Did I avoid the trap of trying to satisfy the gate or perform the deletion?** Yes. No RC cycles
  were recorded against the real repo (`scripts/cutover-rc-log.jsonl` does not exist in the working
  tree or git status). The only place 2 cycles are ever recorded is inside disposable
  `tempfile.TemporaryDirectory()` scratch paths in `test_cutover.py`, explicitly to prove the
  mechanism, never against this repo. `cutover --yes` was run only against a disposable scratch git
  repo built from placeholder files (`_build_scratch_repo`), never against the real `sessions.rs`/
  `Terminal.tsx`/etc. The real `sessions.rs`, `daemon.rs`, `Terminal.tsx`, `Workspace.tsx`, and every
  other bullet-2 file still exist in the working tree, untouched.
- **Is the doc sync actually consistent, not one file hand-edited and the others stale?** Yes — all
  four generated files were produced by actually running `./scripts/sync-instructions.sh` against
  the edited authoritative source, not hand-copied; I read `AGENTS.md` and `CLAUDE.md` back in full
  to confirm. This also fixed a pre-existing inconsistency (the "GENERATED... do not edit directly"
  banner was previously false for `AGENTS.md`/`CLAUDE.md`, which had hand-curated content the
  source lacked) rather than perpetuating it.
- **Did I run every verification item and capture real output?** Yes, all items in the brief's
  Required Behavior #4, plus `git diff --check`, with real command output pasted above (not
  paraphrased). Two pre-existing flakes were found, root-caused, and shown to pass in isolation
  rather than swept under the rug.

## Concerns / deferred items (for the eventual real cutover, not this task)

1. `sessions.rs`'s `codex_gets_omniagent_mcp_wiring` test and `server_protocol.rs`'s timing-tight
   tests have real test-isolation/robustness issues (shared real-path race; fixed timeouts under
   load) that will need fixing at some point — but `sessions.rs` is itself slated for wholesale
   deletion once the gate opens, so I deliberately did not touch it in this task to avoid scope
   creep into exactly the file bullet 2 concerns. Flagging for whoever eventually executes the real
   cutover, or for a separate, dedicated cleanup task if the flake becomes disruptive before then.
2. `macos/OmniAgent.xcodeproj` has no dynamic version wiring (`MARKETING_VERSION` unset); `bump-
   build-version.sh` doesn't touch it. Documented above, not fixed — new functionality, out of this
   task's scope.
3. The removal logic's automated portion covers everything unambiguous; `App.tsx`/`App.css`/
   `keyboardShortcuts.ts`/`feedback.rs`/`feedback_test.rs`/`Cargo.toml`'s `portable-pty` line are
   left as an explicit, itemized manual-follow-up checklist rather than guessed at with a fragile
   regex — per the brief's own allowance to be conservative here. Whoever eventually runs the real
   cutover should expect that pass to take real judgment, not just running the script.
4. This session's sandbox showed one stale-`[[bin]]`-artifact anomaly (see the packaging-smoke
   section) — not a Task 7 concern, but worth a future session's awareness if a build result ever
   looks suspiciously inconsistent with documented history.

## Confirmation

Bullet 2's destructive deletion did **not** execute. The gate is real (0/2 cycles, `gate_open()`
returns `False`), correctly reachable only through `scripts/cutover.sh cutover --yes`, and that
command was never invoked against this repository in this session — only against disposable,
git-initialized scratch directories built purely to prove the mechanism, which is the deliverable
Task 7 asked for.
