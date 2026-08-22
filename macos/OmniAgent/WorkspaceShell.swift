import AppKit

// The workspace shell's shared vocabulary, from the "OmniAgent ADE" design doc
// (design/OmniAgent ADE.dc.html, the 2026-08-10 import): the palette, metrics,
// glyphs and row classes every sidebar surface draws with, plus the session
// row and the files tree the surfaces mount. The sidebar *column* itself is
// `NavigationSidebarView` (NavigationSidebar.swift), and the workspaces tree
// it mounts is `WorkspacesTreeView` (WorkspacesTree.swift) — the 2026-08-20
// redesign replaced this file's two-level sliding track with that one flat
// column.
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

/// The content area's destinations. Home and To Do List are the redesign's
/// placeholder screens; `terminals` is the Desk — the pane workspace — which
/// no longer has a sidebar row and is reached through the sessions tree, the
/// menu and the palette.
enum WorkspaceDestination: String, CaseIterable {
    case home
    case todo
    case terminals

    var title: String {
        switch self {
        case .home: return "Home"
        case .todo: return "To Do List"
        case .terminals: return "Desk"
        }
    }

    /// The palette row's second line.
    var subtitle: String {
        switch self {
        case .home, .todo: return "under development"
        case .terminals: return "no session"
        }
    }

    /// The SF Symbol the spotlight draws for this destination — the same set
    /// the sidebar's nav rows wear.
    var paletteSymbol: String {
        switch self {
        case .home: return "house"
        case .todo: return "checklist"
        case .terminals: return "rectangle.split.2x2"
        }
    }
}

// MARK: - Palette

/// The design doc's dark tokens, once. Deliberately not
/// `NSColor.controlAccentColor` and friends: this window is pinned to
/// `.darkAqua` with its own near-black ground, and the design specifies exact
/// values that must not drift with the user's system accent.
enum ShellPalette {
    static let content = srgb(10, 10, 12)

    /// The sidebar's ground *below macOS 26*: a top-lit blue-black sheet, so
    /// the column reads as glass over the flat `content` black rather than a
    /// second slab of it. There is no Liquid Glass to ask for that far back,
    /// and every stand-in dims rather than refracts, so this paints the look
    /// by hand.
    ///
    /// On 26 and later the column is a real `NSGlassEffectView` wearing
    /// `sidebarGlassTint` instead — see `NavigationSidebarView.glassHost`.
    static let sidebarGlass = NSGradient(
        colors: [srgb(28, 32, 52), srgb(13, 14, 22)]
    )!

    /// The same blue, washed *over* the glass column rather than painted as
    /// its ground. Translucent where `sidebarGlass` is opaque: a solid
    /// gradient over Liquid Glass is paint, and hides the material it is there
    /// to tint.
    ///
    /// Solved against the material, not against the window. The obvious
    /// arithmetic — take `sidebarGlass`'s stops and divide them back out of
    /// their own alpha over the window's `8, 10, 14` ground — is wrong here,
    /// because the wash does not sit on that ground: `.regular` glass in the
    /// dark appearance carries its own frosting, measured at roughly
    /// `66, 72, 78` under the column's head and `54, 57, 65` at its foot. A
    /// wash solved against near-black lands about twice as light as intended
    /// and reads slate rather than blue.
    ///
    /// So these are solved against those two readings. Measured off the built
    /// app, the column now runs `44, 52, 87` down to `29, 32, 52` — the
    /// design's hue and its top-lighting, and a foot that lands on
    /// `sidebarGlass`'s own head,
    /// sitting lighter than the flat token because it is glass and meant to
    /// look like it. Deep navy over a bright material, and the alpha falls with
    /// the light — the sheet shows through most where the column is dimmest.
    static let sidebarGlassTint = [srgb(30, 38, 84, 0.70), srgb(6, 9, 30, 0.52)]

    /// The line down the column's trailing edge — where the sidebar stops and
    /// the pane black starts.
    ///
    /// Grey rather than a lighter step of the column's blue, which would read
    /// as the column's own edge rather than as a border between two things.
    /// It is not the glass sheet's rim either: that rim exists, and measured
    /// `64, 65, 71` at its brightest against the pane black, which is present
    /// without being a separation. This is drawn on every OS — below macOS 26
    /// there is no sheet and so no rim at all.
    static let sidebarEdge = srgb(107, 107, 107)

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
    /// The design width, and what offscreen renders are sized at.
    static let sidebarWidth: CGFloat = 280
    /// How far the sidebar may be dragged. The *live* width is whatever the
    /// divider was last left at (`NSSplitView` autosaves it) clamped to these,
    /// so the floor is the width the column actually opens at for anyone who
    /// has dragged it down — it is the number to move to make the menu bigger,
    /// not `sidebarWidth`. The ceiling keeps the pane grid the larger half on
    /// any window this app opens at.
    static let sidebarMinimumWidth: CGFloat = 240
    static let sidebarMaximumWidth: CGFloat = 560
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

/// Path prose, the way the design writes it.
enum ShellPath {
    /// `/Users/me/Code/x` -> `~/Code/x`.
    static func abbreviate(_ path: String?) -> String {
        guard let path, !path.isEmpty else { return "—" }
        return (path as NSString).abbreviatingWithTildeInPath
    }
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
    case folderOpen
    case file
    case magnifier

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
        case .folderOpen:
            // The closed glyph with its front swung out — the workspace row's
            // "expanded" state. Two filled shapes: the back band with the tab,
            // and the tilted front flap overlapping it.
            path.move(to: NSPoint(x: 2, y: 8))
            path.line(to: NSPoint(x: 2, y: 4.6))
            path.line(to: NSPoint(x: 3.2, y: 3.4))
            path.line(to: NSPoint(x: 5.6, y: 3.4))
            path.line(to: NSPoint(x: 6.8, y: 4.8))
            path.line(to: NSPoint(x: 13, y: 4.8))
            path.line(to: NSPoint(x: 13, y: 8))
            path.close()
            path.fill()
            let flap = NSBezierPath()
            flap.move(to: NSPoint(x: 3.6, y: 7))
            flap.line(to: NSPoint(x: 14.4, y: 7))
            flap.line(to: NSPoint(x: 12.6, y: 12.6))
            flap.line(to: NSPoint(x: 2, y: 12.6))
            flap.close()
            flap.fill()
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

/// A scroll view for a sidebar region. Top-anchored content, scrollers only
/// when the content genuinely does not fit.
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

// MARK: - Session rows

/// The amber "inputs waiting" pill: the count of terminals blocked on a
/// question, worn by the session row — with the pane rows gone from the
/// sidebar it is the one place the count can live.
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

/// A session row — the tree's leaf: name, per-pane status dots, and nothing
/// else (the 2026-08-20 redesign removed the pane rows underneath it, so it
/// no longer discloses anything).
final class SessionRowView: ShellRowView, NSTextFieldDelegate {
    let session: SessionGroupNode
    /// Double-click to rename, the affordance the old outline used to provide.
    /// The design does not draw a rename control, but dropping the capability
    /// along with the outline would be a silent regression.
    var onRename: ((String) -> Void)?
    /// The row's context menu, built fresh per right-click by whoever can
    /// resolve the session — `WorkspaceRowView.onContextMenu`'s contract.
    var onContextMenu: (() -> NSMenu?)?

    private let titleField: NSTextField
    private let dots = ShellDotsView()
    private let bar = NSView()
    private let isCurrent: Bool
    /// A nested session — indented under its parent, wearing the connector
    /// and the dimmed workspace name (the 2026-08-20 redesign's §3).
    let isNested: Bool
    private(set) var connector: SessionRowConnectorView?
    private(set) var workspaceTag: NSTextField?
    /// The amber waiting-inputs count, worn whenever a terminal of this
    /// session is blocked on a question — the session-level "requires
    /// attention", now that the terminal rows themselves are gone.
    private(set) var awaitingBadge: ShellAwaitingBadgeView?

    init(
        session: SessionGroupNode,
        statuses: [RemoteSessionStatus?],
        awaitingCount: Int = 0,
        nested: Bool = false,
        workspaceName: String? = nil
    ) {
        self.session = session
        isCurrent = session.isCurrent
        isNested = nested
        titleField = ShellFont.label(
            session.label,
            font: ShellFont.ui(14, session.isCurrent ? .semibold : .medium),
            color: session.isCurrent ? ShellPalette.ink : ShellPalette.inkSecondary
        )
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.cornerCurve = .continuous
        hoverEnabled = false

        bar.wantsLayer = true
        bar.layer?.cornerRadius = 2
        bar.layer?.backgroundColor = (session.isCurrent ? ShellPalette.accent : .clear).cgColor
        bar.translatesAutoresizingMaskIntoConstraints = false

        dots.apply(
            statuses.map(ShellDotsView.color(for:)),
            pulsing: Set(statuses.enumerated().compactMap { ShellDotsView.pulses($1) ? $0 : nil })
        )

        // Nested rows step one level right of their parent's own indent.
        let indent: CGFloat = nested ? 14 : 0
        for view in [bar, titleField, dots] { addSubview(view) }
        NSLayoutConstraint.activate([
            // Indented under its workspace row — the folder's label column.
            bar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16 + indent),
            bar.widthAnchor.constraint(equalToConstant: 2.5),
            bar.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            bar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),

            titleField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 30 + indent),
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleField.trailingAnchor.constraint(equalTo: dots.leadingAnchor, constant: -8),

            dots.centerYAnchor.constraint(equalTo: centerYAnchor),

            topAnchor.constraint(equalTo: titleField.topAnchor, constant: -6),
            bottomAnchor.constraint(equalTo: titleField.bottomAnchor, constant: 6),
        ])
        if nested {
            // The small tree connector: down from under the parent's rail,
            // elbow toward this row's own bar.
            let line = SessionRowConnectorView()
            connector = line
            addSubview(line)
            NSLayoutConstraint.activate([
                line.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 19),
                line.widthAnchor.constraint(equalToConstant: 8),
                line.topAnchor.constraint(equalTo: topAnchor),
                line.bottomAnchor.constraint(equalTo: centerYAnchor),
            ])
        }
        // The dimmed workspace name at the row's right edge — only nested
        // rows wear it, so a child never loses which workspace it acts in.
        var trailingEdge = trailingAnchor
        if nested, let workspaceName, !workspaceName.isEmpty {
            let tag = ShellFont.label(
                workspaceName,
                font: ShellFont.ui(11),
                color: ShellPalette.inkFaint
            )
            workspaceTag = tag
            addSubview(tag)
            NSLayoutConstraint.activate([
                tag.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
                tag.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
            tag.setContentCompressionResistancePriority(.init(740), for: .horizontal)
            trailingEdge = tag.leadingAnchor
        }
        // The session-level view of "how many of mine are asking" — with the
        // pane rows gone from the sidebar, this is where a session needing
        // attention says so; the pane's own approval bar says *which* one.
        if awaitingCount > 0 {
            let badge = ShellAwaitingBadgeView(count: awaitingCount)
            awaitingBadge = badge
            addSubview(badge)
            NSLayoutConstraint.activate([
                dots.trailingAnchor.constraint(equalTo: badge.leadingAnchor, constant: -8),
                badge.trailingAnchor.constraint(equalTo: trailingEdge, constant: -8),
                badge.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
        } else {
            dots.trailingAnchor.constraint(equalTo: trailingEdge, constant: -8).isActive = true
        }
        dots.setContentCompressionResistancePriority(.init(751), for: .horizontal)
        titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        refreshBackground()
        setAccessibilityLabel("Session \(session.label)")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

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

    override func menu(for event: NSEvent) -> NSMenu? {
        onContextMenu?() ?? super.menu(for: event)
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

// MARK: - Placeholder

/// What the content half shows for a destination that has no screen yet.
/// Home and To Do List are deliberately empty in this step of the redesign.
final class WorkspacePlaceholderView: NSView {
    private let titleField = ShellFont.label(font: ShellFont.ui(16, .semibold), color: ShellPalette.ink)
    private let subtitleField = ShellFont.label(font: ShellFont.ui(12.5), color: ShellPalette.inkMuted)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // Paints nothing. Home and To Do List are the *same* surface the Desk
        // is — `PaneGroundView` behind this view, running from the window's top
        // edge — and an opaque fill here made switching destination look like
        // switching apps.
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
        subtitleField.stringValue = "Under development"
    }

    /// What the placeholder currently says — for the tests, without walking
    /// the view tree.
    var titleText: String { titleField.stringValue }
    var subtitleText: String { subtitleField.stringValue }
}
