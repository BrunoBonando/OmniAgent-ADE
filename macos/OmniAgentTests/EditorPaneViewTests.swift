import AppKit
import XCTest

@testable import OmniAgent

/// Test seam for the Monaco boot handshake. Chains onto whatever `onReady`
/// the pane already installed rather than replacing it, so waiting for the
/// bridge in a test never silently disables the pane's own wiring.
extension EditorWebView {
    var onReadyForTesting: (() -> Void)? {
        get { onReady }
        set {
            let existing = onReady
            onReady = {
                existing?()
                newValue?()
            }
        }
    }
}

extension XCTestCase {
    /// Blocks until an editor pane's Monaco bridge has booted (~2–5 s hosted).
    /// Commands issued before that are queued by `EditorWebView`, so only
    /// tests that read state back need this. On `XCTestCase` rather than one
    /// test class so every editor-pane suite in the target can use it.
    func waitUntilReady(_ pane: EditorPaneView, timeout: TimeInterval = 30) {
        guard !pane.webHost.isReady else { return }
        let ready = expectation(description: "monaco ready")
        ready.assertForOverFulfill = false
        pane.webHost.onReadyForTesting = { ready.fulfill() }
        wait(for: [ready], timeout: timeout)
    }

    /// Drives the bridge the way a keystroke would and waits for the tab to
    /// land dirty. On `XCTestCase` rather than one test class so the
    /// integration suite can stage a real edit too — a `modelForTesting`
    /// dirty flag is only Swift's *copy* of the state, and the paths that
    /// matter here ask the page.
    func makeDirty(_ pane: EditorPaneView, path: String, content: String) {
        let dirty = expectation(description: "dirty")
        dirty.assertForOverFulfill = false
        let previous = pane.onStateChange
        pane.onStateChange = { tabs, active in
            previous?(tabs, active)
            if pane.model.tabs.first(where: { $0.path == path })?.isDirty == true { dirty.fulfill() }
        }
        pane.webHost.setContentForTesting(path: path, content: content)
        wait(for: [dirty], timeout: 10)
        pane.onStateChange = previous
    }
}

final class EditorPaneViewTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    private func write(_ name: String, _ content: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func makePane() -> EditorPaneView {
        let pane = EditorPaneView(initialTabs: [], activeIndex: 0)
        pane.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        return pane
    }

    func testOpenFileAddsPreviewTabAndPublishesState() throws {
        let url = try write("a.swift", "let x = 1")
        let pane = makePane()
        var published: [PersistedEditorTab]?
        var title: String?
        pane.onStateChange = { tabs, _ in published = tabs }
        pane.onTitleChange = { title = $0 }
        pane.openFile(url, pinned: false)
        XCTAssertEqual(pane.model.tabs.count, 1)
        XCTAssertFalse(pane.model.tabs[0].isPinned)
        XCTAssertEqual(published?.map(\.path), [url.path])
        XCTAssertEqual(title, "a.swift")
    }

    func testMediaFileOpensAsMediaTab() throws {
        let url = dir.appendingPathComponent("p.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: url)
        let pane = makePane()
        pane.openFile(url, pinned: true)
        XCTAssertEqual(pane.model.tabs[0].kind, .media)
        XCTAssertFalse(pane.mediaHost.isHidden)
        XCTAssertTrue(pane.webHost.isHidden)
    }

    /// A binary blob is a `.file` tab (it is not media) that nevertheless
    /// renders through the native placeholder, never through Monaco.
    func testBinaryFileOpensAsFileTabShowingPlaceholder() throws {
        let url = dir.appendingPathComponent("a.bin")
        try Data([0x01, 0x00, 0x02, 0x00]).write(to: url)
        let pane = makePane()
        pane.openFile(url, pinned: true)
        XCTAssertEqual(pane.model.tabs[0].kind, .file)
        XCTAssertFalse(pane.mediaHost.isHidden)
        XCTAssertTrue(pane.webHost.isHidden)
    }

    func testDirtyFlowsFromBridgeAndSaveWrites() throws {
        let url = try write("a.swift", "let x = 1")
        let pane = makePane()
        waitUntilReady(pane)
        pane.openFile(url, pinned: true)

        makeDirty(pane, path: url.path, content: "let x = 2")

        let saved = expectation(description: "saved")
        // The tab going clean is the *bridge's* answer, not Swift's — the page
        // only rebases when the buffer has not moved past the version that was
        // written — so it arrives on the message hop after the write.
        let clean = expectation(description: "clean")
        clean.assertForOverFulfill = false
        pane.onStateChange = { _, _ in
            if pane.model.tabs[0].isDirty == false { clean.fulfill() }
        }
        pane.saveActiveTab {
            XCTAssertTrue($0)
            saved.fulfill()
        }
        wait(for: [saved, clean], timeout: 10)
        pane.onStateChange = nil
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "let x = 2")
        XCTAssertFalse(pane.model.tabs[0].isDirty)
    }

    /// Important 1's regression: a file rewritten or deleted under a *dirty*
    /// buffer must not flip the pane to the binary placeholder. The edits are
    /// still in the model, so hiding them reads as data loss.
    func testDirtyBufferSurvivesTheFileVanishingUnderIt() throws {
        let url = try write("a.swift", "let x = 1")
        let pane = makePane()
        waitUntilReady(pane)
        pane.openFile(url, pinned: true)
        makeDirty(pane, path: url.path, content: "let x = 2")

        try FileManager.default.removeItem(at: url)
        pane.strip.selectForTesting(index: 0)

        XCTAssertFalse(pane.webHost.isHidden)
        XCTAssertTrue(pane.mediaHost.isHidden)
        XCTAssertTrue(pane.model.tabs[0].isDirty)
        let intact = expectation(description: "buffer intact")
        pane.webHost.requestContent(path: url.path) { content, _ in
            XCTAssertEqual(content, "let x = 2")
            intact.fulfill()
        }
        wait(for: [intact], timeout: 10)
    }

    /// `loadedPaths` is the flag `showActiveContent` trusts: a `.file` tab
    /// whose text Monaco never received is never marked loaded, never gets the
    /// web surface, and never acquires a phantom entry on re-activation
    /// (which would make the Important-1 early return fire on a tab that has
    /// no model). Restored rather than opened, so the load happens on the
    /// lazy path.
    ///
    /// The reachable instance of "no text" is a binary blob.
    /// `EditorFileClass.classify(url:)` already answers `.binary` for anything
    /// it cannot open, so `loadFileTab`'s both-encodings-failed arm only fires
    /// if the file is swapped out between the classification and the read —
    /// a race no test can stage deterministically. It stays as a guard.
    func testUnloadedFileTabIsNeverHandedToMonaco() throws {
        let url = dir.appendingPathComponent("a.bin")
        try Data([0x01, 0x00, 0x02, 0x00]).write(to: url)
        let pane = EditorPaneView(
            initialTabs: [PersistedEditorTab(path: url.path, kind: "file", pinned: true)],
            activeIndex: 0
        )
        pane.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        XCTAssertEqual(pane.model.tabs.count, 1)
        XCTAssertTrue(pane.loadedPaths.isEmpty)
        XCTAssertTrue(pane.webHost.isHidden)
        XCTAssertFalse(pane.mediaHost.isHidden)

        pane.strip.selectForTesting(index: 0)
        XCTAssertTrue(pane.loadedPaths.isEmpty)
        XCTAssertTrue(pane.webHost.isHidden)
    }

    /// The global rule: a failed write never silently loses work — the buffer
    /// stays dirty and the error is surfaced.
    func testFailedSaveKeepsTabDirtyAndReportsError() throws {
        let sub = dir.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let url = sub.appendingPathComponent("a.swift")
        try "let x = 1".write(to: url, atomically: true, encoding: .utf8)

        let pane = makePane()
        waitUntilReady(pane)
        pane.openFile(url, pinned: true)
        makeDirty(pane, path: url.path, content: "let x = 2")

        try FileManager.default.removeItem(at: sub)
        var reported: String?
        pane.presentError = { reported = $0 }
        let attempted = expectation(description: "save attempted")
        pane.saveActiveTab {
            XCTAssertFalse($0)
            attempted.fulfill()
        }
        wait(for: [attempted], timeout: 10)
        XCTAssertNotNil(reported)
        XCTAssertTrue(pane.model.tabs[0].isDirty)
    }

    func testCloseDirtyTabAsksAndCancelKeepsIt() throws {
        let url = try write("a.swift", "let x = 1")
        let pane = makePane()
        pane.openFile(url, pinned: true)
        pane.modelForTesting { $0.setDirty(true, at: 0) }
        var asked = false
        pane.confirmSave = { _, decide in
            asked = true
            decide(.cancel)
        }
        pane.requestCloseTab(at: 0)
        XCTAssertTrue(asked)
        XCTAssertEqual(pane.model.tabs.count, 1)
        pane.confirmSave = { _, decide in decide(.discard) }
        pane.requestCloseTab(at: 0)
        XCTAssertEqual(pane.model.tabs.count, 0)
    }

    func testCloseCleanTabNeverAsks() throws {
        let url = try write("a.swift", "let x = 1")
        let pane = makePane()
        pane.openFile(url, pinned: true)
        pane.confirmSave = { _, _ in XCTFail("a clean tab must close without a prompt") }
        pane.requestCloseTab(at: 0)
        XCTAssertTrue(pane.model.tabs.isEmpty)
    }

    func testLastTabClosedFires() throws {
        let url = try write("a.swift", "let x = 1")
        let pane = makePane()
        var fired = false
        pane.onLastTabClosed = { fired = true }
        pane.openFile(url, pinned: true)
        pane.requestCloseTab(at: 0)
        XCTAssertTrue(fired)
    }

    /// The quit/close path: every dirty tab is resolved, and one cancel stops
    /// the whole walk.
    func testCloseAllTabsAfterConfirmationHonoursCancel() throws {
        let first = try write("a.swift", "one")
        let second = try write("b.swift", "two")
        let pane = makePane()
        pane.openFile(first, pinned: true)
        pane.openFile(second, pinned: true)
        pane.modelForTesting {
            $0.setDirty(true, at: 0)
            $0.setDirty(true, at: 1)
        }
        XCTAssertTrue(pane.hasDirtyTabs)

        var proceeded: Bool?
        pane.confirmSave = { _, decide in decide(.cancel) }
        pane.closeAllTabsAfterConfirmation { proceeded = $0 }
        XCTAssertEqual(proceeded, false)
        XCTAssertEqual(pane.model.tabs.count, 2)

        proceeded = nil
        pane.confirmSave = { _, decide in decide(.discard) }
        pane.closeAllTabsAfterConfirmation { proceeded = $0 }
        XCTAssertEqual(proceeded, true)
        XCTAssertTrue(pane.model.tabs.isEmpty)
        XCTAssertFalse(pane.hasDirtyTabs)
    }

    func testRestoreDropsVanishedFiles() throws {
        let alive = try write("a.swift", "x")
        let pane = EditorPaneView(
            initialTabs: [
                PersistedEditorTab(path: alive.path, kind: "file", pinned: true),
                PersistedEditorTab(path: dir.appendingPathComponent("gone.swift").path, kind: "file", pinned: true),
                PersistedEditorTab(path: "", kind: "changes", pinned: true),
            ],
            activeIndex: 1
        )
        XCTAssertEqual(pane.model.tabs.map(\.kind), [.file, .changes])
        XCTAssertEqual(pane.model.activeIndex, 1)
    }

    /// Restoration is what the persisted row already says — republishing it
    /// would be a write amplifier on every window open.
    func testRestoreDoesNotRepublishState() throws {
        let alive = try write("a.swift", "x")
        var published = false
        let pane = EditorPaneView(
            initialTabs: [PersistedEditorTab(path: alive.path, kind: "file", pinned: true)],
            activeIndex: 0
        )
        pane.onStateChange = { _, _ in published = true }
        XCTAssertFalse(published)
        XCTAssertEqual(pane.model.tabs.count, 1)
    }

    func testEmptyPaneShowsNeitherSurfaceAndFocusesItself() {
        let pane = makePane()
        XCTAssertNil(pane.model.activeTab)
        XCTAssertTrue(pane.webHost.isHidden)
        XCTAssertTrue(pane.mediaHost.isHidden)
        XCTAssertTrue(pane.primaryResponderView === pane)
    }

    /// A zero-size web view renders nothing at all (Monaco needs a real
    /// frame), so the geometry is worth asserting outright.
    func testLayoutPutsStripOnTopAndGivesTheWebViewTheRest() throws {
        let url = try write("a.swift", "let x = 1")
        let pane = makePane()
        pane.openFile(url, pinned: true)
        pane.layoutSubtreeIfNeeded()
        XCTAssertEqual(pane.strip.frame, NSRect(x: 0, y: 0, width: 800, height: EditorTabStripView.height))
        XCTAssertEqual(
            pane.webHost.frame,
            NSRect(x: 0, y: EditorTabStripView.height, width: 800, height: 600 - EditorTabStripView.height)
        )
        XCTAssertFalse(pane.webHost.isHidden)
        XCTAssertTrue(pane.webHost.webView.frame.width > 0)
        XCTAssertTrue(pane.primaryResponderView === pane.webHost.webView)
    }

    /// The ± button only appears for a file the workspace says has changes,
    /// and it routes up rather than opening the diff itself (the controller
    /// decides which pane shows it).
    func testDiffToggleRoutesUpForChangedFiles() throws {
        let url = try write("a.swift", "let x = 1")
        let pane = makePane()
        var requested: URL?
        pane.onOpenDiffRequest = { requested = $0 }
        pane.openFile(url, pinned: true)
        pane.changedPaths = [url.path]
        pane.strip.onDiffToggle?()
        XCTAssertEqual(requested?.path, url.path)
    }

    /// The other half of eviction: the disposed path must be reopenable. If
    /// anything still pointed at the disposed model, this reads back nil or
    /// stale text instead of the file.
    func testReopeningAnEvictedPreviewPathGetsAFreshModel() throws {
        let first = try write("a.swift", "one")
        let second = try write("b.swift", "two")
        let pane = makePane()
        waitUntilReady(pane)
        pane.openFile(first, pinned: false)
        pane.openFile(second, pinned: false)
        pane.openFile(first, pinned: false)
        XCTAssertEqual(pane.model.tabs.map(\.path), [first.path])
        XCTAssertTrue(pane.loadedPaths.contains(first.path))
        XCTAssertFalse(pane.loadedPaths.contains(second.path))
        let reread = expectation(description: "reopened content")
        pane.webHost.requestContent(path: first.path) { content, _ in
            XCTAssertEqual(content, "one")
            reread.fulfill()
        }
        wait(for: [reread], timeout: 10)
    }

    // MARK: - Diff tabs (Task 12)

    /// The whole Task 12 chain against a **throwaway** repository: the HEAD
    /// blob and the working tree, handed to Monaco's side-by-side diff editor,
    /// which really computes the changes. The computation happens on the
    /// editor web worker, so this is also the pane-level guard on the
    /// deliberately absent `MonacoEnvironment.getWorkerUrl` override
    /// (`bridge.js` explains why it must stay absent).
    func testDiffTabRendersTheWorkingTreeAgainstHead() throws {
        let repo = try makeGitRepository(committing: "a.swift", "let x = 1\n")
        let file = repo.appendingPathComponent("a.swift")
        try "let x = 1\nlet y = 2\n".write(to: file, atomically: true, encoding: .utf8)
        let pane = makePane()
        waitUntilReady(pane)

        pane.openDiff(file)

        XCTAssertEqual(pane.model.tabs.map(\.kind), [.diff])
        XCTAssertTrue(pane.model.tabs[0].isPinned, "a diff open is always deliberate")
        XCTAssertTrue(
            pollUntilPositive(pane.webHost, "window.omniagent.diffChangesForTesting()"),
            "the diff editor never computed the change"
        )
    }

    /// A file that is in no repository at all cannot be diffed, and says so
    /// inside the pane rather than showing two blank editors.
    func testDiffOutsideARepositorySaysSo() throws {
        let url = try write("a.swift", "let x = 1")
        let pane = makePane()
        waitUntilReady(pane)

        pane.openDiff(url)

        XCTAssertTrue(
            pollUntilContains(pane.webHost, "document.getElementById('message').textContent", "git repository"),
            "no explanation ever reached the pane"
        )
    }

    /// A diff tab must run the file through the same classifier the file tabs
    /// do. Without it a changed binary is decoded latin-1 against a HEAD side
    /// full of U+FFFD — and, worse, read whole on the main thread with no size
    /// cap, which a 200 MB asset turns into a stall plus a vast JS literal.
    func testDiffOfABinaryFileRefusesRatherThanRenderingMojibake() throws {
        let repo = try makeGitRepository(committing: "a.swift", "let x = 1\n")
        let binary = repo.appendingPathComponent("asset.bin")
        try Data([0x00, 0x01, 0x02, 0xFF, 0x00]).write(to: binary)
        let pane = makePane()
        waitUntilReady(pane)

        pane.openDiff(binary)

        XCTAssertTrue(
            pollUntilContains(pane.webHost, "document.getElementById('message').textContent", "Binary file"),
            "a binary file was handed to the diff editor anyway"
        )
    }

    /// The classifier must not swallow the *deletion* case: a file that is
    /// gone cannot be classified at all, and its diff is exactly the point.
    func testDiffOfADeletedFileStillShowsItsHeadSide() throws {
        let repo = try makeGitRepository(committing: "a.swift", "let x = 1\nlet y = 2\n")
        let file = repo.appendingPathComponent("a.swift")
        try FileManager.default.removeItem(at: file)
        let pane = makePane()
        waitUntilReady(pane)

        pane.openDiff(file)

        XCTAssertTrue(
            pollUntilPositive(pane.webHost, "window.omniagent.diffChangesForTesting()"),
            "the deletion never reached the diff editor"
        )
    }

    /// A new folder arrives as one `dir/` record; git cannot diff a directory,
    /// and the row has to say so rather than claim there is nothing in it.
    func testChangesRowForANewFolderSaysWhatItIs() throws {
        let repo = try makeGitRepository(committing: "a.swift", "let x = 1\n")
        try FileManager.default.createDirectory(
            at: repo.appendingPathComponent("newdir"),
            withIntermediateDirectories: true
        )
        try "x\n".write(
            to: repo.appendingPathComponent("newdir/f.txt"),
            atomically: true,
            encoding: .utf8
        )
        let pane = makePane()
        waitUntilReady(pane)
        pane.setGitStatus(GitStatus(root: repo, badges: ["newdir": .untracked]))
        pane.openChanges()
        XCTAssertTrue(pollUntilContains(pane.webHost, Self.changesSummary, "newdir:U"))

        run(pane.webHost, "document.querySelectorAll('#changes .file')[0].querySelector('.row').click()")

        XCTAssertTrue(
            pollUntilContains(pane.webHost, Self.firstRowHunks, "New folder"),
            "a new folder was reported as having no changes"
        )
    }

    // MARK: - The Changes overview tab (Task 13)

    /// Every changed file, sorted by path, wearing the FILES tree's own
    /// letters — the two surfaces read from one mapping so they cannot
    /// disagree about what "M" means.
    func testChangesTabListsEveryChangedFileWithTheTreesLetters() {
        let pane = makePane()
        waitUntilReady(pane)
        pane.setGitStatus(GitStatus(root: dir, badges: ["src/b.swift": .untracked, "a.swift": .modified]))

        pane.openChanges()

        XCTAssertEqual(pane.model.tabs.map(\.kind), [.changes])
        XCTAssertTrue(
            pollUntilContains(pane.webHost, Self.changesSummary, "a.swift:M,src/b.swift:U"),
            "the changes list never rendered in path order with the tree's letters"
        )
    }

    /// A pane with no repository behind it says so rather than showing an
    /// empty list that reads as "no changes".
    func testChangesTabWithoutARepositorySaysSo() {
        let pane = makePane()
        waitUntilReady(pane)

        pane.openChanges()

        XCTAssertTrue(
            pollUntilContains(pane.webHost, "document.getElementById('message').textContent", "Not a git repository")
        )
    }

    /// The whole point of the overview: hunks arrive only when a row is
    /// opened, one `git diff` per file, against a real repository.
    func testChangesTabExpandsAFilesHunksLazily() throws {
        let repo = try makeGitRepository(committing: "a.swift", "let x = 1\n")
        try "let x = 1\nlet y = 2\n".write(
            to: repo.appendingPathComponent("a.swift"),
            atomically: true,
            encoding: .utf8
        )
        let pane = makePane()
        waitUntilReady(pane)
        pane.setGitStatus(GitStatus(root: repo, badges: ["a.swift": .modified]))
        pane.openChanges()
        XCTAssertTrue(pollUntilContains(pane.webHost, Self.changesSummary, "a.swift:M"))
        XCTAssertFalse(
            pollUntilContains(pane.webHost, Self.firstRowHunks, "let y", timeout: 1),
            "nothing is fetched until the row is opened"
        )

        run(pane.webHost, "document.querySelectorAll('#changes .file')[0].querySelector('.row').click()")

        XCTAssertTrue(
            pollUntilContains(pane.webHost, Self.firstRowHunks, "+let y = 2"),
            "the row never received its diff"
        )
    }

    /// The two ways out of the overview: "open file" opens the file, a double
    /// click opens its diff. Both route up — which pane they land in is the
    /// controller's rule, not this view's.
    func testChangesTabRoutesOpenFileAndOpenDiffUp() {
        let pane = makePane()
        waitUntilReady(pane)
        var openedFile: URL?
        var openedDiff: URL?
        pane.onOpenFileRequest = { openedFile = $0 }
        pane.onOpenDiffRequest = { openedDiff = $0 }
        pane.setGitStatus(GitStatus(root: dir, badges: ["a.swift": .modified]))
        pane.openChanges()
        XCTAssertTrue(pollUntilContains(pane.webHost, Self.changesSummary, "a.swift:M"))

        run(pane.webHost, "document.querySelectorAll('#changes .file')[0].querySelector('.open-file').click()")
        XCTAssertTrue(pollUntil { openedFile != nil })
        XCTAssertEqual(openedFile?.lastPathComponent, "a.swift")

        run(
            pane.webHost,
            "document.querySelectorAll('#changes .file')[0].querySelector('.row')"
                + ".dispatchEvent(new MouseEvent('dblclick'))"
        )
        XCTAssertTrue(pollUntil { openedDiff != nil })
        XCTAssertEqual(openedDiff?.lastPathComponent, "a.swift")
    }

    /// `path:badge` for every row, in DOM order.
    private static let changesSummary = """
        Array.from(document.querySelectorAll('#changes .file'))
            .map(f => f.dataset.path + ':' + f.querySelector('.badge').textContent).join(',')
        """

    private static let firstRowHunks =
        "document.querySelectorAll('#changes .file')[0].querySelector('pre').textContent"

    /// Fire-and-forget JS, waited on so the page has actually run it.
    private func run(_ view: EditorWebView, _ script: String) {
        let done = expectation(description: "script")
        view.webView.evaluateJavaScript(script) { _, _ in done.fulfill() }
        wait(for: [done], timeout: 10)
    }

    /// Spins the run loop until a Swift-side condition holds — the bridge
    /// answers on the main thread, so nothing else would ever let it in.
    private func pollUntil(timeout: TimeInterval = 10, _ satisfied: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if satisfied() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        return satisfied()
    }

    /// A throwaway repository of this test's own — never this repo's working
    /// tree, whose HEAD and index move under a running suite.
    private func makeGitRepository(committing name: String, _ contents: String) throws -> URL {
        let repo = dir.appendingPathComponent("repo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        func git(_ arguments: String...) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["git", "-C", repo.path] + arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { throw XCTSkip("git is not available on PATH") }
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw XCTSkip("git is not usable here") }
        }
        try git("init", "-q")
        try git("config", "user.email", "t@t")
        try git("config", "user.name", "t")
        try contents.write(to: repo.appendingPathComponent(name), atomically: true, encoding: .utf8)
        try git("add", ".")
        try git("commit", "-qm", "initial")
        return repo
    }

    /// The diff is computed asynchronously by the editor web worker and has no
    /// bridge event of its own, so it is polled. (`EditorWebViewTests` keeps
    /// its own copy of this: a shared one would be a test seam in the pane's
    /// public surface for no product reason.)
    private func pollUntilPositive(_ view: EditorWebView, _ script: String, timeout: TimeInterval = 20) -> Bool {
        poll(view, script, timeout: timeout) { ($0 as? NSNumber).map { $0.intValue > 0 } ?? false }
    }

    private func pollUntilContains(
        _ view: EditorWebView,
        _ script: String,
        _ needle: String,
        timeout: TimeInterval = 20
    ) -> Bool {
        poll(view, script, timeout: timeout) { ($0 as? String)?.contains(needle) ?? false }
    }

    private func poll(
        _ view: EditorWebView,
        _ script: String,
        timeout: TimeInterval,
        until satisfied: @escaping (Any?) -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            var answered = false
            let step = expectation(description: "poll")
            view.webView.evaluateJavaScript(script) { value, _ in
                answered = satisfied(value)
                step.fulfill()
            }
            wait(for: [step], timeout: 5)
            if answered { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return false
    }

    /// A preview open recycles the preview tab; the evicted file's Monaco
    /// model and bookkeeping must go with it.
    func testPreviewTabRecyclingReleasesTheEvictedFile() throws {
        let first = try write("a.swift", "one")
        let second = try write("b.swift", "two")
        let pane = makePane()
        pane.openFile(first, pinned: false)
        pane.openFile(second, pinned: false)
        XCTAssertEqual(pane.model.tabs.map(\.path), [second.path])
        XCTAssertFalse(pane.loadedPaths.contains(first.path))
        XCTAssertTrue(pane.loadedPaths.contains(second.path))
    }

    // MARK: - Final review round

    /// A file of the requested size that `EditorFileClass` still calls text:
    /// the sniff only reads the first 8 KB, so real text there and a sparse
    /// tail keeps the test fast without making the file binary.
    private func makeSparseTextFile(_ name: String, bytes: Int) throws -> URL {
        let url = dir.appendingPathComponent(name)
        let header = Data(String(repeating: "text line\n", count: 2_000).utf8)
        try header.write(to: url)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(bytes))
        try handle.close()
        return url
    }

    /// Final review, Critical (the save half). A tab that vanishes during the
    /// save must take nothing with it. `save`'s own identity guard already
    /// turns most of this window into `.failed`; the `.clean` arm behind it
    /// now re-resolves by identity too, so neither can reach the tab that took
    /// the captured slot.
    func testASaveWhoseTabVanishedTouchesNothingElse() throws {
        let doomed = try write("a.swift", "one")
        let bystander = try write("b.swift", "two")
        let pane = makePane()
        waitUntilReady(pane)
        pane.openFile(doomed, pinned: true)
        pane.openFile(bystander, pinned: true)
        makeDirty(pane, path: doomed.path, content: "edited-a")
        makeDirty(pane, path: bystander.path, content: "edited-b")

        // Answer Save for a.swift, then delete its tab out from under the
        // round trip. Slot 0 now holds b.swift, with unsaved work in it.
        pane.confirmSave = { _, decide in
            decide(.save)
            pane.modelForTesting { $0.close(at: 0) }
        }
        pane.requestCloseTab(at: 0)

        XCTAssertTrue(
            pollUntil(timeout: 15) { pane.model.tabs.map(\.path) == [bystander.path] },
            "the bystander must survive: \(pane.model.tabs.map(\.path))"
        )
        XCTAssertFalse(pollUntil(timeout: 2) { pane.model.tabs.isEmpty })
        XCTAssertTrue(pane.model.tabs[0].isDirty, "…with its unsaved edits intact")
    }

    /// The same rule on the bulk walk, which must also stay live: a tab that
    /// vanished is *resolved*, so the drain has to go on completing or the
    /// close or quit waiting on it hangs.
    func testTheDrainSkipsAVanishedTabWithoutClosingItsSuccessor() throws {
        let doomed = try write("a.swift", "one")
        let bystander = try write("b.swift", "two")
        let pane = makePane()
        waitUntilReady(pane)
        pane.openFile(doomed, pinned: true)
        pane.openFile(bystander, pinned: true)
        makeDirty(pane, path: doomed.path, content: "edited-a")

        var asked = 0
        pane.confirmSave = { _, decide in
            asked += 1
            if asked == 1 { pane.modelForTesting { $0.close(at: 0) } }
            decide(.discard)
        }
        let drained = expectation(description: "the walk finished")
        var proceeded: Bool?
        pane.closeAllTabsAfterConfirmation {
            proceeded = $0
            drained.fulfill()
        }
        wait(for: [drained], timeout: 20)

        XCTAssertEqual(proceeded, true)
        XCTAssertEqual(pane.model.tabs.map(\.path), [bystander.path], "the clean bystander is untouched")
    }

    /// Final review, Important. `maxEditableBytes` only decides read-only —
    /// the whole file was still read on the main thread and escaped into a JS
    /// literal, so a huge one froze the app. Refuse instead.
    func testAFileOverTheHardCapIsRefusedRatherThanRead() throws {
        let url = try makeSparseTextFile("huge.txt", bytes: EditorFileClass.maxReadableBytes + 1)
        let pane = makePane()
        waitUntilReady(pane)

        pane.openFile(url, pinned: true)

        XCTAssertEqual(pane.model.tabs.map(\.path), [url.path], "the tab opens…")
        XCTAssertFalse(pane.loadedPaths.contains(url.path), "…but Monaco is never handed the file")
        XCTAssertTrue(
            pollUntilContains(pane.webHost, "document.getElementById('message').textContent", "too large to open"),
            "and it says so"
        )
    }

    /// Spec §7's read-only banner for the band between the two caps.
    func testAReadOnlyFileWearsABanner() throws {
        let url = try makeSparseTextFile("big.txt", bytes: EditorFileClass.maxEditableBytes + 1024)
        let pane = makePane()
        waitUntilReady(pane)

        pane.openFile(url, pinned: true)

        XCTAssertTrue(pane.loadedPaths.contains(url.path), "it opens — just not for editing")
        XCTAssertTrue(
            pollUntilContains(pane.webHost, "document.getElementById('banner').textContent", "Read-only"),
            "and says why"
        )
    }

    /// A normal file must not wear one.
    func testAnEditableFileHasNoBanner() throws {
        let url = try write("a.swift", "let x = 1")
        let pane = makePane()
        waitUntilReady(pane)
        pane.openFile(url, pinned: true)

        XCTAssertTrue(
            pollUntilContains(pane.webHost, "document.getElementById('banner').style.display", "none")
        )
    }

    // MARK: - Task 15: external changes

    /// Reads a model's text back, polling. The external-change reload is
    /// asynchronous — it asks the page whether the buffer is clean before it
    /// rebases — so one `requestContent` can be dispatched *before* the
    /// `setContent` it is meant to observe.
    private func pollUntilContent(_ pane: EditorPaneView, path: String, equals expected: String) -> Bool {
        var latest: String?
        let matched = pollUntil(timeout: 15) {
            let read = expectation(description: "content")
            pane.webHost.requestContent(path: path) { content, _ in
                latest = content
                read.fulfill()
            }
            wait(for: [read], timeout: 10)
            return latest == expected
        }
        if !matched { XCTFail("expected \(expected), last read \(latest ?? "nil")") }
        return matched
    }


    /// Spec §2: a clean buffer whose file moved under it reloads silently.
    func testCleanBufferSilentlyReloadsOnExternalChange() throws {
        let url = try write("a.swift", "v1")
        let pane = makePane()
        waitUntilReady(pane)
        pane.openFile(url, pinned: true)
        try "v2".write(to: url, atomically: true, encoding: .utf8)
        // mtime granularity is a second on some filesystems; force a date that
        // is unambiguously newer rather than racing the clock.
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(5)],
            ofItemAtPath: url.path
        )
        pane.confirmConflict = { _, _ in XCTFail("a clean buffer must never prompt") }

        pane.checkExternalChanges()

        XCTAssertTrue(pollUntilContent(pane, path: url.path, equals: "v2"))
    }

    /// A dirty buffer is never overwritten without being asked about, and
    /// "Keep Mine" leaves the edits exactly where they were.
    func testDirtyBufferConflictPromptsAndKeepMineKeepsTheEdits() throws {
        let url = try write("a.swift", "v1")
        let pane = makePane()
        waitUntilReady(pane)
        pane.openFile(url, pinned: true)
        makeDirty(pane, path: url.path, content: "mine")
        try "v2".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(5)],
            ofItemAtPath: url.path
        )
        var asked: [String] = []
        pane.confirmConflict = { name, decide in
            asked.append(name)
            decide(false)
        }

        pane.checkExternalChanges()

        XCTAssertTrue(pollUntil(timeout: 10) { asked.count == 1 })
        XCTAssertEqual(asked, ["a.swift"])
        XCTAssertTrue(pane.model.tabs[0].isDirty)

        // Read *after* the prompt callback has returned, so anything it wrongly
        // dispatched (a `setContent` reload) is already queued ahead of this
        // read and would show up in it. Polling for "mine" would not: the
        // buffer already says "mine" on the first iteration, so it passes
        // whatever happens next.
        let kept = expectation(description: "kept")
        pane.webHost.requestContent(path: url.path) { content, _ in
            XCTAssertEqual(content, "mine")
            kept.fulfill()
        }
        wait(for: [kept], timeout: 10)
        // The strong half: a reload would have rebased the page's saved
        // version, so only the Keep Mine path leaves the buffer *unclean*.
        let stillDirty = expectation(description: "still dirty to the page")
        pane.webHost.requestIsClean(path: url.path) { clean in
            XCTAssertFalse(clean, "Keep Mine must not rebase the buffer")
            stillDirty.fulfill()
        }
        wait(for: [stillDirty], timeout: 10)

        // The recorded mtime advanced with the prompt, so the *same* disk
        // change must not ask a second time on the next focus.
        pane.checkExternalChanges()
        XCTAssertFalse(pollUntil(timeout: 2) { asked.count > 1 })
        XCTAssertEqual(asked, ["a.swift"])
    }

    /// "Take Disk" is the other half of the same prompt: the buffer becomes
    /// what is on disk, and the tab goes clean because the page rebased.
    func testConflictTakeDiskReplacesTheBuffer() throws {
        let url = try write("a.swift", "v1")
        let pane = makePane()
        waitUntilReady(pane)
        pane.openFile(url, pinned: true)
        makeDirty(pane, path: url.path, content: "mine")
        try "v2".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(5)],
            ofItemAtPath: url.path
        )
        pane.confirmConflict = { _, decide in decide(true) }

        pane.checkExternalChanges()

        XCTAssertTrue(pollUntilContent(pane, path: url.path, equals: "v2"))
        XCTAssertTrue(
            pollUntil { pane.model.tabs[0].isDirty == false },
            "the page rebased, so the dirty flag must come back false"
        )
        XCTAssertNil(pane.dirtySnapshots[url.path])
    }

    /// A file deleted under the editor keeps its buffer and says so in the
    /// strip; saving recreates the file and clears the mark.
    func testDeletedFileIsMarkedKeepsItsBufferAndSaveRecreatesIt() throws {
        let url = try write("a.swift", "v1")
        let pane = makePane()
        waitUntilReady(pane)
        pane.openFile(url, pinned: true)
        makeDirty(pane, path: url.path, content: "mine")
        try FileManager.default.removeItem(at: url)
        pane.confirmConflict = { _, _ in XCTFail("a deletion is not a keep-mine/take-disk question") }

        pane.checkExternalChanges()

        XCTAssertTrue(pane.deletedPaths.contains(url.path))
        XCTAssertEqual(pane.strip.itemTitles, ["a.swift (deleted)"])
        XCTAssertTrue(pane.model.tabs[0].isDirty, "the buffer is the only copy left")

        let saved = expectation(description: "saved")
        pane.saveActiveTab { XCTAssertTrue($0); saved.fulfill() }
        wait(for: [saved], timeout: 10)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "mine")

        pane.checkExternalChanges()
        XCTAssertFalse(pane.deletedPaths.contains(url.path))
        XCTAssertEqual(pane.strip.itemTitles, ["a.swift"])
    }

    // MARK: - Task 15: renderer-crash restore

    /// Spec §7: unsaved edits survive a WKWebView renderer death. The page is
    /// rebuilt from scratch, so the buffer comes back from its last snapshot.
    func testCrashRestoreReplaysDirtySnapshot() throws {
        let url = try write("a.swift", "v1")
        let pane = makePane()
        waitUntilReady(pane)
        pane.openFile(url, pinned: true)
        pane.injectSnapshotForTesting(path: url.path, content: "edited-but-unsaved")
        pane.modelForTesting { $0.setDirty(true, at: 0) }

        pane.simulateRendererCrashForTesting()
        XCTAssertFalse(pane.webHost.isReady, "the crash tears the bridge down")
        waitUntilReady(pane)

        let restored = expectation(description: "restored")
        pane.webHost.requestContent(path: url.path) { content, _ in
            XCTAssertEqual(content, "edited-but-unsaved")
            restored.fulfill()
        }
        wait(for: [restored], timeout: 15)
        XCTAssertTrue(pane.model.tabs[0].isDirty)
    }

    /// The other half: a *clean* tab comes back from disk, never from a
    /// snapshot left over from before its last save.
    func testCrashRestoreReloadsACleanTabFromDisk() throws {
        let url = try write("a.swift", "v1")
        let pane = makePane()
        waitUntilReady(pane)
        pane.openFile(url, pinned: true)
        pane.injectSnapshotForTesting(path: url.path, content: "stale")
        try "v2".write(to: url, atomically: true, encoding: .utf8)

        pane.simulateRendererCrashForTesting()
        waitUntilReady(pane)

        let restored = expectation(description: "restored")
        pane.webHost.requestContent(path: url.path) { content, _ in
            XCTAssertEqual(content, "v2")
            restored.fulfill()
        }
        wait(for: [restored], timeout: 15)
        XCTAssertFalse(pane.model.tabs[0].isDirty)
    }

    /// The nastiest ordering of the two hardening rules: the file vanishes
    /// *and* the renderer dies, with unsaved work in the buffer. The snapshot
    /// is the only copy left, so it has to come back even though the file
    /// cannot be classified any more.
    func testCrashRestoreKeepsADirtyBufferWhoseFileVanished() throws {
        let url = try write("a.swift", "v1")
        let pane = makePane()
        waitUntilReady(pane)
        pane.openFile(url, pinned: true)
        pane.injectSnapshotForTesting(path: url.path, content: "only-copy")
        pane.modelForTesting { $0.setDirty(true, at: 0) }
        try FileManager.default.removeItem(at: url)

        pane.simulateRendererCrashForTesting()
        waitUntilReady(pane)

        let restored = expectation(description: "restored")
        pane.webHost.requestContent(path: url.path) { content, _ in
            XCTAssertEqual(content, "only-copy")
            restored.fulfill()
        }
        wait(for: [restored], timeout: 15)
        XCTAssertTrue(pane.model.tabs[0].isDirty)
        XCTAssertTrue(pane.loadedPaths.contains(url.path))
    }

    /// Fix round 1, Important. Swift's `isDirty` is only written by the
    /// *posted* `dirtyChanged`, so a keystroke whose message is still in
    /// flight reads as clean — and the silent-reload branch would then rebase
    /// over it with no prompt. The check has to ask the page.
    ///
    /// Staged exactly that way: type, then call `checkExternalChanges()`
    /// synchronously, before the message can possibly have arrived.
    func testAnEditWhoseDirtyMessageIsStillInFlightIsNotOverwritten() throws {
        let url = try write("a.swift", "v1")
        let pane = makePane()
        waitUntilReady(pane)
        pane.openFile(url, pinned: true)
        try "v2".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(5)],
            ofItemAtPath: url.path
        )

        pane.webHost.setContentForTesting(path: url.path, content: "in-flight")
        XCTAssertFalse(pane.model.tabs[0].isDirty, "the posted message cannot have landed yet")

        let asked = expectation(description: "asked about the conflict")
        pane.confirmConflict = { _, decide in
            asked.fulfill()
            decide(false)
        }
        pane.checkExternalChanges()
        wait(for: [asked], timeout: 10)

        let kept = expectation(description: "kept")
        pane.webHost.requestContent(path: url.path) { content, _ in
            XCTAssertEqual(content, "in-flight")
            kept.fulfill()
        }
        wait(for: [kept], timeout: 10)
    }

    /// Fix round 1, Important. The snapshot is the only copy of an unsaved
    /// edit once the renderer is gone, so it comes back whatever the file has
    /// since become — here, a binary blob that `EditorFileClass` would refuse.
    func testCrashRestoreReplaysASnapshotEvenIfTheFileTurnedBinary() throws {
        let url = try write("a.swift", "v1")
        let pane = makePane()
        waitUntilReady(pane)
        pane.openFile(url, pinned: true)
        pane.injectSnapshotForTesting(path: url.path, content: "only-copy")
        pane.modelForTesting { $0.setDirty(true, at: 0) }
        try Data([0x00, 0x01, 0x00, 0x02]).write(to: url)

        pane.simulateRendererCrashForTesting()
        waitUntilReady(pane)

        let restored = expectation(description: "restored")
        pane.webHost.requestContent(path: url.path) { content, _ in
            XCTAssertEqual(content, "only-copy")
            restored.fulfill()
        }
        wait(for: [restored], timeout: 15)
        XCTAssertTrue(pane.model.tabs[0].isDirty)
    }

    /// Fix round 1, Minor. Nothing unsaved survives that crash, so the flag
    /// that claims otherwise has to go: a "Save" prompt on it could only ask
    /// `getContent` for a model that no longer exists, and fail.
    func testCrashRestoreClearsADirtyFlagItCannotHonour() throws {
        let url = try write("a.swift", "v1")
        let pane = makePane()
        waitUntilReady(pane)
        pane.openFile(url, pinned: true)
        pane.modelForTesting { $0.setDirty(true, at: 0) }   // dirty, and no snapshot
        try FileManager.default.removeItem(at: url)

        pane.simulateRendererCrashForTesting()
        waitUntilReady(pane)

        XCTAssertFalse(pane.model.tabs[0].isDirty, "there is nothing left for the flag to protect")
        XCTAssertFalse(pane.loadedPaths.contains(url.path))
        XCTAssertTrue(pane.deletedPaths.contains(url.path))
        XCTAssertFalse(pane.hasDirtyTabs, "…so the pane closes without a prompt it could not honour")
    }

    /// Fix round 1, Minor. The check is wired to `focus()`, not merely
    /// callable by a test.
    func testFocusItselfChecksForExternalChanges() throws {
        let url = try write("a.swift", "v1")
        let pane = makePane()
        waitUntilReady(pane)
        pane.openFile(url, pinned: true)
        try "v2".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(5)],
            ofItemAtPath: url.path
        )

        pane.focus()

        XCTAssertTrue(pollUntilContent(pane, path: url.path, equals: "v2"))
    }

    /// Fix round 2, Important. The gate that decides whether to prompt **at
    /// all** read the same lagging flag: a keystroke whose `dirtyChanged` post
    /// has not landed reads as clean, and the tab was closed over it with no
    /// prompt. Staged by typing and closing in the same run-loop turn.
    func testClosingATabWhoseDirtyMessageIsStillInFlightStillAsks() throws {
        let url = try write("a.swift", "v1")
        let pane = makePane()
        waitUntilReady(pane)
        pane.openFile(url, pinned: true)

        pane.webHost.setContentForTesting(path: url.path, content: "in-flight")
        XCTAssertFalse(pane.model.tabs[0].isDirty, "the posted message cannot have landed yet")

        let asked = expectation(description: "asked before closing")
        pane.confirmSave = { _, decide in
            asked.fulfill()
            decide(.cancel)
        }
        pane.requestCloseTab(at: 0)
        wait(for: [asked], timeout: 10)

        XCTAssertEqual(pane.model.tabs.count, 1, "cancel kept the tab and the edit")
    }

    /// The other side of that gate: a tab with nothing to lose still closes,
    /// and never asks.
    func testClosingACleanTabStillNeverAsks() throws {
        let url = try write("a.swift", "v1")
        let pane = makePane()
        waitUntilReady(pane)
        pane.openFile(url, pinned: true)
        pane.confirmSave = { _, _ in XCTFail("nothing is unsaved") }

        pane.requestCloseTab(at: 0)

        XCTAssertTrue(pollUntil(timeout: 10) { pane.model.tabs.isEmpty })
    }

    /// Fix round 2, Minor. A second disk change while a conflict alert is up
    /// must not stack a nested alert behind it.
    func testASecondExternalChangeDoesNotStackAConflictAlert() throws {
        let url = try write("a.swift", "v1")
        let pane = makePane()
        waitUntilReady(pane)
        pane.openFile(url, pinned: true)
        makeDirty(pane, path: url.path, content: "mine")

        var open = 0
        var peak = 0
        var release: ((Bool) -> Void)?
        pane.confirmConflict = { _, decide in
            open += 1
            peak = max(peak, open)
            release = decide   // held open, exactly as a modal alert holds
        }

        try "v2".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(5)],
            ofItemAtPath: url.path
        )
        pane.checkExternalChanges()
        XCTAssertTrue(pollUntil(timeout: 10) { open == 1 })

        // A second change, and focus comes back while the first alert is still up.
        try "v3".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(10)],
            ofItemAtPath: url.path
        )
        pane.checkExternalChanges()
        pane.focus()
        XCTAssertFalse(pollUntil(timeout: 2) { open > 1 })
        XCTAssertEqual(peak, 1, "one conflict alert at a time")

        // And the change that was skipped is still pending, not lost.
        open = 0
        release?(false)
        pane.checkExternalChanges()
        XCTAssertTrue(pollUntil(timeout: 10) { open == 1 }, "the second change is asked about later")
        release?(false)
    }

    /// Fix round 2. `requestIsClean` answers "not clean" when the bridge is
    /// not ready — deliberately, since unknown must never read as safe to
    /// discard. Routing the *reconcile* through it unfiltered would turn that
    /// into a save prompt for a buffer nobody has touched, on every close and
    /// every drag in a pane's first seconds. With no live page, Swift's flag
    /// is the authority, not a lagging copy of one.
    func testClosingATabBeforeTheBridgeIsUpNeverAsks() throws {
        let url = try write("a.swift", "v1")
        let pane = makePane()
        pane.openFile(url, pinned: true)
        XCTAssertFalse(pane.webHost.isReady, "this test is about the pre-ready window")
        pane.confirmSave = { _, _ in XCTFail("nothing has been typed — there is nothing to ask about") }

        pane.requestCloseTab(at: 0)

        XCTAssertTrue(pane.model.tabs.isEmpty)
    }

    /// Fix round 3, Important 2. A *wedged* renderer never answers
    /// `evaluateJavaScript` — unlike a crashed one, which errors and lets the
    /// completion run. Without a deadline the close simply never happens, and
    /// on the window and quit paths that means an app that cannot be quit.
    /// The safe fallback is "treat it as dirty and ask".
    func testAWedgedRendererStillPromptsRatherThanHangingTheClose() throws {
        let url = try write("a.swift", "v1")
        let pane = makePane()
        waitUntilReady(pane)
        pane.openFile(url, pinned: true)
        pane.webHost.stallsRendererForTesting = true

        let asked = expectation(description: "asked rather than waited forever")
        pane.confirmSave = { _, decide in
            asked.fulfill()
            decide(.cancel)
        }
        pane.requestCloseTab(at: 0)

        wait(for: [asked], timeout: EditorWebView.replyTimeout + 8)
        XCTAssertEqual(pane.model.tabs.count, 1, "cancel kept it, and nothing hung")
    }

    /// The same deadline on the walk the window and quit paths use.
    func testAWedgedRendererStillCompletesTheDirtyWalk() throws {
        let url = try write("a.swift", "v1")
        let pane = makePane()
        waitUntilReady(pane)
        pane.openFile(url, pinned: true)
        pane.webHost.stallsRendererForTesting = true
        pane.confirmSave = { _, decide in decide(.discard) }

        let drained = expectation(description: "the walk finished")
        var proceeded: Bool?
        pane.closeAllTabsAfterConfirmation {
            proceeded = $0
            drained.fulfill()
        }

        wait(for: [drained], timeout: EditorWebView.replyTimeout + 8)
        XCTAssertEqual(proceeded, true)
        XCTAssertTrue(pane.model.tabs.isEmpty)
    }

    /// Fix round 3, Important 3. Both `.discard` arms close by identity: two
    /// closes can overlap inside the reconcile round trip, and closing by a
    /// captured index would discard somebody else's buffer unprompted.
    func testDiscardClosesTheTabItAskedAboutEvenIfTheStripMoved() throws {
        let first = try write("a.swift", "one")
        let second = try write("b.swift", "two")
        let pane = makePane()
        waitUntilReady(pane)
        pane.openFile(first, pinned: true)
        pane.openFile(second, pinned: true)
        makeDirty(pane, path: second.path, content: "edited")
        XCTAssertEqual(pane.model.tabs.map(\.path), [first.path, second.path])

        // The prompt for b.swift (index 1) arrives with a.swift already gone,
        // so the captured index now points at b.swift's *successor* slot.
        pane.confirmSave = { _, decide in
            pane.modelForTesting { $0.close(at: 0) }
            decide(.discard)
        }
        pane.requestCloseTab(at: 1)

        XCTAssertTrue(pollUntil(timeout: 10) { pane.model.tabs.isEmpty })
    }

    /// Fix round 3, Minor. The entry guard cannot help when **one** pass finds
    /// two changed dirty files: both resolves are dispatched before either
    /// alert goes up. The second must back its recorded date out and wait for
    /// the next focus, not stack a nested alert inside the first's `runModal`.
    func testOnePassOverTwoChangedFilesDoesNotStackAlerts() throws {
        let first = try write("a.swift", "v1")
        let second = try write("b.swift", "v1")
        let pane = makePane()
        waitUntilReady(pane)
        pane.openFile(first, pinned: true)
        pane.openFile(second, pinned: true)
        makeDirty(pane, path: first.path, content: "mine-a")
        makeDirty(pane, path: second.path, content: "mine-b")

        var open = 0
        var peak = 0
        var names: [String] = []
        var release: ((Bool) -> Void)?
        pane.confirmConflict = { name, decide in
            open += 1
            peak = max(peak, open)
            names.append(name)
            release = decide
        }

        for url in [first, second] {
            try "v2".write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(5)],
                ofItemAtPath: url.path
            )
        }
        pane.checkExternalChanges()

        XCTAssertTrue(pollUntil(timeout: 10) { open == 1 })
        XCTAssertFalse(pollUntil(timeout: 2) { open > 1 })
        XCTAssertEqual(peak, 1, "one conflict alert at a time")

        // The file that was skipped is still pending, not lost.
        let first_name = names[0]
        release?(false)
        pane.checkExternalChanges()
        XCTAssertTrue(pollUntil(timeout: 10) { names.count == 2 })
        XCTAssertNotEqual(names[1], first_name, "the other file gets its turn")
        release?(false)
    }

    // MARK: - Task 15: the save-acknowledgement window

    /// `save`'s `true` means "the bytes reached disk", not "the buffer is
    /// clean": a keystroke landing inside the `getContent` -> write round trip
    /// is (correctly) refused by the version-scoped `markSaved` and leaves the
    /// buffer dirty. Closing the tab on that `true` alone would discard the
    /// keystroke with no prompt — which the modal alert does *not* prevent,
    /// because `runModal` returns before the async round trip even starts.
    func testDrainWaitsForTheSaveToBeAcknowledgedClean() throws {
        let url = try write("a.swift", "v1")
        let pane = makePane()
        waitUntilReady(pane)
        pane.openFile(url, pinned: true)
        makeDirty(pane, path: url.path, content: "edit-1")

        var prompts = 0
        pane.confirmSave = { _, decide in
            prompts += 1
            decide(.save)
            // `evaluateJavaScript` calls run in the page in order, so this
            // lands *after* the `getContent` `decide(.save)` just issued and
            // *before* Swift's write comes back — exactly the window.
            if prompts == 1 {
                pane.webHost.setContentForTesting(path: url.path, content: "typed-during-save")
            }
        }

        let drained = expectation(description: "drained")
        var proceeded: Bool?
        pane.closeAllTabsAfterConfirmation {
            proceeded = $0
            drained.fulfill()
        }
        wait(for: [drained], timeout: 30)

        XCTAssertEqual(proceeded, true)
        XCTAssertEqual(prompts, 2, "the edit that landed inside the write is asked about again")
        XCTAssertTrue(pane.model.tabs.isEmpty)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "typed-during-save")
    }

    /// The same window, on the single-tab close path.
    func testClosingOneTabWaitsForTheSaveToBeAcknowledgedClean() throws {
        let url = try write("a.swift", "v1")
        let pane = makePane()
        waitUntilReady(pane)
        pane.openFile(url, pinned: true)
        makeDirty(pane, path: url.path, content: "edit-1")

        var prompts = 0
        pane.confirmSave = { _, decide in
            prompts += 1
            decide(.save)
            if prompts == 1 {
                pane.webHost.setContentForTesting(path: url.path, content: "typed-during-save")
            }
        }

        pane.requestCloseTab(at: 0)

        XCTAssertTrue(pollUntil(timeout: 30) { pane.model.tabs.isEmpty })
        XCTAssertEqual(prompts, 2)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "typed-during-save")
    }
}
