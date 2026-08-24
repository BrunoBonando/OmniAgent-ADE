import AppKit

// The review panel's Insights tab — the 2026-08-20 redesign's §5: agent
// activity, from data the app actually has. The data is a per-pane series of
// the daemon's own status events — recorded in memory since launch,
// ring-capped, fed from the same `onStatus` fan-out the activity ledger and
// the usage recorder already read — plus the `PaneActivityLedger`'s totals
// for the header. Rendered as one timeline lane per pane with
// status-coloured segments on a shared time axis (zoomable), and a
// Time-by-status breakdown underneath. No context-percentage chart: nothing
// in the app knows a context size, and a number the app cannot know is worse
// than no number (`HoverCardModel.totalsLine`'s reasoning).

// MARK: - The recorder

/// One status event, as the daemon announced it. `at` is epoch ms — the
/// activity ledger's clock.
struct PaneStatusEvent: Equatable {
    var status: RemoteSessionStatus
    var at: Double
}

/// One drawn stretch of a lane: a status, from when it was announced until
/// the next announcement (or "now").
struct PaneStatusSegment: Equatable {
    var status: RemoteSessionStatus
    var start: Double
    var end: Double
}

/// The status events, kept per pane — what `PaneActivityLedger` reduces to
/// totals, this keeps as a series, because a timeline needs the *when* of
/// every hop, not just the sums. In-memory since launch by design: the
/// timeline's promise is "what the agents did this run", not history.
struct PaneStatusSeriesRecorder: Equatable {
    /// Per pane. A status flip every 5 seconds for 40 minutes still fits —
    /// and past the cap the oldest events fall off, which for a
    /// since-launch timeline is the truthful end of the tape.
    static let capacity = 512

    private var panes: [String: [PaneStatusEvent]] = [:]

    func events(for paneID: String) -> [PaneStatusEvent] { panes[paneID] ?? [] }

    /// One status event. A repeated status is not a new event — the
    /// ledger's own dedupe rule, kept: the daemon re-announcing "thinking"
    /// must not split the segment.
    mutating func record(paneID: String, status: RemoteSessionStatus, at: Double) {
        guard at.isFinite else { return }
        var list = panes[paneID] ?? []
        guard list.last?.status != status else { return }
        list.append(PaneStatusEvent(status: status, at: at))
        if list.count > Self.capacity {
            list.removeFirst(list.count - Self.capacity)
        }
        panes[paneID] = list
    }

    /// A closed pane's series goes with it — `PaneActivityLedger.forget`'s
    /// leak-with-a-slow-fuse reasoning.
    mutating func forget(paneID: String) {
        panes.removeValue(forKey: paneID)
    }

    /// The series as drawable segments: each event runs until the next one,
    /// the last until `now`. An event from after `now` yields nothing — a
    /// clock that went backwards must not draw a negative-width rectangle.
    func segments(for paneID: String, until now: Double) -> [PaneStatusSegment] {
        let list = panes[paneID] ?? []
        var result: [PaneStatusSegment] = []
        for (index, event) in list.enumerated() {
            let end = index + 1 < list.count ? list[index + 1].at : now
            guard end > event.at else { continue }
            result.append(PaneStatusSegment(status: event.status, start: event.at, end: end))
        }
        return result
    }
}

// MARK: - Timeline lane

/// One lane's bar: the pane's segments across the visible window, drawn in
/// the status colours the sidebar dots already speak
/// (`ShellDotsView.color(for:)` — one vocabulary everywhere).
final class ReviewPanelInsightsLaneBarView: NSView {
    var segments: [PaneStatusSegment] = [] { didSet { needsDisplay = true } }
    var windowStart: Double = 0 { didSet { needsDisplay = true } }
    var windowEnd: Double = 0 { didSet { needsDisplay = true } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func draw(_ dirtyRect: NSRect) {
        ShellPalette.fieldFill.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 3, yRadius: 3).fill()
        for segment in segments {
            guard let span = ReviewPanelInsightsView.segmentSpan(
                segment,
                windowStart: windowStart,
                windowEnd: windowEnd,
                width: bounds.width
            ) else { continue }
            ShellDotsView.color(for: segment.status).setFill()
            NSBezierPath(
                roundedRect: NSRect(x: span.x, y: 0, width: span.width, height: bounds.height),
                xRadius: 1.5,
                yRadius: 1.5
            ).fill()
        }
    }
}

/// One timeline row: the pane's name, then its bar. Manual frames — the row
/// is one line and the title column has to agree with the axis below it.
final class ReviewPanelInsightsLaneRowView: NSView {
    let title: String
    let bar = ReviewPanelInsightsLaneBarView()
    private let titleField: NSTextField

    init(title: String) {
        self.title = title
        titleField = ShellFont.label(
            title,
            font: ShellFont.ui(11, .medium),
            color: ShellPalette.inkSecondary
        )
        super.init(frame: .zero)
        addSubview(titleField)
        addSubview(bar)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func layout() {
        super.layout()
        let titleHeight = titleField.intrinsicContentSize.height
        titleField.frame = NSRect(
            x: 0,
            y: (bounds.height - titleHeight) / 2,
            width: ReviewPanelInsightsView.laneTitleWidth,
            height: titleHeight
        )
        bar.frame = NSRect(
            x: ReviewPanelInsightsView.laneTrackX,
            y: 2,
            width: max(0, bounds.width - ReviewPanelInsightsView.laneTrackX),
            height: bounds.height - 4
        )
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }
}

// MARK: - Time-by-status row

/// One status's share of the run: swatch, the status in the hover card's
/// words, a bar sized against the longest status, and the duration.
final class ReviewPanelInsightsStatusRowView: NSView {
    let status: RemoteSessionStatus
    let ms: Double
    /// This status's duration over the longest status's — what sizes the bar.
    let fraction: Double

    let nameField: NSTextField
    let durationField: NSTextField
    private let swatch = NSView()
    private let track = NSView()
    private let fill = NSView()

    init(status: RemoteSessionStatus, ms: Double, fraction: Double) {
        self.status = status
        self.ms = ms
        self.fraction = fraction
        nameField = ShellFont.label(
            HoverCardModel.word(for: status),
            font: ShellFont.ui(11),
            color: ShellPalette.inkSecondary
        )
        durationField = ShellFont.label(
            HoverCardModel.duration(ms),
            font: ShellFont.mono(10),
            color: ShellPalette.inkMuted
        )
        super.init(frame: .zero)
        durationField.alignment = .right
        swatch.wantsLayer = true
        swatch.layer?.cornerRadius = 2
        swatch.layer?.backgroundColor = ShellDotsView.color(for: status).cgColor
        track.wantsLayer = true
        track.layer?.cornerRadius = 3
        track.layer?.backgroundColor = ShellPalette.fieldFill.cgColor
        fill.wantsLayer = true
        fill.layer?.cornerRadius = 3
        fill.layer?.backgroundColor = ShellDotsView.color(for: status).cgColor
        for view in [swatch, nameField, track, fill, durationField] { addSubview(view) }
        setAccessibilityLabel("\(HoverCardModel.word(for: status)): \(HoverCardModel.duration(ms))")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func layout() {
        super.layout()
        let mid = bounds.height / 2
        swatch.frame = NSRect(x: 0, y: mid - 4, width: 8, height: 8)
        let nameHeight = nameField.intrinsicContentSize.height
        nameField.frame = NSRect(x: 14, y: mid - nameHeight / 2, width: 92, height: nameHeight)
        let durationWidth: CGFloat = 52
        let durationHeight = durationField.intrinsicContentSize.height
        durationField.frame = NSRect(
            x: bounds.width - durationWidth,
            y: mid - durationHeight / 2,
            width: durationWidth,
            height: durationHeight
        )
        let trackX: CGFloat = 112
        let trackWidth = max(0, bounds.width - trackX - durationWidth - 8)
        track.frame = NSRect(x: trackX, y: mid - 3, width: trackWidth, height: 6)
        fill.frame = NSRect(
            x: trackX,
            y: mid - 3,
            width: max(fraction > 0 ? 2 : 0, trackWidth * CGFloat(fraction)),
            height: 6
        )
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }
}

// MARK: - The tab

/// The tab's whole content: a header bar ("Agent activity: <active time> ·
/// <n> tool runs", zoom out/in), the per-pane timeline lanes over a time
/// axis, and the Time-by-status bars. Everything on screen is derived from
/// what the controller hands `apply` — the view holds no clock and asks the
/// daemon nothing.
final class ReviewPanelInsightsView: NSView {
    static let headerHeight: CGFloat = 34
    static let laneTitleWidth: CGFloat = 84
    static var laneTrackX: CGFloat { laneTitleWidth + 6 }
    /// Six halvings of the full span — past that the window is a sliver.
    static let maximumZoomLevel = 6

    /// One pane's worth of timeline — what the controller assembles from the
    /// recorder plus the pane's display label.
    struct Lane: Equatable {
        let paneID: String
        let title: String
        let segments: [PaneStatusSegment]
    }

    let headerField = ShellFont.label(
        font: ShellFont.ui(12, .medium),
        color: ShellPalette.inkSecondary
    )
    let zoomOutButton = ReviewPanelIconButton(symbol: "minus.magnifyingglass", label: "Zoom out")
    let zoomInButton = ReviewPanelIconButton(symbol: "plus.magnifyingglass", label: "Zoom in")

    // The empty state — what the tab says before any agent has reported.
    let emptyStateView = NSStackView()
    let emptyGlyph = NSImageView()
    let emptyTitleField = ShellFont.label(
        "No agent activity yet",
        font: ShellFont.ui(13, .medium),
        color: ShellPalette.inkSecondary
    )
    let emptySubtitleField = ShellFont.label(
        "Status events appear here as agents work",
        font: ShellFont.ui(12),
        color: ShellPalette.inkMuted
    )

    private(set) var lanes: [Lane] = []
    private(set) var zoomLevel = 0
    private(set) var laneRows: [ReviewPanelInsightsLaneRowView] = []
    private(set) var statusRows: [ReviewPanelInsightsStatusRowView] = []

    let axisStartField = ShellFont.label(font: ShellFont.mono(9), color: ShellPalette.inkMuted)
    let axisMidField = ShellFont.label(font: ShellFont.mono(9), color: ShellPalette.inkMuted)
    let axisEndField = ShellFont.label(font: ShellFont.mono(9), color: ShellPalette.inkMuted)

    private let headerBar = NSView()
    private let contentContainer = FlippedContentView()
    private let timelineHeader = ShellFont.label(
        "TIMELINE",
        font: ShellFont.ui(10, .semibold),
        color: ShellPalette.inkMuted,
        tracking: 0.7
    )
    private let statusHeader = ShellFont.label(
        "TIME BY STATUS",
        font: ShellFont.ui(10, .semibold),
        color: ShellPalette.inkMuted,
        tracking: 0.7
    )
    private var now: Double = 0

    /// The manual top-down layout's canvas — flipped so "the next row goes
    /// below" is an addition, not a subtraction.
    private final class FlippedContentView: NSView {
        override var isFlipped: Bool { true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // No ground of its own: the panel behind it is the glass sheet, and an
        // opaque fill here would be a slab sitting on top of it.

        zoomOutButton.onPress = { [weak self] in self?.zoomOut() }
        zoomInButton.onPress = { [weak self] in self?.zoomIn() }

        let barHairline = NSView()
        barHairline.wantsLayer = true
        barHairline.layer?.backgroundColor = ShellPalette.hairline.cgColor
        barHairline.translatesAutoresizingMaskIntoConstraints = false

        for view in [headerField, zoomOutButton, zoomInButton, barHairline] as [NSView] {
            headerBar.addSubview(view)
        }
        NSLayoutConstraint.activate([
            headerField.leadingAnchor.constraint(equalTo: headerBar.leadingAnchor, constant: 10),
            headerField.centerYAnchor.constraint(equalTo: headerBar.centerYAnchor),
            headerField.trailingAnchor.constraint(
                lessThanOrEqualTo: zoomOutButton.leadingAnchor, constant: -8
            ),

            zoomInButton.trailingAnchor.constraint(equalTo: headerBar.trailingAnchor, constant: -8),
            zoomInButton.centerYAnchor.constraint(equalTo: headerBar.centerYAnchor),
            zoomOutButton.trailingAnchor.constraint(
                equalTo: zoomInButton.leadingAnchor, constant: -2
            ),
            zoomOutButton.centerYAnchor.constraint(equalTo: headerBar.centerYAnchor),

            barHairline.leadingAnchor.constraint(equalTo: headerBar.leadingAnchor),
            barHairline.trailingAnchor.constraint(equalTo: headerBar.trailingAnchor),
            barHairline.bottomAnchor.constraint(equalTo: headerBar.bottomAnchor),
            barHairline.heightAnchor.constraint(equalToConstant: 1),
        ])

        emptyGlyph.image = NSImage(
            systemSymbolName: "chart.bar.xaxis",
            accessibilityDescription: "No agent activity"
        )?.withSymbolConfiguration(.init(pointSize: 26, weight: .medium))
        emptyGlyph.contentTintColor = ShellPalette.inkFainter

        emptyStateView.orientation = .vertical
        emptyStateView.alignment = .centerX
        emptyStateView.spacing = 4
        emptyStateView.setViews([emptyGlyph, emptyTitleField, emptySubtitleField], in: .center)
        emptyStateView.setCustomSpacing(10, after: emptyGlyph)
        emptyStateView.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(emptyStateView)
        NSLayoutConstraint.activate([
            emptyStateView.centerXAnchor.constraint(equalTo: contentContainer.centerXAnchor),
            emptyStateView.centerYAnchor.constraint(equalTo: contentContainer.centerYAnchor),
        ])

        for view in [timelineHeader, axisStartField, axisMidField, axisEndField, statusHeader] {
            contentContainer.addSubview(view)
        }
        for view in [headerBar, contentContainer] { addSubview(view) }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Insights tab")
        headerField.stringValue = Self.headerText(activeMs: 0, toolRuns: 0)
        applySectionsVisible(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        applyLayout()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        applyLayout()
    }

    // MARK: - Applying data

    /// Everything on screen, in one call: the session's lanes (pane order),
    /// its panes' ledger entries (the header's totals), and the clock they
    /// were read at. Called by the controller on tab activation and on every
    /// status event while the tab is showing.
    func apply(lanes: [Lane], activities: [PaneActivity], now: Double) {
        self.lanes = lanes
        self.now = now

        let activeMs = activities.reduce(0) { $0 + $1.activeMs(now: now) }
        let toolRuns = activities.reduce(0) { $0 + $1.toolRuns }
        headerField.stringValue = Self.headerText(activeMs: activeMs, toolRuns: toolRuns)

        let hasSegments = lanes.contains { !$0.segments.isEmpty }
        emptyStateView.isHidden = hasSegments

        for row in laneRows { row.removeFromSuperview() }
        for row in statusRows { row.removeFromSuperview() }
        laneRows = []
        statusRows = []
        guard hasSegments else {
            applySectionsVisible(false)
            applyLayout()
            return
        }

        laneRows = lanes.map { lane in
            let row = ReviewPanelInsightsLaneRowView(title: lane.title)
            row.bar.segments = lane.segments
            return row
        }
        let totals = Self.timeByStatus(lanes: lanes)
        let longest = totals.map(\.ms).max() ?? 0
        statusRows = totals.map { entry in
            ReviewPanelInsightsStatusRowView(
                status: entry.status,
                ms: entry.ms,
                fraction: longest > 0 ? entry.ms / longest : 0
            )
        }
        for row in laneRows { contentContainer.addSubview(row) }
        for row in statusRows { contentContainer.addSubview(row) }
        applySectionsVisible(true)
        refreshTimeline()
        applyLayout()
    }

    // MARK: - Header

    /// The spec's line: `Agent activity: <total active time> · <n> tool
    /// runs`, in the hover card's own duration vocabulary.
    static func headerText(activeMs: Double, toolRuns: Int) -> String {
        let runs = "\(toolRuns) tool run\(toolRuns == 1 ? "" : "s")"
        return "Agent activity: \(HoverCardModel.duration(activeMs)) · \(runs)"
    }

    // MARK: - Lane math

    /// Where one segment lands on a lane `width` points wide showing
    /// `windowStart..<windowEnd`: linear time-to-pixels, clamped to the
    /// window's edges, `nil` when the segment misses the window entirely,
    /// and a one-point floor so a real-but-brief tool run is still visible.
    static func segmentSpan(
        _ segment: PaneStatusSegment,
        windowStart: Double,
        windowEnd: Double,
        width: CGFloat
    ) -> (x: CGFloat, width: CGFloat)? {
        guard windowEnd > windowStart, width > 0 else { return nil }
        let start = max(segment.start, windowStart)
        let end = min(segment.end, windowEnd)
        guard end > start else { return nil }
        let scale = Double(width) / (windowEnd - windowStart)
        let x = CGFloat((start - windowStart) * scale)
        let span = max(1, CGFloat((end - start) * scale))
        return (x: x, width: min(span, width - x))
    }

    // MARK: - Zoom

    /// How much time the axis shows: the full since-launch span (never less
    /// than a minute, so a young launch still has an axis), halved per zoom
    /// level, floored at ten seconds so the window can never vanish.
    static func windowDuration(fullMs: Double, zoomLevel: Int) -> Double {
        let base = max(fullMs, 60_000)
        let level = max(0, min(maximumZoomLevel, zoomLevel))
        return max(base / pow(2, Double(level)), 10_000)
    }

    /// The stretch of time the lanes currently draw — anchored to `now` on
    /// the right, so zooming in narrows onto what just happened.
    func visibleWindow() -> (start: Double, end: Double) {
        let earliest = lanes.flatMap { $0.segments.map(\.start) }.min()
        let full = earliest.map { max(0, now - $0) } ?? 0
        let duration = Self.windowDuration(fullMs: full, zoomLevel: zoomLevel)
        return (start: now - duration, end: now)
    }

    func zoomIn() {
        guard zoomLevel < Self.maximumZoomLevel else { return }
        zoomLevel += 1
        refreshTimeline()
    }

    func zoomOut() {
        guard zoomLevel > 0 else { return }
        zoomLevel -= 1
        refreshTimeline()
    }

    // MARK: - Time by status

    /// The fixed order the breakdown reads in — busiest kinds of work first,
    /// the settled states after.
    static let statusOrder: [RemoteSessionStatus] = [
        .thinking, .toolExecution, .awaitingApproval, .ready, .error,
    ]

    /// Durations summed per status across every lane, in `statusOrder`,
    /// zero entries dropped — a bar of nothing says nothing.
    static func timeByStatus(lanes: [Lane]) -> [(status: RemoteSessionStatus, ms: Double)] {
        var totals: [RemoteSessionStatus: Double] = [:]
        for lane in lanes {
            for segment in lane.segments {
                totals[segment.status, default: 0] += max(0, segment.end - segment.start)
            }
        }
        return statusOrder.compactMap { status in
            guard let ms = totals[status], ms > 0 else { return nil }
            return (status: status, ms: ms)
        }
    }

    // MARK: - Internals

    /// Fixed 24-hour wall clock with seconds — the axis zooms below a
    /// minute, where `HH:mm` would print the same label at both ends.
    private static let axisFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    static func axisLabel(_ ms: Double) -> String {
        axisFormatter.string(from: Date(timeIntervalSince1970: ms / 1000))
    }

    /// Re-points every lane bar and the axis at the current window — what a
    /// zoom changes, without rebuilding the rows.
    private func refreshTimeline() {
        let window = visibleWindow()
        for row in laneRows {
            row.bar.windowStart = window.start
            row.bar.windowEnd = window.end
        }
        axisStartField.stringValue = Self.axisLabel(window.start)
        axisMidField.stringValue = Self.axisLabel((window.start + window.end) / 2)
        axisEndField.stringValue = Self.axisLabel(window.end)
    }

    private func applySectionsVisible(_ visible: Bool) {
        for view in [timelineHeader, axisStartField, axisMidField, axisEndField, statusHeader] {
            view.isHidden = !visible
        }
    }

    private func applyLayout() {
        headerBar.frame = NSRect(x: 0, y: 0, width: bounds.width, height: Self.headerHeight)
        contentContainer.frame = NSRect(
            x: 0,
            y: Self.headerHeight,
            width: bounds.width,
            height: max(0, bounds.height - Self.headerHeight)
        )

        let inset: CGFloat = 10
        let width = max(0, contentContainer.bounds.width - inset * 2)
        var y: CGFloat = 12

        timelineHeader.frame = NSRect(
            x: inset, y: y, width: width,
            height: timelineHeader.intrinsicContentSize.height
        )
        y += 20
        for row in laneRows {
            row.frame = NSRect(x: inset, y: y, width: width, height: 18)
            y += 22
        }
        // The axis, aligned under the lane track — start flush left, the
        // midpoint centred, the end flush right.
        let trackX = inset + Self.laneTrackX
        let trackWidth = max(0, width - Self.laneTrackX)
        let axisHeight = axisStartField.intrinsicContentSize.height
        let midWidth = axisMidField.intrinsicContentSize.width
        let endWidth = axisEndField.intrinsicContentSize.width
        axisStartField.frame = NSRect(
            x: trackX, y: y, width: axisStartField.intrinsicContentSize.width, height: axisHeight
        )
        axisMidField.frame = NSRect(
            x: trackX + (trackWidth - midWidth) / 2, y: y, width: midWidth, height: axisHeight
        )
        axisEndField.frame = NSRect(
            x: trackX + trackWidth - endWidth, y: y, width: endWidth, height: axisHeight
        )
        y += axisHeight + 14

        statusHeader.frame = NSRect(
            x: inset, y: y, width: width,
            height: statusHeader.intrinsicContentSize.height
        )
        y += 20
        for row in statusRows {
            row.frame = NSRect(x: inset, y: y, width: width, height: 16)
            y += 20
        }
    }
}
