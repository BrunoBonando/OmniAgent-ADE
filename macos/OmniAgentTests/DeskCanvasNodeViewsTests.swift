import AppKit
import XCTest
@testable import OmniAgent

/// The organigram's two drawn pieces: the chips that stand for the account and
/// the workspaces, and the single shape layer that carries every connector.
/// Both are frame-driven — `DeskCanvas.layout` owns every rect — so everything
/// here is checked either as pure geometry or through the repo's offscreen
/// render convention.
final class DeskCanvasNodeViewsTests: XCTestCase {

    // MARK: - Connectors

    /// One elbow per edge: down out of the parent's bottom, across at the waist,
    /// down into the child's top. Canvas space is FLIPPED
    /// (`PaneWorkspaceView.isFlipped == true`), so a parent's `maxY` is its
    /// *bottom* edge and the child sits at the larger y. Reading that the other
    /// way round draws every connector backwards through its own parent, and it
    /// is exactly the class of mistake the PNG harness cannot catch.
    func testEachConnectorLeavesTheParentsBottomAndArrivesAtTheChildsTop() {
        let layout = DeskCanvasLayout(
            frames: [
                "parent": CGRect(x: 100, y: 0, width: 200, height: 80),
                "child": CGRect(x: 0, y: 200, width: 120, height: 60),
            ],
            edges: [DeskEdge(from: "parent", to: "child")],
            contentRect: CGRect(x: 0, y: 0, width: 300, height: 260)
        )

        let path = DeskCanvasEdgeLayer.path(for: layout)
        let box = path.boundingBoxOfPath

        XCTAssertEqual(box.minY, 80, accuracy: 0.01, "it starts at the parent's bottom edge")
        XCTAssertEqual(box.maxY, 200, accuracy: 0.01, "and ends at the child's top edge")
        XCTAssertEqual(box.minX, 60, accuracy: 0.01, "spanning the child's centre")
        XCTAssertEqual(box.maxX, 200, accuracy: 0.01, "to the parent's centre")
        XCTAssertFalse(path.isEmpty, "one edge, one elbow")
    }

    /// Every connector in one path on one layer. A tree of an account, a few
    /// workspaces and up to eight sessions is a few dozen edges, and a few dozen
    /// sublayers is a few dozen composites on every frame of a pinch.
    func testEveryEdgeGoesIntoOnePathNotOneLayerEach() throws {
        let layout = DeskCanvasLayout(
            frames: [
                "a": CGRect(x: 0, y: 0, width: 100, height: 40),
                "b": CGRect(x: 0, y: 100, width: 100, height: 40),
                "c": CGRect(x: 200, y: 100, width: 100, height: 40),
            ],
            edges: [DeskEdge(from: "a", to: "b"), DeskEdge(from: "a", to: "c")],
            contentRect: CGRect(x: 0, y: 0, width: 300, height: 140)
        )
        let edgeLayer = DeskCanvasEdgeLayer()

        edgeLayer.apply(layout, scale: 1)

        XCTAssertNil(edgeLayer.sublayers, "one layer, one path")
        let box = try XCTUnwrap(edgeLayer.path).boundingBoxOfPath
        XCTAssertEqual(box.maxX, 250, accuracy: 0.01, "both edges are in it")
    }

    /// An edge naming a node the layout does not hold is skipped rather than
    /// crashing: the tree and the frames are computed together, but a pinned
    /// node removed mid-drag is the way to get one out of step.
    func testAnEdgeToAMissingNodeIsSkippedRatherThanDrawn() {
        let layout = DeskCanvasLayout(
            frames: ["a": CGRect(x: 0, y: 0, width: 100, height: 40)],
            edges: [DeskEdge(from: "a", to: "gone")],
            contentRect: CGRect(x: 0, y: 0, width: 100, height: 40)
        )

        XCTAssertTrue(DeskCanvasEdgeLayer.path(for: layout).isEmpty, "nothing to draw, nothing drawn")
    }

    /// The camera is a `sublayerTransform`, which scales the stroke along with
    /// everything else: at `fitAll` a 1pt line is 0.2pt, under one device pixel,
    /// and the connectors fade out exactly when the tree is the only thing on
    /// screen. The width is divided back out.
    func testTheConnectorStrokeIsDividedBackOutOfTheCameraScale() {
        let layout = DeskCanvasLayout(
            frames: [
                "a": CGRect(x: 0, y: 0, width: 100, height: 40),
                "b": CGRect(x: 0, y: 100, width: 100, height: 40),
            ],
            edges: [DeskEdge(from: "a", to: "b")],
            contentRect: CGRect(x: 0, y: 0, width: 100, height: 140)
        )
        let edgeLayer = DeskCanvasEdgeLayer()

        edgeLayer.apply(layout, scale: 1)
        XCTAssertEqual(edgeLayer.lineWidth, DeskCanvasEdgeLayer.strokeWidth, accuracy: 0.001)

        edgeLayer.apply(layout, scale: 0.2)
        XCTAssertEqual(
            edgeLayer.lineWidth,
            DeskCanvasEdgeLayer.strokeWidth / 0.2,
            accuracy: 0.001,
            "five times as wide in canvas units, one point on screen"
        )

        edgeLayer.apply(layout, scale: 0)
        XCTAssertEqual(edgeLayer.lineWidth, DeskCanvasEdgeLayer.strokeWidth, accuracy: 0.001, "no divide by zero")
    }

    /// `CAShapeLayer` animates `path` and `lineWidth` implicitly, and the camera
    /// changes `lineWidth` on every frame of a pinch.
    func testTheEdgeLayerRefusesImplicitAnimationsOnEveryKey() {
        let edgeLayer = DeskCanvasEdgeLayer()
        for key in ["path", "lineWidth", "strokeColor", "position"] {
            XCTAssertTrue(
                edgeLayer.action(forKey: key) is NSNull,
                "\(key) must not animate itself sixty times a second"
            )
        }
    }

    /// Core Animation copies a layer through `init(layer:)` to build the
    /// presentation layer. A subclass that does not implement it gets a copy
    /// with none of its own state — and the presentation layer is what is on
    /// screen during any animation the canvas runs over it.
    func testTheEdgeLayerSurvivesCoreAnimationsCopyInitializer() {
        let original = DeskCanvasEdgeLayer()
        let copy = DeskCanvasEdgeLayer(layer: original)
        XCTAssertTrue(copy.action(forKey: "path") is NSNull, "the copy is still a DeskCanvasEdgeLayer")
    }

    // MARK: - Chips

    /// The chip is frame-driven: `DeskCanvas.layout` owns every rect
    /// (`chipWidthFraction` of a session card's width), so the view has no
    /// intrinsic size of its own and everything it draws is a fraction of
    /// `bounds`. That is what keeps it legible at fit-all, where a fixed 13pt
    /// label would be 2pt of screen.
    func testTheChipHasNoOpinionAboutItsOwnSizeAndTakesTheFrameItIsGiven() {
        let chip = DeskCanvasChipView(role: .workspace)
        chip.frame = CGRect(x: 0, y: 0, width: 300, height: 120)

        XCTAssertEqual(chip.intrinsicContentSize.width, NSView.noIntrinsicMetric, "the layout sizes it")
        XCTAssertEqual(chip.intrinsicContentSize.height, NSView.noIntrinsicMetric)
        XCTAssertEqual(chip.bounds.size, CGSize(width: 300, height: 120))
    }

    /// Flipped, like the canvas it sits in — `PaneWorkspaceView.isFlipped` is
    /// `true` and the node rects are in that space, so a chip that disagreed
    /// would draw its tile at the bottom relative to every other node. Asserted
    /// directly rather than through the PNG: `CALayer.render(in:)` skips the
    /// compositor's geometry flips and cannot see this.
    func testTheChipIsFlippedLikeTheCanvasItSitsIn() {
        XCTAssertTrue(DeskCanvasChipView(role: .account).isFlipped)
        XCTAssertTrue(DeskCanvasChipView(role: .workspace).isFlipped)
    }

    /// Selection is a stroke change, not a layout change — the arrows walk the
    /// selection and a relayout per keypress is not free.
    ///
    /// Only the layout half is asserted here, and deliberately: `needsDisplay`'s
    /// *getter* answers `false` on a layer-backed view no matter what
    /// `setNeedsDisplay(_:)` was told (measured — the backing layer's own
    /// `needsDisplay()` is the flag that moves, and offscreen it is already
    /// `true` and never clears, so neither one can witness a redraw). The redraw
    /// half is asserted where it can actually be seen, by
    /// `testSelectingTheWorkspaceChipDrawsTheAccentRingRatherThanTheCardStroke`,
    /// which renders both states and compares the pixels.
    func testSelectingAChipDoesNotLayItOutAgain() {
        let chip = DeskCanvasChipView(role: .workspace)
        chip.frame = CGRect(x: 0, y: 0, width: 300, height: 120)
        let window = show(chip)
        defer { window.close() }
        XCTAssertFalse(chip.needsLayout, "a laid-out chip starts clean")

        chip.isSelected = true

        XCTAssertFalse(chip.needsLayout, "and nothing moves")
    }

    /// Not an accessibility element: the canvas is a picture of state, and every
    /// node it draws is already reachable through the sidebar tree, which is the
    /// surface assistive clients navigate.
    func testAChipIsNotAnAccessibilityElement() {
        XCTAssertFalse(DeskCanvasChipView(role: .workspace).isAccessibilityElement())
    }


    // MARK: - Offscreen render (repo convention: verify AppKit layout by
    // rendering the real view to a PNG from a test — screen capture is
    // unavailable in background sessions). Pass the output directory via
    // `TEST_RUNNER_PANE_RENDER_DIR=/tmp/desk-chips ./macos/build.sh test`;
    // xcodebuild strips the `TEST_RUNNER_` prefix before handing the variable to
    // the test host, and unset it is a no-op.
    //
    // KNOWN BLIND SPOT: `CALayer.render(in:)` does not apply the compositor's
    // geometry flips. It cannot catch an orientation mistake — the pane
    // `maskedCorners` bug "looked perfectly concentric offscreen while the real
    // screen showed the ring pinching out at the bottom corners". The chip's
    // flipped-ness is asserted directly by
    // `testTheChipIsFlippedLikeTheCanvasItSitsIn` for exactly that reason; this
    // render proves it drew something, not which way up.

    func testTheWorkspaceChipDrawsItsTileAndItsNameRatherThanAFlatSheet() throws {
        let chip = DeskCanvasChipView(role: .workspace)
        chip.frame = CGRect(x: 0, y: 0, width: 300, height: 120)
        chip.apply(
            title: "OmniAgent ADE",
            detail: ShellPalette.sessionCountLabel(3),
            tint: ShellPalette.avatarGradient(forID: "omniagent-ade"),
            status: nil
        )
        let window = show(chip)
        defer { window.close() }

        let rep = try XCTUnwrap(render(chip), "the harness sizes the bitmap from bounds; nil means a zero-size chip")
        saveRenderForInspection(rep, named: "desk-canvas-chip-workspace")

        XCTAssertEqual(rep.pixelsWide, 300, "the harness allocates Int(bounds.width) pixels")
        XCTAssertEqual(rep.pixelsHigh, 120)
        XCTAssertGreaterThan(distinctColours(in: rep), 5, "render is a flat sheet — the chip drew nothing")
    }

    /// The account node is the same class with the round avatar, and it is the
    /// only other `Role` — a role that draws nothing would sail past every
    /// assertion above, all of which use `.workspace`.
    func testTheAccountChipDrawsItsAvatarRatherThanAFlatSheet() throws {
        let chip = DeskCanvasChipView(role: .account)
        chip.frame = CGRect(x: 0, y: 0, width: 300, height: 120)
        chip.apply(
            title: "Bruno Bonando",
            detail: nil,
            tint: ShellPalette.avatarGradient(forID: "bruno"),
            status: nil
        )
        let window = show(chip)
        defer { window.close() }

        let rep = try XCTUnwrap(render(chip))
        saveRenderForInspection(rep, named: "desk-canvas-chip-account")

        XCTAssertGreaterThan(distinctColours(in: rep), 5, "render is a flat sheet — the account chip drew nothing")
    }

    /// The other half of "selection is a stroke change": the selected chip is
    /// ringed in the accent, the unselected one in the neutral card stroke.
    ///
    /// The redraw is forced with `display()` rather than left to
    /// `displayIfNeeded()`, which was measured to redraw an offscreen
    /// layer-backed view whether or not it was invalidated — so a
    /// `displayIfNeeded` here would pass with the `isSelected` invalidation
    /// deleted, and claim to prove something it does not. What this asserts is
    /// the drawing: selected and unselected are different pictures.
    func testSelectingTheWorkspaceChipDrawsTheAccentRingRatherThanTheCardStroke() throws {
        let chip = DeskCanvasChipView(role: .workspace)
        chip.frame = CGRect(x: 0, y: 0, width: 300, height: 120)
        chip.apply(
            title: "OmniAgent ADE",
            detail: ShellPalette.sessionCountLabel(3),
            tint: ShellPalette.avatarGradient(forID: "omniagent-ade"),
            status: nil
        )
        let window = show(chip)
        defer { window.close() }
        let plain = try XCTUnwrap(render(chip))

        chip.isSelected = true
        chip.display()
        let ringed = try XCTUnwrap(render(chip))
        saveRenderForInspection(ringed, named: "desk-canvas-chip-workspace-selected")

        XCTAssertGreaterThan(
            blueOverRedAlongTheTopEdge(of: ringed),
            blueOverRedAlongTheTopEdge(of: plain) + 0.05,
            "the selection ring is drawn in the accent, and the unselected one is not"
        )
    }


    /// The failure the offscreen render found and no assertion had: a chip is
    /// `DeskCanvas.chipSize(forCard:)` — the card at 0.25 — so it carries the
    /// Desk viewport's aspect, around 1.6:1. Sizing the type from the height
    /// alone put a 54pt title in a 135pt column and drew every workspace as
    /// "Om…". The type is scaled by a unit capped at a fraction of the width
    /// instead, and this is what holds it there.
    func testAWorkspaceNameFitsTheColumnTheLayoutActuallyGivesIt() {
        for card in [CGSize(width: 1440, height: 900), CGSize(width: 1200, height: 800), CGSize(width: 1600, height: 1000)] {
            let bounds = NSRect(origin: .zero, size: DeskCanvas.chipSize(forCard: card))
            let metrics = DeskCanvasChipView.metrics(in: bounds, hasDetail: true)

            let title = ("OmniAgent ADE" as NSString).size(withAttributes: [.font: metrics.titleFont])
            XCTAssertLessThanOrEqual(
                title.width,
                metrics.title.width,
                "a \(Int(bounds.width))x\(Int(bounds.height)) chip truncates the workspace name"
            )
            let detail = (ShellPalette.sessionCountLabel(3) as NSString)
                .size(withAttributes: [.font: metrics.detailFont])
            XCTAssertLessThanOrEqual(detail.width, metrics.detail.width, "and its session count")
            XCTAssertLessThanOrEqual(metrics.detail.maxX, bounds.maxX, "the text column stays inside the chip")
            XCTAssertGreaterThanOrEqual(metrics.title.minY, bounds.minY, "and the block stays inside it vertically")
            XCTAssertLessThanOrEqual(metrics.detail.maxY, bounds.maxY)
        }
    }


    // MARK: - Installed on the canvas

    /// The chips and the edge layer are only worth building if something puts
    /// them on the canvas. This is that assertion: after a canvas layout pass
    /// there is exactly one chip per non-session node, each at its node's frame,
    /// and the edge layer has been handed a path.
    func testACanvasLayoutPassInstallsAChipPerNonSessionNodeAndOneEdgePath() throws {
        let workspace = makeCanvasWorkspace(sessions: 3)
        workspace.layoutSubtreeIfNeeded()

        let layout = try XCTUnwrap(workspace.canvasLayout)
        let root = workspace.derivedCanvasRoot()
        var expected: [String] = []
        func walk(_ node: DeskNode) {
            if case .session = node.kind {} else { expected.append(node.id) }
            node.children.forEach(walk)
        }
        walk(root)

        XCTAssertEqual(
            Set(workspace.canvasChipIDsForTesting),
            Set(expected),
            "one chip per root/workspace node, and none for a session — a session's card is its own grid"
        )
        for id in expected {
            let chip = try XCTUnwrap(workspace.canvasChipForTesting(id))
            XCTAssertEqual(chip.frame, layout.frames[id], "\(id)'s chip sits at its node frame")
            XCTAssertFalse(chip.isHidden)
            XCTAssertTrue(
                chip.superview === workspace,
                "and in the workspace's own view tree, or the camera's sublayerTransform does not carry it"
            )
        }
        XCTAssertFalse(layout.edges.isEmpty, "a three-session tree has edges")
        XCTAssertNotNil(workspace.canvasEdgePathForTesting, "the edge layer was never given a path")
    }

    /// Normal mode lays one session out in `bounds` and knows nothing about the
    /// organigram, so a chip left behind would hang over the panes at a canvas
    /// frame no pass recomputes — and `landSession` turns canvas mode off on
    /// every single entry into a session.
    func testLeavingCanvasModeTakesTheChipsAndTheConnectorsWithIt() throws {
        let workspace = makeCanvasWorkspace(sessions: 3)
        let chip = try XCTUnwrap(workspace.canvasChipForTesting("root"), "the fixture's premise")
        XCTAssertTrue(
            workspace.layer?.sublayers?.contains { $0 is DeskCanvasEdgeLayer } ?? false,
            "and the connectors are installed too"
        )

        workspace.canvasMode = false

        XCTAssertTrue(workspace.canvasChipIDsForTesting.isEmpty)
        XCTAssertNil(chip.superview, "out of the view tree, not merely forgotten")
        XCTAssertFalse(workspace.subviews.contains { $0 is DeskCanvasChipView })
        XCTAssertFalse(workspace.layer?.sublayers?.contains { $0 is DeskCanvasEdgeLayer } ?? false)
    }

    /// `lineWidth` is in canvas units, so a hairline at fit-all would vanish and
    /// a hairline at identity would be a slab. The edge layer compensates, and
    /// nothing else can do it for it — note the camera runs no layout pass, so
    /// the assignment below is the whole hook.
    func testTheEdgeLineWidthIsCompensatedForTheCamera() throws {
        let workspace = makeCanvasWorkspace(sessions: 3)
        workspace.layoutSubtreeIfNeeded()
        let content = try XCTUnwrap(workspace.canvasLayout?.contentRect)

        workspace.camera = DeskCamera.fitAll(content: content, in: workspace.bounds)
        let wide = workspace.canvasEdgeLineWidthForTesting

        workspace.camera = DeskCamera(scale: 1, origin: .zero)
        let narrow = workspace.canvasEdgeLineWidthForTesting

        XCTAssertEqual(narrow, DeskCanvasEdgeLayer.strokeWidth, accuracy: 0.001, "one point on screen at identity")
        XCTAssertGreaterThan(wide, narrow, "zoomed out, the stroke must be fatter in canvas units to stay visible")
    }

    /// The arrows walk `selectedNodeID` and a keypress runs no layout pass, so
    /// without a hook of its own the ring would only appear the next time
    /// something else happened to re-lay the canvas out — which on a still
    /// canvas is never.
    func testWalkingTheSelectionMovesTheRingWithoutALayoutPass() throws {
        let workspace = makeCanvasWorkspace(sessions: 3)
        let root = try XCTUnwrap(workspace.canvasChipForTesting("root"))
        XCTAssertFalse(root.isSelected, "nothing is selected to begin with")
        // Drained first: installing the chips marked the canvas for layout, and
        // with no window nothing ever comes along to clear that — the flag is
        // only evidence once it starts out down.
        workspace.layoutSubtreeIfNeeded()
        XCTAssertFalse(workspace.needsLayout, "the fixture's premise")

        workspace.selectedNodeID = "root"
        XCTAssertTrue(root.isSelected)
        XCTAssertFalse(workspace.needsLayout, "and nothing was re-laid-out to do it")

        workspace.selectedNodeID = nil
        XCTAssertFalse(root.isSelected, "and it comes off again")
    }

    // MARK: - The assembled canvas

    /// Spec §6: an offscreen render at fit-all and at identity. Run with
    /// `TEST_RUNNER_PANE_RENDER_DIR=/tmp/desk-canvas ./macos/build.sh test` to
    /// keep the PNGs and look at them.
    ///
    /// Known blind spot, and why the assertions below are about content rather
    /// than geometry: `CALayer.render(in:)` skips the compositor's geometry
    /// flips, so this harness cannot see an upside-down `maskedCorners` — the
    /// trap `roundChildren(inside:)`'s own comment records.
    func testTheAssembledCanvasRendersAtFitAllAndAtIdentity() throws {
        let workspace = makeCanvasWorkspace(sessions: 3)
        let window = show(workspace)
        defer { window.close() }
        workspace.layoutSubtreeIfNeeded()
        let content = try XCTUnwrap(workspace.canvasLayout?.contentRect)

        workspace.camera = DeskCamera.fitAll(content: content, in: workspace.bounds)
        workspace.layoutSubtreeIfNeeded()
        let wide = try XCTUnwrap(render(workspace))
        saveRenderForInspection(wide, named: "desk-canvas-fit-all")
        XCTAssertGreaterThan(
            distinctColours(in: wide),
            5,
            "fit-all is a flat sheet — the tree drew nothing"
        )

        let group = try XCTUnwrap(workspace.groupIDs.first)
        workspace.enterSession(group)
        // The flight is 0.38s and its landing is scheduled, not delegated — the
        // render is meant to be of a session the camera has arrived in, and a
        // completion left pending here would fire into a closed window during
        // some later, unrelated test.
        RunLoop.current.run(
            until: Date().addingTimeInterval(PaneWorkspaceView.zoomTransitionDuration + 0.2)
        )
        workspace.layoutSubtreeIfNeeded()
        let close = try XCTUnwrap(render(workspace))
        saveRenderForInspection(close, named: "desk-canvas-identity")
        XCTAssertTrue(workspace.camera.isIdentity, "the render must be of a landed camera, not a mid-flight one")
        XCTAssertEqual(workspace.activeGroup, group, "and of the session that was entered")
        XCTAssertGreaterThan(
            distinctColours(in: close, samples: 120),
            5,
            "identity is a flat sheet — the session's own chrome drew nothing"
        )
    }

    // MARK: - Helpers
    /// One session per group, one pane each, sized like the real Desk. Mirrors
    /// `DeskCanvasInputTests.makeCanvasWorkspace(sessions:)`, whose helpers are
    /// private to that class. Terminals only: the organigram is kind-neutral and
    /// a WKWebView pane costs the test host a renderer process for nothing. The
    /// socket is one nobody is listening on — the Debug `test` path deliberately
    /// never builds the Rust daemon.
    private func makeCanvasWorkspace(sessions: Int) -> PaneWorkspaceView {
        let connection = SessionConnection(
            socketURL: URL(fileURLWithPath: "/tmp/omniagent-desk-canvas-chrome-test.sock")
        )
        let workspace = PaneWorkspaceView { descriptor in
            TerminalSurfaceView(connection: connection, sessionID: descriptor.sessionID)
        }
        workspace.frame = CGRect(x: 0, y: 0, width: 1200, height: 800)
        for index in 1...sessions {
            XCTAssertTrue(workspace.addPane(PaneDescriptor(
                sessionID: "pane-\(index)",
                group: "sess-grp-\(index)",
                groupLabel: nil,
                title: ""
            )))
        }
        workspace.canvasMode = true
        return workspace
    }


    /// A window, because a layer-backed view with no window never runs
    /// `draw(_:)` and the render comes back empty — the test would then pass for
    /// the wrong reason.
    private func show(_ view: NSView) -> NSWindow {
        let window = NSWindow(
            contentRect: view.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        // See `PaneWorkspaceViewTests.makeAttachedWorkspace`: an `NSWindow` that
        // releases itself on close, while ARC still holds it, frees the window
        // early and SIGSEGVs a later, unrelated test on an autorelease drain
        // inside a CA commit.
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.displayIfNeeded()
        view.layoutSubtreeIfNeeded()
        return window
    }

    /// How blue the chip's top border reads: the accent stroke is
    /// srgb(139, 149, 255) and the neutral one is white at 9%, so blue-minus-red
    /// separates them without depending on where exactly the stroke lands.
    private func blueOverRedAlongTheTopEdge(of rep: NSBitmapImageRep) -> CGFloat {
        var best: CGFloat = 0
        for y in 2..<min(8, rep.pixelsHigh) {
            for x in stride(from: 20, to: max(21, rep.pixelsWide - 20), by: 4) {
                guard let colour = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                best = max(best, (colour.blueComponent - colour.redComponent) * colour.alphaComponent)
            }
        }
        return best
    }

    /// `samples` is the grid this walks, per axis. The 20 the chip renders use
    /// is plenty for a 300x120 chip that is nearly all content; a 1200x800
    /// render of one session is ~95% flat terminal, and a 20x20 grid lands
    /// almost entirely inside it — the drawing that proves anything happened is
    /// a 26pt header strip a coarse sample steps straight over.
    private func distinctColours(in rep: NSBitmapImageRep, samples: Int = 20) -> Int {
        var seen = Set<String>()
        for x in stride(from: 2, to: rep.pixelsWide - 2, by: max(1, rep.pixelsWide / samples)) {
            for y in stride(from: 2, to: rep.pixelsHigh - 2, by: max(1, rep.pixelsHigh / samples)) {
                guard let colour = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                seen.insert([
                    Int(colour.redComponent * 255),
                    Int(colour.greenComponent * 255),
                    Int(colour.blueComponent * 255),
                ].map(String.init).joined(separator: "-"))
            }
        }
        return seen.count
    }

    /// Renders a view's whole layer tree, gradients included — `cacheDisplay`
    /// draws `draw(_:)` output only, which is nothing here.
    private func render(_ view: NSView) -> NSBitmapImageRep? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(view.bounds.width),
            pixelsHigh: Int(view.bounds.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .calibratedRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        view.layer?.render(in: context.cgContext)
        return rep
    }

    /// Nothing reads this in CI; it exists so Bruno can eyeball a render.
    /// `xcodebuild test`'s `TEST_RUNNER_` prefix is stripped and the rest handed
    /// straight to the test host's environment, so
    /// `TEST_RUNNER_PANE_RENDER_DIR=/tmp/panes ./macos/build.sh test` drops a PNG
    /// per named render there; unset, this is a no-op.
    private func saveRenderForInspection(_ rep: NSBitmapImageRep, named name: String) {
        guard
            let dir = ProcessInfo.processInfo.environment["PANE_RENDER_DIR"],
            let png = rep.representation(using: .png, properties: [:])
        else { return }
        let directory = URL(fileURLWithPath: dir, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? png.write(to: directory.appendingPathComponent("\(name).png"))
    }
}
