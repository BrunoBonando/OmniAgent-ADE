import XCTest
import Network
@testable import OmniAgent

final class SessionConnectionWebSocketTests: XCTestCase {
    /// A one-shot WebSocket server that answers the first frame it receives
    /// (Hello) with HelloAck, and can push server frames of its own
    /// afterwards.
    ///
    /// Constructed with `rejectWith:` it becomes the opposite: a plain-TCP
    /// listener that refuses every upgrade with that HTTP status. Plain TCP
    /// on purpose — `NWProtocolWebSocket.Response(status: .reject)` writes a
    /// `400 Bad Request` and holds the socket open, so it can neither
    /// produce the status the app keys on nor make the client fail promptly.
    private final class FakeRelay {
        /// What the upgrade request carried. Filled by the client-request
        /// handler, which `NWListener(using:)` copies out of the options at
        /// creation — so it has to be installed before the listener exists,
        /// which is before `self` is usable; hence a box, not `[weak self]`.
        private final class Handshake {
            let lock = NSLock()
            var authorization: String?
        }
        let listener: NWListener
        var port: UInt16 { listener.port!.rawValue }
        var url: URL { URL(string: "ws://127.0.0.1:\(port)/v1/viewer/dev1")! }
        private let handshake: Handshake
        var receivedAuthorization: String? { handshake.lock.withLock { handshake.authorization } }
        /// `nil` for a relay that accepts the upgrade; otherwise the HTTP
        /// status every dial is refused with.
        private let rejectStatus: Int?
        private let lock = NSLock()
        private var connection: NWConnection?
        private var attemptCount = 0
        private var attemptHandler: (() -> Void)?
        /// Every TCP connection the listener accepted — one per dial,
        /// whether it was upgraded or refused.
        var attempts: Int { lock.withLock { attemptCount } }
        /// Fires on each accepted dial, after `attempts` has been bumped.
        var onAttempt: (() -> Void)? {
            get { lock.withLock { attemptHandler } }
            set { lock.withLock { attemptHandler = newValue } }
        }
        init(rejectWith rejectStatus: Int? = nil) throws {
            let handshake = Handshake()
            self.handshake = handshake
            self.rejectStatus = rejectStatus
            if rejectStatus != nil {
                listener = try NWListener(using: .tcp, on: .any)
                return
            }
            let params = NWParameters.tcp
            let ws = NWProtocolWebSocket.Options()
            ws.autoReplyPing = true
            ws.setClientRequestHandler(.global()) { _, headers in
                let value = headers.first { $0.name.lowercased() == "authorization" }?.value
                handshake.lock.withLock { handshake.authorization = value }
                return NWProtocolWebSocket.Response(status: .accept, subprotocol: nil)
            }
            params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
            listener = try NWListener(using: params, on: .any)
        }
        /// `onReady` is installed before `start()`: NWListener never re-delivers
        /// a state it reached while nobody was listening.
        func start(onReady: @escaping () -> Void) {
            listener.stateUpdateHandler = { if case .ready = $0 { onReady() } }
            listener.newConnectionHandler = { [weak self] conn in
                guard let self else { conn.cancel(); return }
                let handler: (() -> Void)? = self.lock.withLock {
                    self.attemptCount += 1
                    return self.attemptHandler
                }
                conn.start(queue: .global())
                if let status = self.rejectStatus {
                    conn.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { _, _, _, _ in
                        let response = "HTTP/1.1 \(status) \(Self.reason(for: status))\r\n"
                            + "Content-Length: 0\r\nConnection: close\r\n\r\n"
                        conn.send(content: Data(response.utf8), completion: .contentProcessed { _ in conn.cancel() })
                    }
                } else {
                    self.lock.withLock { self.connection = conn }
                    self.receive(on: conn)
                }
                handler?()
            }
            listener.start(queue: .global())
        }
        /// Blocking convenience: returns once the listener has a port, so
        /// `url` is usable on the next line.
        func start() {
            let ready = DispatchSemaphore(value: 0)
            start { ready.signal() }
            _ = ready.wait(timeout: .now() + 5)
        }
        /// Sends one server frame down the live WebSocket — how a daemon
        /// push (`SessionResized`, `RemoteViewers`) is simulated.
        func push(kind: MessageKind, json: [String: Any], sequence: UInt64 = 0) {
            let deadline = Date().addingTimeInterval(5)
            var conn: NWConnection?
            while conn == nil, Date() < deadline {
                conn = lock.withLock { connection }
                if conn == nil { Thread.sleep(forTimeInterval: 0.01) }
            }
            guard let conn else { return XCTFail("the relay never accepted a connection") }
            let frame = SessionFrame(
                kind: kind,
                requestOrSequence: sequence,
                payload: try! JSONSerialization.data(withJSONObject: json)
            )
            let meta = NWProtocolWebSocket.Metadata(opcode: .binary)
            conn.send(
                content: try! frame.encoded(),
                contentContext: NWConnection.ContentContext(identifier: "push", metadata: [meta]),
                completion: .idempotent
            )
        }
        private static func reason(for status: Int) -> String {
            switch status {
            case 401: return "Unauthorized"
            case 403: return "Forbidden"
            case 503: return "Service Unavailable"
            default: return "Error"
            }
        }
        private func receive(on conn: NWConnection) {
            conn.receiveMessage { [weak self] data, context, _, _ in
                guard let self, let data else { return }
                if let meta = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata,
                   meta.opcode == .binary {
                    var decoder = FrameDecoder()
                    if let frame = try? decoder.append(data).first, frame.kind == .hello {
                        let ack = SessionFrame(kind: .helloAck, requestOrSequence: frame.requestOrSequence,
                                               payload: try! JSONEncoder().encode(["protocol_version": 1]))
                        let m = NWProtocolWebSocket.Metadata(opcode: .binary)
                        conn.send(content: try! ack.encoded(), contentContext: NWConnection.ContentContext(identifier: "ack", metadata: [m]), completion: .idempotent)
                    }
                }
                self.receive(on: conn)
            }
        }
    }

    func testWebSocketTransportCompletesTheHelloHandshake() throws {
        let relay = try FakeRelay()
        addTeardownBlock { relay.listener.cancel() }
        let ready = expectation(description: "listener ready")
        relay.start { ready.fulfill() }
        wait(for: [ready], timeout: 5)

        let url = URL(string: "ws://127.0.0.1:\(relay.port)/v1/viewer/dev1")!
        let connection = SessionConnection(transport: .webSocket(url, bearer: { "viewer-token" }), callbackQueue: .main)
        let connected = expectation(description: "connected")
        connection.onStateChange = { state in if case .connected = state { connected.fulfill() } }
        connection.connect()
        wait(for: [connected], timeout: 5)
        XCTAssertTrue(connection.isRemote)
        XCTAssertEqual(relay.receivedAuthorization, "Bearer viewer-token")
        connection.disconnect()
    }

    /// A **401** on the upgrade means the credentials are wrong, and
    /// retrying with the same bearer four times a second forever would only
    /// hammer Cloudflare: the connection reports `.unauthorized` once and
    /// stops. A later explicit `connect()` (B4, with a fresh bearer) dials
    /// again. (A 403 is a different animal — see
    /// `testA403KeepsReconnecting`.)
    func testUnauthorizedUpgradeReportsOnceAndStopsReconnecting() throws {
        let relay = try FakeRelay(rejectWith: 401)
        addTeardownBlock { relay.listener.cancel() }
        let ready = expectation(description: "listener ready")
        relay.start { ready.fulfill() }
        wait(for: [ready], timeout: 5)

        let connection = SessionConnection(
            transport: .webSocket(relay.url, bearer: { "stale-token" }),
            reconnectDelay: 0.05,
            callbackQueue: .main
        )
        let unauthorized = expectation(description: "unauthorized reported")
        let unauthorizedAgain = expectation(description: "the explicit reconnect is refused too")
        var errors: [Error] = []
        connection.onError = { error in
            errors.append(error)
            guard case .unauthorized? = error as? SessionConnectionError else { return }
            switch errors.count {
            case 1: unauthorized.fulfill()
            case 2: unauthorizedAgain.fulfill()
            default: break
            }
        }
        connection.connect()
        wait(for: [unauthorized], timeout: 5)

        // With a 50 ms reconnect delay, a connection that kept retrying
        // would have dialed ~20 more times by now.
        let quiet = expectation(description: "no further dials")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { quiet.fulfill() }
        wait(for: [quiet], timeout: 5)
        XCTAssertEqual(relay.attempts, 1)
        XCTAssertEqual(errors.count, 1, "\(errors)")

        // B4's "sign in again" path: an explicit connect() starts over —
        // the relay is dialed exactly once more, and refused once more.
        connection.connect()
        wait(for: [unauthorizedAgain], timeout: 5)
        XCTAssertEqual(relay.attempts, 2)
        XCTAssertEqual(errors.count, 2, "\(errors)")
        connection.disconnect()
    }

    /// An unreachable relay is retried with exponential backoff (doubling
    /// from `reconnectDelay`, capped at 30 s), not on the unix socket's fixed
    /// timer. With a 50 ms seed the dials land at 0, 50, 150, 350 and 750 ms
    /// — five in the first second where a fixed delay would make ~20.
    func testRemoteReconnectBacksOffExponentially() throws {
        // Borrow a port the system hands out, then close it: Network
        // framework will not start a listener without a connection handler.
        let closed = try NWListener(using: .tcp, on: .any)
        let ready = expectation(description: "listener ready")
        closed.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        closed.newConnectionHandler = { $0.cancel() }
        closed.start(queue: .global())
        wait(for: [ready], timeout: 5)
        let port = closed.port!.rawValue
        closed.cancel()

        let url = URL(string: "ws://127.0.0.1:\(port)/v1/viewer/dev1")!
        let connection = SessionConnection(
            transport: .webSocket(url, bearer: { nil }),
            reconnectDelay: 0.05,
            callbackQueue: .main
        )
        var dials = 0
        connection.onStateChange = { state in if case .connecting = state { dials += 1 } }
        connection.connect()
        let window = expectation(description: "one second of retries")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { window.fulfill() }
        wait(for: [window], timeout: 5)
        connection.disconnect()
        XCTAssertGreaterThanOrEqual(dials, 3, "the relay must still be retried at all")
        XCTAssertLessThanOrEqual(dials, 8, "a fixed 50 ms delay would have dialed ~20 times")
    }

    /// The host owns the grid (phase 2 §1): the daemon pushes
    /// `SessionResized` on attach and on every accepted resize, and the
    /// viewer re-pins its scaled render to whatever it says.
    func testASessionResizedPushIsDeliveredAsASizeCallback() throws {
        let relay = try FakeRelay()
        addTeardownBlock { relay.listener.cancel() }
        relay.start()

        let connection = SessionConnection(
            transport: .webSocket(relay.url, bearer: { "viewer-token" }),
            callbackQueue: .main
        )
        let connected = expectation(description: "connected")
        connection.onStateChange = { state in if case .connected = state { connected.fulfill() } }
        connection.connect()
        wait(for: [connected], timeout: 5)

        let sized = expectation(description: "size")
        connection.onSessionSize = { id, cols, rows in
            XCTAssertEqual([id, String(cols), String(rows)], ["s1", "120", "40"])
            sized.fulfill()
        }
        relay.push(kind: .sessionResized, json: ["id": "s1", "cols": 120, "rows": 40])
        wait(for: [sized], timeout: 5)
        connection.disconnect()
    }

    /// The presence roster (phase 2 §5) arrives as a push on local
    /// connections; the daemon's keys are snake_case.
    func testARemoteViewersPushIsDeliveredAsARoster() throws {
        let relay = try FakeRelay()
        addTeardownBlock { relay.listener.cancel() }
        relay.start()

        let connection = SessionConnection(
            transport: .webSocket(relay.url, bearer: { "viewer-token" }),
            callbackQueue: .main
        )
        let connected = expectation(description: "connected")
        connection.onStateChange = { state in if case .connected = state { connected.fulfill() } }
        connection.connect()
        wait(for: [connected], timeout: 5)

        let roster = expectation(description: "roster")
        connection.onRemoteViewers = { viewers in
            XCTAssertEqual(
                viewers,
                [
                    RemoteViewer(
                        viewerID: "v1",
                        machineName: "Bruno's MacBook",
                        sessions: ["p1", "p2"],
                        since: "2026-08-31T10:00:00Z"
                    )
                ]
            )
            roster.fulfill()
        }
        relay.push(
            kind: .remoteViewers,
            json: [
                "viewers": [
                    [
                        "viewer_id": "v1",
                        "machine_name": "Bruno's MacBook",
                        "sessions": ["p1", "p2"],
                        "since": "2026-08-31T10:00:00Z",
                    ]
                ]
            ]
        )
        wait(for: [roster], timeout: 5)
        connection.disconnect()
    }

    /// Only a token refusal may park a connection. The relay answers 403 for
    /// "that device's control channel is not registered yet" — a transient
    /// race, not a bad bearer — and 5xx for its own outages.
    func testOnlyA401ParksTheConnection() {
        XCTAssertFalse(SessionConnection.isTokenRefusal(status: 403))
        XCTAssertFalse(SessionConnection.isTokenRefusal(status: 503))
        XCTAssertTrue(SessionConnection.isTokenRefusal(status: 401))
    }

    /// A 403 is "the host is not registered yet", not "your token is bad":
    /// it must keep retrying rather than blind the viewer to that Mac until
    /// the app is relaunched.
    func testA403KeepsReconnecting() throws {
        let relay = try FakeRelay(rejectWith: 403)
        addTeardownBlock { relay.listener.cancel() }
        relay.start()

        let connection = SessionConnection(
            transport: .webSocket(relay.url, bearer: { "t" }),
            callbackQueue: .main
        )
        let retried = expectation(description: "second attempt")
        retried.assertForOverFulfill = false
        relay.onAttempt = { if relay.attempts >= 2 { retried.fulfill() } }
        connection.connect()
        wait(for: [retried], timeout: 8)   // 250 ms then 500 ms of backoff
        connection.disconnect()
    }
}
