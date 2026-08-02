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

final class SettingsViewModelTests: XCTestCase {
    private func makeModel(
        settingsRows: [String: String] = [:],
        brainAdmin: FakeBrainAdminClient = FakeBrainAdminClient(),
        notifier: SessionNotifier = SessionNotifier(delivery: RecordingDelivery()),
        daemonStatus: FakeDaemonStatus = FakeDaemonStatus()
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
            openLoginItemsSettings: {}
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

    func testSignOutResetsTheAuthGateAndRefreshesTheSummary() {
        let (model, client) = makeModel(settingsRows: ["auth_signed_in": "true", "auth_persona": "student"])
        XCTAssertTrue(model.authSignedIn)

        model.signOut()

        XCTAssertEqual(client.rows["auth_gate_resolved"], "false")
        XCTAssertEqual(client.rows["auth_signed_in"], "false")
        XCTAssertEqual(client.rows["auth_persona"], "")
        XCTAssertFalse(model.authSignedIn)
        XCTAssertEqual(model.authSummary, "Not signed in (dev mode).")
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
