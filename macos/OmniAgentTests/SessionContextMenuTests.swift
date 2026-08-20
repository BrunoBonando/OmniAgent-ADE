import AppKit
import XCTest

@testable import OmniAgent

/// The session row's right-click menu and the controller paths behind its
/// items — the 2026-08-20 redesign's §3
/// (docs/superpowers/specs/2026-08-20-copilot-nav-redesign-design.md):
/// Rename · Pin/Unpin · Open in… (installed apps only) · Create nested
/// session · Delete session.
final class SessionContextMenuTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: WorkspacesTreeView.collapsedDefaultsKey)
        UserDefaults.standard.removeObject(forKey: WorkspacesTreeView.groupModeDefaultsKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: WorkspacesTreeView.collapsedDefaultsKey)
        UserDefaults.standard.removeObject(forKey: WorkspacesTreeView.groupModeDefaultsKey)
        super.tearDown()
    }

    // MARK: - Menu construction

    /// The spec's shape: Rename · Pin session · Open in… · Create nested
    /// session · separator · Delete session.
    func testMenuShape() throws {
        let target = SessionContextMenu.OpenTarget(
            name: "Terminal",
            url: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        )
        let menu = SessionContextMenu.build(
            pinned: false,
            openIn: [target],
            rename: {},
            togglePin: {},
            openInApp: { _ in },
            createNested: {},
            delete: {}
        )
        XCTAssertEqual(
            menu.items.map(\.title),
            ["Rename", "Pin session", "Open in…", "Create nested session", "", "Delete session"]
        )
        XCTAssertTrue(menu.items[4].isSeparatorItem)
        XCTAssertEqual(menu.items[2].submenu?.items.map(\.title), ["Terminal"])
    }

    /// A pinned session offers Unpin.
    func testPinnedSessionOffersUnpin() {
        let menu = SessionContextMenu.build(
            pinned: true,
            openIn: [],
            rename: {},
            togglePin: {},
            openInApp: { _ in },
            createNested: {},
            delete: {}
        )
        XCTAssertEqual(menu.items[1].title, "Unpin session")
    }

    /// With nothing installed there is no Open in… item at all — an empty
    /// submenu would be a claim about apps that are not there.
    func testNoInstalledAppsDropsTheOpenInItem() {
        let menu = SessionContextMenu.build(
            pinned: false,
            openIn: [],
            rename: {},
            togglePin: {},
            openInApp: { _ in },
            createNested: {},
            delete: {}
        )
        XCTAssertEqual(
            menu.items.map(\.title),
            ["Rename", "Pin session", "Create nested session", "", "Delete session"]
        )
    }

    /// Delete session is the destructive item and wears the palette's red.
    func testDeleteSessionIsRed() throws {
        let menu = SessionContextMenu.build(
            pinned: false,
            openIn: [],
            rename: {},
            togglePin: {},
            openInApp: { _ in },
            createNested: {},
            delete: {}
        )
        let item = try XCTUnwrap(menu.items.last)
        let attributes = try XCTUnwrap(item.attributedTitle?.attributes(at: 0, effectiveRange: nil))
        XCTAssertEqual(attributes[.foregroundColor] as? NSColor, ShellPalette.red)
    }

    func testEveryActionFires() throws {
        var fired: [String] = []
        let target = SessionContextMenu.OpenTarget(
            name: "Warp",
            url: URL(fileURLWithPath: "/Applications/Warp.app")
        )
        let menu = SessionContextMenu.build(
            pinned: false,
            openIn: [target],
            rename: { fired.append("rename") },
            togglePin: { fired.append("pin") },
            openInApp: { fired.append("open \($0.name)") },
            createNested: { fired.append("nested") },
            delete: { fired.append("delete") }
        )
        for item in menu.items {
            (item as? ShellMenuItem)?.performForTesting()
            for sub in item.submenu?.items ?? [] {
                (sub as? ShellMenuItem)?.performForTesting()
            }
        }
        XCTAssertEqual(fired, ["rename", "pin", "open Warp", "nested", "delete"])
    }

    // MARK: - Installed-app detection

    /// The spec's candidate list, in its order, by bundle id.
    func testCandidateApps() {
        XCTAssertEqual(
            SessionContextMenu.candidateApps.map(\.name),
            [
                "VS Code", "VS Code Insiders", "Terminal", "Cursor",
                "Xcode", "iTerm", "Warp", "Ghostty",
            ]
        )
        XCTAssertEqual(
            SessionContextMenu.candidateApps.map(\.bundleID),
            [
                "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders",
                "com.apple.Terminal", "com.todesktop.230313mzl4w4u92",
                "com.apple.dt.Xcode", "com.googlecode.iterm2",
                "dev.warp.Warp-Stable", "com.mitchellh.ghostty",
            ]
        )
    }

    /// Only candidates the locator resolves make the list, in candidate
    /// order, each carrying the app URL the locator answered.
    func testInstalledAppsKeepsOnlyWhatTheLocatorFinds() {
        let installed = SessionContextMenu.installedApps { bundleID in
            bundleID == "com.apple.Terminal" || bundleID == "com.mitchellh.ghostty"
                ? URL(fileURLWithPath: "/Applications/\(bundleID).app")
                : nil
        }
        XCTAssertEqual(installed.map(\.name), ["Terminal", "Ghostty"])
        XCTAssertEqual(
            installed.map(\.url.path),
            ["/Applications/com.apple.Terminal.app", "/Applications/com.mitchellh.ghostty.app"]
        )
    }

    // MARK: - The controller's menu

    /// The tree's session-row right-click asks the controller, which answers
    /// with the session's own menu.
    func testTheTreeAsksTheControllerForTheSessionMenu() throws {
        let controller = makeController(panes: [
            PersistedTab(project: "alpha", engine: .claude, cwd: "/tmp/alpha", id: "s-1", group: "g-1"),
        ])
        defer { controller.close() }
        controller.appLocator = { _ in nil }
        let tree = controller.shellSidebar.workspacesTree
        let row = try XCTUnwrap(sessionRow(in: tree, group: "g-1"))
        let menu = try XCTUnwrap(row.menu(for: rightClickEvent(in: row)))
        XCTAssertEqual(menu.items.first?.title, "Rename")
        XCTAssertEqual(menu.items.last?.title, "Delete session")
    }

    /// Rename triggers the row's existing inline rename, not a new dialog.
    func testRenameBeginsTheInlineRenameOnTheRow() throws {
        let controller = makeController(panes: [
            PersistedTab(project: "alpha", engine: .claude, cwd: "/tmp/alpha", id: "s-1", group: "g-1"),
        ])
        defer { controller.close() }
        controller.appLocator = { _ in nil }
        let row = try XCTUnwrap(sessionRow(in: controller.shellSidebar.workspacesTree, group: "g-1"))
        XCTAssertFalse(row.isRenaming)
        let menu = controller.sessionContextMenu(for: row.session)
        try XCTUnwrap(menu.items.first as? ShellMenuItem).performForTesting()
        XCTAssertTrue(row.isRenaming)
    }

    // MARK: - Pinning

    /// Pinning sorts the session first in its workspace, persists to the
    /// `session_meta_native` row, and flips the item to Unpin; unpinning
    /// restores the natural order and empties the row.
    func testPinningSortsFirstPersistsAndUnpinRestores() throws {
        let controller = makeController(panes: [
            PersistedTab(project: "alpha", engine: .claude, cwd: "/tmp/alpha", id: "s-1", group: "g-1"),
            PersistedTab(project: "alpha", engine: .claude, cwd: "/tmp/alpha", id: "s-2", group: "g-2"),
        ])
        defer { controller.close() }
        controller.appLocator = { _ in nil }
        var written: [String: String] = [:]
        controller.settingsWriter = { key, value in written[key] = value }
        controller.applyRestoredSessionMeta(nil)
        let tree = controller.shellSidebar.workspacesTree
        XCTAssertEqual(tree.renderedSessionIDs, ["g-1", "g-2"])

        let row = try XCTUnwrap(sessionRow(in: tree, group: "g-2"))
        let menu = controller.sessionContextMenu(for: row.session)
        XCTAssertEqual(menu.items[1].title, "Pin session")
        try XCTUnwrap(menu.items[1] as? ShellMenuItem).performForTesting()

        XCTAssertEqual(tree.renderedSessionIDs, ["g-2", "g-1"], "pinned sorts first")
        XCTAssertEqual(
            SessionMetaCodec.deserialize(written[SettingsKey.sessionMeta]),
            ["g-2": SessionMeta(pinned: true)]
        )

        let pinnedRow = try XCTUnwrap(sessionRow(in: tree, group: "g-2"))
        let unpinMenu = controller.sessionContextMenu(for: pinnedRow.session)
        XCTAssertEqual(unpinMenu.items[1].title, "Unpin session")
        try XCTUnwrap(unpinMenu.items[1] as? ShellMenuItem).performForTesting()
        XCTAssertEqual(tree.renderedSessionIDs, ["g-1", "g-2"])
        XCTAssertEqual(SessionMetaCodec.deserialize(written[SettingsKey.sessionMeta]), [:])
    }

    // MARK: - Nested sessions

    /// Create nested session starts a session in the same workspace with
    /// `parent` recorded in the persisted row, and the tree renders it
    /// indented under its parent with the connector and the dimmed
    /// workspace name at the row's right edge.
    func testCreateNestedSessionRecordsTheParentAndRendersIndented() throws {
        let controller = makeController(panes: [
            PersistedTab(project: "alpha", engine: .claude, cwd: "/tmp/alpha", id: "s-1", group: "g-1"),
        ])
        defer { controller.close() }
        controller.appLocator = { _ in nil }
        var written: [String: String] = [:]
        controller.settingsWriter = { key, value in written[key] = value }
        controller.applyRestoredSessionMeta(nil)
        let tree = controller.shellSidebar.workspacesTree
        let parentRow = try XCTUnwrap(sessionRow(in: tree, group: "g-1"))
        let before = Set(controller.workspaceView.allPaneIDs)

        let menu = controller.sessionContextMenu(for: parentRow.session)
        let nestedItem = try XCTUnwrap(
            menu.items.first { $0.title == "Create nested session" } as? ShellMenuItem
        )
        nestedItem.performForTesting()

        let added = Set(controller.workspaceView.allPaneIDs).subtracting(before)
        XCTAssertEqual(added.count, 1)
        let pane = try XCTUnwrap(
            controller.workspaceView.descriptor(for: try XCTUnwrap(added.first))
        )
        XCTAssertEqual(pane.project, "alpha", "same workspace")
        XCTAssertEqual(pane.cwd, "/tmp/alpha")
        XCTAssertEqual(
            SessionMetaCodec.deserialize(written[SettingsKey.sessionMeta]),
            [pane.group: SessionMeta(pinned: false, parent: "g-1")]
        )
        XCTAssertEqual(tree.renderedSessionIDs, ["g-1", pane.group], "indented under its parent")
        let nestedRow = try XCTUnwrap(sessionRow(in: tree, group: pane.group))
        XCTAssertTrue(nestedRow.isNested)
        XCTAssertNotNil(nestedRow.connector, "the small tree connector line")
        XCTAssertEqual(nestedRow.workspaceTag?.stringValue, "alpha", "the dimmed workspace name")
        let parent = try XCTUnwrap(sessionRow(in: tree, group: "g-1"))
        XCTAssertFalse(parent.isNested)
        XCTAssertNil(parent.workspaceTag)
    }

    /// The recorded parent survives a relaunch: restoring the row re-nests
    /// the session.
    func testARestoredParentStillNests() throws {
        let controller = makeController(panes: [
            PersistedTab(project: "alpha", engine: .claude, cwd: "/tmp/alpha", id: "s-1", group: "g-1"),
            PersistedTab(project: "alpha", engine: .claude, cwd: "/tmp/alpha", id: "s-2", group: "g-2"),
        ])
        defer { controller.close() }
        controller.applyRestoredSessionMeta(
            SessionMetaCodec.serialize(["g-2": SessionMeta(pinned: false, parent: "g-1")])
        )
        let tree = controller.shellSidebar.workspacesTree
        XCTAssertEqual(tree.renderedSessionIDs, ["g-1", "g-2"])
        XCTAssertTrue(try XCTUnwrap(sessionRow(in: tree, group: "g-2")).isNested)
    }

    /// Restoring the row prunes entries for groups no pane carries any more
    /// — and writes the pruned row back so the next launch reads it clean.
    func testRestorePrunesEntriesForVanishedGroups() throws {
        let controller = makeController(panes: [
            PersistedTab(project: "alpha", engine: .claude, cwd: "/tmp/alpha", id: "s-1", group: "g-1"),
        ])
        defer { controller.close() }
        var written: [String: String] = [:]
        controller.settingsWriter = { key, value in written[key] = value }
        controller.applyRestoredSessionMeta(
            SessionMetaCodec.serialize([
                "g-1": SessionMeta(pinned: true, parent: "g-gone"),
                "g-gone": SessionMeta(pinned: true),
            ])
        )
        XCTAssertEqual(controller.sessionMeta, ["g-1": SessionMeta(pinned: true)])
        XCTAssertEqual(
            SessionMetaCodec.deserialize(written[SettingsKey.sessionMeta]),
            ["g-1": SessionMeta(pinned: true)]
        )
    }

    // MARK: - Open in…

    /// The submenu's items open the session's own cwd in the chosen app,
    /// through the opener seam.
    func testOpenInOpensTheSessionCwdInTheChosenApp() throws {
        let controller = makeController(panes: [
            PersistedTab(project: "alpha", engine: .claude, cwd: "/tmp/alpha", id: "s-1", group: "g-1"),
        ])
        defer { controller.close() }
        controller.appLocator = { bundleID in
            bundleID == "com.apple.Terminal" ? URL(fileURLWithPath: "/Applications/Terminal.app") : nil
        }
        var opened: [(app: URL, directory: String)] = []
        controller.appOpener = { app, directory in opened.append((app, directory)) }
        let row = try XCTUnwrap(sessionRow(in: controller.shellSidebar.workspacesTree, group: "g-1"))

        let menu = controller.sessionContextMenu(for: row.session)
        let openIn = try XCTUnwrap(menu.items.first { $0.title == "Open in…" })
        XCTAssertEqual(openIn.submenu?.items.map(\.title), ["Terminal"])
        try XCTUnwrap(openIn.submenu?.items.first as? ShellMenuItem).performForTesting()

        XCTAssertEqual(opened.count, 1)
        XCTAssertEqual(opened.first?.app.path, "/Applications/Terminal.app")
        XCTAssertEqual(opened.first?.directory, "/tmp/alpha")
    }

    // MARK: - Delete session

    /// Delete asks first — naming the session and its pane count — then
    /// destroys every pane in the group through the existing close path
    /// (daemon kills included) and prunes the session's meta entry.
    func testDeleteSessionConfirmsDestroysPanesAndPrunesMeta() throws {
        let controller = makeController(panes: [
            PersistedTab(project: "alpha", engine: .claude, cwd: "/tmp/alpha", id: "s-1", group: "g-1"),
            PersistedTab(project: "alpha", engine: .codex, cwd: "/tmp/alpha", id: "s-2", group: "g-1"),
            PersistedTab(project: "alpha", engine: .claude, cwd: "/tmp/alpha", id: "s-3", group: "g-2"),
        ])
        defer { controller.close() }
        controller.appLocator = { _ in nil }
        var killed: [String] = []
        controller.sessionKiller = { killed.append($0) }
        var written: [String: String] = [:]
        controller.settingsWriter = { key, value in written[key] = value }
        controller.applyRestoredSessionMeta(
            SessionMetaCodec.serialize(["g-1": SessionMeta(pinned: true)])
        )
        var asked: [(label: String, panes: Int)] = []
        controller.sessionDeletionConfirmer = { label, panes, completion in
            asked.append((label, panes))
            completion(true)
        }
        let tree = controller.shellSidebar.workspacesTree
        let row = try XCTUnwrap(sessionRow(in: tree, group: "g-1"))

        let menu = controller.sessionContextMenu(for: row.session)
        try XCTUnwrap(menu.items.last as? ShellMenuItem).performForTesting()

        XCTAssertEqual(asked.count, 1)
        XCTAssertEqual(asked.first?.label, row.session.label)
        XCTAssertEqual(asked.first?.panes, 2)
        XCTAssertEqual(Set(killed), ["s-1", "s-2"], "every terminal in the group — g-2's stays")
        XCTAssertNil(controller.workspaceView.descriptor(for: "s-1"))
        XCTAssertNil(controller.workspaceView.descriptor(for: "s-2"))
        XCTAssertNotNil(controller.workspaceView.descriptor(for: "s-3"))
        XCTAssertEqual(tree.renderedSessionIDs, ["g-2"])
        XCTAssertEqual(
            SessionMetaCodec.deserialize(written[SettingsKey.sessionMeta]),
            [:],
            "the deleted session's meta entry is pruned"
        )
    }

    /// Declining the confirmation changes nothing.
    func testDecliningDeletionChangesNothing() throws {
        let controller = makeController(panes: [
            PersistedTab(project: "alpha", engine: .claude, cwd: "/tmp/alpha", id: "s-1", group: "g-1"),
        ])
        defer { controller.close() }
        controller.appLocator = { _ in nil }
        var killed: [String] = []
        controller.sessionKiller = { killed.append($0) }
        controller.applyRestoredSessionMeta(nil)
        controller.sessionDeletionConfirmer = { _, _, completion in completion(false) }
        let tree = controller.shellSidebar.workspacesTree
        let row = try XCTUnwrap(sessionRow(in: tree, group: "g-1"))

        let menu = controller.sessionContextMenu(for: row.session)
        try XCTUnwrap(menu.items.last as? ShellMenuItem).performForTesting()

        XCTAssertEqual(killed, [])
        XCTAssertNotNil(controller.workspaceView.descriptor(for: "s-1"))
        XCTAssertEqual(tree.renderedSessionIDs, ["g-1"])
    }

    /// A session holding an editor pane with unsaved work gets ⌘W's gate,
    /// not `destroyPane`'s unguarded half: the delete drains the dirty tabs
    /// with save prompts first, and a cancel there aborts the whole deletion
    /// with every pane — and the unsaved buffer — intact.
    func testDeleteSessionDrainsDirtyEditorPanesBeforeDestroying() throws {
        let controller = makeController(panes: [
            PersistedTab(project: "alpha", engine: .claude, cwd: "/tmp/alpha", id: "s-1", group: "g-1"),
        ])
        defer { controller.close() }
        controller.showWindow(nil)
        controller.appLocator = { _ in nil }
        var killed: [String] = []
        controller.sessionKiller = { killed.append($0) }
        controller.applyRestoredSessionMeta(nil)
        controller.sessionDeletionConfirmer = { _, _, completion in completion(true) }
        // An editor pane in the session, holding an unsaved buffer.
        controller.openFileInEditor(try makeTempFile("a.swift", "x"), pinned: true)
        let workspace = controller.workspaceView
        let editorID = try XCTUnwrap(workspace.focusedPaneID)
        let pane = try XCTUnwrap(workspace.editorPane(for: editorID))
        pane.modelForTesting { $0.setDirty(true, at: 0) }
        let tree = controller.shellSidebar.workspacesTree
        let session = try XCTUnwrap(sessionRow(in: tree, group: "g-1")).session
        XCTAssertTrue(session.paneIDs.count >= 2, "the editor pane joined the session")

        // Cancelling the save prompt aborts the deletion — nothing dies.
        pane.confirmSave = { _, decide in decide(.cancel) }
        controller.deleteSession(session)
        XCTAssertEqual(killed, [])
        XCTAssertNotNil(workspace.descriptor(for: "s-1"), "cancel kept the terminal")
        XCTAssertNotNil(workspace.editorPane(for: editorID), "…and the editor pane")
        XCTAssertEqual(pane.model.tabs.count, 1, "…and the unsaved buffer with it")

        // Discarding resolves the drain and the whole session goes.
        pane.confirmSave = { _, decide in decide(.discard) }
        controller.deleteSession(session)
        XCTAssertEqual(killed, ["s-1"])
        XCTAssertNil(workspace.descriptor(for: "s-1"))
        XCTAssertNil(workspace.editorPane(for: editorID))
    }

    // MARK: - Helpers

    private func makeTempFile(_ name: String, _ contents: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("session-menu-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func makeController(panes: [PersistedTab]) -> WorkspaceWindowController {
        let controller = WorkspaceWindowController(
            connection: SessionConnection(
                socketURL: URL(fileURLWithPath: "/tmp/omniagent-session-menu-test.sock")
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

    private func sessionRow(in tree: WorkspacesTreeView, group: String) -> SessionRowView? {
        tree.rowView(for: .session(group)) as? SessionRowView
    }

    private func rightClickEvent(in view: NSView) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .rightMouseDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: view.window?.windowNumber ?? 0,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            )
        )
    }
}
