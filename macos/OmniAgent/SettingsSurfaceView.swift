import AppKit

// The Settings destination (2026-08-27): a second sidebar column inside the
// content area — the left menu's nav rows on a sheet of *plain* glass, so
// the app's grey-to-black ground shows through and the column reads as a
// different thing from the blue left menu — running edge to edge under the
// window chrome, and beside it the picked section's name up in the title
// strip (where the Desk puts the session's name) over a centred column
// that, for now, says "Under development". The list is the design's; the
// sections' screens come one by one, on top of this.

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

/// The column of sections: the left menu's edge and nav rows on untinted
/// glass — same family, different colour, on purpose.
final class SettingsSidebarView: NSView {
    static let width: CGFloat = 220

    private(set) var rows: [SidebarNavRowView] = []
    var onSelect: ((SettingsSection) -> Void)?
    /// The Liquid Glass sheet on macOS 26, `nil` below — the left menu's
    /// sheet without its blue wash.
    private(set) var glassHost: NSView?
    let trailingEdge = NSView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

        if let glass = WorkspaceGlass.sheet() {
            glassHost = glass
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
        // The column runs under the window chrome; the rows clear it, exactly
        // as the left menu's do.
        stack.edgeInsets = NSEdgeInsets(top: WorkspaceTitleBarView.height + 6, left: 8, bottom: 0, right: 8)
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
    }

    /// Below macOS 26 only — a whisper of white, so the column still reads
    /// as a column on the bare ground.
    override func draw(_ dirtyRect: NSRect) {
        guard glassHost == nil else { return }
        ShellPalette.cardFill.setFill()
        bounds.fill()
    }

    func apply(selected: SettingsSection) {
        for (row, section) in zip(rows, SettingsSection.allCases) {
            row.apply(selected: section == selected)
        }
    }
}

/// The whole Settings screen: the sections column on the left, the picked
/// section's name in the title strip, and its content in Home's centred
/// 880pt column — from the top, though, not from a share of the height.
/// Mounted at the window's top edge, not under the title bar, so the column
/// reaches it. Transparent, like Home: `PaneGroundView` behind it is the
/// ground.
final class SettingsSurfaceView: NSView {
    let sidebar = SettingsSidebarView()
    /// The section's name, in the strip the title bar leaves clear — the
    /// exact place and face `sessionTitleField` gives a session's name.
    let titleField = ShellFont.label(font: ShellFont.ui(13, .medium), color: ShellPalette.inkSecondary)
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

        let column = NSStackView(views: [subtitleField])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 6
        column.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(column)

        let scroll = ShellScrollView(documentView: content)
        addSubview(scroll)
        titleField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleField)
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: bottomAnchor),

            titleField.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: 12),
            titleField.centerYAnchor.constraint(equalTo: topAnchor, constant: WorkspaceTitleBarView.height / 2),

            scroll.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor, constant: WorkspaceTitleBarView.height),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),

            column.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
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
