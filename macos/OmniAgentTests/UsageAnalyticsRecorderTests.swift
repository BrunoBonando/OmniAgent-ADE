import XCTest
@testable import OmniAgent

final class UsageAnalyticsRecorderTests: XCTestCase {
    func testOpeningAPaneInABrandNewSessionRecordsBothATerminalAndASession() {
        let recorder = UsageAnalyticsRecorder()
        var notifications = 0
        recorder.onStoreChanged = { _ in notifications += 1 }

        recorder.recordPaneOpened(paneID: "p1", sessionKey: "g1", project: "alpha", at: 1000)

        XCTAssertEqual(recorder.store.projects["alpha"]?.totals.terminalsOpened, 1)
        XCTAssertEqual(recorder.store.projects["alpha"]?.totals.sessionsOpened, 1)
        XCTAssertEqual(notifications, 1)
    }

    func testASecondPaneInTheSameSessionCountsOnlyAsANewTerminal() {
        let recorder = UsageAnalyticsRecorder()
        recorder.recordPaneOpened(paneID: "p1", sessionKey: "g1", project: "alpha", at: 1000)
        recorder.recordPaneOpened(paneID: "p2", sessionKey: "g1", project: "alpha", at: 2000)

        XCTAssertEqual(recorder.store.projects["alpha"]?.totals.terminalsOpened, 2)
        XCTAssertEqual(recorder.store.projects["alpha"]?.totals.sessionsOpened, 1, "still one session")
    }

    func testTheSamePaneIDNeverCountsTwiceAndDoesNotNotifyAgain() {
        let recorder = UsageAnalyticsRecorder()
        var notifications = 0
        recorder.onStoreChanged = { _ in notifications += 1 }
        recorder.recordPaneOpened(paneID: "p1", sessionKey: "g1", project: "alpha", at: 1000)
        recorder.recordPaneOpened(paneID: "p1", sessionKey: "g1", project: "alpha", at: 2000)

        XCTAssertEqual(recorder.store.projects["alpha"]?.totals.terminalsOpened, 1)
        XCTAssertEqual(notifications, 1, "the repeat is a no-op, not a second write")
    }

    func testTheFirstStatusForASessionOnlyStartsTrackingItAndDoesNotNotify() {
        let recorder = UsageAnalyticsRecorder()
        var notifications = 0
        recorder.onStoreChanged = { _ in notifications += 1 }

        recorder.recordStatus(sessionID: "s1", project: "alpha", status: .thinking, at: 1000)

        XCTAssertEqual(recorder.store.projects["alpha"]?.totals.thinkingMs ?? 0, 0, "nothing to flush yet")
        XCTAssertEqual(notifications, 0)
    }

    func testASecondStatusFlushesTheDurationOfThePreviousOne() {
        let recorder = UsageAnalyticsRecorder()
        var notifications = 0
        recorder.onStoreChanged = { _ in notifications += 1 }

        recorder.recordStatus(sessionID: "s1", project: "alpha", status: .thinking, at: 1_000)
        recorder.recordStatus(sessionID: "s1", project: "alpha", status: .ready, at: 6_000)

        XCTAssertEqual(recorder.store.projects["alpha"]?.totals.thinkingMs, 5_000, "the 5s spent thinking, attributed on the transition")
        XCTAssertEqual(recorder.store.projects["alpha"]?.totals.readyMs ?? 0, 0, "the new status hasn't been flushed yet")
        XCTAssertEqual(notifications, 1)
    }

    func testExitFlushesTheLastTrackedStatusAndForgetsTheSession() {
        let recorder = UsageAnalyticsRecorder()
        recorder.recordStatus(sessionID: "s1", project: "alpha", status: .awaitingApproval, at: 1_000)

        recorder.recordExit(sessionID: "s1", at: 4_000)

        XCTAssertEqual(recorder.store.projects["alpha"]?.totals.awaitingApprovalMs, 3_000)

        // A later exit call for the same (now-forgotten) session is a no-op.
        var notifications = 0
        recorder.onStoreChanged = { _ in notifications += 1 }
        recorder.recordExit(sessionID: "s1", at: 9_000)
        XCTAssertEqual(notifications, 0)
    }

    func testExitForASessionThatNeverReportedAStatusIsANoOp() {
        let recorder = UsageAnalyticsRecorder()
        var notifications = 0
        recorder.onStoreChanged = { _ in notifications += 1 }

        recorder.recordExit(sessionID: "never-tracked", at: 1_000)

        XCTAssertEqual(notifications, 0)
        XCTAssertTrue(recorder.store.projects.isEmpty)
    }

    func testRestoreReplacesTheStoreWholesale() {
        let recorder = UsageAnalyticsRecorder()
        recorder.recordPaneOpened(paneID: "p1", sessionKey: "g1", project: "alpha", at: 1_000)

        var restored = UsageAnalyticsStore()
        UsageAnalytics.recordSessionOpened(&restored, projectId: "beta", at: 500)
        recorder.restore(restored)

        XCTAssertNil(recorder.store.projects["alpha"], "the in-memory store is fully replaced, not merged")
        XCTAssertEqual(recorder.store.projects["beta"]?.totals.sessionsOpened, 1)
    }
}
