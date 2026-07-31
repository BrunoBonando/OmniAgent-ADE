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
        let connection = SessionConnection(socketURL: Self.socketURL)
        let workspace = WorkspaceWindowController(
            connection: connection,
            sessionID: "native-terminal"
        )
        self.workspace = workspace
        workspace.showWindow(nil)
        workspace.start()
        NSApp.activate(ignoringOtherApps: true)
        os_signpost(
            .end,
            log: Instrumentation.log,
            name: "Application Launch",
            signpostID: launchSignpost
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        workspace?.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private static var socketURL: URL {
        if let override = ProcessInfo.processInfo.environment["OMNIAGENT_PTY_SOCKET"] {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".omniagent-ade", isDirectory: true)
            .appendingPathComponent("omniagent-pty.sock")
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
        file.addItem(item("Close Pane", Selector(("closePane:")), "w"))
        file.addItem(
            item("Close Window", #selector(NSWindow.performClose(_:)), "w", [.command, .shift])
        )

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
        for index in 1...PaneGrid.maxPanes {
            let selection = item("Pane \(index)", Selector(("selectPane:")), "\(index)")
            selection.tag = index
            panes.addItem(selection)
        }

        let window = NSMenu(title: "Window")
        main.addItem(withSubmenu: window)
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
