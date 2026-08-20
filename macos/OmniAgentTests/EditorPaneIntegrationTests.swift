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

    /// The hole tile's third dock button reaches the same method the menu
    /// item does — `newEditor(in:)`, which the redesigned sidebar no longer
    /// wraps in a row of its own.
    func testTheHoleTileAndTheDirectCallBothOpenAnEditorPane() throws {
        let controller = makeController()
        defer { controller.close() }
        controller.showWindow(nil)
        let workspace = controller.workspaceView

        try XCTUnwrap(workspace.onRequestNewEditorPane)()
        XCTAssertTrue(controller.newEditor(in: nil))

        XCTAssertEqual(
            workspace.allPaneIDs.filter { workspace.descriptor(for: $0)?.kind == .editor }.count,
            2,
            "the hole tile and the direct call each opened one"
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
        // Demoted from the default row when the toolbar slimmed down, but the
        // button itself lives on in the customization palette.
        XCTAssertTrue(
            controller.toolbarAllowedItemIdentifiers(toolbar)
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

    /// The controller's own entry point carries the pinned flag through
    /// untouched — what the palette (and, soon, the review panel's tree)
    /// route their opens through.
    func testTheControllersOpenFileEntryPointReachesTheEditor() throws {
        let controller = makeController()
        defer { controller.close() }
        controller.showWindow(nil)
        let file = try makeTempFile("a.swift", "x")

        controller.openFileInEditor(file, pinned: true)

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

    /// `openDiffInEditor` is the diff entry point every surface routes
    /// through — the palette today, the review panel's tree tomorrow.
    func testTheDiffEntryPointReachesTheEditor() throws {
        let controller = makeController()
        defer { controller.close() }
        controller.showWindow(nil)
        let file = try makeTempFile("a.swift", "x")

        controller.openDiffInEditor(file)

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

    /// The controller owns the `git status`; every editor pane is told,
    /// including panes created after it landed — otherwise a pane opened
    /// later would show "not a git repository" in a repository.
    func testGitStatusReachesEveryEditorPaneIncludingNewOnes() throws {
        let controller = makeController()
        defer { controller.close() }
        controller.showWindow(nil)
        XCTAssertTrue(controller.newEditor(in: nil))
        let existing = try XCTUnwrap(controller.workspaceView.focusedPaneID)
        let root = try makeTempFile("a.swift", "x").deletingLastPathComponent()

        controller.applyGitStatus(GitStatus(root: root, badges: ["a.swift": .modified]))

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

    /// The palette row exists only where there is a repository to describe,
    /// and running it opens the same tab the header does.
    func testThePaletteOffersAllChangesOnlyOnceTheWorkspaceIsARepo() throws {
        let controller = makeController()
        defer { controller.close() }
        controller.showWindow(nil)

        controller.showCommandPalette(nil)
        XCTAssertFalse(controller.palette.model.commands.contains { $0.action == .showAllChanges })
        controller.palette.dismiss()

        controller.applyGitStatus(
            GitStatus(root: URL(fileURLWithPath: "/w"), badges: ["a.swift": .modified])
        )
        controller.showCommandPalette(nil)
        XCTAssertTrue(controller.palette.model.commands.contains { $0.action == .showAllChanges })
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

    // MARK: - Tab drag-and-drop (Task 14)

    /// The whole cross-pane move, driven through the closure the workspace
    /// actually calls rather than the broker method directly — so this fails
    /// if the wiring is missing as well as if the rule is wrong.
    func testCentreDropMovesTheTabBetweenPanesAndClosesTheEmptySource() throws {
        let controller = makeController()
        defer { controller.close() }
        controller.showWindow(nil)
        let file = try makeTempFile("a.swift", "x")
        controller.openFileInEditor(file, pinned: true)
        let sourceID = try XCTUnwrap(controller.workspaceView.focusedPaneID)
        XCTAssertTrue(controller.newEditor(in: nil))
        let targetID = try XCTUnwrap(controller.workspaceView.focusedPaneID)
        XCTAssertNotEqual(sourceID, targetID)

        try XCTUnwrap(controller.workspaceView.onEditorTabDropOnPane)(
            EditorTabDragPayload(paneID: sourceID, index: 0), targetID, .center
        )

        XCTAssertNil(
            controller.workspaceView.editorPane(for: sourceID),
            "the source closed with its last tab"
        )
        XCTAssertEqual(
            controller.workspaceView.editorPane(for: targetID)?.model.tabs.map(\.path),
            [file.path]
        )
        XCTAssertEqual(controller.workspaceView.focusedPaneID, targetID)
    }

    /// Every pane's strip reports its drops, and the index it reports is the
    /// one the indicator drew — read off the strip as it stands, with the
    /// dragged tab still in it, so a rightward move is one short of it.
    func testAStripDropReordersUsingTheIndicatorsIndex() throws {
        let controller = makeController()
        defer { controller.close() }
        controller.showWindow(nil)
        let files = try ["a.swift", "b.swift", "c.swift"].map { try makeTempFile($0, "x") }
        for file in files { controller.openFileInEditor(file, pinned: true) }
        let paneID = try XCTUnwrap(controller.workspaceView.focusedPaneID)
        let pane = try XCTUnwrap(controller.workspaceView.editorPane(for: paneID))
        XCTAssertEqual(pane.model.tabs.map(\.path), files.map(\.path))
        XCTAssertNotNil(pane.onTabDroppedInStrip, "the strip's drops are wired to the broker")

        try XCTUnwrap(pane.onTabDroppedInStrip)(EditorTabDragPayload(paneID: paneID, index: 0), 2)

        XCTAssertEqual(
            pane.model.tabs.map(\.path),
            [files[1].path, files[0].path, files[2].path],
            "dropped between b and c, not after c"
        )
    }

    /// A drop on a pane's own body says nothing about where the tab should
    /// go, so it moves nothing — an accidental release must not silently
    /// reorder the strip.
    func testACentreDropOnTheTabsOwnPaneMovesNothing() throws {
        let controller = makeController()
        defer { controller.close() }
        controller.showWindow(nil)
        let files = try ["a.swift", "b.swift"].map { try makeTempFile($0, "x") }
        for file in files { controller.openFileInEditor(file, pinned: true) }
        let paneID = try XCTUnwrap(controller.workspaceView.focusedPaneID)
        let pane = try XCTUnwrap(controller.workspaceView.editorPane(for: paneID))

        controller.handleEditorTabDrop(
            EditorTabDragPayload(paneID: paneID, index: 0), intoPane: paneID, at: Int.max
        )

        XCTAssertEqual(pane.model.tabs.map(\.path), files.map(\.path))
    }

    func testEdgeDropInsertsANewPaneAdjacentHoldingTheTab() throws {
        let controller = makeController()
        defer { controller.close() }
        controller.showWindow(nil)
        let a = try makeTempFile("a.swift", "x")
        let b = try makeTempFile("b.swift", "y")
        controller.openFileInEditor(a, pinned: true)
        controller.openFileInEditor(b, pinned: true)
        let paneID = try XCTUnwrap(controller.workspaceView.focusedPaneID)
        let before = controller.workspaceView.paneIDs

        controller.handleEditorTabEdgeDrop(
            EditorTabDragPayload(paneID: paneID, index: 1), target: paneID, zone: .insertAfter
        )

        let after = controller.workspaceView.paneIDs
        XCTAssertEqual(after.count, before.count + 1)
        let anchor = try XCTUnwrap(after.firstIndex(of: paneID))
        let newID = after[anchor + 1]
        XCTAssertEqual(controller.workspaceView.descriptor(for: newID)?.kind, .editor)
        XCTAssertEqual(
            controller.workspaceView.descriptor(for: newID)?.group,
            controller.workspaceView.descriptor(for: paneID)?.group
        )
        XCTAssertEqual(controller.workspaceView.editorPane(for: newID)?.model.tabs.map(\.path), [b.path])
        XCTAssertEqual(controller.workspaceView.editorPane(for: paneID)?.model.tabs.map(\.path), [a.path])
        XCTAssertNotNil(
            controller.workspaceView.editorPane(for: newID)?.onLastTabClosed,
            "the inserted pane got the same controller wiring an ordinary one does"
        )
    }

    func testHoleDropCreatesANewEditorPaneHoldingTheTab() throws {
        let controller = makeController()
        defer { controller.close() }
        controller.showWindow(nil)
        let a = try makeTempFile("a.swift", "x")
        let b = try makeTempFile("b.swift", "y")
        controller.openFileInEditor(a, pinned: true)
        controller.openFileInEditor(b, pinned: true)
        let sourceID = try XCTUnwrap(controller.workspaceView.focusedPaneID)
        XCTAssertTrue(controller.newEditor(in: nil))
        XCTAssertEqual(controller.workspaceView.holePlaceholders.count, 1, "3 panes on the 2x2 rung")

        try XCTUnwrap(controller.workspaceView.onEditorTabDropOnHole)(
            EditorTabDragPayload(paneID: sourceID, index: 1)
        )

        XCTAssertEqual(controller.workspaceView.paneIDs.count, 4)
        let newID = try XCTUnwrap(controller.workspaceView.paneIDs.last)
        XCTAssertEqual(controller.workspaceView.editorPane(for: newID)?.model.tabs.map(\.path), [b.path])
        XCTAssertEqual(controller.workspaceView.editorPane(for: sourceID)?.model.tabs.map(\.path), [a.path])
    }

    /// `PaneGrid.maxPanes`, exactly as every other creation path spells it —
    /// and a refusal moves nothing at all.
    func testEveryDropThatWouldCreateAPaneStopsAtTheGridCap() throws {
        let controller = makeController()
        defer { controller.close() }
        controller.showWindow(nil)
        let a = try makeTempFile("a.swift", "x")
        let b = try makeTempFile("b.swift", "y")
        controller.openFileInEditor(a, pinned: true)
        controller.openFileInEditor(b, pinned: true)
        let sourceID = try XCTUnwrap(controller.workspaceView.focusedPaneID)
        while controller.workspaceView.paneIDs.count < PaneGrid.maxPanes {
            XCTAssertTrue(controller.newEditor(in: nil))
        }
        let panes = controller.workspaceView.paneIDs
        let tabs = controller.workspaceView.editorPane(for: sourceID)?.model.tabs

        controller.handleEditorTabEdgeDrop(
            EditorTabDragPayload(paneID: sourceID, index: 1), target: sourceID, zone: .insertAfter
        )
        controller.handleEditorTabHoleDrop(EditorTabDragPayload(paneID: sourceID, index: 1))

        XCTAssertEqual(controller.workspaceView.paneIDs, panes, "no pane was created")
        XCTAssertEqual(controller.workspaceView.editorPane(for: sourceID)?.model.tabs, tabs, "and no tab moved")
    }

    /// A dirty buffer cannot travel between web views in v1 (each pane owns
    /// its own Monaco), so the move asks first and honours the answer.
    func testADirtyTabIsNeverMovedWithoutAsking() throws {
        let controller = makeController()
        defer { controller.close() }
        controller.showWindow(nil)
        let file = try makeTempFile("a.swift", "x")
        controller.openFileInEditor(file, pinned: true)
        let sourceID = try XCTUnwrap(controller.workspaceView.focusedPaneID)
        let source = try XCTUnwrap(controller.workspaceView.editorPane(for: sourceID))
        XCTAssertTrue(controller.newEditor(in: nil))
        let targetID = try XCTUnwrap(controller.workspaceView.focusedPaneID)
        let target = try XCTUnwrap(controller.workspaceView.editorPane(for: targetID))
        source.modelForTesting { $0.setDirty(true, at: 0) }
        let payload = EditorTabDragPayload(paneID: sourceID, index: 0)

        var asked: [String] = []
        source.confirmSave = { name, decide in
            asked.append(name)
            decide(.cancel)
        }
        controller.handleEditorTabDrop(payload, intoPane: targetID, at: 0)

        XCTAssertEqual(asked, ["a.swift"])
        XCTAssertEqual(source.model.tabs.map(\.path), [file.path], "cancel left it exactly where it was")
        XCTAssertTrue(source.model.tabs[0].isDirty)
        XCTAssertTrue(target.model.tabs.isEmpty)

        source.confirmSave = { _, decide in decide(.discard) }
        controller.handleEditorTabDrop(payload, intoPane: targetID, at: 0)

        XCTAssertNil(controller.workspaceView.editorPane(for: sourceID))
        XCTAssertEqual(target.model.tabs.map(\.path), [file.path])
        XCTAssertFalse(target.model.tabs[0].isDirty, "buffers do not cross web views in v1")
    }

    /// "Save" writes the buffer through the real bridge and only *then* lets
    /// the tab travel — the target reloads from disk, so anything unwritten
    /// would be lost silently without this.
    func testSavingBeforeAMoveWritesTheBufferThenTravels() throws {
        let controller = makeController()
        defer { controller.close() }
        controller.showWindow(nil)
        let file = try makeTempFile("a.swift", "let x = 1")
        controller.openFileInEditor(file, pinned: true)
        let sourceID = try XCTUnwrap(controller.workspaceView.focusedPaneID)
        let source = try XCTUnwrap(controller.workspaceView.editorPane(for: sourceID))
        waitUntilReady(source)
        XCTAssertTrue(controller.newEditor(in: nil))
        let targetID = try XCTUnwrap(controller.workspaceView.focusedPaneID)
        let target = try XCTUnwrap(controller.workspaceView.editorPane(for: targetID))
        source.modelForTesting { $0.setDirty(true, at: 0) }
        source.confirmSave = { _, decide in decide(.save) }

        let travelled = expectation(description: "the tab travelled after the write")
        travelled.assertForOverFulfill = false
        let previous = target.onStateChange
        target.onStateChange = { tabs, active in
            previous?(tabs, active)
            if tabs.contains(where: { $0.path == file.path }) { travelled.fulfill() }
        }

        controller.handleEditorTabDrop(
            EditorTabDragPayload(paneID: sourceID, index: 0), intoPane: targetID, at: 0
        )
        wait(for: [travelled], timeout: 30)

        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "let x = 1")
        XCTAssertEqual(target.model.tabs.map(\.path), [file.path])
        XCTAssertFalse(target.model.tabs[0].isDirty)
    }

    /// Fix round 3, Important 1. ⌘W / the header × / the toolbar / the palette
    /// all arrive at `closePane`, which read the lagging flag and went
    /// straight to destroying the pane — disposing every Monaco model in it
    /// with no prompt. Staged by typing and closing in the same run-loop turn.
    func testClosingAPaneWhoseDirtyMessageIsStillInFlightStillAsks() throws {
        let controller = makeController()
        defer { controller.close() }
        controller.showWindow(nil)
        let file = try makeTempFile("a.swift", "let x = 1")
        controller.openFileInEditor(file, pinned: true)
        let id = try XCTUnwrap(controller.workspaceView.focusedPaneID)
        let pane = try XCTUnwrap(controller.workspaceView.editorPane(for: id))
        waitUntilReady(pane)

        pane.webHost.setContentForTesting(path: file.path, content: "in-flight")
        XCTAssertFalse(pane.model.tabs[0].isDirty, "the posted message cannot have landed yet")

        let asked = expectation(description: "asked before destroying the pane")
        pane.confirmSave = { _, decide in
            asked.fulfill()
            decide(.cancel)
        }
        controller.closePane(nil)
        wait(for: [asked], timeout: 10)

        XCTAssertNotNil(controller.workspaceView.editorPane(for: id), "cancel kept the pane")
    }

    /// Fix round 3, Minor. Every other dirty window/quit test stages dirt with
    /// `modelForTesting` and never waits for the bridge, so they all take the
    /// `!isReady` branch. This one drives the whole thing for real: bridge up,
    /// typed through the page, then quit.
    func testQuitPromptsAboutABufferTypedThroughTheRealBridge() throws {
        let controller = makeController()
        defer { controller.close() }
        controller.showWindow(nil)
        let window = try XCTUnwrap(controller.window)
        let file = try makeTempFile("a.swift", "let x = 1")
        controller.openFileInEditor(file, pinned: true)
        let id = try XCTUnwrap(controller.workspaceView.focusedPaneID)
        let pane = try XCTUnwrap(controller.workspaceView.editorPane(for: id))
        waitUntilReady(pane)
        makeDirty(pane, path: file.path, content: "let x = 2")

        let delegate = AppDelegate()
        var replies: [Bool] = []
        let replied = expectation(description: "AppKit was answered")
        replied.assertForOverFulfill = false
        delegate.replyToTermination = {
            replies.append($0)
            replied.fulfill()
        }
        var asked = 0
        pane.confirmSave = { _, decide in
            asked += 1
            decide(.save)
        }

        XCTAssertEqual(
            AppDelegate.controllersThatMayHaveUnsavedWork(in: [window]).count, 1
        )
        delegate.promptDirtyEditorTabs(in: [controller]) { delegate.replyToTermination($0) }
        wait(for: [replied], timeout: 30)

        XCTAssertEqual(replies, [true])
        XCTAssertEqual(asked, 1, "the real dirty buffer was asked about exactly once")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "let x = 2", "and saved")
        XCTAssertTrue(pane.model.tabs.isEmpty)
    }

    /// Fix round 2, Important. The drag's entry gate read the lagging flag
    /// too: a keystroke whose `dirtyChanged` post has not landed reads clean,
    /// and the tab was carried away — disposing the source's Monaco model,
    /// which is where that keystroke lived — with no prompt at all.
    func testDraggingATabWhoseDirtyMessageIsStillInFlightStillAsks() throws {
        let controller = makeController()
        defer { controller.close() }
        controller.showWindow(nil)
        let file = try makeTempFile("a.swift", "let x = 1")
        controller.openFileInEditor(file, pinned: true)
        let sourceID = try XCTUnwrap(controller.workspaceView.focusedPaneID)
        let source = try XCTUnwrap(controller.workspaceView.editorPane(for: sourceID))
        waitUntilReady(source)
        XCTAssertTrue(controller.newEditor(in: nil))
        let targetID = try XCTUnwrap(controller.workspaceView.focusedPaneID)
        let target = try XCTUnwrap(controller.workspaceView.editorPane(for: targetID))

        source.webHost.setContentForTesting(path: file.path, content: "in-flight")
        XCTAssertFalse(source.model.tabs[0].isDirty, "the posted message cannot have landed yet")

        let asked = expectation(description: "asked before the tab travelled")
        source.confirmSave = { _, decide in
            asked.fulfill()
            decide(.cancel)
        }
        controller.handleEditorTabDrop(
            EditorTabDragPayload(paneID: sourceID, index: 0), intoPane: targetID, at: 0
        )
        wait(for: [asked], timeout: 20)

        XCTAssertEqual(source.model.tabs.map(\.path), [file.path], "cancel left the tab where it was")
        XCTAssertTrue(target.model.tabs.isEmpty)
    }

    /// Fix round 1, Critical. A drag disposes the source's Monaco model just
    /// as finally as a close does, so it is held to the same rule: `save`'s
    /// `true` means the bytes reached disk, not that the buffer is clean. A
    /// keystroke landing inside the write must be asked about again, never
    /// carried away and dropped.
    func testATabDraggedAfterSavingWaitsForTheBufferToGoClean() throws {
        let controller = makeController()
        defer { controller.close() }
        controller.showWindow(nil)
        let file = try makeTempFile("a.swift", "let x = 1")
        controller.openFileInEditor(file, pinned: true)
        let sourceID = try XCTUnwrap(controller.workspaceView.focusedPaneID)
        let source = try XCTUnwrap(controller.workspaceView.editorPane(for: sourceID))
        waitUntilReady(source)
        XCTAssertTrue(controller.newEditor(in: nil))
        let targetID = try XCTUnwrap(controller.workspaceView.focusedPaneID)
        let target = try XCTUnwrap(controller.workspaceView.editorPane(for: targetID))

        makeDirty(source, path: file.path, content: "edit-1")
        var prompts = 0
        source.confirmSave = { _, decide in
            prompts += 1
            decide(.save)
            // `evaluateJavaScript` calls run in the page in order, so this
            // lands after the `getContent` `decide(.save)` just issued and
            // before Swift's write comes back — exactly the window.
            if prompts == 1 {
                source.webHost.setContentForTesting(path: file.path, content: "typed-during-save")
            }
        }

        let travelled = expectation(description: "the tab travelled")
        travelled.assertForOverFulfill = false
        let previous = target.onStateChange
        target.onStateChange = { tabs, active in
            previous?(tabs, active)
            if tabs.contains(where: { $0.path == file.path }) { travelled.fulfill() }
        }

        controller.handleEditorTabDrop(
            EditorTabDragPayload(paneID: sourceID, index: 0), intoPane: targetID, at: 0
        )
        wait(for: [travelled], timeout: 30)

        XCTAssertEqual(prompts, 2, "the edit that landed inside the write is asked about again")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "typed-during-save")
        XCTAssertEqual(target.model.tabs.map(\.path), [file.path])
        XCTAssertTrue(source.model.tabs.isEmpty)
    }

    /// The prompt hands control back to the run loop, so the strip can move
    /// under it — and the payload's index is then pointing at somebody else's
    /// tab. Moving that one would also discard *its* unsaved buffer, so this
    /// is a data-loss guard, not an off-by-one one.
    func testATabThatShiftedUnderTheSavePromptIsStillTheOneThatMoves() throws {
        let controller = makeController()
        defer { controller.close() }
        controller.showWindow(nil)
        let files = try ["a.swift", "b.swift", "c.swift", "d.swift"].map { try makeTempFile($0, "x") }
        for file in files { controller.openFileInEditor(file, pinned: true) }
        let sourceID = try XCTUnwrap(controller.workspaceView.focusedPaneID)
        let source = try XCTUnwrap(controller.workspaceView.editorPane(for: sourceID))
        XCTAssertTrue(controller.newEditor(in: nil))
        let targetID = try XCTUnwrap(controller.workspaceView.focusedPaneID)
        let target = try XCTUnwrap(controller.workspaceView.editorPane(for: targetID))
        // c.swift (index 2) is the one dragged; d.swift is dirty too, and is
        // what index 2 points at once a.swift goes.
        source.modelForTesting {
            $0.setDirty(true, at: 2)
            $0.setDirty(true, at: 3)
        }

        source.confirmSave = { _, decide in
            // The user closes a.swift while the prompt is up.
            source.requestCloseTab(at: 0)
            decide(.discard)
        }
        controller.handleEditorTabDrop(
            EditorTabDragPayload(paneID: sourceID, index: 2), intoPane: targetID, at: 0
        )

        XCTAssertEqual(
            target.model.tabs.map(\.path), [files[2].path],
            "c.swift travelled — not whatever index 2 points at now"
        )
        XCTAssertEqual(source.model.tabs.map(\.path), [files[1].path, files[3].path])
        XCTAssertTrue(
            source.model.tabs[1].isDirty,
            "and d.swift kept its unsaved buffer instead of being lifted and discarded"
        )
    }

    /// The case the create-before-lift order exists for: the pane's **only**
    /// tab, dropped on that same pane's edge. Lifting first closes the source
    /// — which is also the anchor — and the tab would have nowhere to land.
    func testEdgeDroppingAPanesOnlyTabOnItsOwnEdgeKeepsTheTab() throws {
        let controller = makeController()
        defer { controller.close() }
        controller.showWindow(nil)
        let file = try makeTempFile("a.swift", "x")
        controller.openFileInEditor(file, pinned: true)
        let paneID = try XCTUnwrap(controller.workspaceView.focusedPaneID)
        XCTAssertEqual(controller.workspaceView.editorPane(for: paneID)?.model.tabs.count, 1)
        let before = controller.workspaceView.paneIDs.count

        controller.handleEditorTabEdgeDrop(
            EditorTabDragPayload(paneID: paneID, index: 0), target: paneID, zone: .insertBefore
        )

        XCTAssertNil(controller.workspaceView.editorPane(for: paneID), "the emptied source closed")
        let holders = controller.workspaceView.paneIDs.filter {
            controller.workspaceView.editorPane(for: $0)?.model.tabs.contains {
                $0.path == file.path
            } == true
        }
        XCTAssertEqual(holders.count, 1, "the tab survives, in exactly one pane")
        XCTAssertEqual(controller.workspaceView.paneIDs.count, before, "one pane traded for one pane")
    }

    /// An edge drop creates the pane and then lifts the tab, and `addPane`
    /// publishes synchronously in between. No snapshot written across that
    /// pair may show the same file open in two panes — a crash landing there
    /// would restore a duplicate.
    func testNoPersistedSnapshotEverShowsTheDraggedTabInTwoPanes() throws {
        let controller = makeController()
        defer { controller.close() }
        var rows: [String] = []
        controller.settingsWriter = { key, value in
            if key == SettingsKey.editorPanes { rows.append(value) }
        }
        controller.showWindow(nil)
        controller.applyRestoredEditorPanes([])
        let a = try makeTempFile("a.swift", "x")
        let b = try makeTempFile("b.swift", "y")
        controller.openFileInEditor(a, pinned: true)
        controller.openFileInEditor(b, pinned: true)
        let paneID = try XCTUnwrap(controller.workspaceView.focusedPaneID)
        rows.removeAll()

        controller.handleEditorTabEdgeDrop(
            EditorTabDragPayload(paneID: paneID, index: 1), target: paneID, zone: .insertAfter
        )

        XCTAssertFalse(rows.isEmpty, "the move is persisted")
        for row in rows {
            // By name, not by path: the row is JSON, which escapes every "/".
            XCTAssertEqual(
                row.components(separatedBy: b.lastPathComponent).count - 1, 1,
                "b.swift appears once in every snapshot, never in two panes at once: \(row)"
            )
        }
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
    // MARK: - Final review round

    /// Final review, Important. The quit/close walk *closes* every dirty tab,
    /// and `performClose` publishes — so the row was rewritten on the way out
    /// with precisely the files being edited removed, and next launch restored
    /// everything except them (spec §5 says open tabs come back).
    func testQuittingDoesNotEraseTheFilesItPromptedAboutFromTheRow() throws {
        let controller = makeController()
        defer { controller.close() }
        var writes: [String] = []
        controller.settingsWriter = { key, value in
            if key == SettingsKey.editorPanes { writes.append(value) }
        }
        controller.showWindow(nil)
        controller.applyRestoredPanes([])
        controller.applyRestoredEditorPanes([])
        let file = try makeTempFile("a.swift", "let x = 1")
        controller.openFileInEditor(file, pinned: true)
        let id = try XCTUnwrap(controller.workspaceView.focusedPaneID)
        let pane = try XCTUnwrap(controller.workspaceView.editorPane(for: id))
        XCTAssertTrue(
            writes.contains { $0.contains(file.lastPathComponent) },
            "the file is in the row to begin with"
        )
        pane.modelForTesting { $0.setDirty(true, at: 0) }
        pane.confirmSave = { _, decide in decide(.discard) }

        let done = expectation(description: "walked")
        controller.promptDirtyEditorTabs { _ in done.fulfill() }
        wait(for: [done], timeout: 20)

        XCTAssertFalse(
            writes.last?.contains("\"panes\":[]") ?? false,
            "the walk must not persist the emptied pane: \(writes.last ?? "-")"
        )
        XCTAssertTrue(
            writes.last?.contains(file.lastPathComponent) ?? false,
            "the file the user was asked about is still in the row for next launch"
        )
    }

    /// Final review: ⌘S had no menu item at all, so saving only worked while
    /// Monaco itself held focus.
    func testTheFileMenuCarriesSaveAndSaveAll() throws {
        let controller = makeController()
        defer { controller.close() }
        controller.showWindow(nil)

        ApplicationMenus.install()
        let fileMenu = try XCTUnwrap(NSApp.mainMenu?.item(withTitle: "File")?.submenu)
        let save = try XCTUnwrap(fileMenu.item(withTitle: "Save"))
        let saveAll = try XCTUnwrap(fileMenu.item(withTitle: "Save All"))
        XCTAssertEqual(save.action, #selector(WorkspaceWindowController.saveActiveFile(_:)))
        XCTAssertEqual(save.keyEquivalent, "s")
        XCTAssertEqual(save.keyEquivalentModifierMask, [.command], "⌘S")
        XCTAssertEqual(saveAll.action, #selector(WorkspaceWindowController.saveAllFiles(_:)))
        XCTAssertEqual(saveAll.keyEquivalentModifierMask, [.command, .option], "⌥⌘S")
        XCTAssertFalse(controller.validateMenuItem(save), "no editor pane, nothing to save")
        XCTAssertFalse(controller.validateMenuItem(saveAll))

        let file = try makeTempFile("a.swift", "let x = 1")
        controller.openFileInEditor(file, pinned: true)
        let id = try XCTUnwrap(controller.workspaceView.focusedPaneID)
        let pane = try XCTUnwrap(controller.workspaceView.editorPane(for: id))
        waitUntilReady(pane)

        XCTAssertTrue(controller.validateMenuItem(save))
        XCTAssertTrue(controller.validateMenuItem(saveAll))

        makeDirty(pane, path: file.path, content: "let x = 2")
        controller.saveActiveFile(nil)
        XCTAssertTrue(
            pollUntil(timeout: 20) { (try? String(contentsOf: file, encoding: .utf8)) == "let x = 2" },
            "⌘S wrote the buffer"
        )

        // …and Save All reaches a buffer the focused-pane command would not.
        makeDirty(pane, path: file.path, content: "let x = 3")
        controller.saveAllFiles(nil)
        XCTAssertTrue(
            pollUntil(timeout: 20) { (try? String(contentsOf: file, encoding: .utf8)) == "let x = 3" }
        )
    }

    // MARK: - Task 15: the three dirty prompts

    /// ⌘W on an editor pane with unsaved work asks before it destroys it —
    /// the hole Task 10 knowingly left in `closePane`.
    func testCloseDirtyEditorPaneAsksFirst() throws {
        let controller = makeController()
        defer { controller.close() }
        controller.showWindow(nil)
        controller.openFileInEditor(try makeTempFile("a.swift", "x"), pinned: true)
        let workspace = controller.workspaceView
        let id = try XCTUnwrap(workspace.focusedPaneID)
        let pane = try XCTUnwrap(workspace.editorPane(for: id))
        pane.modelForTesting { $0.setDirty(true, at: 0) }

        pane.confirmSave = { _, decide in decide(.cancel) }
        controller.closePane(nil)
        XCTAssertNotNil(workspace.editorPane(for: id), "cancel kept the pane")
        XCTAssertEqual(pane.model.tabs.count, 1, "…and the unsaved buffer with it")

        pane.confirmSave = { _, decide in decide(.discard) }
        controller.closePane(nil)
        XCTAssertNil(workspace.editorPane(for: id))
    }

    /// A clean editor pane closes with no prompt at all.
    func testCloseCleanEditorPaneNeverAsks() throws {
        let controller = makeController()
        defer { controller.close() }
        controller.showWindow(nil)
        controller.openFileInEditor(try makeTempFile("a.swift", "x"), pinned: true)
        let workspace = controller.workspaceView
        let id = try XCTUnwrap(workspace.focusedPaneID)
        let pane = try XCTUnwrap(workspace.editorPane(for: id))
        pane.confirmSave = { _, _ in XCTFail("nothing is unsaved") }

        controller.closePane(nil)

        XCTAssertNil(workspace.editorPane(for: id))
    }

    /// ⇧⌘W: the window holds itself open while anything is unsaved.
    func testWindowCloseAsksAboutDirtyEditorTabs() throws {
        let controller = makeController()
        defer { controller.close() }
        controller.showWindow(nil)
        let window = try XCTUnwrap(controller.window)
        controller.openFileInEditor(try makeTempFile("a.swift", "x"), pinned: true)
        let id = try XCTUnwrap(controller.workspaceView.focusedPaneID)
        let pane = try XCTUnwrap(controller.workspaceView.editorPane(for: id))
        pane.modelForTesting { $0.setDirty(true, at: 0) }

        var asked = 0
        pane.confirmSave = { _, decide in
            asked += 1
            decide(.cancel)
        }
        XCTAssertFalse(controller.windowShouldClose(window), "unsaved work holds the window open")
        XCTAssertTrue(pollUntil(timeout: 10) { asked == 1 })
        XCTAssertTrue(window.isVisible)
        XCTAssertEqual(pane.model.tabs.count, 1)

        pane.confirmSave = { _, decide in
            asked += 1
            decide(.discard)
        }
        XCTAssertFalse(
            controller.windowShouldClose(window),
            "the delegate still answers no — it closes the window itself once the prompt resolves"
        )
        XCTAssertTrue(pollUntil(timeout: 10) { asked == 2 })
        XCTAssertTrue(pollUntilClosed(window), "…and the window is gone")
    }

    /// A workspace holding no editor buffer at all never delays its own close
    /// — that is the one case answerable without asking the page.
    func testWindowCloseIsImmediateWithNoEditorBuffers() throws {
        let controller = makeController()
        defer { controller.close() }
        controller.showWindow(nil)
        let window = try XCTUnwrap(controller.window)

        XCTAssertTrue(controller.windowShouldClose(window))
        XCTAssertTrue(window.isVisible, "…and it is AppKit that closes it, not us")
    }

    /// With a buffer on screen the close goes through the asynchronous walk —
    /// but a clean workspace is never *prompted*, it just closes a run-loop
    /// turn later.
    func testWindowCloseWithACleanBufferAsksTheUserNothing() throws {
        let controller = makeController()
        defer { controller.close() }
        controller.showWindow(nil)
        let window = try XCTUnwrap(controller.window)
        controller.openFileInEditor(try makeTempFile("a.swift", "x"), pinned: true)
        let id = try XCTUnwrap(controller.workspaceView.focusedPaneID)
        let pane = try XCTUnwrap(controller.workspaceView.editorPane(for: id))
        waitUntilReady(pane)
        pane.confirmSave = { _, _ in XCTFail("nothing is unsaved") }

        XCTAssertFalse(controller.windowShouldClose(window), "the answer arrives asynchronously")
        XCTAssertTrue(pollUntilClosed(window), "…and it closes itself once it has one")
    }

    /// ⌘Q walks every window that has something to lose, and one cancel stops
    /// the whole quit.
    func testQuitPromptsEveryWindowWithDirtyEditorTabs() throws {
        let controller = makeController()
        defer { controller.close() }
        controller.showWindow(nil)
        let window = try XCTUnwrap(controller.window)
        controller.openFileInEditor(try makeTempFile("a.swift", "x"), pinned: true)
        let id = try XCTUnwrap(controller.workspaceView.focusedPaneID)
        let pane = try XCTUnwrap(controller.workspaceView.editorPane(for: id))

        // Deliberately "could hold unsaved work", not "does": whether a buffer
        // is dirty is a question only the page can answer, and answering it
        // synchronously here would mean quitting the app over a stale flag.
        // A window with no editor buffers is the one case ruled out for free.
        let empty = makeEmptyController()
        defer { empty.close() }
        empty.showWindow(nil)
        XCTAssertTrue(
            AppDelegate.controllersThatMayHaveUnsavedWork(in: [try XCTUnwrap(empty.window)]).isEmpty,
            "no editor buffers at all, nothing to ask about"
        )
        XCTAssertEqual(AppDelegate.controllersThatMayHaveUnsavedWork(in: [window]).count, 1)
        pane.modelForTesting { $0.setDirty(true, at: 0) }

        let delegate = AppDelegate()
        var replies: [Bool] = []
        delegate.replyToTermination = { replies.append($0) }

        pane.confirmSave = { _, decide in decide(.cancel) }
        delegate.promptDirtyEditorTabs(in: [controller]) { delegate.replyToTermination($0) }
        XCTAssertEqual(replies, [false], "cancel stops the quit")
        XCTAssertEqual(pane.model.tabs.count, 1, "…and nothing was thrown away")

        pane.confirmSave = { _, decide in decide(.discard) }
        delegate.promptDirtyEditorTabs(in: [controller]) { delegate.replyToTermination($0) }
        XCTAssertEqual(replies, [false, true])
        XCTAssertTrue(pane.model.tabs.isEmpty)
    }

    /// And `applicationShouldTerminate` itself defers rather than quitting
    /// out from under an unsaved buffer.
    func testApplicationShouldTerminateDefersWhileAnythingIsUnsaved() throws {
        let controller = makeController()
        defer { controller.close() }
        controller.showWindow(nil)
        controller.openFileInEditor(try makeTempFile("a.swift", "x"), pinned: true)
        let id = try XCTUnwrap(controller.workspaceView.focusedPaneID)
        let pane = try XCTUnwrap(controller.workspaceView.editorPane(for: id))
        pane.modelForTesting { $0.setDirty(true, at: 0) }

        let delegate = AppDelegate()
        var replies: [Bool] = []
        delegate.replyToTermination = { replies.append($0) }
        var asked = 0
        pane.confirmSave = { _, decide in
            asked += 1
            decide(.cancel)
        }

        let replied = expectation(description: "AppKit was answered")
        replied.assertForOverFulfill = false
        delegate.replyToTermination = {
            replies.append($0)
            replied.fulfill()
        }

        XCTAssertEqual(delegate.applicationShouldTerminate(NSApp), .terminateLater)
        XCTAssertTrue(
            replies.isEmpty,
            "reply(toApplicationShouldTerminate:) is only valid after .terminateLater has been "
                + "returned — replying inside this call is dropped and the app never quits"
        )
        wait(for: [replied], timeout: 10)
        XCTAssertGreaterThanOrEqual(asked, 1)
        XCTAssertEqual(replies, [false])

        // This test deliberately ends on "cancel", i.e. with the buffer still
        // unsaved. Left that way, a window that outlives the test would make
        // the *real* delegate put a modal alert on screen when the test host
        // quits — which nobody is there to answer.
        pane.modelForTesting { $0.setDirty(false, at: 0) }
        XCTAssertFalse(controller.hasDirtyEditorTabs)
    }

    /// Spins the run loop until a Swift-side condition holds. The dirty gates
    /// ask the page now, so a close or a drag resolves a run-loop turn or two
    /// after it is asked for.
    @discardableResult
    private func pollUntil(timeout: TimeInterval = 10, _ satisfied: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if satisfied() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        return satisfied()
    }

    private func pollUntilClosed(_ window: NSWindow) -> Bool {
        pollUntil { !window.isVisible }
    }

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
