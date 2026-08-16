import XCTest
import MetalKit
import SwiftTerm
@testable import OmniAgent

final class WorkspaceWindowControllerTests: XCTestCase {
    func testWindowOpensOnASinglePaneWorkspaceAndFocusReturnsToIt() {
        let controller = makeController()
        defer { controller.close() }

        controller.showWindow(nil)
        let workspace: PaneWorkspaceView? = controller.workspaceView
        XCTAssertEqual(workspace?.paneIDs, ["native-terminal"])
        XCTAssertEqual(workspace?.focusedPaneID, "native-terminal")

        controller.focusTerminal(nil)
        XCTAssertTrue(
            controller.window?.firstResponder === workspace?.surface(for: "native-terminal")?.terminalView
        )
    }

    func testNewPaneCommandAddsPanesWithFreshSessionIDsAndStopsAtTheCap() throws {
        let controller = makeController()
        defer { controller.close() }
        controller.showWindow(nil)
        let workspace = controller.workspaceView

        for _ in 0..<12 { controller.newTerminalPane(nil) }

        XCTAssertEqual(workspace.paneIDs.count, PaneGrid.maxPanes, "the cap holds")
        XCTAssertEqual(Set(workspace.paneIDs).count, PaneGrid.maxPanes, "every pane has its own id")
        XCTAssertEqual(
            workspace.paneIDs.filter { UUID(uuidString: $0) != nil }.count,
            PaneGrid.maxPanes - 1,
            "new panes get fresh UUID session ids"
        )
        for id in workspace.paneIDs {
            XCTAssertEqual(workspace.descriptor(for: id)?.group, workspace.descriptor(for: "native-terminal")?.group)
        }
    }

    /// Minor #10: `lastStatus` was the one per-pane dictionary `closePane`
    /// never cleared, so a long-lived window accumulated an entry for every
    /// pane it had ever opened.
    func testClosingAPaneForgetsItsLastStatusAlongWithItsOtherPerPaneState() throws {
        let controller = makeController()
        defer { controller.close() }
        controller.showWindow(nil)
        let workspace = controller.workspaceView
        controller.newTerminalPane(nil)
        let closing = try XCTUnwrap(workspace.focusedPaneID)
        let survivor = try XCTUnwrap(workspace.paneIDs.first { $0 != closing })

        for id in [closing, survivor] {
            controller.recordNotification(
                for: SessionStatusEvent(id: id, status: .awaitingApproval, notify: true, engine: "shell")
            )
        }
        XCTAssertEqual(Set(controller.lastStatus.keys), [closing, survivor])

        controller.closePane(nil)

        XCTAssertEqual(
            Set(controller.lastStatus.keys),
            [survivor],
            "a closed pane's status must not outlive it"
        )
    }

    func testClosePaneCommandRemovesTheFocusedPaneAndLeavesTheRestAlive() throws {
        let controller = makeController()
        defer { controller.close() }
        controller.showWindow(nil)
        let workspace = controller.workspaceView
        controller.newTerminalPane(nil)
        controller.newTerminalPane(nil)
        let survivors = workspace.paneIDs.filter { $0 != workspace.focusedPaneID }
        let survivingTerminals = survivors.map { ObjectIdentifier(workspace.surface(for: $0)!.terminalView) }

        controller.closePane(nil)

        XCTAssertEqual(workspace.paneIDs.count, 2)
        XCTAssertEqual(
            survivors.map { ObjectIdentifier(workspace.surface(for: $0)!.terminalView) },
            survivingTerminals
        )
    }

    func testWindowTitleFollowsTheFocusedPanesOwnStatusAndNeverGoesStale() throws {
        let controller = makeController()
        defer { controller.close() }
        controller.showWindow(nil)
        let workspace = controller.workspaceView
        controller.newTerminalPane(nil)
        let first = "native-terminal"
        let second = try XCTUnwrap(workspace.focusedPaneID)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(controller.window?.title, "OmniAgent")

        // A background pane's status stays on that pane.
        controller.applySessionStatus("Session ended", for: first)
        XCTAssertEqual(controller.window?.title, "OmniAgent")

        workspace.focusPane(first)
        XCTAssertEqual(controller.window?.title, "OmniAgent — Session ended")

        // Switching back must not keep claiming the other pane's status.
        workspace.focusPane(second)
        XCTAssertEqual(controller.window?.title, "OmniAgent")

        // A status a pane reached while unfocused shows when it gains focus.
        controller.applySessionStatus("Needs approval", for: second)
        XCTAssertEqual(controller.window?.title, "OmniAgent — Needs approval")

        // One pane attaching clears only its own line.
        controller.applySessionStatus(nil, for: second)
        XCTAssertEqual(controller.window?.title, "OmniAgent")
        workspace.focusPane(first)
        XCTAssertEqual(controller.window?.title, "OmniAgent — Session ended")

        // Connection status outranks any pane's.
        controller.applyConnectionStatus("Reconnecting")
        XCTAssertEqual(controller.window?.title, "OmniAgent — Reconnecting")
        workspace.focusPane(second)
        XCTAssertEqual(controller.window?.title, "OmniAgent — Reconnecting")
        controller.applyConnectionStatus(nil)
        XCTAssertEqual(controller.window?.title, "OmniAgent")

        // A closed pane takes its status with it.
        workspace.focusPane(first)
        controller.closePane(nil)
        XCTAssertEqual(workspace.focusedPaneID, second)
        XCTAssertEqual(controller.window?.title, "OmniAgent")
    }

    func testPaneCommandsAreOnTheMenuAndReachTheWorkspaceThroughTheResponderChain() throws {
        ApplicationMenus.install()
        let panes = try XCTUnwrap(NSApp.mainMenu?.item(withTitle: "Panes")?.submenu)
        let focusRight = try XCTUnwrap(panes.item(withTitle: "Focus Right"))
        XCTAssertNil(focusRight.target, "pane commands travel the responder chain")
        XCTAssertEqual(focusRight.action, #selector(PaneWorkspaceView.focusPaneRight(_:)))
        XCTAssertEqual(focusRight.keyEquivalentModifierMask, [.command, .option])
        let movePane = try XCTUnwrap(panes.item(withTitle: "Move Pane Right"))
        XCTAssertEqual(movePane.action, #selector(PaneWorkspaceView.swapPaneRight(_:)))
        XCTAssertEqual(movePane.keyEquivalentModifierMask, [.command, .control])
        let fourth = try XCTUnwrap(panes.item(withTitle: "Pane 4"))
        XCTAssertEqual(fourth.action, #selector(PaneWorkspaceView.selectPane(_:)))
        XCTAssertEqual(fourth.tag, 4)
        XCTAssertEqual(fourth.keyEquivalent, "4")
        let file = try XCTUnwrap(NSApp.mainMenu?.item(withTitle: "File")?.submenu)
        XCTAssertEqual(
            file.item(withTitle: "New Terminal Pane")?.action,
            #selector(WorkspaceWindowController.newTerminalPane(_:))
        )
        XCTAssertEqual(file.item(withTitle: "New Terminal Pane")?.keyEquivalent, "t")
        XCTAssertEqual(
            file.item(withTitle: "Close Pane")?.action,
            #selector(WorkspaceWindowController.closePane(_:))
        )

        let controller = makeController()
        defer { controller.close() }
        controller.showWindow(nil)
        let window = try XCTUnwrap(controller.window)
        let workspace = controller.workspaceView
        controller.newTerminalPane(nil)

        var responder: NSResponder? = window.firstResponder
        var chain: [NSResponder] = []
        while let current = responder {
            chain.append(current)
            responder = current.nextResponder
        }
        XCTAssertTrue(chain.contains { $0 === workspace }, "the focused terminal sits under the workspace")
        XCTAssertTrue(chain.contains { $0 === controller }, "the controller answers pane lifecycle commands")
        XCTAssertTrue(workspace.responds(to: #selector(PaneWorkspaceView.focusPaneRight(_:))))
        XCTAssertTrue(workspace.responds(to: #selector(PaneWorkspaceView.selectPane(_:))))
        XCTAssertTrue(controller.responds(to: #selector(WorkspaceWindowController.newTerminalPane(_:))))
        XCTAssertTrue(controller.responds(to: #selector(WorkspaceWindowController.closePane(_:))))
    }

    // MARK: - Restoration

    func testAWindowOpensEmptyAndTheRestoredLayoutFillsIt() throws {
        let controller = makeEmptyController()
        defer { controller.close() }
        controller.showWindow(nil)
        let workspace = controller.workspaceView
        XCTAssertTrue(workspace.paneIDs.isEmpty, "nothing is on screen before the socket answers")

        controller.applyRestoredPanes(
            WorkspaceRestoration.plan(
                fromLayout: PersistedLayoutCodec.serialize([
                    PersistedTab(project: "alpha", engine: .shell, cwd: "/a", id: "sess-a", group: "grp-1", groupLabel: "Session 1"),
                    PersistedTab(project: "alpha", engine: .claude, cwd: "/a", id: "sess-b", group: "grp-1", groupLabel: "Session 1"),
                ])
            )
        )

        XCTAssertEqual(workspace.paneIDs, ["sess-a", "sess-b"], "in the order they were stored")
        XCTAssertEqual(workspace.descriptor(for: "sess-b")?.engine, .claude)
        XCTAssertEqual(workspace.descriptor(for: "sess-b")?.groupLabel, "Session 1")
        XCTAssertEqual(workspace.descriptor(for: "sess-a")?.cwd, "/a")
    }

    func testAnEmptyLayoutRestoresToOneBootstrapPaneRatherThanAnEmptyWindow() throws {
        let controller = makeEmptyController()
        defer { controller.close() }
        controller.showWindow(nil)
        let workspace = controller.workspaceView

        controller.applyRestoredPanes([])

        XCTAssertEqual(workspace.paneIDs.count, 1)
        XCTAssertEqual(workspace.focusedPaneID, workspace.paneIDs.first)
        XCTAssertEqual(workspace.descriptor(for: workspace.paneIDs[0])?.engine, .shell)
    }

    func testRestorationNeverDuplicatesAPaneTheWindowAlreadyHas() throws {
        let controller = makeController()
        defer { controller.close() }
        controller.showWindow(nil)
        let workspace = controller.workspaceView

        controller.applyRestoredPanes([
            WorkspaceRestoration.bootstrapPane(sessionID: "native-terminal"),
            WorkspaceRestoration.bootstrapPane(sessionID: "sess-new"),
        ])

        XCTAssertEqual(workspace.paneIDs, ["native-terminal", "sess-new"])
    }

    func testANewPaneJoinsTheFocusedPanesSessionProjectAndDirectory() throws {
        let controller = makeEmptyController()
        defer { controller.close() }
        controller.showWindow(nil)
        let workspace = controller.workspaceView
        controller.applyRestoredPanes(
            WorkspaceRestoration.plan(
                fromLayout: PersistedLayoutCodec.serialize([
                    PersistedTab(project: "alpha", engine: .shell, cwd: "/a", id: "sess-a", group: "grp-1", groupLabel: "Build"),
                ])
            )
        )

        controller.newTerminalPane(nil)

        let added = try XCTUnwrap(workspace.paneIDs.last.flatMap { workspace.descriptor(for: $0) })
        XCTAssertNotEqual(added.sessionID, "sess-a")
        XCTAssertEqual(added.group, "grp-1")
        XCTAssertEqual(added.groupLabel, "Build")
        XCTAssertEqual(added.project, "alpha")
        XCTAssertEqual(added.cwd, "/a", "a new terminal inherits its session's directory")
        XCTAssertEqual(
            added.engine,
            EngineLauncher.defaultEngine(),
            "a new terminal comes up on an installed agent, not a bare shell"
        )
    }

    // MARK: - Persistence

    func testTheLayoutRowIsWrittenOnlyAfterRestorationAndOnlyWhenItActuallyChanged() throws {
        let controller = makeEmptyController()
        defer { controller.close() }
        var writes: [(String, String)] = []
        controller.settingsWriter = { writes.append(($0, $1)) }
        controller.showWindow(nil)

        controller.newTerminalPane(nil)
        XCTAssertTrue(writes.isEmpty, "a window that has not read the row must not overwrite it")

        controller.applyRestoredPanes(
            WorkspaceRestoration.plan(
                fromLayout: PersistedLayoutCodec.serialize([
                    PersistedTab(project: "alpha", engine: .shell, cwd: "/a", id: "sess-a", group: "g1"),
                ])
            )
        )
        let afterRestore = writes.count
        XCTAssertGreaterThan(afterRestore, 0)
        XCTAssertEqual(writes.last?.0, SettingsKey.layout)
        XCTAssertTrue(try XCTUnwrap(writes.last?.1).contains("sess-a"))

        // The OSC title is not part of the stored shape, so a shell that
        // repaints it on every prompt must not write the row again.
        controller.workspaceView.updateDescriptor(for: "sess-a") { $0.title = "~/src" }
        controller.workspaceView.updateDescriptor(for: "sess-a") { $0.title = "~/src/deep" }
        XCTAssertEqual(writes.count, afterRestore, "an unchanged row is not rewritten")

        controller.workspaceView.updateDescriptor(for: "sess-a") { $0.groupLabel = "Build" }
        XCTAssertEqual(writes.count, afterRestore + 1, "a stored field changing does write")
        XCTAssertTrue(try XCTUnwrap(writes.last?.1).contains("Build"))
    }

    func testAFailedLayoutReadNeverWritesAnEmptyLayoutOverTheSavedOne() throws {
        let controller = makeEmptyController()
        defer { controller.close() }
        var writes: [(String, String)] = []
        controller.settingsWriter = { writes.append(($0, $1)) }
        controller.showWindow(nil)

        controller.layoutReadFailed(SessionConnectionError.disconnected)

        XCTAssertTrue(
            controller.workspaceView.paneIDs.isEmpty,
            "a row that could not be read is not a row that says there are no tabs"
        )
        XCTAssertTrue(try XCTUnwrap(controller.window?.title).contains("Couldn't read the saved layout"))

        // The window is still usable, and nothing it does can destroy the row.
        controller.newTerminalPane(nil)
        controller.workspaceView.updateDescriptor(for: try XCTUnwrap(controller.workspaceView.paneIDs.first)) {
            $0.project = "alpha"
        }

        XCTAssertEqual(writes.count, 0, "the write gate stays shut until a read actually succeeds")
    }

    func testAPaneOpenedWhileTheReadIsInFlightIsNotWrittenUntilTheRowLands() throws {
        let controller = makeEmptyController()
        defer { controller.close() }
        var writes: [(String, String)] = []
        controller.settingsWriter = { writes.append(($0, $1)) }
        controller.showWindow(nil)

        // The read has been dispatched but has not come back yet — exactly the
        // window in which `hasRestored` used to already be true.
        controller.newTerminalPane(nil)
        controller.workspaceView.updateDescriptor(for: try XCTUnwrap(controller.workspaceView.paneIDs.first)) {
            $0.project = "alpha"
        }
        XCTAssertTrue(writes.isEmpty, "nothing may be written before the row has been read")

        controller.applyRestoredPanes(
            WorkspaceRestoration.plan(
                fromLayout: PersistedLayoutCodec.serialize([
                    PersistedTab(project: "beta", engine: .shell, cwd: "/b", id: "sess-b", group: "g1"),
                ])
            )
        )

        let written = try XCTUnwrap(writes.last?.1)
        XCTAssertTrue(written.contains("sess-b"), "the saved pane survived")
        XCTAssertTrue(written.contains("alpha"), "and so did the one opened while the read was in flight")
    }

    func testANotificationRecordedWhileTheFeedIsBeingReadSurvivesTheRestore() {
        let delivery = RecordingDelivery()
        let notifier = SessionNotifier(delivery: delivery)
        let live = NotificationEntry(
            id: "live", sessionID: "s", project: "p", projectLabel: "P", cwd: "/",
            engine: "shell", status: .awaitingApproval, title: "t", sessionLabel: nil,
            createdAt: 2, read: false
        )
        let stored = NotificationEntry(
            id: "stored", sessionID: "s", project: "p", projectLabel: "P", cwd: "/",
            engine: "shell", status: .ready, title: "t", sessionLabel: nil,
            createdAt: 1, read: true
        )
        notifier.restore([live])

        notifier.restore([stored])

        XCTAssertEqual(
            notifier.entries.map(\.id),
            ["live", "stored"],
            "the newer live entry keeps its place at the front instead of being replaced away"
        )
    }

    // MARK: - Sessions

    func testStartingASessionPutsItsPaneInABrandNewGroupWithTheLowestFreeName() throws {
        let controller = makeEmptyController()
        defer { controller.close() }
        controller.showWindow(nil)
        controller.applyRestoredPanes(
            WorkspaceRestoration.plan(
                fromLayout: PersistedLayoutCodec.serialize([
                    PersistedTab(project: "alpha", engine: .shell, cwd: "/a", id: "sess-a", group: "g1", groupLabel: "Session 1"),
                ])
            )
        )

        let group = try XCTUnwrap(controller.startSession(inDirectory: "/a/sub", project: "alpha"))

        XCTAssertNotEqual(group, "g1", "a second session is a second group, not the focused pane's")
        XCTAssertTrue(SessionIdentifier.isValid(group), "and it survives a relaunch")
        let added = try XCTUnwrap(controller.pane(inGroup: group))
        XCTAssertEqual(added.groupLabel, "Session 2", "the lowest free number in this project")
        XCTAssertEqual(added.cwd, "/a/sub", "the session's own directory, not the sibling's")
        XCTAssertEqual(added.project, "alpha")

        let second = try XCTUnwrap(controller.startSession(inDirectory: "/a", project: "alpha"))
        XCTAssertNotEqual(second, group, "two sessions started back to back never share a group id")
        XCTAssertEqual(controller.pane(inGroup: second)?.groupLabel, "Session 3")
    }

    /// A new session starts in the workspace's own folder and asks nothing.
    /// The chooser is reserved for opening a *different* folder as a new
    /// workspace — asking on every new session meant answering a question whose
    /// answer was already known, and on a workspace under `~/Documents` it put
    /// a system folder-access prompt in front of a routine action.
    func testNewSessionStartsInTheWorkspaceFolderWithoutAsking() throws {
        let controller = makeEmptyController()
        defer { controller.close() }
        controller.showWindow(nil)
        controller.applyRestoredPanes(
            WorkspaceRestoration.plan(
                fromLayout: PersistedLayoutCodec.serialize([
                    PersistedTab(project: "alpha", engine: .shell, cwd: "/a", id: "sess-a", group: "g1"),
                ])
            )
        )
        var seeds: [String] = []
        controller.directoryChooser = { seed, completion in
            seeds.append(seed)
            completion("/chosen")
        }

        controller.newSession(nil)

        XCTAssertEqual(seeds, [], "a new session never opens a folder chooser")
        XCTAssertEqual(controller.workspaceView.paneIDs.count, 2)
        XCTAssertEqual(
            controller.workspaceView.paneIDs.last.flatMap { controller.workspaceView.descriptor(for: $0)?.cwd },
            "/a",
            "it starts in the workspace's own folder"
        )
        XCTAssertEqual(
            controller.workspaceView.paneIDs
                .compactMap { controller.workspaceView.descriptor(for: $0)?.group }
                .count,
            2
        )

        // "New workspace" is the one flow that still asks, because the folder
        // is the new thing.
        controller.openWorkspaceFolder(nil)
        XCTAssertEqual(seeds, ["/a"], "the chooser opens at the current workspace's root")
        // By membership, not by position: `paneIDs` is the grid's column-major
        // order, in which the newest pane is not necessarily the last one.
        XCTAssertTrue(
            controller.workspaceView.paneIDs
                .compactMap { controller.workspaceView.descriptor(for: $0)?.cwd }
                .contains("/chosen")
        )

        // Cancelling the chooser starts nothing.
        controller.directoryChooser = { _, completion in completion(nil) }
        let before = controller.workspaceView.paneIDs.count
        controller.openWorkspaceFolder(nil)
        XCTAssertEqual(controller.workspaceView.paneIDs.count, before)

        while controller.workspaceView.paneIDs.count < PaneGrid.maxPanes { controller.newTerminalPane(nil) }
        controller.newSession(nil)
        XCTAssertEqual(controller.workspaceView.paneIDs.count, PaneGrid.maxPanes, "the cap holds")
        XCTAssertFalse(
            controller.validateMenuItem(
                NSMenuItem(title: "New Session", action: #selector(WorkspaceWindowController.newSession(_:)), keyEquivalent: "")
            )
        )
    }

    func testTheOutlinePlusButtonAddsToItsOwnRowNotToWhateverHasFocus() throws {
        let controller = makeEmptyController()
        defer { controller.close() }
        controller.showWindow(nil)
        controller.applyRestoredPanes(
            WorkspaceRestoration.plan(
                fromLayout: PersistedLayoutCodec.serialize([
                    PersistedTab(project: "alpha", engine: .shell, cwd: "/a", id: "sess-a", group: "g1", groupLabel: "One"),
                    PersistedTab(project: "alpha", engine: .shell, cwd: "/b", id: "sess-b", group: "g2", groupLabel: "Two"),
                ])
            )
        )
        controller.workspaceView.focusPane("sess-a")
        let sessions = SessionOutline.group(
            controller.workspaceView.paneIDs.compactMap { controller.workspaceView.descriptor(for: $0) },
            focusedPaneID: "sess-a"
        ).first?.sessions ?? []
        let secondSession = try XCTUnwrap(sessions.first { $0.id == "g2" })

        controller.newPane(in: secondSession)

        let added = try XCTUnwrap(
            controller.workspaceView.paneIDs
                .compactMap { controller.workspaceView.descriptor(for: $0) }
                .first { $0.sessionID != "sess-a" && $0.sessionID != "sess-b" }
        )
        XCTAssertEqual(added.group, "g2", "the row that was clicked, not the row that had focus")
        XCTAssertEqual(added.groupLabel, "Two")
        XCTAssertEqual(added.cwd, "/b")
    }

    /// The window opens sized to the display it lands on. The old fixed
    /// 1040x680 predates the 238pt sidebar and read as cramped everywhere.
    func testTheFirstLaunchWindowSizeFollowsTheScreenWithinBounds() {
        let ultrawide = WorkspaceWindowController.defaultContentRect(
            visibleFrame: NSRect(x: 0, y: 0, width: 5120, height: 2160)
        )
        XCTAssertLessThanOrEqual(ultrawide.width, 1760, "a huge display does not get a huge window")

        let laptop = WorkspaceWindowController.defaultContentRect(
            visibleFrame: NSRect(x: 0, y: 0, width: 1512, height: 916)
        )
        XCTAssertGreaterThan(laptop.width, 1040, "and a normal one gets more than the old fixed size")
        XCTAssertLessThanOrEqual(laptop.width, 1512)
        XCTAssertLessThanOrEqual(laptop.height, 916)

        // The floor must never win over the screen itself.
        let small = WorkspaceWindowController.defaultContentRect(
            visibleFrame: NSRect(x: 0, y: 0, width: 900, height: 600)
        )
        XCTAssertLessThanOrEqual(small.width, 900)
        XCTAssertLessThanOrEqual(small.height, 600)
    }

    // MARK: - Command palette and toolbar

    func testTheCommandPaletteAndSidebarToggleAreOnTheMenuAndTravelTheResponderChain() throws {
        ApplicationMenus.install()
        let palette = try XCTUnwrap(NSApp.mainMenu?.item(withTitle: "File")?.submenu?.item(withTitle: "Command Palette"))
        XCTAssertNil(palette.target)
        XCTAssertEqual(palette.action, #selector(WorkspaceWindowController.showCommandPalette(_:)))
        XCTAssertEqual(palette.keyEquivalent, "k")
        XCTAssertEqual(palette.keyEquivalentModifierMask, [.command])

        let session = try XCTUnwrap(NSApp.mainMenu?.item(withTitle: "File")?.submenu?.item(withTitle: "New Session"))
        XCTAssertNil(session.target)
        XCTAssertEqual(session.action, #selector(WorkspaceWindowController.newSession(_:)))
        XCTAssertEqual(session.keyEquivalent, "n")

        let sidebar = try XCTUnwrap(NSApp.mainMenu?.item(withTitle: "Window")?.submenu?.item(withTitle: "Toggle Sidebar"))
        XCTAssertNil(sidebar.target)
        XCTAssertEqual(sidebar.action, #selector(WorkspaceWindowController.toggleSidebar(_:)))
        XCTAssertEqual(sidebar.keyEquivalentModifierMask, [.command, .control])
    }

    func testTheToolbarCarriesOnlyCommandsThatAlsoExistElsewhereAndTargetsTheResponderChain() throws {
        let controller = makeController()
        defer { controller.close() }
        let toolbar = try XCTUnwrap(controller.window?.toolbar)

        XCTAssertEqual(controller.window?.toolbarStyle, .unified)
        let identifiers = controller.toolbarDefaultItemIdentifiers(toolbar)
        XCTAssertEqual(
            identifiers,
            [
                WorkspaceWindowController.ToolbarItem.sidebar,
                .sidebarTrackingSeparator,
                WorkspaceWindowController.ToolbarItem.newPane,
                WorkspaceWindowController.ToolbarItem.closePane,
                .flexibleSpace,
                WorkspaceWindowController.ToolbarItem.palette,
            ]
        )
        for identifier in identifiers where !identifier.rawValue.hasPrefix("NS") {
            let item = try XCTUnwrap(
                controller.toolbar(toolbar, itemForItemIdentifier: identifier, willBeInsertedIntoToolbar: true)
            )
            XCTAssertNil(item.target, "\(identifier.rawValue) travels the responder chain")
            XCTAssertNotNil(item.action)
            XCTAssertNotNil(item.image, "\(identifier.rawValue) has a symbol")
        }
    }

    func testTheToolbarSharesTheMenusEnablementRuleRatherThanAddingASecondOne() throws {
        let controller = makeEmptyController()
        defer { controller.close() }
        let toolbar = try XCTUnwrap(controller.window?.toolbar)
        let closePane = try XCTUnwrap(
            controller.toolbar(toolbar, itemForItemIdentifier: WorkspaceWindowController.ToolbarItem.closePane, willBeInsertedIntoToolbar: true)
        )

        XCTAssertFalse(controller.validateToolbarItem(closePane), "no pane, nothing to close")

        controller.applyRestoredPanes([])

        XCTAssertTrue(controller.validateToolbarItem(closePane))
    }

    func testEveryPaletteActionRunsTheSameCodeTheMenuItemDoes() throws {
        let controller = makeEmptyController()
        defer { controller.close() }
        controller.showWindow(nil)
        controller.applyRestoredPanes(
            WorkspaceRestoration.plan(
                fromLayout: PersistedLayoutCodec.serialize([
                    PersistedTab(project: "alpha", engine: .shell, cwd: "/a", id: "sess-a", group: "g1"),
                    PersistedTab(project: "alpha", engine: .shell, cwd: "/a", id: "sess-b", group: "g1"),
                ])
            )
        )

        controller.run(.focusPane(sessionID: "sess-a"))
        XCTAssertEqual(controller.workspaceView.focusedPaneID, "sess-a")

        controller.run(.newPane)
        XCTAssertEqual(controller.workspaceView.paneIDs.count, 3)

        controller.run(.closePane(sessionID: "sess-b"))
        XCTAssertFalse(controller.workspaceView.paneIDs.contains("sess-b"))

        let split = try XCTUnwrap(controller.window?.contentViewController as? NSSplitViewController)
        let collapsed = split.splitViewItems[0].isCollapsed
        controller.run(.toggleSidebar)
        XCTAssertNotEqual(split.splitViewItems[0].isCollapsed, collapsed)
    }

    func testThePaletteIsBuiltFromTheLiveWorkspaceOnEveryOpen() throws {
        let controller = makeEmptyController()
        defer { controller.close() }
        controller.showWindow(nil)
        controller.applyRestoredPanes(
            WorkspaceRestoration.plan(
                fromLayout: PersistedLayoutCodec.serialize([
                    PersistedTab(project: "alpha", engine: .shell, cwd: "/a", id: "sess-a", group: "g1"),
                ])
            )
        )

        controller.showCommandPalette(nil)
        XCTAssertTrue(controller.palette.model.matches.contains { $0.action == .focusPane(sessionID: "sess-a") })

        controller.palette.dismiss()
        controller.workspaceView.closePane("sess-a")
        controller.showCommandPalette(nil)

        XCTAssertFalse(
            controller.palette.model.matches.contains { $0.action == .focusPane(sessionID: "sess-a") },
            "a pane that closed while the palette was shut can never be offered"
        )
        controller.palette.dismiss()
    }

    // MARK: - Session outline

    func testTheOutlineFollowsThePanesAndTheFocusedOne() throws {
        let controller = makeEmptyController()
        defer { controller.close() }
        controller.showWindow(nil)
        controller.applyRestoredPanes(
            WorkspaceRestoration.plan(
                fromLayout: PersistedLayoutCodec.serialize([
                    PersistedTab(project: "alpha", engine: .shell, cwd: "/a", id: "sess-a", group: "g1", groupLabel: "Build"),
                ])
            )
        )
        let tree = controller.shellSidebar.sessionsTree
        XCTAssertEqual(tree.renderedSessionIDs, ["g1"])
        XCTAssertEqual(tree.renderedPaneIDs, ["sess-a"])

        controller.newTerminalPane(nil)

        XCTAssertEqual(tree.renderedSessionIDs, ["g1"], "the new pane joins the open session")
        let focused = try XCTUnwrap(controller.workspaceView.focusedPaneID)
        XCTAssertEqual(tree.renderedPaneIDs.count, 2, "the new pane appears in its session")
        XCTAssertTrue(tree.renderedPaneIDs.contains(focused))
    }

    func testRenamingASessionWritesTheNameOntoEveryPaneInIt() throws {
        let controller = makeEmptyController()
        defer { controller.close() }
        controller.showWindow(nil)
        controller.applyRestoredPanes(
            WorkspaceRestoration.plan(
                fromLayout: PersistedLayoutCodec.serialize([
                    PersistedTab(project: "alpha", engine: .shell, cwd: "/a", id: "sess-a", group: "g1"),
                    PersistedTab(project: "alpha", engine: .shell, cwd: "/a", id: "sess-b", group: "g1"),
                ])
            )
        )
        let session = try XCTUnwrap(
            SessionOutline.group(
                controller.workspaceView.paneIDs.compactMap { controller.workspaceView.descriptor(for: $0) },
                focusedPaneID: nil
            ).first?.sessions.first
        )

        controller.renameSession(session, to: "  Migration  ")

        XCTAssertEqual(controller.workspaceView.descriptor(for: "sess-a")?.groupLabel, "Migration")
        XCTAssertEqual(controller.workspaceView.descriptor(for: "sess-b")?.groupLabel, "Migration")

        controller.renameSession(session, to: "   ")
        XCTAssertEqual(
            controller.workspaceView.descriptor(for: "sess-a")?.groupLabel,
            "Migration",
            "a blank name is not a rename"
        )
    }

    private func makeController() -> WorkspaceWindowController {
        WorkspaceWindowController(
            connection: SessionConnection(
                socketURL: URL(fileURLWithPath: "/tmp/omniagent-controller-test.sock")
            ),
            sessionID: "native-terminal"
        )
    }

    private func makeEmptyController() -> WorkspaceWindowController {
        WorkspaceWindowController(
            connection: SessionConnection(
                socketURL: URL(fileURLWithPath: "/tmp/omniagent-controller-test.sock")
            ),
            panes: []
        )
    }

    func testTerminalPreservesComposedTextInsteadOfTreatingOptionAsMeta() {
        let surface = makeSurface()
        let delegate = RecordingTerminalDelegate()
        surface.terminalView.terminalDelegate = delegate

        surface.terminalView.insertText(
            "é",
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )

        XCTAssertFalse(surface.terminalView.optionAsMetaKey)
        XCTAssertEqual(delegate.bytes, Array("é".utf8))
    }

    func testCommandOptionOIsClaimedByMenuBeforeSwiftTermKittyKeyDown() throws {
        ApplicationMenus.install()
        let command = try XCTUnwrap(NSApp.mainMenu?
            .item(withTitle: "Session")?
            .submenu?
            .item(withTitle: "Use Option as Meta"))
        let (surface, window) = makeAttachedSurface()
        defer { window.close() }
        let delegate = RecordingTerminalDelegate()
        surface.terminalView.terminalDelegate = delegate
        surface.terminalView.feed(
            byteArray: Array("\u{1b}[>1u".utf8)[...]
        )
        XCTAssertFalse(surface.terminalView.terminal.keyboardEnhancementFlags.isEmpty)
        let modalSession = NSApp.beginModalSession(for: window)
        defer { NSApp.endModalSession(modalSession) }
        _ = NSApp.runModalSession(modalSession)
        window.makeKeyAndOrderFront(nil)
        XCTAssertTrue(window.makeFirstResponder(surface.terminalView))

        XCTAssertNil(command.target)
        XCTAssertEqual(command.keyEquivalent, "o")
        XCTAssertEqual(command.keyEquivalentModifierMask, [.command, .option])
        let action = try XCTUnwrap(command.action)
        XCTAssertTrue(
            NSApp.target(forAction: action, to: nil, from: command) as? NativeTerminalView
                === surface.terminalView
        )
        XCTAssertFalse(surface.terminalView.optionAsMetaKey)

        let event = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [.command, .option],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                characters: "ø",
                charactersIgnoringModifiers: "o",
                isARepeat: false,
                keyCode: 31
            )
        )
        XCTAssertTrue(try XCTUnwrap(NSApp.mainMenu).performKeyEquivalent(with: event))

        XCTAssertTrue(surface.terminalView.optionAsMetaKey)
        XCTAssertTrue(delegate.bytes.isEmpty)
        XCTAssertTrue(surface.terminalView.validateMenuItem(command))
        XCTAssertEqual(command.state, .on)
    }

    func testTerminalExposesMinimumNativeAccessibilityContract() {
        let surface = makeSurface()
        surface.feed(Data("ready".utf8), isSnapshot: false)

        XCTAssertTrue(surface.terminalView.isAccessibilityElement())
        XCTAssertEqual(surface.terminalView.accessibilityRole(), .textArea)
        XCTAssertEqual(surface.terminalView.accessibilityLabel(), "Terminal")
        XCTAssertTrue((surface.terminalView.accessibilityValue() as? String)?.contains("ready") == true)
        XCTAssertTrue(surface.terminalView.accessibilityPerformPress())
    }

    func testFrameDecodeFeedAndRendererDrawRequestMicrobenchmark() throws {
        let (surface, window) = makeAttachedSurface()
        defer { window.close() }
        let encoded = try SessionFrame(
            kind: .output,
            requestOrSequence: 42,
            payload: RawPayload.encode(
                sessionID: "native-terminal",
                bytes: Data("\u{1b}[2J\u{1b}[Hbenchmark".utf8)
            )
        ).encoded()

        measure(metrics: [XCTClockMetric(), XCTCPUMetric()]) {
            for _ in 0..<100 {
                var decoder = FrameDecoder()
                let frame = try! XCTUnwrap(try! decoder.append(encoded).first)
                let raw = try! RawPayload.decode(frame.payload)
                surface.feed(
                    raw.bytes,
                    isSnapshot: false,
                    sequence: frame.requestOrSequence
                )
                _ = surface.requestRendererDraw()
            }
        }
    }

    func testAttachedMetalTerminalRequestsRendererDrawWhenAvailable() throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal is unavailable on this host")
        }
        let (surface, window) = makeAttachedSurface()
        defer { window.close() }

        XCTAssertTrue(
            surface.terminalView.descendants.contains { $0 is MTKView },
            "Metal-capable attached terminal should own SwiftTerm's MTKView"
        )
        XCTAssertTrue(surface.requestRendererDraw())
    }

    private func makeSurface() -> TerminalSurfaceView {
        TerminalSurfaceView(
            connection: SessionConnection(
                socketURL: URL(fileURLWithPath: "/tmp/omniagent-controller-test.sock")
            ),
            sessionID: "native-terminal"
        )
    }

    private func makeAttachedSurface() -> (TerminalSurfaceView, NSWindow) {
        let surface = makeSurface()
        let window = WorkspaceWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = surface
        window.makeKeyAndOrderFront(nil)
        return (surface, window)
    }
}

private extension NSView {
    var descendants: [NSView] {
        subviews + subviews.flatMap(\.descendants)
    }
}

private final class RecordingTerminalDelegate: TerminalViewDelegate {
    var bytes: [UInt8] = []

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        bytes.append(contentsOf: data)
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

private extension WorkspaceWindowController {
    /// The pane a given session group holds. Sessions are addressed by group,
    /// never by position: `paneIDs` is the grid's *fill* order, and a shape
    /// with a hole in it does not put the newest pane last.
    func pane(inGroup group: String) -> PaneDescriptor? {
        workspaceView.paneIDs
            .compactMap { workspaceView.descriptor(for: $0) }
            .first { $0.group == group }
    }
}

/// Shared with `SessionNotifierTests`' own fake, kept separate so each file
/// stays readable on its own.
private final class RecordingDelivery: NotificationDelivering {
    private(set) var delivered: [NotificationEntry] = []
    private(set) var withdrawn: [String] = []

    func requestAuthorization() {}
    func deliver(_ entry: NotificationEntry) { delivered.append(entry) }
    func withdraw(identifiers: [String]) { withdrawn.append(contentsOf: identifiers) }
    func deliverTransient(identifier: String, title: String, body: String, sessionID: String) {}
}
