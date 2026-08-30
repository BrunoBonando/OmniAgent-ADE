import XCTest

@testable import OmniAgent

/// Answers every request on the stub session from `handler` —
/// `RelayClientTests`' stub, which is `private` to that file, so this is its
/// twin for the device list the viewer side polls.
private final class RemoteRelayStubProtocol: URLProtocol {
    static var handler: ((URLRequest) -> (status: Int, body: String))?
    static var requests: [URLRequest] = []

    static func reset() {
        handler = nil
        requests = []
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RemoteRelayStubProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append(request)
        guard let handler = Self.handler, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let (status, body) = handler(request)
        let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// A `RemoteConnection` that never opens a socket: it counts what the model
/// asks of it and answers `getSetting` from `projectionJSON` on the spot.
private final class FakeRemoteConnection: RemoteConnection {
    var onStateChange: ((ConnectionState) -> Void)?
    var onError: ((Error) -> Void)?
    var connectCalls = 0
    var disconnectCalls = 0
    var settingReads: [String] = []
    var projectionJSON: String? = RemoteMachinesModelTests.projectionA
    /// `nil` answers every read with `.failure` — a socket that is not up yet.
    var readError: Error?

    func connect() { connectCalls += 1 }
    func disconnect() { disconnectCalls += 1 }

    func getSetting(key: String, completion: @escaping (Result<String?, Error>) -> Void) {
        settingReads.append(key)
        if let readError {
            completion(.failure(readError))
        } else {
            completion(.success(projectionJSON))
        }
    }
}

/// `RemoteMachinesModel` — the viewer side's device list and its one
/// connection per online machine (the remote-session-control spec's §4
/// "Viewer side", docs/superpowers/specs/2026-08-30-remote-session-control-design.md).
final class RemoteMachinesModelTests: XCTestCase {
    static let projectionA = #"{"workspaces":[{"id":"/a","name":"A","sessions":[{"id":"s1","title":"Build","engine":"claude","group":"g1"}]}]}"#
    static let projectionB = #"{"workspaces":[{"id":"/b","name":"B","sessions":[{"id":"s2","title":"Docs","engine":"codex","group":"g2"}]}]}"#

    private static let studioOnline = #"{"device_id":"d1","name":"Studio","online":true,"last_seen_at":null}"#
    private static let studioOffline = #"{"device_id":"d1","name":"Studio","online":false,"last_seen_at":null}"#
    private static let airOnline = #"{"device_id":"d2","name":"Air","online":true,"last_seen_at":null}"#
    private static let airOffline = #"{"device_id":"d2","name":"Air","online":false,"last_seen_at":null}"#

    override func setUp() {
        super.setUp()
        RemoteRelayStubProtocol.reset()
    }

    override func tearDown() {
        RemoteRelayStubProtocol.reset()
        super.tearDown()
    }

    private func makeRelay(accessToken: @escaping () -> String? = { "tok" }) -> RelayClient {
        RelayClient(
            baseURL: URL(string: "https://relay.test")!,
            session: RemoteRelayStubProtocol.session(),
            accessToken: accessToken
        )
    }

    private func answer(_ devices: String...) {
        let body = "[" + devices.joined(separator: ",") + "]"
        RemoteRelayStubProtocol.handler = { _ in (200, body) }
    }

    // MARK: - Polling

    func testOnlineDevicesGetOneConnectionAndTheirProjection() async throws {
        answer(Self.studioOnline, Self.airOffline)
        var made: [URL] = []
        let fake = FakeRemoteConnection()
        var changes = 0
        let model = RemoteMachinesModel(
            relay: makeRelay(),
            makeConnection: { url in made.append(url); return fake },
            isSignedIn: { true }
        )
        model.onChange = { changes += 1 }

        await model.refresh()

        XCTAssertEqual(made.map(\.absoluteString), ["wss://relay.test/v1/viewer/d1"])
        XCTAssertEqual(fake.connectCalls, 1)
        XCTAssertEqual(fake.settingReads, [SettingsKey.remoteControl])
        XCTAssertEqual(model.machines.map(\.name), ["Studio"])
        XCTAssertEqual(model.machines.first?.deviceID, "d1")
        XCTAssertEqual(model.machines.first?.projection.workspaces.map(\.id), ["/a"])
        XCTAssertEqual(model.machines.first?.projection.workspaces.first?.sessions.map(\.title), ["Build"])
        XCTAssertNotNil(model.connection(for: "d1"))
        XCTAssertNil(model.connection(for: "d2"), "an offline device gets no connection")
        XCTAssertEqual(changes, 1)
    }

    func testDeviceGoingOfflineIsDropped() async throws {
        answer(Self.studioOnline)
        let fake = FakeRemoteConnection()
        let model = RemoteMachinesModel(relay: makeRelay(), makeConnection: { _ in fake }, isSignedIn: { true })
        await model.refresh()
        XCTAssertEqual(model.machines.count, 1)

        answer(Self.studioOffline)
        await model.refresh()

        XCTAssertTrue(model.machines.isEmpty)
        XCTAssertNil(model.connection(for: "d1"))
        XCTAssertEqual(fake.disconnectCalls, 1)
    }

    /// The machine's panes keep their connection object (the brief's rule),
    /// so when it comes back the *same* object is reconnected rather than a
    /// twin minted beside it — a pane opened before the outage resumes.
    func testADeviceComingBackOnlineReconnectsTheSameObject() async throws {
        answer(Self.studioOnline)
        var made = 0
        let fake = FakeRemoteConnection()
        let model = RemoteMachinesModel(relay: makeRelay(), makeConnection: { _ in made += 1; return fake }, isSignedIn: { true })
        await model.refresh()
        answer(Self.studioOffline)
        await model.refresh()
        XCTAssertNil(model.connection(for: "d1"))
        XCTAssertNotNil(model.retainedConnection(for: "d1"), "panes route through the retained object while it is offline")

        answer(Self.studioOnline)
        await model.refresh()

        XCTAssertEqual(made, 1, "one connection per device, ever")
        XCTAssertEqual(fake.connectCalls, 2)
        XCTAssertNotNil(model.connection(for: "d1"))
        XCTAssertEqual(model.machines.map(\.deviceID), ["d1"])
    }

    func testASecondPollReusesTheConnectionAndRereadsTheProjection() async throws {
        answer(Self.studioOnline)
        var made = 0
        let fake = FakeRemoteConnection()
        let model = RemoteMachinesModel(relay: makeRelay(), makeConnection: { _ in made += 1; return fake }, isSignedIn: { true })
        await model.refresh()

        fake.projectionJSON = Self.projectionB
        await model.refresh()

        XCTAssertEqual(made, 1)
        XCTAssertEqual(fake.connectCalls, 1, "an already-connected device is not reconnected by a poll")
        XCTAssertEqual(fake.settingReads.count, 2, "every poll re-reads the projection")
        XCTAssertEqual(model.machines.first?.projection.workspaces.map(\.id), ["/b"])
    }

    func testMachinesAreSortedByName() async throws {
        answer(Self.studioOnline, Self.airOnline)
        let model = RemoteMachinesModel(relay: makeRelay(), makeConnection: { _ in FakeRemoteConnection() }, isSignedIn: { true })

        await model.refresh()

        XCTAssertEqual(model.machines.map(\.name), ["Air", "Studio"])
    }

    // MARK: - Projection reads

    /// A device whose socket is not up yet is online but has no projection
    /// to show; it joins `machines` the moment the read lands — which the
    /// connection's own `.connected` transition triggers.
    func testAMachineJoinsWhenItsProjectionReadLandsOnConnect() async throws {
        answer(Self.studioOnline)
        let fake = FakeRemoteConnection()
        fake.readError = SessionConnectionError.disconnected
        let model = RemoteMachinesModel(relay: makeRelay(), makeConnection: { _ in fake }, isSignedIn: { true })
        var changes = 0
        model.onChange = { changes += 1 }

        await model.refresh()
        XCTAssertTrue(model.machines.isEmpty, "no projection yet, nothing to list")
        XCTAssertNotNil(model.connection(for: "d1"), "the connection exists ahead of the projection")
        XCTAssertEqual(changes, 0)

        fake.readError = nil
        fake.onStateChange?(.connected)
        await Task.yield()

        XCTAssertEqual(model.machines.map(\.deviceID), ["d1"])
        XCTAssertEqual(fake.settingReads.count, 2)
        XCTAssertEqual(changes, 1)
    }

    /// `onChange` says something changed — an identical projection on the
    /// next poll is not news.
    func testAnUnchangedPollDoesNotFireOnChange() async throws {
        answer(Self.studioOnline)
        let model = RemoteMachinesModel(relay: makeRelay(), makeConnection: { _ in FakeRemoteConnection() }, isSignedIn: { true })
        var changes = 0
        model.onChange = { changes += 1 }

        await model.refresh()
        await model.refresh()

        XCTAssertEqual(changes, 1)
    }

    // MARK: - Failure modes

    /// A relay outage is not an error the user sees: the last answer stands
    /// until the relay is back (spec §6, "Relay restart / Core deploy").
    func testARelayOutageKeepsTheLastAnswer() async throws {
        answer(Self.studioOnline)
        let fake = FakeRemoteConnection()
        let model = RemoteMachinesModel(relay: makeRelay(), makeConnection: { _ in fake }, isSignedIn: { true })
        await model.refresh()

        RemoteRelayStubProtocol.handler = { _ in (503, #"{"detail":"deploying"}"#) }
        await model.refresh()

        XCTAssertEqual(model.machines.map(\.name), ["Studio"])
        XCTAssertNotNil(model.connection(for: "d1"))
        XCTAssertEqual(fake.disconnectCalls, 0)
    }

    /// The access token lives fifteen minutes; the poll outlives it. A 401
    /// from the relay refreshes the session once and retries, so a viewer
    /// left open does not go blind at the quarter hour.
    func testARelayUnauthorizedRefreshesTheSessionOnceAndRetries() async throws {
        var statuses = [401, 200]
        RemoteRelayStubProtocol.handler = { _ in
            let status = statuses.removeFirst()
            return (status, status == 200 ? "[\(Self.studioOnline)]" : #"{"detail":"expired"}"#)
        }
        var refreshes = 0
        let model = RemoteMachinesModel(
            relay: makeRelay(),
            makeConnection: { _ in FakeRemoteConnection() },
            isSignedIn: { true },
            refreshSession: { refreshes += 1 }
        )

        await model.refresh()

        XCTAssertEqual(refreshes, 1)
        XCTAssertEqual(RemoteRelayStubProtocol.requests.count, 2)
        XCTAssertEqual(model.machines.map(\.name), ["Studio"])
    }

    func testARelayUnauthorizedThatStaysUnauthorizedGivesUpAfterOneRetry() async throws {
        RemoteRelayStubProtocol.handler = { _ in (401, #"{"detail":"expired"}"#) }
        var refreshes = 0
        let model = RemoteMachinesModel(
            relay: makeRelay(),
            makeConnection: { _ in FakeRemoteConnection() },
            isSignedIn: { true },
            refreshSession: { refreshes += 1 }
        )

        await model.refresh()

        XCTAssertEqual(refreshes, 1)
        XCTAssertEqual(RemoteRelayStubProtocol.requests.count, 2, "one retry, not a loop")
        XCTAssertTrue(model.machines.isEmpty)
    }

    func testSignedOutDisconnectsEverythingAndClears() async throws {
        answer(Self.studioOnline)
        var signedIn = true
        let fake = FakeRemoteConnection()
        let model = RemoteMachinesModel(relay: makeRelay(), makeConnection: { _ in fake }, isSignedIn: { signedIn })
        await model.refresh()
        XCTAssertEqual(model.machines.count, 1)
        let requestsBefore = RemoteRelayStubProtocol.requests.count

        signedIn = false
        await model.refresh()

        XCTAssertTrue(model.machines.isEmpty)
        XCTAssertNil(model.connection(for: "d1"))
        XCTAssertNil(model.retainedConnection(for: "d1"), "a signed-out viewer keeps no socket to anyone")
        XCTAssertEqual(fake.disconnectCalls, 1)
        XCTAssertEqual(RemoteRelayStubProtocol.requests.count, requestsBefore, "signed out, the relay is not even asked")
    }

    func testStopDisconnectsEverythingAndClears() async throws {
        answer(Self.studioOnline)
        let fake = FakeRemoteConnection()
        let model = RemoteMachinesModel(relay: makeRelay(), makeConnection: { _ in fake }, isSignedIn: { true })
        await model.refresh()

        await MainActor.run { model.stop() }

        XCTAssertTrue(model.machines.isEmpty)
        XCTAssertNil(model.connection(for: "d1"))
        XCTAssertEqual(fake.disconnectCalls, 1)
        XCTAssertFalse(model.isRunning)
    }

    /// A 401/403 on the WebSocket upgrade stops that connection's own
    /// retries (`SessionConnectionError.unauthorized`). The next poll that
    /// gets through the relay has a bearer the relay accepts, so the model
    /// re-`connect()`s the same object with it rather than minting a twin.
    func testAnUnauthorizedConnectionIsReconnectedOnTheNextSuccessfulPoll() async throws {
        answer(Self.studioOnline)
        var made = 0
        let fake = FakeRemoteConnection()
        let model = RemoteMachinesModel(relay: makeRelay(), makeConnection: { _ in made += 1; return fake }, isSignedIn: { true })
        await model.refresh()
        XCTAssertEqual(fake.connectCalls, 1)

        fake.onError?(SessionConnectionError.unauthorized)
        await Task.yield()
        await model.refresh()

        XCTAssertEqual(made, 1)
        XCTAssertEqual(fake.connectCalls, 2)
    }

    func testStartPollsAtOnceAndAgainOnTheInterval() async throws {
        answer(Self.studioOnline)
        let fake = FakeRemoteConnection()
        let model = RemoteMachinesModel(
            relay: makeRelay(),
            pollInterval: 0.05,
            makeConnection: { _ in fake },
            isSignedIn: { true }
        )
        let polled = expectation(description: "polled more than once")
        polled.assertForOverFulfill = false
        RemoteRelayStubProtocol.handler = { _ in
            if RemoteRelayStubProtocol.requests.count >= 2 { polled.fulfill() }
            return (200, "[\(Self.studioOnline)]")
        }

        await MainActor.run { model.start() }
        XCTAssertTrue(model.isRunning)
        await fulfillment(of: [polled], timeout: 5)
        await MainActor.run { model.stop() }

        XCTAssertEqual(fake.connectCalls, 1, "polling never reconnects a device that stayed online")
    }
}

/// The window side of B4: remote panes, their routing and what they must
/// never do — persist, spawn or kill.
final class RemotePanesTests: XCTestCase {
    private static let projection = RemoteMachinesModelTests.projectionA

    override func setUp() {
        super.setUp()
        RemoteRelayStubProtocol.reset()
    }

    override func tearDown() {
        RemoteRelayStubProtocol.reset()
        super.tearDown()
    }

    /// A model with one online machine, "Studio", whose connection is a real
    /// `SessionConnection` over the WebSocket transport — the pane factory
    /// needs the concrete type — pointed at a port nothing listens on, so
    /// `connect()` is refused on the spot and never reaches the network.
    private func makeMachines() async -> RemoteMachinesModel {
        RemoteRelayStubProtocol.handler = { _ in
            (200, #"[{"device_id":"d1","name":"Studio","online":true,"last_seen_at":null}]"#)
        }
        let relay = RelayClient(
            baseURL: URL(string: "http://127.0.0.1:1")!,
            session: RemoteRelayStubProtocol.session(),
            accessToken: { "tok" }
        )
        let model = RemoteMachinesModel(
            relay: relay,
            makeConnection: { url in
                SessionConnection(transport: .webSocket(url, bearer: { "tok" }), reconnectDelay: 60)
            },
            isSignedIn: { true },
            projectionReader: { _, completion in completion(.success(Self.projection)) }
        )
        await model.refresh()
        XCTAssertEqual(model.machines.map(\.name), ["Studio"])
        return model
    }

    private func makeController(
        remoteMachines: RemoteMachinesModel,
        settingsClient: SettingsClient? = nil
    ) -> WorkspaceWindowController {
        WorkspaceWindowController(
            connection: SessionConnection(
                socketURL: URL(fileURLWithPath: "/tmp/omniagent-remote-panes-test.sock")
            ),
            panes: [],
            remoteMachines: remoteMachines,
            settingsClient: settingsClient
        )
    }

    /// Polling follows the account: nothing until the launch gate has
    /// answered (the window-install seed reads a mirror that is only a
    /// guess), on when it answers signed in, off — with every remote pane
    /// closed and the model cleared — on log out.
    ///
    /// The mirror is `UserDefaults.standard`'s `auth.signedIn`, the key the
    /// real launch decision reads; saved and put back, and the suite-level
    /// `RealPreferencesGuard` stands behind that.
    @MainActor
    func testRemotePollingFollowsTheAccount() async throws {
        let key = AuthGate.signedInDefaultsKey
        let previous = UserDefaults.standard.object(forKey: key)
        addTeardownBlock {
            if let previous {
                UserDefaults.standard.set(previous, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        UserDefaults.standard.set(true, forKey: key)

        let machines = await makeMachines()
        let controller = makeController(remoteMachines: machines, settingsClient: FakeSettingsClient())
        defer { controller.close() }
        controller.sessionRestorer = {}
        controller.sessionEnsurer = { _ in }
        controller.serverSessionRevoker = {}
        controller.authGatePresenter = { _ in }
        // `logOutOfAccount` (2026-08-30 logout teardown) ends the daemon;
        // unstubbed that falls through to the real, production-pointed
        // `DaemonPersistenceController()` default and its live, async
        // `LiveDaemonTerminator` — the CRITICAL SAFETY RULE this suite
        // otherwise holds everywhere else `logOutOfAccount`/`switchAccount`
        // is exercised.
        controller.daemonTerminator = { $0(true) }
        controller.showWindow(nil)
        controller.applyRestoredPanes([])
        XCTAssertFalse(machines.isRunning, "the install-time seed must not start polling")
        // `applyRestoredPanes([])` plants a local terminal bootstrap pane
        // (there was nothing to restore) — closed here, unused and on the
        // spot, no ask, so what follows is genuinely "only a remote viewer
        // pane is open", the scenario this test is named for.
        controller.closePane(nil)
        XCTAssertTrue(controller.workspaceView.allPaneIDs.isEmpty)

        controller.presentLaunchGate(defaults: .standard) {}
        XCTAssertTrue(machines.isRunning, "signed in: polling starts as the gate resolves")

        controller.openRemoteSession(deviceID: "d1", sessionID: "s1", title: "Build")
        XCTAssertNotNil(controller.workspaceView.descriptor(for: "s1"))

        // Only a remote viewer pane is open — no local terminal session for
        // ending the daemon to kill — so this goes straight through with no
        // confirmation ask (the fix-round-2 `localTerminalSessionCount` count).
        controller.logOutOfAccount()

        XCTAssertFalse(machines.isRunning, "signed out: polling stops")
        XCTAssertTrue(machines.machines.isEmpty)
        XCTAssertNil(machines.connection(for: "d1"))
        XCTAssertNil(controller.workspaceView.descriptor(for: "s1"), "a signed-out viewer keeps no remote pane")
    }

    @MainActor
    func testOpeningARemoteSessionAddsARemotePaneWithoutSpawningOrKilling() async throws {
        let machines = await makeMachines()
        let controller = makeController(remoteMachines: machines)
        defer { controller.close() }
        var ensured: [String] = []
        var killed: [String] = []
        controller.sessionEnsurer = { ensured.append($0) }
        controller.sessionKiller = { killed.append($0) }
        controller.showWindow(nil)
        // Plants the bootstrap pane and ensures *it* — that one is local.
        controller.applyRestoredPanes([])
        ensured.removeAll()

        controller.openRemoteSession(deviceID: "d1", sessionID: "s1", title: "Build")

        let pane = try XCTUnwrap(controller.workspaceView.descriptor(for: "s1"))
        XCTAssertEqual(pane.remoteDeviceID, "d1")
        XCTAssertEqual(pane.project, "remote:d1")
        XCTAssertEqual(pane.label, "Build")
        XCTAssertEqual(pane.group, "g1", "panes of one remote session share its host group")
        XCTAssertEqual(pane.engine, .claude, "the engine badge is the host's")
        XCTAssertEqual(pane.kind, .terminal)
        XCTAssertEqual(controller.workspaceView.focusedPaneID, "s1")
        XCTAssertTrue(ensured.isEmpty, "a remote session is never created or ensured on the local daemon")
        XCTAssertEqual(
            controller.workspaceView.terminalSurface(for: "s1")?.predictiveEchoEnabled, true,
            "predictive echo is on for remote terminals"
        )

        controller.closePane(nil)

        XCTAssertNil(controller.workspaceView.descriptor(for: "s1"))
        XCTAssertTrue(killed.isEmpty, "closing a remote pane detaches; it never kills the host's session")
    }

    @MainActor
    func testOpeningTheSameRemoteSessionTwiceFocusesTheExistingPane() async throws {
        let machines = await makeMachines()
        let controller = makeController(remoteMachines: machines)
        defer { controller.close() }
        controller.sessionEnsurer = { _ in }
        controller.showWindow(nil)
        controller.applyRestoredPanes([])

        controller.openRemoteSession(deviceID: "d1", sessionID: "s1", title: "Build")
        XCTAssertNotNil(controller.startSession(inDirectory: "/a", project: "alpha"))
        XCTAssertNotEqual(controller.workspaceView.focusedPaneID, "s1")

        controller.openRemoteSession(deviceID: "d1", sessionID: "s1", title: "Build")

        XCTAssertEqual(controller.workspaceView.focusedPaneID, "s1")
        XCTAssertEqual(controller.workspaceView.allPaneIDs.filter { $0 == "s1" }.count, 1)
    }

    @MainActor
    func testAnOfflineMachineOpensNothing() async throws {
        RemoteRelayStubProtocol.handler = { _ in (200, "[]") }
        let relay = RelayClient(
            baseURL: URL(string: "http://127.0.0.1:1")!,
            session: RemoteRelayStubProtocol.session(),
            accessToken: { "tok" }
        )
        let machines = RemoteMachinesModel(relay: relay, makeConnection: { _ in FakeRemoteConnection() }, isSignedIn: { true })
        await machines.refresh()
        let controller = makeController(remoteMachines: machines)
        defer { controller.close() }
        controller.showWindow(nil)

        controller.openRemoteSession(deviceID: "d1", sessionID: "s1", title: "Build")

        XCTAssertNil(controller.workspaceView.descriptor(for: "s1"))
    }

    /// Remote panes are this window's view of another machine's sessions,
    /// not its own: neither the `layout` row nor the `remote_control`
    /// projection may ever carry one.
    @MainActor
    func testRemotePanesAreNeverPersisted() async throws {
        let machines = await makeMachines()
        let controller = makeController(remoteMachines: machines)
        defer { controller.close() }
        var writes: [(String, String)] = []
        controller.settingsWriter = { writes.append(($0, $1)) }
        controller.sessionEnsurer = { _ in }
        controller.showWindow(nil)
        controller.applyRestoredPanes([])
        controller.toggleRemoteControl(workspaceID: "remote:d1")
        writes.removeAll()

        controller.openRemoteSession(deviceID: "d1", sessionID: "s1", title: "Build")
        XCTAssertNotNil(controller.startSession(inDirectory: "/a", project: "alpha"))

        let layout = try XCTUnwrap(writes.last { $0.0 == SettingsKey.layout }?.1)
        XCTAssertTrue(layout.contains("alpha"), "the local session is persisted as ever: \(layout)")
        XCTAssertFalse(layout.contains("s1"), "the layout row must not carry a remote pane: \(layout)")
        XCTAssertFalse(layout.contains("remote:d1"))
        for (key, value) in writes where key == SettingsKey.remoteControl {
            XCTAssertFalse(value.contains("s1"), "the projection must not re-share a remote session: \(value)")
        }
    }

    @MainActor
    func testARemotePanesHoverCardNamesTheMachine() async throws {
        let machines = await makeMachines()
        let controller = makeController(remoteMachines: machines)
        defer { controller.close() }
        controller.sessionEnsurer = { _ in }
        controller.showWindow(nil)
        controller.applyRestoredPanes([])
        controller.openRemoteSession(deviceID: "d1", sessionID: "s1", title: "Build")

        let card = try XCTUnwrap(controller.hoverCardModel(for: .pane("s1")))

        XCTAssertEqual(card.meta, "Remote · Studio")
        XCTAssertEqual(card.title, "Build")
    }

    /// The engine badge's menu switches a terminal's *local* process; a
    /// remote pane has none to switch.
    @MainActor
    func testARemotePaneRefusesAnEngineSwitch() async throws {
        let machines = await makeMachines()
        let controller = makeController(remoteMachines: machines)
        defer { controller.close() }
        controller.sessionEnsurer = { _ in }
        controller.sessionKiller = { _ in XCTFail("a remote pane must never be killed") }
        controller.showWindow(nil)
        controller.applyRestoredPanes([])
        controller.openRemoteSession(deviceID: "d1", sessionID: "s1", title: "Build")

        XCTAssertFalse(controller.replaceEngine("s1", with: .codex))
        XCTAssertEqual(controller.workspaceView.descriptor(for: "s1")?.engine, .claude)
        XCTAssertTrue(controller.engineMenu(for: "s1").items.allSatisfy { !$0.isEnabled })
    }

    /// ⌘T / ⇧⌘T / ⇧⌘E seed the new pane from the focused one — its group,
    /// project and cwd. Seeded from a remote pane that would put a *local*
    /// shell into another machine's session, so a remote pane offers none of
    /// the three.
    @MainActor
    func testARemotePaneOpensNoSiblingPanes() async throws {
        let machines = await makeMachines()
        let controller = makeController(remoteMachines: machines)
        defer { controller.close() }
        controller.sessionEnsurer = { _ in }
        controller.showWindow(nil)
        controller.applyRestoredPanes([])
        controller.openRemoteSession(deviceID: "d1", sessionID: "s1", title: "Build")
        XCTAssertEqual(controller.workspaceView.focusedPaneID, "s1")
        let before = controller.workspaceView.allPaneIDs
        controller.sessionEnsurer = { _ in XCTFail("no local session may be started beside a remote pane") }

        XCTAssertFalse(controller.newPane(in: nil))
        XCTAssertFalse(controller.newBrowser(in: nil))
        XCTAssertFalse(controller.newEditor(in: nil))
        XCTAssertEqual(controller.workspaceView.allPaneIDs, before)
        for selector in ["newTerminalPane:", "newBrowserPane:", "newEditorPane:"] {
            let item = NSMenuItem(title: "", action: Selector(selector), keyEquivalent: "")
            XCTAssertFalse(controller.validateMenuItem(item), "\(selector) must be greyed out on a remote pane")
        }
    }

    func testLocalPanesHaveNoRemoteDevice() {
        XCTAssertNil(PaneDescriptor(sessionID: "local", group: "g").remoteDeviceID)
    }
}
