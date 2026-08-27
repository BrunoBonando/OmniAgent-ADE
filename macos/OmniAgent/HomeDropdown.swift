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
        from anchor: NSView
    ) -> HomeDropdownView {
        current?.performClose(nil)
        let popover = NSPopover()
        current = popover
        let content = HomeDropdownView(searchPlaceholder: searchPlaceholder) { [weak popover] in
            popover?.performClose(nil)
        }
        content.sections = sections
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
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        content.focusSearch()
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

    private let search = NSTextField()
    private let list = NSStackView()
    private var rowViews: [HomeDropdownRowView] = []
    private var headerViews: [(view: NSView, rows: [HomeDropdownRowView])] = []
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
            if let header { headerViews.append((header, sectionRows)) }
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
        // A header with every row filtered out goes too — a heading over
        // nothing reads as a bug.
        for (header, rows) in headerViews {
            header.isHidden = rows.allSatisfy(\.isHidden)
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
