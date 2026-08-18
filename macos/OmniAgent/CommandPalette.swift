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

    init(id: String, title: String, detail: String?, action: PaletteAction, keywords: String? = nil) {
        self.id = id
        self.title = title
        self.detail = detail
        self.action = action
        self.keywords = keywords
    }

    /// Case-insensitive substring over title *and* keywords. `needle` is
    /// already lowercased by the caller.
    func matches(_ needle: String) -> Bool {
        title.lowercased().contains(needle) || keywords?.lowercased().contains(needle) == true
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
        for project in tree {
            for session in project.sessions {
                for paneID in session.paneIDs {
                    guard let pane = byID[paneID] else { continue }
                    commands.append(
                        PaletteCommand(
                            id: "focus:\(paneID)",
                            title: "Switch to \(SessionOutline.projectLabel(project.project, labels: projectLabels)) — \(session.label) — \(SessionOutline.paneLabel(pane))",
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
                                .joined(separator: " ")
                        )
                    )
                }
            }
        }
        // Every file open in an editor pane, deduped by path: a file open in
        // two panes is one thing to go to, not two.
        var seenPaths: Set<String> = []
        for pane in ordered where pane.kind == .editor {
            for tab in pane.editorTabs where seenPaths.insert(tab.path).inserted {
                let name = (tab.path as NSString).lastPathComponent
                let folder = ((tab.path as NSString).deletingLastPathComponent as NSString).lastPathComponent
                commands.append(
                    PaletteCommand(
                        id: "file:\(tab.path)",
                        title: "Open \(name)",
                        detail: folder.isEmpty ? "file" : folder,
                        action: .openFile(path: tab.path),
                        keywords: tab.path
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
            if pane.kind == .editor,
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
        var rows = commands.filter { $0.matches(needle) }
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
