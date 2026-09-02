import AppKit

// The Workspaces tree — the body of the 2026-08-20 flat sidebar
// (docs/superpowers/specs/2026-08-20-copilot-nav-redesign-design.md §2):
// every workspace as a disclosure row with its sessions inline beneath it.
// Sessions are the leaves; pane rows are gone from the sidebar entirely.
// `SessionRowView` and the shared row/glyph vocabulary stay in
// `WorkspaceShell.swift` — this file is the tree and the two row kinds the
// redesign added.

/// One workspace and the sessions inside it — the tree's own input shape.
/// Assembled by `NavigationSidebarView` from the brain's project list *and*
/// the live pane descriptors, so a workspace shows up whether or not it has
/// panes, and a folder opened directly shows up whether or not the brain has
/// heard of it.
struct WorkspaceTreeEntry: Equatable {
    let id: String
    let label: String
    let sessions: [SessionGroupNode]
    /// The customization's folder colour, already resolved to a tint —
    /// `nil` keeps `ShellPalette.folderGlyph`.
    let tint: NSColor?

    init(
        id: String,
        label: String,
        sessions: [SessionGroupNode],
        tint: NSColor? = nil
    ) {
        self.id = id
        self.label = label
        self.sessions = sessions
        self.tint = tint
    }
}

/// A workspace row: disclosure chevron, folder icon (the open variant while
/// expanded), display name. Pressing it folds — selection belongs to the
/// session rows underneath.
final class WorkspaceRowView: ShellRowView {
    let workspaceID: String
    private(set) var isExpanded: Bool
    /// Held so the fold state is a fact a test can read off the icon.
    private(set) var folderGlyph: ShellGlyphView
    private let chevron: ShellGlyphView
    private let titleField: NSTextField
    /// The row's context menu, built fresh per right-click by whoever can
    /// resolve the workspace — the menu reads live state (the GitHub
    /// remote, the stored customization) this row never holds.
    var onContextMenu: (() -> NSMenu?)?

    /// What the row prints — the customization's display name when one is
    /// stored.
    var titleText: String { titleField.stringValue }

    init(
        id: String,
        label: String,
        expanded: Bool,
        tint: NSColor? = nil
    ) {
        workspaceID = id
        isExpanded = expanded
        chevron = ShellGlyphView(.chevronRight, color: ShellPalette.chevron, size: 15, lineWidth: 1.8)
        folderGlyph = ShellGlyphView(
            expanded ? .folderOpen : .folder,
            color: tint ?? ShellPalette.folderGlyph,
            size: 17,
            lineWidth: 1.1
        )
        titleField = ShellFont.label(
            label,
            font: ShellFont.ui(13.5, .semibold),
            color: ShellPalette.inkFolder
        )
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous
        chevron.rotated = expanded

        for view in [chevron, folderGlyph, titleField] { addSubview(view) }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 28),

            chevron.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),

            folderGlyph.leadingAnchor.constraint(equalTo: chevron.trailingAnchor, constant: 3),
            folderGlyph.centerYAnchor.constraint(equalTo: centerYAnchor),

            titleField.leadingAnchor.constraint(equalTo: folderGlyph.trailingAnchor, constant: 6),
            titleField.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setAccessibilityLabel("Workspace \(label)")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func menu(for event: NSEvent) -> NSMenu? {
        onContextMenu?() ?? super.menu(for: event)
    }
}

/// The dim placeholder under an expanded workspace that has nothing running.
final class WorkspaceEmptyRowView: NSView {
    private let titleField = ShellFont.label(
        "No sessions yet",
        font: ShellFont.ui(13),
        color: ShellPalette.inkFaint
    )

    var title: String { titleField.stringValue }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleField)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 24),
            titleField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 46),
            titleField.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("No sessions yet")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
}

/// A Status-mode bucket header — "Needs attention" / "Working" / "Idle".
/// The section-header voice, sitting directly over the session rows it
/// groups where a workspace row would otherwise be.
final class WorkspacesBucketHeaderView: NSView {
    private let titleField: NSTextField

    var title: String { titleField.stringValue }

    init(title: String) {
        titleField = ShellFont.label(
            title,
            font: ShellFont.ui(11, .semibold),
            color: ShellPalette.inkMuted,
            tracking: 0.4
        )
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleField)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 24),
            titleField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            titleField.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            titleField.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(title)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
}

/// The small tree connector a nested session row wears: a hairline dropping
/// from the row above's rail into an elbow that points at this row's own
/// content. Spans from the row's top edge down to its vertical centre, so
/// the elbow lands exactly beside the name.
final class SessionRowConnectorView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath()
        // Not flipped: the view's bottom edge sits at the row's centre.
        path.move(to: NSPoint(x: 0.5, y: bounds.maxY))
        path.line(to: NSPoint(x: 0.5, y: 0.5))
        path.line(to: NSPoint(x: bounds.maxX, y: 0.5))
        path.lineWidth = 1
        ShellPalette.dashedStroke.setStroke()
        path.stroke()
    }
}

/// The tree itself, in whichever of the header's three shapes is chosen:
/// Project (workspace rows, each expanding to its session rows or the dim
/// empty row), Status (sessions bucketed under Needs attention / Working /
/// Idle headers), or Last updated (a flat most-recent-event-first list).
/// Selection, rename and the hover card all ride on the session rows; the
/// workspace rows only fold.
final class WorkspacesTreeView: NSView {
    var onSelectSession: ((SessionGroupNode) -> Void)?
    var onRenameSession: ((SessionGroupNode, String) -> Void)?
    /// The pointer resting on a session row, or leaving one (`nil`) — what
    /// raises the hover card.
    var onHoverTarget: ((SessionHoverCardController.Target?) -> Void)?
    /// A workspace row's right-click: whoever mounts the tree answers with
    /// the row's context menu, built fresh so it reads live state.
    var workspaceMenuProvider: ((String) -> NSMenu?)?
    /// A session row's right-click, same contract: the menu reads live state
    /// (the pin, the installed apps) the row never holds.
    var sessionMenuProvider: ((SessionGroupNode) -> NSMenu?)?

    /// Collapsed workspace ids, persisted so the fold survives a relaunch.
    /// Stored inverted — absent means expanded — so a brand new workspace
    /// opens showing its sessions without anyone having to opt in.
    static let collapsedDefaultsKey = "OmniAgentWorkspacesTreeCollapsed"
    /// The header's group-by choice, persisted by raw value. Absent means
    /// `.project` — the spec's default.
    static let groupModeDefaultsKey = "OmniAgentWorkspacesGroupBy"

    private let defaults: UserDefaults
    private var collapsed: Set<String>
    /// Which of the three shapes renders. `setGroupMode` is the only writer.
    private(set) var groupMode: WorkspacesGroupMode
    private let rows = NSStackView()
    /// What the last `reload` actually drew, so a test can assert the tree's
    /// shape without walking the stack view.
    private(set) var renderedWorkspaceIDs: [String] = []
    /// The session rows on screen, in order — collapsed workspaces contribute
    /// nothing.
    private(set) var renderedSessionIDs: [String] = []
    /// The Status-mode bucket headers on screen, in order — empty in the
    /// other two modes.
    private(set) var renderedBucketTitles: [String] = []

    /// What `reload` was last handed, so toggling a disclosure or switching
    /// the group mode can re-render without the controller having to push the
    /// whole tree again.
    private struct Render {
        var entries: [WorkspaceTreeEntry] = []
        var focusedPaneID: String?
        var statuses: [String: RemoteSessionStatus] = [:]
        var eventTimes: [String: Double] = [:]
        var meta: [String: SessionMeta] = [:]
    }

    private var lastRender = Render()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        collapsed = Set(defaults.stringArray(forKey: Self.collapsedDefaultsKey) ?? [])
        groupMode = defaults.string(forKey: Self.groupModeDefaultsKey)
            .flatMap(WorkspacesGroupMode.init(rawValue:)) ?? .project
        super.init(frame: .zero)

        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 1
        rows.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 6, right: 8)
        rows.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rows)
        NSLayoutConstraint.activate([
            rows.leadingAnchor.constraint(equalTo: leadingAnchor),
            rows.trailingAnchor.constraint(equalTo: trailingAnchor),
            rows.topAnchor.constraint(equalTo: topAnchor),
            rows.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func reload(
        entries: [WorkspaceTreeEntry],
        focusedPaneID: String?,
        statuses: [String: RemoteSessionStatus],
        eventTimes: [String: Double] = [:],
        meta: [String: SessionMeta] = [:]
    ) {
        lastRender = Render(
            entries: entries,
            focusedPaneID: focusedPaneID,
            statuses: statuses,
            eventTimes: eventTimes,
            meta: meta
        )
        renderedWorkspaceIDs = []
        renderedSessionIDs = []
        renderedBucketTitles = []

        for view in rows.arrangedSubviews {
            rows.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        switch groupMode {
        case .project: renderProjectTree(entries)
        case .status: renderStatusBuckets(entries)
        case .lastUpdated: renderLastUpdated(entries)
        }
    }

    /// The header's group-by choice. Persists, then re-renders on the spot
    /// from what the last `reload` handed over — the controller does not have
    /// to know the shape changed.
    func setGroupMode(_ mode: WorkspacesGroupMode) {
        guard mode != groupMode else { return }
        groupMode = mode
        defaults.set(mode.rawValue, forKey: Self.groupModeDefaultsKey)
        rerender()
    }

    /// Project mode: the workspace tree, sessions inline under their
    /// disclosure rows.
    private func renderProjectTree(_ entries: [WorkspaceTreeEntry]) {
        renderedWorkspaceIDs = entries.map(\.id)
        for entry in entries {
            let expanded = !collapsed.contains(entry.id)
            let workspaceRow = WorkspaceRowView(
                id: entry.id,
                label: entry.label,
                expanded: expanded,
                tint: entry.tint
            )
            workspaceRow.onPress = { [weak self] in self?.toggle(entry.id) }
            workspaceRow.onContextMenu = { [weak self] in self?.workspaceMenuProvider?(entry.id) }
            add(workspaceRow)

            guard expanded else { continue }
            if entry.sessions.isEmpty {
                add(WorkspaceEmptyRowView())
                continue
            }
            // Pinned first, nested under their parent — the session-meta
            // arrangement, applied per workspace.
            for (session, nested) in SessionMeta.arrange(entry.sessions, meta: lastRender.meta) {
                addSessionRow(session, nested: nested, workspaceLabel: entry.label)
            }
        }
    }

    /// Status mode: every session, bucketed under Needs attention / Working /
    /// Idle. Workspace rows (and the fold) sit this mode out.
    private func renderStatusBuckets(_ entries: [WorkspaceTreeEntry]) {
        let buckets = WorkspacesGrouping.statusBuckets(
            entries.flatMap(\.sessions),
            statuses: lastRender.statuses
        )
        for bucket in buckets {
            renderedBucketTitles.append(bucket.title)
            add(WorkspacesBucketHeaderView(title: bucket.title))
            for session in bucket.sessions { addSessionRow(session) }
        }
    }

    /// Last-updated mode: one flat list, most recent status event first.
    private func renderLastUpdated(_ entries: [WorkspaceTreeEntry]) {
        let sessions = WorkspacesGrouping.lastUpdatedFirst(
            entries.flatMap(\.sessions),
            eventTimes: lastRender.eventTimes
        )
        for session in sessions { addSessionRow(session) }
    }

    /// One session row.
    private func addSessionRow(
        _ session: SessionGroupNode,
        nested: Bool = false,
        workspaceLabel: String? = nil
    ) {
        renderedSessionIDs.append(session.id)
        let row = SessionRowView(
            session: session,
            statuses: session.paneIDs.map { lastRender.statuses[$0] },
            // The focused pane's ask is on screen already — it counts as
            // seen, the same rule the pane's approval bar applies.
            awaitingCount: session.paneIDs
                .filter {
                    lastRender.statuses[$0] == .awaitingApproval && $0 != lastRender.focusedPaneID
                }
                .count,
            nested: nested,
            workspaceName: nested ? workspaceLabel : nil,
            // The rail wears the workspace's folder colour; looked up here so
            // the Status and Last-updated modes get it too, not just the tree.
            tint: lastRender.entries.first { $0.id == session.project }?.tint
        )
        row.onPress = { [weak self] in self?.onSelectSession?(session) }
        row.onRename = { [weak self] name in self?.onRenameSession?(session, name) }
        row.onHover = { [weak self] inside in
            self?.onHoverTarget?(inside ? .session(session.id) : nil)
        }
        row.onContextMenu = { [weak self] in self?.sessionMenuProvider?(session) }
        add(row)
    }

    private func add(_ row: NSView) {
        rows.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: rows.widthAnchor, constant: -16).isActive = true
    }

    private func rerender() {
        reload(
            entries: lastRender.entries,
            focusedPaneID: lastRender.focusedPaneID,
            statuses: lastRender.statuses,
            eventTimes: lastRender.eventTimes,
            meta: lastRender.meta
        )
    }

    private func toggle(_ workspaceID: String) {
        if collapsed.contains(workspaceID) {
            collapsed.remove(workspaceID)
        } else {
            collapsed.insert(workspaceID)
        }
        defaults.set(collapsed.sorted(), forKey: Self.collapsedDefaultsKey)
        rerender()
    }

    /// The row a hover target names, in whatever the last `reload` built.
    /// Looked up by id rather than remembered, because every status event
    /// throws these rows away and makes new ones — a card holding the view it
    /// opened over would be pointing at a corpse a second later. Pane targets
    /// answer `nil`: the tree has no pane rows any more.
    func rowView(for target: SessionHoverCardController.Target) -> NSView? {
        guard case .session(let id) = target else { return nil }
        return rows.arrangedSubviews.first { ($0 as? SessionRowView)?.session.id == id }
    }
}
