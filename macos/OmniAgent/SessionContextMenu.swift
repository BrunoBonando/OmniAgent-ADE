import AppKit

// The session row's right-click menu — the 2026-08-20 redesign's §3
// (docs/superpowers/specs/2026-08-20-copilot-nav-redesign-design.md). Menu
// construction is pure here, `WorkspaceContextMenu`'s pattern:
// `WorkspaceWindowController` resolves the session (its pin state, its cwd,
// which external apps are installed) and owns what the items do.

enum SessionContextMenu {
    /// One installed app the Open in… submenu offers: the display name and
    /// the app bundle `NSWorkspace` resolved for its bundle id.
    struct OpenTarget: Equatable {
        let name: String
        let url: URL
    }

    /// The spec's candidate list, in menu order. Only the ones actually
    /// installed make the submenu — see `installedApps`.
    static let candidateApps: [(name: String, bundleID: String)] = [
        ("VS Code", "com.microsoft.VSCode"),
        ("VS Code Insiders", "com.microsoft.VSCodeInsiders"),
        ("Terminal", "com.apple.Terminal"),
        ("Cursor", "com.todesktop.230313mzl4w4u92"),
        ("Xcode", "com.apple.dt.Xcode"),
        ("iTerm", "com.googlecode.iterm2"),
        ("Warp", "dev.warp.Warp-Stable"),
        ("Ghostty", "com.mitchellh.ghostty"),
    ]

    /// The candidates the locator resolves, in candidate order. The default
    /// locator is the real `NSWorkspace` bundle-id lookup; tests substitute
    /// a fixed one, and `WorkspaceWindowController.appLocator` is the same
    /// seam one level up.
    static func installedApps(
        locator: (String) -> URL? = {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)
        }
    ) -> [OpenTarget] {
        candidateApps.compactMap { candidate in
            locator(candidate.bundleID).map { OpenTarget(name: candidate.name, url: $0) }
        }
    }

    /// The spec's shape: Rename · Pin/Unpin session · Open in… (only when
    /// something is installed) · Create nested session · separator · Delete
    /// session, red — the one destructive thing on the menu says so before
    /// it is read.
    static func build(
        pinned: Bool,
        openIn targets: [OpenTarget],
        rename: @escaping () -> Void,
        togglePin: @escaping () -> Void,
        openInApp: @escaping (OpenTarget) -> Void,
        createNested: @escaping () -> Void,
        delete: @escaping () -> Void
    ) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(ShellMenuItem("Rename", handler: rename))
        menu.addItem(ShellMenuItem(pinned ? "Unpin session" : "Pin session", handler: togglePin))
        if !targets.isEmpty {
            let openItem = NSMenuItem(title: "Open in…", action: nil, keyEquivalent: "")
            let submenu = NSMenu(title: "Open in…")
            submenu.autoenablesItems = false
            for target in targets {
                submenu.addItem(ShellMenuItem(target.name) { openInApp(target) })
            }
            openItem.submenu = submenu
            menu.addItem(openItem)
        }
        menu.addItem(ShellMenuItem("Create nested session", handler: createNested))
        menu.addItem(.separator())
        let deleteItem = ShellMenuItem("Delete session", handler: delete)
        deleteItem.attributedTitle = NSAttributedString(
            string: "Delete session",
            attributes: [
                .foregroundColor: ShellPalette.red,
                .font: NSFont.menuFont(ofSize: 0),
            ]
        )
        menu.addItem(deleteItem)
        return menu
    }
}
