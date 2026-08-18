import AppKit

/// The ⌘K spotlight: a glass panel with a search field over a table of
/// matches, on a dim wash that pushes the whole workspace back.
///
/// An `NSPanel` rather than a sheet so it can be dismissed with Escape
/// without unwinding a modal session, and so the workspace behind it stays
/// visible while you read the list. All filtering and selection lives in
/// `CommandPaletteModel`; this is the keyboard and the pixels.
///
/// **Why the blur is real here.** `PaneZoomBackdropView` documents at length
/// that a view *inside* the workspace window cannot blur that window with
/// `.withinWindow` blending — it dims and nothing more. This panel is a
/// separate window sitting over the workspace, which is the one arrangement
/// where `.behindWindow` blurs exactly what the design asks for: the app
/// behind the glass, and only behind the glass. The dim everywhere else is
/// `SpotlightScrimWindow`, a plain translucent child window underneath.
final class CommandPaletteController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate,
    NSTextFieldDelegate {
    /// Raised with the chosen row's action. The palette closes first, so the
    /// action lands with focus already back in the workspace.
    var onRun: ((PaletteAction) -> Void)?

    private(set) var model = CommandPaletteModel()
    private let field = NSTextField()
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let scrim = SpotlightScrimWindow()
    /// The table's rows: a section heading, or an index into `model.matches`.
    /// Selection stays the model's business — headings are simply not in it,
    /// which is what makes ↑/↓ skip them without a single special case.
    private var display: [DisplayRow] = []

    private enum DisplayRow {
        case header(PaletteSection)
        case command(Int)
    }

    static let rowHeight: CGFloat = 36
    static let headerHeight: CGFloat = 28
    static let cornerRadius: CGFloat = 22

    init() {
        let panel = CommandPalettePanel(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 460),
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
        field.font = .systemFont(ofSize: 21, weight: .regular)
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
        // `.inset` is what gives the highlight Spotlight's rounded, inset
        // pill instead of a full-bleed blue band.
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

        // Liquid Glass where the OS has it — `NSGlassEffectView` is the real
        // material, with its own refraction and specular edge, not a blur
        // standing in for one. The visual-effect view stays as the fallback
        // for anything older than macOS 26.
        let content = NSView(frame: NSRect(origin: .zero, size: panel.frame.size))
        content.autoresizingMask = [.width, .height]

        let magnifier = NSImageView(frame: NSRect(x: 26, y: content.bounds.height - 55, width: 24, height: 24))
        magnifier.image = NSImage(
            systemSymbolName: "magnifyingglass",
            accessibilityDescription: nil
        )?.withSymbolConfiguration(.init(pointSize: 19, weight: .medium))
        magnifier.contentTintColor = NSColor(white: 1, alpha: 0.6)
        magnifier.autoresizingMask = [.minYMargin]
        field.frame = NSRect(x: 62, y: content.bounds.height - 62, width: content.bounds.width - 86, height: 38)
        field.autoresizingMask = [.width, .minYMargin]
        let rule = NSView(frame: NSRect(x: 0, y: content.bounds.height - 74, width: content.bounds.width, height: 1))
        rule.autoresizingMask = [.width, .minYMargin]
        rule.wantsLayer = true
        rule.layer?.backgroundColor = NSColor(white: 1, alpha: 0.14).cgColor
        scrollView.frame = NSRect(x: 6, y: 10, width: content.bounds.width - 12, height: content.bounds.height - 86)
        scrollView.autoresizingMask = [.width, .height]
        content.addSubview(magnifier)
        content.addSubview(field)
        content.addSubview(rule)
        content.addSubview(scrollView)

        panel.contentView = Self.glassHost(content, size: panel.frame.size)
        panel.initialFirstResponder = field
        panel.onCancel = { [weak self] in self?.dismiss() }
        scrim.onClick = { [weak self] in self?.dismiss() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    /// Wraps the spotlight's content in glass: the real Liquid Glass on
    /// macOS 26, and the `.behindWindow` blur that stood in for it before.
    private static func glassHost(_ content: NSView, size: NSSize) -> NSView {
        let frame = NSRect(origin: .zero, size: size)
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: frame)
            glass.autoresizingMask = [.width, .height]
            glass.cornerRadius = Self.cornerRadius
            glass.style = .regular
            glass.contentView = content
            return glass
        }
        let effect = NSVisualEffectView(frame: frame)
        effect.material = .hudWindow
        // A child window over the workspace is the one arrangement where
        // `.behindWindow` blurs what is behind the panel and nothing else.
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.autoresizingMask = [.width, .height]
        effect.wantsLayer = true
        effect.layer?.cornerRadius = Self.cornerRadius
        effect.layer?.masksToBounds = true
        effect.layer?.borderWidth = 1
        effect.layer?.borderColor = NSColor(white: 1, alpha: 0.12).cgColor
        effect.addSubview(content)
        return effect
    }

    /// Opens over `parent`, rebuilt from scratch so the list can never offer
    /// a pane that closed while the palette was shut.
    func present(commands: [PaletteCommand], over parent: NSWindow?) {
        model.reset(commands: commands)
        field.stringValue = ""
        rebuildDisplay()
        syncSelection()
        // Strict stacking without fighting window levels: the scrim is a
        // child of the workspace and the panel a child of the scrim, and a
        // child window is always above its parent.
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
            let frame = window.frame
            window.setFrameOrigin(
                NSPoint(
                    x: parent.frame.midX - frame.width / 2,
                    y: parent.frame.midY - frame.height / 2 + parent.frame.height / 6
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

    /// Moves the highlight, keeping the table in step — what ⌃/⌄ do, exposed
    /// so the keyboard path and a test drive the same code.
    func moveSelection(by delta: Int) {
        model.moveSelection(by: delta)
        syncSelection()
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
        rebuildDisplay()
        syncSelection()
    }

    /// One heading wherever the section changes — the rows already arrive in
    /// section order, so this is a walk, not a sort.
    private func rebuildDisplay() {
        display = []
        var current: PaletteSection?
        for (index, command) in model.matches.enumerated() {
            if command.section != current {
                display.append(.header(command.section))
                current = command.section
            }
            display.append(.command(index))
        }
        tableView.reloadData()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(by: 1)
            return true
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(by: -1)
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

    /// Arrow keys are handled by the field, but clicking still moves the
    /// model so Enter runs what the eye is on.
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard tableView.selectedRow >= 0, display.indices.contains(tableView.selectedRow),
              case let .command(index) = display[tableView.selectedRow]
        else { return }
        model.select(index: index)
    }
}

/// A panel that can become key while the app stays put, and that treats
/// Escape as "close me" rather than passing it on.
final class CommandPalettePanel: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
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

/// One palette row: the section's icon, the title, and the hint on the right.
final class PaletteRowView: NSTableCellView {
    init(command: PaletteCommand) {
        super.init(frame: .zero)
        let icon = NSImageView()
        icon.image = NSImage(
            systemSymbolName: command.section.symbol,
            accessibilityDescription: nil
        )?.withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
        icon.contentTintColor = NSColor(white: 1, alpha: 0.75)
        addSubview(icon)

        let title = NSTextField(labelWithAttributedString: Self.styled(command.title))
        title.lineBreakMode = .byTruncatingTail
        addSubview(title)
        textField = title

        let detail = NSTextField(labelWithString: command.detail ?? "")
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = NSColor(white: 1, alpha: 0.5)
        detail.alignment = .right
        detail.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(detail)

        setAccessibilityElement(true)
        setAccessibilityLabel(command.detail.map { "\(command.title), \($0)" } ?? command.title)

        icon.translatesAutoresizingMaskIntoConstraints = false
        title.translatesAutoresizingMaskIntoConstraints = false
        detail.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            detail.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 12),
            detail.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            detail.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    /// The name at full strength, everything after the first em dash dimmed:
    /// one string in the model, two weights on screen, and a column of rows
    /// that scans by name rather than by the words they have in common.
    static func styled(_ title: String) -> NSAttributedString {
        let text = NSMutableAttributedString(
            string: title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 14),
                .foregroundColor: NSColor(white: 1, alpha: 0.96),
            ]
        )
        if let dash = title.range(of: " — ") {
            let start = title.distance(from: title.startIndex, to: dash.lowerBound)
            text.addAttributes(
                [.foregroundColor: NSColor(white: 1, alpha: 0.45)],
                range: NSRange(location: start, length: (title as NSString).length - start)
            )
        }
        return text
    }
}

/// The dim wash the spotlight sits on — a translucent borderless child window
/// covering the workspace. It exists for two reasons: everything that is not
/// the spotlight reads as pushed back, and the click that lands outside the
/// panel has something to hit that means "close".
final class SpotlightScrimWindow: NSWindow {
    var onClick: (() -> Void)?

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        isOpaque = false
        hasShadow = false
        backgroundColor = NSColor.black.withAlphaComponent(0.5)
        level = .floating
        // Hides and returns with the panel, which does the same — otherwise
        // switching apps would leave the workspace dimmed with nothing on it.
        hidesOnDeactivate = true
        alphaValue = 0
        contentView = ScrimClickView { [weak self] in self?.onClick?() }
    }

    /// Never key: the search field's window has to keep the keyboard.
    override var canBecomeKey: Bool { false }

    func fadeIn() {
        alphaValue = 0
        orderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
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
