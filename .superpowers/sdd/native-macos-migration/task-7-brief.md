# Task 7 — Phase 7 cutover preparation and documentation

Final task of `docs/plans/native-macos-migration.md`. Plan text (Task 7 section):

> - Add a release-gated cutover script/checklist that refuses destructive web-hot-path deletion until two release-candidate cycles are recorded.
> - After the gate is met, make the native app production, retain the Tauri rollback artifact for one release, and remove xterm.js, React Mosaic, terminal Tauri events/commands, duplicate clients, polling, proxy PTYs, and frontend terminal buffers.
> - Update `AGENTS.md`, `.github/copilot-instructions.md`, `CLAUDE.md` where applicable, build scripts, and release automation together.
> - Verify Rust, clippy, UI tests while retained, Xcode tests, protocol tests, and packaging smoke checks.

**Read first:** `.superpowers/sdd/native-macos-migration/progress.md` (the full ledger — every prior task's completion state, commit ranges, and every deferred Minor finding across Tasks 1-6d) and skim the task reports it references for anything you need. Tasks 1-6d (the entire native macOS migration up to and including distribution/signing) are done.

## The gate is the point of this task — do not try to satisfy it artificially

This task's first bullet has a real, un-fake-able precondition baked in: **the destructive deletion step (bullet 2) cannot happen until two real release-candidate cycles have been recorded.** No release-candidate cycle has happened yet (this plan has not shipped a single RC of anything). That means:

- **You WILL build** the release-gated cutover script/checklist itself — the mechanism that records RC cycles and checks the gate.
- **You WILL NOT** perform the destructive deletion (bullet 2) in this task, because the gate you just built will correctly refuse to let you (0 recorded cycles < 2 required). Do not hand-record fake RC cycles to unlock it, do not bypass the gate "just this once," and do not delete the web terminal hot-path code by hand outside the script. A gate that can be talked around by whoever's holding it isn't a gate.
- **This is the correct, complete state for this task to end in.** The script exists, is tested, and correctly reports "0/2 release-candidate cycles recorded — refusing" when run. That IS Task 7's deliverable for bullet 1 and bullet 2 together: the mechanism, proven to gate correctly, not the outcome it will eventually gate.

## Required behavior

1. **Release-gated cutover script/checklist** (e.g. `scripts/cutover.sh` or similar, following this repo's existing `scripts/*.sh` conventions — see `scripts/bump-build-version.sh`, `scripts/sync-instructions.sh` for style/structure precedent):
   - A way to **record** a release-candidate cycle (what constitutes "recorded" is your call — e.g. an append-only log file under version control, or a state file with cycle metadata: date, version, who/what marked it; document your choice and reasoning in the report).
   - A **status/check** subcommand reporting how many cycles are recorded and whether the gate is open (≥2) or closed (<2).
   - A **cutover** subcommand that, when the gate is open, performs bullet 2's actions (see below) — and when the gate is closed, refuses clearly (non-zero exit, explicit message stating the count and what's missing) and does nothing destructive.
   - The checklist half: a clear, human-readable list of exactly what bullet 2 removes (`xterm.js`, React Mosaic, terminal Tauri events/commands, duplicate clients, polling, proxy PTYs, frontend terminal buffers) and what it retains (the Tauri rollback artifact, for one release) — this can live in the script's own `--help`/status output, a companion doc, or both; your call.
   - Write the **cutover logic** (what bullet 2's removal actually touches, file by file) even though it will not run — this is real code behind the gate, not a stub. Identify the actual files (`ui/`'s xterm.js usage, React Mosaic usage, the Tauri terminal event/command handlers in `src-tauri/src/`, the proxy PTY code superseded by Tasks 2-3's persistent daemon, frontend terminal buffer code) by reading the codebase, and write the removal step for real — it simply won't execute in this session because the gate stays shut.
2. **Documentation sync** — update `AGENTS.md`, `.github/copilot-instructions.md`, `CLAUDE.md` (this repo's, not the parent `Bruno.Digital/CLAUDE.md`) together, per this repo's own sync convention (`.github/copilot-instructions.md` is authoritative; `scripts/sync-instructions.sh` propagates it — read that script before hand-editing three files inconsistently). Add:
   - The native macOS app (`macos/OmniAgent.xcodeproj`) as a first-class part of the repo: how to build/test it (`./macos/build.sh build`/`test`/`universal`), how to sign/notarize/verify (`./macos/dist.sh` — check Task 6d's actual script name/subcommands in its report if `dist.sh` isn't exactly right), and that it exists as of this migration.
   - The cutover script's existence and how to use it (record a cycle, check status, run cutover once the gate opens).
   - Current migration status (native app built and passing its own test suite; web/Tauri app still production, unchanged, pending the gate).
3. **Build scripts and release automation** — this repo has no CI workflow (`.github/workflows/` doesn't exist) and no formal release pipeline beyond `scripts/bump-build-version.sh`/`scripts/rebuild-app.sh`. "Release automation" here means: make sure those existing scripts and the new cutover script compose sensibly (e.g., does a version bump need to interact with recording an RC cycle? Does `rebuild-app.sh` need updating now that `macos/build.sh`/`dist.sh` exist as a second build surface?). Use judgment; document what you changed and why, and equally document if you conclude nothing there needs changing.
4. **Verification pass** — run and report results for all of:
   - `cargo build --workspace` and `cargo test --workspace`
   - `cargo clippy --all-targets --all-features`
   - `npm --prefix ui run test` (UI tests — "while retained" per the plan text, since bullet 2 hasn't executed, the web UI and its tests are unchanged and must still pass)
   - `./macos/build.sh test` and `./macos/build.sh build` (Xcode tests)
   - The daemon protocol test suites (`cargo test -p omniagent-pty-daemon`)
   - Packaging smoke checks (Task 1's harness / whatever `./macos/dist.sh verify` or equivalent exercises today — note Task 6d's report already found a pre-existing, out-of-scope bug in `scripts/native-macos-pty-harness.py`'s protocol client; do not attempt to fix that here unless it blocks you, just note its status)

## Global constraints that bind this task

- Do not perform the destructive deletion (bullet 2) in this session — see "The gate is the point" above. This is not a suggestion to be efficient about; it is the actual requirement.
- Do not change public MCP shapes. Do not touch the frozen v1 contract.
- Follow this repo's existing script conventions (shell style matching `scripts/*.sh`, doc-sync convention matching `.github/copilot-instructions.md`'s stated authority).
- Follow TDD for the cutover script's gate/record/status logic (it has real decision logic — cycle counting, gate-open/closed — that should be unit-testable, not just a hand-run shell script with no coverage; use whatever test approach fits a shell script in this repo, e.g. a small test harness, or document why you chose a different verification approach).

## Verification

- All items in "Required behavior" #4 above, with actual output pasted into your report.
- Run the cutover script's own status/check subcommand and paste its output showing the gate correctly reports closed (0 or however many are actually recorded at the time you run it — there should be zero, since none exist before this task).
- `git diff --check`

Commit all Task 7 work and write `.superpowers/sdd/native-macos-migration/task-7-report.md`.
