import Foundation

/// What running a palette row does. A closed set rather than a closure, so
/// the list is comparable in a test and the window controller stays the only
/// thing that knows how to perform any of it.
enum PaletteAction: Equatable {
    case focusPane(sessionID: String)
    case closePane(sessionID: String)
    case newPane
    case newSession
    case interruptFocusedPane
    case reattachFocusedPane
    case toggleSidebar
    case clearNotifications
    /// Runs `SessionConnection.search` for the current query (Task 6a-2 —
    /// the row Task 6b-1 promised would "come back when the query does").
    case searchBrain(query: String)
    /// One brain-search hit, selected — opens the inspector on the hit's
    /// project, the closest real "go look at this" action available without
    /// a map/graph view.
    case revealProjectContext(project: String)
    /// An informational row with nothing to run ("No matches…") — a
    /// no-op rather than reusing an unrelated action for "does nothing".
    case noop
}

/// One row.
struct PaletteCommand: Equatable {
    let id: String
    let title: String
    /// The right-aligned hint — an engine name, a key equivalent.
    let detail: String?
    let action: PaletteAction
}

/// The ⌘K palette's contents and filtering — the native port of
/// `ui/src/components/CommandPalette.tsx`'s action list.
///
/// **Brain search.** Task 6a-2 routed `search_brain` through the daemon, so
/// the row Task 6b-1 deliberately left out ("it comes back when the query
/// does") is back: `matches` appends a synthetic "Search brain for …" row
/// whenever the query is non-empty. Running it is `WorkspaceWindowController`'s
/// job (same split every other action already has) — this model only ever
/// describes the row, never calls `SessionConnection.search` itself.
struct CommandPaletteModel: Equatable {
    private(set) var commands: [PaletteCommand]
    private(set) var query = ""
    private(set) var selectedIndex = 0

    init(commands: [PaletteCommand] = []) {
        self.commands = commands
    }

    /// Rebuilt from the live workspace every time the palette opens, so it
    /// can never offer a pane that closed while it was shut.
    static func build(
        panes: [PaneDescriptor],
        paneOrder: [String],
        focusedPaneID: String?,
        unreadNotifications: Int,
        nextSessionName: String? = nil,
        projectLabels: [String: String] = [:]
    ) -> [PaletteCommand] {
        // `uniquingKeysWith:` rather than `uniqueKeysWithValues:`, matching
        // the already-fixed call site in `WorkspaceWindowController`'s
        // `projectLabels`: the trapping initializer crashes the app outright
        // on a duplicate key. Pane ids are unique upstream so this is
        // unreachable today, but opening the command palette should not be
        // able to take the app down if that ever stops being true.
        let byID = Dictionary(panes.map { ($0.sessionID, $0) }, uniquingKeysWith: { _, newest in newest })
        let ordered = paneOrder.compactMap { byID[$0] }
        let tree = SessionOutline.group(ordered, focusedPaneID: focusedPaneID)

        var commands: [PaletteCommand] = []
        for project in tree {
            for session in project.sessions {
                for paneID in session.paneIDs {
                    guard let pane = byID[paneID] else { continue }
                    commands.append(
                        PaletteCommand(
                            id: "focus:\(paneID)",
                            title: "Switch to \(SessionOutline.projectLabel(project.project, labels: projectLabels)) — \(session.label) — \(SessionOutline.paneLabel(pane))",
                            detail: pane.engine.rawValue,
                            action: .focusPane(sessionID: paneID)
                        )
                    )
                }
            }
        }
        commands.append(
            PaletteCommand(id: "new-pane", title: "New terminal pane", detail: "⌘T", action: .newPane)
        )
        commands.append(
            PaletteCommand(
                id: "new-session",
                title: "New session\(nextSessionName.map { " — \($0)" } ?? "")",
                detail: "⌘N",
                action: .newSession
            )
        )
        if let focusedPaneID, let pane = byID[focusedPaneID] {
            let name = SessionOutline.paneLabel(pane)
            commands.append(
                PaletteCommand(
                    id: "close-pane",
                    title: "Close pane \(name)",
                    detail: "⌘W",
                    action: .closePane(sessionID: focusedPaneID)
                )
            )
            // Interrupt and reattach are PTY verbs; a non-terminal pane can
            // be closed but has no session to signal or reattach.
            if pane.kind == .terminal {
                commands.append(
                    PaletteCommand(id: "interrupt", title: "Interrupt \(name)", detail: "⌘.", action: .interruptFocusedPane)
                )
                commands.append(
                    PaletteCommand(id: "reattach", title: "Reattach \(name)", detail: "⌘R", action: .reattachFocusedPane)
                )
            }
        }
        commands.append(
            PaletteCommand(id: "toggle-sidebar", title: "Toggle sidebar", detail: "⌃⌘S", action: .toggleSidebar)
        )
        if unreadNotifications > 0 {
            commands.append(
                PaletteCommand(
                    id: "clear-notifications",
                    title: "Clear notifications",
                    detail: "\(unreadNotifications) unread",
                    action: .clearNotifications
                )
            )
        }
        return commands
    }

    /// Case-insensitive substring on the row's title, order preserved — the
    /// same match the web palette does, deliberately not a fuzzy score: the
    /// list is short and stable ordering is what makes muscle memory work.
    ///
    /// A non-empty query also appends a trailing "Search brain for …" row —
    /// present whenever there is something to search for, exactly like the
    /// web palette's own always-offered search row, regardless of whether
    /// any action also matched.
    var matches: [PaletteCommand] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return commands }
        let needle = trimmed.lowercased()
        var rows = commands.filter { $0.title.lowercased().contains(needle) }
        rows.append(
            PaletteCommand(
                id: "search-brain",
                title: "Search brain for \u{201C}\(trimmed)\u{201D}",
                detail: nil,
                action: .searchBrain(query: trimmed)
            )
        )
        return rows
    }

    var selected: PaletteCommand? {
        let rows = matches
        guard rows.indices.contains(selectedIndex) else { return nil }
        return rows[selectedIndex]
    }

    mutating func reset(commands: [PaletteCommand]) {
        self.commands = commands
        query = ""
        selectedIndex = 0
    }

    /// Typing always returns the highlight to the top: the best match for a
    /// new query is never "wherever the cursor happened to be".
    mutating func update(query: String) {
        self.query = query
        selectedIndex = 0
    }

    /// Clamped rather than wrapping — ⌄ at the bottom of a list is a
    /// no-op, not a jump back to the top.
    mutating func moveSelection(by delta: Int) {
        let count = matches.count
        guard count > 0 else {
            selectedIndex = 0
            return
        }
        selectedIndex = min(max(0, selectedIndex + delta), count - 1)
    }

    mutating func select(index: Int) {
        guard matches.indices.contains(index) else { return }
        selectedIndex = index
    }
}
