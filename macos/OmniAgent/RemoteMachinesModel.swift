import Foundation

/// The slice of `SessionConnection` the viewer-side model drives: open,
/// close, read one settings row, and hear about the socket's state. Kept to
/// these five members on purpose — everything else a remote pane needs
/// (attach, input, terminal data) is the pane's business, done on the
/// concrete `SessionConnection` the pane factory is handed. A protocol so a
/// test can stand in a connection that never dials anything.
protocol RemoteConnection: AnyObject {
    var onStateChange: ((ConnectionState) -> Void)? { get set }
    var onError: ((Error) -> Void)? { get set }
    func connect()
    func disconnect()
    func getSetting(key: String, completion: @escaping (Result<String?, Error>) -> Void)
}

extension SessionConnection: RemoteConnection {}

/// One machine on this account that the relay reports connected, with the
/// `remote_control` row it shares — what the sidebar's remote sections and
/// the spotlight's remote rows are drawn from.
struct RemoteMachine: Equatable {
    let deviceID: String
    let name: String
    let projection: RemoteControlProjection.Payload
}

/// The viewer side's device list (the remote-session-control spec's §4
/// "Viewer side", docs/superpowers/specs/2026-08-30-remote-session-control-design.md):
/// polls `RelayClient.listDevices()` while signed in, keeps exactly one
/// `SessionConnection` per online machine, and reads each machine's
/// `remote_control` projection through it.
///
/// Rules, in the order a poll applies them:
/// - A device seen online for the first time gets a connection, `connect()`ed
///   at once, and its projection is read — on the spot (a test double
///   answers synchronously) and again on every `.connected` transition, since
///   the real socket is not up yet when the first read goes out.
/// - A device that is online but whose socket is **down** is `connect()`ed
///   again by every poll, so this model's promise — "the relay says it is
///   online, so we are dialling it" — no longer rests on the transport
///   never giving up on its own. One dial per poll at most; a dial already
///   in flight is left alone. It is not free: an explicit `connect()` is a
///   fresh start for the transport, so a machine that stays down ramps its
///   backoff from the seed again every thirty seconds rather than settling
///   at the 30 s cap. Noticing a host the moment it registers is worth more
///   than those dials.
///   Phase 1 re-dialled only when the bearer had *changed*, which in-session
///   it does not for fifteen minutes, so the relay's 403 for "that device's
///   control channel is not registered yet" (the race a viewer loses the
///   moment the host enables sharing) stranded that Mac until the app was
///   relaunched: with no live connection the projection read can never
///   succeed, and a machine with no projection is not in `machines` at all.
///   Only a refused *token* still parks a connection, keyed on the bearer.
/// - A device that goes offline is `disconnect()`ed and leaves `machines`,
///   but its connection object is **retained**: panes opened on it keep
///   routing through that object (`retainedConnection(for:)`), so when the
///   machine is back the same object is `connect()`ed again and those panes
///   resume through the connection's own reattach, rather than being
///   stranded on a twin. Only `stop()` and signing out release them.
/// - A relay outage never surfaces: `listDevices()` failures are swallowed
///   and the last answer stands (spec §6, "Relay restart / Core deploy").
/// - Signed out: everything is disconnected and cleared without asking the
///   relay.
///
/// Main-thread only for its state, `RelayClient`'s rule: `refresh()` awaits
/// the relay wherever it is called from and applies the answer on the main
/// actor, which is also where every connection callback lands
/// (`SessionConnection`'s default `callbackQueue`).
final class RemoteMachinesModel {
    /// Online machines with a decoded projection, sorted by name.
    private(set) var machines: [RemoteMachine] = [] {
        didSet {
            guard machines != oldValue else { return }
            onChange?()
        }
    }
    var onChange: (() -> Void)?
    /// A connection was just created for a device. The window controller
    /// installs its pane-side handlers (`onTerminalData`, `onStatus`,
    /// `onExit`, …) here, once per object. `onStateChange` and `onError` are
    /// this model's — it needs both — and are forwarded through the two
    /// hooks below instead.
    var onConnectionCreated: ((String, RemoteConnection) -> Void)?
    var onConnectionStateChange: ((String, ConnectionState) -> Void)?
    var onConnectionError: ((String, Error) -> Void)?

    private(set) var isRunning = false
    /// Whether a socket-side token refusal has asked for a fresh session
    /// since the last sign-in — the observable half of "a 401 on the
    /// upgrade refreshes the token at once rather than waiting for
    /// `listDevices()` to meet the same 401 a quarter of an hour later".
    private(set) var didRequestTokenRefresh = false

    /// This Mac's own relay device id — the one device on the account this
    /// viewer must never list or dial: it would be a WebSocket to its own
    /// daemon by way of Cloudflare, showing the sessions already on screen.
    /// Set by the window from the `relay_device_token` row (and straight
    /// after a registration); a device already connected when the id
    /// arrives is dropped on the spot.
    var localDeviceID: String? {
        didSet {
            guard localDeviceID != oldValue, let deviceID = localDeviceID else { return }
            drop(deviceID)
        }
    }

    private let relay: RelayClient
    private let pollInterval: TimeInterval
    private let makeConnection: (URL) -> RemoteConnection
    private let isSignedIn: () -> Bool
    private let refreshSession: () async -> Void
    private let projectionReader: ProjectionReader
    private let currentBearer: () -> String?
    /// Every connection ever made, online or not — see the type comment.
    private var connections: [String: RemoteConnection] = [:]
    /// Devices the relay's last successful answer listed as online.
    private var onlineIDs: Set<String> = []
    private var names: [String: String] = [:]
    private var projections: [String: RemoteControlProjection.Payload] = [:]
    /// Devices whose connection reported `.unauthorized` and stopped
    /// retrying, with the bearer the relay refused. Re-dialled only once the
    /// bearer has *changed* — a REST call succeeding proves nothing about a
    /// WebSocket upgrade the same relay just refused, and re-dialling on it
    /// would be the four-times-a-second loop `.unauthorized` exists to end.
    /// A 401 is the *only* refusal that parks a device this way: everything
    /// else keeps retrying (`SessionConnection.isTokenRefusal`) and is
    /// re-dialled by the next poll.
    private var unauthorized: [String: String?] = [:]
    /// The last state each connection reported. A device the relay lists as
    /// online whose socket last said `.disconnected` is dialled again;
    /// `.connecting` is a dial already in flight and a device that has said
    /// nothing yet was dialled moments ago by this very poll — neither is
    /// worth a second `connect()`, which would only reset the backoff of an
    /// attempt already under way.
    private var connectionStates: [String: ConnectionState] = [:]
    private var timer: Timer?
    private var refreshInFlight = false
    /// A poke that arrived while a poll was in flight. Honoured once that
    /// poll finishes rather than dropped: the poke usually means "the bearer
    /// just landed", and the poll it overlapped went out without one.
    private var refreshRequested = false
    /// Bumped by every `clearAll()`. A poll captures it on the way out and
    /// applies its answer only if nothing cleared the model meanwhile —
    /// otherwise a log-out that raced a poll would have its sockets rebuilt
    /// and dialled, with a bearer that is very likely still valid, by a
    /// model nobody will ever `stop()` again.
    private var generation = 0
    private var lastSessionRefreshAt: Date?
    /// Two polls that both meet a 401 inside this window share one session
    /// refresh: the refresh cookie rotates on every use, and two concurrent
    /// refreshes would spend the same cookie twice.
    static let sessionRefreshCoalesce: TimeInterval = 10

    init(
        relay: RelayClient = .shared,
        pollInterval: TimeInterval = 30,
        makeConnection: @escaping (URL) -> RemoteConnection = { url in
            // Read on the connection's `ioQueue`: a plain stored property,
            // read directly, and never anything that touches UI state.
            SessionConnection(transport: .webSocket(url, bearer: { AuthClient.shared.accessToken }))
        },
        isSignedIn: @escaping () -> Bool = { AuthClient.shared.accessToken != nil },
        refreshSession: @escaping () async -> Void = { _ = try? await AuthClient.shared.restoreSession() },
        projectionReader: @escaping ProjectionReader = { connection, completion in
            connection.getSetting(key: SettingsKey.remoteControl, completion: completion)
        },
        currentBearer: @escaping () -> String? = { AuthClient.shared.accessToken }
    ) {
        self.relay = relay
        self.pollInterval = pollInterval
        self.makeConnection = makeConnection
        self.isSignedIn = isSignedIn
        self.refreshSession = refreshSession
        self.projectionReader = projectionReader
        self.currentBearer = currentBearer
    }

    /// How a machine's `remote_control` row is read through its connection.
    /// The default is the row read itself; a window-level test that needs
    /// real `SessionConnection`s (the pane factory's type) but no socket
    /// answers it directly.
    typealias ProjectionReader = (RemoteConnection, @escaping (Result<String?, Error>) -> Void) -> Void

    deinit {
        timer?.invalidate()
    }

    // MARK: - Lifecycle

    /// Starts polling, and polls at once. Idempotent: calling it while
    /// running is a request for an immediate poll — which is what the
    /// window does when the access token lands after the launch gate has
    /// already resolved.
    func start() {
        if !isRunning {
            isRunning = true
            let timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] timer in
                guard let self else {
                    timer.invalidate()
                    return
                }
                refreshSoon()
            }
            // `.common` so a poll still fires while a menu or a drag has the
            // run loop in a modal mode.
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
        refreshSoon()
    }

    /// Stops polling and drops every connection — sign-out's path.
    func stop() {
        timer?.invalidate()
        timer = nil
        isRunning = false
        clearAll()
    }

    private func refreshSoon() {
        guard !refreshInFlight else {
            refreshRequested = true
            return
        }
        refreshInFlight = true
        Task { [weak self] in
            await self?.refresh()
            await MainActor.run { [weak self] in
                guard let self else { return }
                refreshInFlight = false
                if refreshRequested, isRunning {
                    refreshRequested = false
                    refreshSoon()
                }
            }
        }
    }

    // MARK: - Polling

    /// One poll: list → connect new online devices → re-read every online
    /// projection → drop offline ones.
    func refresh() async {
        let (signedIn, captured) = await MainActor.run { (isSignedIn(), generation) }
        guard signedIn else {
            await MainActor.run { clearAll() }
            return
        }
        guard let devices = await listDevices() else { return }
        await MainActor.run {
            // Cleared while the relay was answering — signed out, or
            // stopped. The answer is for a model that no longer exists.
            guard generation == captured else { return }
            apply(devices)
        }
    }

    /// `listDevices()` with one retry behind a session refresh when the relay
    /// says the bearer is stale: the access token lives fifteen minutes and
    /// the poll outlives it. Every other failure — outage, DNS, a 5xx — is
    /// `nil`: the last answer stands.
    private func listDevices() async -> [RelayClient.Device]? {
        do {
            return try await relay.listDevices()
        } catch let RelayError.server(status, _) where status == 401 || status == 403 {
            await refreshSessionIfStale()
            return try? await relay.listDevices()
        } catch {
            return nil
        }
    }

    /// One session refresh per `sessionRefreshCoalesce` window, whichever
    /// poll asks. A poll that finds one just ran still gets its retry: the
    /// token that refresh produced is the one it needs.
    private func refreshSessionIfStale() async {
        let stale = await MainActor.run { () -> Bool in
            let now = Date()
            if let last = lastSessionRefreshAt, now.timeIntervalSince(last) < Self.sessionRefreshCoalesce {
                return false
            }
            lastSessionRefreshAt = now
            return true
        }
        guard stale else { return }
        await refreshSession()
    }

    private func apply(_ devices: [RelayClient.Device]) {
        let online = devices.filter { $0.online && $0.deviceID != localDeviceID }
        let nowOnline = Set(online.map(\.deviceID))
        for device in online {
            names[device.deviceID] = device.name
        }
        // Gone offline: the socket is closed but the object stays, for the
        // panes still holding it.
        for deviceID in onlineIDs.subtracting(nowOnline) {
            connections[deviceID]?.disconnect()
            projections.removeValue(forKey: deviceID)
            unauthorized.removeValue(forKey: deviceID)
            connectionStates.removeValue(forKey: deviceID)
        }
        for device in online {
            let deviceID = device.deviceID
            if let existing = connections[deviceID] {
                if !onlineIDs.contains(deviceID) {
                    // Back online: `connect()` starts over with the bearer
                    // as it is now.
                    unauthorized.removeValue(forKey: deviceID)
                    existing.connect()
                } else if let refused = unauthorized[deviceID] {
                    // A refused token is the one failure another dial cannot
                    // mend: the same bearer would only be refused again. Wait
                    // for a different one — the 401 asked for it already.
                    if refused != currentBearer() {
                        unauthorized.removeValue(forKey: deviceID)
                        existing.connect()
                    }
                } else if connectionStates[deviceID] == .disconnected {
                    // Online to the relay, down to us: dial it again. Every
                    // refusal but a 401 is transient — the 403 while the
                    // host's control channel registers, a relay restart, an
                    // outage — and leaving those to the bearer changing was
                    // what stranded a machine until the app was relaunched.
                    // The transport retries these itself; this is the poll
                    // saying so anyway, so no future path that quietly stops
                    // retrying can blind the viewer again.
                    existing.connect()
                }
            } else {
                let connection = makeConnection(relay.viewerSocketURL(deviceID: deviceID))
                connections[deviceID] = connection
                install(connection, for: deviceID)
                onConnectionCreated?(deviceID, connection)
                connection.connect()
            }
        }
        onlineIDs = nowOnline
        for deviceID in nowOnline {
            readProjection(for: deviceID)
        }
        rebuildMachines()
    }

    private func install(_ connection: RemoteConnection, for deviceID: String) {
        connection.onStateChange = { [weak self] state in
            guard let self else { return }
            connectionStates[deviceID] = state
            // A fresh socket — first connect or a reconnect after an outage —
            // is when the projection is actually readable.
            if state == .connected { readProjection(for: deviceID) }
            onConnectionStateChange?(deviceID, state)
        }
        connection.onError = { [weak self] error in
            guard let self else { return }
            if case SessionConnectionError.unauthorized = error {
                unauthorized[deviceID] = currentBearer()
                // The relay refused this bearer on the upgrade, so it is
                // stale *now* — asking here rather than waiting for
                // `listDevices()` to meet the same 401 saves the viewer the
                // rest of the token's fifteen minutes blind to this machine.
                // Coalesced with the REST path's refresh, whose cookie it
                // shares; the next poll dials on whatever it produces.
                didRequestTokenRefresh = true
                Task { [weak self] in await self?.refreshSessionIfStale() }
            }
            onConnectionError?(deviceID, error)
        }
    }

    private func readProjection(for deviceID: String) {
        guard let connection = connections[deviceID] else { return }
        projectionReader(connection) { [weak self] result in
            guard let self, case let .success(raw) = result else { return }
            // The device may have gone offline (or the viewer signed out)
            // while the read was in flight.
            guard onlineIDs.contains(deviceID) else { return }
            projections[deviceID] = RemoteControlProjection.decode(raw)
            rebuildMachines()
        }
    }

    private func rebuildMachines() {
        machines = onlineIDs
            .compactMap { deviceID in
                projections[deviceID].map {
                    RemoteMachine(deviceID: deviceID, name: names[deviceID] ?? deviceID, projection: $0)
                }
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func clearAll() {
        generation += 1
        for connection in connections.values {
            connection.disconnect()
        }
        connections.removeAll()
        onlineIDs.removeAll()
        projections.removeAll()
        unauthorized.removeAll()
        connectionStates.removeAll()
        didRequestTokenRefresh = false
        rebuildMachines()
    }

    /// Forgets one device entirely — `localDeviceID` arriving for a device
    /// this model had already dialled.
    private func drop(_ deviceID: String) {
        guard connections[deviceID] != nil || onlineIDs.contains(deviceID) else { return }
        connections[deviceID]?.disconnect()
        connections.removeValue(forKey: deviceID)
        onlineIDs.remove(deviceID)
        projections.removeValue(forKey: deviceID)
        unauthorized.removeValue(forKey: deviceID)
        connectionStates.removeValue(forKey: deviceID)
        rebuildMachines()
    }

    /// The `device_id` inside a `relay_device_token` row
    /// (`RelayClient.deviceTokenRow`'s shape) — the only field of that row
    /// the app ever reads back; the token itself stays the daemon's.
    static func deviceID(inTokenRow raw: String?) -> String? {
        guard
            let raw, !raw.isEmpty,
            let data = raw.data(using: .utf8),
            let row = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let deviceID = row["device_id"] as? String, !deviceID.isEmpty
        else { return nil }
        return deviceID
    }

    /// The `name` inside a `relay_device_token` row — `deviceID(inTokenRow:)`'s
    /// sibling, for Settings › Remote's read-only "This machine" identity
    /// (2026-09-01 remote environment sharing spec §2).
    static func name(inTokenRow raw: String?) -> String? {
        guard
            let raw, !raw.isEmpty,
            let data = raw.data(using: .utf8),
            let row = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let name = row["name"] as? String, !name.isEmpty
        else { return nil }
        return name
    }

    // MARK: - Lookup

    /// The connection for an **online** device, `nil` otherwise — what
    /// "open a remote session" checks before adding a pane.
    func connection(for deviceID: String) -> RemoteConnection? {
        guard onlineIDs.contains(deviceID) else { return nil }
        return connections[deviceID]
    }

    /// The connection object for a device whether or not it is online now —
    /// how a pane opened before an outage keeps routing to the object that
    /// will be reconnected when the machine is back.
    func retainedConnection(for deviceID: String) -> RemoteConnection? {
        connections[deviceID]
    }

    /// `connection(for:)` as the concrete type the pane factory needs.
    func sessionConnection(for deviceID: String) -> SessionConnection? {
        connection(for: deviceID) as? SessionConnection
    }

    func machine(for deviceID: String) -> RemoteMachine? {
        machines.first { $0.deviceID == deviceID }
    }
}
