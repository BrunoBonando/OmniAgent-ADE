import AppKit

// The workspace shell from the "OmniAgent ADE" design doc (design/OmniAgent
// ADE.dc.html, the 2026-08-10 import). A two-level sidebar that slides between
// a workspace picker (Level 1) and the open workspace's navigation (Level 2),
// with the account row pinned outside the sliding track.
//
// Every number in here — inset, corner radius, point size, alpha — is read off
// that document rather than chosen. The design is a web mock, so its `px` are
// CSS pixels, which map 1:1 onto AppKit points; a value that looks oddly
// specific (14.5pt type, .5px hairlines, a 2.5pt selection bar) is specific in
// the drawing too. `ShellPalette`/`ShellMetrics` exist so those constants are
// stated once, next to the rule they came from, instead of being sprinkled
// through twenty view classes.
//
// Deliberately all AppKit: the sidebar is rows, labels, tinted fills and two
// hand-drawn glyph sets, none of which needs a web view next to SwiftTerm.

// MARK: - Destinations

/// Level 2's three destinations, in the design's order.
enum WorkspaceDestination: String, CaseIterable {
    case dashboard
    case board
    case terminals

    var title: String {
        switch self {
        case .dashboard: return "Dashboard"
        case .board: return "Board"
        case .terminals: return "Desk"
        }
    }

    /// The static half of the design's second line. Terminals overrides its
    /// own with live text, so this is only the fallback.
    var subtitle: String {
        switch self {
        case .dashboard: return "activity, tokens, approvals"
        case .board: return "backlog, sprint, timeline"
        case .terminals: return "no session"
        }
    }

    /// The SF Symbol the spotlight draws for this destination. Separate from
    /// `glyph`, which is the sidebar's own hand-drawn vocabulary.
    var paletteSymbol: String {
        switch self {
        case .dashboard: return "chart.bar"
        case .board: return "square.grid.2x2"
        case .terminals: return "rectangle.split.2x2"
        }
    }

    var glyph: ShellGlyph {
        switch self {
        case .dashboard: return .bars
        case .board: return .columns
        case .terminals: return .panes
        }
    }
}

// MARK: - Palette

/// The design doc's dark tokens, once. Deliberately not
/// `NSColor.controlAccentColor` and friends: this window is pinned to
/// `.darkAqua` with its own near-black ground, and the design specifies exact
/// values that must not drift with the user's system accent.
enum ShellPalette {
    static let panel = srgb(23, 23, 26, 0.94)
    static let content = srgb(10, 10, 12)

    static let ink = srgb(240, 240, 244)
    static let inkNav = srgb(176, 176, 186)
    static let inkSecondary = srgb(194, 194, 203)
    static let inkTertiary = srgb(154, 154, 164)
    static let inkFile = srgb(232, 232, 238)
    static let inkFolder = srgb(220, 220, 226)
    static let inkMuted = srgb(101, 101, 111)
    static let inkFaint = srgb(92, 92, 102)
    static let inkFainter = srgb(74, 74, 83)
    static let inkTerminal = srgb(226, 226, 232)

    static let accent = srgb(139, 149, 255)
    static let accentBright = srgb(167, 175, 255)
    static let accentSoft = srgb(139, 149, 255, 0.16)
    static let accentSelection = srgb(139, 149, 255, 0.14)
    static let accentIconTile = srgb(139, 149, 255, 0.28)
    static let accentRail = srgb(139, 149, 255, 0.35)

    static let green = srgb(78, 201, 122)
    static let amber = srgb(240, 180, 70)
    static let red = srgb(242, 85, 90)
    static let blue = srgb(95, 157, 255)
    static let idle = srgb(85, 85, 94)

    static let folderGlyph = srgb(127, 139, 216)
    static let fileGlyph = srgb(139, 139, 149)
    static let chevron = srgb(124, 124, 134)
    static let chevronSoft = srgb(201, 201, 210)

    static let hairline = NSColor(white: 1, alpha: 0.06)
    static let hairlineStrong = NSColor(white: 1, alpha: 0.07)
    static let hover = NSColor(white: 1, alpha: 0.06)
    static let hoverSoft = NSColor(white: 1, alpha: 0.045)
    static let hoverFile = NSColor(white: 1, alpha: 0.05)
    static let rowSelected = NSColor(white: 1, alpha: 0.055)
    static let iconTile = NSColor(white: 1, alpha: 0.06)
    static let cardFill = NSColor(white: 1, alpha: 0.04)
    static let cardFillHover = NSColor(white: 1, alpha: 0.085)
    static let cardStroke = NSColor(white: 1, alpha: 0.09)
    static let cardStrokeHover = NSColor(white: 1, alpha: 0.2)
    static let backRowFill = NSColor(white: 1, alpha: 0.03)
    static let accountFill = NSColor(white: 1, alpha: 0.02)
    static let fieldFill = NSColor(white: 1, alpha: 0.05)
    static let dashedStroke = NSColor(white: 1, alpha: 0.16)

    private static func srgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
    }

    /// The design gives every workspace a 150° two-stop gradient tile. The pair
    /// is picked by the same stable hash `ui/src/state/projectColors.ts` uses,
    /// so a workspace keeps its colour across the two implementations and
    /// across relaunches without anything being persisted.
    static let avatarGradients: [(NSColor, NSColor)] = [
        (srgb(125, 136, 255), srgb(74, 91, 216)),
        (srgb(255, 155, 115), srgb(217, 96, 63)),
        (srgb(99, 209, 168), srgb(47, 143, 109)),
        (srgb(182, 150, 242), srgb(116, 86, 184)),
        (srgb(162, 231, 249), srgb(74, 160, 168)),
        (srgb(237, 129, 195), srgb(174, 71, 134)),
    ]

    /// `Int32` arithmetic with explicit wrapping, matching the JS `| 0` the
    /// TypeScript version relies on — plain `Int` would overflow-trap on a long
    /// id instead of wrapping, and would pick a different colour.
    static func avatarGradient(forID id: String) -> (NSColor, NSColor) {
        var hash: Int32 = 0
        for scalar in id.unicodeScalars {
            hash = hash &* 31 &+ Int32(truncatingIfNeeded: scalar.value)
        }
        let index = Int(hash.magnitude % Int32.Magnitude(avatarGradients.count))
        return avatarGradients[index]
    }

    /// "OmniAgent ADE" -> "OA", "voice" -> "VO". One letter reads as an
    /// accident at the design's 34pt tile.
    static func initials(_ label: String) -> String {
        let words = label.split(whereSeparator: { " -_./".contains($0) })
        if words.count >= 2, let a = words[0].first, let b = words[1].first {
            return "\(a)\(b)".uppercased()
        }
        return String(label.prefix(2)).uppercased()
    }

    static func sessionCountLabel(_ n: Int) -> String {
        switch n {
        case 0: return "no sessions"
        case 1: return "1 session"
        default: return "\(n) sessions"
        }
    }
}

/// Sizes the design states directly. Named rather than inlined because several
/// of them have to agree across view classes (the nav row's 3pt bar and the
/// sessions rail's 18pt indent line up by construction, not by coincidence).
enum ShellMetrics {
    static let sidebarWidth: CGFloat = 238
    /// How far the sidebar may be dragged. `sidebarWidth` is where it opens;
    /// these are the limits it may be dragged between, chosen so the nav rows
    /// still read at the floor and the terminals keep the larger half at the
    /// ceiling.
    static let sidebarMinimumWidth: CGFloat = 190
    static let sidebarMaximumWidth: CGFloat = 460
    static let navRowInset = NSEdgeInsets(top: 8, left: 9, bottom: 8, right: 9)
    static let navBarWidth: CGFloat = 3
    static let navIconTile: CGFloat = 22
    static let sessionRail: CGFloat = 18
    static let sessionRailInset: CGFloat = 10
    static let fileRowHeight: CGFloat = 23
    static let cardTile: CGFloat = 34
    static let backTile: CGFloat = 28
    static let accountAvatar: CGFloat = 22
}

/// The design's slide, and the system's opinion about whether to play it.
enum ShellMotion {
    /// `transition:transform .44s cubic-bezier(.22,.85,.25,1)` on the track.
    static let duration: TimeInterval = 0.44
    static let timing = CAMediaTimingFunction(controlPoints: 0.22, 0.85, 0.25, 1)

    static var reduced: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
}

// MARK: - Typography

enum ShellFont {
    static func ui(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        .systemFont(ofSize: size, weight: weight)
    }

    static func mono(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        .monospacedSystemFont(ofSize: size, weight: weight)
    }

    /// A non-editable, non-drawing `NSTextField` — the only way to get plain
    /// text in AppKit without a cell that paints a background or steals clicks.
    static func label(
        _ text: String = "",
        font: NSFont,
        color: NSColor,
        tracking: CGFloat? = nil
    ) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = font
        field.textColor = color
        field.lineBreakMode = .byTruncatingTail
        field.cell?.truncatesLastVisibleLine = true
        // Every label in this sidebar is one line. Saying so is load-bearing:
        // a wrapping field derives its intrinsic width from
        // `preferredMaxLayoutWidth`, which is 0 here, so a kerned attributed
        // string collapsed to the width of an ellipsis.
        field.usesSingleLineMode = true
        field.cell?.wraps = false
        field.isSelectable = false
        field.translatesAutoresizingMaskIntoConstraints = false
        if let tracking {
            field.attributedStringValue = NSAttributedString(
                string: text,
                attributes: [.font: font, .foregroundColor: color, .kern: tracking]
            )
        }
        return field
    }

    /// Re-applies text to a label built with `tracking:` — plain `stringValue`
    /// would drop the kerning the section headers depend on.
    static func setTracked(_ field: NSTextField, _ text: String, tracking: CGFloat) {
        guard let font = field.font, let color = field.textColor else {
            field.stringValue = text
            return
        }
        field.attributedStringValue = NSAttributedString(
            string: text,
            attributes: [.font: font, .foregroundColor: color, .kern: tracking]
        )
    }
}

// MARK: - Glyphs

/// The design's inline SVGs, drawn rather than bundled. They are all a handful
/// of strokes on a 16 or 24 unit grid, and drawing them keeps the stroke widths
/// and end caps exactly as specified at every size — an exported PNG would not,
/// and an SF Symbol is a different shape.
enum ShellGlyph {
    case chevronRight
    case chevronLeft
    case plus
    case bars
    case columns
    case terminal
    case panes
    case folder
    case file
    case magnifier
    case gear

    /// - Parameter box: the SVG's own viewBox side (16 or 24), so the path can
    ///   be written in the document's coordinates and scaled once here.
    func draw(in rect: NSRect, color: NSColor, lineWidth: CGFloat = 1.6) {
        let box: CGFloat = (self == .bars || self == .columns || self == .terminal || self == .panes) ? 24 : 16
        let scale = min(rect.width, rect.height) / box
        let transform = NSAffineTransform()
        transform.translateX(by: rect.minX, yBy: rect.minY)
        transform.scaleX(by: scale, yBy: -scale)
        transform.translateX(by: 0, yBy: -box)

        NSGraphicsContext.saveGraphicsState()
        transform.concat()
        color.set()
        let path = NSBezierPath()
        path.lineWidth = lineWidth
        path.lineCapStyle = .round
        path.lineJoinStyle = .round

        switch self {
        case .chevronRight:
            path.move(to: NSPoint(x: 6, y: 3.5))
            path.line(to: NSPoint(x: 10.5, y: 8))
            path.line(to: NSPoint(x: 6, y: 12.5))
            path.stroke()
        case .chevronLeft:
            path.move(to: NSPoint(x: 10, y: 3.5))
            path.line(to: NSPoint(x: 5.5, y: 8))
            path.line(to: NSPoint(x: 10, y: 12.5))
            path.stroke()
        case .plus:
            path.move(to: NSPoint(x: 8, y: 3.4))
            path.line(to: NSPoint(x: 8, y: 12.6))
            path.move(to: NSPoint(x: 3.4, y: 8))
            path.line(to: NSPoint(x: 12.6, y: 8))
            path.stroke()
        case .bars:
            for (x, y, h) in [(3.0, 12.5, 8.0), (9.8, 7.0, 13.5), (16.6, 3.5, 17.0)] {
                NSBezierPath(
                    roundedRect: NSRect(x: x, y: y, width: 4.4, height: h),
                    xRadius: 1.5,
                    yRadius: 1.5
                ).fill()
            }
        case .columns:
            for (x, h) in [(3.0, 17.2), (9.5, 11.0), (16.0, 14.4)] {
                NSBezierPath(
                    roundedRect: NSRect(x: x, y: 3.4, width: 5, height: h),
                    xRadius: 1.7,
                    yRadius: 1.7
                ).fill()
            }
        case .terminal:
            let frame = NSBezierPath(
                roundedRect: NSRect(x: 3, y: 4, width: 18, height: 16),
                xRadius: 2.4,
                yRadius: 2.4
            )
            frame.lineWidth = 2
            frame.stroke()
            path.lineWidth = 2
            path.move(to: NSPoint(x: 8, y: 9))
            path.line(to: NSPoint(x: 11, y: 12))
            path.line(to: NSPoint(x: 8, y: 15))
            path.move(to: NSPoint(x: 13, y: 15))
            path.line(to: NSPoint(x: 16, y: 15))
            path.stroke()
        case .panes:
            // A tiled layout, not a terminal: the Desk holds terminals,
            // browsers and editors side by side.
            let outline = NSBezierPath(
                roundedRect: NSRect(x: 3, y: 4, width: 18, height: 16),
                xRadius: 2.4,
                yRadius: 2.4
            )
            outline.lineWidth = 2
            outline.stroke()
            path.lineWidth = 2
            path.move(to: NSPoint(x: 10.5, y: 4))
            path.line(to: NSPoint(x: 10.5, y: 20))
            path.move(to: NSPoint(x: 10.5, y: 12))
            path.line(to: NSPoint(x: 21, y: 12))
            path.stroke()
        case .folder:
            path.move(to: NSPoint(x: 2, y: 4.6))
            path.curve(
                to: NSPoint(x: 3.2, y: 3.4),
                controlPoint1: NSPoint(x: 2, y: 3.9),
                controlPoint2: NSPoint(x: 2.5, y: 3.4)
            )
            path.line(to: NSPoint(x: 5.6, y: 3.4))
            path.line(to: NSPoint(x: 6.8, y: 4.8))
            path.line(to: NSPoint(x: 11.7, y: 4.8))
            path.curve(
                to: NSPoint(x: 13, y: 6.1),
                controlPoint1: NSPoint(x: 12.4, y: 4.8),
                controlPoint2: NSPoint(x: 13, y: 5.4)
            )
            path.line(to: NSPoint(x: 13, y: 11.4))
            path.curve(
                to: NSPoint(x: 11.7, y: 12.6),
                controlPoint1: NSPoint(x: 13, y: 12.1),
                controlPoint2: NSPoint(x: 12.4, y: 12.6)
            )
            path.line(to: NSPoint(x: 3.2, y: 12.6))
            path.curve(
                to: NSPoint(x: 2, y: 11.4),
                controlPoint1: NSPoint(x: 2.5, y: 12.6),
                controlPoint2: NSPoint(x: 2, y: 12.1)
            )
            path.close()
            path.fill()
        case .file:
            path.lineWidth = 1.1
            path.move(to: NSPoint(x: 3.5, y: 2.4))
            path.line(to: NSPoint(x: 8.7, y: 2.4))
            path.line(to: NSPoint(x: 12.5, y: 6.2))
            path.line(to: NSPoint(x: 12.5, y: 13.6))
            path.line(to: NSPoint(x: 3.5, y: 13.6))
            path.close()
            NSColor(white: 1, alpha: 0.05).setFill()
            path.fill()
            color.set()
            path.stroke()
            let fold = NSBezierPath()
            fold.lineWidth = 1.1
            fold.move(to: NSPoint(x: 8.7, y: 2.4))
            fold.line(to: NSPoint(x: 8.7, y: 6.2))
            fold.line(to: NSPoint(x: 12.5, y: 6.2))
            fold.stroke()
        case .magnifier:
            path.lineWidth = 1.3
            path.appendOval(in: NSRect(x: 2.7, y: 2.7, width: 8.6, height: 8.6))
            path.move(to: NSPoint(x: 10.4, y: 10.4))
            path.line(to: NSPoint(x: 13.4, y: 13.4))
            path.stroke()
        case .gear:
            path.lineWidth = 1.2
            path.appendOval(in: NSRect(x: 5.8, y: 5.8, width: 4.4, height: 4.4))
            path.stroke()
            let spokes = NSBezierPath()
            spokes.lineWidth = 1.1
            spokes.lineCapStyle = .round
            let pairs: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
                (8, 1.8, 8, 3.4), (8, 12.6, 8, 14.2),
                (1.8, 8, 3.4, 8), (12.6, 8, 14.2, 8),
                (3.6, 3.6, 4.7, 4.7), (11.3, 11.3, 12.4, 12.4),
                (12.4, 3.6, 11.3, 4.7), (4.7, 11.3, 3.6, 12.4),
            ]
            for (x1, y1, x2, y2) in pairs {
                spokes.move(to: NSPoint(x: x1, y: y1))
                spokes.line(to: NSPoint(x: x2, y: y2))
            }
            spokes.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// A glyph as a view, so it can sit in a stack next to labels.
final class ShellGlyphView: NSView {
    var glyph: ShellGlyph { didSet { needsDisplay = true } }
    var color: NSColor { didSet { needsDisplay = true } }
    var lineWidth: CGFloat = 1.6 { didSet { needsDisplay = true } }
    /// The design rotates the disclosure chevron rather than swapping the art.
    var rotated = false { didSet { needsDisplay = true } }

    init(_ glyph: ShellGlyph, color: NSColor, size: CGFloat, lineWidth: CGFloat = 1.6) {
        self.glyph = glyph
        self.color = color
        self.lineWidth = lineWidth
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: size),
            heightAnchor.constraint(equalToConstant: size),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func draw(_ dirtyRect: NSRect) {
        guard rotated else {
            glyph.draw(in: bounds, color: color, lineWidth: lineWidth)
            return
        }
        NSGraphicsContext.saveGraphicsState()
        let spin = NSAffineTransform()
        spin.translateX(by: bounds.midX, yBy: bounds.midY)
        spin.rotate(byDegrees: -90)
        spin.translateX(by: -bounds.midX, yBy: -bounds.midY)
        spin.concat()
        glyph.draw(in: bounds, color: color, lineWidth: lineWidth)
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// The rounded gradient tile behind a workspace's initials.
final class ShellTileView: NSView {
    private let initialsField: NSTextField
    private var colors: (NSColor, NSColor) = (ShellPalette.accent, ShellPalette.accent)
    private let circular: Bool

    init(size: CGFloat, radius: CGFloat, fontSize: CGFloat, circular: Bool = false) {
        self.circular = circular
        initialsField = ShellFont.label(
            font: ShellFont.ui(fontSize, .bold),
            color: .white
        )
        initialsField.alignment = .center
        initialsField.setContentCompressionResistancePriority(.required, for: .horizontal)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = circular ? size / 2 : radius
        layer?.cornerCurve = .continuous
        translatesAutoresizingMaskIntoConstraints = false
        addSubview(initialsField)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: size),
            heightAnchor.constraint(equalToConstant: size),
            initialsField.centerXAnchor.constraint(equalTo: centerXAnchor),
            initialsField.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func apply(initials: String, gradient: (NSColor, NSColor)) {
        initialsField.stringValue = initials
        colors = gradient
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = circular
            ? NSBezierPath(ovalIn: bounds)
            : NSBezierPath(
                roundedRect: bounds,
                xRadius: layer?.cornerRadius ?? 10,
                yRadius: layer?.cornerRadius ?? 10
            )
        path.addClip()
        // 150° in CSS runs top-left to bottom-right; `NSGradient`'s angle is
        // measured counter-clockwise from east, which puts the same ramp at -60.
        NSGradient(starting: colors.0, ending: colors.1)?.draw(in: bounds, angle: -60)
    }
}

/// The row of 5pt status dots the design puts on every session row.
final class ShellDotsView: NSView {
    private var colors: [NSColor] = []
    /// Indices that breathe — the design animates only the "thinking" dot.
    private var pulsing: Set<Int> = []
    private var widthConstraint: NSLayoutConstraint!

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        widthConstraint = widthAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            widthConstraint,
            heightAnchor.constraint(equalToConstant: 5),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func apply(_ colors: [NSColor], pulsing: Set<Int> = []) {
        self.colors = colors
        self.pulsing = pulsing
        widthConstraint.constant = colors.isEmpty
            ? 0
            : CGFloat(colors.count) * 5 + CGFloat(colors.count - 1) * 2
        rebuildLayers()
        needsDisplay = true
    }

    private func rebuildLayers() {
        layer?.sublayers?.forEach { $0.removeFromSuperlayer() }
        guard !ShellMotion.reduced else { return }
        for index in pulsing where index < colors.count {
            let dot = CALayer()
            dot.frame = NSRect(x: CGFloat(index) * 7, y: 0, width: 5, height: 5)
            dot.cornerRadius = 2.5
            dot.backgroundColor = colors[index].cgColor
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 0.45
            pulse.toValue = 1
            pulse.duration = 0.9
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            dot.add(pulse, forKey: "om-pulse")
            layer?.addSublayer(dot)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        for (index, color) in colors.enumerated() {
            // The pulsing ones are real layers so they can animate; skip them
            // here or they would show through at full opacity underneath.
            if pulsing.contains(index) && !ShellMotion.reduced { continue }
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: CGFloat(index) * 7, y: 0, width: 5, height: 5)).fill()
        }
    }

    /// The design's dot colours, by live session status. Tool execution sits
    /// with thinking in the working family: an agent running a build for five
    /// minutes is *working*, and amber has to mean exactly one thing anywhere
    /// it appears — the agent is waiting on your input.
    static func color(for status: RemoteSessionStatus?) -> NSColor {
        switch status {
        case .thinking, .toolExecution: return ShellPalette.blue
        case .awaitingApproval: return ShellPalette.amber
        case .ready: return ShellPalette.green
        case .error: return ShellPalette.red
        case nil: return ShellPalette.idle
        }
    }

    /// The working family pulses, the settled states do not. Tool execution
    /// belongs with thinking here for the same reason it shares its blue: a
    /// dot that sits still while the pane header pulses says the two disagree
    /// about whether the agent is busy.
    static func pulses(_ status: RemoteSessionStatus?) -> Bool {
        status == .thinking || status == .toolExecution
    }
}

/// The draggable seam above FILES.
///
/// Reads as the design's hairline, but owns a taller invisible grab strip — a
/// 1pt target is not something anyone can reliably hit, and the cursor has to
/// change slightly before the pointer is exactly on the line for the handle to
/// feel like a handle at all.
final class ShellSplitterView: NSView {
    /// How far the pointer moved since the last event. The sidebar owns the
    /// clamping; the splitter only reports motion.
    var onDrag: ((CGFloat) -> Void)?

    static let visualThickness: CGFloat = 1
    static let grabThickness: CGFloat = 9

    private let line = NSView()
    private var lastY: CGFloat?

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        line.wantsLayer = true
        line.layer?.backgroundColor = ShellPalette.hairlineStrong.cgColor
        line.translatesAutoresizingMaskIntoConstraints = false
        addSubview(line)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.grabThickness),
            line.leadingAnchor.constraint(equalTo: leadingAnchor),
            line.trailingAnchor.constraint(equalTo: trailingAnchor),
            line.centerYAnchor.constraint(equalTo: centerYAnchor),
            line.heightAnchor.constraint(equalToConstant: Self.visualThickness),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.splitter)
        setAccessibilityLabel("Resize the files list")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeUpDown)
    }

    override func mouseDown(with event: NSEvent) {
        lastY = event.locationInWindow.y
    }

    override func mouseDragged(with event: NSEvent) {
        guard let previous = lastY else { return }
        let current = event.locationInWindow.y
        lastY = current
        // Window coordinates, not this view's own, and deliberately so: the
        // seam moves as the drag resizes the halves, so a delta measured in
        // its own bounds is measured against an origin that is itself
        // moving. That, plus a sign taken from a flipped view this one is
        // not, made every drag push the seam *away* from the pointer — and
        // since it then moved further from the pointer each event, the
        // error compounded and it shot to a limit on the first twitch.
        //
        // Window coordinates run bottom-up, so a downward drag is a smaller
        // y. Reported downward-positive; the sidebar owns the clamping,
        // this view has no idea what the limits are.
        onDrag?(previous - current)
    }

    override func mouseUp(with event: NSEvent) {
        lastY = nil
    }
}

/// A scroll view for one half of the sidebar's split. Top-anchored content,
/// scrollers only when the content genuinely does not fit.
final class ShellScrollView: NSScrollView {
    init(documentView content: NSView) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        drawsBackground = false
        hasVerticalScroller = true
        autohidesScrollers = true
        scrollerStyle = .overlay
        verticalScrollElasticity = .allowed
        horizontalScrollElasticity = .none
        contentView = ShellFlippedClipView()
        contentView.drawsBackground = false
        content.translatesAutoresizingMaskIntoConstraints = false
        self.documentView = content
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            content.topAnchor.constraint(equalTo: contentView.topAnchor),
            // Width pinned, height free — that is what makes it scroll
            // vertically and never sideways.
            content.widthAnchor.constraint(equalTo: contentView.widthAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
}

/// An `NSClipView` whose origin is top-left. Without this a short document
/// view sits at the *bottom* of a tall scroll view, which is how the workspace
/// cards ended up pinned to the floor of the picker.
final class ShellFlippedClipView: NSClipView {
    override var isFlipped: Bool { true }
}

/// A one-pixel rule. `.5px` in the design; AppKit will land it on the nearest
/// device pixel, which on Retina is exactly the hairline the design wants.
final class ShellSeparator: NSView {
    init(color: NSColor = ShellPalette.hairline) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = color.cgColor
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 1 / max(1, NSScreen.main?.backingScaleFactor ?? 2)).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
}

// MARK: - Clickable row base

/// A row that behaves like a button without being one: `NSButton` cannot hold
/// the multi-line, multi-colour content these rows need without a custom cell,
/// and a custom cell is more code than press handling. Keyboard activation, the
/// accessibility role and `accessibilityPerformPress` are all wired so this
/// stays a real control for VoiceOver and Full Keyboard Access.
class ShellRowView: NSView {
    var onPress: (() -> Void)?
    /// Painted under the row on hover, unless the row is already selected.
    var hoverEnabled = true
    var hoverFill: NSColor = ShellPalette.hover
    /// The pointer arriving (`true`) and leaving (`false`). The base class
    /// already owns the tracking area every row needs for its hover fill, so
    /// the sidebar's hover card rides along on it rather than adding a second.
    var onHover: ((Bool) -> Void)?
    private(set) var isHovered = false
    private var tracking: NSTrackingArea?

    override var acceptsFirstResponder: Bool { onPress != nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        refreshBackground()
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        refreshBackground()
        onHover?(false)
    }

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onPress?()
    }

    override func keyDown(with event: NSEvent) {
        let key = event.charactersIgnoringModifiers
        if key == "\r" || key == " " {
            onPress?()
            return
        }
        super.keyDown(with: event)
    }

    /// Override point: subclasses paint their own selected/hover states.
    func refreshBackground() {
        guard hoverEnabled else { return }
        layer?.backgroundColor = isHovered ? hoverFill.cgColor : NSColor.clear.cgColor
    }

    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func isAccessibilityElement() -> Bool { onPress != nil }
    override func accessibilityPerformPress() -> Bool {
        onPress?()
        return onPress != nil
    }
}

// MARK: - Level 1 · workspace picker

/// One workspace card in the picker.
final class WorkspaceCardView: ShellRowView {
    let workspace: BrainProjectSummary
    private let tile = ShellTileView(size: ShellMetrics.cardTile, radius: 10, fontSize: 14)
    private let nameField: NSTextField
    private let folderField: NSTextField
    private let metaField: NSTextField

    init(workspace: BrainProjectSummary, meta: String) {
        self.workspace = workspace
        nameField = ShellFont.label(
            workspace.label,
            font: ShellFont.ui(15, .semibold),
            color: ShellPalette.ink
        )
        folderField = ShellFont.label(
            WorkspaceCardView.folderName(workspace.path),
            font: ShellFont.mono(11.5),
            color: ShellPalette.inkMuted
        )
        metaField = ShellFont.label(
            meta,
            font: ShellFont.ui(11.5, .medium),
            color: NSColor(srgbRed: 139 / 255, green: 139 / 255, blue: 149 / 255, alpha: 1)
        )
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = 13
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        hoverEnabled = false

        tile.apply(
            initials: ShellPalette.initials(workspace.label),
            gradient: ShellPalette.avatarGradient(forID: workspace.id)
        )
        // The design's tile carries its own drop shadow, which is what lifts
        // the card off a panel this dark.
        tile.shadow = {
            let shadow = NSShadow()
            shadow.shadowColor = NSColor(white: 0, alpha: 0.35)
            shadow.shadowBlurRadius = 8
            shadow.shadowOffset = NSSize(width: 0, height: -2)
            return shadow
        }()

        let chevron = ShellGlyphView(.chevronRight, color: ShellPalette.chevronSoft, size: 18)
        chevron.alphaValue = 0.4

        let text = NSView()
        text.translatesAutoresizingMaskIntoConstraints = false
        for field in [nameField, folderField, metaField] { text.addSubview(field) }

        for view in [tile, text, chevron] { addSubview(view) }
        NSLayoutConstraint.activate([
            tile.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            tile.centerYAnchor.constraint(equalTo: centerYAnchor),

            text.leadingAnchor.constraint(equalTo: tile.trailingAnchor, constant: 10),
            text.trailingAnchor.constraint(equalTo: chevron.leadingAnchor, constant: -6),
            text.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            text.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),

            nameField.topAnchor.constraint(equalTo: text.topAnchor),
            nameField.leadingAnchor.constraint(equalTo: text.leadingAnchor),
            nameField.trailingAnchor.constraint(equalTo: text.trailingAnchor),

            folderField.topAnchor.constraint(equalTo: nameField.bottomAnchor, constant: 2),
            folderField.leadingAnchor.constraint(equalTo: text.leadingAnchor),
            folderField.trailingAnchor.constraint(equalTo: text.trailingAnchor),

            metaField.topAnchor.constraint(equalTo: folderField.bottomAnchor, constant: 4),
            metaField.leadingAnchor.constraint(equalTo: text.leadingAnchor),
            metaField.trailingAnchor.constraint(equalTo: text.trailingAnchor),
            metaField.bottomAnchor.constraint(equalTo: text.bottomAnchor),

            chevron.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        for field in [nameField, folderField, metaField] {
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        refreshBackground()
        setAccessibilityLabel("\(workspace.label), \(meta)")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func setMeta(_ meta: String) {
        metaField.stringValue = meta
        setAccessibilityLabel("\(workspace.label), \(meta)")
    }

    override func refreshBackground() {
        layer?.backgroundColor = (isHovered ? ShellPalette.cardFillHover : ShellPalette.cardFill).cgColor
        layer?.borderColor = (isHovered ? ShellPalette.cardStrokeHover : ShellPalette.cardStroke).cgColor
    }

    /// The design prints the last path component, not the whole path — the full
    /// one is what Level 2's header shows.
    static func folderName(_ path: String?) -> String {
        guard let path, !path.isEmpty else { return "—" }
        return (path as NSString).lastPathComponent
    }
}

/// Level 1: pick a workspace.
final class WorkspacePickerView: NSView {
    var onPick: ((BrainProjectSummary) -> Void)?
    var onNewWorkspace: (() -> Void)?

    private let list = NSStackView()
    private let emptyLabel: NSTextField
    private(set) var cards: [WorkspaceCardView] = []

    override init(frame frameRect: NSRect) {
        emptyLabel = ShellFont.label(
            "No workspaces yet.",
            font: ShellFont.ui(12.5),
            color: ShellPalette.inkMuted
        )
        super.init(frame: frameRect)

        let title = ShellFont.label(
            "Workspaces",
            font: ShellFont.ui(17, .bold),
            color: ShellPalette.ink,
            tracking: -0.25
        )
        let subtitle = ShellFont.label(
            "Open one to see its agents",
            font: ShellFont.ui(12.5),
            color: ShellPalette.inkMuted
        )
        let separator = ShellSeparator()

        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 6
        list.edgeInsets = NSEdgeInsets(top: 9, left: 8, bottom: 9, right: 8)
        list.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.contentView = ShellFlippedClipView()
        scroll.documentView = list
        scroll.translatesAutoresizingMaskIntoConstraints = false

        for view in [title, subtitle, separator, scroll] { addSubview(view) }
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            title.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),

            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 3),
            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.trailingAnchor.constraint(equalTo: title.trailingAnchor),

            separator.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 11),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),

            scroll.topAnchor.constraint(equalTo: separator.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),

            list.widthAnchor.constraint(equalTo: scroll.widthAnchor),
            list.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func setWorkspaces(_ workspaces: [BrainProjectSummary], sessionCounts: [String: Int]) {
        for view in list.arrangedSubviews {
            list.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        cards = []

        for workspace in workspaces {
            let card = WorkspaceCardView(
                workspace: workspace,
                meta: ShellPalette.sessionCountLabel(sessionCounts[workspace.id] ?? 0)
            )
            card.onPress = { [weak self] in self?.onPick?(workspace) }
            list.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: list.widthAnchor, constant: -16).isActive = true
            cards.append(card)
        }

        if workspaces.isEmpty {
            list.addArrangedSubview(emptyLabel)
        }

        let newButton = WorkspaceDashedButton(title: "New workspace")
        newButton.onPress = { [weak self] in self?.onNewWorkspace?() }
        list.addArrangedSubview(newButton)
        newButton.widthAnchor.constraint(equalTo: list.widthAnchor, constant: -16).isActive = true
    }
}

/// The picker's dashed "New workspace" affordance.
final class WorkspaceDashedButton: ShellRowView {
    init(title: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 13
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        hoverEnabled = false

        let plus = ShellGlyphView(.plus, color: ShellPalette.accent, size: 18, lineWidth: 1.5)
        let label = ShellFont.label(title, font: ShellFont.ui(14, .semibold), color: ShellPalette.accent)

        let row = NSStackView(views: [plus, label])
        row.orientation = .horizontal
        row.spacing = 7
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false

        addSubview(row)
        NSLayoutConstraint.activate([
            row.centerXAnchor.constraint(equalTo: centerXAnchor),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 11),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -11),
        ])
        refreshBackground()
        setAccessibilityLabel(title)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func refreshBackground() {
        layer?.backgroundColor = isHovered
            ? NSColor(srgbRed: 139 / 255, green: 149 / 255, blue: 255 / 255, alpha: 0.1).cgColor
            : NSColor.clear.cgColor
        layer?.borderColor = (isHovered
            ? NSColor(srgbRed: 139 / 255, green: 149 / 255, blue: 255 / 255, alpha: 0.45)
            : ShellPalette.dashedStroke).cgColor
    }

    override func draw(_ dirtyRect: NSRect) {
        // A dashed border is not a `CALayer` property; draw it and keep the
        // layer's own border clear.
        super.draw(dirtyRect)
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 13, yRadius: 13)
        path.lineWidth = 1
        path.setLineDash([4, 3], count: 2, phase: 0)
        (isHovered
            ? NSColor(srgbRed: 139 / 255, green: 149 / 255, blue: 255 / 255, alpha: 0.45)
            : ShellPalette.dashedStroke).setStroke()
        path.stroke()
    }
}

// MARK: - Level 2 · back row and navigation

/// Level 2's header: the open workspace, and the way back to the picker.
final class WorkspaceBackRowView: ShellRowView {
    private let tile = ShellTileView(size: ShellMetrics.backTile, radius: 8, fontSize: 12.5)
    private let nameField = ShellFont.label(
        font: ShellFont.ui(15, .semibold),
        color: ShellPalette.ink
    )
    private let pathField = ShellFont.label(
        font: ShellFont.mono(11.5),
        color: ShellPalette.inkMuted
    )

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        hoverFill = NSColor(white: 1, alpha: 0.075)

        let chevron = ShellGlyphView(.chevronLeft, color: ShellPalette.chevronSoft, size: 18, lineWidth: 1.7)
        chevron.alphaValue = 0.6

        let text = NSView()
        text.translatesAutoresizingMaskIntoConstraints = false
        text.addSubview(nameField)
        text.addSubview(pathField)

        for view in [chevron, tile, text] { addSubview(view) }
        NSLayoutConstraint.activate([
            chevron.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),

            tile.leadingAnchor.constraint(equalTo: chevron.trailingAnchor, constant: 9),
            tile.centerYAnchor.constraint(equalTo: centerYAnchor),

            text.leadingAnchor.constraint(equalTo: tile.trailingAnchor, constant: 9),
            text.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            text.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            text.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -9),

            nameField.topAnchor.constraint(equalTo: text.topAnchor),
            nameField.leadingAnchor.constraint(equalTo: text.leadingAnchor),
            nameField.trailingAnchor.constraint(equalTo: text.trailingAnchor),

            pathField.topAnchor.constraint(equalTo: nameField.bottomAnchor, constant: 2),
            pathField.leadingAnchor.constraint(equalTo: text.leadingAnchor),
            pathField.trailingAnchor.constraint(equalTo: text.trailingAnchor),
            pathField.bottomAnchor.constraint(equalTo: text.bottomAnchor),
        ])
        for field in [nameField, pathField] {
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        refreshBackground()
        setAccessibilityLabel("Switch workspace")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func apply(workspace: BrainProjectSummary?) {
        nameField.stringValue = workspace?.label ?? "No workspace"
        pathField.stringValue = WorkspaceBackRowView.abbreviate(workspace?.path)
        tile.apply(
            initials: ShellPalette.initials(workspace?.label ?? "?"),
            gradient: ShellPalette.avatarGradient(forID: workspace?.id ?? "")
        )
    }

    override func refreshBackground() {
        layer?.backgroundColor = (isHovered ? hoverFill : ShellPalette.backRowFill).cgColor
    }

    /// `/Users/me/Code/x` -> `~/Code/x`, the way the design writes it.
    static func abbreviate(_ path: String?) -> String {
        guard let path, !path.isEmpty else { return "—" }
        return (path as NSString).abbreviatingWithTildeInPath
    }
}

/// One of Level 2's three destination rows.
final class WorkspaceNavRowView: ShellRowView {
    let destination: WorkspaceDestination

    private let bar = NSView()
    private let iconTile = NSView()
    private let glyph: ShellGlyphView
    private let titleField: NSTextField
    private let subtitleField: NSTextField
    private let countField: NSTextField
    private var isSelected = false

    init(destination: WorkspaceDestination) {
        self.destination = destination
        glyph = ShellGlyphView(destination.glyph, color: ShellPalette.inkNav, size: 20, lineWidth: 2)
        titleField = ShellFont.label(
            destination.title,
            font: ShellFont.ui(15.5, .semibold),
            color: ShellPalette.inkNav
        )
        subtitleField = ShellFont.label(
            destination.subtitle,
            font: ShellFont.ui(12),
            color: ShellPalette.inkMuted
        )
        countField = ShellFont.label(font: ShellFont.mono(12, .medium), color: ShellPalette.inkFaint)
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        hoverEnabled = false

        bar.wantsLayer = true
        bar.layer?.cornerRadius = 2
        bar.translatesAutoresizingMaskIntoConstraints = false

        iconTile.wantsLayer = true
        iconTile.layer?.cornerRadius = 6
        iconTile.layer?.cornerCurve = .continuous
        iconTile.translatesAutoresizingMaskIntoConstraints = false
        iconTile.addSubview(glyph)

        let text = NSView()
        text.translatesAutoresizingMaskIntoConstraints = false
        for field in [titleField, subtitleField] { text.addSubview(field) }

        for view in [bar, iconTile, text, countField] { addSubview(view) }
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: leadingAnchor),
            bar.widthAnchor.constraint(equalToConstant: ShellMetrics.navBarWidth),
            bar.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            bar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -9),

            iconTile.leadingAnchor.constraint(equalTo: leadingAnchor, constant: ShellMetrics.navRowInset.left),
            iconTile.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconTile.widthAnchor.constraint(equalToConstant: ShellMetrics.navIconTile),
            iconTile.heightAnchor.constraint(equalToConstant: ShellMetrics.navIconTile),
            glyph.centerXAnchor.constraint(equalTo: iconTile.centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: iconTile.centerYAnchor),

            text.leadingAnchor.constraint(equalTo: iconTile.trailingAnchor, constant: 9),
            text.trailingAnchor.constraint(equalTo: countField.leadingAnchor, constant: -6),
            text.topAnchor.constraint(equalTo: topAnchor, constant: ShellMetrics.navRowInset.top),
            text.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -ShellMetrics.navRowInset.bottom),

            titleField.topAnchor.constraint(equalTo: text.topAnchor),
            titleField.leadingAnchor.constraint(equalTo: text.leadingAnchor),
            titleField.trailingAnchor.constraint(equalTo: text.trailingAnchor),

            subtitleField.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: 1),
            subtitleField.leadingAnchor.constraint(equalTo: text.leadingAnchor),
            subtitleField.trailingAnchor.constraint(equalTo: text.trailingAnchor),
            subtitleField.bottomAnchor.constraint(equalTo: text.bottomAnchor),

            countField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -ShellMetrics.navRowInset.right),
            countField.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        countField.setContentCompressionResistancePriority(.required, for: .horizontal)
        countField.setContentHuggingPriority(.required, for: .horizontal)
        titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        subtitleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        apply(selected: false)
        setAccessibilityLabel(destination.title)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func setCount(_ value: Int?) {
        countField.stringValue = value.map(String.init) ?? ""
    }

    func setSubtitle(_ text: String) {
        subtitleField.stringValue = text
    }

    /// Internal so the tests can read the live second line without reaching
    /// through the view hierarchy.
    var subtitleText: String { subtitleField.stringValue }

    /// Files' second line is a two-colour diff, which one plain label cannot
    /// hold — so it is the same label carrying attributed text.
    func setDiff(added: Int, removed: Int) {
        let font = ShellFont.mono(12, .medium)
        let string = NSMutableAttributedString(
            string: "+\(added)",
            attributes: [.font: font, .foregroundColor: ShellPalette.green]
        )
        string.append(NSAttributedString(
            string: " −\(removed)",
            attributes: [.font: font, .foregroundColor: ShellPalette.red]
        ))
        subtitleField.attributedStringValue = string
    }

    func apply(selected: Bool) {
        isSelected = selected
        titleField.textColor = selected ? ShellPalette.ink : ShellPalette.inkNav
        glyph.color = selected ? ShellPalette.ink : ShellPalette.inkNav
        countField.textColor = selected ? ShellPalette.accentBright : ShellPalette.inkFaint
        bar.layer?.backgroundColor = (selected ? ShellPalette.accent : .clear).cgColor
        iconTile.layer?.backgroundColor = (selected ? ShellPalette.accentIconTile : ShellPalette.iconTile).cgColor
        refreshBackground()
        setAccessibilityValue(selected ? "selected" : "")
    }

    override func refreshBackground() {
        let fill: NSColor
        if isSelected {
            fill = ShellPalette.accentSoft
        } else if isHovered {
            fill = ShellPalette.hover
        } else {
            fill = .clear
        }
        layer?.backgroundColor = fill.cgColor
    }
}

// MARK: - Level 2 · sessions tree

/// The amber "inputs waiting" pill: the count of terminals blocked on a
/// question. Worn by a collapsed session row (aggregate) and by an awaiting
/// terminal row (its own 1) — the same badge, so the eye learns it once.
final class ShellAwaitingBadgeView: NSView {
    let count: Int

    init(count: Int) {
        self.count = count
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = ShellPalette.amber.withAlphaComponent(0.12).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = ShellPalette.amber.withAlphaComponent(0.26).cgColor
        let label = ShellFont.label(
            "\(count)",
            font: ShellFont.mono(11, .semibold),
            color: ShellPalette.amber
        )
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 16),
            widthAnchor.constraint(equalTo: label.widthAnchor, constant: 10),
            heightAnchor.constraint(equalToConstant: 16),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(count == 1 ? "1 input waiting" : "\(count) inputs waiting")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
}

/// A session row — the collapsible parent of a set of terminals.
final class SessionRowView: ShellRowView, NSTextFieldDelegate {
    let session: SessionGroupNode
    /// Double-click to rename, the affordance the old outline used to provide.
    /// The design does not draw a rename control, but dropping the capability
    /// along with the outline would be a silent regression.
    var onRename: ((String) -> Void)?

    private let chevron: ShellGlyphView
    private let titleField: NSTextField
    private let dots = ShellDotsView()
    private let bar = NSView()
    private let isCurrent: Bool
    /// The amber waiting-inputs count, worn whenever a terminal of this
    /// session is blocked on a question — the session-level "requires
    /// attention", whether or not the terminal rows are showing.
    private(set) var awaitingBadge: ShellAwaitingBadgeView?

    init(
        session: SessionGroupNode,
        expanded: Bool,
        statuses: [RemoteSessionStatus?],
        awaitingCount: Int = 0
    ) {
        self.session = session
        isCurrent = session.isCurrent
        chevron = ShellGlyphView(
            .chevronRight,
            color: session.isCurrent ? ShellPalette.accentBright : ShellPalette.chevron,
            size: 15,
            lineWidth: 1.8
        )
        titleField = ShellFont.label(
            session.label,
            font: ShellFont.ui(14.5, session.isCurrent ? .semibold : .medium),
            color: session.isCurrent ? ShellPalette.ink : ShellPalette.inkSecondary
        )
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.cornerCurve = .continuous
        hoverEnabled = false
        chevron.rotated = expanded

        bar.wantsLayer = true
        bar.layer?.cornerRadius = 2
        bar.layer?.backgroundColor = (session.isCurrent ? ShellPalette.accent : .clear).cgColor
        bar.translatesAutoresizingMaskIntoConstraints = false

        dots.apply(
            statuses.map(ShellDotsView.color(for:)),
            pulsing: Set(statuses.enumerated().compactMap { ShellDotsView.pulses($1) ? $0 : nil })
        )

        for view in [bar, chevron, titleField, dots] { addSubview(view) }
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            bar.widthAnchor.constraint(equalToConstant: 2.5),
            bar.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            bar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),

            chevron.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),

            titleField.leadingAnchor.constraint(equalTo: chevron.trailingAnchor, constant: 8),
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleField.trailingAnchor.constraint(equalTo: dots.leadingAnchor, constant: -8),

            dots.centerYAnchor.constraint(equalTo: centerYAnchor),

            topAnchor.constraint(equalTo: titleField.topAnchor, constant: -6),
            bottomAnchor.constraint(equalTo: titleField.bottomAnchor, constant: 6),
        ])
        // The session-level view of "how many of mine are asking": always on
        // while something waits, expanded or not, so a session needing
        // attention is findable from the session list alone — the terminal
        // rows underneath add *which* one, not *whether*.
        if awaitingCount > 0 {
            let badge = ShellAwaitingBadgeView(count: awaitingCount)
            awaitingBadge = badge
            addSubview(badge)
            NSLayoutConstraint.activate([
                dots.trailingAnchor.constraint(equalTo: badge.leadingAnchor, constant: -8),
                badge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
                badge.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
        } else {
            dots.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8).isActive = true
        }
        dots.setContentCompressionResistancePriority(.init(751), for: .horizontal)
        titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        refreshBackground()
        setAccessibilityLabel("Session \(session.label)")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func setExpanded(_ expanded: Bool) {
        chevron.rotated = expanded
    }

    override func refreshBackground() {
        let fill: NSColor
        if isCurrent {
            fill = ShellPalette.accentSelection
        } else if isHovered {
            fill = NSColor(white: 1, alpha: 0.055)
        } else {
            fill = .clear
        }
        layer?.backgroundColor = fill.cgColor
    }

    // MARK: Rename

    private(set) var isRenaming = false

    /// The label doubles as the rename editor; exposed for the tests.
    var renameField: NSTextField { titleField }

    /// Commits whatever is in the editor, the way Return does.
    func commitRenameForTesting() { endRenaming(commit: true) }

    override func mouseDown(with event: NSEvent) {
        guard event.clickCount == 2, onRename != nil else {
            super.mouseDown(with: event)
            return
        }
        beginRenaming()
    }

    /// A press that lands while the editor is up must not also select the row,
    /// or committing a rename would re-focus the session underneath it.
    override func mouseUp(with event: NSEvent) {
        guard !isRenaming else { return }
        super.mouseUp(with: event)
    }

    func beginRenaming() {
        guard !isRenaming else { return }
        isRenaming = true
        titleField.isEditable = true
        titleField.isSelectable = true
        titleField.isBordered = false
        titleField.drawsBackground = true
        titleField.backgroundColor = NSColor(white: 1, alpha: 0.1)
        titleField.focusRingType = .none
        titleField.delegate = self
        titleField.stringValue = session.name ?? session.label
        window?.makeFirstResponder(titleField)
        titleField.currentEditor()?.selectAll(nil)
    }

    private func endRenaming(commit: Bool) {
        guard isRenaming else { return }
        let typed = titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        isRenaming = false
        titleField.isEditable = false
        titleField.isSelectable = false
        titleField.drawsBackground = false
        titleField.delegate = nil
        window?.makeFirstResponder(nil)

        // An empty name is a cancel, not a request to clear the label — the
        // derived "Session N" would come back and look like data loss.
        guard commit, !typed.isEmpty, typed != session.label else {
            titleField.stringValue = session.label
            return
        }
        onRename?(typed)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            endRenaming(commit: true)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            endRenaming(commit: false)
            return true
        default:
            return false
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        endRenaming(commit: true)
    }
}

/// A terminal row under its session.
final class TerminalRowView: ShellRowView, NSTextFieldDelegate {
    let paneID: String

    /// Double-click to rename, the same affordance a session row has. A
    /// terminal normally wears whatever the agent says it is working on; this
    /// is how the user pins a name of their own over the top of it.
    var onRename: ((String) -> Void)?

    private let statusGlyph = NSImageView()
    private var isFocused: Bool
    private let titleField: NSTextField
    /// What the row shows now — the editor opens on this, and a cancelled or
    /// empty rename puts it back.
    private let displayedName: String
    /// The amber waiting pill beside the engine icon while this terminal is
    /// blocked on a question. Selecting the terminal is what clears it — the
    /// row is focused, the approval bar is on screen, the ask is answered.
    private(set) var awaitingBadge: ShellAwaitingBadgeView?
    /// The engine (or browser) icon. Held so the badge's placement against it
    /// is a fact a test can check, not a constraint nobody ever sees again.
    private(set) var engineIcon: NSView!

    init(pane: PaneDescriptor, focused: Bool, status: RemoteSessionStatus?) {
        paneID = pane.sessionID
        isFocused = focused
        displayedName = SessionOutline.paneLabel(pane)
        titleField = ShellFont.label(
            displayedName,
            font: ShellFont.ui(14),
            color: focused
                ? ShellPalette.inkTerminal
                : (pane.engine == .shell ? ShellPalette.inkTertiary : ShellPalette.inkSecondary)
        )
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous
        hoverEnabled = false
        hoverFill = ShellPalette.hoverSoft

        let icon: NSView
        switch pane.kind {
        case .browser: icon = TerminalRowView.browserIcon()
        case .editor: icon = ShellGlyphView(.file, color: ShellPalette.fileGlyph, size: 16, lineWidth: 1.1)
        case .terminal: icon = TerminalRowView.engineIcon(for: pane.engine)
        }
        engineIcon = icon
        let title = titleField

        // The design tints the OmniAgent mark per status and puts a matching
        // glow behind it; a template image is what lets one asset do that.
        let tint = ShellDotsView.color(for: status)
        statusGlyph.image = OmniAgentMark.image
        statusGlyph.contentTintColor = tint
        statusGlyph.translatesAutoresizingMaskIntoConstraints = false
        if status != nil {
            statusGlyph.shadow = {
                let shadow = NSShadow()
                shadow.shadowColor = tint.withAlphaComponent(0.53)
                shadow.shadowBlurRadius = 4
                shadow.shadowOffset = .zero
                return shadow
            }()
        }
        if ShellDotsView.pulses(status), !ShellMotion.reduced {
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 0.45
            pulse.toValue = 1
            pulse.duration = 0.9
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            statusGlyph.wantsLayer = true
            statusGlyph.layer?.add(pulse, forKey: "om-pulse")
        }

        for view in [icon, title, statusGlyph] { addSubview(view) }
        title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 7).isActive = true
        // An unselected terminal blocked on a question wears the amber pill
        // in the row's own indent, *left* of the engine icon; selecting the row
        // retires it. Left rather than right so it never moves the icon or the
        // name: every row's icon column stays where it is, badge or no badge,
        // and the pill reads as a marker in the margin instead of a word
        // wedged into the title.
        if status == .awaitingApproval, !focused {
            let badge = ShellAwaitingBadgeView(count: 1)
            awaitingBadge = badge
            addSubview(badge)
            NSLayoutConstraint.activate([
                badge.trailingAnchor.constraint(equalTo: icon.leadingAnchor, constant: -5),
                badge.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.heightAnchor.constraint(equalToConstant: 18),

            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            title.trailingAnchor.constraint(equalTo: statusGlyph.leadingAnchor, constant: -7),

            statusGlyph.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            statusGlyph.centerYAnchor.constraint(equalTo: centerYAnchor),
            statusGlyph.widthAnchor.constraint(equalToConstant: 12),
            statusGlyph.heightAnchor.constraint(equalToConstant: 12),

            topAnchor.constraint(equalTo: title.topAnchor, constant: -4),
            bottomAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),
        ])
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        refreshBackground()
        setAccessibilityLabel(SessionOutline.paneLabel(pane))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func refreshBackground() {
        let fill: NSColor = (isFocused || isHovered) ? ShellPalette.hoverSoft : .clear
        layer?.backgroundColor = fill.cgColor
    }

    /// The engine's own logo, falling back to the design's stroked terminal
    /// glyph when the asset is missing so a row is never blank.
    // MARK: - Rename

    private(set) var isRenaming = false

    /// The label doubles as the rename editor; exposed for the tests.
    var renameField: NSTextField { titleField }

    /// Commits whatever is in the editor, the way Return does.
    func commitRenameForTesting() { endRenaming(commit: true) }

    override func mouseDown(with event: NSEvent) {
        guard event.clickCount == 2, onRename != nil else {
            super.mouseDown(with: event)
            return
        }
        beginRenaming()
    }

    /// A press that lands while the editor is up must not also select the row,
    /// or committing a rename would focus the terminal underneath it.
    override func mouseUp(with event: NSEvent) {
        guard !isRenaming else { return }
        super.mouseUp(with: event)
    }

    func beginRenaming() {
        guard !isRenaming else { return }
        isRenaming = true
        titleField.isEditable = true
        titleField.isSelectable = true
        titleField.isBordered = false
        titleField.drawsBackground = true
        titleField.backgroundColor = NSColor(white: 1, alpha: 0.1)
        titleField.focusRingType = .none
        titleField.delegate = self
        titleField.stringValue = displayedName
        window?.makeFirstResponder(titleField)
        titleField.currentEditor()?.selectAll(nil)
    }

    private func endRenaming(commit: Bool) {
        guard isRenaming else { return }
        let typed = titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        isRenaming = false
        titleField.isEditable = false
        titleField.isSelectable = false
        titleField.drawsBackground = false
        titleField.delegate = nil
        window?.makeFirstResponder(nil)

        // Empty is a cancel, not "clear the name": clearing would hand the row
        // straight back to the agent's title, which reads as the rename having
        // been thrown away.
        guard commit, !typed.isEmpty, typed != displayedName else {
            titleField.stringValue = displayedName
            return
        }
        onRename?(typed)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            endRenaming(commit: true)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            endRenaming(commit: false)
            return true
        default:
            return false
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        endRenaming(commit: true)
    }

    private static func engineIcon(for engine: Engine) -> NSView {
        if let image = engine.iconImage {
            let view = NSImageView(image: image)
            view.translatesAutoresizingMaskIntoConstraints = false
            view.imageScaling = .scaleProportionallyUpOrDown
            if image.isTemplate { view.contentTintColor = ShellPalette.inkTertiary }
            return view
        }
        return ShellGlyphView(.terminal, color: ShellPalette.inkTertiary, size: 18, lineWidth: 2.2)
    }

    /// A browser pane's row wears a globe, not an engine logo — it has no
    /// engine, whatever placeholder its descriptor carries.
    private static func browserIcon() -> NSView {
        guard let image = NSImage(systemSymbolName: "globe", accessibilityDescription: "Browser") else {
            return ShellGlyphView(.terminal, color: ShellPalette.inkTertiary, size: 18, lineWidth: 2.2)
        }
        let view = NSImageView(image: image)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.imageScaling = .scaleProportionallyUpOrDown
        view.contentTintColor = ShellPalette.inkTertiary
        return view
    }
}

/// The design's "+ New terminal  ⌘T" row — parameterised so the browser
/// add-row is the same row wearing different words, not a second class to
/// keep in step.
final class NewTerminalRowView: ShellRowView {
    init(title: String = "New terminal", shortcut: String = "⌘T") {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous
        hoverEnabled = false

        let plus = ShellGlyphView(.plus, color: ShellPalette.accent, size: 18, lineWidth: 1.5)
        let label = ShellFont.label(title, font: ShellFont.ui(14, .medium), color: ShellPalette.accent)
        let shortcut = ShellFont.label(shortcut, font: ShellFont.mono(12, .medium), color: ShellPalette.inkFaint)

        for view in [plus, label, shortcut] { addSubview(view) }
        NSLayoutConstraint.activate([
            plus.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            plus.centerYAnchor.constraint(equalTo: centerYAnchor),

            label.leadingAnchor.constraint(equalTo: plus.trailingAnchor, constant: 7),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),

            shortcut.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            shortcut.centerYAnchor.constraint(equalTo: centerYAnchor),

            topAnchor.constraint(equalTo: label.topAnchor, constant: -4),
            bottomAnchor.constraint(equalTo: label.bottomAnchor, constant: 4),
        ])
        refreshBackground()
        setAccessibilityLabel(title)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func refreshBackground() {
        layer?.backgroundColor = (isHovered ? ShellPalette.accentSelection : .clear).cgColor
    }
}

/// The sessions tree that hangs off the Terminals row, accent rail and all.
final class SessionsTreeView: NSView {
    var onSelectPane: ((String) -> Void)?
    var onSelectSession: ((SessionGroupNode) -> Void)?
    var onNewSession: (() -> Void)?
    var onNewTerminal: (() -> Void)?
    var onNewBrowser: (() -> Void)?
    var onNewEditor: (() -> Void)?
    var onRenameSession: ((SessionGroupNode, String) -> Void)?
    var onRenamePane: ((String, String) -> Void)?
    /// The pointer resting on a row, or leaving one (`nil`) — what raises the
    /// hover card.
    var onHoverTarget: ((SessionHoverCardController.Target?) -> Void)?

    private let countField = ShellFont.label(font: ShellFont.mono(12, .semibold), color: ShellPalette.inkFainter)
    private let rows = NSStackView()
    private let rail = NSView()
    /// What the last `reload` actually drew, so a test can assert scoping
    /// without walking the stack view.
    private(set) var renderedSessionIDs: [String] = []
    /// The terminal rows currently on screen, in order.
    var renderedPaneIDs: [String] {
        rows.arrangedSubviews.compactMap { ($0 as? TerminalRowView)?.paneID }
    }
    /// Whether the "+ New terminal" row is on screen at all.
    var showsNewTerminalRow: Bool {
        rows.arrangedSubviews.contains { $0 is NewTerminalRowView }
    }
    /// Sessions the user has collapsed. Absent means expanded, so a brand new
    /// session shows its terminals without anyone having to opt in.
    private var collapsed: Set<String> = []

    /// What `reload` was last handed, so toggling a disclosure can re-render
    /// without the controller having to push the whole tree again.
    private struct Render {
        var sessions: [SessionGroupNode] = []
        var panes: [String: PaneDescriptor] = [:]
        var focusedPaneID: String?
        var statuses: [String: RemoteSessionStatus] = [:]
    }

    private var lastRender = Render()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        let header = ShellFont.label(
            "SESSIONS",
            font: ShellFont.ui(12, .semibold),
            color: ShellPalette.inkMuted,
            tracking: 1.2
        )
        let add = ShellRowView()
        add.wantsLayer = true
        add.layer?.cornerRadius = 5
        add.hoverFill = NSColor(white: 1, alpha: 0.1)
        add.onPress = { [weak self] in self?.onNewSession?() }
        add.setAccessibilityLabel("New session")
        let addGlyph = ShellGlyphView(.plus, color: ShellPalette.chevron, size: 19, lineWidth: 1.4)
        add.addSubview(addGlyph)
        add.translatesAutoresizingMaskIntoConstraints = false

        rail.wantsLayer = true
        rail.layer?.backgroundColor = ShellPalette.accentRail.cgColor
        rail.translatesAutoresizingMaskIntoConstraints = false

        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 1
        rows.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 6, right: 6)
        rows.translatesAutoresizingMaskIntoConstraints = false

        for field in [header, countField] {
            field.setContentCompressionResistancePriority(.required, for: .horizontal)
            field.setContentHuggingPriority(.required, for: .horizontal)
        }
        for view in [rail, header, countField, add, rows] { addSubview(view) }
        NSLayoutConstraint.activate([
            // The design draws a 1.5pt accent rail 18pt in, with the tree's
            // content another 10pt to its right.
            rail.leadingAnchor.constraint(equalTo: leadingAnchor, constant: ShellMetrics.sessionRail),
            rail.widthAnchor.constraint(equalToConstant: 1.5),
            rail.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            rail.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),

            header.leadingAnchor.constraint(equalTo: rail.trailingAnchor, constant: 14),
            header.topAnchor.constraint(equalTo: topAnchor, constant: 9),

            countField.leadingAnchor.constraint(equalTo: header.trailingAnchor, constant: 6),
            countField.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            add.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            add.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            add.widthAnchor.constraint(equalToConstant: 18),
            add.heightAnchor.constraint(equalToConstant: 18),
            addGlyph.centerXAnchor.constraint(equalTo: add.centerXAnchor),
            addGlyph.centerYAnchor.constraint(equalTo: add.centerYAnchor),

            rows.leadingAnchor.constraint(equalTo: rail.trailingAnchor, constant: ShellMetrics.sessionRailInset),
            rows.trailingAnchor.constraint(equalTo: trailingAnchor),
            rows.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 5),
            rows.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func reload(
        sessions: [SessionGroupNode],
        panes: [String: PaneDescriptor],
        focusedPaneID: String?,
        statuses: [String: RemoteSessionStatus]
    ) {
        lastRender = Render(
            sessions: sessions,
            panes: panes,
            focusedPaneID: focusedPaneID,
            statuses: statuses
        )
        renderedSessionIDs = sessions.map(\.id)
        countField.stringValue = "\(sessions.count)"

        for view in rows.arrangedSubviews {
            rows.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        for session in sessions {
            let expanded = !collapsed.contains(session.id)
            let row = SessionRowView(
                session: session,
                expanded: expanded,
                statuses: session.paneIDs.map { statuses[$0] },
                // The focused terminal's ask is on screen already — it counts
                // as seen, the same rule that clears its own row's badge.
                awaitingCount: session.paneIDs
                    .filter { statuses[$0] == .awaitingApproval && $0 != focusedPaneID }
                    .count
            )
            row.onPress = { [weak self] in
                guard let self else { return }
                // The design's chevron collapses; selecting is what the row as
                // a whole does. Both on one press would fight each other, so
                // the current session toggles and any other one is selected.
                if session.isCurrent {
                    if self.collapsed.contains(session.id) {
                        self.collapsed.remove(session.id)
                    } else {
                        self.collapsed.insert(session.id)
                    }
                    self.rerender()
                } else {
                    self.onSelectSession?(session)
                }
            }
            row.onRename = { [weak self] name in self?.onRenameSession?(session, name) }
            row.onHover = { [weak self] inside in
                self?.onHoverTarget?(inside ? .session(session.id) : nil)
            }
            rows.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rows.widthAnchor, constant: -12).isActive = true

            guard expanded else { continue }
            for paneID in session.paneIDs {
                guard let pane = panes[paneID] else { continue }
                let terminal = TerminalRowView(
                    pane: pane,
                    focused: paneID == focusedPaneID,
                    status: statuses[paneID]
                )
                terminal.onPress = { [weak self] in self?.onSelectPane?(paneID) }
                terminal.onRename = { [weak self] name in self?.onRenamePane?(paneID, name) }
                terminal.onHover = { [weak self] inside in
                    self?.onHoverTarget?(inside ? .pane(paneID) : nil)
                }
                rows.addArrangedSubview(terminal)
                terminal.widthAnchor.constraint(equalTo: rows.widthAnchor, constant: -12).isActive = true
            }

            // A session at the twelve-terminal cap has nowhere to put a
            // thirteenth — `PaneWorkspaceView.addPane` would refuse it — so the
            // row goes away rather than sitting there doing nothing when pressed.
            if session.isCurrent, session.paneIDs.count < PaneGrid.maxPanes {
                let add = NewTerminalRowView()
                add.onPress = { [weak self] in self?.onNewTerminal?() }
                rows.addArrangedSubview(add)
                add.widthAnchor.constraint(equalTo: rows.widthAnchor, constant: -12).isActive = true
                // The browser twin, under the same cap: both rows add to the
                // same grid, and a full grid is a full grid whatever it holds.
                let addBrowser = NewTerminalRowView(title: "New browser", shortcut: "⇧⌘T")
                addBrowser.onPress = { [weak self] in self?.onNewBrowser?() }
                rows.addArrangedSubview(addBrowser)
                addBrowser.widthAnchor.constraint(equalTo: rows.widthAnchor, constant: -12).isActive = true
                // And the editor's, under that same cap.
                let addEditor = NewTerminalRowView(title: "New editor", shortcut: "⇧⌘E")
                addEditor.onPress = { [weak self] in self?.onNewEditor?() }
                rows.addArrangedSubview(addEditor)
                addEditor.widthAnchor.constraint(equalTo: rows.widthAnchor, constant: -12).isActive = true
            }
        }
    }

    private func rerender() {
        reload(
            sessions: lastRender.sessions,
            panes: lastRender.panes,
            focusedPaneID: lastRender.focusedPaneID,
            statuses: lastRender.statuses
        )
    }

    /// The row a hover target names, in whatever the last `reload` built.
    /// Looked up by id rather than remembered, because every status event
    /// throws these rows away and makes new ones — a card holding the view it
    /// opened over would be pointing at a corpse a second later.
    func rowView(for target: SessionHoverCardController.Target) -> NSView? {
        rows.arrangedSubviews.first { view in
            switch target {
            case .pane(let id): return (view as? TerminalRowView)?.paneID == id
            case .session(let id): return (view as? SessionRowView)?.session.id == id
            }
        }
    }
}

// MARK: - Level 2 · files tree

/// One row of the design's Finder-like tree.
final class WorkspaceFileRowView: ShellRowView {
    let node: WorkspaceFileNode

    /// Pressing the git badge asks for the file's diff instead of opening it.
    /// `nil` on every row that has no badge to press — a clean file's whole
    /// width stays "open this file".
    var onBadgePress: (() -> Void)?

    private let chevron: ShellGlyphView?
    private let badgeField: NSTextField
    private var isSelected: Bool
    /// Set on a mouse-down that landed on the badge, so the *release* decides
    /// — a press that starts on the badge and ends elsewhere does nothing, the
    /// way every other control on the platform behaves.
    private var badgePressArmed = false

    init(node: WorkspaceFileNode, depth: Int, expanded: Bool, selected: Bool) {
        self.node = node
        isSelected = selected
        chevron = node.isDirectory
            ? ShellGlyphView(.chevronRight, color: ShellPalette.chevron, size: 15, lineWidth: 1.6)
            : nil
        badgeField = ShellFont.label(
            WorkspaceFileRowView.badgeText(node),
            font: ShellFont.mono(node.isDirectory ? 11.5 : 12, .semibold),
            color: WorkspaceFileRowView.badgeColor(node)
        )
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous
        hoverEnabled = false
        chevron?.rotated = expanded

        // The design indents 13pt for the first level and 21pt after it, which
        // is what keeps a file's icon aligned under its folder's name rather
        // than under its folder's chevron.
        let indent: CGFloat = depth == 0 ? 8 : 8 + 13 + CGFloat(depth - 1) * 21

        let icon = ShellGlyphView(
            node.isDirectory ? .folder : .file,
            color: node.isDirectory ? ShellPalette.folderGlyph : ShellPalette.fileGlyph,
            size: node.isDirectory ? 20 : 19,
            lineWidth: 1.1
        )
        icon.alphaValue = node.isDirectory ? (depth <= 1 ? 0.85 : 0.7) : 1

        let name = ShellFont.label(
            node.name,
            font: ShellFont.ui(14.5, node.isDirectory ? .medium : .regular),
            color: WorkspaceFileRowView.nameColor(node: node, depth: depth, selected: selected)
        )

        let badge = badgeField

        var leading: NSLayoutXAxisAnchor = leadingAnchor
        var offset = indent
        if let chevron {
            addSubview(chevron)
            NSLayoutConstraint.activate([
                chevron.leadingAnchor.constraint(equalTo: leadingAnchor, constant: indent),
                chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
            leading = chevron.trailingAnchor
            offset = 5
        } else {
            // The design reserves the chevron's width on leaf rows so names
            // still line up in a column.
            offset = indent + 9
        }

        for view in [icon, name, badge] { addSubview(view) }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leading, constant: offset),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),

            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 5),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
            name.trailingAnchor.constraint(equalTo: badge.leadingAnchor, constant: -5),

            badge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),

            heightAnchor.constraint(equalToConstant: ShellMetrics.fileRowHeight),
        ])
        badge.setContentCompressionResistancePriority(.required, for: .horizontal)
        badge.setContentHuggingPriority(.required, for: .horizontal)
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        refreshBackground()
        setAccessibilityLabel(node.name)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func setExpanded(_ expanded: Bool) { chevron?.rotated = expanded }

    /// The badge is a small target, so it is grown by 6 pt on every side —
    /// enough to hit reliably, still far from the name.
    private func isBadgePoint(_ point: NSPoint) -> Bool {
        guard onBadgePress != nil, !badgeField.isHidden, !badgeField.stringValue.isEmpty else { return false }
        return badgeField.frame.insetBy(dx: -6, dy: -6).contains(point)
    }

    override func mouseDown(with event: NSEvent) {
        if isBadgePoint(convert(event.locationInWindow, from: nil)) {
            badgePressArmed = true
            return
        }
        super.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        guard badgePressArmed else {
            super.mouseUp(with: event)
            return
        }
        badgePressArmed = false
        guard isBadgePoint(convert(event.locationInWindow, from: nil)) else { return }
        onBadgePress?()
    }

    override func refreshBackground() {
        let fill: NSColor
        if isSelected {
            fill = ShellPalette.rowSelected
        } else if isHovered {
            fill = ShellPalette.hoverFile
        } else {
            fill = .clear
        }
        layer?.backgroundColor = fill.cgColor
    }

    private static func nameColor(node: WorkspaceFileNode, depth: Int, selected: Bool) -> NSColor {
        if selected { return ShellPalette.inkFile }
        if node.isDirectory { return depth == 0 ? ShellPalette.inkFolder : ShellPalette.inkSecondary }
        return node.gitBadge == nil ? ShellPalette.inkTertiary : ShellPalette.inkSecondary
    }

    static func badgeText(_ node: WorkspaceFileNode) -> String {
        if node.isDirectory { return node.changedCount == 0 ? "" : "\(node.changedCount)" }
        return node.gitBadge?.letter ?? ""
    }

    static func badgeColor(_ node: WorkspaceFileNode) -> NSColor {
        if node.isDirectory { return ShellPalette.green }
        switch node.gitBadge {
        case .modified, .renamed: return ShellPalette.amber
        case .added, .untracked: return ShellPalette.green
        case .deleted, .conflicted: return ShellPalette.red
        case nil: return .clear
        }
    }
}

/// The design's FILES section: header with the diff counts, a filter field, and
/// a lazily expanded tree with git state on the right.
final class WorkspaceFilesTreeView: NSView {
    /// `(url, pinned)` — VS Code's rule: a single click previews, a double
    /// click pins.
    var onOpenFile: ((URL, Bool) -> Void)?
    /// A git badge was clicked: show that file's diff against HEAD.
    var onOpenDiff: ((URL) -> Void)?
    /// The header's +N −M counts were clicked: show the repo-wide overview.
    var onOpenAllChanges: (() -> Void)?
    /// Every `git status` this tree loads, so the editor panes render the same
    /// snapshot the badges were drawn from rather than running git again.
    var onStatusChanged: ((GitStatus?) -> Void)?

    private let diffField = ShellFont.label(font: ShellFont.mono(12, .semibold), color: ShellPalette.green)
    /// Held so it can be disabled outside a repository — see
    /// `updateDiffHeaderAvailability`.
    private lazy var diffHeaderRecognizer = NSClickGestureRecognizer(
        target: self,
        action: #selector(diffHeaderPressed)
    )
    private let filterField = NSTextField()
    private let rows = NSStackView()
    private var root: URL?
    /// The last `git status`. Kept whole rather than reduced to its badge map
    /// so path math goes through `GitStatus`, which resolves the `/var` vs
    /// `/private/var` symlink case a string prefix silently gets wrong.
    private var gitStatus: GitStatus?
    private var expanded: Set<URL> = []
    private var selected: URL?
    /// Children already listed, so re-rendering a collapse does not re-hit the
    /// filesystem for every level.
    private var children: [URL: [WorkspaceFileNode]] = [:]
    /// The rows run their own mouse handling, so `NSEvent.clickCount` never
    /// reaches `activate(_:)`; this stands in for it.
    private var doublePress = DoublePressDetector()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        let header = ShellFont.label(
            "FILES",
            font: ShellFont.ui(12, .semibold),
            color: ShellPalette.inkMuted,
            tracking: 1.2
        )

        filterField.font = ShellFont.ui(14)
        filterField.textColor = ShellPalette.inkSecondary
        filterField.placeholderString = "Filter files"
        filterField.isBordered = false
        filterField.drawsBackground = false
        filterField.focusRingType = .none
        filterField.translatesAutoresizingMaskIntoConstraints = false
        filterField.target = self
        filterField.action = #selector(filterChanged)

        let fieldBox = NSView()
        fieldBox.wantsLayer = true
        fieldBox.layer?.backgroundColor = ShellPalette.fieldFill.cgColor
        fieldBox.layer?.cornerRadius = 6
        fieldBox.layer?.cornerCurve = .continuous
        fieldBox.layer?.borderWidth = 1
        fieldBox.layer?.borderColor = ShellPalette.hairline.cgColor
        fieldBox.translatesAutoresizingMaskIntoConstraints = false
        let magnifier = ShellGlyphView(.magnifier, color: ShellPalette.chevronSoft, size: 18, lineWidth: 1.3)
        magnifier.alphaValue = 0.45
        fieldBox.addSubview(magnifier)
        fieldBox.addSubview(filterField)

        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 0
        rows.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 8, right: 6)
        rows.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.contentView = ShellFlippedClipView()
        scroll.documentView = rows
        scroll.translatesAutoresizingMaskIntoConstraints = false

        for view in [header, diffField, fieldBox, scroll] { addSubview(view) }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),

            diffField.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            diffField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),

            fieldBox.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 5),
            fieldBox.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            fieldBox.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            fieldBox.heightAnchor.constraint(equalToConstant: 24),

            magnifier.leadingAnchor.constraint(equalTo: fieldBox.leadingAnchor, constant: 8),
            magnifier.centerYAnchor.constraint(equalTo: fieldBox.centerYAnchor),

            filterField.leadingAnchor.constraint(equalTo: magnifier.trailingAnchor, constant: 6),
            filterField.trailingAnchor.constraint(equalTo: fieldBox.trailingAnchor, constant: -8),
            filterField.centerYAnchor.constraint(equalTo: fieldBox.centerYAnchor),

            scroll.topAnchor.constraint(equalTo: fieldBox.bottomAnchor, constant: 7),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),

            rows.widthAnchor.constraint(equalTo: scroll.widthAnchor),
            rows.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
        ])
        setDiff(added: 0, removed: 0)

        // The counts are the button for the repo-wide overview — a gesture
        // recognizer rather than a button, because the design's header is a
        // two-colour attributed string and an NSButton cannot wear one
        // without a custom cell.
        diffField.addGestureRecognizer(diffHeaderRecognizer)
        diffField.setAccessibilityLabel("Show all changes")
        // Inert until a `git status` actually lands: outside a repository
        // there is no overview to show, and a click that opens a tab saying
        // so is worse than a header that simply is not a button.
        updateDiffHeaderAvailability()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    @objc private func filterChanged() { render() }

    @objc private func diffHeaderPressed() { onOpenAllChanges?() }

    /// The counts are a button only where there is a repository behind them.
    private func updateDiffHeaderAvailability() {
        let inRepository = gitStatus != nil
        diffHeaderRecognizer.isEnabled = inRepository
        diffField.setAccessibilityElement(inRepository)
        diffField.setAccessibilityRole(inRepository ? .button : .staticText)
    }

    func setDiff(added: Int, removed: Int) {
        let font = ShellFont.mono(12, .semibold)
        let string = NSMutableAttributedString(
            string: "+\(added)",
            attributes: [.font: font, .foregroundColor: ShellPalette.green]
        )
        string.append(NSAttributedString(
            string: "−\(removed)",
            attributes: [.font: font, .foregroundColor: ShellPalette.red]
        ))
        diffField.attributedStringValue = string
    }

    /// Point the tree at a workspace. Listing, `git status` and the diff totals
    /// all happen off the main thread — a cold `git status` on a large repo is
    /// tens of milliseconds and must never land on a keystroke.
    func setRoot(_ url: URL?) {
        root = url
        gitStatus = nil
        expanded = []
        children = [:]
        selected = nil
        setDiff(added: 0, removed: 0)
        updateDiffHeaderAvailability()
        render()
        // The reset is reported too: a pane must not keep rendering the last
        // workspace's changes while this one's status is still loading.
        onStatusChanged?(nil)
        guard let url else { return }

        DispatchQueue.global(qos: .userInitiated).async {
            let listing = WorkspaceFiles.children(of: url)
            let repo = GitStatus.repoRoot(for: url)
            let status = repo.flatMap { GitStatus.load(repoRoot: $0) }
            let totals = repo.flatMap { WorkspaceFilesTreeView.diffTotals(repoRoot: $0) } ?? (0, 0)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.root == url else { return }
                self.children[url] = listing
                self.gitStatus = status
                self.setDiff(added: totals.added, removed: totals.removed)
                self.updateDiffHeaderAvailability()
                self.render()
                self.onStatusChanged?(status)
            }
        }
    }

    /// `git status --porcelain` says *which* files changed but not by how much,
    /// and the design's header prints lines. One extra `--shortstat` is cheaper
    /// than parsing a full diff, and it covers staged and unstaged together.
    static func diffTotals(repoRoot: URL) -> (added: Int, removed: Int)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", repoRoot.path, "diff", "--shortstat", "HEAD"]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8)
        else { return nil }

        func number(before keyword: String) -> Int {
            guard let range = text.range(of: keyword) else { return 0 }
            let head = text[text.startIndex..<range.lowerBound]
            let digits = head.reversed().drop(while: { $0 == " " }).prefix(while: \.isNumber)
            return Int(String(digits.reversed())) ?? 0
        }
        return (number(before: "insertion"), number(before: "deletion"))
    }

    private func render() {
        for view in rows.arrangedSubviews {
            rows.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        guard let root else { return }
        let needle = filterField.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        appendRows(of: root, depth: 0, filter: needle)
    }

    private func appendRows(of directory: URL, depth: Int, filter: String) {
        let listing = children[directory] ?? []
        for node in listing {
            let matches = filter.isEmpty || node.name.lowercased().contains(filter)
            let isOpen = expanded.contains(node.url)
            // A filtered-out directory still shows when something under it
            // matches, otherwise the match would be unreachable.
            if !matches && !node.isDirectory { continue }

            let annotated = annotate(node)
            let row = WorkspaceFileRowView(
                node: annotated,
                depth: depth,
                expanded: isOpen,
                selected: node.url == selected
            )
            row.onPress = { [weak self] in self?.activate(node) }
            // Only a changed file has a badge, and only a badge is clickable:
            // a directory's count is an aggregate with no single diff behind
            // it, and a clean file has nothing to show.
            if !node.isDirectory, annotated.gitBadge != nil {
                row.onBadgePress = { [weak self] in self?.onOpenDiff?(node.url) }
            }
            rows.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rows.widthAnchor, constant: -12).isActive = true

            if node.isDirectory && isOpen {
                appendRows(of: node.url, depth: depth + 1, filter: filter)
            }
        }
    }

    /// Git state is looked up at render time from the porcelain map, so one
    /// `git status` annotates every level without re-walking.
    private func annotate(_ node: WorkspaceFileNode) -> WorkspaceFileNode {
        guard let gitStatus else { return node }
        var copy = node
        if node.isDirectory {
            copy.changedCount = gitStatus.relativePath(for: node.url)
                .map(gitStatus.changedCount(under:)) ?? 0
        } else {
            copy.gitBadge = gitStatus.badge(for: node.url)
        }
        return copy
    }

    private func activate(_ node: WorkspaceFileNode) {
        guard node.isDirectory else {
            selected = node.url
            // `systemUptime` rather than wall clock: monotonic, so a clock
            // adjustment between two clicks cannot invent or swallow a double.
            let pinned = doublePress.register(node.url.path, at: ProcessInfo.processInfo.systemUptime)
            onOpenFile?(node.url, pinned)
            render()
            return
        }
        if expanded.contains(node.url) {
            expanded.remove(node.url)
            render()
            return
        }
        expanded.insert(node.url)
        guard children[node.url] == nil else {
            render()
            return
        }
        // Expanding is the only thing that touches the disk after the first
        // load, and a cold directory on a network volume can block.
        WorkspaceFiles.list(node.url) { [weak self] listing in
            guard let self, self.expanded.contains(node.url) else { return }
            self.children[node.url] = listing
            self.render()
        }
        render()
    }
}

// MARK: - Level 2 · account row

/// The sidebar's footer. Outside the sliding track in the design, so it stays
/// put while the levels move behind it.
final class WorkspaceAccountRowView: NSView {
    var onOpenSettings: (() -> Void)?

    private let statusField = ShellFont.label(
        "Brain ready",
        font: ShellFont.ui(12),
        color: ShellPalette.green
    )

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = ShellPalette.accountFill.cgColor

        let name = NSFullUserName()
        let avatar = ShellTileView(
            size: ShellMetrics.accountAvatar,
            radius: ShellMetrics.accountAvatar / 2,
            fontSize: 12,
            circular: true
        )
        avatar.apply(
            initials: ShellPalette.initials(name),
            gradient: (
                NSColor(srgbRed: 74 / 255, green: 91 / 255, blue: 216 / 255, alpha: 1),
                NSColor(srgbRed: 139 / 255, green: 149 / 255, blue: 255 / 255, alpha: 1)
            )
        )
        let nameField = ShellFont.label(
            name,
            font: ShellFont.ui(14, .medium),
            color: NSColor(srgbRed: 216 / 255, green: 216 / 255, blue: 222 / 255, alpha: 1)
        )

        let gear = ShellRowView()
        gear.wantsLayer = true
        gear.layer?.cornerRadius = 5
        gear.hoverFill = NSColor(white: 1, alpha: 0.09)
        gear.onPress = { [weak self] in self?.onOpenSettings?() }
        gear.setAccessibilityLabel("Settings")
        gear.translatesAutoresizingMaskIntoConstraints = false
        let gearGlyph = ShellGlyphView(.gear, color: ShellPalette.chevron, size: 20)
        gear.addSubview(gearGlyph)

        let separator = ShellSeparator(color: ShellPalette.hairlineStrong)
        let text = NSView()
        text.translatesAutoresizingMaskIntoConstraints = false
        text.addSubview(nameField)
        text.addSubview(statusField)

        for view in [separator, avatar, text, gear] { addSubview(view) }
        NSLayoutConstraint.activate([
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),

            avatar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            avatar.centerYAnchor.constraint(equalTo: centerYAnchor),

            text.leadingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: 8),
            text.trailingAnchor.constraint(equalTo: gear.leadingAnchor, constant: -6),
            text.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            text.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),

            nameField.topAnchor.constraint(equalTo: text.topAnchor),
            nameField.leadingAnchor.constraint(equalTo: text.leadingAnchor),
            nameField.trailingAnchor.constraint(equalTo: text.trailingAnchor),

            statusField.topAnchor.constraint(equalTo: nameField.bottomAnchor, constant: 1),
            statusField.leadingAnchor.constraint(equalTo: text.leadingAnchor),
            statusField.trailingAnchor.constraint(equalTo: text.trailingAnchor),
            statusField.bottomAnchor.constraint(equalTo: text.bottomAnchor),

            gear.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            gear.centerYAnchor.constraint(equalTo: centerYAnchor),
            gear.widthAnchor.constraint(equalToConstant: 20),
            gear.heightAnchor.constraint(equalToConstant: 20),
            gearGlyph.centerXAnchor.constraint(equalTo: gear.centerXAnchor),
            gearGlyph.centerYAnchor.constraint(equalTo: gear.centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func setBrainStatus(_ text: String, healthy: Bool = true) {
        statusField.stringValue = text
        statusField.textColor = healthy ? ShellPalette.green : ShellPalette.amber
    }
}

// MARK: - Sidebar

/// The sidebar itself: a two-level track that slides, with the account row
/// pinned underneath it.
///
/// The slide is a constant on the track's leading constraint rather than a
/// `CATransform3D`, because the constant has to be re-derived in `layout()` —
/// the sidebar's width is fixed by the design but the window can still be
/// resized before the first pass, and a transform captured once would leave the
/// track half a level over.
final class WorkspaceSidebarView: NSView {
    var onSelectWorkspace: ((BrainProjectSummary) -> Void)?
    var onSelectDestination: ((WorkspaceDestination) -> Void)?
    var onNewWorkspace: (() -> Void)?
    var onSelectPane: ((String) -> Void)?
    var onSelectSession: ((SessionGroupNode) -> Void)?
    var onNewSession: (() -> Void)?
    var onNewTerminal: (() -> Void)?
    var onNewBrowser: (() -> Void)?
    var onNewEditor: (() -> Void)?
    var onRenameSession: ((SessionGroupNode, String) -> Void)?
    var onRenamePane: ((String, String) -> Void)?
    /// The sessions tree's hovers, forwarded to the controller — which owns
    /// the hover card, because the card is a window and the sidebar is a view.
    var onHoverTarget: ((SessionHoverCardController.Target?) -> Void)?
    var onOpenSettings: (() -> Void)?
    /// The FILES tree's `(url, pinned)`, forwarded to the controller.
    var onOpenFile: ((URL, Bool) -> Void)?
    /// The FILES tree's badge clicks, forwarded to the controller.
    var onOpenDiff: ((URL) -> Void)?
    /// The FILES header's counts, forwarded to the controller.
    var onOpenAllChanges: (() -> Void)?
    /// Every `git status` the FILES tree loads, forwarded to the controller,
    /// which fans it out to the editor panes.
    var onGitStatusChanged: ((GitStatus?) -> Void)?

    let picker = WorkspacePickerView()
    let backRow = WorkspaceBackRowView()
    let sessionsTree = SessionsTreeView()
    let filesTree = WorkspaceFilesTreeView()
    let accountRow = WorkspaceAccountRowView()

    private(set) var isShowingPicker = true
    private(set) var destination: WorkspaceDestination = .terminals
    private(set) var selectedWorkspace: BrainProjectSummary?
    private(set) var navRows: [WorkspaceNavRowView] = []

    private let track = NSView()
    /// The two rest positions, as constraints rather than a constant computed
    /// from `bounds`. The track is exactly twice the sidebar's width, so
    /// pinning its leading edge shows Level 1 and pinning its trailing edge
    /// shows Level 2 — neither depends on knowing the width during a layout
    /// pass, which is what previously left the track parked half a level over.
    private var pickerPin: NSLayoutConstraint!
    private var workspacePin: NSLayoutConstraint!
    private let navStack = NSStackView()
    /// Exposed so the suite can pin where it sits in the menu.
    private(set) var sessionsContainer = NSView()
    /// The seam above FILES, and the height it controls.
    let splitter = ShellSplitterView()
    private(set) var menuHeight: NSLayoutConstraint!
    /// The whole menu half — nav rows *and* sessions tree — scrolls as one.
    private(set) var menuScroll: ShellScrollView?
    /// Once the user has moved the seam it is theirs; before that it sits at
    /// the halfway mark.
    private(set) var hasUserAdjustedDivider = false

    /// Where the user last put the seam. Window geometry on this machine, not
    /// something the web build shares, so it lives in `UserDefaults` rather
    /// than the daemon's `brain.db` settings table.
    /// ponytail: move it to `SettingsKey` only if the seam has to follow the
    /// user to another machine.
    static let dividerDefaultsKey = "sidebarMenuHeight"

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = ShellPalette.panel.cgColor
        // The off-screen level must not paint outside the sidebar.
        layer?.masksToBounds = true

        let level2 = buildLevel2()
        // A stored seam is the user's, same as one they just dragged: it is
        // theirs from launch, not "unset until they touch it again".
        if let saved = UserDefaults.standard.object(forKey: Self.dividerDefaultsKey) as? Double {
            menuHeight.constant = saved
            hasUserAdjustedDivider = true
        }
        picker.onPick = { [weak self] workspace in self?.onSelectWorkspace?(workspace) }
        picker.onNewWorkspace = { [weak self] in self?.onNewWorkspace?() }
        backRow.onPress = { [weak self] in self?.showPicker() }
        accountRow.onOpenSettings = { [weak self] in self?.onOpenSettings?() }
        sessionsTree.onSelectPane = { [weak self] id in self?.onSelectPane?(id) }
        sessionsTree.onSelectSession = { [weak self] session in self?.onSelectSession?(session) }
        sessionsTree.onNewSession = { [weak self] in self?.onNewSession?() }
        sessionsTree.onNewTerminal = { [weak self] in self?.onNewTerminal?() }
        sessionsTree.onNewBrowser = { [weak self] in self?.onNewBrowser?() }
        sessionsTree.onNewEditor = { [weak self] in self?.onNewEditor?() }
        filesTree.onOpenFile = { [weak self] url, pinned in self?.onOpenFile?(url, pinned) }
        filesTree.onOpenDiff = { [weak self] url in self?.onOpenDiff?(url) }
        filesTree.onOpenAllChanges = { [weak self] in self?.onOpenAllChanges?() }
        filesTree.onStatusChanged = { [weak self] status in self?.onGitStatusChanged?(status) }
        sessionsTree.onRenamePane = { [weak self] paneID, name in
            self?.onRenamePane?(paneID, name)
        }
        sessionsTree.onRenameSession = { [weak self] session, name in
            self?.onRenameSession?(session, name)
        }
        sessionsTree.onHoverTarget = { [weak self] target in self?.onHoverTarget?(target) }
        for view in [track, picker, level2, accountRow] { view.translatesAutoresizingMaskIntoConstraints = false }
        addSubview(track)
        addSubview(accountRow)
        track.addSubview(picker)
        track.addSubview(level2)

        pickerPin = track.leadingAnchor.constraint(equalTo: leadingAnchor)
        workspacePin = track.trailingAnchor.constraint(equalTo: trailingAnchor)
        pickerPin.isActive = true
        NSLayoutConstraint.activate([
            track.topAnchor.constraint(equalTo: topAnchor),
            track.bottomAnchor.constraint(equalTo: accountRow.topAnchor),
            track.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 2),

            accountRow.leadingAnchor.constraint(equalTo: leadingAnchor),
            accountRow.trailingAnchor.constraint(equalTo: trailingAnchor),
            accountRow.bottomAnchor.constraint(equalTo: bottomAnchor),

            picker.leadingAnchor.constraint(equalTo: track.leadingAnchor),
            picker.widthAnchor.constraint(equalTo: widthAnchor),
            picker.topAnchor.constraint(equalTo: track.topAnchor),
            picker.bottomAnchor.constraint(equalTo: track.bottomAnchor),

            level2.leadingAnchor.constraint(equalTo: picker.trailingAnchor),
            level2.widthAnchor.constraint(equalTo: widthAnchor),
            level2.topAnchor.constraint(equalTo: track.topAnchor),
            level2.bottomAnchor.constraint(equalTo: track.bottomAnchor),
        ])

        applyDestination(.terminals)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    /// Re-clamps on every resize. Shrinking the window can otherwise leave the
    /// divider below the floor it was legal at when the user dragged it,
    /// squeezing the FILES half out of existence.
    override func layout() {
        super.layout()
        clampMenuHeight()
    }

    private func buildLevel2() -> NSView {
        navRows = WorkspaceDestination.allCases.map { destination in
            let row = WorkspaceNavRowView(destination: destination)
            row.onPress = { [weak self] in
                self?.applyDestination(destination)
                self?.onSelectDestination?(destination)
            }
            return row
        }

        sessionsContainer.translatesAutoresizingMaskIntoConstraints = false
        sessionsTree.translatesAutoresizingMaskIntoConstraints = false
        sessionsContainer.addSubview(sessionsTree)
        NSLayoutConstraint.activate([
            sessionsTree.leadingAnchor.constraint(equalTo: sessionsContainer.leadingAnchor),
            sessionsTree.trailingAnchor.constraint(equalTo: sessionsContainer.trailingAnchor),
            sessionsTree.topAnchor.constraint(equalTo: sessionsContainer.topAnchor, constant: 2),
            sessionsTree.bottomAnchor.constraint(equalTo: sessionsContainer.bottomAnchor, constant: -4),
        ])

        navStack.orientation = .vertical
        navStack.alignment = .leading
        navStack.spacing = 2
        navStack.edgeInsets = NSEdgeInsets(top: 8, left: 7, bottom: 9, right: 7)
        navStack.translatesAutoresizingMaskIntoConstraints = false

        // Dashboard, Board, Terminals — the three buttons stay one block, and
        // the sessions tree hangs directly off Terminals rather than trailing
        // the whole menu, and stays on screen no matter which button is lit.
        //
        // The buttons scroll *with* the sessions list rather than staying put
        // above a scrolling tree: at the seam's floor the three rows use the
        // whole half, so a tree that is the only scroller has nowhere to put
        // the sessions. One scroller over the lot means the user can always
        // reach them, at any seam position.
        for row in navRows {
            navStack.addArrangedSubview(row)
            if row.destination == .terminals { navStack.addArrangedSubview(sessionsContainer) }
        }
        for row in navRows {
            row.widthAnchor.constraint(equalTo: navStack.widthAnchor, constant: -14).isActive = true
            row.setContentHuggingPriority(.required, for: .vertical)
            row.setContentCompressionResistancePriority(.required, for: .vertical)
        }
        sessionsContainer.widthAnchor.constraint(equalTo: navStack.widthAnchor, constant: -14).isActive = true
        let menuScroll = ShellScrollView(documentView: navStack)
        self.menuScroll = menuScroll

        let navSeparator = ShellSeparator()
        let container = NSView()

        // The seam above FILES is a real divider now, not a decoration that
        // floated wherever the sessions list happened to end. Both halves
        // scroll, because a draggable split whose contents can be squeezed has
        // to have somewhere for the overflow to go.
        // `filesTree` already owns an internal scroll view for its rows, so it
        // is pinned to the region and compresses into it. Wrapping it in a
        // second scroll view let it keep its natural height and clipped the
        // filter field off the bottom instead.
        for view in [backRow, navSeparator, menuScroll, splitter, filesTree] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }

        menuHeight = menuScroll.heightAnchor.constraint(equalToConstant: 0)
        // Below `.required` on purpose: the very first layout runs before
        // `clampMenuHeight` has a container height to work with, and a required
        // constraint carrying a placeholder 0 would be an unsatisfiable
        // conflict rather than a value to be corrected a moment later.
        menuHeight.priority = .defaultHigh

        NSLayoutConstraint.activate([
            backRow.topAnchor.constraint(equalTo: container.topAnchor),
            backRow.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            backRow.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            navSeparator.topAnchor.constraint(equalTo: backRow.bottomAnchor),
            navSeparator.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            navSeparator.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            menuScroll.topAnchor.constraint(equalTo: navSeparator.bottomAnchor),
            menuScroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            menuScroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            menuHeight,

            splitter.topAnchor.constraint(equalTo: menuScroll.bottomAnchor),
            splitter.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            splitter.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            filesTree.topAnchor.constraint(equalTo: splitter.bottomAnchor, constant: 2),
            filesTree.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            filesTree.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            filesTree.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        splitter.onDrag = { [weak self] delta in
            guard let self else { return }
            // Downward-positive (see `ShellSplitterView.mouseDragged`), and
            // the menu is the half above the seam, so dragging down is a
            // taller menu and a shorter files list.
            hasUserAdjustedDivider = true
            menuHeight.constant += delta
            clampMenuHeight()
            UserDefaults.standard.set(Double(menuHeight.constant), forKey: Self.dividerDefaultsKey)
        }
        return container
    }

    /// The shortest the menu half is allowed to be: every nav row still on
    /// screen, plus the stack's own insets. That is the user's rule — "the
    /// highest it can go is where Dash, Board and Terminals are still
    /// visible" — expressed as a number rather than a guess, so it stays true
    /// if a row's height or the insets ever change.
    var minimumMenuHeight: CGFloat {
        let rows = navRows.reduce(0) { total, row in
            total + max(row.fittingSize.height, row.intrinsicContentSize.height)
        }
        let spacing = navStack.spacing * CGFloat(max(0, navRows.count - 1))
        return rows + spacing + navStack.edgeInsets.top + navStack.edgeInsets.bottom
    }

    /// Keeps the divider inside its limits, and seeds it on the first layout
    /// that has a real height to divide.
    func clampMenuHeight() {
        let available = bounds.height - backRow.fittingSize.height - ShellSplitterView.grabThickness
        guard available > 0 else { return }
        let lowest = minimumMenuHeight
        // Always leave room for something under the divider, or the FILES half
        // becomes a scroll view with no visible rows.
        let highest = max(lowest, available - Self.minimumFilesHeight)
        if !hasUserAdjustedDivider {
            // Halfway, until the user takes hold of it — an even split reads as
            // "both halves matter" where a content-height seam left FILES a
            // sliver on a workspace with many sessions. The clamp below keeps
            // it legal on a short window.
            menuHeight.constant = available / 2
        }
        // A flag rather than a "constant is still 0" sentinel: a drag to the
        // very top drives the constant negative, which such a sentinel read as
        // "never laid out" and answered by snapping the divider back to the
        // content height instead of holding it at the floor.
        menuHeight.constant = min(max(menuHeight.constant, lowest), highest)
    }

    /// Enough for the FILES header, its diff summary and the filter field —
    /// the parts that are always there. Below this the half stops being a
    /// files list and becomes a clipped label.
    static let minimumFilesHeight: CGFloat = 124

    // MARK: Slide

    func showPicker(animated: Bool = true) {
        guard !isShowingPicker else { return }
        isShowingPicker = true
        slide(animated: animated)
    }

    func showWorkspace(_ workspace: BrainProjectSummary?, animated: Bool = true) {
        selectedWorkspace = workspace
        backRow.apply(workspace: workspace)
        guard isShowingPicker else { return }
        isShowingPicker = false
        slide(animated: animated)
    }

    private func slide(animated: Bool) {
        workspacePin.isActive = false
        pickerPin.isActive = false
        (isShowingPicker ? pickerPin : workspacePin).isActive = true

        guard animated, !ShellMotion.reduced else {
            layoutSubtreeIfNeeded()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = ShellMotion.duration
            context.timingFunction = ShellMotion.timing
            context.allowsImplicitAnimation = true
            layoutSubtreeIfNeeded()
        }
    }

    // MARK: Content

    func setWorkspaces(_ workspaces: [BrainProjectSummary], sessionCounts: [String: Int]) {
        picker.setWorkspaces(workspaces, sessionCounts: sessionCounts)
    }

    func applyDestination(_ destination: WorkspaceDestination) {
        self.destination = destination
        for row in navRows { row.apply(selected: row.destination == destination) }
        // Terminals always shows at least its sessions, so the tree never
        // hides — switching to Dashboard or Board only changes which row is
        // lit.
    }

    /// Everything the sessions half of Level 2 renders.
    /// Where a hovered row sits on screen right now, or `nil` if it is gone or
    /// slid off with Level 1. The hover card asks this every tick rather than
    /// remembering a frame: the rows are rebuilt constantly, and the sidebar
    /// itself slides.
    func rowFrameOnScreen(for target: SessionHoverCardController.Target) -> NSRect? {
        guard let row = sessionsTree.rowView(for: target),
              let window = row.window,
              row.superview != nil,
              !row.isHiddenOrHasHiddenAncestor,
              row.bounds.width > 0
        else { return nil }
        return window.convertToScreen(row.convert(row.bounds, to: nil))
    }

    func reloadSessions(
        panes: [PaneDescriptor],
        focusedPaneID: String?,
        statuses: [String: RemoteSessionStatus],
        project: String?
    ) {
        let scoped = project.map { id in panes.filter { $0.project == id } } ?? panes
        let sessions = SessionOutline.group(scoped, focusedPaneID: focusedPaneID)
            .flatMap(\.sessions)
        var byID: [String: PaneDescriptor] = [:]
        for pane in scoped { byID[pane.sessionID] = pane }

        sessionsTree.reload(
            sessions: sessions,
            panes: byID,
            focusedPaneID: focusedPaneID,
            statuses: statuses
        )

        if let terminals = navRows.first(where: { $0.destination == .terminals }) {
            terminals.setCount(scoped.isEmpty ? nil : scoped.count)
            let current = sessions.first(where: \.isCurrent)
            let shape = PaneGrid.shape(count: max(1, current?.paneIDs.count ?? 0))
            terminals.setSubtitle(
                current.map { "\($0.label) · \(shape.rows)×\(shape.cols)" } ?? "no session"
            )
        }
    }

    /// Points the FILES tree at the open workspace's directory.
    func setFilesRoot(_ url: URL?) {
        filesTree.setRoot(url)
    }

    func setDashboardCount(_ value: Int?) {
        navRows.first(where: { $0.destination == .dashboard })?.setCount(value)
    }

    func setBoardCount(_ value: Int?) {
        navRows.first(where: { $0.destination == .board })?.setCount(value)
    }
}

// MARK: - Placeholder

/// What the content half shows for a destination that has no screen yet.
/// Dashboard and Board are deliberately empty in this step.
final class WorkspacePlaceholderView: NSView {
    private let titleField = ShellFont.label(font: ShellFont.ui(16, .semibold), color: ShellPalette.ink)
    private let subtitleField = ShellFont.label(font: ShellFont.ui(12.5), color: ShellPalette.inkMuted)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = ShellPalette.content.cgColor

        let stack = NSStackView(views: [titleField, subtitleField])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func show(_ destination: WorkspaceDestination) {
        titleField.stringValue = destination.title
        subtitleField.stringValue = "Coming in a later step."
    }
}
