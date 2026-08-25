import AppKit

/// One `TranscriptTurn`, laid out whole in `init` from the blocks it is
/// handed.
///
/// A row is *not* built once and kept: a turn grows as its reply lands, and
/// `PaneAppView.appendMessages` answers that by throwing this view away and
/// constructing a new one from the merged blocks. Nothing here mutates after
/// `init`, which is what makes that safe — and why the only view state worth
/// keeping, a work group's expansion, is carried across by the caller through
/// `workGroups` rather than living in here.
final class PaneAppMessageRowView: NSView {
    /// This row's work groups, in the order they were built — the handle
    /// `PaneAppView.appendMessages` restores expansion state through when it
    /// rebuilds a growing turn. (A traversal would do as well; this is the
    /// one the row already knows for free, and the recursive `descendants`
    /// helper the tests use is test-only.)
    private(set) var workGroups: [PaneAppWorkGroupView] = []

    init(turn: TranscriptTurn) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let body = NSStackView()
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 4
        body.translatesAutoresizingMaskIntoConstraints = false

        let roleLabel = ShellFont.label(
            turn.isUser ? "You" : "Claude",
            font: ShellFont.ui(11, .semibold),
            color: turn.isUser ? ShellPalette.inkTertiary : ShellPalette.accent
        )
        body.addArrangedSubview(roleLabel)

        // Consecutive tool calls are one run and collapse together; anything
        // else flushes the run in progress first, so work keeps its place
        // between the prose either side of it.
        var run: [(name: String, detail: String)] = []
        func flushRun() {
            guard !run.isEmpty else { return }
            // A run of one is not the wall of shell commands the collapse
            // exists to remove — it renders inline, exactly as it did before
            // work groups existed. Only two or more calls collapse.
            if run.count == 1 {
                let call = run[0]
                for view in Self.blockViews(for: .tool(name: call.name, detail: call.detail)) {
                    add(view, to: body)
                }
            } else {
                let group = PaneAppWorkGroupView(calls: run)
                workGroups.append(group)
                add(group, to: body)
            }
            run = []
        }
        for block in turn.blocks {
            switch block {
            case .tool(let name, let detail):
                run.append((name, detail))
            case .text(let text):
                flushRun()
                for view in Self.blockViews(for: .text(text)) { add(view, to: body) }
            }
        }
        flushRun()

        addSubview(body)
        NSLayoutConstraint.activate([
            body.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            body.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            body.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            body.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    /// `.leading` alignment only pins each arranged view's leading edge;
    /// without the width constraint, a wrapping prose label or a truncating
    /// tool line reports its own tiny intrinsic width instead of filling the
    /// row.
    private func add(_ view: NSView, to body: NSStackView) {
        body.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
    }

    private static func blockViews(for block: TranscriptBlock) -> [NSView] {
        switch block {
        case .text(let text):
            return MarkdownBlock.parse(text).map { markdown -> NSView in
                switch markdown {
                case .paragraph(let prose):
                    return PaneAppView.proseLabel(prose)
                case .heading(let level, let text):
                    return PaneAppView.headingLabel(level: level, text: text)
                case .list(let items, let ordered):
                    return PaneAppView.listView(items: items, ordered: ordered)
                case .code(let code):
                    return PaneAppView.codeBlockView(code)
                case .table(let header, let rows):
                    return PaneAppView.codeBlockView(
                        PaneAppView.renderTable(header: header, rows: rows)
                    )
                }
            }
        case .tool(let name, let detail):
            return [PaneAppView.toolLabel(name: name, detail: detail)]
        }
    }
}

/// A run of consecutive tool calls in one turn, collapsed to a summary line
/// that expands on click.
///
/// The detail is built up front and merely hidden, never built on expand.
/// Not because rows are never rebuilt — a growing turn's row *is* rebuilt on
/// every poll — but because expansion state survives those rebuilds
/// (`PaneAppView.appendMessages` reapplies it), so a group can be expanded
/// from its first frame and the toggle must be a plain `isHidden` flip on a
/// tree that is already there rather than a mid-scroll construction.
final class PaneAppWorkGroupView: NSView {
    private(set) var isExpanded = false
    private let chevron: NSTextField
    private let detail = NSStackView()
    /// The clickable strip, kept for the cursor tracking area below: only the
    /// header toggles, so the pointing hand must not cover the detail lines.
    private let header: NSStackView
    private var cursorTracking: NSTrackingArea?

    init(calls: [(name: String, detail: String)]) {
        chevron = ShellFont.label("⌄", font: ShellFont.ui(11), color: ShellPalette.inkFaint)
        let summaryText = PaneAppView.workSummary(for: calls.map(\.name))
        let summary = ShellFont.label(
            summaryText,
            font: ShellFont.ui(12),
            color: ShellPalette.inkMuted
        )
        header = NSStackView(views: [chevron, summary])
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        // The header looks like a line of text and behaves like a control.
        // Without this it is invisible to VoiceOver and gives the pointer no
        // hint that it does anything.
        setAccessibilityElement(true)
        setAccessibilityRole(.disclosureTriangle)
        setAccessibilityLabel(summaryText)
        setAccessibilityExpanded(isExpanded)

        header.orientation = .horizontal
        header.alignment = .firstBaseline
        header.spacing = 6
        header.translatesAutoresizingMaskIntoConstraints = false

        detail.orientation = .vertical
        detail.alignment = .leading
        detail.spacing = 2
        detail.isHidden = true
        detail.translatesAutoresizingMaskIntoConstraints = false
        for call in calls {
            let label = PaneAppView.toolLabel(name: call.name, detail: call.detail)
            detail.addArrangedSubview(label)
            label.widthAnchor.constraint(equalTo: detail.widthAnchor).isActive = true
        }

        let body = NSStackView(views: [header, detail])
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 4
        body.translatesAutoresizingMaskIntoConstraints = false

        addSubview(body)
        NSLayoutConstraint.activate([
            body.topAnchor.constraint(equalTo: topAnchor),
            body.leadingAnchor.constraint(equalTo: leadingAnchor),
            body.trailingAnchor.constraint(equalTo: trailingAnchor),
            body.bottomAnchor.constraint(equalTo: bottomAnchor),
            header.widthAnchor.constraint(equalTo: body.widthAnchor),
            detail.widthAnchor.constraint(equalTo: body.widthAnchor),
        ])

        let click = NSClickGestureRecognizer(target: self, action: #selector(handleClick))
        header.addGestureRecognizer(click)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    /// The pointing hand over the header only — the detail lines below are
    /// selectable text and must keep the I-beam. `.cursorUpdate` on an
    /// explicit rect rather than a cursor rect for the same reason
    /// `PaneApprovalBar`'s buttons use one: these views are laid out by a
    /// stack that moves them, and a cursor rect is a frame the window caches.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let cursorTracking { removeTrackingArea(cursorTracking) }
        let area = NSTrackingArea(
            rect: convert(header.bounds, from: header),
            options: [.cursorUpdate, .activeInKeyWindow],
            owner: self
        )
        addTrackingArea(area)
        cursorTracking = area
    }

    override func cursorUpdate(with event: NSEvent) { NSCursor.pointingHand.set() }

    @objc private func handleClick() { toggle() }

    /// Internal rather than private so the tests can drive expansion without
    /// synthesising a click.
    func toggle() {
        isExpanded.toggle()
        detail.isHidden = !isExpanded
        chevron.stringValue = isExpanded ? "⌃" : "⌄"
        setAccessibilityExpanded(isExpanded)
    }
}
