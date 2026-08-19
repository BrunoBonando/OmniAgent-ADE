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
            controller.window?.firstResponder === workspace?.terminalSurface(for: "native-terminal")?.terminalView
        )
    }

    /// Every terminal is named apart, restored ones included: a layout stored
    /// before terminals were named carries no label at all, and those panes
    /// would otherwise keep falling back to the engine's name and render
    /// `claude` in every row.
    func testEveryTerminalIsNamedApartIncludingRestoredOnes() throws {
        let controller = makeEmptyController()
        defer { controller.close() }
        controller.showWindow(nil)
        let workspace = controller.workspaceView

        controller.applyRestoredPanes(
            WorkspaceRestoration.plan(
                fromLayout: PersistedLayoutCodec.serialize([
                    PersistedTab(project: "alpha", engine: .claude, cwd: "/a", id: "sess-a", group: "grp-1"),
                    PersistedTab(project: "alpha", engine: .claude, cwd: "/a", id: "sess-b", group: "grp-1"),
                    PersistedTab(project: "alpha", engine: .shell, cwd: "/a", id: "sess-c", group: "grp-1"),
                ])
            )
        )

        // By id rather than by position: `allPaneIDs` is the grid's fill order,
        // which is not the order the panes were restored in.
        func name(_ id: String) -> String? {
            workspace.descriptor(for: id).map(SessionOutline.paneLabel)
        }
        XCTAssertEqual(name("sess-a"), "Claude 1")
        XCTAssertEqual(name("sess-b"), "Claude 2")
        XCTAssertEqual(name("sess-c"), "Shell 1")
        let names = workspace.allPaneIDs.compactMap(name)
        XCTAssertEqual(Set(names).count, names.count, "no two terminals read the same")
    }

    /// Terminals come back in the order they were saved in, and re-saving
    /// them does not move them. Panes restore one at a time, and
    /// `PaneGrid.synced`'s 2 -> 3 rule seats the third one ahead of the
    /// second — which swapped panes 2 and 3 on every single launch, then
    /// wrote the swap back so the next launch swapped them again.
    func testRestoredTerminalsKeepTheirSavedOrderAcrossRelaunches() {
        let saved = ["sess-a", "sess-b", "sess-c", "sess-d"]
        var layout = PersistedLayoutCodec.serialize(
            saved.map { PersistedTab(project: "alpha", engine: .claude, cwd: "/a", id: $0, group: "grp-1") }
        )

        for launch in 1...3 {
            let controller = makeEmptyController()
            defer { controller.close() }
            controller.showWindow(nil)
            controller.applyRestoredPanes(WorkspaceRestoration.plan(fromLayout: layout))

            XCTAssertEqual(controller.workspaceView.allPaneIDs, saved, "launch \(launch)")
            layout = PersistedLayoutCodec.serialize(
                WorkspaceRestoration.persistedTabs(
                    from: controller.workspaceView.allPaneIDs.compactMap { controller.workspaceView.descriptor(for: $0) }
                )
            )
        }
    }

    /// A terminal claims its Claude conversation exactly once. Claiming twice
    /// is what `--session-id` punishes: naming a conversation that already
    /// exists makes `claude` exit 1 immediately, so a respawn after the daemon
    /// lost a session has to fall back to a stock `claude` rather than
    /// re-claim an id it has already written under.
    func testAConversationIsClaimedOncePerTerminalAndNeverForARestoredOne() throws {
        let controller = makeEmptyController()
        defer { controller.close() }
        controller.showWindow(nil)

        controller.allowConversationClaim(for: "fresh")
        XCTAssertEqual(
            controller.claimConversation(for: "fresh"),
            ClaudeConversation.uuid(forSessionID: "fresh")
        )
        XCTAssertNil(controller.claimConversation(for: "fresh"), "a second spawn goes stock")
        XCTAssertNil(
            controller.claimConversation(for: "restored"),
            "a pane back from the persisted layout may already own a conversation"
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

    /// The lifecycle invariant behind browser panes: a non-terminal pane id
    /// must never reach `ensureSession` (a browser id there silently spawns a
    /// login shell) nor `connection.kill`.
    func testBrowserPanesNeverEnsureOrKillDaemonSessions() {
        let controller = makeController()
        defer { controller.close() }
        controller.showWindow(nil)
        var ensured: [String] = []
        var killed: [String] = []
        controller.sessionEnsurer = { ensured.append($0) }
        controller.sessionKiller = { killed.append($0) }

        controller.applyRestoredPanes([
            RestoredPane(
                sessionID: "term-1", reattaches: true, project: "p", engine: .shell,
                cwd: "/tmp", label: nil, themeId: nil, group: "g1", groupLabel: nil
            ),
        ])
        controller.workspaceView.addPane(
            PaneDescriptor(sessionID: "web-1", group: "g1", kind: .browser, browserURL: "https://example.com")
        )
        // A later restore pass (reconnect path) must skip the browser pane.
        controller.applyRestoredPanes([])
        XCTAssertFalse(ensured.contains("web-1"))
        XCTAssertTrue(ensured.contains("term-1"))

        controller.workspaceView.focusPane("web-1")
        controller.closePane(nil)
        XCTAssertEqual(killed, [], "closing a browser pane must not kill anything")

        controller.workspaceView.focusPane("term-1")
        controller.closePane(nil)
        XCTAssertEqual(killed, ["term-1"])
    }

    /// ⇧⌘T: a browser pane joins the focused pane's session with no PTY
    /// behind it — only the 8-pane grid geometry can refuse one.
    func testNewBrowserJoinsTheFocusedSessionWithoutADaemonSessionAndStopsAtTheGrid() throws {
        let controller = makeController()
        defer { controller.close() }
        controller.showWindow(nil)
        var ensured: [String] = []
        controller.sessionEnsurer = { ensured.append($0) }
        let workspace = controller.workspaceView
        let group = try XCTUnwrap(workspace.descriptor(for: "native-terminal")?.group)

        XCTAssertTrue(controller.newBrowser(in: nil))

        let browserID = try XCTUnwrap(workspace.focusedPaneID)
        let descriptor = try XCTUnwrap(workspace.descriptor(for: browserID))
        XCTAssertEqual(descriptor.kind, .browser)
        XCTAssertEqual(descriptor.group, group, "the browser joins the focused pane's session")
        XCTAssertTrue(ensured.isEmpty, "a browser pane never reaches ensureSession")

        while workspace.paneIDs.count < PaneGrid.maxPanes {
            XCTAssertTrue(controller.newBrowser(in: nil))
        }
        XCTAssertFalse(controller.newBrowser(in: nil), "the grid geometry is the only bound")
        let probe = NSMenuItem(
            title: "New Browser Pane",
            action: #selector(WorkspaceWindowController.newBrowserPane(_:)),
            keyEquivalent: ""
        )
        XCTAssertFalse(controller.validateMenuItem(probe), "and the menu item says so")
        XCTAssertTrue(ensured.isEmpty)
    }

    /// The native-only restore path: browser panes come back from their own
    /// settings row, not the shared `layout` one, and never touch the daemon.
    func testApplyRestoredBrowserPanesAddsBrowserPanesWithoutEnsuringADaemonSession() throws {
        let controller = makeEmptyController()
        defer { controller.close() }
        controller.showWindow(nil)
        var ensured: [String] = []
        controller.sessionEnsurer = { ensured.append($0) }

        controller.applyRestoredBrowserPanes([
            PersistedBrowserPane(url: "https://x", group: "g1", groupLabel: nil),
        ])

        let workspace = controller.workspaceView
        let browserID = try XCTUnwrap(
            workspace.allPaneIDs.first { workspace.descriptor(for: $0)?.kind == .browser }
        )
        let descriptor = try XCTUnwrap(workspace.descriptor(for: browserID))
        XCTAssertEqual(descriptor.browserURL, "https://x")
        XCTAssertEqual(descriptor.group, "g1")
        XCTAssertTrue(ensured.isEmpty, "a restored browser pane never reaches ensureSession")
    }

    /// The shared-row invariant, from the controller's own write path this
    /// time: adding/closing a browser pane writes `SettingsKey.browserPanes`
    /// and never changes the `SettingsKey.layout` value.
    func testBrowserPanesPersistToTheirOwnRowAndNeverTouchTheSharedLayoutRow() throws {
        let controller = makeEmptyController()
        defer { controller.close() }
        var writes: [(String, String)] = []
        controller.settingsWriter = { writes.append(($0, $1)) }
        controller.showWindow(nil)

        // Arm both write gates the way a real launch would once both rows
        // have actually been read.
        controller.applyRestoredPanes([])
        controller.applyRestoredBrowserPanes([])
        let layoutValueBeforeBrowser = writes.last { $0.0 == SettingsKey.layout }?.1

        XCTAssertTrue(controller.newBrowser(in: nil))

        XCTAssertTrue(
            writes.contains { $0.0 == SettingsKey.browserPanes },
            "adding a browser pane persists its own row"
        )
        XCTAssertEqual(
            writes.last { $0.0 == SettingsKey.layout }?.1,
            layoutValueBeforeBrowser,
            "a browser pane must never change the shared layout row"
        )

        let browserWritesAfterAdd = writes.filter { $0.0 == SettingsKey.browserPanes }.count
        controller.closePane(nil)

        XCTAssertGreaterThan(
            writes.filter { $0.0 == SettingsKey.browserPanes }.count,
            browserWritesAfterAdd,
            "closing a browser pane persists the row too"
        )
        XCTAssertEqual(
            writes.last { $0.0 == SettingsKey.layout }?.1,
            layoutValueBeforeBrowser,
            "closing a browser pane must not touch the shared layout row either"
        )
    }

    /// A terminal link click's browser twin of `testNewBrowserJoinsTheFocusedSessionWithoutADaemonSessionAndStopsAtTheGrid`:
    /// the pane lands in the clicking terminal's own session, showing the
    /// clicked URL rather than blank.
    func testALinkClickOpensABrowserPaneInTheSameSessionShowingThatURL() throws {
        let controller = makeController()
        defer { controller.close() }
        controller.showWindow(nil)
        let workspace = controller.workspaceView
        let group = try XCTUnwrap(workspace.descriptor(for: "native-terminal")?.group)
        let surface = try XCTUnwrap(workspace.terminalSurface(for: "native-terminal"))

        surface.onLinkClick?(try XCTUnwrap(URL(string: "https://example.com/path")))

        let browserID = try XCTUnwrap(workspace.focusedPaneID)
        let descriptor = try XCTUnwrap(workspace.descriptor(for: browserID))
        XCTAssertEqual(descriptor.kind, .browser)
        XCTAssertEqual(descriptor.group, group, "opens in the clicking terminal's own session")
        XCTAssertEqual(descriptor.browserURL, "https://example.com/path")
    }

    /// The grid-full edge `testNewBrowserJoinsTheFocusedSessionWithoutADaemonSessionAndStopsAtTheGrid`
    /// leaves unhandled for the toolbar/hole-tile (which just hide instead):
    /// a link click has nowhere silent to go, so it asks, and a confirmed
    /// answer opens a fresh session rather than doing nothing.
    func testALinkClickWithAFullGridAsksAndOpensInAFreshSessionWhenConfirmed() throws {
        let controller = makeController()
        defer { controller.close() }
        controller.showWindow(nil)
        let workspace = controller.workspaceView
        let group = try XCTUnwrap(workspace.descriptor(for: "native-terminal")?.group)
        let surface = try XCTUnwrap(workspace.terminalSurface(for: "native-terminal"))
        while workspace.paneIDs.count < PaneGrid.maxPanes {
            XCTAssertTrue(controller.newBrowser(in: nil))
        }
        var asked: URL?
        controller.newSessionForLinkConfirmer = { url, completion in
            asked = url
            completion(true)
        }

        surface.onLinkClick?(try XCTUnwrap(URL(string: "https://example.com")))

        XCTAssertEqual(asked, URL(string: "https://example.com"))
        let browserID = try XCTUnwrap(workspace.focusedPaneID)
        let descriptor = try XCTUnwrap(workspace.descriptor(for: browserID))
        XCTAssertEqual(descriptor.kind, .browser)
        XCTAssertNotEqual(descriptor.group, group, "a fresh session, not the full one")
        XCTAssertEqual(descriptor.browserURL, "https://example.com")
    }

    /// Declining the prompt must not strand the click: it falls back to
    /// wherever a non-web link already goes (see the test below), and opens
    /// no pane.
    func testDecliningTheNewSessionPromptOpensTheLinkExternallyInstead() throws {
        let controller = makeController()
        defer { controller.close() }
        controller.showWindow(nil)
        let workspace = controller.workspaceView
        let surface = try XCTUnwrap(workspace.terminalSurface(for: "native-terminal"))
        while workspace.paneIDs.count < PaneGrid.maxPanes {
            XCTAssertTrue(controller.newBrowser(in: nil))
        }
        controller.newSessionForLinkConfirmer = { _, completion in completion(false) }
        var opened: URL?
        controller.externalLinkOpener = { opened = $0 }
        let before = workspace.allPaneIDs.count

        surface.onLinkClick?(try XCTUnwrap(URL(string: "https://example.com")))

        XCTAssertEqual(opened, URL(string: "https://example.com"))
        XCTAssertEqual(workspace.allPaneIDs.count, before, "no pane was created")
    }

    /// A browser pane can't do anything with `mailto:`/custom schemes, so
    /// those skip the pane grid entirely rather than asking first.
    func testANonWebLinkSkipsTheBrowserPaneAndOpensExternally() throws {
        let controller = makeController()
        defer { controller.close() }
        controller.showWindow(nil)
        let workspace = controller.workspaceView
        let surface = try XCTUnwrap(workspace.terminalSurface(for: "native-terminal"))
        var opened: URL?
        controller.externalLinkOpener = { opened = $0 }
        let before = workspace.allPaneIDs.count

        surface.onLinkClick?(try XCTUnwrap(URL(string: "mailto:bruno@bonando.com")))

        XCTAssertEqual(opened, URL(string: "mailto:bruno@bonando.com"))
        XCTAssertEqual(workspace.allPaneIDs.count, before, "no browser pane for a non-web scheme")
    }

    func testClosePaneCommandRemovesTheFocusedPaneAndLeavesTheRestAlive() throws {
        let controller = makeController()
        defer { controller.close() }
        controller.showWindow(nil)
        let workspace = controller.workspaceView
        controller.newTerminalPane(nil)
        controller.newTerminalPane(nil)
        let survivors = workspace.paneIDs.filter { $0 != workspace.focusedPaneID }
        let survivingTerminals = survivors.map { ObjectIdentifier(workspace.terminalSurface(for: $0)!.terminalView) }

        controller.closePane(nil)

        XCTAssertEqual(workspace.paneIDs.count, 2)
        XCTAssertEqual(
            survivors.map { ObjectIdentifier(workspace.terminalSurface(for: $0)!.terminalView) },
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
            file.item(withTitle: "New Browser Pane")?.action,
            #selector(WorkspaceWindowController.newBrowserPane(_:))
        )
        XCTAssertEqual(file.item(withTitle: "New Browser Pane")?.keyEquivalent, "t")
        XCTAssertEqual(
            file.item(withTitle: "New Browser Pane")?.keyEquivalentModifierMask,
            [.command, .shift],
            "⇧⌘T, beside New Terminal Pane's ⌘T"
        )
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

    // MARK: - Focus mode

    /// ⌘↩'s responder-chain action: zooms the focused pane, and the same
    /// command shrinks it back.
    func testToggleFocusModeEntersAndLeavesZoomOnTheFocusedPane() throws {
        let controller = makeController()
        defer { controller.close() }
        controller.showWindow(nil)
        let workspace = controller.workspaceView
        controller.newTerminalPane(nil)
        let focused = try XCTUnwrap(workspace.focusedPaneID)
        XCTAssertEqual(workspace.paneIDs.count, 2)

        controller.toggleFocusMode(nil)
        XCTAssertEqual(workspace.zoomedPaneID, focused)

        controller.toggleFocusMode(nil)
        XCTAssertNil(workspace.zoomedPaneID)
    }

    /// Revealing a pane while a card is up — the palette, or clicking the
    /// notification an agent raised in another pane — has to move the card, not
    /// just the caret. Focusing behind the blur is how the approval the
    /// notification asked for gets typed into a terminal nobody can see.
    func testRevealingAPaneWhileACardIsUpMovesTheCardToIt() throws {
        let controller = makeController()
        defer { controller.close() }
        controller.showWindow(nil)
        let workspace = controller.workspaceView
        controller.newTerminalPane(nil)
        let panes = workspace.paneIDs
        XCTAssertEqual(panes.count, 2)
        workspace.focusPane(panes[0])
        controller.toggleFocusMode(nil)
        XCTAssertEqual(workspace.zoomedPaneID, panes[0])

        XCTAssertTrue(controller.revealPane(panes[1]))

        XCTAssertEqual(workspace.focusedPaneID, panes[1])
        XCTAssertEqual(
            workspace.zoomedPaneID,
            panes[1],
            "the card follows, so what the user types is in the terminal they can see"
        )
    }

    /// And with focus moved off the card by ⌘1…⌘9 or ⌥arrows, ⌘↩ hands the card
    /// to the focused pane — so an item reading "Exit Focus" would be describing
    /// the opposite of what it is about to do.
    func testTheFocusMenuItemTellsTheTruthWhenFocusHasLeftTheCard() throws {
        let controller = makeController()
        defer { controller.close() }
        controller.showWindow(nil)
        let workspace = controller.workspaceView
        controller.newTerminalPane(nil)
        let panes = workspace.paneIDs
        workspace.focusPane(panes[0])
        controller.toggleFocusMode(nil)

        let item = NSMenuItem(
            title: "",
            action: #selector(WorkspaceWindowController.toggleFocusMode(_:)),
            keyEquivalent: "\r"
        )
        XCTAssertTrue(controller.validateMenuItem(item))
        XCTAssertEqual(item.title, "Exit Focus", "the focused pane is the card")

        // A focus *command* carries the card now, so the divergent state is only
        // reachable through `focusPane(_:)` itself — which is what the palette's
        // "close pane" arm and the sidebar's rows call, and which deliberately does
        // not carry (it is what `setZoomed` calls, so it would re-enter).
        workspace.focusPane(panes[1])
        XCTAssertEqual(workspace.zoomedPaneID, panes[0], "the card stayed where it was")
        XCTAssertTrue(controller.validateMenuItem(item))
        XCTAssertEqual(
            item.title,
            "Focus This Terminal",
            "focus is off the card, so ⌘↩ moves the card rather than exiting"
        )

        // And the commands themselves keep the two together.
        XCTAssertTrue(workspace.focusPane(at: 1))
        XCTAssertTrue(controller.validateMenuItem(item))
        XCTAssertEqual(item.title, "Exit Focus", "focus and the card are one again")
    }

    /// ⌘↩ is about a terminal. Off the Terminals destination the pane workspace
    /// is hidden entirely, so the item greys out and the action refuses.
    func testFocusModeIsRefusedOffTheTerminalsDestination() throws {
        let controller = makeController()
        defer { controller.close() }
        controller.showWindow(nil)
        let workspace = controller.workspaceView
        controller.newTerminalPane(nil)
        let item = NSMenuItem(
            title: "",
            action: #selector(WorkspaceWindowController.toggleFocusMode(_:)),
            keyEquivalent: "\r"
        )
        XCTAssertTrue(controller.validateMenuItem(item), "enabled on Terminals")

        controller.applyDestination(.dashboard)

        XCTAssertFalse(controller.validateMenuItem(item), "and greyed out off it")
        controller.toggleFocusMode(nil)
        XCTAssertNil(workspace.zoomedPaneID, "the action refuses too, not only the item")

        controller.applyDestination(.terminals)
        XCTAssertTrue(controller.validateMenuItem(item))
    }

    func testToggleFocusModeWithNoFocusedPaneDoesNothing() {
        let controller = makeEmptyController()
        defer { controller.close() }
        controller.showWindow(nil)
        XCTAssertNil(controller.workspaceView.focusedPaneID, "nothing restored yet, nothing focused")

        controller.toggleFocusMode(nil)

        XCTAssertNil(controller.workspaceView.zoomedPaneID)
    }

    /// The menu item that carries ⌘↩: greyed out below two panes, and its
    /// title tells the truth about what pressing it will do.
    func testFocusModeMenuItemIsDisabledBelowTwoPanesAndItsTitleFollowsZoomState() throws {
        let controller = makeController()
        defer { controller.close() }
        controller.showWindow(nil)
        let workspace = controller.workspaceView
        let menuItem = NSMenuItem(
            title: "Focus This Terminal",
            action: #selector(WorkspaceWindowController.toggleFocusMode(_:)),
            keyEquivalent: ""
        )

        XCTAssertFalse(controller.validateMenuItem(menuItem), "one pane on screen — nothing to zoom over")

        controller.newTerminalPane(nil)
        XCTAssertTrue(controller.validateMenuItem(menuItem))
        XCTAssertEqual(menuItem.title, "Focus This Terminal")

        let focused = try XCTUnwrap(workspace.focusedPaneID)
        workspace.setZoomed(focused)
        XCTAssertTrue(controller.validateMenuItem(menuItem))
        XCTAssertEqual(menuItem.title, "Exit Focus", "the menu tells the truth about what ⌘↩ will do next")
    }

    /// The window's `onEscape` closure — not a synthesised `NSEvent`, per the
    /// brief: exercise the handler `WorkspaceWindowController` wires up
    /// directly.
    func testEscapeClosureUnzoomsWhileZoomedAndOtherwiseLeavesEscapeToTheTerminal() throws {
        let controller = makeController()
        defer { controller.close() }
        controller.showWindow(nil)
        let workspace = controller.workspaceView
        controller.newTerminalPane(nil)
        let focused = try XCTUnwrap(workspace.focusedPaneID)
        let window = try XCTUnwrap(controller.window as? WorkspaceWindow)
        let onEscape = try XCTUnwrap(window.onEscape)

        XCTAssertFalse(onEscape(), "nothing zoomed — the terminal must keep getting escape")

        workspace.setZoomed(focused)
        XCTAssertTrue(onEscape(), "escape is consumed")
        XCTAssertNil(workspace.zoomedPaneID, "and focus mode ends")
    }

    /// The gate that decides whether `sendEvent` even offers a key to
    /// `onEscape` — a bare escape, none of command/option/control/shift
    /// held, and not currently typed into a field editor. A realistic
    /// key-down `NSEvent` paired with a real field-editor first responder
    /// isn't worth synthesising, so the predicate is exercised directly.
    func testIsPlainEscapeExcludesModifiedKeysOtherKeysAndAnActiveFieldEditor() {
        XCTAssertTrue(
            WorkspaceWindow.isPlainEscape(keyCode: WorkspaceWindow.escapeKeyCode, modifierFlags: [], isEditingText: false)
        )
        XCTAssertFalse(
            WorkspaceWindow.isPlainEscape(keyCode: 36, modifierFlags: [], isEditingText: false),
            "any other keycode is not escape"
        )
        let blockingModifiers: [NSEvent.ModifierFlags] = [.command, .option, .control, .shift]
        for modifier in blockingModifiers {
            XCTAssertFalse(
                WorkspaceWindow.isPlainEscape(
                    keyCode: WorkspaceWindow.escapeKeyCode,
                    modifierFlags: modifier,
                    isEditingText: false
                ),
                "\(modifier) held must not count as a plain escape"
            )
        }
        XCTAssertFalse(
            WorkspaceWindow.isPlainEscape(keyCode: WorkspaceWindow.escapeKeyCode, modifierFlags: [], isEditingText: true),
            "an active field editor — a sidebar rename, the files-tree filter field — keeps its own escape"
        )
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

    /// The title an engine reports arrives with its spinner attached — Claude
    /// sends `✳ …` one frame and `◐ …` the next — and it is stripped once, on
    /// the way in, so the header, the sidebar row, the window title and the
    /// session-ended notification all read the task rather than the animation.
    func testAReportedTitleIsStrippedOfItsSpinnerOnTheWayIn() throws {
        let controller = makeEmptyController()
        defer { controller.close() }
        controller.showWindow(nil)
        controller.applyRestoredPanes(
            WorkspaceRestoration.plan(
                fromLayout: PersistedLayoutCodec.serialize([
                    PersistedTab(project: "alpha", engine: .claude, cwd: "/a", id: "sess-a", group: "g1"),
                ])
            )
        )
        let workspace = controller.workspaceView
        let surface = try XCTUnwrap(workspace.terminalSurface(for: "sess-a"))

        surface.onTitleChange?("✳ Fixing the parser")
        XCTAssertEqual(workspace.descriptor(for: "sess-a")?.title, "Fixing the parser")
        XCTAssertEqual(
            workspace.descriptor(for: "sess-a").map(SessionOutline.paneLabel),
            "Fixing the parser"
        )

        surface.onTitleChange?("◐ Fixing the parser")
        XCTAssertEqual(
            workspace.descriptor(for: "sess-a")?.title,
            "Fixing the parser",
            "the next spinner frame is the same name, so nothing downstream even sees a change"
        )
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
        XCTAssertEqual(controller.workspaceView.allPaneIDs.count, 2)
        XCTAssertEqual(
            controller.workspaceView.paneIDs.count,
            1,
            "a session shows its own terminals and only its own"
        )
        XCTAssertEqual(
            controller.workspaceView.paneIDs.last.flatMap { controller.workspaceView.descriptor(for: $0)?.cwd },
            "/a",
            "it starts in the workspace's own folder"
        )
        XCTAssertEqual(
            Set(
                controller.workspaceView.allPaneIDs
                    .compactMap { controller.workspaceView.descriptor(for: $0)?.group }
            ).count,
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
        let before = controller.workspaceView.allPaneIDs.count
        controller.openWorkspaceFolder(nil)
        XCTAssertEqual(controller.workspaceView.allPaneIDs.count, before)

        // Eight terminals is a *session's* limit, not the app's. ⌘T adds to
        // the session on screen, so filling that one greys ⌘T out and leaves
        // everything else alone.
        while controller.workspaceView.paneIDs.count < PaneGrid.maxPanes {
            controller.newTerminalPane(nil)
        }
        let full = controller.workspaceView.allPaneIDs.count
        XCTAssertEqual(controller.workspaceView.paneIDs.count, PaneGrid.maxPanes, "the session is full")
        XCTAssertGreaterThan(full, PaneGrid.maxPanes, "and other sessions still hold their own")

        controller.newTerminalPane(nil)
        XCTAssertEqual(controller.workspaceView.allPaneIDs.count, full, "a full session takes no more")
        XCTAssertFalse(
            controller.validateMenuItem(
                NSMenuItem(title: "New Terminal", action: #selector(WorkspaceWindowController.newTerminalPane(_:)), keyEquivalent: "")
            ),
            "⌘T is greyed out for a full session"
        )
        XCTAssertTrue(
            controller.validateMenuItem(
                NSMenuItem(title: "New Session", action: #selector(WorkspaceWindowController.newSession(_:)), keyEquivalent: "")
            ),
            "but a full session must not stop a new one from being started"
        )

        controller.newSession(nil)
        XCTAssertEqual(controller.workspaceView.paneIDs.count, 1, "which opens with one terminal of its own")
        XCTAssertEqual(controller.workspaceView.allPaneIDs.count, full + 1)
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
        // From every pane, not just the visible ones: the sidebar draws every
        // session, and the row being clicked here is one that is off screen.
        let sessions = SessionOutline.group(
            controller.workspaceView.allPaneIDs.compactMap { controller.workspaceView.descriptor(for: $0) },
            focusedPaneID: "sess-a"
        ).first?.sessions ?? []
        let secondSession = try XCTUnwrap(sessions.first { $0.id == "g2" })

        controller.newPane(in: secondSession)

        let added = try XCTUnwrap(
            controller.workspaceView.allPaneIDs
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

    /// The ladder's row counts map to window sizes through `rowWindowScale`,
    /// and two and three rows deliberately share one. `makeController` already opens
    /// one pane, so the window has already been through its *first*
    /// row-count transition — and already scaled from whatever raw frame it
    /// started at — by the time this reads `window.frame`; there is no
    /// observing the pre-scale frame from outside. What the reference-frame
    /// design promises, and what is actually checkable, is that returning to
    /// a row count always lands on the exact size that row count landed on
    /// before — never a little larger each time.
    func testWindowScalesOnARowCountTransitionAndReturnsToTheSameSizeRatherThanCompounding() throws {
        let controller = makeController()
        defer { controller.close() }
        controller.showWindow(nil)
        let window = try XCTUnwrap(controller.window)
        let visible = try XCTUnwrap(window.screen?.visibleFrame)
        let group = try XCTUnwrap(controller.workspaceView.descriptor(for: "native-terminal")?.group)
        let oneRow = window.frame.size

        // Two browser panes — no daemon session behind them, so no PTY
        // needed — bring the grid from one pane to three, which is row two
        // on this ladder.
        controller.workspaceView.addPane(
            PaneDescriptor(sessionID: "extra-1", group: group, kind: .browser, browserURL: "https://example.com")
        )
        controller.workspaceView.addPane(
            PaneDescriptor(sessionID: "extra-2", group: group, kind: .browser, browserURL: "https://example.com")
        )
        XCTAssertEqual(controller.workspaceView.grid?.rows, 2)
        let twoRow = window.frame.size
        XCTAssertNotEqual(twoRow, oneRow, "the transition to two rows actually resized the window")
        XCTAssertEqual(window.frame.midX, visible.midX, accuracy: 1, "centred on screen")
        XCTAssertEqual(window.frame.midY, visible.midY, accuracy: 1)

        controller.workspaceView.focusPane("extra-1")
        controller.closePane(nil)
        controller.workspaceView.focusPane("extra-2")
        controller.closePane(nil)
        XCTAssertEqual(controller.workspaceView.grid?.rows, 1)
        XCTAssertEqual(window.frame.size, oneRow, "back to one row lands on the exact size the first transition did")

        // A second round trip must land on the same two sizes again, not
        // scale either one further from wherever the window sits now — the
        // property scaling from a fixed reference, rather than the window's
        // current frame, exists to guarantee.
        controller.workspaceView.addPane(
            PaneDescriptor(sessionID: "extra-3", group: group, kind: .browser, browserURL: "https://example.com")
        )
        controller.workspaceView.addPane(
            PaneDescriptor(sessionID: "extra-4", group: group, kind: .browser, browserURL: "https://example.com")
        )
        XCTAssertEqual(window.frame.size, twoRow, "a second trip to two rows lands on the same size as the first")
    }

    // MARK: - Orphaned sessions

    /// The daemon outlives the app so terminals survive a restart, but nothing
    /// used to clean up the sessions a restart left behind — and it caps at 8.
    /// Found in the wild holding 8 live sessions against a 2-pane layout, at
    /// which point every new terminal was refused and drawn as a blank pane.
    func testOrphanedSessionsAreTheOnesNoPaneOwns() {
        let owned: Set<String> = ["a", "b"]
        XCTAssertEqual(
            WorkspaceWindowController.orphanedSessions(
                daemonSessions: ["a", "b", "stale-1", "stale-2"],
                owned: owned
            ),
            ["stale-1", "stale-2"]
        )

        XCTAssertEqual(
            WorkspaceWindowController.orphanedSessions(daemonSessions: ["a", "b"], owned: owned),
            [],
            "a daemon holding exactly what the window owns loses nothing"
        )

        XCTAssertEqual(
            WorkspaceWindowController.orphanedSessions(daemonSessions: [], owned: owned),
            []
        )
    }

    /// The dangerous case. Owning nothing means something went wrong upstream
    /// — a restore always leaves at least one pane — and that is precisely
    /// when killing every session on the machine would be worst.
    func testOwningNoPanesReapsNothingRatherThanEverything() {
        XCTAssertEqual(
            WorkspaceWindowController.orphanedSessions(
                daemonSessions: ["live-1", "live-2", "live-3"],
                owned: []
            ),
            []
        )
    }

    // MARK: - Command palette and toolbar

    func testTheCommandPaletteAndSidebarToggleAreOnTheMenuAndTravelTheResponderChain() throws {
        ApplicationMenus.install()
        let file = try XCTUnwrap(NSApp.mainMenu?.item(withTitle: "File")?.submenu)
        let spotlights = file.items.filter { $0.title == "Spotlight" }
        XCTAssertEqual(spotlights.count, 2, "one visible row, plus the ⌘K alternate under ⌥")
        for palette in spotlights {
            XCTAssertNil(palette.target)
            XCTAssertEqual(palette.action, #selector(WorkspaceWindowController.showCommandPalette(_:)))
        }
        // ⌃Space is the shortcut; ⌘K still opens it for anyone whose input
        // sources have claimed that chord.
        XCTAssertEqual(spotlights.map(\.keyEquivalent), [" ", "k"])
        XCTAssertEqual(spotlights.map(\.keyEquivalentModifierMask), [[.control], [.command]])
        XCTAssertEqual(spotlights.map(\.isAlternate), [false, true])

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
                WorkspaceWindowController.ToolbarItem.newBrowser,
                WorkspaceWindowController.ToolbarItem.newEditor,
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

    /// A restart comes back to the session that was in use last, not to
    /// whichever pane happened to be restored last (every restored pane
    /// focuses itself on the way in, so without this the last one wins).
    func testRestoreReturnsToTheLastUsedSession() {
        let controller = makeEmptyController()
        defer { controller.close() }
        controller.sessionEnsurer = { _ in }
        controller.showWindow(nil)
        controller.lastFocusedPaneOnLaunch = "sess-a"

        controller.applyRestoredPanes(
            WorkspaceRestoration.plan(
                fromLayout: PersistedLayoutCodec.serialize([
                    PersistedTab(project: "alpha", engine: .shell, cwd: "/a", id: "sess-a", group: "grp-1"),
                    PersistedTab(project: "alpha", engine: .shell, cwd: "/a", id: "sess-b", group: "grp-2"),
                ])
            )
        )
        XCTAssertEqual(controller.workspaceView.activeGroup, "grp-2", "the last restored pane won, so far")

        controller.applyRestoredBrowserPanes([])

        XCTAssertEqual(controller.workspaceView.focusedPaneID, "sess-a")
        XCTAssertEqual(controller.workspaceView.activeGroup, "grp-1")
        XCTAssertNil(controller.lastFocusedPaneOnLaunch, "spent once, so a reconnect never re-steals focus")
    }

    func testThePaneHeaderMenuButtonHasAMenuToOpen() {
        let controller = makeController()

        XCTAssertNotNil(
            controller.workspaceView.onRequestPaneMenu,
            "the ⋯ button asked and nobody answered, so clicking it did nothing"
        )
        let menu = controller.paneOptionsMenu()
        XCTAssertEqual(
            menu.items.map(\.title),
            ["Rename Conversation…", "Use Option as Meta", "", "Close Pane"]
        )
        XCTAssertTrue(
            menu.items.allSatisfy { $0.isSeparatorItem || ($0.action != nil && $0.target == nil) },
            "nil targets are what send each item down the responder chain to the focused pane"
        )
    }

    func testEveryItemInTheMenuNamesSomethingThatExists() {
        // Half the items are `Selector(("…"))` string literals, because the
        // methods live on classes this one cannot see. A typo in one of those
        // compiles happily and greys the item out at runtime with nothing said,
        // which is the exact failure the ⋯ button already had once.
        let controller = makeController()
        let surface = makeSurface()
        for item in controller.paneOptionsMenu().items where !item.isSeparatorItem {
            guard let action = item.action else {
                XCTAssertNotNil(item.submenu, "\(item.title) does nothing and opens nothing")
                continue
            }
            XCTAssertTrue(
                controller.responds(to: action) || surface.terminalView.responds(to: action),
                "\(item.title) sends \(action), which nothing in the pane's responder chain implements"
            )
        }
    }

    func testTheColorItemIsClaudeOnly() {
        let controller = makeController()
        controller.applyRestoredPanes(
            WorkspaceRestoration.plan(
                fromLayout: PersistedLayoutCodec.serialize([
                    PersistedTab(project: "alpha", engine: .shell, cwd: "/a", id: "sess-sh", group: "grp-1"),
                    PersistedTab(project: "alpha", engine: .claude, cwd: "/a", id: "sess-cl", group: "grp-1"),
                ])
            )
        )

        controller.workspaceView.focusPane("sess-sh")
        XCTAssertFalse(
            controller.paneOptionsMenu().items.contains { $0.title == "Change Claude Color" },
            "a shell terminal has no /color, so offering it is offering nothing"
        )
        XCTAssertFalse(
            controller.paneOptionsMenu().items.contains { $0.title == "Change Model" },
            "nor a /model"
        )

        controller.workspaceView.focusPane("sess-cl")
        let colors = controller.paneOptionsMenu().items.first { $0.title == "Change Claude Color" }
        XCTAssertEqual(
            colors?.submenu?.items.map(\.title),
            ["Red", "Blue", "Green", "Yellow", "Purple", "Orange", "Pink", "Cyan", "Default"],
            "/color takes these names and rejects everything else, hex included"
        )
        XCTAssertEqual(
            colors?.submenu?.items.map { $0.representedObject as? String },
            WorkspaceWindowController.claudeColors,
            "the lowercase name is what gets typed at the terminal"
        )
        XCTAssertTrue(
            colors?.submenu?.items.allSatisfy { $0.image != nil } == true,
            "the swatch is what makes a list of colour words pickable at a glance"
        )

        let models = controller.paneOptionsMenu().items.first { $0.title == "Change Model" }
        XCTAssertEqual(
            models?.submenu?.items.map { $0.representedObject as? String },
            WorkspaceWindowController.claudeModels.map(\.1),
            "the alias is what gets typed after /model"
        )
    }

    func testRenamingTheConversationRenamesThePane() {
        let controller = makeController()
        controller.applyRestoredPanes(
            WorkspaceRestoration.plan(
                fromLayout: PersistedLayoutCodec.serialize([
                    PersistedTab(project: "alpha", engine: .claude, cwd: "/a", id: "sess-cl", group: "grp-1"),
                ])
            )
        )
        controller.workspaceView.focusPane("sess-cl")
        controller.conversationNamePrompt = { _, completion in completion("  Ingest rewrite  ") }

        controller.renameConversation(nil)

        XCTAssertEqual(
            controller.workspaceView.descriptor(for: "sess-cl")?.label,
            "Ingest rewrite",
            "the sidebar's half of the rename"
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

    func testOptionDeleteSendsMetaBackspaceSoTheShellKillsAWord() throws {
        let surface = makeSurface()
        let delegate = RecordingTerminalDelegate()
        surface.terminalView.terminalDelegate = delegate

        XCTAssertTrue(surface.terminalView.optionAsMetaKey)
        surface.terminalView.keyDown(with: try optionDeleteEvent())

        // ESC DEL is readline's `backward-kill-word`; a bare 0x7f kills one char.
        XCTAssertEqual(delegate.bytes, [0x1b, 0x7f])
    }

    private func optionDeleteEvent() throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [.option],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: 0,
                context: nil,
                characters: "\u{7f}",
                charactersIgnoringModifiers: "\u{7f}",
                isARepeat: false,
                keyCode: 51
            )
        )
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
        XCTAssertTrue(surface.terminalView.optionAsMetaKey)

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

        XCTAssertFalse(surface.terminalView.optionAsMetaKey)
        XCTAssertTrue(delegate.bytes.isEmpty)
        XCTAssertTrue(surface.terminalView.validateMenuItem(command))
        XCTAssertEqual(command.state, .off)
    }

    /// The one-line mechanism the whole feature rides on: `.hover` matches
    /// exactly what `.hoverWithModifier` (SwiftTerm's default) already
    /// matches, minus the ⌘ requirement — so a plain click opens a link
    /// without new mouse-event interception.
    func testTheTerminalMatchesLinksOnAPlainClickNotOnlyCommandClick() {
        let surface = makeSurface()
        XCTAssertEqual(surface.terminalView.linkHighlightMode, .hover)
    }

    /// `requestOpenLink` is a forwarder, same shape as `onTitleChange`/
    /// `onDirectoryChange`: parse and hand upward, decide nothing itself.
    func testALinkClickForwardsTheParsedURL() {
        let surface = makeSurface()
        var clicked: URL?
        surface.onLinkClick = { clicked = $0 }

        surface.requestOpenLink(source: surface.terminalView, link: "https://example.com/path", params: [:])

        XCTAssertEqual(clicked, URL(string: "https://example.com/path"))
    }

    func testAnUnparsableLinkForwardsNothing() {
        let surface = makeSurface()
        var clicked: URL?
        surface.onLinkClick = { clicked = $0 }

        surface.requestOpenLink(source: surface.terminalView, link: "", params: [:])

        XCTAssertNil(clicked)
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
        // Not released on close: see `PaneWorkspaceViewTests.makeAttachedWorkspace`
        // for what an over-released test window does to a later CA commit.
        window.isReleasedWhenClosed = false
        window.contentView = surface
        window.makeKeyAndOrderFront(nil)
        return (surface, window)
    }

    /// A daemon restart must not leave dead terminals — nor start a shell
    /// behind a browser pane.
    func testReattachFailureRebuildsTerminalPanesOnly() {
        let controller = makeController()
        defer { controller.close() }
        controller.showWindow(nil)
        var ensured: [String] = []
        controller.sessionEnsurer = { ensured.append($0) }
        controller.applyRestoredPanes([
            RestoredPane(
                sessionID: "term-1", reattaches: true, project: "p", engine: .claude,
                cwd: "/tmp", label: nil, themeId: nil, group: "g1", groupLabel: nil
            ),
        ])
        controller.workspaceView.addPane(
            PaneDescriptor(sessionID: "web-1", group: "g1", kind: .browser, browserURL: "https://example.com")
        )
        ensured.removeAll()

        controller.handleReattachFailure("term-1")
        controller.handleReattachFailure("web-1")
        controller.handleReattachFailure("gone-1")

        XCTAssertEqual(ensured, ["term-1"])
    }

    /// Two callers asking for the same pane at once — a reconnect's restore
    /// sweep and that pane's own reattach failure — must produce one spawn,
    /// not two and a `session already exists` error painted over a working
    /// agent.
    func testEnsureIsClaimedUntilTheSpawnAnswers() {
        let controller = makeController()
        defer { controller.close() }
        XCTAssertTrue(controller.beginEnsure("term-1"))
        XCTAssertFalse(controller.beginEnsure("term-1"))
        XCTAssertTrue(controller.beginEnsure("term-2"), "a different pane is unaffected")
        controller.endEnsure("term-1")
        XCTAssertTrue(controller.beginEnsure("term-1"))
    }

    // MARK: - `--resume` fallback

    func testResumeFailedOnlyForAFastNonZeroExitOfAResumeSpawn() {
        let now = Date()
        let spawned = now.addingTimeInterval(-1.25)
        XCTAssertTrue(WorkspaceWindowController.resumeFailed(spawnedAt: spawned, exitCode: 1, now: now))
        // Killed by a signal — no code — still means the pane never started.
        XCTAssertTrue(WorkspaceWindowController.resumeFailed(spawnedAt: spawned, exitCode: nil, now: now))
        // A clean quit is a quit, not a missing conversation.
        XCTAssertFalse(WorkspaceWindowController.resumeFailed(spawnedAt: spawned, exitCode: 0, now: now))
        // An hour in, a crash is the agent's business, not a failed resume.
        XCTAssertFalse(
            WorkspaceWindowController.resumeFailed(
                spawnedAt: now.addingTimeInterval(-3600),
                exitCode: 1,
                now: now
            )
        )
        // A session that never carried `--resume` is never respawned.
        XCTAssertFalse(WorkspaceWindowController.resumeFailed(spawnedAt: nil, exitCode: 1, now: now))
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
