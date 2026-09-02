import Foundation

enum MessageKind: UInt8 {
    case hello = 0x01
    case listSessions = 0x02
    case createSession = 0x03
    case attach = 0x04
    case input = 0x05
    case resize = 0x06
    case interrupt = 0x07
    case kill = 0x08
    case detach = 0x09
    case getSetting = 0x0a
    case setSetting = 0x0b
    /// Brain-store read: every ingested project (Task 6a — appended, never
    /// renumbering an existing kind). Mirrors
    /// `omniagent_pty_daemon::protocol::MessageKind::BrainListProjects`.
    case brainListProjects = 0x0c
    /// Brain-store read: one project's briefing block (Task 6a — appended,
    /// never renumbering an existing kind). Mirrors
    /// `omniagent_pty_daemon::protocol::MessageKind::BrainGetContext`.
    case brainGetContext = 0x0d
    /// Persists a project root and kicks off background ingestion under it
    /// (Task 6a-2 — appended, never renumbering an existing kind). Mirrors
    /// `omniagent_pty_daemon::protocol::MessageKind::RootsStartIngest`.
    case rootsStartIngest = 0x0e
    /// Polls the daemon's own `IngestionState` snapshot (Task 6a-2). Mirrors
    /// `RootsIngestionStatus`.
    case rootsIngestionStatus = 0x0f
    /// Every persisted project root (Task 6a-2). Mirrors `RootsList`.
    case rootsList = 0x10
    /// The project with the most nodes in the store (Task 6a-2). Mirrors
    /// `RootsBiggestProject`.
    case rootsBiggestProject = 0x11
    /// Adds exactly one project directory (Task 6a-2). Mirrors
    /// `RootsAddProject`.
    case rootsAddProject = 0x12
    /// Overrides a project's display label (Task 6a-2). Mirrors
    /// `RootsRenameProject`.
    case rootsRenameProject = 0x13
    /// Every project id currently marked paused (Task 6a-2). Mirrors
    /// `RootsPausedProjects`.
    case rootsPausedProjects = 0x14
    /// Marks a project paused/unpaused (Task 6a-2). Mirrors
    /// `RootsSetPaused`.
    case rootsSetPaused = 0x15
    /// Every project's staleness reading (Task 6a-2). Mirrors
    /// `RootsStaleness`.
    case rootsStaleness = 0x16
    /// Manual "re-check" for one already-known project (Task 6a-2). Mirrors
    /// `RootsReingestProject`.
    case rootsReingestProject = 0x17
    /// "Rebuild brain": wipes and re-ingests the whole store (Task 6a-2).
    /// Mirrors `RootsRebuild`.
    case rootsRebuild = 0x18
    /// Full-text search over the local knowledge graph (Task 6a-2). Mirrors
    /// `BrainSearch`.
    case brainSearch = 0x19
    /// The roster of remote viewers currently attached to this daemon, on
    /// demand (phase 2 §5 — appended, never renumbering an existing kind).
    /// Local-only: it is in `authorize_remote`'s deny arm. Mirrors
    /// `omniagent_pty_daemon::protocol::MessageKind::ListViewers`.
    case listViewers = 0x1a
    /// Kicks one remote viewer and blocks it until Remote Control is turned
    /// on again (phase 2 §5). Local-only. Mirrors `DisconnectViewer`.
    case disconnectViewer = 0x1b
    /// Publishes the host's own state — the gauges, the Claude usage limits
    /// and engine availability the app computes in-process (2026-09-01
    /// remote environment sharing spec §4, Task 22). The payload is opaque
    /// JSON the daemon stores and forwards to the lease holder without ever
    /// parsing it. Local-only, like `listViewers`/`disconnectViewer`: it is
    /// in `authorize_remote`'s deny arm, so a remote client's own attempt is
    /// refused. Mirrors
    /// `omniagent_pty_daemon::protocol::MessageKind::PublishHostState`.
    case publishHostState = 0x1c
    case helloAck = 0x81
    case sessionList = 0x82
    case sessionCreated = 0x83
    case snapshot = 0x84
    case output = 0x85
    case sessionStatus = 0x86
    case attention = 0x87
    case sessionExited = 0x88
    case response = 0x89
    case resyncRequired = 0x8a
    case error = 0x8b
    /// The session's current grid, `{id, cols, rows}` (phase 2 §1 —
    /// appended, never renumbering an existing kind). Pushed on `Attach`,
    /// just before the snapshot, and again on every accepted resize; a local
    /// client ignores it, a remote viewer re-pins its scaled render to it.
    /// Mirrors `omniagent_pty_daemon::protocol::MessageKind::SessionResized`.
    case sessionResized = 0x8c
    /// The presence roster push, `{"viewers":[…]}` (phase 2 §5). Sent to
    /// local connections only — a viewer never learns about other viewers.
    /// Mirrors `RemoteViewers`.
    case remoteViewers = 0x8d
    /// The host's own state — `publishHostState`'s opaque JSON payload,
    /// forwarded byte-for-byte (spec §4, Task 22). Pushed to the lease
    /// holder only, on attach and again on every publish; the app's own
    /// (local) connection never receives its own publishes echoed back to
    /// it, which is why nothing in this app decodes this kind today — that
    /// is the *viewer* side, a later task. Mirrors
    /// `omniagent_pty_daemon::protocol::MessageKind::HostState`.
    case hostState = 0x8e
    /// One batch of daemon-witnessed activity rows,
    /// `{"entries":[{"ts","kind","summary","detail"}]}` (phase 3 spec §8 —
    /// Task 19). Sent to local connections only — a remote viewer must never
    /// learn what the log says about it. Mirrors `RemoteActivity`.
    case remoteActivity = 0x8f
}

enum SessionProtocolError: Error, Equatable {
    case payloadTooLarge(Int)
    case unsupportedVersion(UInt8)
    case unknownMessageKind(UInt8)
    case unsupportedFlags(UInt16)
    case invalidRawPayload
    case invalidSessionID
    case sessionIDTooLong(Int)
}

struct SessionFrame: Equatable {
    /// The wire version, matching `PROTOCOL_VERSION` in the daemon's
    /// `protocol.rs` — **2** since environment sharing. The two ship in one
    /// bundle, so the app and its own daemon never disagree; what the bump is
    /// for is the *other* Mac, which the daemon refuses at `Hello` with
    /// "update OmniAgent on ‹machine›" rather than by dropping the stream.
    static let protocolVersion: UInt8 = 2
    static let headerLength = 16
    static let maximumPayloadLength = 1_048_576

    let kind: MessageKind
    let flags: UInt16
    let requestOrSequence: UInt64
    let payload: Data

    init(
        kind: MessageKind,
        flags: UInt16 = 0,
        requestOrSequence: UInt64,
        payload: Data
    ) {
        self.kind = kind
        self.flags = flags
        self.requestOrSequence = requestOrSequence
        self.payload = payload
    }

    func encoded() throws -> Data {
        guard payload.count <= Self.maximumPayloadLength else {
            throw SessionProtocolError.payloadTooLarge(payload.count)
        }
        guard flags == 0 else {
            throw SessionProtocolError.unsupportedFlags(flags)
        }
        var encoded = Data()
        encoded.reserveCapacity(Self.headerLength + payload.count)
        encoded.append(contentsOf: UInt32(payload.count).bigEndianBytes)
        encoded.append(Self.protocolVersion)
        encoded.append(kind.rawValue)
        encoded.append(contentsOf: flags.bigEndianBytes)
        encoded.append(contentsOf: requestOrSequence.bigEndianBytes)
        encoded.append(payload)
        return encoded
    }
}

struct FrameDecoder {
    private var buffer = Data()

    mutating func append(_ data: Data) throws -> [SessionFrame] {
        buffer.append(data)
        var frames: [SessionFrame] = []

        while buffer.count >= SessionFrame.headerLength {
            let length = Int(buffer.readUInt32(at: 0))
            guard length <= SessionFrame.maximumPayloadLength else {
                throw SessionProtocolError.payloadTooLarge(length)
            }
            let version = buffer.byte(at: 4)
            guard version == SessionFrame.protocolVersion else {
                throw SessionProtocolError.unsupportedVersion(version)
            }
            let rawKind = buffer.byte(at: 5)
            guard let kind = MessageKind(rawValue: rawKind) else {
                throw SessionProtocolError.unknownMessageKind(rawKind)
            }
            let flags = buffer.readUInt16(at: 6)
            guard flags == 0 else {
                throw SessionProtocolError.unsupportedFlags(flags)
            }
            let frameLength = SessionFrame.headerLength + length
            guard buffer.count >= frameLength else { break }
            frames.append(
                SessionFrame(
                    kind: kind,
                    flags: flags,
                    requestOrSequence: buffer.readUInt64(at: 8),
                    payload: buffer.subdata(atOffsets: SessionFrame.headerLength..<frameLength)
                )
            )
            buffer.removeFirst(frameLength)
        }
        return frames
    }
}

struct DecodedRawPayload {
    let sessionID: String
    let bytes: Data
}

enum RawPayload {
    static func encode(sessionID: String, bytes: Data) throws -> Data {
        let id = Data(sessionID.utf8)
        guard id.count <= Int(UInt16.max) else {
            throw SessionProtocolError.sessionIDTooLong(id.count)
        }
        let length = 2 + id.count + bytes.count
        guard length <= SessionFrame.maximumPayloadLength else {
            throw SessionProtocolError.payloadTooLarge(length)
        }
        var payload = Data()
        payload.reserveCapacity(length)
        payload.append(contentsOf: UInt16(id.count).bigEndianBytes)
        payload.append(id)
        payload.append(bytes)
        return payload
    }

    static func decode(_ payload: Data) throws -> DecodedRawPayload {
        guard payload.count >= 2 else {
            throw SessionProtocolError.invalidRawPayload
        }
        let idLength = Int(payload.readUInt16(at: 0))
        let rawStart = 2 + idLength
        guard rawStart <= payload.count else {
            throw SessionProtocolError.invalidRawPayload
        }
        let idData = payload.subdata(atOffsets: 2..<rawStart)
        guard let sessionID = String(data: idData, encoding: .utf8) else {
            throw SessionProtocolError.invalidSessionID
        }
        return DecodedRawPayload(
            sessionID: sessionID,
            bytes: payload.subdata(atOffsets: rawStart..<payload.count)
        )
    }
}

extension FixedWidthInteger {
    var bigEndianBytes: [UInt8] {
        withUnsafeBytes(of: bigEndian) { Array($0) }
    }
}

private extension Data {
    func byte(at offset: Int) -> UInt8 {
        self[index(startIndex, offsetBy: offset)]
    }

    func readUInt16(at offset: Int) -> UInt16 {
        UInt16(byte(at: offset)) << 8 | UInt16(byte(at: offset + 1))
    }

    func readUInt32(at offset: Int) -> UInt32 {
        (0..<4).reduce(0) { ($0 << 8) | UInt32(byte(at: offset + $1)) }
    }

    func readUInt64(at offset: Int) -> UInt64 {
        (0..<8).reduce(0) { ($0 << 8) | UInt64(byte(at: offset + $1)) }
    }

    func subdata(atOffsets range: Range<Int>) -> Data {
        let lower = index(startIndex, offsetBy: range.lowerBound)
        let upper = index(startIndex, offsetBy: range.upperBound)
        return subdata(in: lower..<upper)
    }
}
