import AppKit
import XCTest

@testable import OmniAgent

/// The review panel's Files tab — the 2026-08-20 redesign's §5: the migrated
/// workspace file tree beside an embedded single-file Monaco view, with the
/// gear popover's two preferences (hidden files, tree position), the
/// hide-tree toggle, and New file / New folder from the tree's right-click.
final class ReviewPanelFilesViewTests: XCTestCase {
    // MARK: - Tree basics

    /// Pointing the tab at a workspace lists that workspace's root.
    func testTheTreeRendersTheWorkspaceRoot() throws {
        let files = makeFiles()
        let directory = try makeTempDirectory(containing: "alpha.swift", "beta.swift")

        files.apply(root: directory, openFile: nil, treePosition: nil, showHidden: nil)

        try awaitFileRow(named: "alpha.swift", in: files.tree)
        try awaitFileRow(named: "beta.swift", in: files.tree)
    }

    /// The filter field narrows the tree to matching names.
    func testTheFilterNarrowsTheTree() throws {
        let files = makeFiles()
        let directory = try makeTempDirectory(containing: "alpha.swift", "beta.swift")
        files.apply(root: directory, openFile: nil, treePosition: nil, showHidden: nil)
        try awaitFileRow(named: "beta.swift", in: files.tree)

        files.tree.setFilter("alp")

        let names = files.tree.descendants(WorkspaceFileRowView.self).map(\.node.name)
        XCTAssertEqual(names, ["alpha.swift"])
    }

    // MARK: - Hidden files

    /// Dotfiles stay out until the gear's toggle asks for them; the toggle is
    /// a user preference, so it reports for persistence.
    func testTheHiddenFilesToggleRevealsDotfiles() throws {
        let files = makeFiles()
        let directory = try makeTempDirectory(containing: "a.swift", ".secret")
        files.apply(root: directory, openFile: nil, treePosition: nil, showHidden: nil)
        try awaitFileRow(named: "a.swift", in: files.tree)
        XCTAssertFalse(
            files.tree.descendants(WorkspaceFileRowView.self).contains { $0.node.name == ".secret" },
            "hidden files stay hidden by default"
        )
        var reported = 0
        files.onPreferencesChanged = { reported += 1 }

        files.setShowsHiddenFiles(true)

        try awaitFileRow(named: ".secret", in: files.tree)
        XCTAssertTrue(files.showsHiddenFiles)
        XCTAssertEqual(reported, 1)
    }

    /// The data layer's half of the same rule — and `.git` stays skipped even
    /// with hidden files on, because enumerating it is never worth a row.
    func testChildrenCanIncludeHiddenEntriesButNeverDotGit() throws {
        let directory = try makeTempDirectory(containing: "a.swift", ".secret")
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent(".git"),
            withIntermediateDirectories: true
        )

        XCTAssertEqual(WorkspaceFiles.children(of: directory).map(\.name), ["a.swift"])
        XCTAssertEqual(
            WorkspaceFiles.children(of: directory, includingHidden: true).map(\.name),
            [".secret", "a.swift"]
        )
    }

    // MARK: - Tree position and the hide toggle

    /// Left/Right from the gear popover moves the tree column to the other
    /// side of the viewer, and reports for persistence. A restore via
    /// `apply` sets the same thing silently.
    func testTheTreePositionSwapsTheColumnsAndReports() {
        let files = makeFiles()
        var reported = 0
        files.onPreferencesChanged = { reported += 1 }
        files.layoutSubtreeIfNeeded()
        XCTAssertEqual(files.treePosition, .left)
        XCTAssertLessThan(files.tree.frame.minX, files.viewerContainer.frame.minX)

        files.setTreePosition(.right)
        files.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(files.tree.frame.minX, files.viewerContainer.frame.minX)
        XCTAssertEqual(reported, 1)

        files.apply(root: nil, openFile: nil, treePosition: "left", showHidden: nil)
        files.layoutSubtreeIfNeeded()
        XCTAssertEqual(files.treePosition, .left)
        XCTAssertLessThan(files.tree.frame.minX, files.viewerContainer.frame.minX)
        XCTAssertEqual(reported, 1, "a restore is not an edit")
    }

    /// The hide-tree button collapses the tree column and hands its width to
    /// the viewer; pressing again brings it back.
    func testTheHideTreeToggleCollapsesTheTreeColumn() throws {
        let files = makeFiles()
        files.layoutSubtreeIfNeeded()
        XCTAssertFalse(files.tree.isHidden)

        try XCTUnwrap(files.hideTreeButton.onPress)()
        files.layoutSubtreeIfNeeded()

        XCTAssertTrue(files.tree.isHidden)
        XCTAssertEqual(files.viewerContainer.frame.width, files.bounds.width)

        try XCTUnwrap(files.hideTreeButton.onPress)()
        files.layoutSubtreeIfNeeded()
        XCTAssertFalse(files.tree.isHidden)
    }

    // MARK: - The gear popover's controls

    func testTheSettingsControlsReport() {
        let view = ReviewPanelFilesSettingsView(showsHidden: false, position: .left)
        var hidden: [Bool] = []
        var positions: [ReviewPanelFilesView.TreePosition] = []
        view.onShowHiddenChanged = { hidden.append($0) }
        view.onPositionChanged = { positions.append($0) }

        view.hiddenCheckbox.performClick(nil)
        view.positionControl.selectedSegment = 1
        view.positionPicked()

        XCTAssertEqual(hidden, [true])
        XCTAssertEqual(positions, [.right])
    }

    // MARK: - New file / New folder

    /// Right-clicking a file row targets its directory; the context menu's
    /// New File creates on disk there and the tree selects the new node.
    func testTheContextMenuCreatesAFileOnDiskAndSelectsIt() throws {
        let files = makeFiles()
        let directory = try makeTempDirectory(containing: "a.swift")
        files.apply(root: directory, openFile: nil, treePosition: nil, showHidden: nil)
        let row = try awaitFileRow(named: "a.swift", in: files.tree)
        files.tree.layoutSubtreeIfNeeded()
        let point = row.convert(NSPoint(x: 12, y: row.bounds.midY), to: files.tree)
        XCTAssertEqual(
            files.tree.contextDirectory(at: point)?.lastPathComponent,
            directory.lastPathComponent,
            "a file row targets the directory that holds it"
        )

        let menu = try XCTUnwrap(files.tree.makeContextMenu(for: directory))
        XCTAssertEqual(menu.items.map(\.title), ["New File…", "New Folder…"])
        files.tree.promptForName = { _, done in done("fresh.swift") }
        try XCTUnwrap(menu.items.first as? ShellMenuItem).performForTesting()

        let created = directory.appendingPathComponent("fresh.swift")
        XCTAssertTrue(FileManager.default.fileExists(atPath: created.path))
        let fresh = try awaitFileRow(named: "fresh.swift", in: files.tree)
        XCTAssertFalse(fresh.node.isDirectory)
        XCTAssertEqual(files.tree.selected?.lastPathComponent, "fresh.swift")
    }

    func testTheContextMenuCreatesAFolderOnDiskAndSelectsIt() throws {
        let files = makeFiles()
        let directory = try makeTempDirectory(containing: "a.swift")
        files.apply(root: directory, openFile: nil, treePosition: nil, showHidden: nil)
        try awaitFileRow(named: "a.swift", in: files.tree)

        let menu = try XCTUnwrap(files.tree.makeContextMenu(for: directory))
        files.tree.promptForName = { _, done in done("Sources") }
        try XCTUnwrap(menu.items.last as? ShellMenuItem).performForTesting()

        var isDirectory: ObjCBool = false
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("Sources").path,
                isDirectory: &isDirectory
            )
        )
        XCTAssertTrue(isDirectory.boolValue)
        let row = try awaitFileRow(named: "Sources", in: files.tree)
        XCTAssertTrue(row.node.isDirectory)
        XCTAssertEqual(files.tree.selected?.lastPathComponent, "Sources")
    }

    // MARK: - The Monaco seam

    /// Clicking a file in the tree opens it in the embedded Monaco view —
    /// verified end to end: the click builds the web host, and the file's
    /// text really lands in a Monaco model.
    func testAFileClickReachesTheMonacoSeam() throws {
        let files = makeFiles()
        let directory = try makeTempDirectory()
        let url = directory.appendingPathComponent("a.swift")
        try "let x = 1".write(to: url, atomically: true, encoding: .utf8)
        files.apply(root: directory, openFile: nil, treePosition: nil, showHidden: nil)
        var reportedOpens: [String?] = []
        files.onOpenFileChanged = { reportedOpens.append($0) }
        XCTAssertNil(files.webHost, "the web view is not paid for until a file needs it")

        let row = try awaitFileRow(named: "a.swift", in: files.tree)
        try XCTUnwrap(row.onPress)()

        XCTAssertEqual(files.currentOpenFilePath, url.path)
        XCTAssertEqual(reportedOpens, [url.path])
        let host = try XCTUnwrap(files.webHost)
        waitUntilReady(host)
        let answered = expectation(description: "monaco holds the file")
        host.requestContent(path: url.path) { content, _ in
            XCTAssertEqual(content, "let x = 1")
            answered.fulfill()
        }
        wait(for: [answered], timeout: 10)
    }

    /// `apply` restores the persisted open file silently, and clears the
    /// viewer when the entry points at a file that no longer exists.
    func testApplyRestoresTheOpenFileSilently() throws {
        let files = makeFiles()
        let directory = try makeTempDirectory()
        let url = directory.appendingPathComponent("kept.swift")
        try "kept".write(to: url, atomically: true, encoding: .utf8)
        var reportedOpens: [String?] = []
        files.onOpenFileChanged = { reportedOpens.append($0) }

        files.apply(root: directory, openFile: url.path, treePosition: nil, showHidden: nil)
        XCTAssertEqual(files.currentOpenFilePath, url.path)

        files.apply(
            root: directory,
            openFile: directory.appendingPathComponent("gone.swift").path,
            treePosition: nil,
            showHidden: nil
        )
        XCTAssertNil(files.currentOpenFilePath)
        XCTAssertEqual(reportedOpens, [], "a restore never reports")
    }

    // MARK: - The panel mounts the real view

    func testTheFilesTabShowsARegisteredContentView() {
        let panel = ReviewPanelView()
        let view = NSView()
        panel.setContent(view, for: .files)

        panel.selectTab(.files)
        XCTAssertFalse(view.isHidden)
        XCTAssertNil(panel.placeholders[.files], "no placeholder behind a real view")

        panel.selectTab(.changes)
        XCTAssertTrue(view.isHidden)
        XCTAssertEqual(panel.placeholders[.changes]?.isHidden, false)
    }

    // MARK: - Per-session persistence through the controller

    /// The Files tab's preferences and open file ride the same
    /// `review_panel_native` row as the rest of the panel: a restored row
    /// configures the view, and a user change writes straight back.
    func testFilesStateRoundTripsThroughTheReviewPanelRow() throws {
        let directory = try makeTempDirectory()
        let url = directory.appendingPathComponent("a.swift")
        try "x".write(to: url, atomically: true, encoding: .utf8)
        let controller = makeController(panes: [
            PersistedTab(project: "alpha", engine: .claude, cwd: directory.path, id: "s-1", group: "g-1"),
        ])
        defer { controller.close() }
        var written: [String: String] = [:]
        controller.settingsWriter = { key, value in written[key] = value }

        controller.applyRestoredReviewPanel(
            ReviewPanelStateCodec.serialize([
                "g-1": ReviewPanelSessionState(
                    open: true,
                    tabs: ["changes", "files"],
                    activeTab: "files",
                    openFile: url.path,
                    treePosition: "right",
                    showHidden: true
                ),
            ])
        )

        XCTAssertEqual(controller.reviewPanelFiles.treePosition, .right)
        XCTAssertTrue(controller.reviewPanelFiles.showsHiddenFiles)
        XCTAssertEqual(controller.reviewPanelFiles.currentOpenFilePath, url.path)
        XCTAssertEqual(
            controller.reviewPanelFiles.tree.rootForTesting?.path,
            directory.path,
            "the tree is pointed at the session's workspace"
        )

        controller.reviewPanelFiles.setTreePosition(.left)

        let persisted = ReviewPanelStateCodec.deserialize(written[SettingsKey.reviewPanel])
        XCTAssertEqual(persisted["g-1"]?.treePosition, "left")
        XCTAssertEqual(persisted["g-1"]?.showHidden, true)
        XCTAssertEqual(persisted["g-1"]?.openFile, url.path)
    }

    // MARK: - Pixels

    /// Offscreen render of the whole panel with the Files tab active — the
    /// flat sidebar's pattern: constraints alone can pass while a view drew
    /// nothing, so every block must show a channel spread in the bitmap.
    /// Drops a PNG when `PANE_RENDER_DIR` is set
    /// (`TEST_RUNNER_PANE_RENDER_DIR` through `build.sh`).
    func testThePanelRendersTheFilesTabInPixels() throws {
        let panel = ReviewPanelView()
        let files = ReviewPanelFilesView()
        panel.setContent(files, for: .files)
        panel.load(tabs: ReviewPanelTab.defaultTabs, active: .files)

        let directory = try makeTempDirectory(containing: "alpha.swift", "beta.swift")
        files.apply(root: directory, openFile: nil, treePosition: nil, showHidden: nil)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 480),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = panel

        try awaitFileRow(named: "alpha.swift", in: files.tree)
        try awaitFileRow(named: "beta.swift", in: files.tree)

        // A green marker anchors which end of the bitmap is up — the sidebar
        // render test's pattern. Top-left corner: the tab stack's 8pt leading
        // inset keeps that spot empty. The panel is not flipped, so the
        // view's top is `bounds.maxY`.
        let marker = NSView(
            frame: NSRect(x: 0, y: panel.bounds.height - 6, width: 10, height: 6)
        )
        marker.wantsLayer = true
        marker.layer?.backgroundColor = NSColor.green.cgColor
        panel.addSubview(marker)

        window.makeKeyAndOrderFront(nil)
        panel.layoutSubtreeIfNeeded()
        window.displayIfNeeded()

        let image = try XCTUnwrap(render(panel))
        saveRenderForInspection(image, named: "review-panel-files")

        func pixel(_ x: Int, _ y: Int) -> NSColor {
            image.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) ?? .black
        }
        let anchor = try XCTUnwrap(
            (0..<image.pixelsHigh).first {
                pixel(3, $0).greenComponent > 0.8 && pixel(3, $0).redComponent < 0.4
            },
            "the marker has to show up, or the render proves nothing"
        )
        let topDown = anchor < image.pixelsHigh / 2
        func bitmapRow(forViewY viewY: Int) -> Int {
            topDown ? image.pixelsHigh - 1 - viewY : viewY
        }

        /// The widest channel spread across the block's pixels — a block
        /// that drew nothing is flat panel background, spread ≈ 0.
        func spread(_ view: NSView) -> CGFloat {
            let rect = view.convert(view.bounds, to: panel).intersection(panel.bounds)
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

        // The tab bar: both default tabs drew, and Files wears the selection.
        XCTAssertEqual(panel.tabItems.map(\.tab), [.changes, .files])
        for item in panel.tabItems {
            XCTAssertGreaterThan(spread(item), 0.1, "the \(item.tab.title) tab rendered nothing")
        }
        let filesItem = try XCTUnwrap(panel.tabItems.first { $0.tab == .files })
        XCTAssertTrue(filesItem.isSelected, "the Files tab is the active one")
        XCTAssertGreaterThan(spread(panel.addButton), 0.08, "the + button rendered nothing")
        XCTAssertGreaterThan(spread(panel.expandButton), 0.08, "the expand toggle rendered nothing")

        // The Files content: controls-bar buttons, both file rows, and the
        // viewer's click-a-file placeholder.
        XCTAssertGreaterThan(spread(files.gearButton), 0.08, "the gear rendered nothing")
        XCTAssertGreaterThan(spread(files.hideTreeButton), 0.08, "the hide-tree toggle rendered nothing")
        let rows = files.tree.descendants(WorkspaceFileRowView.self)
        XCTAssertEqual(rows.map(\.node.name), ["alpha.swift", "beta.swift"])
        for row in rows {
            XCTAssertGreaterThan(spread(row), 0.1, "the \(row.node.name) row rendered nothing")
        }
        XCTAssertGreaterThan(
            spread(files.viewerContainer), 0.08,
            "the viewer's empty placeholder rendered nothing"
        )
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

    // MARK: - Helpers

    private func makeFiles() -> ReviewPanelFilesView {
        let files = ReviewPanelFilesView()
        files.frame = NSRect(x: 0, y: 0, width: 640, height: 420)
        files.layoutSubtreeIfNeeded()
        return files
    }

    private func makeController(panes: [PersistedTab]) -> WorkspaceWindowController {
        let controller = WorkspaceWindowController(
            connection: SessionConnection(
                socketURL: URL(fileURLWithPath: "/tmp/omniagent-review-files-test.sock")
            ),
            panes: []
        )
        controller.sessionEnsurer = { _ in }
        controller.sessionKiller = { _ in }
        controller.applyRestoredPanes(
            WorkspaceRestoration.plan(fromLayout: PersistedLayoutCodec.serialize(panes))
        )
        // The review panel only syncs while the Desk is on screen; these tests
        // are about the panel, not the destination default, so restore that
        // precondition explicitly now that `.home` is the initial destination.
        controller.applyDestination(.terminals)
        return controller
    }

    private func makeTempDirectory(containing names: String...) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("review-files-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        for name in names {
            try "x".write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        return directory
    }

    /// The tree lists off the main thread, so a row worth asserting on may
    /// not exist yet.
    @discardableResult
    private func awaitFileRow(
        named name: String,
        in tree: WorkspaceFilesTreeView,
        timeout: TimeInterval = 10
    ) throws -> WorkspaceFileRowView {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let row = tree.descendants(WorkspaceFileRowView.self).first(where: { $0.node.name == name }) {
                return row
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        } while Date() < deadline
        XCTFail("the row for \(name) never arrived")
        throw XCTSkip("no row to press")
    }

    private func waitUntilReady(_ host: EditorWebView, timeout: TimeInterval = 30) {
        guard !host.isReady else { return }
        let ready = expectation(description: "monaco ready")
        ready.assertForOverFulfill = false
        host.onReadyForTesting = { ready.fulfill() }
        wait(for: [ready], timeout: timeout)
    }
}

private extension NSView {
    /// Depth-first search — the tree's rows live in a private stack, and
    /// walking the view tree is how a test sees what a user sees.
    func descendants<View: NSView>(_ type: View.Type) -> [View] {
        var found: [View] = []
        for subview in subviews {
            if let match = subview as? View { found.append(match) }
            found += subview.descendants(type)
        }
        return found
    }
}
