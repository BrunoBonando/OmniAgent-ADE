import AppKit
import os.signpost

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let launchSignpost = OSSignpostID(log: Instrumentation.log)
    private var workspace: WorkspaceWindowController?

    override init() {
        super.init()
        os_signpost(
            .begin,
            log: Instrumentation.log,
            name: "Application Launch",
            signpostID: launchSignpost
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        ApplicationMenus.install()
        let paths = Self.daemonPaths
        // Task 6c: register (or fall back to spawning) the daemon *before*
        // the socket connect attempt begins, so degraded mode's own spawn
        // has a head start on the connection's first retry.
        let daemonPersistence = DaemonPersistenceController(paths: paths)
        daemonPersistence.start()
        let connection = SessionConnection(socketURL: paths.socketURL)
        let delivery = UserNotificationDelivery()
        // No panes yet: the window opens immediately, and `start()` fills it
        // from the shared `layout` row the moment the socket comes up. The
        // window must not wait on the daemon — a daemon that is slow (or not
        // running) has to produce a visible window saying so, not no window.
        let workspace = WorkspaceWindowController(
            connection: connection,
            panes: [],
            notifier: SessionNotifier(delivery: delivery),
            daemonPersistence: daemonPersistence
        )
        delivery.onActivate = { [weak workspace] sessionID in
            workspace?.revealPane(sessionID)
        }
        self.workspace = workspace
        workspace.showWindow(nil)
        workspace.start()
        workspace.notifier.requestAuthorization()
        NSApp.activate(ignoringOtherApps: true)
        os_signpost(
            .end,
            log: Instrumentation.log,
            name: "Application Launch",
            signpostID: launchSignpost
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Deliberately does not touch the daemon process or its PTY
        // sessions in either persistence mode — see
        // `DaemonPersistenceController.stop()`'s doc comment and the Task
        // 6c report's "termination cleanup" section.
        workspace?.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Task 6c's channel-aware path resolution. Production's result is
    /// byte-identical to this property's pre-6c literal (see
    /// `DaemonPersistenceTests`), so this is a resolution-mechanism change,
    /// not a behavior change, for every build shipped so far.
    private static var daemonPaths: DaemonPaths {
        DaemonPaths.resolve(
            channel: DaemonBuildChannel.resolve(bundleIdentifier: Bundle.main.bundleIdentifier)
        )
    }
}

enum ApplicationMenus {
    static func install() {
        let main = NSMenu(title: "Main")
        NSApp.mainMenu = main

        let application = NSMenu(title: "OmniAgent")
        main.addItem(withSubmenu: application)
        application.addItem(
            item("About OmniAgent", #selector(NSApplication.orderFrontStandardAboutPanel(_:)))
        )
        application.addItem(.separator())
        // Task 6b-2's SwiftUI settings screen — the standard macOS
        // Settings/Preferences slot (⌘,), traveling the responder chain
        // like every other command in this app.
        application.addItem(item("Settings…", Selector(("showSettings:")), ","))
        application.addItem(.separator())
        let services = NSMenu(title: "Services")
        application.addItem(withSubmenu: services, title: "Services")
        NSApp.servicesMenu = services
        application.addItem(.separator())
        application.addItem(item("Hide OmniAgent", #selector(NSApplication.hide(_:)), "h"))
        application.addItem(
            item(
                "Hide Others",
                #selector(NSApplication.hideOtherApplications(_:)),
                "h",
                [.command, .option]
            )
        )
        application.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:))))
        application.addItem(.separator())
        application.addItem(item("Quit OmniAgent", #selector(NSApplication.terminate(_:)), "q"))

        let file = NSMenu(title: "File")
        main.addItem(withSubmenu: file)
        file.addItem(item("New Terminal Pane", Selector(("newTerminalPane:")), "t"))
        file.addItem(item("New Browser Pane", Selector(("newBrowserPane:")), "t", [.command, .shift]))
        file.addItem(item("New Session", Selector(("newSession:")), "n"))
        file.addItem(item("Close Pane", Selector(("closePane:")), "w"))
        file.addItem(
            item("Close Window", #selector(NSWindow.performClose(_:)), "w", [.command, .shift])
        )
        file.addItem(.separator())
        file.addItem(item("Command Palette", Selector(("showCommandPalette:")), "k"))

        let edit = NSMenu(title: "Edit")
        main.addItem(withSubmenu: edit)
        edit.addItem(item("Copy", Selector(("copy:")), "c"))
        edit.addItem(item("Paste", Selector(("paste:")), "v"))
        edit.addItem(item("Select All", Selector(("selectAll:")), "a"))

        let session = NSMenu(title: "Session")
        main.addItem(withSubmenu: session)
        session.addItem(item("Interrupt", Selector(("interruptSession:")), "."))
        session.addItem(
            item("Kill Session", Selector(("killSession:")), "k", [.command, .control])
        )
        session.addItem(item("Reattach", Selector(("reattachSession:")), "r"))
        session.addItem(item("Focus Terminal", Selector(("focusTerminal:")), "l"))
        // Focus *mode* — the pane blown up over the others on a blurred
        // backdrop — not the item above, which only moves keyboard focus
        // into the terminal. ⌘↩ is Bruno's own binding, chosen over the
        // design hint text's ⌃⌘F.
        session.addItem(item("Focus This Terminal", Selector(("toggleFocusMode:")), "\r"))
        session.addItem(.separator())
        session.addItem(
            item(
                "Use Option as Meta",
                Selector(("toggleOptionAsMeta:")),
                "o",
                [.command, .option]
            )
        )

        // Pane commands travel the responder chain (target nil): directional
        // focus and swap land on PaneWorkspaceView, pane lifecycle on
        // WorkspaceWindowController.
        let panes = NSMenu(title: "Panes")
        main.addItem(withSubmenu: panes)
        let directions: [(String, String, Selector, Selector)] = [
            ("Left", arrowKey(NSLeftArrowFunctionKey), Selector(("focusPaneLeft:")), Selector(("swapPaneLeft:"))),
            ("Right", arrowKey(NSRightArrowFunctionKey), Selector(("focusPaneRight:")), Selector(("swapPaneRight:"))),
            ("Up", arrowKey(NSUpArrowFunctionKey), Selector(("focusPaneUp:")), Selector(("swapPaneUp:"))),
            ("Down", arrowKey(NSDownArrowFunctionKey), Selector(("focusPaneDown:")), Selector(("swapPaneDown:"))),
        ]
        for (name, key, focus, _) in directions {
            panes.addItem(item("Focus \(name)", focus, key, [.command, .option]))
        }
        panes.addItem(.separator())
        for (name, key, _, swap) in directions {
            panes.addItem(item("Move Pane \(name)", swap, key, [.command, .control]))
        }
        panes.addItem(.separator())
        // A key equivalent only up to nine: there is no single keystroke for
        // "10", and handing AppKit a two-character equivalent gives an item
        // that draws a nonsense shortcut and never fires. Panes 10-12 are still
        // here as menu items (and still reachable from the palette and the
        // grid); they simply have no ⌘ shortcut.
        for index in 1...PaneGrid.maxPanes {
            let key = index <= 9 ? "\(index)" : ""
            let selection = item("Pane \(index)", Selector(("selectPane:")), key)
            selection.tag = index
            panes.addItem(selection)
        }

        let window = NSMenu(title: "Window")
        main.addItem(withSubmenu: window)
        // ⌃⌘S rather than AppKit's own ⌃⌘S-free default: `toggleSidebar:` here
        // is the workspace controller's, not `NSSplitViewController`'s, so the
        // palette row and this item run the same method.
        window.addItem(
            item("Toggle Sidebar", Selector(("toggleSidebar:")), "s", [.command, .control])
        )
        // Task 6b-2's per-project brain-context panel, scoped to the
        // focused pane's project.
        window.addItem(item("Show Inspector", Selector(("showInspectorPanel:")), "i"))
        window.addItem(.separator())
        window.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        window.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
        NSApp.windowsMenu = window
    }

    private static func arrowKey(_ functionKey: Int) -> String {
        guard let scalar = UnicodeScalar(UInt32(functionKey)) else { return "" }
        return String(Character(scalar))
    }

    private static func item(
        _ title: String,
        _ action: Selector,
        _ key: String = "",
        _ modifiers: NSEvent.ModifierFlags = [.command]
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = nil
        item.keyEquivalentModifierMask = modifiers
        return item
    }
}

private extension NSMenu {
    func addItem(withSubmenu submenu: NSMenu, title: String? = nil) {
        let item = NSMenuItem()
        item.title = title ?? submenu.title
        item.submenu = submenu
        addItem(item)
    }
}
