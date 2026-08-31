import AppKit

/// # Resume remote session
///
/// The picker behind "+ → Resume remote session…" — the remote-session-control
/// phase 2 spec's §4 ("The + menu picker",
/// docs/superpowers/specs/2026-08-31-remote-session-control-phase-2-design.md).
///
/// Phase 1 shipped that menu item as "open the spotlight, pre-filtered to
/// `remote`", which is a fast path for someone who already knows what is
/// there and a shrug for someone who does not. Bruno's words after the first
/// two-Mac session: *"It was expected to the user click on + and then resume
/// remote connection and choose from a list of the possible remote
/// connections."* This is that list. The spotlight rows stay exactly as they
/// were — they are the keyboard path, this is the discoverable one.
///
/// The rows are a pure function of the relay's machine list
/// (`RemoteSessionPickerModel.rows`) so that what the picker offers can be
/// asserted without a window; `RemoteSessionPickerView` is the glass and the
/// keyboard, and `RemoteSessionPickerController` is the mount point.
struct RemoteSessionPickerModel: Equatable {
    /// One line of the list. Headings and empty states are rows too — they
    /// are what makes the list a *tree* rather than a flat pile of session
    /// names, and keeping them in the same array is what lets the view skip
    /// them for selection in one place instead of three.
    enum Row: Equatable {
        /// A machine section heading.
        case machine(deviceID: String, name: String)
        /// One of that machine's shared workspaces.
        case workspace(name: String)
        /// A terminal pane on that machine — the only openable row. `paneID`
        /// is a *pane* id: the only id a viewer may `Attach` with, and what
        /// `WorkspaceWindowController.openRemoteSession` looks up inside its
        /// session.
        case session(deviceID: String, paneID: String, label: String, detail: String)
        /// Why there is nothing here, in plain words.
        case empty(message: String)
    }

    /// The host's tree, per machine, in the host's order — the same
    /// projection §2 defines and the sidebar renders, so the picker and the
    /// sidebar cannot disagree about what is on the other Mac.
    ///
    /// Nothing is re-sorted here. `order` is the host's answer, and deriving
    /// a second ordering on this side is exactly the drift schema v2 exists
    /// to prevent. `machines` arrives from `RemoteMachinesModel` already
    /// sorted by name, which is the only ordering this side owns.
    static func rows(machines: [RemoteMachine], signedIn: Bool) -> [Row] {
        // Signed out is not "nothing shared" — the relay has not been asked
        // yet. Saying so is the difference between "wait a moment" and "give
        // up".
        guard signedIn else { return [.empty(message: "Signing in…")] }
        guard !machines.isEmpty else {
            return [.empty(message: "No other Macs are sharing sessions")]
        }

        var rows: [Row] = []
        for machine in machines {
            rows.append(.machine(deviceID: machine.deviceID, name: machine.name))
            let workspaces = machine.projection.workspaces.sorted { $0.order < $1.order }
            // A projection with no workspace at all means the tunnel is down:
            // the daemon holds its control channel open *iff* the row lists
            // ≥ 1 workspace (`remote_control_active`), so a machine still on
            // the relay's list with an empty projection is one that has just
            // stopped sharing, or is on its way off the list. "Offline" is
            // what a user can act on; a blank section is not.
            guard !workspaces.isEmpty else {
                rows.append(.empty(message: "\(machine.name) is offline"))
                continue
            }
            for workspace in workspaces {
                rows.append(.workspace(name: workspace.name))
                let sessions = workspace.sessions.sorted { $0.order < $1.order }
                var offered = 0
                for session in sessions {
                    for pane in session.panes.sorted(by: { $0.order < $1.order })
                    where pane.kind == PaneKind.terminal.rawValue {
                        // Only a terminal pane is attachable (spec §2); an
                        // editor or browser pane is carried by the projection
                        // for structural fidelity and is not openable here.
                        offered += 1
                        rows.append(
                            .session(
                                deviceID: machine.deviceID,
                                paneID: pane.id,
                                label: pane.title,
                                detail: detail(for: pane, in: session.label)
                            )
                        )
                    }
                }
                // Shared but idle: listed, because it *is* the host's tree and
                // dropping it would leave a user wondering where the workspace
                // they just enabled went.
                if offered == 0 {
                    rows.append(.empty(message: "Nothing is running in \(workspace.name)"))
                }
            }
        }
        return rows
    }

    /// The right-hand line: which session this pane belongs to, and what is
    /// running in it. A one-pane session whose pane is named after it — the
    /// common case — would otherwise print its own name twice, so the session
    /// half is dropped when it adds nothing.
    private static func detail(for pane: RemoteControlProjection.Pane, in sessionLabel: String) -> String {
        let engine = Engine(rawValue: pane.engine)?.displayName ?? pane.engine
        return pane.title == sessionLabel ? engine : "\(sessionLabel) · \(engine)"
    }
}

/// The picker's glass sheet: the house modal standard (`PaneAskOverlayView`),
/// built from the same two panels and the same navy wash, with a list where
/// the ask has a message and buttons.
///
/// Deliberately not an `NSAlert` and not an `NSTableView` in a plain panel —
/// every modal question in this app wears this glass, and "which of these
/// sessions do you want?" is a modal question. What is behind the glass is
/// this Mac's Desk, which is exactly the context for "open one of the other
/// Mac's sessions here".
final class RemoteSessionPickerView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    /// The chosen session: device id, pane id, and the label the pane should
    /// carry until the host says otherwise.
    var onOpen: ((String, String, String) -> Void)?
    /// Escape, a click on the glass, or Cancel.
    var onCancel: (() -> Void)?

    let rows: [RemoteSessionPickerModel.Row]
    /// The indexes of `rows` a user can actually open, in list order.
    let openableRowIndexes: [Int]

    private static let cardWidth: CGFloat = 460
    private static let padding: CGFloat = 22
    private static let iconSize: CGFloat = 30
    private static let buttonHeight: CGFloat = 26
    private static let cardRadius: CGFloat = 16
    private static let sessionRowHeight: CGFloat = 46
    /// Taller than the workspace heading under it: it is what separates one
    /// machine's section from the sessions of the machine above.
    private static let machineRowHeight: CGFloat = 34
    private static let workspaceRowHeight: CGFloat = 24
    private static let emptyRowHeight: CGFloat = 38
    /// Enough for roughly six sessions; past that the list scrolls rather
    /// than the card growing taller than the window it sits in.
    private static let maxListHeight: CGFloat = 286

    private let scrim: NSView?
    private let cardGlass: NSView?
    private let cardTint = NSView()
    private let cardTintLayer = CAGradientLayer()
    /// `PaneAskOverlayView`'s navy, copied for the same reason it copies
    /// Spotlight's: two colours are not worth tying two overlays together.
    private static let navyTint = [
        NSColor(srgbRed: 0.11, green: 0.16, blue: 0.38, alpha: 0.40).cgColor,
        NSColor(srgbRed: 0.05, green: 0.08, blue: 0.22, alpha: 0.14).cgColor,
    ]

    private let iconView = NSImageView()
    private let titleLabel: NSTextField
    private let messageLabel: NSTextField
    private let listWell = NSView()
    private let scrollView = NSScrollView()
    private let tableView = PickerTableView()
    private let buttons: [PaneApprovalButton]
    private var cardFrame: NSRect = .zero
    /// One answer per sheet, whichever route it arrives by — Return, a
    /// double-click, a button, Escape, a click on the glass.
    private var isAnswered = false

    init(rows: [RemoteSessionPickerModel.Row]) {
        self.rows = rows
        openableRowIndexes = rows.indices.filter {
            if case .session = rows[$0] { return true }
            return false
        }
        titleLabel = Self.label(
            "Resume remote session",
            font: ShellFont.ui(15, .semibold),
            color: NSColor(srgbRed: 240 / 255, green: 240 / 255, blue: 244 / 255, alpha: 1)
        )
        messageLabel = Self.label(
            openableRowIndexes.isEmpty
                ? "Sessions shared by your other Macs show up here."
                : "Pick a session running on one of your other Macs.",
            font: ShellFont.ui(13),
            color: NSColor(srgbRed: 176 / 255, green: 180 / 255, blue: 198 / 255, alpha: 1)
        )
        // Nothing to open, nothing to choose between: one button that closes,
        // rather than a dead "Open" beside it.
        buttons = (openableRowIndexes.isEmpty ? [("Close", true)] : [("Cancel", false), ("Open", true)])
            .map { PaneApprovalButton(title: $0.0, isPrimary: $0.1, tint: PaneAskOverlayView.accent) }
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

        iconView.image = NSImage(
            systemSymbolName: "desktopcomputer.and.arrow.down",
            accessibilityDescription: nil
        )?.withSymbolConfiguration(.init(pointSize: 22, weight: .regular))
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

        listWell.wantsLayer = true
        listWell.layer?.backgroundColor = NSColor(white: 1, alpha: 0.06).cgColor
        listWell.layer?.cornerRadius = 10
        listWell.layer?.cornerCurve = .continuous
        listWell.layer?.borderWidth = 1
        listWell.layer?.borderColor = NSColor(white: 1, alpha: 0.12).cgColor
        listWell.layer?.masksToBounds = true

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("remote-session"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = Self.sessionRowHeight
        // Spotlight's inset pill rather than a full-bleed band — this is the
        // same kind of list and it should not look like a different app.
        tableView.style = .inset
        tableView.backgroundColor = .clear
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.allowsEmptySelection = true
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(rowDoubleClicked)
        tableView.setAccessibilityLabel("Remote sessions")
        tableView.onReturn = { [weak self] in self?.activateSelection() }
        tableView.onEscape = { [weak self] in self?.cancel() }

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.automaticallyAdjustsContentInsets = false
        listWell.addSubview(scrollView)

        // The primary button is Open on a list with something in it and Close
        // on one without — the same two paths Return takes. `isPrimary` is
        // read here rather than inside the closure so the button does not
        // capture itself.
        for button in buttons {
            let opens = button.isPrimary && !openableRowIndexes.isEmpty
            button.onClick = { [weak self] in
                if opens { self?.activateSelection() } else { self?.cancel() }
            }
        }

        for view in [scrim, cardGlass].compactMap({ $0 })
            + [cardTint, iconView, titleLabel, messageLabel, listWell]
            + (buttons as [NSView])
        {
            addSubview(view)
        }

        // Return alone opens something: a picker that needs an arrow key
        // first needs two keystrokes to do its one job.
        if let first = openableRowIndexes.first {
            tableView.selectRowIndexes(IndexSet(integer: first), byExtendingSelection: false)
        }

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Resume remote session")
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

    /// The sheet takes the keyboard while it is up. The table holds it when
    /// there is something to arrow between; the view itself when there is
    /// not, so Escape and Return still land.
    var firstResponderView: NSView { openableRowIndexes.isEmpty ? self : tableView }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: activateSelection() // Return, Enter
        case 53: cancel() // Esc
        default: NSSound.beep()
        }
    }

    /// A click on the glass is a cancel; inside the card it is swallowed.
    override func mouseDown(with event: NSEvent) {
        guard !cardFrame.contains(convert(event.locationInWindow, from: nil)) else { return }
        cancel()
    }

    // MARK: - Answering

    /// Opens whatever is selected — the one path Return, a double-click and
    /// the Open button share. A list with nothing openable in it closes
    /// instead of beeping: there is no answer to give.
    func activateSelection() {
        guard !isAnswered else { return }
        guard
            case let .session(deviceID, paneID, label, _)? = selectedRow()
        else { return cancel() }
        isAnswered = true
        onOpen?(deviceID, paneID, label)
    }

    /// Escape, the glass, Cancel, Close.
    func cancel() {
        guard !isAnswered else { return }
        isAnswered = true
        onCancel?()
    }

    /// Selects the *n*-th openable row — the production path is the table's
    /// own arrow keys, which a test has no window focus to drive.
    func selectOpenableRow(at index: Int) {
        guard openableRowIndexes.indices.contains(index) else { return }
        tableView.selectRowIndexes(
            IndexSet(integer: openableRowIndexes[index]),
            byExtendingSelection: false
        )
    }

    /// Whether row `index` is one a user can land on — a heading and an
    /// empty state are not.
    func canSelectRow(_ index: Int) -> Bool { openableRowIndexes.contains(index) }

    var numberOfRowsForTesting: Int { rows.count }

    /// Where the card ended up, for the layout test — a modal that goes up
    /// as a zero-sized or off-window card is the one failure no assertion
    /// about rows would catch.
    var cardFrameForTesting: NSRect { cardFrame }

    private func selectedRow() -> RemoteSessionPickerModel.Row? {
        let selected = tableView.selectedRow
        guard rows.indices.contains(selected) else { return nil }
        return rows[selected]
    }

    @objc private func rowDoubleClicked() {
        guard tableView.clickedRow >= 0 else { return }
        activateSelection()
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch rows[row] {
        case .machine: return Self.machineRowHeight
        case .workspace: return Self.workspaceRowHeight
        case .session: return Self.sessionRowHeight
        case .empty: return Self.emptyRowHeight
        }
    }

    /// Headings and empty states are not answers, so arrow keys pass over
    /// them and a click on one selects nothing.
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        canSelectRow(row)
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        RemoteSessionPickerRowView(row: rows[row])
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        scrim?.frame = bounds
        let padding = Self.padding
        let width = min(Self.cardWidth, max(240, bounds.width - 48))
        let content = width - padding * 2
        let titleHeight = Self.height(of: titleLabel, width: content)
        let messageHeight = Self.height(of: messageLabel, width: content)
        let listHeight = min(
            Self.maxListHeight,
            max(Self.emptyRowHeight, rows.indices.reduce(0) { $0 + self.tableView(tableView, heightOfRow: $1) })
                // `.inset` style keeps a little air above and below its pills;
                // without it the last row is clipped by a hairline.
                + 8
        )
        let height = padding + Self.iconSize + 12 + titleHeight + 8 + messageHeight
            + 16 + listHeight + 16 + Self.buttonHeight + padding
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
        iconView.frame = NSRect(
            x: cardFrame.midX - Self.iconSize / 2,
            y: y,
            width: Self.iconSize,
            height: Self.iconSize
        )
        y += Self.iconSize + 12
        titleLabel.frame = NSRect(x: cardFrame.minX + padding, y: y, width: content, height: titleHeight)
        y += titleHeight + 8
        messageLabel.frame = NSRect(x: cardFrame.minX + padding, y: y, width: content, height: messageHeight)
        y += messageHeight + 16
        listWell.frame = NSRect(x: cardFrame.minX + padding, y: y, width: content, height: listHeight)
        scrollView.frame = listWell.bounds
        y += listHeight + 16

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
        // Only before macOS 26, where there is no glass to ask for —
        // `PaneAskOverlayView`'s reasoning exactly.
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

/// Return and Escape inside the list. Without this they are the table's
/// business — Return does nothing at all, and Escape unwinds nothing.
private final class PickerTableView: NSTableView {
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

/// One line of the picker. Deliberately the spotlight's row shape for the
/// openable rows (`PaletteRowView`) — plate, title, detail — so the two lists
/// of the same things look like the same app.
final class RemoteSessionPickerRowView: NSTableCellView {
    init(row: RemoteSessionPickerModel.Row) {
        super.init(frame: .zero)
        switch row {
        case let .machine(_, name):
            build(heading: name, symbol: "desktopcomputer.and.arrow.down", indent: 0, alpha: 0.78)
        case let .workspace(name):
            build(heading: name, symbol: "folder", indent: 14, alpha: 0.55)
        case let .session(_, _, label, detail):
            build(title: label, detail: detail)
        case let .empty(message):
            build(empty: message)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    private func build(heading: String, symbol: String, indent: CGFloat, alpha: CGFloat) {
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10.5, weight: .semibold))
        icon.contentTintColor = NSColor(white: 1, alpha: alpha)
        addSubview(icon)

        let title = NSTextField(labelWithString: heading)
        title.font = ShellFont.ui(11.5, .semibold)
        title.textColor = NSColor(white: 1, alpha: alpha)
        title.lineBreakMode = .byTruncatingMiddle
        addSubview(title)
        textField = title

        setAccessibilityElement(true)
        setAccessibilityLabel(heading)

        [icon, title].forEach { $0.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12 + indent),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 7),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            title.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
        ])
    }

    private func build(title text: String, detail: String) {
        let plate = NSView()
        plate.wantsLayer = true
        plate.layer?.cornerRadius = 8
        plate.layer?.cornerCurve = .continuous
        plate.layer?.backgroundColor = NSColor(white: 1, alpha: 0.10).cgColor
        addSubview(plate)

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
        icon.contentTintColor = NSColor(white: 1, alpha: 0.85)
        plate.addSubview(icon)

        let title = NSTextField(labelWithString: text)
        title.font = ShellFont.ui(13.5, .medium)
        title.textColor = NSColor(white: 1, alpha: 0.97)
        title.lineBreakMode = .byTruncatingTail
        addSubview(title)
        textField = title

        let subtitle = NSTextField(labelWithString: detail)
        subtitle.font = ShellFont.ui(11.5)
        subtitle.textColor = NSColor(white: 1, alpha: 0.5)
        subtitle.lineBreakMode = .byTruncatingMiddle
        addSubview(subtitle)

        setAccessibilityElement(true)
        setAccessibilityLabel([text, detail].filter { !$0.isEmpty }.joined(separator: ", "))

        [plate, icon, title, subtitle].forEach { $0.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            plate.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 26),
            plate.centerYAnchor.constraint(equalTo: centerYAnchor),
            plate.widthAnchor.constraint(equalToConstant: 28),
            plate.heightAnchor.constraint(equalToConstant: 28),
            icon.centerXAnchor.constraint(equalTo: plate.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: plate.centerYAnchor),

            title.leadingAnchor.constraint(equalTo: plate.trailingAnchor, constant: 11),
            title.topAnchor.constraint(equalTo: plate.topAnchor, constant: -2),
            title.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 1),
            subtitle.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
        ])
    }

    private func build(empty message: String) {
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
}

/// Mounts the picker over the workspace window and takes it down again —
/// `WorkspaceWindowController.presentWindowAsk`'s pattern, minus the
/// deminiaturize-and-activate dance: an ask can be raised by a background
/// event, while this only ever opens from a menu in the window that is
/// already in front.
final class RemoteSessionPickerController {
    /// The sheet while one is up, `nil` otherwise — one at a time.
    private(set) var view: RemoteSessionPickerView?

    /// Returns whether the sheet actually went up: `false` when one is
    /// already showing, or the window has no content view yet. A caller that
    /// must do *something* (the menu item) can then fall back rather than
    /// appearing to have been ignored.
    @discardableResult
    func present(
        over window: NSWindow?,
        rows: [RemoteSessionPickerModel.Row],
        onOpen: @escaping (String, String, String) -> Void
    ) -> Bool {
        guard view == nil, let content = window?.contentView else { return false }
        let sheet = RemoteSessionPickerView(rows: rows)
        sheet.onOpen = { [weak self] deviceID, paneID, title in
            // Down first, so the pane the caller opens gets the keyboard.
            self?.dismiss()
            onOpen(deviceID, paneID, title)
        }
        sheet.onCancel = { [weak self] in self?.dismiss() }
        sheet.frame = content.bounds
        sheet.autoresizingMask = [.width, .height]
        content.addSubview(sheet, positioned: .above, relativeTo: nil)
        view = sheet
        window?.makeFirstResponder(sheet.firstResponderView)
        return true
    }

    func dismiss() {
        view?.removeFromSuperview()
        view = nil
    }
}
