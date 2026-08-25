import AppKit

/// Four readouts over the transcript: what this conversation has cost, how
/// full its context is, and how much of Claude's session and week windows are
/// gone.
///
/// The first two are per *conversation* — summed from this pane's own
/// transcript, not from `UsageAnalytics`, which buckets per project and is the
/// wrong unit for a pane. The last two are account-global and identical in
/// every pane, which is why one app-wide poller feeds them all.
final class PaneAppStatsBar: NSView {
    /// Below this width four readouts crowd or wrap, so the bar keeps the one
    /// that changes minute to minute and puts the rest behind a tap.
    static let fourUpMinimumWidth: CGFloat = 560

    var tokens: Int = 0 { didSet { needsLayout = true } }
    var context: Int = 0 { didSet { needsLayout = true } }
    var limits: ClaudeUsageLimits? { didSet { needsLayout = true } }

    private(set) var visibleReadoutCount = 4

    private let tokensReadout = Readout(title: "Tokens")
    private let contextReadout = Readout(title: "Context")
    private let sessionReadout = Readout(title: "Session")
    private let weekReadout = Readout(title: "Week")
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
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func layout() {
        super.layout()
        tokensReadout.value = Self.compact(tokens)
        contextReadout.value = Self.compact(context)
        // Never a fabricated zero: a pane that has had no successful fetch
        // says so, because "0% used" is a claim and "—" is an admission.
        sessionReadout.value = Self.percent(limits?.sessionPercent)
        weekReadout.value = Self.percent(limits?.weekPercent)

        let wanted = bounds.width >= Self.fourUpMinimumWidth ? 4 : 1
        guard wanted != visibleReadoutCount else { return }
        visibleReadoutCount = wanted
        let collapsed = wanted == 1
        tokensReadout.isHidden = collapsed
        sessionReadout.isHidden = collapsed
        weekReadout.isHidden = collapsed
    }

    /// `341000` reads `341k`. A raw seven-digit number in a 34pt bar is noise.
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
    private final class Readout: NSView {
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
