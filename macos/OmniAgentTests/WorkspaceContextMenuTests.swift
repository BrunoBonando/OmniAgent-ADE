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
            remoteControlEnabled: false,
            toggleRemoteControl: {},
            remove: {}
        )
        XCTAssertEqual(
            menu.items.map(\.title),
            [
                "New session", "Show in Finder", "", "Customize…",
                "Enable Remote Control", "", "Remove workspace",
            ]
        )
        XCTAssertTrue(menu.items[2].isSeparatorItem)
        XCTAssertTrue(menu.items[5].isSeparatorItem)
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
            remoteControlEnabled: false,
            toggleRemoteControl: {},
            remove: {}
        )
        XCTAssertEqual(
            menu.items.map(\.title),
            [
                "New session", "Show in Finder", "Open on GitHub", "",
                "Customize…", "Enable Remote Control", "", "Remove workspace",
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
            remoteControlEnabled: false,
            toggleRemoteControl: {},
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
            remoteControlEnabled: false,
            toggleRemoteControl: { fired.append("remote") },
            remove: { fired.append("remove") }
        )
        for item in menu.items {
            (item as? ShellMenuItem)?.performForTesting()
        }
        XCTAssertEqual(fired, ["new", "finder", "customize", "remote", "remove"])
    }

    /// Enable Remote Control is a check-toggle: the checkmark is the only
    /// place the menu says whether this workspace is currently offered to
    /// other machines (the remote-session-control spec's §2).
    func testEnableRemoteControlCarriesItsCheckmark() throws {
        for enabled in [true, false] {
            let menu = WorkspaceContextMenu.build(
                gitHubURL: nil,
                newSession: {},
                showInFinder: {},
                openOnGitHub: { _ in },
                customize: {},
                remoteControlEnabled: enabled,
                toggleRemoteControl: {},
                remove: {}
            )
            let item = try XCTUnwrap(menu.items.first { $0.title == "Enable Remote Control" })
            XCTAssertEqual(item.state, enabled ? .on : .off)
        }
    }

    // MARK: - Enable Remote Control (2026-08-30 remote-session-control spec §2)

    /// The first enable does all four things at once: stores the intent,
    /// writes the projection the daemon authorizes against, registers this
    /// Mac with the relay, and lights the row's globe. Only the enabled
    /// workspace is in the projection — that is the whole trust boundary.
    func testEnablingRemoteControlWritesBothRowsRegistersOnceAndLightsTheGlobe() throws {
        let controller = makeController(panes: [
            PersistedTab(project: "alpha", engine: .claude, cwd: "/tmp/alpha", id: "s-1", label: "one", group: "g-1"),
            PersistedTab(project: "beta", engine: .shell, cwd: "/tmp/beta", id: "s-2", group: "g-2"),
        ])
        defer { controller.close() }
        controller.showWindow(nil)

        var written: [String: String] = [:]
        let registered = expectation(description: "the device token row is written")
        controller.settingsWriter = { key, value in
            written[key] = value
            if key == SettingsKey.relayDeviceToken { registered.fulfill() }
        }
        var registrations: [String] = []
        controller.relayDeviceRegistrar = { name in
            registrations.append(name)
            return RelayClient.Registration(deviceID: "d1", token: "secret")
        }
        // The token row read as absent — the one state an enable may register
        // from.
        controller.applyRestoredRelayDeviceToken(nil)

        controller.toggleRemoteControl(workspaceID: "alpha")

        XCTAssertEqual(
            RemoteControlProjection.decodeEnabled(written[SettingsKey.remoteControlWorkspaces]),
            ["alpha"]
        )
        let payload = RemoteControlProjection.decode(written[SettingsKey.remoteControl])
        XCTAssertEqual(payload.workspaces.map(\.id), ["alpha"], "only the enabled workspace is projected")
        XCTAssertEqual(payload.workspaces[0].sessions.map(\.id), ["s-1"])
        XCTAssertEqual(payload.workspaces[0].sessions[0].engine, "claude")
        XCTAssertEqual(payload.workspaces[0].sessions[0].title, "one")

        let row = try XCTUnwrap(firstWorkspaceRow(in: controller.shellSidebar.workspacesTree))
        XCTAssertEqual(row.workspaceID, "alpha")
        XCTAssertFalse(row.remoteGlyph.isHidden)

        wait(for: [registered], timeout: 5)
        XCTAssertEqual(registrations.count, 1)
        XCTAssertEqual(
            written[SettingsKey.relayDeviceToken],
            RelayClient.shared.deviceTokenRow(
                RelayClient.Registration(deviceID: "d1", token: "secret"),
                name: try XCTUnwrap(registrations.first)
            )
        )

        // A second workspace joins the projection; the Mac is already
        // registered, so nothing asks the relay again.
        controller.toggleRemoteControl(workspaceID: "beta")
        XCTAssertEqual(
            RemoteControlProjection.decode(written[SettingsKey.remoteControl]).workspaces.map(\.id).sorted(),
            ["alpha", "beta"]
        )
        XCTAssertEqual(registrations.count, 1, "registration happens once per Mac, not once per workspace")
    }

    /// Turning it off again empties the projection — the value the daemon
    /// closes its control channel on, dropping every remote viewer.
    func testDisablingRemoteControlEmptiesTheProjection() throws {
        let controller = makeController(panes: [
            PersistedTab(project: "alpha", engine: .claude, cwd: "/tmp/alpha", id: "s-1", group: "g-1"),
        ])
        defer { controller.close() }
        controller.showWindow(nil)
        var written: [String: String] = [:]
        controller.settingsWriter = { key, value in written[key] = value }
        controller.relayDeviceRegistrar = { _ in RelayClient.Registration(deviceID: "d1", token: "secret") }

        controller.toggleRemoteControl(workspaceID: "alpha")
        controller.toggleRemoteControl(workspaceID: "alpha")

        XCTAssertEqual(written[SettingsKey.remoteControlWorkspaces], "[]")
        XCTAssertEqual(RemoteControlProjection.decode(written[SettingsKey.remoteControl]), .init(workspaces: []))
        XCTAssertTrue(controller.remoteControlWorkspaceIDs.isEmpty)
        let row = try XCTUnwrap(firstWorkspaceRow(in: controller.shellSidebar.workspacesTree))
        XCTAssertTrue(row.remoteGlyph.isHidden)
    }

    /// A disable must reach disk even on a launch that has written nothing.
    ///
    /// The row survives restarts, so a Mac that shared `alpha` yesterday
    /// starts today with a non-empty `remote_control` on disk. If the layout
    /// read has not landed when the user turns the workspace off, the
    /// layout-derived path is (rightly) still quiet — but the toggle is not
    /// derived from the layout, it *is* the user's answer, and skipping it
    /// would leave the daemon authorizing Attach/Input on ids whose checkmark
    /// is now off. (The window's `lastPersisted` cache cannot stand in for
    /// "a row exists": it only ever records what this window has written.)
    func testDisablingWritesAnEmptyProjectionEvenBeforeTheLayoutLands() throws {
        let controller = makeUnrestoredController()
        defer { controller.close() }
        controller.showWindow(nil)
        var written: [String: String] = [:]
        controller.settingsWriter = { key, value in written[key] = value }
        controller.relayDeviceRegistrar = { _ in
            XCTFail("a disable never registers")
            return RelayClient.Registration(deviceID: "d1", token: "secret")
        }

        // Yesterday's row comes back; the layout has not been read yet.
        controller.applyRestoredRemoteControlWorkspaces(#"["alpha"]"#)
        XCTAssertNil(
            written[SettingsKey.remoteControl],
            "the layout-derived path stays quiet until the layout is read"
        )

        controller.toggleRemoteControl(workspaceID: "alpha")

        XCTAssertEqual(
            RemoteControlProjection.decode(written[SettingsKey.remoteControl]),
            .init(workspaces: []),
            "the stale row on disk has to be overwritten, not left behind"
        )
        XCTAssertEqual(written[SettingsKey.remoteControlWorkspaces], "[]")
    }

    /// Two enables inside one network round trip are one registration.
    /// `registerThisMachine` claims the state before it awaits, so the second
    /// toggle sees a registration in flight and stands down — otherwise the
    /// relay gets two device rows and the token row keeps whichever landed
    /// last, orphaning the other.
    func testTwoEnablesInsideOneRoundTripRegisterOnce() throws {
        let controller = makeController(panes: [
            PersistedTab(project: "alpha", engine: .claude, cwd: "/tmp/alpha", id: "s-1", group: "g-1"),
            PersistedTab(project: "beta", engine: .shell, cwd: "/tmp/beta", id: "s-2", group: "g-2"),
        ])
        defer { controller.close() }
        controller.showWindow(nil)
        let registered = expectation(description: "the device token row is written")
        controller.settingsWriter = { key, _ in
            if key == SettingsKey.relayDeviceToken { registered.fulfill() }
        }
        var registrations: [String] = []
        controller.relayDeviceRegistrar = { name in
            registrations.append(name)
            return RelayClient.Registration(deviceID: "d1", token: "secret")
        }
        controller.applyRestoredRelayDeviceToken(nil)

        // Both toggles land before the registration task can run — the exact
        // window the state machine exists to close.
        controller.toggleRemoteControl(workspaceID: "alpha")
        controller.toggleRemoteControl(workspaceID: "beta")

        wait(for: [registered], timeout: 5)
        XCTAssertEqual(registrations.count, 1)
        XCTAssertEqual(controller.relayTokenState, .present)
    }

    /// Until the token row has actually been read, "no token" is a guess —
    /// and acting on it costs a duplicate device row. Nothing registers from
    /// `unknown`.
    func testAnEnableBeforeTheTokenRowIsReadDoesNotRegisterOnAGuess() throws {
        let controller = makeController(panes: [
            PersistedTab(project: "alpha", engine: .claude, cwd: "/tmp/alpha", id: "s-1", group: "g-1"),
        ])
        defer { controller.close() }
        controller.showWindow(nil)
        controller.settingsWriter = { _, _ in }
        var registrations = 0
        controller.relayDeviceRegistrar = { _ in
            registrations += 1
            return RelayClient.Registration(deviceID: "d1", token: "secret")
        }

        controller.toggleRemoteControl(workspaceID: "alpha")

        XCTAssertEqual(controller.relayTokenState, .unknown)
        XCTAssertEqual(registrations, 0, "the row has not been read; nothing may register on a guess")
    }

    /// The projection follows the layout: a session started in an enabled
    /// workspace is remotely reachable without anyone touching the toggle
    /// again — that is what wiring it into `persistLayout` buys.
    func testASessionStartedInAnEnabledWorkspaceJoinsTheProjection() throws {
        let controller = makeController(panes: [
            PersistedTab(project: "alpha", engine: .claude, cwd: "/tmp/alpha", id: "s-1", group: "g-1"),
        ])
        defer { controller.close() }
        controller.showWindow(nil)
        var written: [String: String] = [:]
        controller.settingsWriter = { key, value in written[key] = value }
        // Already registered, so nothing here reaches for the network.
        controller.applyRestoredRelayDeviceToken(#"{"device_id":"d1","token":"t"}"#)

        controller.toggleRemoteControl(workspaceID: "alpha")
        XCTAssertEqual(
            RemoteControlProjection.decode(written[SettingsKey.remoteControl]).workspaces.first?.sessions.map(\.id),
            ["s-1"]
        )

        // `startSession` answers with the session *group* id; the projection
        // carries daemon session ids, one per pane.
        XCTAssertNotNil(controller.startSession(inDirectory: "/tmp/alpha", project: "alpha"))
        let added = try XCTUnwrap(controller.workspaceView.paneIDs.first { $0 != "s-1" })

        XCTAssertEqual(
            RemoteControlProjection.decode(written[SettingsKey.remoteControl]).workspaces.first?.sessions.map(\.id),
            ["s-1", added],
            "the layout persist re-derived the projection"
        )
    }

    /// A workspace is called the same thing on both machines: the projection
    /// carries the name the sidebar prints, Customize… included — and those
    /// are keyed by directory, not by workspace id, which is the mapping a
    /// second lookup here would get wrong.
    func testTheProjectionCarriesTheSidebarsDisplayName() throws {
        let controller = makeController(panes: [
            PersistedTab(project: "alpha", engine: .claude, cwd: "/tmp/alpha", id: "s-1", group: "g-1"),
        ])
        defer { controller.close() }
        controller.showWindow(nil)
        var written: [String: String] = [:]
        controller.settingsWriter = { key, value in written[key] = value }
        controller.relayDeviceRegistrar = { _ in RelayClient.Registration(deviceID: "d1", token: "secret") }
        controller.applyRestoredWorkspaceCustomizations(
            WorkspaceCustomizationsCodec.serialize(
                ["/tmp/alpha": WorkspaceCustomization(displayName: "Mission Control", color: nil)]
            )
        )

        controller.toggleRemoteControl(workspaceID: "alpha")

        XCTAssertEqual(
            RemoteControlProjection.decode(written[SettingsKey.remoteControl]).workspaces.map(\.name),
            ["Mission Control"]
        )
    }

    /// The menu the row actually pops carries the checkmark for the state
    /// the controller holds — the toggle and the glyph read the same fact.
    func testTheWorkspaceMenuReflectsTheStoredEnablement() throws {
        let controller = makeController(panes: [
            PersistedTab(project: "alpha", engine: .claude, cwd: "/tmp/alpha", id: "s-1", group: "g-1"),
        ])
        defer { controller.close() }
        controller.showWindow(nil)
        controller.settingsWriter = { _, _ in }
        controller.relayDeviceRegistrar = { _ in RelayClient.Registration(deviceID: "d1", token: "secret") }

        let before = try XCTUnwrap(
            controller.workspaceContextMenu(for: "alpha").items.first { $0.title == "Enable Remote Control" }
        )
        XCTAssertEqual(before.state, .off)

        try XCTUnwrap(before as? ShellMenuItem).performForTesting()

        let after = try XCTUnwrap(
            controller.workspaceContextMenu(for: "alpha").items.first { $0.title == "Enable Remote Control" }
        )
        XCTAssertEqual(after.state, .on)
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

    /// A workspace holding an editor pane with unsaved work gets ⌘W's gate,
    /// not `destroyPane`'s unguarded half: the removal drains the dirty tabs
    /// with save prompts first, and a cancel there aborts the whole removal
    /// with every pane — and the unsaved buffer — intact.
    func testRemoveWorkspaceDrainsDirtyEditorPanesBeforeDestroying() throws {
        let controller = makeController(panes: [
            PersistedTab(project: "alpha", engine: .claude, cwd: "/tmp/alpha", id: "s-1", group: "g-1"),
        ])
        defer { controller.close() }
        controller.showWindow(nil)
        var killed: [String] = []
        controller.sessionKiller = { killed.append($0) }
        var written: [String: String] = [:]
        controller.settingsWriter = { key, value in written[key] = value }
        controller.applyRestoredClosedWorkspaces(nil)
        controller.workspaceRemovalConfirmer = { _, _, completion in completion(true) }
        // An editor pane in the workspace, holding an unsaved buffer.
        controller.openFileInEditor(try makeTempFile("a.swift", "x"), pinned: true)
        let workspace = controller.workspaceView
        let editorID = try XCTUnwrap(workspace.focusedPaneID)
        let pane = try XCTUnwrap(workspace.editorPane(for: editorID))
        pane.modelForTesting { $0.setDirty(true, at: 0) }

        // Cancelling the save prompt aborts the removal — nothing dies.
        pane.confirmSave = { _, decide in decide(.cancel) }
        controller.removeWorkspace("alpha")
        XCTAssertEqual(killed, [])
        XCTAssertNotNil(workspace.descriptor(for: "s-1"), "cancel kept the terminal")
        XCTAssertNotNil(workspace.editorPane(for: editorID), "…and the editor pane")
        XCTAssertEqual(pane.model.tabs.count, 1, "…and the unsaved buffer with it")
        XCTAssertNil(
            written[SettingsKey.closedWorkspaces],
            "an aborted removal records nothing"
        )
        XCTAssertEqual(controller.shellSidebar.workspacesTree.renderedWorkspaceIDs, ["alpha"])

        // Discarding resolves the drain and the whole workspace goes.
        pane.confirmSave = { _, decide in decide(.discard) }
        controller.removeWorkspace("alpha")
        XCTAssertEqual(killed, ["s-1"])
        XCTAssertNil(workspace.descriptor(for: "s-1"))
        XCTAssertNil(workspace.editorPane(for: editorID))
        XCTAssertEqual(
            ClosedWorkspacesCodec.deserialize(written[SettingsKey.closedWorkspaces]),
            ["alpha"]
        )
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

    private func makeTempFile(_ name: String, _ contents: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("workspace-menu-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

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

    /// `makeController`'s twin for the pre-restore window: the layout row has
    /// not been read, so `layoutReadCompleted` is false and every
    /// layout-derived write is still gated shut.
    private func makeUnrestoredController() -> WorkspaceWindowController {
        let controller = WorkspaceWindowController(
            connection: SessionConnection(
                socketURL: URL(fileURLWithPath: "/tmp/omniagent-workspace-menu-test.sock")
            ),
            panes: []
        )
        controller.sessionEnsurer = { _ in }
        controller.sessionKiller = { _ in }
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
