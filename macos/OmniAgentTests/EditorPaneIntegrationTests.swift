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

    // MARK: - Helpers

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
