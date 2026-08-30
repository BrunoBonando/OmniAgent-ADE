import XCTest
@testable import OmniAgent

/// Task 6c's pure decision logic — build-channel/path resolution, the
/// registration-attempt gate, the mode decision, the spawn gate, restart-loss
/// tracking, and the LaunchAgent plist's content. Nothing here touches
/// `SMAppService`, `Process`, or the real filesystem — that's
/// `DaemonPersistenceControllerTests`' job, against fakes.
final class DaemonPersistenceTests: XCTestCase {
    // MARK: - DaemonBuildChannel

    func testBuildChannelDefaultsToProduction() {
        XCTAssertEqual(
            DaemonBuildChannel.resolve(bundleIdentifier: "digital.bruno.omniagent", environment: [:]),
            .production
        )
        XCTAssertEqual(DaemonBuildChannel.resolve(bundleIdentifier: nil, environment: [:]), .production)
    }

    func testBuildChannelResolvesPreviewFromABundleIdentifierSuffix() {
        XCTAssertEqual(
            DaemonBuildChannel.resolve(
                bundleIdentifier: "digital.bruno.omniagent.preview",
                environment: [:]
            ),
            .preview
        )
    }

    func testBuildChannelEnvironmentOverrideWinsOverTheBundleIdentifier() {
        XCTAssertEqual(
            DaemonBuildChannel.resolve(
                bundleIdentifier: "digital.bruno.omniagent",
                environment: ["OMNIAGENT_ADE_BUILD_CHANNEL": "preview"]
            ),
            .preview
        )
    }

    // MARK: - DaemonPaths

    func testProductionPathsMatchTheExistingUnchangedLiterals() {
        let home = URL(fileURLWithPath: "/Users/dev")
        let paths = DaemonPaths.resolve(channel: .production, homeDirectory: home, environment: [:])

        // `crates/brain-core/src/store.rs:268-276`'s `default_data_dir()`.
        XCTAssertEqual(paths.dataDir.path, "/Users/dev/Library/Application Support/OmniAgent-ADE")
        // `AppDelegate.swift`'s pre-6c `socketURL` literal.
        XCTAssertEqual(paths.socketURL.path, "/Users/dev/.omniagent-ade/omniagent-pty.sock")
        XCTAssertEqual(paths.launchAgentLabel, "digital.bruno.omniagent.pty-daemon")
        XCTAssertEqual(paths.plistName, "digital.bruno.omniagent.pty-daemon.plist")
    }

    func testPreviewPathsAreDistinctFromProductionInEveryField() {
        let home = URL(fileURLWithPath: "/Users/dev")
        let production = DaemonPaths.resolve(channel: .production, homeDirectory: home, environment: [:])
        let preview = DaemonPaths.resolve(channel: .preview, homeDirectory: home, environment: [:])

        XCTAssertNotEqual(production.dataDir, preview.dataDir)
        XCTAssertNotEqual(production.socketURL, preview.socketURL)
        XCTAssertNotEqual(production.launchAgentLabel, preview.launchAgentLabel)
        XCTAssertNotEqual(production.plistName, preview.plistName)
    }

    func testEnvironmentOverridesWinOverEitherChannelsDefault() {
        let home = URL(fileURLWithPath: "/Users/dev")
        let environment = [
            "OMNIAGENT_ADE_DATA_DIR": "/tmp/scratch-data",
            "OMNIAGENT_PTY_SOCKET": "/tmp/scratch.sock",
        ]

        for channel in [DaemonBuildChannel.production, .preview] {
            let paths = DaemonPaths.resolve(channel: channel, homeDirectory: home, environment: environment)
            XCTAssertEqual(paths.dataDir.path, "/tmp/scratch-data")
            XCTAssertEqual(paths.socketURL.path, "/tmp/scratch.sock")
        }
    }

    // MARK: - shouldAttemptRegistration

    func testShouldAttemptRegistrationOnlyForNotRegisteredOrNotFound() {
        XCTAssertTrue(DaemonPersistence.shouldAttemptRegistration(currentStatus: .notRegistered))
        XCTAssertTrue(DaemonPersistence.shouldAttemptRegistration(currentStatus: .notFound))
        XCTAssertFalse(DaemonPersistence.shouldAttemptRegistration(currentStatus: .enabled))
        XCTAssertFalse(DaemonPersistence.shouldAttemptRegistration(currentStatus: .requiresApproval))
    }

    // MARK: - resolveMode

    func testResolveModeIsRegisteredServiceOnlyWhenEnabled() {
        XCTAssertEqual(
            DaemonPersistence.resolveMode(from: .registered(.enabled)),
            .registeredService
        )
    }

    func testResolveModeIsAppOwnedForEveryOtherOutcome() {
        XCTAssertEqual(DaemonPersistence.resolveMode(from: .registered(.notRegistered)), .appOwned)
        XCTAssertEqual(DaemonPersistence.resolveMode(from: .registered(.requiresApproval)), .appOwned)
        XCTAssertEqual(DaemonPersistence.resolveMode(from: .registered(.notFound)), .appOwned)
        XCTAssertEqual(DaemonPersistence.resolveMode(from: .failed), .appOwned)
    }

    // MARK: - shouldSpawn

    func testShouldSpawnWheneverNothingIsListening() {
        XCTAssertTrue(DaemonPersistence.shouldSpawn(socketReachable: false))
        XCTAssertFalse(DaemonPersistence.shouldSpawn(socketReachable: true))
    }


    // MARK: - statusDescription

    func testStatusDescriptionNamesTheRegisteredServiceCase() {
        let description = DaemonPersistence.statusDescription(
            mode: .registeredService,
            outcome: .registered(.enabled),
            channel: .production
        )
        XCTAssertTrue(description.contains("login item"))
    }

    func testStatusDescriptionNamesWaitingForApproval() {
        let description = DaemonPersistence.statusDescription(
            mode: .appOwned,
            outcome: .registered(.requiresApproval),
            channel: .production
        )
        XCTAssertTrue(description.contains("System Settings"))
    }

    func testStatusDescriptionPrefixesPreviewBuilds() {
        let description = DaemonPersistence.statusDescription(
            mode: .appOwned,
            outcome: .failed,
            channel: .preview
        )
        XCTAssertTrue(description.hasPrefix("[Preview] "))
    }

    // MARK: - DaemonRestartLossTracker

    func testRestartLossTrackerAccumulatesInOrderAndDeduplicates() {
        var tracker = DaemonRestartLossTracker()
        tracker.recordReattachFailure(sessionID: "s1")
        tracker.recordReattachFailure(sessionID: "s2")
        tracker.recordReattachFailure(sessionID: "s1")
        XCTAssertEqual(tracker.lostSessions, ["s1", "s2"])
    }

    func testRestartLossTrackerDismissClears() {
        var tracker = DaemonRestartLossTracker()
        tracker.recordReattachFailure(sessionID: "s1")
        tracker.dismiss()
        XCTAssertEqual(tracker.lostSessions, [])
    }

    // MARK: - DaemonLaunchAgentPlist

    func testLaunchAgentPlistContainsTheStandardLaunchdKeysAndEnvironment() throws {
        let plist = DaemonLaunchAgentPlist.build(
            label: "digital.bruno.omniagent.pty-daemon",
            programPath: "Contents/MacOS/omniagent-pty-daemon",
            socketURL: URL(fileURLWithPath: "/Users/dev/.omniagent-ade/omniagent-pty.sock"),
            dataDir: URL(fileURLWithPath: "/Users/dev/Library/Application Support/OmniAgent-ADE")
        )

        XCTAssertEqual(plist["Label"] as? String, "digital.bruno.omniagent.pty-daemon")
        XCTAssertEqual(
            plist["ProgramArguments"] as? [String],
            ["Contents/MacOS/omniagent-pty-daemon"]
        )
        XCTAssertEqual(plist["RunAtLoad"] as? Bool, true)
        XCTAssertEqual(plist["KeepAlive"] as? Bool, true)
        let environment = try XCTUnwrap(plist["EnvironmentVariables"] as? [String: String])
        XCTAssertEqual(environment["OMNIAGENT_PTY_SOCKET"], "/Users/dev/.omniagent-ade/omniagent-pty.sock")
        XCTAssertEqual(
            environment["OMNIAGENT_ADE_DATA_DIR"],
            "/Users/dev/Library/Application Support/OmniAgent-ADE"
        )
    }

    // MARK: - DaemonBinaryLocator

    func testBinaryLocatorResolveReturnsTheFirstExistingCandidate() {
        let resolved = DaemonBinaryLocator.resolve(
            candidates: ["/a/missing", "/b/present", "/c/present-too"],
            fileExists: { $0 == "/b/present" || $0 == "/c/present-too" }
        )
        XCTAssertEqual(resolved, "/b/present")
    }

    func testBinaryLocatorResolveReturnsNilWhenNothingExists() {
        let resolved = DaemonBinaryLocator.resolve(candidates: ["/a", "/b"], fileExists: { _ in false })
        XCTAssertNil(resolved)
    }

    func testBinaryLocatorCandidatesPutsTheEnvironmentOverrideFirst() {
        let candidates = DaemonBinaryLocator.candidates(
            bundleURL: URL(fileURLWithPath: "/Applications/OmniAgent.app"),
            environment: ["OMNIAGENT_PTY_DAEMON_BIN": "/custom/daemon", "PATH": "/usr/bin:/usr/local/bin"],
            debugBuild: true
        )
        XCTAssertEqual(candidates.first, "/custom/daemon")
        XCTAssertTrue(candidates.contains("/Applications/OmniAgent.app/Contents/MacOS/omniagent-pty-daemon"))
        XCTAssertTrue(
            candidates.contains("/Applications/OmniAgent.app/Contents/Resources/omniagent-pty-daemon")
        )
        XCTAssertTrue(candidates.contains("/usr/bin/omniagent-pty-daemon"))
        XCTAssertTrue(candidates.contains("/usr/local/bin/omniagent-pty-daemon"))
    }

    func testBinaryLocatorCandidatesWithoutAnOverrideStillOffersBundleAndPathLocations() {
        let candidates = DaemonBinaryLocator.candidates(
            bundleURL: URL(fileURLWithPath: "/Applications/OmniAgent.app"),
            environment: ["PATH": "/usr/bin"],
            debugBuild: true
        )
        XCTAssertFalse(candidates.isEmpty)
        XCTAssertFalse(candidates.contains(where: { $0 == "/custom/daemon" }))
    }

    func testReleaseBuildsOnlyLaunchTheBundledDaemon() {
        let candidates = DaemonBinaryLocator.candidates(
            bundleURL: URL(fileURLWithPath: "/Applications/OmniAgent.app"),
            environment: ["OMNIAGENT_PTY_DAEMON_BIN": "/custom/daemon", "PATH": "/usr/bin:/usr/local/bin"],
            debugBuild: false
        )
        XCTAssertEqual(candidates, [
            "/Applications/OmniAgent.app/Contents/MacOS/omniagent-pty-daemon",
            "/Applications/OmniAgent.app/Contents/Resources/omniagent-pty-daemon",
        ])
    }
}
