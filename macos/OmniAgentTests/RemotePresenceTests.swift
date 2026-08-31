import AppKit
import XCTest

@testable import OmniAgent

/// Viewer presence on the *host* — the phase 2 spec's §5 "Presence, and
/// disconnecting a viewer"
/// (docs/superpowers/specs/2026-08-31-remote-session-control-phase-2-design.md).
///
/// Bruno's finding was that a live remote connection left no trace on the
/// machine being watched: no count, nothing on the pane, and no way to end
/// it. Everything under this is already landed — the daemon keeps the
/// registry, pushes `RemoteViewers` and answers `DisconnectViewer` — so what
/// these tests pin is the last mile: the roster becoming a number beside the
/// globe, a machine name under the pane's card, a kick that reaches the
/// daemon, and the one thing the app owes the daemon in return — clearing
/// `remote_control_blocked` when sharing is switched back on, without which
/// a kick is permanent.
final class RemotePresenceTests: XCTestCase {
    // MARK: - The three the plan named

    /// The badge counts *machines*, not attachments: two Macs watching the
    /// same pane are two, and the pane's own line names both.
    func testTheWorkspaceBadgeCountsMachinesWatchingThatWorkspace() {
        let controller = makeController(panes: [pane("s1", project: "/a", group: "g1")])
        controller.applyRemoteViewers([
            .init(viewerID: "v1", machineName: "Air", sessions: ["s1"], since: "2026-08-31T10:00:00Z"),
            .init(viewerID: "v2", machineName: "MBP", sessions: ["s1"], since: "2026-08-31T10:01:00Z")])
        XCTAssertEqual(controller.remoteViewerCount(forWorkspace: "/a"), 2)
        XCTAssertEqual(controller.remoteViewerNames(forPane: "s1"), ["Air", "MBP"])
    }

    /// The daemon only ever *adds* to `remote_control_blocked` — it is the
    /// enforcer, and the kick has to hold with the app closed. Clearing it is
    /// the app's half of that contract, and the deliberate act the spec picks
    /// is turning Remote Control on.
    func testEnablingRemoteControlClearsTheBlocklist() {
        let controller = makeController(panes: [pane("s1", project: "/a", group: "g1")])
        controller.toggleRemoteControl(workspaceID: "/a")      // on
        XCTAssertEqual(controller.lastWrittenSetting(SettingsKey.remoteControlBlocked), "[]",
                       "turning sharing back on is how a kicked Mac is forgiven")
    }

    /// Disconnect reaches the daemon with the viewer id, and the machine
    /// leaves the roster on the spot rather than lingering until the next
    /// push.
    func testDisconnectSendsTheViewerIdAndDropsItFromTheRoster() {
        let controller = makeController(panes: [pane("s1", project: "/a", group: "g1")])
        controller.applyRemoteViewers([.init(viewerID: "v1", machineName: "Air", sessions: ["s1"], since: "…")])
        controller.disconnectViewer("v1")
        XCTAssertEqual(controller.connectionDouble.disconnectedViewerIDs, ["v1"])
        XCTAssertEqual(controller.remoteViewerNames(forPane: "s1"), [])
    }

    /// The removal is optimistic, so the daemon refusing the kick has to undo
    /// it. Anything else is the one wrong answer a security surface must
    /// never give: the window saying nobody is watching while the other Mac
    /// still is.
    func testADisconnectTheDaemonRefusesPutsTheMachineBackOnTheRoster() {
        let controller = makeController(panes: [pane("s1", project: "/a", group: "g1")])
        let air = RemoteViewer(viewerID: "v1", machineName: "Air", sessions: ["s1"], since: "…")
        controller.applyRemoteViewers([air])
        // The kick fails, and the daemon — asked again — still has the Air.
        controller.connectionDouble.disconnectResult = .failure(
            NSError(domain: "test", code: 1)
        )
        controller.connectionDouble.rosterFromDaemon = [air]

        controller.disconnectViewer("v1")

        XCTAssertEqual(controller.connectionDouble.listViewerCalls, 1,
                       "a failed kick must re-read the roster rather than trust its guess")
        XCTAssertEqual(controller.remoteViewerNames(forPane: "s1"), ["Air"],
                       "the machine is still watching, so it is still listed")
    }

    // MARK: - The rest of the surface

    /// A viewer attached to another workspace's pane is not this workspace's
    /// business, and a pane id nothing on this Mac owns counts for nobody —
    /// the roster is the daemon's, and it can name panes this window has
    /// already closed.
    func testTheBadgeCountsOnlyMachinesInsideThatWorkspace() {
        let controller = makeController(panes: [
            pane("s1", project: "/a", group: "g1"),
            pane("s2", project: "/b", group: "g2"),
        ])
        controller.applyRemoteViewers([
            .init(viewerID: "v1", machineName: "Air", sessions: ["s1"], since: "…"),
            .init(viewerID: "v2", machineName: "MBP", sessions: ["s2"], since: "…"),
            .init(viewerID: "v3", machineName: "Ghost", sessions: ["gone"], since: "…"),
        ])
        XCTAssertEqual(controller.remoteViewerCount(forWorkspace: "/a"), 1)
        XCTAssertEqual(controller.remoteViewerNames(forWorkspace: "/a"), ["Air"])
        XCTAssertEqual(controller.remoteViewerCount(forWorkspace: "/b"), 1)
        XCTAssertEqual(controller.remoteViewerCount(forWorkspace: "/c"), 0)
        XCTAssertEqual(controller.remoteViewerNames(forPane: "s2"), ["MBP"])
        XCTAssertTrue(controller.remoteViewerNames(forPane: "s1").contains("Air"))
    }

    /// The row wears the count only while someone is watching, and the
    /// tooltip is where the machines are named — a number alone answers "how
    /// many", never "who".
    func testTheWorkspaceRowWearsTheCountOnlyWhileSomeoneIsWatching() throws {
        let controller = makeController(panes: [pane("s1", project: "/a", group: "g1")])
        controller.toggleRemoteControl(workspaceID: "/a")
        let row = try XCTUnwrap(firstWorkspaceRow(in: controller.shellSidebar.workspacesTree))
        XCTAssertTrue(row.viewerBadge.isHidden, "nobody watching, no badge")

        controller.applyRemoteViewers([
            .init(viewerID: "v1", machineName: "Air", sessions: ["s1"], since: "…"),
            .init(viewerID: "v2", machineName: "MBP", sessions: ["s1"], since: "…"),
        ])
        let watched = try XCTUnwrap(firstWorkspaceRow(in: controller.shellSidebar.workspacesTree))
        XCTAssertFalse(watched.viewerBadge.isHidden)
        XCTAssertEqual(watched.viewerBadge.countText, "2")
        XCTAssertEqual(watched.viewerBadge.toolTip, "Watched by Air, MBP")
    }

    /// Clicking the count is how the popover opens — the row itself only
    /// folds, so the badge has to take the click rather than the row, and the
    /// press has to travel tree → sidebar → controller like every other row
    /// action.
    func testClickingTheCountAsksForTheViewerList() throws {
        let controller = makeController(panes: [pane("s1", project: "/a", group: "g1")])
        controller.toggleRemoteControl(workspaceID: "/a")
        controller.applyRemoteViewers([
            .init(viewerID: "v1", machineName: "Air", sessions: ["s1"], since: "…"),
        ])
        // Replaces the controller's own handler, which would put a real
        // popover on screen.
        var asked: [String] = []
        controller.shellSidebar.onShowViewers = { asked.append($0) }
        let row = try XCTUnwrap(firstWorkspaceRow(in: controller.shellSidebar.workspacesTree))
        row.viewerBadge.onPress?()
        XCTAssertEqual(asked, ["/a"])
    }

    /// The pane's own card says which machine is on it, so it is obvious
    /// *which* of a workspace's panes is being watched — the count on the
    /// workspace row cannot answer that.
    func testTheWatchedPanesCardNamesTheMachine() {
        let card = PaneFilmstripItemView(paneID: "s1")
        card.detail = "Claude Code"
        XCTAssertEqual(card.detailText, "Claude Code")
        card.viewerNames = ["Air", "MBP"]
        XCTAssertEqual(card.detailText, "Air, MBP", "several machines join with a comma")
        XCTAssertFalse(card.viewerGlyph.isHidden, "and the remote glyph leads the line")
        card.viewerNames = []
        XCTAssertEqual(card.detailText, "Claude Code", "the engine comes back when nobody is watching")
        XCTAssertTrue(card.viewerGlyph.isHidden)
    }

    /// The popover lists each machine with what it is on and a Disconnect,
    /// and says once — under the buttons — what Disconnect costs.
    func testThePopoverListsEveryMachineWithADisconnectAndSaysWhatItCosts() {
        var kicked: [String] = []
        let view = RemoteViewersView(
            rows: [
                RemoteViewersView.Row(
                    viewerID: "v1",
                    machineName: "Air",
                    since: "2026-08-31T10:00:00Z",
                    paneTitles: ["migrate", "logs"]
                ),
                RemoteViewersView.Row(
                    viewerID: "v2",
                    machineName: "MBP",
                    since: "2026-08-31T10:00:00Z",
                    paneTitles: []
                ),
            ],
            onDisconnect: { kicked.append($0) }
        )
        XCTAssertEqual(view.machineNames, ["Air", "MBP"])
        XCTAssertEqual(view.paneLines, ["migrate, logs", "Not attached"])
        XCTAssertEqual(view.footerText, "Blocked until you turn Remote Control off and on again.")
        XCTAssertEqual(view.disconnectButtons.count, 2)
        view.disconnectButtons[1].performClick(nil)
        XCTAssertEqual(kicked, ["v2"], "each button carries its own machine's id")
    }

    /// "How long" without a locale-dependent formatter in the way — and an
    /// unparseable `since` prints nothing rather than a wrong number. (The
    /// daemon's own timestamps are RFC 3339; this is what a future protocol
    /// change would fall back to.)
    func testTheListSaysHowLongEachMachineHasBeenWatching() throws {
        let start = "2026-08-31T10:00:00Z"
        let base = try XCTUnwrap(ISO8601DateFormatter().date(from: start))
        XCTAssertEqual(RemoteViewersView.connectedText(since: start, now: base), "Just connected")
        XCTAssertEqual(RemoteViewersView.connectedText(since: start, now: base.addingTimeInterval(300)), "5 min")
        XCTAssertEqual(RemoteViewersView.connectedText(since: start, now: base.addingTimeInterval(7_200)), "2 hr")
        XCTAssertEqual(RemoteViewersView.connectedText(since: "…", now: base), "")
    }

    /// The one the dedupe in `write(_:to:)` would otherwise eat. The daemon
    /// writes this row too, so "the app already wrote `[]`" is never proof
    /// that the row on disk *is* `[]` — a second enable after a kick has to
    /// reach disk or the kicked Mac is blocked forever.
    func testASecondEnableClearsTheBlocklistAgainAfterADaemonSideKick() {
        let controller = makeController(panes: [pane("s1", project: "/a", group: "g1")])
        controller.toggleRemoteControl(workspaceID: "/a")   // on  — clears
        controller.connectionDouble.written.removeValue(forKey: SettingsKey.remoteControlBlocked)
        controller.toggleRemoteControl(workspaceID: "/a")   // off — no clear
        XCTAssertNil(
            controller.lastWrittenSetting(SettingsKey.remoteControlBlocked),
            "turning sharing off forgives nobody"
        )
        controller.toggleRemoteControl(workspaceID: "/a")   // on  — clears again
        XCTAssertEqual(controller.lastWrittenSetting(SettingsKey.remoteControlBlocked), "[]")
    }

    /// The standing "Spotlight finds everything" rule over the popover: the
    /// controller offers a row per watched workspace, named as the sidebar
    /// names it, and none at all while nobody is watching.
    func testTheViewerListIsFindableFromTheSpotlight() {
        let controller = makeController(panes: [pane("s1", project: "/a", group: "g1")])
        XCTAssertTrue(controller.watchedPaletteWorkspaces().isEmpty)

        controller.applyRemoteViewers([
            .init(viewerID: "v1", machineName: "Air", sessions: ["s1"], since: "…"),
        ])
        XCTAssertEqual(controller.watchedPaletteWorkspaces().map(\.id), ["/a"])
        XCTAssertEqual(controller.watchedPaletteWorkspaces().map(\.viewerNames), [["Air"]])
    }

    /// `NSPopover` raises rather than shrugs when handed a view in no window,
    /// and the spotlight can reach this with the window closed. Asking for a
    /// list there must do nothing at all.
    func testAskingForTheListWithNoWindowIsQuiet() {
        let controller = makeController(panes: [pane("s1", project: "/a", group: "g1")])
        controller.applyRemoteViewers([
            .init(viewerID: "v1", machineName: "Air", sessions: ["s1"], since: "…"),
        ])
        controller.close()
        // The assertion is that this does not raise.
        controller.showRemoteViewers(forWorkspace: "/a")
        controller.run(.showRemoteViewers(workspaceID: "/a"))
    }

    // MARK: - Helpers

    private func pane(
        _ id: String,
        project: String,
        group: String,
        label: String? = nil
    ) -> PersistedTab {
        PersistedTab(
            project: project,
            engine: .claude,
            cwd: project,
            id: id,
            label: label,
            group: group
        )
    }

    private func makeController(panes: [PersistedTab]) -> WorkspaceWindowController {
        let controller = WorkspaceWindowController(
            connection: SessionConnection(
                socketURL: URL(fileURLWithPath: "/tmp/omniagent-remote-presence-test.sock")
            ),
            panes: []
        )
        let recorder = Recorder()
        recorders[ObjectIdentifier(controller)] = recorder
        controller.sessionEnsurer = { _ in }
        controller.sessionKiller = { _ in }
        controller.settingsWriter = { key, value in recorder.written[key] = value }
        controller.viewerDisconnector = { viewerID, completion in
            recorder.disconnectedViewerIDs.append(viewerID)
            completion(recorder.disconnectResult)
        }
        controller.viewerLister = { completion in
            recorder.listViewerCalls += 1
            completion(.success(recorder.rosterFromDaemon))
        }
        controller.relayDeviceRegistrar = { _ in
            XCTFail("no test here may reach the relay")
            return RelayClient.Registration(deviceID: "d1", token: "secret")
        }
        controller.showWindow(nil)
        controller.applyRestoredPanes(
            WorkspaceRestoration.plan(fromLayout: PersistedLayoutCodec.serialize(panes))
        )
        addTeardownBlock { [weak controller] in
            if let controller { recorders.removeValue(forKey: ObjectIdentifier(controller)) }
            controller?.close()
        }
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

    /// What a test controller's settings writes and viewer kicks land in, so
    /// neither reaches the developer's real `brain.db` or a socket.
    final class Recorder {
        var written: [String: String] = [:]
        var disconnectedViewerIDs: [String] = []
        /// What the daemon is pretending to answer a kick with. A refusal is
        /// the interesting case: the kick did not happen.
        var disconnectResult: Result<Void, Error> = .success(())
        /// What a re-read of the roster finds, and how often one was asked
        /// for.
        var rosterFromDaemon: [RemoteViewer] = []
        var listViewerCalls = 0
    }
}

/// The recorders, keyed by controller — an extension cannot store a property,
/// and threading a double through every assertion would bury what each test
/// is actually about.
private var recorders: [ObjectIdentifier: RemotePresenceTests.Recorder] = [:]

private extension WorkspaceWindowController {
    var connectionDouble: RemotePresenceTests.Recorder {
        recorders[ObjectIdentifier(self)] ?? RemotePresenceTests.Recorder()
    }

    func lastWrittenSetting(_ key: String) -> String? { connectionDouble.written[key] }
}
