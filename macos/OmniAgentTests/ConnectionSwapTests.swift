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

    /// A machine to drive. The viewer sees the host's real workspaces because
    /// it is reading the host's own rows over the same RPCs (spec §1) — this
    /// type carries nothing but what the relay itself knows any more.
    private let studio = RemoteMachine(deviceID: "device-studio", name: "Mac Studio")

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

    // MARK: - The connect ceremony never checks a step off ahead of its fact

    /// Fix round 1: the ceremony's `.securing` row must stay **active** —
    /// never read as done — until `.connected` genuinely arrives. This pins
    /// the real production wiring (`WorkspaceWindowController
    /// .beginConnecting` → `installConnectionHandlers`'s `.connecting`/
    /// `.connected` cases), not just `RemoteConnectCeremony`'s own state
    /// machine, because the bug this fixes was in the wiring: it used to
    /// call `dataChannelOpened()` from the same synchronous `.connecting`
    /// event as `webSocketOpened()`, which checked "Establishing a secure
    /// line…" off at the very instant the dial *started* — before any
    /// secure line existed — with "Confirming credentials…" then spinning
    /// through the entire real wait behind it.
    func testSecuringStaysActiveUntilTheConnectionIsGenuinelyUp() async throws {
        let (controller, _, remote) = try makeController()
        defer { controller.close() }
        controller.remoteConnectionProvider = { _ in remote }

        controller.beginConnecting(to: studio)
        // `beginConnecting` dials through a `Task`; `connectRemote` itself
        // has no suspension point once scheduled (Task 23's own design —
        // it swaps and returns), so a bounded run of cooperative yields is
        // enough to let it complete without a wall-clock wait.
        for _ in 0..<20 where !controller.isDrivingRemote {
            await Task.yield()
        }
        XCTAssertTrue(controller.isDrivingRemote, "the swap has to have happened for the wiring under test to run at all")
        let ceremony = try XCTUnwrap(controller.connectCeremony)

        // The real event: `SessionConnection.openConnection()` fires
        // `.connecting` at the very top, before the socket even exists.
        remote.onStateChange?(.connecting)
        XCTAssertEqual(ceremony.step, .securing)
        XCTAssertNotEqual(
            ceremony.step, .confirming,
            "confirming credentials cannot be true before the socket has even opened"
        )

        // Only now — a genuine `HelloAck` — does the wait actually end.
        remote.onStateChange?(.connected)
        XCTAssertEqual(
            ceremony.step, .loading,
            "both the secure line and confirming credentials become true together, on the one signal that proves either"
        )
    }

    // MARK: - A session's cwd never guesses this Mac's own disk (Task 28 fix
    // round 2, 2026-09-01 remote environment sharing spec §4/§6)

    /// The local case's last resort — this Mac's own home directory — is a
    /// guess about a machine the host has never described. `portable_pty`
    /// accepts a bad `cwd` silently whenever a directory of that same name
    /// happens to exist on the host too (the common case for one person's
    /// own two Macs sharing a username), so nothing downstream would ever
    /// say this went wrong. While driving, with nothing recorded,
    /// `startingDirectory`/`workspaceRoot` answer `nil` instead of guessing.
    func testStartingDirectoryNeverGuessesThisMacsHomeWhileDrivingWithNothingKnown() async throws {
        let (controller, _, remote) = try makeController()
        defer { controller.close() }
        XCTAssertEqual(
            controller.startingDirectory(for: nil),
            FileManager.default.homeDirectoryForCurrentUser.path,
            "the local case is unchanged"
        )

        controller.remoteConnectionProvider = { _ in remote }
        try await controller.connectRemote(to: studio)

        XCTAssertNil(controller.startingDirectory(for: nil))
        XCTAssertNil(controller.workspaceRoot())
    }

    /// The fix is "never guess", not "never answer": a real host workspace
    /// still resolves correctly while driving.
    func testStartingDirectoryStillResolvesARealHostWorkspaceWhileDriving() async throws {
        let (controller, _, remote) = try makeController()
        defer { controller.close() }
        controller.remoteConnectionProvider = { _ in remote }
        try await controller.connectRemote(to: studio)

        controller.projectLister = { completion in
            completion(.success([
                BrainProjectSummary(id: "host-project", label: "Host Project", path: "/Users/host/Project"),
            ]))
        }
        controller.refreshProjectLabels()

        XCTAssertEqual(controller.workspaceDirectory(for: "host-project"), "/Users/host/Project")
        XCTAssertEqual(
            controller.startingDirectory(
                for: PaneDescriptor(sessionID: "p", group: "g", project: "host-project")
            ),
            "/Users/host/Project"
        )
    }

    /// Home's Chat scratch folder is this Mac's own
    /// `~/Documents/OmniAgent/Chats` — meaningless on a host that has never
    /// heard of it. While driving it must not resolve at all, rather than
    /// answering with a real folder that happens to exist on the host for a
    /// completely unrelated reason.
    func testHomeChatWorkspaceDoesNotResolveToThisMacsOwnFolderWhileDriving() async throws {
        let (controller, _, remote) = try makeController()
        defer { controller.close() }
        XCTAssertEqual(
            controller.workspaceDirectory(for: HomeChatWorkspace.id),
            HomeChatWorkspace.directory,
            "the local case is unchanged"
        )

        controller.remoteConnectionProvider = { _ in remote }
        try await controller.connectRemote(to: studio)

        XCTAssertNil(controller.workspaceDirectory(for: HomeChatWorkspace.id))
    }

    /// Task 28 fix round 2, item 1: connecting to a host whose `layout` row
    /// is empty — the grid is empty too, straight after
    /// `resetForAccountSwitch` — is exactly a first connection to that
    /// host, and it must not bootstrap a pane carrying this Mac's own home
    /// directory. `WorkspaceRestorationTests` proves `bootstrapPane`
    /// itself; this proves the real path a host's own empty `layout`
    /// answer actually takes.
    func testAnEmptyHostLayoutWhileDrivingBootstrapsAPaneWithNoCarriedDirectory() async throws {
        let (controller, _, remote) = try makeController()
        defer { controller.close() }
        controller.remoteConnectionProvider = { _ in remote }
        try await controller.connectRemote(to: studio)

        controller.applyRestoredPanes([])

        let paneID = try XCTUnwrap(controller.workspaceView.allPaneIDs.first)
        let descriptor = try XCTUnwrap(controller.workspaceView.descriptor(for: paneID))
        XCTAssertEqual(descriptor.cwd, "", "no viewer-local directory carried")
        XCTAssertNil(
            controller.startingDirectory(for: descriptor),
            "and startingDirectory refuses to guess one, rather than the carried value short-circuiting that"
        )
    }

    // MARK: - The App view composer's attach button follows the swap
    // (Task 28 fix round 3)

    /// End to end, both directions: `swapConnection` closes every pane
    /// (`resetForAccountSwitch`) before `syncTakeoverPanel` ever runs, so no
    /// `PaneAppView` survives the swap itself to be told about afterwards —
    /// the real question is whether one built *after* the swap, from the
    /// window's own reading at that moment, gets it right. It does, both
    /// ways.
    func testTheAppViewComposersAttachButtonReadsTheCurrentDrivingStateAtConstruction() async throws {
        let (controller, _, remote) = try makeController()
        defer { controller.close() }
        controller.showWindow(nil)

        controller.remoteConnectionProvider = { _ in remote }
        try await controller.connectRemote(to: studio)

        // A pane built (from the host's own panes, in production) while
        // driving is already the answer.
        controller.newTerminalPane(nil)
        let drivingPaneID = try XCTUnwrap(controller.workspaceView.allPaneIDs.first)
        let drivingContainer = try XCTUnwrap(controller.workspaceView.container(for: drivingPaneID))
        drivingContainer.viewMode = .app
        let drivingAppView = try XCTUnwrap(drivingContainer.appView)
        XCTAssertFalse(drivingAppView.isAttachButtonEnabledForTesting, "built while driving")
        XCTAssertEqual(
            drivingAppView.attachButtonToolTipForTesting,
            "Attachments aren't available while driving Mac Studio"
        )

        controller.disconnectRemote()

        // A pane built afterwards, back on this Mac's own environment, is
        // not held to the takeover's own reading.
        controller.newTerminalPane(nil)
        let localPaneID = try XCTUnwrap(
            controller.workspaceView.allPaneIDs.first { $0 != drivingPaneID }
        )
        let localContainer = try XCTUnwrap(controller.workspaceView.container(for: localPaneID))
        localContainer.viewMode = .app
        let localAppView = try XCTUnwrap(localContainer.appView)
        XCTAssertTrue(localAppView.isAttachButtonEnabledForTesting, "back on this Mac's own environment")
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
