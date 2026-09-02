import Foundation

/// One machine on this account that the relay reports online — what the
/// sidebar's remote sections, the spotlight's "Connect to ‹machine›" rows and
/// the picker are drawn from.
///
/// **No projection any more** (2026-09-01 remote environment sharing spec §1,
/// Task 29): the viewer used to read a `remote_control` row through an
/// eagerly-dialled connection and mirror the host's workspace tree from it.
/// That model is gone — a viewer now points its whole app at the host's
/// daemon and reads the host's *real* state over the same RPCs the host
/// uses, so this type carries nothing but what the relay itself knows.
struct RemoteMachine: Equatable {
    let deviceID: String
    let name: String
}

/// The viewer side's device list (2026-09-01 remote environment sharing spec
/// §6/§10): polls `RelayClient.listDevices()` while signed in and turns the
/// account's registered machines into `machines` (online, connectable) and
/// `offlineMachineNames` (known but not reachable right now) — nothing else.
///
/// **Opens no connection of its own** (Task 29 — "stop the eager dialing").
/// Earlier phases kept one `SessionConnection` per online machine so a
/// pane could be opened directly against it; that per-pane picker is gone,
/// and with it the reason to dial anything before the user actually asks to
/// connect. The daemon allows exactly one remote connection per machine, so
/// polling every online device used to take each one's lease for no reason —
/// two real Macs would fight over it. `sessionConnection(for:)` is the only
/// thing that ever builds a socket, and it does so once, on demand, for
/// `WorkspaceWindowController.connectRemote(to:)` to dial.
///
/// Main-thread only for its state, `RelayClient`'s rule: `refresh()` awaits
/// the relay wherever it is called from and applies the answer on the main
/// actor.
final class RemoteMachinesModel {
    /// Online machines with a decoded projection, sorted by name.
    private(set) var machines: [RemoteMachine] = [] {
        didSet {
            guard machines != oldValue else { return }
            onChange?()
        }
    }
    /// Machines the relay reports as registered to this account but not
    /// currently online — the picker's "‹name› is offline" row (spec's
    /// phase 2 §4 empty states, reworded for machines by Task 29). Sorted by
    /// name, same as `machines`.
    private(set) var offlineMachineNames: [String] = []
    var onChange: (() -> Void)?

    private(set) var isRunning = false

    /// This Mac's own relay device id — the one device on the account this
    /// viewer must never list: it would be a WebSocket to its own daemon by
    /// way of Cloudflare, showing the sessions already on screen. Set by the
    /// window from the `relay_device_token` row (and straight after a
    /// registration).
    var localDeviceID: String? {
        didSet {
            guard localDeviceID != oldValue else { return }
            apply(lastDevices)
        }
    }

    private let relay: RelayClient
    private let pollInterval: TimeInterval
    private let makeConnection: (URL) -> SessionConnection
    private let isSignedIn: () -> Bool
    private let refreshSession: () async -> Void
    private var timer: Timer?
    private var refreshInFlight = false
    /// A poke that arrived while a poll was in flight. Honoured once that
    /// poll finishes rather than dropped: the poke usually means "the bearer
    /// just landed", and the poll it overlapped went out without one.
    private var refreshRequested = false
    /// Bumped by every `clearAll()`. A poll captures it on the way out and
    /// applies its answer only if nothing cleared the model meanwhile —
    /// otherwise a log-out that raced a poll would repopulate `machines` for
    /// a model nobody will ever `stop()` again.
    private var generation = 0
    private var lastSessionRefreshAt: Date?
    /// The relay's last successful answer, so `localDeviceID` arriving late
    /// can be applied without a fresh round trip.
    private var lastDevices: [RelayClient.Device] = []
    /// Two polls that both meet a 401 inside this window share one session
    /// refresh: the refresh cookie rotates on every use, and two concurrent
    /// refreshes would spend the same cookie twice.
    static let sessionRefreshCoalesce: TimeInterval = 10

    init(
        relay: RelayClient = .shared,
        pollInterval: TimeInterval = 30,
        makeConnection: @escaping (URL) -> SessionConnection = { url in
            SessionConnection(transport: .webSocket(url, bearer: { AuthClient.shared.accessToken }))
        },
        isSignedIn: @escaping () -> Bool = { AuthClient.shared.accessToken != nil },
        refreshSession: @escaping () async -> Void = { _ = try? await AuthClient.shared.restoreSession() }
    ) {
        self.relay = relay
        self.pollInterval = pollInterval
        self.makeConnection = makeConnection
        self.isSignedIn = isSignedIn
        self.refreshSession = refreshSession
    }

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

    /// Stops polling and clears the list — sign-out's path.
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

    /// One poll: list the account's devices, apply the answer.
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

    /// One poll's answer, applied. Not `private` — tests call it directly to
    /// pin `machines`/`offlineMachineNames` without standing up a relay stub.
    func apply(_ devices: [RelayClient.Device]) {
        lastDevices = devices
        let others = devices.filter { $0.deviceID != localDeviceID }
        machines = others
            .filter(\.online)
            .map { RemoteMachine(deviceID: $0.deviceID, name: $0.name) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        offlineMachineNames = others
            .filter { !$0.online }
            .map(\.name)
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private func clearAll() {
        generation += 1
        lastDevices = []
        machines = []
        offlineMachineNames = []
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

    func machine(for deviceID: String) -> RemoteMachine? {
        machines.first { $0.deviceID == deviceID }
    }

    /// Builds a fresh, unconnected connection to an online device — a socket
    /// is opened only when the user actually connects
    /// (`WorkspaceWindowController.connectRemote(to:)` dials it via
    /// `SessionConnection.connect()`, through `swapConnection`). `nil` when
    /// the device is not on the relay's last-known online list, matching
    /// `connectRemote`'s "machine offline" refusal.
    func sessionConnection(for deviceID: String) -> SessionConnection? {
        guard machines.contains(where: { $0.deviceID == deviceID }) else { return nil }
        return makeConnection(relay.viewerSocketURL(deviceID: deviceID))
    }
}
