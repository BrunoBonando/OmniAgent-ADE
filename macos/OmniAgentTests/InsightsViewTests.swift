import XCTest
@testable import OmniAgent

/// The Insights page — usage KPIs and charts on one tab, the agent-activity
/// timeline on the other. Spec §6,
/// `docs/superpowers/specs/2026-09-01-flow-layout-design.md`.
final class InsightsViewTests: XCTestCase {
    // MARK: - The KPI row

    /// The three cards read the numbers the usage analytics derive: two
    /// grouped counts and the run's active hours to one decimal.
    func testTheKPICardsReadTheInsights() {
        let view = InsightsSurfaceView()

        view.applyInsights(insights(sessions: 1_234, tokens: 56_789, hoursPerDay: 2.5, days: 5))

        XCTAssertEqual(view.kpiCards.map { $0.labelField.stringValue }, ["SESSIONS", "TOKENS", "ACTIVE HOURS"])
        XCTAssertEqual(view.kpiCards.map { $0.valueField.stringValue }, ["1,234", "56,789", "12.5"])
    }

    /// A fresh page has cards, not blanks — and nothing that reads as a real
    /// number before any data has been applied.
    func testTheKPICardsStartEmptyRatherThanAtZero() {
        let view = InsightsSurfaceView()
        XCTAssertEqual(view.kpiCards.count, 3)
        for card in view.kpiCards {
            XCTAssertEqual(card.valueField.stringValue, "—")
        }
    }

    // MARK: - The tabs

    func testTheShellWearsThePagesTitleAndItsTwoTabs() {
        let view = InsightsSurfaceView()
        XCTAssertEqual(view.shell.titleField.stringValue, "Insights")
        XCTAssertEqual(view.shell.tabButtons.count, 2)
        XCTAssertEqual(view.selectedTab, .usage, "the page opens on Usage")
        XCTAssertFalse(view.usageBody.isHidden)
        XCTAssertTrue(view.activity.isHidden)
    }

    /// Picking Activity swaps the bodies and takes the shell's underline with
    /// it — one tab, one visible body.
    func testPickingActivityShowsTheTimelineAndMovesTheUnderline() {
        let view = InsightsSurfaceView()

        view.select(.activity)
        layout(view)

        XCTAssertEqual(view.selectedTab, .activity)
        XCTAssertTrue(view.usageBody.isHidden)
        XCTAssertFalse(view.activity.isHidden)
        XCTAssertEqual(view.shell.selectedTab, 1)
        XCTAssertEqual(
            view.shell.underline.frame.midX,
            view.shell.tabButtons[1].frame.midX,
            accuracy: 0.5
        )
    }

    /// Pressing the strip does the same thing the API does, and reports the
    /// pick — the controller's cue to feed the timeline.
    func testPressingTheSecondTabPicksActivityAndReports() {
        let view = InsightsSurfaceView()
        var reported: [InsightsTab] = []
        view.onSelectTab = { reported.append($0) }

        view.shell.tabButtons[1].onPress?()
        layout(view)

        XCTAssertEqual(reported, [.activity])
        XCTAssertEqual(view.selectedTab, .activity)
        XCTAssertTrue(view.usageBody.isHidden)
        XCTAssertFalse(view.activity.isHidden)
        XCTAssertEqual(
            view.shell.underline.frame.midX,
            view.shell.tabButtons[1].frame.midX,
            accuracy: 0.5
        )

        view.shell.tabButtons[0].onPress?()
        XCTAssertEqual(reported, [.activity, .usage])
        XCTAssertFalse(view.usageBody.isHidden)
    }

    /// A programmatic pick reports too — the spotlight's `Insights › Activity`
    /// row lands through `select(_:)`, and the timeline it wants has to be
    /// fed the same way a press would feed it.
    func testAProgrammaticPickReportsSoEveryRouteFeedsTheTimeline() {
        let view = InsightsSurfaceView()
        var reported: [InsightsTab] = []
        view.onSelectTab = { reported.append($0) }

        view.select(.activity)

        XCTAssertEqual(reported, [.activity])
    }

    // MARK: - The hosted charts

    /// The SwiftUI usage view is hosted inside the card under the KPI row,
    /// and re-applying swaps it rather than stacking a second one on top.
    func testApplyingUsageHostsTheChartsAndSwapsOnReapply() {
        let view = InsightsSurfaceView()
        let client = FakeBrainAdminClient()

        view.applyUsage(model: UsageViewModel(store: UsageAnalyticsStore(), projectDirectory: client))
        XCTAssertEqual(view.usageCard.subviews.count, 1)

        view.applyUsage(model: UsageViewModel(store: UsageAnalyticsStore(), projectDirectory: client))
        XCTAssertEqual(view.usageCard.subviews.count, 1, "the old host goes with its model")
    }

    // MARK: - Render

    /// Repo convention: verify AppKit layout by offscreen render. A crash or
    /// a zero-size layout fails loudly here; `PANE_RENDER_DIR` drops a PNG
    /// for inspection.
    func testTheInsightsPageRendersOffscreen() throws {
        let view = InsightsSurfaceView()
        view.applyInsights(insights(sessions: 1_234, tokens: 56_789, hoursPerDay: 2.5, days: 5))
        view.applyUsage(
            model: UsageViewModel(store: UsageAnalyticsStore(), projectDirectory: FakeBrainAdminClient())
        )

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 1200, height: 900))
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        let window = NSWindow(
            contentRect: container.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = container
        container.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(view.kpiCards[0].frame.width, 0)
        let bitmap = try XCTUnwrap(container.bitmapImageRepForCachingDisplay(in: container.bounds))
        container.cacheDisplay(in: container.bounds, to: bitmap)
        XCTAssertGreaterThan(bitmap.size.width, 0)
        saveRenderForInspection(bitmap, named: "insights")
    }

    // MARK: - Helpers

    /// The page has no superview in these tests, so its own frame stands in
    /// for what the content card would otherwise constrain it to.
    private func layout(_ view: InsightsSurfaceView, width: CGFloat = 1_200, height: CGFloat = 900) {
        view.frame = NSRect(x: 0, y: 0, width: width, height: height)
        view.layoutSubtreeIfNeeded()
    }

    private func insights(
        sessions: Double,
        tokens: Double,
        hoursPerDay: Double,
        days: Int
    ) -> UsageInsights {
        var totals = UsageBucket()
        totals.sessionsOpened = sessions
        totals.tokenCount = tokens
        return UsageInsights(
            totals: totals,
            trackedDays: days,
            avgSessionsPerDay: 0,
            avgTokensPerDay: 0,
            avgActiveHoursPerDay: hoursPerDay,
            bestHour: nil,
            hourlyActiveHours: Array(repeating: 0, count: 24),
            daily: []
        )
    }

    /// The repo's render-drop seam: a PNG per named render when the runner
    /// exports `PANE_RENDER_DIR`; unset, a no-op.
    private func saveRenderForInspection(_ rep: NSBitmapImageRep, named name: String) {
        guard
            let dir = ProcessInfo.processInfo.environment["PANE_RENDER_DIR"],
            let png = rep.representation(using: .png, properties: [:])
        else { return }
        let directory = URL(fileURLWithPath: dir, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? png.write(to: directory.appendingPathComponent("\(name).png"))
    }
}
