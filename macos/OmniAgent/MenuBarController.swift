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

/// Pure menu construction, `SessionContextMenu.build`'s pattern: no AppKit
/// state, no target/action — just data in and closures for what each item
/// does, so it is testable without a real `NSStatusItem`.
enum MenuBarMenu {
    static func build(
        into menu: NSMenu,
        summary: MenuBarSummary,
        revealSession: @escaping (String) -> Void,
        createInWorkspace: @escaping (String) -> Void,
        chooseFolder: @escaping () -> Void,
        showSettings: @escaping () -> Void,
        quit: @escaping () -> Void
    ) {
        menu.removeAllItems()
        menu.autoenablesItems = false

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
        menu.addItem(ShellMenuItem("Settings…", handler: showSettings))
        menu.addItem(.separator())
        menu.addItem(ShellMenuItem("Quit", handler: quit))
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
    private let statusItem: NSStatusItem
    private weak var workspace: WorkspaceWindowController?

    init(workspace: WorkspaceWindowController) {
        self.workspace = workspace
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        if let button = statusItem.button {
            let image = NSImage(named: "OmniAgentMark")
            image?.isTemplate = true
            button.image = image
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    /// Rebuilt right before it opens rather than kept live — the same reason
    /// `hoverCardModel` is pull, not push: cheap to assemble, and never
    /// stale by however long the icon has been sitting there.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let workspace else { return }
        MenuBarMenu.build(
            into: menu,
            summary: workspace.menuBarSummary(),
            revealSession: { [weak workspace] paneID in workspace?.revealPane(paneID) },
            createInWorkspace: { [weak workspace] projectID in
                guard let workspace else { return }
                workspace.startSession(
                    inDirectory: workspace.workspaceDirectory(for: projectID) ?? "",
                    project: projectID
                )
            },
            chooseFolder: { [weak workspace] in workspace?.openWorkspaceFolder(nil) },
            showSettings: { [weak workspace] in workspace?.showSettings(nil) },
            quit: { NSApp.terminate(nil) }
        )
    }
}
