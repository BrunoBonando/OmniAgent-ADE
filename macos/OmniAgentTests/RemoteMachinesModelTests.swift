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
    /// What this socket does when the model dials it. Silence by default —
    /// a dial that neither lands nor fails, which is every test written
    /// before the state of the socket mattered.
    private var dialOutcome: (() -> Void)?

    /// The relay refusing the upgrade *without* refusing the bearer — its
    /// 403 for "that device's control channel is not registered yet", the
    /// race a viewer loses whenever it polls before the host's daemon has
    /// opened its control socket. The real connection reports `.disconnected`
    /// and keeps retrying on its own backoff (`SessionConnection`'s
    /// `isTokenRefusal`), so the model sees a socket that is simply down.
    func simulateRefusedDial() {
        dialOutcome = { [weak self] in self?.onStateChange?(.disconnected) }
    }

    /// A real 401: the relay looked at the bearer and refused it. The
    /// connection closes — `.disconnected` first, then the error, the order
    /// `closeConnection(error:)` reports them in — and stops retrying.
    func simulateTokenRefusal() {
        dialOutcome = { [weak self] in
            self?.onStateChange?(.disconnected)
            self?.onError?(SessionConnectionError.unauthorized)
        }
    }

    func connect() {
        connectCalls += 1
        dialOutcome?()
    }

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
        XCTAssertEqual(model.machines.first?.projection.workspaces.first?.sessions.map(\.label), ["Build"])
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
    /// retries (`SessionConnectionError.unauthorized`). The model re-dials
    /// the same object only once the bearer has *changed* — a REST poll
    /// succeeding proves nothing about the upgrade the relay just refused.
    func testAnUnauthorizedConnectionIsReconnectedOnceTheBearerChanges() async throws {
        answer(Self.studioOnline)
        var made = 0
        var bearer: String? = "tok1"
        let fake = FakeRemoteConnection()
        let model = RemoteMachinesModel(
            relay: makeRelay(),
            makeConnection: { _ in made += 1; return fake },
            isSignedIn: { true },
            currentBearer: { bearer }
        )
        await model.refresh()
        XCTAssertEqual(fake.connectCalls, 1)

        fake.onError?(SessionConnectionError.unauthorized)
        await Task.yield()
        bearer = "tok2"
        await model.refresh()

        XCTAssertEqual(made, 1)
        XCTAssertEqual(fake.connectCalls, 2)
    }

    /// The negative twin: the same bearer would only be refused again, so a
    /// poll that finds it unchanged leaves the connection alone.
    func testAnUnauthorizedConnectionIsNotReDialledWhileTheBearerIsUnchanged() async throws {
        answer(Self.studioOnline)
        let fake = FakeRemoteConnection()
        let model = RemoteMachinesModel(
            relay: makeRelay(),
            makeConnection: { _ in fake },
            isSignedIn: { true },
            currentBearer: { "tok1" }
        )
        await model.refresh()
        fake.onError?(SessionConnectionError.unauthorized)
        await Task.yield()

        await model.refresh()
        await model.refresh()

        XCTAssertEqual(fake.connectCalls, 1, "same bearer, same refusal — do not dial")
    }

    /// Phase 1's loudest defect: the relay answers **403** while the host's
    /// daemon is still registering its control channel, and "re-dial only
    /// when the bearer changed" — which in-session it does not for fifteen
    /// minutes — left that one early refusal stranding the machine until the
    /// app was relaunched. An online device whose socket is down is dialled
    /// again by every poll; the connection's own backoff owns the rate.
    func testAnOnlineDeviceWithNoLiveConnectionIsAlwaysRedialled() async throws {
        answer(Self.studioOnline)
        let fake = FakeRemoteConnection()
        fake.simulateRefusedDial()
        let model = RemoteMachinesModel(
            relay: makeRelay(),
            makeConnection: { _ in fake },
            isSignedIn: { true },
            currentBearer: { "same-token" }
        )

        await model.refresh()
        XCTAssertEqual(fake.connectCalls, 1)
        await model.refresh()

        XCTAssertEqual(fake.connectCalls, 2, "a refusal must not strand the machine forever")
        XCTAssertFalse(model.didRequestTokenRefresh, "the bearer was never the problem")
    }

    /// The negative twin, and the one refusal re-dialling cannot mend: a
    /// real 401 is parked on the bearer that was refused — but a fresh one
    /// is asked for on the spot, rather than waiting the quarter hour for
    /// `listDevices()` to meet the same 401 itself.
    func testATokenRefusalStillWaitsForANewTokenAndAsksForOneAtOnce() async throws {
        answer(Self.studioOnline)
        let fake = FakeRemoteConnection()
        fake.simulateTokenRefusal()
        var refreshes = 0
        let model = RemoteMachinesModel(
            relay: makeRelay(),
            makeConnection: { _ in fake },
            isSignedIn: { true },
            refreshSession: { refreshes += 1 },
            currentBearer: { "same-token" }
        )

        await model.refresh()
        await model.refresh()

        XCTAssertEqual(fake.connectCalls, 1, "a refused token is not retried with the same token")
        XCTAssertTrue(model.didRequestTokenRefresh, "…but a fresh one is asked for immediately")
        for _ in 0..<200 where refreshes == 0 {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(refreshes, 1, "the socket's 401 refreshes the session itself")
    }

    /// `stop()` (or a log-out) while a poll's relay request is in flight:
    /// the answer that lands afterwards is for a model that no longer
    /// exists, and must not rebuild connections nobody will ever stop again.
    func testStopMidPollDropsThePollsAnswer() async throws {
        let gate = DispatchSemaphore(value: 0)
        RemoteRelayStubProtocol.handler = { _ in
            gate.wait()
            return (200, "[\(Self.studioOnline)]")
        }
        let fake = FakeRemoteConnection()
        let model = RemoteMachinesModel(relay: makeRelay(), makeConnection: { _ in fake }, isSignedIn: { true })

        let poll = Task { await model.refresh() }
        for _ in 0..<500 where RemoteRelayStubProtocol.requests.isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(RemoteRelayStubProtocol.requests.isEmpty, "the poll never reached the relay")
        await MainActor.run { model.stop() }
        gate.signal()
        await poll.value

        XCTAssertNil(model.retainedConnection(for: "d1"), "the parked poll's answer must be dropped")
        XCTAssertEqual(fake.connectCalls, 0, "no socket may be opened after stop()")
        XCTAssertTrue(model.machines.isEmpty)
    }

    /// This Mac's own relay device is on the account's list too; dialling it
    /// would be a WebSocket to the daemon already behind this very window.
    func testThisMacsOwnDeviceIsNeverListedOrDialled() async throws {
        answer(Self.studioOnline, Self.airOnline)
        var made: [URL] = []
        let model = RemoteMachinesModel(
            relay: makeRelay(),
            makeConnection: { url in made.append(url); return FakeRemoteConnection() },
            isSignedIn: { true }
        )
        model.localDeviceID = "d1"

        await model.refresh()

        XCTAssertEqual(model.machines.map(\.name), ["Air"])
        XCTAssertNil(model.connection(for: "d1"))
        XCTAssertEqual(made.map(\.absoluteString), ["wss://relay.test/v1/viewer/d2"])
    }

    /// The token row can land after the first poll (it is read over the
    /// daemon socket); a connection already dialled to ourselves is dropped
    /// the moment the id arrives.
    func testLocalDeviceIDArrivingLateDropsAnAlreadyDialledConnection() async throws {
        answer(Self.studioOnline)
        let fake = FakeRemoteConnection()
        let model = RemoteMachinesModel(relay: makeRelay(), makeConnection: { _ in fake }, isSignedIn: { true })
        await model.refresh()
        XCTAssertNotNil(model.connection(for: "d1"))

        model.localDeviceID = "d1"

        XCTAssertEqual(fake.disconnectCalls, 1)
        XCTAssertNil(model.retainedConnection(for: "d1"))
        XCTAssertTrue(model.machines.isEmpty)
    }

    /// The window reads the id out of the daemon's `relay_device_token` row;
    /// only that one field — the token itself stays the daemon's.
    func testDeviceIDInTokenRow() {
        XCTAssertEqual(
            RemoteMachinesModel.deviceID(
                inTokenRow: #"{"device_id":"d9","name":"Mac","relay_url":"https://r","token":"secret"}"#
            ),
            "d9"
        )
        XCTAssertNil(RemoteMachinesModel.deviceID(inTokenRow: nil))
        XCTAssertNil(RemoteMachinesModel.deviceID(inTokenRow: ""))
        XCTAssertNil(RemoteMachinesModel.deviceID(inTokenRow: "not json"))
        XCTAssertNil(RemoteMachinesModel.deviceID(inTokenRow: "{}"))
    }

    /// A `start()` poke that lands while a poll is in flight — "the bearer
    /// just arrived" — is honoured once that poll finishes, not dropped.
    func testAPokeDuringAnInFlightPollIsHonouredAfterIt() async throws {
        let gate = DispatchSemaphore(value: 0)
        RemoteRelayStubProtocol.handler = { _ in
            if RemoteRelayStubProtocol.requests.count == 1 { gate.wait() }
            return (200, "[]")
        }
        let model = RemoteMachinesModel(
            relay: makeRelay(),
            pollInterval: 3600,
            makeConnection: { _ in FakeRemoteConnection() },
            isSignedIn: { true }
        )

        await MainActor.run { model.start() }
        for _ in 0..<500 where RemoteRelayStubProtocol.requests.isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(RemoteRelayStubProtocol.requests.count, 1)
        await MainActor.run { model.start() }
        gate.signal()
        for _ in 0..<500 where RemoteRelayStubProtocol.requests.count < 2 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        await MainActor.run { model.stop() }

        XCTAssertGreaterThanOrEqual(RemoteRelayStubProtocol.requests.count, 2, "the poke's poll must follow")
    }

    /// Two polls that both meet a 401 inside the coalesce window share one
    /// session refresh — the refresh cookie rotates on every use, and two
    /// concurrent refreshes would spend the same cookie twice.
    func testConcurrentUnauthorizedPollsShareOneSessionRefresh() async throws {
        RemoteRelayStubProtocol.handler = { _ in (401, #"{"detail":"expired"}"#) }
        var refreshes = 0
        let model = RemoteMachinesModel(
            relay: makeRelay(),
            makeConnection: { _ in FakeRemoteConnection() },
            isSignedIn: { true },
            refreshSession: { refreshes += 1 }
        )

        await model.refresh()
        await model.refresh()

        XCTAssertEqual(refreshes, 1, "the second poll inside the window reuses the first refresh")
        XCTAssertEqual(RemoteRelayStubProtocol.requests.count, 4, "both polls still retry once")
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
    /// A schema-v2 row — the shape phase 2 ships: one session ("g1") with two
    /// panes in it, each running its own engine. The pane ids are what a
    /// viewer attaches to; the session id is the host's grouping, and the
    /// only place a viewer can learn that two panes belong together.
    /// (`RemoteMachinesModelTests.projectionA` stays v1 on purpose — it is
    /// what pins the back-compatibility path.)
    private static let projection = #"{"version":2,"workspaces":[{"id":"/a","name":"A","tint":null,"order":0,"sessions":[{"id":"g1","label":"Build · host","order":0,"panes":[{"id":"e1","title":"Notes · host","engine":"shell","kind":"editor","order":0},{"id":"s1","title":"Build · host","engine":"claude","kind":"terminal","order":1},{"id":"s2","title":"Docs · host","engine":"codex","kind":"terminal","order":2}]}]}]}"#

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
        settingsClient: SettingsClient? = nil,
        defaults: UserDefaults = .standard
    ) -> WorkspaceWindowController {
        WorkspaceWindowController(
            connection: SessionConnection(
                socketURL: URL(fileURLWithPath: "/tmp/omniagent-remote-panes-test.sock")
            ),
            panes: [],
            remoteMachines: remoteMachines,
            settingsClient: settingsClient,
            authDefaults: defaults
        )
    }

    /// Polling follows the account: nothing until the launch gate has
    /// answered (the window-install seed reads a mirror that is only a
    /// guess), on when it answers signed in, off — with every remote pane
    /// closed and the model cleared — on log out.
    ///
    /// The mirror is a throwaway suite, threaded through the controller's
    /// `defaults:` seam so neither the read (`presentLaunchGate`) nor the
    /// coordinator's own writes ever touch the real app's domain.
    @MainActor
    func testRemotePollingFollowsTheAccount() async throws {
        let suite = "digital.bruno.omniagent.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: AuthGate.signedInDefaultsKey)

        let machines = await makeMachines()
        let controller = makeController(
            remoteMachines: machines,
            settingsClient: FakeSettingsClient(),
            defaults: defaults
        )
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

        controller.presentLaunchGate(defaults: defaults) {}
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
        XCTAssertEqual(pane.label, "Build · host", "the host's own title for the pane, not the caller's")
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

    /// The whole point of projecting the host's tree: a viewer opens two
    /// panes of one remote session and gets one session here too — same
    /// group, so they share a grid — with each pane's own engine on its own
    /// badge. The id a viewer holds is a *pane* id, so a lookup that matched
    /// the session's id instead would find nothing and quietly hand every
    /// remote pane its own group and a Shell badge.
    @MainActor
    func testTwoPanesOfOneRemoteSessionShareItsGroupAndKeepTheirEngines() async throws {
        let machines = await makeMachines()
        let controller = makeController(remoteMachines: machines)
        defer { controller.close() }
        controller.sessionEnsurer = { _ in }
        controller.showWindow(nil)
        controller.applyRestoredPanes([])

        controller.openRemoteSession(deviceID: "d1", sessionID: "s1", title: "Build")
        controller.openRemoteSession(deviceID: "d1", sessionID: "s2", title: "Docs")

        let first = try XCTUnwrap(controller.workspaceView.descriptor(for: "s1"))
        let second = try XCTUnwrap(controller.workspaceView.descriptor(for: "s2"))
        XCTAssertEqual(first.group, "g1", "the host's session group, not the pane id")
        XCTAssertEqual(second.group, first.group, "two panes of one host session share a grid here too")
        // The fixture's names differ from the `title:` arguments above on
        // purpose: these assertions are about what the *host* calls things,
        // and would pass on the caller's string by accident otherwise.
        XCTAssertEqual(first.groupLabel, "Build · host", "and the session is named what the host names it")
        XCTAssertEqual(first.engine, .claude)
        XCTAssertEqual(second.engine, .codex, "each pane keeps the engine the host runs in it")
        XCTAssertEqual(second.label, "Docs · host", "and its own title")
    }

    /// Only a terminal has a daemon session behind it, so only a terminal is
    /// offered as something to open (the phase-2 spec's §2: other kinds are
    /// projected for structural fidelity). An editor row would build a
    /// terminal pane for an id the daemon knows nothing about — a pane that
    /// opens empty and never attaches. The fixture's session has an editor
    /// **first**, which is exactly the case a "first pane" rule gets wrong.
    @MainActor
    func testTheSpotlightOffersARemoteSessionsTerminalsAndNotItsEditor() async throws {
        let machines = await makeMachines()
        let controller = makeController(remoteMachines: machines)
        defer { controller.close() }
        controller.sessionEnsurer = { _ in }
        controller.showWindow(nil)
        controller.applyRestoredPanes([])

        controller.presentCommandPalette()
        defer { controller.palette.dismiss() }

        let commands = controller.palette.model.commands
        let ids = commands.map(\.id)
        XCTAssertTrue(ids.contains("remote:d1/s1"), "the terminals are rows")
        XCTAssertTrue(ids.contains("remote:d1/s2"))
        XCTAssertFalse(ids.contains("remote:d1/e1"), "the editor is not: \(ids)")
        XCTAssertEqual(
            commands.first { $0.id == "remote-machine:d1" }?.action,
            .openRemoteSession(deviceID: "d1", sessionID: "s1", title: "Build · host"),
            "and the machine row opens its first *terminal*, not its first pane"
        )
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
        writes.removeAll()

        controller.openRemoteSession(deviceID: "d1", sessionID: "s1", title: "Build")
        XCTAssertNotNil(controller.startSession(inDirectory: "/a", project: "alpha"))

        let layout = try XCTUnwrap(writes.last { $0.0 == SettingsKey.layout }?.1)
        XCTAssertTrue(layout.contains("alpha"), "the local session is persisted as ever: \(layout)")
        XCTAssertFalse(layout.contains("s1"), "the layout row must not carry a remote pane: \(layout)")
        XCTAssertFalse(layout.contains("remote:d1"))
        // `remote_control` is not written at all right now: the
        // per-workspace toggle that used to gate `persistRemoteControlProjection`
        // is deleted (2026-09-01 remote environment sharing spec §1) and
        // nothing replaces it yet — that wiring is deliberately parked for a
        // later task. This asserts that current fact directly, rather than
        // a loop over zero elements that would pass no matter what the code
        // did: if a future change starts writing this row again, this
        // fails, and whoever changed it has to update this test on purpose.
        XCTAssertFalse(
            writes.contains { $0.0 == SettingsKey.remoteControl },
            "remote_control has no write path yet; if this fires, wire this test's assertion to the new one"
        )
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
        XCTAssertEqual(card.title, "Build · host", "the host's title for the pane")
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

    /// A remote pane is reachable from the spotlight exactly once — through
    /// the row the relay's projection builds, which says which machine and
    /// workspace it lives on. The palette is built from local panes only, so
    /// the same session can never also appear as an ordinary pane row
    /// subtitled with the raw `remote:<device>` project string.
    @MainActor
    func testARemotePaneIsNotAlsoAnOrdinaryPaletteRow() async throws {
        let machines = await makeMachines()
        let controller = makeController(remoteMachines: machines)
        defer { controller.close() }
        controller.sessionEnsurer = { _ in }
        controller.showWindow(nil)
        controller.applyRestoredPanes([])
        controller.openRemoteSession(deviceID: "d1", sessionID: "s1", title: "Build")
        XCTAssertNotNil(controller.workspaceView.descriptor(for: "s1"))

        controller.presentCommandPalette()
        defer { controller.palette.dismiss() }

        let ids = controller.palette.model.commands.map(\.id)
        XCTAssertTrue(ids.contains("remote:d1/s1"), "the projection's row is how you get there")
        XCTAssertFalse(ids.contains("focus:s1"), "and it is not also a local pane row: \(ids)")
        XCTAssertFalse(
            ids.contains { $0.hasPrefix("session:remote:") },
            "nor a session row named by the raw remote project string: \(ids)"
        )
    }

    /// Session › Kill Session (⌃⌘K) belongs to the machine that owns the
    /// session. `Kill` is off the remote allowlist in the daemon, so the item
    /// would only ever fail — spec §4 says remote panes hide it, so the
    /// surface both greys it out and refuses the action. Interrupt is *not*
    /// gated: it is allowlisted by design.
    @MainActor
    func testARemotePaneHidesKillSession() async throws {
        let machines = await makeMachines()
        let controller = makeController(remoteMachines: machines)
        defer { controller.close() }
        controller.sessionEnsurer = { _ in }
        controller.showWindow(nil)
        controller.applyRestoredPanes([])
        controller.openRemoteSession(deviceID: "d1", sessionID: "s1", title: "Build")

        let remote = try XCTUnwrap(controller.workspaceView.terminalSurface(for: "s1"))
        let kill = NSMenuItem(title: "", action: Selector(("killSession:")), keyEquivalent: "")
        XCTAssertFalse(remote.validateMenuItem(kill), "Kill Session must be greyed out on a remote pane")
        // The same `connection.isRemote` the action's own guard reads.
        XCTAssertTrue(remote.predictiveEchoEnabled, "the pane really is bound to the remote connection")
        remote.killSession(nil)  // refused rather than sent; nothing to observe but a crash

        let interrupt = NSMenuItem(title: "", action: Selector(("interruptSession:")), keyEquivalent: "")
        XCTAssertTrue(remote.validateMenuItem(interrupt), "Interrupt stays: it is on the remote allowlist")

        // The bootstrap pane `applyRestoredPanes([])` planted is this Mac's own.
        let localID = try XCTUnwrap(controller.workspaceView.allPaneIDs.first { $0 != "s1" })
        let local = try XCTUnwrap(controller.workspaceView.terminalSurface(for: localID))
        XCTAssertTrue(local.validateMenuItem(kill), "a local pane keeps Kill Session")
    }

    func testLocalPanesHaveNoRemoteDevice() {
        XCTAssertNil(PaneDescriptor(sessionID: "local", group: "g").remoteDeviceID)
    }
}
