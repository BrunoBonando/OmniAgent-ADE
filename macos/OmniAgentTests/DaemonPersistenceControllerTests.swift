import Darwin
import XCTest
@testable import OmniAgent

/// A scripted `DaemonServiceRegistrar` — the seam that lets
/// `DaemonPersistenceController`'s gating/spawning logic be exercised
/// without ever touching real `SMAppService` (whose approval flow cannot
/// run in CI; see the Task 6c report).
private final class FakeDaemonServiceRegistrar: DaemonServiceRegistrar {
    var status: DaemonServiceStatus
    var registerOutcome: DaemonRegistrationOutcome
    private(set) var registerCallCount = 0

    init(status: DaemonServiceStatus, registerOutcome: DaemonRegistrationOutcome) {
        self.status = status
        self.registerOutcome = registerOutcome
    }

    func currentStatus() -> DaemonServiceStatus { status }

    func register() -> DaemonRegistrationOutcome {
        registerCallCount += 1
        return registerOutcome
    }
}

private final class FakeDaemonProcessHandle: DaemonProcessHandle {
    var isRunning = true
}

private final class FakeDaemonProcessLauncher: DaemonProcessLaunching {
    private(set) var launchCallCount = 0
    private(set) var lastBinaryPath: String?
    private(set) var lastSocketURL: URL?
    private(set) var lastDataDir: URL?
    var shouldThrow = false

    func launch(binaryPath: String, socketURL: URL, dataDir: URL) throws -> DaemonProcessHandle {
        launchCallCount += 1
        lastBinaryPath = binaryPath
        lastSocketURL = socketURL
        lastDataDir = dataDir
        if shouldThrow { throw SessionConnectionError.disconnected }
        return FakeDaemonProcessHandle()
    }
}

/// A scripted `DaemonTerminating`: records what it was asked to end and
/// answers at once — the real one sends SIGTERM and polls a socket, which
/// no test may do to the developer's live daemon.
private final class FakeDaemonTerminator: DaemonTerminating {
    private(set) var calls: [(pid: pid_t?, socketURL: URL)] = []
    var result = true

    func terminate(pid: pid_t?, socketURL: URL, timeout: TimeInterval, completion: @escaping (Bool) -> Void) {
        calls.append((pid, socketURL))
        completion(result)
    }
}

final class DaemonPersistenceControllerTests: XCTestCase {
    private let paths = DaemonPaths.resolve(
        channel: .production,
        homeDirectory: URL(fileURLWithPath: "/Users/dev"),
        environment: [:]
    )

    private func makeController(
        registrar: FakeDaemonServiceRegistrar,
        launcher: FakeDaemonProcessLauncher = FakeDaemonProcessLauncher(),
        binaryPath: String? = "/Applications/OmniAgent.app/Contents/MacOS/omniagent-pty-daemon",
        socketReachable: Bool = false,
        terminator: FakeDaemonTerminator = FakeDaemonTerminator()
    ) -> DaemonPersistenceController {
        DaemonPersistenceController(
            paths: paths,
            registrar: registrar,
            processLauncher: launcher,
            resolveBinaryPath: { binaryPath },
            socketReachable: { socketReachable },
            terminator: terminator
        )
    }

    func testStartResolvesRegisteredServiceModeAndLeavesALiveDaemonAlone() {
        let registrar = FakeDaemonServiceRegistrar(
            status: .notRegistered,
            registerOutcome: .registered(.enabled)
        )
        let launcher = FakeDaemonProcessLauncher()
        let controller = makeController(
            registrar: registrar,
            launcher: launcher,
            socketReachable: true
        )
        var observedModes: [DaemonPersistenceMode] = []
        controller.onModeChanged = { observedModes.append($0) }

        controller.start()

        XCTAssertEqual(controller.mode, .registeredService)
        XCTAssertEqual(observedModes, [.registeredService])
        XCTAssertEqual(registrar.registerCallCount, 1)
        XCTAssertEqual(launcher.launchCallCount, 0)
    }

    /// Regression: spawning used to be gated on `.appOwned` mode, which
    /// treated an `.enabled` registration as proof a daemon was listening.
    /// It is no such thing — replacing the app bundle (`rm -rf` + `ditto`,
    /// what every `scripts/rebuild-app.sh` install does) leaves the job
    /// `.enabled` while launchd can no longer resolve its bundle-relative
    /// `Program`, so it fails every spawn with `EX_CONFIG`. The app then
    /// declined to start a daemon nothing else was going to start either.
    /// The already-running daemon survives the install, so this stayed
    /// invisible until one exited — after which no terminal could open at
    /// all, with the daemon settings still cheerfully reporting a healthy
    /// login item.
    func testStartSpawnsForARegisteredServiceLaunchdIsNotActuallyRunning() {
        let registrar = FakeDaemonServiceRegistrar(status: .enabled, registerOutcome: .failed)
        let launcher = FakeDaemonProcessLauncher()
        let controller = makeController(
            registrar: registrar,
            launcher: launcher,
            socketReachable: false
        )

        controller.start()

        XCTAssertEqual(controller.mode, .registeredService, "the registration really is enabled")
        XCTAssertEqual(launcher.launchCallCount, 1, "but nothing answered, so we start one anyway")
    }

    func testStartFallsBackToAppOwnedAndSpawnsWhenRegistrationFails() {
        let registrar = FakeDaemonServiceRegistrar(status: .notRegistered, registerOutcome: .failed)
        let launcher = FakeDaemonProcessLauncher()
        let controller = makeController(registrar: registrar, launcher: launcher)

        controller.start()

        XCTAssertEqual(controller.mode, .appOwned)
        XCTAssertEqual(launcher.launchCallCount, 1)
        XCTAssertEqual(
            launcher.lastBinaryPath,
            "/Applications/OmniAgent.app/Contents/MacOS/omniagent-pty-daemon"
        )
        XCTAssertEqual(launcher.lastSocketURL, paths.socketURL)
        XCTAssertEqual(launcher.lastDataDir, paths.dataDir)
    }

    func testStartSpawnsWhenApprovalIsStillPending() {
        let registrar = FakeDaemonServiceRegistrar(
            status: .notRegistered,
            registerOutcome: .registered(.requiresApproval)
        )
        let launcher = FakeDaemonProcessLauncher()
        let controller = makeController(registrar: registrar, launcher: launcher)

        controller.start()

        XCTAssertEqual(controller.mode, .appOwned)
        XCTAssertEqual(launcher.launchCallCount, 1)
    }

    func testStartDoesNotReRegisterAnAlreadyEnabledService() {
        let registrar = FakeDaemonServiceRegistrar(status: .enabled, registerOutcome: .failed)
        let controller = makeController(registrar: registrar)

        controller.start()

        XCTAssertEqual(controller.mode, .registeredService)
        XCTAssertEqual(registrar.registerCallCount, 0, "already enabled — must read status, not re-register")
    }

    func testStartDoesNotReRegisterAnAlreadyPendingApproval() {
        let registrar = FakeDaemonServiceRegistrar(status: .requiresApproval, registerOutcome: .failed)
        let controller = makeController(registrar: registrar)

        controller.start()

        XCTAssertEqual(registrar.registerCallCount, 0, "already pending — must not resurface the prompt")
        XCTAssertEqual(controller.mode, .appOwned)
    }

    func testStartDoesNotSpawnWhenTheSocketIsReachable() {
        let registrar = FakeDaemonServiceRegistrar(status: .notRegistered, registerOutcome: .failed)
        let launcher = FakeDaemonProcessLauncher()
        let controller = makeController(registrar: registrar, launcher: launcher, socketReachable: true)

        controller.start()

        XCTAssertEqual(launcher.launchCallCount, 0)
    }

    /// The reviewed fix: a stale socket *file* left behind by an
    /// uncleanly-killed app-owned daemon (no launchd supervision in that
    /// mode) must not block a respawn. Exercises the real
    /// `DaemonSocketProbe.isReachable` — not a fake — against a real Unix
    /// domain socket that was bound and listening, then had its listener
    /// closed without unlinking the path, mirroring a `SIGKILL`.
    func testStartSpawnsWhenAStaleSocketFileIsPresentButNothingIsListening() throws {
        let socketPath = "/tmp/omniagent-stale-\(UUID().uuidString.prefix(8)).sock"
        let listener = try bindAndListenTestSocket(at: socketPath)
        Darwin.close(listener) // the file survives; nothing is listening anymore
        defer { unlink(socketPath) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: socketPath), "the stale file must still exist")

        let registrar = FakeDaemonServiceRegistrar(status: .notRegistered, registerOutcome: .failed)
        let launcher = FakeDaemonProcessLauncher()
        let controller = DaemonPersistenceController(
            paths: paths,
            registrar: registrar,
            processLauncher: launcher,
            resolveBinaryPath: { "/Applications/OmniAgent.app/Contents/MacOS/omniagent-pty-daemon" },
            socketReachable: { DaemonSocketProbe.isReachable(at: URL(fileURLWithPath: socketPath)) }
        )

        controller.start()

        XCTAssertEqual(launcher.launchCallCount, 1, "a stale socket file must not block a respawn")
    }

    func testStartDoesNotSpawnWhenNoBinaryCanBeResolved() {
        let registrar = FakeDaemonServiceRegistrar(status: .notRegistered, registerOutcome: .failed)
        let launcher = FakeDaemonProcessLauncher()
        let controller = makeController(registrar: registrar, launcher: launcher, binaryPath: nil)

        controller.start()

        XCTAssertEqual(launcher.launchCallCount, 0)
    }

    func testStatusDescriptionAndLostSessionsReflectTheOutcome() {
        let registrar = FakeDaemonServiceRegistrar(status: .notRegistered, registerOutcome: .failed)
        let controller = makeController(registrar: registrar)
        controller.start()

        XCTAssertTrue(controller.statusDescription.contains("app-owned"))
        XCTAssertEqual(controller.lostSessions, [])
    }

    // MARK: - Restart-loss reporting

    func testRecordReattachFailureAccumulatesAndNotifies() {
        let registrar = FakeDaemonServiceRegistrar(status: .enabled, registerOutcome: .registered(.enabled))
        let controller = makeController(registrar: registrar)
        var observed: [[String]] = []
        controller.onLostSessionsChanged = { observed.append($0) }

        controller.recordReattachFailure(sessionID: "s1")
        controller.recordReattachFailure(sessionID: "s2")

        XCTAssertEqual(controller.lostSessions, ["s1", "s2"])
        XCTAssertEqual(observed, [["s1"], ["s1", "s2"]])
    }

    func testDismissLostSessionsClearsAndNotifies() {
        let registrar = FakeDaemonServiceRegistrar(status: .enabled, registerOutcome: .registered(.enabled))
        let controller = makeController(registrar: registrar)
        controller.recordReattachFailure(sessionID: "s1")
        var observed: [[String]] = []
        controller.onLostSessionsChanged = { observed.append($0) }

        controller.dismissLostSessions()

        XCTAssertEqual(controller.lostSessions, [])
        XCTAssertEqual(observed, [[]])
    }

    // MARK: - Termination cleanup

    func testStopClearsObserversWithoutTouchingAnySpawnedProcessOrLostSessions() {
        let registrar = FakeDaemonServiceRegistrar(status: .notRegistered, registerOutcome: .failed)
        let launcher = FakeDaemonProcessLauncher()
        let controller = makeController(registrar: registrar, launcher: launcher)
        controller.start()
        controller.recordReattachFailure(sessionID: "s1")
        var modeChanges = 0
        controller.onModeChanged = { _ in modeChanges += 1 }

        controller.stop()
        // A callback that fires after `stop()` must be a no-op: `stop()`
        // clears the closures, it never mutates `mode`/`lostSessions`.
        controller.recordReattachFailure(sessionID: "s2")

        XCTAssertEqual(modeChanges, 0)
        XCTAssertEqual(controller.mode, .appOwned)
        XCTAssertEqual(controller.lostSessions, ["s1", "s2"], "stop() is bookkeeping-only, not a reset")
        XCTAssertEqual(launcher.launchCallCount, 1, "stop() never terminates the daemon process")
    }

    // MARK: - Account switch: terminate + respawn

    func testTerminateDaemonSignalsThePidAndRespawnsInAppOwnedMode() {
        let registrar = FakeDaemonServiceRegistrar(status: .notRegistered, registerOutcome: .failed)
        let launcher = FakeDaemonProcessLauncher()
        let terminator = FakeDaemonTerminator()
        let controller = makeController(registrar: registrar, launcher: launcher, terminator: terminator)
        controller.start()
        XCTAssertEqual(launcher.launchCallCount, 1)

        var completed = 0
        controller.terminateDaemon(pid: 4242) { completed += 1 }

        XCTAssertEqual(terminator.calls.map(\.pid), [4242])
        XCTAssertEqual(terminator.calls.map(\.socketURL), [paths.socketURL])
        XCTAssertEqual(launcher.launchCallCount, 2, "app-owned: nothing else will bring a daemon back")
        XCTAssertEqual(completed, 1)
    }

    func testTerminateDaemonLeavesTheRespawnToLaunchdForARegisteredService() {
        let registrar = FakeDaemonServiceRegistrar(status: .enabled, registerOutcome: .registered(.enabled))
        let launcher = FakeDaemonProcessLauncher()
        let terminator = FakeDaemonTerminator()
        let controller = makeController(
            registrar: registrar, launcher: launcher, socketReachable: true, terminator: terminator
        )
        controller.start()
        XCTAssertEqual(launcher.launchCallCount, 0)

        var completed = 0
        controller.terminateDaemon(pid: nil) { completed += 1 }

        XCTAssertEqual(terminator.calls.count, 1, "the wait for the socket to drop still runs")
        XCTAssertEqual(launcher.launchCallCount, 0, "launchd's KeepAlive owns the respawn")
        XCTAssertEqual(completed, 1)
    }

    // MARK: - SessionConnection.peerProcessID

    /// The pid the terminator signals comes off the connected AF_UNIX
    /// descriptor (`LOCAL_PEERPID`), so it is always the daemon this app is
    /// actually talking to — never a pid file that could be stale. Exercised
    /// against a real listening socket owned by this very process.
    func testPeerProcessIDReadsTheListeningProcessOffTheConnectedDescriptor() throws {
        let path = "/tmp/omniagent-peerpid-\(UUID().uuidString.prefix(8)).sock"
        let listener = try bindAndListenTestSocket(at: path)
        defer {
            Darwin.close(listener)
            unlink(path)
        }
        let connection = SessionConnection(socketURL: URL(fileURLWithPath: path))
        XCTAssertNil(connection.peerProcessID(), "nothing connected yet")

        connection.connect()
        let connected = expectation(description: "the descriptor is connected")
        DispatchQueue.global().async {
            for _ in 0..<100 where connection.peerProcessID() == nil {
                Thread.sleep(forTimeInterval: 0.02)
            }
            connected.fulfill()
        }
        wait(for: [connected], timeout: 5)

        XCTAssertEqual(connection.peerProcessID(), getpid(), "the listener is this very process")
        connection.disconnect()
    }
}
