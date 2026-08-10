import AppKit

// The workspace shell from the "OmniAgent ADE" design doc, step 1 (Bruno,
// 2026-08-10): a two-level sidebar that slides between a workspace picker
// (Level 1) and the open workspace's navigation (Level 2), plus the four
// destinations Level 2 navigates to — Dashboard, Board, Terminals, Files.
//
// **Terminals is the only one that does anything in this step**, deliberately:
// it keeps showing `SessionOutlineView` over `PaneWorkspaceView`, i.e. the
// existing sessions/panes/SwiftTerm hot path, entirely untouched. Dashboard
// and Board are empty placeholders on purpose ("Dashboard and board are just
// placeholders to empty views for now. Let's focus just on the foundation").
// Files is a placeholder too, for a different reason — see
// `WorkspaceDestination.files`.
//
// Everything here is AppKit: the app has no webview, and the design's CSS
// slide has no native equivalent, so the transition is a hand-rolled
// constant animation on a two-pane track (`WorkspaceSidebarView`).

// MARK: - Destinations

/// Level 2's four destinations, in the design's order.
enum WorkspaceDestination: String, CaseIterable {
    case dashboard
    case board
    /// The only one wired to real content in step 1.
    case terminals
    /// A placeholder for a reason the other two don't share: the design draws
    /// a Finder-like tree with live git badges, and this app has **no**
    /// file-listing client at all (nothing in `macos/` calls `list_dir` or
    /// walks a directory). That is a new daemon surface, not a view — out of
    /// scope for a foundation step.
    case files

    var title: String {
        switch self {
        case .dashboard: return "Dashboard"
        case .board: return "Board"
        case .terminals: return "Terminals"
        case .files: return "Files"
        }
    }

    var subtitle: String {
        switch self {
        case .dashboard: return "activity, tokens, approvals"
        case .board: return "backlog, sprint, timeline"
        case .terminals: return "sessions and their terminals"
        case .files: return "tree, diffs, editor"
        }
    }

    /// SF Symbols rather than bundled art: every glyph the design draws is a
    /// standard shape, and a system symbol is what keeps the row matching the
    /// rest of macOS across accent colours, text sizes and appearances.
    var symbolName: String {
        switch self {
        case .dashboard: return "chart.bar.fill"
        case .board: return "rectangle.split.3x1.fill"
        case .terminals: return "terminal"
        case .files: return "folder.fill"
        }
    }
}

// MARK: - Palette

/// The design doc's dark tokens, once. Deliberately not `NSColor.controlAccentColor`
/// and friends: this window is pinned to `.darkAqua` with its own near-black
/// ground, and the design specifies exact values.
enum ShellPalette {
    static let panel = NSColor(srgbRed: 23 / 255, green: 23 / 255, blue: 26 / 255, alpha: 1)
    static let content = NSColor(srgbRed: 10 / 255, green: 10 / 255, blue: 12 / 255, alpha: 1)
    static let ink = NSColor(srgbRed: 240 / 255, green: 240 / 255, blue: 244 / 255, alpha: 1)
    static let inkDim = NSColor(srgbRed: 139 / 255, green: 139 / 255, blue: 149 / 255, alpha: 1)
    static let inkFaint = NSColor(srgbRed: 101 / 255, green: 101 / 255, blue: 111 / 255, alpha: 1)
    static let accent = NSColor(srgbRed: 139 / 255, green: 149 / 255, blue: 255 / 255, alpha: 1)
    static let hairline = NSColor(white: 1, alpha: 0.07)
    static let hover = NSColor(white: 1, alpha: 0.06)
    static let cardFill = NSColor(white: 1, alpha: 0.04)
    static let cardStroke = NSColor(white: 1, alpha: 0.09)
    static let selected = NSColor(srgbRed: 139 / 255, green: 149 / 255, blue: 255 / 255, alpha: 0.14)

    /// Port of `ui/src/state/projectColors.ts` — same palette, same stable
    /// hash, so a workspace keeps its colour across the two implementations
    /// and across relaunches without anything being persisted.
    static let avatarColors: [NSColor] = [
        NSColor(srgbRed: 182 / 255, green: 150 / 255, blue: 242 / 255, alpha: 1),
        NSColor(srgbRed: 162 / 255, green: 231 / 255, blue: 249 / 255, alpha: 1),
        NSColor(srgbRed: 237 / 255, green: 129 / 255, blue: 195 / 255, alpha: 1),
        NSColor(srgbRed: 232 / 255, green: 162 / 255, blue: 61 / 255, alpha: 1),
        NSColor(srgbRed: 95 / 255, green: 212 / 255, blue: 200 / 255, alpha: 1),
        NSColor(srgbRed: 120 / 255, green: 169 / 255, blue: 255 / 255, alpha: 1),
    ]

    /// `Int32` arithmetic with explicit wrapping, matching the JS `| 0` the
    /// TypeScript version relies on — plain `Int` would overflow-trap on a
    /// long id instead of wrapping, and would pick a different colour.
    static func avatarColor(forID id: String) -> NSColor {
        var hash: Int32 = 0
        for scalar in id.unicodeScalars {
            hash = hash &* 31 &+ Int32(truncatingIfNeeded: scalar.value)
        }
        let index = Int(hash.magnitude % Int32.Magnitude(avatarColors.count))
        return avatarColors[index]
    }

    /// "OmniAgent ADE" -> "OA", "voice" -> "VO". One letter reads as an
    /// accident at the design's 32pt tile.
    static func initials(_ label: String) -> String {
        let words = label.split(whereSeparator: { " -_./".contains($0) })
        if words.count >= 2, let a = words[0].first, let b = words[1].first {
            return "\(a)\(b)".uppercased()
        }
        return String(label.prefix(2)).uppercased()
    }

    static func sessionCountLabel(_ n: Int) -> String {
        switch n {
        case 0: return "no sessions"
        case 1: return "1 session"
        default: return "\(n) sessions"
        }
    }
}

/// The design's slide, and the system's opinion about whether to play it.
enum ShellMotion {
    static let duration: TimeInterval = 0.34
    static let timing = CAMediaTimingFunction(controlPoints: 0.22, 0.85, 0.25, 1)

    static var reduced: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
}

// MARK: - Clickable row base

/// A row that behaves like a button without being one: `NSButton` cannot hold
/// the multi-line, multi-colour content these rows need without a custom cell,
/// and a custom cell is more code than press handling. Keyboard activation,
/// the accessibility role and `accessibilityPerformPress` are all wired so
/// this stays a real control for VoiceOver and Full Keyboard Access.
class ShellRowView: NSView {
    var onPress: (() -> Void)?
    /// Painted under the row on hover, unless the row is already selected.
    var hoverEnabled = true
    private(set) var isHovered = false
    private var tracking: NSTrackingArea?

    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        refreshBackground()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        refreshBackground()
    }

    override func mouseUp(with event: NSEvent) {
        // Only a click that both started and ended inside the row counts —
        // a drag that wandered off it is not a press.
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onPress?()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.charactersIgnoringModifiers == " " {
            onPress?()
            return
        }
        super.keyDown(with: event)
    }

    /// Subclasses paint here; the base only tells them when.
    func refreshBackground() {}

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityPerformPress() -> Bool {
        onPress?()
        return true
    }
}

// MARK: - Level 1 · workspace picker

/// One workspace card: colour tile with initials, name, path, session count.
final class WorkspaceCardView: ShellRowView {
    let workspace: BrainProjectSummary

    private let tile = NSTextField(labelWithString: "")
    private let name = NSTextField(labelWithString: "")
    private let path = NSTextField(labelWithString: "")
    private let meta = NSTextField(labelWithString: "")

    init(workspace: BrainProjectSummary, sessionCount: Int) {
        self.workspace = workspace
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.borderWidth = 1
        layer?.borderColor = ShellPalette.cardStroke.cgColor
        refreshBackground()

        tile.stringValue = ShellPalette.initials(workspace.label)
        tile.alignment = .center
        tile.font = .systemFont(ofSize: 12, weight: .bold)
        tile.textColor = .white
        tile.wantsLayer = true
        tile.layer?.cornerRadius = 9
        tile.layer?.backgroundColor = ShellPalette.avatarColor(forID: workspace.id).cgColor
        // A label draws its text at the top of its frame by default; the tile
        // needs it centred in a 32pt square.
        tile.isBezeled = false
        tile.usesSingleLineMode = true
        tile.cell?.lineBreakMode = .byClipping

        name.stringValue = workspace.label
        name.font = .systemFont(ofSize: 13, weight: .semibold)
        name.textColor = ShellPalette.ink
        name.lineBreakMode = .byTruncatingTail

        path.stringValue = workspace.path ?? ""
        path.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        path.textColor = ShellPalette.inkFaint
        path.lineBreakMode = .byTruncatingHead
        path.isHidden = (workspace.path ?? "").isEmpty

        meta.stringValue = ShellPalette.sessionCountLabel(sessionCount)
        meta.font = .systemFont(ofSize: 10, weight: .medium)
        meta.textColor = ShellPalette.inkDim

        let chevron = NSImageView()
        chevron.image = NSImage(
            systemSymbolName: "chevron.right",
            accessibilityDescription: nil
        )
        chevron.contentTintColor = ShellPalette.inkDim
        chevron.symbolConfiguration = .init(pointSize: 10, weight: .semibold)

        let text = NSStackView(views: [name, path, meta])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        text.setHuggingPriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [tile, text, chevron])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        NSLayoutConstraint.activate([
            tile.widthAnchor.constraint(equalToConstant: 32),
            tile.heightAnchor.constraint(equalToConstant: 32),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])

        setAccessibilityLabel("Open workspace \(workspace.label)")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func refreshBackground() {
        let fill = isHovered && hoverEnabled
            ? NSColor(white: 1, alpha: 0.085)
            : ShellPalette.cardFill
        layer?.backgroundColor = fill.cgColor
    }
}

/// Level 1: "Workspaces / Open one to see its agents", one card each, and the
/// dashed "New workspace" the design ends the list with.
final class WorkspacePickerView: NSView {
    var onPick: ((BrainProjectSummary) -> Void)?
    var onNewWorkspace: (() -> Void)?

    private let list = NSStackView()
    private let empty = NSTextField(labelWithString: "No workspaces yet.")
    private(set) var cards: [WorkspaceCardView] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        let title = NSTextField(labelWithString: "Workspaces")
        title.font = .systemFont(ofSize: 15, weight: .bold)
        title.textColor = ShellPalette.ink

        let subtitle = NSTextField(labelWithString: "Open one to see its agents")
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = ShellPalette.inkFaint

        let header = NSStackView(views: [title, subtitle])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 3
        header.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 11, right: 14)

        let rule = NSBox()
        rule.boxType = .separator

        empty.font = .systemFont(ofSize: 11)
        empty.textColor = ShellPalette.inkFaint

        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 6
        list.edgeInsets = NSEdgeInsets(top: 9, left: 8, bottom: 9, right: 8)
        list.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.documentView = list
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [header, rule, scroll])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            rule.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            // The list is as wide as the clip view, so cards stretch rather
            // than sizing to their longest path string.
            list.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    /// Rebuilt wholesale: the list is a handful of rows read from one
    /// `listProjects` response, so diffing it would be more moving parts than
    /// the thing it optimises.
    func setWorkspaces(_ workspaces: [BrainProjectSummary], sessionCounts: [String: Int]) {
        for view in list.arrangedSubviews {
            list.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        cards = workspaces.map { workspace in
            let card = WorkspaceCardView(
                workspace: workspace,
                sessionCount: sessionCounts[workspace.id] ?? 0
            )
            card.onPress = { [weak self] in self?.onPick?(workspace) }
            return card
        }
        for card in cards {
            list.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: list.widthAnchor, constant: -16).isActive = true
        }
        if workspaces.isEmpty { list.addArrangedSubview(empty) }

        let new = NSButton(title: "New workspace", target: self, action: #selector(newWorkspace))
        new.bezelStyle = .rounded
        new.controlSize = .large
        list.addArrangedSubview(new)
        new.widthAnchor.constraint(equalTo: list.widthAnchor, constant: -16).isActive = true
    }

    @objc private func newWorkspace() {
        onNewWorkspace?()
    }
}

// MARK: - Level 2 · workspace nav

/// One destination row: icon tile, title, subtitle, optional count, and the
/// design's 3pt accent bar down the leading edge when selected.
final class WorkspaceNavRowView: ShellRowView {
    let destination: WorkspaceDestination

    private let bar = NSView()
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private let count = NSTextField(labelWithString: "")

    private(set) var isSelected = false

    init(destination: WorkspaceDestination) {
        self.destination = destination
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8

        bar.wantsLayer = true
        bar.layer?.cornerRadius = 1.5
        bar.layer?.backgroundColor = NSColor.clear.cgColor
        bar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bar)

        icon.image = NSImage(systemSymbolName: destination.symbolName, accessibilityDescription: nil)
        icon.symbolConfiguration = .init(pointSize: 12, weight: .semibold)

        title.stringValue = destination.title
        title.font = .systemFont(ofSize: 13, weight: .semibold)

        subtitle.stringValue = destination.subtitle
        subtitle.font = .systemFont(ofSize: 10)
        subtitle.textColor = ShellPalette.inkFaint
        subtitle.lineBreakMode = .byTruncatingTail

        count.font = .monospacedSystemFont(ofSize: 10, weight: .medium)
        count.textColor = ShellPalette.inkDim
        count.isHidden = true

        let text = NSStackView(views: [title, subtitle])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        text.setHuggingPriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [icon, text, count])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 9
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: leadingAnchor),
            bar.widthAnchor.constraint(equalToConstant: 3),
            bar.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            bar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            icon.widthAnchor.constraint(equalToConstant: 20),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
        ])

        apply(selected: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    /// `nil` hides the badge — an empty destination shows nothing rather than
    /// a zero.
    func setCount(_ value: Int?) {
        if let value, value > 0 {
            count.stringValue = "\(value)"
            count.isHidden = false
        } else {
            count.isHidden = true
        }
    }

    func apply(selected: Bool) {
        isSelected = selected
        title.textColor = selected ? ShellPalette.ink : ShellPalette.inkDim
        icon.contentTintColor = selected ? ShellPalette.accent : ShellPalette.inkDim
        bar.layer?.backgroundColor = (selected ? ShellPalette.accent : .clear).cgColor
        setAccessibilityLabel(destination.title)
        // AppKit has no "tab" role that carries selection on a plain view;
        // the selected state is what VoiceOver reads instead.
        setAccessibilityValue(selected ? "selected" : "")
        refreshBackground()
    }

    override func refreshBackground() {
        let fill: NSColor
        if isSelected {
            fill = ShellPalette.selected
        } else if isHovered && hoverEnabled {
            fill = ShellPalette.hover
        } else {
            fill = .clear
        }
        layer?.backgroundColor = fill.cgColor
    }
}

/// The back row that names the open workspace and returns to the picker.
final class WorkspaceBackRowView: ShellRowView {
    private let tile = NSTextField(labelWithString: "")
    private let name = NSTextField(labelWithString: "")
    private let path = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        let chevron = NSImageView()
        chevron.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: nil)
        chevron.contentTintColor = ShellPalette.inkDim
        chevron.symbolConfiguration = .init(pointSize: 11, weight: .semibold)

        tile.alignment = .center
        tile.font = .systemFont(ofSize: 10.5, weight: .bold)
        tile.textColor = .white
        tile.wantsLayer = true
        tile.layer?.cornerRadius = 7
        tile.usesSingleLineMode = true

        name.font = .systemFont(ofSize: 13, weight: .semibold)
        name.textColor = ShellPalette.ink
        name.lineBreakMode = .byTruncatingTail

        path.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        path.textColor = ShellPalette.inkFaint
        path.lineBreakMode = .byTruncatingHead

        let text = NSStackView(views: [name, path])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        text.setHuggingPriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [chevron, tile, text])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 9
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        NSLayoutConstraint.activate([
            tile.widthAnchor.constraint(equalToConstant: 26),
            tile.heightAnchor.constraint(equalToConstant: 26),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -9),
        ])
        refreshBackground()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    func apply(workspace: BrainProjectSummary?) {
        let label = workspace?.label ?? "No workspace"
        tile.stringValue = ShellPalette.initials(label)
        tile.layer?.backgroundColor = workspace
            .map { ShellPalette.avatarColor(forID: $0.id) }
            .unwrapped(or: ShellPalette.inkFaint)
            .cgColor
        name.stringValue = label
        path.stringValue = workspace?.path ?? ""
        path.isHidden = (workspace?.path ?? "").isEmpty
        setAccessibilityLabel("Switch workspace, currently \(label)")
    }

    override func refreshBackground() {
        layer?.backgroundColor = (isHovered ? ShellPalette.hover : NSColor(white: 1, alpha: 0.03)).cgColor
    }
}

private extension Optional where Wrapped == NSColor {
    func unwrapped(or fallback: NSColor) -> NSColor { self ?? fallback }
}

// MARK: - The sliding sidebar

/// Levels 1 and 2 side by side on a track twice the sidebar's width, with the
/// track's leading constant animated between `0` and `-width`.
///
/// AppKit offers `NSViewController.transition(from:to:options:.slideForward)`,
/// which would be free — but it swaps one child for another with the system's
/// own timing, and the design specifies both panes existing at once and its
/// own easing. Recomputing the constant in `layout()` is what keeps the track
/// correct across a sidebar resize, which a one-shot animation would not.
final class WorkspaceSidebarView: NSView {
    var onSelectWorkspace: ((BrainProjectSummary) -> Void)?
    var onSelectDestination: ((WorkspaceDestination) -> Void)?
    var onNewWorkspace: (() -> Void)?

    let picker = WorkspacePickerView()
    let backRow = WorkspaceBackRowView()
    /// The existing session outline, hosted under Terminals. Injected rather
    /// than owned: `WorkspaceWindowController` already wires every one of its
    /// callbacks, and this view has no business in that.
    let outline: SessionOutlineView

    private(set) var isShowingPicker = true
    private(set) var destination: WorkspaceDestination = .terminals
    private(set) var selectedWorkspace: BrainProjectSummary?

    private let track = NSView()
    private var trackLeading: NSLayoutConstraint!
    /// Internal, not private, so the tests can assert which destination row is
    /// lit and whether the sessions tree is showing without reaching through
    /// `NSStackView`'s visibility priorities.
    private(set) var navRows: [WorkspaceNavRowView] = []
    private(set) var outlineContainer = NSView()
    private let spacer = NSView()
    private let navStack = NSStackView()

    init(outline: SessionOutlineView) {
        self.outline = outline
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = ShellPalette.panel.cgColor
        // The off-screen level must not paint outside the sidebar.
        layer?.masksToBounds = true

        let level2 = buildLevel2()
        picker.onPick = { [weak self] workspace in self?.onSelectWorkspace?(workspace) }
        picker.onNewWorkspace = { [weak self] in self?.onNewWorkspace?() }
        backRow.onPress = { [weak self] in self?.showPicker() }

        for view in [track, picker, level2] { view.translatesAutoresizingMaskIntoConstraints = false }
        addSubview(track)
        track.addSubview(picker)
        track.addSubview(level2)

        trackLeading = track.leadingAnchor.constraint(equalTo: leadingAnchor)
        NSLayoutConstraint.activate([
            trackLeading,
            track.topAnchor.constraint(equalTo: topAnchor),
            track.bottomAnchor.constraint(equalTo: bottomAnchor),
            track.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 2),

            picker.leadingAnchor.constraint(equalTo: track.leadingAnchor),
            picker.widthAnchor.constraint(equalTo: widthAnchor),
            picker.topAnchor.constraint(equalTo: track.topAnchor),
            picker.bottomAnchor.constraint(equalTo: track.bottomAnchor),

            level2.leadingAnchor.constraint(equalTo: picker.trailingAnchor),
            level2.widthAnchor.constraint(equalTo: widthAnchor),
            level2.topAnchor.constraint(equalTo: track.topAnchor),
            level2.bottomAnchor.constraint(equalTo: track.bottomAnchor),
        ])

        applyDestination(.terminals)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    private func buildLevel2() -> NSView {
        navRows = WorkspaceDestination.allCases.map { destination in
            let row = WorkspaceNavRowView(destination: destination)
            row.onPress = { [weak self] in
                self?.applyDestination(destination)
                self?.onSelectDestination?(destination)
            }
            return row
        }

        outline.translatesAutoresizingMaskIntoConstraints = false
        outlineContainer.translatesAutoresizingMaskIntoConstraints = false
        outlineContainer.addSubview(outline)
        NSLayoutConstraint.activate([
            // Indented under Terminals, exactly as the design nests the
            // sessions tree beneath its own nav row.
            outline.leadingAnchor.constraint(equalTo: outlineContainer.leadingAnchor, constant: 18),
            outline.trailingAnchor.constraint(equalTo: outlineContainer.trailingAnchor),
            outline.topAnchor.constraint(equalTo: outlineContainer.topAnchor),
            outline.bottomAnchor.constraint(equalTo: outlineContainer.bottomAnchor),
        ])

        navStack.orientation = .vertical
        navStack.alignment = .leading
        navStack.spacing = 2
        navStack.edgeInsets = NSEdgeInsets(top: 0, left: 7, bottom: 8, right: 7)
        navStack.translatesAutoresizingMaskIntoConstraints = false

        navStack.addArrangedSubview(backRow)
        // The design's order: Dashboard, Board, Terminals, [sessions tree],
        // Files — the tree hangs off Terminals, so it sits between them.
        for row in navRows {
            navStack.addArrangedSubview(row)
            if row.destination == .terminals { navStack.addArrangedSubview(outlineContainer) }
        }
        navStack.addArrangedSubview(spacer)

        // The tree absorbs the slack when it is visible; the spacer does when
        // it is not, so the nav rows never stretch.
        outlineContainer.setContentHuggingPriority(.init(1), for: .vertical)
        spacer.setContentHuggingPriority(.init(1), for: .vertical)

        let container = NSView()
        container.addSubview(navStack)
        NSLayoutConstraint.activate([
            navStack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            navStack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            navStack.topAnchor.constraint(equalTo: container.topAnchor),
            navStack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        for view in [backRow, outlineContainer, spacer] + navRows {
            view.widthAnchor.constraint(equalTo: navStack.widthAnchor, constant: -14).isActive = true
        }
        return container
    }

    // MARK: Slide

    override func layout() {
        // Re-derived rather than remembered: the sidebar is user-resizable,
        // and a stale constant would leave the track half a level over.
        //
        // **Before** `super.layout()`, not after: the constant has to be in
        // place for the pass that is about to run, or the new width lands one
        // pass late and a drag of the split divider drags Level 2 off-screen
        // behind it. It settles because the second pass computes the same
        // value and stops marking the view dirty.
        trackLeading.constant = isShowingPicker ? 0 : -bounds.width
        super.layout()
    }

    func showPicker(animated: Bool = true) {
        guard !isShowingPicker else { return }
        isShowingPicker = true
        slide(to: 0, animated: animated)
    }

    /// Opens a workspace: names it on the back row and slides to its nav.
    func showWorkspace(_ workspace: BrainProjectSummary?, animated: Bool = true) {
        selectedWorkspace = workspace
        backRow.apply(workspace: workspace)
        guard workspace != nil else {
            // Nothing to show a nav for — the picker is the only honest state,
            // and it is also exactly the first-run screen the design draws.
            if !isShowingPicker {
                isShowingPicker = true
                slide(to: 0, animated: animated)
            }
            return
        }
        guard isShowingPicker else { return }
        isShowingPicker = false
        slide(to: -bounds.width, animated: animated)
    }

    private func slide(to constant: CGFloat, animated: Bool) {
        guard animated, !ShellMotion.reduced else {
            trackLeading.constant = constant
            layoutSubtreeIfNeeded()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = ShellMotion.duration
            context.timingFunction = ShellMotion.timing
            context.allowsImplicitAnimation = true
            trackLeading.animator().constant = constant
            layoutSubtreeIfNeeded()
        }
    }

    // MARK: Content

    func setWorkspaces(_ workspaces: [BrainProjectSummary], sessionCounts: [String: Int]) {
        picker.setWorkspaces(workspaces, sessionCounts: sessionCounts)
    }

    func applyDestination(_ destination: WorkspaceDestination) {
        self.destination = destination
        for row in navRows { row.apply(selected: row.destination == destination) }
        let showTree = destination == .terminals
        navStack.setVisibilityPriority(showTree ? .mustHold : .notVisible, for: outlineContainer)
        navStack.setVisibilityPriority(showTree ? .notVisible : .mustHold, for: spacer)
    }

    /// The badge on Terminals — how many sessions the open workspace has.
    func setSessionCount(_ count: Int) {
        navRows.first { $0.destination == .terminals }?.setCount(count)
    }
}

// MARK: - Placeholder content

/// What Dashboard, Board and Files show in step 1.
final class WorkspacePlaceholderView: NSView {
    private let title = NSTextField(labelWithString: "")
    private let hint = NSTextField(labelWithString: "Coming in a later step.")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = ShellPalette.content.cgColor

        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.textColor = ShellPalette.inkDim
        title.alignment = .center

        hint.font = .systemFont(ofSize: 11.5)
        hint.textColor = ShellPalette.inkFaint
        hint.alignment = .center

        let stack = NSStackView(views: [title, hint])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    func show(_ destination: WorkspaceDestination) {
        title.stringValue = destination.title
    }
}
