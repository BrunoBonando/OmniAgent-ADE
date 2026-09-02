import AppKit

/// The dropdown behind every Home composer chip (engine, model, project,
/// session, branch) — a search field integrated into the first row, then
/// icon-and-title rows with a checkmark on the current choice and a hover
/// fill in the app's own palette, wrapped in `NSPopover` rather than a stock
/// `NSMenu`. `NSPopover` supplies the anchoring, the arrow and the click-away
/// dismissal for free (ladder rung 3: the platform already does this); only
/// the content is custom, which is what makes it read as this app instead of
/// system chrome.
enum HomeDropdown {
    struct Row {
        let icon: NSImage?
        let title: String
        let isCurrent: Bool
        let isEnabled: Bool
        let action: () -> Void

        init(
            icon: NSImage? = nil,
            title: String,
            isCurrent: Bool = false,
            isEnabled: Bool = true,
            action: @escaping () -> Void
        ) {
            self.icon = icon
            self.title = title
            self.isCurrent = isCurrent
            self.isEnabled = isEnabled
            self.action = action
        }
    }

    struct Section {
        let header: String?
        let rows: [Row]

        init(header: String? = nil, rows: [Row]) {
            self.header = header
            self.rows = rows
        }
    }

    /// An SF Symbol at the size every row icon shares — every row wears
    /// one, so the titles line up and nothing reads as a missing image.
    static func symbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
    }

    /// One `NSPopover` retained for as long as it is on screen — otherwise
    /// nothing would hold it alive between `show` returning and a row being
    /// pressed.
    private static var current: NSPopover?

    /// Presents below `anchor` and returns the content view, so a caller
    /// whose rows arrive later (a model list fetched off the main thread)
    /// can swap them in via `sections` without re-presenting.
    @discardableResult
    static func show(
        _ sections: [Section],
        searchPlaceholder: String,
        from anchor: NSView,
        preferredEdge: NSRectEdge = .minY,
        /// Where in `anchor` the popover hangs off, given the menu's own
        /// size — for a caller that wants it bottom- or top-aligned rather
        /// than centred on the anchor. `nil`: the anchor's bounds.
        positioning: ((NSSize) -> NSRect)? = nil
    ) -> HomeDropdownView {
        let content = present(from: anchor, preferredEdge: preferredEdge, positioning: positioning) { dismiss -> HomeDropdownView in
            let view = HomeDropdownView(searchPlaceholder: searchPlaceholder, dismiss: dismiss)
            view.sections = sections
            return view
        }
        content.focusSearch()
        return content
    }

    /// The popover alone, for content that is not the rows-and-search
    /// dropdown — the account menu. `make` is handed the closure that closes
    /// the popover, so the content can dismiss on a press the way the rows
    /// do; it runs before the popover is shown, so what it returns is what
    /// the popover is sized to.
    @discardableResult
    static func present<Content: NSView>(
        from anchor: NSView,
        preferredEdge: NSRectEdge = .minY,
        positioning: ((NSSize) -> NSRect)? = nil,
        make: (_ dismiss: @escaping () -> Void) -> Content
    ) -> Content {
        current?.performClose(nil)
        let popover = NSPopover()
        current = popover
        let content = make { [weak popover] in popover?.performClose(nil) }
        let controller = NSViewController()
        controller.view = content
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.animates = true
        // Dark vibrancy on the popover's own native rounded shape — the
        // same "glass, not flat chrome" call `WorkspaceGlass`/
        // `PaneAskOverlayView` make elsewhere, minus a bespoke panel: a
        // popover's built-in material already reads as this app's dark
        // surface, arrow included.
        popover.appearance = NSAppearance(named: .vibrantDark)
        // `.minY` is the anchor's *bottom* edge — these chips are plain,
        // unflipped `NSView`s — which is what puts the dropdown under the
        // chip rather than over it.
        let rect = positioning?(content.fittingSize) ?? anchor.bounds
        popover.show(relativeTo: rect, of: anchor, preferredEdge: preferredEdge)
        return content
    }
}

/// The popover's content: the search row, a hairline, then the sections.
/// Typing filters rows by title; `extraRows` lets a caller append rows that
/// depend on the query itself (the branch picker's "Create ‘…’ from main").
final class HomeDropdownView: NSView, NSTextFieldDelegate {
    var sections: [HomeDropdown.Section] = [] {
        didSet { rebuild() }
    }

    /// Rows appended under the sections whenever the query is non-empty —
    /// called on every keystroke with the current text. Not filtered: the
    /// caller decides what the query means.
    var extraRows: ((String) -> [HomeDropdown.Row])? {
        didSet { rebuild() }
    }

    /// Test seam: the rows on screen right now, in order, after filtering.
    var visibleTitlesForTesting: [String] {
        rowViews.filter { !$0.isHidden }.map(\.title)
    }

    /// The same for the section headings, which carry text of their own — an
    /// account popover's heading *is* the account's name, so whether it is on
    /// screen is a fact worth asserting.
    var visibleHeadersForTesting: [String] {
        headerViews.filter { !$0.view.isHidden }.map(\.title)
    }

    private let search = NSTextField()
    private let list = NSStackView()
    private var rowViews: [HomeDropdownRowView] = []
    private var headerViews: [(view: NSView, title: String, rows: [HomeDropdownRowView])] = []
    private let dismiss: () -> Void

    init(searchPlaceholder: String, dismiss: @escaping () -> Void) {
        self.dismiss = dismiss
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        // The search row: a bare field, no bezel, no focus ring — it is
        // *part of the dropdown*, not a control sitting in it. Return picks
        // the first visible row, so typing-then-Enter never needs the mouse.
        search.isBordered = false
        search.isBezeled = false
        search.drawsBackground = false
        search.focusRingType = .none
        search.font = ShellFont.ui(13)
        search.textColor = ShellPalette.ink
        search.placeholderAttributedString = NSAttributedString(
            string: searchPlaceholder,
            attributes: [.foregroundColor: ShellPalette.inkMuted, .font: ShellFont.ui(13)]
        )
        search.delegate = self
        search.target = self
        search.action = #selector(pickFirstVisible)
        search.translatesAutoresizingMaskIntoConstraints = false

        let rule = ShellSeparator()

        list.orientation = .vertical
        list.spacing = 1
        list.translatesAutoresizingMaskIntoConstraints = false

        addSubview(search)
        addSubview(rule)
        addSubview(list)
        NSLayoutConstraint.activate([
            search.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            search.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            search.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            rule.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 12),
            rule.leadingAnchor.constraint(equalTo: leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: trailingAnchor),
            list.topAnchor.constraint(equalTo: rule.bottomAnchor, constant: 6),
            list.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            list.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            list.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 260),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func focusSearch() {
        window?.makeFirstResponder(search)
    }

    /// Test seam: the same path a keystroke takes.
    func setQueryForTesting(_ query: String) {
        search.stringValue = query
        applyFilter()
    }

    /// Test seam: what Return in the search field does.
    func pressFirstVisibleForTesting() { pickFirstVisible() }

    func controlTextDidChange(_ obj: Notification) {
        applyFilter()
    }

    @objc private func pickFirstVisible() {
        rowViews.first { !$0.isHidden && $0.onPress != nil }?.onPress?()
    }

    private func rebuild() {
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        rowViews = []
        headerViews = []
        for (index, section) in sections.enumerated() {
            var sectionRows: [HomeDropdownRowView] = []
            var header: NSView?
            if let title = section.header {
                let label = ShellFont.label(title.uppercased(), font: ShellFont.ui(10, .bold), color: ShellPalette.inkFaint)
                let wrap = NSView()
                wrap.translatesAutoresizingMaskIntoConstraints = false
                wrap.addSubview(label)
                NSLayoutConstraint.activate([
                    label.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: 10),
                    label.trailingAnchor.constraint(lessThanOrEqualTo: wrap.trailingAnchor, constant: -12),
                    label.topAnchor.constraint(equalTo: wrap.topAnchor, constant: index == 0 ? 4 : 10),
                    label.bottomAnchor.constraint(equalTo: wrap.bottomAnchor, constant: -4),
                ])
                list.addArrangedSubview(wrap)
                wrap.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
                header = wrap
            }
            for row in section.rows {
                let view = makeRow(row)
                sectionRows.append(view)
            }
            if let header, let title = section.header {
                headerViews.append((header, title, sectionRows))
            }
        }
        applyFilter()
    }

    private func makeRow(_ row: HomeDropdown.Row) -> HomeDropdownRowView {
        let view = HomeDropdownRowView(icon: row.icon, title: row.title, isCurrent: row.isCurrent, isEnabled: row.isEnabled)
        if row.isEnabled {
            view.onPress = { [dismiss] in
                row.action()
                dismiss()
            }
        }
        list.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
        rowViews.append(view)
        return view
    }

    private var extraRowViews: [HomeDropdownRowView] = []

    private func applyFilter() {
        let query = search.stringValue.trimmingCharacters(in: .whitespaces)
        for view in rowViews where !extraRowViews.contains(where: { $0 === view }) {
            view.isHidden = !query.isEmpty && !view.title.localizedCaseInsensitiveContains(query)
        }
        // A header whose rows the query all filtered out goes with them — a
        // heading over nothing reads as a bug. A section that *never had* rows
        // is not that case: its heading is the content (the account popover's
        // heading is the account's name), so `allSatisfy` on an empty array
        // must not be allowed to vacuously hide it.
        for (header, _, rows) in headerViews {
            header.isHidden = !rows.isEmpty && rows.allSatisfy(\.isHidden)
        }
        // The query-dependent rows are rebuilt from scratch each keystroke;
        // they are few and their content is what changed.
        extraRowViews.forEach { $0.removeFromSuperview() }
        rowViews.removeAll { view in extraRowViews.contains { $0 === view } }
        extraRowViews = []
        if !query.isEmpty, let extra = extraRows?(query) {
            extraRowViews = extra.map(makeRow)
        }
    }
}

/// One row: an icon, a title, and — on the current row only — a checkmark
/// at the trailing edge, so every title starts at the same left edge with
/// no reserved column in front of it. Built on
/// `ShellRowView` for its hover tracking rather than reimplementing
/// mouse-entered/exited handling. Icons are never dimmed — a greyed-out
/// title says "unavailable" on its own; a washed-out brand mark just looks
/// broken.
final class HomeDropdownRowView: ShellRowView {
    let title: String

    init(icon: NSImage?, title: String, isCurrent: Bool, isEnabled: Bool) {
        self.title = title
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.cornerCurve = .continuous
        hoverFill = ShellPalette.hover
        hoverEnabled = isEnabled

        var views: [NSView] = []
        if let icon {
            let imageView = NSImageView()
            imageView.image = icon
            imageView.imageScaling = .scaleProportionallyDown
            // Template art (Shell, Copilot, SF Symbols) needs a tint or it
            // renders black on this ground; brand marks ignore it.
            imageView.contentTintColor = ShellPalette.ink
            imageView.translatesAutoresizingMaskIntoConstraints = false
            imageView.widthAnchor.constraint(equalToConstant: 18).isActive = true
            imageView.heightAnchor.constraint(equalToConstant: 18).isActive = true
            views.append(imageView)
        }
        let label = ShellFont.label(
            title,
            font: ShellFont.ui(13, isCurrent ? .semibold : .regular),
            color: isEnabled ? ShellPalette.ink : ShellPalette.inkFaint
        )
        label.lineBreakMode = .byTruncatingMiddle
        // The title takes the slack, which is what pushes the check to the
        // trailing edge.
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        views.append(label)
        if isCurrent {
            let check = NSImageView()
            check.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
            check.contentTintColor = ShellPalette.ink
            check.translatesAutoresizingMaskIntoConstraints = false
            views.append(check)
        }

        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
}

// MARK: - Account menu

/// The avatar's popover: who is signed in, the plan they are on with the one
/// way up from it, then the door to the account — laid out like Flow's, whose
/// rows are not a list of commands, which is why this is not a
/// `HomeDropdownView` with a search field over three rows. "Log out" is
/// deliberately not here: it lives behind Manage account (Settings ›
/// Accounts), because it is not something anyone does every day and a menu
/// one click from the pointer is not where it belongs (Bruno, 2026-09-02).
final class AccountMenuView: NSView {
    static let width: CGFloat = 340
    /// What the plan row says. Plans do not exist yet (2026-09-02): everyone
    /// is on Free, and "Upgrade" opens the pricing page rather than an
    /// in-app checkout, so the menu already has the shape it will keep.
    static let freePlanTitle = "You are on OmniAgent Free"
    static let upgradeURL = URL(string: "https://www.omni-agent.ai/pricing")!

    var onUpgrade: (() -> Void)?
    var onManageAccount: (() -> Void)?
    var onSignIn: (() -> Void)?

    private let avatar = AccountAvatarView(diameter: 44)
    private let nameField = ShellFont.label(font: ShellFont.ui(15, .semibold), color: ShellPalette.ink)
    private let emailField = ShellFont.label(font: ShellFont.ui(13), color: ShellPalette.inkSecondary)
    private let planField = ShellFont.label(font: ShellFont.ui(14, .semibold), color: ShellPalette.ink)
    private let upgradeButton = PaneApprovalButton(title: "Upgrade", isPrimary: true, tint: ShellPalette.accent)
    private var rows: [HomeDropdownRowView] = []
    private let dismiss: () -> Void

    init(name: String?, email: String?, picture: NSImage?, signedIn: Bool, dismiss: @escaping () -> Void) {
        self.dismiss = dismiss
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        // Who. Signed in with no name on file, the email stands in for it
        // rather than printing twice.
        let title = signedIn ? (name ?? email ?? "Account") : "Not signed in"
        avatar.apply(name: signedIn ? name : nil, picture: signedIn ? picture : nil)
        nameField.stringValue = title
        emailField.stringValue = email ?? ""
        emailField.isHidden = !signedIn || email == nil || email == title
        for field in [nameField, emailField] { field.lineBreakMode = .byTruncatingMiddle }
        let identityText = NSStackView(views: [nameField, emailField])
        identityText.orientation = .vertical
        identityText.alignment = .leading
        identityText.spacing = 3
        let identity = NSStackView(views: [avatar, identityText])
        identity.orientation = .horizontal
        identity.alignment = .centerY
        identity.spacing = 14
        identity.edgeInsets = NSEdgeInsets(top: 16, left: 18, bottom: 16, right: 18)
        // The cross-axis insets of a horizontal stack are advisory — measured,
        // the row came out 6pt short — so the heights are stated: the avatar
        // plus its insets, the pill plus its.
        identity.heightAnchor.constraint(equalToConstant: 44 + 32).isActive = true

        var sections: [NSView] = [identity]

        // The plan, and the way up from it — only for an account that has one.
        if signedIn {
            planField.stringValue = Self.freePlanTitle
            planField.setContentHuggingPriority(.defaultLow, for: .horizontal)
            upgradeButton.translatesAutoresizingMaskIntoConstraints = false
            upgradeButton.onClick = { [weak self] in
                self?.onUpgrade?()
                self?.dismiss()
            }
            let plan = NSStackView(views: [planField, upgradeButton])
            plan.orientation = .horizontal
            plan.alignment = .centerY
            plan.spacing = 12
            plan.edgeInsets = NSEdgeInsets(top: 14, left: 18, bottom: 14, right: 18)
            plan.heightAnchor.constraint(equalToConstant: 26 + 28).isActive = true
            sections.append(plan)
        }

        // The door(s). Signed out, "Sign in" comes first: it is the one
        // thing to do; the account page still opens, and offers the same.
        let doors = NSStackView(views: [])
        doors.orientation = .vertical
        doors.spacing = 1
        // 8 + the row's own 10 puts its text on the 18pt line the sections
        // above share.
        doors.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        if !signedIn {
            doors.addArrangedSubview(row("Sign in") { [weak self] in self?.onSignIn?() })
        }
        doors.addArrangedSubview(row("Manage account") { [weak self] in self?.onManageAccount?() })
        for view in doors.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: doors.widthAnchor, constant: -16).isActive = true
        }
        sections.append(doors)

        let column = NSStackView(views: [])
        column.orientation = .vertical
        column.spacing = 0
        column.translatesAutoresizingMaskIntoConstraints = false
        for (index, section) in sections.enumerated() {
            if index > 0 { column.addArrangedSubview(ShellSeparator()) }
            column.addArrangedSubview(section)
        }
        for view in column.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        }
        addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor),
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthAnchor.constraint(equalToConstant: Self.width),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    /// A dropdown row without an icon — Flow's account rows are plain text —
    /// that closes the menu after its action, as the dropdown's own do.
    private func row(_ title: String, action: @escaping () -> Void) -> HomeDropdownRowView {
        let view = HomeDropdownRowView(icon: nil, title: title, isCurrent: false, isEnabled: true)
        view.onPress = { [dismiss] in
            action()
            dismiss()
        }
        rows.append(view)
        return view
    }

    // MARK: Test seams

    var visibleTitlesForTesting: [String] { rows.map(\.title) }
    var nameTextForTesting: String { nameField.stringValue }
    var emailTextForTesting: String? { emailField.isHidden ? nil : emailField.stringValue }
    /// `nil` while signed out — there is no plan row to read.
    var planTextForTesting: String? { upgradeButton.superview == nil ? nil : planField.stringValue }
    var avatarModeForTesting: AccountAvatarView.AvatarMode { avatar.mode }
    func pressRowForTesting(_ title: String) { rows.first { $0.title == title }?.onPress?() }
    func pressUpgradeForTesting() { upgradeButton.onClick?() }
}
