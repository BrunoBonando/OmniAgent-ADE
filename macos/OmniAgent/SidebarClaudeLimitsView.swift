import AppKit

/// A percentage as a bar: a dim track with a fill across it.
///
/// Shared by the Claude limits card and the machine gauges below it, which is
/// the point — one bar, one colour ramp, one reading of what "full" means,
/// whether the number is a spent quota or a busy CPU.
///
/// A plain pair of layers rather than `NSProgressIndicator`, which draws its
/// own aqua-tinted geometry and neither takes this palette's fill colours nor
/// sits at this height without fighting.
final class SidebarPercentBarView: NSView {
    static let height: CGFloat = 5

    private let track = CALayer()
    private let fill = CALayer()

    /// 0…1, or nil for "no reading yet" — an empty track rather than a zero
    /// fill, because "you have used none of it" and "we do not know" must not
    /// look the same. See `minimumFillWidth` for the other half of that.
    private(set) var fraction: Double?

    /// What the fill currently reads, for a test that would otherwise have to
    /// render the layer to find out.
    var fillFraction: Double { fraction ?? 0 }
    var fillColor: NSColor? { fill.backgroundColor.map { NSColor(cgColor: $0) ?? .clear } }
    /// The fill's drawn width — the thing `minimumFillWidth` is about.
    var fillWidth: CGFloat { fill.frame.width }

    /// A real reading of 0% still draws a nub this wide.
    ///
    /// Without it a fresh session window renders as an empty track, which is
    /// pixel-identical to having no reading at all — the exact "why does this
    /// row look broken" this card was rebuilt over.
    static var minimumFillWidth: CGFloat { height }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        track.backgroundColor = NSColor(white: 1, alpha: 0.12).cgColor
        track.cornerRadius = Self.height / 2
        fill.cornerRadius = Self.height / 2
        fill.backgroundColor = ShellPalette.green.cgColor
        layer?.addSublayer(track)
        layer?.addSublayer(fill)
        heightAnchor.constraint(equalToConstant: Self.height).isActive = true
        setAccessibilityElement(true)
        setAccessibilityRole(.progressIndicator)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    /// The fill is how full a thing is, and the colour ramps with it: green to
    /// 70%, amber to 90%, red beyond.
    ///
    /// Continuous rather than three steps. A hard switch makes the bar jump
    /// between two states with nothing in between, so the colour only ever
    /// tells you which bucket you are in; sliding through the change means the
    /// bar is already warming before it is a warning, and you can see it
    /// coming. The stops:
    ///
    /// - `0…0.60`   green
    /// - `0.60…0.70` green sliding into amber, so 70% *arrives* amber
    /// - `0.70…0.80` amber
    /// - `0.80…0.90` amber sliding into red, so 90% *arrives* red
    /// - `0.90…1`   red
    ///
    /// And the colour strengthens the closer the bar gets to its limit, so a
    /// bar at 8% sits quietly and one about to hit the wall does not. Hue says
    /// which band you are in; strength says how close to the end of it.
    ///
    /// The single definition of the ramp: every bar and every number in both
    /// cards calls this, rather than carrying its own copy of the thresholds.
    static func colour(for fraction: Double?) -> NSColor {
        guard let fraction else { return ShellPalette.inkTertiary }
        return hue(for: fraction).withAlphaComponent(strength(for: fraction))
    }

    /// Which band the fraction is in, before strength is applied.
    static func hue(for fraction: Double) -> NSColor {
        if fraction <= 0.60 { return ShellPalette.green }
        if fraction < 0.70 {
            return blend(ShellPalette.green, ShellPalette.amber, (fraction - 0.60) / 0.10)
        }
        if fraction <= 0.80 { return ShellPalette.amber }
        if fraction < 0.90 {
            return blend(ShellPalette.amber, ShellPalette.red, (fraction - 0.80) / 0.10)
        }
        return ShellPalette.red
    }

    /// How present the colour is, rising with the fill.
    ///
    /// Floored well above transparent rather than starting at nothing: this
    /// paints the *numbers* as well as the bars, and a `8%` faded toward the
    /// background to make a point about being low is a readout you have to
    /// squint at. Legibility is not the thing to spend for an effect.
    static func strength(for fraction: Double) -> CGFloat {
        0.80 + 0.20 * min(max(fraction, 0), 1)
    }

    /// `from` and `to` mixed at `t`, in sRGB.
    ///
    /// Component-wise in a fixed space rather than `NSColor.blended(withFraction:)`,
    /// which mixes in whatever space the receiver happens to be in and would
    /// make the ramp depend on how the palette colours were built.
    static func blend(_ from: NSColor, _ to: NSColor, _ t: Double) -> NSColor {
        guard let a = from.usingColorSpace(.sRGB), let b = to.usingColorSpace(.sRGB) else {
            return to
        }
        let t = min(max(t, 0), 1)
        func mix(_ x: CGFloat, _ y: CGFloat) -> CGFloat { x + (y - x) * t }
        return NSColor(
            srgbRed: mix(a.redComponent, b.redComponent),
            green: mix(a.greenComponent, b.greenComponent),
            blue: mix(a.blueComponent, b.blueComponent),
            alpha: mix(a.alphaComponent, b.alphaComponent)
        )
    }

    func apply(_ value: Double?) {
        fraction = value.map { min(max($0, 0), 1) }
        fill.backgroundColor = Self.colour(for: fraction).cgColor
        setAccessibilityValue(fraction.map { "\(Int(($0 * 100).rounded()))% used" } ?? "no reading")
        needsLayout = true
    }

    override func layout() {
        super.layout()
        // No implicit animation: this is re-laid-out on every sidebar resize
        // and a quarter-second fill slide on each one reads as a glitch.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        track.frame = bounds
        if let fraction {
            let width = max(bounds.width * fraction, Self.minimumFillWidth)
            fill.frame = NSRect(x: 0, y: 0, width: min(width, bounds.width), height: bounds.height)
        } else {
            fill.frame = .zero
        }
        CATransaction.commit()
    }
}

/// A window's progress, cut into the units it is actually made of: five
/// blocks for the five-hour session, seven for the week.
///
/// Deliberately blocky where `SidebarPercentBarView` is a pill — the two sit
/// stacked in the same column and must not read as one bar drawn twice. And
/// Coloured by how much of the window has gone, on the same ramp as every
/// other bar in both cards — a full block bar is red like a full anything
/// else. Bruno's call, after seeing a nearly-spent five-hour window sitting
/// there in green: whatever the colour *means*, one card that colours two
/// bars by two different rules reads as a bug.
///
/// The pace reading it used to carry is not lost; it moved into the hover,
/// which already spelled it out in words.
final class SidebarSegmentedBarView: NSView {
    static let height: CGFloat = 5
    private static let gap: CGFloat = 2

    let segments: Int
    private var trackLayers: [CALayer] = []
    private var fillLayers: [CALayer] = []

    /// How far through the window we are, 0…1. Nil when there is nothing to
    /// derive it from — every block empty rather than a guess.
    private(set) var fraction: Double?

    /// How many blocks are at least partly filled, which is the thing a test
    /// can assert without measuring layers.
    var filledSegments: Int {
        guard let fraction, fraction > 0 else { return 0 }
        return min(segments, Int((fraction * Double(segments)).rounded(.up)))
    }

    init(segments: Int) {
        self.segments = segments
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        for _ in 0..<segments {
            let track = CALayer()
            track.backgroundColor = NSColor(white: 1, alpha: 0.10).cgColor
            track.cornerRadius = 1.5
            let fill = CALayer()
            // Bright enough to separate from its own track at a glance: at
            // `inkMuted` a spent block and an unspent one were the same grey
            // in an offscreen render, which makes the whole bar decoration.
            fill.backgroundColor = ShellPalette.green.cgColor
            fill.cornerRadius = 1.5
            layer?.addSublayer(track)
            layer?.addSublayer(fill)
            trackLayers.append(track)
            fillLayers.append(fill)
        }
        heightAnchor.constraint(equalToConstant: Self.height).isActive = true
        setAccessibilityElement(true)
        setAccessibilityRole(.progressIndicator)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    /// What the fill currently reads, for a test that would otherwise have to
    /// render the layer.
    var fillColor: NSColor? { fillLayers.first?.backgroundColor.map { NSColor(cgColor: $0) ?? .clear } }

    func apply(_ value: Double?) {
        fraction = value.map { min(max($0, 0), 1) }
        let paint = SidebarPercentBarView.colour(for: fraction)
        for fill in fillLayers { fill.backgroundColor = paint.cgColor }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let total = bounds.width - Self.gap * CGFloat(segments - 1)
        let width = max(total / CGFloat(segments), 1)
        for index in 0..<segments {
            let x = (width + Self.gap) * CGFloat(index)
            trackLayers[index].frame = NSRect(x: x, y: 0, width: width, height: bounds.height)
            // Each block is one whole unit of the window, so its own fill is
            // how far into *that* unit we are — the block being lived through
            // is partly filled while the ones behind it are solid.
            let progress = fraction.map { min(max($0 * Double(segments) - Double(index), 0), 1) } ?? 0
            fillLayers[index].frame = NSRect(
                x: x, y: 0, width: width * progress, height: bounds.height
            )
        }
        CATransaction.commit()
    }
}

/// One limit as a column: the window's name, the percentage big under it, how
/// much is spent, and how far through the window we are.
///
/// `SidebarStatGaugeView`'s rhythm exactly — caption over a big number —
/// because this card sits directly on top of that one, and the two used to
/// read as different design languages.
///
/// The countdown is a tooltip rather than a line of text. It said the same
/// thing the block bar says, and spending a whole row to repeat it was what
/// made this card crowd the sidebar.
final class SidebarLimitColumnView: NSView {
    let bar = SidebarPercentBarView()
    let timeBar: SidebarSegmentedBarView
    private let valueField: NSTextField
    private let captionField: NSTextField
    /// Named for length, not `window` — `NSView.window` already owns that.
    private let windowLength: TimeInterval

    /// What the big number reads, asserted directly rather than rendered.
    var readout: String { valueField.stringValue }
    var readoutColor: NSColor? { valueField.textColor }
    /// The countdown, `"4h 54m left"` — on hover now rather than on screen.
    private(set) var remaining: String = "—"

    /// `segments` is the unit the window is made of: five hours, or seven
    /// days. `window` is how long the whole thing lasts.
    ///
    /// `windowLength` is authored rather than derived, because `/usage` reports
    /// only when a window *ends*, never when it began. ponytail: a wrong
    /// constant here misreports how far through you are — if Claude's session
    /// window stops being five hours, this is the line that has to move.
    init(name: String, segments: Int, windowLength: TimeInterval) {
        self.windowLength = windowLength
        timeBar = SidebarSegmentedBarView(segments: segments)
        valueField = ShellFont.label(
            "—",
            font: ShellFont.ui(17, .semibold),
            color: ShellPalette.inkTertiary
        )
        captionField = ShellFont.label(
            name,
            font: ShellFont.ui(10, .semibold),
            color: ShellPalette.inkTertiary,
            tracking: 0.5
        )
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        for field in [valueField, captionField] { field.alignment = .center }

        // Caption first: the label names the thing, then the number answers
        // it. Reading `12%` before knowing it is the session is backwards.
        let stack = NSStackView(views: [captionField, valueField, bar, timeBar])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 1
        // The bars span the column; the labels centre in it.
        stack.setCustomSpacing(5, after: valueField)
        stack.setCustomSpacing(3, after: bar)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            bar.widthAnchor.constraint(equalTo: stack.widthAnchor),
            timeBar.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.progressIndicator)
        setAccessibilityLabel(name)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    /// `percent` is what `/usage` reported; `resetsAt` is when the window
    /// rolls over. Either may be absent and the column still reads sensibly.
    func apply(percent: Int?, resetsAt: Date?, now: Date = Date()) {
        let fraction = percent.map { Double($0) / 100 }
        bar.apply(fraction)
        valueField.stringValue = percent.map { "\($0)%" } ?? "—"
        valueField.textColor = SidebarPercentBarView.colour(for: fraction)
        let elapsed = Self.elapsedFraction(until: resetsAt, windowLength: windowLength, now: now)
        let projected = Self.projectedUsage(usage: fraction, elapsed: elapsed)
        timeBar.apply(elapsed)
        // "left" spelled out, because a bare `2d 11h` does not say whether it
        // is time spent, time left, or time until something else entirely.
        //
        // And the pace spelled out with it. The blocks no longer carry it in
        // their colour, so the hover is the only place it lives — worth
        // keeping, since "80% spent with four hours still to run" is the one
        // thing on this card you might actually act on.
        remaining = ClaudeUsageLimits.timeLeft(until: resetsAt, now: now)
            .map { "\($0 == "now" ? "resetting" : "\($0) left")\(Self.paceNote(projected: projected))" }
            ?? "no reading"
        // On every subview too: an `NSView`'s tooltip covers its own rect, and
        // the labels and bars sit on top of this one — without this, hovering
        // the actual number is the one place that shows nothing.
        for view in [self] + subviews + subviews.flatMap(\.subviews) { view.toolTip = remaining }
        setAccessibilityValue("\(readout) used, \(remaining)")
    }

    /// Where this window's spending is headed by the time it resets, as a
    /// fraction of the limit: 1.0 lands exactly on it, 2.0 hits the wall
    /// halfway through.
    ///
    /// A straight-line extrapolation, which is the honest amount of maths for
    /// a sidebar readout — it answers "at this rate", nothing more.
    ///
    /// Nil until there is enough window behind us to extrapolate from: in the
    /// first minutes two requests project to anything at all, and a bar that
    /// cries wolf on the opening move gets ignored by lunchtime.
    static func projectedUsage(usage: Double?, elapsed: Double?) -> Double? {
        guard let usage, let elapsed, elapsed >= 0.05, usage > 0 else { return nil }
        return usage / elapsed
    }

    /// What the blocks' colour is saying, in words.
    static func paceNote(projected: Double?) -> String {
        guard let projected, projected > 1 else { return "" }
        // Rounded to a whole multiple: "1.7× the clock" is false precision on
        // a straight-line guess.
        let times = Int(projected.rounded())
        return times >= 2
            ? " · spending \(times)× the clock"
            : " · spending faster than the clock"
    }

    /// How far through the window `now` is, 0…1.
    ///
    /// Derived from the end, because the end is all `/usage` gives: whatever
    /// is not still to come has already gone. Clamped, so a reset further out
    /// than one whole window — which would mean the window length below is
    /// wrong — reads as a fresh window rather than a negative one.
    static func elapsedFraction(
        until resetsAt: Date?, windowLength: TimeInterval, now: Date
    ) -> Double? {
        guard let resetsAt, windowLength > 0 else { return nil }
        let left = resetsAt.timeIntervalSince(now)
        return min(max((windowLength - left) / windowLength, 0), 1)
    }
}

/// Claude's own rate-limit windows, pinned above the machine gauges: how much
/// of the five-hour session and of the week is spent, and how long each has
/// left before it rolls over.
///
/// No `CLAUDE` header row: it cost a full line plus its spacing in a sidebar
/// that was being crowded, and the machine-gauges card directly below carries
/// no header either — so the two now match. The column captions and the
/// accessibility label are what name it.
///
/// Account-global, so it lives here rather than in a pane — every App view
/// would otherwise render the identical two numbers, which is what the pane's
/// old stats bar did.
final class SidebarClaudeLimitsView: NSView {
    static let height: CGFloat = 70

    /// Five hours in five blocks, seven days in seven — the units each window
    /// is actually counted in, so a block means something you can name.
    let sessionColumn = SidebarLimitColumnView(name: "SESSION", segments: 5, windowLength: 5 * 3600)
    let weekColumn = SidebarLimitColumnView(name: "WEEK", segments: 7, windowLength: 7 * 86_400)

    /// Ticks the two countdowns down without spending a `/usage` request. The
    /// percentages only move when the poller fetches; the clock moves anyway.
    private var clock: Timer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

        // `SidebarSystemStatsView`'s treatment exactly — this is the same kind
        // of card sitting directly on top of it, and a second radius or fill
        // would read as two unrelated things.
        let glass = WorkspaceGlass.sheet(cornerRadius: 14)
        if glass == nil {
            layer?.cornerRadius = 14
            layer?.cornerCurve = .continuous
            layer?.backgroundColor = NSColor(white: 1, alpha: 0.05).cgColor
            layer?.borderWidth = 1
            layer?.borderColor = ShellPalette.hairlineStrong.cgColor
        }

        let columns = NSStackView(views: [sessionColumn, Self.divider(), weekColumn])
        columns.orientation = .horizontal
        columns.alignment = .top
        columns.distribution = .fill
        columns.spacing = 10
        columns.translatesAutoresizingMaskIntoConstraints = false
        // Equal widths, so neither column's own content can make the two bars
        // start or end at different x — the ragged edges this card had when
        // each row sized itself around its own label and countdown.
        weekColumn.widthAnchor.constraint(equalTo: sessionColumn.widthAnchor).isActive = true

        for view in [glass, columns].compactMap({ $0 }) { addSubview(view) }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            columns.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            columns.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            columns.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        if let glass {
            glass.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                glass.leadingAnchor.constraint(equalTo: leadingAnchor),
                glass.trailingAnchor.constraint(equalTo: trailingAnchor),
                glass.topAnchor.constraint(equalTo: topAnchor),
                glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Claude usage limits")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    /// `SidebarSystemStatsView.divider()`'s own hairline, so the two cards
    /// split their columns identically.
    private static func divider() -> NSView {
        let line = NSView()
        line.wantsLayer = true
        line.translatesAutoresizingMaskIntoConstraints = false
        line.layer?.backgroundColor = ShellPalette.hairlineStrong.cgColor
        line.widthAnchor.constraint(equalToConstant: 1).isActive = true
        line.heightAnchor.constraint(equalToConstant: 30).isActive = true
        return line
    }

    /// Registers for the poller's push and starts it, and ticks the local
    /// clock — both only while there is a window, the same rule
    /// `SidebarSystemStatsView` samples the machine under.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        clock?.invalidate()
        clock = nil
        guard window != nil else {
            ClaudeUsageLimitsPoller.shared.removeObserver(self)
            return
        }
        ClaudeUsageLimitsPoller.shared.addObserver(self) { [weak self] in
            self?.apply(ClaudeUsageLimitsPoller.shared.latest)
        }
        ClaudeUsageLimitsPoller.shared.start()
        apply(ClaudeUsageLimitsPoller.shared.latest)
        // A minute, because the readout's finest unit is a minute.
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            self?.apply(ClaudeUsageLimitsPoller.shared.latest)
        }
        RunLoop.main.add(timer, forMode: .common)
        clock = timer
    }

    /// Internal rather than private so the tests can drive it with a fixed
    /// `now` instead of waiting a minute for the clock.
    func apply(_ limits: ClaudeUsageLimits?, now: Date = Date()) {
        sessionColumn.apply(
            percent: limits?.sessionPercent, resetsAt: limits?.sessionResetsAt, now: now
        )
        weekColumn.apply(percent: limits?.weekPercent, resetsAt: limits?.weekResetsAt, now: now)
    }
}
