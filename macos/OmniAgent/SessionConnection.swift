import Darwin
import Foundation
import os.signpost

enum ConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
}

enum RemoteSessionStatus: String, Codable {
    case ready
    case thinking
    case toolExecution = "tool_execution"
    case awaitingApproval = "awaiting_approval"
    case error
}

struct SessionStatusEvent: Codable, Equatable {
    let id: String
    let status: RemoteSessionStatus
    let notify: Bool
    let engine: String
}

struct SessionExitedEvent: Codable, Equatable {
    let id: String
    let exitCode: UInt32?

    enum CodingKeys: String, CodingKey {
        case id
        case exitCode = "exit_code"
    }
}

struct CreateSessionRequest: Codable, Equatable {
    let id: String
    let command: [String]
    let cwd: String?
    let environment: [String: String]
    let cols: UInt16
    let rows: UInt16
    let transcriptPath: String?

    enum CodingKeys: String, CodingKey {
        case id, command, cwd, cols, rows
        case environment = "env"
        case transcriptPath = "transcript_path"
    }
}

enum SessionConnectionError: Error, LocalizedError {
    case socketPathTooLong
    case posix(String, Int32)
    case disconnected
    case invalidResponse(MessageKind)
    case daemon(String)

    var errorDescription: String? {
        switch self {
        case .socketPathTooLong:
            return "The daemon socket path is too long."
        case let .posix(operation, code):
            return "\(operation): \(String(cString: strerror(code)))"
        case .disconnected:
            return "The PTY daemon connection closed."
        case let .invalidResponse(kind):
            return "Unexpected daemon response: \(kind)."
        case let .daemon(message):
            return message
        }
    }
}

final class SessionConnection {
    var onStateChange: ((ConnectionState) -> Void)?
    var onTerminalData: ((String, Data, UInt64, Bool) -> Void)?
    var onStatus: ((SessionStatusEvent) -> Void)?
    var onAttention: ((String) -> Void)?
    var onExit: ((SessionExitedEvent) -> Void)?
    var onError: ((Error) -> Void)?

    private struct Attachment {
        var sequence: UInt64?
    }

    private let socketURL: URL
    private let reconnectDelay: TimeInterval
    private let callbackQueue: DispatchQueue
    private let ioQueue = DispatchQueue(label: "digital.bruno.omniagent.session-connection")
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var frameDecoder = FrameDecoder()
    private var descriptor: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var nextRequest: UInt64 = 1
    private var helloRequest: UInt64?
    private var pending: [UInt64: (Result<SessionFrame, Error>) -> Void] = [:]
    private var attachments: [String: Attachment] = [:]
    private var shouldReconnect = false
    private var reconnectScheduled = false
    private var state: ConnectionState = .disconnected
    private var connectSignpost: OSSignpostID?

    init(
        socketURL: URL,
        reconnectDelay: TimeInterval = 0.25,
        callbackQueue: DispatchQueue = .main
    ) {
        self.socketURL = socketURL
        self.reconnectDelay = reconnectDelay
        self.callbackQueue = callbackQueue
    }

    deinit {
        if descriptor >= 0 {
            Darwin.close(descriptor)
        }
    }

    func connect() {
        ioQueue.async {
            self.shouldReconnect = true
            self.openConnection()
        }
    }

    func disconnect() {
        ioQueue.async {
            self.shouldReconnect = false
            self.reconnectScheduled = false
            self.closeConnection(report: false)
        }
    }

    func listSessions(completion: @escaping (Result<[String], Error>) -> Void) {
        request(kind: .listSessions, payload: Data("{}".utf8)) { result in
            completion(
                result.flatMap { frame in
                    guard frame.kind == .sessionList else {
                        return .failure(SessionConnectionError.invalidResponse(frame.kind))
                    }
                    return Result {
                        try self.decoder.decode(SessionListPayload.self, from: frame.payload).sessions
                    }
                }
            )
        }
    }

    func createSession(
        _ request: CreateSessionRequest,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        sendCodable(kind: .createSession, value: request) { result in
            completion(
                result.flatMap { frame in
                    guard frame.kind == .sessionCreated else {
                        return .failure(SessionConnectionError.invalidResponse(frame.kind))
                    }
                    return Result {
                        try self.decoder.decode(SessionIDPayload.self, from: frame.payload).id
                    }
                }
            )
        }
    }

    func attach(sessionID: String, afterSequence: UInt64?) {
        ioQueue.async {
            self.attachments[sessionID] = Attachment(sequence: afterSequence)
            guard self.state == .connected else { return }
            self.sendAttach(sessionID: sessionID, afterSequence: afterSequence)
        }
    }

    func reattach(sessionID: String) {
        ioQueue.async {
            guard let attachment = self.attachments[sessionID], self.state == .connected else {
                return
            }
            self.sendAttach(sessionID: sessionID, afterSequence: attachment.sequence)
        }
    }

    func write(
        sessionID: String,
        bytes: Data,
        completion: ((Result<Void, Error>) -> Void)? = nil
    ) {
        do {
            let payload = try RawPayload.encode(sessionID: sessionID, bytes: bytes)
            request(kind: .input, payload: payload) {
                self.finishResponse($0, completion: completion)
            }
        } catch {
            completion?(.failure(error))
            report(error)
        }
    }

    func resize(
        sessionID: String,
        cols: UInt16,
        rows: UInt16,
        pixelWidth: UInt16,
        pixelHeight: UInt16,
        completion: ((Result<Void, Error>) -> Void)? = nil
    ) {
        sendCodable(
            kind: .resize,
            value: ResizePayload(
                id: sessionID,
                cols: cols,
                rows: rows,
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight
            )
        ) {
            self.finishResponse($0, completion: completion)
        }
    }

    func interrupt(
        sessionID: String,
        completion: ((Result<Void, Error>) -> Void)? = nil
    ) {
        sendCodable(kind: .interrupt, value: SessionIDPayload(id: sessionID)) {
            self.finishResponse($0, completion: completion)
        }
    }

    func kill(
        sessionID: String,
        completion: ((Result<Void, Error>) -> Void)? = nil
    ) {
        sendCodable(kind: .kill, value: SessionIDPayload(id: sessionID)) { result in
            self.ioQueue.async {
                self.attachments.removeValue(forKey: sessionID)
            }
            self.finishResponse(result, completion: completion)
        }
    }

    private func openConnection() {
        guard descriptor < 0, shouldReconnect else { return }
        transition(to: .connecting)
        let signpost = OSSignpostID(log: Instrumentation.log)
        connectSignpost = signpost
        os_signpost(
            .begin,
            log: Instrumentation.log,
            name: "Daemon Connect",
            signpostID: signpost
        )
        let socketDescriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketDescriptor >= 0 else {
            connectionFailed(SessionConnectionError.posix("socket", errno))
            return
        }
        var noSigPipe: Int32 = 1
        setsockopt(
            socketDescriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSigPipe,
            socklen_t(MemoryLayout<Int32>.size)
        )

        let connectionResult: Int32
        do {
            connectionResult = try withUnixSocketAddress(path: socketURL.path) {
                Darwin.connect(socketDescriptor, $0, $1)
            }
        } catch {
            Darwin.close(socketDescriptor)
            connectionFailed(error)
            return
        }
        guard connectionResult == 0 else {
            let code = errno
            Darwin.close(socketDescriptor)
            connectionFailed(SessionConnectionError.posix("connect", code))
            return
        }

        descriptor = socketDescriptor
        frameDecoder = FrameDecoder()
        let source = DispatchSource.makeReadSource(
            fileDescriptor: socketDescriptor,
            queue: ioQueue
        )
        source.setEventHandler { [weak self] in self?.readAvailable() }
        readSource = source
        source.resume()
        let request = takeRequest()
        helloRequest = request
        do {
            try send(
                SessionFrame(
                    kind: .hello,
                    requestOrSequence: request,
                    payload: try encoder.encode(HelloPayload(client: "omniagent-native-macos"))
                )
            )
        } catch {
            closeConnection(error: error)
        }
    }

    private func connectionFailed(_ error: Error) {
        finishConnectSignpost()
        transition(to: .disconnected)
        report(error)
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard shouldReconnect, !reconnectScheduled else { return }
        reconnectScheduled = true
        ioQueue.asyncAfter(deadline: .now() + reconnectDelay) {
            self.reconnectScheduled = false
            self.openConnection()
        }
    }

    private func readAvailable() {
        var bytes = [UInt8](repeating: 0, count: 65_536)
        let count = Darwin.read(descriptor, &bytes, bytes.count)
        if count > 0 {
            do {
                for frame in try frameDecoder.append(Data(bytes.prefix(count))) {
                    handle(frame)
                }
            } catch {
                closeConnection(error: error)
            }
        } else if count == 0 {
            closeConnection(error: SessionConnectionError.disconnected)
        } else if errno != EINTR {
            closeConnection(error: SessionConnectionError.posix("read", errno))
        }
    }

    private func handle(_ frame: SessionFrame) {
        if frame.kind == .helloAck, frame.requestOrSequence == helloRequest {
            helloRequest = nil
            finishConnectSignpost()
            transition(to: .connected)
            for (sessionID, attachment) in attachments {
                sendAttach(sessionID: sessionID, afterSequence: attachment.sequence)
            }
            return
        }

        switch frame.kind {
        case .response, .sessionList, .sessionCreated:
            completeRequest(frame)
        case .error:
            let message =
                (try? decoder.decode(ErrorPayload.self, from: frame.payload).message)
                ?? "The daemon rejected the request."
            completeRequest(
                frame,
                result: .failure(SessionConnectionError.daemon(message))
            )
        case .snapshot, .output:
            do {
                let raw = try RawPayload.decode(frame.payload)
                updateSequence(sessionID: raw.sessionID, sequence: frame.requestOrSequence)
                os_signpost(
                    .event,
                    log: Instrumentation.log,
                    name: "Latency.OutputReceipt",
                    "sequence=%llu bytes=%lu",
                    frame.requestOrSequence,
                    raw.bytes.count
                )
                callbackQueue.async {
                    self.onTerminalData?(
                        raw.sessionID,
                        raw.bytes,
                        frame.requestOrSequence,
                        frame.kind == .snapshot
                    )
                }
            } catch {
                closeConnection(error: error)
            }
        case .sessionStatus:
            do {
                let event = try decoder.decode(SessionStatusEvent.self, from: frame.payload)
                updateSequence(sessionID: event.id, sequence: frame.requestOrSequence)
                callbackQueue.async { self.onStatus?(event) }
            } catch {
                closeConnection(error: error)
            }
        case .attention:
            if let id = try? decoder.decode(SessionIDPayload.self, from: frame.payload).id {
                callbackQueue.async { self.onAttention?(id) }
            }
        case .sessionExited:
            if let event = try? decoder.decode(SessionExitedEvent.self, from: frame.payload) {
                updateSequence(sessionID: event.id, sequence: frame.requestOrSequence)
                callbackQueue.async { self.onExit?(event) }
            }
        case .resyncRequired:
            if let id = try? decoder.decode(SessionIDPayload.self, from: frame.payload).id {
                attachments[id] = Attachment(sequence: nil)
                sendAttach(sessionID: id, afterSequence: nil)
            }
        default:
            break
        }
    }

    private func updateSequence(sessionID: String, sequence: UInt64) {
        guard var attachment = attachments[sessionID] else { return }
        attachment.sequence = max(attachment.sequence ?? 0, sequence)
        attachments[sessionID] = attachment
    }

    private func completeRequest(
        _ frame: SessionFrame,
        result: Result<SessionFrame, Error>? = nil
    ) {
        guard let completion = pending.removeValue(forKey: frame.requestOrSequence) else {
            return
        }
        callbackQueue.async {
            completion(result ?? .success(frame))
        }
    }

    private func request(
        kind: MessageKind,
        payload: Data,
        completion: @escaping (Result<SessionFrame, Error>) -> Void
    ) {
        ioQueue.async {
            guard self.state == .connected else {
                self.callbackQueue.async {
                    completion(.failure(SessionConnectionError.disconnected))
                }
                return
            }
            let request = self.takeRequest()
            self.pending[request] = completion
            do {
                try self.send(
                    SessionFrame(
                        kind: kind,
                        requestOrSequence: request,
                        payload: payload
                    )
                )
            } catch {
                self.pending.removeValue(forKey: request)
                self.callbackQueue.async { completion(.failure(error)) }
                self.closeConnection(error: error)
            }
        }
    }

    private func sendCodable<T: Encodable>(
        kind: MessageKind,
        value: T,
        completion: @escaping (Result<SessionFrame, Error>) -> Void
    ) {
        do {
            request(kind: kind, payload: try encoder.encode(value), completion: completion)
        } catch {
            callbackQueue.async { completion(.failure(error)) }
            report(error)
        }
    }

    private func sendAttach(sessionID: String, afterSequence: UInt64?) {
        do {
            let request = takeRequest()
            try send(
                SessionFrame(
                    kind: .attach,
                    requestOrSequence: request,
                    payload: try encoder.encode(
                        AttachPayload(id: sessionID, afterSequence: afterSequence)
                    )
                )
            )
        } catch {
            closeConnection(error: error)
        }
    }

    private func send(_ frame: SessionFrame) throws {
        let data = try frame.encoded()
        var written = 0
        try data.withUnsafeBytes { bytes in
            while written < data.count {
                let count = Darwin.write(
                    descriptor,
                    bytes.baseAddress!.advanced(by: written),
                    data.count - written
                )
                guard count > 0 else {
                    throw SessionConnectionError.posix("write", errno)
                }
                written += count
            }
        }
        if frame.kind == .input {
            os_signpost(
                .event,
                log: Instrumentation.log,
                name: "Latency.IPCSend",
                "request=%llu bytes=%lu",
                frame.requestOrSequence,
                frame.payload.count
            )
        }
    }

    private func takeRequest() -> UInt64 {
        defer { nextRequest &+= 1 }
        return nextRequest
    }

    private func closeConnection(
        error: Error = SessionConnectionError.disconnected,
        report shouldReport: Bool = true
    ) {
        finishConnectSignpost()
        readSource?.cancel()
        readSource = nil
        if descriptor >= 0 {
            Darwin.close(descriptor)
            descriptor = -1
        }
        helloRequest = nil
        let completions = pending.values
        pending.removeAll()
        for completion in completions {
            callbackQueue.async { completion(.failure(error)) }
        }
        transition(to: .disconnected)
        if shouldReport {
            report(error)
        }
        scheduleReconnect()
    }

    private func transition(to newState: ConnectionState) {
        guard state != newState else { return }
        state = newState
        callbackQueue.async { self.onStateChange?(newState) }
    }

    private func report(_ error: Error) {
        callbackQueue.async { self.onError?(error) }
    }

    private func finishConnectSignpost() {
        guard let connectSignpost else { return }
        os_signpost(
            .end,
            log: Instrumentation.log,
            name: "Daemon Connect",
            signpostID: connectSignpost
        )
        self.connectSignpost = nil
    }

    private func finishResponse(
        _ result: Result<SessionFrame, Error>,
        completion: ((Result<Void, Error>) -> Void)?
    ) {
        completion?(
            result.flatMap { frame in
                frame.kind == .response
                    ? .success(())
                    : .failure(SessionConnectionError.invalidResponse(frame.kind))
            }
        )
    }
}

private struct HelloPayload: Codable {
    let client: String
}

private struct SessionListPayload: Codable {
    let sessions: [String]
}

private struct SessionIDPayload: Codable {
    let id: String
}

private struct AttachPayload: Codable {
    let id: String
    let afterSequence: UInt64?

    enum CodingKeys: String, CodingKey {
        case id
        case afterSequence = "after_sequence"
    }
}

private struct ResizePayload: Codable {
    let id: String
    let cols: UInt16
    let rows: UInt16
    let pixelWidth: UInt16
    let pixelHeight: UInt16

    enum CodingKeys: String, CodingKey {
        case id, cols, rows
        case pixelWidth = "pixel_width"
        case pixelHeight = "pixel_height"
    }
}

private struct ErrorPayload: Codable {
    let message: String
}

private func withUnixSocketAddress<T>(
    path: String,
    _ body: (UnsafePointer<sockaddr>, socklen_t) -> T
) throws -> T {
    var address = sockaddr_un()
    let pathBytes = Array(path.utf8CString)
    guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
        throw SessionConnectionError.socketPathTooLong
    }
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
