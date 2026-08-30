import AppKit

/// The one definition of how these two cards move.
///
/// Shared so a needle and a bar arriving at the same reading arrive the same
/// way — the cards already share a colour ramp, and motion is the other half
/// of reading as one design.
enum SidebarMotion {
    /// Unhurried on purpose. The machine gauges resample every two seconds,
    /// so at this length a needle is still travelling when the next reading is
    /// most of the way there — which is the point: the card reads as something
    /// continuously alive rather than a thing that flicks between states.
    ///
    /// Still short of the sample interval, so a reading does finish before its
    /// successor lands. An interrupted one continues from where it visibly was
    /// rather than restarting, so overrunning would degrade gracefully anyway.
    static let duration: TimeInterval = 1.2

    /// Eases away from rest, runs quickest through the middle, slows as it
    /// arrives — carrying a little past the reading before settling onto it.
    ///
    /// The first control point's `y` of 0 is the standing start: the curve
    /// leaves at zero velocity instead of snapping into motion. The second
    /// point above 1 is what takes it beyond the destination before it eases
    /// back — about 12% past, and roughly a third of the duration is spent on
    /// the way back, which is what makes the arrival read as settling rather
    /// than as a bounce.
    ///
    /// The two `x` values are what make it an S at all, and they have to run
    /// in order: a second point sitting *before* the first draws something
    /// that is not an ease-in-out however promising its `y` values look. The
    /// numbers here were measured rather than guessed — equal thirds of the
    /// duration cover 17%, 63% and 21% of the distance.
    static let overshoot = CAMediaTimingFunction(controlPoints: 0.65, 0, 0.70, 1.55)

    /// The same slow-fast-slow shape with the overshoot taken out, for the
    /// things that have nowhere to put it.
    static let settle = CAMediaTimingFunction(controlPoints: 0.65, 0, 0.70, 1)

    /// Which of the two a change should use.
    ///
    /// A needle has room to swing past either end of its dial, so it always
    /// springs. A bar does not: overshooting a value on the way *down* means a
    /// negative width, which is an empty rectangle — the fill vanishes for a
    /// frame and comes back, which reads as a flicker rather than as physics.
    /// So a bar springs on the way up and merely arrives on the way down.
    static func curve(rising: Bool, canOvershootBothWays: Bool = false) -> CAMediaTimingFunction {
        rising || canOvershootBothWays ? overshoot : settle
    }

    /// How far along the journey the curve is after `x` of its duration.
    ///
    /// A timing function is parametric: its `t` is a position along the curve,
    /// not a moment in time. So this searches for the `t` whose *x* is the
    /// elapsed fraction and reads that point's `y`, which is what a timing
    /// function actually means. Core Animation does this internally for a
    /// layer; a number counting beside one has to do it out loud.
    static func progress(_ curve: CAMediaTimingFunction, atElapsed x: Double) -> Double {
        var p1 = [Float](repeating: 0, count: 2)
        var p2 = [Float](repeating: 0, count: 2)
        curve.getControlPoint(at: 1, values: &p1)
        curve.getControlPoint(at: 2, values: &p2)
        func axis(_ a: Double, _ b: Double, _ t: Double) -> Double {
            3 * pow(1 - t, 2) * t * a + 3 * (1 - t) * pow(t, 2) * b + pow(t, 3)
        }
        var low = 0.0
        var high = 1.0
        for _ in 0..<40 {
            let mid = (low + high) / 2
            if axis(Double(p1[0]), Double(p2[0]), mid) < x { low = mid } else { high = mid }
        }
        return axis(Double(p1[1]), Double(p2[1]), (low + high) / 2)
    }

    /// Whether motion is wanted at all: the caller's intent, overruled by
    /// Reduce Motion the way every animation in this app is.
    static func wanted(_ animated: Bool) -> Bool {
        animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Moves `layer`'s `keyPath` to `value`, travelling rather than jumping.
    ///
    /// **Explicit**, not a value set inside a transaction, and that is the
    /// whole point. Implicit animations are *actions*, and AppKit runs a
    /// layer-backed view's `layout()` inside a transaction with actions
    /// disabled — so a sublayer frame set there animates silently nothing.
    /// These bars did exactly that: correct-looking code, a transaction
    /// carrying the right curve, and `animationKeys()` empty every time. An
    /// explicit animation is not an action and is not suppressed.
    ///
    /// The model value is set first with actions off, so the layer's own state
    /// is already the destination and the animation is only how it is seen to
    /// arrive. `from` comes from the presentation, so a change arriving
    /// mid-flight continues from where it visibly was instead of snapping.
    static func move(
        _ layer: CALayer,
        _ keyPath: String,
        to value: Any,
        from previous: Any?,
        animated: Bool,
        rising: Bool,
        bothWays: Bool = false,
        key: String
    ) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.setValue(value, forKeyPath: keyPath)
        CATransaction.commit()
        guard wanted(animated) else { return layer.removeAnimation(forKey: key) }
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = previous
        animation.toValue = value
        animation.duration = duration
        animation.timingFunction = curve(rising: rising, canOvershootBothWays: bothWays)
        layer.add(animation, forKey: key)
    }
}

/// A readout that counts to its new value rather than cutting to it.
///
/// On the same curve and the same duration as the bar beside it, so the two
/// move as one thing — a number that snapped while its bar travelled would
/// read as two unrelated events.
///
/// **Overshoots with the bar, but never past what the figure can legally be.**
/// The number was clamped to its destination at first, on the reasoning that a
/// readout showing `48%` when the reading is `46%` states something untrue.
/// Bruno's call to let it run: a counter that drifts past and settles reads as
/// a live instrument, and the value it lands on is the true one. What it still
/// will not do is show an *impossible* figure — `103%` is not a reading
/// anybody is settling toward — so the travel is bounded by `range` rather
/// than by the destination.
///
/// Driven by a `Timer` rather than a display link: this is a label redrawing a
/// short string, the work per frame is one `stringValue` assignment, and a
/// timer needs no view to hang off and no availability to guard.
/// ponytail: swap it for `NSView.displayLink` if a number ever visibly stutters.
final class SidebarCountingLabel {
    /// Roughly a frame at 60Hz.
    private static let step: TimeInterval = 1.0 / 60

    private var timer: Timer?
    private var began = Date()
    private var from: Double = 0
    private var to: Double = 0
    private let range: ClosedRange<Double>
    private let render: (Double) -> Void

    /// The value last rendered — where a new count starts, so a reading
    /// arriving mid-count continues instead of jumping back.
    private(set) var current: Double = 0

    /// `render` is handed the value to display and decides how to write it.
    /// `range` bounds the travel, overshoot included — the readouts here are
    /// percentages, and no amount of momentum makes `103%` a number worth
    /// showing.
    init(range: ClosedRange<Double> = 0...100, render: @escaping (Double) -> Void) {
        self.range = range
        self.render = render
    }

    deinit { timer?.invalidate() }

    /// Counts from wherever it is to `value`.
    func count(to value: Double, animated: Bool) {
        timer?.invalidate()
        timer = nil
        guard SidebarMotion.wanted(animated), value != current else {
            current = value
            render(value)
            return
        }
        from = current
        to = value
        began = Date()
        // The first frame, now rather than a sixtieth of a second from now.
        // Without it the label holds whatever it last showed — on a first
        // reading, the "—" placeholder — until the timer's first tick.
        render(from)
        let ticker = Timer(timeInterval: Self.step, repeats: true) { [weak self] timer in
            guard let self else { return timer.invalidate() }
            let elapsed = Date().timeIntervalSince(self.began) / SidebarMotion.duration
            guard elapsed < 1 else {
                timer.invalidate()
                self.timer = nil
                self.current = self.to
                self.render(self.to)
                return
            }
            // Unclamped progress, so the count runs past its reading and
            // eases back the way the bar beside it does — bounded only by what
            // a percentage is allowed to be.
            let progress = SidebarMotion.progress(SidebarMotion.overshoot, atElapsed: elapsed)
            let value = self.from + (self.to - self.from) * progress
            self.current = min(max(value, self.range.lowerBound), self.range.upperBound)
            self.render(self.current)
        }
        // `.common`, so a number does not freeze mid-count while the sidebar
        // is being scrolled or a divider dragged.
        RunLoop.main.add(ticker, forMode: .common)
        timer = ticker
    }

    /// Whether a count is in flight.
    var isCounting: Bool { timer != nil }

    /// Puts the readout at `value` with no travel — for a state that is not a
    /// new reading, such as losing one entirely.
    func settle(at value: Double) {
        timer?.invalidate()
        timer = nil
        current = value
    }
}

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
    /// Whether the next layout pass is a value change (animate) or a geometry
    /// change (do not), and which way it is going.
    private var pendingAnimation = false
    private var pendingRise = true

    /// 0…1, or nil for "no reading yet" — an empty track rather than a zero
    /// fill, because "you have used none of it" and "we do not know" must not
    /// look the same. See `minimumFillWidth` for the other half of that.
    private(set) var fraction: Double?

    var fillColor: NSColor? { fill.backgroundColor.map { NSColor(cgColor: $0) ?? .clear } }
    /// The fill's drawn width — the thing `minimumFillWidth` is about.
    var fillWidth: CGFloat { fill.frame.width }

    /// Which animations are attached to the fill right now, and what curve
    /// they carry. The presentation layer does not advance under
    /// `xcodebuild test` — no window ever really comes on screen — so this is
    /// how a test asks whether the motion was *set up*, which is the part this
    /// code is responsible for.
    var fillAnimation: CABasicAnimation? {
        fill.animation(forKey: Self.widthKey) as? CABasicAnimation
    }

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
        // Pinned by its left edge, so growing is a change to one property —
        // `bounds.size.width` — rather than a frame change that has to move
        // `position` in step with it.
        fill.anchorPoint = NSPoint(x: 0, y: 0.5)
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
        let previous = fraction ?? 0
        fraction = value.map { min(max($0, 0), 1) }
        // Only a change in the *value* animates. A resize comes through
        // `layout` too, and a bar that springs whenever the sidebar is dragged
        // is a toy.
        pendingRise = (fraction ?? 0) >= previous
        pendingAnimation = (fraction ?? 0) != previous
        setFillColour(for: fraction)
        setAccessibilityValue(fraction.map { "\(Int(($0 * 100).rounded()))% used" } ?? "no reading")
        needsLayout = true
    }

    /// Repaints without touching geometry, so the colour can be walked through
    /// the ramp frame by frame while the fill travels — green does not become
    /// amber in one step any more than 41% becomes 62% in one step.
    func setFillColour(for value: Double?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.backgroundColor = Self.colour(for: value).cgColor
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        let animate = pendingAnimation
        let rising = pendingRise
        pendingAnimation = false
        // The track is geometry and never animates; only the fill carries the
        // value, so only the fill springs.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        track.frame = bounds
        CATransaction.commit()

        let width = fraction.map {
            min(max(bounds.width * $0, Self.minimumFillWidth), bounds.width)
        } ?? 0
        let previous = fill.presentation()?.bounds.width ?? fill.bounds.width
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.position = NSPoint(x: 0, y: bounds.midY)
        fill.bounds = NSRect(x: 0, y: 0, width: fill.bounds.width, height: bounds.height)
        CATransaction.commit()
        SidebarMotion.move(
            fill, "bounds.size.width", to: width, from: previous,
            animated: animate, rising: rising, key: Self.widthKey
        )
    }

    /// The key the fill's width animation is filed under, so a test can find
    /// it. The presentation layer does not advance under `xcodebuild test` —
    /// no window ever really comes on screen — so whether the motion was
    /// *installed* is the part this code can be held to.
    static let widthKey = "om-fill-width"
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
    /// Whether the next layout pass is a value change (animate) or a geometry
    /// change (do not), and which way it is going.
    private var pendingAnimation = false
    private var pendingRise = true

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
            fill.anchorPoint = NSPoint(x: 0, y: 0.5)
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
        let previous = fraction ?? 0
        fraction = value.map { min(max($0, 0), 1) }
        // Only a change in the *value* animates. A resize goes through
        // `layout` too, and a bar that springs every time the sidebar is
        // dragged is a toy.
        pendingRise = (fraction ?? 0) >= previous
        pendingAnimation = (fraction ?? 0) != previous
        setFillColour(for: fraction)
        needsLayout = true
    }

    /// Repaints every block without touching geometry — see
    /// `SidebarPercentBarView.setFillColour`.
    func setFillColour(for value: Double?) {
        let paint = SidebarPercentBarView.colour(for: value).cgColor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for fill in fillLayers { fill.backgroundColor = paint }
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        let animate = pendingAnimation
        let rising = pendingRise
        pendingAnimation = false
        let total = bounds.width - Self.gap * CGFloat(segments - 1)
        let width = max(total / CGFloat(segments), 1)
        // The tracks are geometry and never animate; only the fills carry the
        // value, so only the fills spring.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for index in 0..<segments {
            let x = (width + Self.gap) * CGFloat(index)
            trackLayers[index].frame = NSRect(x: x, y: 0, width: width, height: bounds.height)
        }
        CATransaction.commit()

        for index in 0..<segments {
            let x = (width + Self.gap) * CGFloat(index)
            let fill = fillLayers[index]
            // Each block is one whole unit of the window, so its own fill is
            // how far into *that* unit we are — the block being lived through
            // is partly filled, the ones behind it are solid.
            let progress = fraction.map {
                min(max($0 * Double(segments) - Double(index), 0), 1)
            } ?? 0
            let previous = fill.presentation()?.bounds.width ?? fill.bounds.width
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            fill.position = NSPoint(x: x, y: bounds.midY)
            fill.bounds = NSRect(x: 0, y: 0, width: fill.bounds.width, height: bounds.height)
            CATransaction.commit()
            SidebarMotion.move(
                fill, "bounds.size.width", to: width * progress, from: previous,
                animated: animate, rising: rising, key: SidebarPercentBarView.widthKey
            )
        }
    }

    /// What the blocks' fills are animating, for the same reason
    /// `SidebarPercentBarView.fillAnimation` exists.
    var fillAnimations: [CABasicAnimation] {
        fillLayers.compactMap {
            $0.animation(forKey: SidebarPercentBarView.widthKey) as? CABasicAnimation
        }
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
    /// The countdown in words, face down over the two bars until asked for.
    ///
    /// It occupies the bars' own band rather than a row of its own — a 10pt
    /// line is almost exactly as tall as `bar` + its gap + `timeBar` — so
    /// turning the card over costs no height and nothing below it moves.
    let timeLabel: NSTextField
    /// What each bar measures, at a glance: a bolt for quota spent, a clock
    /// for the window elapsing. Tinted with the bar beside it.
    let barIcon = SidebarLimitColumnView.icon("bolt.fill")
    let timeIcon = SidebarLimitColumnView.icon("clock")
    private let barsBox = NSView()
    private let valueField: NSTextField
    private let captionField: NSTextField
    /// Counts the percentage through every value between the old reading and
    /// the new one, at the pace of the bar beside it.
    private var counter: SidebarCountingLabel!
    /// The same, for how much of the window has gone.
    ///
    /// A second one because it counts a *different quantity*: the blocks and
    /// the countdown are coloured by elapsed window, not by spent quota, and
    /// those two are routinely in different bands — 4% of the quota with the
    /// window nearly gone is a green bar over red blocks. One counter cannot
    /// paint both without conflating them.
    ///
    /// It renders no text; it exists to walk two colours through the ramp.
    private var timeCounter: SidebarCountingLabel!
    /// Named for length, not `window` — `NSView.window` already owns that.
    private let windowLength: TimeInterval

    /// What the big number reads, asserted directly rather than rendered.
    var readout: String { valueField.stringValue }
    var readoutColor: NSColor? { valueField.textColor }
    /// What the number is counting, so a test can watch it travel.
    var countingLabel: SidebarCountingLabel { counter }

    /// The same for the window's own colour, which counts a different figure.
    var timeCountingLabel: SidebarCountingLabel { timeCounter }

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
        timeLabel = ShellFont.label(
            "—",
            font: ShellFont.ui(12, .medium),
            color: ShellPalette.inkMuted
        )
        super.init(frame: .zero)
        counter = SidebarCountingLabel { [weak self] value in
            guard let self else { return }
            self.valueField.stringValue = "\(Int(value.rounded()))%"
            // The colour walks the ramp with the number, so green does not
            // become amber in one step any more than 41% becomes 62% in one.
            // This is the *only* place a live reading's colour is set — the
            // branch in `apply` covers the no-reading case, where there is
            // nothing to travel and so no frames to paint.
            let reached = value / 100
            self.valueField.textColor = SidebarPercentBarView.colour(for: reached)
            self.bar.setFillColour(for: reached)
            self.barIcon.contentTintColor = SidebarPercentBarView.colour(for: reached)
        }
        timeCounter = SidebarCountingLabel(range: 0...1) { [weak self] value in
            guard let self else { return }
            self.timeBar.setFillColour(for: value)
            self.timeLabel.textColor = SidebarPercentBarView.colour(for: value)
            self.timeIcon.contentTintColor = SidebarPercentBarView.colour(for: value)
        }
        translatesAutoresizingMaskIntoConstraints = false
        for field in [valueField, captionField, timeLabel] { field.alignment = .center }
        timeLabel.alphaValue = 0

        // The two bars and the countdown share one band: the bars stacked in
        // it, the words laid over them, one visible at a time.
        // Each bar wears its icon on the left; the icons share one fixed
        // width so the two bars still start at the same x.
        let bars = NSStackView(views: [Self.row(barIcon, bar), Self.row(timeIcon, timeBar)])
        bars.orientation = .vertical
        bars.alignment = .centerX
        bars.spacing = 7
        bars.translatesAutoresizingMaskIntoConstraints = false
        barsBox.translatesAutoresizingMaskIntoConstraints = false
        barsBox.addSubview(bars)
        barsBox.addSubview(timeLabel)
        NSLayoutConstraint.activate([
            bars.leadingAnchor.constraint(equalTo: barsBox.leadingAnchor),
            bars.trailingAnchor.constraint(equalTo: barsBox.trailingAnchor),
            bars.topAnchor.constraint(equalTo: barsBox.topAnchor),
            bars.bottomAnchor.constraint(equalTo: barsBox.bottomAnchor),
            timeLabel.centerXAnchor.constraint(equalTo: barsBox.centerXAnchor),
            timeLabel.centerYAnchor.constraint(equalTo: barsBox.centerYAnchor),
            timeLabel.leadingAnchor.constraint(greaterThanOrEqualTo: barsBox.leadingAnchor),
        ])

        // Caption first: the label names the thing, then the number answers
        // it. Reading `12%` before knowing it is the session is backwards.
        let stack = NSStackView(views: [captionField, valueField, barsBox])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 1
        // The bars span the column; the labels centre in it.
        stack.setCustomSpacing(5, after: valueField)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            barsBox.widthAnchor.constraint(equalTo: stack.widthAnchor),
            bar.superview!.widthAnchor.constraint(equalTo: barsBox.widthAnchor),
            timeBar.superview!.widthAnchor.constraint(equalTo: barsBox.widthAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.progressIndicator)
        setAccessibilityLabel(name)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    static let iconWidth: CGFloat = 14

    private static func icon(_ name: String) -> NSImageView {
        let view = NSImageView()
        view.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        view.contentTintColor = SidebarPercentBarView.colour(for: nil)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalToConstant: iconWidth).isActive = true
        return view
    }

    /// `[icon] [bar────────]`: the icon keeps its width, the bar takes the rest.
    private static func row(_ icon: NSImageView, _ bar: NSView) -> NSStackView {
        let row = NSStackView(views: [icon, bar])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 4
        row.translatesAutoresizingMaskIntoConstraints = false
        icon.setContentHuggingPriority(.required, for: .horizontal)
        bar.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return row
    }

    /// `percent` is what `/usage` reported; `resetsAt` is when the window
    /// rolls over. Either may be absent and the column still reads sensibly.
    func apply(percent: Int?, resetsAt: Date?, now: Date = Date(), animated: Bool = true) {
        let fraction = percent.map { Double($0) / 100 }
        bar.apply(fraction)
        if let percent {
            counter.count(to: Double(percent), animated: animated)
        } else {
            // Losing a reading is not a journey to zero — it is the absence of
            // a number, so there is nothing to count through.
            counter.settle(at: 0)
            valueField.stringValue = "—"
            // The count paints the number while it travels; with no reading to
            // travel to, the colour has to be set here instead.
            valueField.textColor = SidebarPercentBarView.colour(for: nil)
            barIcon.contentTintColor = SidebarPercentBarView.colour(for: nil)
        }
        let elapsed = Self.elapsedFraction(until: resetsAt, windowLength: windowLength, now: now)
        let projected = Self.projectedUsage(usage: fraction, elapsed: elapsed)
        timeBar.apply(elapsed)
        if let elapsed {
            timeCounter.count(to: elapsed, animated: animated)
        } else {
            // No reading, so no travel — and the blocks and countdown wear the
            // same nothing-known grey the usage side does.
            timeCounter.settle(at: 0)
            timeBar.setFillColour(for: nil)
            timeLabel.textColor = SidebarPercentBarView.colour(for: nil)
            timeIcon.contentTintColor = SidebarPercentBarView.colour(for: nil)
        }
        // The countdown wears its own bar's colour rather than the usage
        // bar's — it reads the same thing the blocks beneath it read — and
        // `timeCounter` above is what paints both, frame by frame.
        // "left" spelled out, because a bare `2d 11h` does not say whether it
        // is time spent, time left, or time until something else entirely.
        //
        // And the pace spelled out with it. The blocks no longer carry it in
        // their colour, so the hover is the only place it lives — worth
        // keeping, since "80% spent with four hours still to run" is the one
        // thing on this card you might actually act on.
        remaining = ClaudeUsageLimits.timeLeft(until: resetsAt, now: now)
            .map { $0 == "now" ? "resetting" : "\($0) left" }
            ?? "no reading"
        timeLabel.stringValue = remaining
        // The hover says more than the face can fit: the pace note is the one
        // figure here you might act on, and it does not fit in a column this
        // narrow at a legible size.
        let hover = remaining + Self.paceNote(projected: projected)
        // Down the whole subtree, not two levels of it. An `NSView`'s tooltip
        // covers only its own rect, and the bars sit three deep now that they
        // share a band with the countdown — a hand-unrolled two levels used to
        // reach them and silently stopped when that band was added.
        Self.applyToolTip(hover, to: self)
        setAccessibilityValue("\(readout) used, \(hover)")
    }

    /// Sets `text` as the tooltip of `view` and everything under it.
    private static func applyToolTip(_ text: String, to view: NSView) {
        view.toolTip = text
        for child in view.subviews { applyToolTip(text, to: child) }
    }

    /// How long the turn takes. Fast, because it is a reveal rather than a
    /// transition between two screens — anything slower reads as a delay
    /// between the click and the answer.
    static let flipDuration: TimeInterval = 0.14

    /// Whether the words are showing instead of the bars.
    private(set) var isShowingTime = false

    /// Turns the column over. Instant under Reduce Motion, like every other
    /// animation in this app.
    func setShowingTime(_ showing: Bool, animated: Bool = true) {
        guard showing != isShowingTime else { return }
        isShowingTime = showing
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard animated, !reduceMotion else {
            barsBox.subviews.first?.alphaValue = showing ? 0 : 1
            timeLabel.alphaValue = showing ? 1 : 0
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.flipDuration
            barsBox.subviews.first?.animator().alphaValue = showing ? 0 : 1
            timeLabel.animator().alphaValue = showing ? 1 : 0
        }
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
    static let height: CGFloat = 78

    /// Five hours in five blocks, seven days in seven — the units each window
    /// is actually counted in, so a block means something you can name.
    let sessionColumn = SidebarLimitColumnView(name: "SESSION", segments: 5, windowLength: 5 * 3600)
    let weekColumn = SidebarLimitColumnView(name: "WEEK", segments: 7, windowLength: 7 * 86_400)

    /// Ticks the two countdowns down without spending a `/usage` request. The
    /// percentages only move when the poller fetches; the clock moves anyway.
    private var clock: Timer?

    /// How long the words stay up before the card turns back by itself.
    ///
    /// Long enough to read two short durations without hurrying, short enough
    /// that a card left face-up by a stray click does not stay that way.
    static let revealDuration: TimeInterval = 7

    private var revealTimer: Timer?

    /// Whether the card is showing the countdowns instead of the bars. Both
    /// columns turn together — the card is one thing, not two.
    var isShowingTime: Bool { sessionColumn.isShowingTime }

    /// Anywhere on the card, because the card is the button.
    ///
    /// No `hitTest` override to force that: `ShellFont.label` builds
    /// non-selectable fields and the bars are plain views, so an unhandled
    /// `mouseDown` walks the responder chain up to here on its own. Overriding
    /// `hitTest` *would* have caught every click and cost the per-subview
    /// tooltips, which are what carry the pace note.
    override func mouseDown(with event: NSEvent) {
        setShowingTime(!isShowingTime)
    }

    /// Internal rather than private so a test can turn the card over without
    /// synthesising a click.
    ///
    /// `after` is how long the card stays face-up, and is a parameter so a
    /// test can exercise the turn-back without waiting seven real seconds.
    /// That wait was the whole of its flakiness: it passed alone and failed in
    /// a full suite, where a machine busy with everything else is exactly when
    /// a wall-clock deadline slips. The production default is asserted
    /// separately, so shortening it here cannot quietly shorten it there.
    func setShowingTime(
        _ showing: Bool,
        animated: Bool = true,
        after: TimeInterval = SidebarClaudeLimitsView.revealDuration
    ) {
        revealTimer?.invalidate()
        revealTimer = nil
        for column in [sessionColumn, weekColumn] {
            column.setShowingTime(showing, animated: animated)
        }
        guard showing else { return }
        let timer = Timer(timeInterval: after, repeats: false) { [weak self] _ in
            self?.setShowingTime(false)
        }
        // `.common`, so a card left face-up while the sidebar is being
        // scrolled or dragged still turns back rather than freezing mid-reveal.
        RunLoop.main.add(timer, forMode: .common)
        revealTimer = timer
    }

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
        revealTimer?.invalidate()
        revealTimer = nil
        guard window != nil else {
            ClaudeUsageLimitsPoller.shared.removeObserver(self)
            // Face down again: a card that went away mid-reveal must not come
            // back still showing words with no timer left to turn it over.
            for column in [sessionColumn, weekColumn] { column.setShowingTime(false, animated: false) }
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
    func apply(_ limits: ClaudeUsageLimits?, now: Date = Date(), animated: Bool = true) {
        sessionColumn.apply(
            percent: limits?.sessionPercent, resetsAt: limits?.sessionResetsAt,
            now: now, animated: animated
        )
        weekColumn.apply(
            percent: limits?.weekPercent, resetsAt: limits?.weekResetsAt,
            now: now, animated: animated
        )
    }
}
