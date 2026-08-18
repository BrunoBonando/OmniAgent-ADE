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

    init() {
        let panel = CommandPalettePanel(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 380),
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
        field.font = .systemFont(ofSize: 19, weight: .regular)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = self
        field.setAccessibilityLabel("Spotlight query")

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("command"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 30
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

        let glass = NSVisualEffectView(frame: NSRect(origin: .zero, size: panel.frame.size))
        glass.material = .hudWindow
        glass.blendingMode = .behindWindow
        // `.active`, not `.followsWindowActiveState`: the glass must not go
        // flat the moment something else takes key.
        glass.state = .active
        glass.autoresizingMask = [.width, .height]
        glass.wantsLayer = true
        glass.layer?.cornerRadius = 16
        glass.layer?.masksToBounds = true
        glass.layer?.borderWidth = 1
        glass.layer?.borderColor = NSColor(white: 1, alpha: 0.12).cgColor

        field.frame = NSRect(x: 22, y: glass.bounds.height - 58, width: glass.bounds.width - 44, height: 34)
        field.autoresizingMask = [.width, .minYMargin]
        let rule = NSView(frame: NSRect(x: 0, y: glass.bounds.height - 68, width: glass.bounds.width, height: 1))
        rule.autoresizingMask = [.width, .minYMargin]
        rule.wantsLayer = true
        rule.layer?.backgroundColor = NSColor(white: 1, alpha: 0.09).cgColor
        scrollView.frame = NSRect(x: 8, y: 8, width: glass.bounds.width - 16, height: glass.bounds.height - 80)
        scrollView.autoresizingMask = [.width, .height]
        glass.addSubview(field)
        glass.addSubview(rule)
        glass.addSubview(scrollView)
        panel.contentView = glass
        panel.initialFirstResponder = field
        panel.onCancel = { [weak self] in self?.dismiss() }
        scrim.onClick = { [weak self] in self?.dismiss() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    /// Opens over `parent`, rebuilt from scratch so the list can never offer
    /// a pane that closed while the palette was shut.
    func present(commands: [PaletteCommand], over parent: NSWindow?) {
        model.reset(commands: commands)
        field.stringValue = ""
        tableView.reloadData()
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
        tableView.reloadData()
        syncSelection()
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
        guard tableView.clickedRow >= 0 else { return }
        model.select(index: tableView.clickedRow)
        runSelected()
    }

    private func syncSelection() {
        let rows = model.matches
        guard !rows.isEmpty else {
            tableView.deselectAll(nil)
            return
        }
        tableView.selectRowIndexes(IndexSet(integer: model.selectedIndex), byExtendingSelection: false)
        tableView.scrollRowToVisible(model.selectedIndex)
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { model.matches.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let rows = model.matches
        guard rows.indices.contains(row) else { return nil }
        return PaletteRowView(command: rows[row])
    }

    /// Arrow keys are handled by the field, but clicking still moves the
    /// model so Enter runs what the eye is on.
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard tableView.selectedRow >= 0 else { return }
        model.select(index: tableView.selectedRow)
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

/// One palette row: title on the left, hint on the right.
final class PaletteRowView: NSTableCellView {
    init(command: PaletteCommand) {
        super.init(frame: .zero)
        let title = NSTextField(labelWithString: command.title)
        title.font = .systemFont(ofSize: 13)
        title.lineBreakMode = .byTruncatingTail
        addSubview(title)
        textField = title

        let detail = NSTextField(labelWithString: command.detail ?? "")
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = NSColor(srgbRed: 130 / 255, green: 140 / 255, blue: 158 / 255, alpha: 1)
        detail.alignment = .right
        addSubview(detail)

        setAccessibilityElement(true)
        setAccessibilityLabel(command.detail.map { "\(command.title), \($0)" } ?? command.title)

        title.translatesAutoresizingMaskIntoConstraints = false
        detail.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            detail.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 8),
            detail.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            detail.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
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
