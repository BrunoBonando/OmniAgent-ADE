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

    /// Drives the bridge the way a keystroke would and waits for the tab to
    /// land dirty.
    private func makeDirty(_ pane: EditorPaneView, path: String, content: String) {
        let dirty = expectation(description: "dirty")
        dirty.assertForOverFulfill = false
        pane.onStateChange = { _, _ in
            if pane.model.tabs.first(where: { $0.path == path })?.isDirty == true { dirty.fulfill() }
        }
        pane.webHost.setContentForTesting(path: path, content: content)
        wait(for: [dirty], timeout: 10)
        pane.onStateChange = nil
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
}
