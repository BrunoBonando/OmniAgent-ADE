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

/// `RemoteMachinesModel` — the viewer side's device list (2026-09-01 remote
/// environment sharing spec §6/§10). Task 29 deleted the eager per-device
/// dialing: the model now does nothing but poll `RelayClient.listDevices()`
/// and turn the answer into `machines`/`offlineMachineNames`. No socket is
/// ever opened by a poll — `sessionConnection(for:)` is the only thing that
/// builds one, and only when asked to, for `connectRemote(to:)` to dial.
final class RemoteMachinesModelTests: XCTestCase {
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

    /// A connection factory that never opens a socket — every test here is
    /// about the device list, not the transport.
    private func makeModel(
        relay: RelayClient,
        isSignedIn: @escaping () -> Bool = { true },
        refreshSession: @escaping () async -> Void = {}
    ) -> RemoteMachinesModel {
        RemoteMachinesModel(
            relay: relay,
            makeConnection: { url in SessionConnection(transport: .webSocket(url, bearer: { nil }), reconnectDelay: 60) },
            isSignedIn: isSignedIn,
            refreshSession: refreshSession
        )
    }

    // MARK: - Polling

    /// Online devices become `machines`; nothing is dialled to get there.
    func testOnlineDevicesBecomeMachinesWithNoDialing() async throws {
        answer(Self.studioOnline, Self.airOffline)
        var changes = 0
        let model = makeModel(relay: makeRelay())
        model.onChange = { changes += 1 }

        await model.refresh()

        XCTAssertEqual(model.machines, [RemoteMachine(deviceID: "d1", name: "Studio")])
        XCTAssertEqual(model.offlineMachineNames, ["Air"])
        XCTAssertEqual(changes, 1)
    }

    func testMachinesAreSortedByName() async throws {
        answer(Self.studioOnline, Self.airOnline)
        let model = makeModel(relay: makeRelay())

        await model.refresh()

        XCTAssertEqual(model.machines.map(\.name), ["Air", "Studio"])
    }

    /// `onChange` says something changed — an identical poll answer is not
    /// news.
    func testAnUnchangedPollDoesNotFireOnChange() async throws {
        answer(Self.studioOnline)
        let model = makeModel(relay: makeRelay())
        var changes = 0
        model.onChange = { changes += 1 }

        await model.refresh()
        await model.refresh()

        XCTAssertEqual(changes, 1)
    }

    /// A device going offline moves from `machines` to `offlineMachineNames`
    /// rather than vanishing — a known machine that cannot be connected to
    /// right now is still worth naming.
    func testADeviceGoingOfflineMovesToTheOfflineList() async throws {
        answer(Self.studioOnline)
        let model = makeModel(relay: makeRelay())
        await model.refresh()
        XCTAssertEqual(model.machines.map(\.name), ["Studio"])

        answer(Self.studioOffline)
        await model.refresh()

        XCTAssertTrue(model.machines.isEmpty)
        XCTAssertEqual(model.offlineMachineNames, ["Studio"])
    }

    // MARK: - Failure modes

    /// A relay outage is not an error the user sees: the last answer stands
    /// until the relay is back (spec §6, "Relay restart / Core deploy").
    func testARelayOutageKeepsTheLastAnswer() async throws {
        answer(Self.studioOnline)
        let model = makeModel(relay: makeRelay())
        await model.refresh()

        RemoteRelayStubProtocol.handler = { _ in (503, #"{"detail":"deploying"}"#) }
        await model.refresh()

        XCTAssertEqual(model.machines.map(\.name), ["Studio"])
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
        let model = makeModel(relay: makeRelay(), refreshSession: { refreshes += 1 })

        await model.refresh()

        XCTAssertEqual(refreshes, 1)
        XCTAssertEqual(RemoteRelayStubProtocol.requests.count, 2)
        XCTAssertEqual(model.machines.map(\.name), ["Studio"])
    }

    func testARelayUnauthorizedThatStaysUnauthorizedGivesUpAfterOneRetry() async throws {
        RemoteRelayStubProtocol.handler = { _ in (401, #"{"detail":"expired"}"#) }
        var refreshes = 0
        let model = makeModel(relay: makeRelay(), refreshSession: { refreshes += 1 })

        await model.refresh()

        XCTAssertEqual(refreshes, 1)
        XCTAssertEqual(RemoteRelayStubProtocol.requests.count, 2, "one retry, not a loop")
        XCTAssertTrue(model.machines.isEmpty)
    }

    func testSignedOutClears() async throws {
        answer(Self.studioOnline)
        var signedIn = true
        let model = makeModel(relay: makeRelay(), isSignedIn: { signedIn })
        await model.refresh()
        XCTAssertEqual(model.machines.count, 1)
        let requestsBefore = RemoteRelayStubProtocol.requests.count

        signedIn = false
        await model.refresh()

        XCTAssertTrue(model.machines.isEmpty)
        XCTAssertEqual(RemoteRelayStubProtocol.requests.count, requestsBefore, "signed out, the relay is not even asked")
    }

    func testStopClears() async throws {
        answer(Self.studioOnline)
        let model = makeModel(relay: makeRelay())
        await model.refresh()

        await MainActor.run { model.stop() }

        XCTAssertTrue(model.machines.isEmpty)
        XCTAssertFalse(model.isRunning)
    }

    /// `stop()` (or a log-out) while a poll's relay request is in flight:
    /// the answer that lands afterwards is for a model that no longer
    /// exists, and must not repopulate `machines`.
    func testStopMidPollDropsThePollsAnswer() async throws {
        let gate = DispatchSemaphore(value: 0)
        RemoteRelayStubProtocol.handler = { _ in
            gate.wait()
            return (200, "[\(Self.studioOnline)]")
        }
        let model = makeModel(relay: makeRelay())

        let poll = Task { await model.refresh() }
        for _ in 0..<500 where RemoteRelayStubProtocol.requests.isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(RemoteRelayStubProtocol.requests.isEmpty, "the poll never reached the relay")
        await MainActor.run { model.stop() }
        gate.signal()
        await poll.value

        XCTAssertTrue(model.machines.isEmpty)
    }

    /// This Mac's own relay device is on the account's list too; it must
    /// never be listed, online or offline.
    func testThisMacsOwnDeviceIsNeverListed() async throws {
        answer(Self.studioOnline, Self.airOnline)
        let model = makeModel(relay: makeRelay())
        model.localDeviceID = "d1"

        await model.refresh()

        XCTAssertEqual(model.machines.map(\.name), ["Air"])
    }

    /// The token row can land after the first poll (it is read over the
    /// daemon socket); a device already listed under the old id is dropped
    /// the moment the id arrives, without waiting for the next poll.
    func testLocalDeviceIDArrivingLateDropsAnAlreadyListedDevice() async throws {
        answer(Self.studioOnline)
        let model = makeModel(relay: makeRelay())
        await model.refresh()
        XCTAssertEqual(model.machines.map(\.name), ["Studio"])

        model.localDeviceID = "d1"

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
            makeConnection: { url in SessionConnection(transport: .webSocket(url, bearer: { nil }), reconnectDelay: 60) },
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
        let model = makeModel(relay: makeRelay(), refreshSession: { refreshes += 1 })

        await model.refresh()
        await model.refresh()

        XCTAssertEqual(refreshes, 1, "the second poll inside the window reuses the first refresh")
        XCTAssertEqual(RemoteRelayStubProtocol.requests.count, 4, "both polls still retry once")
    }

    func testStartPollsAtOnceAndAgainOnTheInterval() async throws {
        answer(Self.studioOnline)
        let model = RemoteMachinesModel(
            relay: makeRelay(),
            pollInterval: 0.05,
            makeConnection: { url in SessionConnection(transport: .webSocket(url, bearer: { nil }), reconnectDelay: 60) },
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
    }

    // MARK: - Connecting on demand

    /// `sessionConnection(for:)` is the only thing that ever builds a
    /// socket, and it does so only for a device the last poll reported
    /// online — not before, and not for one it does not know about (Task 29,
    /// "stop the eager dialing").
    func testSessionConnectionOnlyBuildsOneForAKnownOnlineDevice() async throws {
        answer(Self.studioOnline, Self.airOffline)
        var made: [URL] = []
        let model = RemoteMachinesModel(
            relay: makeRelay(),
            makeConnection: { url in
                made.append(url)
                return SessionConnection(transport: .webSocket(url, bearer: { nil }), reconnectDelay: 60)
            },
            isSignedIn: { true }
        )
        XCTAssertNil(model.sessionConnection(for: "d1"), "nothing dialled before a poll has even run")
        XCTAssertTrue(made.isEmpty)

        await model.refresh()
        XCTAssertTrue(made.isEmpty, "the poll itself opens no socket")

        XCTAssertNotNil(model.sessionConnection(for: "d1"))
        XCTAssertEqual(made.map(\.absoluteString), ["wss://relay.test/v1/viewer/d1"])
        XCTAssertNil(model.sessionConnection(for: "d2"), "offline — nothing to dial")
        XCTAssertNil(model.sessionConnection(for: "d3"), "unknown — nothing to dial")
    }

    /// Every call is a fresh connection — nothing is retained between them,
    /// since only one remote session is ever live at a time (the daemon's
    /// own one-lease-per-machine rule) and the window's `active` box is what
    /// holds the connection for as long as it is actually in use.
    func testEveryCallBuildsAFreshConnection() async throws {
        answer(Self.studioOnline)
        var made = 0
        let model = RemoteMachinesModel(
            relay: makeRelay(),
            makeConnection: { url in
                made += 1
                return SessionConnection(transport: .webSocket(url, bearer: { nil }), reconnectDelay: 60)
            },
            isSignedIn: { true }
        )
        await model.refresh()

        _ = model.sessionConnection(for: "d1")
        _ = model.sessionConnection(for: "d1")

        XCTAssertEqual(made, 2)
    }

    // MARK: - Lookup

    func testMachineForDeviceID() async throws {
        answer(Self.studioOnline)
        let model = makeModel(relay: makeRelay())
        await model.refresh()

        XCTAssertEqual(model.machine(for: "d1"), RemoteMachine(deviceID: "d1", name: "Studio"))
        XCTAssertNil(model.machine(for: "unknown"))
    }
}
