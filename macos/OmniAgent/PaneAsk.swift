import AppKit

// The pane ask: the one modal a pane puts over itself when it must have an
// answer before it can go on. See `PaneAskOverlayView` below for what belongs
// in one, and `PaneContainerView.presentAsk` (PaneWorkspaceView.swift) for the
// entry point — the overlay's stored state lives on the container, which is
// why the two halves are not in one file.

/// One answer on a **pane ask** — the label, and what pressing it does.
///
/// The action is handed whatever is in the card's text field, or `""` on an
/// ask that has none: one signature covers "are you sure?" and "what should it
/// be called?", rather than a second option type for the half with a field.
struct PaneAskOption {
    let title: String
    /// The filled accent button. At most one per ask, always drawn rightmost,
    /// and the one Return activates.
    let isPrimary: Bool
    let action: (String) -> Void

    init(_ title: String, isPrimary: Bool = false, action: @escaping (String) -> Void) {
        self.title = title
        self.isPrimary = isPrimary
        self.action = action
    }
}

/// # Pane ask
///
/// The one way a pane asks a question that must be answered before it can go
/// on: the pane itself goes behind Liquid Glass and the question sits in the
/// middle of it. Which of twelve panes is asking is then answered by *where
/// the card is*, before a word of it is read.
///
/// Deliberately not an `NSAlert`. A sheet hangs off the window and says
/// nothing about which pane it means — and what is being decided (this
/// terminal's conversation, this editor's unsaved buffer) is on screen right
/// behind the glass, which is the whole argument for the decision.
///
/// **Every blocking pane-scoped question goes through here**: swapping a
/// terminal's engine, renaming a conversation, closing an editor tab over
/// unsaved edits, a file that changed on disk under a dirty buffer. Anything
/// new that the user must answer before *their pane* can continue belongs here
/// too, not in an alert — a close-pane confirmation, say, is
/// `container.presentAsk(title:message:icon:options:)` and nothing else.
///
/// `PaneContainerView.presentAsk` is the whole entry point: it reveals the
/// pane, hands the card the keyboard, and guarantees the caller hears back
/// exactly once. Pass `input:` to get a text field, and the answer arrives as
/// the chosen option's argument.
/// Window-scoped questions (quitting, "which pane should this link open in?")
/// are not pane asks and stay alerts — they are not about one pane.
///
/// Two deliberate departures from the amber card this replaced. The glass is
/// navy, the same wash Spotlight (`CommandPaletteController`) wears, because
/// amber in this app means "an agent is blocked and waiting" and a question
/// about the user's own next move is not that. And the icon is the *subject*
/// of the question — the engine being switched to, the file about to be lost —
/// not a warning triangle, which said "danger" where the answer is a choice.
final class PaneAskOverlayView: NSView {
    /// Esc, or a click on the glass outside the card — the way clicking
    /// outside a popover dismisses it.
    var onCancel: (() -> Void)?

    /// The answers, left to right as they are drawn.
    private(set) var options: [PaneAskOption]

    /// The pane accent, not the approval bar's amber. See the note above.
    static let accent = NSColor(srgbRed: 139 / 255, green: 149 / 255, blue: 255 / 255, alpha: 1)

    private static let cardWidth: CGFloat = 330
    private static let padding: CGFloat = 22
    private static let iconSize: CGFloat = 30
    private static let buttonHeight: CGFloat = 26
    private static let fieldHeight: CGFloat = 28
    private static let cardRadius: CGFloat = 16

    /// The glass, on macOS 26. Two panels: the pane-sized one that puts the
    /// pane behind glass, and the card's own. `nil` before 26, where `draw`
    /// paints flat navy instead — every pre-26 stand-in for glass inside one
    /// window's compositing tree is a flat tint with no blur anyway (see
    /// `PaneZoomBackdropView`), so it may as well be an honest fill.
    private let scrim: NSView?
    private let cardGlass: NSView?
    /// The navy wash over the card's glass, as its own view so it can sit
    /// between the glass and the text. Spotlight's construction exactly:
    /// `.regular` glass with a gradient tint in front of it, rather than the
    /// glass view's flat `tintColor`.
    private let cardTint = NSView()
    private let cardTintLayer = CAGradientLayer()
    /// Spotlight's own navy, top-down, copied rather than shared: the palette
    /// is a separate window with a separate life, and reaching into it for two
    /// colours would tie a pane's overlay to whatever that panel does next.
    private static let navyTint = [
        NSColor(srgbRed: 0.11, green: 0.16, blue: 0.38, alpha: 0.40).cgColor,
        NSColor(srgbRed: 0.05, green: 0.08, blue: 0.22, alpha: 0.14).cgColor,
    ]
    /// The subject of the question, for the test that the right one is shown.
    var icon: NSImage? { iconView.image }

    /// What is typed in, or `""` on an ask with no field.
    var text: String { field?.stringValue ?? "" }

    /// Who should hold the keyboard while this is up — the field when there is
    /// one, so a rename can be typed the moment it opens.
    var firstResponderView: NSView { field ?? self }

    private let iconView = NSImageView()
    private let titleLabel: NSTextField
    private let messageLabel: NSTextField
    private let field: NSTextField?
    private let buttons: [PaneApprovalButton]
    private var cardFrame: NSRect = .zero
    /// One answer per card, whichever route it arrives by. Return in the field
    /// and a click on the primary button are two paths to the same option, and
    /// a caller's completion may only be called once.
    private var isAnswered = false

    init(title: String, message: String, icon: NSImage?, input: String?, options: [PaneAskOption]) {
        self.options = options
        field = input.map { seed in
            let field = NSTextField(string: seed)
            field.font = ShellFont.ui(13)
            field.textColor = NSColor(srgbRed: 240 / 255, green: 240 / 255, blue: 244 / 255, alpha: 1)
            field.isBezeled = false
            field.drawsBackground = true
            field.backgroundColor = NSColor(white: 1, alpha: 0.08)
            field.focusRingType = .none
            field.wantsLayer = true
            field.layer?.cornerRadius = 7
            field.layer?.cornerCurve = .continuous
            field.layer?.masksToBounds = true
            field.layer?.borderWidth = 1
            field.layer?.borderColor = NSColor(white: 1, alpha: 0.16).cgColor
            return field
        }
        titleLabel = Self.label(title, font: ShellFont.ui(15, .semibold), color: NSColor(
            srgbRed: 240 / 255, green: 240 / 255, blue: 244 / 255, alpha: 1
        ))
        messageLabel = Self.label(message, font: ShellFont.ui(13), color: NSColor(
            srgbRed: 176 / 255, green: 180 / 255, blue: 198 / 255, alpha: 1
        ))
        buttons = options.map {
            PaneApprovalButton(title: $0.title, isPrimary: $0.isPrimary, tint: Self.accent)
        }
        if #available(macOS 26.0, *) {
            let pane = NSGlassEffectView()
            // `.clear`, untinted — the same call focus mode makes, for the same
            // reason: the pane behind the question is glassed, not coloured and
            // not dimmed. A tint here is a wash over everything behind the
            // panel, which puts the card's navy on the surroundings too.
            pane.style = .clear
            pane.tintColor = nil
            scrim = pane
            let card = NSGlassEffectView()
            card.style = .regular
            card.cornerRadius = Self.cardRadius
            // No tint: `cardTint` is the card's colour, gradient like Spotlight's.
            card.tintColor = nil
            cardGlass = card
        } else {
            scrim = nil
            cardGlass = nil
        }
        super.init(frame: .zero)
        wantsLayer = true
        iconView.image = icon
        // Only reaches the template engine marks (Shell, Copilot) and the SF
        // symbols the editor asks with; the colour brand logos ignore it.
        iconView.contentTintColor = NSColor(white: 1, alpha: 0.92)
        iconView.imageScaling = .scaleProportionallyUpOrDown
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
        for (index, button) in buttons.enumerated() {
            button.onClick = { [weak self] in self?.choose(index) }
        }
        field?.delegate = self
        for view in [scrim, cardGlass, cardTint, iconView, titleLabel, messageLabel, field]
            .compactMap({ $0 }) + (buttons as [NSView])
        {
            addSubview(view)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(title)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    private static func label(_ text: String, font: NSFont, color: NSColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = font
        field.textColor = color
        field.alignment = .center
        field.lineBreakMode = .byWordWrapping
        field.maximumNumberOfLines = 0
        return field
    }

    override var isFlipped: Bool { true }

    /// The card takes the keyboard while it is up, so Return and Esc answer
    /// it and nothing else reaches the pane underneath — a question about
    /// throwing work away must not be answered by typing into it.
    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: submit() // Return, Enter
        case 53: cancel() // Esc
        default: NSSound.beep()
        }
    }

    /// Types into the card's field, for tests — the production path is the
    /// field editor, which a test has no window focus to drive.
    func type(_ value: String) { field?.stringValue = value }

    /// Runs answer `index` — the one path every button, Return and the field
    /// share, so the one-shot guard is written once.
    func choose(_ index: Int) {
        guard !isAnswered, options.indices.contains(index) else { return }
        isAnswered = true
        options[index].action(text)
    }

    /// Return: the primary answer, or a beep on a card that has none.
    private func submit() {
        guard let index = options.firstIndex(where: \.isPrimary) else { return NSSound.beep() }
        choose(index)
    }

    private func cancel() {
        guard !isAnswered else { return }
        isAnswered = true
        onCancel?()
    }

    /// A click on the glass is a cancel. Inside the card it is swallowed and
    /// nothing else.
    override func mouseDown(with event: NSEvent) {
        guard !cardFrame.contains(convert(event.locationInWindow, from: nil)) else { return }
        cancel()
    }

    override func layout() {
        super.layout()
        scrim?.frame = bounds
        let padding = Self.padding
        let width = min(Self.cardWidth, max(160, bounds.width - 32))
        let content = width - padding * 2
        let titleHeight = Self.height(of: titleLabel, width: content)
        let messageHeight = Self.height(of: messageLabel, width: content)
        let fieldBlock = field == nil ? 0 : Self.fieldHeight + 14
        let height = padding + Self.iconSize + 12 + titleHeight + 8 + messageHeight
            + 18 + fieldBlock + Self.buttonHeight + padding
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
        iconView.frame = NSRect(
            x: cardFrame.midX - Self.iconSize / 2,
            y: y,
            width: Self.iconSize,
            height: Self.iconSize
        )
        y += Self.iconSize + 12
        titleLabel.frame = NSRect(x: cardFrame.minX + padding, y: y, width: content, height: titleHeight)
        y += titleHeight + 8
        messageLabel.frame = NSRect(x: cardFrame.minX + padding, y: y, width: content, height: messageHeight)
        y += messageHeight + 18
        if let field {
            field.frame = NSRect(
                x: cardFrame.minX + padding,
                y: y,
                width: content,
                height: Self.fieldHeight
            )
            y += Self.fieldHeight + 14
        }
        // Given order, left to right, with the primary last — where every
        // macOS dialog puts the button you are most likely to want, so the
        // muscle memory is already correct.
        let gap: CGFloat = 9
        let widths = buttons.map { $0.intrinsicContentSize.width }
        let total = widths.reduce(0, +) + gap * CGFloat(max(0, buttons.count - 1))
        var x = cardFrame.midX - total / 2
        for (button, buttonWidth) in zip(buttons, widths) {
            button.frame = NSRect(x: x, y: y, width: buttonWidth, height: Self.buttonHeight)
            x += buttonWidth + gap
        }
    }

    /// Wrapped-text height, measured off the string rather than asked of the
    /// cell: the message is two or three lines and the card's height is built
    /// from it, so it has to be right before the field is ever laid out.
    private static func height(of field: NSTextField, width: CGFloat) -> CGFloat {
        let font = field.font ?? ShellFont.ui(13)
        let rect = (field.stringValue as NSString).boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        )
        return ceil(rect.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // Only before macOS 26, where there is no glass to ask for. With the
        // panels present this would be painting *behind* them, and the scrim
        // samples the window backing — so it would darken its own input.
        guard scrim == nil else { return }
        // Neutral, not navy: only the card is tinted.
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

/// The one sheet of glass this app lays over the workspace.
///
/// Focus mode's backdrop and the spotlight's surround are the same material at
/// the same strength, from here — they are the same gesture ("push the
/// workspace back, keep it readable") and had drifted into two settings of it.
///
/// `.clear`, untinted, and just short of full strength. `strength` is the one
/// knob, and it was found by walking it: at `1` the material frosts hard enough
/// that you stop recognising which pane is which, and at `0.62` so much of the
/// sharp original comes back through that it reads as a transparent wash rather
/// than as glass. `0.85` is the frost that still leaves the workspace legible.
enum WorkspaceGlass {
    static let strength: CGFloat = 0.85

    /// The sheet, or `nil` before macOS 26 — where there is no glass to ask
    /// for and every stand-in dims rather than refracts, so the callers leave
    /// it out entirely.
    static func sheet(cornerRadius: CGFloat = 0) -> NSView? {
        guard #available(macOS 26.0, *) else { return nil }
        let glass = NSGlassEffectView()
        glass.style = .clear
        // Explicitly none: a tint is a wash of colour over everything behind
        // the sheet, which is exactly the darkening this exists without.
        glass.tintColor = nil
        glass.cornerRadius = cornerRadius
        glass.alphaValue = strength
        return glass
    }
}

/// Return and Esc while the text field holds the keyboard. Without this they
/// are the field editor's business and never reach `keyDown` — a rename you
/// could type and not commit.
extension PaneAskOverlayView: NSTextFieldDelegate {
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            submit()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            cancel()
            return true
        default:
            return false
        }
    }
}
