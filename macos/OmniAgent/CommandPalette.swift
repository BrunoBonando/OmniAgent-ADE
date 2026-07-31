import Foundation

/// What running a palette row does. A closed set rather than a closure, so
/// the list is comparable in a test and the window controller stays the only
/// thing that knows how to perform any of it.
enum PaletteAction: Equatable {
    case focusPane(sessionID: String)
    case closePane(sessionID: String)
    case newPane
    case interruptFocusedPane
    case reattachFocusedPane
    case toggleSidebar
    case clearNotifications
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
/// **No brain search.** The web palette's third section calls `search_brain`,
/// which Task 6a deliberately did not route through the daemon; a row that
/// opened an empty result list would be the dead UI this codebase refuses.
/// The row comes back when the query does.
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
        unreadNotifications: Int
    ) -> [PaletteCommand] {
        let byID = Dictionary(uniqueKeysWithValues: panes.map { ($0.sessionID, $0) })
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
                            title: "Switch to \(SessionOutline.projectLabel(project.project)) — \(session.label) — \(SessionOutline.paneLabel(pane))",
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
            commands.append(
                PaletteCommand(id: "interrupt", title: "Interrupt \(name)", detail: "⌘.", action: .interruptFocusedPane)
            )
            commands.append(
                PaletteCommand(id: "reattach", title: "Reattach \(name)", detail: "⌘R", action: .reattachFocusedPane)
            )
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
    var matches: [PaletteCommand] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return commands }
        return commands.filter { $0.title.lowercased().contains(needle) }
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
