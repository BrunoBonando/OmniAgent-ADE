import Foundation

/// What running a palette row does. A closed set rather than a closure, so
/// the list is comparable in a test and the window controller stays the only
/// thing that knows how to perform any of it.
enum PaletteAction: Equatable {
    case focusPane(sessionID: String)
    case closePane(sessionID: String)
    case newPane
    case newBrowserPane
    case newEditorPane
    case newSession
    /// The focused editor's active file, diffed against HEAD — the palette's
    /// twin of the tab strip's ± toggle.
    case openDiffForCurrentFile(path: String)
    /// A file open in some editor pane, chosen from the spotlight — reveals
    /// the pane holding it and brings that tab forward.
    case openFile(path: String)
    /// The repo-wide Changes overview.
    case showAllChanges
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

/// The heading a row sits under, in the order the sections appear. Spotlight
/// groups what it finds rather than pouring it into one list, and so does
/// this: rows are emitted in section order, so a section is just a run of
/// consecutive rows and nothing has to sort or re-index after filtering.
enum PaletteSection: String, CaseIterable, Equatable {
    case terminals = "Terminals"
    case browsers = "Browsers"
    case files = "Files"
    case actions = "Actions"
    case brain = "Brain"

    /// The SF Symbol every row in the section wears.
    var symbol: String {
        switch self {
        case .terminals: return "apple.terminal"
        case .browsers: return "globe"
        case .files: return "doc.text"
        case .actions: return "command"
        case .brain: return "sparkle.magnifyingglass"
        }
    }
}

/// One row.
struct PaletteCommand: Equatable {
    let id: String
    let title: String
    /// The right-aligned hint — an engine name, a key equivalent.
    let detail: String?
    let action: PaletteAction
    /// Text the query matches but the row never shows: a browser's URL, a
    /// terminal's cwd, a file's full path. Spotlight has to find a pane by
    /// what is *in* it, not only by the words its row happens to print.
    let keywords: String?
    let section: PaletteSection
    /// Where the thing *is* — a pane's project and session, a file's folder.
    /// Its own line under the title, as in Spotlight, rather than a suffix
    /// dimmed inside one.
    let subtitle: String?

    init(
        id: String,
        title: String,
        detail: String?,
        action: PaletteAction,
        keywords: String? = nil,
        section: PaletteSection = .actions,
        subtitle: String? = nil
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.action = action
        self.keywords = keywords
        self.section = section
        self.subtitle = subtitle
    }

    /// Case-insensitive substring over everything the row carries — what it
    /// shows and what it hides. `needle` is already lowercased by the caller.
    func matches(_ needle: String) -> Bool {
        title.lowercased().contains(needle)
            || subtitle?.lowercased().contains(needle) == true
            || keywords?.lowercased().contains(needle) == true
    }
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
    /// The chosen tag, or `nil` for "All".
    private(set) var selectedSection: PaletteSection?

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
        projectLabels: [String: String] = [:],
        /// Whether the open workspace is a git repository. Passed in rather
        /// than discovered: this model never runs a subprocess.
        hasGitRepo: Bool = false
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
        // Walked once, emitted per kind: the outline's project/session order
        // survives inside each section, and the sections come out in the
        // order the palette shows them.
        var paneRows: [PaneKind: [PaletteCommand]] = [:]
        for project in tree {
            for session in project.sessions {
                for paneID in session.paneIDs {
                    guard let pane = byID[paneID] else { continue }
                    paneRows[pane.kind, default: []].append(
                        PaletteCommand(
                            id: "focus:\(paneID)",
                            title: SessionOutline.paneLabel(pane),
                            // A browser or editor is a pane kind, not an
                            // engine — the `.shell` its descriptor carries is
                            // a placeholder that must not be shown as what
                            // the pane runs.
                            detail: {
                                switch pane.kind {
                                case .browser: return "browser"
                                case .editor: return "editor"
                                case .terminal: return pane.engine.rawValue
                                }
                            }(),
                            action: .focusPane(sessionID: paneID),
                            // A browser is worth finding by its address and a
                            // terminal by the folder it sits in, neither of
                            // which the row's title says.
                            keywords: [pane.browserURL, pane.cwd, pane.title].filter { !$0.isEmpty }
                                .joined(separator: " "),
                            section: {
                                switch pane.kind {
                                case .terminal: return .terminals
                                case .browser: return .browsers
                                // An editor pane sits with the files it holds.
                                case .editor: return .files
                                }
                            }(),
                            subtitle: "\(SessionOutline.projectLabel(project.project, labels: projectLabels)) · \(session.label)\(pane.browserURL.isEmpty ? "" : " · \(pane.browserURL)")"
                        )
                    )
                }
            }
        }
        commands += paneRows[.terminal] ?? []
        commands += paneRows[.browser] ?? []
        commands += paneRows[.editor] ?? []
        // Every file open in an editor pane, deduped by path: a file open in
        // two panes is one thing to go to, not two.
        var seenPaths: Set<String> = []
        for pane in ordered where pane.kind == .editor {
            for tab in pane.editorTabs where seenPaths.insert(tab.path).inserted {
                let name = (tab.path as NSString).lastPathComponent
                commands.append(
                    PaletteCommand(
                        id: "file:\(tab.path)",
                        title: name,
                        detail: nil,
                        action: .openFile(path: tab.path),
                        keywords: tab.path,
                        section: .files,
                        // The folder it lives in, home abbreviated — the
                        // location line Spotlight puts under a file's name.
                        subtitle: ((tab.path as NSString).deletingLastPathComponent as NSString)
                            .abbreviatingWithTildeInPath
                    )
                )
            }
        }
        commands.append(
            PaletteCommand(id: "new-pane", title: "New terminal pane", detail: "⌘T", action: .newPane)
        )
        commands.append(
            PaletteCommand(id: "new-browser", title: "New browser pane", detail: "⇧⌘T", action: .newBrowserPane)
        )
        commands.append(
            PaletteCommand(id: "new-editor", title: "New editor pane", detail: "⇧⌘E", action: .newEditorPane)
        )
        if hasGitRepo {
            commands.append(
                PaletteCommand(
                    id: "show-all-changes",
                    title: "Show all changes",
                    detail: "git",
                    action: .showAllChanges
                )
            )
        }
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
            // Only a *file* tab has something to diff: a media tab is not
            // text, and a diff tab is already the answer. The descriptor's
            // persisted tab list is the palette's only view of the pane —
            // it never reaches into `EditorPaneView` itself.
            // Gated on `hasGitRepo` like "Show all changes" above: outside a
            // repository the row is *absent*, rather than a row that runs and
            // lands on an inline "is this file in a git repository?" message.
            if hasGitRepo,
               pane.kind == .editor,
               pane.editorTabs.indices.contains(pane.editorActiveIndex) {
                let active = pane.editorTabs[pane.editorActiveIndex]
                if active.kind == EditorTabKind.file.rawValue {
                    commands.append(
                        PaletteCommand(
                            id: "open-diff",
                            title: "Open diff for \((active.path as NSString).lastPathComponent)",
                            detail: "vs HEAD",
                            action: .openDiffForCurrentFile(path: active.path)
                        )
                    )
                }
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

    /// The rows the query found, narrowed to the selected tag.
    ///
    /// **Nothing until something is typed.** An empty field shows the bar and
    /// only the bar — the palette used to answer "" with its whole command
    /// list, which is a menu, not a search.
    ///
    /// Order is preserved and matching is a case-insensitive substring,
    /// deliberately not a fuzzy score: the list is short and stable ordering
    /// is what makes muscle memory work. A non-empty query always ends with
    /// the "Search brain for …" row, whether or not anything else matched.
    var matches: [PaletteCommand] {
        guard let section = selectedSection else { return found }
        return found.filter { $0.section == section }
    }

    /// Everything the query found, before the tag narrows it — what the tag
    /// row itself is built from, so filtering can never hide the tag you
    /// would need to get back.
    var found: [PaletteCommand] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let needle = trimmed.lowercased()
        var rows = commands.filter { $0.matches(needle) }
        rows.append(
            PaletteCommand(
                id: "search-brain",
                title: "Search brain for \u{201C}\(trimmed)\u{201D}",
                detail: nil,
                action: .searchBrain(query: trimmed),
                section: .brain
            )
        )
        return rows
    }

    /// The tags under the field: `nil` — "All" — first, then every section
    /// the query actually found, in the palette's own section order.
    var sectionTags: [PaletteSection?] {
        let present = Set(found.map(\.section))
        return [nil] + PaletteSection.allCases.filter(present.contains)
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
        selectedSection = nil
    }

    /// Typing always returns the highlight to the top: the best match for a
    /// new query is never "wherever the cursor happened to be".
    mutating func update(query: String) {
        self.query = query
        selectedIndex = 0
        // A tag the new query no longer finds would filter the list down to
        // nothing with no way back except noticing why.
        if let section = selectedSection, !sectionTags.contains(section) {
            selectedSection = nil
        }
    }

    /// Picks a tag — `nil` for "All".
    mutating func select(section: PaletteSection?) {
        selectedSection = section
        selectedIndex = 0
    }

    /// ⇥ / ⇧⇥ through the tags, wrapping: a short, closed ring is the one
    /// place wrapping beats clamping, because every stop is one step away.
    mutating func cycleSection(by delta: Int) {
        let tags = sectionTags
        guard tags.count > 1 else { return }
        let current = tags.firstIndex(of: selectedSection) ?? 0
        let next = ((current + delta) % tags.count + tags.count) % tags.count
        select(section: tags[next])
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
