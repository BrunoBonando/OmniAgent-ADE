import AppKit
import XCTest

@testable import OmniAgent

/// The review panel's Changes tab — the 2026-08-20 redesign's §5: the
/// workspace's working-tree diff, strictly read-only. The changed-file list
/// comes from `GitStatus.load`, a row's diff from `GitFileContent.unifiedDiff`
/// through the Monaco bridge (the editor's changes-overview machinery), and a
/// clean tree shows the centred empty state instead.
///
/// Every test builds its **own** throwaway repository in a temp directory —
/// never this repo's working tree, which several agents mutate concurrently
/// and whose HEAD moves mid-run.
final class ReviewPanelChangesViewTests: XCTestCase {
    /// Stands in for the Monaco host, so the list and diff payloads can be
    /// asserted without booting WebKit.
    private final class RendererSpy: ReviewPanelDiffRenderer {
        var shownLists: [[(path: String, badge: String)]] = []
        var appendedDiffs: [(path: String, text: String)] = []
        func showChanges(files: [(path: String, badge: String)]) { shownLists.append(files) }
        func appendFileDiff(path: String, text: String) { appendedDiffs.append((path, text)) }
    }

    private var repo: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        try skipUnlessGitIsAvailable()
        repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("review-changes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try git("init", "-q")
        try git("config", "user.email", "t@t")
        try git("config", "user.name", "t")
        try write("one\n", to: "a.txt")
        try git("add", ".")
        try git("commit", "-qm", "initial")
        try write("one\ntwo\n", to: "a.txt")
        try write("new\n", to: "b.txt")
    }

    override func tearDownWithError() throws {
        if let repo { try? FileManager.default.removeItem(at: repo) }
        repo = nil
        try super.tearDownWithError()
    }

    // MARK: - The changed-file list

    /// A refresh loads `git status` for the workspace root and hands the
    /// sorted list — with the FILES tree's own badge letters — to the bridge.
    func testTheListShowsTheChangedFilesFromTheWorkingTree() throws {
        let changes = makeChanges()
        let spy = RendererSpy()
        changes.rendererForTesting = spy

        changes.setRoot(repo)
        changes.refresh()

        try awaitCondition("the list payload arrives") { !spy.shownLists.isEmpty }
        let files = try XCTUnwrap(spy.shownLists.last)
        XCTAssertEqual(files.map(\.path), ["a.txt", "b.txt"])
        XCTAssertEqual(files.map(\.badge), ["M", "U"])
        XCTAssertTrue(changes.emptyStateView.isHidden, "there are changes, so no empty state")
        XCTAssertEqual(changes.summaryField.stringValue, "2 changed files")
        XCTAssertNil(changes.webHost, "the seam replaces the web view — none is paid for")
    }

    /// The controls bar's refresh button reloads the status, so a change made
    /// after the last look shows up without switching tabs.
    func testTheRefreshButtonReloadsTheStatus() throws {
        let changes = makeChanges()
        let spy = RendererSpy()
        changes.rendererForTesting = spy
        changes.setRoot(repo)
        changes.refresh()
        try awaitCondition("the first payload arrives") { !spy.shownLists.isEmpty }

        try write("later\n", to: "c.txt")
        try XCTUnwrap(changes.refreshButton.onPress)()

        try awaitCondition("the reload sees the new file") {
            spy.shownLists.last?.contains { $0.path == "c.txt" } == true
        }
    }

    // MARK: - The empty state

    /// A clean working tree shows the spec's centred empty state — the
    /// plus-minus glyph and its two lines — and sends the bridge nothing.
    func testTheEmptyStateShowsWhenThereIsNothingToCompare() throws {
        try git("add", ".")
        try git("commit", "-qm", "everything")
        let changes = makeChanges()
        let spy = RendererSpy()
        changes.rendererForTesting = spy

        changes.setRoot(repo)
        changes.refresh()

        try awaitCondition("the clean status lands") { changes.currentStatus != nil }
        XCTAssertFalse(changes.emptyStateView.isHidden)
        XCTAssertEqual(changes.emptyTitleField.stringValue, "No changes to compare")
        XCTAssertEqual(
            changes.emptySubtitleField.stringValue,
            "Make changes in this workspace to see them here"
        )
        XCTAssertNotNil(changes.emptyGlyph.image, "the plus-minus glyph is there")
        XCTAssertTrue(spy.shownLists.isEmpty, "nothing to list, nothing sent")
    }

    /// A workspace that is not a repository has nothing to compare either —
    /// the same empty state, not an error.
    func testAWorkspaceOutsideARepositoryShowsTheEmptyState() throws {
        let plain = FileManager.default.temporaryDirectory
            .appendingPathComponent("review-changes-plain-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: plain) }
        let changes = makeChanges()
        let spy = RendererSpy()
        changes.rendererForTesting = spy
        var settled = false

        changes.setRoot(plain)
        changes.refresh { settled = true }

        try awaitCondition("the load settles") { settled }
        XCTAssertNil(changes.currentStatus)
        XCTAssertFalse(changes.emptyStateView.isHidden)
        XCTAssertTrue(spy.shownLists.isEmpty)
    }

    // MARK: - The diff seam

    /// A row asking for its hunks costs one `git diff` and lands back on the
    /// bridge as `appendFileDiff` with the real unified diff.
    func testTheDiffSeamReceivesTheRightPayload() throws {
        let changes = makeChanges()
        let spy = RendererSpy()
        changes.rendererForTesting = spy
        changes.setRoot(repo)
        changes.refresh()
        try awaitCondition("the list payload arrives") { !spy.shownLists.isEmpty }

        changes.handleFileDiffRequest("a.txt")

        try awaitCondition("the diff payload arrives") { !spy.appendedDiffs.isEmpty }
        let diff = try XCTUnwrap(spy.appendedDiffs.first)
        XCTAssertEqual(diff.path, "a.txt")
        XCTAssertTrue(diff.text.contains("@@"), "a unified diff carries hunk headers")
        XCTAssertTrue(diff.text.contains("+two"), "the working tree's new line is the + side")
    }

    /// An untracked file still gets a diff — everything as additions, the
    /// `--no-index` fallback `GitFileContent.unifiedDiff` carries.
    func testAnUntrackedFileDiffsAsAllAdditions() throws {
        let changes = makeChanges()
        let spy = RendererSpy()
        changes.rendererForTesting = spy
        changes.setRoot(repo)
        changes.refresh()
        try awaitCondition("the list payload arrives") { !spy.shownLists.isEmpty }

        changes.handleFileDiffRequest("b.txt")

        try awaitCondition("the diff payload arrives") { !spy.appendedDiffs.isEmpty }
        let diff = try XCTUnwrap(spy.appendedDiffs.first)
        XCTAssertEqual(diff.path, "b.txt")
        XCTAssertTrue(diff.text.contains("+new"))
    }

    // MARK: - Read-only routing

    /// The overview's "open file" and double-click route up to the editor
    /// flows — the panel itself opens nothing and edits nothing.
    func testRowActivationsRouteToTheEditorFlows() throws {
        let changes = makeChanges()
        let spy = RendererSpy()
        changes.rendererForTesting = spy
        changes.setRoot(repo)
        changes.refresh()
        try awaitCondition("the list payload arrives") { !spy.shownLists.isEmpty }
        var openedFiles: [URL] = []
        var openedDiffs: [URL] = []
        changes.onOpenFileRequest = { openedFiles.append($0) }
        changes.onOpenDiffRequest = { openedDiffs.append($0) }

        changes.handleChangesOpen("a.txt", asDiff: false)
        changes.handleChangesOpen("b.txt", asDiff: true)

        XCTAssertEqual(openedFiles.map(\.lastPathComponent), ["a.txt"])
        XCTAssertEqual(openedDiffs.map(\.lastPathComponent), ["b.txt"])
    }

    // MARK: - Refresh on tab activation, through the controller

    /// Selecting the Changes tab is what points it at the showing session's
    /// workspace and reloads — the spec's refresh-on-activation.
    func testActivatingTheChangesTabPointsItAtTheSessionWorkspace() throws {
        let controller = makeController(panes: [
            PersistedTab(project: "alpha", engine: .claude, cwd: repo.path, id: "s-1", group: "g-1"),
        ])
        defer { controller.close() }
        let spy = RendererSpy()
        controller.reviewPanelChanges.rendererForTesting = spy

        controller.applyRestoredReviewPanel(
            ReviewPanelStateCodec.serialize([
                "g-1": ReviewPanelSessionState(open: true, activeTab: "files"),
            ])
        )
        XCTAssertNil(
            controller.reviewPanelChanges.rootURL,
            "an inactive tab loads nothing — activation is the trigger"
        )

        controller.reviewPanel.selectTab(.changes)

        XCTAssertEqual(controller.reviewPanelChanges.rootURL?.path, repo.path)
        try awaitCondition("activation refreshed the status") {
            controller.reviewPanelChanges.currentStatus != nil
        }
        XCTAssertEqual(spy.shownLists.last?.map(\.path), ["a.txt", "b.txt"])
    }

    // MARK: - Pixels

    /// Offscreen render of the empty state — the flat sidebar's pattern:
    /// the centred stack's constraints can hold while the glyph or a line
    /// drew nothing, so each block must show a channel spread in the bitmap.
    /// Drops a PNG when `PANE_RENDER_DIR` is set
    /// (`TEST_RUNNER_PANE_RENDER_DIR` through `build.sh`).
    func testTheChangesEmptyStateRendersInPixels() throws {
        let plain = FileManager.default.temporaryDirectory
            .appendingPathComponent("review-changes-render-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: plain) }
        let changes = makeChanges()
        let spy = RendererSpy()
        changes.rendererForTesting = spy
        var settled = false

        changes.setRoot(plain)
        changes.refresh { settled = true }
        try awaitCondition("the load settles") { settled }
        XCTAssertFalse(changes.emptyStateView.isHidden, "a non-repo shows the empty state")

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 480),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = changes

        // A green marker anchors which end of the bitmap is up — the sidebar
        // render test's pattern. This view IS flipped, so its top is y = 0,
        // and the top-left corner is the controls bar's empty leading edge
        // (the summary field is blank outside a repository).
        let marker = NSView(frame: NSRect(x: 0, y: 0, width: 10, height: 6))
        marker.wantsLayer = true
        marker.layer?.backgroundColor = NSColor.green.cgColor
        changes.addSubview(marker)

        window.makeKeyAndOrderFront(nil)
        changes.layoutSubtreeIfNeeded()
        window.displayIfNeeded()

        let image = try XCTUnwrap(render(changes))
        saveRenderForInspection(image, named: "review-panel-changes-empty")

        func pixel(_ x: Int, _ y: Int) -> NSColor {
            image.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) ?? .black
        }
        let anchor = try XCTUnwrap(
            (0..<image.pixelsHigh).first {
                pixel(3, $0).greenComponent > 0.8 && pixel(3, $0).redComponent < 0.4
            },
            "the marker has to show up, or the render proves nothing"
        )
        // The marker sits at the view's top. In this flipped view a rect's
        // minY is measured from the top, so top-down bitmaps map directly.
        let topDown = anchor < image.pixelsHigh / 2
        func bitmapRow(forViewY viewY: Int) -> Int {
            topDown ? viewY : image.pixelsHigh - 1 - viewY
        }

        /// The widest channel spread across the block's pixels — a block
        /// that drew nothing is flat panel background, spread ≈ 0.
        func spread(_ view: NSView) -> CGFloat {
            let rect = view.convert(view.bounds, to: changes).intersection(changes.bounds)
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

        XCTAssertGreaterThan(spread(changes.emptyGlyph), 0.08, "the plus-minus glyph rendered nothing")
        XCTAssertGreaterThan(spread(changes.emptyTitleField), 0.1, "the title line rendered nothing")
        XCTAssertGreaterThan(spread(changes.emptySubtitleField), 0.08, "the subtitle rendered nothing")
        XCTAssertGreaterThan(spread(changes.refreshButton), 0.08, "the refresh button rendered nothing")

        // And the glyph sits above its two lines, centred in the content
        // area — the spec's layout, in the same flipped coordinates.
        func top(_ view: NSView) -> CGFloat { view.convert(view.bounds, to: changes).minY }
        XCTAssertLessThan(top(changes.emptyGlyph), top(changes.emptyTitleField))
        XCTAssertLessThan(top(changes.emptyTitleField), top(changes.emptySubtitleField))
    }

    /// Renders the view's whole layer tree — `cacheDisplay` draws `draw(_:)`
    /// output only. The pane workspace render tests' pattern, plus one turn:
    /// `layer.render(in:)` ignores the root layer's `geometryFlipped`, so a
    /// flipped view comes out mirrored; pre-flipping the context keeps the
    /// inspection PNG legible (the marker anchoring absorbs either way up).
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
        if view.isFlipped {
            context.cgContext.translateBy(x: 0, y: CGFloat(rep.pixelsHigh))
            context.cgContext.scaleBy(x: 1, y: -1)
        }
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

    private func makeChanges() -> ReviewPanelChangesView {
        let changes = ReviewPanelChangesView()
        changes.frame = NSRect(x: 0, y: 0, width: 420, height: 480)
        changes.layoutSubtreeIfNeeded()
        return changes
    }

    private func makeController(panes: [PersistedTab]) -> WorkspaceWindowController {
        let controller = WorkspaceWindowController(
            connection: SessionConnection(
                socketURL: URL(fileURLWithPath: "/tmp/omniagent-review-changes-test.sock")
            ),
            panes: []
        )
        controller.sessionEnsurer = { _ in }
        controller.sessionKiller = { _ in }
        controller.applyRestoredPanes(
            WorkspaceRestoration.plan(fromLayout: PersistedLayoutCodec.serialize(panes))
        )
        return controller
    }

    private func awaitCondition(
        _ what: String,
        timeout: TimeInterval = 10,
        _ condition: () -> Bool
    ) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        XCTFail("\(what) never happened")
        throw XCTSkip("nothing to assert on")
    }

    private func write(_ contents: String, to relativePath: String) throws {
        let url = repo.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    private func git(_ arguments: String...) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", repo.path] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "git \(arguments.joined(separator: " ")) failed")
    }

    private func skipUnlessGitIsAvailable() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "--version"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { throw XCTSkip("git is not available on PATH") }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw XCTSkip("git is not available on PATH") }
    }
}
