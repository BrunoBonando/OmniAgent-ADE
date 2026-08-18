import XCTest
@testable import OmniAgent

/// A minimal `NotificationDelivering` fake, local to this file (the
/// existing ones in `SessionNotifierTests.swift`/`WorkspaceWindowControllerTests.swift`
/// are each `private` to their own file).
private final class RecordingDelivery: NotificationDelivering {
    func requestAuthorization() {}
    func deliver(_ entry: NotificationEntry) {}
    func withdraw(identifiers: [String]) {}
    func deliverTransient(identifier: String, title: String, body: String, sessionID: String) {}
}

/// A scripted `DaemonStatusProviding` — local to this file, mirroring
/// `FakeSettingsClient`/`FakeBrainAdminClient`'s shape, so the Daemon tab's
/// view-model wiring is testable without a real `DaemonPersistenceController`.
private final class FakeDaemonStatus: DaemonStatusProviding {
    var mode: DaemonPersistenceMode
    var statusDescription: String
    var lostSessions: [String]
    private(set) var dismissCallCount = 0

    init(
        mode: DaemonPersistenceMode = .appOwned,
        statusDescription: String = "Running in app-owned mode.",
        lostSessions: [String] = []
    ) {
        self.mode = mode
        self.statusDescription = statusDescription
        self.lostSessions = lostSessions
    }

    func dismissLostSessions() {
        dismissCallCount += 1
        lostSessions = []
    }
}

/// The About tab's version line. Until the final whole-branch review
/// (Important #4) the Xcode project set no `MARKETING_VERSION` at all, so
/// every native build shipped `CFBundleShortVersionString = 1.0` forever —
/// which also broke `cutover.sh record --version`, Task 7's cutover gate.
final class NativeAppVersionTests: XCTestCase {
    func testRecombinesTheMarketingVersionAndBuildNumberIntoTheRepoWideString() {
        // `scripts/bump-build-version.sh` writes MARKETING_VERSION = 2026.8.3
        // and CURRENT_PROJECT_VERSION = 1 for a repo version of 2026.8.3+001;
        // this must put them back together exactly.
        XCTAssertEqual(NativeAppVersion.compose(short: "2026.8.3", build: "1"), "2026.8.3+001")
        XCTAssertEqual(NativeAppVersion.compose(short: "2026.8.3", build: "12"), "2026.8.3+012")
        XCTAssertEqual(NativeAppVersion.compose(short: "2026.12.31", build: "144"), "2026.12.31+144")
    }

    func testDegradesToTheMarketingVersionRatherThanToNothing() {
        XCTAssertEqual(NativeAppVersion.compose(short: "2026.8.3", build: nil), "2026.8.3")
        XCTAssertEqual(NativeAppVersion.compose(short: "2026.8.3", build: "not-a-number"), "2026.8.3")
    }

    func testHasNoVersionLineWhenTheBundleDeclaresNoVersionAtAll() {
        XCTAssertNil(NativeAppVersion.compose(short: nil, build: "1"))
        XCTAssertNil(NativeAppVersion.compose(short: "", build: "1"))
    }
}

final class SettingsViewModelTests: XCTestCase {
    private func makeModel(
        settingsRows: [String: String] = [:],
        brainAdmin: FakeBrainAdminClient = FakeBrainAdminClient(),
        notifier: SessionNotifier = SessionNotifier(delivery: RecordingDelivery()),
        daemonStatus: FakeDaemonStatus = FakeDaemonStatus(),
        revokeServerSession: @escaping () -> Void = {}
    ) -> (SettingsViewModel, FakeSettingsClient) {
        let client = FakeSettingsClient(rows: settingsRows)
        let settings = SettingsStore(client: client)
        let model = SettingsViewModel(
            settings: settings,
            authGate: AuthGateCoordinator(settings: settings),
            brainAdmin: brainAdmin,
            notifier: notifier,
            version: "2026.7.30",
            daemonStatus: daemonStatus,
            openLoginItemsSettings: {},
            revokeServerSession: revokeServerSession
        )
        return (model, client)
    }

    func testInitLoadsAccountReviewAndPanelsFromSettings() {
        let (model, _) = makeModel(settingsRows: [
            "auth_signed_in": "false",
            "review_memory": "true",
            "file_tree_width": "260",
            "code_review_width": "420",
        ])

        XCTAssertFalse(model.authSignedIn)
        XCTAssertEqual(model.authSummary, "Not signed in (dev mode).")
        XCTAssertTrue(model.reviewMemoryEnabled)
        XCTAssertEqual(model.fileTreeWidthText, "260")
        XCTAssertEqual(model.codeReviewWidthText, "420")
        XCTAssertEqual(model.versionLine, "v2026.7.30 — dogfood build")
    }

    func testSettingReviewMemoryPersistsTheLiteralTrueFalseString() {
        let (model, client) = makeModel()
        model.setReviewMemory(true)
        XCTAssertTrue(model.reviewMemoryEnabled)
        XCTAssertEqual(client.rows["review_memory"], "true")

        model.setReviewMemory(false)
        XCTAssertEqual(client.rows["review_memory"], "false")
    }

    func testCommittingPanelWidthsPersiststheTypedText() {
        let (model, client) = makeModel()
        model.fileTreeWidthText = "300"
        model.commitFileTreeWidth()
        XCTAssertEqual(client.rows["file_tree_width"], "300")

        model.codeReviewWidthText = "500"
        model.commitCodeReviewWidth()
        XCTAssertEqual(client.rows["code_review_width"], "500")
    }

    /// Minor #11: a transient read failure must not become a write. Both the
    /// Review toggle and the panel-width fields used to fall back to a
    /// default on a `.failure`, then persist that default the moment the user
    /// touched them — over a row the web build reads from the same
    /// `brain.db`.
    func testAFailedReviewReadNeverWritesTheDefaultOverTheRealRow() {
        let client = FakeSettingsClient(rows: ["review_memory": "true"])
        client.failing = ["review_memory"]
        let settings = SettingsStore(client: client)
        let model = SettingsViewModel(
            settings: settings,
            authGate: AuthGateCoordinator(settings: settings),
            brainAdmin: FakeBrainAdminClient(),
            notifier: SessionNotifier(delivery: RecordingDelivery()),
            version: "2026.8.3+001",
            daemonStatus: FakeDaemonStatus(),
            openLoginItemsSettings: {}
        )

        XCTAssertTrue(model.reviewMemoryReadFailed, "the failure is surfaced, not swallowed")

        model.setReviewMemory(true)
        XCTAssertTrue(
            client.setCalls.filter { $0.key == "review_memory" }.isEmpty,
            "the write gate must stay shut while the real value is unknown"
        )
        XCTAssertEqual(client.rows["review_memory"], "true", "the real row is untouched")

        // The retry the refused write kicked off now succeeds.
        client.failing = []
        model.setReviewMemory(false)
        XCTAssertTrue(model.reviewMemoryEnabled, "the retry read the real value back")
        XCTAssertFalse(model.reviewMemoryReadFailed)

        // And with a good read behind it, writing works normally again.
        model.setReviewMemory(false)
        XCTAssertEqual(client.rows["review_memory"], "false")
    }

    func testAFailedPanelWidthReadNeverWritesAnEmptyWidthOverTheSavedOne() {
        let client = FakeSettingsClient(rows: ["file_tree_width": "260", "code_review_width": "420"])
        client.failing = ["file_tree_width"]
        let settings = SettingsStore(client: client)
        let model = SettingsViewModel(
            settings: settings,
            authGate: AuthGateCoordinator(settings: settings),
            brainAdmin: FakeBrainAdminClient(),
            notifier: SessionNotifier(delivery: RecordingDelivery()),
            version: "2026.8.3+001",
            daemonStatus: FakeDaemonStatus(),
            openLoginItemsSettings: {}
        )

        XCTAssertTrue(model.fileTreeWidthReadFailed)
        XCTAssertTrue(model.panelsReadFailed)
        XCTAssertFalse(model.codeReviewWidthReadFailed, "the other row read fine")
        XCTAssertEqual(model.codeReviewWidthText, "420")

        model.commitFileTreeWidth()
        XCTAssertTrue(
            client.setCalls.filter { $0.key == "file_tree_width" }.isEmpty,
            "an empty field from a failed read must never be persisted"
        )
        XCTAssertEqual(client.rows["file_tree_width"], "260", "the real width is untouched")

        // The row that *did* read is writable throughout.
        model.codeReviewWidthText = "500"
        model.commitCodeReviewWidth()
        XCTAssertEqual(client.rows["code_review_width"], "500")

        client.failing = []
        model.commitFileTreeWidth() // refuses, retries the read
        XCTAssertFalse(model.fileTreeWidthReadFailed)
        XCTAssertEqual(model.fileTreeWidthText, "260")
        model.commitFileTreeWidth()
        XCTAssertEqual(client.rows["file_tree_width"], "260")
    }

    func testSignOutResetsTheAuthGateAndRefreshesTheSummary() {
        var revokeCallCount = 0
        let (model, client) = makeModel(
            settingsRows: ["auth_signed_in": "true", "auth_persona": "student"],
            revokeServerSession: { revokeCallCount += 1 }
        )
        XCTAssertTrue(model.authSignedIn)

        model.signOut()

        XCTAssertEqual(client.rows["auth_gate_resolved"], "false")
        XCTAssertEqual(client.rows["auth_signed_in"], "false")
        XCTAssertEqual(client.rows["auth_persona"], "")
        XCTAssertFalse(model.authSignedIn)
        XCTAssertEqual(model.authSummary, "Not signed in (dev mode).")
        // Log out is not only local: the server session (refresh token +
        // cookie) must be revoked too — production wires this closure to
        // `AuthClient.shared.logout()`.
        XCTAssertEqual(revokeCallCount, 1)
    }

    func testSignInCallsThePresentAuthGateHook() {
        let (model, _) = makeModel()
        var presented = false
        model.presentAuthGate = { presented = true }
        model.signIn()
        XCTAssertTrue(presented)
    }

    func testNotificationsMirrorTheNotifierAndSupportMarkReadAndClear() {
        let delivery = RecordingDelivery()
        let notifier = SessionNotifier(delivery: delivery)
        notifier.record(
            NotificationContext(
                event: SessionStatusEvent(id: "s1", status: .awaitingApproval, notify: true, engine: "claude"),
                pane: PaneDescriptor(sessionID: "s1", group: "g1", title: "t", project: "alpha", engine: .claude, cwd: "/a"),
                projectLabel: "Alpha",
                focusedPaneID: nil,
                windowVisible: false,
                appActive: false,
                previousStatus: nil,
                now: 1000
            )
        )
        let (model, _) = makeModel(notifier: notifier)
        XCTAssertEqual(model.notificationEntries.count, 1)
        XCTAssertFalse(model.notificationEntries[0].read)

        model.markAllNotificationsRead()
        XCTAssertTrue(model.notificationEntries[0].read)

        model.clearAllNotifications()
        XCTAssertTrue(model.notificationEntries.isEmpty)
        XCTAssertTrue(notifier.entries.isEmpty)
    }

    func testRebuildBrainClearsConfirmingOnSuccessAndSurfacesTheErrorOnFailure() {
        let brainAdmin = FakeBrainAdminClient()
        let (model, _) = makeModel(brainAdmin: brainAdmin)
        model.rebuildConfirming = true

        model.rebuildBrain()

        XCTAssertFalse(model.rebuildInProgress)
        XCTAssertFalse(model.rebuildConfirming)
        XCTAssertEqual(brainAdmin.rebuildCallCount, 1)
        XCTAssertNil(model.rebuildError)

        brainAdmin.rebuildResult = .failure(SessionConnectionError.disconnected)
        model.rebuildConfirming = true
        model.rebuildBrain()
        XCTAssertTrue(model.rebuildConfirming, "stays open so the user can retry")
        XCTAssertNotNil(model.rebuildError)
    }

    // MARK: - Daemon (Task 6c)

    func testInitLoadsTheDaemonStatusSnapshot() {
        let daemonStatus = FakeDaemonStatus(
            mode: .registeredService,
            statusDescription: "Running as a login item.",
            lostSessions: ["s1"]
        )
        let (model, _) = makeModel(daemonStatus: daemonStatus)

        XCTAssertEqual(model.daemonMode, .registeredService)
        XCTAssertEqual(model.daemonStatusDescription, "Running as a login item.")
        XCTAssertEqual(model.daemonLostSessions, ["s1"])
    }

    func testDismissLostSessionsClearsBothTheProviderAndThePublishedList() {
        let daemonStatus = FakeDaemonStatus(lostSessions: ["s1", "s2"])
        let (model, _) = makeModel(daemonStatus: daemonStatus)
        XCTAssertEqual(model.daemonLostSessions, ["s1", "s2"])

        model.dismissLostSessions()

        XCTAssertEqual(daemonStatus.dismissCallCount, 1)
        XCTAssertEqual(model.daemonLostSessions, [])
    }

    func testOpenLoginItemsSettingsCallsTheInjectedHook() {
        var called = false
        let client = FakeSettingsClient(rows: [:])
        let settings = SettingsStore(client: client)
        let model = SettingsViewModel(
            settings: settings,
            authGate: AuthGateCoordinator(settings: settings),
            brainAdmin: FakeBrainAdminClient(),
            notifier: SessionNotifier(delivery: RecordingDelivery()),
            version: nil,
            daemonStatus: FakeDaemonStatus(),
            openLoginItemsSettings: { called = true }
        )

        model.openLoginItemsSettings()

        XCTAssertTrue(called)
    }
}
