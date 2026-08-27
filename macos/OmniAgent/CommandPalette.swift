import Foundation

/// What running a palette row does. A closed set rather than a closure, so
/// the list is comparable in a test and the window controller stays the only
/// thing that knows how to perform any of it.
enum PaletteAction: Equatable {
    case focusPane(sessionID: String)
    /// Fly the Desk's camera onto one session's card. The palette twin of
    /// ⌃1…⌃9 and of the sidebar's session row — all three land in
    /// `WorkspaceWindowController.enterDeskSession`.
    case enterSession(group: String)
    /// A workspace from the sidebar, by name — opened, and the Desk shown.
    case selectWorkspace(id: String)
    /// One of the sidebar's destinations — Home, To Do List, Desk, Settings
    /// — reachable by typing its name.
    case showDestination(WorkspaceDestination)
    /// One Settings section, straight from the spotlight — the page opens
    /// on it, the way the gear's panel would.
    case showSettingsSection(SettingsSection)
    /// A file open in some editor pane, chosen from the spotlight — reveals
    /// the pane holding it and brings that tab forward.
    case openFile(path: String)
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
    /// Where things are — workspaces, the destinations, the Settings
    /// sections. The spotlight is for *finding*; the verbs (new pane, close,
    /// interrupt…) left it on 2026-08-28, since a search that lists commands
    /// is a menu.
    case places = "Places"
    case brain = "Brain"

    /// The SF Symbol every row in the section wears.
    var symbol: String {
        switch self {
        case .sessions: return "rectangle.stack"
        case .terminals: return "apple.terminal"
        case .browsers: return "globe"
        case .files: return "doc.text"
        case .places: return "location"
        case .brain: return "sparkle.magnifyingglass"
        }
    }
}

/// Fuzzy matching: the query's characters have to appear in order, but not
/// next to each other — `cmdpal` finds `CommandPalette.swift`, the way ⌘P
/// does in every editor.
///
/// Loose matching needs ranking or the good row drowns, so a match is scored
/// rather than merely accepted: a character that continues a run is worth far
/// more than a scattered one, and one that starts a word — after a separator
/// or at a camelCase hump — a little more again. A plain substring hit is a
/// run from end to end, so it always outscores a scattered one, and equal
/// scores keep the order the list already had, which is what muscle memory
/// rests on.
enum FuzzyMatch {
    private static let runBonus = 8
    private static let boundaryBonus = 5

    /// `nil` when `needle`'s characters do not all appear in order. `needle`
    /// is already lowercased by the caller.
    ///
    /// The better of two readings, because the scattered one alone gets the
    /// obvious case wrong: scanning "Switch to alpha — pane" for `pane`
    /// greedily takes the `p` in "alpha" and never sees the word. So a whole
    /// run is looked for first, and only the leftovers are matched loosely.
    static func score(_ needle: String, in haystack: String) -> Int? {
        guard !needle.isEmpty else { return 0 }
        let wanted = Array(needle.lowercased())
        let characters = Array(haystack)
        let lowered = Array(haystack.lowercased())
        return [run(wanted, in: characters, lowered: lowered), scattered(wanted, in: characters, lowered: lowered)]
            .compactMap { $0 }
            .max()
    }

    /// The needle as one unbroken run — a plain substring — scored at every
    /// place it appears, best first. `nil` when it appears nowhere.
    private static func run(_ wanted: [Character], in characters: [Character], lowered: [Character]) -> Int? {
        guard wanted.count <= lowered.count else { return nil }
        var best: Int?
        for start in 0...(lowered.count - wanted.count)
        where Array(lowered[start..<(start + wanted.count)]) == wanted {
            let score = wanted.count + runBonus * (wanted.count - 1)
                + (isWordStart(characters, at: start) ? boundaryBonus : 0)
            best = max(best ?? score, score)
        }
        return best
    }

    /// The characters in order but not together.
    ///
    /// ponytail: greedy — it takes the first place each character fits rather
    /// than the best, so an unusual path can score below its ideal alignment.
    /// A proper Smith-Waterman pass is the upgrade if that ever shows.
    private static func scattered(_ wanted: [Character], in characters: [Character], lowered: [Character]) -> Int? {
        var next = 0
        var score = 0
        var previousMatched = false
        for index in lowered.indices {
            guard next < wanted.count else { break }
            guard lowered[index] == wanted[next] else {
                previousMatched = false
                continue
            }
            score += 1
            if previousMatched { score += runBonus }
            if isWordStart(characters, at: index) { score += boundaryBonus }
            previousMatched = true
            next += 1
        }
        return next == wanted.count ? score : nil
    }

    /// The start of a word: the first character, one after a separator, or the
    /// upper half of a camelCase hump.
    private static func isWordStart(_ characters: [Character], at index: Int) -> Bool {
        guard index > 0 else { return true }
        let previous = characters[index - 1]
        if previous == "/" || previous == "." || previous == "_" || previous == "-" || previous == " " {
            return true
        }
        return previous.isLowercase && characters[index].isUppercase
    }
}

/// One row.
/// A sidebar workspace as the palette sees it: the id it selects by, the
/// name the sidebar shows (renames included), and the path the query may
/// match.
struct PaletteWorkspace: Equatable {
    let id: String
    let label: String
    let path: String?
}

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
        section: PaletteSection = .places,
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

    /// How well the query fits this row, over everything it carries — what it
    /// shows and what it hides — or `nil` for no fit at all. The best of the
    /// three, so a row is never punished for having a subtitle the query
    /// ignores. `needle` is already lowercased by the caller.
    func score(for needle: String) -> Int? {
        [title, subtitle, keywords]
            .compactMap { $0 }
            .compactMap { FuzzyMatch.score(needle, in: $0) }
            .max()
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

    /// How many repository files one query may show — the twelve that fit it
    /// best. The list is a shortcut to a file you can name, not a directory
    /// listing.
    /// ponytail: a flat scan over the path list; an index if a repo outgrows it.
    static let fileMatchLimit = 12

    /// Rebuilt from the live workspace every time the palette opens, so it
    /// can never offer a pane that closed while it was shut.
    static func build(
        panes: [PaneDescriptor],
        paneOrder: [String],
        focusedPaneID: String?,
        projectLabels: [String: String] = [:],
        /// The sidebar's open workspaces, in its order, with their display
        /// names — so a workspace with nothing running is still findable.
        workspaces: [PaletteWorkspace] = []
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
        // One row per session, before the pane rows and in the same section:
        // a section is a run of consecutive rows, so these cannot be appended
        // after the browser and editor rows without splitting Terminals in two.
        for project in tree {
            for (index, session) in project.sessions.enumerated() {
                commands.append(
                    PaletteCommand(
                        id: "enter:\(session.id)",
                        title: "Enter \(session.label) — \(SessionOutline.projectLabel(project.project, labels: projectLabels))",
                        // Hand-typed, like every other key hint in this file:
                        // nothing links a row to the NSMenuItem that defines
                        // its chord. ⌃1…⌃9 is per project, and there is no
                        // single keystroke past nine.
                        detail: index < 9 ? "⌃\(index + 1)" : nil,
                        action: .enterSession(group: session.id),
                        keywords: session.cwd,
                        section: .terminals
                    )
                )
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
        for workspace in workspaces {
            commands.append(
                PaletteCommand(
                    id: "workspace:\(workspace.id)",
                    title: workspace.label,
                    detail: nil,
                    action: .selectWorkspace(id: workspace.id),
                    keywords: workspace.path,
                    section: .places,
                    subtitle: "Workspace",
                    symbol: "folder"
                )
            )
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
                    section: .places,
                    subtitle: destination.subtitle,
                    symbol: destination.paletteSymbol
                )
            )
        }
        // Every Settings section, findable by its own name or by "settings".
        for section in SettingsSection.allCases {
            commands.append(
                PaletteCommand(
                    id: "settings:\(section.rawValue)",
                    title: section.title,
                    detail: nil,
                    action: .showSettingsSection(section),
                    keywords: "settings",
                    section: .places,
                    subtitle: "Settings",
                    symbol: section.symbol
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
    /// Matching is fuzzy and case-insensitive (see `FuzzyMatch`): the query's
    /// characters have to appear in order, not next to each other. Rows are
    /// ranked inside their section by how well they fit, and an equal fit
    /// keeps the order the list already had. What the query does not match is
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
        let rows = commands.enumerated().compactMap { order, command in
            command.score(for: needle).map { Ranked(command: command, score: $0, order: order) }
        } + fileRows(matching: needle)
        // Grouped by section rather than ranked across all of them: rows have
        // to arrive in section order for the headings to be a walk instead of
        // a sort, and the repository files join the files the editors already
        // have open. Ranking happens inside a section, where the comparison
        // means something.
        return PaletteSection.allCases.flatMap { section in
            rows.filter { $0.command.section == section }.sortedByRank()
        }
    }

    /// A row and how well the query fit it, with where it started out — the
    /// tie-break, so an equal score never reshuffles the list.
    fileprivate struct Ranked {
        let command: PaletteCommand
        let score: Int
        let order: Int
    }

    /// Repository files the query names, minus the ones an editor already has
    /// open — those are rows already, and going to the open tab beats opening
    /// the file a second time.
    private func fileRows(matching needle: String) -> [Ranked] {
        guard let root = filesRoot else { return [] }
        let open = Set(commands.compactMap { command -> String? in
            if case let .openFile(path) = command.action { return path }
            return nil
        })
        // The best matches rather than the first ones: with fuzzy matching a
        // loose query fits half the repository, and the twelve it fits *best*
        // are the twelve worth showing.
        return files.enumerated()
            .compactMap { order, relative -> (relative: String, score: Int, order: Int)? in
                guard !open.contains(root.appendingPathComponent(relative).path),
                      let score = FuzzyMatch.score(needle, in: relative)
                else { return nil }
                return (relative, score, order)
            }
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.order < $1.order }
            .prefix(Self.fileMatchLimit)
            .enumerated()
            .map { rank, match in
                let path = root.appendingPathComponent(match.relative).path
                let folder = (match.relative as NSString).deletingLastPathComponent
                return Ranked(
                    command: PaletteCommand(
                        id: "file:\(path)",
                        title: (match.relative as NSString).lastPathComponent,
                        detail: nil,
                        action: .openFile(path: path),
                        keywords: match.relative,
                        section: .files,
                        subtitle: folder.isEmpty ? root.lastPathComponent : folder
                    ),
                    score: match.score,
                    // Behind every command row, so a file never jumps the
                    // workspace's own rows on a tie.
                    order: commands.count + rank
                )
            }
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


private extension Array where Element == CommandPaletteModel.Ranked {
    /// Best fit first, and an equal fit keeps the order it came in — Swift's
    /// sort is not stable, so the tie-break has to be explicit.
    func sortedByRank() -> [PaletteCommand] {
        sorted { $0.score != $1.score ? $0.score > $1.score : $0.order < $1.order }.map(\.command)
    }
}
