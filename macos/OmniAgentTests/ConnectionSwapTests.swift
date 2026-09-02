import AppKit
import XCTest

@testable import OmniAgent

/// The connection swap — the 2026-09-01 remote environment sharing spec's §6,
/// and the app's half of §3's no-chaining property.
///
/// The app used to *add* connections: one local socket built in `AppDelegate`
/// plus one WebSocket per remote machine, with panes routed between them. On
/// that shape a Mac driving another Mac still held its own local connection,
/// so it still satisfied the daemon's "at least one local app connection"
/// condition (spec §2, condition 3), so it stayed shareable — and a third Mac
/// could drive it. The chaining ban was satisfiable by accident.
///
/// This window now *swaps*: one connection, re-pointed, with every subscriber
/// moved across and the outgoing one disconnected. `theLocalConnectionDoesNot
/// SurviveATakeover` is the test that says so, and it is the reason this file
/// is release-blocking rather than merely structural.
@MainActor
final class ConnectionSwapTests: XCTestCase {
    // MARK: - Fixtures

    /// A machine to drive. The projection is empty on purpose: nothing in the
    /// swap reads it — the viewer sees the host's real workspaces because it
    /// is reading the host's own rows over the same RPCs (spec §1).
    private let studio = RemoteMachine(
        deviceID: "device-studio",
        name: "Mac Studio",
        projection: RemoteControlProjection.Payload(workspaces: [])
    )

    private let air = RemoteViewer(
        viewerID: "v-air",
        machineName: "MacBook Air",
        sessions: ["s1"],
        since: "2026-09-01T09:00:00Z",
        accountEmail: "bruno@bonando.com",
        ip: "203.0.113.7",
        country: "DE",
        client: "OmniAgent/1.7.22 macOS 27.0"
    )

    private let localProjects = [
        BrainProjectSummary(id: "local-alpha", label: "Alpha", path: "/tmp/alpha"),
        BrainProjectSummary(id: "local-beta", label: "Beta", path: "/tmp/beta"),
    ]

    // MARK: - The environment changes, and comes back

    /// Driving another Mac replaces what this window is showing, and ending
    /// the session puts this Mac's own environment back.
    ///
    /// Only the in-memory half is asserted here, because only the in-memory
    /// half is restored synchronously. The panes come back from the local
    /// daemon's own `layout` row on the next `.connected` — untouched by the
    /// takeover, since the swap drops `layoutReadCompleted` (the write gate
    /// every `persist*` checks) before anything else, and every write that did
    /// happen while driving went to the machine being driven.
    func testSwappingRestoresLocalStateExactly() async throws {
        let (controller, local, remote) = try makeController()
        defer { controller.close() }

        controller.projectLister = { [localProjects] completion in completion(.success(localProjects)) }
        controller.refreshProjectLabels()
        let localWorkspaces = controller.workspaceIDs
        XCTAssertEqual(localWorkspaces, ["local-alpha", "local-beta"])
        XCTAssertFalse(controller.isDrivingRemote)

        controller.remoteConnectionProvider = { _ in remote }
        try await controller.connectRemote(to: studio)

        XCTAssertTrue(controller.isDrivingRemote)
        XCTAssertTrue(controller.connection === remote, "the window is answered by the other Mac's daemon")
        XCTAssertNotEqual(
            controller.workspaceIDs, localWorkspaces,
            "this Mac's workspaces are not the ones on screen while another Mac is being driven"
        )

        controller.disconnectRemote()

        XCTAssertFalse(controller.isDrivingRemote)
        XCTAssertTrue(controller.connection === local, "the window is back on its own daemon")
        XCTAssertEqual(controller.workspaceIDs, localWorkspaces, "exactly what it was before the takeover")
    }

    // MARK: - The security property

    /// **No local connection survives a takeover.**
    ///
    /// This is the whole of the app's contribution to spec §3. While this
    /// window drives another Mac there must be nothing attached to this Mac's
    /// own daemon and nothing subscribed to it — because that, and only that,
    /// is what makes this Mac fail the daemon's sharing condition and refuse
    /// everyone inbound. A subscriber left holding the local connection would
    /// not fail visibly; it would quietly re-open the door.
    func testTheLocalConnectionDoesNotSurviveATakeover() async throws {
        let (controller, local, remote) = try makeController()
        defer { controller.close() }
        controller.start()
        XCTAssertTrue(local.hasSubscribers, "before the takeover the window listens to its own daemon")
        XCTAssertTrue(local.wantsConnection)

        controller.remoteConnectionProvider = { _ in remote }
        try await controller.connectRemote(to: studio)

        XCTAssertFalse(
            local.hasSubscribers,
            "no subscriber may still be holding the local connection — a stale capture here is how "
                + "a Mac that is driving another Mac stays shareable, and chaining becomes possible"
        )
        XCTAssertFalse(
            local.wantsConnection,
            "and it is detached, not merely unheard: the daemon's condition is a live connection, "
                + "not a listener"
        )
        XCTAssertTrue(remote.hasSubscribers, "every subscription moved across rather than being dropped")
        XCTAssertTrue(remote.wantsConnection)
    }

    /// And it comes back on its own — the takeover parks the local
    /// connection, it does not destroy it.
    func testEndingTheSessionReattachesAndResubscribesTheLocalConnection() async throws {
        let (controller, local, remote) = try makeController()
        defer { controller.close() }
        controller.start()

        controller.remoteConnectionProvider = { _ in remote }
        try await controller.connectRemote(to: studio)
        controller.disconnectRemote()

        XCTAssertTrue(local.hasSubscribers)
        XCTAssertTrue(local.wantsConnection)
        XCTAssertFalse(remote.hasSubscribers, "and nothing is left listening to the machine that was driven")
        XCTAssertFalse(remote.wantsConnection)
    }

    /// The UI half of §3 arrives with the live-session widget; the API refuses
    /// on its own regardless, so no caller can hop by forgetting a check.
    func testASecondTakeoverIsRefused() async throws {
        let (controller, _, remote) = try makeController()
        defer { controller.close() }
        controller.remoteConnectionProvider = { _ in remote }
        try await controller.connectRemote(to: studio)

        do {
            try await controller.connectRemote(to: studio)
            XCTFail("a machine already driving another one must not start a second session")
        } catch let error as WorkspaceWindowController.RemoteDriveError {
            XCTAssertEqual(error, .alreadyDriving)
        }
        XCTAssertTrue(controller.connection === remote, "and the refusal changed nothing")
    }

    /// A machine with no connection to it is a refusal, never a silent swap to
    /// nothing.
    func testAMachineWithNoConnectionIsRefused() async throws {
        let (controller, local, _) = try makeController()
        defer { controller.close() }
        controller.remoteConnectionProvider = { _ in nil }

        do {
            try await controller.connectRemote(to: studio)
            XCTFail("there is nothing to drive")
        } catch let error as WorkspaceWindowController.RemoteDriveError {
            XCTAssertEqual(error, .machineOffline("Mac Studio"))
        }
        XCTAssertFalse(controller.isDrivingRemote)
        XCTAssertTrue(controller.connection === local)
    }

    // MARK: - Host-side surfaces do not follow the swap

    /// The takeover panel and the host-state publisher are about *this* Mac
    /// being driven. A swap must take both down and must never start either:
    /// the roster this window last heard is a frozen copy of what the local
    /// daemon said before the swap, and raising a panel from it would put
    /// "somebody is here" over an environment that belongs to somebody else.
    func testDrivingAnotherMacTakesDownThePanelAndStopsPublishingHostState() async throws {
        let (controller, _, remote) = try makeController()
        defer { controller.close() }
        controller.takeoverPanelPresenter = { _ in }

        controller.applyRemoteViewers([air])
        XCTAssertNotNil(controller.takeoverPanel, "somebody is driving this Mac")
        XCTAssertTrue(controller.isPublishingHostState)

        controller.remoteConnectionProvider = { _ in remote }
        try await controller.connectRemote(to: studio)

        XCTAssertNil(controller.takeoverPanel, "this Mac is not a host while it is driving one")
        XCTAssertFalse(
            controller.isPublishingHostState,
            "and it publishes nothing about itself: its gauges and limits are not the ones on screen"
        )

        // Even a fresh roster push cannot raise it while the swap is live.
        controller.applyRemoteViewers([air])
        XCTAssertNil(controller.takeoverPanel)
        XCTAssertFalse(controller.isPublishingHostState)
    }

    /// The takeover panel's Terminate/Block go to *this* Mac's daemon, so the
    /// panel is built on the local connection and not on whatever the window
    /// happens to be driving. (`DisconnectViewer` is local-only in the
    /// allowlist — spec §12.3 — so the far end would refuse it anyway; the
    /// point is that the call site says which machine it means.)
    func testTheTakeoverPanelIsBuiltOnTheLocalConnection() throws {
        let (controller, local, _) = try makeController()
        defer { controller.close() }
        controller.takeoverPanelPresenter = { _ in }

        controller.applyRemoteViewers([air])

        let panel = try XCTUnwrap(controller.takeoverPanel)
        XCTAssertTrue(panel.connection === local)
    }

    // MARK: - The poll does not pull the rug

    /// A machine the window is driving is no longer the model's to close. Its
    /// connection is the one the whole window is running on, and a relay list
    /// that flickers — a Core deploy, a lost call — must not end the session.
    func testThePollLeavesTheDrivenMachinesConnectionAlone() async {
        let driven = RecordingRemoteConnection()
        let other = RecordingRemoteConnection()
        let model = RemoteMachinesModel(
            relay: RelayClient(
                baseURL: URL(string: "http://127.0.0.1:1")!,
                session: .shared,
                accessToken: { "tok" }
            ),
            makeConnection: { url in url.absoluteString.contains("device-studio") ? driven : other },
            isSignedIn: { true },
            projectionReader: { _, completion in completion(.success(nil)) }
        )
        model.apply([
            RelayClient.Device(deviceID: "device-studio", name: "Mac Studio", online: true, lastSeenAt: nil),
            RelayClient.Device(deviceID: "device-air", name: "MacBook Air", online: true, lastSeenAt: nil),
        ])
        model.drivenDeviceID = "device-studio"

        // Both drop off the relay's answer at once.
        model.apply([])

        XCTAssertEqual(driven.disconnects, 0, "the window is running on this one")
        XCTAssertEqual(other.disconnects, 1, "every other machine is closed as before")
    }

    // MARK: - Helpers

    /// A window on a local unix socket that does not exist and a remote
    /// WebSocket that dials nothing, both with a minute of reconnect delay so
    /// neither spins while a test runs.
    private func makeController() throws -> (WorkspaceWindowController, SessionConnection, SessionConnection) {
        let local = SessionConnection(
            socketURL: URL(fileURLWithPath: "/tmp/omniagent-connection-swap-\(UUID().uuidString).sock"),
            reconnectDelay: 60
        )
        let remote = SessionConnection(
            transport: .webSocket(URL(string: "wss://127.0.0.1:1/v1/viewer/device-studio")!, bearer: { nil }),
            reconnectDelay: 60
        )
        let controller = WorkspaceWindowController(
            connection: local,
            panes: [],
            remoteSharing: RemoteSharingModel(store: SettingsStore(client: FakeSettingsClient())),
            settingsClient: FakeSettingsClient(),
            authDefaults: try throwawayDefaults()
        )
        controller.takeoverPanelPresenter = { _ in }
        controller.sessionEnsurer = { _ in }
        controller.sessionKiller = { _ in }
        controller.relayDeviceRegistrar = { _ in
            XCTFail("no test here may reach the relay")
            return RelayClient.Registration(deviceID: "d1", token: "secret")
        }
        addTeardownBlock {
            local.disconnect()
            remote.disconnect()
        }
        return (controller, local, remote)
    }

    /// A suite of its own, torn down after — never the real app's defaults
    /// (`RealPreferencesGuard`).
    private func throwawayDefaults() throws -> UserDefaults {
        let name = "digital.bruno.omniagent.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        return defaults
    }
}

/// A `RemoteConnection` that only counts what the model asked it to do.
private final class RecordingRemoteConnection: RemoteConnection {
    var onStateChange: ((ConnectionState) -> Void)?
    var onError: ((Error) -> Void)?
    var connects = 0
    var disconnects = 0

    func connect() { connects += 1 }
    func disconnect() { disconnects += 1 }

    func getSetting(key: String, completion: @escaping (Result<String?, Error>) -> Void) {
        completion(.success(nil))
    }
}
