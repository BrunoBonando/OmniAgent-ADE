import XCTest
@testable import OmniAgent

final class SessionNotifierTests: XCTestCase {
    func testAnAttentionEventIsRecordedDeliveredAndPublished() throws {
        let (notifier, delivery) = makeNotifier()
        var published: [[NotificationEntry]] = []
        notifier.onEntriesChanged = { published.append($0) }

        let entry = try XCTUnwrap(notifier.record(context(status: .awaitingApproval)))

        XCTAssertEqual(notifier.entries.map(\.id), [entry.id])
        XCTAssertEqual(delivery.delivered.map(\.id), [entry.id])
        XCTAssertEqual(published.count, 1)
        XCTAssertEqual(notifier.unreadCount, 1)
    }

    func testAnEventTheRuleSuppressesDeliversNothingAndPublishesNothing() {
        let (notifier, delivery) = makeNotifier()
        var published = 0
        notifier.onEntriesChanged = { _ in published += 1 }

        XCTAssertNil(notifier.record(context(status: .thinking, notify: false)))
        XCTAssertNil(
            notifier.record(context(status: .awaitingApproval, focusedPaneID: "sess-a")),
            "the pane the user is looking at"
        )

        XCTAssertTrue(notifier.entries.isEmpty)
        XCTAssertTrue(delivery.delivered.isEmpty)
        XCTAssertEqual(published, 0, "no churn for an event that produced nothing")
    }

    func testAnsweringThePromptPullsTheBannerBackOutOfNotificationCenter() throws {
        let (notifier, delivery) = makeNotifier()
        let pending = try XCTUnwrap(notifier.record(context(status: .awaitingApproval)))
        _ = notifier.record(context(status: .ready, previousStatus: .awaitingApproval))

        notifier.resolveApproval(sessionID: "sess-a")

        XCTAssertEqual(delivery.withdrawn, [pending.id], "only the pending row's banner")
        XCTAssertEqual(notifier.entries.map(\.status), [.ready], "the outcome row is history, and stays")
    }

    func testResolvingAnApprovalThatIsNotPendingChangesNothing() {
        let (notifier, delivery) = makeNotifier()
        var published = 0
        notifier.onEntriesChanged = { _ in published += 1 }

        notifier.resolveApproval(sessionID: "sess-a")

        XCTAssertTrue(delivery.withdrawn.isEmpty)
        XCTAssertEqual(published, 0)
    }

    func testARestoredRowIsAdoptedButNeverReDelivered() {
        let (notifier, delivery) = makeNotifier()

        notifier.restore([entry(id: "old", status: .awaitingApproval)])

        XCTAssertEqual(notifier.entries.map(\.id), ["old"])
        XCTAssertTrue(delivery.delivered.isEmpty, "a banner for last week's prompt is noise, not news")
    }

    func testASessionEndingNotifiesButNeverJoinsThePersistedFeed() {
        let (notifier, delivery) = makeNotifier()

        notifier.recordExit(sessionID: "sess-a", paneTitle: "build", exitCode: 130)

        XCTAssertEqual(delivery.transient.map(\.identifier), ["exit:sess-a"])
        XCTAssertEqual(delivery.transient.first?.body, "Session ended (exit 130)")
        XCTAssertTrue(
            notifier.entries.isEmpty,
            "the shared row only accepts the three notifiable statuses"
        )
    }

    func testASessionEndingClearsItsOwnPendingApproval() throws {
        let (notifier, delivery) = makeNotifier()
        let pending = try XCTUnwrap(notifier.record(context(status: .awaitingApproval)))

        notifier.recordExit(sessionID: "sess-a", paneTitle: "build", exitCode: nil)

        XCTAssertTrue(notifier.entries.isEmpty, "a dead session is not waiting on anything")
        XCTAssertEqual(delivery.withdrawn, [pending.id])
    }

    func testMarkingReadAndClearing() {
        let (notifier, delivery) = makeNotifier()
        _ = notifier.record(context(status: .awaitingApproval))
        XCTAssertEqual(notifier.unreadCount, 1)

        notifier.markAllRead()
        XCTAssertEqual(notifier.unreadCount, 0)

        notifier.clear()
        XCTAssertTrue(notifier.entries.isEmpty)
        XCTAssertEqual(delivery.withdrawn.count, 1)
    }

    // MARK: - fixtures

    private func makeNotifier() -> (SessionNotifier, RecordingDelivery) {
        let delivery = RecordingDelivery()
        return (SessionNotifier(delivery: delivery), delivery)
    }

    private func context(
        status: RemoteSessionStatus,
        notify: Bool = true,
        focusedPaneID: String? = "other",
        previousStatus: RemoteSessionStatus? = .awaitingApproval
    ) -> NotificationContext {
        NotificationContext(
            event: SessionStatusEvent(id: "sess-a", status: status, notify: notify, engine: "shell"),
            pane: PaneDescriptor(sessionID: "sess-a", group: "grp-1", project: "alpha", cwd: "/a"),
            projectLabel: "Alpha",
            focusedPaneID: focusedPaneID,
            windowVisible: true,
            appActive: true,
            previousStatus: previousStatus,
            now: Date().timeIntervalSince1970 * 1000
        )
    }

    private func entry(id: String, status: RemoteSessionStatus) -> NotificationEntry {
        NotificationEntry(
            id: id,
            sessionID: "sess-a",
            project: "alpha",
            projectLabel: "Alpha",
            cwd: "/a",
            engine: "shell",
            status: status,
            title: "shell",
            sessionLabel: nil,
            createdAt: 1,
            read: false
        )
    }
}

private final class RecordingDelivery: NotificationDelivering {
    struct Transient {
        let identifier: String
        let title: String
        let body: String
    }

    private(set) var authorizationRequests = 0
    private(set) var delivered: [NotificationEntry] = []
    private(set) var withdrawn: [String] = []
    private(set) var transient: [Transient] = []

    func requestAuthorization() { authorizationRequests += 1 }
    func deliver(_ entry: NotificationEntry) { delivered.append(entry) }
    func withdraw(identifiers: [String]) { withdrawn.append(contentsOf: identifiers) }

    func deliverTransient(identifier: String, title: String, body: String, sessionID: String) {
        transient.append(Transient(identifier: identifier, title: title, body: body))
    }
}
