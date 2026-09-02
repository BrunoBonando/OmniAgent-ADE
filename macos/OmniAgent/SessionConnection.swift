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

/// The `list_projects` / `get_context.related_projects` shape,
/// `mcp_server::tools::list_projects`'s frozen `{id, label, path}` (Task 6a).
struct BrainProjectSummary: Codable, Equatable {
    let id: String
    let label: String
    let path: String?
}

/// The shared node projection `mcp_server::tools`'s `search_brain`/`related`/
/// `get_context` all reuse: `{id, kind, project, label, path?, summary?}`
/// (Task 6a — `get_context`'s `recent_decisions`/`memory_notes` entries).
struct BrainNodeView: Codable, Equatable {
    let id: String
    let kind: String
    let project: String
    let label: String
    let path: String?
    let summary: String?
}

/// `get_context {project}` -> `{summary, recent_decisions, related_projects,
/// memory_notes}` (Task 6a) — the per-project briefing block a native
/// settings/usage/inspector surface reads.
struct BrainContext: Codable, Equatable {
    let summary: String
    let recentDecisions: [BrainNodeView]
    let relatedProjects: [BrainProjectSummary]
    let memoryNotes: [BrainNodeView]

    enum CodingKeys: String, CodingKey {
        case summary
        case recentDecisions = "recent_decisions"
        case relatedProjects = "related_projects"
        case memoryNotes = "memory_notes"
    }
}

/// One machine currently watching sessions on this daemon — the
/// `RemoteViewers` push and `ListViewers` response entry (phase 2 §5).
///
/// The identity is **self-reported by the viewer app**: both Macs belong to
/// the same account and the relay already refuses anyone else, so this is a
/// labelling and convenience mechanism, not an authorization boundary.
struct RemoteViewer: Codable, Equatable {
    let viewerID: String
    let machineName: String
    /// The pane ids this viewer is attached to right now.
    let sessions: [String]
    /// RFC 3339, when this viewer connected.
    let since: String
    /// Relay-asserted: the account the viewer's JWT is signed in as
    /// (`AssertedIdentity`, daemon `connections.rs`; spec §9).
    let accountEmail: String?
    /// Relay-asserted: `CF-Connecting-IP`, set by Cloudflare at the edge.
    let ip: String?
    /// Relay-asserted: `CF-IPCountry`, same.
    let country: String?
    /// The viewer app's user agent as the relay saw it — relayed, but *set
    /// by the client*, so the takeover panel shows what it carries (app
    /// version, OS) **unmarked**, beside the self-reported machine name.
    /// Only `accountEmail`/`ip`/`country` were checked by anybody.
    let client: String?

    /// The four asserted fields are absent on a row the relay said nothing
    /// about — and on every row an older daemon sends, which is why they
    /// decode as `nil` rather than failing the whole roster.
    init(
        viewerID: String,
        machineName: String,
        sessions: [String],
        since: String,
        accountEmail: String? = nil,
        ip: String? = nil,
        country: String? = nil,
        client: String? = nil
    ) {
        self.viewerID = viewerID
        self.machineName = machineName
        self.sessions = sessions
        self.since = since
        self.accountEmail = accountEmail
        self.ip = ip
        self.country = country
        self.client = client
    }

    enum CodingKeys: String, CodingKey {
        case viewerID = "viewer_id"
        case machineName = "machine_name"
        case sessions
        case since
        case accountEmail = "account_email"
        case ip
        case country
        case client
    }
}

/// What this Mac calls itself on every `Hello` — the other half of
/// `RemoteViewer` (phase 2 §5). The daemon records it only for a
/// `ClientTrust::Remote` connection, and it is what its presence roster and
/// its blocklist are keyed on.
///
/// The id is created once and persisted, so this Mac keeps **one** identity
/// across launches: a kick has to stick, and the daemon blocks by viewer id.
/// A fresh id per launch would let a disconnected viewer walk straight back
/// in by relaunching.
struct SessionIdentity: Equatable {
    /// Where the id lives. Not a `settings`-table row: it identifies this
    /// *installation* to whatever daemon it dials, so it must not travel
    /// with an account's data dir.
    static let viewerIDDefaultsKey = "remote.viewerID"

    let viewerID: String
    let machineName: String

    /// `defaults` is injectable because the test host shares the real app's
    /// defaults domain — a test must never write into it.
    init(
        defaults: UserDefaults = .standard,
        machineName: String = Host.current().localizedName ?? "Mac"
    ) {
        if let existing = defaults.string(forKey: Self.viewerIDDefaultsKey),
           !existing.isEmpty {
            viewerID = existing
        } else {
            let fresh = UUID().uuidString
            defaults.set(fresh, forKey: Self.viewerIDDefaultsKey)
            viewerID = fresh
        }
        self.machineName = machineName
    }
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
    /// The relay answered the WebSocket upgrade with 401: this device's
    /// bearer is signed out, expired or revoked. Retrying with the same
    /// credentials cannot succeed, so the connection stops reconnecting
    /// until an explicit `connect()` supplies a fresh bearer. Only 401 —
    /// a 403 means the host is not registered *yet* and keeps retrying
    /// (`isTokenRefusal`).
    case unauthorized

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "The relay rejected this device's credentials. Sign in again to reconnect."
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

/// Where a `SessionConnection` gets its bytes from. Everything above the
/// transport — the frame codec, attachments, sequence cursors, reconnect and
/// blind reattach, `ResyncRequired` handling — is shared; only how a
/// connection is opened, read, written and closed differs.
enum SessionTransport {
    /// The local PTY daemon's unix socket (`DaemonPaths.socketURL`).
    case unixSocket(URL)
    /// A remote daemon reached through the relay: the URL is
    /// `wss://relay.omni-agent.ai/v1/viewer/<device_id>` and one WebSocket
    /// binary message carries protocol bytes. The bearer is read at every
    /// (re)connect so a refreshed token is picked up without a new
    /// `SessionConnection`. It is invoked on the connection's private
    /// `ioQueue`, never the main thread, so it must read the token store
    /// without touching UI state.
    case webSocket(URL, bearer: @Sendable () -> String?)
}

final class SessionConnection {
    var onStateChange: ((ConnectionState) -> Void)?
    var onTerminalData: ((String, Data, UInt64, Bool) -> Void)?
    var onStatus: ((SessionStatusEvent) -> Void)?
    var onAttention: ((String) -> Void)?
    var onExit: ((SessionExitedEvent) -> Void)?
    var onError: ((Error) -> Void)?
    /// The host's grid for one session — `(sessionID, cols, rows)` — from a
    /// `SessionResized` push (phase 2 §1). The daemon sends one on attach,
    /// just before the snapshot, and again whenever the host resizes. A
    /// local pane ignores it (its own view drives the size); a remote pane
    /// pins its terminal to this grid and scales it into the space it has.
    var onSessionSize: ((String, UInt16, UInt16) -> Void)?
    /// The machines currently watching sessions on this daemon, from a
    /// `RemoteViewers` push (phase 2 §5). Local connections only: the daemon
    /// never tells a viewer about other viewers.
    var onRemoteViewers: (([RemoteViewer]) -> Void)?
    /// One batch of daemon-witnessed activity rows, from a `RemoteActivity`
    /// push (Task 19, spec §8). Local connections only, the same reasoning as
    /// `onRemoteViewers`: a remote viewer must never learn what the log says
    /// about it. A row this build cannot parse (an unparseable timestamp) is
    /// dropped rather than crashing the batch it arrived in.
    var onRemoteActivity: (([RemoteActivityLog.Entry]) -> Void)?
    /// Fires when a **reconnect's automatic reattach** comes back "session
    /// not found" — Task 6c's restart-loss signal. Only the reconnect-time
    /// blind reattach (the `helloAck` handler's loop below) is tracked, not
    /// every `attach(sessionID:afterSequence:)` call: the other call sites
    /// (`WorkspaceWindowController.ensureSession`/`attach`) already check
    /// `listSessions` first, so a failure there would be a genuine protocol
    /// anomaly, not "the daemon restarted and forgot this session."
    var onReattachFailed: ((String) -> Void)?

    private struct Attachment {
        var sequence: UInt64?
    }

    private let transport: SessionTransport
    /// What this Mac calls itself on every `Hello`. Sent on local and remote
    /// connections alike: the daemon records identity only for a remote
    /// client, so there is nothing to branch on, and a local `Hello`
    /// carrying it is harmless.
    private let identity: SessionIdentity
    /// `true` when this connection reaches a daemon on another machine
    /// through the relay (`.webSocket`), `false` for the local unix socket.
    var isRemote: Bool {
        if case .webSocket = transport { return true }
        return false
    }
    private let reconnectDelay: TimeInterval
    private let callbackQueue: DispatchQueue
    private let ioQueue = DispatchQueue(label: "digital.bruno.omniagent.session-connection")
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var frameDecoder = FrameDecoder()
    private var descriptor: Int32 = -1
    private var readSource: DispatchSourceRead?
    /// The live `.webSocket` connection; `nil` for `.unixSocket` and between
    /// connections. Every WebSocket callback checks identity against this
    /// before acting so a stale task's late failure can never close its
    /// successor.
    private var webSocketTask: URLSessionWebSocketTask?
    /// Keeps a relay-routed WebSocket alive: Cloudflare drops idle
    /// WebSockets at ~100 s, so both ends ping every 30 s (spec §1).
    private var pingTimer: DispatchSourceTimer?
    private var nextRequest: UInt64 = 1
    private var helloRequest: UInt64?
    private var pending: [UInt64: (Result<SessionFrame, Error>) -> Void] = [:]
    private var attachments: [String: Attachment] = [:]
    /// Request id -> session id, populated only for the reconnect-time
    /// automatic reattach loop in `handle(_:)`'s `helloAck` branch — what
    /// lets a later `.error` response be recognized as "this reattach
    /// failed" without correlating through `pending` (which `sendAttach`
    /// deliberately never registers into; see its own doc comment).
    ///
    /// Scoped to **one** reattach round: cleared when a round starts, when a
    /// reattach is confirmed (a `.snapshot` for that session, or the
    /// `.response` the daemon sends for an empty resume), and when the
    /// connection closes. It used to be pruned only on the `.error` branch,
    /// so every *successful* reattach left an entry behind forever — one per
    /// session per reconnect, for the life of the app (final whole-branch
    /// review, Minor #10).
    private var pendingReattachSessions: [UInt64: String] = [:]
    /// How many reattach-tracking entries are outstanding. Exists for the
    /// test that pins Minor #10 (the map must not grow without bound across
    /// reconnects); read on `ioQueue`, where every mutation happens, so it
    /// can never race the connection's own I/O.
    var pendingReattachCount: Int { ioQueue.sync { pendingReattachSessions.count } }

    /// Whether **anything** is still listening to this connection's pushes.
    ///
    /// The observable half of the no-chaining property (2026-09-01 remote
    /// environment sharing spec §3): while this app drives another Mac, its
    /// own local connection must have no subscribers left and must not be
    /// attached, because a machine that is driving is not a machine that can
    /// be driven. `WorkspaceWindowController.swapConnection` clears every one
    /// of these on the way out and `ConnectionSwapTests` asserts the result —
    /// a stale capture somewhere else in the app would show up here as a
    /// closure that outlived the swap.
    var hasSubscribers: Bool {
        onStateChange != nil
            || onTerminalData != nil
            || onStatus != nil
            || onAttention != nil
            || onExit != nil
            || onError != nil
            || onSessionSize != nil
            || onRemoteViewers != nil
            || onRemoteActivity != nil
            || onReattachFailed != nil
    }

    /// Whether this connection is attached or trying to be — `connect()` sets
    /// it, `disconnect()` clears it. Read on `ioQueue`, where it is owned, so
    /// it cannot race a connect or a close, and ordered *after* the
    /// `disconnect()` that precedes it because that queue is serial.
    var wantsConnection: Bool { ioQueue.sync { shouldReconnect } }

    private var shouldReconnect = false
    private var reconnectScheduled = false
    /// The delay the *next* remote reconnect waits. Doubles per failed
    /// attempt up to `maximumRemoteReconnectDelay` and resets to
    /// `reconnectDelay` once a HelloAck lands or an explicit `connect()`
    /// starts over. Only `.webSocket` reads it: the unix socket keeps its
    /// fixed `reconnectDelay`, a local daemon comes back in milliseconds.
    private var nextReconnectDelay: TimeInterval
    /// Backoff ceiling for a relay that stays unreachable — a machine that
    /// is offline for an hour dials Cloudflare twice a minute, not four
    /// times a second.
    private static let maximumRemoteReconnectDelay: TimeInterval = 30
    private var state: ConnectionState = .disconnected
    private var connectSignpost: OSSignpostID?

    init(
        transport: SessionTransport,
        reconnectDelay: TimeInterval = 0.25,
        callbackQueue: DispatchQueue = .main,
        identity: SessionIdentity = SessionIdentity()
    ) {
        self.transport = transport
        self.reconnectDelay = reconnectDelay
        self.nextReconnectDelay = reconnectDelay
        self.callbackQueue = callbackQueue
        self.identity = identity
    }

    /// The local daemon — every pre-existing call site, unchanged.
    convenience init(
        socketURL: URL,
        reconnectDelay: TimeInterval = 0.25,
        callbackQueue: DispatchQueue = .main,
        identity: SessionIdentity = SessionIdentity()
    ) {
        self.init(
            transport: .unixSocket(socketURL),
            reconnectDelay: reconnectDelay,
            callbackQueue: callbackQueue,
            identity: identity
        )
    }

    deinit {
        if descriptor >= 0 {
            Darwin.close(descriptor)
        }
        pingTimer?.cancel()
        webSocketTask?.cancel(with: .goingAway, reason: nil)
    }

    func connect() {
        ioQueue.async {
            self.shouldReconnect = true
            // An explicit connect is a fresh start — after `.unauthorized`
            // (B4 calls this with a new bearer) or a long outage, the first
            // retry must not inherit the old backoff.
            self.nextReconnectDelay = self.reconnectDelay
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

    /// The pid on the other end of the connected unix-socket descriptor —
    /// `getsockopt(SOL_LOCAL, LOCAL_PEERPID)` — i.e. the daemon this
    /// connection is actually attached to, which is the only daemon
    /// `DaemonPersistenceController.terminateDaemon` may ever signal. `nil`
    /// while disconnected and for the relay transport, where the peer is a
    /// WebSocket on another machine. Read on `ioQueue`, where the descriptor
    /// is owned, so it can never race a connect or a close.
    func peerProcessID() -> pid_t? {
        ioQueue.sync {
            guard descriptor >= 0 else { return nil }
            var pid: pid_t = 0
            var length = socklen_t(MemoryLayout<pid_t>.size)
            // <sys/un.h>: SOL_LOCAL is 0, LOCAL_PEERPID is 0x002; both are
            // plain integer macros and import into Swift as-is.
            guard getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0, pid > 0 else {
                return nil
            }
            return pid
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

    // MARK: - Settings (Task 6a)

    /// Reads one `settings`-table row (e.g. `LAYOUT_SETTING_KEY`'s `"layout"`
    /// row) — `nil` when unset, mirroring `Store::get_setting` and the Tauri
    /// `settings_get` command's `Option<String>` result exactly.
    func getSetting(key: String, completion: @escaping (Result<String?, Error>) -> Void) {
        sendCodable(kind: .getSetting, value: SettingKeyPayload(key: key)) { result in
            completion(
                result.flatMap { frame in
                    guard frame.kind == .response else {
                        return .failure(SessionConnectionError.invalidResponse(frame.kind))
                    }
                    return Result {
                        try self.decoder.decode(SettingValueResponse.self, from: frame.payload).value
                    }
                }
            )
        }
    }

    /// Upserts a `settings`-table row.
    func setSetting(
        key: String,
        value: String,
        completion: ((Result<Void, Error>) -> Void)? = nil
    ) {
        sendCodable(kind: .setSetting, value: SettingValuePayload(key: key, value: value)) {
            self.finishResponse($0, completion: completion)
        }
    }

    // MARK: - Viewer presence (phase 2 §5)

    /// The machines currently watching sessions on this daemon, on demand —
    /// the same roster the `RemoteViewers` push carries, for a surface that
    /// opens after the last push. Local connections only: `ListViewers` is
    /// in the daemon's `authorize_remote` deny arm, so a remote connection
    /// gets an `.error` here rather than a roster.
    func listViewers(completion: @escaping (Result<[RemoteViewer], Error>) -> Void) {
        request(kind: .listViewers, payload: Data("{}".utf8)) { result in
            completion(
                result.flatMap { frame in
                    guard frame.kind == .response else {
                        return .failure(SessionConnectionError.invalidResponse(frame.kind))
                    }
                    return Result {
                        try self.decoder.decode(RemoteViewersPayload.self, from: frame.payload).viewers
                    }
                }
            )
        }
    }

    /// Kicks one viewer: the daemon drops its data WebSocket immediately.
    ///
    /// **Terminate and Block are two different verbs** (2026-09-01 remote
    /// environment sharing spec §7, daemon Task 14). `block: false`
    /// terminates — the socket goes and the machine is free to dial straight
    /// back. `block: true` also appends the viewer id to the daemon's own
    /// `remote_control_blocked` row, so it is refused at its next `Hello`
    /// until someone unblocks it in Settings › Remote. The daemon is the only
    /// writer of that row; the app only ever removes from it
    /// (`RemoteSharingModel.unblock`).
    ///
    /// `block` defaults to `true`, which is what `DisconnectViewer` meant
    /// before the field existed — phase 2's popover Disconnect keeps its
    /// behaviour without naming it. Local-only, like `listViewers`.
    func disconnectViewer(
        viewerID: String,
        block: Bool = true,
        completion: ((Result<Void, Error>) -> Void)? = nil
    ) {
        sendCodable(
            kind: .disconnectViewer,
            value: DisconnectViewerPayload(viewerID: viewerID, block: block)
        ) {
            self.finishResponse($0, completion: completion)
        }
    }

    // MARK: - Host state (spec §4, Task 22)

    /// Publishes this host's own state — `HostStatePublisher.payload()` —
    /// to whichever remote connection currently holds the lease. `payload`
    /// is sent **verbatim**, never through `sendCodable`: it is already the
    /// wire JSON, and re-encoding it here would be a second pass through the
    /// same promise the daemon already keeps — that it never parses this
    /// payload. Local-only, like `disconnectViewer`.
    func publishHostState(_ payload: Data, completion: ((Result<Void, Error>) -> Void)? = nil) {
        request(kind: .publishHostState, payload: payload) {
            self.finishResponse($0, completion: completion)
        }
    }

    // MARK: - Brain reads (Task 6a)

    /// Every ingested project — `mcp_server::tools::list_projects`'s frozen
    /// shape, unchanged whether read via this daemon route or the Tauri
    /// `brain_query { kind: "list_projects" }` command.
    func listProjects(completion: @escaping (Result<[BrainProjectSummary], Error>) -> Void) {
        request(kind: .brainListProjects, payload: Data("{}".utf8)) { result in
            completion(
                result.flatMap { frame in
                    guard frame.kind == .response else {
                        return .failure(SessionConnectionError.invalidResponse(frame.kind))
                    }
                    return Result {
                        try self.decoder.decode(BrainListProjectsResponse.self, from: frame.payload)
                            .projects
                    }
                }
            )
        }
    }

    /// One project's briefing block — `mcp_server::tools::get_context`'s
    /// frozen shape. An unknown `project` is not an error: it degrades to an
    /// empty briefing, same as the Tauri `brain_get_context` command backed
    /// by the same shared tool.
    func getContext(project: String, completion: @escaping (Result<BrainContext, Error>) -> Void) {
        sendCodable(kind: .brainGetContext, value: BrainGetContextPayload(project: project)) { result in
            completion(
                result.flatMap { frame in
                    guard frame.kind == .response else {
                        return .failure(SessionConnectionError.invalidResponse(frame.kind))
                    }
                    return Result {
                        try self.decoder.decode(BrainGetContextResponse.self, from: frame.payload).context
                    }
                }
            )
        }
    }

    // MARK: - Roots / ingestion (Task 6a-2)

    /// Persists `path` as a known project root and kicks off background
    /// ingestion for every project discovered under it — the first-run
    /// folder picker's whole job. Mirrors `roots_start_ingest`.
    func startIngest(path: String, completion: ((Result<Void, Error>) -> Void)? = nil) {
        sendCodable(kind: .rootsStartIngest, value: RootsStartIngestPayload(path: path)) {
            self.finishResponse($0, completion: completion)
        }
    }

    /// Polls the daemon's own in-flight (or just-finished) ingestion
    /// snapshot. Mirrors `ingestion_status`.
    func ingestionStatus(completion: @escaping (Result<IngestionStatus, Error>) -> Void) {
        request(kind: .rootsIngestionStatus, payload: Data("{}".utf8)) { result in
            completion(
                result.flatMap { frame in
                    guard frame.kind == .response else {
                        return .failure(SessionConnectionError.invalidResponse(frame.kind))
                    }
                    return Result {
                        try self.decoder.decode(RootsIngestionStatusResponse.self, from: frame.payload).status
                    }
                }
            )
        }
    }

    /// Every persisted project root. Mirrors `roots_list`.
    func rootsList(completion: @escaping (Result<[String], Error>) -> Void) {
        request(kind: .rootsList, payload: Data("{}".utf8)) { result in
            completion(
                result.flatMap { frame in
                    guard frame.kind == .response else {
                        return .failure(SessionConnectionError.invalidResponse(frame.kind))
                    }
                    return Result {
                        try self.decoder.decode(RootsListResponse.self, from: frame.payload).roots
                    }
                }
            )
        }
    }

    /// The project with the most nodes in the store — offers a first
    /// terminal tab on it. `nil` when nothing has been ingested yet. Mirrors
    /// `roots_biggest_project`.
    func biggestProject(completion: @escaping (Result<BrainProjectSummary?, Error>) -> Void) {
        request(kind: .rootsBiggestProject, payload: Data("{}".utf8)) { result in
            completion(
                result.flatMap { frame in
                    guard frame.kind == .response else {
                        return .failure(SessionConnectionError.invalidResponse(frame.kind))
                    }
                    return Result {
                        try self.decoder.decode(RootsBiggestProjectResponse.self, from: frame.payload).project
                    }
                }
            )
        }
    }

    /// Adds exactly one project directory, synchronously creating its node
    /// and kicking off background ingestion. Mirrors `add_project`.
    func addProject(
        path: String,
        name: String? = nil,
        completion: @escaping (Result<BrainProjectSummary, Error>) -> Void
    ) {
        sendCodable(kind: .rootsAddProject, value: RootsAddProjectPayload(path: path, name: name)) { result in
            completion(
                result.flatMap { frame in
                    guard frame.kind == .response else {
                        return .failure(SessionConnectionError.invalidResponse(frame.kind))
                    }
                    return Result {
                        try self.decoder.decode(RootsAddProjectResponse.self, from: frame.payload).project
                    }
                }
            )
        }
    }

    /// Overrides a project's display label. Mirrors `rename_project`.
    func renameProject(
        id: String,
        newLabel: String,
        completion: ((Result<Void, Error>) -> Void)? = nil
    ) {
        sendCodable(
            kind: .rootsRenameProject,
            value: RootsRenameProjectPayload(id: id, newLabel: newLabel)
        ) {
            self.finishResponse($0, completion: completion)
        }
    }

    /// Every project id currently marked paused. Mirrors
    /// `roots_paused_projects`.
    func pausedProjects(completion: @escaping (Result<[String], Error>) -> Void) {
        request(kind: .rootsPausedProjects, payload: Data("{}".utf8)) { result in
            completion(
                result.flatMap { frame in
                    guard frame.kind == .response else {
                        return .failure(SessionConnectionError.invalidResponse(frame.kind))
                    }
                    return Result {
                        try self.decoder.decode(RootsPausedProjectsResponse.self, from: frame.payload).projects
                    }
                }
            )
        }
    }

    /// Marks a project paused/unpaused for future ingest/rebuild passes.
    /// Mirrors `roots_set_paused`.
    func setPaused(
        project: String,
        paused: Bool,
        completion: ((Result<Void, Error>) -> Void)? = nil
    ) {
        sendCodable(
            kind: .rootsSetPaused,
            value: RootsSetPausedPayload(project: project, paused: paused)
        ) {
            self.finishResponse($0, completion: completion)
        }
    }

    /// Every project's staleness reading. Mirrors `roots_staleness`.
    func staleness(completion: @escaping (Result<[ProjectStaleness], Error>) -> Void) {
        request(kind: .rootsStaleness, payload: Data("{}".utf8)) { result in
            completion(
                result.flatMap { frame in
                    guard frame.kind == .response else {
                        return .failure(SessionConnectionError.invalidResponse(frame.kind))
                    }
                    return Result {
                        try self.decoder.decode(RootsStalenessResponse.self, from: frame.payload).projects
                    }
                }
            )
        }
    }

    /// Manual "re-check" for one already-known project. Mirrors
    /// `roots_reingest_project`.
    func reingestProject(project: String, completion: ((Result<Void, Error>) -> Void)? = nil) {
        sendCodable(
            kind: .rootsReingestProject,
            value: RootsReingestProjectPayload(project: project)
        ) {
            self.finishResponse($0, completion: completion)
        }
    }

    /// "Rebuild brain": wipes and re-ingests the whole store. Mirrors
    /// `roots_rebuild`.
    func rebuildBrain(completion: ((Result<Void, Error>) -> Void)? = nil) {
        request(kind: .rootsRebuild, payload: Data("{}".utf8)) { result in
            self.finishResponse(result, completion: completion)
        }
    }

    // MARK: - Search (Task 6a-2)

    /// Full-text search over the local knowledge graph. Mirrors
    /// `mcp_server::tools::search_brain` — the native command palette's
    /// brain search route.
    func search(
        query: String,
        scope: String? = nil,
        completion: @escaping (Result<[BrainNodeView], Error>) -> Void
    ) {
        sendCodable(kind: .brainSearch, value: BrainSearchPayload(query: query, scope: scope)) { result in
            completion(
                result.flatMap { frame in
                    guard frame.kind == .response else {
                        return .failure(SessionConnectionError.invalidResponse(frame.kind))
                    }
                    return Result {
                        try self.decoder.decode(BrainSearchResponse.self, from: frame.payload).results
                    }
                }
            )
        }
    }

    private func openConnection() {
        guard descriptor < 0, webSocketTask == nil, shouldReconnect else { return }
        transition(to: .connecting)
        let signpost = OSSignpostID(log: Instrumentation.log)
        connectSignpost = signpost
        os_signpost(
            .begin,
            log: Instrumentation.log,
            name: "Daemon Connect",
            signpostID: signpost
        )
        switch transport {
        case let .unixSocket(url):
            openUnixSocket(path: url.path)
        case let .webSocket(url, bearer):
            openWebSocket(url, bearer: bearer())
        }
    }

    private func openUnixSocket(path: String) {
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
            connectionResult = try withUnixSocketAddress(path: path) {
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
        sendHello()
    }

    /// One WebSocket binary message carries protocol bytes. The relay is a
    /// dumb pipe and the daemon writes frames the same way it does to the
    /// unix socket, so a frame may straddle messages: every received
    /// message goes through `frameDecoder.append`, never a per-message
    /// decode.
    private func openWebSocket(_ url: URL, bearer: String?) {
        var request = URLRequest(url: url)
        if let bearer {
            request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        }
        let task = URLSession.shared.webSocketTask(with: request)
        webSocketTask = task
        frameDecoder = FrameDecoder()
        task.resume()
        receiveNextMessage(task)
        let timer = DispatchSource.makeTimerSource(queue: ioQueue)
        timer.schedule(deadline: .now() + 30, repeating: 30)
        timer.setEventHandler { [weak task] in task?.sendPing { _ in } }
        timer.resume()
        pingTimer = timer
        sendHello()
    }

    private func receiveNextMessage(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }
            self.ioQueue.async {
                guard self.webSocketTask === task else { return }
                switch result {
                case let .success(.data(data)):
                    do {
                        for frame in try self.frameDecoder.append(data) {
                            self.handle(frame)
                        }
                    } catch {
                        self.closeConnection(error: error)
                        return
                    }
                case .success(.string):
                    break
                case .success:
                    break
                case let .failure(error):
                    self.webSocketFailed(task, error: error)
                    return
                }
                self.receiveNextMessage(task)
            }
        }
    }

    /// The first frame on every fresh connection, whichever transport
    /// carried it; `handle(_:)` completes the handshake on the matching
    /// `helloAck`.
    private func sendHello() {
        let request = takeRequest()
        helloRequest = request
        do {
            try send(
                SessionFrame(
                    kind: .hello,
                    requestOrSequence: request,
                    payload: try encoder.encode(
                        HelloPayload(
                            client: "omniagent-native-macos",
                            viewerID: identity.viewerID,
                            machineName: identity.machineName
                        )
                    )
                )
            )
        } catch {
            closeConnection(error: error)
        }
    }

    /// Whether a `Hello` refusal's **code** — never its sentence, with one
    /// narrow, bounded exception below — is one that dialling again cannot
    /// fix (Task 14 item 2; fix round 1).
    ///
    /// Only `RefusalCode.versionSkew` is. Version skew is a refusal with a
    /// human in its way: nothing changes until someone updates the other Mac,
    /// so retrying is a loop with a dead keyboard — phase 1's exact failure,
    /// which is what the refusal exists to replace.
    ///
    /// Every other code clears itself. A lease held elsewhere is transient by
    /// nature, and it is the refusal a viewer sees when it *re-dials after a
    /// blip*, because the relay holds two sockets for one machine until the
    /// dead one is reaped — parking there would turn a refusal that resolves in
    /// a second into one that needs the user to start over. Blocked is the same
    /// shape: the host turning sharing off and on lifts it, with nothing for
    /// this end to do but keep asking on the backoff it already has.
    ///
    /// **An unrecognised code defaults to non-terminal, on purpose.** A code
    /// this build has never heard of is what a daemon ahead of this app sends,
    /// for some future refusal neither side has written yet — wrongly
    /// continuing to retry costs one more backoff cycle and self-corrects the
    /// moment this app updates; wrongly parking strands the connection with no
    /// cause visible anywhere on this end.
    ///
    /// **An absent code is not the same question, and does not get the same
    /// answer.** No code at all is what a daemon *built before this contract
    /// existed* sends — for every refusal, version skew included — and that is
    /// exactly the pairing remote sharing exists for: two Macs updated
    /// independently, one of them old. Treating an absent code as uniformly
    /// non-terminal would make a genuinely version-skewed old daemon redial
    /// forever against a peer that cannot change without a human updating
    /// it — phase 1's dead-keyboard failure, reintroduced in the one case this
    /// whole feature targets. So there is a narrow, bounded legacy bridge for
    /// this one case only: **no code, and the message carries the stable
    /// `"update OmniAgent"` prefix `server.rs`'s `send_handshake_error` has
    /// always sent for version skew** (that function exists specifically so a
    /// skewed peer can still decode its own refusal, so this is a designed-for
    /// path, not a hypothetical one). Any other message with no code stays
    /// non-terminal. This is not the general string contract coming back —
    /// every *other* classification here keys on the code alone — it is one
    /// fallback for peers old enough to predate `code` entirely, and it can be
    /// deleted once no un-updated daemon can be met.
    ///
    /// Before this field existed, the whole classification was a prefix match
    /// on the sentence — one string literal on each side of the wire that
    /// happened to agree — and a routine copy edit to `server.rs`'s "update
    /// OmniAgent on …" could silently turn a terminal refusal into an infinite
    /// retry loop, with nothing to catch it. The code is the fix for every
    /// case a current daemon can send; the prefix survives only as the
    /// narrowly-scoped bridge above.
    static func isTerminalRefusal(_ code: String?, message: String) -> Bool {
        guard let code else {
            return message.hasPrefix(Self.legacyVersionSkewPrefix)
        }
        return RefusalCode(rawValue: code) == .versionSkew
    }

    /// The opening of the daemon's version-skew sentence
    /// (`crates/omniagent-pty-daemon/src/server.rs`, `send_handshake_error`),
    /// read only when a `Hello` refusal carries no `code` at all — a daemon
    /// built before Task 14 item 2. See `isTerminalRefusal` for why this one
    /// case still reads the sentence.
    private static let legacyVersionSkewPrefix = "update OmniAgent"

    /// The daemon answered `Hello` with an `Error` instead of a `HelloAck` —
    /// it looked at who is connecting and said no.
    ///
    /// The message is reported through `onError`, which is where the connect
    /// ceremony reads it (spec §6, step 3). A terminal refusal additionally
    /// clears `shouldReconnect`, which has to happen *before* the close,
    /// because `closeConnection` ends by scheduling a reconnect.
    private func refusedAtHello(_ frame: SessionFrame) {
        let payload = try? decoder.decode(ErrorPayload.self, from: frame.payload)
        let message = payload?.message ?? "The daemon refused the connection."
        helloRequest = nil
        if Self.isTerminalRefusal(payload?.code, message: message) {
            shouldReconnect = false
            nextReconnectDelay = reconnectDelay
        }
        closeConnection(error: SessionConnectionError.daemon(message))
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
        let delay: TimeInterval
        if isRemote {
            delay = nextReconnectDelay
            nextReconnectDelay = min(nextReconnectDelay * 2, Self.maximumRemoteReconnectDelay)
        } else {
            delay = reconnectDelay
        }
        ioQueue.asyncAfter(deadline: .now() + delay) {
            self.reconnectScheduled = false
            self.openConnection()
        }
    }

    /// Whether an upgrade status means "this bearer will never work" — the
    /// only reason to stop dialling the relay.
    ///
    /// Phase 1 parked on 403 too, and that was the loudest defect of the
    /// first build: the relay answers **403** for "that device's control
    /// channel is not registered yet", a race every viewer loses when it
    /// polls before the host's daemon has opened its control WebSocket. One
    /// early dial then blinded the viewer to that Mac until the app was
    /// relaunched. 403 (and 5xx, and everything else) is transient: keep
    /// retrying on the existing backoff.
    static func isTokenRefusal(status: Int) -> Bool { status == 401 }

    /// Every WebSocket-side failure (the receive loop's and `send`'s) lands
    /// here. A 401 on the upgrade is not an outage: the relay looked at the
    /// bearer and refused it, so reconnecting with the same one would dial
    /// `relay.omni-agent.ai` four times a second for nothing. Report
    /// `.unauthorized` once and stop until an explicit `connect()`.
    private func webSocketFailed(_ task: URLSessionWebSocketTask, error: Error) {
        guard webSocketTask === task else { return }
        if let status = (task.response as? HTTPURLResponse)?.statusCode,
           Self.isTokenRefusal(status: status) {
            shouldReconnect = false
            nextReconnectDelay = reconnectDelay
            closeConnection(error: SessionConnectionError.unauthorized)
            return
        }
        closeConnection(error: error)
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
            // The relay is reachable again: the next outage starts its
            // backoff from the seed, not from wherever the last one ended.
            nextReconnectDelay = reconnectDelay
            // A new round: anything left from the previous connection's
            // round can never be answered now.
            pendingReattachSessions.removeAll()
            for (sessionID, attachment) in attachments {
                sendAttach(
                    sessionID: sessionID,
                    afterSequence: attachment.sequence,
                    trackReattachFailure: true
                )
            }
            return
        }
        if frame.kind == .error, frame.requestOrSequence == helloRequest {
            refusedAtHello(frame)
            return
        }

        switch frame.kind {
        case .response, .sessionList, .sessionCreated:
            // The daemon answers an empty resume with a plain `.response`
            // on the attach's own request id — a confirmed reattach.
            pendingReattachSessions.removeValue(forKey: frame.requestOrSequence)
            completeRequest(frame)
        case .error:
            let message =
                (try? decoder.decode(ErrorPayload.self, from: frame.payload).message)
                ?? "The daemon rejected the request."
            if let sessionID = pendingReattachSessions.removeValue(forKey: frame.requestOrSequence) {
                // The daemon no longer knows this session — it forgot
                // because it restarted, not because the app asked for
                // something invalid. Stop reattaching to it on the next
                // reconnect, and let the caller (`WorkspaceWindowController`)
                // report the loss rather than retry forever.
                attachments.removeValue(forKey: sessionID)
                callbackQueue.async { self.onReattachFailed?(sessionID) }
            }
            completeRequest(
                frame,
                result: .failure(SessionConnectionError.daemon(message))
            )
        case .snapshot, .output:
            do {
                let raw = try RawPayload.decode(frame.payload)
                if frame.kind == .snapshot {
                    // A snapshot is the daemon's answer to an attach. It
                    // carries a *sequence*, not the attach's request id, so
                    // the tracking entry has to be found by session instead.
                    pendingReattachSessions = pendingReattachSessions.filter {
                        $0.value != raw.sessionID
                    }
                }
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
        case .sessionResized:
            // Deliberately *not* run through `updateSequence`: a resize is
            // not terminal output, and advancing a session's resume cursor
            // past output it has not received would drop that output on the
            // next reattach.
            if let size = try? decoder.decode(SessionSizePayload.self, from: frame.payload) {
                callbackQueue.async { self.onSessionSize?(size.id, size.cols, size.rows) }
            }
        case .remoteViewers:
            if let payload = try? decoder.decode(RemoteViewersPayload.self, from: frame.payload) {
                callbackQueue.async { self.onRemoteViewers?(payload.viewers) }
            }
        case .remoteActivity:
            if let payload = try? decoder.decode(RemoteActivityPushPayload.self, from: frame.payload) {
                var entries = payload.entries.compactMap(RemoteActivityLog.Entry.init(wire:))
                // Fix round 1, IMPORTANT 2: a gap this feed fell behind is
                // put on screen, not silently skipped — and it comes first,
                // since it covers whatever happened *before* the entries in
                // this same push.
                if payload.dropped > 0 {
                    entries.insert(.init(gapCount: payload.dropped), at: 0)
                }
                callbackQueue.async { self.onRemoteActivity?(entries) }
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

    private func sendAttach(
        sessionID: String,
        afterSequence: UInt64?,
        trackReattachFailure: Bool = false
    ) {
        do {
            let request = takeRequest()
            if trackReattachFailure {
                pendingReattachSessions[request] = sessionID
            }
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
        if let task = webSocketTask {
            task.send(.data(data)) { [weak self] error in
                guard let self, let error else { return }
                self.ioQueue.async {
                    // `webSocketFailed` drops a stale task's late failure
                    // so it can never close its successor.
                    self.webSocketFailed(task, error: error)
                }
            }
        } else {
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
        pingTimer?.cancel()
        pingTimer = nil
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        helloRequest = nil
        // Per-connection state: a reattach whose connection is gone can
        // never be answered on it.
        pendingReattachSessions.removeAll()
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

/// `{client, viewer_id, machine_name}` (phase 2 §5). The daemon declares the
/// two identity fields `Option` with `#[serde(default)]` and ignores unknown
/// fields, so this stays readable by a daemon that predates them.
private struct HelloPayload: Codable {
    let client: String
    let viewerID: String
    let machineName: String

    enum CodingKeys: String, CodingKey {
        case client
        case viewerID = "viewer_id"
        case machineName = "machine_name"
    }
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
    /// The wire value of `omniagent_pty_daemon::protocol::RefusalCode`
    /// (Task 14 item 2), kept as a raw `String?` rather than decoded straight
    /// into `RefusalCode` — decoding a `String`-backed enum synthesised by
    /// `Codable` *throws* on a raw value it does not recognise, and that
    /// would fail this whole payload's decode, losing `message` along with
    /// it, the moment a daemon ahead of this app sends a code this build has
    /// never heard of. `RefusalCode(rawValue:)` is where "unknown" gets
    /// decided instead, at the one place that reads it —
    /// `isTerminalRefusal`. Absent entirely on an `Error` a daemon built
    /// before this field existed sends, or on any `Error` outside the
    /// `Hello` arm — both decode to `nil` the same ordinary way any missing
    /// `Optional` key does.
    let code: String?
}

/// Mirrors `omniagent_pty_daemon::protocol::RefusalCode`
/// (`crates/omniagent-pty-daemon/src/protocol.rs`) — the wire values on both
/// sides must agree, kept in step by hand since nothing generates one side
/// from the other. Read only by `isTerminalRefusal`; every other user of a
/// refusal reads `ErrorPayload.message` instead, which stays free to reword.
///
/// Internal rather than `private`, solely so
/// `testRefusalCodeWireValuesMatchTheRustEnum` (`SessionConnectionTests.swift`,
/// via `@testable import`) can pin each case's raw value against a literal
/// list identical to Rust's `refusal_code_wire_values_are_frozen`
/// (`crates/omniagent-pty-daemon/tests/protocol.rs`) — the mirror-image half
/// of that test, so a wire string changed on either side without the other
/// turns exactly one of the two red (fix round 1, FIX 2).
enum RefusalCode: String {
    case versionSkew = "version_skew"
    case leaseHeld = "lease_held"
    case machineUnavailable = "machine_unavailable"
    case hostSignedOut = "host_signed_out"
    case wrongAccount = "wrong_account"
    case blocked = "blocked"
}

/// `SessionResized`'s payload — the daemon's `SessionSizePayload`
/// (`{id, cols, rows}`), the host's current grid for one session.
private struct SessionSizePayload: Codable {
    let id: String
    let cols: UInt16
    let rows: UInt16
}

/// The `RemoteViewers` push payload, and `ListViewers`' `Response` payload —
/// the same `{"viewers": [...]}` shape on both routes.
private struct RemoteViewersPayload: Codable {
    let viewers: [RemoteViewer]
}

private struct DisconnectViewerPayload: Codable {
    let viewerID: String
    /// Kick and keep out (`true`) or kick only (`false`) — the daemon's
    /// `DisconnectViewerPayload.block`. Always sent explicitly from here;
    /// the daemon's `#[serde(default)]` covers callers older than the field.
    let block: Bool

    enum CodingKeys: String, CodingKey {
        case viewerID = "viewer_id"
        case block
    }
}

private struct SettingKeyPayload: Codable {
    let key: String
}

private struct SettingValuePayload: Codable {
    let key: String
    let value: String
}

/// `GetSetting`'s `Response` payload shape (`{"value": ...}` — the daemon
/// wraps the raw `Option<String>` under a named key rather than sending a
/// bare JSON string/null, since `Response` is also used for plain acks).
private struct SettingValueResponse: Codable {
    let value: String?
}

private struct BrainGetContextPayload: Codable {
    let project: String
}

/// `BrainListProjects`'s `Response` payload shape (`{"projects": [...]}`).
private struct BrainListProjectsResponse: Codable {
    let projects: [BrainProjectSummary]
}

/// `BrainGetContext`'s `Response` payload shape (`{"context": {...}}`).
private struct BrainGetContextResponse: Codable {
    let context: BrainContext
}

// MARK: - Roots / ingestion payloads (Task 6a-2)

private struct RootsStartIngestPayload: Codable {
    let path: String
}

private struct RootsAddProjectPayload: Codable {
    let path: String
    let name: String?
}

private struct RootsRenameProjectPayload: Codable {
    let id: String
    let newLabel: String

    enum CodingKeys: String, CodingKey {
        case id
        case newLabel = "new_label"
    }
}

private struct RootsSetPausedPayload: Codable {
    let project: String
    let paused: Bool
}

private struct RootsReingestProjectPayload: Codable {
    let project: String
}

private struct RootsListResponse: Codable {
    let roots: [String]
}

private struct RootsBiggestProjectResponse: Codable {
    let project: BrainProjectSummary?
}

private struct RootsAddProjectResponse: Codable {
    let project: BrainProjectSummary
}

private struct RootsPausedProjectsResponse: Codable {
    let projects: [String]
}

/// `ingestion_status`'s polled snapshot shape — `IngestionStatus`'s frozen
/// Serde projection (`brain_ingest::roots::IngestionStatus`), unchanged
/// whether read via this daemon route or the Tauri `ingestion_status`
/// command.
struct IngestionStatus: Codable, Equatable {
    let running: Bool
    let projectsTotal: Int
    let projectsDone: Int
    let currentProject: String?
    let totalNodes: Int
    let error: String?

    enum CodingKeys: String, CodingKey {
        case running
        case projectsTotal = "projects_total"
        case projectsDone = "projects_done"
        case currentProject = "current_project"
        case totalNodes = "total_nodes"
        case error
    }
}

private struct RootsIngestionStatusResponse: Codable {
    let status: IngestionStatus
}

/// One project's staleness reading — `roots_staleness`'s frozen
/// `{project, last_ingested, stale}` shape.
struct ProjectStaleness: Codable, Equatable {
    let project: String
    let lastIngested: Int64?
    let stale: Bool

    enum CodingKeys: String, CodingKey {
        case project
        case lastIngested = "last_ingested"
        case stale
    }
}

private struct RootsStalenessResponse: Codable {
    let projects: [ProjectStaleness]
}

// MARK: - Search payloads (Task 6a-2)

private struct BrainSearchPayload: Codable {
    let query: String
    let scope: String?
}

/// `BrainSearch`'s `Response` payload shape (`{"results": [...]}`) — reuses
/// `BrainNodeView`, the same `{id, kind, project, label, path?, summary?}`
/// projection `search_brain`/`related`/`get_context` all share.
private struct BrainSearchResponse: Codable {
    let results: [BrainNodeView]
}

/// Not `private`: `DaemonSocketProbe` (`DaemonServiceRegistrar.swift`)
/// reuses this to fill a `sockaddr_un` correctly rather than duplicating
/// this unsafe-pointer code a second time.
func withUnixSocketAddress<T>(
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
