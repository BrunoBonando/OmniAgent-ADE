import AppKit
import os.signpost

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let launchSignpost = OSSignpostID(log: Instrumentation.log)
    private var workspace: WorkspaceWindowController?
    private var menuBar: MenuBarController?

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
        menuBar = MenuBarController(workspace: workspace)
        // `start()` before anything is shown: the socket comes up behind the
        // login window, so signing in costs no wait for the daemon.
        workspace.start()
        workspace.notifier.requestAuthorization()
        NSApp.activate(ignoringOtherApps: true)
        // The gate is what puts the first window on screen. Deliberately not
        // `showWindow` first and a sheet after: a workspace flashing up behind
        // a login is the app admitting the login is decoration.
        workspace.presentLaunchGate {
            workspace.showWindow(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
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

    /// `false`: the menu bar icon is the point of staying alive with the
    /// window closed — closing it (`WorkspaceWindowController.windowShouldClose`)
    /// just hides it now, it does not quit the app.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// The Dock icon's standard reopen gesture, now that the window can be
    /// hidden without the app quitting — the same "bring it to the front"
    /// the menu bar icon's own items do.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        workspace?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        return true
    }

    /// How the deferred answer gets back to AppKit. A seam because
    /// `NSApp.reply(toApplicationShouldTerminate:)` outside a real
    /// termination sequence does nothing a test can observe.
    var replyToTermination: (Bool) -> Void = { NSApp.reply(toApplicationShouldTerminate: $0) }

    /// ⌘Q must not throw away unsaved editor buffers. Every workspace window
    /// holding any is walked with save prompts; one cancel anywhere stops the
    /// quit. A session with nothing unsaved quits immediately — no deferral,
    /// no run-loop turn.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let dirty = Self.controllersThatMayHaveUnsavedWork(in: sender.windows)
        guard !dirty.isEmpty else { return .terminateNow }
        // Deferred by one run-loop turn, and that is not a detail:
        // `reply(toApplicationShouldTerminate:)` is only valid *after*
        // `.terminateLater` has been returned. The default `confirmSave` is a
        // synchronous `runModal`, so the whole walk would otherwise finish
        // inside this call and reply too early — AppKit drops that reply and
        // then waits for one that never comes, leaving the app unquittable.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            promptDirtyEditorTabs(in: dirty) { [weak self] proceed in
                self?.replyToTermination(proceed)
            }
        }
        return .terminateLater
    }

    /// Every workspace window that *could* be holding unsaved work, in window
    /// order and deduplicated — a controller can own more than one window, and
    /// must be asked about its panes exactly once.
    ///
    /// Deliberately "could", not "does". Whether a buffer is dirty is a
    /// question only the page can answer, and asking it is asynchronous; a
    /// synchronous "nothing is dirty" here would be read off flags that lag a
    /// keystroke, and would quit the app over it. A window with no editor
    /// buffers at all is the one case that can be ruled out for free.
    static func controllersThatMayHaveUnsavedWork(in windows: [NSWindow]) -> [WorkspaceWindowController] {
        var seen = Set<ObjectIdentifier>()
        return windows
            .compactMap { $0.windowController as? WorkspaceWindowController }
            .filter { seen.insert(ObjectIdentifier($0)).inserted }
            .filter(\.mayHaveUnsavedEditorWork)
    }

    /// One window at a time, chained: each controller's prompts answer on a
    /// callback. Internal so a test can drive the walk without staging a real
    /// application termination.
    func promptDirtyEditorTabs(
        in controllers: [WorkspaceWindowController],
        completion: @escaping (Bool) -> Void
    ) {
        guard let next = controllers.first else {
            completion(true)
            return
        }
        next.promptDirtyEditorTabs { [weak self] proceed in
            guard proceed, let self else {
                completion(false)
                return
            }
            promptDirtyEditorTabs(in: Array(controllers.dropFirst()), completion: completion)
        }
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
        file.addItem(item("New Editor Pane", Selector(("newEditorPane:")), "e", [.command, .shift]))
        file.addItem(item("New Session", Selector(("newSession:")), "n"))
        file.addItem(.separator())
        file.addItem(item("Save", Selector(("saveActiveFile:")), "s"))
        file.addItem(item("Save All", Selector(("saveAllFiles:")), "s", [.command, .option]))
        file.addItem(.separator())
        file.addItem(item("Close Pane", Selector(("closePane:")), "w"))
        file.addItem(
            item("Close Window", #selector(NSWindow.performClose(_:)), "w", [.command, .shift])
        )
        file.addItem(.separator())
        // ⌃Space, Spotlight's own shape. macOS ships "Select the previous
        // input source" on the same chord, but only binds it once a second
        // keyboard layout exists; ⌘K stays as the alternative for anyone it
        // does collide with.
        file.addItem(item("Spotlight", Selector(("showCommandPalette:")), " ", [.control]))
        file.addItem(spotlightAlternate())

        let edit = NSMenu(title: "Edit")
        main.addItem(withSubmenu: edit)
        edit.addItem(item("Copy", Selector(("copy:")), "c"))
        edit.addItem(item("Paste", Selector(("paste:")), "v"))
        edit.addItem(item("Select All", Selector(("selectAll:")), "a"))

        let view = NSMenu(title: "View")
        main.addItem(withSubmenu: view)
        // Session-scoped — `validateMenuItem` enables it whenever a session
        // is on screen, since the panel reviews that session.
        view.addItem(
            item("Toggle Review Panel", Selector(("toggleReviewPanel:")), "b", [.command, .option])
        )
        view.addItem(.separator())
        // ⌃⌘F, the system-standard chord. AppKit fills this item in for apps
        // that let it build the View menu; these menus are hand-built, so
        // without it the window's green button is the only way in or out.
        view.addItem(
            item("Toggle Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control])
        )

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

        // The Desk destination's own commands — the spatial canvas, not one
        // terminal. A separate menu from "Session" above, which is deliberately
        // left as it is: its items (Interrupt, Kill Session, Reattach) are one
        // PTY's verbs, and the user-facing Session these commands move between
        // is a *group* of those. Renaming that menu would be churn in an
        // unrelated place; naming this one after the destination it belongs to
        // keeps the two apart where the user looks for them.
        let desk = NSMenu(title: "Desk")
        main.addItem(withSubmenu: desk)
        desk.addItem(item("Enter Session", Selector(("enterFocusedSession:"))))
        desk.addItem(.separator())
        // ⇧⌘[ / ⇧⌘], the system's own previous/next-tab chords, both unbound
        // here. The web build steps sessions with ⌃↑/⌃↓, which collide with
        // Mission Control and App Exposé.
        desk.addItem(item("Previous Session", Selector(("previousSession:")), "[", [.command, .shift]))
        desk.addItem(item("Next Session", Selector(("nextSession:")), "]", [.command, .shift]))
        desk.addItem(.separator())
        // ⌃1…⌃9, the `selectPane:` loop's shape with Control instead of
        // Command: no plain-Control chord but ⌃Space (Spotlight) is bound
        // anywhere in this app. macOS ships "Switch to Desktop N" on the same
        // chords once a second Desktop exists, and the system binding wins —
        // ⌥⌘1…⌥⌘9 is the fallback if that ever bites.
        for index in 1...9 {
            let selection = item("Session \(index)", Selector(("selectSession:")), "\(index)", [.control])
            selection.tag = index
            desk.addItem(selection)
        }

        let window = NSMenu(title: "Window")
        main.addItem(withSubmenu: window)
        // ⌃⌘S rather than AppKit's own ⌃⌘S-free default. The selector is
        // deliberately NOT `toggleSidebar:`: `NSSplitViewController` is the
        // content view controller and answers that name earlier in the
        // responder chain, where it refuses to validate — there is no
        // `.sidebar`-behavior item for it to act on.
        window.addItem(
            item("Toggle Sidebar", Selector(("toggleWorkspaceSidebar:")), "s", [.command, .control])
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

    /// The same command on ⌘K, shown only while ⌥ is held: one visible row,
    /// two chords, no second line of menu clutter.
    private static func spotlightAlternate() -> NSMenuItem {
        let item = item("Spotlight", Selector(("showCommandPalette:")), "k")
        item.isAlternate = true
        item.keyEquivalentModifierMask = [.command]
        return item
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
