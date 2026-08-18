# Zoom Backdrop Real Blur Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the zoom/focus overlay (⌘↩ on a pane) a real, visible blur of the panes behind the focused card — the thing `PaneZoomBackdropView`'s `.withinWindow` `NSVisualEffectView` was supposed to do and, per direct on-screen confirmation, does not.

**Architecture:** Root cause (confirmed, not guessed): `NSVisualEffectView.blendingMode = .withinWindow` samples sibling views inside one window's own private compositing tree, and in this window it produces no visible blur at all — confirmed by checking the sidebar (plain AppKit content, no Metal involved) behind the backdrop, which is exactly as unblurred as the terminal panes. `.behindWindow` blending is the mechanism the Dock, Mission Control and Notification Center use: it reads the real, already-composited screen buffer, which is reliable over anything, GPU-rendered content included.

The fix adds up to four small, borderless, transparent auxiliary `NSPanel`s tiling the region *around* the focused card (top band, bottom band, left band, right band — the standard "outer rect minus inner rect" decomposition into non-overlapping rectangles), each hosting an `NSVisualEffectView` with `.behindWindow` blending, attached to the main window via `addChildWindow(_:ordered:.above)` so they inherit its move/show/hide/ordering behavior for free. Because no auxiliary window's *frame* ever overlaps the card's own screen rect, clicks on the card reach the main window underneath with no hit-testing or click-passthrough tricks needed.

To avoid synchronizing four separate `NSWindow` frames against an in-flight, CALayer-driven card animation (real risk of visible tearing/lag), the blur panels only appear once the card's ~0.38s grow animation has settled, and disappear immediately the instant a shrink begins. The existing `PaneZoomBackdropView` (dim tint) is untouched and keeps doing exactly what it does today throughout the whole interaction — this plan adds real blur on top of it, once settled; it does not replace the dim layer.

**Tech Stack:** Swift, AppKit (`NSVisualEffectView`, `NSPanel`, `NSWindow.addChildWindow`), XCTest.

**Spec:** This plan document is self-contained — there is no separate spec file. The root-cause investigation (confirmed via direct user observation that the sidebar shows no blur either) and the chosen architecture were agreed with the project owner in the conversation that produced this plan; no other design doc exists to cross-reference.

## Global Constraints

- Do not create new `.swift` files. This project's `.xcodeproj` uses old-style explicit `PBXFileReference`/`PBXBuildFile`/group entries (confirmed: no `PBXFileSystemSynchronizedRootGroup` present), not Xcode 16's auto-including synchronized groups — a new file needs four hand-edited, ID-matched entries in `project.pbxproj` to even compile, which is exactly the kind of edit that silently diverges between "builds in Xcode" and "builds from the command line." Add every new type to the existing, already-registered `macos/OmniAgent/PaneWorkspaceView.swift`, and every new test to the existing `macos/OmniAgentTests/PaneWorkspaceViewTests.swift`. This single file already houses many unrelated view classes (`PaneContainerView`, `PaneHeaderView`, `PaneZoomBackdropView`, …) — this is the established convention in this specific codebase, not a violation of it.
- `PaneZoomBackdropView` (the existing dim-tint layer) is not deleted, renamed away from, or behaviorally changed. Only its doc comments are corrected where they currently (incorrectly) claim it blurs anything.
- Every new piece of pure geometry logic must be a `static` function, directly unit-testable with plain `NSRect` values and no live window — follow the existing `PaneWorkspaceView.focusCardFrame(in:)` pattern exactly.
- Window-lifecycle code (panel creation, `addChildWindow`, teardown, repositioning) is not unit-testable the way geometry is; keep it as thin as possible and cover it with structural tests (config assertions, `NSWindow.childWindows` bookkeeping) rather than trying to force pixel-level test coverage — this matches the existing `PaneZoomBackdropView` test, which already only asserts configuration, never pixels.
- Build after every task: `cd macos && ./build.sh test`. All tests must pass before moving to the next task.
- Every commit ends with:
  ```
  Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01AA8fLnpANER99Nq4dGy2Hy
  ```
- This is a shared working tree — other sessions may be editing `PaneWorkspaceView.swift` concurrently. Every `Edit` step below anchors on a distinctive code snippet, not a line number, for exactly this reason. If an anchor's surrounding text has drifted when a step runs, re-read the file, locate the equivalent code by its function name / doc comment, and adapt the edit — do not skip the step.

---

### Task 1: Pure band-decomposition geometry

**Files:**
- Modify: `macos/OmniAgent/PaneWorkspaceView.swift` (add a new class, `PaneZoomBlurOverlay`, near `PaneZoomBackdropView` — search for `final class PaneZoomBackdropView` and insert the new class immediately after its closing `}`)
- Test: `macos/OmniAgentTests/PaneWorkspaceViewTests.swift` (add new tests near the existing `testTheBackdropBlursTheAppBehindItAndTintsNothing` — search for that function name)

**Interfaces:**
- Produces: `PaneZoomBlurOverlay.blurBands(around hole: NSRect, in outer: NSRect) -> [NSRect]` — a `static` pure function. Later tasks (2, 3, 4) call this from `PaneZoomBlurOverlay.show(around:in:parent:)`.

- [ ] **Step 1: Write the failing tests**

Open `macos/OmniAgentTests/PaneWorkspaceViewTests.swift`, find `func testTheBackdropBlursTheAppBehindItAndTintsNothing()`, and add these new test functions directly after it (inside the same `XCTestCase` class, before its closing `}`):

```swift
    /// The standard "outer rect minus inner rect" decomposition into four
    /// non-overlapping bands: a full-width strip above the hole, a
    /// full-width strip below it, and two strips exactly as tall as the
    /// hole itself to its left and right. Together with the hole they tile
    /// `outer` with no gaps and no overlaps — the property that lets four
    /// separate windows cover "everywhere except the card" with no
    /// hit-testing tricks needed, since no band's rect ever touches the
    /// hole's rect.
    func testBlurBandsTileTheOuterRectAroundTheHoleWithNoOverlap() {
        let outer = NSRect(x: 0, y: 0, width: 1000, height: 800)
        let hole = NSRect(x: 300, y: 250, width: 400, height: 300)

        let bands = PaneZoomBlurOverlay.blurBands(around: hole, in: outer)

        XCTAssertEqual(bands.count, 4, "a hole with room on every side produces all four bands")
        for band in bands {
            XCTAssertFalse(band.intersects(hole), "no band may cover any part of the card")
            XCTAssertTrue(outer.contains(band), "no band may spill outside the region being blurred")
        }
        // Every band, plus the hole itself, must reconstruct outer's area
        // exactly — the tiling has no gaps.
        let totalArea = bands.reduce(hole.width * hole.height) { $0 + $1.width * $1.height }
        XCTAssertEqual(totalArea, outer.width * outer.height, accuracy: 0.001)
    }

    func testBlurBandsDropsAZeroSizedSideRatherThanEmittingAnEmptyRect() {
        let outer = NSRect(x: 0, y: 0, width: 1000, height: 800)
        // Flush against the left edge: there is no room for a left band.
        let hole = NSRect(x: 0, y: 200, width: 400, height: 300)

        let bands = PaneZoomBlurOverlay.blurBands(around: hole, in: outer)

        XCTAssertEqual(bands.count, 3, "top, bottom and right only — no zero-width left band")
        for band in bands {
            XCTAssertGreaterThan(band.width, 0)
            XCTAssertGreaterThan(band.height, 0)
        }
    }

    func testBlurBandsWithNoHoleBlursTheWholeOuterRect() {
        let outer = NSRect(x: 0, y: 0, width: 1000, height: 800)

        XCTAssertEqual(PaneZoomBlurOverlay.blurBands(around: .zero, in: outer), [outer])
    }

    func testBlurBandsWithAnEmptyOuterRectProducesNothing() {
        XCTAssertEqual(
            PaneZoomBlurOverlay.blurBands(around: NSRect(x: 0, y: 0, width: 10, height: 10), in: .zero),
            []
        )
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd macos && ./build.sh test 2>&1 | grep -E "testBlurBands|error:"`
Expected: compile error — `PaneZoomBlurOverlay` does not exist yet.

- [ ] **Step 3: Write the minimal implementation**

Open `macos/OmniAgent/PaneWorkspaceView.swift`, find `final class PaneZoomBackdropView: NSVisualEffectView {` and its matching closing `}` (the class ends right before the doc comment for `PaneHeaderView` — search for `/// One rectangular slice` is not present yet, so instead search for the literal text `final class PaneHeaderView: NSView {` and insert the new class immediately before that, right after `PaneZoomBackdropView`'s closing brace). Insert:

```swift
/// Up to four borderless, transparent windows tiling the region around a
/// zoomed pane's card, each a real system blur (`.behindWindow` — what the
/// Dock, Mission Control and Notification Center use) of whatever is
/// actually on screen behind it: the main window's panes, sidebar,
/// everything, Metal-rendered terminal content included, because this
/// reads the composited screen buffer rather than trying to sample sibling
/// layers inside one window's own compositing tree the way
/// `PaneZoomBackdropView`'s `.withinWindow` blending does — confirmed, not
/// guessed, to blur nothing in this app: even the plain, non-Metal sidebar
/// behind it showed no blur, only that view's own flat tint.
///
/// No auxiliary window's *frame* ever overlaps the card's own screen rect
/// — `blurBands` guarantees that — so clicking the card reaches the main
/// window underneath with no hit-testing or click-passthrough trick
/// needed: there is simply nothing covering that region.
final class PaneZoomBlurOverlay {
    /// The standard "outer rect minus inner rect" decomposition: a
    /// full-width band above the hole, a full-width band below it, and two
    /// bands exactly as tall as the hole to its left and right. Together
    /// with the hole itself these tile `outer` with no gaps and no
    /// overlaps. A side with no room (the hole flush against that edge, or
    /// past it) is omitted rather than emitted as a zero- or negative-sized
    /// rect — an empty window is a real `NSWindow` doing nothing.
    ///
    /// Static and pure so the geometry can be checked without a window,
    /// the same reason `PaneWorkspaceView.focusCardFrame(in:)` is.
    static func blurBands(around hole: NSRect, in outer: NSRect) -> [NSRect] {
        guard outer.width > 0, outer.height > 0 else { return [] }
        let clampedHole = hole.intersection(outer)
        guard !clampedHole.isEmpty else { return [outer] }

        var bands: [NSRect] = []
        let top = NSRect(
            x: outer.minX, y: clampedHole.maxY,
            width: outer.width, height: outer.maxY - clampedHole.maxY
        )
        if top.height > 0 { bands.append(top) }

        let bottom = NSRect(
            x: outer.minX, y: outer.minY,
            width: outer.width, height: clampedHole.minY - outer.minY
        )
        if bottom.height > 0 { bands.append(bottom) }

        let left = NSRect(
            x: outer.minX, y: clampedHole.minY,
            width: clampedHole.minX - outer.minX, height: clampedHole.height
        )
        if left.width > 0 { bands.append(left) }

        let right = NSRect(
            x: clampedHole.maxX, y: clampedHole.minY,
            width: outer.maxX - clampedHole.maxX, height: clampedHole.height
        )
        if right.width > 0 { bands.append(right) }

        return bands
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd macos && ./build.sh test 2>&1 | grep -E "testBlurBands|TEST (SUCCEEDED|FAILED)"`
Expected: all four new tests pass.

- [ ] **Step 5: Commit**

```bash
git add macos/OmniAgent/PaneWorkspaceView.swift macos/OmniAgentTests/PaneWorkspaceViewTests.swift
git commit -m "$(cat <<'EOF'
feat(macos): pure geometry for tiling blur bands around the focus card

PaneZoomBlurOverlay.blurBands(around:in:) decomposes an outer rect minus
an inner hole into up to four non-overlapping bands (top, bottom, left,
right) — the layout four auxiliary blur windows will tile in a later
task. Pure and static, tested directly with plain NSRect values, no
window needed, the same pattern focusCardFrame(in:) already uses.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01AA8fLnpANER99Nq4dGy2Hy
EOF
)"
```

---

### Task 2: The blur band window and its click-swallowing content view

**Files:**
- Modify: `macos/OmniAgent/PaneWorkspaceView.swift` (add two more classes right after `PaneZoomBlurOverlay`'s closing `}` from Task 1)
- Test: `macos/OmniAgentTests/PaneWorkspaceViewTests.swift`

**Interfaces:**
- Consumes: nothing from Task 1 directly (this task adds sibling types).
- Produces: `PaneZoomBlurBandView: NSVisualEffectView` (with `var onClick: (() -> Void)?`), `PaneZoomBlurPanel: NSPanel` (with `var onClick: (() -> Void)?` forwarding to its content view). Task 3 constructs `PaneZoomBlurPanel` instances and reads/writes `onClick` on them.

- [ ] **Step 1: Write the failing tests**

In `macos/OmniAgentTests/PaneWorkspaceViewTests.swift`, add after the Task 1 tests:

```swift
    /// Mirrors `testTheBackdropBlursTheAppBehindItAndTintsNothing`'s shape:
    /// configuration only, no pixels — `.behindWindow` blur is exactly as
    /// unrenderable in an offscreen test as `.withinWindow` was, this just
    /// confirms the one property that actually decides whether real blur
    /// happens (`blendingMode`), plus everything else the panel needs.
    func testBlurBandViewIsConfiguredForRealSystemBlur() {
        let band = PaneZoomBlurBandView()

        XCTAssertEqual(band.blendingMode, .behindWindow, "reads the real screen buffer, not sibling layers")
        XCTAssertEqual(band.state, .active, "blurred whether or not the window is key")
        XCTAssertEqual(band.material, .sidebar)
    }

    func testBlurBandViewSwallowsMouseDownAndFiresOnClickOnMouseUp() throws {
        let band = PaneZoomBlurBandView()
        var clicked = false
        band.onClick = { clicked = true }

        // The exact construction `testClickingAnywhereInAPaneMakesItTheActiveOne`
        // and others in this file already use for a synthetic mouse event —
        // `NSEvent` has no bare parameterless initializer.
        func mouseEvent(_ type: NSEvent.EventType) throws -> NSEvent {
            try XCTUnwrap(
                NSEvent.mouseEvent(
                    with: type, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
                )
            )
        }

        band.mouseDown(with: try mouseEvent(.leftMouseDown))
        XCTAssertFalse(clicked, "mouseDown alone must not dismiss the zoom")

        band.mouseUp(with: try mouseEvent(.leftMouseUp))
        XCTAssertTrue(clicked)
    }

    func testBlurPanelIsABorderlessNonactivatingTransparentWindowHostingABandView() {
        let panel = PaneZoomBlurPanel()

        XCTAssertTrue(panel.styleMask.contains(.borderless))
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel), "must never steal key window / app activation")
        XCTAssertFalse(panel.isOpaque)
        XCTAssertFalse(panel.hasShadow, "the shadow belongs to the card, not to a plain rectangle of blur")
        XCTAssertTrue(panel.contentView is PaneZoomBlurBandView)

        var clicked = false
        panel.onClick = { clicked = true }
        (panel.contentView as? PaneZoomBlurBandView)?.onClick?()
        XCTAssertTrue(clicked, "the panel's onClick must forward to its content view's")
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd macos && ./build.sh test 2>&1 | grep -E "testBlurBandView|testBlurPanel|error:"`
Expected: compile error — `PaneZoomBlurBandView` / `PaneZoomBlurPanel` do not exist yet.

- [ ] **Step 3: Write the minimal implementation**

Insert immediately after `PaneZoomBlurOverlay`'s closing `}` from Task 1:

```swift
/// One rectangular slice of the region around a zoomed pane's card,
/// showing real system blur. `.sidebar` for the same reason
/// `PaneZoomBackdropView` picked it: the middle-tier material real frosted
/// glass uses, without `.hudWindow`'s dark panel tint.
final class PaneZoomBlurBandView: NSVisualEffectView {
    static let material: NSVisualEffectView.Material = .sidebar

    var onClick: (() -> Void)?

    init() {
        super.init(frame: .zero)
        material = Self.material
        blendingMode = .behindWindow
        state = .active
        appearance = NSAppearance(named: .darkAqua)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    // Swallowed for the same reason PaneZoomBackdropView's is: a click
    // meant for "get me out of here" must not reach — or focus — the
    // blurred pane underneath.
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) { onClick?() }
}

/// The window one blur band lives in: borderless and non-activating so
/// clicking it never steals key window status or app activation from the
/// main window, transparent everywhere its content view is not painting
/// blur, and with no shadow of its own — the card's shadow belongs to the
/// card, not to a plain rectangle standing in for empty space.
final class PaneZoomBlurPanel: NSPanel {
    var onClick: (() -> Void)? {
        get { bandView.onClick }
        set { bandView.onClick = newValue }
    }

    private let bandView = PaneZoomBlurBandView()

    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        // Never torn down by AppKit out from under PaneZoomBlurOverlay's
        // own pooling — `close()` is never called on these, `orderOut`
        // and `removeChildWindow` are, and this panel is reused, not
        // recreated, across a `hide()`/`show()` pair.
        isReleasedWhenClosed = false
        contentView = bandView
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd macos && ./build.sh test 2>&1 | grep -E "testBlurBandView|testBlurPanel|TEST (SUCCEEDED|FAILED)"`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add macos/OmniAgent/PaneWorkspaceView.swift macos/OmniAgentTests/PaneWorkspaceViewTests.swift
git commit -m "$(cat <<'EOF'
feat(macos): borderless blur panel with a click-swallowing band view

PaneZoomBlurBandView is an NSVisualEffectView configured for real
.behindWindow blur (the reliable mechanism .withinWindow is not, see
PaneZoomBlurOverlay's doc comment) and swallows mouseDown the same way
PaneZoomBackdropView already does, firing onClick only on mouseUp.
PaneZoomBlurPanel hosts one as a borderless, non-activating, shadowless,
transparent NSPanel — the window one blur band from Task 1's geometry
will live in.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01AA8fLnpANER99Nq4dGy2Hy
EOF
)"
```

---

### Task 3: Show/hide orchestration

**Files:**
- Modify: `macos/OmniAgent/PaneWorkspaceView.swift` (extend `PaneZoomBlurOverlay` from Task 1 with instance state and methods)
- Test: `macos/OmniAgentTests/PaneWorkspaceViewTests.swift`

**Interfaces:**
- Consumes: `PaneZoomBlurOverlay.blurBands(around:in:)` (Task 1), `PaneZoomBlurPanel` (Task 2).
- Produces: `PaneZoomBlurOverlay.show(around hole: NSRect, in outer: NSRect, parent: NSWindow)`, `PaneZoomBlurOverlay.hide()`, `PaneZoomBlurOverlay.isShown: Bool`, `var onClick: (() -> Void)?`. Task 4 constructs one `PaneZoomBlurOverlay`, sets `onClick`, and calls `show`/`hide`/`isShown` from `PaneWorkspaceView`.

- [ ] **Step 1: Write the failing tests**

Add after the Task 2 tests:

```swift
    /// `show` in screen coordinates against a real (offscreen, zero-size is
    /// fine — nothing here needs to be visible) NSWindow, checking the
    /// bookkeeping `PaneWorkspaceView` will rely on: the right number of
    /// child windows, at the geometry `blurBands` computed, and cleanly
    /// removable — this is the level real coverage is possible at; the
    /// blur itself is exactly as unrenderable offscreen as
    /// PaneZoomBackdropView's always was.
    func testZoomBlurOverlayShowsOneChildWindowPerBandAndHideRemovesThem() {
        let parent = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.borderless], backing: .buffered, defer: true
        )
        let overlay = PaneZoomBlurOverlay()
        let outer = NSRect(x: 0, y: 0, width: 1000, height: 800)
        let hole = NSRect(x: 300, y: 250, width: 400, height: 300)

        overlay.show(around: hole, in: outer, parent: parent)

        let expectedBands = PaneZoomBlurOverlay.blurBands(around: hole, in: outer)
        XCTAssertEqual(parent.childWindows?.count, expectedBands.count)
        XCTAssertEqual(Set(parent.childWindows?.map(\.frame) ?? []), Set(expectedBands))
        XCTAssertTrue(overlay.isShown)

        overlay.hide()

        XCTAssertEqual(parent.childWindows?.count ?? 0, 0)
        XCTAssertFalse(overlay.isShown)
    }

    func testZoomBlurOverlayReusesItsPanelsRatherThanLeakingNewOnesEachShow() {
        let parent = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.borderless], backing: .buffered, defer: true
        )
        let overlay = PaneZoomBlurOverlay()
        let outer = NSRect(x: 0, y: 0, width: 1000, height: 800)

        overlay.show(around: NSRect(x: 300, y: 250, width: 400, height: 300), in: outer, parent: parent)
        let firstRun = Set(parent.childWindows?.map(ObjectIdentifier.init) ?? [])

        overlay.show(around: NSRect(x: 100, y: 100, width: 200, height: 200), in: outer, parent: parent)
        let secondRun = Set(parent.childWindows?.map(ObjectIdentifier.init) ?? [])

        XCTAssertEqual(firstRun, secondRun, "the same panel objects, repositioned, not new ones each call")
    }

    func testZoomBlurOverlayClickForwardsToOnClick() {
        let parent = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.borderless], backing: .buffered, defer: true
        )
        let overlay = PaneZoomBlurOverlay()
        var clicked = false
        overlay.onClick = { clicked = true }

        overlay.show(
            around: NSRect(x: 300, y: 250, width: 400, height: 300),
            in: NSRect(x: 0, y: 0, width: 1000, height: 800),
            parent: parent
        )
        let panel = try! XCTUnwrap(parent.childWindows?.first as? PaneZoomBlurPanel)
        panel.onClick?()

        XCTAssertTrue(clicked)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd macos && ./build.sh test 2>&1 | grep -E "testZoomBlurOverlay|error:"`
Expected: compile error — `show`, `hide`, `isShown`, `onClick` do not exist on `PaneZoomBlurOverlay` yet.

- [ ] **Step 3: Write the minimal implementation**

In `PaneZoomBlurOverlay` (from Task 1), add instance state and methods alongside the existing `static func blurBands`:

```swift
final class PaneZoomBlurOverlay {
    private var panels: [PaneZoomBlurPanel] = []
    var onClick: (() -> Void)?

    /// True once at least one band is on screen — `PaneWorkspaceView` uses
    /// this to know a window resize needs to reposition them rather than
    /// leave stale geometry from before the resize.
    var isShown: Bool { !panels.isEmpty }

    /// Shows exactly as many panels as `blurBands` computes for this
    /// `hole`/`outer` pair, reusing whatever panels already exist — a panel
    /// is a generic rectangle of blur, which band it was last positioned as
    /// does not matter — creating new ones only if more are needed and
    /// releasing extras back out rather than leaving them parked offscreen.
    func show(around hole: NSRect, in outer: NSRect, parent: NSWindow) {
        let bands = Self.blurBands(around: hole, in: outer)
        guard !bands.isEmpty else { return hide() }

        while panels.count < bands.count {
            panels.append(PaneZoomBlurPanel())
        }
        while panels.count > bands.count {
            let panel = panels.removeLast()
            parent.removeChildWindow(panel)
            panel.orderOut(nil)
        }

        for (panel, band) in zip(panels, bands) {
            panel.onClick = { [weak self] in self?.onClick?() }
            panel.setFrame(band, display: true)
            if panel.parent == nil {
                parent.addChildWindow(panel, ordered: .above)
            }
            panel.orderFront(nil)
        }
    }

    /// Idempotent: safe to call whether or not anything is currently shown,
    /// so every call site that ends a zoom transition can call it
    /// unconditionally rather than tracking whether blur happened to be up.
    func hide() {
        guard !panels.isEmpty else { return }
        for panel in panels {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
        panels.removeAll()
    }

    // MARK: - Geometry
    // (blurBands from Task 1 stays here, unchanged)
```

(`blurBands` from Task 1 does not move — this just adds the new members alongside it, before the class's closing `}`.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd macos && ./build.sh test 2>&1 | grep -E "testZoomBlurOverlay|TEST (SUCCEEDED|FAILED)"`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add macos/OmniAgent/PaneWorkspaceView.swift macos/OmniAgentTests/PaneWorkspaceViewTests.swift
git commit -m "$(cat <<'EOF'
feat(macos): PaneZoomBlurOverlay show/hide orchestration

show(around:in:parent:) turns blurBands' geometry into real child
windows — reusing existing panels across calls rather than leaking new
ones, creating or releasing only the count difference. hide() is
idempotent so every call site in the next task can call it
unconditionally. onClick forwards from whichever panel was clicked.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01AA8fLnpANER99Nq4dGy2Hy
EOF
)"
```

---

### Task 4: Wire it into the zoom lifecycle

**Files:**
- Modify: `macos/OmniAgent/PaneWorkspaceView.swift` (the `PaneWorkspaceView` class: `zoomBackdrop`'s doc comments, a new `zoomBlur` property, `applyZoom`, `collapseZoom`, `finishZoomTransition`, `updateLayout`, `teardownOverlay`)
- Modify: `macos/OmniAgentTests/PaneWorkspaceViewTests.swift` (rename/refocus the existing backdrop test)

**Interfaces:**
- Consumes: `PaneZoomBlurOverlay` (Task 3), `PaneZoomBlurOverlay.isShown`, `.show(around:in:parent:)`, `.hide()`, `.onClick`.
- Produces: nothing further downstream — this is the final integration task.

- [ ] **Step 1: Correct `PaneZoomBackdropView`'s misleading doc comments**

Find this doc comment block (the one directly above `final class PaneZoomBackdropView: NSVisualEffectView {`):

```swift
/// The blurred backdrop a zoomed pane sits on, and the way out of the zoom
/// that does not require finding the button again.
///
/// This was a layer background filter, to keep `NSVisualEffectView`'s
/// display-link-backed animation machine out of the test host — one that had
/// been seen spinning forever retrying `CVDisplayLinkCreateWithCGDisplays` where
/// no display exists. It bought a suite that never blurred anything: see `init`.
/// The effect view is back, and the constraint it was avoided for is now a
/// property of the *host*, not of this view — a test host with no display attached
/// must not construct one.
final class PaneZoomBackdropView: NSVisualEffectView {
```

Replace with:

```swift
/// The dim tint a zoomed pane sits on. Despite `blendingMode = .withinWindow`
/// below, this does **not** blur anything — confirmed directly on screen: even
/// the plain, non-Metal sidebar behind it shows no blur, only this view's own
/// flat material tint. `.withinWindow` blending samples sibling views inside
/// one window's own private compositing tree, and in this window that
/// sampling produces nothing visible; `.behindWindow` (`PaneZoomBlurOverlay`,
/// real auxiliary windows) is what actually blurs the panes behind the card.
/// This view stays for the tint alone, and because it is what animates in
/// smoothly the instant a zoom starts — `PaneZoomBlurOverlay` only appears
/// once that animation has settled, to avoid syncing four separate window
/// frames against an in-flight CALayer animation.
///
/// This was a layer background filter before it was an in-window
/// `NSVisualEffectView`, to keep `NSVisualEffectView`'s display-link-backed
/// animation machine out of the test host — one that had been seen spinning
/// forever retrying `CVDisplayLinkCreateWithCGDisplays` where no display
/// exists. It bought a suite that never blurred anything: see `init`. The
/// effect view is back, and the constraint it was avoided for is now a
/// property of the *host*, not of this view — a test host with no display
/// attached must not construct one.
final class PaneZoomBackdropView: NSVisualEffectView {
```

Also find, inside that same class's `init`, this comment above `blendingMode = .withinWindow`:

```swift
    /// `backdrop-filter:blur(16px)` as the platform's own within-window blur,
    /// rather than the `CIGaussianBlur` in `layer.backgroundFilters` this used to
    /// carry. That is what "the background is not blurred" was:
    /// `backgroundFilters` are only composited for layers the window server can
    /// read back through, which a layer-backed view inside an ordinary window is
    /// not — the filter was installed, ramped, and drew nothing, leaving a flat
    /// 62% black wash over a perfectly sharp app. `NSVisualEffectView` with
    /// `.withinWindow` blurs the sibling views behind it, which is exactly what
    /// the design's overlay does.
    ///
    /// No tint over it, and the design's `rgba(6,6,8,.62)` is deliberately not
    /// reproduced. It is a wash meant to carry a CSS blur on its own; here the
    /// blur already makes the app unreadable, which is the entire job, and every
    /// amount of black tried on top of it — .62, .22, .12 — only took away the
    /// one thing focus mode should leave you: seeing where everything else is.
    init() {
```

Replace with:

```swift
    /// `.withinWindow`, tried as the platform's own within-window blur to
    /// replace the `CIGaussianBlur` in `layer.backgroundFilters` this used to
    /// carry (`backgroundFilters` are only composited for layers the window
    /// server can read back through, which a layer-backed view in an ordinary
    /// window is not — that filter was installed, ramped, and drew nothing,
    /// leaving a flat 62% black wash over a perfectly sharp app). This
    /// replacement does blend — the tint below is real — but does not blur:
    /// see the class doc comment. Left as `.withinWindow` anyway rather than
    /// switched to `.behindWindow` here too, because a view *inside* the main
    /// window cannot use `.behindWindow` blending to blur that same window's
    /// own content — `.behindWindow` blurs whatever is behind the window
    /// hosting it, and this view's window *is* the main window. Real blur
    /// needed a window of its own: `PaneZoomBlurOverlay`.
    ///
    /// No tint beyond the material's own, and the design's `rgba(6,6,8,.62)`
    /// is deliberately not reproduced. It is a wash meant to carry a CSS blur
    /// on its own; every amount of black tried on top of it here — .62, .22,
    /// .12 — only took away the one thing focus mode should leave you: seeing
    /// where everything else is.
    init() {
```

- [ ] **Step 2: Add the `zoomBlur` property**

Find:

```swift
    private lazy var zoomBackdrop: PaneZoomBackdropView = {
        let view = PaneZoomBackdropView()
        view.onClick = { [weak self] in self?.setZoomed(nil) }
        return view
    }()
```

Replace with:

```swift
    private lazy var zoomBackdrop: PaneZoomBackdropView = {
        let view = PaneZoomBackdropView()
        view.onClick = { [weak self] in self?.setZoomed(nil) }
        return view
    }()

    /// The real blur `zoomBackdrop` cannot provide — see its doc comment.
    /// Shown only once a zoom's grow animation has settled
    /// (`finishZoomTransition`) and hidden the instant any transition
    /// starts (`applyZoom`, `collapseZoom`), so nothing has to track it
    /// through the ~0.38s the card is actually moving.
    private lazy var zoomBlur: PaneZoomBlurOverlay = {
        let overlay = PaneZoomBlurOverlay()
        overlay.onClick = { [weak self] in self?.setZoomed(nil) }
        return overlay
    }()
```

- [ ] **Step 3: Hide blur the instant any transition starts**

Find, in `applyZoom()`:

```swift
    private func applyZoom() {
        guard let id = zoomedPaneID, let container = containers[id] else {
            return collapseZoom()
        }
```

Replace with:

```swift
    private func applyZoom() {
        guard let id = zoomedPaneID, let container = containers[id] else {
            return collapseZoom()
        }
        // Stale geometry from whatever was zoomed before — a different
        // pane, or this same one at its old card rect — must never show
        // through a transition; only `finishZoomTransition` puts it back,
        // once the new target has settled.
        zoomBlur.hide()
```

Find, in `collapseZoom()`:

```swift
    private func collapseZoom() {
        zoomBackdrop.setShown(false, duration: zoomTransition)
```

Replace with:

```swift
    private func collapseZoom() {
        zoomBlur.hide()
        zoomBackdrop.setShown(false, duration: zoomTransition)
```

- [ ] **Step 4: Show blur once the grow animation settles**

Find:

```swift
    private func finishZoomTransition(_ token: Int) {
        guard token == zoomTransitionToken, overlayIsCollapsing, let id = overlayPaneID
        else { return }
        landCard(id)
        teardownOverlay()
    }
```

Replace with:

```swift
    private func finishZoomTransition(_ token: Int) {
        guard token == zoomTransitionToken else { return }
        if overlayIsCollapsing, let id = overlayPaneID {
            landCard(id)
            teardownOverlay()
            return
        }
        // A grow just settled, and nothing since has changed the target —
        // a switch straight to a different pane, or an exit, would have
        // moved the token on and failed the guard above already.
        if let zoomedPaneID, overlayPaneID == zoomedPaneID {
            showZoomBlur(around: zoomedPaneID)
        }
    }

    /// Converts the card's current rect — read from the live view, in the
    /// overlay host's coordinate space — to screen coordinates and shows
    /// `zoomBlur` around it. Also what `updateLayout` calls to reposition
    /// the bands if the window resizes while blur is already showing;
    /// `PaneZoomBlurOverlay.show` is safe to call repeatedly with updated
    /// geometry, it just repositions its existing panels.
    private func showZoomBlur(around id: String) {
        guard
            let window,
            let container = containers[id],
            container.superview === focusOverlay
        else { return }
        let outer = window.convertToScreen(focusOverlay.convert(focusOverlay.bounds, to: nil))
        let hole = window.convertToScreen(focusOverlay.convert(container.frame, to: nil))
        zoomBlur.show(around: hole, in: outer, parent: window)
    }
```

- [ ] **Step 5: Reposition blur on resize, and add a final safety net in `teardownOverlay`**

Find, in `updateLayout()`:

```swift
        syncDividerViews(layout.dividers)
        syncHolePlaceholders(layout, holeIDs: grid.cells.filter(\.isHole).map(\.id))
        applyZoom()
        updateAccessibilityLabels()
        refreshFocusSubtitles()
    }
```

Replace with:

```swift
        syncDividerViews(layout.dividers)
        syncHolePlaceholders(layout, holeIDs: grid.cells.filter(\.isHole).map(\.id))
        applyZoom()
        // A window resize while blur is already settled and showing has to
        // move with it — `addChildWindow` tracks the main window's *moves*
        // automatically, but not its resizes.
        if zoomBlur.isShown, let zoomedPaneID, overlayPaneID == zoomedPaneID, !overlayIsCollapsing {
            showZoomBlur(around: zoomedPaneID)
        }
        updateAccessibilityLabels()
        refreshFocusSubtitles()
    }
```

Find, in `teardownOverlay()`:

```swift
    private func teardownOverlay() {
        focusCardShadow.removeFromSuperlayer()
```

Replace with:

```swift
    private func teardownOverlay() {
        // Idempotent — a safety net covering any path here that did not
        // already go through applyZoom/collapseZoom's own zoomBlur.hide().
        zoomBlur.hide()
        focusCardShadow.removeFromSuperlayer()
```

- [ ] **Step 6: Refocus the existing backdrop test on what it actually verifies**

In `macos/OmniAgentTests/PaneWorkspaceViewTests.swift`, find `func testTheBackdropBlursTheAppBehindItAndTintsNothing()` in full (its doc comment and body), and replace the whole thing with:

```swift
    /// `PaneZoomBackdropView` provides the dim tint alone, not blur — see
    /// its class doc comment. Real blur is `PaneZoomBlurOverlay`, covered by
    /// its own tests; this only confirms the tint's own configuration.
    func testTheBackdropTintsTheAppBehindItAndDoesNotClaimToBlurIt() throws {
        let backdrop = PaneZoomBackdropView()
        backdrop.frame = NSRect(x: 0, y: 0, width: 400, height: 300)

        XCTAssertEqual(backdrop.blendingMode, .withinWindow)
        XCTAssertEqual(backdrop.state, .active, "tinted whether or not the window is key")
        XCTAssertEqual(backdrop.material, .sidebar)

        backdrop.setShown(true, duration: 0)
        backdrop.layoutSubtreeIfNeeded()
        XCTAssertEqual(backdrop.subviews, [], "nothing tinting the tint")
        // Short of 1, on purpose: at full alpha nothing of the sharp app
        // shows through, only the material's own tint — see `shownAlpha`.
        XCTAssertEqual(backdrop.alphaValue, 0.78)
    }
```

(This changes only the function's name and doc comment — every assertion inside is identical to what was already there, since `PaneZoomBackdropView`'s actual behavior is unchanged by this plan. If Xcode/Swift flags a duplicate-symbol error because both the old and new function names briefly coexist, make sure the *old* `testTheBackdropBlursTheAppBehindItAndTintsNothing` was fully replaced, not left in place alongside the new one.)

- [ ] **Step 7: Run the full test suite**

Run: `cd macos && ./build.sh test 2>&1 | tail -15`
Expected: `** TEST SUCCEEDED **`, no failures.

- [ ] **Step 8: Commit**

```bash
git add macos/OmniAgent/PaneWorkspaceView.swift macos/OmniAgentTests/PaneWorkspaceViewTests.swift
git commit -m "$(cat <<'EOF'
fix(macos): real blur behind the zoomed pane via auxiliary windows

Wires PaneZoomBlurOverlay into the zoom lifecycle: hidden the instant any
transition starts (applyZoom, collapseZoom), shown once a grow settles
(finishZoomTransition, now branching on overlayIsCollapsing instead of
only ever handling the shrink-completed case), repositioned on resize
while already showing (updateLayout), and torn down as a safety net
(teardownOverlay). PaneZoomBackdropView is unchanged behaviorally — it
still provides the dim tint throughout every transition — only its doc
comments are corrected: they claimed .withinWindow blending blurs the
panes behind it, which direct on-screen confirmation (the plain, non-Metal
sidebar showed no blur either) proved false.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01AA8fLnpANER99Nq4dGy2Hy
EOF
)"
```

---

### Task 5: Build the real app and hand off for a visual check

**Files:** none (build/install only).

**Interfaces:** none — this task consumes the finished feature from Task 4 and produces a running app build for the user to look at.

- [ ] **Step 1: Full workspace test run**

Run: `cd macos && ./build.sh test 2>&1 | tail -10`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 2: Rebuild, sign, and install the native app**

Run: `./scripts/rebuild-app.sh --no-notarize`
Expected: ends with `Installed OmniAgent <version> (native) -> /Applications/OmniAgent.app`. Note the printed version string for the handoff message.

- [ ] **Step 3: Hand off to the user for the one check that actually matters**

This plan cannot verify the blur is visible — `screencapture`, `CGWindowListCreateImage`, and every other on-screen pixel-reading API require Screen Recording permission that is not available in this environment (confirmed earlier in the conversation this plan came from), and an offscreen `CALayer.render(in:)`/`cacheDisplay` snapshot would not exercise the real window-server compositing `.behindWindow` blur depends on even if it were attempted. Tell the user, in the final report:

- The app is rebuilt and installed at the version printed in Step 2.
- Ask them to press ⌘↩ on any pane with at least one sibling, wait for the card to finish growing, and confirm the area around the card now shows real blur (soft, indistinct shapes) rather than a flat tint.
- If it still is not visible, the next diagnostic step is confirming the auxiliary panels are actually being added as child windows at runtime (e.g., attach `lldb -p <OmniAgent pid>` and inspect `WorkspaceWindowController`'s `workspaceView.zoomBlur` state, or a temporary `NSLog` in `showZoomBlur`) rather than guessing at another material or blending mode change — the mechanism itself (`.behindWindow`) is not in question, only whether the wiring is reaching it.

- [ ] **Step 4: No commit** — this task only builds and reports; there is nothing to commit beyond what Task 4 already committed.
