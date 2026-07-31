import Darwin
import XCTest
@testable import OmniAgent

final class SessionConnectionTests: XCTestCase {
    func testReconnectReattachesAfterLatestRawOutputSequence() throws {
        let socketPath = "/tmp/omniagent-\(UUID().uuidString.prefix(8)).sock"
        let server = try UnixTestServer(path: socketPath)
        let initialAttach = expectation(description: "initial sequence attach")
        let rawOutput = expectation(description: "raw output")
        let resumedAttach = expectation(description: "reattach after reconnect")

        server.run { firstClient in
            let hello = try readFrame(from: firstClient)
            try writeFrame(
                SessionFrame(
                    kind: .helloAck,
                    requestOrSequence: hello.requestOrSequence,
                    payload: try JSONSerialization.data(withJSONObject: ["protocol_version": 1])
                ),
                to: firstClient,
                splitAt: 7
            )
            let attach = try readFrame(from: firstClient)
            let firstPayload = try XCTUnwrap(
                JSONSerialization.jsonObject(with: attach.payload) as? [String: Any]
            )
            XCTAssertEqual((firstPayload["after_sequence"] as? NSNumber)?.uint64Value, 40)
            initialAttach.fulfill()
            try writeFrame(
                SessionFrame(
                    kind: .output,
                    requestOrSequence: 41,
                    payload: try RawPayload.encode(
                        sessionID: "native-terminal",
                        bytes: Data([0, 0xff, 0x1b, 0x5b])
                    )
                ),
                to: firstClient,
                splitAt: 19
            )
            Darwin.close(firstClient)

            let secondClient = try server.accept()
            let reconnectHello = try readFrame(from: secondClient)
            try writeFrame(
                SessionFrame(
                    kind: .helloAck,
                    requestOrSequence: reconnectHello.requestOrSequence,
                    payload: try JSONSerialization.data(withJSONObject: ["protocol_version": 1])
                ),
                to: secondClient
            )
            let reattach = try readFrame(from: secondClient)
            let resumedPayload = try XCTUnwrap(
                JSONSerialization.jsonObject(with: reattach.payload) as? [String: Any]
            )
            XCTAssertEqual((resumedPayload["after_sequence"] as? NSNumber)?.uint64Value, 41)
            resumedAttach.fulfill()
            Darwin.close(secondClient)
        }

        let connection = SessionConnection(
            socketURL: URL(fileURLWithPath: socketPath),
            reconnectDelay: 0.02
        )
        var attached = false
        connection.onStateChange = { state in
            guard state == .connected, !attached else { return }
            attached = true
            connection.attach(sessionID: "native-terminal", afterSequence: 40)
        }
        connection.onTerminalData = { sessionID, bytes, sequence, isSnapshot in
            XCTAssertEqual(sessionID, "native-terminal")
            XCTAssertEqual(bytes, Data([0, 0xff, 0x1b, 0x5b]))
            XCTAssertEqual(sequence, 41)
            XCTAssertFalse(isSnapshot)
            rawOutput.fulfill()
        }
        connection.connect()

        wait(for: [initialAttach, rawOutput, resumedAttach], timeout: 3)
        connection.disconnect()
        server.stop()
    }

    // MARK: - Settings / brain client methods (Task 6a)

    func testGetSettingSendsTheKeyAndDecodesAnOptionalValue() throws {
        let socketPath = "/tmp/omniagent-\(UUID().uuidString.prefix(8)).sock"
        let server = try UnixTestServer(path: socketPath)
        let responded = expectation(description: "getSetting responded")

        server.run { client in
            try Self.ackHello(on: client)
            let request = try readFrame(from: client)
            XCTAssertEqual(request.kind, .getSetting)
            let payload = try XCTUnwrap(
                JSONSerialization.jsonObject(with: request.payload) as? [String: Any]
            )
            XCTAssertEqual(payload["key"] as? String, "layout")
            try writeFrame(
                SessionFrame(
                    kind: .response,
                    requestOrSequence: request.requestOrSequence,
                    payload: try JSONSerialization.data(withJSONObject: ["value": "{\"tabs\":[]}"])
                ),
                to: client
            )
        }

        let connection = SessionConnection(
            socketURL: URL(fileURLWithPath: socketPath),
            reconnectDelay: 0.02
        )
        var sent = false
        connection.onStateChange = { state in
            guard state == .connected, !sent else { return }
            sent = true
            connection.getSetting(key: "layout") { result in
                XCTAssertEqual(try? result.get(), "{\"tabs\":[]}")
                responded.fulfill()
            }
        }
        connection.connect()

        wait(for: [responded], timeout: 3)
        connection.disconnect()
        server.stop()
    }

    func testGetSettingDecodesAMissingValueAsNil() throws {
        let socketPath = "/tmp/omniagent-\(UUID().uuidString.prefix(8)).sock"
        let server = try UnixTestServer(path: socketPath)
        let responded = expectation(description: "getSetting responded")

        server.run { client in
            try Self.ackHello(on: client)
            let request = try readFrame(from: client)
            try writeFrame(
                SessionFrame(
                    kind: .response,
                    requestOrSequence: request.requestOrSequence,
                    payload: try JSONSerialization.data(withJSONObject: ["value": NSNull()])
                ),
                to: client
            )
        }

        let connection = SessionConnection(
            socketURL: URL(fileURLWithPath: socketPath),
            reconnectDelay: 0.02
        )
        var sent = false
        connection.onStateChange = { state in
            guard state == .connected, !sent else { return }
            sent = true
            connection.getSetting(key: "does-not-exist") { result in
                switch result {
                case let .success(value):
                    XCTAssertNil(value)
                case let .failure(error):
                    XCTFail("getSetting failed: \(error)")
                }
                responded.fulfill()
            }
        }
        connection.connect()

        wait(for: [responded], timeout: 3)
        connection.disconnect()
        server.stop()
    }

    func testSetSettingSendsTheKeyAndValueAndCompletesOnResponse() throws {
        let socketPath = "/tmp/omniagent-\(UUID().uuidString.prefix(8)).sock"
        let server = try UnixTestServer(path: socketPath)
        let responded = expectation(description: "setSetting responded")

        server.run { client in
            try Self.ackHello(on: client)
            let request = try readFrame(from: client)
            XCTAssertEqual(request.kind, .setSetting)
            let payload = try XCTUnwrap(
                JSONSerialization.jsonObject(with: request.payload) as? [String: Any]
            )
            XCTAssertEqual(payload["key"] as? String, "layout")
            XCTAssertEqual(payload["value"] as? String, "{\"tabs\":[]}")
            try writeFrame(
                SessionFrame(
                    kind: .response,
                    requestOrSequence: request.requestOrSequence,
                    payload: try JSONSerialization.data(withJSONObject: ["ok": true])
                ),
                to: client
            )
        }

        let connection = SessionConnection(
            socketURL: URL(fileURLWithPath: socketPath),
            reconnectDelay: 0.02
        )
        var sent = false
        connection.onStateChange = { state in
            guard state == .connected, !sent else { return }
            sent = true
            connection.setSetting(key: "layout", value: "{\"tabs\":[]}") { result in
                if case let .failure(error) = result {
                    XCTFail("setSetting failed: \(error)")
                }
                responded.fulfill()
            }
        }
        connection.connect()

        wait(for: [responded], timeout: 3)
        connection.disconnect()
        server.stop()
    }

    func testListProjectsSendsAnEmptyPayloadAndDecodesTheProjectSummaries() throws {
        let socketPath = "/tmp/omniagent-\(UUID().uuidString.prefix(8)).sock"
        let server = try UnixTestServer(path: socketPath)
        let responded = expectation(description: "listProjects responded")

        server.run { client in
            try Self.ackHello(on: client)
            let request = try readFrame(from: client)
            XCTAssertEqual(request.kind, .brainListProjects)
            try writeFrame(
                SessionFrame(
                    kind: .response,
                    requestOrSequence: request.requestOrSequence,
                    payload: try JSONSerialization.data(withJSONObject: [
                        "projects": [
                            ["id": "demo", "label": "demo", "path": "/tmp/demo"],
                            ["id": "other", "label": "Other", "path": NSNull()],
                        ],
                    ])
                ),
                to: client
            )
        }

        let connection = SessionConnection(
            socketURL: URL(fileURLWithPath: socketPath),
            reconnectDelay: 0.02
        )
        var sent = false
        connection.onStateChange = { state in
            guard state == .connected, !sent else { return }
            sent = true
            connection.listProjects { result in
                let projects = try? result.get()
                XCTAssertEqual(
                    projects,
                    [
                        BrainProjectSummary(id: "demo", label: "demo", path: "/tmp/demo"),
                        BrainProjectSummary(id: "other", label: "Other", path: nil),
                    ]
                )
                responded.fulfill()
            }
        }
        connection.connect()

        wait(for: [responded], timeout: 3)
        connection.disconnect()
        server.stop()
    }

    func testGetContextSendsTheProjectAndDecodesTheBriefing() throws {
        let socketPath = "/tmp/omniagent-\(UUID().uuidString.prefix(8)).sock"
        let server = try UnixTestServer(path: socketPath)
        let responded = expectation(description: "getContext responded")

        server.run { client in
            try Self.ackHello(on: client)
            let request = try readFrame(from: client)
            XCTAssertEqual(request.kind, .brainGetContext)
            let payload = try XCTUnwrap(
                JSONSerialization.jsonObject(with: request.payload) as? [String: Any]
            )
            XCTAssertEqual(payload["project"] as? String, "demo")
            try writeFrame(
                SessionFrame(
                    kind: .response,
                    requestOrSequence: request.requestOrSequence,
                    payload: try JSONSerialization.data(withJSONObject: [
                        "context": [
                            "summary": "A demo project.",
                            "recent_decisions": [
                                ["id": "demo:d1", "kind": "memory", "project": "demo", "label": "Decision: x"],
                            ],
                            "related_projects": [],
                            "memory_notes": [],
                        ],
                    ])
                ),
                to: client
            )
        }

        let connection = SessionConnection(
            socketURL: URL(fileURLWithPath: socketPath),
            reconnectDelay: 0.02
        )
        var sent = false
        connection.onStateChange = { state in
            guard state == .connected, !sent else { return }
            sent = true
            connection.getContext(project: "demo") { result in
                let context = try? result.get()
                XCTAssertEqual(context?.summary, "A demo project.")
                XCTAssertEqual(context?.recentDecisions.count, 1)
                XCTAssertEqual(context?.recentDecisions.first?.id, "demo:d1")
                XCTAssertEqual(context?.recentDecisions.first?.path, nil)
                XCTAssertEqual(context?.relatedProjects, [])
                XCTAssertEqual(context?.memoryNotes, [])
                responded.fulfill()
            }
        }
        connection.connect()

        wait(for: [responded], timeout: 3)
        connection.disconnect()
        server.stop()
    }

    private static func ackHello(on client: Int32) throws {
        let hello = try readFrame(from: client)
        try writeFrame(
            SessionFrame(
                kind: .helloAck,
                requestOrSequence: hello.requestOrSequence,
                payload: try JSONSerialization.data(withJSONObject: ["protocol_version": 1])
            ),
            to: client
        )
    }
}

private final class UnixTestServer {
    private let path: String
    private let listener: Int32
    private let queue = DispatchQueue(label: "digital.bruno.omniagent.test-daemon")

    init(path: String) throws {
        self.path = path
        unlink(path)
        listener = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw POSIXError(.EIO) }
        let result = withUnixSocketAddress(path: path) {
            Darwin.bind(listener, $0, $1)
        }
        guard result == 0, Darwin.listen(listener, 2) == 0 else {
            Darwin.close(listener)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    func run(_ body: @escaping (Int32) throws -> Void) {
        queue.async {
            do {
                try body(try self.accept())
            } catch {
                XCTFail("test daemon failed: \(error)")
            }
        }
    }

    func accept() throws -> Int32 {
        let client = Darwin.accept(listener, nil, nil)
        guard client >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return client
    }

    func stop() {
        Darwin.close(listener)
        unlink(path)
    }
}

private func withUnixSocketAddress<T>(
    path: String,
    _ body: (UnsafePointer<sockaddr>, socklen_t) -> T
) -> T {
    var address = sockaddr_un()
    let pathBytes = Array(path.utf8CString)
    precondition(pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path))
    address.sun_family = sa_family_t(AF_UNIX)
    let length = socklen_t(MemoryLayout<sa_family_t>.size + pathBytes.count)
    address.sun_len = UInt8(length)
    withUnsafeMutablePointer(to: &address.sun_path) {
        let destination = UnsafeMutableRawPointer($0).assumingMemoryBound(to: UInt8.self)
        for (index, byte) in pathBytes.enumerated() {
            destination[index] = UInt8(bitPattern: byte)
        }
    }
    return withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            body($0, length)
        }
    }
}

private func readFrame(from descriptor: Int32) throws -> SessionFrame {
    let header = try readExactly(16, from: descriptor)
    let length = Int(header.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
    var decoder = FrameDecoder()
    return try XCTUnwrap(try decoder.append(header + readExactly(length, from: descriptor)).first)
}

private func readExactly(_ count: Int, from descriptor: Int32) throws -> Data {
    var data = Data()
    while data.count < count {
        var bytes = [UInt8](repeating: 0, count: count - data.count)
        let readCount = Darwin.read(descriptor, &bytes, bytes.count)
        guard readCount > 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ECONNRESET)
        }
        data.append(contentsOf: bytes.prefix(readCount))
    }
    return data
}

private func writeFrame(
    _ frame: SessionFrame,
    to descriptor: Int32,
    splitAt: Int? = nil
) throws {
    let data = try frame.encoded()
    if let splitAt {
        try writeAll(data.prefix(splitAt), to: descriptor)
        usleep(5_000)
        try writeAll(data.suffix(from: splitAt), to: descriptor)
    } else {
        try writeAll(data[...], to: descriptor)
    }
}

private func writeAll(_ data: Data.SubSequence, to descriptor: Int32) throws {
    var written = 0
    try data.withUnsafeBytes { bytes in
        while written < data.count {
            let count = Darwin.write(
                descriptor,
                bytes.baseAddress!.advanced(by: written),
                data.count - written
            )
            guard count > 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            written += count
        }
    }
}
