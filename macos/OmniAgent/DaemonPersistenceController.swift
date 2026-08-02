import Foundation

/// What `SettingsViewModel`'s Daemon tab needs from the persistence
/// mechanism — narrowed to exactly what the status UI reads/does, the same
/// seam shape `BrainClients.swift` gives every other settings-adjacent
/// client (a protocol over `SessionConnection`, plus a blank `extension`
/// conformance below).
protocol DaemonStatusProviding {
    var mode: DaemonPersistenceMode { get }
    var statusDescription: String { get }
    var lostSessions: [String] { get }
    func dismissLostSessions()
}

/// Owns the whole Task 6c mechanism end to end: attempts `SMAppService`
/// registration once at launch, falls back to spawning the daemon itself
/// when registration isn't (yet) `.enabled`, and collects restart-loss
/// reports fed from `SessionConnection.onReattachFailed`.
///
/// Deliberately thin — every actual decision (`resolveMode`,
/// `shouldAttemptRegistration`, `shouldSpawn`) lives in the pure
/// `DaemonPersistence` enum; this class's own job is wiring those decisions
/// to the real `SMAppService`/`Process`/filesystem calls that cannot be
/// exercised in CI (see the Task 6c report). `DaemonPersistenceControllerTests`
/// exercises this class's own logic — gating, spawning, loss tracking —
/// against fake `DaemonServiceRegistrar`/`DaemonProcessLaunching`
/// implementations, so only the two real API calls themselves go untested.
final class DaemonPersistenceController {
    let paths: DaemonPaths
    private(set) var mode: DaemonPersistenceMode = .appOwned
    private(set) var lastOutcome: DaemonRegistrationOutcome = .failed
    private(set) var restartLoss = DaemonRestartLossTracker()

    private let registrar: DaemonServiceRegistrar
    private let processLauncher: DaemonProcessLaunching
    private let resolveBinaryPath: () -> String?
    /// A real liveness probe result, not file existence — see
    /// `DaemonSocketProbe`'s doc comment for why the distinction matters.
    private let socketReachable: () -> Bool
    /// Retained for as long as the app runs so the child process stays
    /// tracked — never used to terminate it (see `LiveDaemonProcessLauncher`'s
    /// doc comment).
    private var ownedProcess: DaemonProcessHandle?

    var onModeChanged: ((DaemonPersistenceMode) -> Void)?
    var onLostSessionsChanged: (([String]) -> Void)?

    init(
        paths: DaemonPaths,
        registrar: DaemonServiceRegistrar,
        processLauncher: DaemonProcessLaunching,
        resolveBinaryPath: @escaping () -> String?,
        socketReachable: @escaping () -> Bool
    ) {
        self.paths = paths
        self.registrar = registrar
        self.processLauncher = processLauncher
        self.resolveBinaryPath = resolveBinaryPath
        self.socketReachable = socketReachable
    }

    /// The real, production-shaped construction: a genuine `SMAppService`
    /// registrar and process launcher. Tests use the designated
    /// initializer above with fakes instead.
    convenience init(paths: DaemonPaths = DaemonPaths.resolve(channel: .production)) {
        self.init(
            paths: paths,
            registrar: SMAppServiceDaemonRegistrar(plistName: paths.plistName),
            processLauncher: LiveDaemonProcessLauncher(),
            resolveBinaryPath: {
                DaemonBinaryLocator.resolve(
                    candidates: DaemonBinaryLocator.candidates(
                        bundleURL: Bundle.main.bundleURL,
                        environment: ProcessInfo.processInfo.environment
                    ),
                    fileExists: { FileManager.default.isExecutableFile(atPath: $0) }
                )
            },
            socketReachable: {
                DaemonSocketProbe.isReachable(at: paths.socketURL)
            }
        )
    }

    /// Call once at launch, before connecting. Registers (or reads back an
    /// already-registered status without re-prompting), resolves the mode,
    /// and — only in app-owned mode, only when nothing is actually
    /// reachable on the socket (a real probe, not a file check) — spawns
    /// the daemon.
    func start() {
        let status = registrar.currentStatus()
        let outcome: DaemonRegistrationOutcome =
            DaemonPersistence.shouldAttemptRegistration(currentStatus: status)
            ? registrar.register()
            : .registered(status)
        lastOutcome = outcome
        mode = DaemonPersistence.resolveMode(from: outcome)
        onModeChanged?(mode)

        guard
            DaemonPersistence.shouldSpawn(mode: mode, socketReachable: socketReachable())
        else { return }
        guard let binaryPath = resolveBinaryPath() else { return }
        ownedProcess = try? processLauncher.launch(
            binaryPath: binaryPath,
            socketURL: paths.socketURL,
            dataDir: paths.dataDir
        )
    }

    /// Wired to `SessionConnection.onReattachFailed`. Deliberately never
    /// touches `ownedProcess`/the daemon itself — termination cleanup is
    /// limited to this controller's own bookkeeping (see `stop()`), not the
    /// daemon-owned sessions this exists to keep alive.
    func recordReattachFailure(sessionID: String) {
        restartLoss.recordReattachFailure(sessionID: sessionID)
        onLostSessionsChanged?(restartLoss.lostSessions)
    }

    /// The app's own termination cleanup: clears observer closures. Never
    /// touches the daemon process or its sessions in either mode — see the
    /// Task 6c report's "termination cleanup" section for why.
    func stop() {
        onModeChanged = nil
        onLostSessionsChanged = nil
    }
}

extension DaemonPersistenceController: DaemonStatusProviding {
    var statusDescription: String {
        DaemonPersistence.statusDescription(mode: mode, outcome: lastOutcome, channel: paths.channel)
    }

    var lostSessions: [String] { restartLoss.lostSessions }

    func dismissLostSessions() {
        restartLoss.dismiss()
        onLostSessionsChanged?(restartLoss.lostSessions)
    }
}
