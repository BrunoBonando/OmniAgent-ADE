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

## 5b. Intermittent failures in event-synthesising tests

`WorkspaceWindowControllerTests.testCommandOptionODoesNotTurnOffOptionAsMeta`
failed once in a full-suite run on 2026-08-26, at the final assertion
(`delegate.bytes.isEmpty` — something wrote bytes to the terminal). It passes
in isolation and passed on an immediate re-run of the same tree, so it is
order- or state-dependent rather than a real regression, and it is unrelated
to the sidebar work that happened to be in the tree at the time.

Worth catching properly: shared `NSApp.mainMenu` / key-window state across
test classes is the usual cause of this shape, and an intermittent test is one
nobody trusts and everybody re-runs.

A **second** followed the same day, its identity lost to a filter that kept
only the verdict line. A **third** the day after:
`PaneApprovalButtonClickTests.testClickingApproveSendsEnter`, asserting that a
click on Approve writes `\r` to the session — it wrote nothing. It too passes
in isolation.

Three data points, and they have a shape: every one is a test that
**synthesises an AppKit event** — a key equivalent, a click — and every one
passes alone and fails only in a full run. The common dependency is a window
that has actually become key, which under `xcodebuild test` is timing
dependent and shared across test classes. That is a hypothesis with a test:
if a failing case is preceded by another class leaving a window key, ordering
is the cause.

Lesson already applied: keep the full log when running the suite. It is what
turned the third failure from "something broke" into a named test with an
assertion, and what makes this entry a diagnosis rather than a shrug.

**Done when:** either event-synthesising tests stop depending on ambient
key-window state, or the ordering hypothesis above is confirmed and fixed.

## 6. Browser-PKCE login — done (2026-08-28)

Shipped as the Sign in with Apple web flow: native Sign in with Apple is
unsupported in Developer ID apps (Apple DTS), so `ASWebAuthenticationSession`
opens Apple's page, Core's `POST /v1/auth/apple/callback` mints a one-time
code, `omniagent://auth/apple` hands it back, and `POST /v1/auth/apple/exchange`
redeems it with PKCE S256 + nonce. Plan: `~/.claude/plans/peaceful-humming-charm.md`
(session 016ErTyKfE762JDBskXnEF69). Left for later: an app-level
`omniagent://` handler for callbacks that arrive with no live session, and
wiring `AuthClient.restoreSession()` once the bearer token authorises anything.

---

## Not doing

Splitting `PaneWorkspaceView.swift` (6,585 lines) and
`WorkspaceWindowController.swift` (5,001) — 28% of the app's Swift in two
files is ugly and is not costing anything today. Revisit when an edit in one
of them is genuinely hard, not before.
