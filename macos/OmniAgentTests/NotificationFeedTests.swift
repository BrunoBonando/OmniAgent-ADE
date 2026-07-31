import XCTest
@testable import OmniAgent

/// Ported fixture-for-fixture from `ui/src/state/notifications.test.ts`, plus
/// the two clauses of the on-screen rule that change shape natively.
final class NotificationFeedTests: XCTestCase {
    // MARK: - derive

    func testAnEventTheBackendDidNotFlagNeverNotifies() {
        XCTAssertNil(NotificationFeed.derive(context(status: .awaitingApproval, notify: false)))
    }

    func testAnEventForASessionThisWindowHasNoPaneForNeverNotifies() {
        XCTAssertNil(NotificationFeed.derive(context(status: .awaitingApproval, pane: nil)))
    }

    func testTheFocusedPaneInAVisibleActiveWindowIsNotNews() {
        XCTAssertNil(
            NotificationFeed.derive(
                context(status: .awaitingApproval, focusedPaneID: "sess-a", windowVisible: true, appActive: true)
            )
        )
    }

    func testABackgroundPaneAHiddenWindowOrABackgroundedAppAllNotify() {
        XCTAssertNotNil(
            NotificationFeed.derive(context(status: .awaitingApproval, focusedPaneID: "other")),
            "a pane the user is not focused on"
        )
        XCTAssertNotNil(
            NotificationFeed.derive(
                context(status: .awaitingApproval, focusedPaneID: "sess-a", windowVisible: false, appActive: true)
            ),
            "a hidden or fully occluded window"
        )
        XCTAssertNotNil(
            NotificationFeed.derive(
                context(status: .awaitingApproval, focusedPaneID: "sess-a", windowVisible: true, appActive: false)
            ),
            "another app in front"
        )
    }

    func testTheFeedCarriesPendingApprovalsAndTheirImmediateOutcomeOnly() {
        XCTAssertNotNil(NotificationFeed.derive(context(status: .awaitingApproval)), "pending")
        XCTAssertNotNil(
            NotificationFeed.derive(context(status: .ready, previousStatus: .awaitingApproval)),
            "approved"
        )
        XCTAssertNotNil(
            NotificationFeed.derive(context(status: .error, previousStatus: .awaitingApproval)),
            "rejected"
        )
        XCTAssertNil(
            NotificationFeed.derive(context(status: .ready, previousStatus: .thinking)),
            "a run finishing without ever asking is not an attention event"
        )
        XCTAssertNil(
            NotificationFeed.derive(context(status: .error, previousStatus: .toolExecution)),
            "an unrelated error is not an approval outcome"
        )
    }

    func testAnEntryFreezesWhatTheSessionWasCalledWhenItFired() throws {
        let entry = try XCTUnwrap(
            NotificationFeed.derive(
                context(
                    status: .awaitingApproval,
                    pane: PaneDescriptor(
                        sessionID: "sess-a",
                        group: "grp-1",
                        groupLabel: "Build",
                        project: "alpha",
                        engine: .claude,
                        cwd: "/a",
                        label: "migrate"
                    )
                )
            )
        )

        XCTAssertEqual(entry.title, "migrate")
        XCTAssertEqual(entry.sessionLabel, "Build")
        XCTAssertEqual(entry.project, "alpha")
        XCTAssertEqual(entry.cwd, "/a")
        XCTAssertEqual(entry.engine, "claude")
        XCTAssertFalse(entry.read)
    }

    func testAnUnnamedPaneFallsBackToItsEngineName() throws {
        let entry = try XCTUnwrap(NotificationFeed.derive(context(status: .awaitingApproval)))
        XCTAssertEqual(entry.title, "shell")
    }

    // MARK: - the list

    func testAnImmediateRepeatCollapsesButAnythingInBetweenKeepsBothRows() {
        let first = entry(id: "1", session: "a", status: .awaitingApproval)
        let repeated = entry(id: "2", session: "a", status: .awaitingApproval)
        let other = entry(id: "3", session: "b", status: .awaitingApproval)

        XCTAssertEqual(
            NotificationFeed.adding(repeated, to: [first]).map(\.id),
            ["2"],
            "same session, same status, nothing in between"
        )
        XCTAssertEqual(
            NotificationFeed.adding(repeated, to: [other, first]).map(\.id),
            ["2", "3", "1"],
            "another session's row in between means the older one still says something"
        )
    }

    func testTheListIsCappedAtFortyEntries() {
        var entries: [NotificationEntry] = []
        for i in 0..<60 {
            entries = NotificationFeed.adding(entry(id: "\(i)", session: "s\(i)", status: .awaitingApproval), to: entries)
        }
        XCTAssertEqual(entries.count, NotificationFeed.maxEntries)
        XCTAssertEqual(entries.first?.id, "59", "newest first")
    }

    func testAnsweringAPromptDropsThatSessionsPendingRowsAndNothingElse() {
        let entries = [
            entry(id: "1", session: "a", status: .awaitingApproval),
            entry(id: "2", session: "a", status: .ready),
            entry(id: "3", session: "b", status: .awaitingApproval),
        ]

        XCTAssertEqual(
            NotificationFeed.resolvingApproval(forSession: "a", in: entries).map(\.id),
            ["2", "3"]
        )
    }

    func testUnreadCountAndMarkingRead() {
        let entries = [
            entry(id: "1", session: "a", status: .awaitingApproval),
            entry(id: "2", session: "b", status: .ready),
        ]
        XCTAssertEqual(NotificationFeed.unreadCount(entries), 2)
        XCTAssertEqual(NotificationFeed.unreadCount(NotificationFeed.markingRead(entries)), 0)
    }

    func testTwoEventsInTheSameMillisecondGetDistinctNotificationIdentifiers() {
        let first = entry(id: "sess-a:1700000000000", session: "a", status: .awaitingApproval)
        let second = entry(id: "sess-a:1700000000000", session: "a", status: .ready)

        XCTAssertEqual(NotificationFeed.uniqueID(second.id, among: [first]), "sess-a:1700000000000#2")
        XCTAssertEqual(
            NotificationFeed.uniqueID(second.id, among: [first, entry(id: "sess-a:1700000000000#2", session: "a", status: .error)]),
            "sess-a:1700000000000#3"
        )
        XCTAssertEqual(
            NotificationFeed.uniqueID("sess-b:1", among: [first]),
            "sess-b:1",
            "an id nothing collides with is left exactly as derived"
        )
    }

    func testSubtitlesAreTotalEvenForStatusesThatCannotReachTheFeed() {
        XCTAssertEqual(NotificationFeed.subtitle(for: .awaitingApproval), "Needs your approval.")
        XCTAssertEqual(NotificationFeed.subtitle(for: .ready), "Approved.")
        XCTAssertEqual(NotificationFeed.subtitle(for: .error), "Rejected.")
        XCTAssertEqual(NotificationFeed.subtitle(for: .thinking), "Status changed.")
    }

    func testRelativeTimeUsesThePanelsCoarseVocabulary() {
        let now: Double = 10_000_000_000
        XCTAssertEqual(NotificationFeed.relativeTime(now - 5_000, now: now), "Just now")
        XCTAssertEqual(NotificationFeed.relativeTime(now - 120_000, now: now), "2m")
        XCTAssertEqual(NotificationFeed.relativeTime(now - 7_200_000, now: now), "2h")
        XCTAssertEqual(NotificationFeed.relativeTime(now - 86_400_000, now: now), "1 day")
        XCTAssertEqual(NotificationFeed.relativeTime(now - 3 * 86_400_000, now: now), "3 days")
        XCTAssertEqual(NotificationFeed.relativeTime(now + 5_000, now: now), "Just now", "clock skew never goes negative")
    }

    // MARK: - persistence

    func testEntriesRoundTripThroughTheSharedSettingsRow() {
        let entries = [
            entry(id: "1", session: "a", status: .awaitingApproval),
            entry(id: "2", session: "b", status: .ready, sessionLabel: "Build"),
        ]

        XCTAssertEqual(NotificationFeedCodec.deserialize(NotificationFeedCodec.serialize(entries)), entries)
    }

    func testTheSerializedShapeIsTheOneTheWebBuildWrites() throws {
        let json = NotificationFeedCodec.serialize([entry(id: "1", session: "a", status: .awaitingApproval)])
        let parsed = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
        let row = try XCTUnwrap((parsed["entries"] as? [[String: Any]])?.first)

        XCTAssertEqual(row["sessionId"] as? String, "a", "camelCase, exactly as notifications.ts writes it")
        XCTAssertEqual(row["status"] as? String, "awaiting_approval", "the Rust status wire value")
        XCTAssertEqual(row["read"] as? Bool, false)
        XCTAssertNil(row["sessionLabel"], "an absent optional is omitted, not written as null")
    }

    func testACorruptRowRestoresAsNoNotificationsAndOneBadEntryCostsOnlyItself() {
        XCTAssertTrue(NotificationFeedCodec.deserialize(nil).isEmpty)
        XCTAssertTrue(NotificationFeedCodec.deserialize("}{").isEmpty)
        XCTAssertTrue(NotificationFeedCodec.deserialize(#"{"entries":"nope"}"#).isEmpty)

        let mixed = #"""
        {"entries":[
          {"id":"1","sessionId":"a","project":"p","projectLabel":"P","cwd":"/","engine":"shell","status":"ready","title":"t","createdAt":1},
          {"id":"2","sessionId":"b"},
          {"id":"3","sessionId":"c","project":"p","projectLabel":"P","cwd":"/","engine":"shell","status":"thinking","title":"t","createdAt":2}
        ]}
        """#

        XCTAssertEqual(
            NotificationFeedCodec.deserialize(mixed).map(\.id),
            ["1"],
            "a truncated entry and a status the notify rule never allows are both dropped, the good one stays"
        )
    }

    func testARestoredRowIsCappedTooSoAHandEditedFileCannotGrowTheFeed() {
        let rows = (0..<80).map {
            #"{"id":"\#($0)","sessionId":"s","project":"p","projectLabel":"P","cwd":"/","engine":"shell","status":"ready","title":"t","createdAt":1}"#
        }
        XCTAssertEqual(
            NotificationFeedCodec.deserialize("{\"entries\":[\(rows.joined(separator: ","))]}").count,
            NotificationFeed.maxEntries
        )
    }

    // MARK: - fixtures

    private func context(
        status: RemoteSessionStatus,
        notify: Bool = true,
        pane: PaneDescriptor? = PaneDescriptor(sessionID: "sess-a", group: "grp-1", project: "alpha", cwd: "/a"),
        focusedPaneID: String? = "other",
        windowVisible: Bool = true,
        appActive: Bool = true,
        previousStatus: RemoteSessionStatus? = .awaitingApproval
    ) -> NotificationContext {
        NotificationContext(
            event: SessionStatusEvent(id: "sess-a", status: status, notify: notify, engine: ""),
            pane: pane,
            projectLabel: "Alpha",
            focusedPaneID: focusedPaneID,
            windowVisible: windowVisible,
            appActive: appActive,
            previousStatus: previousStatus,
            now: 1_700_000_000_000
        )
    }

    private func entry(
        id: String,
        session: String,
        status: RemoteSessionStatus,
        sessionLabel: String? = nil
    ) -> NotificationEntry {
        NotificationEntry(
            id: id,
            sessionID: session,
            project: "alpha",
            projectLabel: "Alpha",
            cwd: "/a",
            engine: "shell",
            status: status,
            title: "shell",
            sessionLabel: sessionLabel,
            createdAt: 1_700_000_000_000,
            read: false
        )
    }
}
