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
    // MARK: - Reset instants

    /// The whole point of parsing the phrase: a real instant to count down to.
    func testAResetPhraseBecomesAnInstant() throws {
        let now = try XCTUnwrap(date(2026, 8, 25, 15, 0))
        let parsed = try XCTUnwrap(ClaudeUsageLimits.resetDate(from: "Aug 25 at 8:30pm", now: now))
        let fields = Calendar.current.dateComponents([.month, .day, .hour, .minute], from: parsed)
        XCTAssertEqual(fields.month, 8)
        XCTAssertEqual(fields.day, 25)
        XCTAssertEqual(fields.hour, 20, "8:30pm is 20:30")
        XCTAssertEqual(fields.minute, 30)
    }

    /// `/usage` writes a whole hour without minutes — `resets Aug 28 at 11am`.
    func testAWholeHourPhraseParsesToo() throws {
        let now = try XCTUnwrap(date(2026, 8, 25, 15, 0))
        let parsed = try XCTUnwrap(ClaudeUsageLimits.resetDate(from: "Aug 28 at 11am", now: now))
        let fields = Calendar.current.dateComponents([.month, .day, .hour], from: parsed)
        XCTAssertEqual([fields.month, fields.day, fields.hour], [8, 28, 11])
    }

    /// The phrase carries no year, so a December reading of a January reset has
    /// to roll forward rather than land eleven months in the past.
    func testAResetPastTheYearEndRollsForward() throws {
        let now = try XCTUnwrap(date(2026, 12, 31, 23, 0))
        let parsed = try XCTUnwrap(ClaudeUsageLimits.resetDate(from: "Jan 1 at 9am", now: now))
        XCTAssertGreaterThan(parsed, now, "next year's January, not this one's")
        XCTAssertEqual(Calendar.current.component(.year, from: parsed), 2027)
    }

    func testAnUnreadablePhraseHasNoInstant() {
        XCTAssertNil(ClaudeUsageLimits.resetDate(from: "in a little while"))
        XCTAssertNil(ClaudeUsageLimits.resetDate(from: ""))
        XCTAssertNil(ClaudeUsageLimits.resetDate(from: nil))
    }

    func testTimeLeftReadsAtTheCoarsenessTheSidebarShows() throws {
        let now = try XCTUnwrap(date(2026, 8, 25, 15, 0))
        XCTAssertEqual(ClaudeUsageLimits.timeLeft(until: date(2026, 8, 25, 19, 12), now: now), "4h 12m")
        XCTAssertEqual(ClaudeUsageLimits.timeLeft(until: date(2026, 8, 28, 10, 0), now: now), "2d 19h")
        XCTAssertEqual(ClaudeUsageLimits.timeLeft(until: date(2026, 8, 25, 15, 25), now: now), "25m")
        XCTAssertEqual(ClaudeUsageLimits.timeLeft(until: date(2026, 8, 25, 14, 0), now: now), "now")
        XCTAssertNil(ClaudeUsageLimits.timeLeft(until: nil, now: now))
    }

    /// End to end: the two limits carry instants of their own, off one real
    /// `/usage` block.
    func testParsedLimitsCarryTheirResetInstants() {
        let limits = ClaudeUsageLimits.parse(
            "Current session: 4% used · resets Aug 25 at 8:30pm (Europe/Berlin)\n"
            + "Current week (all models): 40% used · resets Aug 28 at 11am (Europe/Berlin)"
        )
        XCTAssertNotNil(limits.sessionResetsAt)
        XCTAssertNotNil(limits.weekResetsAt)
    }

    // MARK: - The activity gate

    /// An idle machine must not spend quota re-reading a number that cannot
    /// have moved. `start()` fetches once; the tick after it does not.
    func testAnIdleTickDoesNotFetch() {
        var runs = 0
        poller.runnerForTesting = {
            runs += 1
            return "Current session: 5% used · resets Aug 25 at 8:30pm"
        }
        expectPush { self.poller.refresh() }
        XCTAssertEqual(runs, 1)

        expectNoPush { self.poller.refreshIfWorthIt() }
        XCTAssertEqual(runs, 1, "nothing was sent, so nothing was worth asking about")
    }

    func testSendingSomethingEarnsTheNextFetch() {
        var runs = 0
        poller.runnerForTesting = {
            runs += 1
            return "Current session: 5% used · resets Aug 25 at 8:30pm"
        }
        expectPush { self.poller.refresh() }
        poller.noteActivity()
        expectPush { self.poller.refreshIfWorthIt() }
        XCTAssertEqual(runs, 2)
    }

    /// The one case where idleness does not earn a skip: the window rolled
    /// over, so the percentage now describes a window that no longer exists.
    ///
    /// The phrase is built from the clock rather than hardcoded — a fixed
    /// date would be read as *next* year's by `resetDate`'s wrap rule and the
    /// rollover would never be seen, which is what a hardcoded "Jan 1" fixture
    /// did on the first run of this test.
    func testARolledOverWindowFetchesEvenWhileIdle() {
        var runs = 0
        let anHourAgo = phrase(for: Date().addingTimeInterval(-3600))
        poller.runnerForTesting = {
            runs += 1
            return "Current session: 5% used · resets \(anHourAgo)"
        }
        expectPush { self.poller.refresh() }
        XCTAssertEqual(runs, 1)

        expectPush { self.poller.refreshIfWorthIt() }
        XCTAssertEqual(runs, 2, "a stale window is worth one request")
    }

    /// The wrap rule is months wide, not a day: a week-old reset is a stale
    /// reading that must stay in the past, because staying in the past is what
    /// tells the poller to go and look again.
    func testARecentlyPassedResetStaysInThePast() throws {
        let now = Date()
        let lastWeek = try XCTUnwrap(
            ClaudeUsageLimits.resetDate(from: phrase(for: now.addingTimeInterval(-7 * 86_400)), now: now)
        )
        XCTAssertLessThan(lastWeek, now, "not rolled forward into next year")
    }

    /// `/usage`'s own rendering of an instant, which is what the parser reads.
    private func phrase(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.amSymbol = "am"
        formatter.pmSymbol = "pm"
        formatter.dateFormat = "MMM d 'at' h:mma"
        return formatter.string(from: date)
    }

    /// A failed fetch must not count as "seen" — otherwise one timeout parks
    /// the readout until the next thing is sent.
    func testAFailedFetchLeavesTheGateOpen() {
        poller.runnerForTesting = { "" }
        expectPush { self.poller.refresh() }
        var runs = 0
        poller.runnerForTesting = {
            runs += 1
            return "Current session: 5% used · resets Aug 25 at 8:30pm"
        }
        expectPush { self.poller.refreshIfWorthIt() }
        XCTAssertEqual(runs, 1, "the failure did not close the gate")
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date? {
        Calendar.current.date(
            from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)
        )
    }

    /// The counterpart to `expectPush`: runs `body` and asserts no push
    /// followed. Two main-queue hops, so it drains past anything the call
    /// could have scheduled before deciding nothing happened.
    private func expectNoPush(_ body: () -> Void) {
        var pushed = false
        poller.addObserver(self) { pushed = true }
        body()
        let drained = expectation(description: "the main queue drained")
        DispatchQueue.main.async { DispatchQueue.main.async { drained.fulfill() } }
        wait(for: [drained], timeout: 5)
        poller.removeObserver(self)
        XCTAssertFalse(pushed)
    }

}
