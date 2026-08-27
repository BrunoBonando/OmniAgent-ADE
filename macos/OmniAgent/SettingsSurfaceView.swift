import AppKit

// The Settings destination (2026-08-27), in the Apple TV idiom: a floating
// rounded panel of sections at the top-left of the content area — inset from
// every edge, on plain glass so the app's grey-to-black ground shows through
// — with "Settings" in the title strip above it, the way the Desk names its
// session, and the picked section's content in a centred column beside it.
// Every section still says "Under development"; the screens come one by one.
//
// The panel is one object in two roles (2026-08-28): the sidebar gear
// *offers* it beside itself, tip on the gear, as the menu; a pick slides it
// up to *dock* under the title as the page's sidebar; the gear again brings
// it back down to pick anew. `WorkspaceWindowController` owns it and places
// it — it floats over the content area, not inside this page — so the same
// glass travels between the two places instead of a popup standing in for
// it. ⌘, and the palette open the page on whatever section it was last on.

/// The Settings page's sections, in the design's order. `startsGroup` marks
/// the gaps in the list: General…Accessibility, Customize/Model providers,
/// Experimental.
enum SettingsSection: String, CaseIterable {
    case general
    case accounts
    case sessions
    case themes
    case accessibility
    case customize
    case modelProviders
    case experimental

    var title: String {
        switch self {
        case .general: return "General"
        case .accounts: return "Accounts"
        case .sessions: return "Sessions"
        case .themes: return "Themes"
        case .accessibility: return "Accessibility"
        case .customize: return "Customize"
        case .modelProviders: return "Model providers"
        case .experimental: return "Experimental"
        }
    }

    /// SF Symbols approximating the design's set.
    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .accounts: return "person.2"
        case .sessions: return "arrow.triangle.branch"
        case .themes: return "paintpalette"
        case .accessibility: return "accessibility"
        case .customize: return "square.grid.2x2"
        case .modelProviders: return "cpu"
        case .experimental: return "flask"
        }
    }

    var startsGroup: Bool { self == .customize || self == .experimental }
}

/// The floating panel of sections: the left menu's nav rows on a rounded
/// sheet of untinted glass, hugging its rows rather than the window's
/// height. The picked row wears the app's accent — the blue the left menu's
/// gradient is made of — solidly enough to read as "you are here". Placed by
/// frame (its owner slides it about), sized `width` × `fittingSize.height`.
final class SettingsSidebarView: NSView {
    static let width: CGFloat = 220
    static let cornerRadius: CGFloat = 16

    private(set) var rows: [SidebarNavRowView] = []
    var onSelect: ((SettingsSection) -> Void)?
    /// The Liquid Glass sheet on macOS 26, `nil` below — the left menu's
    /// sheet without its blue wash, and with corners.
    private(set) var glassHost: NSView?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        if let glass = WorkspaceGlass.sheet(cornerRadius: Self.cornerRadius) {
            glassHost = glass
            addSubview(glass)
        } else {
            layer?.cornerRadius = Self.cornerRadius
            layer?.cornerCurve = .continuous
            layer?.backgroundColor = ShellPalette.cardFill.cgColor
            layer?.borderWidth = 1
            layer?.borderColor = ShellPalette.hairlineStrong.cgColor
        }

        rows = SettingsSection.allCases.map { section in
            let row = SidebarNavRowView(
                title: section.title,
                symbol: section.symbol,
                selectedFill: ShellPalette.accentFill
            )
            row.onPress = { [weak self] in self?.onSelect?(section) }
            return row
        }
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        for (index, section) in SettingsSection.allCases.enumerated() {
            rows[index].widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20).isActive = true
            if section.startsGroup, index > 0 { stack.setCustomSpacing(18, after: rows[index - 1]) }
        }
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        // Frame-placed: start at the size the rows need, or the zero frame
        // stands as a required `height == 0` against the rows until the
        // owner's first placement ("Unable to simultaneously satisfy").
        frame.size = NSSize(width: Self.width, height: fittingSize.height)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func layout() {
        super.layout()
        glassHost?.frame = bounds
    }

    func apply(selected: SettingsSection) {
        for (row, section) in zip(rows, SettingsSection.allCases) {
            row.apply(selected: section == selected)
        }
    }
}

/// The tip the offered panel wears on the gear: a rounded square turned 45°
/// in a box of its bounding span, half tucked under the panel (the owner
/// stacks the panel above it), so the half that shows is a point. The box is
/// what gets moved — setting `frame` on a rotated view resizes its bounds to
/// keep the bounding box.
final class SettingsPanelTipView: NSView {
    static let side: CGFloat = 12
    static var span: CGFloat { side * 2.squareRoot() }

    override init(frame frameRect: NSRect) {
        super.init(frame: NSRect(origin: frameRect.origin, size: NSSize(width: Self.span, height: Self.span)))
        let square = NSView(frame: NSRect(
            x: (Self.span - Self.side) / 2,
            y: (Self.span - Self.side) / 2,
            width: Self.side,
            height: Self.side
        ))
        square.wantsLayer = true
        square.layer?.cornerRadius = 2
        // The hover card's bead colour — the dark a glass card settles on.
        square.layer?.backgroundColor = NSColor(srgbRed: 0.12, green: 0.13, blue: 0.20, alpha: 0.92).cgColor
        square.frameCenterRotation = 45
        addSubview(square)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
}

/// The Settings page's content: the picked section's name and body in
/// Home's centred 880pt column, clear of the docked panel on the left —
/// from the top, though, not from a share of the height. Transparent, like
/// Home: `PaneGroundView` behind it is the ground. The panel itself and the
/// "Settings" title above it are the controller's — see `settingsPanel` and
/// `refreshTitle`.
final class SettingsSurfaceView: NSView {
    /// The room the docked panel takes on the left: the title's 12pt inset,
    /// the panel, and a gutter.
    static let panelRoom = 12 + SettingsSidebarView.width + 16

    /// The picked section's name, heading its content.
    let titleField = ShellFont.label(font: ShellFont.ui(22, .semibold), color: ShellPalette.ink)
    let subtitleField = ShellFont.label(
        "Under development",
        font: ShellFont.ui(13),
        color: ShellPalette.inkMuted
    )
    /// The section on screen. Sticks for as long as the app lives, like
    /// Home's own picks.
    private(set) var section: SettingsSection = .general

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let column = NSStackView(views: [titleField, subtitleField])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 6
        column.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(column)

        let scroll = ShellScrollView(
            documentView: content,
            topFade: ShellScrollView.pageFade,
            topInset: WorkspaceTitleBarView.height
        )
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.panelRoom),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),

            // Past the fade band, so the heading is whole at rest.
            column.topAnchor.constraint(
                equalTo: content.topAnchor,
                constant: ShellScrollView.pageFade - WorkspaceTitleBarView.height + 8
            ),
            column.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -36),
            column.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            column.leadingAnchor.constraint(greaterThanOrEqualTo: content.leadingAnchor, constant: 24),
        ])
        let width = column.widthAnchor.constraint(equalToConstant: 880)
        width.priority = .defaultHigh
        width.isActive = true

        select(.general)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func select(_ section: SettingsSection) {
        self.section = section
        titleField.stringValue = section.title
    }
}
