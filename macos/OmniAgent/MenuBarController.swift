import AppKit

// The menu bar status item: a persistent icon showing how many sessions,
// terminals and working agents are open, the last 5 active sessions, and a
// way to create a new one — the reason the app is menu-bar-resident now
// (`AppDelegate.applicationShouldTerminateAfterLastWindowClosed` is `false`,
// `WorkspaceWindowController.windowShouldClose` hides rather than closes).

/// What the dropdown shows — assembled fresh every time it opens by
/// `WorkspaceWindowController.menuBarSummary()`, so there is no second copy
/// of session state to keep in sync.
struct MenuBarSummary: Equatable {
    struct RecentSession: Equatable {
        let id: String
        let label: String
        let project: String
        let projectLabel: String
        let firstPaneID: String
    }

    struct RecentWorkspace: Equatable {
        let project: String
        let label: String
    }

    var sessionCount = 0
    var terminalCount = 0
    var workingCount = 0
    /// Most-recently-focused first, capped at 5.
    var recentSessions: [RecentSession] = []
    /// The recent sessions' distinct projects, same order, capped at 5 —
    /// "Create Session"'s candidate list.
    var recentWorkspaces: [RecentWorkspace] = []
}

/// The status icon's three states (2026-09-01 remote environment sharing
/// spec §2). `.off`/`.sharing` are real as of Task 4; `.connected` is
/// reachable and correct once something sets it, but nothing does yet —
/// that is the live remote lease, Task 16's.
enum MenuBarShareState { case off, sharing, connected }

/// Pure menu construction, `SessionContextMenu.build`'s pattern: no AppKit
/// state, no target/action — just data in and closures for what each item
/// does, so it is testable without a real `NSStatusItem`.
enum MenuBarMenu {
    static func build(
        into menu: NSMenu,
        summary: MenuBarSummary,
        accountLabel: String,
        shareState: MenuBarShareState,
        revealSession: @escaping (String) -> Void,
        createInWorkspace: @escaping (String) -> Void,
        chooseFolder: @escaping () -> Void,
        toggleSharing: @escaping () -> Void,
        showSettings: @escaping () -> Void,
        quit: @escaping () -> Void
    ) {
        menu.removeAllItems()
        menu.autoenablesItems = false

        // The item exists only while signed in, and its first line says for
        // whom (2026-08-30 spec: "logged in as {name}").
        menu.addItem(disabledItem(accountLine(accountLabel)))
        menu.addItem(disabledItem(headline(summary)))

        if !summary.recentSessions.isEmpty {
            menu.addItem(.separator())
            var lastProject: String?
            for session in summary.recentSessions {
                if session.project != lastProject {
                    menu.addItem(disabledItem(session.projectLabel))
                    lastProject = session.project
                }
                let item = ShellMenuItem(session.label) { revealSession(session.firstPaneID) }
                item.indentationLevel = 1
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        let createItem = NSMenuItem(title: "Create Session…", action: nil, keyEquivalent: "")
        createItem.submenu = WorkspacesHeaderMenus.plus(
            workspaces: summary.recentWorkspaces.map { (id: $0.project, label: $0.label) },
            startSession: createInWorkspace,
            addLocalFolder: chooseFolder
        )
        menu.addItem(createItem)

        menu.addItem(.separator())
        // The sharing switch (§2, §10) — above Settings…, checkmarked
        // exactly like `WorkspacesHeaderMenus.groupBy`'s current-mode rows.
        let shareItem = ShellMenuItem("Share this environment", handler: toggleSharing)
        shareItem.state = shareState == .off ? .off : .on
        menu.addItem(shareItem)
        menu.addItem(.separator())
        menu.addItem(ShellMenuItem("Settings…", handler: showSettings))
        menu.addItem(.separator())
        menu.addItem(ShellMenuItem("Quit", handler: quit))
    }

    /// The status icon for each of the three sharing states. Green means the
    /// machine is reachable; blue means someone is on it right now. Tinting
    /// requires `isTemplate = false`, so the icon stops adapting to the menu
    /// bar's appearance — deliberate: the whole point is that it stops
    /// looking ordinary.
    static func shareIcon(_ state: MenuBarShareState) -> NSImage {
        let base = NSImage(named: "OmniAgentMark") ?? NSImage()
        let size = NSSize(width: 18, height: 18)
        guard let tint: NSColor = {
            switch state {
            case .off: return nil
            case .sharing: return .systemGreen
            case .connected: return .systemBlue
            }
        }() else {
            let image = base.copy() as! NSImage
            image.size = size
            image.isTemplate = true
            return image
        }
        let image = NSImage(size: size, flipped: false) { rect in
            base.draw(in: rect)
            tint.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        image.isTemplate = false
        return image
    }

    /// "2 sessions · 3 terminals · 1 working agent" — the three counts the
    /// icon exists to answer at a glance.
    static func headline(_ summary: MenuBarSummary) -> String {
        [
            plural(summary.sessionCount, "session"),
            plural(summary.terminalCount, "terminal"),
            plural(summary.workingCount, "working agent"),
        ].joined(separator: " · ")
    }

    /// "Logged in as Bruno Bonando" — `auth_account_name`, falling back to
    /// the email (`WorkspaceWindowController.accountDisplayLabel`); just
    /// "Logged in" until the rows have been read.
    static func accountLine(_ label: String) -> String {
        label.isEmpty ? "Logged in" : "Logged in as \(label)"
    }

    private static func plural(_ count: Int, _ noun: String) -> String {
        "\(count) \(noun)\(count == 1 ? "" : "s")"
    }

    private static func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }
}

/// Owns the status item. There is exactly one workspace window in this app,
/// so a weak reference to it is all the icon needs — `AppDelegate` keeps it
/// alive for as long as the app runs.
final class MenuBarController: NSObject, NSMenuDelegate {
    /// Not `private`: `refreshShareIcon`'s test reads `statusItem.button
    /// .image` back to confirm what actually got drawn.
    let statusItem: NSStatusItem
    private weak var workspace: WorkspaceWindowController?

    init(workspace: WorkspaceWindowController) {
        self.workspace = workspace
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        // Seeds the real state at construction (sharing may already be on
        // from a previous launch) rather than the flat template `shareIcon`
        // would otherwise sit under until the menu is first opened.
        refreshShareIcon()
    }

    /// Released by `AppDelegate` on log-out: the item leaves the menu bar
    /// with the controller, not at the app's exit.
    deinit {
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    /// Rebuilt right before it opens rather than kept live — the same reason
    /// `hoverCardModel` is pull, not push: cheap to assemble, and never
    /// stale by however long the icon has been sitting there.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let workspace else { return }
        MenuBarMenu.build(
            into: menu,
            summary: workspace.menuBarSummary(),
            accountLabel: workspace.accountDisplayLabel,
            shareState: shareState,
            revealSession: { [weak workspace] paneID in workspace?.revealPane(paneID) },
            createInWorkspace: { [weak workspace] projectID in
                guard let workspace else { return }
                workspace.startSession(
                    inDirectory: workspace.workspaceDirectory(for: projectID) ?? "",
                    project: projectID
                )
            },
            chooseFolder: { [weak workspace] in workspace?.openWorkspaceFolder(nil) },
            toggleSharing: { [weak workspace] in workspace?.toggleRemoteSharing() },
            showSettings: { [weak workspace] in workspace?.showSettings(nil) },
            quit: { NSApp.terminate(nil) }
        )
    }

    /// This controller's own reading of the sharing state — `.off`/`.sharing`
    /// off `workspace.isSharingEnvironment`; `.connected` is not wired to
    /// anything yet (Task 16's live lease).
    private var shareState: MenuBarShareState {
        workspace?.isSharingEnvironment == true ? .sharing : .off
    }

    /// Redraws the status item's icon from the current sharing state —
    /// called once at construction and again on every `RemoteSharingModel
    /// .onChange`, by way of `WorkspaceWindowController.onRemoteSharingChanged`
    /// (`AppDelegate` wires the two together). Unlike `menuNeedsUpdate`, this
    /// has to be push: the icon must show green the instant sharing is
    /// switched on from Settings, not only the next time someone opens the
    /// menu.
    func refreshShareIcon() {
        guard let button = statusItem.button else { return }
        // The asset is 256pt; a status button draws it at natural size,
        // which at menu bar height is an invisible smear — `shareIcon`
        // scales every state to the standard 18pt status-icon size, and
        // `.off`'s template rendering is what makes it white on a dark menu
        // bar.
        button.image = MenuBarMenu.shareIcon(shareState)
    }
}
