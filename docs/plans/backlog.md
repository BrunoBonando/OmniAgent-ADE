# Backlog — 2026-08-25

Ordered by value per line of diff. Each task is done when its **Done when** holds.

---

## 1. Record release-candidate cycle 1/2

Unblocks task 2, which deletes ~48k lines. `cutover.sh status` is the gate:
2 recorded cycles, currently 0.

```bash
./scripts/cutover.sh record --version 2026.8.25+008 --note "app view chat redesign shipped"
./scripts/cutover.sh status
```

A cycle means a build **actually shipped to real users**, not a local rebuild —
that is why this is manual and deliberately not wired into `rebuild-app.sh`.
If +008 has not gone out to anyone, this task waits for the build that does.

**Done when:** `status` reports 1/2.

---

## 2. Cut the web terminal hot path

Blocked on task 1 reaching 2/2. Never hand-delete this code; never hand-record
a cycle to force the gate.

```
ui/src         36,734 lines   not built by rebuild-app.sh
src-tauri/src  11,208 lines   sessions.rs alone is 5,656
macos/         41,635 lines   the only thing that ships
```

```bash
./scripts/cutover.sh status   # gate must read OPEN
./scripts/cutover.sh cutover
```

Then the manual pass the script prints and cannot do blind: `ui/src/App.tsx`
(drop `<Workspace>`, keep the workspace-tab bookkeeping other surfaces use),
`ui/src/App.css` (xterm/mosaic rules), `keyboardShortcuts.ts` (mosaic
shortcut), `src-tauri/src/feedback.rs` (`on_session_end` + its two helpers,
keep pending-notes), `feedback_test.rs`, and `src-tauri/Cargo.toml`'s
`portable-pty` line if nothing under `src-tauri/` still references it — the
daemon's own dependency stays.

**Done when:** `cargo build/test/clippy --workspace`, `npm --prefix ui run test`,
and `./macos/build.sh test` all pass with that code gone.

---

## 3. Wire up the home screen

`macos/OmniAgent/HomeView.swift` is a finished-looking launcher whose every
control presses into nothing — nine `onPress = {}` closures (lines 220, 394,
400, 406, 420, 482, 514, 686). Hover, focus ring, keyboard activation and
Return/Space handling all already work; only the behaviour is missing.
`WorkspaceWindowController.swift:117` owns the single instance.

Decide per control what it opens, then hand each closure the call the sidebar
or command palette already makes for the same action. No new plumbing — if a
control needs a code path that does not exist yet, that control is its own
task, not part of this one.

**Done when:** every `onPress = {}` in `HomeView.swift` is either wired or
deliberately removed, with a test per wired control asserting the press
reaches the controller.

---

## 4. Four minors from the chat-redesign review

Carried out of `.superpowers/sdd/2026-08-25-app-view-chat-redesign/fix-wave-report.md`,
"Not addressed". About an hour, all four.

- `PaneAppSystemBlocks.swift` — nested same-kind blocks match the innermost
  close, so the outer `</system-reminder>` leaks into prose as literal text.
- `ClaudeUsageLimits.swift` — a partial `/usage` parse overwrites `latest`
  wholesale, blanking the readouts the run did not mention, with no stale
  marker. Merge into the previous reading instead.
- `PaneAppView.swift:1150` — `rise.fromValue = 8` is a *rise* only if the row
  layer is flipped, and nothing pins it. Assert the group carries a
  `transform.translation.y` from 8 to 0.
- `PaneWorkspaceView.swift:1714` — `restoreComposerFocusAfterMove` is wired to
  `reorderPanes`/`swapPanes` but not to `reflowForSize` crossing the filmstrip
  threshold, which its own doc names.

**Done when:** four fixes, four tests, `./macos/build.sh test` green.

---

## 5. Retire or repair the PTY smoke harness

`scripts/native-macos-pty-harness.py` still speaks Task 1's per-request
JSON-over-a-newline protocol; the daemon has used 16-byte envelope framing
since Task 2. It is already quarantined — `dist.sh verify` does not run it,
only the opt-in `dist.sh verify-smoke` does — so nothing is currently lying to
you, and this is low priority.

Lazy call: delete the harness and the `verify-smoke` subcommand. Keep and fix
it only if the packaged-daemon benchmark is worth the reframing work.

**Done when:** either the file and subcommand are gone, or
`./macos/dist.sh verify-smoke /Applications/OmniAgent.app` passes.

---

## 5b. An intermittent keyboard test

`WorkspaceWindowControllerTests.testCommandOptionODoesNotTurnOffOptionAsMeta`
failed once in a full-suite run on 2026-08-26, at the final assertion
(`delegate.bytes.isEmpty` — something wrote bytes to the terminal). It passes
in isolation and passed on an immediate re-run of the same tree, so it is
order- or state-dependent rather than a real regression, and it is unrelated
to the sidebar work that happened to be in the tree at the time.

Worth catching properly: shared `NSApp.mainMenu` / key-window state across
test classes is the usual cause of this shape, and an intermittent test is one
nobody trusts and everybody re-runs.

A **second** intermittent full-suite failure followed on the same day. Its
identity was lost — the run was piped through a filter that kept only the
verdict line — and the immediate rerun passed 1391 tests with zero failures.
So: two intermittent failures in one day, one of them identified, neither
reproducible on demand.

Lesson already applied: keep the full log when running the suite, or the next
one is unidentifiable too.

**Done when:** either the shared state is isolated per test, or the flake is
reproduced often enough to name its real cause.

## 6. Browser-PKCE login

The agreed follow-up to the unmerged ADE+Core login branches, which are
blocked on an Apple entitlement. Its own project, not a backlog line — worth a
spec before any code.

**Done when:** it has a spec.

---

## Not doing

Splitting `PaneWorkspaceView.swift` (6,585 lines) and
`WorkspaceWindowController.swift` (5,001) — 28% of the app's Swift in two
files is ugly and is not costing anything today. Revisit when an edit in one
of them is genuinely hard, not before.
