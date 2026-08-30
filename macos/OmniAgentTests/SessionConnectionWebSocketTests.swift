import XCTest
import Network
@testable import OmniAgent

final class SessionConnectionWebSocketTests: XCTestCase {
    /// A one-shot WebSocket server that answers the first frame it receives (Hello) with HelloAck.
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
        private let handshake: Handshake
        var receivedAuthorization: String? { handshake.lock.withLock { handshake.authorization } }
        private var connection: NWConnection?
        init() throws {
            let handshake = Handshake()
            let params = NWParameters.tcp
            let ws = NWProtocolWebSocket.Options()
            ws.autoReplyPing = true
            ws.setClientRequestHandler(.global()) { _, headers in
                let value = headers.first { $0.name.lowercased() == "authorization" }?.value
                handshake.lock.withLock { handshake.authorization = value }
                return NWProtocolWebSocket.Response(status: .accept, subprotocol: nil)
            }
            params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
            self.handshake = handshake
            listener = try NWListener(using: params, on: .any)
        }
        /// `onReady` is installed before `start()`: NWListener never re-delivers
        /// a state it reached while nobody was listening.
        func start(onReady: @escaping () -> Void) {
            listener.stateUpdateHandler = { if case .ready = $0 { onReady() } }
            listener.newConnectionHandler = { [weak self] conn in
                self?.connection = conn
                conn.start(queue: .global())
                self?.receive(on: conn)
            }
            listener.start(queue: .global())
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

    /// A relay that refuses every upgrade with `403 Forbidden` — what
    /// `relay.omni-agent.ai` answers for a signed-out user, an expired
    /// token or a deleted device row. Plain TCP on purpose:
    /// `NWProtocolWebSocket.Response(status: .reject)` writes a
    /// `400 Bad Request` and holds the socket open, so it can neither
    /// produce the status the app keys on nor make the client fail promptly.
    private final class ForbiddingRelay {
        let listener: NWListener
        var port: UInt16 { listener.port!.rawValue }
        private let lock = NSLock()
        private var attempts = 0
        var connectionAttempts: Int { lock.withLock { attempts } }
        init() throws {
            listener = try NWListener(using: .tcp, on: .any)
        }
        func start(onReady: @escaping () -> Void) {
            listener.stateUpdateHandler = { if case .ready = $0 { onReady() } }
            listener.newConnectionHandler = { [weak self] conn in
                self?.lock.withLock { self?.attempts += 1 }
                conn.start(queue: .global())
                conn.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { _, _, _, _ in
                    let response = "HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                    conn.send(content: Data(response.utf8), completion: .contentProcessed { _ in conn.cancel() })
                }
            }
            listener.start(queue: .global())
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

    /// A 401/403 on the upgrade means the credentials are wrong, and
    /// retrying with the same bearer four times a second forever would only
    /// hammer Cloudflare: the connection reports `.unauthorized` once and
    /// stops. A later explicit `connect()` (B4, with a fresh bearer) dials
    /// again.
    func testUnauthorizedUpgradeReportsOnceAndStopsReconnecting() throws {
        let relay = try ForbiddingRelay()
        addTeardownBlock { relay.listener.cancel() }
        let ready = expectation(description: "listener ready")
        relay.start { ready.fulfill() }
        wait(for: [ready], timeout: 5)

        let url = URL(string: "ws://127.0.0.1:\(relay.port)/v1/viewer/dev1")!
        let connection = SessionConnection(
            transport: .webSocket(url, bearer: { "stale-token" }),
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
        XCTAssertEqual(relay.connectionAttempts, 1)
        XCTAssertEqual(errors.count, 1, "\(errors)")

        // B4's "sign in again" path: an explicit connect() starts over —
        // the relay is dialed exactly once more, and refused once more.
        connection.connect()
        wait(for: [unauthorizedAgain], timeout: 5)
        XCTAssertEqual(relay.connectionAttempts, 2)
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
}
