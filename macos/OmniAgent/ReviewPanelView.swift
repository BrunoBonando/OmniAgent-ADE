import AppKit

// The review panel — the 2026-08-20 redesign's §5: a third split item on the
// right of the session content, a tab bar across the top (closable tabs, a
// "+" menu that adds views, an expand-to-full-width toggle), and one content
// view per tab. This task builds the frame; the tab contents are placeholders
// the next tasks replace.

/// A small square icon button — `SidebarHeaderButtonView`'s shape, with a
/// swappable symbol so the expand toggle can tell the truth about which way
/// it is about to go.
final class ReviewPanelIconButton: ShellRowView {
    private let icon = NSImageView()
    private(set) var symbolName: String

    init(symbol: String, label: String) {
        symbolName = symbol
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.cornerCurve = .continuous
        translatesAutoresizingMaskIntoConstraints = false
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.contentTintColor = ShellPalette.chevron
        addSubview(icon)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 22),
            heightAnchor.constraint(equalToConstant: 22),
            icon.centerXAnchor.constraint(equalTo: centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setSymbol(symbol, label: label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func setSymbol(_ symbol: String, label: String) {
        symbolName = symbol
        icon.image = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: label
        )?.withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        setAccessibilityLabel(label)
    }
}

/// The × that closes one tab. Drawn with `drawXGlyph` so it is the same
/// shape as the pane header's and the editor strip's close glyphs.
final class ReviewPanelTabCloseView: ShellRowView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 3
        layer?.cornerCurve = .continuous
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 14),
            heightAnchor.constraint(equalToConstant: 14),
        ])
        setAccessibilityLabel("Close tab")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func draw(_ dirtyRect: NSRect) {
        drawXGlyph(
            in: bounds,
            color: isHovered ? ShellPalette.ink : ShellPalette.inkMuted,
            lineWidth: 1.2
        )
    }

    override func refreshBackground() {
        super.refreshBackground()
        needsDisplay = true
    }
}

/// One tab in the panel's tab bar: icon + label + the close ×. Reports
/// presses; the panel owns the tab set.
final class ReviewPanelTabItemView: ShellRowView {
    let tab: ReviewPanelTab
    var onClose: (() -> Void)?

    private let icon = NSImageView()
    private let titleField: NSTextField
    let closeButton = ReviewPanelTabCloseView()
    private(set) var isSelected = false

    init(tab: ReviewPanelTab) {
        self.tab = tab
        titleField = ShellFont.label(
            tab.title,
            font: ShellFont.ui(12, .medium),
            color: ShellPalette.inkNav
        )
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous
        translatesAutoresizingMaskIntoConstraints = false

        icon.image = NSImage(
            systemSymbolName: tab.symbolName,
            accessibilityDescription: tab.title
        )?.withSymbolConfiguration(.init(pointSize: 10.5, weight: .semibold))
        icon.contentTintColor = ShellPalette.inkNav
        icon.translatesAutoresizingMaskIntoConstraints = false
        closeButton.onPress = { [weak self] in self?.onClose?() }

        for view in [icon, titleField, closeButton] as [NSView] { addSubview(view) }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 24),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleField.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 5),
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.leadingAnchor.constraint(equalTo: titleField.trailingAnchor, constant: 4),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityLabel(tab.title)
        refreshSelection()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func setSelected(_ selected: Bool) {
        guard isSelected != selected else { return }
        isSelected = selected
        refreshSelection()
    }

    private func refreshSelection() {
        titleField.textColor = isSelected ? ShellPalette.ink : ShellPalette.inkNav
        icon.contentTintColor = isSelected ? ShellPalette.ink : ShellPalette.inkNav
        refreshBackground()
    }

    override func refreshBackground() {
        let fill: NSColor
        if isSelected {
            fill = ShellPalette.rowSelected
        } else if isHovered {
            fill = ShellPalette.hoverSoft
        } else {
            fill = .clear
        }
        layer?.backgroundColor = fill.cgColor
    }
}

/// A tab's stand-in content: the tab's name, dim and centred — replaced by
/// the real Changes/Files/Browser/Insights views in the next tasks.
final class ReviewPanelPlaceholderView: NSView {
    let tab: ReviewPanelTab

    init(tab: ReviewPanelTab) {
        self.tab = tab
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let label = ShellFont.label(
            tab.title,
            font: ShellFont.ui(13, .medium),
            color: ShellPalette.inkMuted
        )
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
}

/// The panel itself. Holds the tab set and selection and reports every
/// mutation through `onTabsChanged`; which session those tabs belong to —
/// and everything persisted — is `WorkspaceWindowController`'s business.
final class ReviewPanelView: NSView {
    /// The split item's floor — wide enough for a diff gutter or a file tree.
    static let minimumWidth: CGFloat = 280
    static let tabBarHeight: CGFloat = 34

    private(set) var openTabs: [ReviewPanelTab] = ReviewPanelTab.defaultTabs
    private(set) var activeTab: ReviewPanelTab? = ReviewPanelTab.defaultTabs.first
    private(set) var isExpanded = false

    /// The tab set or the selection changed by user action. Not raised by
    /// `load` — a restore is not an edit.
    var onTabsChanged: (() -> Void)?
    var onToggleExpand: (() -> Void)?

    let addButton = ReviewPanelIconButton(symbol: "plus", label: "Add view")
    let expandButton = ReviewPanelIconButton(
        symbol: "arrow.left.to.line",
        label: "Expand to full width"
    )

    private let tabStack = NSStackView()
    private let hairline = NSView()
    private let contentContainer = NSView()
    private(set) var tabItems: [ReviewPanelTabItemView] = []
    private(set) var placeholders: [ReviewPanelTab: ReviewPanelPlaceholderView] = [:]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = ShellPalette.content.cgColor

        tabStack.orientation = .horizontal
        tabStack.alignment = .centerY
        tabStack.spacing = 2
        tabStack.translatesAutoresizingMaskIntoConstraints = false

        hairline.wantsLayer = true
        hairline.layer?.backgroundColor = ShellPalette.hairline.cgColor
        hairline.translatesAutoresizingMaskIntoConstraints = false

        contentContainer.translatesAutoresizingMaskIntoConstraints = false

        addButton.onPress = { [weak self] in self?.presentAddMenu() }
        expandButton.onPress = { [weak self] in self?.onToggleExpand?() }

        for view in [tabStack, expandButton, hairline, contentContainer] as [NSView] {
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            tabStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            tabStack.topAnchor.constraint(equalTo: topAnchor),
            tabStack.heightAnchor.constraint(equalToConstant: Self.tabBarHeight),
            tabStack.trailingAnchor.constraint(
                lessThanOrEqualTo: expandButton.leadingAnchor, constant: -6
            ),

            expandButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            expandButton.centerYAnchor.constraint(equalTo: tabStack.centerYAnchor),

            hairline.leadingAnchor.constraint(equalTo: leadingAnchor),
            hairline.trailingAnchor.constraint(equalTo: trailingAnchor),
            hairline.topAnchor.constraint(equalTo: topAnchor, constant: Self.tabBarHeight),
            hairline.heightAnchor.constraint(equalToConstant: 1),

            contentContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentContainer.topAnchor.constraint(equalTo: hairline.bottomAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        rebuildTabBar()
        updateContent()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    // MARK: - State

    /// Replaces the tab set without firing `onTabsChanged` — the restore
    /// path, where reporting the change back would write what was just read.
    func load(tabs: [ReviewPanelTab], active: ReviewPanelTab?) {
        var seen: Set<ReviewPanelTab> = []
        openTabs = tabs.filter { seen.insert($0).inserted }
        activeTab = active.flatMap { openTabs.contains($0) ? $0 : nil } ?? openTabs.first
        rebuildTabBar()
        updateContent()
    }

    func selectTab(_ tab: ReviewPanelTab) {
        guard openTabs.contains(tab), activeTab != tab else { return }
        activeTab = tab
        refreshSelection()
        updateContent()
        onTabsChanged?()
    }

    /// Adds and selects; an already-open tab is only selected.
    func addTab(_ tab: ReviewPanelTab) {
        if openTabs.contains(tab) {
            selectTab(tab)
            return
        }
        openTabs.append(tab)
        activeTab = tab
        rebuildTabBar()
        updateContent()
        onTabsChanged?()
    }

    func closeTab(_ tab: ReviewPanelTab) {
        guard let index = openTabs.firstIndex(of: tab) else { return }
        openTabs.remove(at: index)
        if activeTab == tab {
            // The neighbour that slid into the closed tab's place, else the
            // new last tab — the editor strip's rule.
            activeTab = openTabs.indices.contains(index) ? openTabs[index] : openTabs.last
        }
        rebuildTabBar()
        updateContent()
        onTabsChanged?()
    }

    /// The "+" menu: every view not already open — Browser and Insights from
    /// the default tab set, which is the spec's list; a closed default tab
    /// re-appears here rather than being lost for the session.
    func addMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for tab in ReviewPanelTab.allCases where !openTabs.contains(tab) {
            let item = ShellMenuItem(tab.title) { [weak self] in self?.addTab(tab) }
            item.image = NSImage(
                systemSymbolName: tab.symbolName,
                accessibilityDescription: tab.title
            )?.withSymbolConfiguration(.init(pointSize: 11, weight: .medium))
            menu.addItem(item)
        }
        return menu
    }

    /// The controller owns the split geometry, so it tells the panel which
    /// way its toggle now points rather than the button deciding for itself.
    func setExpanded(_ expanded: Bool) {
        guard isExpanded != expanded else { return }
        isExpanded = expanded
        expandButton.setSymbol(
            expanded ? "arrow.right.to.line" : "arrow.left.to.line",
            label: expanded ? "Restore panel width" : "Expand to full width"
        )
    }

    // MARK: - Internals

    private func presentAddMenu() {
        let menu = addMenu()
        guard !menu.items.isEmpty else { return }
        menu.popUp(
            positioning: nil,
            at: NSPoint(x: 0, y: addButton.bounds.maxY + 4),
            in: addButton
        )
    }

    private func rebuildTabBar() {
        for view in tabStack.arrangedSubviews { view.removeFromSuperview() }
        tabItems = openTabs.map { tab in
            let item = ReviewPanelTabItemView(tab: tab)
            item.onPress = { [weak self] in self?.selectTab(tab) }
            item.onClose = { [weak self] in self?.closeTab(tab) }
            return item
        }
        for item in tabItems { tabStack.addArrangedSubview(item) }
        tabStack.addArrangedSubview(addButton)
        refreshSelection()
    }

    private func refreshSelection() {
        for item in tabItems { item.setSelected(item.tab == activeTab) }
    }

    private func updateContent() {
        // Placeholders are created on first use and kept — the next tasks
        // swap this dictionary's values for the real views, and a hidden
        // view keeps its state where a recreated one would not.
        if let tab = activeTab, placeholders[tab] == nil {
            let placeholder = ReviewPanelPlaceholderView(tab: tab)
            placeholders[tab] = placeholder
            contentContainer.addSubview(placeholder)
            NSLayoutConstraint.activate([
                placeholder.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
                placeholder.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
                placeholder.topAnchor.constraint(equalTo: contentContainer.topAnchor),
                placeholder.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
            ])
        }
        for (tab, view) in placeholders { view.isHidden = tab != activeTab }
    }
}
