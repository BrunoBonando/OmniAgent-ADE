import AppKit
import XCTest

@testable import OmniAgent

/// The workspace row's right-click menu, the Customize… card behind its
/// item, and the Remove-workspace path — the 2026-08-20 redesign's §3
/// (docs/superpowers/specs/2026-08-20-copilot-nav-redesign-design.md).
final class WorkspaceContextMenuTests: XCTestCase {
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

    /// The spec's shape without a GitHub remote: New session · Show in
    /// Finder · separator · Customize… · separator · Remove workspace.
    func testMenuShapeWithoutAGitHubRemote() throws {
        let menu = WorkspaceContextMenu.build(
            gitHubURL: nil,
            newSession: {},
            showInFinder: {},
            openOnGitHub: { _ in },
            customize: {},
            remove: {}
        )
        XCTAssertEqual(
            menu.items.map(\.title),
            ["New session", "Show in Finder", "", "Customize…", "", "Remove workspace"]
        )
        XCTAssertTrue(menu.items[2].isSeparatorItem)
        XCTAssertTrue(menu.items[4].isSeparatorItem)
    }

    /// With a GitHub remote the item appears between Show in Finder and the
    /// first separator, and fires with the repository page URL.
    func testMenuShapeWithAGitHubRemote() throws {
        var opened: [URL] = []
        let url = try XCTUnwrap(URL(string: "https://github.com/owner/repo"))
        let menu = WorkspaceContextMenu.build(
            gitHubURL: url,
            newSession: {},
            showInFinder: {},
            openOnGitHub: { opened.append($0) },
            customize: {},
            remove: {}
        )
        XCTAssertEqual(
            menu.items.map(\.title),
            [
                "New session", "Show in Finder", "Open on GitHub", "",
                "Customize…", "", "Remove workspace",
            ]
        )
        try XCTUnwrap(menu.items[2] as? ShellMenuItem).performForTesting()
        XCTAssertEqual(opened, [url])
    }

    /// Remove workspace is the destructive item and wears the palette's red.
    func testRemoveWorkspaceIsRed() throws {
        let menu = WorkspaceContextMenu.build(
            gitHubURL: nil,
            newSession: {},
            showInFinder: {},
            openOnGitHub: { _ in },
            customize: {},
            remove: {}
        )
        let item = try XCTUnwrap(menu.items.last)
        let attributes = try XCTUnwrap(item.attributedTitle?.attributes(at: 0, effectiveRange: nil))
        XCTAssertEqual(attributes[.foregroundColor] as? NSColor, ShellPalette.red)
    }

    func testEveryActionFires() throws {
        var fired: [String] = []
        let menu = WorkspaceContextMenu.build(
            gitHubURL: nil,
            newSession: { fired.append("new") },
            showInFinder: { fired.append("finder") },
            openOnGitHub: { _ in },
            customize: { fired.append("customize") },
            remove: { fired.append("remove") }
        )
        for item in menu.items {
            (item as? ShellMenuItem)?.performForTesting()
        }
        XCTAssertEqual(fired, ["new", "finder", "customize", "remove"])
    }

    // MARK: - GitHub remote parsing

    /// Every shape `git remote get-url origin` actually answers with, mapped
    /// to the https repository page; anything not github.com is `nil`.
    func testGitHubRepositoryURLFromRemote() {
        let expectations: [(String, String?)] = [
            ("git@github.com:owner/repo.git", "https://github.com/owner/repo"),
            ("git@github.com:owner/repo", "https://github.com/owner/repo"),
            ("https://github.com/owner/repo.git", "https://github.com/owner/repo"),
            ("https://github.com/owner/repo", "https://github.com/owner/repo"),
            ("ssh://git@github.com/owner/repo.git", "https://github.com/owner/repo"),
            ("git://github.com/owner/repo.git", "https://github.com/owner/repo"),
            ("https://github.com/owner/repo/", "https://github.com/owner/repo"),
            ("https://gitlab.com/owner/repo.git", nil),
            ("git@bitbucket.org:owner/repo.git", nil),
            ("", nil),
            ("github.com", nil),
        ]
        for (remote, expected) in expectations {
            XCTAssertEqual(
                WorkspaceContextMenu.gitHubRepositoryURL(fromRemote: remote)?.absoluteString,
                expected,
                "remote: \(remote)"
            )
        }
    }

    /// Off a real repository: a github.com origin is found, a directory
    /// without one answers `nil`.
    func testGitHubRepositoryURLInDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("om-menu-git-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertNil(
            WorkspaceContextMenu.gitHubRepositoryURL(inDirectory: root.path),
            "no repository, no remote"
        )
        try runGit(["-C", root.path, "init", "-q"])
        XCTAssertNil(
            WorkspaceContextMenu.gitHubRepositoryURL(inDirectory: root.path),
            "a repository without an origin"
        )
        try runGit(["-C", root.path, "remote", "add", "origin", "git@github.com:owner/repo.git"])
        XCTAssertEqual(
            WorkspaceContextMenu.gitHubRepositoryURL(inDirectory: root.path)?.absoluteString,
            "https://github.com/owner/repo"
        )
    }

    // MARK: - The controller's menu

    /// The controller wires the tree's right-click to a real menu for the
    /// row's workspace.
    func testTheTreeAsksTheControllerForTheMenu() throws {
        let controller = makeController(panes: [
            PersistedTab(project: "alpha", engine: .claude, cwd: "/tmp", id: "s-1", group: "g-1"),
        ])
        defer { controller.close() }
        let tree = controller.shellSidebar.workspacesTree
        XCTAssertEqual(tree.renderedWorkspaceIDs, ["alpha"])
        let row = try XCTUnwrap(firstWorkspaceRow(in: tree))
        let menu = try XCTUnwrap(row.menu(for: rightClickEvent(in: row)))
        XCTAssertEqual(menu.items.first?.title, "New session")
        XCTAssertEqual(menu.items.last?.title, "Remove workspace")
    }

    /// The menu's New session lands in the workspace's own directory, the
    /// same seam the header's plus menu uses.
    func testNewSessionStartsInTheWorkspace() throws {
        let controller = makeController(panes: [
            PersistedTab(project: "alpha", engine: .claude, cwd: "/tmp/alpha", id: "s-1", group: "g-1"),
        ])
        defer { controller.close() }
        controller.sessionEnsurer = { _ in }
        controller.sessionKiller = { _ in }
        let before = Set(controller.workspaceView.allPaneIDs)
        let menu = controller.workspaceContextMenu(for: "alpha")
        try XCTUnwrap(menu.items.first as? ShellMenuItem).performForTesting()
        let added = Set(controller.workspaceView.allPaneIDs).subtracting(before)
        XCTAssertEqual(added.count, 1)
        let pane = try XCTUnwrap(controller.workspaceView.descriptor(for: try XCTUnwrap(added.first)))
        XCTAssertEqual(pane.project, "alpha")
        XCTAssertEqual(pane.cwd, "/tmp/alpha")
    }

    /// Show in Finder reveals the workspace directory through the test seam.
    func testShowInFinderRevealsTheDirectory() throws {
        let controller = makeController(panes: [
            PersistedTab(project: "alpha", engine: .claude, cwd: "/tmp/alpha", id: "s-1", group: "g-1"),
        ])
        defer { controller.close() }
        var revealed: [String] = []
        controller.fileRevealer = { revealed.append($0) }
        let menu = controller.workspaceContextMenu(for: "alpha")
        try XCTUnwrap(menu.items[1] as? ShellMenuItem).performForTesting()
        XCTAssertEqual(revealed, ["/tmp/alpha"])
    }

    // MARK: - Customize…

    /// The card opens seeded per spec: title, the folder name as the field's
    /// placeholder, the caption naming the fallback, eight swatches, Cancel
    /// and Save.
    func testCustomizeCardOpensSeededWithTheFolderName() throws {
        let controller = makeController(panes: [
            PersistedTab(project: "alpha", engine: .claude, cwd: "/tmp/alpha", id: "s-1", group: "g-1"),
        ])
        defer { controller.close() }
        controller.showWindow(nil)
        controller.presentCustomizeWorkspace("alpha")
        let card = try XCTUnwrap(controller.customizeCard)
        XCTAssertEqual(card.titleText, "Customize Workspace")
        XCTAssertEqual(card.placeholder, "alpha")
        XCTAssertEqual(card.captionText, "Leave blank to use alpha")
        XCTAssertEqual(card.swatches.count, 8)
        XCTAssertEqual(card.swatches.map(\.color), WorkspaceColor.allCases)
        XCTAssertNil(card.selectedColor)
        card.cancel()
        XCTAssertNil(controller.customizeCard)
    }

    /// Saving persists the customization keyed by the workspace's path and
    /// re-renders the row with the display name and the tinted folder.
    func testSavingCustomizationPersistsAndRetints() throws {
        let controller = makeController(panes: [
            PersistedTab(project: "alpha", engine: .claude, cwd: "/tmp/alpha", id: "s-1", group: "g-1"),
        ])
        defer { controller.close() }
        controller.showWindow(nil)
        var written: [String: String] = [:]
        controller.settingsWriter = { key, value in written[key] = value }
        controller.applyRestoredWorkspaceCustomizations(nil)

        controller.presentCustomizeWorkspace("alpha")
        let card = try XCTUnwrap(controller.customizeCard)
        card.type("Mission Control")
        card.selectColor(.gold)
        card.save()

        XCTAssertNil(controller.customizeCard, "saving dismisses the card")
        let raw = try XCTUnwrap(written[SettingsKey.workspaceCustomizations])
        XCTAssertEqual(
            WorkspaceCustomizationsCodec.deserialize(raw),
            ["/tmp/alpha": WorkspaceCustomization(displayName: "Mission Control", color: .gold)]
        )
        let row = try XCTUnwrap(firstWorkspaceRow(in: controller.shellSidebar.workspacesTree))
        XCTAssertEqual(row.titleText, "Mission Control")
        XCTAssertEqual(row.folderGlyph.color, WorkspaceColor.gold.tint)
    }

    /// Reopening the card shows what is stored, and saving it blank puts the
    /// label back to the folder's own name.
    func testSavingBlankClearsTheCustomization() throws {
        let controller = makeController(panes: [
            PersistedTab(project: "alpha", engine: .claude, cwd: "/tmp/alpha", id: "s-1", group: "g-1"),
        ])
        defer { controller.close() }
        controller.showWindow(nil)
        var written: [String: String] = [:]
        controller.settingsWriter = { key, value in written[key] = value }
        controller.applyRestoredWorkspaceCustomizations(
            WorkspaceCustomizationsCodec.serialize(
                ["/tmp/alpha": WorkspaceCustomization(displayName: "Mission Control", color: .gold)]
            )
        )

        controller.presentCustomizeWorkspace("alpha")
        let card = try XCTUnwrap(controller.customizeCard)
        XCTAssertEqual(card.nameText, "Mission Control")
        XCTAssertEqual(card.selectedColor, .gold)
        card.type("   ")
        card.selectColor(nil)
        card.save()

        let raw = try XCTUnwrap(written[SettingsKey.workspaceCustomizations])
        XCTAssertEqual(WorkspaceCustomizationsCodec.deserialize(raw), [:])
        let row = try XCTUnwrap(firstWorkspaceRow(in: controller.shellSidebar.workspacesTree))
        XCTAssertEqual(row.titleText, "alpha")
        XCTAssertEqual(row.folderGlyph.color, ShellPalette.folderGlyph)
    }

    /// Clicking the selected swatch deselects it — back to the default tint.
    func testClickingTheSelectedSwatchDeselects() throws {
        let card = WorkspaceCustomizeCard(
            folderName: "alpha",
            current: WorkspaceCustomization(displayName: nil, color: .blue)
        )
        let blue = try XCTUnwrap(card.swatches.first { $0.color == .blue })
        XCTAssertTrue(blue.isSelected)
        try XCTUnwrap(blue.onPick)()
        XCTAssertNil(card.selectedColor)
        try XCTUnwrap(blue.onPick)()
        XCTAssertEqual(card.selectedColor, .blue)
    }

    // MARK: - Remove workspace

    /// Remove asks first — naming the workspace and its sessions — then
    /// kills every daemon session in it, closes its panes, and records the
    /// workspace closed in the web build's own `closed_workspaces` row.
    func testRemoveWorkspaceConfirmsKillsSessionsAndPersistsTheClosure() throws {
        let controller = makeController(panes: [
            PersistedTab(project: "alpha", engine: .claude, cwd: "/tmp/alpha", id: "s-1", group: "g-1"),
            PersistedTab(project: "alpha", engine: .codex, cwd: "/tmp/alpha", id: "s-2", group: "g-2"),
            PersistedTab(project: "beta", engine: .claude, cwd: "/tmp/beta", id: "s-3", group: "g-3"),
        ])
        defer { controller.close() }
        var killed: [String] = []
        controller.sessionKiller = { killed.append($0) }
        var written: [String: String] = [:]
        controller.settingsWriter = { key, value in written[key] = value }
        controller.applyRestoredClosedWorkspaces(nil)
        var asked: [(label: String, sessions: Int)] = []
        controller.workspaceRemovalConfirmer = { label, sessions, completion in
            asked.append((label, sessions))
            completion(true)
        }

        controller.removeWorkspace("alpha")

        XCTAssertEqual(asked.count, 1)
        XCTAssertEqual(asked.first?.label, "alpha")
        XCTAssertEqual(asked.first?.sessions, 2)
        XCTAssertEqual(Set(killed), ["s-1", "s-2"], "its sessions end with it — beta's does not")
        XCTAssertNil(controller.workspaceView.descriptor(for: "s-1"))
        XCTAssertNil(controller.workspaceView.descriptor(for: "s-2"))
        XCTAssertNotNil(controller.workspaceView.descriptor(for: "s-3"))
        XCTAssertEqual(
            ClosedWorkspacesCodec.deserialize(written[SettingsKey.closedWorkspaces]),
            ["alpha"]
        )
        XCTAssertEqual(
            controller.shellSidebar.workspacesTree.renderedWorkspaceIDs,
            ["beta"],
            "the removed workspace leaves the tree"
        )
    }

    /// Declining the confirmation changes nothing.
    func testDecliningRemovalChangesNothing() throws {
        let controller = makeController(panes: [
            PersistedTab(project: "alpha", engine: .claude, cwd: "/tmp/alpha", id: "s-1", group: "g-1"),
        ])
        defer { controller.close() }
        var killed: [String] = []
        controller.sessionKiller = { killed.append($0) }
        controller.applyRestoredClosedWorkspaces(nil)
        controller.workspaceRemovalConfirmer = { _, _, completion in completion(false) }

        controller.removeWorkspace("alpha")

        XCTAssertEqual(killed, [])
        XCTAssertNotNil(controller.workspaceView.descriptor(for: "s-1"))
        XCTAssertEqual(controller.shellSidebar.workspacesTree.renderedWorkspaceIDs, ["alpha"])
    }

    /// Starting a session in a closed workspace reopens it — the web
    /// build's `reopenWorkspace` rule, so the two builds agree about the row.
    func testStartingASessionReopensAClosedWorkspace() throws {
        let controller = makeController(panes: [
            PersistedTab(project: "alpha", engine: .claude, cwd: "/tmp/alpha", id: "s-1", group: "g-1"),
        ])
        defer { controller.close() }
        controller.sessionKiller = { _ in }
        controller.sessionEnsurer = { _ in }
        var written: [String: String] = [:]
        controller.settingsWriter = { key, value in written[key] = value }
        controller.applyRestoredClosedWorkspaces(nil)
        controller.workspaceRemovalConfirmer = { _, _, completion in completion(true) }
        controller.removeWorkspace("alpha")
        XCTAssertEqual(
            ClosedWorkspacesCodec.deserialize(written[SettingsKey.closedWorkspaces]),
            ["alpha"]
        )

        controller.startSession(inDirectory: "/tmp/alpha", project: "alpha")

        XCTAssertEqual(
            ClosedWorkspacesCodec.deserialize(written[SettingsKey.closedWorkspaces]),
            []
        )
        XCTAssertEqual(controller.shellSidebar.workspacesTree.renderedWorkspaceIDs, ["alpha"])
    }

    /// The pure filter the outline applies to the brain's project list —
    /// the web build's `openWorkspaces`, shape-for-shape.
    func testOpenWorkspacesFilter() {
        let projects = [
            BrainProjectSummary(id: "a", label: "A", path: "/a"),
            BrainProjectSummary(id: "b", label: "B", path: "/b"),
        ]
        XCTAssertEqual(WorkspaceWindowController.openWorkspaces(projects, closed: []), projects)
        XCTAssertEqual(
            WorkspaceWindowController.openWorkspaces(projects, closed: ["a"]).map(\.id),
            ["b"]
        )
    }

    // MARK: - Helpers

    private func makeController(panes: [PersistedTab]) -> WorkspaceWindowController {
        let controller = WorkspaceWindowController(
            connection: SessionConnection(
                socketURL: URL(fileURLWithPath: "/tmp/omniagent-workspace-menu-test.sock")
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

    private func firstWorkspaceRow(in tree: WorkspacesTreeView) -> WorkspaceRowView? {
        firstWorkspaceRow(under: tree)
    }

    private func firstWorkspaceRow(under view: NSView) -> WorkspaceRowView? {
        for subview in view.subviews {
            if let match = subview as? WorkspaceRowView { return match }
            if let match = firstWorkspaceRow(under: subview) { return match }
        }
        return nil
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

    private func runGit(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "git \(arguments.joined(separator: " "))")
    }
}
