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
        XCTAssertEqual(added.cwd, "/a")
        XCTAssertEqual(added.engine, .shell, "the native build can only launch a shell today")
    }

    // MARK: - Command palette and toolbar

    func testTheCommandPaletteAndSidebarToggleAreOnTheMenuAndTravelTheResponderChain() throws {
        ApplicationMenus.install()
        let palette = try XCTUnwrap(NSApp.mainMenu?.item(withTitle: "File")?.submenu?.item(withTitle: "Command Palette"))
        XCTAssertNil(palette.target)
        XCTAssertEqual(palette.action, #selector(WorkspaceWindowController.showCommandPalette(_:)))
        XCTAssertEqual(palette.keyEquivalent, "k")
        XCTAssertEqual(palette.keyEquivalentModifierMask, [.command])

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
        XCTAssertEqual(controller.outline.outlineView.numberOfRows, 3, "project, session, pane")

        controller.newTerminalPane(nil)

        XCTAssertEqual(controller.outline.outlineView.numberOfRows, 4, "the new pane appears in its session")
        let focused = try XCTUnwrap(controller.workspaceView.focusedPaneID)
        XCTAssertEqual(
            controller.outline.outlineView.selectedRow,
            controller.outline.outlineView.row(forItem: SessionOutlineView.OutlineItem.pane(focused))
        )
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
