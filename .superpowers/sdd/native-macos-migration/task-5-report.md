# Task 5 report — Phase 4 identity-preserving AppKit pane workspace

Branch: `codex/native-macos-migration-progress`. Base commit: `caaf9fb`. Six commits, no squash, not pushed. (This report itself is not committed — `.superpowers/sdd/` is gitignored.)

```
a89990f refactor: drop the unused pane replacement path and name pane selectors
a9cdf79 docs: record the Phase 4 pane workspace and its benchmark limits
55822d7 feat: show holes as an add-terminal affordance and bundle the pane fixture
95d4d47 feat: own N pane sessions from the workspace window controller
883bb7a feat: add the identity-preserving AppKit pane workspace view
f5f1bd6 feat: port paneGrid semantics to a native PaneGrid value type
```

## What was built

### 1. `macos/OmniAgent/PaneGrid.swift` (new)

The Swift port of `ui/src/state/paneGrid.ts` plus the geometry the browser used to provide.

- `PaneGrid.ladder` / `shape(count:)` / `maxPanes` — the approved 1, 2×1, 2×2, 3×2, 4×2 rungs, cap 8, and the past-the-cap behaviour (widest rung, grow rows, never drop a live session).
- `build(_:)` — column-major fill, leftover cells padded with `__pane-hole-N` holes (byte-identical prefix to the TypeScript), always a complete rectangle.
- `synced(_:desiredIDs:)` — the single entry point for adds and closes, carrying both special cases: the **2 → 3 lower-left** placement and the **1-for-1 in-place replacement**. Returns the grid unchanged (fractions and all) when membership has not moved.
- `paneIDs()`, `contains`, `position(of:)`, `swap`, `replace`.
- `neighbor(of:direction:)` — directional focus (derived, see divergences).
- `layout(in:dividerThickness:)` — direct frame calculation for every cell (holes included) and every seam.
- `moveDivider(_:by:in:dividerThickness:minimumPaneSize:)` — per-column width fractions and per-column row-height fractions, clamped to a minimum pane size.

### 2. `macos/OmniAgent/PaneWorkspaceView.swift` (new)

- `PaneWorkspaceView` — the window's content view. Holds `PaneGrid` + a `[sessionID: PaneContainerView]` dictionary + `[sessionID: PaneDescriptor]`. The grid only ever moves ids between cells, so `addPane`/`closePane`/`swapPanes`/drop reframe existing `TerminalSurfaceView`s and never construct a new one. `isFlipped` so row 0 is the top row, matching `PaneGrid.layout`.
- `PaneDescriptor` — pane identity plus the grouping metadata that travels with it (`group`, `groupLabel`, `title`), the native equivalent of `TabInfo.group`/`groupLabel`.
- `PaneResizeCoalescer` — batches PTY resizes; flushed by the view's `CADisplayLink` (macOS 14's `NSView.displayLink(target:selector:)`), which is unpaused on schedule and paused again after each flush. Without a window there is no display link, so the burst is flushed once at the end of the run-loop turn instead.
- `PaneContainerView` — one pane: a 22 pt drag-handle header over the `TerminalSurfaceView`, focus/drop-target ring, `NSDraggingSource` (writes the pane id to `digital.bruno.omniagent.pane`) and dragging destination (drop another pane on it to trade places).
- `PaneHeaderView`, `PaneDividerView` (resize cursor rects, mouse-drag seam tracking, flush on mouse-up), `PaneHolePlaceholderView` (dashed empty cell reporting itself as an "Add terminal" button).
- Responder-chain commands: `focusPane{Left,Right,Up,Down}:`, `swapPane{Left,Right,Up,Down}:`, `selectPane:` (1-based `NSMenuItem.tag`), plus `NSMenuItemValidation` that disables a direction with no neighbour and an out-of-range pane index.
- Accessibility: workspace is a `.group` labelled "Terminal panes" with the panes as ordered children; each pane is a `.group` labelled "Terminal pane N of M" (prefixed with the session group label when there is one); the terminal inside keeps Task 4's "Terminal" text-area label; holes are `.button` "Add terminal"; dividers are not accessibility elements.
- Occlusion: observes `NSWindow.didChangeOcclusionStateNotification` and flips `suspendsDrawing` on every surface.

### 3. `macos/OmniAgent/TerminalSurfaceView.swift` (modified, not forked)

- `resizeCoalescer` + `scheduleResize()`/`flushResize()`: the delegate `sizeChanged` and `syncSize()` now record the latest geometry and hand it to the coalescer; only the last size is sent. Falls back to sending immediately when there is no coalescer, so a standalone surface behaves exactly as in Task 4.
- `suspendsDrawing`: `feed` still runs the parser (SwiftTerm's bounded buffer keeps consuming output) but skips scheduling the renderer draw. Unsuspending marks the view dirty rather than forcing a draw.
- `resizeSendCount` / `drawRequestCount`: real counters the coalescing and occlusion tests assert on.
- Dropped the Auto Layout pinning of the SwiftTerm view in favour of direct frame propagation (`setFrameSize` → `terminalView.frame = bounds`), so a divider drag resizes the terminal in the same turn the pointer moved rather than on the next layout pass.

### 4. `macos/OmniAgent/WorkspaceWindowController.swift` (rewritten around N panes)

- Content view is now `PaneWorkspaceView`; the initial pane (`native-terminal`) is added in `init`.
- Session lifecycle generalised to one session per pane: `ensureSession`/`createSession`/`attach` take a session id, `onTerminalData`/`onStatus`/`onAttention`/`onExit` are routed by id through the workspace, and on reconnect every pane is re-ensured.
- `newTerminalPane:` (⌘T) — a fresh `UUID().uuidString` session created with the exact Task 4 defaults (`/bin/zsh -l`, home cwd, `TERM=xterm-256color`, `COLORTERM=truecolor`, 80×24, no transcript path), refused past 8. `closePane:` (⌘W) kills the focused session and removes its pane.
- `WorkspaceWindow.makeFirstResponder` is overridden to report first-responder changes, which gives click-to-focus without the panes fighting SwiftTerm for the mouse event. `windowDidBecomeKey` restores focus to the focused pane.
- Window title follows the focused pane's terminal title, with connection/status/error text taking precedence — same shape as Task 4, just focus-aware.
- The `Latency.KeyboardReceipt` signpost stays in this file, so `macos/check-latency-markers.sh` still passes (verified).

### 5. `macos/OmniAgent/AppDelegate.swift` (menus)

`File`: New Terminal Pane ⌘T, Close Pane ⌘W, Close Window ⇧⌘W (moved, the way Terminal.app and iTerm2 order these). New `Panes` menu: Focus Left/Right/Up/Down on ⌥⌘arrows, Move Pane Left/Right/Up/Down on ⌃⌘arrows, Pane 1…8 on ⌘1…⌘8 with `tag` carrying the index. All items keep `target = nil` so they travel the responder chain exactly like the Task 4 session commands.

### 6. Tests

- `macos/OmniAgentTests/PaneGridTests.swift` (new, 37 cases) — a transliteration of `paneGrid.test.ts` plus geometry, divider-drag and neighbour cases, and a fixture case that decodes `fixtures/native-macos-compat/pane-grid.json` (the same file `ui/src/state/nativeMacosCompatibility.test.ts` reads) and checks every shape, its hole count and the hole-repair expectation.
- `macos/OmniAgentTests/PaneWorkspaceViewTests.swift` (new, 20 cases) — ladder/cap, exact tiling, terminal-instance identity across add/close/swap/focus, swap moves frames not terminals, grouping metadata survives swap and reflow, close-focus succession, directional focus/swap, numeric selection, focus restoration on activation and across swap/reflow, drag/drop through the real `NSDraggingDestination` entry points, refusal of self-drops and unknown ids, accessibility descriptions, resize coalescing, immediate frames during a deferred resize, occlusion, hole placeholder, and the eight-pane benchmark.
- `macos/OmniAgentTests/WorkspaceWindowControllerTests.swift` (extended, 9 cases) — the Task 4 single-terminal test was rewritten for the pane workspace; added new-pane/cap/UUID/group, close-pane-keeps-the-rest, and a menu + responder-chain test.

## How the `paneGrid.ts` semantics were ported, and where this diverges

**Data shape (deliberate divergence).** The oracle stores a react-mosaic `PaneTree` (leaf id, or a row/column split). Every tree `buildGrid` produces is a complete rectangle — a row split of `cols` column splits each `rows` tall, holes padding the leftovers — so the port stores that rectangle directly: `cols`, `rows`, and `cells` in column-major order. The two are isomorphic (`cells` in order *is* the tree's depth-first leaf order, i.e. `paneIds`), and the rectangle is what direct frame calculation needs. Every fixture case and every `paneGrid.test.ts` expectation was re-expressed in cell terms and passes, including:

- the `2 → 3` branch, which produces cells `[present0, added, present1, hole0]` — the same `row([column([a, c]), column([b, hole])])` the oracle emits, and not what a plain rebuild would give;
- the 1-for-1 replacement keeping its cell;
- "survivors keep their fill order including a user rearrangement" (the oracle's input for that case is a non-rectangular hand-built tree, which this model cannot represent because it never produces one; the equivalent state — a swapped 3-pane rectangle — reflows to the same answer);
- `gridShape(9)` → 4×3 with all nine panes kept.

**Split percentages.** The oracle carries an optional `splitPercentages` on split nodes and only ever preserves them. The port stores `columnFractions` (per column) and `rowFractions` (per column, per row) — the same independence react-mosaic's nested column nodes had. Reshaping resets them to even (a rebuild in the oracle drops them too); swaps and no-op syncs preserve them.

**Directional focus (derived, not ported).** `paneGrid.ts` has no directional focus — the browser build had none, so there is nothing to preserve. The rule implemented is derived from the rectangle and documented in `neighbor(of:direction:)`: vertical moves walk rows inside the pane's own column and stop at the edge; horizontal moves walk columns preferring the same row, falling back to the nearest real cell above (then below) when that row is a hole. A hole is never a focus target. No wrapping in any direction.

**Grouping metadata (moved, not ported).** In the web build grouping lives on `TabInfo.group`/`groupLabel`, not in the grid. Here it lives in `PaneDescriptor`, keyed by session id, so it travels with the pane through every cell change. Every pane a window opens belongs to one group (`"sess-grp-1"`, label "Session 1") because the UI that creates a second group is the Task 6 sidebar/session outline.

**One removal.** `PaneWorkspaceView.replacePane` (the view-level 1-for-1 swap) was written and then deleted in the last commit: nothing calls it, because the engine-restart flow that needs it is Task 6. The semantics are still preserved and tested where they are exercised, in `PaneGrid.synced`/`replace`.

## Verification

`./macos/build.sh test` — 71 tests, 0 failures:

```
Test Suite 'FrameCodecTests' passed at 2026-07-31 12:48:14.856.
	 Executed 4 tests, with 0 failures (0 unexpected) in 0.002 (0.004) seconds
Test Suite 'PaneGridTests' passed at 2026-07-31 12:48:14.895.
	 Executed 37 tests, with 0 failures (0 unexpected) in 0.030 (0.039) seconds
Test Suite 'PaneWorkspaceViewTests' passed at 2026-07-31 12:48:15.412.
	 Executed 20 tests, with 0 failures (0 unexpected) in 0.513 (0.517) seconds
Test Suite 'SessionConnectionTests' passed at 2026-07-31 12:48:15.447.
	 Executed 1 test, with 0 failures (0 unexpected) in 0.035 (0.035) seconds
Test Suite 'WorkspaceWindowControllerTests' passed at 2026-07-31 12:48:16.098.
	 Executed 9 tests, with 0 failures (0 unexpected) in 0.649 (0.651) seconds
Test Suite 'All tests' passed at 2026-07-31 12:48:16.098.
	 Executed 71 tests, with 0 failures (0 unexpected) in 1.229 (1.246) seconds
** TEST SUCCEEDED **
```

(Baseline before this task: 11 tests.)

- `./macos/build.sh build` — `** BUILD SUCCEEDED **`.
- `./macos/check-latency-markers.sh` — passes; the keyboard → IPC → PTY → output → feed → draw-attempted chain and the pinned SwiftTerm revision are intact.
- `cargo test -p omniagent-pty-daemon` — 6 + 8 + … all pass (frame/protocol, session runtime).
- `src-tauri`: `cargo test --test daemon_client_protocol --test native_macos_compatibility_test` — 6 and 2 tests, all pass.
- `git diff --check` — clean.

**Pre-existing failures, untouched by this task:** `cargo test --lib` in `src-tauri` fails 2 of 173 — `tests::the_titles_version_is_the_one_tauri_conf_json_declares` (runtime version `v2026.7.28+004` vs `tauri.conf.json` `v2026.7.29+006`) and `sessions::tests::codex_gets_omniagent_mcp_wiring`. `git diff --stat caaf9fb..HEAD` shows only `macos/`, `docs/plans/`, `benchmarks/` and this report changed, so neither can be caused by Task 5.

## The benchmark, and what it cannot tell you

`PaneWorkspaceViewTests.testEightPaneDividerAndRendererDrawBenchmark` is an attached `measure(metrics: [XCTClockMetric(), XCTCPUMetric()])` case: an eight-pane workspace in a real on-screen window, 30 divider drags across every seam, one coalesced resize flush, then a renderer draw request per pane.

Honest limits, also written into `benchmarks/native-macos/README.md`:

- There is no PTY behind these panes — the socket never connects — and no daemon, so it measures none of throughput, input-to-glyph latency, CPU under continuous output, or memory with hidden output.
- The test host is headless-ish; window compositing is not what it would be on a user's desktop.
- It measures the in-process cost of *this app's* work (rectangle recomputation, reframing eight surfaces, draw requests) on whatever machine runs the suite, as a regression tripwire. **No number it prints is a benchmark result and none is committed.**
- The external hardware gate is unchanged and still the only source of numbers: `python3 scripts/native-macos-pty-harness.py benchmark /Applications/OmniAgent.app` against a packaged app on reference hardware, with `benchmarks/native-macos/reference-machine.schema.json` metadata. No result file is committed.

## Concerns and notes for whoever picks up Task 6

1. **Fill order after incremental adds is not creation order.** Because ⌘T routes through `synced` and the 2 → 3 rule, opening four panes one at a time gives fill order `1, 3, 2, 4` (columns `[1,3]` and `[2,4]`). This is exactly what the web build does, and ⌘1…⌘8 select by *cell* in fill order, not by creation order. The tests state this explicitly so nobody "fixes" it by accident.
2. **⌘W now closes a pane, not the window** (Close Window moved to ⇧⌘W). That matches Terminal.app/iTerm2 but is a behaviour change from Task 4's menu. Closing the last pane leaves an empty workspace (a bare "Add terminal" hole) rather than closing the window — Task 6's session outline is the right place to decide whether that should close the window instead.
3. **Occlusion is window-level, not pane-level.** Panes in a grid never overlap, so the only real occlusion is the window being hidden/covered, which is what is observed. If Task 6 adds an overlay (palette, inspector) that fully covers panes, that path will need its own suspension trigger.
4. **The drag/drop test drives the real `NSDraggingDestination` methods through a stub `NSDraggingInfo`.** What is *not* covered by a test is `beginDraggingSession` itself (AppKit owns the drag loop); the header's mouse-drag threshold and snapshot path are exercised only by running the app.
5. **The resize-coalescing fallback when there is no window** flushes once per run-loop turn rather than once per display refresh. It exists so an attach that happens before the window is on screen still sends its size. Worth a look if Task 6 ever creates panes off-screen in bulk.
6. **TCC**: the fixture is copied into the test bundle as a resource rather than read from the source tree at run time. Reading `~/Documents/...` from the test process stalled the suite for 60+ seconds on privacy consent. If a future test needs another repo file, bundle it the same way.
7. **TDD honesty**: for `PaneGrid` the tests were written before the implementation but the first *executed* run contained both (it went green immediately, since the cases were transliterated from a known-good oracle). The workspace-view, controller and menu increments each ran red first — the workspace-view suite failed on six assertions I had written against a wrong fill order, which is what surfaced concern 1 above.

---

# Fix report — review findings 1 and 2

Commit: `3162243 fix: keep window title per session and make pane focus/drop feedback visible`. Both findings confirmed as real bugs and fixed; both now have covering tests. Full range is now `caaf9fb..3162243` (7 commits).

## Finding 1 — one global `statusTitle` for N sessions

Confirmed exactly as described. `statusTitle` was a single `String?` written from per-session callbacks and cleared by any pane's `attach`, so:

- an exited pane's "Session ended" followed the user onto every other pane and never cleared;
- one pane attaching wiped another pane's real error off the title;
- `onStatus` was guarded on `event.id == workspace.focusedPaneID`, so a background pane's status was dropped rather than deferred — switching to a pane that hit "Needs approval" while unfocused showed nothing.

**Fix** (`macos/OmniAgent/WorkspaceWindowController.swift`):

- `private var sessionStatus: [String: String]` replaces `statusTitle`, keyed by session id.
- `private var connectionStatus: String?` holds what genuinely belongs to the connection rather than a session — connecting, reconnecting, and `connection.onError` — and outranks session status in the title.
- Two single writers, `applySessionStatus(_:for:)` and `applyConnectionStatus(_:)`, both of which refresh the title. Every write site now goes through one of them: `onStateChange`, `onStatus`, `onExit`, `onError`, the `listSessions`/`createSession` failure paths (per session), and `attach` (clears only its own session).
- The focus guard is gone from `onStatus`; it is replaced by a `workspace.container(for:) != nil` guard so only panes this window owns are recorded.
- `refreshTitle()` reads `connectionStatus` first, then `sessionStatus[focusedPaneID]`, then the focused pane's terminal title. `onFocusedPaneChanged` therefore recomputes correctly with no extra plumbing.
- `closePane:` removes the closed pane's entry so a dead session cannot leave status behind.

**Test** (`WorkspaceWindowControllerTests.testWindowTitleFollowsTheFocusedPanesOwnStatusAndNeverGoesStale`) — walks the exact reported scenario and its mirrors: a background pane's status stays off the title; focusing it shows it; focusing back does *not* keep claiming it; a status reached while unfocused appears on focus; clearing one pane's status leaves the other pane's intact; connection status outranks both and clears cleanly; a closed pane takes its status with it. The two writers are `internal` rather than `private` precisely so this test drives the real code path instead of a stub.

## Finding 2 — focus ring and drop tint buried under opaque subviews

Confirmed. `applyLayout()` tiles the container with `header` (opaque fill in its `draw`) and `surface` (alpha-1 layer background) with no inset, and `PaneContainerView.draw(_:)` drew the 1 pt border and the drop tint into the container's own layer, which those two sublayers composite over. `draggingEntered` returned `.move` and set `isDropTarget`, and the user saw nothing.

**Fix** (`macos/OmniAgent/PaneWorkspaceView.swift`):

- `PaneContainerView.draw(_:)` deleted. The ring is now `layer?.borderWidth`/`borderColor` — a layer border draws above sublayers — with the three states as named statics (`idleBorderColor`, `focusedBorderColor`, `dropTargetBorderColor`).
- The drop tint is a new `PaneDropOverlayView`, added last so it is the top-most subview, sized to `bounds` in `applyLayout()`, shown/hidden by `isDropTarget`. It overrides `hitTest` to return `nil`, so it cannot swallow a click or a drag meant for the pane underneath.
- `isFocused`/`isDropTarget` both funnel into one `updateChrome()`; the `needsDisplay` churn in the dragging-destination methods is gone.

**Test** (`PaneWorkspaceViewTests.testFocusRingAndDropTintCompositeAboveTheOpaqueTerminal`) — asserts what is verifiable without a rendering harness, and it is enough to catch this exact regression: that the header and surface tile the container with no inset (the condition that made `draw(_:)` useless), that the border width/colour is on the container's *layer* and tracks idle → focused → idle, that a `draggingEntered` unhides the overlay, that the overlay's frame is the full bounds, that it is `subviews.last` (i.e. above the terminal), that the border switches to the drop-target colour, and that the overlay is transparent to hit testing. What it cannot assert is the rasterised pixels; a screenshot-diff harness would be needed for that and none exists in this project.

While writing it, the test caught its own wrong assumption — `makeWorkspace(panes: 4)` leaves the *last added* pane focused, so pane-4 starts with a focus ring — which is worth knowing for any future test that assumes a neutral starting state.

## Verification after the fix

`./macos/build.sh test` — 73 tests (was 71), 0 failures:

```
Test Suite 'FrameCodecTests' passed at 2026-07-31 13:03:13.933.
	 Executed 4 tests, with 0 failures (0 unexpected) in 0.002 (0.003) seconds
Test Suite 'PaneGridTests' passed at 2026-07-31 13:03:13.988.
	 Executed 37 tests, with 0 failures (0 unexpected) in 0.043 (0.055) seconds
Test Suite 'PaneWorkspaceViewTests' passed at 2026-07-31 13:03:14.440.
	 Executed 21 tests, with 0 failures (0 unexpected) in 0.450 (0.453) seconds
Test Suite 'SessionConnectionTests' passed at 2026-07-31 13:03:14.479.
	 Executed 1 test, with 0 failures (0 unexpected) in 0.038 (0.039) seconds
Test Suite 'WorkspaceWindowControllerTests' passed at 2026-07-31 13:03:15.136.
	 Executed 10 tests, with 0 failures (0 unexpected) in 0.655 (0.657) seconds
Test Suite 'All tests' passed at 2026-07-31 13:03:15.136.
	 Executed 73 tests, with 0 failures (0 unexpected) in 1.188 (1.207) seconds
```

- `./macos/build.sh build` after `xcodebuild clean` — `** BUILD SUCCEEDED **`.
- `./macos/check-latency-markers.sh` — passes.
- `git diff --check` — clean.

## Compiler warnings (the gap in the original report)

A **clean** build (`xcodebuild clean` first, so every file recompiles) emits exactly three warnings, all pre-existing and none from Task 5 code:

```
macos/OmniAgent/AppDelegate.swift:93:35: warning: use '#selector' instead of explicitly constructing a 'Selector'
macos/OmniAgent/AppDelegate.swift:94:36: warning: use '#selector' instead of explicitly constructing a 'Selector'
macos/OmniAgent/AppDelegate.swift:95:41: warning: use '#selector' instead of explicitly constructing a 'Selector'
```

Those three lines are the Edit menu's `Selector(("copy:"))`, `Selector(("paste:"))` and `Selector(("selectAll:"))`, written in Task 4 and untouched here — only their line numbers moved when the File menu grew. They are trivially fixable (`#selector(NSText.copy(_:))` and friends) but belong to the deferred-minor ledger, not to this task's diff. My own new menu wiring and the new test assertions use `#selector` and warn about nothing; the eight `Selector(("…"))` warnings I introduced in the test file during this task were removed in `a89990f` before it was reported complete.

The test build additionally prints nine `warning: not stripping binary because it is signed: …XCTest…` lines. Those come from Xcode copying its own signed XCTest frameworks into the test host and are toolchain noise, not source diagnostics.

## Concerns after the fix

- Nothing new. The concerns listed in the original report (fill order after incremental adds, ⌘W closing a pane rather than the window, window-level occlusion, `beginDraggingSession` being untestable, the no-window resize-flush fallback, and the two pre-existing `src-tauri --lib` failures) all still stand unchanged.
- Worth flagging for Task 6: now that status is per session, the sidebar/session outline has the right data to show a per-pane status badge; the title only ever shows the focused pane's.
