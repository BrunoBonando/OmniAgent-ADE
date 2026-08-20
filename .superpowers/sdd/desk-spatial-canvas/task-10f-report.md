# Task 10f — whole suite, then a packaged build and install

**Status:** complete. Suite **986 passed / 0 failed / 0 skipped**; the app is built, signed,
packaged and installed to `/Applications/OmniAgent.app`. Two of the gaps earlier tasks recorded as
open are now closed, with four tests that were each confirmed to fail without their fix.

This is the last task of `docs/superpowers/plans/2026-08-18-desk-spatial-canvas.md`, so this report is
also the branch's hand-over: what works, what was cut, and what only a human at the keyboard can check.

---

## 1. The suite

| Run | Result |
|---|---|
| Baseline at planning time (2026-08-18) | 708 passed / 0 failed |
| This branch as Task 10e left it | 982 passed / 0 failed / 0 skipped |
| After this task's four tests | **986 passed / 0 failed / 0 skipped** |

`caffeinate -disu ./macos/build.sh test`, `** TEST SUCCEEDED **`. Read back with

```
xcrun xcresulttool get test-results summary --path \
  ~/Library/Developer/Xcode/DerivedData/OmniAgent-dcystiwktbsinzgjbzxoacrfltfu/Logs/Test/Test-OmniAgent-2026.08.20_03-18-14-+0200.xcresult
```
→ `"failedTests": 0`, `"passedTests": 986`, `"result": "Passed"`.

That is the final run, on the exact tree that was committed (the suite was run three times in this
task: 982 on arrival, 986 after the fixes, 986 again on the committed tree).

**Nothing was red when I arrived.** No pre-existing failure to report, nothing weakened, nothing
skipped. The `caffeinate -disu` prefix is not optional — the suite hangs when the display sleeps.

---

## 2. The two gaps I closed

Both were recorded in predecessors' reports as known-open, both are user-visible, and both are now
covered by tests I first watched fail.

### 2a. Desk → Dashboard → Desk did not return you to what you left

Recorded by Task 10a ("Known gap, nobody's section owns it yet") and re-confirmed by Task 10e. Two
different wrongnesses depending on where you were:

- **On the canvas** at some camera: `canvasMode`'s setter resets the camera on the way out ("Normal
  mode must carry no transform at all"), so coming back put you at scale 1 / origin 0 — the *corner*
  of the organigram, not the middle of it.
- **Inside a session**: canvas mode is already off (that is what `landSession` does as it lands), and
  `applyDestination` turned it back on unconditionally — so you came back to the organigram you had
  not left from, at that same corner.

Neither flag can be recovered after the fact, so `WorkspaceWindowController` now writes down which of
the two states the Desk was in when it was left:

```swift
private enum DeskReturn { case canvas(DeskCamera); case session }
private var deskReturn: DeskReturn?
```

`applyDestination(_:)` calls `rememberDeskState()` on the way off the Desk (and only from a
destination that *was* the Desk, so two Dashboard selections in a row do not overwrite the first
one's record with the mode the first one turned off) and `restoreDeskState()` on the way on. With
nothing recorded — the first selection of a run — it is the plain "load the organigram" it always was,
which is why Task 10a's own destination tests still pass unchanged.

Task 8's suggested repair (re-seat with `DeskCamera.focus(on: card)`) is deliberately **not** used;
Task 10a is right that it is wrong. A `focus`-on-a-card camera has a non-zero origin, so
`camera.isIdentityTransform` is false, so `canvasOwnsInput` is true — you would be staring at a
full-size session that swallowed every keystroke into the canvas. Recording *"you were in a session"*
and leaving canvas mode off is the honest version.

**One case that is neither state:** leaving while an entry flight is still in the air. `canvasMode` is
on but the camera is already parked over the destination card, and the landing arrives on its own
`asyncAfter` whether or not the Desk is still on screen — so by the time you come back you are inside
that session. `rememberDeskState` asks `workspace.isEnteringSession` and records `.session` for it.
Storing the camera there is exactly the swallowed-keystroke state above.

### 2b. A click during an entry flight acted on a canvas you were 0.38s from leaving

Recorded in the review-b fix report as "strictly better than the previous behaviour and outside both
findings, so it was left alone; a later task may want gestures to cancel `pendingSessionEntry`."

Cancelling the entry is not available: the landing is already scheduled and token-guarded, and
stopping it mid-air leaves the camera in the same non-identity, canvas-owns-input state as above. So
the click gives way instead — `mouseDown` returns early while `isEnteringSession`. Without it, a drag
in that window *pinned* a node, and `onDeskCanvasChanged` then persisted the pin to
`desk_canvas_native`: a permanent change made by a click the user meant for something else.

### Tests (4 new, all confirmed to fail without their fix)

`macos/OmniAgentTests/WorkspaceWindowControllerDeskCanvasTests.swift`
- `testLeavingTheDeskAndComingBackReturnsToTheCameraItWasLeftAt`
- `testLeavingTheDeskFromInsideASessionComesBackInsideThatSession`
- `testLeavingTheDeskMidFlightComesBackInsideTheSessionItWasFlyingTo`

`macos/OmniAgentTests/DeskCanvasInputTests.swift`
- `testAClickIsSwallowedWhileAnEntryFlightIsStillInTheAir`

The three controller tests were run against a deliberately sabotaged `restoreDeskState()` (forced back
to the old `canvasMode = true`) and all three failed; restored, all three pass. They are not
decoration.

One thing worth knowing for anyone writing more tests in this file: **the restore leaves the *last*
group active**, so `focusPane("sess-a")` on a two-session plan is the one that starts a flight, and
`focusPane("sess-b")` is a no-op. Two of these tests were written the other way round first and were
silently testing nothing.

---

## 3. The packaged build

`./scripts/rebuild-app.sh --no-notarize`, run with `caffeinate -disu`, exit 0:

```
** BUILD SUCCEEDED **                       (universal, arm64 + x86_64, Release)
Signed … Developer ID Application: Bruno Bonando (86JZ74B6NT)
  … app bundle: valid on disk, satisfies its Designated Requirement
Styled DMG: target/native-macos-dist/OmniAgent_2026.8.20+001_universal.dmg
Installed OmniAgent 2026.8.20+001 (native) -> /Applications/OmniAgent.app
Notarized: no (signed only).
```

Installed bundle: `CFBundleShortVersionString = 2026.8.20`, `CFBundleVersion = 1`,
`Identifier = digital.bruno.omniagent`, `TeamIdentifier = 86JZ74B6NT`. The app relaunched itself
(the script only puts back what it closed) and is alive.

### The version number is `2026.8.20+001`, not `2026.8.19+025`

My brief said 2026.8.19 and "do not reset the counter". **The clock rolled past midnight while this
branch was being built** — `scripts/rebuild-app.sh` runs `scripts/bump-build-version.sh` itself, and
that script derives the date from `datetime.date.today()`, which was 2026-08-20 by the time it ran
(03:14 CEST). Per the repo's rule the same-day counter is per *day*, so a new date legitimately starts
at `+001`; nothing was reset within a day. It bumped all four version surfaces together
(`src-tauri/tauri.conf.json`, `ui/package.json`, `src-tauri/Cargo.toml` + `Cargo.lock`, and the three
Xcode configurations' `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`), which also repaired a pre-
existing skew: the committed tree had the Xcode project at 2026.8.19/24 while `tauri.conf.json` still
said 2026.8.18+035.

### The PTY daemon was NOT restarted, and that is expected here

```
PTY daemon NOT restarted: it is this shell's own parent (rebuild started
  from a pane inside OmniAgent). Daemon-side changes are not live.
```

The rebuild ran from a terminal pane *inside* OmniAgent, so the daemon is this shell's own ancestor
and `pkill` excludes it — the script says so rather than pretending, and killing it would have hung up
the install mid-run. **It costs nothing on this branch: no Rust *source* changed at all** — `git diff main...HEAD -- '*.rs'`
is empty, the whole plan is Swift + `project.pbxproj`, and the only Rust-side edit is the version
string the bump script writes into `src-tauri/Cargo.toml` — so the running daemon is byte-identical in behaviour to the one now
inside the bundle. It is running from an unlinked inode until it is restarted, which matters only for
the next daemon-side change. To finish it off from an outside Terminal:

```
osascript -e 'quit app "OmniAgent"' && pkill -f omniagent-pty-daemon && open -a OmniAgent
```

---

## 4. What I could verify on the installed app, and what only you can

Verified against the *running, installed* app (via the accessibility API):

- The menu bar is `Apple, OmniAgent, File, Edit, Session, Panes, Desk, Window` — the new **Desk** menu
  exists **and the pre-existing Session menu is still there**, which is the constraint the whole plan
  was written around.
- Desk's items are `Zoom In, Zoom Out, Zoom to Fit, Enter Session, —, Previous Session, Next Session,
  —, Session 1 … Session 9`.
- **⌃1…⌃9 is not shadowed on this Mac.** `~/Library/Preferences/com.apple.symbolichotkeys.plist` has
  `AppleSymbolicHotKeys:118` ("Switch to Desktop 1", key 18 + control) with `enabled = false`, and
  119+ do not exist at all. So the app's bindings should win here. If a second Desktop is ever added
  and macOS re-enables them, the recorded fallback is ⌥⌘1…⌥⌘9 in `ApplicationMenus.install()`.

**Not verified — please check by hand** (I could not: the display was asleep at 03:17, so a screen
capture returned black, and menu-item enablement is only computed when a menu is actually opened):

1. Desk's items enabled on the Desk destination, greyed out on Dashboard.
2. **⌘0** zooms out to the whole organigram; the chips and connectors are drawn; sessions below 0.2
   scale draw as chips rather than live terminals.
3. **⌃1 / ⌃2 / ⌃3** land on the matching session (the binding-shadowing check above is evidence, not
   proof).
4. **⇧⌘]** / **⇧⌘[** step and stop at both ends.
5. The **Zoom to Fit** and **Enter Session** toolbar buttons are visible — if they are not, the
   toolbar autosave identity bump (Task 10c) did not take.
6. Drag a node, quit, relaunch: it is still where you put it. First launch after this install has no
   `desk_canvas_native` row yet, so it opens on the whole organigram — that is correct, not a bug.
7. The round trip I fixed: on the canvas, select Dashboard in the sidebar and then DESK again — you
   come back to the same camera; do it from inside a session and you come back *into that session*.

---

## 5. The cutover gate: untouched, still closed

```
./scripts/cutover.sh status
  0/2 release-candidate cycles recorded
  GATE: CLOSED (0/2 recorded, 2 more needed)
```

Nothing recorded. This was a local build, not a release-candidate cycle shipped to real users, and
`cutover.sh record` is only for the latter — recording here to open the gate is precisely the failure
mode the script's design forbids. The web terminal hot path stays in the tree.

---

## 6. What is still not done

1. **`dist.sh verify`'s packaged-PTY smoke check** fails against every build and still does.
   Pre-existing, documented in `CLAUDE.md`: `scripts/native-macos-pty-harness.py` speaks the pre-Task-2
   per-request JSON protocol, not the daemon's persistent 16-byte-envelope framing. Out of scope, not
   touched. (`dist.sh sign`'s own verification, which is what the install depends on, passed.)
2. **`PaneWorkspaceView.onCanvasPinsChanged` has no consumer.** Task 8 added it; Task 10e persists pins
   through `onDeskCanvasChanged` instead, one callback for the whole row. Left in place rather than
   deleted — removing another task's tested API at the last gate is churn, not cleanup.
3. **No test drives a real `.magnify` or `.scrollWheel` `NSEvent`.** AppKit exposes no initialiser
   carrying a magnification or scrolling delta. Both overrides are three-line adapters over
   `pinchCanvas`/`panCanvas`, which are covered.
4. **Re-selecting DESK while already on the Desk still bounces you to the organigram** if you were
   inside a session. Unchanged from before this task (the old code did the same), and arguably right —
   clicking DESK is a reasonable way to ask for the organigram. Named here so it is a decision rather
   than an oversight.
5. **The daemon is the pre-install one** — see §3. No behavioural difference on this branch.
6. **Not merged.** The branch is pushed as `worktree-desk-canvas`; `main` has another session's
   uncommitted work in it, so the merge is yours to make.

---

## 7. Files this task changed

- `macos/OmniAgent/WorkspaceWindowController.swift` — `DeskReturn`, `rememberDeskState()`,
  `restoreDeskState()`, and `applyDestination(_:)`'s two-line change.
- `macos/OmniAgent/PaneWorkspaceView.swift` — `mouseDown`'s early return while a flight is in the air.
- `macos/OmniAgentTests/WorkspaceWindowControllerDeskCanvasTests.swift` — +3 tests.
- `macos/OmniAgentTests/DeskCanvasInputTests.swift` — +1 test.
- `.superpowers/sdd/desk-spatial-canvas/progress.md` — the real status of all 19 tasks.
- Version bump (by `scripts/bump-build-version.sh`, via `rebuild-app.sh`):
  `src-tauri/tauri.conf.json`, `ui/package.json`, `src-tauri/Cargo.toml`, `Cargo.lock`,
  `macos/OmniAgent.xcodeproj/project.pbxproj`.
