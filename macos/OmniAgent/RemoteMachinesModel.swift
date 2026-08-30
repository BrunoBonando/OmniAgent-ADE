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

    private let relay: RelayClient
    private let pollInterval: TimeInterval
    private let makeConnection: (URL) -> RemoteConnection
    private let isSignedIn: () -> Bool
    private let refreshSession: () async -> Void
    private let projectionReader: ProjectionReader
    /// Every connection ever made, online or not — see the type comment.
    private var connections: [String: RemoteConnection] = [:]
    /// Devices the relay's last successful answer listed as online.
    private var onlineIDs: Set<String> = []
    private var names: [String: String] = [:]
    private var projections: [String: RemoteControlProjection.Payload] = [:]
    /// Devices whose connection reported `.unauthorized` and stopped
    /// retrying. The next poll that gets through the relay carries a bearer
    /// the relay accepts, and `connect()`s them again with it.
    private var unauthorized: Set<String> = []
    private var timer: Timer?
    private var refreshInFlight = false

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
        }
    ) {
        self.relay = relay
        self.pollInterval = pollInterval
        self.makeConnection = makeConnection
        self.isSignedIn = isSignedIn
        self.refreshSession = refreshSession
        self.projectionReader = projectionReader
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
        guard !refreshInFlight else { return }
        refreshInFlight = true
        Task { [weak self] in
            await self?.refresh()
            await MainActor.run { [weak self] in self?.refreshInFlight = false }
        }
    }

    // MARK: - Polling

    /// One poll: list → connect new online devices → re-read every online
    /// projection → drop offline ones.
    func refresh() async {
        let signedIn = await MainActor.run { isSignedIn() }
        guard signedIn else {
            await MainActor.run { clearAll() }
            return
        }
        guard let devices = await listDevices() else { return }
        await MainActor.run { apply(devices) }
    }

    /// `listDevices()` with one retry behind a session refresh when the relay
    /// says the bearer is stale: the access token lives fifteen minutes and
    /// the poll outlives it. Every other failure — outage, DNS, a 5xx — is
    /// `nil`: the last answer stands.
    private func listDevices() async -> [RelayClient.Device]? {
        do {
            return try await relay.listDevices()
        } catch let RelayError.server(status, _) where status == 401 || status == 403 {
            await refreshSession()
            return try? await relay.listDevices()
        } catch {
            return nil
        }
    }

    private func apply(_ devices: [RelayClient.Device]) {
        let online = devices.filter(\.online)
        let nowOnline = Set(online.map(\.deviceID))
        for device in online {
            names[device.deviceID] = device.name
        }
        // Gone offline: the socket is closed but the object stays, for the
        // panes still holding it.
        for deviceID in onlineIDs.subtracting(nowOnline) {
            connections[deviceID]?.disconnect()
            projections.removeValue(forKey: deviceID)
            unauthorized.remove(deviceID)
        }
        for device in online {
            let deviceID = device.deviceID
            if let existing = connections[deviceID] {
                // Back online, or refused last time: `connect()` starts over
                // with the bearer as it is now.
                if !onlineIDs.contains(deviceID) || unauthorized.contains(deviceID) {
                    unauthorized.remove(deviceID)
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
            // A fresh socket — first connect or a reconnect after an outage —
            // is when the projection is actually readable.
            if state == .connected { readProjection(for: deviceID) }
            onConnectionStateChange?(deviceID, state)
        }
        connection.onError = { [weak self] error in
            guard let self else { return }
            if case SessionConnectionError.unauthorized = error {
                unauthorized.insert(deviceID)
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
        for connection in connections.values {
            connection.disconnect()
        }
        connections.removeAll()
        onlineIDs.removeAll()
        projections.removeAll()
        unauthorized.removeAll()
        rebuildMachines()
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
