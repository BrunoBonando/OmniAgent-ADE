import XCTest
@testable import OmniAgent

/// Task 10: `.editor` becomes a pane kind a user can actually create.
///
/// Every assertion here has a browser-pane twin in
/// `WorkspaceWindowControllerTests` — the editor pane is deliberately the
/// browser pane's shape (no PTY, `startSession: false`, its own native-only
/// settings row) and these tests exist to keep it that shape.
final class EditorPaneIntegrationTests: XCTestCase {
    // MARK: - Creation

    /// ⇧⌘E's core promise: a pane that is an editor, in the focused pane's
    /// session, with no daemon session behind it.
    func testNewEditorAddsANonTerminalPaneWithARealEditorSurface() throws {
        let controller = makeController()
        defer { controller.close() }
        controller.showWindow(nil)
        var ensured: [String] = []
        controller.sessionEnsurer = { ensured.append($0) }
        let workspace = controller.workspaceView
        let group = try XCTUnwrap(workspace.descriptor(for: "native-terminal")?.group)

        XCTAssertTrue(controller.newEditor(in: nil))

        let editorID = try XCTUnwrap(workspace.focusedPaneID)
        let descriptor = try XCTUnwrap(workspace.descriptor(for: editorID))
        XCTAssertEqual(descriptor.kind, .editor)
        XCTAssertEqual(descriptor.group, group, "the editor joins the focused pane's session")
        XCTAssertEqual(workspace.terminalPaneCount, 1, "just the bootstrap terminal")
        XCTAssertNotNil(workspace.editorPane(for: editorID), "and it is a real EditorPaneView")
        XCTAssertTrue(ensured.isEmpty, "an editor pane never reaches ensureSession")
    }

    /// The grid geometry is the only bound — an editor costs no PTY — and the
    /// menu item greys out on exactly that bound.
    func testEditorPanesStopAtTheGridCapAndTheMenuItemSaysSo() {
        let controller = makeController()
        defer { controller.close() }
        controller.showWindow(nil)
        let workspace = controller.workspaceView

        while workspace.paneIDs.count < PaneGrid.maxPanes {
            XCTAssertTrue(controller.newEditor(in: nil))
        }
        XCTAssertFalse(controller.newEditor(in: nil), "the grid geometry is the only bound")

        let probe = NSMenuItem(
            title: "New Editor Pane",
            action: #selector(WorkspaceWindowController.newEditorPane(_:)),
            keyEquivalent: ""
        )
        XCTAssertFalse(controller.validateMenuItem(probe), "and the menu item says so")
    }

    // MARK: - Persistence

    /// Tab mutations reach the descriptor, and the descriptor reaches the
    /// `editor_panes_native` row — the editor's twin of the browser's
    /// `onURLChange` -> `updateDescriptor` -> `onPanesChanged` chain.
    func testEditorStateFlowsToTheDescriptorAndItsOwnSettingsRow() throws {
        var written: [String: String] = [:]
        let controller = makeController()
        defer { controller.close() }
        controller.settingsWriter = { key, value in written[key] = value }
        controller.showWindow(nil)
        controller.applyRestoredEditorPanes([])

        XCTAssertTrue(controller.newEditor(in: nil))
        let workspace = controller.workspaceView
        let editorID = try XCTUnwrap(workspace.focusedPaneID)
        let pane = try XCTUnwrap(workspace.editorPane(for: editorID))

        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).swift")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        pane.openFile(file, pinned: true)

        XCTAssertEqual(workspace.descriptor(for: editorID)?.editorTabs.map(\.path), [file.path])
        let row = try XCTUnwrap(written[SettingsKey.editorPanes])
        XCTAssertTrue(row.contains(file.lastPathComponent), "…and it is in the persisted row: \(row)")
    }

    /// The shared-row invariant: an editor pane writes its own row and never
    /// changes `layout`, which the web build rewrites without these fields.
    func testEditorPanesNeverTouchTheSharedLayoutRow() {
        let controller = makeEmptyController()
        defer { controller.close() }
        var writes: [(String, String)] = []
        controller.settingsWriter = { writes.append(($0, $1)) }
        controller.showWindow(nil)

        // Arm both write gates the way a real launch would, once both rows
        // have actually been read.
        controller.applyRestoredPanes([])
        controller.applyRestoredEditorPanes([])
        let layoutBefore = writes.last { $0.0 == SettingsKey.layout }?.1

        XCTAssertTrue(controller.newEditor(in: nil))

        XCTAssertTrue(
            writes.contains { $0.0 == SettingsKey.editorPanes },
            "adding an editor pane persists its own row"
        )
        XCTAssertEqual(
            writes.last { $0.0 == SettingsKey.layout }?.1,
            layoutBefore,
            "an editor pane must never change the shared layout row"
        )

        let editorWritesAfterAdd = writes.filter { $0.0 == SettingsKey.editorPanes }.count
        controller.closePane(nil)

        XCTAssertGreaterThan(
            writes.filter { $0.0 == SettingsKey.editorPanes }.count,
            editorWritesAfterAdd,
            "closing an editor pane persists the row too"
        )
        XCTAssertEqual(
            writes.last { $0.0 == SettingsKey.layout }?.1,
            layoutBefore,
            "closing an editor pane must not touch the shared layout row either"
        )
    }

    /// The write gate: a pane opened before the row has been read must not
    /// write over a row nobody has looked at yet.
    func testWriteGateStaysShutUntilTheRowHasBeenRead() {
        var written: [String: String] = [:]
        let controller = makeController()
        defer { controller.close() }
        controller.settingsWriter = { key, value in written[key] = value }
        controller.showWindow(nil)

        XCTAssertTrue(controller.newEditor(in: nil))

        XCTAssertNil(written[SettingsKey.editorPanes], "no read, no write")
    }

    /// The restore path: panes come back from their own row, keep their tabs,
    /// and never reach the daemon.
    func testRestoreRebuildsPanesAndNeverTouchesTheDaemon() throws {
        let controller = makeEmptyController()
        defer { controller.close() }
        controller.showWindow(nil)
        var ensured: [String] = []
        controller.sessionEnsurer = { ensured.append($0) }

        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).swift")
        try "restored".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }

        controller.applyRestoredEditorPanes([
            PersistedEditorPane(
                tabs: [PersistedEditorTab(path: file.path, kind: "file", pinned: true)],
                active: 0,
                group: "g1",
                groupLabel: "Session 1"
            ),
        ])

        let workspace = controller.workspaceView
        let editors = workspace.allPaneIDs.filter { workspace.descriptor(for: $0)?.kind == .editor }
        XCTAssertEqual(editors.count, 1)
        let descriptor = try XCTUnwrap(workspace.descriptor(for: try XCTUnwrap(editors.first)))
        XCTAssertEqual(descriptor.group, "g1")
        XCTAssertEqual(descriptor.editorTabs.map(\.path), [file.path])
        XCTAssertNotNil(workspace.editorPane(for: descriptor.sessionID))
        XCTAssertTrue(ensured.isEmpty, "a restored editor pane never reaches ensureSession")
    }

    /// A restore is not a focus change: the browser step has already put focus
    /// back where the user left it by the time this runs, and `addPane`
    /// focuses everything it adds.
    func testRestoringEditorPanesLeavesFocusWhereItWas() throws {
        let controller = makeController()
        defer { controller.close() }
        controller.showWindow(nil)

        controller.applyRestoredEditorPanes([
            PersistedEditorPane(tabs: [], active: 0, group: nil, groupLabel: nil),
        ])

        XCTAssertEqual(controller.workspaceView.focusedPaneID, "native-terminal")
    }

    // MARK: - Entry points

    func testPaletteOffersNewEditorPaneAndTheControllerRunsIt() throws {
        let commands = CommandPaletteModel.build(
            panes: [],
            paneOrder: [],
            focusedPaneID: nil,
            unreadNotifications: 0
        )
        let row = try XCTUnwrap(commands.first { $0.action == .newEditorPane })
        XCTAssertEqual(row.id, "new-editor")
        XCTAssertEqual(row.title, "New editor pane")
        XCTAssertEqual(row.detail, "⇧⌘E")

        let controller = makeController()
        defer { controller.close() }
        controller.showWindow(nil)

        controller.run(.newEditorPane)

        let workspace = controller.workspaceView
        XCTAssertEqual(
            workspace.allPaneIDs.filter { workspace.descriptor(for: $0)?.kind == .editor }.count,
            1
        )
    }

    /// The hole tile's third dock button and the sidebar's "New editor" row
    /// both reach the same method the menu item does.
    func testTheHoleTileAndTheSidebarRowBothOpenAnEditorPane() throws {
        let controller = makeController()
        defer { controller.close() }
        controller.showWindow(nil)
        let workspace = controller.workspaceView

        try XCTUnwrap(workspace.onRequestNewEditorPane)()
        try XCTUnwrap(controller.shellSidebar.onNewEditor)()

        XCTAssertEqual(
            workspace.allPaneIDs.filter { workspace.descriptor(for: $0)?.kind == .editor }.count,
            2,
            "the hole tile and the sidebar row each opened one"
        )
    }

    func testTheEditorPaneIsOnTheFileMenuAndTheToolbar() throws {
        ApplicationMenus.install()
        let file = try XCTUnwrap(NSApp.mainMenu?.item(withTitle: "File")?.submenu)
        let item = try XCTUnwrap(file.item(withTitle: "New Editor Pane"))
        XCTAssertEqual(item.action, #selector(WorkspaceWindowController.newEditorPane(_:)))
        XCTAssertEqual(item.keyEquivalent, "e")
        XCTAssertEqual(item.keyEquivalentModifierMask, [.command, .shift], "⇧⌘E")

        let controller = makeController()
        defer { controller.close() }
        let toolbar = try XCTUnwrap(controller.window?.toolbar)
        XCTAssertTrue(
            controller.toolbarDefaultItemIdentifiers(toolbar)
                .contains(WorkspaceWindowController.ToolbarItem.newEditor)
        )
        let button = try XCTUnwrap(
            controller.toolbar(
                toolbar,
                itemForItemIdentifier: WorkspaceWindowController.ToolbarItem.newEditor,
                willBeInsertedIntoToolbar: true
            )
        )
        XCTAssertEqual(button.action, #selector(WorkspaceWindowController.newEditorPane(_:)))
        XCTAssertNil(button.target, "it travels the responder chain, like every other item")
    }

    // MARK: - Opening from the FILES tree (Task 11)

    /// The cold-start case: nothing is open, a single click has to conjure the
    /// pane as well as the tab, and the tab is a *preview*.
    func testOpenFileCreatesAPaneAndAPreviewTab() throws {
        let controller = makeController()
        defer { controller.close() }
        controller.showWindow(nil)
        let file = try makeTempFile("a.swift", "x")

        controller.openFileInEditor(file, pinned: false)

        let workspace = controller.workspaceView
        let editors = workspace.allPaneIDs.filter { workspace.descriptor(for: $0)?.kind == .editor }
        XCTAssertEqual(editors.count, 1)
        let pane = try XCTUnwrap(workspace.editorPane(for: editors[0]))
        XCTAssertEqual(pane.model.tabs.map(\.path), [file.path])
        XCTAssertEqual(pane.model.tabs.map(\.isPinned), [false], "single click previews")
    }

    /// VS Code's preview slot: the second single click lands in the same pane
    /// and recycles the same tab rather than piling up.
    func testSecondOpenReusesTheSamePaneAndPreviewTab() throws {
        let controller = makeController()
        defer { controller.close() }
        controller.showWindow(nil)

        controller.openFileInEditor(try makeTempFile("a.swift", "x"), pinned: false)
        let second = try makeTempFile("b.swift", "y")
        controller.openFileInEditor(second, pinned: false)

        let workspace = controller.workspaceView
        let editors = workspace.allPaneIDs.filter { workspace.descriptor(for: $0)?.kind == .editor }
        XCTAssertEqual(editors.count, 1, "no second pane appeared")
        let pane = try XCTUnwrap(workspace.editorPane(for: editors[0]))
        XCTAssertEqual(pane.model.tabs.map(\.path), [second.path], "the preview slot was recycled")
    }

    /// A double click pins, and the pinned tab is no longer the recycling
    /// slot — the next single click opens beside it.
    func testDoubleClickPinsAndTheNextPreviewOpensBesideIt() throws {
        let controller = makeController()
        defer { controller.close() }
        controller.showWindow(nil)
        let pinned = try makeTempFile("a.swift", "x")
        let preview = try makeTempFile("b.swift", "y")

        controller.openFileInEditor(pinned, pinned: true)
        controller.openFileInEditor(preview, pinned: false)

        let workspace = controller.workspaceView
        let editors = workspace.allPaneIDs.filter { workspace.descriptor(for: $0)?.kind == .editor }
        let pane = try XCTUnwrap(workspace.editorPane(for: editors[0]))
        XCTAssertEqual(pane.model.tabs.map(\.path), [pinned.path, preview.path])
        XCTAssertEqual(pane.model.tabs.map(\.isPinned), [true, false])
    }

    /// A single click on a file that is already open somewhere else focuses
    /// that pane's tab. It never opens a second copy — the no-duplicates rule
    /// is workspace-wide, not per pane.
    func testFileOpenAnywhereIsFocusedNotDuplicated() throws {
        let controller = makeController()
        defer { controller.close() }
        controller.showWindow(nil)
        let file = try makeTempFile("a.swift", "x")
        controller.openFileInEditor(file, pinned: true)
        let workspace = controller.workspaceView
        let holder = try XCTUnwrap(workspace.focusedPaneID)
        XCTAssertTrue(controller.newEditor(in: nil), "a second, empty editor pane, now focused")

        controller.openFileInEditor(file, pinned: false)

        let panes = workspace.allPaneIDs.compactMap { workspace.editorPane(for: $0) }
        XCTAssertEqual(panes.count, 2)
        XCTAssertEqual(
            panes.map(\.model.tabs.count).sorted(),
            [0, 1],
            "no duplicate tab appeared in the empty pane"
        )
        XCTAssertEqual(workspace.focusedPaneID, holder, "focus moved to the pane that has it")
        XCTAssertEqual(
            workspace.editorPane(for: holder)?.model.tabs.map(\.isPinned),
            [true],
            "and a preview open never un-pins what is already pinned"
        )
    }

    /// Which pane a file opens into: the most recently focused editor pane,
    /// not simply the first one in the grid.
    func testOpenGoesToTheMostRecentlyFocusedEditorPane() throws {
        let controller = makeController()
        defer { controller.close() }
        controller.showWindow(nil)
        XCTAssertTrue(controller.newEditor(in: nil))
        let workspace = controller.workspaceView
        let first = try XCTUnwrap(workspace.focusedPaneID)
        XCTAssertTrue(controller.newEditor(in: nil))
        let second = try XCTUnwrap(workspace.focusedPaneID)
        XCTAssertNotEqual(first, second)

        controller.openFileInEditor(try makeTempFile("a.swift", "x"), pinned: false)
        XCTAssertEqual(workspace.editorPane(for: second)?.model.tabs.count, 1)
        XCTAssertEqual(workspace.editorPane(for: first)?.model.tabs.count, 0)

        workspace.focusPane(first)
        controller.openFileInEditor(try makeTempFile("b.swift", "y"), pinned: false)
        XCTAssertEqual(workspace.editorPane(for: first)?.model.tabs.count, 1, "recency, not order")
    }

    /// An image opens as a `.media` tab, so the "already open" lookup has to
    /// ask `EditorFileClass` what kind it would be rather than assuming
    /// `.file` — otherwise every click on an image opens another tab.
    func testAnImageOpensOnceAsAMediaTab() throws {
        let controller = makeController()
        defer { controller.close() }
        controller.showWindow(nil)
        let image = try makeTempFile("a.png", "not really a png")

        controller.openFileInEditor(image, pinned: false)
        controller.openFileInEditor(image, pinned: false)

        let workspace = controller.workspaceView
        let editors = workspace.allPaneIDs.filter { workspace.descriptor(for: $0)?.kind == .editor }
        let pane = try XCTUnwrap(workspace.editorPane(for: editors[0]))
        XCTAssertEqual(pane.model.tabs.map(\.kind), [.media])
    }

    /// The chain the sidebar completes: `WorkspaceSidebarView.onOpenFile` is
    /// wired to the controller, carrying the pinned flag through untouched.
    func testTheSidebarsOpenFileCallbackReachesTheEditor() throws {
        let controller = makeController()
        defer { controller.close() }
        controller.showWindow(nil)
        let file = try makeTempFile("a.swift", "x")

        try XCTUnwrap(controller.shellSidebar.onOpenFile)(file, true)

        let workspace = controller.workspaceView
        let editors = workspace.allPaneIDs.filter { workspace.descriptor(for: $0)?.kind == .editor }
        let pane = try XCTUnwrap(workspace.editorPane(for: editors[0]))
        XCTAssertEqual(pane.model.tabs.map(\.isPinned), [true], "the pinned flag survives the chain")
    }

    /// The grid is full and none of it is an editor: there is nowhere to put
    /// one, and the click has to be a no-op rather than a crash or a 13th pane.
    func testOpeningWithAFullGridDoesNothing() throws {
        let controller = makeController()
        defer { controller.close() }
        controller.showWindow(nil)
        let workspace = controller.workspaceView
        while workspace.paneIDs.count < PaneGrid.maxPanes {
            XCTAssertTrue(controller.newBrowser(in: nil))
        }

        controller.openFileInEditor(try makeTempFile("a.swift", "x"), pinned: false)

        XCTAssertEqual(workspace.paneIDs.count, PaneGrid.maxPanes)
        XCTAssertTrue(workspace.allPaneIDs.allSatisfy { workspace.descriptor(for: $0)?.kind != .editor })
    }

    // MARK: - Diffs (Task 12)

    /// The strip's ± toggle, the FILES badge and the palette all land here: a
    /// diff tab, always pinned — asking for a diff is never accidental.
    func testOpenDiffCreatesAPinnedDiffTab() throws {
        let controller = makeController()
        defer { controller.close() }
        controller.showWindow(nil)

        controller.openDiffInEditor(try makeTempFile("a.swift", "x"))

        let pane = try XCTUnwrap(firstEditorPane(in: controller))
        XCTAssertEqual(pane.model.tabs.map(\.kind), [.diff])
        XCTAssertTrue(pane.model.tabs[0].isPinned)
    }

    /// The ± toggle belongs to a *particular* pane, and the callback carries
    /// no pane id — so the wiring has to remember which pane asked. Focus has
    /// usually moved on by the time a request lands.
    func testTheStripsDiffRequestOpensInTheAskingPane() throws {
        let controller = makeController()
        defer { controller.close() }
        controller.showWindow(nil)
        let workspace = controller.workspaceView
        XCTAssertTrue(controller.newEditor(in: nil))
        let asking = try XCTUnwrap(workspace.focusedPaneID)
        XCTAssertTrue(controller.newEditor(in: nil))
        let other = try XCTUnwrap(workspace.focusedPaneID)
        let file = try makeTempFile("a.swift", "x")

        try XCTUnwrap(workspace.editorPane(for: asking)?.onOpenDiffRequest)(file)

        XCTAssertEqual(workspace.editorPane(for: asking)?.model.tabs.map(\.kind), [.diff])
        XCTAssertEqual(workspace.editorPane(for: other)?.model.tabs.count, 0, "not the pane that happened to be focused")
        XCTAssertEqual(workspace.focusedPaneID, asking, "and focus follows the diff")
    }

    /// The no-duplicates rule is workspace-wide (Task 11's, applied to diffs):
    /// a diff already open anywhere is focused rather than opened again.
    func testADiffAlreadyOpenAnywhereIsFocusedNotDuplicated() throws {
        let controller = makeController()
        defer { controller.close() }
        controller.showWindow(nil)
        let workspace = controller.workspaceView
        XCTAssertTrue(controller.newEditor(in: nil))
        let first = try XCTUnwrap(workspace.focusedPaneID)
        XCTAssertTrue(controller.newEditor(in: nil))
        let second = try XCTUnwrap(workspace.focusedPaneID)
        let file = try makeTempFile("a.swift", "x")
        try XCTUnwrap(workspace.editorPane(for: first)?.onOpenDiffRequest)(file)

        try XCTUnwrap(workspace.editorPane(for: second)?.onOpenDiffRequest)(file)

        XCTAssertEqual(workspace.editorPane(for: first)?.model.tabs.count, 1)
        XCTAssertEqual(workspace.editorPane(for: second)?.model.tabs.count, 0)
        XCTAssertEqual(workspace.focusedPaneID, first)
    }

    /// The palette row runs the same method the toggle does.
    func testThePaletteOpensTheDiffForTheFocusedEditorsFile() throws {
        let controller = makeController()
        defer { controller.close() }
        controller.showWindow(nil)
        let file = try makeTempFile("a.swift", "x")

        controller.run(.openDiffForCurrentFile(path: file.path))

        let pane = try XCTUnwrap(firstEditorPane(in: controller))
        XCTAssertEqual(pane.model.tabs.map(\.path), [file.path])
        XCTAssertEqual(pane.model.tabs.map(\.kind), [.diff])
    }

    /// The sidebar's badge click is the third entry point, and it goes through
    /// the same chain the file rows already use.
    func testTheSidebarsBadgeClickReachesTheEditor() throws {
        let controller = makeController()
        defer { controller.close() }
        controller.showWindow(nil)
        let file = try makeTempFile("a.swift", "x")

        try XCTUnwrap(controller.shellSidebar.onOpenDiff)(file)

        let pane = try XCTUnwrap(firstEditorPane(in: controller))
        XCTAssertEqual(pane.model.tabs.map(\.kind), [.diff])
    }

    // MARK: - The Changes overview (Task 13)

    /// One overview per pane: asking twice focuses the tab that is already
    /// there rather than stacking a second copy of the same list.
    func testOpenChangesOverviewCreatesSingletonTab() throws {
        let controller = makeController()
        defer { controller.close() }
        controller.showWindow(nil)

        controller.openChangesOverview()
        controller.openChangesOverview()

        let pane = try XCTUnwrap(firstEditorPane(in: controller))
        XCTAssertEqual(pane.model.tabs.filter { $0.kind == .changes }.count, 1)
    }

    /// The sidebar owns the `git status`; every editor pane is told, including
    /// panes created after it landed — otherwise a pane opened later would
    /// show "not a git repository" in a repository.
    func testGitStatusReachesEveryEditorPaneIncludingNewOnes() throws {
        let controller = makeController()
        defer { controller.close() }
        controller.showWindow(nil)
        XCTAssertTrue(controller.newEditor(in: nil))
        let existing = try XCTUnwrap(controller.workspaceView.focusedPaneID)
        let root = try makeTempFile("a.swift", "x").deletingLastPathComponent()

        try XCTUnwrap(controller.shellSidebar.onGitStatusChanged)(
            GitStatus(root: root, badges: ["a.swift": .modified])
        )

        XCTAssertEqual(
            controller.workspaceView.editorPane(for: existing)?.changedPaths,
            [root.appendingPathComponent("a.swift").path],
            "a live pane hears about it"
        )
        XCTAssertTrue(controller.newEditor(in: nil))
        let fresh = try XCTUnwrap(controller.workspaceView.focusedPaneID)
        XCTAssertEqual(
            controller.workspaceView.editorPane(for: fresh)?.changedPaths,
            [root.appendingPathComponent("a.swift").path],
            "and so does a pane created afterwards"
        )
    }

    /// The FILES header's +N −M counts are the button: clicking them opens the
    /// repo-wide overview.
    func testTheFilesHeaderOpensTheChangesOverview() throws {
        let controller = makeController()
        defer { controller.close() }
        controller.showWindow(nil)

        try XCTUnwrap(controller.shellSidebar.onOpenAllChanges)()

        let pane = try XCTUnwrap(firstEditorPane(in: controller))
        XCTAssertEqual(pane.model.tabs.map(\.kind), [.changes])
    }

    /// The palette row exists only where there is a repository to describe,
    /// and running it opens the same tab the header does.
    func testThePaletteOffersAllChangesOnlyOnceTheWorkspaceIsARepo() throws {
        let controller = makeController()
        defer { controller.close() }
        controller.showWindow(nil)

        controller.showCommandPalette(nil)
        XCTAssertFalse(controller.palette.model.matches.contains { $0.action == .showAllChanges })
        controller.palette.dismiss()

        try XCTUnwrap(controller.shellSidebar.onGitStatusChanged)(
            GitStatus(root: URL(fileURLWithPath: "/w"), badges: ["a.swift": .modified])
        )
        controller.showCommandPalette(nil)
        XCTAssertTrue(controller.palette.model.matches.contains { $0.action == .showAllChanges })
        controller.palette.dismiss()

        controller.run(.showAllChanges)

        let pane = try XCTUnwrap(firstEditorPane(in: controller))
        XCTAssertEqual(pane.model.tabs.map(\.kind), [.changes])
    }

    /// The overview's "open file" is the FILES tree's own routing, so a file
    /// opened from it lands pinned in an editor pane like any deliberate open.
    func testTheOverviewsOpenFileRequestOpensAPinnedFileTab() throws {
        let controller = makeController()
        defer { controller.close() }
        controller.showWindow(nil)
        XCTAssertTrue(controller.newEditor(in: nil))
        let paneID = try XCTUnwrap(controller.workspaceView.focusedPaneID)
        let pane = try XCTUnwrap(controller.workspaceView.editorPane(for: paneID))
        let file = try makeTempFile("a.swift", "x")

        try XCTUnwrap(pane.onOpenFileRequest)(file)

        XCTAssertEqual(pane.model.tabs.map(\.path), [file.path])
        XCTAssertEqual(pane.model.tabs.map(\.kind), [.file])
        XCTAssertTrue(pane.model.tabs[0].isPinned)
    }

    // MARK: - Helpers

    /// The first editor pane in grid order — the routing rules decide *which*
    /// pane, and every diff/changes test only cares that exactly one got it.
    private func firstEditorPane(in controller: WorkspaceWindowController) -> EditorPaneView? {
        controller.workspaceView.allPaneIDs.lazy
            .compactMap { controller.workspaceView.editorPane(for: $0) }
            .first
    }

    /// A real file on disk — `EditorPaneView.openFile` stats and reads it.
    private func makeTempFile(_ name: String, _ contents: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("editor-open-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func makeController() -> WorkspaceWindowController {
        WorkspaceWindowController(
            connection: SessionConnection(
                socketURL: URL(fileURLWithPath: "/tmp/omniagent-editor-integration-test.sock")
            ),
            sessionID: "native-terminal"
        )
    }

    private func makeEmptyController() -> WorkspaceWindowController {
        WorkspaceWindowController(
            connection: SessionConnection(
                socketURL: URL(fileURLWithPath: "/tmp/omniagent-editor-integration-test.sock")
            ),
            panes: []
        )
    }
}
