import AppKit

/// The spotlight (⌃Space, or ⌘K): a glass bar over a glassed workspace, and —
/// once something is typed — a row of category tags and the results under it.
///
/// An `NSPanel` rather than a sheet so it can be dismissed with Escape without
/// unwinding a modal session, and so the workspace behind it stays visible
/// while you read the list. All filtering and selection lives in
/// `CommandPaletteModel`; this is the keyboard and the pixels.
///
/// **The glass.** Both surfaces are macOS 26's own `NSGlassEffectView`, the
/// system material rather than a stand-in: `SpotlightGlassScrimWindow` lays one
/// clear, untinted sheet over the whole workspace — the same treatment focus
/// mode uses, which refracts rather than darkens — and the panel is a second
/// sheet with a slight navy gradient over it, which is all that separates it
/// from the sheet behind. Below macOS 26 both fall back to
/// `NSVisualEffectView`, which does blur here because these are *separate
/// windows* over the workspace: `.behindWindow` blending has something behind
/// it to work with, which a view inside the workspace window never does (see
/// `PaneZoomBackdropView`).
final class CommandPaletteController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate,
    NSTextFieldDelegate {
    /// Raised with the chosen row's action. The palette closes first, so the
    /// action lands with focus already back in the workspace.
    var onRun: ((PaletteAction) -> Void)?

    private(set) var model = CommandPaletteModel()
    private let field = NSTextField()
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let tagBar = SpotlightTagBar()
    private let rule = NSView()
    private let scrim = SpotlightGlassScrimWindow()
    private let content = NSView()
    /// The tint that separates the panel from the glass behind it. A layer
    /// rather than the glass view's own `tintColor`, because a flat wash of
    /// navy reads as paint and a gradient reads as glass.
    private let tintLayer = CAGradientLayer()

    /// The table's rows: a section heading, or an index into `model.matches`.
    /// Selection stays the model's business — headings are simply not in it,
    /// which is what makes ↑/↓ skip them without a single special case.
    private var display: [DisplayRow] = []

    private enum DisplayRow {
        case header(PaletteSection)
        case command(Int)
    }

    static let width: CGFloat = 720
    /// The search bar alone — the whole panel until something is typed.
    static let barHeight: CGFloat = 74
    static let tagBarHeight: CGFloat = 46
    static let rowHeight: CGFloat = 52
    static let headerHeight: CGFloat = 26
    static let maxResultsHeight: CGFloat = 396
    static let cornerRadius: CGFloat = 24

    init() {
        let panel = CommandPalettePanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: Self.barHeight),
            // Borderless: a titled window brings its own square-cornered
            // shadow and background, both of which show through the glass
            // panel's rounded corners.
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.hidesOnDeactivate = true
        panel.level = .floating
        super.init(window: panel)

        field.placeholderString = "Search terminals, browsers, files…"
        field.font = .systemFont(ofSize: 22, weight: .regular)
        field.textColor = .white
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = self
        field.setAccessibilityLabel("Spotlight query")

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("command"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = Self.rowHeight
        // `.inset` is what gives the highlight Spotlight's rounded, inset pill
        // instead of a full-bleed blue band.
        tableView.style = .inset
        tableView.backgroundColor = .clear
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(rowClicked)
        tableView.setAccessibilityLabel("Spotlight results")

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false

        tagBar.onSelect = { [weak self] section in
            guard let self else { return }
            model.select(section: section)
            reloadResults()
        }

        rule.wantsLayer = true
        rule.layer?.backgroundColor = NSColor(white: 1, alpha: 0.12).cgColor

        content.frame = NSRect(x: 0, y: 0, width: Self.width, height: Self.barHeight)
        content.autoresizingMask = [.width, .height]
        content.wantsLayer = true
        tintLayer.colors = [
            NSColor(srgbRed: 0.11, green: 0.16, blue: 0.38, alpha: 0.40).cgColor,
            NSColor(srgbRed: 0.05, green: 0.08, blue: 0.22, alpha: 0.14).cgColor,
        ]
        tintLayer.startPoint = CGPoint(x: 0.5, y: 1)
        tintLayer.endPoint = CGPoint(x: 0.5, y: 0)
        tintLayer.cornerRadius = Self.cornerRadius
        content.layer?.addSublayer(tintLayer)

        let magnifier = NSImageView()
        magnifier.image = NSImage(
            systemSymbolName: "magnifyingglass",
            accessibilityDescription: nil
        )?.withSymbolConfiguration(.init(pointSize: 20, weight: .medium))
        magnifier.contentTintColor = NSColor(white: 1, alpha: 0.62)
        magnifier.frame = NSRect(x: 26, y: 24, width: 26, height: 26)
        magnifier.autoresizingMask = [.minYMargin]
        self.magnifier = magnifier

        content.addSubview(magnifier)
        content.addSubview(field)
        content.addSubview(rule)
        content.addSubview(tagBar)
        content.addSubview(scrollView)

        panel.contentView = Self.glassHost(content, size: panel.frame.size)
        panel.initialFirstResponder = field
        panel.onCancel = { [weak self] in self?.dismiss() }
        scrim.onClick = { [weak self] in self?.dismiss() }
        layoutContent(height: Self.barHeight)
    }

    private var magnifier: NSImageView?

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    /// Wraps a view in glass: the real Liquid Glass on macOS 26, and the
    /// `.behindWindow` blur that stood in for it before.
    static func glassHost(
        _ content: NSView,
        size: NSSize,
        cornerRadius: CGFloat = CommandPaletteController.cornerRadius
    ) -> NSView {
        let frame = NSRect(origin: .zero, size: size)
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: frame)
            glass.autoresizingMask = [.width, .height]
            glass.cornerRadius = cornerRadius
            // Full strength, unlike `WorkspaceGlass`: this sheet has the
            // search field and the results inside it, and `alphaValue` fades a
            // view's whole subtree — softening the panel would soften the text
            // it exists to show. The navy gradient over it is what separates it
            // from the softened sheet behind.
            glass.style = .regular
            glass.contentView = content
            return glass
        }
        let effect = NSVisualEffectView(frame: frame)
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.autoresizingMask = [.width, .height]
        effect.wantsLayer = true
        effect.layer?.cornerRadius = cornerRadius
        effect.layer?.masksToBounds = true
        effect.addSubview(content)
        return effect
    }

    /// Opens over `parent`, rebuilt from scratch so the list can never offer a
    /// pane that closed while the palette was shut.
    func present(commands: [PaletteCommand], over parent: NSWindow?) {
        model.reset(commands: commands)
        field.stringValue = ""
        reloadResults()
        // Strict stacking without fighting window levels: the scrim is a child
        // of the workspace and the panel a child of the scrim, and a child
        // window is always above its parent.
        if let parent, let window {
            if scrim.parent !== parent {
                scrim.parent?.removeChildWindow(scrim)
                parent.addChildWindow(scrim, ordered: .above)
            }
            scrim.setFrame(parent.frame, display: false)
            if window.parent !== scrim {
                window.parent?.removeChildWindow(window)
                scrim.addChildWindow(window, ordered: .above)
            }
            scrim.fadeIn()
            // A third of the way down, where Spotlight sits — and where the
            // panel can grow downwards without walking off the window.
            window.setFrameOrigin(
                NSPoint(
                    x: parent.frame.midX - window.frame.width / 2,
                    y: parent.frame.maxY - parent.frame.height / 4 - window.frame.height
                )
            )
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(field)
    }

    func dismiss() {
        if let window {
            window.parent?.removeChildWindow(window)
            window.orderOut(nil)
        }
        // Ordered out rather than faded: dismissal should feel like the
        // workspace snapping back, not like waiting for it.
        scrim.parent?.removeChildWindow(scrim)
        scrim.orderOut(nil)
    }

    /// Types into the field — exactly the path a keystroke takes, exposed so
    /// the keyboard and a test drive the same code.
    func setQuery(_ text: String) {
        field.stringValue = text
        model.update(query: text)
        reloadResults()
    }

    /// Moves the highlight, keeping the table in step — what ⌃/⌄ do, exposed
    /// so the keyboard path and a test drive the same code.
    func moveSelection(by delta: Int) {
        model.moveSelection(by: delta)
        syncSelection()
    }

    /// ⇥ / ⇧⇥: the next tag, and the list narrowed to it.
    func cycleSection(by delta: Int) {
        model.cycleSection(by: delta)
        reloadResults()
    }

    /// Runs the highlighted row. Closes first: the action belongs to the
    /// workspace, and it should land with focus already back there.
    func runSelected() {
        guard let action = model.selected?.action else { return }
        dismiss()
        onRun?(action)
    }

    // MARK: - Keyboard

    func controlTextDidChange(_ notification: Notification) {
        model.update(query: field.stringValue)
        reloadResults()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(by: 1)
            return true
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(by: -1)
            return true
        case #selector(NSResponder.insertTab(_:)):
            cycleSection(by: 1)
            return true
        case #selector(NSResponder.insertBacktab(_:)):
            cycleSection(by: -1)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            runSelected()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            dismiss()
            return true
        default:
            return false
        }
    }

    @objc private func rowClicked() {
        guard tableView.clickedRow >= 0, display.indices.contains(tableView.clickedRow),
              case let .command(index) = display[tableView.clickedRow]
        else { return }
        model.select(index: index)
        runSelected()
    }

    // MARK: - Layout

    /// The whole of "what the panel looks like right now": the tags, the rows,
    /// and the height that holds them. One method, because every one of those
    /// changes for exactly the same reason — the query or the tag moved.
    private func reloadResults() {
        rebuildDisplay()
        tagBar.set(tags: model.sectionTags, selected: model.selectedSection)
        syncSelection()
        setHeight(preferredHeight())
    }

    /// One heading wherever the section changes — the rows already arrive in
    /// section order, so this is a walk, not a sort. No headings once a tag is
    /// chosen: the tag is the heading then, and repeating it over a filtered
    /// list is noise.
    private func rebuildDisplay() {
        display = []
        var current: PaletteSection?
        for (index, command) in model.matches.enumerated() {
            if model.selectedSection == nil, command.section != current {
                display.append(.header(command.section))
                current = command.section
            }
            display.append(.command(index))
        }
        tableView.reloadData()
    }

    private func resultsHeight() -> CGFloat {
        let content = display.reduce(into: CGFloat(0)) { total, row in
            if case .header = row {
                total += Self.headerHeight
            } else {
                total += Self.rowHeight
            }
        }
        return min(content + 12, Self.maxResultsHeight)
    }

    private func preferredHeight() -> CGFloat {
        guard !display.isEmpty else { return Self.barHeight }
        return Self.barHeight + Self.tagBarHeight + resultsHeight()
    }

    /// Grows and shrinks from the top edge, the way Spotlight does: the bar
    /// stays where the eye left it and the results unfold beneath it.
    ///
    /// Deliberately not animated. The height changes on every keystroke, and
    /// an animated resize both lags the typing it is following and leaves the
    /// window's frame lying about its size until the animation lands.
    private func setHeight(_ height: CGFloat) {
        guard let window else { return }
        let frame = window.frame
        layoutContent(height: height)
        guard abs(frame.height - height) > 0.5 else { return }
        window.setFrame(
            NSRect(x: frame.minX, y: frame.maxY - height, width: frame.width, height: height),
            display: true
        )
    }

    /// Hand-laid rather than constrained: the panel's height changes on every
    /// keystroke, and three frames are cheaper to reason about than a stack of
    /// constraints that have to be de-activated to let it.
    private func layoutContent(height: CGFloat) {
        let width = Self.width
        content.frame = NSRect(x: 0, y: 0, width: width, height: height)
        CATransaction.begin()
        // The tint follows the panel in the same frame; without this it lags a
        // resize by one implicit animation and the gradient visibly slides.
        CATransaction.setDisableActions(true)
        tintLayer.frame = content.bounds
        CATransaction.commit()

        magnifier?.frame = NSRect(x: 26, y: height - 50, width: 26, height: 26)
        field.frame = NSRect(x: 62, y: height - 54, width: width - 88, height: 34)
        let showsResults = height > Self.barHeight + 1
        rule.isHidden = !showsResults
        tagBar.isHidden = !showsResults
        scrollView.isHidden = !showsResults
        guard showsResults else { return }
        rule.frame = NSRect(x: 0, y: height - Self.barHeight, width: width, height: 1)
        tagBar.frame = NSRect(
            x: 0,
            y: height - Self.barHeight - Self.tagBarHeight,
            width: width,
            height: Self.tagBarHeight
        )
        scrollView.frame = NSRect(x: 6, y: 6, width: width - 12, height: tagBar.frame.minY - 6)
    }

    private func syncSelection() {
        guard let row = displayRow(for: model.selectedIndex) else {
            tableView.deselectAll(nil)
            return
        }
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        // The heading above it comes along, so scrolling to the first row of a
        // section never leaves its title clipped off the top.
        tableView.scrollRowToVisible(row > 0 ? row - 1 : row)
        tableView.scrollRowToVisible(row)
    }

    /// Where a model index sits in the table, once headings are counted.
    private func displayRow(for index: Int) -> Int? {
        display.firstIndex {
            if case let .command(i) = $0 { return i == index }
            return false
        }
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { display.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard display.indices.contains(row) else { return nil }
        switch display[row] {
        case let .header(section):
            return PaletteSectionHeaderView(section: section)
        case let .command(index):
            let rows = model.matches
            guard rows.indices.contains(index) else { return nil }
            return PaletteRowView(command: rows[index])
        }
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard display.indices.contains(row) else { return Self.rowHeight }
        if case .header = display[row] { return Self.headerHeight }
        return Self.rowHeight
    }

    /// A heading is a label, not a destination.
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        guard display.indices.contains(row) else { return false }
        if case .header = display[row] { return false }
        return true
    }

    /// Arrow keys are handled by the field, but clicking still moves the model
    /// so Enter runs what the eye is on.
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard tableView.selectedRow >= 0, display.indices.contains(tableView.selectedRow),
              case let .command(index) = display[tableView.selectedRow]
        else { return }
        model.select(index: index)
    }
}

/// A panel that can become key while the app stays put, and that treats Escape
/// as "close me" rather than passing it on.
final class CommandPalettePanel: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

/// The tags under the field: "All" first, then every category the query found.
/// Click one, or ⇥ through them.
final class SpotlightTagBar: NSView {
    var onSelect: ((PaletteSection?) -> Void)?

    private(set) var tags: [PaletteSection?] = []
    private var buttons: [SpotlightTagButton] = []

    func set(tags: [PaletteSection?], selected: PaletteSection?) {
        self.tags = tags
        buttons.forEach { $0.removeFromSuperview() }
        buttons = tags.map { section in
            let button = SpotlightTagButton(section: section, selected: section == selected)
            button.onClick = { [weak self] in self?.onSelect?(section) }
            addSubview(button)
            return button
        }
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    override func layout() {
        super.layout()
        var x: CGFloat = 20
        for button in buttons {
            let width = button.preferredWidth
            button.frame = NSRect(x: x, y: (bounds.height - 26) / 2, width: width, height: 26)
            x += width + 8
        }
    }
}

/// One tag pill.
final class SpotlightTagButton: NSView {
    var onClick: (() -> Void)?

    let section: PaletteSection?
    private let selected: Bool
    private let label: NSTextField

    var preferredWidth: CGFloat { label.intrinsicContentSize.width + 26 }

    init(section: PaletteSection?, selected: Bool) {
        self.section = section
        self.selected = selected
        // "All" is a tag like any other — the one that filters nothing.
        label = NSTextField(labelWithString: section?.rawValue ?? "All")
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = selected ? .white : NSColor(white: 1, alpha: 0.62)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 13
        layer?.backgroundColor = selected
            ? NSColor(white: 1, alpha: 0.20).cgColor
            : NSColor(white: 1, alpha: 0.07).cgColor
        addSubview(label)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(section?.rawValue ?? "All")
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func mouseDown(with event: NSEvent) { onClick?() }
}

/// A section heading — "Terminals", "Files" — small, uppercase and quiet, so
/// the eye lands on the rows and uses the headings only to orient.
final class PaletteSectionHeaderView: NSTableCellView {
    init(section: PaletteSection) {
        super.init(frame: .zero)
        // Tracking is what keeps a 10pt uppercase label readable rather than
        // cramped, and is the difference between "a heading" and "small text".
        let label = NSTextField(labelWithAttributedString: NSAttributedString(
            string: section.rawValue.uppercased(),
            attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .bold),
                .foregroundColor: NSColor(white: 1, alpha: 0.42),
                .kern: 1.2,
            ]
        ))
        addSubview(label)
        textField = label
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(section.rawValue)

        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }
}

/// One result: the icon on a rounded plate, the name, and under it where the
/// thing lives — Spotlight's own row, with our kinds in it.
final class PaletteRowView: NSTableCellView {
    init(command: PaletteCommand) {
        super.init(frame: .zero)
        let plate = NSView()
        plate.wantsLayer = true
        plate.layer?.cornerRadius = 8
        plate.layer?.backgroundColor = NSColor(white: 1, alpha: 0.10).cgColor
        addSubview(plate)

        let icon = NSImageView()
        icon.image = NSImage(
            systemSymbolName: command.section.symbol,
            accessibilityDescription: nil
        )?.withSymbolConfiguration(.init(pointSize: 15, weight: .regular))
        icon.contentTintColor = NSColor(white: 1, alpha: 0.85)
        plate.addSubview(icon)

        let title = NSTextField(labelWithString: command.title)
        title.font = .systemFont(ofSize: 15, weight: .medium)
        title.textColor = NSColor(white: 1, alpha: 0.97)
        title.lineBreakMode = .byTruncatingTail
        addSubview(title)
        textField = title

        let subtitle = NSTextField(labelWithString: command.subtitle ?? "")
        subtitle.font = .systemFont(ofSize: 11.5)
        subtitle.textColor = NSColor(white: 1, alpha: 0.5)
        subtitle.lineBreakMode = .byTruncatingMiddle
        addSubview(subtitle)

        let detail = NSTextField(labelWithString: command.detail ?? "")
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = NSColor(white: 1, alpha: 0.45)
        detail.alignment = .right
        detail.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(detail)

        setAccessibilityElement(true)
        setAccessibilityLabel([command.title, command.subtitle, command.detail]
            .compactMap { $0 }
            .joined(separator: ", "))

        [plate, icon, title, subtitle, detail].forEach { $0.translatesAutoresizingMaskIntoConstraints = false }
        // One line or two: a row with no location centres its title rather
        // than leaving a gap where the second line would have been.
        let hasSubtitle = !(command.subtitle ?? "").isEmpty
        NSLayoutConstraint.activate([
            plate.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            plate.centerYAnchor.constraint(equalTo: centerYAnchor),
            plate.widthAnchor.constraint(equalToConstant: 30),
            plate.heightAnchor.constraint(equalToConstant: 30),
            icon.centerXAnchor.constraint(equalTo: plate.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: plate.centerYAnchor),

            title.leadingAnchor.constraint(equalTo: plate.trailingAnchor, constant: 12),
            hasSubtitle
                ? title.topAnchor.constraint(equalTo: plate.topAnchor, constant: -1)
                : title.centerYAnchor.constraint(equalTo: centerYAnchor),
            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 1),
            subtitle.trailingAnchor.constraint(lessThanOrEqualTo: detail.leadingAnchor, constant: -12),

            detail.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 12),
            detail.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            detail.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }
}

/// The sheet of glass the spotlight sits on: one clear, untinted pane over the
/// whole workspace — focus mode's treatment, which refracts what is behind it
/// rather than darkening it. It also catches the click that lands outside the
/// panel and treats it as "close".
final class SpotlightGlassScrimWindow: NSWindow {
    var onClick: (() -> Void)?

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        isOpaque = false
        hasShadow = false
        backgroundColor = .clear
        level = .floating
        // Hides and returns with the panel, which does the same — otherwise
        // switching apps would leave the workspace glassed with nothing on it.
        hidesOnDeactivate = true
        alphaValue = 0
        let click = ScrimClickView { [weak self] in self?.onClick?() }
        click.autoresizingMask = [.width, .height]
        // `WorkspaceGlass` is the app's one sheet — the same material at the
        // same strength focus mode uses, rather than a second setting of it.
        // Below macOS 26 there is no sheet and the click-catcher stands alone:
        // every pre-26 stand-in dims the workspace instead of glassing it.
        if let sheet = WorkspaceGlass.sheet() {
            sheet.autoresizingMask = [.width, .height]
            if #available(macOS 26.0, *), let glass = sheet as? NSGlassEffectView {
                glass.contentView = click
            }
            contentView = sheet
        } else {
            contentView = click
        }
    }

    /// Never key: the search field's window has to keep the keyboard.
    override var canBecomeKey: Bool { false }

    func fadeIn() {
        contentView?.frame = NSRect(origin: .zero, size: frame.size)
        contentView?.subviews.forEach { $0.frame = NSRect(origin: .zero, size: frame.size) }
        alphaValue = 0
        orderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            animator().alphaValue = 1
        }
    }
}

/// A view whose only job is turning a click into a callback.
private final class ScrimClickView: NSView {
    private let onClick: () -> Void

    init(onClick: @escaping () -> Void) {
        self.onClick = onClick
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func mouseDown(with event: NSEvent) { onClick() }
}
