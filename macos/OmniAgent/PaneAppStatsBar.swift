import AppKit

/// Four readouts over the transcript: what this conversation has cost, how
/// full its context is, and how much of Claude's session and week windows are
/// gone.
///
/// The first two are per *conversation* — summed from this pane's own
/// transcript, not from `UsageAnalytics`, which buckets per project and is the
/// wrong unit for a pane. The last two are account-global and identical in
/// every pane, which is why one app-wide poller feeds them all.
///
/// Two click targets, and they do not overlap. A click on the bar itself
/// toggles the expanded state — the narrow pane's three hidden readouts plus
/// the per-model weekly line. A click on the refresh glyph asks the poller for
/// a fresh reading. The glyph is a control, so `mouseDown` is delivered to it
/// and never reaches this view's own handler; the same hit-testing rule
/// `ComposerCardView` relies on, for the same reason.
final class PaneAppStatsBar: NSView {
    /// Below this width four readouts crowd or wrap, so the bar keeps the one
    /// that changes minute to minute and puts the rest behind a tap.
    static let fourUpMinimumWidth: CGFloat = 560

    var tokens: Int = 0 { didSet { tokensReadout.value = Self.compact(tokens) } }
    var context: Int = 0 { didSet { contextReadout.value = Self.compact(context) } }
    var limits: ClaudeUsageLimits? { didSet { applyLimits() } }

    /// Asked for when the refresh glyph is clicked. `/usage` is a real request
    /// against the limits it reports, so this is the only way a reading is
    /// ever taken off-schedule.
    var onRefreshRequested: (() -> Void)?

    private(set) var visibleReadoutCount = 4

    /// Whether the bar is showing everything it has: on a narrow pane the
    /// three readouts the collapse hid, and on any width the per-model weekly
    /// line, which exists nowhere else in the app.
    private(set) var isExpanded = false {
        didSet {
            guard isExpanded != oldValue else { return }
            applyLimits()
            needsLayout = true
        }
    }

    // Internal rather than private so the tests can assert *which* readout
    // survives a collapse. `descendants` walks hidden views too, so a test
    // that only searches for the word "Context" passes whichever three the
    // bar hid — the assertion has to name the views.
    let tokensReadout = Readout(title: "Tokens")
    let contextReadout = Readout(title: "Context")
    let sessionReadout = Readout(title: "Session")
    let weekReadout = Readout(title: "Week")

    /// The per-model weekly line, which `/usage` reports alongside the
    /// all-models one. Only ever visible expanded — it is a fifth number, and
    /// four already crowd a grid pane.
    let modelLabel = ShellFont.label(
        "", font: ShellFont.ui(10), color: ShellPalette.inkFaint
    )

    let refreshButton = NSButton()

    private let row = NSStackView()

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true

        // The same glass the composer and the approval card use, via the same
        // shared helper — three surfaces agreeing by construction rather than
        // by three hand-rolled availability branches.
        if let glass = WorkspaceGlass.sheet(cornerRadius: 12) {
            glass.translatesAutoresizingMaskIntoConstraints = false
            addSubview(glass)
            NSLayoutConstraint.activate([
                glass.topAnchor.constraint(equalTo: topAnchor),
                glass.leadingAnchor.constraint(equalTo: leadingAnchor),
                glass.trailingAnchor.constraint(equalTo: trailingAnchor),
                glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        } else {
            layer?.backgroundColor = ShellPalette.fieldFill.cgColor
            layer?.borderWidth = 1
            layer?.borderColor = ShellPalette.hairlineStrong.cgColor
        }

        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fillEqually
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        for readout in [tokensReadout, contextReadout, sessionReadout, weekReadout] {
            row.addArrangedSubview(readout)
        }

        refreshButton.bezelStyle = .regularSquare
        refreshButton.isBordered = false
        refreshButton.image = NSImage(
            systemSymbolName: "arrow.clockwise",
            accessibilityDescription: "Refresh usage"
        )
        refreshButton.contentTintColor = ShellPalette.inkFaint
        refreshButton.imageScaling = .scaleProportionallyDown
        refreshButton.setContentHuggingPriority(.required, for: .horizontal)
        refreshButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        refreshButton.translatesAutoresizingMaskIntoConstraints = false
        refreshButton.widthAnchor.constraint(equalToConstant: 18).isActive = true
        refreshButton.target = self
        refreshButton.action = #selector(requestRefresh)

        let top = NSStackView(views: [row, refreshButton])
        top.orientation = .horizontal
        top.alignment = .centerY
        top.spacing = 10
        top.translatesAutoresizingMaskIntoConstraints = false

        modelLabel.isHidden = true

        let column = NSStackView(views: [top, modelLabel])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 2
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            top.widthAnchor.constraint(equalTo: column.widthAnchor),
        ])

        // `didSet` never fires for an initial value, so the first render is
        // established here rather than left to whoever assigns first.
        tokensReadout.value = Self.compact(tokens)
        contextReadout.value = Self.compact(context)
        applyLimits()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    /// A click anywhere the refresh glyph did not take toggles the expansion.
    /// Only meaningful when the bar has something more to show, which on a
    /// wide pane is the per-model line and on a narrow one is three readouts
    /// as well.
    override func mouseDown(with event: NSEvent) {
        isExpanded.toggle()
    }

    @objc private func requestRefresh() {
        onRefreshRequested?()
    }

    /// Values only — never geometry. Writing a label's `stringValue` from
    /// inside `layout()` mutates its intrinsic content size mid-pass, which is
    /// how a bar ends up one pass behind the number it is showing.
    private func applyLimits() {
        // Never a fabricated zero: a pane that has had no successful fetch
        // says so, because "0% used" is a claim and "—" is an admission.
        sessionReadout.value = Self.percent(limits?.sessionPercent)
        weekReadout.value = Self.percent(limits?.weekPercent)
        if let name = limits?.modelName {
            modelLabel.stringValue = "Week (\(name)) \(Self.percent(limits?.modelPercent))"
        } else {
            modelLabel.stringValue = ""
        }
        modelLabel.isHidden = !(isExpanded && limits?.modelName != nil)
    }

    override func layout() {
        super.layout()
        // Expanded overrides the collapse: the tap is what puts the three
        // hidden readouts back, and without that there is no way to reach
        // them again on a pane that never gets wider.
        let wanted = bounds.width >= Self.fourUpMinimumWidth || isExpanded ? 4 : 1
        guard wanted != visibleReadoutCount else { return }
        visibleReadoutCount = wanted
        let collapsed = wanted == 1
        tokensReadout.isHidden = collapsed
        sessionReadout.isHidden = collapsed
        weekReadout.isHidden = collapsed
    }

    /// `341000` reads `341k`. A raw seven-digit number in a bar this shallow —
    /// ~45pt, two stacked labels and 6pt insets, as `PaneAppView.layout()`
    /// measures it — is noise.
    static func compact(_ value: Int) -> String {
        switch value {
        case 1_000_000...: return String(format: "%.1fM", Double(value) / 1_000_000)
        case 10_000...: return "\(value / 1_000)k"
        default: return "\(value)"
        }
    }

    static func percent(_ value: Int?) -> String {
        value.map { "\($0)%" } ?? "—"
    }

    /// One label pair: a muted title over its value.
    final class Readout: NSView {
        private let valueLabel = ShellFont.label("—", font: ShellFont.ui(13, .semibold), color: ShellPalette.ink)

        var value: String {
            get { valueLabel.stringValue }
            set { valueLabel.stringValue = newValue }
        }

        init(title: String) {
            super.init(frame: .zero)
            translatesAutoresizingMaskIntoConstraints = false
            let titleLabel = ShellFont.label(
                title,
                font: ShellFont.ui(10),
                color: ShellPalette.inkFaint
            )
            let stack = NSStackView(views: [titleLabel, valueLabel])
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 1
            stack.translatesAutoresizingMaskIntoConstraints = false
            addSubview(stack)
            NSLayoutConstraint.activate([
                stack.topAnchor.constraint(equalTo: topAnchor),
                stack.leadingAnchor.constraint(equalTo: leadingAnchor),
                stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
                stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    }
}
