import AppKit

/// The ⌘K palette: a floating panel with a search field over a table of
/// matches.
///
/// An `NSPanel` rather than a sheet so it can be dismissed with Escape
/// without unwinding a modal session, and so the workspace behind it stays
/// visible while you read the list. All filtering and selection lives in
/// `CommandPaletteModel`; this is the keyboard and the pixels.
final class CommandPaletteController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate,
    NSTextFieldDelegate {
    /// Raised with the chosen row's action. The palette closes first, so the
    /// action lands with focus already back in the workspace.
    var onRun: ((PaletteAction) -> Void)?

    private(set) var model = CommandPaletteModel()
    private let field = NSTextField()
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()

    init() {
        let panel = CommandPalettePanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 340),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.hidesOnDeactivate = true
        panel.level = .floating
        super.init(window: panel)

        field.placeholderString = "Switch pane, or run a command…"
        field.font = .systemFont(ofSize: 16)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = self
        field.setAccessibilityLabel("Command palette query")

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("command"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 28
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(rowClicked)
        tableView.setAccessibilityLabel("Command palette results")

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false

        let container = NSView(frame: panel.contentLayoutRect)
        container.autoresizingMask = [.width, .height]
        field.frame = NSRect(x: 18, y: container.bounds.height - 46, width: container.bounds.width - 36, height: 30)
        field.autoresizingMask = [.width, .minYMargin]
        scrollView.frame = NSRect(x: 8, y: 8, width: container.bounds.width - 16, height: container.bounds.height - 60)
        scrollView.autoresizingMask = [.width, .height]
        container.addSubview(field)
        container.addSubview(scrollView)
        panel.contentView = container
        panel.initialFirstResponder = field
        panel.onCancel = { [weak self] in self?.dismiss() }
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
        if let parent, window?.parent !== parent {
            parent.addChildWindow(window!, ordered: .above)
        }
        if let parent, let window {
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
        window?.parent?.removeChildWindow(window!)
        window?.orderOut(nil)
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
