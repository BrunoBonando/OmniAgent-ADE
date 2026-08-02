import XCTest
@testable import OmniAgent

final class UsageAnalyticsTests: XCTestCase {
    /// Builds an epoch-ms timestamp from local calendar components — the
    /// module derives day keys and hours in local time (mirroring the
    /// TypeScript oracle's own use of the un-zoned `Date` constructor), so
    /// tests build fixtures the same way rather than hardcoding UTC millis
    /// that would drift on a machine in a different timezone.
    private func ts(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Double {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        let date = Calendar.current.date(from: components)!
        return date.timeIntervalSince1970 * 1000
    }

    // MARK: - Recording

    func testRecordingSessionsCommandsTokensAndStatusDurationAccumulatesIntoTotals() {
        var store = UsageAnalyticsStore()
        let at = ts(2026, 7, 28, 10)
        UsageAnalytics.recordSessionOpened(&store, projectId: "proj-a", at: at)
        UsageAnalytics.recordInput(&store, projectId: "proj-a", chars: 42, commands: 2, at: at)
        UsageAnalytics.recordTokens(&store, projectId: "proj-a", tokens: 120, at: at)
        UsageAnalytics.recordStatusDuration(&store, projectId: "proj-a", status: .thinking, fromTs: at, toTs: at + 30 * 60 * 1000)

        let insights = UsageAnalytics.deriveUsageInsights(store, projectId: "proj-a", now: at + 2 * 86_400_000)
        XCTAssertEqual(insights.totals.sessionsOpened, 1)
        XCTAssertEqual(insights.totals.commandsSubmitted, 2)
        XCTAssertEqual(insights.totals.inputChars, 42)
        XCTAssertEqual(insights.totals.tokenCount, 120)
        XCTAssertEqual(insights.totals.thinkingMs, 30 * 60 * 1000)
        XCTAssertEqual(insights.totals.activeMs, 30 * 60 * 1000, "thinking counts as active")
        XCTAssertNotNil(insights.bestHour)
    }

    func testEveryMetricFansOutIntoTheGlobalAllProjectsBucketToo() {
        var store = UsageAnalyticsStore()
        let at = ts(2026, 7, 28, 9)
        UsageAnalytics.recordSessionOpened(&store, projectId: "proj-a", at: at)
        UsageAnalytics.recordSessionOpened(&store, projectId: "proj-b", at: at)

        XCTAssertEqual(store.projects["proj-a"]?.totals.sessionsOpened, 1)
        XCTAssertEqual(store.projects["proj-b"]?.totals.sessionsOpened, 1)
        XCTAssertEqual(store.projects[UsageAnalytics.globalProject]?.totals.sessionsOpened, 2, "both fan out into __all__")
    }

    func testRecordingDirectlyAgainstTheGlobalProjectDoesNotDoubleCount() {
        var store = UsageAnalyticsStore()
        UsageAnalytics.recordSessionOpened(&store, projectId: UsageAnalytics.globalProject, at: ts(2026, 7, 28))
        XCTAssertEqual(store.projects.count, 1, "no second, redundant __all__ entry")
        XCTAssertEqual(store.projects[UsageAnalytics.globalProject]?.totals.sessionsOpened, 1)
    }

    func testNonPositiveOrNonFiniteAmountsAreIgnored() {
        var store = UsageAnalyticsStore()
        let at = ts(2026, 7, 28)
        UsageAnalytics.recordTokens(&store, projectId: "proj-a", tokens: 0, at: at)
        UsageAnalytics.recordTokens(&store, projectId: "proj-a", tokens: -5, at: at)
        XCTAssertNil(store.projects["proj-a"], "an ignored metric never even creates the project bucket")
    }

    func testStatusDurationSplitsAtEveryHourBoundaryItCrosses() {
        var store = UsageAnalyticsStore()
        // 11:50 -> 12:20: 10 minutes in hour 11, 20 minutes in hour 12.
        let from = ts(2026, 7, 28, 11, 50)
        let to = ts(2026, 7, 28, 12, 20)
        UsageAnalytics.recordStatusDuration(&store, projectId: "proj-a", status: .thinking, fromTs: from, toTs: to)

        let project = try! XCTUnwrap(store.projects["proj-a"])
        XCTAssertEqual(project.totals.thinkingMs, 30 * 60 * 1000, "the full span still lands in totals")
        XCTAssertEqual(project.hourActivityMs[11], 10 * 60 * 1000)
        XCTAssertEqual(project.hourActivityMs[12], 20 * 60 * 1000)
    }

    func testReadyStatusNeverContributesToTheHourlyActivityHistogram() {
        var store = UsageAnalyticsStore()
        let from = ts(2026, 7, 28, 9)
        let to = ts(2026, 7, 28, 9, 30)
        UsageAnalytics.recordStatusDuration(&store, projectId: "proj-a", status: .ready, fromTs: from, toTs: to)

        let project = try! XCTUnwrap(store.projects["proj-a"])
        XCTAssertEqual(project.totals.readyMs, 30 * 60 * 1000)
        XCTAssertEqual(project.totals.activeMs, 0, "ready is not active")
        XCTAssertEqual(project.hourActivityMs.reduce(0, +), 0, "ready never touches the histogram")
    }

    func testAZeroOrInvertedSpanRecordsNothing() {
        var store = UsageAnalyticsStore()
        let at = ts(2026, 7, 28, 9)
        UsageAnalytics.recordStatusDuration(&store, projectId: "proj-a", status: .thinking, fromTs: at, toTs: at)
        UsageAnalytics.recordStatusDuration(&store, projectId: "proj-a", status: .thinking, fromTs: at, toTs: at - 1)
        XCTAssertNil(store.projects["proj-a"])
    }

    // MARK: - deriveUsageInsights

    func testDeriveUsageInsightsReadsAnUnknownProjectAsAllZeroesRatherThanFailing() {
        let store = UsageAnalyticsStore()
        let insights = UsageAnalytics.deriveUsageInsights(store, projectId: "never-seen", now: ts(2026, 7, 28))
        XCTAssertEqual(insights.totals, UsageBucket())
        XCTAssertNil(insights.bestHour)
        XCTAssertEqual(insights.daily.count, 14)
    }

    func testDeriveUsageInsightsWithANilProjectIdReadsTheGlobalBucket() {
        var store = UsageAnalyticsStore()
        UsageAnalytics.recordSessionOpened(&store, projectId: "proj-a", at: ts(2026, 7, 28))
        let insights = UsageAnalytics.deriveUsageInsights(store, projectId: nil, now: ts(2026, 7, 28))
        XCTAssertEqual(insights.totals.sessionsOpened, 1)
    }

    func testDailySequenceCoversExactlyRangeDaysEndingToday() {
        let store = UsageAnalyticsStore()
        let now = ts(2026, 7, 28)
        let insights = UsageAnalytics.deriveUsageInsights(store, projectId: "proj-a", now: now, rangeDays: 7)
        XCTAssertEqual(insights.daily.count, 7)
        XCTAssertEqual(insights.daily.last?.day, UsageAnalytics.dayKey(now))
    }

    func testBestHourPicksTheHighestNonZeroSlotOrNilWhenAllAreZero() {
        var store = UsageAnalyticsStore()
        UsageAnalytics.recordStatusDuration(
            &store, projectId: "proj-a", status: .thinking,
            fromTs: ts(2026, 7, 28, 14), toTs: ts(2026, 7, 28, 14, 10)
        )
        UsageAnalytics.recordStatusDuration(
            &store, projectId: "proj-a", status: .thinking,
            fromTs: ts(2026, 7, 28, 9), toTs: ts(2026, 7, 28, 9, 5)
        )
        let insights = UsageAnalytics.deriveUsageInsights(store, projectId: "proj-a", now: ts(2026, 7, 28))
        XCTAssertEqual(insights.bestHour, 14, "10 minutes beats 5")

        let empty = UsageAnalytics.deriveUsageInsights(UsageAnalyticsStore(), projectId: "proj-a", now: ts(2026, 7, 28))
        XCTAssertNil(empty.bestHour)
    }

    // MARK: - parseTokenEstimateMax

    func testParseTokenEstimateMaxExtractsTheHighestMentionAcrossPhrasings() {
        let text = "Cascading… (14s · ↓ 92 tokens)\nusage tokens: 105\nsomething else"
        XCTAssertEqual(UsageAnalytics.parseTokenEstimateMax(text), 105)
    }

    func testParseTokenEstimateMaxHandlesThousandsSeparatorsAndReturnsNilWithNoMatch() {
        XCTAssertEqual(UsageAnalytics.parseTokenEstimateMax("used 12,345 tokens so far"), 12345)
        XCTAssertNil(UsageAnalytics.parseTokenEstimateMax(""))
        XCTAssertNil(UsageAnalytics.parseTokenEstimateMax("no numbers here at all"))
    }

    // MARK: - Codec

    func testCodecRoundTripsAStoreExactly() {
        var store = UsageAnalyticsStore()
        let at = ts(2026, 7, 28, 10)
        UsageAnalytics.recordSessionOpened(&store, projectId: "proj-a", at: at)
        UsageAnalytics.recordStatusDuration(&store, projectId: "proj-a", status: .error, fromTs: at, toTs: at + 60_000)

        let restored = UsageAnalyticsCodec.deserialize(UsageAnalyticsCodec.serialize(store))
        XCTAssertEqual(restored, store)
    }

    func testCodecDeserializeNeverThrowsOnMissingOrGarbageInput() {
        XCTAssertEqual(UsageAnalyticsCodec.deserialize(nil), UsageAnalyticsStore())
        XCTAssertEqual(UsageAnalyticsCodec.deserialize(""), UsageAnalyticsStore())
        XCTAssertEqual(UsageAnalyticsCodec.deserialize("not json"), UsageAnalyticsStore())
        XCTAssertEqual(UsageAnalyticsCodec.deserialize(#"{"version":2,"projects":{}}"#), UsageAnalyticsStore(), "a version mismatch resets rather than misreads")
    }

    func testCodecDropsOnlyTheMalformedDayOrFieldNotTheWholeProject() {
        let raw = """
        {"version":1,"projects":{"proj-a":{
          "totals":{"sessionsOpened":3,"tokenCount":-9},
          "days":{
            "2026-07-28":{"sessionsOpened":1},
            "not-a-day":{"sessionsOpened":99},
            "2026-07-29":"garbage"
          },
          "hourActivityMs":[1,2,3],
          "updatedAt":1690000000000
        }}}
        """
        let store = UsageAnalyticsCodec.deserialize(raw)
        let project = try! XCTUnwrap(store.projects["proj-a"])
        XCTAssertEqual(project.totals.sessionsOpened, 3, "the valid field survives")
        XCTAssertEqual(project.totals.tokenCount, 0, "a negative value is dropped, not kept as negative")
        XCTAssertEqual(project.days.count, 1, "only the well-formed day key survives")
        XCTAssertEqual(project.days["2026-07-28"]?.sessionsOpened, 1)
        XCTAssertEqual(project.hourActivityMs[0], 1)
        XCTAssertEqual(project.hourActivityMs[2], 3)
        XCTAssertEqual(project.hourActivityMs[23], 0)
    }
}
