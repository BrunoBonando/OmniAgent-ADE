import AppKit

/// The window's toolbar. Four items, each one a command that already exists
/// somewhere else (a menu item, a palette row) — a toolbar button that is the
/// only way to reach something would be a fifth place for the same behaviour
/// to drift.
///
/// Every item targets `nil` so it travels the responder chain exactly like
/// the menu items do, which is also what makes `validateMenuItem`/
/// `validateToolbarItem` agree without a second enablement rule.
extension WorkspaceWindowController: NSToolbarDelegate, NSToolbarItemValidation {
    enum ToolbarItem {
        static let sidebar = NSToolbarItem.Identifier("digital.bruno.omniagent.toolbar.sidebar")
        static let newPane = NSToolbarItem.Identifier("digital.bruno.omniagent.toolbar.new-pane")
        static let newBrowser = NSToolbarItem.Identifier("digital.bruno.omniagent.toolbar.new-browser")
        static let newEditor = NSToolbarItem.Identifier("digital.bruno.omniagent.toolbar.new-editor")
        static let closePane = NSToolbarItem.Identifier("digital.bruno.omniagent.toolbar.close-pane")
        static let palette = NSToolbarItem.Identifier("digital.bruno.omniagent.toolbar.palette")
    }

    func installToolbar(on window: NSWindow) {
        let toolbar = NSToolbar(identifier: "digital.bruno.omniagent.workspace")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        window.toolbar = toolbar
        window.toolbarStyle = .unified
    }

    public func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            ToolbarItem.sidebar,
            .sidebarTrackingSeparator,
            ToolbarItem.newPane,
            ToolbarItem.newBrowser,
            ToolbarItem.newEditor,
            ToolbarItem.closePane,
            .flexibleSpace,
            ToolbarItem.palette,
        ]
    }

    public func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + [.space, .flexibleSpace]
    }

    public func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier identifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch identifier {
        case ToolbarItem.sidebar:
            return item(identifier, "Sidebar", "sidebar.leading", #selector(toggleSidebar(_:)))
        case ToolbarItem.newPane:
            return item(identifier, "New Pane", "plus.rectangle", #selector(newTerminalPane(_:)))
        case ToolbarItem.newBrowser:
            return item(identifier, "New Browser", "globe", #selector(newBrowserPane(_:)))
        case ToolbarItem.newEditor:
            return item(identifier, "New Editor", "doc.text", #selector(newEditorPane(_:)))
        case ToolbarItem.closePane:
            return item(identifier, "Close Pane", "xmark.rectangle", #selector(closePane(_:)))
        case ToolbarItem.palette:
            return item(identifier, "Commands", "command", #selector(showCommandPalette(_:)))
        default:
            return nil
        }
    }

    private func item(
        _ identifier: NSToolbarItem.Identifier,
        _ label: String,
        _ symbol: String,
        _ action: Selector
    ) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = label
        item.paletteLabel = label
        item.toolTip = label
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        item.target = nil
        item.action = action
        item.isBordered = true
        return item
    }

    public func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        guard let action = item.action else { return true }
        // One enablement rule, shared with the menu — `validateMenuItem`
        // already answers for every action these buttons carry.
        let probe = NSMenuItem(title: item.label, action: action, keyEquivalent: "")
        return validateMenuItem(probe)
    }
}
