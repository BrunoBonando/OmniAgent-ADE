import AppKit
import XCTest

@testable import OmniAgent

/// The host's takeover panel — the 2026-09-01 remote environment sharing
/// spec's §7. What the person sitting at this Mac sees while somebody else
/// drives it, and the two verbs on it.
@MainActor
final class RemoteTakeoverPanelTests: XCTestCase {
    // MARK: - Doubles

    /// A kick is a write to another Mac's connection; no test may send one
    /// down a live socket. `SettingsStoreTests`' `FakeSettingsClient` pattern.
    final class SpyConnection: RemoteViewerDisconnecting {
        struct Disconnect: Equatable {
            let viewerID: String
            let block: Bool
        }

        private(set) var disconnects: [Disconnect] = []
        var lastDisconnect: Disconnect? { disconnects.last }
        /// What the daemon answers. `nil` means "no reply yet", which is the
        /// live case: the panel must not act as though a kick landed.
        var result: Result<Void, Error>? = .success(())

        func disconnectViewer(
            viewerID: String,
            block: Bool,
            completion: ((Result<Void, Error>) -> Void)?
        ) {
            disconnects.append(Disconnect(viewerID: viewerID, block: block))
            if let result { completion?(result) }
        }
    }

    private struct Refused: LocalizedError {
        var errorDescription: String? { "the daemon said no" }
    }

    private func info(
        viewerID: String = "v-mbp",
        machineName: String = "MacBook Pro",
        accountEmail: String? = "bruno@bonando.com",
        ip: String? = "203.0.113.7",
        country: String? = "DE",
        client: String? = "OmniAgent/1.7.22 macOS 27.0",
        isAttached: Bool = true
    ) -> RemoteConnectionInfo {
        RemoteConnectionInfo(
            viewerID: viewerID,
            machineName: machineName,
            accountEmail: accountEmail,
            ip: ip,
            country: country,
            client: client,
            since: Date(timeIntervalSince1970: 1_780_000_000),
            isAttached: isAttached
        )
    }

    // MARK: - The identity grid (Task 15)

    /// The panel's whole argument: the reader can tell what the relay
    /// asserted from what the far end said about itself. Account, IP and
    /// country are the three nobody on the other end can choose — a verified
    /// JWT and two headers Cloudflare sets at the edge. The machine name is
    /// out of the viewer's own `Hello`, and the app/OS are out of a user
    /// agent the client wrote, so neither is marked.
    func testAssertedFieldsAreMarkedAndSelfReportedOnesAreNot() {
        let panel = RemoteTakeoverPanel(info: info(), connection: SpyConnection())
        XCTAssertEqual(panel.row(for: .account)?.isVerified, true)
        XCTAssertEqual(panel.row(for: .ip)?.isVerified, true)
        XCTAssertEqual(panel.row(for: .country)?.isVerified, true)
        XCTAssertEqual(panel.row(for: .machineName)?.isVerified, false)
        XCTAssertEqual(panel.row(for: .os)?.isVerified, false)
        XCTAssertEqual(panel.row(for: .appVersion)?.isVerified, false)
        // The daemon's own observation is truer than any of them and still
        // not a relay assertion, so it wears nothing either — the glyph has
        // exactly one meaning.
        XCTAssertEqual(panel.row(for: .since)?.isVerified, false)
    }

    /// A row with no value is not drawn blank — it does not exist. "The
    /// relay said nothing" and "the relay said empty" are different facts,
    /// and a labelled blank states the second one.
    func testAbsentAssertedFieldsAreOmittedNotShownEmpty() {
        let panel = RemoteTakeoverPanel(
            info: info(ip: nil, country: nil, client: nil),
            connection: SpyConnection()
        )
        XCTAssertNil(panel.row(for: .ip))
        XCTAssertNil(panel.row(for: .country))
        XCTAssertNil(panel.row(for: .os))
        XCTAssertNil(panel.row(for: .appVersion))
        XCTAssertNotNil(panel.row(for: .account), "what the relay did say is still there")
        XCTAssertFalse(
            panel.rows.contains { $0.value.trimmingCharacters(in: .whitespaces).isEmpty },
            "no row on the panel is ever an empty value"
        )
    }

    /// An empty string is not a value either — a relay that sent `""` said
    /// nothing, and the roster's own decode must not turn that into a row.
    func testAnEmptyAssertedStringIsTreatedAsAbsent() {
        let panel = RemoteTakeoverPanel(
            info: RemoteConnectionInfo(viewer: RemoteViewer(
                viewerID: "v-air",
                machineName: "Air",
                sessions: [],
                since: "2026-09-01T09:00:00Z",
                accountEmail: "  ",
                ip: "",
                country: nil,
                client: nil
            )),
            connection: SpyConnection()
        )
        XCTAssertNil(panel.row(for: .account))
        XCTAssertNil(panel.row(for: .ip))
    }

    /// The app and OS rows come out of the relay's user-agent string, and
    /// only when it has the shape they are read from — a guess would be a
    /// fact invented for the panel.
    func testTheAppAndOSRowsAreReadOffTheUserAgentAndNotGuessed() {
        XCTAssertEqual(
            RemoteTakeoverPanel.appVersion(fromUserAgent: "OmniAgent/1.7.22 macOS 27.0"),
            "OmniAgent 1.7.22"
        )
        XCTAssertEqual(
            RemoteTakeoverPanel.operatingSystem(fromUserAgent: "OmniAgent/1.7.22 macOS 27.0"),
            "macOS 27.0"
        )
        for junk in ["OmniAgent", "some other client", ""] {
            XCTAssertNil(RemoteTakeoverPanel.appVersion(fromUserAgent: junk), junk)
        }
        XCTAssertNil(RemoteTakeoverPanel.operatingSystem(fromUserAgent: "OmniAgent/1.7.22"))
    }

    /// The header advances on a fact the daemon witnessed — the viewer
    /// attaching to a session — rather than on a timer pretending to be one.
    func testTheStateLineAdvancesOnlyWhenTheViewerHasAttached() {
        let panel = RemoteTakeoverPanel(info: info(isAttached: false), connection: SpyConnection())
        XCTAssertEqual(panel.state, .settingUp)
        XCTAssertEqual(panel.state.line, "Setting up connection…")
        panel.apply(info(isAttached: true))
        XCTAssertEqual(panel.state, .connected)
        XCTAssertEqual(panel.state.line, "Connected")
    }

    // MARK: - No way out (Task 15)

    /// While somebody is connected, the panel *is* the app: it cannot be
    /// closed, minimized or dragged aside. ⌘Q still quits, which is the only
    /// way out and ends sharing with it.
    func testThePanelHasNoDismissPath() {
        let panel = RemoteTakeoverPanel(info: info(), connection: SpyConnection())
        XCTAssertFalse(panel.window.isMovable)
        XCTAssertFalse(panel.window.styleMask.contains(.closable))
        XCTAssertFalse(panel.window.styleMask.contains(.miniaturizable))
        XCTAssertEqual(panel.window.level, .modalPanel, "above the workspace window")
        XCTAssertTrue(panel.window.canBecomeKey, "or its two buttons are mouse-only")
    }

    // MARK: - Terminate and Block (Task 16)

    /// Terminate kicks and nothing else: the machine is free to dial back
    /// the instant it wants to.
    func testTerminateSendsDisconnectWithoutBlocking() {
        let spy = SpyConnection()
        let panel = RemoteTakeoverPanel(info: info(viewerID: "v-mbp"), connection: spy)
        panel.terminate()
        XCTAssertEqual(spy.lastDisconnect, .init(viewerID: "v-mbp", block: false))
    }

    /// Block kicks *and* keeps out — the daemon appends the id to
    /// `remote_control_blocked`, so the app has to re-read that row.
    func testBlockSendsDisconnectWithBlockingAndAsksForAReRead() {
        let spy = SpyConnection()
        let panel = RemoteTakeoverPanel(info: info(viewerID: "v-mbp"), connection: spy)
        var reReads = 0
        panel.onBlocked = { reReads += 1 }
        panel.block()
        XCTAssertEqual(spy.lastDisconnect, .init(viewerID: "v-mbp", block: true))
        XCTAssertEqual(reReads, 1, "the daemon wrote the blocked row; the app's copy is stale")
    }

    /// The kick names the **viewer id**, which is what the daemon's roster
    /// and blocklist are keyed on — never the machine name, which is not
    /// unique and which nothing on the daemon side matches against.
    func testTheKickNamesTheViewerIDNotTheMachineName() {
        let spy = SpyConnection()
        let panel = RemoteTakeoverPanel(
            info: info(viewerID: "v-mbp", machineName: "MacBook Pro"),
            connection: spy
        )
        panel.block()
        XCTAssertEqual(spy.lastDisconnect?.viewerID, "v-mbp")
    }

    /// A refused kick must never look like a successful one. This is a
    /// security surface: "they are off your Mac" while they are still on it
    /// is the one wrong answer it can give.
    func testAFailedKickSaysSoOnThePanelItself() {
        let spy = SpyConnection()
        spy.result = .failure(Refused())
        let panel = RemoteTakeoverPanel(info: info(), connection: spy)
        var failures: [Error] = []
        panel.onActionFailed = { failures.append($0) }
        panel.terminate()
        XCTAssertEqual(failures.count, 1)
        XCTAssertTrue(
            renderedText(of: panel.view).contains("the daemon said no"),
            "the panel covers the window, so the house ask card would be invisible behind it"
        )
    }

    /// Nothing about the panel is optimistic: the daemon's roster is what
    /// takes it down, so a kick leaves it exactly where it was.
    func testAKickDoesNotTakeThePanelDownByItself() {
        let spy = SpyConnection()
        let panel = RemoteTakeoverPanel(info: info(), connection: spy)
        panel.present(over: nil)
        panel.terminate()
        XCTAssertTrue(panel.window.isVisible, "only the roster ends the takeover")
        panel.dismiss()
    }

    // MARK: - Layout, by offscreen render

    /// Verified by rendering, not by eye: screen capture cannot see this
    /// app's windows on this machine. A panel that failed to lay out paints
    /// as one flat sheet, and its rows do not fit inside its card.
    func testThePanelRendersItsCardAndEveryRowInsideIt() throws {
        let panel = RemoteTakeoverPanel(info: info(), connection: SpyConnection())
        let view = panel.view
        view.frame = NSRect(x: 0, y: 0, width: 1440, height: 900)
        view.layoutSubtreeIfNeeded()

        let card = view.cardFrame
        XCTAssertEqual(card.width, RemoteTakeoverPanelView.cardWidth)
        XCTAssertTrue(view.bounds.contains(card), "the card fits the screen it covers")
        // Every label the panel drew is inside the card, not spilling onto
        // the dimmed workspace behind it.
        let labels = view.subviews.compactMap { $0 as? NSTextField }
        XCTAssertGreaterThanOrEqual(labels.count, 9, "state, machine, explanation and the grid")
        for label in labels where !label.stringValue.isEmpty {
            XCTAssertTrue(
                card.insetBy(dx: -1, dy: -1).contains(label.frame),
                "\"\(label.stringValue)\" spilled outside the card: \(label.frame) vs \(card)"
            )
        }
        XCTAssertTrue(card.contains(view.terminateButton.frame))
        XCTAssertTrue(card.contains(view.blockButton.frame))
        XCTAssertGreaterThan(view.blockButton.frame.minX, view.terminateButton.frame.maxX)

        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        var seen = Set<String>()
        for x in stride(from: 10, to: rep.pixelsWide, by: max(1, rep.pixelsWide / 24)) {
            for y in stride(from: 10, to: rep.pixelsHigh, by: max(1, rep.pixelsHigh / 24)) {
                if let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) {
                    seen.insert(String(
                        format: "%.3f/%.3f/%.3f",
                        color.redComponent, color.greenComponent, color.blueComponent
                    ))
                }
            }
        }
        XCTAssertGreaterThan(seen.count, 2, "a flat sheet means the panel did not lay out")
        if let png = rep.representation(using: .png, properties: [:]) {
            let path = ProcessInfo.processInfo.environment["TAKEOVER_PANEL_RENDER_PATH"]
                ?? (NSTemporaryDirectory() as NSString).appendingPathComponent("takeover-panel.png")
            try png.write(to: URL(fileURLWithPath: path))
        }
    }

    /// The activity table's room (spec §8) is reserved for exactly one thing:
    /// the table itself (Task 20) — never a stray label or button of the
    /// grid/footer spilling into it.
    func testTheActivityRoomHoldsExactlyTheActivityTable() {
        let panel = RemoteTakeoverPanel(info: info(), connection: SpyConnection())
        panel.view.frame = NSRect(x: 0, y: 0, width: 1440, height: 900)
        panel.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(panel.view.activityFrame.height, RemoteTakeoverPanelView.activityRoom)
        let table = try? XCTUnwrap(
            panel.view.subviews.first { $0 is RemoteActivityTableView }
        )
        XCTAssertEqual(table?.frame, panel.view.activityFrame)
        let strayed = panel.view.subviews.filter {
            !($0 is RemoteActivityTableView)
                && $0.frame.intersects(panel.view.activityFrame.insetBy(dx: 2, dy: 2))
                && ($0 is NSTextField || $0 is PaneApprovalButton)
        }
        XCTAssertTrue(strayed.isEmpty, "a grid/footer view spilled into the activity room: \(strayed)")
    }

    /// Rows arriving through the panel land on its table, newest last, and a
    /// row with no detail is not expandable — spec §8's whole promise, pinned
    /// through the real path (`RemoteTakeoverPanel.appendActivity`) rather
    /// than only through `RemoteActivityTable` directly.
    func testActivityPushedToThePanelReachesItsTable() {
        let panel = RemoteTakeoverPanel(info: info(), connection: SpyConnection())
        panel.appendActivity([
            .init(ts: Date(), kind: "attach", summary: "Opened Terminal 1", detail: nil),
            .init(ts: Date(), kind: "input", summary: "Sent a prompt", detail: "hello"),
        ])
        XCTAssertEqual(panel.activityLog.entries.map(\.kind), ["attach", "input"])
    }

    /// Activity fix round 1, IMPORTANT 3: a later push must *add* rows to
    /// the table, never rebuild it from the log's whole accumulated array —
    /// the old shape was O(n²) over an unbounded live history and collapsed
    /// every already-expanded row the instant the next one arrived. Two
    /// pushes' row counts summing, rather than the second push's count alone
    /// (which the old rebuild-from-`activityLog.entries` shape would also
    /// have produced, just by re-deriving the same total from scratch), is
    /// what tells "appended" apart from "rebuilt to the same total".
    func testASecondPushAppendsRatherThanRebuildingTheTable() {
        let view = RemoteActivityTableView(frame: NSRect(x: 0, y: 0, width: 400, height: 150))
        view.append([
            .init(ts: Date(), kind: "attach", summary: "Opened Terminal 1", detail: nil)
        ])
        XCTAssertEqual(view.rowCount, 1)
        view.append([
            .init(ts: Date(), kind: "kill", summary: "Closed Terminal 1", detail: nil)
        ])
        XCTAssertEqual(view.rowCount, 2, "the second push added a row rather than replacing the table")
    }

    /// The same fix, through the row itself: expansion is state a
    /// `RemoteActivityRowView` instance owns, so it can only survive a later
    /// push if that instance is the same object afterward — proof that
    /// appending never tears down and rebuilds rows that were already there.
    func testExpandingARowSurvivesALaterPushBecauseTheRowIsNeverRebuilt() {
        let row = RemoteActivityRowView(
            entry: .init(ts: Date(), kind: "input", summary: "Sent a prompt", detail: "hello there"),
            timeText: "10:00:00",
            symbolName: "character.cursor.ibeam"
        )
        XCTAssertFalse(row.isExpanded)
        row.toggle()
        XCTAssertTrue(row.isExpanded, "the same instance, toggled once, stays expanded regardless of what a later push does — it is never rebuilt")
    }

    // MARK: - The panel is never absent while somebody is driving (fix round 1)

    /// **A live connection presents the panel on its own.**
    ///
    /// It used to also require `isSharing`, which is this app's *cached* copy
    /// of a row the daemon reads from disk independently. A post-connect
    /// restore that fails — real enough that `connectionDidComeUp()` exists
    /// to retry it — leaves that copy `false`, and the roster push would then
    /// have shown no panel at all while somebody drove the Mac. Worse, the
    /// menu bar would have gone blue at the same instant, because
    /// `MenuBarController.shareState` asks `liveRemoteConnection` first: two
    /// surfaces disagreeing about whether anyone is here.
    func testALiveConnectionPresentsThePanelEvenWhenTheSharingRowNeverRead() throws {
        let client = FakeSettingsClient()
        // The restore fails, so `isSharing` stays at its fail-closed default.
        client.failing = [SettingsKey.remoteSharing]
        let controller = try makeController(client: client, socket: "panel-fails-open")
        defer { controller.close() }
        XCTAssertFalse(controller.isSharingEnvironment, "the app believes it is not sharing")

        controller.applyRemoteViewers([air])

        XCTAssertNotNil(controller.liveRemoteConnection)
        XCTAssertNotNil(
            controller.takeoverPanel,
            "somebody is driving this Mac, so the panel is up — a panel a moment early is "
                + "harmless, a panel missing is the whole failure"
        )
    }

    /// And it comes down when, and only when, the daemon says the connection
    /// is gone.
    func testThePanelComesDownWhenTheRosterEmpties() throws {
        let controller = try makeController(socket: "panel-down")
        defer { controller.close() }
        controller.applyRemoteViewers([air])
        XCTAssertNotNil(controller.takeoverPanel)

        controller.applyRemoteViewers([])

        XCTAssertNil(controller.takeoverPanel)
    }

    /// **A kick the daemon refused leaves the panel exactly where it was.**
    ///
    /// The popover's Disconnect used to filter the machine out of the roster
    /// before the daemon had answered, which drove `liveConnection` to `nil`
    /// and dismissed the panel — so a refused kick read as "they are off your
    /// Mac" while they were still on it, and stayed wrong if the follow-up
    /// re-read failed too.
    func testARefusedKickLeavesThePanelExactlyWhereItWas() throws {
        let controller = try makeController(socket: "panel-refused-kick")
        defer { controller.close() }
        controller.viewerLister = { $0(.success([self.air])) }
        controller.viewerDisconnector = { _, completion in
            completion(.failure(NSError(domain: "test", code: 1)))
        }
        controller.applyRemoteViewers([air])
        XCTAssertNotNil(controller.takeoverPanel)

        controller.disconnectViewer(air.viewerID)

        XCTAssertNotNil(
            controller.takeoverPanel,
            "the daemon refused, so the machine is still driving this Mac"
        )
        XCTAssertNotNil(controller.liveRemoteConnection)
    }

    /// Even a kick the daemon *accepted* does not take the panel down by
    /// itself: the roster does. The app must not predict what the daemon is
    /// about to report.
    func testAnAcceptedKickStillWaitsForTheRosterBeforeThePanelGoes() throws {
        let controller = try makeController(socket: "panel-accepted-kick")
        defer { controller.close() }
        controller.viewerDisconnector = { _, completion in completion(.success(())) }
        controller.applyRemoteViewers([air])

        controller.disconnectViewer(air.viewerID)
        XCTAssertNotNil(controller.takeoverPanel, "only the daemon's next roster ends the takeover")

        controller.applyRemoteViewers([])
        XCTAssertNil(controller.takeoverPanel)
    }

    /// A kick that blocks makes the app's copy of `remote_control_blocked`
    /// stale — the daemon wrote it — so the controller re-reads. Without
    /// this, a later Unblock of a *different* id computed from the stale copy
    /// silently forgave this machine.
    func testAKickThatBlocksReReadsTheBlockedRowTheDaemonJustWrote() throws {
        let client = FakeSettingsClient()
        let controller = try makeController(client: client, socket: "panel-kick-blocked")
        defer { controller.close() }
        controller.viewerDisconnector = { _, completion in completion(.success(())) }
        XCTAssertEqual(controller.settingsView.blockedViewerIDs, [])

        // What the daemon does as part of the kick.
        client.seedRow("remote_control_blocked", #"["v-air"]"#)
        controller.disconnectViewer(air.viewerID)

        XCTAssertEqual(controller.settingsView.blockedViewerIDs, ["v-air"])
    }

    /// **The spotlight has to stack above the panel.**
    ///
    /// `CommandPaletteController.present(over:)` stacks by child window, not
    /// by level, so handing it the workspace window while the panel is up
    /// drew the palette *behind* a `.modalPanel` — it took the keyboard,
    /// showed nothing, and dismissed itself on the next resign-key. The
    /// Terminate/Block rows passed their own test and could not be reached.
    func testTheSpotlightStacksAboveTheTakeoverPanelWhileItIsUp() throws {
        let controller = try makeController(socket: "panel-palette-parent")
        defer { controller.close() }
        XCTAssertTrue(controller.paletteParentWindow === controller.window)

        controller.applyRemoteViewers([air])

        let panel = try XCTUnwrap(controller.takeoverPanel)
        XCTAssertTrue(
            controller.paletteParentWindow === panel.window,
            "a child window is always drawn above its parent"
        )
        controller.applyRemoteViewers([])
        XCTAssertTrue(controller.paletteParentWindow === controller.window)
    }

    // MARK: - Controller helpers

    /// The one machine every controller test above hands the roster.
    private var air: RemoteViewer {
        RemoteViewer(
            viewerID: "v-air",
            machineName: "Air",
            sessions: ["s1"],
            since: "2026-09-01T09:00:00Z",
            accountEmail: "bruno@bonando.com",
            ip: "203.0.113.7",
            country: "DE",
            client: "OmniAgent/1.7.22 macOS 27.0"
        )
    }

    /// A controller whose takeover panel is built but never ordered on
    /// screen: the seam is presentation only, so `takeoverPanel` — the thing
    /// every assertion above is about — is exactly what production sets.
    private func makeController(
        client: FakeSettingsClient = FakeSettingsClient(),
        socket: String
    ) throws -> WorkspaceWindowController {
        let controller = WorkspaceWindowController(
            connection: SessionConnection(
                socketURL: URL(fileURLWithPath: "/tmp/omniagent-\(socket)-test.sock")
            ),
            panes: [],
            remoteSharing: RemoteSharingModel(store: SettingsStore(client: client)),
            authDefaults: try throwawayDefaults()
        )
        controller.takeoverPanelPresenter = { _ in }
        controller.relayDeviceRegistrar = { _ in
            XCTFail("no test here may reach the relay")
            return RelayClient.Registration(deviceID: "d1", token: "secret")
        }
        return controller
    }

    /// A suite of its own, torn down after — never the real app's defaults
    /// (`RealPreferencesGuard`).
    private func throwawayDefaults() throws -> UserDefaults {
        let name = "digital.bruno.omniagent.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        return defaults
    }

    private func renderedText(of view: NSView) -> String {
        view.subviews.compactMap { ($0 as? NSTextField)?.stringValue }.joined(separator: "\n")
    }
}
