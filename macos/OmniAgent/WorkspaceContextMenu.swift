import AppKit

// The workspace row's right-click menu and the Customize… card behind its
// item — the 2026-08-20 redesign's §3
// (docs/superpowers/specs/2026-08-20-copilot-nav-redesign-design.md). Menu
// construction is pure here, `WorkspacesHeaderMenus`' pattern:
// `WorkspaceWindowController` resolves the workspace (directory, GitHub
// remote, stored customization) and owns what the items do.

enum WorkspaceContextMenu {
    /// The spec's shape: New session · Show in Finder · Open on GitHub (only
    /// when a github.com origin exists) · separator · Customize… ·
    /// separator · Remove workspace, red — the one destructive thing on the
    /// menu says so before it is read.
    ///
    /// **Enable Remote Control is gone** (2026-09-01 remote environment
    /// sharing spec §1): sharing is one machine-wide switch now
    /// (`RemoteSharingModel`, Settings › Remote), not a per-workspace
    /// checkmark, so this menu has nothing left to say about it.
    static func build(
        gitHubURL: URL?,
        newSession: @escaping () -> Void,
        showInFinder: @escaping () -> Void,
        openOnGitHub: @escaping (URL) -> Void,
        customize: @escaping () -> Void,
        remove: @escaping () -> Void
    ) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(ShellMenuItem("New session", handler: newSession))
        menu.addItem(ShellMenuItem("Show in Finder", handler: showInFinder))
        if let gitHubURL {
            menu.addItem(ShellMenuItem("Open on GitHub") { openOnGitHub(gitHubURL) })
        }
        menu.addItem(.separator())
        menu.addItem(ShellMenuItem("Customize…", handler: customize))
        menu.addItem(.separator())
        let removeItem = ShellMenuItem("Remove workspace", handler: remove)
        removeItem.attributedTitle = NSAttributedString(
            string: "Remove workspace",
            attributes: [
                .foregroundColor: ShellPalette.red,
                .font: NSFont.menuFont(ofSize: 0),
            ]
        )
        menu.addItem(removeItem)
        return menu
    }

    /// `git remote get-url origin`, mapped to the repository's https page —
    /// or `nil` for no repository, no origin, or an origin that is not
    /// github.com. Synchronous: the menu is built on right-click and
    /// `get-url` only reads `.git/config`.
    static func gitHubRepositoryURL(inDirectory directory: String) -> URL? {
        guard
            let output = GitStatus.runGit(
                ["remote", "get-url", "origin"],
                in: URL(fileURLWithPath: directory, isDirectory: true)
            )
        else {
            return nil
        }
        return gitHubRepositoryURL(fromRemote: output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The remote shapes git actually hands out — scp-like
    /// (`git@github.com:owner/repo.git`) and URL (`https://`, `ssh://`,
    /// `git://`) — normalized to `https://github.com/owner/repo`.
    static func gitHubRepositoryURL(fromRemote remote: String) -> URL? {
        let trimmed = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let repositoryPath: Substring?
        if !trimmed.contains("://"), let range = trimmed.range(of: "github.com:") {
            // scp-like: everything after the colon is the path.
            repositoryPath = trimmed[range.upperBound...]
        } else if let url = URL(string: trimmed), url.host?.lowercased() == "github.com" {
            repositoryPath = Substring(url.path)
        } else {
            repositoryPath = nil
        }
        guard let repositoryPath else { return nil }

        var path = repositoryPath.drop(while: { $0 == "/" })
        while path.hasSuffix("/") { path = path.dropLast() }
        if path.hasSuffix(".git") { path = path.dropLast(4) }
        let components = path.split(separator: "/")
        guard components.count >= 2 else { return nil }
        return URL(string: "https://github.com/\(components[0])/\(components[1])")
    }
}

// MARK: - Colour swatch

/// One of the Customize card's eight swatches: a filled circle of the
/// colour, a white ring when it is the chosen one.
final class WorkspaceColorSwatchView: NSView {
    let color: WorkspaceColor
    var isSelected: Bool { didSet { needsDisplay = true } }
    var onPick: (() -> Void)?

    static let side: CGFloat = 22

    init(color: WorkspaceColor, selected: Bool) {
        self.color = color
        isSelected = selected
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.side),
            heightAnchor.constraint(equalToConstant: Self.side),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(color.rawValue)
        toolTip = color.rawValue
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onPick?()
    }

    override func draw(_ dirtyRect: NSRect) {
        color.tint.setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 3.5, dy: 3.5)).fill()
        guard isSelected else { return }
        let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1))
        ring.lineWidth = 1.5
        NSColor(white: 1, alpha: 0.9).setStroke()
        ring.stroke()
    }

    override func accessibilityValue() -> Any? { isSelected ? "selected" : "" }
}

// MARK: - The Customize card

/// # Customize Workspace
///
/// The pane ask's construction — glass over the window, a navy card in the
/// middle — carrying a display-name field and the eight colour swatches.
/// Window-scoped rather than pane-scoped: the subject is a workspace row in
/// the sidebar, not any one pane, so `WorkspaceWindowController` lays it
/// over the whole content view and owns its lifetime (`customizeCard`).
final class WorkspaceCustomizeCard: NSView {
    /// Esc, Cancel, or a click on the glass outside the card.
    var onCancel: (() -> Void)?
    /// Save: the customization as edited — a blank name means "use the
    /// folder name", carried as `nil`.
    var onSave: ((WorkspaceCustomization) -> Void)?

    private(set) var selectedColor: WorkspaceColor?
    private(set) var swatches: [WorkspaceColorSwatchView] = []

    private static let cardWidth: CGFloat = 330
    private static let padding: CGFloat = 22
    private static let fieldHeight: CGFloat = 30
    private static let fieldInset: CGFloat = 10
    private static let buttonHeight: CGFloat = 26
    private static let swatchGap: CGFloat = 8
    private static let cardRadius: CGFloat = 16

    /// The glass pair, `PaneAskOverlayView`'s exactly: the window-sized
    /// panel and the card's own, with the navy gradient tint between glass
    /// and text. `nil` before macOS 26, where `draw` paints flat navy.
    private let scrim: NSView?
    private let cardGlass: NSView?
    private let cardTint = NSView()
    private let cardTintLayer = CAGradientLayer()
    private static let navyTint = [
        NSColor(srgbRed: 0.11, green: 0.16, blue: 0.38, alpha: 0.40).cgColor,
        NSColor(srgbRed: 0.05, green: 0.08, blue: 0.22, alpha: 0.14).cgColor,
    ]

    private let titleLabel: NSTextField
    private let field: NSTextField
    private let fieldWell = NSView()
    private let captionLabel: NSTextField
    private let cancelButton: PaneApprovalButton
    private let saveButton: PaneApprovalButton
    private var cardFrame: NSRect = .zero
    /// One answer per card — Save and Cancel are two paths to "this card is
    /// done", and the owner hears back exactly once.
    private var isAnswered = false

    var titleText: String { titleLabel.stringValue }
    var placeholder: String { field.placeholderString ?? "" }
    var captionText: String { captionLabel.stringValue }
    var nameText: String { field.stringValue }
    /// Who should hold the keyboard while the card is up.
    var firstResponderView: NSView { field }

    init(folderName: String, current: WorkspaceCustomization?) {
        titleLabel = Self.label(
            "Customize Workspace",
            font: ShellFont.ui(15, .semibold),
            color: NSColor(srgbRed: 240 / 255, green: 240 / 255, blue: 244 / 255, alpha: 1)
        )
        field = NSTextField(string: current?.displayName ?? "")
        field.placeholderString = folderName
        field.font = ShellFont.ui(13)
        field.textColor = NSColor(srgbRed: 240 / 255, green: 240 / 255, blue: 244 / 255, alpha: 1)
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        captionLabel = Self.label(
            "Leave blank to use \(folderName)",
            font: ShellFont.ui(11.5),
            color: ShellPalette.inkMuted
        )
        captionLabel.alignment = .left
        selectedColor = current?.color
        cancelButton = PaneApprovalButton(
            title: "Cancel",
            isPrimary: false,
            tint: PaneAskOverlayView.accent
        )
        saveButton = PaneApprovalButton(
            title: "Save",
            isPrimary: true,
            tint: PaneAskOverlayView.accent
        )
        if #available(macOS 26.0, *) {
            let pane = NSGlassEffectView()
            pane.style = .regular
            pane.tintColor = nil
            scrim = pane
            let card = NSGlassEffectView()
            card.style = .regular
            card.cornerRadius = Self.cardRadius
            card.tintColor = nil
            cardGlass = card
        } else {
            scrim = nil
            cardGlass = nil
        }
        super.init(frame: .zero)
        wantsLayer = true

        fieldWell.wantsLayer = true
        fieldWell.layer?.backgroundColor = NSColor(white: 1, alpha: 0.08).cgColor
        fieldWell.layer?.cornerRadius = 8
        fieldWell.layer?.cornerCurve = .continuous
        fieldWell.layer?.borderWidth = 1
        fieldWell.layer?.borderColor = NSColor(white: 1, alpha: 0.16).cgColor

        cardTint.wantsLayer = true
        cardTintLayer.colors = Self.navyTint
        cardTintLayer.startPoint = CGPoint(x: 0.5, y: 1)
        cardTintLayer.endPoint = CGPoint(x: 0.5, y: 0)
        cardTint.layer?.addSublayer(cardTintLayer)
        cardTint.layer?.cornerRadius = Self.cardRadius
        cardTint.layer?.cornerCurve = .continuous
        cardTint.layer?.masksToBounds = true
        cardTint.layer?.borderWidth = 1
        cardTint.layer?.borderColor = NSColor(white: 1, alpha: 0.16).cgColor

        swatches = WorkspaceColor.allCases.map { color in
            let swatch = WorkspaceColorSwatchView(color: color, selected: color == selectedColor)
            swatch.onPick = { [weak self] in
                guard let self else { return }
                // Clicking the chosen swatch clears it — back to the
                // default folder tint, without needing a ninth "none" chip.
                selectColor(selectedColor == color ? nil : color)
            }
            return swatch
        }

        cancelButton.onClick = { [weak self] in self?.cancel() }
        saveButton.onClick = { [weak self] in self?.save() }
        field.delegate = self

        for view in [scrim, cardGlass, cardTint, titleLabel, fieldWell, field, captionLabel]
            .compactMap({ $0 }) + (swatches as [NSView]) + [cancelButton, saveButton]
        {
            addSubview(view)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Customize Workspace")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    private static func label(_ text: String, font: NSFont, color: NSColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = font
        field.textColor = color
        field.alignment = .center
        field.lineBreakMode = .byTruncatingTail
        return field
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    /// Selects everything in the field, so a stored name is replaced by the
    /// first keystroke rather than appended to.
    func selectInput() { field.currentEditor()?.selectAll(nil) }

    /// Types into the card's field, for tests — the production path is the
    /// field editor, which a test has no window focus to drive.
    func type(_ value: String) { field.stringValue = value }

    /// Chooses a swatch (or none) — the one path clicks and tests share.
    func selectColor(_ color: WorkspaceColor?) {
        selectedColor = color
        for swatch in swatches {
            swatch.isSelected = swatch.color == color
        }
    }

    func save() {
        guard !isAnswered else { return }
        isAnswered = true
        let trimmed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        onSave?(
            WorkspaceCustomization(
                displayName: trimmed.isEmpty ? nil : trimmed,
                color: selectedColor
            )
        )
    }

    func cancel() {
        guard !isAnswered else { return }
        isAnswered = true
        onCancel?()
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: save() // Return, Enter
        case 53: cancel() // Esc
        default: NSSound.beep()
        }
    }

    /// A click on the glass is a cancel; inside the card it is swallowed.
    override func mouseDown(with event: NSEvent) {
        guard !cardFrame.contains(convert(event.locationInWindow, from: nil)) else { return }
        cancel()
    }

    override func layout() {
        super.layout()
        scrim?.frame = bounds
        let padding = Self.padding
        let width = min(Self.cardWidth, max(200, bounds.width - 32))
        let content = width - padding * 2
        let titleHeight = ceil(titleLabel.intrinsicContentSize.height)
        let captionHeight = ceil(captionLabel.intrinsicContentSize.height)
        let height = padding + titleHeight + 16 + Self.fieldHeight + 6 + captionHeight
            + 16 + WorkspaceColorSwatchView.side + 20 + Self.buttonHeight + padding
        cardFrame = NSRect(
            x: ((bounds.width - width) / 2).rounded(),
            y: max(0, ((bounds.height - height) / 2)).rounded(),
            width: width,
            height: height
        )
        cardGlass?.frame = cardFrame
        cardTint.frame = cardFrame
        cardTintLayer.frame = cardTint.bounds

        var y = cardFrame.minY + padding
        titleLabel.frame = NSRect(x: cardFrame.minX + padding, y: y, width: content, height: titleHeight)
        y += titleHeight + 16
        fieldWell.frame = NSRect(x: cardFrame.minX + padding, y: y, width: content, height: Self.fieldHeight)
        let line = ceil(field.intrinsicContentSize.height)
        field.frame = NSRect(
            x: fieldWell.frame.minX + Self.fieldInset,
            y: fieldWell.frame.minY + ((Self.fieldHeight - line) / 2).rounded(),
            width: content - Self.fieldInset * 2,
            height: line
        )
        y += Self.fieldHeight + 6
        captionLabel.frame = NSRect(
            x: cardFrame.minX + padding,
            y: y,
            width: content,
            height: captionHeight
        )
        y += captionHeight + 16
        let side = WorkspaceColorSwatchView.side
        let rowWidth = CGFloat(swatches.count) * side + CGFloat(max(0, swatches.count - 1)) * Self.swatchGap
        var x = (cardFrame.midX - rowWidth / 2).rounded()
        for swatch in swatches {
            swatch.frame = NSRect(x: x, y: y, width: side, height: side)
            x += side + Self.swatchGap
        }
        y += side + 20
        let gap: CGFloat = 9
        let widths = [cancelButton, saveButton].map { $0.intrinsicContentSize.width }
        let total = widths.reduce(0, +) + gap
        var buttonX = cardFrame.midX - total / 2
        for (button, buttonWidth) in zip([cancelButton, saveButton], widths) {
            button.frame = NSRect(x: buttonX, y: y, width: buttonWidth, height: Self.buttonHeight)
            buttonX += buttonWidth + gap
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // Only before macOS 26 — see `PaneAskOverlayView.draw`.
        guard scrim == nil else { return }
        NSColor(white: 0, alpha: 0.62).setFill()
        bounds.fill()
        let card = NSBezierPath(
            roundedRect: cardFrame,
            xRadius: Self.cardRadius,
            yRadius: Self.cardRadius
        )
        NSColor(srgbRed: 0.09, green: 0.12, blue: 0.26, alpha: 1).setFill()
        card.fill()
        NSColor(white: 1, alpha: 0.16).setStroke()
        let ring = NSBezierPath(
            roundedRect: cardFrame.insetBy(dx: 0.5, dy: 0.5),
            xRadius: Self.cardRadius,
            yRadius: Self.cardRadius
        )
        ring.lineWidth = 1
        ring.stroke()
    }
}

/// Return and Esc while the field holds the keyboard — `PaneAskOverlayView`'s
/// delegate, for the same reason: the field editor swallows both otherwise.
extension WorkspaceCustomizeCard: NSTextFieldDelegate {
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            save()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            cancel()
            return true
        default:
            return false
        }
    }
}
