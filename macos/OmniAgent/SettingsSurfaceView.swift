import AppKit

// The Settings destination (2026-08-27): a second sidebar column inside the
// content area — the left menu's own glass and nav rows, one level in — and
// beside it a centred column that, for now, says "Under development" for
// every section. The list is the design's; the sections' screens come one
// by one, on top of this.

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

/// The column of sections: the left menu's glass, edge and nav rows, so the
/// two sidebars read as one family.
final class SettingsSidebarView: NSView {
    static let width: CGFloat = 220

    private(set) var rows: [SidebarNavRowView] = []
    var onSelect: ((SettingsSection) -> Void)?
    /// The Liquid Glass sheet on macOS 26, `nil` below — the exact treatment
    /// `NavigationSidebarView.glassHost` gives the left menu.
    private(set) var glassHost: NSView?
    private var glassTint: NSView?
    let trailingEdge = NSView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

        let tint = ShellGlassTintView()
        if let glass = WorkspaceGlass.sheet(content: tint) {
            glassHost = glass
            glassTint = tint
            addSubview(glass)
        }

        rows = SettingsSection.allCases.map { section in
            let row = SidebarNavRowView(title: section.title, symbol: section.symbol)
            row.onPress = { [weak self] in self?.onSelect?(section) }
            return row
        }
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 8, bottom: 0, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        for (index, section) in SettingsSection.allCases.enumerated() {
            rows[index].widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -16).isActive = true
            if section.startsGroup, index > 0 { stack.setCustomSpacing(18, after: rows[index - 1]) }
        }
        addSubview(stack)

        trailingEdge.wantsLayer = true
        trailingEdge.layer?.backgroundColor = ShellPalette.sidebarEdge.cgColor
        trailingEdge.translatesAutoresizingMaskIntoConstraints = false
        addSubview(trailingEdge)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.width),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            trailingEdge.trailingAnchor.constraint(equalTo: trailingAnchor),
            trailingEdge.topAnchor.constraint(equalTo: topAnchor),
            trailingEdge.bottomAnchor.constraint(equalTo: bottomAnchor),
            trailingEdge.widthAnchor.constraint(equalToConstant: 1),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func layout() {
        super.layout()
        glassHost?.frame = bounds
        glassTint?.frame = NSRect(origin: .zero, size: bounds.size)
    }

    /// Below macOS 26 only — with glass, a sheet covers these bounds already.
    override func draw(_ dirtyRect: NSRect) {
        guard glassHost == nil else { return }
        ShellPalette.sidebarGlass.draw(in: bounds, angle: -90)
    }

    func apply(selected: SettingsSection) {
        for (row, section) in zip(rows, SettingsSection.allCases) {
            row.apply(selected: section == selected)
        }
    }
}

/// The whole Settings screen: the sections column on the left, and the
/// picked section's content in Home's centred 880pt column on the right —
/// from the top, though, not from a share of the height. Transparent, like
/// Home: `PaneGroundView` behind it is the ground.
final class SettingsSurfaceView: NSView {
    let sidebar = SettingsSidebarView()
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
        addSubview(sidebar)

        let column = NSStackView(views: [titleField, subtitleField])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 6
        column.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(column)

        let scroll = ShellScrollView(documentView: content)
        addSubview(scroll)
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: bottomAnchor),

            scroll.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),

            column.topAnchor.constraint(equalTo: content.topAnchor, constant: 48),
            column.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -36),
            column.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            column.leadingAnchor.constraint(greaterThanOrEqualTo: content.leadingAnchor, constant: 40),
        ])
        let width = column.widthAnchor.constraint(equalToConstant: 880)
        width.priority = .defaultHigh
        width.isActive = true

        sidebar.onSelect = { [weak self] section in self?.select(section) }
        select(.general)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func select(_ section: SettingsSection) {
        self.section = section
        sidebar.apply(selected: section)
        titleField.stringValue = section.title
    }
}
