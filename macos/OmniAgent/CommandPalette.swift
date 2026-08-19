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
    /// One of Level 2's three destinations — Dashboard, Board, Desk — the
    /// sidebar's own buttons, reachable by typing their names.
    case showDestination(WorkspaceDestination)
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
    case sessions = "Sessions"
    case terminals = "Terminals"
    case browsers = "Browsers"
    case files = "Files"
    case actions = "Actions"
    case brain = "Brain"

    /// The SF Symbol every row in the section wears.
    var symbol: String {
        switch self {
        case .sessions: return "rectangle.stack"
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
    /// Overrides the section's icon for a row that has its own — the
    /// destinations, which are places rather than commands.
    let symbol: String?
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
        subtitle: String? = nil,
        symbol: String? = nil
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.action = action
        self.keywords = keywords
        self.section = section
        self.subtitle = subtitle
        self.symbol = symbol
    }

    /// What the row draws: its own icon when it has one, its section's
    /// otherwise.
    var icon: String { symbol ?? section.symbol }

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
/// **No brain-search row.** The list is what the query matched and nothing
/// else — the synthetic "Search brain for …" row is gone (2026-08-19). The
/// `.searchBrain` action and `WorkspaceWindowController`'s handler for it
/// remain, with nothing offering them.
struct CommandPaletteModel: Equatable {
    private(set) var commands: [PaletteCommand]
    private(set) var query = ""
    private(set) var selectedIndex = 0
    /// The chosen tag, or `nil` for "All".
    private(set) var selectedSection: PaletteSection?

    /// Every tracked file in the workspace's repository, repository-relative,
    /// and the root they hang off. Held as paths rather than rows and matched
    /// at query time: a repository has thousands of files and the palette
    /// shows a handful, so turning them all into rows on every open is work
    /// nobody sees.
    private(set) var files: [String] = []
    private(set) var filesRoot: URL?

    init(commands: [PaletteCommand] = [], files: [String] = [], filesRoot: URL? = nil) {
        self.commands = commands
        self.files = files
        self.filesRoot = filesRoot
    }

    /// How many repository files one query may show. The list is a shortcut to
    /// a file you can name, not a directory listing — a query loose enough to
    /// match hundreds is a query to narrow.
    /// ponytail: a flat scan over the path list; an index if a repo outgrows it.
    static let fileMatchLimit = 12

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
        // A session is a row of its own: typing its name goes to the session,
        // landing on the first pane in it. The count is what tells two
        // identically-named sessions in different projects apart at a glance.
        for project in tree {
            let projectLabel = SessionOutline.projectLabel(project.project, labels: projectLabels)
            for session in project.sessions {
                guard let first = session.paneIDs.first else { continue }
                let panes = session.paneIDs.count
                commands.append(
                    PaletteCommand(
                        id: "session:\(project.project)/\(session.id)",
                        title: session.label,
                        detail: panes == 1 ? "1 pane" : "\(panes) panes",
                        action: .focusPane(sessionID: first),
                        keywords: projectLabel,
                        section: .sessions,
                        subtitle: projectLabel
                    )
                )
            }
        }
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
                            subtitle: {
                                var parts = [
                                    SessionOutline.projectLabel(project.project, labels: projectLabels),
                                    session.label,
                                ]
                                // The agent's own live title — "Fixing the
                                // parser". Already searchable through
                                // `keywords`; shown too whenever the pane wears
                                // a name of its own, because then the title is
                                // the one thing on the row you cannot see.
                                let title = pane.title.trimmingCharacters(in: .whitespacesAndNewlines)
                                if !title.isEmpty, title != SessionOutline.paneLabel(pane) {
                                    parts.append(title)
                                }
                                if !pane.browserURL.isEmpty { parts.append(pane.browserURL) }
                                return parts.joined(separator: " · ")
                            }()
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
        // The sidebar's own three buttons, by name. `allCases` rather than a
        // hand-written list: a fourth destination should appear here the day
        // it appears in the sidebar, not the day someone remembers this.
        for destination in WorkspaceDestination.allCases {
            commands.append(
                PaletteCommand(
                    id: "destination:\(destination.rawValue)",
                    title: destination.title,
                    detail: nil,
                    action: .showDestination(destination),
                    section: .actions,
                    subtitle: destination.subtitle,
                    symbol: destination.paletteSymbol
                )
            )
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
    /// is what makes muscle memory work. What the query does not match is
    /// simply not there — no synthetic trailing row offering to search
    /// something else.
    var matches: [PaletteCommand] {
        let rows = selectedSection.map { section in found.filter { $0.section == section } } ?? found
        guard rows.isEmpty, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return rows }
        // Something rather than a bar that silently refuses to grow: a query
        // that finds nothing should say so.
        return [
            PaletteCommand(
                id: "no-matches",
                title: "No matches",
                detail: nil,
                action: .noop,
                subtitle: "Nothing here matches \u{201C}\(query.trimmingCharacters(in: .whitespacesAndNewlines))\u{201D}"
            )
        ]
    }

    /// Everything the query found, before the tag narrows it — what the tag
    /// row itself is built from, so filtering can never hide the tag you
    /// would need to get back.
    var found: [PaletteCommand] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let needle = trimmed.lowercased()
        let rows = commands.filter { $0.matches(needle) } + fileRows(matching: needle)
        // Grouped rather than sorted: rows have to arrive in section order for
        // the headings to be a walk instead of a sort, and the repository
        // files join the files the editors already have open.
        return PaletteSection.allCases.flatMap { section in rows.filter { $0.section == section } }
    }

    /// Repository files the query names, minus the ones an editor already has
    /// open — those are rows already, and going to the open tab beats opening
    /// the file a second time.
    private func fileRows(matching needle: String) -> [PaletteCommand] {
        guard let root = filesRoot else { return [] }
        let open = Set(commands.compactMap { command -> String? in
            if case let .openFile(path) = command.action { return path }
            return nil
        })
        var rows: [PaletteCommand] = []
        for relative in files where relative.lowercased().contains(needle) {
            let path = root.appendingPathComponent(relative).path
            guard !open.contains(path) else { continue }
            let folder = (relative as NSString).deletingLastPathComponent
            rows.append(
                PaletteCommand(
                    id: "file:\(path)",
                    title: (relative as NSString).lastPathComponent,
                    detail: nil,
                    action: .openFile(path: path),
                    keywords: relative,
                    section: .files,
                    subtitle: folder.isEmpty ? root.lastPathComponent : folder
                )
            )
            if rows.count == Self.fileMatchLimit { break }
        }
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

    mutating func reset(commands: [PaletteCommand], files: [String] = [], filesRoot: URL? = nil) {
        self.commands = commands
        self.files = files
        self.filesRoot = filesRoot
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
