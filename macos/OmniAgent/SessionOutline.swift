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
    /// **Every** pane of the session, whatever its kind — what the row's
    /// status dots count, so a viewer's row has exactly as many dots as the
    /// host's.
    let paneIDs: [String]
    /// The subset of `paneIDs` that are terminals. Only a terminal has a
    /// daemon session behind it, so it is the only kind a click can open —
    /// on another Mac that is the rule the projection states outright (the
    /// phase-2 spec's §2: editors and browsers are carried for structural
    /// fidelity and are not openable remotely). Left unsaid at a call site
    /// that has no kinds to hand, it is `paneIDs`.
    let terminalPaneIDs: [String]
    /// Contains the focused pane — the session that is "currently on the
    /// screen".
    let isCurrent: Bool

    init(
        id: String,
        project: String,
        name: String?,
        label: String,
        cwd: String,
        paneIDs: [String],
        terminalPaneIDs: [String]? = nil,
        isCurrent: Bool
    ) {
        self.id = id
        self.project = project
        self.name = name
        self.label = label
        self.cwd = cwd
        self.paneIDs = paneIDs
        self.terminalPaneIDs = terminalPaneIDs ?? paneIDs
        self.isCurrent = isCurrent
    }
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
    /// Panes grouped project -> session -> panes. Projects keep first-seen
    /// order and a new pane in a known session never re-sorts anything —
    /// but the sessions inside a project list in **creation order**: their
    /// ids carry the instant they were minted (`sess-grp-<ms>-<counter>`),
    /// so the order survives restores and pane drags that reorder the pane
    /// array itself. Ids without that key (the ungrouped sentinel) predate
    /// grouping and sort first, keeping first-seen order among themselves.
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
            // Swift's sort is stable, so two keyless ids keep their
            // first-seen order rather than jumping around per render.
            let order = (groupOrder[project] ?? []).sorted { lhs, rhs in
                switch (creationKey(lhs), creationKey(rhs)) {
                case let (l?, r?): return l < r
                case (nil, .some): return true
                case (.some, nil), (nil, nil): return false
                }
            }
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
                    terminalPaneIDs: sessionPanes.filter { $0.kind == .terminal }.map(\.sessionID),
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

    /// The creation instant a real group id carries
    /// (`sess-grp-<ms>-<counter>`), as a sortable pair — what `group` orders
    /// sessions by. `nil` for the ungrouped sentinel and any foreign id.
    static func creationKey(_ group: String) -> (ms: Int, counter: Int)? {
        guard group.hasPrefix("sess-grp-") else { return nil }
        let parts = group.dropFirst("sess-grp-".count).split(separator: "-")
        guard parts.count == 2, let ms = Int(parts[0]), let counter = Int(parts[1]) else {
            return nil
        }
        return (ms, counter)
    }

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

    /// The session the user is currently on — the group holding the focused
    /// pane. `nil` when nothing is focused, and `nil` when the focused id
    /// names no live pane (a stale focus).
    ///
    /// The strict "who has focus" answer. What is on *screen* — and what a
    /// new pane joins — is `visibleSessionGroupID`, which falls back exactly
    /// where this returns `nil`. Port of `currentSessionGroupId`.
    ///
    /// No `?? ungroupedSessionID` here, deliberately: `PaneDescriptor.group`
    /// is non-optional and a pre-grouping pane already carries the sentinel,
    /// resolved once at the restore boundary.
    static func currentSessionGroupID(_ panes: [PaneDescriptor], focusedPaneID: String?) -> String? {
        guard let focusedPaneID else { return nil }
        return panes.first { $0.sessionID == focusedPaneID }?.group
    }

    /// Which session's panes this project actually puts **on screen** — and
    /// the session a newly opened single pane JOINS. Port of
    /// `visibleSessionGroupId`.
    ///
    /// The rule, and why it is not just `currentSessionGroupID`:
    ///
    /// - **The focused pane's session**, when the focused pane is in this
    ///   project. This agrees with `group`'s `isCurrent` by construction, so
    ///   the grid and the sidebar's accent rail can never point at different
    ///   sessions.
    /// - **Otherwise the project's first session** (creation order = the
    ///   topmost row in the sidebar). Selecting a workspace deliberately does
    ///   *not* move focus, so `focusedPaneID` routinely belongs to a
    ///   different project than the one being rendered;
    ///   `currentSessionGroupID` answers `nil` there, and showing nothing at
    ///   all would be a worse answer than showing the session the eye lands
    ///   on anyway. A stale `focusedPaneID` lands here too, rather than
    ///   blanking.
    /// - **`nil`** only when the project genuinely has no panes — the caller
    ///   then renders its empty state, or mints a group with
    ///   `existingGroup ?? newSessionGroupID()`.
    ///
    /// This absorbed a near-twin, `sessionGroupForNewPane`, identical except
    /// that its no-focus-in-this-project fallback picked the project's
    /// *most-recently-created* session instead of the first-seen one — which
    /// is how "the 'New terminal' row could be drawn under Session 1 and
    /// spawn into Session 2". One question, one answer: a new pane joins the
    /// session you are looking at.
    static func visibleSessionGroupID(
        _ panes: [PaneDescriptor],
        project: String,
        focusedPaneID: String?
    ) -> String? {
        let focused = focusedPaneID.flatMap { id in panes.first { $0.sessionID == id } }
        if let focused, focused.project == project { return focused.group }
        // Through `group` rather than `panes.first`, so "the topmost row"
        // stays literally true now that sessions list in creation order.
        return group(panes, focusedPaneID: nil)
            .first { $0.project == project }?
            .sessions.first?.id
    }

    /// The first pane of the adjacent session in `project`, or `nil` at a
    /// project boundary. Port of `adjacentSessionTab` — what session
    /// stepping (`⌃1…⌃9`-style, and the canvas's "fly sideways") walks.
    ///
    /// Two behaviours ride on the oracle's single line
    /// (`sessions[(currentIndex === -1 ? 0 : currentIndex) + offset]?.tabs[0] ?? null`):
    ///
    /// - **No current session in this project** — focus is elsewhere, or
    ///   nowhere — starts the walk from index 0. So `offset: 1` lands on the
    ///   project's *second* session and `offset: -1` computes index -1.
    /// - **Index -1 and index >= count are both `nil`, with no wrapping.**
    ///   JS reads those as `undefined` and short-circuits; Swift traps, so
    ///   the `indices.contains` guard below *is* the end behaviour rather
    ///   than a defensive extra.
    ///
    /// Returns the target session's **first** pane, not its focused one.
    static func adjacentSessionTab(
        _ panes: [PaneDescriptor],
        project: String,
        focusedPaneID: String?,
        offset: Int
    ) -> PaneDescriptor? {
        let sessions = group(panes, focusedPaneID: focusedPaneID)
            .first { $0.project == project }?
            .sessions ?? []
        let currentIndex = sessions.firstIndex { $0.isCurrent } ?? -1
        let target = (currentIndex == -1 ? 0 : currentIndex) + offset
        guard sessions.indices.contains(target),
              let firstPaneID = sessions[target].paneIDs.first
        else { return nil }
        return panes.first { $0.sessionID == firstPaneID }
    }

    /// Which engines are running in one session and how many terminals of
    /// each, in first-seen order — what the canvas's session chips and the
    /// hover card draw an engine-coloured dot per entry from. Port of
    /// `sessionEngineBreakdown`.
    ///
    /// Two deliberate divergences from the oracle:
    ///
    /// - **It takes the descriptors and a group id, not a session node.**
    ///   The oracle reads `session.tabs`, whole `TabInfo`s;
    ///   `SessionGroupNode` carries only `paneIDs`, so it physically cannot
    ///   answer this. Callers already keep the descriptors beside the tree.
    /// - **Only `.terminal` panes count.** A browser or editor pane carries
    ///   `.shell` as a placeholder, not as an identity — the same reason
    ///   `nextPaneNumber` gives them their own ladder — and counting one
    ///   would make the card claim a shell that is not running. The web
    ///   build has no pane kinds, so its oracle cannot express this.
    ///
    /// Scoped by group alone, matching how `PaneWorkspaceView.grids` is
    /// keyed. Real group ids are unique across projects
    /// (`sess-grp-<ms>-<counter>`); `WorkspaceRestoration.ungroupedSessionID`
    /// is shared by construction, so for that one id this merges the
    /// pre-grouping panes of every project. Pass project-scoped panes if
    /// that matters at the call site.
    ///
    /// Built from live panes, never from what a create dialog chose: a
    /// terminal closed afterwards must not leave the card claiming it is
    /// there.
    static func sessionEngineBreakdown(_ panes: [PaneDescriptor], group: String) -> [(engine: Engine, count: Int)] {
        var counts: [(engine: Engine, count: Int)] = []
        for pane in panes where pane.group == group && pane.kind == .terminal {
            if let index = counts.firstIndex(where: { $0.engine == pane.engine }) {
                counts[index].count += 1
            } else {
                counts.append((engine: pane.engine, count: 1))
            }
        }
        return counts
    }

    static func defaultPaneName(_ engine: Engine, _ n: Int) -> String {
        "\(engine.displayName) \(n)"
    }

    /// The kind-aware placeholder: a browser or editor is not an engine, so
    /// each gets its own `Browser N` / `Editor N` ladder rather than wearing
    /// the `.shell` its descriptor happens to carry.
    static func defaultPaneName(_ pane: PaneDescriptor) -> String {
        switch pane.kind {
        case .browser: return "Browser \(pane.autoNumber)"
        case .editor: return "Editor \(pane.autoNumber)"
        case .terminal: return defaultPaneName(pane.engine, pane.autoNumber)
        }
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
        return parts[0] == "Browser" || parts[0] == "Editor"
            || Engine.allCases.contains { $0.displayName == parts[0] }
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
        // Browsers and editors number their own ladder regardless of engine
        // — the `.shell` their descriptor carries is a placeholder, not an
        // identity — while terminals keep numbering per engine.
        let taken = Set(
            panes
                .filter { $0.group == group && $0.kind == kind && (kind != .terminal || $0.engine == engine) }
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
