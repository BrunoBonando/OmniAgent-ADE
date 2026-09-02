import AppKit

/// The remote live-session card (2026-09-01 remote environment sharing spec
/// §6/§10, Task 25): directly **above** the self-update card at the foot of
/// the sidebar — the same sheet of liquid glass, the same 14pt radius, the
/// same 8pt inset as `SidebarUpdateWidgetView`, so the column reads as one
/// stack of cards (remote session → update → session/week limits) rather
/// than three unrelated things.
///
/// Host name, elapsed time counting up **locally** (not re-read from the
/// daemon — `RemoteSessionInfo.since` is this window's own clock, set the
/// instant the takeover begins), and a red **End session** button calling
/// `WorkspaceWindowController.disconnectRemote()`.
///
/// Hidden — and hidden *properly*, as an arranged subview whose `isHidden`
/// drops it from the stack's layout — for the entire time nobody is being
/// driven, `SidebarUpdateWidgetView`'s own reasoning.
final class SidebarRemoteSessionWidgetView: NSView {
    static let height: CGFloat = 56
    static let cornerRadius: CGFloat = 14

    /// Pressed: end the session. The widget does not end it itself — ending
    /// a takeover is `WorkspaceWindowController`'s call (it also restores the
    /// local environment), not a view's.
    var onEndSession: (() -> Void)?

    private let icon = NSImageView()
    private let titleField: NSTextField
    private let captionField: NSTextField
    private let endButton: PaneApprovalButton
    /// The accent wash over the glass — red, so this card cannot be mistaken
    /// for the update card sitting right under it even at a glance.
    private let tint = NSView()

    /// `nil` outside a takeover — `apply(nil)`'s resting state.
    private(set) var session: RemoteSessionInfo?
    /// Ticks the elapsed-time label without touching the daemon —
    /// `SidebarClaudeLimitsView.clock`'s own pattern: the daemon's fact
    /// (`since`) only ever changes on a fresh takeover, but the clock has to
    /// move every second regardless.
    private var clock: Timer?

    override init(frame frameRect: NSRect) {
        titleField = ShellFont.label("", font: ShellFont.ui(12.5, .semibold), color: ShellPalette.ink)
        captionField = ShellFont.label("", font: ShellFont.ui(11), color: ShellPalette.inkSecondary)
        endButton = PaneApprovalButton(title: "End session", isPrimary: true, tint: ShellPalette.red)
        super.init(frame: frameRect)

        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

        // `SidebarUpdateWidgetView`'s exact treatment — the two cards sit
        // directly on top of one another and must read as one stack.
        let glass = WorkspaceGlass.sheet(cornerRadius: Self.cornerRadius)
        if glass == nil {
            layer?.cornerRadius = Self.cornerRadius
            layer?.cornerCurve = .continuous
            layer?.backgroundColor = NSColor(white: 1, alpha: 0.05).cgColor
            layer?.borderWidth = 1
            layer?.borderColor = ShellPalette.hairlineStrong.cgColor
        }

        tint.wantsLayer = true
        tint.translatesAutoresizingMaskIntoConstraints = false
        tint.layer?.cornerRadius = Self.cornerRadius
        tint.layer?.cornerCurve = .continuous
        tint.layer?.masksToBounds = true
        tint.layer?.backgroundColor = ShellPalette.red.withAlphaComponent(0.16).cgColor

        icon.image = NSImage(systemSymbolName: "desktopcomputer.and.arrow.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))
        icon.contentTintColor = ShellPalette.red
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.setContentHuggingPriority(.required, for: .horizontal)

        let text = NSStackView(views: [titleField, captionField])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        text.translatesAutoresizingMaskIntoConstraints = false

        endButton.translatesAutoresizingMaskIntoConstraints = false
        endButton.onClick = { [weak self] in self?.onEndSession?() }
        endButton.setContentHuggingPriority(.required, for: .horizontal)

        for view in [glass, tint, icon, text, endButton].compactMap({ $0 }) { addSubview(view) }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),

            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 13),
            icon.centerYAnchor.constraint(equalTo: titleField.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 17),
            icon.heightAnchor.constraint(equalToConstant: 17),

            text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 9),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
            text.trailingAnchor.constraint(lessThanOrEqualTo: endButton.leadingAnchor, constant: -10),

            endButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            endButton.centerYAnchor.constraint(equalTo: centerYAnchor),
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
        NSLayoutConstraint.activate([
            tint.leadingAnchor.constraint(equalTo: leadingAnchor),
            tint.trailingAnchor.constraint(equalTo: trailingAnchor),
            tint.topAnchor.constraint(equalTo: topAnchor),
            tint.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    /// What the card says right now — the facts tests assert on.
    var titleText: String { titleField.stringValue }
    var captionText: String { captionField.stringValue }
    /// The button itself, for the test that pressing it fires
    /// `onEndSession` and the layout test that it stays inside the card.
    var endButtonForTesting: PaneApprovalButton { endButton }

    /// `nil` takes the card down; a session shows the host name and starts
    /// the elapsed clock from `session.since`. Called by
    /// `WorkspaceWindowController` off `RemoteSharingModel.onChange`, the
    /// same push `MenuBarController.refreshShareIcon` reads.
    func apply(_ session: RemoteSessionInfo?) {
        self.session = session
        isHidden = session == nil
        titleField.stringValue = session.map { "Driving \($0.machineName)" } ?? ""
        setAccessibilityLabel(session.map { "Driving \($0.machineName)" } ?? "")
        tick()
        restartClockIfNeeded()
    }

    /// Recomputes the caption from `session.since` — internal rather than
    /// private so a test can drive the clock without waiting real seconds.
    func tick(now: Date = Date()) {
        guard let session else {
            captionField.stringValue = ""
            return
        }
        captionField.stringValue = Self.format(elapsed: now.timeIntervalSince(session.since))
    }

    private func restartClockIfNeeded() {
        clock?.invalidate()
        clock = nil
        guard session != nil, window != nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        // `.common`, so the clock keeps ticking while the sidebar is being
        // scrolled or a menu is tracking — `SidebarClaudeLimitsView`'s own
        // reasoning for its countdown.
        RunLoop.main.add(timer, forMode: .common)
        clock = timer
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        restartClockIfNeeded()
    }

    /// `h:mm:ss` past the first hour, `mm:ss` before it — a session is
    /// commonly minutes long, occasionally hours; seconds are the only unit
    /// fine enough to prove the clock is actually counting up rather than
    /// stuck.
    static func format(elapsed interval: TimeInterval) -> String {
        let total = max(0, Int(interval.rounded(.down)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
