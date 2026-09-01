import AppKit

/// The update strip, above the sidebar's nav rows. The whole self-update
/// feature has one place to speak from, and this is it:
///
///     Update available -> Updating... (bar) -> Update ready, restart
///
/// Hidden when there is nothing to say, and hidden *properly*: it lives as the
/// first arranged subview of the nav stack, so `isHidden` takes it out of the
/// layout entirely rather than leaving a 30-point gap above Home. That is the
/// one reason it is a stack child instead of a pinned view with its own
/// height constraint.
final class SidebarUpdateWidgetView: ShellRowView {
    /// Pressed while an update was available: start downloading.
    var onDownload: (() -> Void)?
    /// Pressed while an update was ready: restart into it.
    var onRestart: (() -> Void)?
    /// Pressed after a failure: try the check again.
    var onRetry: (() -> Void)?

    private let icon = NSImageView()
    private let titleField: NSTextField
    private let progress = NSProgressIndicator()

    private(set) var state: UpdateState = .idle

    override init(frame frameRect: NSRect) {
        titleField = ShellFont.label(
            "",
            font: ShellFont.ui(12.5, .medium),
            color: ShellPalette.accentBright
        )
        super.init(frame: frameRect)

        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = ShellPalette.accentSoft.cgColor

        icon.contentTintColor = ShellPalette.accentBright
        icon.translatesAutoresizingMaskIntoConstraints = false

        progress.style = .bar
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 1
        progress.controlSize = .small
        progress.isHidden = true
        progress.translatesAutoresizingMaskIntoConstraints = false

        for view in [icon, titleField, progress] { addSubview(view) }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            icon.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),

            titleField.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            titleField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            titleField.centerYAnchor.constraint(equalTo: icon.centerYAnchor),

            progress.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
            progress.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            progress.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 5),
            progress.heightAnchor.constraint(equalToConstant: 4),
        ])

        // The bar decides the height when it is showing; the icon does when it
        // is not. Both bottom constraints stay active, and the lower-priority
        // one loses whenever the bar is visible -- which is cheaper and less
        // fragile than swapping constraints on every state change.
        let compact = icon.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7)
        compact.priority = .defaultLow
        let tall = progress.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -8)
        NSLayoutConstraint.activate([compact, tall])
        heightAnchor.constraint(greaterThanOrEqualToConstant: 30).isActive = true

        onPress = { [weak self] in self?.press() }
        apply(.idle)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    /// What the row says right now — the fact tests assert on, since the
    /// label is the entire point of the view.
    var titleText: String { titleField.stringValue }

    func apply(_ state: UpdateState) {
        self.state = state
        isHidden = !state.isVisible

        switch state {
        case .idle:
            break
        case .checking:
            set(symbol: "arrow.triangle.2.circlepath", title: "Checking for updates…")
            progress.isHidden = true
        case let .available(version):
            set(symbol: "arrow.down.circle", title: "Update available · \(version)")
            progress.isHidden = true
        case let .updating(fraction):
            set(symbol: "arrow.down.circle", title: "Updating…")
            progress.isHidden = false
            // No expected content length yet: barber-pole rather than a bar
            // frozen at zero, which reads as stuck.
            progress.isIndeterminate = fraction == nil
            if let fraction {
                progress.stopAnimation(nil)
                progress.doubleValue = fraction
            } else {
                progress.startAnimation(nil)
            }
        case let .readyToRestart(version):
            let suffix = version.isEmpty ? "" : " · \(version)"
            set(symbol: "checkmark.circle", title: "Update ready\(suffix) — Restart")
            progress.isHidden = true
        case .failed:
            set(symbol: "exclamationmark.triangle", title: "Update failed — Retry")
            progress.isHidden = true
        }

        // Failure is the one state that is not the app's accent: a red row is
        // how it reads as a problem rather than an offer.
        let tint = isFailure ? ShellPalette.red : ShellPalette.accentBright
        icon.contentTintColor = tint
        titleField.textColor = tint
        refreshBackground()
        invalidateIntrinsicContentSize()
    }

    private var isFailure: Bool { if case .failed = state { return true }; return false }

    private func set(symbol: String, title: String) {
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
        titleField.stringValue = title
        setAccessibilityLabel(title)
    }

    private func press() {
        switch state {
        case .available: onDownload?()
        case .readyToRestart: onRestart?()
        case .failed: onRetry?()
        // Checking and updating are not buttons. Pressing during a download
        // should not cancel it by accident -- there is nothing here the user
        // can usefully do until it finishes.
        case .idle, .checking, .updating: break
        }
    }

    override func refreshBackground() {
        let base = isFailure
            ? ShellPalette.red.withAlphaComponent(0.16)
            : ShellPalette.accentSoft
        let fill = isHovered ? base.blended(withFraction: 0.12, of: .white) ?? base : base
        layer?.backgroundColor = fill.cgColor
    }
}
