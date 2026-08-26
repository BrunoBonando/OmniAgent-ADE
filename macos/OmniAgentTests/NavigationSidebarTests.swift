import AppKit
import XCTest

@testable import OmniAgent

/// The flat Copilot-style sidebar from the 2026-08-20 navigation redesign:
/// the fixed nav rows, the Search seam, the Workspaces section, the pinned
/// account row — and the content routing the rows drive on the controller.
final class NavigationSidebarTests: XCTestCase {
    private func makeSidebar() -> NavigationSidebarView {
        let sidebar = NavigationSidebarView()
        sidebar.frame = NSRect(x: 0, y: 0, width: ShellMetrics.sidebarWidth, height: 700)
        sidebar.layoutSubtreeIfNeeded()
        return sidebar
    }

    // MARK: - Fixed nav rows

    /// The spec's order, top to bottom: Home, To Do List, Search.
    func testNavRowsArePresentInTheSpecOrder() {
        let sidebar = makeSidebar()
        XCTAssertEqual(sidebar.navRows.map(\.item), [.home, .todo, .search])
        XCTAssertEqual(
            sidebar.navRows.map(\.item.title),
            ["Home", "To Do List", "Search"]
        )
        XCTAssertEqual(
            sidebar.navRows.map(\.item.symbol),
            ["house", "checklist", "magnifyingglass"]
        )
    }

    func testHomeAndToDoListRouteAsDestinations() throws {
        let sidebar = makeSidebar()
        var reported: [WorkspaceDestination] = []
        sidebar.onSelectDestination = { reported.append($0) }

        try XCTUnwrap(sidebar.navRows.first { $0.item == .home }?.onPress)()
        XCTAssertEqual(reported, [.home])
        XCTAssertEqual(sidebar.destination, .home)
        XCTAssertEqual(sidebar.navRows.filter(\.isSelected).map(\.item), [.home])

        try XCTUnwrap(sidebar.navRows.first { $0.item == .todo }?.onPress)()
        XCTAssertEqual(reported, [.home, .todo])
        XCTAssertEqual(sidebar.navRows.filter(\.isSelected).map(\.item), [.todo])
    }

    /// Search is an action, not a place: it raises the spotlight and the lit
    /// row stays exactly where it was.
    func testSearchFiresTheSpotlightSeamAndDoesNotSelect() throws {
        let sidebar = makeSidebar()
        var searches = 0
        var routed = 0
        sidebar.onSearch = { searches += 1 }
        sidebar.onSelectDestination = { _ in routed += 1 }
        sidebar.applyDestination(.home)

        try XCTUnwrap(sidebar.navRows.first { $0.item == .search }?.onPress)()

        XCTAssertEqual(searches, 1)
        XCTAssertEqual(routed, 0, "Search never routes")
        XCTAssertEqual(sidebar.destination, .home, "and never moves the selection")
        XCTAssertEqual(sidebar.navRows.filter(\.isSelected).map(\.item), [.home])
    }

    /// The Desk has no sidebar row any more — on `.terminals` nothing is lit.
    func testTheDeskLightsNoNavRow() {
        let sidebar = makeSidebar()
        sidebar.applyDestination(.home)
        sidebar.applyDestination(.terminals)
        XCTAssertTrue(sidebar.navRows.filter(\.isSelected).isEmpty)
    }

    // MARK: - Workspaces section

    /// The workspaces tree stays mounted, under a "Workspaces" section header
    /// that sits between the nav rows and the tree.
    func testTheWorkspacesHeaderSitsBetweenTheNavRowsAndTheTree() throws {
        let sidebar = makeSidebar()
        XCTAssertEqual(sidebar.workspacesHeader.title, "Workspaces")
        XCTAssertNotNil(sidebar.workspacesTree.superview, "the tree is mounted")

        func top(_ view: NSView) -> CGFloat { view.convert(view.bounds, to: sidebar).maxY }
        let lastNav = try XCTUnwrap(sidebar.navRows.last)
        // Not flipped: larger y is higher on screen.
        XCTAssertLessThan(top(sidebar.workspacesHeader), top(lastNav))
        XCTAssertLessThanOrEqual(top(sidebar.workspacesTree), top(sidebar.workspacesHeader))
    }

    // MARK: - Account row

    /// Pinned to the floor, but inset from it: the chip is a card that has to
    /// clear the window's corner curve, not a strip flush with the edges.
    func testTheAccountRowIsPinnedAtTheBottom() {
        let sidebar = makeSidebar()
        XCTAssertTrue(sidebar.accountRow.superview === sidebar)
        XCTAssertEqual(sidebar.accountRow.frame.minY, 10, accuracy: 0.5, "inset off the bottom edge")
        XCTAssertEqual(
            sidebar.accountRow.frame.width, sidebar.bounds.width - 16, accuracy: 0.5,
            "inset from both side edges"
        )
        // Every row above it — but not the two full-height pieces that are not
        // rows at all: the glass ground runs the whole column *under* the chip,
        // and the trailing edge runs it *beside* the chip.
        let rows = sidebar.subviews.filter {
            $0 !== sidebar.accountRow && $0 !== sidebar.glassHost && $0 !== sidebar.trailingEdge
        }
        for sibling in rows {
            XCTAssertGreaterThanOrEqual(
                sibling.frame.minY,
                sidebar.accountRow.frame.maxY - 0.5,
                "\(type(of: sibling)) overlaps the pinned account row"
            )
        }
    }

    /// A placeholder until real accounts exist: a generic avatar and
    /// "Not signed in" — never the machine user's name.
    func testTheAccountRowIsAPlaceholder() {
        XCTAssertEqual(makeSidebar().accountRow.accountLabel, "Not signed in")
    }

    func testTheGearOpensSettings() throws {
        let sidebar = makeSidebar()
        var opened = 0
        sidebar.onOpenSettings = { opened += 1 }
        try XCTUnwrap(sidebar.accountRow.gear.onPress)()
        XCTAssertEqual(opened, 1)
    }

    // MARK: - System stats

    /// The machine card sits directly above the account chip, on the same
    /// side insets.
    func testTheStatsCardSitsAboveTheAccountRow() {
        let sidebar = makeSidebar()
        XCTAssertTrue(sidebar.statsRow.superview === sidebar)
        XCTAssertEqual(
            sidebar.statsRow.frame.minY,
            sidebar.accountRow.frame.maxY + 8,
            accuracy: 0.5
        )
        XCTAssertEqual(sidebar.statsRow.frame.width, sidebar.bounds.width - 16, accuracy: 0.5)
    }

    /// Fractions render as whole percentages and clamp to 0...1; a metric
    /// with no reading says so instead of inventing a number.
    func testTheGaugesRenderPercentagesAndClamp() {
        let stats = SidebarSystemStatsView()
        stats.apply(cpu: 0.37, memory: 1.7, gpu: nil)
        XCTAssertEqual(stats.cpuGauge.readout, "37%")
        XCTAssertEqual(stats.memoryGauge.readout, "100%")
        XCTAssertEqual(stats.gpuGauge.readout, "—")
    }

    /// The number's colour is the pressure analysis: green while comfortable,
    /// amber past 70%, red past 90% — and no verdict at all without a reading.
    func testTheGaugesWearThePressureColour() {
        let stats = SidebarSystemStatsView()
        stats.apply(cpu: 0.3, memory: 0.75, gpu: 0.95)
        XCTAssertEqual(stats.cpuGauge.readoutColor, ShellPalette.green)
        XCTAssertEqual(stats.memoryGauge.readoutColor, ShellPalette.amber)
        XCTAssertEqual(stats.gpuGauge.readoutColor, ShellPalette.red)

        stats.apply(cpu: 0.3, memory: 0.75, gpu: nil)
        XCTAssertEqual(stats.gpuGauge.readoutColor, ShellPalette.inkTertiary)
    }

    /// The kernel answers on this machine: memory is always readable and in
    /// range. CPU legitimately needs two samples for a delta and the tick
    /// counters may not advance between them, so it only must not crash.
    func testMachineStatsAnswerFromTheKernel() {
        _ = MachineStats.cpuFraction()
        _ = MachineStats.cpuFraction()
        let memory = MachineStats.memoryFraction()
        XCTAssertNotNil(memory)
        XCTAssertGreaterThan(memory ?? 0, 0)
        XCTAssertLessThanOrEqual(memory ?? 0, 1)
    }

    // MARK: - Content routing (controller)

    /// Home shows its real screen, To Do List still lands on the "Under
    /// development" placeholder, and the pane workspace hides and comes back
    /// with the Desk.
    func testHomeShowsItsScreenAndToDoThePlaceholder() throws {
        let controller = makeController()
        defer { controller.close() }
        controller.showWindow(nil)

        controller.applyDestination(.home)
        XCTAssertTrue(controller.workspaceView.isHidden)
        XCTAssertFalse(controller.homeView.isHiddenOrHasHiddenAncestor)
        XCTAssertTrue(try XCTUnwrap(placeholderView(in: controller)).isHidden)

        controller.applyDestination(.todo)
        XCTAssertTrue(controller.workspaceView.isHidden)
        XCTAssertTrue(controller.homeView.isHidden)
        let placeholder = try XCTUnwrap(placeholderView(in: controller))
        XCTAssertFalse(placeholder.isHiddenOrHasHiddenAncestor)
        XCTAssertEqual(placeholder.titleText, WorkspaceDestination.todo.title)
        XCTAssertEqual(placeholder.subtitleText, "Under development")

        controller.applyDestination(.terminals)
        XCTAssertFalse(controller.workspaceView.isHidden)
        XCTAssertTrue(controller.homeView.isHidden)
        XCTAssertTrue(try XCTUnwrap(placeholderView(in: controller)).isHidden)
    }

    /// The sidebar's rows drive the same routing the palette does.
    func testTheSidebarRowsRouteToTheController() throws {
        let controller = makeController()
        defer { controller.close() }
        controller.showWindow(nil)

        try XCTUnwrap(controller.shellSidebar.navRows.first { $0.item == .home }?.onPress)()
        XCTAssertEqual(controller.destination, .home)

        try XCTUnwrap(controller.shellSidebar.navRows.first { $0.item == .todo }?.onPress)()
        XCTAssertEqual(controller.destination, .todo)
    }

    /// The Search row raises the spotlight — the same panel ⌃Space and ⌘K
    /// raise — without touching the destination.
    func testTheSearchRowRaisesTheSpotlightWithoutChangingTheDestination() throws {
        let controller = makeController()
        defer { controller.close() }
        controller.showWindow(nil)
        XCTAssertEqual(controller.destination, .home)
        XCTAssertTrue(controller.palette.model.commands.isEmpty, "nothing presented yet")

        try XCTUnwrap(controller.shellSidebar.navRows.first { $0.item == .search }?.onPress)()

        XCTAssertFalse(controller.palette.model.commands.isEmpty, "the spotlight was presented")
        XCTAssertEqual(controller.destination, .home, "and Search selected nothing")
        XCTAssertTrue(controller.workspaceView.isHidden)
        controller.palette.dismiss()
    }

    // MARK: - The column's ground

    /// The column is Liquid Glass where there is glass to ask for: one
    /// full-bleed sheet at the very back of the view, with the design's blue
    /// washed over it rather than under it. Below macOS 26 there is no sheet
    /// and `draw` paints the opaque gradient exactly as it always did.
    func testTheColumnIsAGlassGroundCarryingTheBlueWash() throws {
        let sidebar = makeSidebar()

        guard #available(macOS 26.0, *) else {
            XCTAssertNil(
                sidebar.glassHost,
                "below 26 there is no glass to ask for and `draw` is the ground"
            )
            return
        }

        let glass = try XCTUnwrap(sidebar.glassHost, "macOS 26 has glass to ask for")
        XCTAssertIdentical(
            sidebar.subviews.first, glass, "the sheet is the ground, behind every row"
        )
        XCTAssertEqual(glass.frame, sidebar.bounds, "full-bleed: no inset, no floating slab")

        let wash = try XCTUnwrap(sidebar.glassTint)
        XCTAssertEqual(wash.frame.size, glass.frame.size, "the wash covers the whole sheet")
        let stops = try XCTUnwrap(wash.layer as? CAGradientLayer)
        let colors = try XCTUnwrap(stops.colors as? [CGColor])
            .compactMap { NSColor(cgColor: $0)?.usingColorSpace(.sRGB) }
        XCTAssertEqual(colors.count, 2)
        let top = try XCTUnwrap(colors.first)
        let bottom = try XCTUnwrap(colors.last)
        // Translucent, or the wash is paint over the glass and hides the
        // material it is supposed to tint.
        XCTAssertLessThan(top.alphaComponent, 1)
        XCTAssertGreaterThan(top.alphaComponent, 0)
        XCTAssertLessThan(bottom.alphaComponent, top.alphaComponent, "top-lit, as it always was")
        // Still the column's blue, both ends.
        XCTAssertGreaterThan(top.blueComponent, top.redComponent)
        XCTAssertGreaterThan(bottom.blueComponent, bottom.redComponent)
        // Top to bottom: (0.5, 1) is the top in the layer's y-up unit space,
        // the direction `NSGradient`'s -90° angle gave the opaque gradient.
        XCTAssertEqual(stops.startPoint.y, 1)
        XCTAssertEqual(stops.endPoint.y, 0)
    }

    /// The column's trailing edge carries its own grey hairline. The sheet
    /// draws a rim there, but it measured `64, 65, 71` at its brightest
    /// against the pane black beside it — present, and not enough to say where
    /// the column stops. This line is, and it is grey on purpose: the column's
    /// own blue would read as part of the column rather than as its border.
    ///
    /// Drawn whatever the OS: below macOS 26 there is no sheet and so no rim
    /// at all, which is the case that needs it most.
    func testTheColumnsTrailingEdgeCarriesAGreySeparator() throws {
        let sidebar = makeSidebar()
        let edge = sidebar.trailingEdge

        XCTAssertEqual(edge.frame.width, 1, accuracy: 0.01, "a hairline, not a bar")
        XCTAssertEqual(
            edge.frame.maxX, sidebar.bounds.maxX, accuracy: 0.5, "pinned to the trailing edge"
        )
        XCTAssertEqual(
            edge.frame.height, sidebar.bounds.height, accuracy: 0.5,
            "the whole height, chrome included — the column runs under it"
        )
        XCTAssertIdentical(
            sidebar.subviews.last, edge, "over the glass and every row, never under them"
        )

        let cg = try XCTUnwrap(edge.layer?.backgroundColor)
        let color = try XCTUnwrap(NSColor(cgColor: cg)?.usingColorSpace(.sRGB))
        XCTAssertEqual(
            color.redComponent, color.blueComponent, accuracy: 0.02,
            "grey — the column's blue would read as column, not as border"
        )
        XCTAssertEqual(color.redComponent, color.greenComponent, accuracy: 0.02)
        XCTAssertGreaterThan(
            color.redComponent, 0.25, "and light enough to read against both sides"
        )
    }

    /// The sheet went behind the rows, not over them: a press still lands on
    /// the row under the cursor. A full-bleed view added on top would eat
    /// every click in the column.
    func testTheGlassGroundDoesNotSwallowTheRowsUnderIt() throws {
        let sidebar = makeSidebar()
        let row = try XCTUnwrap(sidebar.navRows.first)
        let centre = row.convert(NSPoint(x: row.bounds.midX, y: row.bounds.midY), to: sidebar)

        // `hitTest` reads its point in the superview's space; this sidebar has
        // no superview and sits at the origin, so the column's own coordinates
        // are that space.
        let hit = try XCTUnwrap(sidebar.hitTest(centre))
        XCTAssertTrue(
            hit === row || hit.isDescendant(of: row),
            "the Home row should take its own click, not \(type(of: hit))"
        )
    }

    // MARK: - Offscreen render

    /// The whole flat column, rendered offscreen: the three nav rows, the
    /// Workspaces header, both workspace rows with their session rows and the
    /// dim empty row, and the pinned account row each put ink down where their
    /// frame says they are — a block whose region reads as flat panel
    /// background laid out but never drew. Drops a PNG when `PANE_RENDER_DIR`
    /// is set (`TEST_RUNNER_PANE_RENDER_DIR` through `build.sh`).
    func testTheFlatSidebarRendersItsWholeStructure() throws {
        // A fold or group mode left behind by an earlier run would change the
        // shape this render asserts on.
        UserDefaults.standard.removeObject(forKey: WorkspacesTreeView.collapsedDefaultsKey)
        UserDefaults.standard.removeObject(forKey: WorkspacesTreeView.groupModeDefaultsKey)

        let sidebar = NavigationSidebarView()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: ShellMetrics.sidebarWidth, height: 700),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = sidebar

        sidebar.reloadWorkspaces(
            workspaces: [
                BrainProjectSummary(id: "p1", label: "Alpha", path: nil),
                BrainProjectSummary(id: "p2", label: "Beta", path: nil),
            ],
            panes: [
                pane("t1", group: "s1", project: "p1"),
                pane("t2", group: "s2", project: "p1"),
            ],
            focusedPaneID: "t1",
            statuses: ["t1": .ready, "t2": .thinking],
            projectLabels: [:]
        )

        // Which end of the bitmap is up is not readable off the code — the
        // layer render's unit space is y-up while the bitmap's row 0 is its
        // top — so a green marker anchors the mapping, the pane-wash render
        // test's pattern. Top-left corner: the nav stack's top inset keeps
        // that spot empty, where the view's y = 0 is the account row's.
        let marker = NSView(
            frame: NSRect(x: 0, y: sidebar.bounds.height - 6, width: 10, height: 6)
        )
        marker.wantsLayer = true
        marker.layer?.backgroundColor = NSColor.green.cgColor
        sidebar.addSubview(marker)

        window.makeKeyAndOrderFront(nil)
        sidebar.layoutSubtreeIfNeeded()
        window.displayIfNeeded()

        let image = try XCTUnwrap(render(sidebar))
        saveRenderForInspection(image, named: "flat-sidebar")

        func pixel(_ x: Int, _ y: Int) -> NSColor {
            image.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) ?? .black
        }
        let anchor = try XCTUnwrap(
            (0..<image.pixelsHigh).first {
                pixel(3, $0).greenComponent > 0.8 && pixel(3, $0).redComponent < 0.4
            },
            "the marker has to show up, or the render proves nothing"
        )
        // The marker sits at the view's top: found near bitmap row 0, the
        // bitmap reads top-down; found near the end, it reads bottom-up.
        let topDown = anchor < image.pixelsHigh / 2
        func bitmapRow(forViewY viewY: Int) -> Int {
            topDown ? image.pixelsHigh - 1 - viewY : viewY
        }

        /// The widest channel spread across the block's pixels — a block
        /// that drew nothing is flat panel background, spread ≈ 0.
        func spread(_ view: NSView) -> CGFloat {
            let rect = view.convert(view.bounds, to: sidebar).intersection(sidebar.bounds)
            guard !rect.isEmpty else {
                XCTFail("\(type(of: view)) has no on-screen frame")
                return 0
            }
            var lows: [CGFloat] = [1, 1, 1]
            var highs: [CGFloat] = [0, 0, 0]
            for x in Int(rect.minX)..<Int(rect.maxX) {
                for viewY in Int(rect.minY)..<Int(rect.maxY) {
                    let color = pixel(x, bitmapRow(forViewY: viewY))
                    let channels = [color.redComponent, color.greenComponent, color.blueComponent]
                    for (index, value) in channels.enumerated() {
                        lows[index] = min(lows[index], value)
                        highs[index] = max(highs[index], value)
                    }
                }
            }
            return zip(lows, highs).map { $1 - $0 }.max() ?? 0
        }

        for row in sidebar.navRows {
            // The selected row (Home, by default now that the app lands
            // there) wears `accentSoft` under `ink` text — a softer,
            // lower-contrast combination than an unselected row's flat
            // background under `inkNav`, so it clears a lower bar.
            let threshold: CGFloat = row.isSelected ? 0.05 : 0.1
            XCTAssertGreaterThan(spread(row), threshold, "the \(row.item.title) row rendered nothing")
        }
        XCTAssertGreaterThan(
            spread(sidebar.workspacesHeader), 0.1, "the Workspaces header rendered nothing"
        )

        let workspaceRows = descendants(WorkspaceRowView.self, under: sidebar.workspacesTree)
        XCTAssertEqual(workspaceRows.map(\.workspaceID), ["p1", "p2"])
        for row in workspaceRows {
            XCTAssertGreaterThan(spread(row), 0.1, "the \(row.titleText) row rendered nothing")
        }

        let sessionRows = descendants(SessionRowView.self, under: sidebar.workspacesTree)
        XCTAssertEqual(sessionRows.map(\.session.id), ["s1", "s2"])
        for row in sessionRows {
            XCTAssertGreaterThan(spread(row), 0.1, "the \(row.session.label) row rendered nothing")
        }

        let emptyRow = try XCTUnwrap(
            descendants(WorkspaceEmptyRowView.self, under: sidebar.workspacesTree).first,
            "Beta has no sessions — the dim placeholder stands in"
        )
        XCTAssertGreaterThan(spread(emptyRow), 0.08, "the No-sessions-yet row rendered nothing")
        XCTAssertGreaterThan(spread(sidebar.accountRow), 0.1, "the account row rendered nothing")

        // And the column is flat: one straight top-to-bottom order — nav
        // rows, header, each workspace over its own leaves, the account row
        // on the floor.
        func top(_ view: NSView) -> CGFloat { view.convert(view.bounds, to: sidebar).maxY }
        let expected: [NSView] =
            sidebar.navRows + [sidebar.workspacesHeader, workspaceRows[0]]
            + sessionRows + [workspaceRows[1], emptyRow, sidebar.accountRow]
        for (above, below) in zip(expected, expected.dropFirst()) {
            XCTAssertGreaterThan(
                top(above), top(below),
                "\(type(of: above)) should sit above \(type(of: below))"
            )
        }
        XCTAssertEqual(sidebar.accountRow.frame.minY, 10, accuracy: 0.5)
    }

    // MARK: - Helpers

    private func pane(_ id: String, group: String, project: String) -> PaneDescriptor {
        PaneDescriptor(
            sessionID: id,
            group: group,
            groupLabel: group,
            title: "term",
            project: project,
            engine: .claude,
            cwd: "/tmp"
        )
    }

    private func descendants<View: NSView>(_ type: View.Type, under view: NSView) -> [View] {
        view.subviews.flatMap { subview -> [View] in
            var found = descendants(type, under: subview)
            if let match = subview as? View { found.insert(match, at: 0) }
            return found
        }
    }

    /// Renders the view's whole layer tree — `cacheDisplay` draws `draw(_:)`
    /// output only. The pane workspace render tests' pattern.
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
    /// `TEST_RUNNER_PANE_RENDER_DIR=/tmp/panes ./macos/build.sh test` drops a
    /// PNG per named render there; unset, this is a no-op.
    private func saveRenderForInspection(_ rep: NSBitmapImageRep, named name: String) {
        guard
            let dir = ProcessInfo.processInfo.environment["PANE_RENDER_DIR"],
            let png = rep.representation(using: .png, properties: [:])
        else { return }
        let directory = URL(fileURLWithPath: dir, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? png.write(to: directory.appendingPathComponent("\(name).png"))
    }

    private func makeController() -> WorkspaceWindowController {
        WorkspaceWindowController(
            connection: SessionConnection(
                socketURL: URL(fileURLWithPath: "/tmp/omniagent-nav-sidebar-test.sock")
            ),
            panes: []
        )
    }

    private func placeholderView(in controller: WorkspaceWindowController) -> WorkspacePlaceholderView? {
        controller.window?.contentView.flatMap(firstPlaceholder(under:))
    }

    private func firstPlaceholder(under view: NSView) -> WorkspacePlaceholderView? {
        for subview in view.subviews {
            if let match = subview as? WorkspacePlaceholderView { return match }
            if let match = firstPlaceholder(under: subview) { return match }
        }
        return nil
    }
    // MARK: - The time blocks

    /// The window cut into the units it is actually made of: five hours, or
    /// seven days.
    func testEachWindowIsCutIntoItsOwnUnits() {
        let card = makeLimitsCard()
        XCTAssertEqual(card.sessionColumn.timeBar.segments, 5, "five hours")
        XCTAssertEqual(card.weekColumn.timeBar.segments, 7, "seven days")
    }

    /// `/usage` reports only when a window ends, so how far through it we are
    /// is derived from the end: whatever is not still to come has gone.
    func testHowFarThroughAWindowIsDerivedFromItsEnd() throws {
        let now = try XCTUnwrap(
            Calendar.current.date(from: DateComponents(year: 2026, month: 8, day: 26, hour: 11))
        )
        let fiveHours: TimeInterval = 5 * 3600

        // 2h 18m still to come out of five hours, so 2h 42m has gone.
        let partial = try XCTUnwrap(SidebarLimitColumnView.elapsedFraction(
            until: now.addingTimeInterval(2 * 3600 + 18 * 60), windowLength: fiveHours, now: now
        ))
        XCTAssertEqual(partial, (fiveHours - (2 * 3600 + 18 * 60)) / fiveHours, accuracy: 0.001)

        XCTAssertEqual(
            SidebarLimitColumnView.elapsedFraction(
                until: now.addingTimeInterval(-60), windowLength: fiveHours, now: now
            ), 1, "a window past its reset is spent, not negative"
        )
        // A reset further out than one whole window means the length above is
        // wrong; it must read as a fresh window rather than run off the end.
        XCTAssertEqual(
            SidebarLimitColumnView.elapsedFraction(
                until: now.addingTimeInterval(fiveHours * 3), windowLength: fiveHours, now: now
            ), 0
        )
        XCTAssertNil(SidebarLimitColumnView.elapsedFraction(
            until: nil, windowLength: fiveHours, now: now
        ))
    }

    /// The block being lived through is partly filled; the ones behind it are
    /// solid. Rounding up is what makes the current block count as started.
    func testTheBlockBeingLivedThroughCountsAsStarted() {
        let bar = SidebarSegmentedBarView(segments: 5)
        bar.apply(nil)
        XCTAssertEqual(bar.filledSegments, 0, "no reading, no blocks")
        bar.apply(0)
        XCTAssertEqual(bar.filledSegments, 0, "a fresh window is empty")
        bar.apply(0.46)
        XCTAssertEqual(bar.filledSegments, 3, "two whole hours and into the third")
        bar.apply(1)
        XCTAssertEqual(bar.filledSegments, 5)
    }

    /// Blocks fill the same direction as the usage bar above them, so the
    /// column has one rule rather than two opposite ones.
    func testTheBlocksFillAsTheWindowIsSpent() throws {
        let card = makeLimitsCard()
        let now = try XCTUnwrap(
            Calendar.current.date(from: DateComponents(year: 2026, month: 8, day: 26, hour: 11))
        )
        // Reset a whole week out: the week has only just begun.
        card.apply(
            ClaudeUsageLimits.parse("Current week (all models): 2% used · resets Sep 2 at 11am"),
            now: now
        )
        let fresh = card.weekColumn.timeBar.filledSegments

        // Reset an hour out: almost all of it has gone.
        card.apply(
            ClaudeUsageLimits.parse("Current week (all models): 90% used · resets Aug 26 at 12pm"),
            now: now
        )
        XCTAssertGreaterThan(card.weekColumn.timeBar.filledSegments, fresh, "fills, not drains")
        XCTAssertEqual(card.weekColumn.timeBar.filledSegments, 7)
    }

    /// The countdown is a hover now, and a tooltip covers only its own view —
    /// so hovering the number itself has to work, not just the gaps.
    func testHoveringAnywhereInTheColumnShowsTheTime() throws {
        let card = makeLimitsCard()
        card.apply(
            ClaudeUsageLimits.parse("Current session: 12% used · resets Aug 25 at 3:00pm"),
            now: noon
        )
        XCTAssertEqual(card.sessionColumn.toolTip, "3h 0m left")
        XCTAssertEqual(card.sessionColumn.timeBar.toolTip, "3h 0m left")
        let labels = descendants(NSTextField.self, under: card.sessionColumn)
        XCTAssertFalse(labels.isEmpty)
        for label in labels {
            XCTAssertEqual(label.toolTip, "3h 0m left", "the number is hoverable too")
        }
    }

    // MARK: - Reading order

    /// The label names the thing, then the number answers it. Reading `12%`
    /// before knowing it is the session is backwards.
    func testTheCaptionSitsAboveTheNumber() {
        let card = makeLimitsCard()
        card.apply(ClaudeUsageLimits.parse("Current session: 12% used · resets Aug 25 at 3:00pm"), now: noon)
        card.layoutSubtreeIfNeeded()
        assertCaptionAboveNumber(in: card.sessionColumn, caption: "SESSION")

        let gauges = SidebarSystemStatsView()
        gauges.frame = NSRect(x: 0, y: 0, width: 216, height: SidebarSystemStatsView.height)
        gauges.apply(cpu: 0.13, memory: nil, gpu: nil)
        gauges.layoutSubtreeIfNeeded()
        assertCaptionAboveNumber(in: gauges.cpuGauge, caption: "CPU")
    }

    /// A non-flipped view puts what is higher on screen at the larger `minY`.
    private func assertCaptionAboveNumber(
        in column: NSView, caption: String, line: UInt = #line
    ) {
        let labels = descendants(NSTextField.self, under: column)
        guard
            let captionField = labels.first(where: { $0.stringValue == caption }),
            let valueField = labels.first(where: { $0.stringValue.hasSuffix("%") })
        else { return XCTFail("missing \(caption) or its number", line: line) }
        XCTAssertGreaterThan(
            captionField.frame.minY, valueField.frame.minY,
            "\(caption) sits above its number", line: line
        )
    }

    // MARK: - Machine gauges

    /// The gauges wear the same bar as the Claude card above them — one bar,
    /// one ramp, one reading of what "full" means.
    func testTheGaugesCarryABarToo() {
        let card = SidebarSystemStatsView()
        card.frame = NSRect(
            x: 0, y: 0, width: ShellMetrics.sidebarWidth - 16, height: SidebarSystemStatsView.height
        )
        card.apply(cpu: 0.34, memory: 0.78, gpu: 0.95)
        card.layoutSubtreeIfNeeded()

        XCTAssertEqual(card.cpuGauge.bar.fillFraction, 0.34, accuracy: 0.001)
        XCTAssertEqual(card.cpuGauge.bar.fillColor, ShellPalette.green)
        XCTAssertEqual(card.memoryGauge.bar.fillColor, ShellPalette.amber)
        XCTAssertEqual(card.gpuGauge.bar.fillColor, ShellPalette.red)
        XCTAssertGreaterThan(card.cpuGauge.bar.frame.width, 20, "the bar spans its column")
    }

    /// The number and its bar share one ramp, so they cannot drift apart —
    /// the gauge used to carry its own copy of the same three thresholds.
    func testTheGaugesNumberAndBarAgree() {
        let card = SidebarSystemStatsView()
        card.apply(cpu: 0.95, memory: nil, gpu: nil)
        XCTAssertEqual(card.cpuGauge.readoutColor, ShellPalette.red)
        XCTAssertEqual(card.cpuGauge.bar.fillColor, ShellPalette.red)
        XCTAssertEqual(card.memoryGauge.readout, "—")
        XCTAssertNil(card.memoryGauge.bar.fraction, "no sample, empty track")
    }

    /// Adding the bars must not have cost the sidebar any height: they went
    /// into padding the card already had.
    func testTheGaugesCardDidNotGrow() {
        XCTAssertEqual(SidebarSystemStatsView.height, 62)
        let card = SidebarSystemStatsView()
        card.frame = NSRect(x: 0, y: 0, width: 216, height: SidebarSystemStatsView.height)
        card.apply(cpu: 1, memory: 1, gpu: 1)
        card.layoutSubtreeIfNeeded()
        XCTAssertLessThanOrEqual(
            card.cpuGauge.fittingSize.height, SidebarSystemStatsView.height,
            "the column still fits inside the card"
        )
    }

    // MARK: - Claude limits card

    /// It sits above the machine gauges, which is where it was asked to go —
    /// and both survive.
    func testTheClaudeCardSitsAboveTheMachineGauges() {
        let sidebar = makeSidebar()
        XCTAssertGreaterThan(
            sidebar.claudeLimits.frame.minY, sidebar.statsRow.frame.minY,
            "higher up the column than CPU/MEM/GPU"
        )
        XCTAssertGreaterThan(sidebar.statsRow.frame.height, 0, "the gauges are still there")
    }

    private func makeLimitsCard() -> SidebarClaudeLimitsView {
        let card = SidebarClaudeLimitsView()
        card.frame = NSRect(
            x: 0, y: 0, width: ShellMetrics.sidebarWidth - 16, height: SidebarClaudeLimitsView.height
        )
        return card
    }

    private let noon = Calendar.current.date(
        from: DateComponents(year: 2026, month: 8, day: 25, hour: 12)
    )!

    /// The number is the fastest read on the card, and it was missing
    /// entirely — the card showed a bar and nothing else.
    func testEachColumnLeadsWithItsPercentage() {
        let card = makeLimitsCard()
        card.apply(
            ClaudeUsageLimits.parse(
                "Current session: 4% used · resets Aug 25 at 3:00pm\n"
                + "Current week (all models): 41% used · resets Aug 28 at 11am"
            ),
            now: noon
        )
        XCTAssertEqual(card.sessionColumn.readout, "4%")
        XCTAssertEqual(card.weekColumn.readout, "41%")
    }

    /// A bare `2d 11h` does not say whether it is time spent or time left.
    /// It lives on the hover now rather than on a row of its own.
    func testTheCountdownSaysWhatItIs() {
        let card = makeLimitsCard()
        card.apply(
            ClaudeUsageLimits.parse(
                "Current session: 4% used · resets Aug 25 at 3:00pm\n"
                + "Current week (all models): 41% used · resets Aug 28 at 11am"
            ),
            now: noon
        )
        XCTAssertEqual(card.sessionColumn.remaining, "3h 0m left")
        XCTAssertEqual(card.weekColumn.remaining, "2d 23h left")
    }

    /// Equal-width columns are what stop the two bars starting or ending at
    /// different x — the ragged edges the first version had, where each row
    /// sized itself around its own label and its own countdown.
    func testTheTwoBarsShareAStartAndAnEnd() {
        let card = makeLimitsCard()
        card.apply(
            ClaudeUsageLimits.parse(
                "Current session: 4% used · resets Aug 25 at 3:00pm\n"
                + "Current week (all models): 41% used · resets Aug 28 at 11am"
            ),
            now: noon
        )
        card.layoutSubtreeIfNeeded()

        let session = card.sessionColumn.bar.convert(card.sessionColumn.bar.bounds, to: card)
        let week = card.weekColumn.bar.convert(card.weekColumn.bar.bounds, to: card)
        XCTAssertEqual(session.width, week.width, accuracy: 0.5, "same length")
        XCTAssertEqual(session.minY, week.minY, accuracy: 0.5, "same baseline")
        XCTAssertGreaterThan(session.width, 30, "wide enough to read a level")
    }

    /// Fill is what has been spent and the colour ramps with it, so a full bar
    /// is always red — "full" and "bad" never disagree.
    func testTheFillAndItsColourAgree() {
        let bar = SidebarPercentBarView()
        bar.apply(0.41)
        XCTAssertEqual(bar.fillColor, ShellPalette.green)
        bar.apply(0.75)
        XCTAssertEqual(bar.fillColor, ShellPalette.amber)
        bar.apply(0.95)
        XCTAssertEqual(bar.fillColor, ShellPalette.red)
    }

    /// The number wears the same verdict as its bar, so the two cannot say
    /// different things about the same window.
    func testTheNumberWearsTheBarsVerdict() {
        let card = makeLimitsCard()
        card.apply(ClaudeUsageLimits.parse("Current session: 95% used · resets Aug 25 at 3:00pm"), now: noon)
        XCTAssertEqual(card.sessionColumn.readoutColor, ShellPalette.red)
        XCTAssertEqual(card.sessionColumn.bar.fillColor, ShellPalette.red)
    }

    /// A fresh window reads 0%, and drawing that as an empty track made it
    /// pixel-identical to having no reading at all. This is the whole reason
    /// the Session row looked broken.
    func testARealZeroStillDrawsSomething() {
        let card = makeLimitsCard()
        card.frame = NSRect(x: 0, y: 0, width: 216, height: SidebarClaudeLimitsView.height)
        card.apply(ClaudeUsageLimits.parse("Current session: 0% used · resets Aug 25 at 3:00pm"), now: noon)
        card.layoutSubtreeIfNeeded()

        XCTAssertEqual(card.sessionColumn.readout, "0%")
        XCTAssertGreaterThanOrEqual(
            card.sessionColumn.bar.fillWidth, SidebarPercentBarView.minimumFillWidth,
            "a real zero still shows a nub"
        )
    }

    /// And no reading at all draws nothing, so the two states stay distinct.
    func testNoReadingDrawsNothingAndSaysSo() {
        let card = makeLimitsCard()
        card.apply(nil, now: noon)
        card.layoutSubtreeIfNeeded()

        XCTAssertEqual(card.sessionColumn.readout, "—")
        XCTAssertEqual(card.sessionColumn.remaining, "no reading")
        XCTAssertNil(card.sessionColumn.bar.fraction)
        XCTAssertEqual(card.sessionColumn.bar.fillWidth, 0, "empty track, not a zero fill")
    }

    /// The card was trimmed from 108pt to 74pt because it crowded the
    /// sidebar. That trim is only safe while the content still fits: a later
    /// font bump or an extra line would clip silently, since the height is
    /// authored rather than intrinsic.
    func testTheCardIsTallEnoughForItsOwnContent() {
        let card = makeLimitsCard()
        card.apply(
            ClaudeUsageLimits.parse(
                "Current session: 100% used · resets Aug 28 at 11am\n"
                + "Current week (all models): 100% used · resets Aug 28 at 11am"
            ),
            now: noon
        )
        card.layoutSubtreeIfNeeded()

        for column in [card.sessionColumn, card.weekColumn] {
            XCTAssertLessThanOrEqual(
                column.fittingSize.height, SidebarClaudeLimitsView.height,
                "the column fits inside the card"
            )
            XCTAssertGreaterThan(column.bar.frame.width, 0, "and the bar survived the trim")
        }
    }

    /// Shorter than it was, and still clearly the taller of the two cards —
    /// it carries four lines of content to the gauges' two.
    func testTheCardIsNoTallerThanItNeedsToBe() {
        XCTAssertEqual(SidebarClaudeLimitsView.height, 70)
        XCTAssertLessThan(
            SidebarClaudeLimitsView.height, 90,
            "the sidebar has a workspace list to show as well"
        )
    }

    /// A `/usage` that reports only the week must not blank the session half.
    /// It used to, and an empty bar beside a dash is what that looked like.
    func testAWeekOnlyReadingKeepsTheSession() {
        let full = ClaudeUsageLimits.parse(
            "Current session: 4% used · resets Aug 25 at 3:00pm\n"
            + "Current week (all models): 41% used · resets Aug 28 at 11am"
        )
        let weekOnly = ClaudeUsageLimits.parse(
            "Current week (all models): 43% used · resets Aug 28 at 11am"
        )

        let merged = weekOnly.merged(onto: full)

        XCTAssertEqual(merged.sessionPercent, 4, "kept from the last reading that had one")
        XCTAssertEqual(merged.sessionResets, "Aug 25 at 3:00pm")
        XCTAssertEqual(merged.weekPercent, 43, "the fresh half won")
    }

    /// Merged per window, not per field: a session that reported a percentage
    /// but no readable reset must not inherit the previous window's reset and
    /// count down to the wrong moment.
    func testAWindowIsKeptOrReplacedWhole() {
        let full = ClaudeUsageLimits.parse("Current session: 4% used · resets Aug 25 at 3:00pm")
        // A session line carrying no `resets` clause at all, so the phrase is
        // genuinely absent rather than merely unparseable.
        let noPhrase = ClaudeUsageLimits.parse("Current session: 9% used")

        let merged = noPhrase.merged(onto: full)

        XCTAssertEqual(merged.sessionPercent, 9, "the fresh window won")
        XCTAssertNil(merged.sessionResets, "and did not inherit the old window's reset time")
        XCTAssertNil(merged.sessionResetsAt, "so there is no instant to count down to")
    }

}
