import XCTest
@testable import OmniAgent

final class ClaudeUsageLimitsTests: XCTestCase {
    /// The real shape, captured from `claude -p "/usage"` on 2026-08-25.
    private let sample = """
    You are currently using your subscription to power your Claude Code usage

    Current session: 9% used · resets Aug 25 at 2:10pm (Europe/Berlin)
    Current week (all models): 37% used · resets Aug 28 at 11am (Europe/Berlin)
    Current week (Fable): 10% used · resets Aug 28 at 11am (Europe/Berlin)
    """

    func testParsesSessionAndWeek() {
        let limits = ClaudeUsageLimits.parse(sample)
        XCTAssertEqual(limits.sessionPercent, 9)
        XCTAssertEqual(limits.sessionResets, "Aug 25 at 2:10pm")
        XCTAssertEqual(limits.weekPercent, 37)
        XCTAssertEqual(limits.weekResets, "Aug 28 at 11am")
    }

    func testParsesThePerModelWeeklyLine() {
        let limits = ClaudeUsageLimits.parse(sample)
        XCTAssertEqual(limits.modelName, "Fable")
        XCTAssertEqual(limits.modelPercent, 10)
    }

    /// A failed or changed `/usage` must never blank the bar or throw — every
    /// field is optional and garbage yields all-nil.
    func testGarbageYieldsAllNilRatherThanThrowing() {
        let limits = ClaudeUsageLimits.parse("command not found\n")
        XCTAssertNil(limits.sessionPercent)
        XCTAssertNil(limits.weekPercent)
        XCTAssertNil(limits.modelPercent)
    }

    /// Against `.empty`, not against another `parse` call: comparing two
    /// parses of two blank strings is true for any implementation that does
    /// not crash, so it asserted nothing about the parser at all.
    func testEmptyInput() {
        XCTAssertEqual(ClaudeUsageLimits.parse(""), .empty)
        XCTAssertEqual(ClaudeUsageLimits.parse("   \n  "), .empty)
    }
}

/// The app-wide poller. Every test here drives it through `runnerForTesting`,
/// which is also the only thing that lets `refresh()` run under XCTest at all
/// — `/usage` is a real request against Bruno's real quota.
final class ClaudeUsageLimitsPollerTests: XCTestCase {
    private var poller: ClaudeUsageLimitsPoller { .shared }

    override func setUp() {
        super.setUp()
        // Both ends, not just tearDown: the poller is a process-wide
        // singleton and a live `PaneAppView` in an earlier test file arms it
        // too, so a clean slate cannot be assumed from this class alone.
        poller.resetForTesting()
    }

    override func tearDown() {
        // App-wide state: an observer or a stub runner left behind would be
        // inherited by whatever test runs next.
        poller.resetForTesting()
        super.tearDown()
    }

    /// The bug this replaced: `onChange` was one closure, so registering a
    /// second pane silently unregistered the first and only the most recently
    /// live pane ever saw a new reading.
    func testEveryRegisteredObserverIsPushedTo() {
        poller.runnerForTesting = { "Current session: 5% used · resets Aug 25 at 2:10pm" }
        var hits: [String] = []
        let first = NSObject()
        let second = NSObject()
        poller.addObserver(first) { hits.append("first") }
        poller.addObserver(second) { hits.append("second") }

        expectPush { self.poller.refresh() }

        XCTAssertEqual(Set(hits), ["first", "second"], "both panes, not just the last one registered")
        XCTAssertEqual(poller.latest?.sessionPercent, 5)
    }

    /// And a pane that went non-live stops being pushed at, without taking
    /// anyone else's push down with it.
    func testARemovedObserverStopsBeingPushedTo() {
        poller.runnerForTesting = { "Current session: 5% used · resets Aug 25 at 2:10pm" }
        var hits: [String] = []
        let gone = NSObject()
        let live = NSObject()
        poller.addObserver(gone) { hits.append("gone") }
        poller.addObserver(live) { hits.append("live") }
        poller.removeObserver(gone)

        expectPush { self.poller.refresh() }

        XCTAssertEqual(hits, ["live"])
    }

    /// `interval` used to be referenced by nothing at all: the constant made a
    /// repeating poll look implemented while `refresh()` only ever fired on an
    /// `isLive` false→true edge, so the bar took one reading and kept it for
    /// the life of the app.
    func testStartArmsTheRepeatingRefresh() {
        XCTAssertFalse(poller.isRepeating)
        poller.runnerForTesting = { "" }

        poller.start()

        XCTAssertTrue(poller.isRepeating)
        XCTAssertGreaterThanOrEqual(ClaudeUsageLimitsPoller.interval, 60, "minutes, not seconds")
    }

    /// A parse that found nothing leaves the last good reading alone — a
    /// failed or timed-out fetch must never blank the bar.
    func testAFailedFetchLeavesTheLastKnownValue() {
        poller.runnerForTesting = { "Current session: 5% used · resets Aug 25 at 2:10pm" }
        expectPush { self.poller.refresh() }
        XCTAssertEqual(poller.latest?.sessionPercent, 5)

        poller.runnerForTesting = { "" }
        expectPush { self.poller.refresh() }

        XCTAssertEqual(poller.latest?.sessionPercent, 5, "stale beats blank")
    }

    /// Runs `body` and waits for the push that follows it. The nested hop is
    /// what makes this land *after* the whole notify loop rather than in the
    /// middle of it, since the observers are a dictionary and their order is
    /// not defined.
    private func expectPush(_ body: () -> Void) {
        let pushed = expectation(description: "the poller pushed")
        poller.addObserver(self) { DispatchQueue.main.async { pushed.fulfill() } }
        body()
        wait(for: [pushed], timeout: 5)
        poller.removeObserver(self)
    }
}
