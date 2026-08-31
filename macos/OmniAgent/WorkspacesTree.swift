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
    /// Remote Control is on for this workspace — its row wears the globe
    /// (the remote-session-control spec's §2). Defaulted so every existing
    /// call site keeps compiling and reads "not shared", which is the truth
    /// for a workspace nobody has enabled.
    let remoteControl: Bool
    /// The machines watching a pane of this workspace right now (the phase 2
    /// spec's §5) — the count beside the globe, and the tooltip's list.
    /// Empty is the overwhelmingly common case and wears no badge at all.
    let viewerNames: [String]

    init(
        id: String,
        label: String,
        sessions: [SessionGroupNode],
        tint: NSColor? = nil,
        remoteControl: Bool = false,
        viewerNames: [String] = []
    ) {
        self.id = id
        self.label = label
        self.sessions = sessions
        self.tint = tint
        self.remoteControl = remoteControl
        self.viewerNames = viewerNames
    }
}

/// One online machine and what it shares — the input shape of the sidebar's
/// remote sections (the remote-session-control spec's §4 "Viewer side").
/// Assembled by `WorkspaceWindowController` from `RemoteMachinesModel`'s
/// live device list; the tree renders it after the local rows.
struct RemoteMachineTreeEntry: Equatable {
    let deviceID: String
    let name: String
    let workspaces: [WorkspaceTreeEntry]
}

/// A workspace row: disclosure chevron, folder icon (the open variant while
/// expanded), display name. Pressing it folds — selection belongs to the
/// session rows underneath.
final class WorkspaceRowView: ShellRowView {
    /// What the trailing mark says. `.shared` is this Mac offering the
    /// workspace to other machines (the globe); `.viewing` is a workspace
    /// that lives on *another* Mac and is being watched from here. The glyph
    /// is one of only two things a remote row is allowed to differ by — the
    /// other is where a click goes (the phase-2 spec's §2 "Rendering",
    /// docs/superpowers/specs/2026-08-31-remote-session-control-phase-2-design.md).
    enum RemoteMark: String {
        case shared = "globe"
        case viewing = "desktopcomputer.and.arrow.down"
    }

    let workspaceID: String
    /// Which mark the row wears when it wears one — readable so a test can
    /// tell a shared workspace from a watched one without decoding an image.
    let mark: RemoteMark
    private(set) var isExpanded: Bool
    /// Held so the fold state is a fact a test can read off the icon.
    private(set) var folderGlyph: ShellGlyphView
    private let chevron: ShellGlyphView
    private let titleField: NSTextField
    /// The Remote Control marker, trailing. An `NSImageView` over an SF
    /// Symbol rather than a `ShellGlyphView`: the vocabulary has no globe,
    /// and one drawn by hand would be a lot of bezier for a 16 pt mark.
    /// Held (not conditionally added) so a test can read the fact off the
    /// row the way `folderGlyph` reads the fold.
    private(set) var remoteGlyph: NSImageView
    /// How many other Macs are watching a pane of this workspace, beside the
    /// globe (the phase 2 spec's §5). Hidden at zero, which is nearly always
    /// — presence is news, and a permanent "0" would be noise on every row.
    /// Pressing it is what opens the list; the row itself only folds.
    private(set) var viewerBadge: WorkspaceViewerBadgeView
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
        tint: NSColor? = nil,
        remoteControl: Bool = false,
        mark: RemoteMark = .shared,
        viewerNames: [String] = []
    ) {
        workspaceID = id
        self.mark = mark
        isExpanded = expanded
        chevron = ShellGlyphView(.chevronRight, color: ShellPalette.chevron, size: 15, lineWidth: 1.8)
        viewerBadge = WorkspaceViewerBadgeView(count: viewerNames.count)
        remoteGlyph = NSImageView(
            image: NSImage(
                systemSymbolName: mark.rawValue,
                accessibilityDescription: mark == .shared
                    ? "Remote Control on"
                    : "Shared from another Mac"
            ) ?? NSImage()
        )
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

        remoteGlyph.translatesAutoresizingMaskIntoConstraints = false
        remoteGlyph.contentTintColor = ShellPalette.folderGlyph
        remoteGlyph.isHidden = !remoteControl
        remoteGlyph.toolTip = mark == .shared
            ? "Remote Control is on for this workspace"
            : "This workspace lives on another Mac"

        // Only a workspace *this* Mac shares can be watched — a `.viewing`
        // row is somebody else's workspace, and its viewers are their
        // business, not something this sidebar has a roster for.
        viewerBadge.isHidden = mark != .shared || viewerNames.isEmpty
        viewerBadge.toolTip = viewerNames.isEmpty
            ? nil
            : "Watched by \(viewerNames.joined(separator: ", "))"

        // A stack rather than a chain of constraints: the badge comes and
        // goes with the roster, and `NSStackView` takes a hidden arranged
        // subview out of the layout, so the name reclaims the space instead
        // of stopping short of a badge that is not there.
        let marks = NSStackView(views: [viewerBadge, remoteGlyph])
        marks.orientation = .horizontal
        marks.alignment = .centerY
        marks.spacing = 5
        marks.translatesAutoresizingMaskIntoConstraints = false

        for view in [chevron, folderGlyph, titleField, marks] { addSubview(view) }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 28),

            chevron.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),

            folderGlyph.leadingAnchor.constraint(equalTo: chevron.trailingAnchor, constant: 3),
            folderGlyph.centerYAnchor.constraint(equalTo: centerYAnchor),

            titleField.leadingAnchor.constraint(equalTo: folderGlyph.trailingAnchor, constant: 6),
            // The title stops short of the marks whether or not the globe is
            // shown: a hidden view still holds its frame, so one pair of
            // constraints serves both states and the name never slides under
            // the mark.
            titleField.trailingAnchor.constraint(lessThanOrEqualTo: marks.leadingAnchor, constant: -6),
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor),

            marks.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            marks.centerYAnchor.constraint(equalTo: centerYAnchor),
            remoteGlyph.widthAnchor.constraint(equalToConstant: 16),
            remoteGlyph.heightAnchor.constraint(equalToConstant: 16),
        ])
        titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // VoiceOver keeps the one fact the glyph carries: whose Mac this is.
        setAccessibilityLabel(mark == .shared ? "Workspace \(label)" : "Remote workspace \(label)")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func menu(for event: NSEvent) -> NSMenu? {
        onContextMenu?() ?? super.menu(for: event)
    }
}

/// The "somebody is watching this" mark on a shared workspace row: a screen
/// glyph and the number of machines attached to one of its panes (the phase 2
/// spec's §5 "Host UI").
///
/// A control, not decoration — pressing it opens the list of machines, each
/// with a Disconnect. It takes the click itself so the row underneath does not
/// fold: `WorkspaceRowView` acts on `mouseUp`, and AppKit sends both halves of
/// a click to whichever view took the `mouseDown`.
final class WorkspaceViewerBadgeView: NSView {
    var onPress: (() -> Void)?

    /// What the badge prints — held readable so a test can check the count
    /// without measuring a text field.
    private(set) var countText: String

    private let glyph = NSImageView(
        image: NSImage(systemSymbolName: "display", accessibilityDescription: "Viewers") ?? NSImage()
    )
    private let countField: NSTextField

    init(count: Int) {
        countText = String(count)
        countField = ShellFont.label(
            countText,
            font: ShellFont.ui(11, .semibold),
            color: ShellPalette.accentBright
        )
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = ShellPalette.accentSoft.cgColor

        glyph.translatesAutoresizingMaskIntoConstraints = false
        glyph.contentTintColor = ShellPalette.accentBright

        addSubview(glyph)
        addSubview(countField)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 16),
            glyph.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            glyph.centerYAnchor.constraint(equalTo: centerYAnchor),
            glyph.widthAnchor.constraint(equalToConstant: 11),
            glyph.heightAnchor.constraint(equalToConstant: 11),
            countField.leadingAnchor.constraint(equalTo: glyph.trailingAnchor, constant: 3),
            countField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            countField.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityRole(.button)
        setAccessibilityLabel(count == 1 ? "1 machine watching" : "\(count) machines watching")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func mouseDown(with event: NSEvent) {
        onPress?()
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
    /// A remote session row's click — the machine's device id, the daemon
    /// session id and its title, for `openRemoteSession` on the controller.
    var onOpenRemoteSession: ((_ deviceID: String, _ sessionID: String, _ title: String) -> Void)?
    /// The viewer count on a workspace row was pressed: whoever mounts the
    /// tree opens the list of machines watching it (the phase 2 spec's §5).
    /// Routed up like `workspaceMenuProvider` — the roster lives on the
    /// controller, and the row holds only the names it was drawn with.
    var onShowViewers: ((String) -> Void)?

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
    /// The remote machines the last `reload` drew sections for, in order —
    /// empty while no other Mac is sharing anything.
    private(set) var renderedRemoteMachineNames: [String] = []

    /// What `reload` was last handed, so toggling a disclosure or switching
    /// the group mode can re-render without the controller having to push the
    /// whole tree again.
    private struct Render {
        var entries: [WorkspaceTreeEntry] = []
        var focusedPaneID: String?
        var statuses: [String: RemoteSessionStatus] = [:]
        var eventTimes: [String: Double] = [:]
        var meta: [String: SessionMeta] = [:]
        var remoteMachines: [RemoteMachineTreeEntry] = []
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
        meta: [String: SessionMeta] = [:],
        remoteMachines: [RemoteMachineTreeEntry] = []
    ) {
        lastRender = Render(
            entries: entries,
            focusedPaneID: focusedPaneID,
            statuses: statuses,
            eventTimes: eventTimes,
            meta: meta,
            remoteMachines: remoteMachines
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
        renderRemoteMachines(remoteMachines)
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
                tint: entry.tint,
                remoteControl: entry.remoteControl,
                viewerNames: entry.viewerNames
            )
            workspaceRow.onPress = { [weak self] in self?.toggle(entry.id) }
            workspaceRow.onContextMenu = { [weak self] in self?.workspaceMenuProvider?(entry.id) }
            workspaceRow.viewerBadge.onPress = { [weak self] in self?.onShowViewers?(entry.id) }
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

    /// The remote sections, after whichever local shape is chosen: one
    /// bucket-voice header per machine — "<name> · remote" — then its
    /// projected workspaces, drawn through the *same* rows the local tree
    /// uses. Same disclosure row, same fold, same folder tint, same session
    /// rows with a dot per pane, same empty placeholder: the phase-2 spec's
    /// §2 leaves a remote row exactly two ways to differ — the trailing
    /// glyph, and that a click opens the session on its own machine instead
    /// of selecting one of ours.
    ///
    /// Rendered in every group mode, because another Mac's sessions have no
    /// local status or event times to bucket by. Their order is the host's
    /// and is never re-sorted here: `SessionMeta.arrange` reads *this* Mac's
    /// pins, and applying them to another machine's tree is exactly the
    /// drift the shared projection exists to prevent.
    private func renderRemoteMachines(_ machines: [RemoteMachineTreeEntry]) {
        renderedRemoteMachineNames = machines.map(\.name)
        for machine in machines {
            add(WorkspacesBucketHeaderView(title: "\(machine.name) · remote"))
            for workspace in machine.workspaces {
                // The ids arrive prefixed per machine, so the fold is stored
                // per remote workspace and cannot collide with a local one.
                let expanded = !collapsed.contains(workspace.id)
                let workspaceRow = WorkspaceRowView(
                    id: workspace.id,
                    label: workspace.label,
                    expanded: expanded,
                    tint: workspace.tint,
                    remoteControl: true,
                    mark: .viewing
                )
                workspaceRow.onPress = { [weak self] in self?.toggle(workspace.id) }
                add(workspaceRow)

                guard expanded else { continue }
                if workspace.sessions.isEmpty {
                    // An enabled workspace with nothing running is projected
                    // with no sessions — the host draws the same placeholder.
                    add(WorkspaceEmptyRowView())
                    continue
                }
                for session in workspace.sessions {
                    addSessionRow(
                        session,
                        remote: (deviceID: machine.deviceID, tint: workspace.tint)
                    )
                }
            }
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

    /// One session row. `remote` names the machine a session lives on when it
    /// is not this one: the row itself is identical — same dots, indent,
    /// tint and label — but the press opens the session over that machine's
    /// connection, and the local-only wiring is left off. Rename would write
    /// *this* Mac's session meta for an id that is not ours, and the hover
    /// card reads local statuses and event times; neither is a fact about
    /// the other Mac.
    private func addSessionRow(
        _ session: SessionGroupNode,
        nested: Bool = false,
        workspaceLabel: String? = nil,
        remote: (deviceID: String, tint: NSColor?)? = nil
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
            // A remote session's workspace is not in `entries` at all — its
            // tint is the host's, carried by the projection.
            tint: remote?.tint ?? lastRender.entries.first { $0.id == session.project }?.tint
        )
        if let remote {
            // The attachable id is a pane's, as the projection schema says —
            // and only a *terminal* pane's: an editor or browser id names
            // nothing the daemon has a session behind, so a press on it would
            // open an empty pane that never attaches. A session of nothing
            // but editors still renders, with its dots; it simply has no door
            // in it.
            if let paneID = session.terminalPaneIDs.first {
                row.onPress = { [weak self] in
                    self?.onOpenRemoteSession?(remote.deviceID, paneID, session.label)
                }
            }
        } else {
            row.onPress = { [weak self] in self?.onSelectSession?(session) }
            row.onRename = { [weak self] name in self?.onRenameSession?(session, name) }
            row.onHover = { [weak self] inside in
                self?.onHoverTarget?(inside ? .session(session.id) : nil)
            }
            row.onContextMenu = { [weak self] in self?.sessionMenuProvider?(session) }
        }
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
            meta: lastRender.meta,
            remoteMachines: lastRender.remoteMachines
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

    /// What the viewer popover hangs off — looked up live for `rowView`'s
    /// reason. `nil` in Status and Last-updated mode, which draw no workspace
    /// rows at all; the caller falls back to the tree itself rather than
    /// leaving the click unanswered.
    func viewerBadge(forWorkspace id: String) -> NSView? {
        let row = rows.arrangedSubviews.first { ($0 as? WorkspaceRowView)?.workspaceID == id }
        return (row as? WorkspaceRowView)?.viewerBadge
    }
}

/// The list behind the viewer count: every machine watching this workspace,
/// what it is attached to, how long it has been there, and a Disconnect —
/// the phase 2 spec's §5 "Host UI" popover.
///
/// Plain AppKit in the app's own palette rather than the liquid-glass ask
/// overlay: this is a list you can dismiss by clicking away, not a modal
/// question, and `NSPopover` already supplies the anchoring, the arrow, the
/// dark material and the click-away for free.
final class RemoteViewersView: NSView {
    /// One machine, already resolved: the daemon's roster carries pane *ids*,
    /// and only the window controller can turn those into the titles a person
    /// recognises.
    struct Row: Equatable {
        let viewerID: String
        let machineName: String
        /// RFC 3339, from the daemon.
        let since: String
        let paneTitles: [String]
    }

    static let footer = "Blocked until you turn Remote Control off and on again."

    /// Readable so a test can check the list without walking the stack view.
    private(set) var machineNames: [String] = []
    private(set) var paneLines: [String] = []
    private(set) var disconnectButtons: [NSButton] = []
    var footerText: String { footerField.stringValue }

    private let footerField = ShellFont.label(
        RemoteViewersView.footer,
        font: ShellFont.ui(10.5),
        color: ShellPalette.inkFaint
    )
    private let onDisconnect: (String) -> Void

    init(rows: [Row], now: Date = Date(), onDisconnect: @escaping (String) -> Void) {
        self.onDisconnect = onDisconnect
        super.init(frame: .zero)

        let list = NSStackView()
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 10
        list.translatesAutoresizingMaskIntoConstraints = false

        let heading = ShellFont.label(
            rows.count == 1 ? "1 machine watching" : "\(rows.count) machines watching",
            font: ShellFont.ui(12, .semibold),
            color: ShellPalette.ink
        )
        list.addArrangedSubview(heading)

        for row in rows {
            machineNames.append(row.machineName)
            // "Not attached" rather than an empty line: a viewer that has
            // opened the machine but no session is connected and kickable,
            // and a blank second line would read as a rendering bug.
            let panes = row.paneTitles.isEmpty ? "Not attached" : row.paneTitles.joined(separator: ", ")
            paneLines.append(panes)

            let name = ShellFont.label(
                row.machineName,
                font: ShellFont.ui(12.5, .semibold),
                color: ShellPalette.inkFile
            )
            let connected = Self.connectedText(since: row.since, now: now)
            let where_ = ShellFont.label(
                connected.isEmpty ? panes : "\(panes) · \(connected)",
                font: ShellFont.ui(11),
                color: ShellPalette.inkTertiary
            )
            let text = NSStackView(views: [name, where_])
            text.orientation = .vertical
            text.alignment = .leading
            text.spacing = 1

            let button = NSButton(title: "Disconnect", target: self, action: #selector(disconnect(_:)))
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.font = ShellFont.ui(11, .medium)
            // The viewer id travels on the button rather than in a captured
            // closure, so which machine a press kicks is a fact the button
            // carries and a test can read.
            button.identifier = NSUserInterfaceItemIdentifier(row.viewerID)
            button.setContentHuggingPriority(.required, for: .horizontal)
            disconnectButtons.append(button)

            let line = NSStackView(views: [text, NSView(), button])
            line.orientation = .horizontal
            line.alignment = .centerY
            line.spacing = 12
            line.translatesAutoresizingMaskIntoConstraints = false
            list.addArrangedSubview(line)
            line.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
        }

        list.addArrangedSubview(footerField)

        addSubview(list)
        NSLayoutConstraint.activate([
            list.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            list.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            list.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            list.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 300),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    @objc private func disconnect(_ sender: NSButton) {
        guard let viewerID = sender.identifier?.rawValue else { return }
        onDisconnect(viewerID)
    }

    /// How long a machine has been watching, said plainly. Hand-rolled rather
    /// than `RelativeDateTimeFormatter`, whose output is locale- and
    /// version-dependent — this is one short line beside a machine name, and
    /// a test may as well be able to assert it.
    ///
    /// An unparseable `since` prints nothing at all: a wrong duration is
    /// worse than no duration.
    static func connectedText(since: String, now: Date) -> String {
        guard let start = iso8601.date(from: since) ?? iso8601Fractional.date(from: since) else { return "" }
        let seconds = max(0, now.timeIntervalSince(start))
        if seconds < 60 { return "Just connected" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "\(hours) hr" : "\(hours) hr \(rest) min"
    }

    private static let iso8601 = ISO8601DateFormatter()
    private static let iso8601Fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

/// The popover that carries `RemoteViewersView` — `HomeDropdown.show`'s
/// shape, for its reasons: one retained popover, dark vibrancy over the
/// system's own rounded material, transient dismissal.
enum RemoteViewersPopover {
    private static var current: NSPopover?

    @discardableResult
    static func show(
        rows: [RemoteViewersView.Row],
        from anchor: NSView,
        onDisconnect: @escaping (String) -> Void
    ) -> RemoteViewersView {
        current?.performClose(nil)
        let popover = NSPopover()
        current = popover
        let content = RemoteViewersView(rows: rows, onDisconnect: onDisconnect)
        let controller = NSViewController()
        controller.view = content
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.appearance = NSAppearance(named: .vibrantDark)
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxX)
        return content
    }

    static func dismiss() {
        current?.performClose(nil)
        current = nil
    }

    /// Whether a viewer list is on screen right now — what tells a roster
    /// change whether it has a popover to refresh.
    static var isShown: Bool { current?.isShown == true }
}
