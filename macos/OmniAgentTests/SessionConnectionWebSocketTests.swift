import XCTest
import Network
@testable import OmniAgent

final class SessionConnectionWebSocketTests: XCTestCase {
    /// A one-shot WebSocket server that answers the first frame it receives (Hello) with HelloAck.
    private final class FakeRelay {
        let listener: NWListener
        var port: UInt16 { listener.port!.rawValue }
        var receivedAuthorization: String?
        private var connection: NWConnection?
        init() throws {
            let params = NWParameters.tcp
            let ws = NWProtocolWebSocket.Options()
            ws.autoReplyPing = true
            params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
            listener = try NWListener(using: params, on: .any)
        }
        func start() {
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

    func testWebSocketTransportCompletesTheHelloHandshake() throws {
        let relay = try FakeRelay()
        relay.start()
        let ready = expectation(description: "listener ready")
        relay.listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        wait(for: [ready], timeout: 5)

        let url = URL(string: "ws://127.0.0.1:\(relay.port)/v1/viewer/dev1")!
        let connection = SessionConnection(transport: .webSocket(url, bearer: { "viewer-token" }), callbackQueue: .main)
        let connected = expectation(description: "connected")
        connection.onStateChange = { state in if case .connected = state { connected.fulfill() } }
        connection.connect()
        wait(for: [connected], timeout: 5)
        XCTAssertTrue(connection.isRemote)
        connection.disconnect()
    }
}
