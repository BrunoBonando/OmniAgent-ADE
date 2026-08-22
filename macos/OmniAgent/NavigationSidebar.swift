import AppKit

// The flat Copilot-style sidebar — the 2026-08-20 navigation redesign
// (docs/superpowers/specs/2026-08-20-copilot-nav-redesign-design.md). One
// straight column in the existing `ShellPalette` language: fixed nav rows on
// top (Home, To Do List, Search), then the Workspaces section holding the
// workspaces tree (`WorkspacesTree.swift`), and the account row pinned at the
// bottom. It replaces the two-level sliding track `WorkspaceShell.swift` used
// to build; that file keeps the shared tokens, glyphs and row classes.

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

/// One of the section header's small icon buttons — an SF Symbol in a
/// 20-point hover square, the same symbol vocabulary as the nav rows above.
final class SidebarHeaderButtonView: ShellRowView {
    /// Which symbol this button wears — a fact for tests, since the image
    /// itself does not answer.
    let symbolName: String

    init(symbol: String, label: String) {
        symbolName = symbol
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.cornerCurve = .continuous
        translatesAutoresizingMaskIntoConstraints = false

        let icon = NSImageView()
        icon.image = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: label
        )?.withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        icon.contentTintColor = ShellPalette.chevron
        icon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 20),
            heightAnchor.constraint(equalToConstant: 20),
            icon.centerXAnchor.constraint(equalTo: centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityLabel(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
}

/// The "Workspaces" section header: the tracked title on the left, the
/// group-by and plus icon buttons on the right. The buttons only report
/// presses — the sidebar builds the menus and pops them, because the menus
/// read state (the tree's mode, the rendered workspaces) the header never
/// holds.
final class SidebarSectionHeaderView: NSView {
    private let titleField: NSTextField

    let groupButton = SidebarHeaderButtonView(symbol: "rectangle.grid.1x2", label: "Group by")
    let plusButton = SidebarHeaderButtonView(symbol: "plus", label: "Add")

    init(title: String) {
        titleField = ShellFont.label(
            title,
            font: ShellFont.ui(11.5, .semibold),
            color: ShellPalette.inkMuted,
            tracking: 0.5
        )
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        for view in [titleField, groupButton, plusButton] { addSubview(view) }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 22),
            titleField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 17),
            titleField.trailingAnchor.constraint(
                lessThanOrEqualTo: groupButton.leadingAnchor, constant: -8
            ),
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor),

            plusButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            plusButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            groupButton.trailingAnchor.constraint(equalTo: plusButton.leadingAnchor, constant: -2),
            groupButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
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

    /// The chip's own height, and half of it its capsule radius. Fixed rather
    /// than derived from the label's padding because the row is now a card:
    /// the sidebar insets it from its own edges so it clears the window's
    /// corner curve — on macOS 26 that curve is wide enough that an
    /// edge-to-edge footer tucks its avatar under the bevel.
    static let height: CGFloat = 44

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
        translatesAutoresizingMaskIntoConstraints = false

        // Liquid Glass where there is glass to ask for. Before macOS 26 there
        // is none, and every stand-in dims rather than refracts, so the
        // fallback is the plainest thing that still reads as a card.
        let glass = WorkspaceGlass.sheet(cornerRadius: Self.height / 2)
        if glass == nil {
            layer?.cornerRadius = Self.height / 2
            layer?.cornerCurve = .continuous
            layer?.backgroundColor = NSColor(white: 1, alpha: 0.05).cgColor
            layer?.borderWidth = 1
            layer?.borderColor = ShellPalette.hairlineStrong.cgColor
        }

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
        gear.layer?.cornerRadius = 6
        gear.hoverFill = NSColor(white: 1, alpha: 0.09)
        gear.onPress = { [weak self] in self?.onOpenSettings?() }
        gear.setAccessibilityLabel("Settings")
        gear.translatesAutoresizingMaskIntoConstraints = false
        // The system gear, not the hand-drawn one this used to carry: a ring
        // with eight straight spokes is the brightness glyph, and at 20pt it
        // read as one.
        let gearGlyph = NSImageView()
        gearGlyph.image = NSImage(
            systemSymbolName: "gearshape",
            accessibilityDescription: "Settings"
        )?.withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        gearGlyph.contentTintColor = ShellPalette.chevron
        gearGlyph.translatesAutoresizingMaskIntoConstraints = false
        gear.addSubview(gearGlyph)

        for view in [glass, avatar, nameField, gear].compactMap({ $0 }) { addSubview(view) }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),

            avatar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 11),
            avatar.centerYAnchor.constraint(equalTo: centerYAnchor),
            avatar.widthAnchor.constraint(equalToConstant: ShellMetrics.accountAvatar),
            avatar.heightAnchor.constraint(equalToConstant: ShellMetrics.accountAvatar),
            person.centerXAnchor.constraint(equalTo: avatar.centerXAnchor),
            person.centerYAnchor.constraint(equalTo: avatar.centerYAnchor),

            nameField.leadingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: 8),
            nameField.trailingAnchor.constraint(equalTo: gear.leadingAnchor, constant: -6),
            nameField.centerYAnchor.constraint(equalTo: centerYAnchor),

            gear.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            gear.centerYAnchor.constraint(equalTo: centerYAnchor),
            gear.widthAnchor.constraint(equalToConstant: 24),
            gear.heightAnchor.constraint(equalToConstant: 24),
            gearGlyph.centerXAnchor.constraint(equalTo: gear.centerXAnchor),
            gearGlyph.centerYAnchor.constraint(equalTo: gear.centerYAnchor),
        ])
        if let glass {
            glass.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                glass.leadingAnchor.constraint(equalTo: leadingAnchor),
                glass.trailingAnchor.constraint(equalTo: trailingAnchor),
                glass.topAnchor.constraint(equalTo: topAnchor),
                glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }
        nameField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Not signed in")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
}

// MARK: - The sidebar

/// The blue the glass column wears. Its backing layer *is* the gradient, so
/// the wash resizes with the sheet and there is no sublayer frame for anyone
/// to keep in step.
private final class SidebarGlassTintView: NSView {
    override func makeBackingLayer() -> CALayer {
        let layer = CAGradientLayer()
        layer.colors = ShellPalette.sidebarGlassTint.map(\.cgColor)
        // (0.5, 1) is the top of a layer's y-up unit space — the direction
        // `NSGradient`'s -90° gave the opaque gradient this replaces.
        layer.startPoint = CGPoint(x: 0.5, y: 1)
        layer.endPoint = CGPoint(x: 0.5, y: 0)
        return layer
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
}

/// The sidebar itself: one flat column, top to bottom — nav rows, the
/// Workspaces section with the workspaces tree, the account row.
final class NavigationSidebarView: NSView {
    /// Home or To Do List was pressed (Search never routes here).
    var onSelectDestination: ((WorkspaceDestination) -> Void)?
    /// The Search row: raise the spotlight. Deliberately not a selection —
    /// the lit row stays wherever it was.
    var onSearch: (() -> Void)?
    var onSelectSession: ((SessionGroupNode) -> Void)?
    var onRenameSession: ((SessionGroupNode, String) -> Void)?
    /// The workspaces tree's hovers, forwarded to the controller — which owns
    /// the hover card, because the card is a window and the sidebar is a view.
    var onHoverTarget: ((SessionHoverCardController.Target?) -> Void)?
    var onOpenSettings: (() -> Void)?
    /// The plus menu's "Start session in" — a workspace id; the controller
    /// resolves it to a directory and starts the session there.
    var onStartSession: ((String) -> Void)?
    /// The plus menu's "Local folder or repository…" — the existing
    /// add-workspace folder chooser.
    var onAddLocalFolder: (() -> Void)?
    /// A workspace row's right-click, forwarded to the controller — which
    /// resolves the workspace's directory, GitHub remote and stored
    /// customization, none of which the sidebar holds.
    var workspaceMenuProvider: ((String) -> NSMenu?)?
    /// A session row's right-click, same contract: the pin state, the
    /// installed apps and the delete path all live on the controller.
    var sessionMenuProvider: ((SessionGroupNode) -> NSMenu?)?

    private(set) var navRows: [SidebarNavRowView] = []
    let workspacesHeader = SidebarSectionHeaderView(title: "Workspaces")
    let workspacesTree = WorkspacesTreeView()
    let accountRow = SidebarAccountRowView()
    private(set) var destination: WorkspaceDestination = .terminals

    /// The column's ground on macOS 26: one full-bleed sheet of Liquid Glass
    /// behind every row, with `glassTint` washing the design's blue over it.
    /// `nil` below 26, where `draw` paints the opaque gradient instead.
    ///
    /// Full-bleed and square — no inset, no corner radius. The rim the sheet
    /// draws down its trailing edge is the border between the column and the
    /// black pane area, which is the whole reason for the glass. An inset
    /// rounded slab is the chrome a `.sidebar` split item gives for free, and
    /// the one this app turned down (see `installSplitView`).
    private(set) var glassHost: NSView?
    /// The blue over the sheet — the glass view's `contentView`, so it is
    /// composited on top of the material rather than behind it.
    private(set) var glassTint: NSView?
    /// The grey line where the column stops. Topmost, so nothing the column
    /// grows later can cover the one thing that separates it from the panes.
    let trailingEdge = NSView()
    /// What the plus menu lists: every workspace the tree currently renders,
    /// in render order.
    private(set) var workspaceMenuEntries: [(id: String, label: String)] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

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

        let scroll = ShellScrollView(documentView: workspacesTree)

        accountRow.onOpenSettings = { [weak self] in self?.onOpenSettings?() }
        workspacesHeader.groupButton.onPress = { [weak self] in
            guard let self else { return }
            pop(makeGroupByMenu(), from: workspacesHeader.groupButton)
        }
        workspacesHeader.plusButton.onPress = { [weak self] in
            guard let self else { return }
            pop(makePlusMenu(), from: workspacesHeader.plusButton)
        }
        workspacesTree.onSelectSession = { [weak self] session in self?.onSelectSession?(session) }
        workspacesTree.onRenameSession = { [weak self] session, name in
            self?.onRenameSession?(session, name)
        }
        workspacesTree.onHoverTarget = { [weak self] target in self?.onHoverTarget?(target) }
        workspacesTree.workspaceMenuProvider = { [weak self] id in self?.workspaceMenuProvider?(id) }
        workspacesTree.sessionMenuProvider = { [weak self] session in
            self?.sessionMenuProvider?(session)
        }

        // The ground first, so every row above sits on it. Sized in `layout`
        // rather than by an autoresizing mask: the mask scales from this
        // view's own frame, which at init is whatever the caller passed —
        // usually zero, and zero scales to zero.
        let tint = SidebarGlassTintView()
        if let glass = WorkspaceGlass.sheet(content: tint) {
            glassHost = glass
            glassTint = tint
            addSubview(glass)
        }

        for view in [navStack, workspacesHeader, scroll, accountRow] { addSubview(view) }

        // Last, and so on top of everything: the rows are all inset from this
        // edge, so it never covers one, and being topmost means it cannot be
        // covered either.
        trailingEdge.wantsLayer = true
        trailingEdge.layer?.backgroundColor = ShellPalette.sidebarEdge.cgColor
        trailingEdge.translatesAutoresizingMaskIntoConstraints = false
        addSubview(trailingEdge)

        NSLayoutConstraint.activate([
            trailingEdge.trailingAnchor.constraint(equalTo: trailingAnchor),
            trailingEdge.topAnchor.constraint(equalTo: topAnchor),
            trailingEdge.bottomAnchor.constraint(equalTo: bottomAnchor),
            trailingEdge.widthAnchor.constraint(equalToConstant: 1),
        ])

        NSLayoutConstraint.activate([
            // The column runs under the window chrome (titleBar) and this clears it.
            navStack.topAnchor.constraint(equalTo: topAnchor, constant: WorkspaceTitleBarView.height),
            navStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            navStack.trailingAnchor.constraint(equalTo: trailingAnchor),

            workspacesHeader.topAnchor.constraint(equalTo: navStack.bottomAnchor, constant: 14),
            workspacesHeader.leadingAnchor.constraint(equalTo: leadingAnchor),
            workspacesHeader.trailingAnchor.constraint(equalTo: trailingAnchor),

            scroll.topAnchor.constraint(equalTo: workspacesHeader.bottomAnchor, constant: 2),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: accountRow.topAnchor, constant: -8),

            accountRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            accountRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            accountRow.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])

        applyDestination(.terminals)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    /// The sheet fills the column, and so does the wash on it — through every
    /// divider drag, which is the one thing this view's geometry ever does.
    override func layout() {
        super.layout()
        glassHost?.frame = bounds
        glassTint?.frame = NSRect(origin: .zero, size: bounds.size)
    }

    /// Top-lit, so the column has a light source and the content black beside
    /// it does not.
    ///
    /// Only below macOS 26. With glass there is a sheet covering these exact
    /// bounds carrying the same blue itself, and painting an opaque gradient
    /// under it is work no pixel ever shows.
    override func draw(_ dirtyRect: NSRect) {
        guard glassHost == nil else { return }
        ShellPalette.sidebarGlass.draw(in: bounds, angle: -90)
    }

    /// Lights the row for `destination`, or none: Desk (`.terminals`) has no
    /// sidebar row any more — its content is entered through the sessions
    /// tree, the menu and the palette.
    func applyDestination(_ destination: WorkspaceDestination) {
        self.destination = destination
        for row in navRows { row.apply(selected: row.item.destination == destination) }
    }

    /// Everything the Workspaces section renders: EVERY workspace, its
    /// sessions inline — never scoped to the open one. The brain's project
    /// list supplies the rows (so a workspace with nothing running still
    /// shows), and the pane descriptors supply the sessions — plus a row for
    /// any project only the panes know about (a folder opened directly).
    func reloadWorkspaces(
        workspaces: [BrainProjectSummary],
        panes: [PaneDescriptor],
        focusedPaneID: String?,
        statuses: [String: RemoteSessionStatus],
        projectLabels: [String: String],
        eventTimes: [String: Double] = [:],
        customizations: [String: WorkspaceCustomization] = [:],
        sessionMeta: [String: SessionMeta] = [:]
    ) {
        let grouped = SessionOutline.group(panes, focusedPaneID: focusedPaneID)
        var entries: [WorkspaceTreeEntry] = []
        var listed = Set<String>()
        for workspace in workspaces {
            listed.insert(workspace.id)
            let custom = customizations[workspace.id]
            entries.append(
                WorkspaceTreeEntry(
                    id: workspace.id,
                    label: custom?.displayName ?? workspace.label,
                    sessions: grouped.first { $0.project == workspace.id }?.sessions ?? [],
                    tint: custom?.color?.tint
                )
            )
        }
        for node in grouped where !listed.contains(node.project) {
            let custom = customizations[node.project]
            entries.append(
                WorkspaceTreeEntry(
                    id: node.project,
                    label: custom?.displayName
                        ?? SessionOutline.projectLabel(node.project, labels: projectLabels),
                    sessions: node.sessions,
                    tint: custom?.color?.tint
                )
            )
        }
        workspaceMenuEntries = entries.map { ($0.id, $0.label) }
        workspacesTree.reload(
            entries: entries,
            focusedPaneID: focusedPaneID,
            statuses: statuses,
            eventTimes: eventTimes,
            meta: sessionMeta
        )
    }

    // MARK: - The header's menus

    /// The group-by menu, built fresh per pop so the checkmark always reads
    /// the tree's current mode. Selecting a mode re-renders the tree on the
    /// spot and persists the choice.
    func makeGroupByMenu() -> NSMenu {
        WorkspacesHeaderMenus.groupBy(current: workspacesTree.groupMode) { [weak self] mode in
            self?.workspacesTree.setGroupMode(mode)
        }
    }

    /// The plus menu over whatever the tree currently renders.
    func makePlusMenu() -> NSMenu {
        WorkspacesHeaderMenus.plus(
            workspaces: workspaceMenuEntries,
            startSession: { [weak self] id in self?.onStartSession?(id) },
            addLocalFolder: { [weak self] in self?.onAddLocalFolder?() }
        )
    }

    /// Drops the menu just under its button, left-aligned with it.
    private func pop(_ menu: NSMenu, from button: NSView) {
        menu.popUp(
            positioning: nil,
            at: NSPoint(x: 0, y: button.bounds.minY - 6),
            in: button
        )
    }

    /// Where a hovered row sits on screen right now, or `nil` if it is gone.
    /// The hover card asks this every tick rather than remembering a frame:
    /// the rows are rebuilt constantly.
    func rowFrameOnScreen(for target: SessionHoverCardController.Target) -> NSRect? {
        guard let row = workspacesTree.rowView(for: target),
              let window = row.window,
              row.superview != nil,
              !row.isHiddenOrHasHiddenAncestor,
              row.bounds.width > 0
        else { return nil }
        return window.convertToScreen(row.convert(row.bounds, to: nil))
    }
}
