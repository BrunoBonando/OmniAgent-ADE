import AppKit

// The flat Copilot-style sidebar — the 2026-08-20 navigation redesign
// (docs/superpowers/specs/2026-08-20-copilot-nav-redesign-design.md). One
// straight column in the existing `ShellPalette` language: fixed nav rows on
// top (Home, To Do List, Search), then the Workspaces section holding the
// sessions tree, and the account row pinned at the bottom. It replaces the
// two-level sliding track `WorkspaceShell.swift` used to build; that file
// keeps the shared tokens, glyphs and the trees this column still mounts.

// MARK: - Fixed nav rows

/// The sidebar's three fixed rows. Home and To Do List are destinations;
/// Search only acts — it raises the spotlight and selects nothing.
enum SidebarNavItem: CaseIterable {
    case home
    case todo
    case search

    var title: String {
        switch self {
        case .home: return "Home"
        case .todo: return "To Do List"
        case .search: return "Search"
        }
    }

    /// SF Symbols approximating Copilot's set.
    var symbol: String {
        switch self {
        case .home: return "house"
        case .todo: return "checklist"
        case .search: return "magnifyingglass"
        }
    }

    /// Where the row routes, or `nil` for a row that only acts.
    var destination: WorkspaceDestination? {
        switch self {
        case .home: return .home
        case .todo: return .todo
        case .search: return nil
        }
    }
}

/// One fixed nav row: symbol and label, flat and squared.
final class SidebarNavRowView: ShellRowView {
    let item: SidebarNavItem

    private let icon = NSImageView()
    private let titleField: NSTextField
    private(set) var isSelected = false

    init(item: SidebarNavItem) {
        self.item = item
        titleField = ShellFont.label(
            item.title,
            font: ShellFont.ui(13.5, .medium),
            color: ShellPalette.inkNav
        )
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous
        hoverEnabled = false

        icon.image = NSImage(
            systemSymbolName: item.symbol,
            accessibilityDescription: item.title
        )?.withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
        icon.contentTintColor = ShellPalette.inkNav
        icon.translatesAutoresizingMaskIntoConstraints = false

        for view in [icon, titleField] { addSubview(view) }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 30),

            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.heightAnchor.constraint(equalToConstant: 18),

            titleField.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            titleField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        refreshBackground()
        setAccessibilityLabel(item.title)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func apply(selected: Bool) {
        isSelected = selected
        titleField.textColor = selected ? ShellPalette.ink : ShellPalette.inkNav
        icon.contentTintColor = selected ? ShellPalette.ink : ShellPalette.inkNav
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

// MARK: - Section header

/// The "Workspaces" section header. Its group-by and plus buttons arrive in a
/// later task of the same redesign.
final class SidebarSectionHeaderView: NSView {
    private let titleField: NSTextField

    init(title: String) {
        titleField = ShellFont.label(
            title,
            font: ShellFont.ui(11.5, .semibold),
            color: ShellPalette.inkMuted,
            tracking: 0.5
        )
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleField)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 22),
            titleField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 17),
            titleField.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(title)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    var title: String { titleField.stringValue }
}

// MARK: - Account row

/// The pinned footer: a generic avatar circle and "Not signed in" until real
/// accounts exist, plus the gear that opens the app's existing Settings
/// surface.
final class SidebarAccountRowView: NSView {
    var onOpenSettings: (() -> Void)?

    private let nameField = ShellFont.label(
        "Not signed in",
        font: ShellFont.ui(13.5, .medium),
        color: ShellPalette.inkTertiary
    )

    /// Exposed so a test can press the gear the way a user does.
    private(set) var gear = ShellRowView()

    /// What the row says about the account — a fact a test can read without
    /// walking the view tree.
    var accountLabel: String { nameField.stringValue }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = ShellPalette.accountFill.cgColor
        translatesAutoresizingMaskIntoConstraints = false

        let avatar = NSView()
        avatar.wantsLayer = true
        avatar.layer?.cornerRadius = ShellMetrics.accountAvatar / 2
        avatar.layer?.backgroundColor = ShellPalette.iconTile.cgColor
        avatar.layer?.borderWidth = 1
        avatar.layer?.borderColor = ShellPalette.hairlineStrong.cgColor
        avatar.translatesAutoresizingMaskIntoConstraints = false
        let person = NSImageView()
        person.image = NSImage(
            systemSymbolName: "person.fill",
            accessibilityDescription: "Account"
        )?.withSymbolConfiguration(.init(pointSize: 10, weight: .medium))
        person.contentTintColor = ShellPalette.inkMuted
        person.translatesAutoresizingMaskIntoConstraints = false
        avatar.addSubview(person)

        gear.wantsLayer = true
        gear.layer?.cornerRadius = 5
        gear.hoverFill = NSColor(white: 1, alpha: 0.09)
        gear.onPress = { [weak self] in self?.onOpenSettings?() }
        gear.setAccessibilityLabel("Settings")
        gear.translatesAutoresizingMaskIntoConstraints = false
        let gearGlyph = ShellGlyphView(.gear, color: ShellPalette.chevron, size: 20)
        gear.addSubview(gearGlyph)

        let separator = ShellSeparator(color: ShellPalette.hairlineStrong)
        for view in [separator, avatar, nameField, gear] { addSubview(view) }
        NSLayoutConstraint.activate([
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),

            avatar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            avatar.centerYAnchor.constraint(equalTo: centerYAnchor),
            avatar.widthAnchor.constraint(equalToConstant: ShellMetrics.accountAvatar),
            avatar.heightAnchor.constraint(equalToConstant: ShellMetrics.accountAvatar),
            person.centerXAnchor.constraint(equalTo: avatar.centerXAnchor),
            person.centerYAnchor.constraint(equalTo: avatar.centerYAnchor),

            nameField.leadingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: 8),
            nameField.trailingAnchor.constraint(equalTo: gear.leadingAnchor, constant: -6),
            nameField.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            nameField.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),

            gear.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            gear.centerYAnchor.constraint(equalTo: centerYAnchor),
            gear.widthAnchor.constraint(equalToConstant: 20),
            gear.heightAnchor.constraint(equalToConstant: 20),
            gearGlyph.centerXAnchor.constraint(equalTo: gear.centerXAnchor),
            gearGlyph.centerYAnchor.constraint(equalTo: gear.centerYAnchor),
        ])
        nameField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Not signed in")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
}

// MARK: - The sidebar

/// The sidebar itself: one flat column, top to bottom — nav rows, the
/// Workspaces section with the sessions tree, the account row.
final class NavigationSidebarView: NSView {
    /// Home or To Do List was pressed (Search never routes here).
    var onSelectDestination: ((WorkspaceDestination) -> Void)?
    /// The Search row: raise the spotlight. Deliberately not a selection —
    /// the lit row stays wherever it was.
    var onSearch: (() -> Void)?
    var onSelectPane: ((String) -> Void)?
    var onSelectSession: ((SessionGroupNode) -> Void)?
    var onNewSession: (() -> Void)?
    var onRenameSession: ((SessionGroupNode, String) -> Void)?
    var onRenamePane: ((String, String) -> Void)?
    /// The sessions tree's hovers, forwarded to the controller — which owns
    /// the hover card, because the card is a window and the sidebar is a view.
    var onHoverTarget: ((SessionHoverCardController.Target?) -> Void)?
    var onOpenSettings: (() -> Void)?

    private(set) var navRows: [SidebarNavRowView] = []
    let workspacesHeader = SidebarSectionHeaderView(title: "Workspaces")
    let sessionsTree = SessionsTreeView()
    let accountRow = SidebarAccountRowView()
    private(set) var destination: WorkspaceDestination = .terminals

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = ShellPalette.panel.cgColor

        navRows = SidebarNavItem.allCases.map { item in
            let row = SidebarNavRowView(item: item)
            row.onPress = { [weak self] in
                guard let self else { return }
                if let destination = item.destination {
                    applyDestination(destination)
                    onSelectDestination?(destination)
                } else {
                    onSearch?()
                }
            }
            return row
        }

        let navStack = NSStackView(views: navRows)
        navStack.orientation = .vertical
        navStack.alignment = .leading
        navStack.spacing = 2
        navStack.edgeInsets = NSEdgeInsets(top: 10, left: 8, bottom: 0, right: 8)
        navStack.translatesAutoresizingMaskIntoConstraints = false
        for row in navRows {
            row.widthAnchor.constraint(equalTo: navStack.widthAnchor, constant: -16).isActive = true
        }

        let scroll = ShellScrollView(documentView: sessionsTree)

        accountRow.onOpenSettings = { [weak self] in self?.onOpenSettings?() }
        sessionsTree.onSelectPane = { [weak self] id in self?.onSelectPane?(id) }
        sessionsTree.onSelectSession = { [weak self] session in self?.onSelectSession?(session) }
        sessionsTree.onNewSession = { [weak self] in self?.onNewSession?() }
        sessionsTree.onRenameSession = { [weak self] session, name in
            self?.onRenameSession?(session, name)
        }
        sessionsTree.onRenamePane = { [weak self] paneID, name in
            self?.onRenamePane?(paneID, name)
        }
        sessionsTree.onHoverTarget = { [weak self] target in self?.onHoverTarget?(target) }

        for view in [navStack, workspacesHeader, scroll, accountRow] { addSubview(view) }
        NSLayoutConstraint.activate([
            navStack.topAnchor.constraint(equalTo: topAnchor),
            navStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            navStack.trailingAnchor.constraint(equalTo: trailingAnchor),

            workspacesHeader.topAnchor.constraint(equalTo: navStack.bottomAnchor, constant: 14),
            workspacesHeader.leadingAnchor.constraint(equalTo: leadingAnchor),
            workspacesHeader.trailingAnchor.constraint(equalTo: trailingAnchor),

            scroll.topAnchor.constraint(equalTo: workspacesHeader.bottomAnchor, constant: 2),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: accountRow.topAnchor),

            accountRow.leadingAnchor.constraint(equalTo: leadingAnchor),
            accountRow.trailingAnchor.constraint(equalTo: trailingAnchor),
            accountRow.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        applyDestination(.terminals)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    /// Lights the row for `destination`, or none: Desk (`.terminals`) has no
    /// sidebar row any more — its content is entered through the sessions
    /// tree, the menu and the palette.
    func applyDestination(_ destination: WorkspaceDestination) {
        self.destination = destination
        for row in navRows { row.apply(selected: row.item.destination == destination) }
    }

    /// Everything the sessions half renders, scoped to the open workspace.
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
    }

    /// Where a hovered row sits on screen right now, or `nil` if it is gone.
    /// The hover card asks this every tick rather than remembering a frame:
    /// the rows are rebuilt constantly.
    func rowFrameOnScreen(for target: SessionHoverCardController.Target) -> NSRect? {
        guard let row = sessionsTree.rowView(for: target),
              let window = row.window,
              row.superview != nil,
              !row.isHiddenOrHasHiddenAncestor,
              row.bounds.width > 0
        else { return nil }
        return window.convertToScreen(row.convert(row.bounds, to: nil))
    }
}
