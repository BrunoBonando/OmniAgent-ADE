import Foundation

/// One session — a set of panes inside one project, created together with
/// their own layout and their own working directory. The native port of
/// `ui/src/state/sessionGroups.ts`'s `SessionGroup`.
struct SessionGroupNode: Equatable {
    /// `PaneDescriptor.group`, or `WorkspaceRestoration.ungroupedSessionID`.
    let id: String
    let project: String
    /// The name actually stored on the panes, or `nil` for a session nobody
    /// has named (a pre-naming layout, or the implicit ungrouped session).
    let name: String?
    /// What to print: the stored `name`, else a derived `Session N`.
    let label: String
    /// The session's own root — the cwd of its **first** pane. A session is
    /// created with one cwd and its panes normally agree; they can drift, so
    /// this picks the first rather than pretending there is no single answer.
    let cwd: String
    let paneIDs: [String]
    /// Contains the focused pane — the session that is "currently on the
    /// screen".
    let isCurrent: Bool
}

/// One project and the sessions inside it.
struct ProjectSessionsNode: Equatable {
    let project: String
    let sessions: [SessionGroupNode]
}

/// The workspace -> session -> pane tree the outline renders, derived purely
/// from the pane descriptors. A direct port of
/// `ui/src/state/sessionGroups.ts`.
///
/// There is no second collection to keep in sync — restore the panes and the
/// grouping comes back with them, which is what keeps restoration honest.
enum SessionOutline {
    /// Panes grouped project -> session -> panes. Both levels keep first-seen
    /// order, so a new pane in a known session never re-sorts anything.
    static func group(_ panes: [PaneDescriptor], focusedPaneID: String?) -> [ProjectSessionsNode] {
        var projectOrder: [String] = []
        var groupOrder: [String: [String]] = [:]
        var groups: [String: [String: [PaneDescriptor]]] = [:]

        for pane in panes {
            if groups[pane.project] == nil {
                groups[pane.project] = [:]
                groupOrder[pane.project] = []
                projectOrder.append(pane.project)
            }
            if groups[pane.project]?[pane.group] == nil {
                groups[pane.project]?[pane.group] = []
                groupOrder[pane.project]?.append(pane.group)
            }
            groups[pane.project]?[pane.group]?.append(pane)
        }

        return projectOrder.map { project in
            let order = groupOrder[project] ?? []
            // Two passes: a derived default must never collide with a name
            // actually stored somewhere in this project, so collect the real
            // names first and hand the leftovers the lowest free number.
            let names = order.map { storedName(groups[project]?[$0] ?? []) }
            var taken = Set(names.compactMap { $0 })
            let sessions = zip(order, names).map { id, name -> SessionGroupNode in
                let sessionPanes = groups[project]?[id] ?? []
                var label = name
                if label == nil {
                    label = defaultSessionName(lowestFreeSessionNumber(taken))
                    taken.insert(label!)
                }
                return SessionGroupNode(
                    id: id,
                    project: project,
                    name: name,
                    label: label ?? "",
                    cwd: sessionPanes.first?.cwd ?? "",
                    paneIDs: sessionPanes.map(\.sessionID),
                    isCurrent: focusedPaneID != nil && sessionPanes.contains { $0.sessionID == focusedPaneID }
                )
            }
            return ProjectSessionsNode(project: project, sessions: sessions)
        }
    }

    /// The name stored on a session's panes: the first non-empty `groupLabel`.
    /// Renaming writes it onto every pane, so they normally agree; taking the
    /// first keeps a half-written group readable instead of blank.
    private static func storedName(_ panes: [PaneDescriptor]) -> String? {
        for pane in panes {
            if let name = pane.groupLabel?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                return name
            }
        }
        return nil
    }

    static func defaultSessionName(_ n: Int) -> String { "Session \(n)" }

    /// A fresh session-group id — the port of `newSessionGroupId`.
    ///
    /// Wall clock plus a process-local counter, so two sessions started in
    /// the same millisecond still differ, in the same
    /// `[A-Za-z0-9_-]{1,96}` shape `SessionIdentifier` accepts: a group id
    /// that could not survive a relaunch would silently un-group its panes on
    /// the next launch.
    static func newSessionGroupID(now: Date = Date()) -> String {
        groupCounter += 1
        return "sess-grp-\(Int(now.timeIntervalSince1970 * 1000))-\(groupCounter)"
    }

    /// Main-thread only, like every other caller in this file.
    private static var groupCounter = 0

    /// **The numbering rule:** the lowest positive integer whose default name
    /// is not already taken by a live session in that project. So sessions
    /// created and closed out of order never collide and never climb forever
    /// — with `Session 1` and `Session 3` open, the next one is `Session 2`.
    /// "Taken" means the name a session *shows*, stored or derived, because
    /// the collision that matters is two rows reading the same.
    private static func lowestFreeSessionNumber(_ taken: Set<String>) -> Int {
        var n = 1
        while taken.contains(defaultSessionName(n)) { n += 1 }
        return n
    }

    /// What to call the session about to be created in `project`.
    static func nextSessionName(_ panes: [PaneDescriptor], project: String) -> String {
        let sessions = group(panes, focusedPaneID: nil)
            .first { $0.project == project }?
            .sessions ?? []
        return defaultSessionName(lowestFreeSessionNumber(Set(sessions.map(\.label))))
    }

    /// What a pane's row says: its own label, else the engine's name — the
    /// port of `ui/src/state/sessions.ts`'s `tabDisplayLabel`.
    static func paneLabel(_ pane: PaneDescriptor) -> String {
        if let label = pane.label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty {
            return label
        }
        if !pane.title.isEmpty { return pane.title }
        return pane.engine.rawValue
    }

    /// What a project row says. The native build has no project *labels* yet
    /// (`list_projects` is a separate read the outline does not make), so an
    /// id is shown as-is and the ungrouped/no-project case is named rather
    /// than shown as an empty row.
    static func projectLabel(_ project: String) -> String {
        project.isEmpty ? "No project" : project
    }
}
