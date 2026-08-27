import AppKit

// The Settings destination (2026-08-27), in the Apple TV idiom: a floating
// rounded panel of sections at the top-left of the content area — inset from
// every edge, on plain glass so the app's grey-to-black ground shows through
// — with "Settings" in the title strip above it, the way the Desk names its
// session, and the picked section's content in a centred column beside it.
// Every section still says "Under development"; the screens come one by one.
//
// Reached three ways: the sidebar gear pops a menu of the sections and lands
// on the one picked; ⌘, and the palette open the page on whatever section it
// was last on.

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
/// gradient is made of — solidly enough to read as "you are here".
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
        translatesAutoresizingMaskIntoConstraints = false

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
            widthAnchor.constraint(equalToConstant: Self.width),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
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

/// The whole Settings screen: the floating panel at the top-left, and the
/// picked section's content in Home's centred 880pt column beside it — from
/// the top, though, not from a share of the height. Transparent, like Home:
/// `PaneGroundView` behind it is the ground. The "Settings" title above the
/// panel is the window's own session-title field, which the controller
/// points at this page — see `refreshTitle`.
final class SettingsSurfaceView: NSView {
    /// The panel's inset from the content area's edges — off the edge, "a
    /// bit more inside", as the Apple TV sidebar sits.
    static let inset: CGFloat = 16

    let sidebar = SettingsSidebarView()
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

        let scroll = ShellScrollView(documentView: content)
        addSubview(scroll)
        // The panel floats over the scroll's leading edge: added after it, so
        // it is above, and the content column keeps clear of it by its own
        // leading constraint.
        addSubview(sidebar)
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.inset),
            sidebar.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            sidebar.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -Self.inset),

            scroll.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: Self.inset),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),

            column.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            column.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -36),
            column.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            column.leadingAnchor.constraint(greaterThanOrEqualTo: content.leadingAnchor, constant: 24),
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
