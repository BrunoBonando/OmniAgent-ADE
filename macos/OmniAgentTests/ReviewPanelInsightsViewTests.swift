import AppKit
import XCTest

@testable import OmniAgent

/// The review panel's Insights tab — the 2026-08-20 redesign's §5: agent
/// activity from data the app actually has. A per-pane status-event series
/// (in-memory since launch, ring-capped, fed from the same `onStatus` fan-out
/// the activity ledger reads), rendered as one timeline lane per pane with
/// status-coloured segments, a Time-by-status breakdown, and a header that
/// reads the `PaneActivityLedger`'s totals.
final class ReviewPanelInsightsViewTests: XCTestCase {
    // MARK: - The recorder

    /// A synthetic event sequence becomes segments: each event runs until the
    /// next one, and the last runs until "now".
    func testRecorderTurnsEventsIntoSegments() {
        var series = PaneStatusSeriesRecorder()
        series.record(paneID: "s-1", status: .ready, at: 1_000)
        series.record(paneID: "s-1", status: .thinking, at: 2_000)
        series.record(paneID: "s-1", status: .toolExecution, at: 3_500)
        series.record(paneID: "s-1", status: .ready, at: 5_000)

        XCTAssertEqual(
            series.segments(for: "s-1", until: 6_000),
            [
                PaneStatusSegment(status: .ready, start: 1_000, end: 2_000),
                PaneStatusSegment(status: .thinking, start: 2_000, end: 3_500),
                PaneStatusSegment(status: .toolExecution, start: 3_500, end: 5_000),
                PaneStatusSegment(status: .ready, start: 5_000, end: 6_000),
            ]
        )
    }

    /// A repeated status is not a new event — the ledger's own dedupe rule,
    /// kept: the daemon re-announcing "thinking" must not split the segment.
    func testRecorderIgnoresARepeatedStatus() {
        var series = PaneStatusSeriesRecorder()
        series.record(paneID: "s-1", status: .thinking, at: 1_000)
        series.record(paneID: "s-1", status: .thinking, at: 2_000)

        XCTAssertEqual(series.events(for: "s-1").count, 1)
        XCTAssertEqual(
            series.segments(for: "s-1", until: 3_000),
            [PaneStatusSegment(status: .thinking, start: 1_000, end: 3_000)]
        )
    }

    /// The ring cap: the series holds the newest `capacity` events and drops
    /// the oldest — in-memory since launch must not mean growing forever.
    func testRecorderRingCapDropsTheOldest() {
        var series = PaneStatusSeriesRecorder()
        let extra = 10
        for index in 0..<(PaneStatusSeriesRecorder.capacity + extra) {
            series.record(
                paneID: "s-1",
                status: index.isMultiple(of: 2) ? .ready : .thinking,
                at: Double(index)
            )
        }

        let events = series.events(for: "s-1")
        XCTAssertEqual(events.count, PaneStatusSeriesRecorder.capacity)
        XCTAssertEqual(events.first?.at, Double(extra))
    }

    /// A closed pane's series goes with it — `PaneActivityLedger.forget`'s
    /// leak-with-a-slow-fuse reasoning.
    func testRecorderForgetsAPane() {
        var series = PaneStatusSeriesRecorder()
        series.record(paneID: "s-1", status: .thinking, at: 1_000)
        series.forget(paneID: "s-1")

        XCTAssertTrue(series.events(for: "s-1").isEmpty)
        XCTAssertTrue(series.segments(for: "s-1", until: 2_000).isEmpty)
    }

    /// An event from after "now" yields no segment — a clock that went
    /// backwards must not draw a negative-width rectangle.
    func testSegmentsClampToNow() {
        var series = PaneStatusSeriesRecorder()
        series.record(paneID: "s-1", status: .thinking, at: 5_000)

        XCTAssertTrue(series.segments(for: "s-1", until: 4_000).isEmpty)
    }

    // MARK: - Lane layout math

    /// Time maps to pixels linearly across the visible window; segments
    /// straddling an edge clamp to it, segments outside vanish, and a segment
    /// too thin to see gets a floor of one point.
    func testSegmentSpanMapsTimeToPixels() throws {
        let span = try XCTUnwrap(ReviewPanelInsightsView.segmentSpan(
            PaneStatusSegment(status: .thinking, start: 250, end: 500),
            windowStart: 0,
            windowEnd: 1_000,
            width: 100
        ))
        XCTAssertEqual(span.x, 25, accuracy: 0.001)
        XCTAssertEqual(span.width, 25, accuracy: 0.001)

        let clamped = try XCTUnwrap(ReviewPanelInsightsView.segmentSpan(
            PaneStatusSegment(status: .ready, start: -500, end: 500),
            windowStart: 0,
            windowEnd: 1_000,
            width: 100
        ))
        XCTAssertEqual(clamped.x, 0, accuracy: 0.001)
        XCTAssertEqual(clamped.width, 50, accuracy: 0.001)

        XCTAssertNil(ReviewPanelInsightsView.segmentSpan(
            PaneStatusSegment(status: .ready, start: 2_000, end: 3_000),
            windowStart: 0,
            windowEnd: 1_000,
            width: 100
        ), "a segment entirely outside the window draws nothing")

        let sliver = try XCTUnwrap(ReviewPanelInsightsView.segmentSpan(
            PaneStatusSegment(status: .error, start: 100, end: 101),
            windowStart: 0,
            windowEnd: 1_000,
            width: 100
        ))
        XCTAssertEqual(sliver.width, 1, "a sliver is still visible")
    }

    /// Zoom halves the visible window per step, clamped: never past the
    /// zoom ceiling, never below the ten-second floor, and a young launch
    /// still shows at least a minute.
    func testWindowDurationZoomsByHalves() {
        XCTAssertEqual(
            ReviewPanelInsightsView.windowDuration(fullMs: 480_000, zoomLevel: 0),
            480_000
        )
        XCTAssertEqual(
            ReviewPanelInsightsView.windowDuration(fullMs: 480_000, zoomLevel: 1),
            240_000
        )
        XCTAssertEqual(
            ReviewPanelInsightsView.windowDuration(fullMs: 30_000, zoomLevel: 0),
            60_000,
            "a young launch still shows a minute of axis"
        )
        XCTAssertEqual(
            ReviewPanelInsightsView.windowDuration(
                fullMs: 60_000,
                zoomLevel: ReviewPanelInsightsView.maximumZoomLevel
            ),
            10_000,
            "the floor: zooming can never make the window vanish"
        )
    }

    /// The zoom buttons walk the level up and down, clamped at both ends,
    /// and the axis window scales with them.
    func testZoomButtonsScaleTheAxis() throws {
        let view = makeView()
        view.apply(
            lanes: [lane("s-1", segments: [
                PaneStatusSegment(status: .thinking, start: 520_000, end: 1_000_000),
            ])],
            activities: [],
            now: 1_000_000
        )
        let full = view.visibleWindow()
        XCTAssertEqual(full.end - full.start, 480_000, accuracy: 0.001)

        try XCTUnwrap(view.zoomInButton.onPress)()
        let halved = view.visibleWindow()
        XCTAssertEqual(halved.end - halved.start, 240_000, accuracy: 0.001)

        try XCTUnwrap(view.zoomOutButton.onPress)()
        try XCTUnwrap(view.zoomOutButton.onPress)()
        let floor = view.visibleWindow()
        XCTAssertEqual(view.zoomLevel, 0, "zooming out clamps at the full view")
        XCTAssertEqual(floor.end - floor.start, 480_000, accuracy: 0.001)
    }

    // MARK: - Header totals

    /// The spec's header line, from the ledger's numbers.
    func testHeaderTextSpeaksTheSpecsLine() {
        XCTAssertEqual(
            ReviewPanelInsightsView.headerText(activeMs: 185_000, toolRuns: 4),
            "Agent activity: 3m 5s · 4 tool runs"
        )
        XCTAssertEqual(
            ReviewPanelInsightsView.headerText(activeMs: 0, toolRuns: 1),
            "Agent activity: 0s · 1 tool run"
        )
    }

    /// The header sums the session's panes: settled time, the run still in
    /// progress, and every pane's tool runs.
    func testHeaderTotalsSumTheLedger() {
        let view = makeView()
        view.apply(
            lanes: [lane("s-1", segments: [
                PaneStatusSegment(status: .thinking, start: 0, end: 1_000),
            ])],
            activities: [
                PaneActivity(busySince: nil, settledActiveMs: 125_000, toolRuns: 3),
                PaneActivity(busySince: 940_000, settledActiveMs: 0, toolRuns: 1),
            ],
            now: 1_000_000
        )

        XCTAssertEqual(
            view.headerField.stringValue,
            "Agent activity: 3m 5s · 4 tool runs"
        )
    }

    // MARK: - Lanes and bars

    /// One timeline lane per pane, in pane order, each bar wearing its own
    /// segments — and the Time-by-status rows aggregate across every lane in
    /// the fixed status order, sized against the longest.
    func testApplyBuildsALanePerPaneAndTheStatusBars() {
        let view = makeView()
        view.apply(
            lanes: [
                lane("s-1", title: "Claude 1", segments: [
                    PaneStatusSegment(status: .thinking, start: 0, end: 2_000),
                    PaneStatusSegment(status: .ready, start: 2_000, end: 3_000),
                ]),
                lane("s-2", title: "Claude 2", segments: [
                    PaneStatusSegment(status: .thinking, start: 0, end: 1_000),
                ]),
            ],
            activities: [],
            now: 3_000
        )

        XCTAssertTrue(view.emptyStateView.isHidden)
        XCTAssertEqual(view.laneRows.map(\.title), ["Claude 1", "Claude 2"])
        XCTAssertEqual(view.laneRows[0].bar.segments.count, 2)
        XCTAssertEqual(view.laneRows[1].bar.segments.count, 1)

        XCTAssertEqual(view.statusRows.map(\.status), [.thinking, .ready])
        XCTAssertEqual(view.statusRows.map(\.ms), [3_000, 1_000])
        XCTAssertEqual(view.statusRows[0].fraction, 1, accuracy: 0.001)
        XCTAssertEqual(view.statusRows[1].fraction, 1.0 / 3.0, accuracy: 0.001)
    }

    /// Nothing recorded yet: the centred empty state, and no lanes or bars
    /// pretending otherwise.
    func testEmptyStateShowsWhenNothingIsRecorded() {
        let view = makeView()
        view.apply(
            lanes: [lane("s-1", segments: [])],
            activities: [],
            now: 1_000
        )

        XCTAssertFalse(view.emptyStateView.isHidden)
        XCTAssertTrue(view.laneRows.isEmpty)
        XCTAssertTrue(view.statusRows.isEmpty)
    }

    /// The aggregation itself, pure: durations sum per status across lanes,
    /// ordered thinking → tool → waiting → ready → error, zeros dropped.
    func testTimeByStatusAggregatesAcrossLanes() {
        let totals = ReviewPanelInsightsView.timeByStatus(lanes: [
            lane("s-1", segments: [
                PaneStatusSegment(status: .ready, start: 0, end: 300),
                PaneStatusSegment(status: .thinking, start: 300, end: 1_300),
            ]),
            lane("s-2", segments: [
                PaneStatusSegment(status: .thinking, start: 0, end: 500),
                PaneStatusSegment(status: .toolExecution, start: 500, end: 700),
            ]),
        ])

        XCTAssertEqual(totals.map(\.status), [.thinking, .toolExecution, .ready])
        XCTAssertEqual(totals.map(\.ms), [1_500, 200, 300])
    }

    // MARK: - Fed from the status fan-out, through the controller

    /// Activating the Insights tab is what reads the recorded series — and
    /// the series is fed by the same `onStatus` path the ledger reads, so a
    /// status event recorded before the panel ever opened still shows.
    func testActivatingTheInsightsTabReadsTheRecordedSeries() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("review-insights-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let controller = makeController(panes: [
            PersistedTab(project: "alpha", engine: .claude, cwd: dir.path, id: "s-1", group: "g-1"),
        ])
        defer { controller.close() }
        controller.recordNotification(
            for: SessionStatusEvent(id: "s-1", status: .thinking, notify: false, engine: "claude")
        )

        controller.applyRestoredReviewPanel(
            ReviewPanelStateCodec.serialize([
                "g-1": ReviewPanelSessionState(open: true, activeTab: "files"),
            ])
        )
        XCTAssertTrue(
            controller.reviewPanelInsights.lanes.isEmpty,
            "an inactive tab is fed nothing — activation is the trigger"
        )

        controller.reviewPanel.addTab(.insights)

        let lanes = controller.reviewPanelInsights.lanes
        XCTAssertEqual(lanes.map(\.paneID), ["s-1"])
        XCTAssertEqual(lanes.first?.segments.map(\.status), [.thinking])
        XCTAssertTrue(
            controller.reviewPanelInsights.headerField.stringValue
                .hasPrefix("Agent activity:")
        )
    }

    // MARK: - Helpers

    private func makeView() -> ReviewPanelInsightsView {
        let view = ReviewPanelInsightsView()
        view.frame = NSRect(x: 0, y: 0, width: 420, height: 480)
        view.layoutSubtreeIfNeeded()
        return view
    }

    private func lane(
        _ paneID: String,
        title: String = "Claude",
        segments: [PaneStatusSegment]
    ) -> ReviewPanelInsightsView.Lane {
        ReviewPanelInsightsView.Lane(paneID: paneID, title: title, segments: segments)
    }

    private func makeController(panes: [PersistedTab]) -> WorkspaceWindowController {
        let controller = WorkspaceWindowController(
            connection: SessionConnection(
                socketURL: URL(fileURLWithPath: "/tmp/omniagent-review-insights-test.sock")
            ),
            panes: []
        )
        controller.sessionEnsurer = { _ in }
        controller.sessionKiller = { _ in }
        controller.applyRestoredPanes(
            WorkspaceRestoration.plan(fromLayout: PersistedLayoutCodec.serialize(panes))
        )
        return controller
    }
}
