import Darwin
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

/// Is a daemon actually listening on this Unix domain socket? **File
/// presence is not enough** — a socket file is not removed automatically
/// when its owning process dies uncleanly (SIGKILL, a panic before its own
/// cleanup runs), which is exactly the case degraded app-owned mode has to
/// handle since nothing supervises it the way launchd supervises a
/// registered service. Mirrors `src-tauri/src/daemon.rs`'s
/// `remove_stale_socket_if_unreachable()`: a real, immediately-abandoned
/// `connect()` attempt, not a `FileManager` existence check.
enum DaemonSocketProbe {
    static func isReachable(at socketURL: URL) -> Bool {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }
        let result = try? withUnixSocketAddress(path: socketURL.path) {
            Darwin.connect(descriptor, $0, $1)
        }
        return result == 0
    }
}

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

    /// Whether this is a Debug build. Kept independent of `WebInspectorPolicy`
    /// (owned by a different task) even though the `#if DEBUG` body matches.
    static var isDebugBuild: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    /// This build's real candidate list: an explicit override (matching
    /// `daemon.rs`'s `OMNIAGENT_PTY_DAEMON_BIN` env var name), the two
    /// locations Task 6d may embed the binary at once it wires the
    /// bundling, then every `PATH` directory.
    ///
    /// The override and `PATH` fallbacks are gated on `debugBuild`: in every
    /// non-Debug configuration, the "Embed PTY Daemon" build phase hard-fails
    /// if the daemon is missing, so the bundled path always exists and wins —
    /// those fallbacks are only ever reached in Debug builds, so restricting
    /// them there removes attack surface without changing behavior.
    static func candidates(
        bundleURL: URL,
        environment: [String: String],
        debugBuild: Bool = isDebugBuild
    ) -> [String] {
        var result: [String] = []
        if debugBuild, let override = environment["OMNIAGENT_PTY_DAEMON_BIN"] {
            result.append(override)
        }
        result.append(
            bundleURL.appendingPathComponent("Contents/MacOS/omniagent-pty-daemon").path
        )
        result.append(
            bundleURL.appendingPathComponent("Contents/Resources/omniagent-pty-daemon").path
        )
        if debugBuild, let path = environment["PATH"] {
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

// MARK: - Account switch: ending the running daemon

/// Ends the daemon on the other side of the socket and waits for it to be
/// gone. The one place the app is allowed to end a daemon — and it is only
/// ever reached after the user agreed to (`WorkspaceWindowController.
/// switchAccount`/`logOutOfAccount` ask first whenever sessions would end):
/// "Do not kill the daemon on your choice. Just do it if I allow."
protocol DaemonTerminating {
    /// SIGTERM `pid` (when known — the daemon's own handler shuts every PTY
    /// down and unlinks its socket) and poll `socketURL` until nothing
    /// answers, for at most `timeout`. Completes on the main queue with
    /// whether the socket actually dropped.
    func terminate(pid: pid_t?, socketURL: URL, timeout: TimeInterval, completion: @escaping (Bool) -> Void)
}

final class LiveDaemonTerminator: DaemonTerminating {
    func terminate(pid: pid_t?, socketURL: URL, timeout: TimeInterval, completion: @escaping (Bool) -> Void) {
        if let pid, pid > 0 {
            Darwin.kill(pid, SIGTERM)
        }
        let deadline = Date().addingTimeInterval(timeout)
        DispatchQueue.global(qos: .userInitiated).async {
            var gone = !DaemonSocketProbe.isReachable(at: socketURL)
            while !gone, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.1)
                gone = !DaemonSocketProbe.isReachable(at: socketURL)
            }
            DispatchQueue.main.async { completion(gone) }
        }
    }
}
