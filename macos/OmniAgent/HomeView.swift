import AppKit

// The Home destination's real screen — the 2026-08-22 home design: the
// OmniAgent mark over a composer, three suggestion cards, an "Up next" empty
// state, two "Extend your experience" cards and the release notes. Replaces
// the "Under development" placeholder for `.home` only; To Do List keeps the
// placeholder.
//
// A pure design surface, by decision (2026-08-22): nothing on it acts yet —
// no control starts a session or routes anywhere. The behavior comes as its
// own step, on top of this screen.
//
// Deliberately all AppKit, on the same `ShellPalette`/`ShellFont` tokens the
// sidebar wears, and transparent throughout — `PaneGroundView` behind it is
// the ground, exactly as it is for the placeholder, so switching destinations
// never looks like switching apps.

// MARK: - Small parts

/// A rounded token-styled card — the composer, the suggestions, and every
/// section body wear this.
final class HomeCardView: NSView {
    init(cornerRadius: CGFloat = 12, fill: NSColor = ShellPalette.cardFill) {
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        layer?.cornerRadius = cornerRadius
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = fill.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = ShellPalette.cardStroke.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
}

/// The design's small secondary button: icon-tile fill, card stroke, 12.5pt
/// medium label. Renders only — the whole screen is design-only for now.
final class HomePillView: NSView {
    let label: NSTextField

    init(_ title: String) {
        label = ShellFont.label(title, font: ShellFont.ui(12.5, .medium), color: ShellPalette.ink)
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        layer?.cornerRadius = 7
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = ShellPalette.iconTile.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = ShellPalette.cardStroke.cgColor
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 13),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -13),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
}

// MARK: - Home

final class HomeSurfaceView: NSView {
    // Exposed for the tests, which assert the design's words without walking
    // the whole tree.
    let composerCard = HomeCardView(cornerRadius: 14, fill: ShellPalette.fieldFill)
    let composerPrompt = ShellFont.label(
        "Ask anything, or start a session. Use / for commands…",
        font: ShellFont.ui(14),
        color: ShellPalette.inkMuted
    )
    private(set) var suggestionCards: [HomeCardView] = []
    let viewAllPill = HomePillView("View all")
    let addWorkspaceLabel = ShellFont.label(
        "Add workspace",
        font: ShellFont.ui(12.5),
        color: ShellPalette.inkTertiary
    )
    let markImageView = NSImageView()
    let workspaceChipTile = ShellTileView(size: 16, radius: 5, fontSize: 7)
    let workspaceChipName = ShellFont.label(
        font: ShellFont.ui(12.5, .medium),
        color: ShellPalette.inkSecondary
    )
    let versionLabel = ShellFont.label(
        font: ShellFont.ui(13.5, .semibold),
        color: ShellPalette.ink
    )

    private let column = NSStackView()

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        column.orientation = .vertical
        column.alignment = .centerX
        column.spacing = 0
        column.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(column)

        let scroll = ShellScrollView(documentView: content)
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),

            // The design's centred 880pt column, giving way on thin windows.
            column.topAnchor.constraint(equalTo: content.topAnchor, constant: 120),
            column.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -36),
            column.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            column.leadingAnchor.constraint(greaterThanOrEqualTo: content.leadingAnchor, constant: 40),
        ])
        let width = column.widthAnchor.constraint(equalToConstant: 880)
        width.priority = .defaultHigh
        width.isActive = true

        buildHero()
        buildComposer()
        buildSuggestions()
        buildUpNext()
        buildExtend()
        buildWhatsNew()
        buildFooter()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    /// What the meta strip says a new session lands in. Called on every visit
    /// so a workspace switch shows up without any observing.
    func refresh(workspaceID: String?, workspaceName: String?) {
        let name = workspaceName ?? "No workspace"
        workspaceChipName.stringValue = name
        workspaceChipTile.apply(
            initials: ShellPalette.initials(name),
            gradient: ShellPalette.avatarGradient(forID: workspaceID ?? name)
        )
    }

    // MARK: Sections

    private func buildHero() {
        // The OmniAgent mark on the design's indigo 150° tile — the brand
        // pair, not a workspace's hashed colour.
        let tile = NSView()
        tile.translatesAutoresizingMaskIntoConstraints = false
        tile.wantsLayer = true
        let gradient = CAGradientLayer()
        gradient.colors = [ShellPalette.avatarGradients[0].0, ShellPalette.avatarGradients[0].1]
            .map(\.cgColor)
        gradient.startPoint = CGPoint(x: 0.25, y: 1)
        gradient.endPoint = CGPoint(x: 0.75, y: 0)
        gradient.cornerRadius = 16
        gradient.cornerCurve = .continuous
        tile.layer = gradient
        tile.layer?.shadowColor = ShellPalette.accent.cgColor
        tile.layer?.shadowOpacity = 0.18
        tile.layer?.shadowRadius = 30
        tile.layer?.shadowOffset = .zero
        tile.layer?.masksToBounds = false

        markImageView.image = OmniAgentMark.image
        markImageView.contentTintColor = .white
        markImageView.imageScaling = .scaleProportionallyUpOrDown
        markImageView.translatesAutoresizingMaskIntoConstraints = false
        tile.addSubview(markImageView)
        NSLayoutConstraint.activate([
            tile.widthAnchor.constraint(equalToConstant: 64),
            tile.heightAnchor.constraint(equalToConstant: 64),
            markImageView.widthAnchor.constraint(equalToConstant: 34),
            markImageView.heightAnchor.constraint(equalToConstant: 34),
            markImageView.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
            markImageView.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
        ])
        column.addArrangedSubview(tile)
        column.setCustomSpacing(48, after: tile)
    }

    private func buildComposer() {
        let engine = EngineLauncher.defaultEngine()
        let engineIcon = NSImageView()
        engineIcon.image = engine.iconImage
        engineIcon.contentTintColor = ShellPalette.inkSecondary
        engineIcon.imageScaling = .scaleProportionallyDown
        let engineName = ShellFont.label(
            engine.displayName,
            font: ShellFont.ui(12.5, .medium),
            color: ShellPalette.inkSecondary
        )
        let auto = ShellFont.label("Auto", font: ShellFont.ui(12.5), color: ShellPalette.inkTertiary)

        let send = NSView()
        send.translatesAutoresizingMaskIntoConstraints = false
        send.wantsLayer = true
        send.layer?.cornerRadius = 16
        send.layer?.backgroundColor = ShellPalette.accentIconTile.cgColor
        let arrow = symbol("arrow.up", pointSize: 13, weight: .semibold, color: ShellPalette.accentBright)
        send.addSubview(arrow)

        let separator = NSView()
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.wantsLayer = true
        separator.layer?.backgroundColor = ShellPalette.cardStroke.cgColor

        let controls = NSStackView(views: [
            symbol("plus", pointSize: 13, weight: .medium, color: ShellPalette.inkTertiary),
            engineIcon, engineName, separator, auto, NSView(), send,
        ])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 10
        controls.setCustomSpacing(14, after: controls.arrangedSubviews[0])
        controls.setCustomSpacing(7, after: engineIcon)
        controls.setCustomSpacing(14, after: engineName)
        controls.setCustomSpacing(14, after: separator)
        controls.translatesAutoresizingMaskIntoConstraints = false

        let meta = buildComposerMeta()

        composerCard.addSubview(composerPrompt)
        composerCard.addSubview(controls)
        composerCard.addSubview(meta)
        composerPrompt.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            engineIcon.widthAnchor.constraint(equalToConstant: 16),
            engineIcon.heightAnchor.constraint(equalToConstant: 16),
            separator.widthAnchor.constraint(equalToConstant: 1),
            separator.heightAnchor.constraint(equalToConstant: 16),
            send.widthAnchor.constraint(equalToConstant: 32),
            send.heightAnchor.constraint(equalToConstant: 32),
            arrow.centerXAnchor.constraint(equalTo: send.centerXAnchor),
            arrow.centerYAnchor.constraint(equalTo: send.centerYAnchor),

            composerPrompt.topAnchor.constraint(equalTo: composerCard.topAnchor, constant: 20),
            composerPrompt.leadingAnchor.constraint(equalTo: composerCard.leadingAnchor, constant: 20),
            composerPrompt.trailingAnchor.constraint(lessThanOrEqualTo: composerCard.trailingAnchor, constant: -20),
            controls.topAnchor.constraint(equalTo: composerPrompt.bottomAnchor, constant: 18),
            controls.leadingAnchor.constraint(equalTo: composerCard.leadingAnchor, constant: 16),
            controls.trailingAnchor.constraint(equalTo: composerCard.trailingAnchor, constant: -14),
            meta.topAnchor.constraint(equalTo: controls.bottomAnchor, constant: 14),
            meta.leadingAnchor.constraint(equalTo: composerCard.leadingAnchor),
            meta.trailingAnchor.constraint(equalTo: composerCard.trailingAnchor),
            meta.bottomAnchor.constraint(equalTo: composerCard.bottomAnchor),
        ])

        column.addArrangedSubview(composerCard)
        composerCard.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        column.setCustomSpacing(40, after: composerCard)
    }

    /// The strip under the composer: where a session would land. ponytail:
    /// the design's worktree and branch chips wait until Home can actually
    /// make worktrees / read the branch.
    private func buildComposerMeta() -> NSView {
        let strip = NSView()
        strip.translatesAutoresizingMaskIntoConstraints = false
        strip.wantsLayer = true
        strip.layer?.backgroundColor = ShellPalette.backRowFill.cgColor

        let rule = ShellSeparator()
        let addIcon = symbol("plus", pointSize: 10, weight: .medium, color: ShellPalette.inkMuted)
        let add = NSStackView(views: [addIcon, addWorkspaceLabel])
        add.orientation = .horizontal
        add.spacing = 6
        let chip = NSStackView(views: [workspaceChipTile, workspaceChipName])
        chip.orientation = .horizontal
        chip.spacing = 7

        let row = NSStackView(views: [chip, NSView(), add])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        strip.addSubview(rule)
        strip.addSubview(row)
        NSLayoutConstraint.activate([
            rule.topAnchor.constraint(equalTo: strip.topAnchor),
            rule.leadingAnchor.constraint(equalTo: strip.leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: strip.trailingAnchor),
            row.topAnchor.constraint(equalTo: strip.topAnchor, constant: 9),
            row.bottomAnchor.constraint(equalTo: strip.bottomAnchor, constant: -9),
            row.leadingAnchor.constraint(equalTo: strip.leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(equalTo: strip.trailingAnchor, constant: -16),
        ])

        add.setAccessibilityElement(true)
        add.setAccessibilityRole(.button)
        add.setAccessibilityLabel("Add workspace")
        return strip
    }

    private func buildSuggestions() {
        let suggestions: [(String, String)] = [
            ("chevron.left.forwardslash.chevron.right", "Review recent changes and suggest improvements."),
            ("book", "Update or generate documentation from the source."),
            ("checkmark.shield", "Scan for security vulnerabilities and fix them."),
        ]
        let cards = suggestions.map { name, text in
            let card = HomeCardView()
            let icon = symbol(name, pointSize: 15, weight: .regular, color: ShellPalette.inkTertiary)
            let body = wrapping(text, font: ShellFont.ui(13), color: ShellPalette.inkSecondary)
            card.addSubview(icon)
            card.addSubview(body)
            NSLayoutConstraint.activate([
                icon.topAnchor.constraint(equalTo: card.topAnchor, constant: 18),
                icon.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
                body.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 14),
                body.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
                body.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -18),
                body.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -20),
            ])
            return card
        }
        suggestionCards = cards
        let row = NSStackView(views: cards)
        row.orientation = .horizontal
        row.distribution = .fillEqually
        row.spacing = 16
        column.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        column.setCustomSpacing(72, after: row)
    }

    private func buildUpNext() {
        addSectionHeader(
            "Up next",
            sub: "Recently updated sessions and tasks across your workspaces."
        )
        let card = HomeCardView()
        let icon = symbol("checkmark.circle", pointSize: 20, weight: .regular, color: ShellPalette.inkTertiary)
        let title = ShellFont.label(
            "You're all caught up",
            font: ShellFont.ui(15, .semibold),
            color: ShellPalette.ink
        )
        let stack = NSStackView(views: [icon, title, viewAllPill])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 56),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -56),
            stack.centerXAnchor.constraint(equalTo: card.centerXAnchor),
        ])
        column.addArrangedSubview(card)
        card.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        column.setCustomSpacing(72, after: card)
    }

    private func buildExtend() {
        addSectionHeader(
            "Extend your experience",
            sub: "Find new ways to work with the app, from connecting your tools to growing its memory."
        )
        let extras: [(String, String, String, String)] = [
            (
                "puzzlepiece.extension",
                "Extend with MCP servers",
                "Connect tools like Figma, Playwright, or Linear so agents can take actions beyond your codebase.",
                "Add MCP server"
            ),
            (
                "brain",
                "Grow the brain",
                "Ingest repositories into the knowledge graph so every agent answers with your code's context.",
                "Add repository"
            ),
        ]
        let cards = extras.map { name, title, body, pillTitle in
            let card = HomeCardView()
            let icon = symbol(name, pointSize: 17, weight: .regular, color: ShellPalette.accent)
            let heading = ShellFont.label(title, font: ShellFont.ui(14, .semibold), color: ShellPalette.ink)
            let text = wrapping(body, font: ShellFont.ui(13), color: ShellPalette.inkTertiary)
            let pill = HomePillView(pillTitle)
            for view in [icon, heading, text, pill] { card.addSubview(view) }
            NSLayoutConstraint.activate([
                icon.topAnchor.constraint(equalTo: card.topAnchor, constant: 22),
                icon.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 22),
                heading.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 12),
                heading.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 22),
                text.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 8),
                text.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 22),
                text.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -22),
                pill.topAnchor.constraint(equalTo: text.bottomAnchor, constant: 14),
                pill.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 22),
                pill.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -20),
            ])
            return card
        }
        let row = NSStackView(views: cards)
        row.orientation = .horizontal
        row.distribution = .fillEqually
        row.spacing = 16
        column.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        column.setCustomSpacing(72, after: row)
    }

    private func buildWhatsNew() {
        addSectionHeader("What's new", sub: "Explore the changes included in the latest release.")

        let card = HomeCardView()

        let releaseTile = NSView()
        releaseTile.translatesAutoresizingMaskIntoConstraints = false
        releaseTile.wantsLayer = true
        let gradient = CAGradientLayer()
        gradient.colors = [ShellPalette.avatarGradients[0].0, ShellPalette.avatarGradients[0].1]
            .map(\.cgColor)
        gradient.startPoint = CGPoint(x: 0.25, y: 1)
        gradient.endPoint = CGPoint(x: 0.75, y: 0)
        gradient.cornerRadius = 10
        gradient.cornerCurve = .continuous
        releaseTile.layer = gradient
        let smallMark = NSImageView()
        smallMark.image = OmniAgentMark.image
        smallMark.contentTintColor = .white
        smallMark.imageScaling = .scaleProportionallyUpOrDown
        smallMark.translatesAutoresizingMaskIntoConstraints = false
        releaseTile.addSubview(smallMark)

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        versionLabel.stringValue = "OmniAgent ADE \(version ?? "")"
        let release = NSStackView(views: [releaseTile, versionLabel, HomePillView("Check for updates")])
        release.orientation = .vertical
        release.alignment = .leading
        release.spacing = 14
        release.translatesAutoresizingMaskIntoConstraints = false

        let divider = NSView()
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.wantsLayer = true
        divider.layer?.backgroundColor = ShellPalette.hairline.cgColor

        let notes = [
            "The sidebar keeps an eye on the machine — CPU, memory, and GPU live in the session hover card.",
            "The git tab now leads with the diff: files changed, insertions, and deletions at a glance.",
            "Engine badges follow a hand-typed /model, and every Claude pane wears one.",
        ]
        let bullets = notes.map { note -> NSView in
            let dot = NSView()
            dot.translatesAutoresizingMaskIntoConstraints = false
            dot.wantsLayer = true
            dot.layer?.cornerRadius = 2.5
            dot.layer?.backgroundColor = ShellPalette.inkFaint.cgColor
            let text = wrapping(note, font: ShellFont.ui(13), color: ShellPalette.inkSecondary)
            let row = NSView()
            row.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(dot)
            row.addSubview(text)
            NSLayoutConstraint.activate([
                dot.widthAnchor.constraint(equalToConstant: 5),
                dot.heightAnchor.constraint(equalToConstant: 5),
                dot.leadingAnchor.constraint(equalTo: row.leadingAnchor),
                dot.topAnchor.constraint(equalTo: row.topAnchor, constant: 7),
                text.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 12),
                text.trailingAnchor.constraint(equalTo: row.trailingAnchor),
                text.topAnchor.constraint(equalTo: row.topAnchor),
                text.bottomAnchor.constraint(equalTo: row.bottomAnchor),
            ])
            return row
        }
        let changelog = ShellFont.label(
            "Read changelog ↗",
            font: ShellFont.ui(13, .medium),
            color: ShellPalette.accentBright
        )
        let changes = NSStackView(views: bullets + [changelog])
        changes.orientation = .vertical
        changes.alignment = .leading
        changes.spacing = 13
        changes.translatesAutoresizingMaskIntoConstraints = false
        for bullet in bullets {
            bullet.widthAnchor.constraint(equalTo: changes.widthAnchor).isActive = true
        }

        card.addSubview(release)
        card.addSubview(divider)
        card.addSubview(changes)
        NSLayoutConstraint.activate([
            releaseTile.widthAnchor.constraint(equalToConstant: 40),
            releaseTile.heightAnchor.constraint(equalToConstant: 40),
            smallMark.widthAnchor.constraint(equalToConstant: 22),
            smallMark.heightAnchor.constraint(equalToConstant: 22),
            smallMark.centerXAnchor.constraint(equalTo: releaseTile.centerXAnchor),
            smallMark.centerYAnchor.constraint(equalTo: releaseTile.centerYAnchor),

            release.topAnchor.constraint(equalTo: card.topAnchor, constant: 26),
            release.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 24),
            release.widthAnchor.constraint(equalToConstant: 232),
            release.bottomAnchor.constraint(lessThanOrEqualTo: card.bottomAnchor, constant: -26),

            divider.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 280),
            divider.topAnchor.constraint(equalTo: card.topAnchor),
            divider.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),

            changes.topAnchor.constraint(equalTo: card.topAnchor, constant: 26),
            changes.leadingAnchor.constraint(equalTo: divider.trailingAnchor, constant: 28),
            changes.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -28),
            changes.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -26),
        ])

        column.addArrangedSubview(card)
        card.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        column.setCustomSpacing(88, after: card)
    }

    private func buildFooter() {
        let footer = ShellFont.label(
            "OmniAgent uses AI. Check for mistakes.",
            font: ShellFont.ui(12),
            color: ShellPalette.inkFaint
        )
        column.addArrangedSubview(footer)
    }

    // MARK: Shared pieces

    private func addSectionHeader(_ title: String, sub: String) {
        let heading = ShellFont.label(title, font: ShellFont.ui(15, .semibold), color: ShellPalette.ink)
        let subtitle = ShellFont.label(sub, font: ShellFont.ui(13), color: ShellPalette.inkMuted)
        let stack = NSStackView(views: [heading, subtitle])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 5
        column.addArrangedSubview(stack)
        stack.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        column.setCustomSpacing(22, after: stack)
    }

    private func symbol(
        _ name: String,
        pointSize: CGFloat,
        weight: NSFont.Weight,
        color: NSColor
    ) -> NSImageView {
        let view = NSImageView()
        view.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: pointSize, weight: weight))
        view.contentTintColor = color
        view.translatesAutoresizingMaskIntoConstraints = false
        view.setContentHuggingPriority(.required, for: .horizontal)
        return view
    }

    private func wrapping(_ text: String, font: NSFont, color: NSColor) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = font
        field.textColor = color
        field.isSelectable = false
        field.translatesAutoresizingMaskIntoConstraints = false
        return field
    }
}
