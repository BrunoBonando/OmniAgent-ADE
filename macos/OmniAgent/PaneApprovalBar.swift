import AppKit

/// The dialog an engine is blocked on, read off the terminal screen: the
/// question line and the numbered options under it. Claude's selection dialogs
/// all share the "Esc to cancel" footer and `N. label` option rows, and a bare
/// digit keystroke activates that option outright (measured against Claude
/// Code 2.1.234 — pressing "2" answered an AskUserQuestion with no Enter).
struct ApprovalPrompt: Equatable {
    struct Option: Equatable {
        let number: Int
        let label: String
    }

    var question: String?
    var options: [Option]

    /// Reads the dialog out of the screen's tail lines, bottom-up: find the
    /// footer, collect `N. label` rows above it, and stop at the question —
    /// the nearest line above the options that ends in `?`. Returns nil when
    /// no options are on screen (the bar then falls back to Approve/Deny).
    static func parse(lines: [String]) -> ApprovalPrompt? {
        let footer = lines.lastIndex { $0.contains("Esc to cancel") } ?? lines.count
        // ponytail: 24 lines is deeper than any dialog Claude renders today
        let region = lines[..<footer].suffix(24)
        var byNumber: [Int: String] = [:]
        var question: String?
        for line in region.reversed() {
            if let option = Self.option(from: line) {
                // Scanning upward, the row nearest the footer wins — anything
                // further up with the same number is older output.
                if byNumber[option.number] == nil {
                    byNumber[option.number] = option.label
                }
            } else if !byNumber.isEmpty, line.trimmingCharacters(in: .whitespaces).hasSuffix("?") {
                question = line.trimmingCharacters(in: .whitespaces)
                break
            }
        }
        guard !byNumber.isEmpty else { return nil }
        let options = byNumber.keys.sorted().prefix(9).map {
            Option(number: $0, label: byNumber[$0] ?? "")
        }
        return ApprovalPrompt(question: question, options: Array(options))
    }

    /// `❯ 1. Yes` / `  2. No, and tell Claude what to do differently`.
    private static func option(from line: String) -> Option? {
        var rest = Substring(line).drop { $0 == " " || $0 == "❯" }
        let digits = rest.prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count <= 2, let number = Int(digits) else { return nil }
        rest = rest.dropFirst(digits.count)
        guard rest.first == "." else { return nil }
        let label = rest.dropFirst().trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty else { return nil }
        return Option(number: number, label: label)
    }
}

/// The design's amber approval strip along a pane's bottom edge: the question
/// on the left, one button per on-screen option on the right — the first
/// filled amber, the rest outlined. With no options parsed it degrades to
/// Approve (Enter confirms the dialog's highlighted default) and Deny (Esc).
final class PaneApprovalBarView: NSView {
    static let height: CGFloat = 42
    static let amber = NSColor(srgbRed: 240 / 255, green: 180 / 255, blue: 70 / 255, alpha: 1)

    /// What each button writes to the PTY: the option's digit, or Enter/Esc
    /// for the fallback pair.
    var onChoose: ((String) -> Void)?

    var prompt: ApprovalPrompt? {
        didSet {
            guard prompt != oldValue else { return }
            rebuild()
        }
    }

    private let questionLabel = NSTextField(labelWithString: "")
    private var buttons: [PaneApprovalButton] = []

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Self.background.cgColor
        questionLabel.font = ShellFont.ui(13.5, .semibold)
        questionLabel.textColor = Self.amber
        questionLabel.lineBreakMode = .byTruncatingTail
        questionLabel.maximumNumberOfLines = 1
        addSubview(questionLabel)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Needs your input")
        rebuild()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override var isFlipped: Bool { true }

    /// The design's bar background, precomposited opaque: amber at 9% over the
    /// pane background — the bar sits on the container, whose backing colour
    /// is the border ring's.
    private static let background = NSColor(
        srgbRed: 33 / 255,
        green: 27 / 255,
        blue: 20 / 255,
        alpha: 1
    )

    override func draw(_ dirtyRect: NSRect) {
        // The design's `.5px` amber top border.
        Self.amber.withAlphaComponent(0.28).setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }

    private func rebuild() {
        buttons.forEach { $0.removeFromSuperview() }
        buttons = []
        let question = prompt?.question ?? "Needs your input"
        questionLabel.stringValue = question
        setAccessibilityLabel(question)
        let choices: [(title: String, input: String)]
        if let options = prompt?.options, !options.isEmpty {
            choices = options.map { (Self.buttonTitle($0.label), String($0.number)) }
        } else {
            choices = [("Approve", "\r"), ("Deny", "\u{1b}")]
        }
        for (index, choice) in choices.enumerated() {
            let button = PaneApprovalButton(title: choice.title, isPrimary: index == 0)
            button.onClick = { [weak self] in self?.onChoose?(choice.input) }
            addSubview(button)
            buttons.append(button)
        }
        needsLayout = true
    }

    private static func buttonTitle(_ label: String) -> String {
        label.count <= 28 ? label : label.prefix(27) + "…"
    }

    override func layout() {
        super.layout()
        let padding: CGFloat = 10
        let gap: CGFloat = 9
        let buttonHeight: CGFloat = 26
        let y = (bounds.height - buttonHeight) / 2
        // Buttons lay right-to-left from the trailing edge; ones that would
        // crowd the question out are dropped whole, the way the header drops
        // its badges. The question keeps at least a readable share.
        var x = bounds.width - padding
        let minQuestion: CGFloat = 60
        for button in buttons.reversed() {
            let width = button.intrinsicContentSize.width
            let fits = x - width - gap >= padding + minQuestion
            button.isHidden = !fits
            guard fits else { continue }
            x -= width
            button.frame = NSRect(x: x, y: y, width: width, height: buttonHeight)
            x -= gap
        }
        questionLabel.frame = NSRect(
            x: padding,
            y: (bounds.height - questionLabel.intrinsicContentSize.height) / 2,
            width: max(0, x - padding),
            height: questionLabel.intrinsicContentSize.height
        )
    }
}

/// One button in the approval bar — the design's filled-amber primary or
/// outlined secondary pill.
final class PaneApprovalButton: NSView {
    let title: String
    let isPrimary: Bool
    /// What a primary button is filled with. Amber in the approval bar, where
    /// it means "an agent is waiting"; the pane accent in a pane ask, which is
    /// a choice rather than a warning (see `PaneAskOverlayView`).
    let tint: NSColor
    var onClick: (() -> Void)?

    private var isHovered = false { didSet { needsDisplay = true } }
    private var isPressed = false { didSet { needsDisplay = true } }
    /// Set by whichever of the two paths below saw the mouse-up first, so a
    /// click never fires twice.
    private var clickHandled = false
    private var tracking: NSTrackingArea?

    init(title: String, isPrimary: Bool, tint: NSColor = PaneApprovalBarView.amber) {
        self.title = title
        self.isPrimary = isPrimary
        self.tint = tint
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
        toolTip = title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    private var font: NSFont { ShellFont.ui(13.5, isPrimary ? .semibold : .medium) }

    override var intrinsicContentSize: NSSize {
        let text = (title as NSString).size(withAttributes: [.font: font])
        return NSSize(width: ceil(text.width) + 22, height: 26)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        // `.inVisibleRect` keeps the hover region correct through the bar's
        // relayouts, which move these buttons on every rebuild — and it is why
        // the pointing hand rides on `.cursorUpdate` rather than a cursor rect:
        // cursor rects are frames the window caches, and every one of these
        // buttons is laid out by hand and moves.
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .cursorUpdate, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        tracking = area
    }

    override func cursorUpdate(with event: NSEvent) { NSCursor.pointingHand.set() }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// How long the press below waits for its own mouse-up before giving up
    /// and leaving the job to `mouseUp`. Longer than any click, short enough
    /// that a lost-up event cannot wedge the view.
    private static let pressTimeout: TimeInterval = 1.5

    /// The click is swallowed here so it never falls through to pane focus
    /// handling — and then *tracked* here rather than being left to arrive as
    /// `mouseUp`, because a view that eats a mouse-down only hears the
    /// matching mouse-up if AppKit routes it back, and in the app it did not:
    /// the bar drew, hovered and hit-tested correctly while every click on it
    /// did nothing. Pulling the rest of the click off the queue is what a real
    /// button does, and it does not depend on that routing.
    override func mouseDown(with event: NSEvent) {
        clickHandled = false
        isPressed = true
        var inside = true
        while let next = NSApp.nextEvent(
            matching: [.leftMouseUp, .leftMouseDragged],
            until: Date(timeIntervalSinceNow: Self.pressTimeout),
            inMode: .eventTracking,
            dequeue: true
        ) {
            inside = bounds.contains(convert(next.locationInWindow, from: nil))
            isPressed = inside
            guard next.type == .leftMouseUp else { continue }
            isPressed = false
            clickHandled = true
            if inside { onClick?() }
            return
        }
        isPressed = false
    }

    /// The other half of the pair: the mouse-up AppKit routes back on its own,
    /// which is the path a synthesised click takes (nothing enqueues an event
    /// for the loop above to dequeue). `clickHandled` is what stops the two
    /// paths from both firing on one press.
    override func mouseUp(with event: NSEvent) {
        guard !clickHandled else { return }
        clickHandled = true
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClick?()
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return onClick != nil
    }

    override func draw(_ dirtyRect: NSRect) {
        let pill = NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6)
        let textColor: NSColor
        if isPrimary {
            var fill = tint
            if isPressed {
                fill = fill.blended(withFraction: 0.18, of: .black) ?? fill
            } else if isHovered {
                fill = fill.blended(withFraction: 0.1, of: .white) ?? fill
            }
            fill.setFill()
            pill.fill()
            // The label is the fill taken almost to black rather than one
            // hardcoded brown: both tints this button wears are light enough
            // to need dark text, and each keeps its own hue doing it.
            textColor = tint.blended(withFraction: 0.86, of: .black) ?? .black
        } else {
            if isPressed || isHovered {
                NSColor(white: 1, alpha: isPressed ? 0.16 : 0.08).setFill()
                pill.fill()
            }
            NSColor(white: 1, alpha: 0.16).setStroke()
            let stroke = NSBezierPath(
                roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                xRadius: 6,
                yRadius: 6
            )
            stroke.lineWidth = 1
            stroke.stroke()
            textColor = NSColor(srgbRed: 194 / 255, green: 194 / 255, blue: 203 / 255, alpha: 1)
        }
        let text = title as NSString
        let size = text.size(withAttributes: [.font: font])
        text.draw(
            at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2),
            withAttributes: [.font: font, .foregroundColor: textColor]
        )
    }
}
