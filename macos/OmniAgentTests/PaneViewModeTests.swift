import AppKit
import XCTest

@testable import OmniAgent

/// The App view wired into a pane: the header's Terminal ⇄ App switch, which
/// of the two content views is on screen, and what the swap does to the
/// terminal behind it — which is nothing at all. The PTY is the base either
/// way; only `destroyPane` ever ends a session.
final class PaneViewModeTests: XCTestCase {
    // MARK: - Swapping the two views

    /// `.app` shows the chat and puts the terminal down; `.terminal` puts it
    /// back. One writer, `applyContentVisibility`, decides both.
    func testTogglingSwapsWhichContentViewIsOnScreen() throws {
        let workspace = makeWorkspace()
        let container = try XCTUnwrap(workspace.container(for: "pane-1"))
        XCTAssertFalse(container.surface.isHidden)
        XCTAssertNil(container.appView, "a pane opens in Terminal view and builds nothing else")

        container.viewMode = .app
        let appView = try XCTUnwrap(container.appView)
        XCTAssertTrue(container.surface.isHidden)
        XCTAssertFalse(appView.isHidden)

        container.viewMode = .terminal
        XCTAssertFalse(container.surface.isHidden)
        XCTAssertTrue(appView.isHidden)
    }

    /// The App view takes the terminal's box exactly, so the swap is a change
    /// of what fills the pane and not of how much of it is filled.
    func testTheAppViewTakesTheSurfacesFrame() throws {
        let workspace = makeWorkspace()
        let container = try XCTUnwrap(workspace.container(for: "pane-1"))
        container.viewMode = .app
        let appView = try XCTUnwrap(container.appView)
        XCTAssertEqual(appView.frame, container.surface.frame)
        XCTAssertGreaterThan(appView.frame.height, 0, "and it is a real box, not a collapsed one")
    }

    /// The point of the whole feature: App mode hides the terminal, it never
    /// ends it. The same surface object comes back, still in the pane, still
    /// framed where it was — so the scrollback, the Metal setup and the daemon
    /// attachment are all untouched and the PTY never reflowed.
    func testTheTerminalSurvivesARoundTripThroughTheAppView() throws {
        let workspace = makeWorkspace()
        let container = try XCTUnwrap(workspace.container(for: "pane-1"))
        let surface = container.surface
        let identity = ObjectIdentifier(surface)
        let frame = surface.frame

        container.viewMode = .app
        XCTAssertEqual(surface.frame, frame, "hidden, and holding its geometry: no reflow to answer")
        container.viewMode = .terminal

        XCTAssertEqual(ObjectIdentifier(container.surface), identity)
        XCTAssertIdentical(container.surface.superview, container)
        XCTAssertEqual(container.surface.frame, frame)
        XCTAssertNotNil(workspace.terminalSurface(for: "pane-1"))
    }

    // MARK: - The chip

    /// The chip replaces the pane whole, so it outranks the view mode: both
    /// content views go down for it, and the one that comes back up is the one
    /// the pane was showing — never the terminal by default.
    func testTheChipHidesBothContentViewsAndComesBackToTheModeItLeft() throws {
        let workspace = makeWorkspace()
        let container = try XCTUnwrap(workspace.container(for: "pane-1"))
        container.viewMode = .app
        let appView = try XCTUnwrap(container.appView)

        container.isChipped = true
        XCTAssertTrue(container.surface.isHidden)
        XCTAssertTrue(appView.isHidden)
        XCTAssertFalse(appView.isLive, "and a pane drawn as a placeholder polls nothing")

        container.isChipped = false
        XCTAssertTrue(container.surface.isHidden, "the terminal is not resurrected by the chip going down")
        XCTAssertFalse(appView.isHidden)
        XCTAssertTrue(appView.isLive)
    }

    // MARK: - Polling

    /// `isLive` is the poll timer's switch, so it has to track whether anyone
    /// can see the view — driven here through the workspace's own visibility
    /// pass, which is what a session switch actually runs.
    func testIsLiveFollowsWhetherThePaneIsOnScreen() throws {
        let workspace = makeWorkspace()
        XCTAssertTrue(workspace.addPane(makeDescriptor("pane-2", group: "sess-grp-2")))
        workspace.focusPane("pane-1")
        let container = try XCTUnwrap(workspace.container(for: "pane-1"))
        container.viewMode = .app
        let appView = try XCTUnwrap(container.appView)
        XCTAssertTrue(appView.isLive, "on screen, unchipped and in App view")

        workspace.focusPane("pane-2")
        XCTAssertTrue(container.isHidden, "another session is on screen")
        XCTAssertFalse(appView.isLive)

        workspace.focusPane("pane-1")
        XCTAssertTrue(appView.isLive)

        container.viewMode = .terminal
        XCTAssertFalse(appView.isLive, "and nothing polls behind the terminal either")
    }

    // MARK: - Lazily built

    /// Most panes are shells, browsers and editors that will never ask for a
    /// chat view, so none of them pays for one — and the pane that does asks
    /// once.
    func testTheAppViewIsBuiltOnDemandAndOnlyOnce() throws {
        let workspace = makeWorkspace()
        XCTAssertTrue(workspace.addPane(makeDescriptor("pane-browser", kind: .browser)))
        XCTAssertTrue(workspace.addPane(makeDescriptor("pane-editor", kind: .editor)))
        for id in ["pane-1", "pane-browser", "pane-editor"] {
            XCTAssertNil(workspace.container(for: id)?.appView, "\(id) never asked for one")
        }

        let container = try XCTUnwrap(workspace.container(for: "pane-1"))
        container.viewMode = .app
        let first = try XCTUnwrap(container.appView)
        container.viewMode = .terminal
        container.viewMode = .app
        XCTAssertIdentical(container.appView, first, "kept for the pane's life, not rebuilt per switch")
    }

    /// The composer's only job is to reach the PTY, and Task 3 is what hands
    /// it the door.
    func testTheComposerIsWiredOnTheFirstSwitch() throws {
        let workspace = makeWorkspace()
        let container = try XCTUnwrap(workspace.container(for: "pane-1"))
        container.viewMode = .app
        XCTAssertNotNil(try XCTUnwrap(container.appView).onSubmit)
    }

    // MARK: - Gating

    /// Only Claude writes the transcript the App view renders, so it is the
    /// only engine with a second view to offer.
    func testTheSwitchIsOfferedToClaudeTerminalsOnly() throws {
        let workspace = makeWorkspace()
        XCTAssertTrue(workspace.addPane(makeDescriptor("pane-shell", engine: .shell)))
        XCTAssertTrue(workspace.addPane(makeDescriptor("pane-browser", kind: .browser)))
        XCTAssertTrue(workspace.addPane(makeDescriptor("pane-editor", kind: .editor)))

        XCTAssertTrue(try XCTUnwrap(workspace.container(for: "pane-1")).header.isViewToggleAvailable)
        for id in ["pane-shell", "pane-browser", "pane-editor"] {
            let container = try XCTUnwrap(workspace.container(for: id))
            XCTAssertFalse(container.header.isViewToggleAvailable, "\(id) has no transcript to render")
        }
    }

    /// An engine changed out from under an App-mode pane leaves a conversation
    /// nothing will ever append to — and takes the control that gets the user
    /// back to the terminal with it. So the pane goes back on its own.
    func testChangingTheEngineAwayFromClaudeReturnsThePaneToItsTerminal() throws {
        let workspace = makeWorkspace()
        let container = try XCTUnwrap(workspace.container(for: "pane-1"))
        container.viewMode = .app
        let appView = try XCTUnwrap(container.appView)

        workspace.updateDescriptor(for: "pane-1") { $0.engine = .codex }

        XCTAssertEqual(container.viewMode, .terminal)
        XCTAssertFalse(container.header.isViewToggleAvailable)
        XCTAssertFalse(container.surface.isHidden)
        XCTAssertTrue(appView.isHidden)
        XCTAssertFalse(appView.isLive)
    }

    // MARK: - The header

    /// The switch is placed outside the badge loop on purpose: badges drop out
    /// of a narrow pane by design, and the one control that gets the user back
    /// to their terminal must not go with them.
    func testTheHeaderKeepsTheSwitchWhenTheBadgesDrop() throws {
        let header = PaneHeaderView(title: "a pane with a name long enough to compete")
        header.engine = .claude
        header.model = "sonnet"
        header.claudeColor = "blue"
        header.isViewToggleAvailable = true

        layOut(header, width: 900)
        let toggle = try XCTUnwrap(header.subviews.compactMap { $0 as? PaneViewToggleView }.first)
        let badges = header.subviews.compactMap { $0 as? PaneBadgeView }.filter { !$0.isHidden }
        XCTAssertFalse(badges.isEmpty, "a Claude pane wears the engine, model and colour badges")
        XCTAssertEqual(toggle.frame.size, toggle.intrinsicContentSize)
        XCTAssertTrue(
            badges.allSatisfy { $0.frame.maxX <= toggle.frame.minX },
            "and it sits to the right of them, between the badges and the cluster"
        )
        let discs = header.subviews.compactMap { $0 as? PaneHeaderButton }
        XCTAssertEqual(discs.count, 3)
        let cluster = try XCTUnwrap(discs.map(\.frame.minX).min())
        XCTAssertLessThan(toggle.frame.maxX, cluster, "and to the left of the traffic-light cluster")

        layOut(header, width: 260)
        XCTAssertTrue(badges.allSatisfy { $0.frame == .zero }, "the badges drop whole")
        XCTAssertEqual(toggle.frame.size, toggle.intrinsicContentSize, "the switch does not")
        XCTAssertGreaterThanOrEqual(toggle.frame.minX, 0)
        // The bar still reads as a bar: the pane's mark, its name and all three
        // discs are placed.
        let mark = try XCTUnwrap(header.subviews.compactMap { $0 as? PaneStatusMarkView }.first)
        XCTAssertGreaterThan(mark.frame.width, 0)
        let title = try XCTUnwrap(header.subviews.compactMap { $0 as? NSTextField }.first)
        XCTAssertGreaterThan(title.frame.width, 0)
        XCTAssertTrue(discs.allSatisfy { $0.frame.width > 0 })
    }

    /// A hidden switch reserves nothing: a shell pane's badges sit exactly
    /// where they sat before the control existed.
    func testAnUnavailableSwitchTakesNoRoomFromTheBadges() throws {
        let withToggle = PaneHeaderView(title: "pane")
        let without = PaneHeaderView(title: "pane")
        for header in [withToggle, without] {
            header.engine = .claude
            header.model = "sonnet"
            layOut(header, width: 900)
        }
        withToggle.isViewToggleAvailable = true
        layOut(withToggle, width: 900)

        let shifted = try XCTUnwrap(withToggle.subviews.compactMap { $0 as? PaneBadgeView }.first { !$0.isHidden })
        let unshifted = try XCTUnwrap(without.subviews.compactMap { $0 as? PaneBadgeView }.first { !$0.isHidden })
        XCTAssertLessThan(shifted.frame.minX, unshifted.frame.minX, "the switch pushes the badges left")

        withToggle.isViewToggleAvailable = false
        layOut(withToggle, width: 900)
        XCTAssertEqual(shifted.frame, unshifted.frame, "and gives the room straight back")
    }

    /// Pressing a segment is the whole user-facing path: the control reports,
    /// the pane switches, and the control is told what the pane did rather than
    /// lighting itself.
    func testPressingTheAppSegmentSwitchesThePane() throws {
        let workspace = makeWorkspace()
        let container = try XCTUnwrap(workspace.container(for: "pane-1"))
        let toggle = try XCTUnwrap(container.header.subviews.compactMap { $0 as? PaneViewToggleView }.first)
        XCTAssertFalse(toggle.isHidden, "a Claude terminal wears the switch")

        let appSegment = try XCTUnwrap(toggle.subviews.first { $0.accessibilityLabel() == "App view" })
        XCTAssertEqual(appSegment.accessibilityRole(), .button)
        XCTAssertTrue(appSegment.accessibilityPerformPress())

        XCTAssertEqual(container.viewMode, .app)
        XCTAssertEqual(toggle.mode, .app)
        XCTAssertTrue(container.surface.isHidden)

        let terminalSegment = try XCTUnwrap(toggle.subviews.first { $0.accessibilityLabel() == "Terminal view" })
        XCTAssertTrue(terminalSegment.accessibilityPerformPress())
        XCTAssertEqual(container.viewMode, .terminal)
        XCTAssertEqual(toggle.mode, .terminal)
        XCTAssertFalse(container.surface.isHidden)
    }

    // MARK: - Helpers

    /// A workspace holding one Claude terminal pane, built the way the
    /// production factory builds one — real surfaces over a `SessionConnection`
    /// pointed at a socket nothing is listening on, which is fine because
    /// nothing here connects.
    private func makeWorkspace(width: CGFloat = 1200) -> PaneWorkspaceView {
        let connection = SessionConnection(
            socketURL: URL(fileURLWithPath: "/tmp/omniagent-pane-view-mode-test.sock")
        )
        let workspace = PaneWorkspaceView { descriptor in
            switch descriptor.kind {
            case .terminal:
                return TerminalSurfaceView(connection: connection, sessionID: descriptor.sessionID)
            case .browser:
                return BrowserPaneView(initialURL: descriptor.browserURL)
            case .editor:
                return EditorPaneView(
                    initialTabs: descriptor.editorTabs,
                    activeIndex: descriptor.editorActiveIndex
                )
            }
        }
        workspace.frame = CGRect(x: 0, y: 0, width: width, height: 800)
        XCTAssertTrue(workspace.addPane(makeDescriptor("pane-1")))
        return workspace
    }

    private func makeDescriptor(
        _ id: String,
        group: String = "sess-grp-1",
        engine: Engine = .claude,
        kind: PaneKind = .terminal
    ) -> PaneDescriptor {
        PaneDescriptor(
            sessionID: id,
            group: group,
            groupLabel: nil,
            title: "",
            engine: engine,
            // A directory with no `~/.claude` transcript under it, so a poll
            // that does slip through finds nothing and reads no file.
            cwd: "/tmp/omniagent-pane-view-mode-tests",
            kind: kind
        )
    }

    /// A header laid out at a given width, on its own — `PaneWorkspaceViewTests`
    /// own helper: in the app its pane sets the frame and AppKit runs the pass.
    private func layOut(_ header: PaneHeaderView, width: CGFloat) {
        header.frame = CGRect(x: 0, y: 0, width: width, height: header.currentHeight)
        header.needsLayout = true
        header.layoutSubtreeIfNeeded()
    }
}
