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
        controller.applyDestination(.terminals)
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
        controller.applyDestination(.terminals)
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
        controller.applyDestination(.terminals)
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
        controller.applyDestination(.terminals)
        let item = NSMenuItem(
            title: "",
            action: #selector(WorkspaceWindowController.toggleFocusMode(_:)),
            keyEquivalent: "\r"
        )
        XCTAssertTrue(controller.validateMenuItem(item), "enabled on Terminals")

        controller.applyDestination(.home)

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
        controller.applyDestination(.terminals)
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

    /// Selecting a workspace does not move focus, so focus routinely belongs to
    /// another project. The "new terminal" row under a project must still add to
    /// that project — under the current rule it silently did nothing.
    func testNewTerminalAddsToTheVisibleSessionWhenFocusIsInAnotherProject() throws {
        let controller = makeEmptyController()
        defer { controller.close() }
        controller.showWindow(nil)
        let workspace = controller.workspaceView
        controller.applyRestoredPanes(
            WorkspaceRestoration.plan(
                fromLayout: PersistedLayoutCodec.serialize([
                    PersistedTab(project: "alpha", engine: .shell, cwd: "/a", id: "alpha-1", group: "grp-alpha"),
                    PersistedTab(project: "beta", engine: .shell, cwd: "/b", id: "beta-1", group: "grp-beta"),
                ])
            )
        )
        controller.selectWorkspace(id: "alpha", animated: false)
        workspace.focusPane("beta-1")

        let before = Set(workspace.allPaneIDs)
        XCTAssertTrue(controller.newPaneInVisibleSessionForTesting())

        XCTAssertEqual(workspace.allPaneIDs.count, before.count + 1, "the row did nothing")
        // Found by difference rather than `allPaneIDs.last`: that array runs
        // session by session, so a pane added to the *first* session is not
        // last in it.
        let added = try XCTUnwrap(
            Set(workspace.allPaneIDs).subtracting(before).first.flatMap { workspace.descriptor(for: $0) }
        )
        XCTAssertEqual(added.project, "alpha", "it joined the project on screen, not the one holding focus")
        XCTAssertEqual(added.group, "grp-alpha")
    }

    /// The visible rule agrees with the current rule whenever focus *is* in the
    /// project on screen — the change must not move panes that were landing
    /// correctly before.
    func testNewTerminalStillJoinsTheFocusedSessionWhenFocusIsInThisProject() throws {
        let controller = makeEmptyController()
        defer { controller.close() }
        controller.showWindow(nil)
        let workspace = controller.workspaceView
        controller.applyRestoredPanes(
            WorkspaceRestoration.plan(
                fromLayout: PersistedLayoutCodec.serialize([
                    PersistedTab(project: "alpha", engine: .shell, cwd: "/a", id: "alpha-1", group: "grp-one"),
                    PersistedTab(project: "alpha", engine: .shell, cwd: "/a", id: "alpha-2", group: "grp-two"),
                ])
            )
        )
        controller.selectWorkspace(id: "alpha", animated: false)
        workspace.focusPane("alpha-2")

        let before = Set(workspace.allPaneIDs)
        XCTAssertTrue(controller.newPaneInVisibleSessionForTesting())

        let added = try XCTUnwrap(
            Set(workspace.allPaneIDs).subtracting(before).first.flatMap { workspace.descriptor(for: $0) }
        )
        XCTAssertEqual(added.group, "grp-two", "focus is in this project, so its session still wins")
    }

    /// A window that has not picked a workspace — Level 1, or a bootstrap pane,
    /// whose project is `""` and so never selects one — still has a session on
    /// screen: the focused pane's. Resolving the target from `selectedProjectID`
    /// alone left all three rows doing nothing there, which is the same silence
    /// the visible-session rule exists to remove rather than move.
    func testNewTerminalStillAddsBeforeAnyWorkspaceHasBeenSelected() throws {
        let controller = makeController()
        defer { controller.close() }
        controller.showWindow(nil)
        let workspace = controller.workspaceView
        XCTAssertNil(
            controller.selectedProjectID,
            "the bootstrap pane carries no project, so no workspace was selected"
        )

        let before = Set(workspace.allPaneIDs)
        XCTAssertTrue(controller.newPaneInVisibleSessionForTesting())

        let added = try XCTUnwrap(
            Set(workspace.allPaneIDs).subtracting(before).first.flatMap { workspace.descriptor(for: $0) }
        )
        XCTAssertEqual(
            added.group,
            workspace.descriptor(for: "native-terminal")?.group,
            "it joined the focused pane's session"
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

    /// Crossing a row count leaves the window exactly where the user put it
    /// (Bruno, 2026-08-21). The window used to scale and re-centre on every
    /// row-count change, which moved it out from under the cursor mid-drop.
    func testCrossingARowCountNeverResizesOrMovesTheWindow() throws {
        let controller = makeController()
        defer { controller.close() }
        controller.showWindow(nil)
        let window = try XCTUnwrap(controller.window)
        window.setFrame(NSRect(x: 40, y: 60, width: 1400, height: 900), display: true)
        let before = window.frame
        let group = try XCTUnwrap(controller.workspaceView.descriptor(for: "native-terminal")?.group)

        // Browser panes — no daemon session behind them, so no PTY needed —
        // bring the grid from one pane to three, which is row two on this ladder.
        for id in ["extra-1", "extra-2"] {
            controller.workspaceView.addPane(
                PaneDescriptor(sessionID: id, group: group, kind: .browser, browserURL: "https://example.com")
            )
        }
        XCTAssertEqual(controller.workspaceView.grid?.rows, 2)
        XCTAssertEqual(window.frame, before, "growing into a second row left the window alone")

        for id in ["extra-1", "extra-2"] {
            controller.workspaceView.focusPane(id)
            controller.closePane(nil)
        }
        XCTAssertEqual(controller.workspaceView.grid?.rows, 1)
        XCTAssertEqual(window.frame, before, "and so did coming back to one")
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
        XCTAssertEqual(
            sidebar.action,
            #selector(WorkspaceWindowController.toggleWorkspaceSidebar(_:)),
            "not AppKit's toggleSidebar: — NSSplitViewController answers that one first"
        )
        XCTAssertEqual(sidebar.keyEquivalentModifierMask, [.command, .control])
    }

    /// The window draws its own bar: no `NSToolbar`, no system title row, and
    /// the three real window buttons hidden so the bar's own can stand where
    /// its layout puts them.
    func testTheWindowWearsItsOwnTitleBarAndNoSystemChrome() throws {
        let controller = makeController()
        defer { controller.close() }
        let window = try XCTUnwrap(controller.window)

        XCTAssertNil(window.toolbar, "the toolbar is gone, not restyled")
        XCTAssertEqual(window.titleVisibility, .hidden)
        XCTAssertTrue(window.titlebarAppearsTransparent)
        XCTAssertTrue(
            window.styleMask.contains(.fullSizeContentView),
            "the content starts at the top edge, so the drawn bar is the only bar"
        )
        // Still closable/minimizable/resizable — only the drawing goes.
        for behaviour in [NSWindow.StyleMask.closable, .miniaturizable, .resizable] {
            XCTAssertTrue(window.styleMask.contains(behaviour))
        }
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            XCTAssertEqual(window.standardWindowButton(button)?.isHidden, true)
        }
        XCTAssertNotNil(controller.titleBar.superview, "the bar is installed, not just built")
    }

    /// The bar names the session on screen, and names nothing anywhere else —
    /// no app name, no fallback. The review toggle goes with it: gone, not
    /// greyed out, since a disabled control invites a click that cannot work.
    func testTheBarNamesTheRunningSessionAndEmptiesOffTheDesk() throws {
        let controller = makeController()
        defer { controller.close() }
        controller.showWindow(nil)
        controller.applyDestination(.terminals)

        let session = controller.sessionTitleField.stringValue
        XCTAssertFalse(session.isEmpty, "a session is on screen, so the bar names it")
        XCTAssertNotEqual(session, "OmniAgent", "the app's name is not a session name")
        XCTAssertTrue(controller.titleBar.isReviewToggleVisible)

        controller.applyDestination(.home)

        XCTAssertEqual(controller.sessionTitleField.stringValue, "", "Home names no session")
        XCTAssertFalse(controller.titleBar.isReviewToggleVisible, "and offers nothing to review")

        controller.applyDestination(.terminals)
        XCTAssertEqual(controller.sessionTitleField.stringValue, session, "and it comes back on the way in")
        XCTAssertTrue(controller.titleBar.isReviewToggleVisible)
    }

    /// The session title label is a subview of the content column, so it is
    /// carried by the column's own collapse animation and cannot drift from it.
    func testTheSessionNameRidesTheContentColumnSoItCannotDriftFromIt() throws {
        let controller = makeController()
        defer { controller.close() }
        controller.showWindow(nil)

        let sessionLabel = controller.sessionTitleField
        let contentContainer = try XCTUnwrap(controller.workspaceView.superview)
        XCTAssertTrue(
            sessionLabel.isDescendant(of: contentContainer),
            "the session label is part of the content column, so it is carried by its animation"
        )

        // Riding the column has one sharp edge: collapse the sidebar and the
        // column reaches the window's left edge, which would draw the name
        // straight through the window buttons. It did, once.
        let window = try XCTUnwrap(controller.window)
        window.setFrame(NSRect(x: 0, y: 0, width: 1200, height: 600), display: true)
        let split = try XCTUnwrap(controller.splitController)
        split.view.layoutSubtreeIfNeeded()
        let openX = sessionLabel.convert(sessionLabel.bounds, to: nil).minX

        try XCTUnwrap(split.splitViewItems.first).isCollapsed = true
        split.view.layoutSubtreeIfNeeded()
        let collapsedX = sessionLabel.convert(sessionLabel.bounds, to: nil).minX

        XCTAssertLessThan(collapsedX, openX, "it does follow the column in")
        // The left-hand cluster only: `controlsForTesting` is in layout order,
        // so that is the three lights and the sidebar toggle. The review
        // toggle is the fifth and sits at the far right, where it is no
        // obstacle to a name growing rightwards.
        let buttonsEnd = controller.titleBar.controlsForTesting
            .prefix(4)
            .map { $0.convert($0.bounds, to: nil).maxX }
            .max() ?? 0
        XCTAssertGreaterThanOrEqual(
            collapsedX,
            buttonsEnd,
            "and still clears the window buttons rather than printing over them"
        )
    }

    /// The login is the app's front door: the workspace window does not open
    /// until the gate is answered, and the decision is made from `UserDefaults`
    /// rather than over the socket, so a slow daemon cannot delay it.
    func testTheWorkspaceWindowWaitsBehindTheLaunchGate() throws {
        let strangers = Set(NSApp.windows.map(ObjectIdentifier.init))
        addTeardownBlock {
            for window in NSApp.windows where !strangers.contains(ObjectIdentifier(window)) {
                window.close()
            }
        }

        let waiting = makeController()
        defer { waiting.close() }
        var revealed = false
        waiting.presentLaunchGate(defaults: try throwawayDefaults()) { revealed = true }
        XCTAssertFalse(revealed, "nothing signed in, so the workspace waits on the gate")
        XCTAssertFalse(try XCTUnwrap(waiting.window).isVisible, "and stays off screen while it does")

        let signedIn = try throwawayDefaults()
        signedIn.set(true, forKey: AuthGate.signedInDefaultsKey)
        let straightIn = makeController()
        defer { straightIn.close() }
        var openedImmediately = false
        straightIn.presentLaunchGate(defaults: signedIn) { openedImmediately = true }
        XCTAssertTrue(openedImmediately, "signed in already: nothing to ask, so the workspace opens")
    }

    /// A suite of its own, torn down after — never the real app's defaults,
    /// which is where the real launch decision lives.
    private func throwawayDefaults() throws -> UserDefaults {
        let name = "digital.bruno.omniagent.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        return defaults
    }

    /// The bar is a transparent overlay across the top of the split now, and
    /// the *topmost* subview of the window's container — so AppKit asks it
    /// first for every point in the window, not just for points in its own
    /// 38pt strip. Its `hitTest` answered `self` unconditionally, which was
    /// invisible while the bar was laid out above the split (the split was
    /// asked first) and fatal the moment it became the overlay: every click
    /// in the sidebar and the panes went to the bar and straight into
    /// `performDrag(with:)`. The whole window was a drag handle and nothing
    /// else answered a mouse at all.
    func testAClickBelowTheBarReachesTheSplitRatherThanTheOverlay() throws {
        let controller = makeController()
        defer { controller.close() }
        controller.showWindow(nil)
        let window = try XCTUnwrap(controller.window)
        window.setFrame(NSRect(x: 0, y: 0, width: 1200, height: 800), display: true)
        let content = try XCTUnwrap(window.contentView)
        content.layoutSubtreeIfNeeded()

        let bar = controller.titleBar
        let inTheContent = NSPoint(x: content.bounds.midX, y: content.bounds.midY)
        let hit = try XCTUnwrap(content.hitTest(inTheContent), "something must answer a click")
        XCTAssertFalse(
            hit.isDescendant(of: bar),
            "a click in the middle of the window belongs to what is drawn there, not to the bar"
        )

        // The other half of the contract, which is why the bar answers at all:
        // its own transparent background is the window drag.
        let inTheBar = NSPoint(
            x: content.bounds.midX,
            y: content.bounds.maxY - WorkspaceTitleBarView.height / 2
        )
        XCTAssertTrue(
            try XCTUnwrap(content.hitTest(inTheBar)).isDescendant(of: bar),
            "and the strip it does cover still drags the window"
        )
    }

    /// Hiding the real green button took full screen with it: the bar's own
    /// was wired to `zoom`, and these menus are hand-built, so AppKit never
    /// filled in an Enter Full Screen item to fall back on. Both routes are
    /// pinned here.
    func testFullScreenSurvivesTheWindowDrawingItsOwnButtons() throws {
        let controller = makeController()
        defer { controller.close() }
        let window = try XCTUnwrap(controller.window)

        XCTAssertTrue(
            window.collectionBehavior.contains(.fullScreenPrimary),
            "the window must actually be willing to go full screen"
        )

        ApplicationMenus.install()
        let item = try XCTUnwrap(
            NSApp.mainMenu?.item(withTitle: "View")?.submenu?.item(withTitle: "Toggle Full Screen")
        )
        XCTAssertNil(item.target, "it travels the responder chain to the window")
        XCTAssertEqual(item.action, #selector(NSWindow.toggleFullScreen(_:)))
        XCTAssertEqual(item.keyEquivalent, "f")
        XCTAssertEqual(item.keyEquivalentModifierMask, [.command, .control], "⌃⌘F")
    }

    /// The toggles have to reach *this* controller. They dispatch through the
    /// responder chain, where `NSSplitViewController` sits ahead of it — so
    /// the sidebar action must be a name the split does not answer, or the
    /// split swallows the press (it has no `.sidebar`-behavior item to act on).
    func testTheTitleBarButtonsTravelTheResponderChainPastTheSplit() throws {
        let controller = makeController()
        defer { controller.close() }

        let buttons = controller.titleBar.controlsForTesting.compactMap { $0 as? WorkspaceTitleBarButton }
        XCTAssertEqual(buttons.count, 2, "the sidebar and review toggles")
        XCTAssertEqual(
            buttons.map(\.action),
            [
                #selector(WorkspaceWindowController.toggleWorkspaceSidebar(_:)),
                #selector(WorkspaceWindowController.toggleReviewPanel(_:)),
            ]
        )
        XCTAssertFalse(
            controller.splitController?
                .responds(to: #selector(WorkspaceWindowController.toggleWorkspaceSidebar(_:))) ?? true,
            "NSSplitViewController must not answer this selector first"
        )
    }

    func testTheViewMenuCarriesToggleReviewPanelOnCmdOptB() throws {
        ApplicationMenus.install()
        let view = try XCTUnwrap(NSApp.mainMenu?.item(withTitle: "View")?.submenu)
        let item = try XCTUnwrap(view.item(withTitle: "Toggle Review Panel"))
        XCTAssertNil(item.target, "it travels the responder chain, like every other item")
        XCTAssertEqual(item.action, #selector(WorkspaceWindowController.toggleReviewPanel(_:)))
        XCTAssertEqual(item.keyEquivalent, "b")
        XCTAssertEqual(item.keyEquivalentModifierMask, [.command, .option], "⌥⌘B")
    }

    /// The panel exists now, so the chord and the button are live — but only
    /// with a session on screen, since the panel reviews that session. Both
    /// surfaces answer through the one shared enablement rule.
    func testToggleReviewPanelEnablesExactlyWhenASessionIsOnScreen() throws {
        let probe = NSMenuItem(
            title: "Toggle Review Panel",
            action: #selector(WorkspaceWindowController.toggleReviewPanel(_:)),
            keyEquivalent: ""
        )

        let empty = makeEmptyController()
        defer { empty.close() }
        XCTAssertFalse(empty.validateMenuItem(probe), "no session, nothing to review")

        let controller = makeController()
        defer { controller.close() }
        controller.applyDestination(.terminals)
        XCTAssertTrue(controller.validateMenuItem(probe))

        // The bar's own affordance answers to the same rule — and it answers
        // by being there at all rather than by greying out.
        XCTAssertTrue(controller.titleBar.isReviewToggleVisible)
        XCTAssertFalse(empty.titleBar.isReviewToggleVisible)
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

        let split = try XCTUnwrap(controller.splitController)
        let collapsed = split.splitViewItems[0].isCollapsed
        controller.run(.toggleSidebar)
        XCTAssertNotEqual(split.splitViewItems[0].isCollapsed, collapsed)
    }

    /// Dragging the sidebar divider has to hold. It did not: the split view
    /// carried an `autosaveName` while its `NSSplitViewController` was already
    /// restoring divider positions itself, and the autosaved subview frames
    /// were re-applied on the next layout pass, snapping the column back.
    func testDraggingTheSidebarDividerSticks() throws {
        let controller = makeEmptyController()
        defer { controller.close() }
        controller.showWindow(nil)
        let window = try XCTUnwrap(controller.window)
        window.setFrame(NSRect(x: 0, y: 0, width: 1400, height: 800), display: true)
        let split = try XCTUnwrap(controller.splitController)
        split.view.layoutSubtreeIfNeeded()

        split.splitView.setPosition(380, ofDividerAt: 0)
        // The snap-back happened on the *next* pass, not the drag itself, so
        // one more layout is the whole point of the test.
        split.view.needsLayout = true
        split.view.layoutSubtreeIfNeeded()

        XCTAssertEqual(
            split.splitViewItems[0].viewController.view.frame.width,
            380,
            accuracy: 1,
            "the dragged width has to survive the next layout"
        )
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
        XCTAssertTrue(controller.palette.model.commands.contains { $0.action == .focusPane(sessionID: "sess-a") })

        controller.palette.dismiss()
        controller.workspaceView.closePane("sess-a")
        controller.showCommandPalette(nil)

        XCTAssertFalse(
            controller.palette.model.commands.contains { $0.action == .focusPane(sessionID: "sess-a") },
            "a pane that closed while the palette was shut can never be offered"
        )
        controller.palette.dismiss()
    }

    // MARK: - Session outline

    func testTheOutlineFollowsThePanesAndTheFocusedOne() throws {
        UserDefaults.standard.removeObject(forKey: WorkspacesTreeView.collapsedDefaultsKey)
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
        let tree = controller.shellSidebar.workspacesTree
        XCTAssertEqual(tree.renderedWorkspaceIDs, ["alpha"])
        XCTAssertEqual(tree.renderedSessionIDs, ["g1"])

        controller.newTerminalPane(nil)

        XCTAssertEqual(tree.renderedSessionIDs, ["g1"], "the new pane joins the open session")
        XCTAssertEqual(controller.workspaceView.paneIDs.count, 2, "and exists, without a row of its own")
    }

    /// The redesign's selection seam: a session row in ANY workspace both
    /// selects that workspace and activates that session's panes.
    func testClickingASessionInAnotherWorkspaceSwitchesWorkspaceAndActivatesIt() throws {
        UserDefaults.standard.removeObject(forKey: WorkspacesTreeView.collapsedDefaultsKey)
        let controller = makeEmptyController()
        defer { controller.close() }
        controller.sessionEnsurer = { _ in }
        controller.showWindow(nil)
        controller.applyRestoredPanes(
            WorkspaceRestoration.plan(
                fromLayout: PersistedLayoutCodec.serialize([
                    PersistedTab(project: "alpha", engine: .shell, cwd: "/a", id: "sess-a", group: "g1"),
                    PersistedTab(project: "beta", engine: .shell, cwd: "/b", id: "sess-b", group: "g2"),
                ])
            )
        )
        // The restore focused beta's pane last, so beta is the open workspace.
        controller.selectWorkspace(id: "beta", animated: false)

        let tree = controller.shellSidebar.workspacesTree
        let row = try XCTUnwrap(
            tree.descendants.compactMap { $0 as? SessionRowView }
                .first { $0.session.project == "alpha" }
        )
        try XCTUnwrap(row.onPress)()

        XCTAssertEqual(controller.selectedProjectID, "alpha", "the workspace follows the session")
        // On the Desk the activation is a camera flight; pump until it lands.
        let landed = Date().addingTimeInterval(5)
        while controller.workspaceView.activeGroup != "g1", Date() < landed {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertEqual(controller.workspaceView.activeGroup, "g1", "and the session's panes are active")
        let highlighted = tree.descendants.compactMap { $0 as? SessionRowView }
            .filter(\.session.isCurrent)
        XCTAssertEqual(highlighted.map(\.session.id), ["g1"], "the current session row is the lit one")
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
        // On the Desk the workspace is in canvas mode, where `focusPane` flies
        // the camera to the session rather than swapping the grid out from
        // under it — so the answer arrives one camera flight later, at
        // `landSession`, instead of on this line. Pumped until it lands rather
        // than for a fixed 0.38s: the landing is a `DispatchQueue.main`
        // deadline, and a fixed wait that only just covers it fails whenever a
        // loaded machine runs the whole class instead of this one test.
        let landed = Date().addingTimeInterval(5)
        while controller.workspaceView.activeGroup != "grp-1", Date() < landed {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }

        XCTAssertEqual(controller.workspaceView.focusedPaneID, "sess-a")
        XCTAssertEqual(controller.workspaceView.activeGroup, "grp-1")
        XCTAssertNil(controller.lastFocusedPaneOnLaunch, "spent once, so a reconnect never re-steals focus")
    }

    func testThePaneHeaderRenameAndColorCallbacksAreWired() {
        let controller = makeController()

        XCTAssertNotNil(
            controller.workspaceView.onRequestRenamePane,
            "pencil button tapped and nobody answered"
        )
        XCTAssertNotNil(
            controller.workspaceView.onRequestColorMenu,
            "color badge tapped and nobody answered"
        )
    }

    func testTheColorMenuIsClaudeOnlyAndHasAllColors() {
        let controller = makeController()
        let menu = controller.claudeColorMenu()
        XCTAssertEqual(
            menu.items.map(\.title),
            ["Red", "Blue", "Green", "Yellow", "Purple", "Orange", "Pink", "Cyan", "Default"],
            "/color takes these names and rejects everything else, hex included"
        )
        XCTAssertEqual(
            menu.items.map { $0.representedObject as? String },
            WorkspaceWindowController.claudeColors,
            "the lowercase name is what gets typed at the terminal"
        )
        XCTAssertTrue(
            menu.items.allSatisfy { $0.image != nil },
            "the swatch is what makes a list of colour words pickable at a glance"
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


    /// The real prompt — no test seam — is a pane ask on the pane being
    /// renamed, seeded with the current name, and typing into it renames both
    /// halves. A sheet on the window could not say which of twelve panes it
    /// meant.
    func testRenamingAsksOnThePaneItself() throws {
        let controller = makeController()
        defer { controller.close() }
        controller.showWindow(nil)
        controller.applyRestoredPanes(
            WorkspaceRestoration.plan(
                fromLayout: PersistedLayoutCodec.serialize([
                    PersistedTab(project: "alpha", engine: .claude, cwd: "/a", id: "sess-cl", group: "grp-1"),
                ])
            )
        )
        controller.workspaceView.focusPane("sess-cl")
        controller.workspaceView.updateDescriptor(for: "sess-cl") { $0.label = "Ingest" }

        controller.renameConversation(nil)

        let container = try XCTUnwrap(controller.workspaceView.container(for: "sess-cl"))
        let card = try XCTUnwrap(container.askOverlay)
        XCTAssertEqual(card.text, "Ingest", "the field opens on the name being changed")
        XCTAssertEqual(card.options.map(\.title), ["Cancel", "Rename"])

        card.type("Ingest rewrite")
        card.choose(1)
        XCTAssertNil(container.askOverlay)
        XCTAssertEqual(controller.workspaceView.descriptor(for: "sess-cl")?.label, "Ingest rewrite")
    }

    /// Cancelling changes nothing — and an ask answered once may not also
    /// report a cancel, or every caller settles its decision twice.
    func testCancellingTheRenameLeavesTheNameAlone() throws {
        let controller = makeController()
        defer { controller.close() }
        controller.showWindow(nil)
        controller.applyRestoredPanes(
            WorkspaceRestoration.plan(
                fromLayout: PersistedLayoutCodec.serialize([
                    PersistedTab(project: "alpha", engine: .claude, cwd: "/a", id: "sess-cl", group: "grp-1"),
                ])
            )
        )
        controller.workspaceView.focusPane("sess-cl")
        controller.workspaceView.updateDescriptor(for: "sess-cl") { $0.label = "Ingest" }

        controller.renameConversation(nil)
        let container = try XCTUnwrap(controller.workspaceView.container(for: "sess-cl"))
        let card = try XCTUnwrap(container.askOverlay)
        card.type("something else")
        card.onCancel?()

        XCTAssertNil(container.askOverlay)
        XCTAssertEqual(controller.workspaceView.descriptor(for: "sess-cl")?.label, "Ingest")
    }

    /// Closing a terminal that has been typed into kills a conversation, so it
    /// asks first — on the pane it is about — and changes nothing until the
    /// card is answered. Same rule the engine switch follows.
    func testClosingATypedTerminalAsksOnThePaneFirst() throws {
        let controller = makeController()
        defer { controller.close() }
        controller.showWindow(nil)
        controller.sessionKiller = { _ in }
        controller.sessionEnsurer = { _ in }
        let workspace = controller.workspaceView
        let paneID = try XCTUnwrap(workspace.paneIDs.first)
        let surface = try XCTUnwrap(workspace.terminalSurface(for: paneID))
        surface.send(source: surface.terminalView, data: ArraySlice([UInt8(0x68)]))
        workspace.focusPane(paneID)

        controller.closePane(nil)

        let container = try XCTUnwrap(workspace.container(for: paneID))
        let card = try XCTUnwrap(container.askOverlay)
        XCTAssertEqual(card.options.map(\.title), ["Keep", "Close Terminal"])
        XCTAssertNotNil(workspace.descriptor(for: paneID), "nothing has happened yet")

        // Keep leaves the terminal exactly as it was.
        card.choose(0)
        XCTAssertNil(container.askOverlay)
        XCTAssertNotNil(workspace.descriptor(for: paneID))

        controller.closePane(nil)
        try XCTUnwrap(container.askOverlay).choose(1)
        XCTAssertNil(workspace.descriptor(for: paneID), "and Close is the path that ends it")
    }

    /// A terminal nobody has typed in has nothing to lose and closes on the
    /// spot — a confirmation on every ⌘W would be a tax, not a safeguard.
    func testClosingAnUntypedTerminalDoesNotAsk() throws {
        let controller = makeController()
        defer { controller.close() }
        controller.showWindow(nil)
        controller.sessionKiller = { _ in }
        controller.sessionEnsurer = { _ in }
        let workspace = controller.workspaceView
        let paneID = try XCTUnwrap(workspace.paneIDs.first)
        workspace.focusPane(paneID)

        controller.closePane(nil)

        XCTAssertNil(workspace.descriptor(for: paneID))
    }

    /// Both halves of "the pane and the conversation are called the same
    /// thing": the agent's reported title is typed back at it as a `/rename`,
    /// and a `/clear` — a new conversation — puts the name back to the
    /// numbered placeholder.
    func testTheConversationNameFollowsTheReportedTitleAndResetsOnClear() throws {
        let controller = makeController()
        controller.applyRestoredPanes(
            WorkspaceRestoration.plan(
                fromLayout: PersistedLayoutCodec.serialize([
                    PersistedTab(project: "alpha", engine: .claude, cwd: "/a", id: "sess-cl", group: "grp-1"),
                ])
            )
        )
        let workspace = controller.workspaceView
        let surface = try XCTUnwrap(workspace.terminalSurface(for: "sess-cl"))

        surface.setTerminalTitle(source: surface.terminalView, title: "\u{2733} Ingest rewrite")
        XCTAssertEqual(workspace.descriptor(for: "sess-cl")?.title, "Ingest rewrite")
        XCTAssertEqual(
            controller.lastSyncedName["sess-cl"],
            "Ingest rewrite",
            "the engine has to be told the name the sidebar is showing"
        )

        surface.send(source: surface.terminalView, data: ArraySlice(Array("/clear\r".utf8)))
        let descriptor = try XCTUnwrap(workspace.descriptor(for: "sess-cl"))
        XCTAssertEqual(descriptor.title, "")
        XCTAssertNil(descriptor.label)
        XCTAssertNil(controller.lastSyncedName["sess-cl"])
        XCTAssertEqual(SessionOutline.paneLabel(descriptor), "Claude 1")

        // A name the user typed is the agreed one already — the agent is not
        // told to overwrite it with whatever it happens to be reporting.
        workspace.updateDescriptor(for: "sess-cl") { $0.label = "Ingest" }
        surface.setTerminalTitle(source: surface.terminalView, title: "Something else")
        XCTAssertNil(controller.lastSyncedName["sess-cl"])
    }

    /// Collapsing the sidebar used to leave a strip of bare window background
    /// where the column had been — a black band, the same at every window
    /// width. AppKit pins its own split view inside the split view
    /// controller's view at priority 749, and the sizing chain a collapsed
    /// item leaves behind outranks it: the split gave up 109pt and hugged the
    /// trailing edge. Nothing paints there, so the window's own ground showed.
    func testCollapsingTheSidebarLeavesNoBandOfBareWindowBehindIt() throws {
        let controller = makeController()
        defer { controller.close() }
        controller.showWindow(nil)
        let window = try XCTUnwrap(controller.window)
        window.setFrame(NSRect(x: 0, y: 0, width: 1400, height: 900), display: true)
        let content = try XCTUnwrap(window.contentView)
        let split = try XCTUnwrap(controller.splitController)
        content.layoutSubtreeIfNeeded()

        try XCTUnwrap(split.splitViewItems.first).isCollapsed = true
        content.layoutSubtreeIfNeeded()

        let filled = split.splitView.convert(split.splitView.bounds, to: content)
        XCTAssertEqual(filled, content.bounds, "the split fills the window with the column gone")
        let column = try XCTUnwrap(controller.workspaceView.superview)
        XCTAssertEqual(
            column.convert(column.bounds, to: content).minX,
            0,
            accuracy: 0.5,
            "and the content reaches the window's left edge, with nothing bare beside it"
        )
    }

    /// The window is the user's: adding panes must not resize it, and the
    /// review panel must not squeeze the pane column below one comfortable
    /// terminal (Bruno, 2026-08-21 — terminals wrapping at six characters
    /// beside an expanded panel).
    func testTheWindowKeepsItsSizeAndThePaneColumnKeepsItsMinimumWidth() throws {
        let controller = makeController()
        defer { controller.close() }
        controller.showWindow(nil)
        let window = try XCTUnwrap(controller.window)
        window.setFrame(NSRect(x: 0, y: 0, width: 1400, height: 900), display: true)
        window.layoutIfNeeded()
        let before = window.frame

        // Two panes, then three — the row count crosses 1 -> 2 here.
        controller.newTerminalPane(nil)
        controller.newTerminalPane(nil)
        window.layoutIfNeeded()
        XCTAssertEqual(controller.workspaceView.paneIDs.count, 3)
        XCTAssertEqual(window.frame, before, "adding a pane never resizes the window")

        controller.toggleReviewPanel(nil)
        controller.reviewPanel.onToggleExpand?()
        window.layoutIfNeeded()
        XCTAssertEqual(window.frame, before, "opening and expanding the panel never resizes the window")
        XCTAssertGreaterThanOrEqual(
            controller.workspaceView.frame.width,
            PaneWorkspaceView.minimumPaneAreaWidth,
            "the panel may not squeeze the pane column below one comfortable terminal"
        )

        // And at the narrowest the window is allowed to be, where the three
        // columns' floors cannot all be paid: still no window resize — the
        // pane column simply keeps what it is owed.
        window.setFrame(NSRect(origin: before.origin, size: window.minSize), display: true)
        window.layoutIfNeeded()
        let narrow = window.frame
        controller.reviewPanel.onToggleExpand?()
        controller.reviewPanel.onToggleExpand?()
        window.layoutIfNeeded()
        XCTAssertEqual(window.frame, narrow, "a squeezed window is never grown to fit the panel")
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

    /// ⌥-as-Meta is standard behaviour here and has no toggle. SwiftTerm's
    /// built-in ⌘⌥O would still turn it off from inside `keyDown`, so the
    /// keystroke is swallowed in `performKeyEquivalent` before it lands.
    func testCommandOptionODoesNotTurnOffOptionAsMeta() throws {
        ApplicationMenus.install()
        XCTAssertNil(
            NSApp.mainMenu?.item(withTitle: "Session")?.submenu?
                .item(withTitle: "Use Option as Meta"),
            "the toggle is gone from the menu"
        )
        let (surface, window) = makeAttachedSurface()
        defer { window.close() }
        let delegate = RecordingTerminalDelegate()
        surface.terminalView.terminalDelegate = delegate
        surface.terminalView.feed(byteArray: Array("\u{1b}[>1u".utf8)[...])
        XCTAssertFalse(surface.terminalView.terminal.keyboardEnhancementFlags.isEmpty)
        let modalSession = NSApp.beginModalSession(for: window)
        defer { NSApp.endModalSession(modalSession) }
        _ = NSApp.runModalSession(modalSession)
        window.makeKeyAndOrderFront(nil)
        XCTAssertTrue(window.makeFirstResponder(surface.terminalView))
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
        XCTAssertFalse(try XCTUnwrap(NSApp.mainMenu).performKeyEquivalent(with: event))
        XCTAssertTrue(window.performKeyEquivalent(with: event), "swallowed by the terminal view")

        XCTAssertTrue(surface.terminalView.optionAsMetaKey, "still Meta")
        XCTAssertTrue(delegate.bytes.isEmpty)
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
