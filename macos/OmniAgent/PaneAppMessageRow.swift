import AppKit

/// The speaker's mark beside a run of turns. Built only for the turn that
/// opens a run: a suppressed avatar is absent rather than hidden, so it takes
/// no space in the gutter and a continuing turn's prose still lines up.
final class PaneAppAvatarView: NSView {
    enum Kind { case agent, user }

    static let side: CGFloat = 28

    init(kind: Kind) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = Self.side / 2
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true

        let image = NSImageView()
        image.imageScaling = .scaleProportionallyUpOrDown
        image.translatesAutoresizingMaskIntoConstraints = false
        switch kind {
        case .agent:
            layer?.backgroundColor = ShellPalette.accentIconTile.cgColor
            image.image = OmniAgentMark.image
            image.contentTintColor = .white
        case .user:
            layer?.backgroundColor = ShellPalette.iconTile.cgColor
            // ponytail: SF Symbol, not a bundled silhouette. The reference
            // image is a generic head-and-shoulders; the symbol is its
            // equivalent, tints with the palette, and stays sharp at any
            // scale. Swap in an imageset here if a specific face is wanted.
            image.image = NSImage(
                systemSymbolName: "person.crop.circle.fill",
                accessibilityDescription: "Dev Mode"
            )
            image.contentTintColor = ShellPalette.inkTertiary
        }

        addSubview(image)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.side),
            heightAnchor.constraint(equalToConstant: Self.side),
            image.centerXAnchor.constraint(equalTo: centerXAnchor),
            image.centerYAnchor.constraint(equalTo: centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: Self.side - 8),
            image.heightAnchor.constraint(equalToConstant: Self.side - 8),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
}

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

    /// The vertical stack holding this turn's rendered blocks. Internal so
    /// the ordering tests can assert what landed in it, and so
    /// `proseOriginInWindow` can find the first prose view.
    private(set) var bodyStack: NSStackView?

    /// The user's bubble, or nil for an agent turn — the agent's prose sits
    /// directly on the ground. Internal so the layout tests can tell the two
    /// shapes apart without reading colours.
    private(set) var bubbleView: NSView?

    /// Where this row's first prose view starts, in window coordinates — the
    /// seam the alignment test measures.
    var proseOriginInWindow: CGPoint? {
        guard let body = bodyStack, let first = body.arrangedSubviews.first else { return nil }
        return first.convert(CGPoint.zero, to: nil)
    }

    /// True at each index whose turn opens a run of its speaker. Pure: the
    /// avatar rule is "once per run", and a run is exactly what
    /// `TranscriptTurn` already models.
    ///
    /// In a conversation built by `TranscriptTurn.append` every flag comes
    /// back true, because that merge is what makes consecutive same-role
    /// *turns* impossible in the first place. The false case is deliberate
    /// slack, not dead weight: it is the rule stated where the rule belongs,
    /// so a caller that ever hands over turns grouped some other way — a
    /// filtered view, a search result — draws one avatar per run rather than
    /// one per row.
    static func avatarFlags(for turns: [TranscriptTurn]) -> [Bool] {
        var flags: [Bool] = []
        var previousWasUser: Bool?
        for turn in turns {
            flags.append(previousWasUser != turn.isUser)
            previousWasUser = turn.isUser
        }
        return flags
    }

    init(turn: TranscriptTurn, showsAvatar: Bool) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let body = NSStackView()
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 4
        body.translatesAutoresizingMaskIntoConstraints = false
        bodyStack = body

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

        // Wide enough for the avatar plus the air beside it, so an agent's
        // prose clears the gutter whether or not this row draws a mark in it.
        let gutter = PaneAppAvatarView.side + 10
        let avatar = showsAvatar
            ? PaneAppAvatarView(kind: turn.isUser ? .user : .agent)
            : nil

        if turn.isUser {
            let bubble = NSView()
            bubble.wantsLayer = true
            bubble.layer?.backgroundColor = ShellPalette.cardFill.cgColor
            bubble.layer?.cornerRadius = 14
            bubble.layer?.cornerCurve = .continuous
            bubble.layer?.borderWidth = 1
            bubble.layer?.borderColor = ShellPalette.cardStroke.cgColor
            bubble.translatesAutoresizingMaskIntoConstraints = false
            bubble.addSubview(body)
            bubbleView = bubble
            addSubview(bubble)
            NSLayoutConstraint.activate([
                body.topAnchor.constraint(equalTo: bubble.topAnchor, constant: 12),
                body.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 14),
                body.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -14),
                body.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -12),
                bubble.topAnchor.constraint(equalTo: topAnchor, constant: 10),
                bubble.trailingAnchor.constraint(equalTo: trailingAnchor),
                // The bubble hugs its content — nothing stretches it — and
                // this floor is what stops a long question from running the
                // whole column and reading as a banner instead of a question.
                bubble.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: gutter),
            ])

            if let avatar {
                // Below the bubble, not beside it: both are pinned to the
                // trailing edge, so a shared top would stack the mark on top
                // of the words.
                let name = ShellFont.label(
                    "Dev Mode",
                    font: ShellFont.ui(11, .semibold),
                    color: ShellPalette.inkTertiary
                )
                let credit = NSStackView(views: [name, avatar])
                credit.orientation = .horizontal
                credit.alignment = .centerY
                credit.spacing = 8
                credit.translatesAutoresizingMaskIntoConstraints = false
                addSubview(credit)
                NSLayoutConstraint.activate([
                    credit.topAnchor.constraint(equalTo: bubble.bottomAnchor, constant: 6),
                    credit.trailingAnchor.constraint(equalTo: trailingAnchor),
                    credit.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
                ])
            } else {
                bubble.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10).isActive = true
            }
        } else {
            addSubview(body)
            NSLayoutConstraint.activate([
                body.topAnchor.constraint(equalTo: topAnchor, constant: 10),
                body.leadingAnchor.constraint(equalTo: leadingAnchor, constant: gutter),
                body.trailingAnchor.constraint(equalTo: trailingAnchor),
                body.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            ])

            if let avatar {
                addSubview(avatar)
                NSLayoutConstraint.activate([
                    avatar.topAnchor.constraint(equalTo: topAnchor, constant: 10),
                    avatar.leadingAnchor.constraint(equalTo: leadingAnchor),
                    // A one-line answer is shorter than the mark beside it;
                    // without this the avatar draws over the row below.
                    bottomAnchor.constraint(greaterThanOrEqualTo: avatar.bottomAnchor),
                ])
            }
        }
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
