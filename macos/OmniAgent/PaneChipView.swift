import AppKit

/// A pane, drawn small enough to be worth drawing at all.
///
/// Below `DeskCanvas.lodThreshold` a pane's surface carries no information —
/// at 0.2 a 12pt glyph is 2.4pt — so the surface comes down and this takes its
/// place.
///
/// What it draws is the pane's **kind**, not a generic badge: a terminal reads
/// as a terminal, a browser as a browser, an editor as a file. At this size
/// nobody can read a title, but everybody can tell a window of code from a
/// window of output from a web page — shape and rhythm survive the shrink that
/// text does not, and shape is what lets you find the pane you are looking for
/// from across the canvas.
///
/// A **fourth sibling** of the container's header/surface/approvalBar rather
/// than a replacement surface. `PaneContainerView.surface` is
/// `let surface: any PaneContentView`, and a live terminal swapped out of the
/// view tree is one that has to be rebuilt — with its scrollback — to come
/// back.
///
/// Drawn rather than composed, the way `PaneHolePlaceholderView` is: static
/// content in a box whose size changes with the camera, where each piece as a
/// subview would need its own frame maths for nothing.
final class PaneChipView: NSView {
    /// Everything here is a fraction of the chip's own box, never a point
    /// size. The camera scales the whole card, so a fixed 12pt label is 1.8pt
    /// on screen at the scale this view exists for — the same trap the surface
    /// it replaces falls into.
    private static let headerFraction: CGFloat = 0.17
    private static let iconFraction: CGFloat = 0.62
    private static let dotFraction: CGFloat = 0.34
    private static let padFraction: CGFloat = 0.045
    private static let rowFraction: CGFloat = 0.075
    private static let rowGapFraction: CGFloat = 0.055

    /// Ragged on purpose, and fixed rather than random: an even stack of bars
    /// reads as a loading skeleton — the universal "nothing here yet" — and
    /// this pane is running. Uneven line lengths are what say "output".
    /// Deterministic so a chip does not reshuffle itself on every repaint.
    private static let terminalRows: [CGFloat] = [0.86, 0.54, 0.72, 0.4, 0.63, 0.31]
    private static let editorRows: [(indent: CGFloat, width: CGFloat)] = [
        (0, 0.62), (0.12, 0.78), (0.12, 0.45), (0.24, 0.66), (0.12, 0.5), (0, 0.7),
    ]

    private static let inkStrong = NSColor(white: 1, alpha: 0.34)
    private static let inkMedium = NSColor(white: 1, alpha: 0.2)
    private static let inkFaint = NSColor(white: 1, alpha: 0.11)
    private static let surface = NSColor(white: 1, alpha: 0.05)
    /// The one saturated mark on the chip: a terminal's prompt caret. Spending
    /// the colour in exactly one place is what keeps a canvas of ninety-six
    /// chips from reading as confetti.
    private static let prompt = NSColor(srgbRed: 0.44, green: 0.78, blue: 0.62, alpha: 0.85)

    var title = "" {
        didSet {
            guard title != oldValue else { return }
            needsDisplay = true
        }
    }

    /// `nil` for a browser or an editor. Both carry `.shell` as a placeholder
    /// engine, and a chip showing that badge would claim the pane runs
    /// something it does not — the header already refuses it for this reason.
    var engine: Engine? {
        didSet {
            guard engine != oldValue else { return }
            needsDisplay = true
        }
    }

    /// Which of the three placeholders to draw.
    var kind: PaneKind = .terminal {
        didSet {
            guard kind != oldValue else { return }
            needsDisplay = true
        }
    }

    var status: RemoteSessionStatus? {
        didSet {
            guard status != oldValue else { return }
            needsDisplay = true
        }
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = PaneContainerView.paneBackgroundColor.cgColor
        // The container's own accessibility label already names this pane; a
        // second element for the same pane is noise to a screen reader.
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    /// Matching `PaneContainerView` and `PaneBadgeView`, both flipped — the
    /// icon draw below is the same call `PaneBadgeView` makes in a flipped view.
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard bounds.width > 2, bounds.height > 2 else { return }
        let pad = bounds.width * Self.padFraction
        let headerHeight = bounds.height * Self.headerFraction
        drawHeader(in: NSRect(x: 0, y: 0, width: bounds.width, height: headerHeight), pad: pad)

        let body = NSRect(
            x: pad,
            y: headerHeight + pad,
            width: max(0, bounds.width - pad * 2),
            height: max(0, bounds.height - headerHeight - pad * 2)
        )
        guard body.width > 1, body.height > 1 else { return }
        switch kind {
        case .terminal: drawTerminal(in: body)
        case .browser: drawBrowser(in: body)
        case .editor: drawEditor(in: body)
        }
    }

    /// The pane's identity strip: the engine's mark, its name, and the status
    /// dot. The same three facts the real header carries, in the same order, so
    /// a chip and the pane it stands for do not read as two different things.
    private func drawHeader(in rect: NSRect, pad: CGFloat) {
        Self.surface.setFill()
        rect.fill()

        var x = pad
        let side = rect.height * Self.iconFraction
        let iconY = rect.midY - side / 2
        if let image = engine?.iconImage {
            image.tinted(engine?.badgeForeground ?? .labelColor).draw(
                in: NSRect(x: x, y: iconY, width: side, height: side)
            )
            x += side + pad
        }

        let dot = rect.height * Self.dotFraction
        PaneStatusMarkView.color(for: status).setFill()
        NSBezierPath(
            ovalIn: NSRect(x: rect.maxX - pad - dot, y: rect.midY - dot / 2, width: dot, height: dot)
        ).fill()

        let font = NSFont.systemFont(ofSize: max(1, rect.height * 0.62), weight: .medium)
        let textHeight = font.boundingRectForFont.height
        let width = max(0, rect.maxX - pad * 2 - dot - x)
        guard width > 1 else { return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        (title as NSString).draw(
            in: NSRect(x: x, y: rect.midY - textHeight / 2, width: width, height: textHeight),
            withAttributes: [
                .font: font,
                .foregroundColor: NSColor(white: 1, alpha: 0.82),
                .paragraphStyle: paragraph,
            ]
        )
    }

    /// Output: a prompt caret and ragged lines under it.
    private func drawTerminal(in rect: NSRect) {
        let row = rect.height * Self.rowFraction
        let gap = rect.height * Self.rowGapFraction
        var y = rect.minY
        let caret = row * 1.4
        Self.prompt.setFill()
        bar(NSRect(x: rect.minX, y: y, width: caret, height: row)).fill()
        Self.inkStrong.setFill()
        bar(NSRect(
            x: rect.minX + caret + row, y: y,
            width: max(0, rect.width * 0.42), height: row
        )).fill()
        y += row + gap

        for fraction in Self.terminalRows {
            guard y + row <= rect.maxY else { return }
            Self.inkFaint.setFill()
            bar(NSRect(x: rect.minX, y: y, width: rect.width * fraction, height: row)).fill()
            y += row + gap
        }
    }

    /// A page: chrome across the top with a location pill, then content.
    private func drawBrowser(in rect: NSRect) {
        let chrome = max(1, rect.height * 0.16)
        Self.surface.setFill()
        panel(NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: chrome)).fill()

        let dot = chrome * 0.34
        var x = rect.minX + dot
        for _ in 0..<3 {
            Self.inkMedium.setFill()
            NSBezierPath(
                ovalIn: NSRect(x: x, y: rect.minY + chrome / 2 - dot / 2, width: dot, height: dot)
            ).fill()
            x += dot * 1.7
        }
        Self.inkFaint.setFill()
        bar(NSRect(
            x: x + dot, y: rect.minY + chrome * 0.22,
            width: max(0, rect.maxX - x - dot * 2), height: chrome * 0.56
        )).fill()

        // One dominant block above two short lines: the shape of a page with a
        // hero on it, which is what a browser pane is far more often than not.
        let top = rect.minY + chrome + rect.height * 0.06
        let blockHeight = rect.height * 0.42
        guard top + blockHeight <= rect.maxY else { return }
        Self.inkFaint.setFill()
        panel(NSRect(x: rect.minX, y: top, width: rect.width, height: blockHeight)).fill()

        let row = rect.height * Self.rowFraction
        var y = top + blockHeight + rect.height * 0.06
        for fraction in [CGFloat(0.78), 0.5] {
            guard y + row <= rect.maxY else { return }
            Self.inkMedium.setFill()
            bar(NSRect(x: rect.minX, y: y, width: rect.width * fraction, height: row)).fill()
            y += row * 1.8
        }
    }

    /// A file: a gutter of line numbers and indented code.
    private func drawEditor(in rect: NSRect) {
        let gutter = rect.width * 0.11
        Self.surface.setFill()
        panel(NSRect(x: rect.minX, y: rect.minY, width: gutter, height: rect.height)).fill()

        let row = rect.height * Self.rowFraction
        let gap = rect.height * Self.rowGapFraction
        let codeLeft = rect.minX + gutter + rect.width * 0.06
        let codeWidth = max(0, rect.maxX - codeLeft)
        var y = rect.minY
        for line in Self.editorRows {
            guard y + row <= rect.maxY else { return }
            Self.inkFaint.setFill()
            bar(NSRect(
                x: rect.minX + gutter * 0.28, y: y,
                width: gutter * 0.44, height: row
            )).fill()
            Self.inkMedium.setFill()
            bar(NSRect(
                x: codeLeft + codeWidth * line.indent, y: y,
                width: codeWidth * line.width, height: row
            )).fill()
            y += row + gap
        }
    }

    /// A bar with ends rounded to its own height, which is what stops a stack of
    /// them reading as a bar chart. Degenerate sizes answer a plain rect rather
    /// than a `NaN` radius.
    /// A panel: a *surface*, not a line, so it is rounded by a small fixed
    /// fraction rather than by its own height. `bar`'s capsule radius on a tall
    /// box turns a browser's content block into a giant pill and a gutter into
    /// a lozenge — shapes that read as controls rather than as a page and a
    /// margin.
    private func panel(_ rect: NSRect) -> NSBezierPath {
        guard rect.width > 0, rect.height > 0 else { return NSBezierPath(rect: rect) }
        let radius = min(min(rect.width, rect.height) * 0.12, 3)
        return NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    }

    private func bar(_ rect: NSRect) -> NSBezierPath {
        guard rect.width > 0, rect.height > 0 else { return NSBezierPath(rect: rect) }
        let radius = min(rect.height / 2, rect.width / 2)
        return NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    }
}
