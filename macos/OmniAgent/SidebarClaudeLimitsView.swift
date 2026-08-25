import AppKit

/// One limit's horizontal bar: a dim track with a fill across it.
///
/// A plain pair of layers rather than `NSProgressIndicator`, which draws its
/// own aqua-tinted geometry and neither takes this palette's fill colours nor
/// sits at a 3pt height without fighting.
final class SidebarLimitBarView: NSView {
    static let height: CGFloat = 4

    private let track = CALayer()
    private let fill = CALayer()

    /// 0…1, or nil for "no reading yet" — an empty track rather than a zero
    /// fill, because "0% used" and "we do not know" must not look the same.
    private(set) var fraction: Double?

    /// What the fill currently reads, for a test that would otherwise have to
    /// render the layer to find out.
    var fillFraction: Double { fraction ?? 0 }
    var fillColor: NSColor? { fill.backgroundColor.map { NSColor(cgColor: $0) ?? .clear } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        track.backgroundColor = NSColor(white: 1, alpha: 0.10).cgColor
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

    func apply(_ value: Double?) {
        fraction = value.map { min(max($0, 0), 1) }
        // The machine gauges' own thresholds, so one glance down the sidebar
        // reads amber the same way whatever it is measuring.
        fill.backgroundColor = (fraction.map {
            $0 >= 0.9 ? ShellPalette.red : $0 >= 0.7 ? ShellPalette.amber : ShellPalette.green
        } ?? ShellPalette.inkTertiary).cgColor
        setAccessibilityValue(fraction.map { "\(Int(($0 * 100).rounded()))%" } ?? "unknown")
        needsLayout = true
    }

    override func layout() {
        super.layout()
        // No implicit animation: this is re-laid-out on every sidebar resize
        // and a quarter-second fill slide on each one reads as a glitch.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        track.frame = bounds
        fill.frame = NSRect(x: 0, y: 0, width: bounds.width * (fraction ?? 0), height: bounds.height)
        CATransaction.commit()
    }
}

/// One labelled limit: `Session ▓▓░░░░ 4h 12m`.
final class SidebarLimitRowView: NSView {
    let bar = SidebarLimitBarView()
    private let nameField: NSTextField
    private let remainingField: NSTextField

    /// What the right-hand countdown reads — asserted directly by the tests.
    var remaining: String { remainingField.stringValue }

    init(name: String) {
        nameField = ShellFont.label(
            name,
            font: ShellFont.ui(10.5, .medium),
            color: ShellPalette.inkMuted
        )
        remainingField = ShellFont.label(
            "—",
            font: ShellFont.ui(10.5),
            color: ShellPalette.inkTertiary
        )
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        remainingField.alignment = .right

        let row = NSStackView(views: [nameField, bar, remainingField])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 7
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        // The two labels keep their intrinsic widths and the bar takes the
        // rest — without this the bar collapses to nothing and the labels
        // stretch, which is the opposite of what the row is for.
        nameField.setContentHuggingPriority(.required, for: .horizontal)
        remainingField.setContentHuggingPriority(.required, for: .horizontal)
        nameField.setContentCompressionResistancePriority(.required, for: .horizontal)
        remainingField.setContentCompressionResistancePriority(.required, for: .horizontal)
        bar.setContentHuggingPriority(.defaultLow, for: .horizontal)

        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(name)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    /// `percent` is what `/usage` reported; `resetsAt` is when the window
    /// rolls over. Either may be absent and the row still reads sensibly.
    func apply(percent: Int?, resetsAt: Date?, now: Date = Date()) {
        bar.apply(percent.map { Double($0) / 100 })
        remainingField.stringValue = ClaudeUsageLimits.timeLeft(until: resetsAt, now: now) ?? "—"
        setAccessibilityValue("\(percent.map { "\($0)% used" } ?? "unknown"), \(remaining) left")
    }
}

/// Claude's own rate-limit windows, pinned above the machine gauges in the
/// sidebar's bottom stack: how much of the five-hour session and of the week
/// is spent, and how long until each rolls over.
///
/// Account-global, so it lives here rather than in a pane — every App view
/// would otherwise render the identical two numbers, which is what the pane's
/// old stats bar did.
final class SidebarClaudeLimitsView: NSView {
    static let height: CGFloat = 58

    let sessionRow = SidebarLimitRowView(name: "Session")
    let weekRow = SidebarLimitRowView(name: "Week")

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

        let caption = ShellFont.label(
            "CLAUDE",
            font: ShellFont.ui(10, .semibold),
            color: ShellPalette.inkTertiary,
            tracking: 0.5
        )
        let stack = NSStackView(views: [caption, sessionRow, weekRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false

        for view in [glass, stack].compactMap({ $0 }) { addSubview(view) }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            sessionRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            weekRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
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
        sessionRow.apply(
            percent: limits?.sessionPercent, resetsAt: limits?.sessionResetsAt, now: now
        )
        weekRow.apply(percent: limits?.weekPercent, resetsAt: limits?.weekResetsAt, now: now)
    }
}
