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

    init(id: String, label: String, expanded: Bool) {
        workspaceID = id
        isExpanded = expanded
        chevron = ShellGlyphView(.chevronRight, color: ShellPalette.chevron, size: 15, lineWidth: 1.8)
        folderGlyph = ShellGlyphView(
            expanded ? .folderOpen : .folder,
            color: ShellPalette.folderGlyph,
            size: 17,
            lineWidth: 1.1
        )
        let titleField = ShellFont.label(
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
            titleField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setAccessibilityLabel("Workspace \(label)")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
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
            titleField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 30),
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

/// The tree itself: workspace rows, each expanding to its session rows (or
/// the dim empty row). Selection, rename and the hover card all ride on the
/// session rows; the workspace rows only fold.
final class WorkspacesTreeView: NSView {
    var onSelectSession: ((SessionGroupNode) -> Void)?
    var onRenameSession: ((SessionGroupNode, String) -> Void)?
    /// The pointer resting on a session row, or leaving one (`nil`) — what
    /// raises the hover card.
    var onHoverTarget: ((SessionHoverCardController.Target?) -> Void)?

    /// Collapsed workspace ids, persisted so the fold survives a relaunch.
    /// Stored inverted — absent means expanded — so a brand new workspace
    /// opens showing its sessions without anyone having to opt in.
    static let collapsedDefaultsKey = "OmniAgentWorkspacesTreeCollapsed"

    private let defaults: UserDefaults
    private var collapsed: Set<String>
    private let rows = NSStackView()
    /// What the last `reload` actually drew, so a test can assert the tree's
    /// shape without walking the stack view.
    private(set) var renderedWorkspaceIDs: [String] = []
    /// The session rows on screen, in order — collapsed workspaces contribute
    /// nothing.
    private(set) var renderedSessionIDs: [String] = []

    /// What `reload` was last handed, so toggling a disclosure can re-render
    /// without the controller having to push the whole tree again.
    private struct Render {
        var entries: [WorkspaceTreeEntry] = []
        var focusedPaneID: String?
        var statuses: [String: RemoteSessionStatus] = [:]
    }

    private var lastRender = Render()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        collapsed = Set(defaults.stringArray(forKey: Self.collapsedDefaultsKey) ?? [])
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
        statuses: [String: RemoteSessionStatus]
    ) {
        lastRender = Render(entries: entries, focusedPaneID: focusedPaneID, statuses: statuses)
        renderedWorkspaceIDs = entries.map(\.id)
        renderedSessionIDs = []

        for view in rows.arrangedSubviews {
            rows.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        for entry in entries {
            let expanded = !collapsed.contains(entry.id)
            let workspaceRow = WorkspaceRowView(id: entry.id, label: entry.label, expanded: expanded)
            workspaceRow.onPress = { [weak self] in self?.toggle(entry.id) }
            add(workspaceRow)

            guard expanded else { continue }
            if entry.sessions.isEmpty {
                add(WorkspaceEmptyRowView())
                continue
            }
            for session in entry.sessions {
                renderedSessionIDs.append(session.id)
                let row = SessionRowView(
                    session: session,
                    statuses: session.paneIDs.map { statuses[$0] },
                    // The focused pane's ask is on screen already — it counts
                    // as seen, the same rule the pane's approval bar applies.
                    awaitingCount: session.paneIDs
                        .filter { statuses[$0] == .awaitingApproval && $0 != focusedPaneID }
                        .count
                )
                row.onPress = { [weak self] in self?.onSelectSession?(session) }
                row.onRename = { [weak self] name in self?.onRenameSession?(session, name) }
                row.onHover = { [weak self] inside in
                    self?.onHoverTarget?(inside ? .session(session.id) : nil)
                }
                add(row)
            }
        }
    }

    private func add(_ row: NSView) {
        rows.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: rows.widthAnchor, constant: -16).isActive = true
    }

    private func toggle(_ workspaceID: String) {
        if collapsed.contains(workspaceID) {
            collapsed.remove(workspaceID)
        } else {
            collapsed.insert(workspaceID)
        }
        defaults.set(collapsed.sorted(), forKey: Self.collapsedDefaultsKey)
        reload(
            entries: lastRender.entries,
            focusedPaneID: lastRender.focusedPaneID,
            statuses: lastRender.statuses
        )
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
