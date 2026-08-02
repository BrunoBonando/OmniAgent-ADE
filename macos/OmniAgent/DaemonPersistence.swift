import Foundation

// MARK: - Build channel & paths

/// Which build of the app is running — the production dogfood build, or a
/// preview/beta build sharing the same machine. Task 6c's "preview
/// bundle/data separation" requirement: the two must never collide on a
/// data dir, socket path, or LaunchAgent label.
///
/// There is no separate Xcode "Preview" build configuration yet — only
/// Debug/Release, both `digital.bruno.omniagent`
/// (`OmniAgent.xcodeproj/project.pbxproj`'s `PRODUCT_BUNDLE_IDENTIFIER`).
/// Wiring one is Task 6d's (distribution/signing) territory. This resolves
/// from either an explicit `OMNIAGENT_ADE_BUILD_CHANNEL=preview` override
/// (the only way to exercise the preview path today, and a genuine dev-time
/// toggle) or a `.preview`-suffixed bundle identifier, so 6d only needs to
/// add a build configuration with that suffix to activate it — nothing here
/// changes.
enum DaemonBuildChannel: String, Equatable {
    case production
    case preview

    static func resolve(
        bundleIdentifier: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> DaemonBuildChannel {
        if environment["OMNIAGENT_ADE_BUILD_CHANNEL"] == "preview" {
            return .preview
        }
        return (bundleIdentifier ?? "").hasSuffix(".preview") ? .preview : .production
    }
}

/// Where the daemon lives for one build channel: its data dir, its socket,
/// and the label/plist name `SMAppService` registers it under. Every field
/// honors the same environment overrides `AppDelegate` and the daemon
/// itself already do (`OMNIAGENT_PTY_SOCKET`, `OMNIAGENT_ADE_DATA_DIR`), so
/// an explicit override always wins over either channel's default.
struct DaemonPaths: Equatable {
    let channel: DaemonBuildChannel
    let dataDir: URL
    let socketURL: URL
    let launchAgentLabel: String
    let plistName: String

    /// Production's default data dir must resolve to the exact path
    /// `brain_core::Store::default_data_dir()` computes
    /// (`crates/brain-core/src/store.rs:268-276`) — "existing production
    /// data reuse" means this build must never invent a second default.
    /// Production's default socket must likewise match
    /// `AppDelegate.socketURL`'s pre-6c literal exactly.
    static func resolve(
        channel: DaemonBuildChannel,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> DaemonPaths {
        let dataDir: URL
        if let override = environment["OMNIAGENT_ADE_DATA_DIR"] {
            dataDir = URL(fileURLWithPath: override)
        } else {
            switch channel {
            case .production:
                dataDir = homeDirectory.appendingPathComponent(
                    "Library/Application Support/OmniAgent-ADE"
                )
            case .preview:
                dataDir = homeDirectory.appendingPathComponent(
                    "Library/Application Support/OmniAgent-ADE-Preview"
                )
            }
        }

        let socketURL: URL
        if let override = environment["OMNIAGENT_PTY_SOCKET"] {
            socketURL = URL(fileURLWithPath: override)
        } else {
            switch channel {
            case .production:
                socketURL = homeDirectory
                    .appendingPathComponent(".omniagent-ade", isDirectory: true)
                    .appendingPathComponent("omniagent-pty.sock")
            case .preview:
                socketURL = homeDirectory
                    .appendingPathComponent(".omniagent-ade", isDirectory: true)
                    .appendingPathComponent("preview", isDirectory: true)
                    .appendingPathComponent("omniagent-pty.sock")
            }
        }

        let label: String
        switch channel {
        case .production: label = "digital.bruno.omniagent.pty-daemon"
        case .preview: label = "digital.bruno.omniagent.preview.pty-daemon"
        }

        return DaemonPaths(
            channel: channel,
            dataDir: dataDir,
            socketURL: socketURL,
            launchAgentLabel: label,
            plistName: "\(label).plist"
        )
    }
}

// MARK: - Registration status & mode decision

/// Mirrors `ServiceManagement.SMAppService.Status` (macOS 13+) without
/// importing `ServiceManagement` into the decision logic — the whole point
/// being that everything in this file is testable without ever touching the
/// real framework, whose approval flow cannot be exercised in CI.
enum DaemonServiceStatus: Equatable {
    case notRegistered
    case enabled
    case requiresApproval
    case notFound
}

/// The result of one attempt to register (or read back the status of) the
/// LaunchAgent — the thin `SMAppServiceDaemonRegistrar` layer's only output,
/// and the only thing the decision logic below needs to pick a mode.
enum DaemonRegistrationOutcome: Equatable {
    case registered(DaemonServiceStatus)
    case failed
}

enum DaemonPersistenceMode: Equatable {
    /// `SMAppService` reports `.enabled` — launchd owns the daemon's
    /// lifecycle, and it survives this app quitting or crashing.
    case registeredService
    /// Anything else: not yet approved in System Settings, registration
    /// failed, or this build's `SMAppService` plist isn't bundled yet (see
    /// `DaemonLaunchAgentPlist`'s doc comment). The app takes
    /// responsibility for making sure the daemon is running.
    case appOwned
}

/// Pure decision logic — no `SMAppService`, `Process`, or filesystem call
/// anywhere in this enum. `DaemonPersistenceController` is the thin shell
/// that calls the real APIs and feeds their results through here.
enum DaemonPersistence {
    /// Re-registering an already-`.enabled` service is harmless but
    /// pointless, and re-registering a `.requiresApproval` one just
    /// resurfaces a System Settings entry the user already dismissed once.
    /// Only a service that has never been registered, or whose prior
    /// registration can no longer be found, is worth another attempt.
    static func shouldAttemptRegistration(currentStatus: DaemonServiceStatus) -> Bool {
        switch currentStatus {
        case .notRegistered, .notFound: return true
        case .enabled, .requiresApproval: return false
        }
    }

    static func resolveMode(from outcome: DaemonRegistrationOutcome) -> DaemonPersistenceMode {
        if case .registered(.enabled) = outcome { return .registeredService }
        return .appOwned
    }

    /// Degraded mode must not pile a second daemon process on top of one
    /// already listening (dev-started manually, or spawned by an earlier
    /// launch of this same app) — a live socket path reads as "already
    /// running", and the spawn is skipped.
    static func shouldSpawn(mode: DaemonPersistenceMode, socketAlreadyPresent: Bool) -> Bool {
        mode == .appOwned && !socketAlreadyPresent
    }

    static func statusDescription(
        mode: DaemonPersistenceMode,
        outcome: DaemonRegistrationOutcome,
        channel: DaemonBuildChannel
    ) -> String {
        let prefix = channel == .preview ? "[Preview] " : ""
        switch (mode, outcome) {
        case (.registeredService, _), (_, .registered(.enabled)):
            return prefix
                + "Running as a login item — persists across app quits and daemon restarts."
        case (_, .registered(.requiresApproval)):
            return prefix
                + "Waiting for approval in System Settings \u{2192} General \u{2192} Login Items. "
                + "Running in app-owned mode until approved."
        case (_, .registered(.notFound)):
            return prefix + "Login item registration not found — running in app-owned mode."
        case (_, .registered(.notRegistered)):
            return prefix + "Not yet registered as a login item — running in app-owned mode."
        case (_, .failed):
            return prefix + "Could not register as a login item — running in app-owned mode."
        }
    }
}

// MARK: - Restart-loss reporting

/// Sessions the daemon forgot about since the app last observed it —
/// detected via `SessionConnection.onReattachFailed` (a reconnect's
/// automatic reattach came back "session not found", the signal a daemon
/// restart leaves behind since PTY session state lives in the daemon
/// process, not on disk). Pure and order-preserving so the status UI can
/// list them and let the user dismiss the report once read, "rather than
/// silently reattaching to nothing" (the Task 6c brief's own phrase for the
/// bug this fixes).
struct DaemonRestartLossTracker: Equatable {
    private(set) var lostSessions: [String] = []

    mutating func recordReattachFailure(sessionID: String) {
        guard !lostSessions.contains(sessionID) else { return }
        lostSessions.append(sessionID)
    }

    mutating func dismiss() {
        lostSessions.removeAll()
    }
}

// MARK: - LaunchAgent plist content

/// The standard launchd property list `SMAppService.agent(plistName:)`
/// expects to find at `Contents/Library/LaunchAgents/<plistName>` inside
/// the app bundle. Building it here — pure, tested — pins down the exact
/// content Task 6d's Xcode bundling step must embed.
///
/// **This task does not add the Copy Files build phase or embed the
/// compiled `omniagent-pty-daemon` binary itself.** Both couple to
/// code-signing/notarization decisions that belong with 6d's
/// "distribution/signing" scope, and neither can be verified end-to-end
/// without it — see the Task 6c report's self-review section. Until that
/// lands, `SMAppServiceDaemonRegistrar.register()` correctly fails (no
/// plist to find) and the app correctly falls back to degraded app-owned
/// mode, which is the real, working path this build ships with today.
enum DaemonLaunchAgentPlist {
    /// `programPath` is bundle-relative (e.g.
    /// `Contents/MacOS/omniagent-pty-daemon`) — `SMAppService` resolves
    /// relative `ProgramArguments[0]` paths against the app's own install
    /// location at registration time, so the plist never hardcodes an
    /// absolute path that would break the moment the app is moved.
    static func build(
        label: String,
        programPath: String,
        socketURL: URL,
        dataDir: URL
    ) -> [String: Any] {
        [
            "Label": label,
            "ProgramArguments": [programPath],
            "RunAtLoad": true,
            "KeepAlive": true,
            "ProcessType": "Interactive",
            "EnvironmentVariables": [
                "OMNIAGENT_PTY_SOCKET": socketURL.path,
                "OMNIAGENT_ADE_DATA_DIR": dataDir.path,
            ],
        ]
    }
}
