import Foundation

/// The two pages under Help, bundled under `Resources/Legal` and opened in
/// the default browser — a reviewer's first question, and a licence
/// obligation: SwiftTerm, Monaco and lobe-icons are MIT, so attribution is
/// not optional.
enum LegalDocument: String, CaseIterable {
    case privacyPolicy = "privacy-policy"
    case thirdPartyNotices = "third-party-notices"

    var title: String { self == .privacyPolicy ? "Privacy Policy" : "Third-Party Notices" }

    /// `nil` only if the page failed to make it into the bundle —
    /// `BundleComplianceTests` is what keeps that from shipping.
    var url: URL? { Bundle.main.url(forResource: rawValue, withExtension: "html", subdirectory: "Legal") }
}

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
    /// The "Show 10 more" / "Show all" row under a capped category: reveals
    /// the next step of it in place. The panel handles it itself and stays
    /// open — it is a button on the list, not a place to go.
    case showMore(PaletteSection)
    /// One of the sidebar's destinations — Home, To Do List, Insights, Desk,
    /// Settings — reachable by typing its name.
    case showDestination(WorkspaceDestination)
    /// One Settings section, straight from the spotlight — the page opens
    /// on it, the way the docked panel's own row would.
    case showSettingsSection(SettingsSection)
    /// One tab of the Insights page (the flow-layout spec's §8). A row of
    /// its own per tab, the same reasoning as the Settings sections above:
    /// "Activity" is a place you go, and the destination row only ever
    /// lands on the tab the page happens to be showing.
    case showInsightsTab(InsightsTab)
    /// Opens the focused branch/session setup flow for the current workspace.
    case startBranchSession
    /// The title bar's two popovers (the flow layout spec's §1). Rows of their
    /// own because the bell and the avatar are 24pt controls in the window's
    /// chrome — the standing rule says everything navigable is findable, and
    /// these two have no other name to type.
    case showNotifications
    case showAccountMenu
    /// The sidebar foot's Help row (the flow layout spec's §3), which pops
    /// the app's Help menu — a row of its own for the same reason the two
    /// above are: a symbol at the bottom of a column has no name to type.
    case showHelp
    /// Settings › Accounts' one button, in its two states. Only ever one of
    /// these is a row — whichever the account makes true — because the
    /// spotlight offers what you can do now, not both halves of a toggle.
    case signIn
    case signOut
    /// Settings › Accounts' GitHub button, in its two states — the same
    /// one-row-not-both rule as the pair above.
    case connectGitHub
    case disconnectGitHub
    /// Settings › Accounts' destructive third button. A row only while
    /// signed in: deleting nothing is a dead end, not an offer — which is
    /// why this one is not half of a pair like the two above.
    case deleteAccount
    /// Settings › Remote's one control (2026-09-01 remote environment
    /// sharing spec §10) — a fixed row, unlike the account/GitHub pairs
    /// above: sharing is a plain on/off switch with one verb, not a mode
    /// with a different one on each side.
    case toggleRemoteSharing
    /// Settings › Remote's blocked list (spec §7, §10) — a place inside a
    /// section, which the standing rule says is findable by name.
    case showBlockedMachines
    /// Settings › Remote's activity history (spec §8, §10, Task 20) — the
    /// daemon-witnessed log of what a remote viewer did, read back and
    /// grouped by connection. Findable by name for the same reason
    /// `showBlockedMachines` is: it is a place inside a section.
    case showRemoteActivity
    /// The takeover panel's two verbs (spec §7), reachable by typing rather
    /// than only by finding the buttons. Present only while somebody is
    /// actually connected — there is nothing to terminate otherwise.
    case terminateRemoteConnection
    case blockRemoteConnection
    /// Self-update, in its three takeable forms. Like the account rows
    /// above, only the one the current state actually allows becomes a row —
    /// offering "Restart to Update" with nothing downloaded is a dead end.
    case checkForUpdates
    case downloadUpdate
    case restartToUpdate
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
    /// A Help page — the privacy policy or the third-party notices — opened
    /// in the default browser.
    case openLegal(LegalDocument)
    /// **Connect to ‹machine›** (2026-09-01 remote environment sharing spec
    /// §6/§10, Task 24/25) — swaps this window onto that machine's daemon
    /// through the connect ceremony. Disabled (`PaletteCommand.isEnabled`)
    /// for the entire time another session is already live
    /// (`RemoteSessionPicker.canConnect`); see that type's doc comment for
    /// why this is belt-and-braces over the daemon's own structural refusal
    /// rather than the guarantee itself.
    case connectRemoteMachine(deviceID: String)
    /// **End remote session** — present only while `activeRemoteSession !=
    /// nil` (spec §10); swaps this window back onto its own daemon.
    case endRemoteSession
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
    /// Where things are — workspaces, the destinations, the Settings
    /// sections. The spotlight is for *finding*; the verbs (new pane, close,
    /// interrupt…) left it on 2026-08-28, since a search that lists commands
    /// is a menu.
    case places = "Places"
    case brain = "Brain"
    /// Last: a loose query fits half a repository, and the files it fits
    /// must not stand between the user and the categories that fit better.
    case files = "Files"

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

/// One online machine from the relay's device list — the spotlight's own
/// copy of `RemoteMachine`. Task 29 collapses the projection this used to
/// carry (workspaces, sessions, panes) away entirely: a viewer's app now
/// swaps its whole connection onto the host's daemon, so there is nothing
/// below the machine for a row to name any more — see `connectRemoteMachine`.
struct PaletteRemoteMachine: Equatable {
    let deviceID: String
    let name: String
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
    /// Whether Return or a click actually runs `action`. `true` for every
    /// row that existed before 2026-09-02 — the palette had no disabled rows
    /// until **Connect to ‹machine›** needed one (spec §3, Task 25): shown
    /// so it stays findable and explains itself (`subtitle` carries the
    /// reason), but inert, the same "announced but disabled" shape
    /// `WorkspacesHeaderMenus.plus` already draws for its own remote item.
    let isEnabled: Bool

    init(
        id: String,
        title: String,
        detail: String?,
        action: PaletteAction,
        keywords: String? = nil,
        section: PaletteSection = .places,
        subtitle: String? = nil,
        symbol: String? = nil,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.action = action
        self.keywords = keywords
        self.section = section
        self.subtitle = subtitle
        self.symbol = symbol
        self.isEnabled = isEnabled
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
    /// How many rows a category shows in the All view before its "Show
    /// more" row — enough to see it is there, few enough to reach the next
    /// one without scrolling.
    static let sectionPreview = 5
    /// How many more each press of the row reveals; the last press, with no
    /// more than this left, says "Show all" instead.
    static let sectionStep = 10
    /// Rows revealed past the preview, per category the user has clicked
    /// open. A new query folds them back.
    private(set) var revealed: [PaletteSection: Int] = [:]

    /// What the account row answers to in either state. Its title says half
    /// of what it is — "Log out" is not found by typing "sign out", and
    /// "Sign in with Apple…" is not found by typing "account" — so both
    /// states carry both vocabularies.
    static let accountKeywords = "log out sign out sign in account apple settings"

    /// The GitHub row's vocabulary, both states again: "connect" does not
    /// find "Disconnect GitHub" and "disconnect" does not find "Connect
    /// GitHub…", and neither title contains the word "account" it lives
    /// under.
    static let githubKeywords = "github connect disconnect account settings"

    /// Rebuilt from the live workspace every time the palette opens, so it
    /// can never offer a pane that closed while it was shut.
    static func build(
        panes: [PaneDescriptor],
        paneOrder: [String],
        focusedPaneID: String?,
        projectLabels: [String: String] = [:],
        /// The sidebar's open workspaces, in its order, with their display
        /// names — so a workspace with nothing running is still findable.
        workspaces: [PaletteWorkspace] = [],
        /// What Settings › Accounts currently shows, which decides whether
        /// the account row logs out or signs in.
        signedIn: Bool = false,
        /// The same, for the GitHub row: connected offers Disconnect.
        githubConnected: Bool = false,
        /// What the relay reports online right now — every machine and each
        /// of its shared sessions becomes a row (the remote-session-control
        /// spec's §4 "Spotlight").
        remoteMachines: [PaletteRemoteMachine] = [],
        /// What the self-update controller is doing, which decides which of
        /// the three update rows is offered.
        updateState: UpdateState = .idle,
        /// Whether sharing can be switched on at all — an
        /// `auth_account_email` row exists. Defaults to `false`, fail-closed
        /// like every other reading of this: a signed-out Mac has no device
        /// registration to share with, and offering the switch there is
        /// offering a button whose every outcome is a refusal.
        canShareEnvironment: Bool = false,
        /// The machine driving this Mac right now, by name — `nil` when
        /// nobody is. Decides whether Terminate/Block are rows at all.
        liveRemoteMachine: String? = nil,
        /// How many machines are blocked, for the blocked-list row's detail.
        blockedMachineCount: Int = 0,
        /// The machine **this** Mac is driving right now (Task 25,
        /// `RemoteSharingModel.activeRemoteSession`) — the opposite
        /// direction from `liveRemoteMachine` above. Non-`nil` disables
        /// every **Connect to ‹machine›** row (`RemoteSessionPicker
        /// .canConnect`'s reasoning) and adds **End remote session**.
        activeRemoteSession: RemoteSessionInfo? = nil
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
        // Connect to ‹machine› (spec §6/§10, Task 24/25): swaps this window
        // onto that machine's daemon through the connect ceremony — a
        // different action from the rows just above, which open one shared
        // *pane* without disturbing this window's own environment.
        // Disabled, with the reason as the subtitle, for the entire time a
        // session is already live — `RemoteSessionPicker`'s own doc comment
        // explains why this is belt-and-braces rather than the guarantee.
        for machine in remoteMachines {
            let disabledReason = activeRemoteSession.map { "End the session with \($0.machineName) first" }
            commands.append(
                PaletteCommand(
                    id: "remote-connect:\(machine.deviceID)",
                    title: "Connect to \(machine.name)",
                    detail: nil,
                    action: .connectRemoteMachine(deviceID: machine.deviceID),
                    keywords: "connect remote takeover drive machine \(machine.name)",
                    section: .places,
                    subtitle: disabledReason ?? "Take over \(machine.name)",
                    symbol: "desktopcomputer.and.arrow.down",
                    isEnabled: activeRemoteSession == nil
                )
            )
        }
        // End remote session — present only while this Mac is driving one
        // (spec §10's own "present only while a session is live").
        if let activeRemoteSession {
            commands.append(
                PaletteCommand(
                    id: "remote:end-session",
                    title: "End remote session",
                    detail: activeRemoteSession.machineName,
                    action: .endRemoteSession,
                    keywords: "end remote session disconnect stop driving \(activeRemoteSession.machineName)",
                    section: .places,
                    subtitle: "Return to this Mac's own environment",
                    symbol: "arrow.uturn.backward"
                )
            )
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
        commands.append(
            PaletteCommand(
                id: "session:new-branch",
                title: "New Branch Session…",
                detail: nil,
                action: .startBranchSession,
                keywords: "new session branch worktree terminal create",
                section: .places,
                subtitle: "Sessions",
                symbol: "arrow.triangle.branch"
            )
        )
        // The sidebar's own destinations, by name. `allCases` rather than a
        // hand-written list: a new destination should appear here the day it
        // appears in the sidebar, not the day someone remembers this.
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
        // The two tabs *inside* the Insights page — the standing rule again:
        // the items in a page are findable as soon as the page is real.
        // `allCases`, so a third tab appears here the day it is added.
        for tab in InsightsTab.allCases {
            commands.append(
                PaletteCommand(
                    id: "insights:\(tab.title.lowercased())",
                    title: "Insights › \(tab.title)",
                    detail: nil,
                    action: .showInsightsTab(tab),
                    keywords: "insights usage tokens sessions activity timeline",
                    section: .places,
                    subtitle: "Insights",
                    symbol: "chart.bar.xaxis"
                )
            )
        }
        // The sidebar foot's other row. Settings is already a destination
        // row above; Help is a menu, and this is the only other place its
        // name is written down.
        commands.append(
            PaletteCommand(
                id: "sidebar:help",
                title: "Help",
                detail: nil,
                action: .showHelp,
                keywords: "help support docs privacy notices",
                section: .places,
                subtitle: "Sidebar",
                symbol: "questionmark.circle"
            )
        )
        // The title bar's own pair, which are places in the window's chrome
        // rather than in the sidebar — hence the "Title bar" subtitle.
        commands.append(
            PaletteCommand(
                id: "titlebar:notifications",
                title: "Notifications",
                detail: nil,
                action: .showNotifications,
                keywords: "notifications bell alerts",
                section: .places,
                subtitle: "Title bar",
                symbol: "bell"
            )
        )
        commands.append(
            PaletteCommand(
                id: "titlebar:account",
                title: "Account",
                detail: nil,
                action: .showAccountMenu,
                keywords: "account profile avatar me",
                section: .places,
                subtitle: "Title bar",
                symbol: "person.crop.circle"
            )
        )
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
        // The things *inside* a Settings section that are rows of their own
        // (the standing rule: the spotlight finds the items in the sections
        // as they are built). One row per button, not two: signing out and
        // signing in are the same button in two states — as are connecting
        // and disconnecting GitHub — and offering the one you cannot do is
        // offering a dead end.
        commands.append(
            signedIn
                ? PaletteCommand(
                    id: "settings:accounts:logout",
                    title: "Log out",
                    detail: nil,
                    action: .signOut,
                    keywords: accountKeywords,
                    section: .places,
                    subtitle: "Settings › Accounts",
                    symbol: "person.crop.circle.badge.xmark"
                )
                : PaletteCommand(
                    id: "settings:accounts:signin",
                    title: "Sign in with Apple…",
                    detail: nil,
                    action: .signIn,
                    keywords: accountKeywords,
                    section: .places,
                    subtitle: "Settings › Accounts",
                    symbol: "person.crop.circle.badge.checkmark"
                )
        )
        commands.append(
            githubConnected
                ? PaletteCommand(
                    id: "settings:accounts:github:disconnect",
                    title: "Disconnect GitHub",
                    detail: nil,
                    action: .disconnectGitHub,
                    keywords: githubKeywords,
                    section: .places,
                    subtitle: "Settings › Accounts",
                    // Not `link.slash`, which reads better and does not
                    // exist: no macOS SF Symbols release ships it, so it
                    // would draw as nothing at all.
                    symbol: "personalhotspot.slash"
                )
                : PaletteCommand(
                    id: "settings:accounts:github:connect",
                    title: "Connect GitHub…",
                    detail: nil,
                    action: .connectGitHub,
                    keywords: githubKeywords,
                    section: .places,
                    subtitle: "Settings › Accounts",
                    symbol: "link.badge.plus"
                )
        )
        // The destructive third button, offered only where it can be taken.
        if signedIn {
            commands.append(
                PaletteCommand(
                    id: "settings:accounts:delete",
                    title: "Delete account…",
                    detail: nil,
                    action: .deleteAccount,
                    keywords: accountKeywords + " delete remove erase",
                    section: .places,
                    subtitle: "Settings › Accounts",
                    symbol: "person.crop.circle.badge.minus"
                )
            )
        }
        // Settings › Remote's switch (2026-09-01 remote environment sharing
        // spec §10). One verb whichever way it is thrown, so unlike the
        // account pairs above there is one row rather than two — but it is
        // offered only where it can be taken: a Mac nobody is signed in to
        // has no account to share with, and the switch itself refuses there
        // (`RemoteSharingModel.setSharing`).
        if canShareEnvironment {
            commands.append(
                PaletteCommand(
                    id: "settings:remote:toggle-sharing",
                    title: "Share this environment",
                    detail: nil,
                    action: .toggleRemoteSharing,
                    keywords: "remote share sharing screen access connect environment",
                    section: .places,
                    subtitle: "Settings › Remote",
                    symbol: "antenna.radiowaves.left.and.right"
                )
            )
        }
        // The blocked list, which is a place inside that section — always a
        // row, empty or not: "nothing is blocked" is an answer somebody types
        // this to get.
        commands.append(
            PaletteCommand(
                id: "settings:remote:blocked",
                title: "Blocked machines",
                detail: blockedMachineCount == 0
                    ? nil
                    : (blockedMachineCount == 1 ? "1 machine" : "\(blockedMachineCount) machines"),
                action: .showBlockedMachines,
                keywords: "blocked block unblock remote machines banned refused allow",
                section: .places,
                subtitle: "Settings › Remote",
                symbol: "hand.raised"
            )
        )
        // Activity (spec §8, §10, Task 20) — a place inside the section,
        // `showBlockedMachines`'s own reasoning: always a row, so "nothing
        // has happened here" is still something the section can say.
        commands.append(
            PaletteCommand(
                id: "settings:remote:activity",
                title: "Remote activity",
                detail: nil,
                action: .showRemoteActivity,
                keywords: "remote activity history log connections viewers audit",
                section: .places,
                subtitle: "Settings › Remote",
                symbol: "list.bullet.rectangle"
            )
        )
        // Terminate and Block, while there is a connection to end (spec §7,
        // §10) — the takeover panel's two buttons, typeable. Absent
        // otherwise, the same one-row-only-where-it-can-be-taken rule the
        // account rows follow.
        if let liveRemoteMachine {
            commands.append(
                PaletteCommand(
                    id: "remote:terminate",
                    title: "Terminate connection",
                    detail: liveRemoteMachine,
                    action: .terminateRemoteConnection,
                    keywords: "terminate disconnect kick end remote connection "
                        + "stop \(liveRemoteMachine)",
                    section: .places,
                    subtitle: "\(liveRemoteMachine) may connect again",
                    symbol: "bolt.horizontal.circle"
                )
            )
            commands.append(
                PaletteCommand(
                    id: "remote:block",
                    title: "Block this machine",
                    detail: liveRemoteMachine,
                    action: .blockRemoteConnection,
                    keywords: "block ban refuse kick remote connection \(liveRemoteMachine)",
                    section: .places,
                    subtitle: "Until you unblock it in Settings › Remote",
                    symbol: "hand.raised.slash"
                )
            )
        }
        // Self-update. One row, whichever one can be taken right now — the
        // same rule the account pair follows. `Spotlight finds everything`
        // (the repo's standing rule) is why these exist at all: the sidebar
        // widget is a thing you can navigate to, so it is typeable.
        let updateKeywords = "update upgrade version release download install new sparkle"
        switch updateState {
        case let .available(version):
            commands.append(
                PaletteCommand(
                    id: "update:download",
                    title: "Download Update",
                    detail: version,
                    action: .downloadUpdate,
                    keywords: updateKeywords,
                    section: .places,
                    subtitle: "Version \(version) is available",
                    symbol: "arrow.down.circle"
                )
            )
        case let .readyToRestart(version):
            commands.append(
                PaletteCommand(
                    id: "update:restart",
                    title: "Restart to Update",
                    detail: version.isEmpty ? nil : version,
                    action: .restartToUpdate,
                    keywords: updateKeywords + " restart relaunch quit",
                    section: .places,
                    subtitle: "Ends any running terminal sessions",
                    symbol: "checkmark.circle"
                )
            )
        case .idle, .failed:
            commands.append(
                PaletteCommand(
                    id: "update:check",
                    title: "Check for Updates",
                    detail: nil,
                    action: .checkForUpdates,
                    keywords: updateKeywords + " check",
                    section: .places,
                    subtitle: "Settings › General",
                    symbol: "arrow.triangle.2.circlepath"
                )
            )
        // Nothing to offer while a check or a download is already running.
        case .checking, .updating:
            break
        }
        // The Help menu's two pages. Everything navigable is findable, and a
        // privacy policy nobody can locate is the same as not having one.
        for doc in LegalDocument.allCases {
            commands.append(
                PaletteCommand(
                    id: "help:\(doc.rawValue)",
                    title: doc.title,
                    detail: nil,
                    action: .openLegal(doc),
                    keywords: "help legal privacy licence license trademark",
                    section: .places,
                    subtitle: "Help",
                    symbol: doc == .privacyPolicy ? "hand.raised" : "doc.text"
                )
            )
        }
        // In section order whatever the order above emitted them in, so a
        // heading is a walk over consecutive rows — and Files really is last.
        return PaletteSection.allCases.flatMap { section in commands.filter { $0.section == section } }
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
        // A tag shows its category whole: the cap exists to skip past a long
        // category to the next one, and under a tag there is no next.
        let rows = selectedSection.map { section in found.filter { $0.section == section } }
            ?? Self.previewed(found, revealed: revealed)
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

    /// The All view's cap: `sectionPreview` rows per category plus whatever
    /// has been revealed, then one row standing for the rest — "Show 10
    /// more" while more than a step remains, "Show all" for the tail.
    static func previewed(_ rows: [PaletteCommand], revealed: [PaletteSection: Int]) -> [PaletteCommand] {
        var out: [PaletteCommand] = []
        for section in PaletteSection.allCases {
            let run = rows.filter { $0.section == section }
            let shown = sectionPreview + (revealed[section] ?? 0)
            guard run.count > shown else {
                out += run
                continue
            }
            let remaining = run.count - shown
            out += run.prefix(shown)
            out.append(
                PaletteCommand(
                    id: "show-more:\(section.rawValue)",
                    title: remaining > sectionStep ? "Show \(sectionStep) more" : "Show all",
                    detail: "\(remaining) more",
                    action: .showMore(section),
                    section: section,
                    symbol: "ellipsis"
                )
            )
        }
        return out
    }

    mutating func reveal(section: PaletteSection) {
        revealed[section, default: 0] += Self.sectionStep
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
        revealed = [:]
    }

    /// Typing always returns the highlight to the top: the best match for a
    /// new query is never "wherever the cursor happened to be".
    mutating func update(query: String) {
        self.query = query
        selectedIndex = 0
        revealed = [:]
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
