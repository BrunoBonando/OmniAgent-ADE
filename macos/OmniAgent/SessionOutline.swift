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

    static func defaultPaneName(_ engine: Engine, _ n: Int) -> String {
        "\(engine.displayName) \(n)"
    }

    /// The kind-aware placeholder: a browser is not an engine, so it gets its
    /// own `Browser N` ladder rather than wearing the `.shell` its descriptor
    /// happens to carry.
    static func defaultPaneName(_ pane: PaneDescriptor) -> String {
        pane.kind == .browser ? "Browser \(pane.autoNumber)" : defaultPaneName(pane.engine, pane.autoNumber)
    }

    /// Whether a stored label is one this app generated rather than one the
    /// user typed.
    ///
    /// Terminals were briefly *stored* under their generated name, which made
    /// every one of them look hand-named and permanently outrank the summary
    /// the agent reports. Panes carrying those labels are still out there in
    /// saved layouts, so they are recognised and dropped on the way in — a
    /// user who deliberately typed "Claude 2" loses a name they would have got
    /// for free anyway.
    static func isGeneratedPaneName(_ name: String) -> Bool {
        let parts = name.split(separator: " ")
        guard parts.count == 2, Int(parts[1]) != nil else { return false }
        return parts[0] == "Browser" || Engine.allCases.contains { $0.displayName == parts[0] }
    }

    /// The number a new terminal takes in its session — the lowest free one,
    /// so terminals opened and closed out of order never collide and never
    /// climb forever.
    ///
    /// A number, not a name: the name is only a placeholder until the agent
    /// says what it is working on, and storing it would make it permanent.
    static func nextPaneNumber(
        _ panes: [PaneDescriptor],
        group: String,
        engine: Engine,
        kind: PaneKind = .terminal
    ) -> Int {
        // Browsers number their own ladder regardless of engine — the
        // `.shell` a browser descriptor carries is a placeholder, not an
        // identity — while terminals keep numbering per engine.
        let taken = Set(
            panes
                .filter { $0.group == group && $0.kind == kind && (kind == .browser || $0.engine == engine) }
                .map(\.autoNumber)
        )
        var n = 1
        while taken.contains(n) { n += 1 }
        return n
    }

    /// What a terminal is called, in order of who has the better claim:
    ///
    /// 1. **the name the user typed** — nothing outranks it, and nothing
    ///    overwrites it afterwards;
    /// 2. **what the agent says it is doing** — the title the engine reports
    ///    (Claude publishes a summary of the task in flight), which is the
    ///    whole point of showing a name rather than a number;
    /// 3. **a numbered placeholder** — "Claude 2", until the agent has said
    ///    anything. Per session and per engine, so two terminals never read
    ///    the same while they are all still starting up.
    ///
    /// Only (1) is stored. (2) is live and (3) is derived, so a terminal is
    /// never stuck wearing a name it was given before it had anything to say.
    static func paneLabel(_ pane: PaneDescriptor) -> String {
        if let label = pane.label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty {
            return label
        }
        let title = pane.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { return title }
        // A browser with no page title yet still has an address worth
        // showing — the URL is its cwd, and beats a bare `Browser N`.
        if pane.kind == .browser, !pane.browserURL.isEmpty { return pane.browserURL }
        return defaultPaneName(pane)
    }

    /// The status decoration an engine puts in front of the title it reports.
    /// Claude cycles `· ✢ ✳ ✶ ✻ ✽` as its spinner and prefixes `◐` while a
    /// tool is running, so the reported title reads `✳ Fixing the parser` one
    /// frame and `◐ Fixing the parser` the next.
    ///
    /// That is an animation, and a pane header already has one thing that says
    /// "this agent is busy" — the OmniAgent mark beside the name, in the
    /// status colour, the same for every engine. A second one, made of text,
    /// jittering the name it sits in front of, is noise.
    ///
    /// Deliberately an explicit set rather than "strip leading punctuation":
    /// a shell reports `~/src` as its title, and eating that `~` would be a
    /// worse bug than the one this fixes.
    private static let titleDecoration: CharacterSet = {
        var set = CharacterSet.whitespacesAndNewlines
        set.insert(charactersIn: "*\u{00B7}\u{2217}")
        set.insert(charactersIn: "\u{2722}"..."\u{2727}")
        set.insert(charactersIn: "\u{2731}"..."\u{2736}")
        set.insert(charactersIn: "\u{273A}"..."\u{273D}")
        // Circles and arcs — ◐◑◒◓ and the quadrant/clock spinners beside them.
        set.insert(charactersIn: "\u{25CB}"..."\u{25FF}")
        // Braille spinners, the other common CLI idiom.
        set.insert(charactersIn: "\u{2800}"..."\u{28FF}")
        return set
    }()

    /// The reported title with that decoration taken off the front, so a pane
    /// wears the task rather than the spinner frame it arrived with.
    static func sanitizedPaneTitle(_ title: String) -> String {
        let stripped = title.drop { $0.unicodeScalars.allSatisfy(titleDecoration.contains) }
        return String(stripped).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether a reported title says nothing but which engine is running.
    ///
    /// Claude Code writes both `✳ Claude Code` and `✳ <summary>` inside a
    /// single burst of OSC title updates — captured live, five writes in the
    /// same tenth of a second, the brand sometimes last. A pane stores the one
    /// that landed last, so a named terminal kept flipping back to "Claude
    /// Code". Brand-only titles are dropped rather than stored; before any
    /// summary exists the numbered placeholder ("Claude 2") covers it, and it
    /// reads better than the brand anyway.
    static func isEngineBrandTitle(_ title: String) -> Bool {
        Engine.allCases.contains { $0.badgeTitle == title || $0.displayName == title }
    }

    /// What a project row says: the label `listProjects` returned for this
    /// project id, else the id itself (a project the directory hasn't
    /// loaded yet, or one the brain has never heard of), and the
    /// ungrouped/no-project case named rather than shown as an empty row.
    ///
    /// `labels` is the one shared id -> label cache
    /// `WorkspaceWindowController.projectLabels` builds from `listProjects`
    /// — the fix for 6b-1 concern #3 ("project rows show ids, not labels")
    /// is passing that same cache in here, not a second lookup path the
    /// inspector/palette would otherwise need of their own.
    static func projectLabel(_ project: String, labels: [String: String] = [:]) -> String {
        guard !project.isEmpty else { return "No project" }
        return labels[project] ?? project
    }
}
