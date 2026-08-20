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
