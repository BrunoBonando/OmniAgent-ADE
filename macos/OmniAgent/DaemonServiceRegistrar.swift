import Foundation
import ServiceManagement

/// What `DaemonPersistenceController` needs from `SMAppService` — narrowed
/// to exactly the two calls `DaemonPersistence`'s decision logic reasons
/// about, so a fake can stand in without ever touching `ServiceManagement`.
protocol DaemonServiceRegistrar {
    func currentStatus() -> DaemonServiceStatus
    func register() -> DaemonRegistrationOutcome
}

/// The real, thin layer — every call here is genuine `SMAppService` API.
/// None of it is exercised by this task's automated tests (its approval
/// flow cannot run in CI; see the Task 6c report's "untestable in CI"
/// section). `DaemonPersistenceControllerTests` stands a fake
/// `DaemonServiceRegistrar` in for it instead.
final class SMAppServiceDaemonRegistrar: DaemonServiceRegistrar {
    private let service: SMAppService

    /// A per-user LaunchAgent (`.agent`), never `.daemon` — the brief is
    /// explicit that `.daemon` (root/system-level) is wrong for a per-user
    /// PTY session owner.
    init(plistName: String) {
        service = SMAppService.agent(plistName: plistName)
    }

    func currentStatus() -> DaemonServiceStatus {
        DaemonServiceStatus(service.status)
    }

    func register() -> DaemonRegistrationOutcome {
        do {
            try service.register()
            return .registered(currentStatus())
        } catch {
            return .failed
        }
    }
}

private extension DaemonServiceStatus {
    init(_ status: SMAppService.Status) {
        switch status {
        case .notRegistered: self = .notRegistered
        case .enabled: self = .enabled
        case .requiresApproval: self = .requiresApproval
        case .notFound: self = .notFound
        @unknown default: self = .notFound
        }
    }
}

/// The System Settings deep link the status UI's "Open Login Items
/// Settings…" button uses. Isolated here (rather than called directly from
/// `SettingsView.swift`) so `ServiceManagement` stays imported in exactly
/// one file.
enum SystemLoginItemsSettings {
    static func open() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

// MARK: - Degraded app-owned mode: spawning the daemon ourselves

/// Where the daemon binary might be found, in priority order. Mirrors
/// `src-tauri/src/daemon.rs`'s `resolve_daemon_binary` — the Tauri-side
/// auto-launcher precedent the Task 6c brief points at — minus its "shell
/// out to `cargo build`" dev convenience, which would be surprising
/// behavior for a packaged GUI app to do silently.
enum DaemonBinaryLocator {
    /// Pure: the first candidate `fileExists` accepts. Kept separate from
    /// `candidates(...)` below so the search-*order* rule is unit-testable
    /// without touching `Bundle`/`ProcessInfo`/the real filesystem.
    static func resolve(
        candidates: [String],
        fileExists: (String) -> Bool
    ) -> String? {
        candidates.first(where: fileExists)
    }

    /// This build's real candidate list: an explicit override (matching
    /// `daemon.rs`'s `OMNIAGENT_PTY_DAEMON_BIN` env var name), the two
    /// locations Task 6d may embed the binary at once it wires the
    /// bundling, then every `PATH` directory.
    static func candidates(
        bundleURL: URL,
        environment: [String: String]
    ) -> [String] {
        var result: [String] = []
        if let override = environment["OMNIAGENT_PTY_DAEMON_BIN"] {
            result.append(override)
        }
        result.append(
            bundleURL.appendingPathComponent("Contents/MacOS/omniagent-pty-daemon").path
        )
        result.append(
            bundleURL.appendingPathComponent("Contents/Resources/omniagent-pty-daemon").path
        )
        if let path = environment["PATH"] {
            for dir in path.split(separator: ":") {
                result.append("\(dir)/omniagent-pty-daemon")
            }
        }
        return result
    }
}

/// A running, app-spawned daemon process — narrowed to what
/// `DaemonPersistenceController` needs to know about it.
protocol DaemonProcessHandle {
    var isRunning: Bool { get }
}

protocol DaemonProcessLaunching {
    func launch(binaryPath: String, socketURL: URL, dataDir: URL) throws -> DaemonProcessHandle
}

/// The real shell: an actual `Process`. Deliberately never terminated by
/// this app on quit — see `DaemonPersistenceController`'s doc comment on
/// `recordReattachFailure` and the Task 6c report's "termination cleanup"
/// section: killing it would kill every live PTY session it owns, which is
/// exactly the persistence this whole task exists to provide, degraded mode
/// included.
final class LiveDaemonProcessLauncher: DaemonProcessLaunching {
    func launch(binaryPath: String, socketURL: URL, dataDir: URL) throws -> DaemonProcessHandle {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.environment = ProcessInfo.processInfo.environment.merging(
            ["OMNIAGENT_PTY_SOCKET": socketURL.path, "OMNIAGENT_ADE_DATA_DIR": dataDir.path]
        ) { _, new in new }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return LiveDaemonProcessHandle(process: process)
    }
}

private final class LiveDaemonProcessHandle: DaemonProcessHandle {
    private let process: Process
    init(process: Process) { self.process = process }
    var isRunning: Bool { process.isRunning }
}
