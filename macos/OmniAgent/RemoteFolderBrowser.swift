import AppKit

// "Add local folder…" while this Mac is driving another (2026-09-01 remote
// environment sharing spec §4/§6, Task 28). `NSOpenPanel` reads *this*
// machine's own filesystem — the wrong one for the whole time a lease is
// held, the same class of bug `HostStateModel` exists to fix for the
// sidebar's gauges (Task 26). This file is the daemon-backed replacement: a
// model that walks the daemon's `ListDirectory` RPC (`0x1d`, Task 9) one
// directory at a time, and the liquid-glass sheet built on it.
//
// `WorkspaceWindowController.usesNativeOpenPanel(isDrivingRemote:)` is the
// one fact that decides which of this file or `NSOpenPanel` a folder pick
// uses — asked the same way by every caller rather than an inline
// `isDrivingRemote` check duplicated at each one.

/// Talks to the daemon's `ListDirectory` RPC. Kept apart from the view so
/// the network/decoding half is testable without a window — `list(_:)` is
/// this type's whole contract, proven directly against a real (fake)
/// daemon in `RemoteFolderBrowserTests`.
final class RemoteFolderBrowser {
    private let connection: SessionConnection

    /// Whether the most recent `list(_:)` had to drop entries past the
    /// daemon's `LIST_DIRECTORY_MAX_ENTRIES` cap (512, `protocol.rs`). A
    /// caller must render this: silently showing part of a directory as if
    /// it were the whole one is how a folder picker lies — the daemon's own
    /// words for the flag.
    private(set) var truncated = false

    init(connection: SessionConnection) {
        self.connection = connection
    }

    /// Only a directory can be entered or added; a file is listed for
    /// context and nothing else — `ListDirectory` never says more than a
    /// name and `is_dir`, so there is nothing else *to* choose.
    func canChoose(_ entry: DirectoryEntry) -> Bool { entry.isDir }

    /// One directory's entries, directories-first then alphabetical — the
    /// daemon's own ordering, trusted rather than re-sorted here.
    func list(_ path: String) async throws -> [DirectoryEntry] {
        let listing = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<DirectoryListing, Error>) in
            connection.listDirectory(path: path) { continuation.resume(with: $0) }
        }
        truncated = listing.truncated
        return listing.entries
    }
}

/// The sheet's own state — what it is showing right now, independent of
/// which directory produced it. Kept as one value rather than a scatter of
/// booleans so the table's data source can never show, say, an error message
/// *and* a stale entry list at once.
private enum RemoteFolderBrowserStatus: Equatable {
    case loading
    case loaded([DirectoryEntry], truncated: Bool)
    case failed(String)
}

/// The picker's glass sheet: the house modal standard (`PaneAskOverlayView`),
/// built from the same two panels and the same navy wash `RemoteSessionPickerView`
/// uses, with a folder list where that one has a session list.
///
/// Deliberately not an `NSAlert` and not an `NSOpenPanel` in disguise — this
/// view never touches the filesystem itself. Every entry it shows, and every
/// directory it descends into, came from a `ListDirectory` reply; `apply`/
/// `applyFailure`/`beginLoading` are the only way its state changes, so the
/// view is fully driven and fully testable without a real connection.
final class RemoteFolderBrowserView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    /// A directory the user double-clicked into, or the "up" chevron's
    /// target — the caller (`RemoteFolderBrowserController`) fetches the new
    /// listing and reports back through `beginLoading`/`apply`/
    /// `applyFailure`. This view never calls the daemon itself.
    var onNavigate: ((String) -> Void)?
    /// The chosen absolute path — the selected subfolder if one is
    /// highlighted, otherwise the directory currently being browsed. Handed
    /// straight to the caller, which decides what "Add" means for it
    /// (`WorkspaceWindowController.openWorkspaceFolder` calls
    /// `RootsAddProject`; Home's picker only points at it).
    var onAdd: ((String) -> Void)?
    /// Escape, a click on the glass, or Cancel.
    var onCancel: (() -> Void)?

    private(set) var currentPath: String
    private var status: RemoteFolderBrowserStatus = .loading
    /// Index into the current `.loaded` entries, or `nil` — only ever set on
    /// a directory row (`tableView(_:shouldSelectRow:)` refuses a file).
    private var selectedIndex: Int?

    private static let cardWidth: CGFloat = 480
    private static let padding: CGFloat = 22
    private static let iconSize: CGFloat = 30
    private static let buttonHeight: CGFloat = 26
    private static let cardRadius: CGFloat = 16
    private static let pathBarHeight: CGFloat = 30
    private static let rowHeight: CGFloat = 32
    private static let maxListHeight: CGFloat = 260

    private let scrim: NSView?
    private let cardGlass: NSView?
    private let cardTint = NSView()
    private let cardTintLayer = CAGradientLayer()
    /// `PaneAskOverlayView`'s navy, copied for the reason `RemoteSessionPickerView`
    /// copies it: two colours are not worth tying two overlays together.
    private static let navyTint = [
        NSColor(srgbRed: 0.11, green: 0.16, blue: 0.38, alpha: 0.40).cgColor,
        NSColor(srgbRed: 0.05, green: 0.08, blue: 0.22, alpha: 0.14).cgColor,
    ]

    private let iconView = NSImageView()
    private let titleLabel: NSTextField
    private let messageLabel: NSTextField
    private let pathBar = NSView()
    private let upButton = NSButton()
    private let pathLabel: NSTextField
    private let listWell = NSView()
    private let scrollView = NSScrollView()
    private let tableView = FolderBrowserTableView()
    private let truncatedLabel: NSTextField
    private let buttons: [PaneApprovalButton]
    private var cardFrame: NSRect = .zero
    private var isAnswered = false

    /// `machineName` names the host in the title ("Add a folder on Bruno's
    /// Mac Studio") when known; `nil` falls back to plain wording rather
    /// than leaving a blank.
    init(machineName: String?, startingAt path: String) {
        currentPath = path
        titleLabel = Self.label(
            machineName.map { "Add a folder on \($0)" } ?? "Add a folder on the other Mac",
            font: ShellFont.ui(15, .semibold),
            color: NSColor(srgbRed: 240 / 255, green: 240 / 255, blue: 244 / 255, alpha: 1)
        )
        messageLabel = Self.label(
            "This browses the other Mac's disk, not this one — only a folder can be added.",
            font: ShellFont.ui(12.5),
            color: NSColor(srgbRed: 176 / 255, green: 180 / 255, blue: 198 / 255, alpha: 1)
        )
        pathLabel = Self.label(
            path,
            font: ShellFont.ui(12, .medium),
            color: NSColor(white: 1, alpha: 0.85)
        )
        pathLabel.alignment = .left
        pathLabel.lineBreakMode = .byTruncatingHead
        pathLabel.maximumNumberOfLines = 1
        truncatedLabel = Self.label(
            "Showing the first 512 items in this folder.",
            font: ShellFont.ui(11),
            color: NSColor(srgbRed: 235 / 255, green: 190 / 255, blue: 120 / 255, alpha: 1)
        )
        truncatedLabel.isHidden = true
        buttons = [
            PaneApprovalButton(title: "Cancel", isPrimary: false, tint: PaneAskOverlayView.accent),
            PaneApprovalButton(title: "Add", isPrimary: true, tint: PaneAskOverlayView.accent),
        ]
        if #available(macOS 26.0, *) {
            let pane = NSGlassEffectView()
            pane.style = .regular
            pane.tintColor = nil
            scrim = pane
            let card = NSGlassEffectView()
            card.style = .regular
            card.cornerRadius = Self.cardRadius
            card.tintColor = nil
            cardGlass = card
        } else {
            scrim = nil
            cardGlass = nil
        }
        super.init(frame: .zero)
        wantsLayer = true

        iconView.image = NSImage(systemSymbolName: "folder.badge.gearshape", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 22, weight: .regular))
        iconView.contentTintColor = NSColor(white: 1, alpha: 0.92)
        iconView.imageScaling = .scaleProportionallyUpOrDown

        cardTint.wantsLayer = true
        cardTintLayer.colors = Self.navyTint
        cardTintLayer.startPoint = CGPoint(x: 0.5, y: 1)
        cardTintLayer.endPoint = CGPoint(x: 0.5, y: 0)
        cardTint.layer?.addSublayer(cardTintLayer)
        cardTint.layer?.cornerRadius = Self.cardRadius
        cardTint.layer?.cornerCurve = .continuous
        cardTint.layer?.masksToBounds = true
        cardTint.layer?.borderWidth = 1
        cardTint.layer?.borderColor = NSColor(white: 1, alpha: 0.16).cgColor

        upButton.image = NSImage(systemSymbolName: "chevron.up", accessibilityDescription: "Up one folder")
        upButton.bezelStyle = .accessoryBarAction
        upButton.isBordered = false
        upButton.target = self
        upButton.action = #selector(upTapped)
        upButton.contentTintColor = NSColor(white: 1, alpha: 0.85)

        pathBar.addSubview(upButton)
        pathBar.addSubview(pathLabel)

        listWell.wantsLayer = true
        listWell.layer?.backgroundColor = NSColor(white: 1, alpha: 0.06).cgColor
        listWell.layer?.cornerRadius = 10
        listWell.layer?.cornerCurve = .continuous
        listWell.layer?.borderWidth = 1
        listWell.layer?.borderColor = NSColor(white: 1, alpha: 0.12).cgColor
        listWell.layer?.masksToBounds = true

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("remote-folder"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = Self.rowHeight
        tableView.style = .inset
        tableView.backgroundColor = .clear
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.allowsEmptySelection = true
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(rowDoubleClicked)
        tableView.setAccessibilityLabel("Folder contents")
        tableView.onReturn = { [weak self] in self?.activateAdd() }
        tableView.onEscape = { [weak self] in self?.cancel() }

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.automaticallyAdjustsContentInsets = false
        listWell.addSubview(scrollView)

        for button in buttons {
            let isAdd = button.isPrimary
            button.onClick = { [weak self] in
                if isAdd { self?.activateAdd() } else { self?.cancel() }
            }
        }

        for view in [scrim, cardGlass].compactMap({ $0 })
            + [cardTint, iconView, titleLabel, messageLabel, pathBar, listWell, truncatedLabel]
            + (buttons as [NSView])
        {
            addSubview(view)
        }

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Add a folder")
        applyStatusToUpButton()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    private static func label(_ text: String, font: NSFont, color: NSColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = font
        field.textColor = color
        field.alignment = .center
        field.lineBreakMode = .byWordWrapping
        field.maximumNumberOfLines = 0
        return field
    }

    override var isFlipped: Bool { true }

    var firstResponderView: NSView { tableView }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: activateAdd() // Return, Enter
        case 53: cancel() // Esc
        default: NSSound.beep()
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard !cardFrame.contains(convert(event.locationInWindow, from: nil)) else { return }
        cancel()
    }

    // MARK: - Driven state (the controller's only door into this view)

    /// The controller is about to fetch `path` — the list well shows a
    /// loading placeholder and the selection is cleared, since whatever was
    /// selected belonged to the directory being left.
    func beginLoading(path: String) {
        currentPath = path
        pathLabel.stringValue = path
        status = .loading
        selectedIndex = nil
        truncatedLabel.isHidden = true
        applyStatusToUpButton()
        tableView.reloadData()
    }

    /// `path`'s listing came back. Ignored by the controller (never called)
    /// for a path the sheet has since navigated away from — see
    /// `RemoteFolderBrowserController`'s request token.
    func apply(path: String, entries: [DirectoryEntry], truncated: Bool) {
        currentPath = path
        pathLabel.stringValue = path
        status = .loaded(entries, truncated: truncated)
        selectedIndex = nil
        truncatedLabel.isHidden = !truncated
        applyStatusToUpButton()
        tableView.reloadData()
        needsLayout = true
    }

    /// `path`'s listing failed — an unreadable directory (permissions, or one
    /// that vanished between the click and the reply) is an error to show,
    /// not a panic.
    func applyFailure(path: String, message: String) {
        currentPath = path
        pathLabel.stringValue = path
        status = .failed(message)
        selectedIndex = nil
        truncatedLabel.isHidden = true
        applyStatusToUpButton()
        tableView.reloadData()
    }

    private func applyStatusToUpButton() {
        upButton.isEnabled = currentPath != "/" && currentPath.isEmpty == false
    }

    // MARK: - Answering

    /// Confirms whichever the sheet currently offers: the selected subfolder,
    /// or — with nothing selected — the folder being browsed itself. The
    /// same two paths `NSOpenPanel`'s "Choose" supports, mapped onto one
    /// button because this sheet only ever shows one directory at a time.
    func activateAdd() {
        guard !isAnswered else { return }
        guard case .loaded = status else { return NSSound.beep() }
        isAnswered = true
        onAdd?(addTarget())
    }

    /// Escape, the glass, Cancel.
    func cancel() {
        guard !isAnswered else { return }
        isAnswered = true
        onCancel?()
    }

    private func addTarget() -> String {
        if case let .loaded(entries, _) = status,
           let selectedIndex, entries.indices.contains(selectedIndex), entries[selectedIndex].isDir
        {
            return (currentPath as NSString).appendingPathComponent(entries[selectedIndex].name)
        }
        return currentPath
    }

    @objc private func upTapped() {
        onNavigate?(Self.parentPath(of: currentPath))
    }

    /// `deletingLastPathComponent` returns `""` for a top-level entry like
    /// `/Users` — root itself, not nothing — so that case is mapped back to
    /// `/` rather than handed to `ListDirectory` as an empty path.
    static func parentPath(of path: String) -> String {
        let parent = (path as NSString).deletingLastPathComponent
        return parent.isEmpty ? "/" : parent
    }

    /// A double-click on a directory row descends into it; on a file row —
    /// unreachable in production since a file row never takes the
    /// selection, reachable only by a test driving `clickedRow` directly —
    /// it does nothing.
    @objc private func rowDoubleClicked() {
        guard case let .loaded(entries, _) = status, entries.indices.contains(tableView.clickedRow),
              entries[tableView.clickedRow].isDir
        else { return }
        onNavigate?((currentPath as NSString).appendingPathComponent(entries[tableView.clickedRow].name))
    }

    // MARK: - Testing seams

    /// Drives the same `@objc` action the up button's `target`/`action`
    /// fires — reachable in production only through a real click.
    func upTappedForTesting() { upTapped() }

    func selectEntryForTesting(at index: Int) {
        guard case let .loaded(entries, _) = status, entries.indices.contains(index), entries[index].isDir
        else { return }
        tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        selectedIndex = index
    }

    func doubleClickForTesting(at index: Int) {
        tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        // `NSTableView.clickedRow` is only ever set by a real click; the test
        // seam drives the same handler `rowDoubleClicked` calls instead of
        // trying to fabricate one.
        guard case let .loaded(entries, _) = status, entries.indices.contains(index), entries[index].isDir
        else { return }
        onNavigate?((currentPath as NSString).appendingPathComponent(entries[index].name))
    }

    var numberOfRowsForTesting: Int { tableView.numberOfRows }
    var cardFrameForTesting: NSRect { cardFrame }
    var currentPathForTesting: String { currentPath }
    var isTruncatedLabelHiddenForTesting: Bool { truncatedLabel.isHidden }
    var isUpButtonEnabledForTesting: Bool { upButton.isEnabled }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int {
        switch status {
        case .loading, .failed: return 1
        case let .loaded(entries, _): return entries.isEmpty ? 1 : entries.count
        }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        guard case let .loaded(entries, _) = status, entries.indices.contains(row) else { return false }
        return entries[row].isDir
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        guard case let .loaded(entries, _) = status, entries.indices.contains(row) else {
            selectedIndex = nil
            return
        }
        selectedIndex = row
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch status {
        case .loading: return RemoteFolderBrowserRowView(placeholder: "Loading…")
        case let .failed(message): return RemoteFolderBrowserRowView(placeholder: message)
        case let .loaded(entries, _):
            guard !entries.isEmpty else {
                return RemoteFolderBrowserRowView(placeholder: "This folder is empty")
            }
            return RemoteFolderBrowserRowView(entry: entries[row])
        }
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        scrim?.frame = bounds
        let padding = Self.padding
        let width = min(Self.cardWidth, max(260, bounds.width - 48))
        let content = width - padding * 2
        let titleHeight = Self.height(of: titleLabel, width: content)
        let messageHeight = Self.height(of: messageLabel, width: content)
        let listHeight = min(
            Self.maxListHeight,
            max(Self.rowHeight, CGFloat(numberOfRows(in: tableView)) * Self.rowHeight) + 8
        )
        let truncatedHeight: CGFloat = truncatedLabel.isHidden ? 0 : 18
        let height = padding + Self.iconSize + 12 + titleHeight + 6 + messageHeight
            + 14 + Self.pathBarHeight + 8 + listHeight + truncatedHeight + 16 + Self.buttonHeight + padding
        cardFrame = NSRect(
            x: ((bounds.width - width) / 2).rounded(),
            y: max(0, (bounds.height - height) / 2).rounded(),
            width: width,
            height: height
        )
        cardGlass?.frame = cardFrame
        cardTint.frame = cardFrame
        cardTintLayer.frame = cardTint.bounds

        var y = cardFrame.minY + padding
        iconView.frame = NSRect(x: cardFrame.midX - Self.iconSize / 2, y: y, width: Self.iconSize, height: Self.iconSize)
        y += Self.iconSize + 12
        titleLabel.frame = NSRect(x: cardFrame.minX + padding, y: y, width: content, height: titleHeight)
        y += titleHeight + 6
        messageLabel.frame = NSRect(x: cardFrame.minX + padding, y: y, width: content, height: messageHeight)
        y += messageHeight + 14

        pathBar.frame = NSRect(x: cardFrame.minX + padding, y: y, width: content, height: Self.pathBarHeight)
        upButton.frame = NSRect(x: 0, y: (Self.pathBarHeight - 22) / 2, width: 24, height: 22)
        pathLabel.frame = NSRect(
            x: 30, y: (Self.pathBarHeight - 18) / 2, width: max(0, content - 30), height: 18
        )
        y += Self.pathBarHeight + 8

        listWell.frame = NSRect(x: cardFrame.minX + padding, y: y, width: content, height: listHeight)
        scrollView.frame = listWell.bounds
        y += listHeight
        if !truncatedLabel.isHidden {
            truncatedLabel.frame = NSRect(x: cardFrame.minX + padding, y: y, width: content, height: truncatedHeight)
        }
        y += truncatedHeight + 16

        let gap: CGFloat = 9
        let widths = buttons.map { $0.intrinsicContentSize.width }
        let total = widths.reduce(0, +) + gap * CGFloat(max(0, buttons.count - 1))
        var x = cardFrame.midX - total / 2
        for (button, buttonWidth) in zip(buttons, widths) {
            button.frame = NSRect(x: x, y: y, width: buttonWidth, height: Self.buttonHeight)
            x += buttonWidth + gap
        }
    }

    private static func height(of field: NSTextField, width: CGFloat) -> CGFloat {
        let font = field.font ?? ShellFont.ui(13)
        let rect = (field.stringValue as NSString).boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        )
        return ceil(rect.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard scrim == nil else { return }
        NSColor(white: 0, alpha: 0.62).setFill()
        bounds.fill()
        NSColor(srgbRed: 0.09, green: 0.12, blue: 0.26, alpha: 1).setFill()
        NSBezierPath(roundedRect: cardFrame, xRadius: Self.cardRadius, yRadius: Self.cardRadius).fill()
        NSColor(white: 1, alpha: 0.16).setStroke()
        let ring = NSBezierPath(
            roundedRect: cardFrame.insetBy(dx: 0.5, dy: 0.5),
            xRadius: Self.cardRadius,
            yRadius: Self.cardRadius
        )
        ring.lineWidth = 1
        ring.stroke()
    }
}

/// Return and Escape inside the list — without this they are the table's own
/// business, exactly `RemoteSessionPickerView`'s `PickerTableView`.
private final class FolderBrowserTableView: NSTableView {
    var onReturn: (() -> Void)?
    var onEscape: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: onReturn?()
        case 53: onEscape?()
        default: super.keyDown(with: event)
        }
    }
}

/// One row: a folder or document glyph, the name, and — for a file, which
/// can never be selected — a dimmer tint that reads as "here for context
/// only". A placeholder (loading/error/empty) is centred text with no icon.
final class RemoteFolderBrowserRowView: NSTableCellView {
    init(entry: DirectoryEntry) {
        super.init(frame: .zero)
        let icon = NSImageView()
        icon.image = NSImage(
            systemSymbolName: entry.isDir ? "folder.fill" : "doc",
            accessibilityDescription: nil
        )?.withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        icon.contentTintColor = NSColor(white: 1, alpha: entry.isDir ? 0.85 : 0.35)
        addSubview(icon)

        let title = NSTextField(labelWithString: entry.name)
        title.font = ShellFont.ui(13, entry.isDir ? .medium : .regular)
        title.textColor = NSColor(white: 1, alpha: entry.isDir ? 0.95 : 0.4)
        title.lineBreakMode = .byTruncatingMiddle
        addSubview(title)
        textField = title

        setAccessibilityElement(true)
        setAccessibilityLabel(entry.isDir ? "\(entry.name), folder" : "\(entry.name), file, not selectable")

        [icon, title].forEach { $0.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 9),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            title.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
        ])
    }

    init(placeholder message: String) {
        super.init(frame: .zero)
        let title = NSTextField(labelWithString: message)
        title.font = ShellFont.ui(12.5)
        title.textColor = NSColor(white: 1, alpha: 0.5)
        title.alignment = .center
        title.lineBreakMode = .byWordWrapping
        title.maximumNumberOfLines = 2
        addSubview(title)
        textField = title

        setAccessibilityElement(true)
        setAccessibilityLabel(message)

        title.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            title.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }
}

/// Mounts the sheet over the workspace window and takes it down again, and
/// owns the one thing the view itself never does: talking to the daemon.
/// `RemoteSessionPickerController`'s pattern exactly, plus the async round
/// trip a folder browse needs that a pre-built row list does not.
final class RemoteFolderBrowserController {
    private(set) var view: RemoteFolderBrowserView?
    private var browser: RemoteFolderBrowser?
    /// Bumped on every `load`, so a reply for a path the sheet has since
    /// navigated away from (double-click into `b` right after double-
    /// clicking into `a`, before `a`'s reply lands) is dropped rather than
    /// clobbering what the user is now looking at.
    private var requestToken = 0

    /// Returns whether the sheet actually went up: `false` when one is
    /// already showing, or the window has no content view yet.
    @discardableResult
    func present(
        over window: NSWindow?,
        browser: RemoteFolderBrowser,
        machineName: String?,
        startingAt path: String,
        onAdd: @escaping (String) -> Void
    ) -> Bool {
        guard view == nil, let content = window?.contentView else { return false }
        self.browser = browser
        let sheet = RemoteFolderBrowserView(machineName: machineName, startingAt: path)
        sheet.onNavigate = { [weak self] newPath in self?.load(newPath) }
        sheet.onAdd = { [weak self] chosen in
            self?.dismiss()
            onAdd(chosen)
        }
        sheet.onCancel = { [weak self] in self?.dismiss() }
        sheet.frame = content.bounds
        sheet.autoresizingMask = [.width, .height]
        content.addSubview(sheet, positioned: .above, relativeTo: nil)
        view = sheet
        window?.makeFirstResponder(sheet.firstResponderView)
        load(path)
        return true
    }

    private func load(_ path: String) {
        requestToken += 1
        let token = requestToken
        view?.beginLoading(path: path)
        Task { @MainActor [weak self] in
            guard let self, let browser = self.browser else { return }
            do {
                let entries = try await browser.list(path)
                guard self.requestToken == token else { return }
                self.view?.apply(path: path, entries: entries, truncated: browser.truncated)
            } catch {
                guard self.requestToken == token else { return }
                self.view?.applyFailure(path: path, message: error.localizedDescription)
            }
        }
    }

    func dismiss() {
        view?.removeFromSuperview()
        view = nil
        browser = nil
    }
}
