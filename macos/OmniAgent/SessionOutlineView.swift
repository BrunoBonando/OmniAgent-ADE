import AppKit

/// The sidebar's session outline: workspace -> session -> pane, over a real
/// `NSOutlineView` (so disclosure, keyboard navigation, type-select and
/// VoiceOver come from AppKit rather than being re-implemented).
///
/// Read-only over the pane model: it renders whatever `reload(panes:focused:)`
/// is handed and raises intents. `WorkspaceWindowController` owns every
/// mutation, exactly as it does for the grid.
final class SessionOutlineView: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate {
    /// Selecting a pane row asks for that pane.
    var onSelectPane: ((String) -> Void)?
    /// Selecting a session row asks for its first pane — a session is a set
    /// of panes, and "go to this session" means "go to where it starts".
    var onSelectSession: ((SessionGroupNode) -> Void)?
    /// The "+" on a session row, carrying **that** row's session — never
    /// "whatever has focus". Clicking "+" on session 2 while a session 1 pane
    /// is focused has to open the pane in session 2.
    var onRequestNewPane: ((SessionGroupNode) -> Void)?
    /// A renamed session row — the outline validates only that the name is
    /// non-empty and actually changed.
    var onRenameSession: ((SessionGroupNode, String) -> Void)?

    let outlineView = NSOutlineView()

    private let scrollView = NSScrollView()
    private var tree: [ProjectSessionsNode] = []
    private var panes: [String: PaneDescriptor] = [:]
    private var focusedPaneID: String?
    /// Set while the outline is applying a model change, so the selection it
    /// restores does not echo back as a user intent.
    private var isReloading = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(srgbRed: 10 / 255, green: 13 / 255, blue: 18 / 255, alpha: 1).cgColor

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("session"))
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.rowSizeStyle = .default
        outlineView.floatsGroupRows = false
        outlineView.selectionHighlightStyle = .sourceList
        outlineView.autoresizesOutlineColumn = false
        outlineView.dataSource = self
        outlineView.delegate = self
        // Renaming through the outline's own double-click action rather than
        // a `mouseDown` override on the cell: `NSOutlineView` consumes the
        // mouse itself, so a cell-level override would simply never fire.
        outlineView.target = self
        outlineView.doubleAction = #selector(rowDoubleClicked)
        outlineView.setAccessibilityLabel("Sessions")

        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.autoresizingMask = [.width, .height]
        scrollView.frame = bounds
        addSubview(scrollView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    /// Re-derives the tree from the panes and re-renders, keeping every
    /// project and session expanded (the outline is short — a workspace holds
    /// at most eight panes — so collapsing hides more than it saves) and
    /// re-selecting the focused pane's row.
    ///
    /// **Deferred while a name is being edited.** This is called from
    /// `onPanesChanged`, which a background pane repainting its shell prompt
    /// fires several times a second (a pane row falls back to the terminal's
    /// live OSC title when it has no name of its own, so the rendered tree
    /// really does change). `reloadData` tears down the open field editor and
    /// yanks the selection back, so a rename would be impossible to finish on
    /// any window with a busy pane in it. The newest request is kept and
    /// applied the moment editing ends — never dropped.
    func reload(panes: [PaneDescriptor], focusedPaneID: String?) {
        guard !isRenaming else {
            pendingReload = (panes, focusedPaneID)
            return
        }
        pendingReload = nil
        self.panes = Dictionary(uniqueKeysWithValues: panes.map { ($0.sessionID, $0) })
        self.focusedPaneID = focusedPaneID
        tree = SessionOutline.group(panes, focusedPaneID: focusedPaneID)
        isReloading = true
        outlineView.reloadData()
        outlineView.expandItem(nil, expandChildren: true)
        if let focusedPaneID {
            let row = outlineView.row(forItem: OutlineItem.pane(focusedPaneID))
            if row >= 0 {
                outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
        } else {
            outlineView.deselectAll(nil)
        }
        isReloading = false
    }

    /// True while a session row's name field is open. Tracked here rather
    /// than read from `outlineView.currentEditor()`, which is always `nil` in
    /// a view-based table: the editing control is the `NSTextField` inside
    /// the cell, not the table itself.
    private(set) var isRenaming = false
    private var pendingReload: (panes: [PaneDescriptor], focusedPaneID: String?)?

    private func editingEnded() {
        isRenaming = false
        guard let pending = pendingReload else { return }
        reload(panes: pending.panes, focusedPaneID: pending.focusedPaneID)
    }

    /// The outline's items. A value type keyed by id rather than the model
    /// structs themselves, so `NSOutlineView`'s identity survives a reload
    /// that changed a session's label or a pane's title.
    enum OutlineItem: Hashable {
        case project(String)
        case session(project: String, group: String)
        case pane(String)
    }

    private func projectNode(_ project: String) -> ProjectSessionsNode? {
        tree.first { $0.project == project }
    }

    private func sessionNode(project: String, group: String) -> SessionGroupNode? {
        projectNode(project)?.sessions.first { $0.id == group }
    }

    // MARK: - NSOutlineViewDataSource

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        switch item as? OutlineItem {
        case .none: return tree.count
        case let .project(project): return projectNode(project)?.sessions.count ?? 0
        case let .session(project, group): return sessionNode(project: project, group: group)?.paneIDs.count ?? 0
        case .pane: return 0
        }
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        switch item as? OutlineItem {
        case .none:
            return OutlineItem.project(tree[index].project)
        case let .project(project):
            let session = projectNode(project)?.sessions[index]
            return OutlineItem.session(project: project, group: session?.id ?? "")
        case let .session(project, group):
            return OutlineItem.pane(sessionNode(project: project, group: group)?.paneIDs[index] ?? "")
        case .pane:
            return OutlineItem.pane("")
        }
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        self.outlineView(outlineView, numberOfChildrenOfItem: item) > 0
    }

    // MARK: - NSOutlineViewDelegate

    /// Rows are **reused by identifier**, one identifier per kind (a session
    /// row carries a "+" button the other two do not, so the three are not
    /// interchangeable). Rebuilding a cell on every reload is what made an
    /// open name field disposable; a reused cell is re-labelled in place.
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let item = item as? OutlineItem else { return nil }
        switch item {
        case let .project(project):
            let row = dequeue(kind: .project)
            row.apply(title: SessionOutline.projectLabel(project), detail: nil, kind: .project)
            return row
        case let .session(project, group):
            guard let session = sessionNode(project: project, group: group) else { return nil }
            let row = dequeue(kind: .session(isCurrent: session.isCurrent))
            row.apply(
                title: session.label,
                detail: session.paneIDs.count == 1 ? "1 pane" : "\(session.paneIDs.count) panes",
                kind: .session(isCurrent: session.isCurrent)
            )
            row.onRename = { [weak self] name in self?.onRenameSession?(session, name) }
            row.onAdd = { [weak self] in self?.onRequestNewPane?(session) }
            row.onEditingEnded = { [weak self] in self?.editingEnded() }
            return row
        case let .pane(id):
            guard let pane = panes[id] else { return nil }
            let row = dequeue(kind: .pane(isFocused: id == focusedPaneID))
            row.apply(
                title: SessionOutline.paneLabel(pane),
                detail: pane.engine.rawValue,
                kind: .pane(isFocused: id == focusedPaneID)
            )
            return row
        }
    }

    private func dequeue(kind: SessionOutlineRowView.Kind) -> SessionOutlineRowView {
        let identifier = NSUserInterfaceItemIdentifier(kind.reuseIdentifier)
        if let existing = outlineView.makeView(withIdentifier: identifier, owner: self) as? SessionOutlineRowView {
            return existing
        }
        let row = SessionOutlineRowView(kind: kind)
        row.identifier = identifier
        return row
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isReloading else { return }
        let row = outlineView.selectedRow
        guard row >= 0, let item = outlineView.item(atRow: row) as? OutlineItem else { return }
        switch item {
        case .project:
            break
        case let .session(project, group):
            if let session = sessionNode(project: project, group: group) { onSelectSession?(session) }
        case let .pane(id):
            onSelectPane?(id)
        }
    }

    /// A project row is a header: it groups, it never navigates.
    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        if case .project = item as? OutlineItem { return false }
        return true
    }

    /// Double-clicking a session row renames it in place — the same gesture
    /// the web build's pane header and project menu established.
    @objc func rowDoubleClicked() {
        beginRenamingSession(atRow: outlineView.clickedRow)
    }

    /// Split out so the gesture and a test drive the same code. Opening the
    /// field is what suspends reloads — see `reload`.
    @discardableResult
    func beginRenamingSession(atRow row: Int) -> Bool {
        guard row >= 0, case .session = outlineView.item(atRow: row) as? OutlineItem,
              let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: true) as? SessionOutlineRowView,
              cell.beginRename()
        else { return false }
        isRenaming = true
        return true
    }
}

/// One outline row. Three kinds, one view: the differences are typography and
/// which affordances the row carries, not structure.
///
/// Built once per kind and then **reused** — `apply(title:detail:kind:)`
/// re-labels an existing row rather than the outline constructing a fresh one
/// for every reload.
final class SessionOutlineRowView: NSTableCellView {
    enum Kind {
        case project
        case session(isCurrent: Bool)
        case pane(isFocused: Bool)

        /// One identifier per kind: a session row carries a "+" button the
        /// other two do not, so the three are not interchangeable in the
        /// reuse queue.
        var reuseIdentifier: String {
            switch self {
            case .project: return "digital.bruno.omniagent.outline.project"
            case .session: return "digital.bruno.omniagent.outline.session"
            case .pane: return "digital.bruno.omniagent.outline.pane"
            }
        }
    }

    /// Committed on ⏎ or blur, only when non-empty — the same
    /// double-click-to-rename gesture the web's `PaneHeader`/`ProjectMenu`
    /// established.
    var onRename: ((String) -> Void)?
    var onAdd: (() -> Void)?
    /// Raised whichever way editing finished (committed, blurred, cancelled),
    /// so the outline knows it may reload again.
    var onEditingEnded: (() -> Void)?

    fileprivate let label = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private var kind: Kind
    private var addButton: NSButton?
    /// Guards against the double commit of `NSTextField`'s action *and*
    /// `controlTextDidEndEditing` both firing for one edit.
    private var isEditing = false

    init(kind: Kind) {
        self.kind = kind
        super.init(frame: .zero)

        label.lineBreakMode = .byTruncatingTail
        label.isEditable = false
        label.isBordered = false
        label.drawsBackground = false
        label.target = self
        label.action = #selector(commitEditedName)
        label.delegate = self
        addSubview(label)
        textField = label

        detail.font = NSFont.systemFont(ofSize: 10)
        detail.textColor = NSColor(srgbRed: 110 / 255, green: 120 / 255, blue: 138 / 255, alpha: 1)
        detail.alignment = .right
        addSubview(detail)

        if case .session = kind {
            let button = NSButton(title: "+", target: self, action: #selector(add))
            button.bezelStyle = .inline
            button.isBordered = false
            button.font = NSFont.systemFont(ofSize: 13, weight: .medium)
            addSubview(button)
            addButton = button
        }

        setAccessibilityElement(true)
    }

    /// Re-labels a reused row. Deliberately a no-op on the text while the
    /// name field is open: a reload that slipped through would otherwise
    /// overwrite what the user is typing.
    func apply(title: String, detail detailText: String?, kind: Kind) {
        self.kind = kind
        label.font = Self.font(for: kind)
        label.textColor = Self.color(for: kind)
        if !isEditing {
            label.stringValue = title
        }
        detail.stringValue = detailText ?? ""
        detail.isHidden = detailText == nil
        addButton?.setAccessibilityLabel("New pane in \(title)")
        setAccessibilityLabel(Self.accessibilityLabelText(title: title, kind: kind))
        needsLayout = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func layout() {
        super.layout()
        let trailing: CGFloat = addButton == nil ? 0 : 20
        let detailWidth: CGFloat = detail.isHidden ? 0 : 58
        label.frame = NSRect(
            x: 0,
            y: 0,
            width: max(0, bounds.width - detailWidth - trailing),
            height: bounds.height
        )
        detail.frame = NSRect(
            x: max(0, bounds.width - detailWidth - trailing),
            y: 0,
            width: detailWidth,
            height: bounds.height
        )
        addButton?.frame = NSRect(x: max(0, bounds.width - trailing), y: 0, width: trailing, height: bounds.height)
    }

    @discardableResult
    func beginRename() -> Bool {
        guard case .session = kind else { return false }
        isEditing = true
        label.isEditable = true
        label.isBordered = true
        label.drawsBackground = true
        window?.makeFirstResponder(label)
        return true
    }

    @objc private func commitEditedName() {
        commitRename(named: label.stringValue)
    }

    /// The name the field ended up holding, trimmed. A blank name is not a
    /// rename — it leaves the session called whatever it was.
    func commitRename(named name: String) {
        guard isEditing else { return }
        isEditing = false
        label.isEditable = false
        label.isBordered = false
        label.drawsBackground = false
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            onRename?(trimmed)
        }
        // Always, even for a rejected blank name: the outline is holding a
        // deferred reload and must not hold it forever.
        onEditingEnded?()
    }

    @objc private func add() {
        onAdd?()
    }

    private static func font(for kind: Kind) -> NSFont {
        switch kind {
        case .project: return .systemFont(ofSize: 10, weight: .semibold)
        case let .session(isCurrent): return .systemFont(ofSize: 12, weight: isCurrent ? .semibold : .regular)
        case .pane: return .systemFont(ofSize: 12, weight: .regular)
        }
    }

    private static func color(for kind: Kind) -> NSColor {
        switch kind {
        case .project:
            return NSColor(srgbRed: 110 / 255, green: 120 / 255, blue: 138 / 255, alpha: 1)
        case let .session(isCurrent):
            return isCurrent
                ? NSColor(srgbRed: 65 / 255, green: 132 / 255, blue: 255 / 255, alpha: 1)
                : NSColor(srgbRed: 224 / 255, green: 229 / 255, blue: 237 / 255, alpha: 1)
        case let .pane(isFocused):
            return isFocused
                ? NSColor(srgbRed: 224 / 255, green: 229 / 255, blue: 237 / 255, alpha: 1)
                : NSColor(srgbRed: 160 / 255, green: 170 / 255, blue: 186 / 255, alpha: 1)
        }
    }

    private static func accessibilityLabelText(title: String, kind: Kind) -> String {
        switch kind {
        case .project: return "Workspace \(title)"
        case let .session(isCurrent): return isCurrent ? "\(title), current session" : "Session \(title)"
        case let .pane(isFocused): return isFocused ? "\(title), focused pane" : "Pane \(title)"
        }
    }
}

/// Blur and Escape end editing too, not just ⏎ — otherwise a rename
/// abandoned by clicking elsewhere would leave the outline's deferred
/// reload parked forever.
extension SessionOutlineRowView: NSTextFieldDelegate {
    func controlTextDidEndEditing(_ notification: Notification) {
        commitRename(named: label.stringValue)
    }
}
