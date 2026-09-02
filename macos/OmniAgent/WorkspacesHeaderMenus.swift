import AppKit

// The Workspaces section header's two menus and the grouping rules behind
// them — the 2026-08-20 redesign's §2
// (docs/superpowers/specs/2026-08-20-copilot-nav-redesign-design.md). The
// menus are pure construction here; `NavigationSidebarView` owns the buttons
// that pop them and the seams their items fire, and `WorkspacesTreeView`
// renders the shape the group-by choice selects.

/// How the Workspaces section arranges its sessions. Persisted by raw value
/// (`WorkspacesTreeView.groupModeDefaultsKey`), so the cases' strings are a
/// tiny contract with past launches.
enum WorkspacesGroupMode: String, CaseIterable {
    case project
    case status
    case lastUpdated = "last-updated"

    var title: String {
        switch self {
        case .project: return "Project"
        case .status: return "Status"
        case .lastUpdated: return "Last updated"
        }
    }
}

/// The two grouping rules that are not "the workspace tree": Status mode's
/// buckets and Last-updated mode's ordering. Pure functions over the same
/// inputs the tree renders from, so the shapes are testable without a view.
enum WorkspacesGrouping {
    /// Status mode's three buckets, in the order they render.
    enum Bucket: CaseIterable {
        case needsAttention
        case working
        case idle

        var title: String {
            switch self {
            case .needsAttention: return "Needs attention"
            case .working: return "Working"
            case .idle: return "Idle"
            }
        }
    }

    /// Which bucket one session belongs to, aggregated over its panes: a pane
    /// asking or broken outranks work in progress, which outranks quiet —
    /// the same precedence the row's amber-over-blue dot colours imply.
    static func bucket(
        for session: SessionGroupNode,
        statuses: [String: RemoteSessionStatus]
    ) -> Bucket {
        let panes = session.paneIDs.map { statuses[$0] }
        if panes.contains(where: { $0 == .awaitingApproval || $0 == .error }) {
            return .needsAttention
        }
        if panes.contains(where: { $0 == .thinking || $0 == .toolExecution }) {
            return .working
        }
        return .idle
    }

    /// Sessions bucketed for Status mode. Only buckets with members are
    /// returned — an empty header would be a claim about sessions that do not
    /// exist. Within a bucket the incoming order (the tree's) is kept.
    static func statusBuckets(
        _ sessions: [SessionGroupNode],
        statuses: [String: RemoteSessionStatus]
    ) -> [(title: String, sessions: [SessionGroupNode])] {
        Bucket.allCases.compactMap { bucket in
            let members = sessions.filter { self.bucket(for: $0, statuses: statuses) == bucket }
            return members.isEmpty ? nil : (bucket.title, members)
        }
    }

    /// Last-updated mode's order: the session whose panes most recently
    /// reported a status event first; sessions that never reported one keep
    /// their incoming order at the end. Sorted by explicit index because
    /// `sorted` promises nothing about stability.
    static func lastUpdatedFirst(
        _ sessions: [SessionGroupNode],
        eventTimes: [String: Double]
    ) -> [SessionGroupNode] {
        sessions.enumerated()
            .sorted { a, b in
                let ta = latestEvent(a.element, eventTimes)
                let tb = latestEvent(b.element, eventTimes)
                if ta != tb { return ta > tb }
                return a.offset < b.offset
            }
            .map(\.element)
    }

    private static func latestEvent(
        _ session: SessionGroupNode,
        _ eventTimes: [String: Double]
    ) -> Double {
        session.paneIDs.compactMap { eventTimes[$0] }.max() ?? -.infinity
    }
}

/// An `NSMenuItem` that runs a closure. The header's menus are built by a
/// view with per-workspace items, and a selector per workspace has nowhere
/// to live; the item is its own target, so the menu retaining its items
/// keeps the handler alive exactly as long as the menu.
final class ShellMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    @objc private func fire() { handler() }

    /// What a click does, callable from a test without running the menu.
    func performForTesting() { handler() }
}

/// The two menus themselves, in the spec's exact shape. `autoenablesItems`
/// is off on both: which items are choices and which are titles (or the
/// disabled remote future) is decided here, not by responder-chain
/// validation.
enum WorkspacesHeaderMenus {
    /// "Group by" title, then Project / Status / Last updated with a
    /// checkmark on the current mode.
    static func groupBy(
        current: WorkspacesGroupMode,
        select: @escaping (WorkspacesGroupMode) -> Void
    ) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(sectionTitle("Group by"))
        for mode in WorkspacesGroupMode.allCases {
            let item = ShellMenuItem(mode.title) { select(mode) }
            item.state = mode == current ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    /// "Start session in" over one item per workspace, "Add project from"
    /// over the local-folder chooser, then Resume remote session… behind a
    /// separator — alive when the caller can open the picker of the other
    /// Macs' shared sessions (the phase 2 spec's §4 "The + menu picker",
    /// `RemoteSessionPickerController`), the announced-but-disabled future
    /// for callers that cannot (the menu bar's copy).
    static func plus(
        workspaces: [(id: String, label: String)],
        startSession: @escaping (String) -> Void,
        addLocalFolder: @escaping () -> Void,
        resumeRemoteSession: (() -> Void)? = nil,
        /// Why the item below is disabled, shown as its tooltip — `nil`
        /// leaves the pre-2026-09-01 "announced future" copy with no reason
        /// attached (`resumeRemoteSession == nil` because nothing has wired
        /// it up yet, as opposed to `resumeRemoteSession == nil` because a
        /// takeover is live right now).
        remoteSessionDisabledReason: String? = nil
    ) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(sectionTitle("Start session in"))
        for workspace in workspaces {
            menu.addItem(ShellMenuItem(workspace.label) { startSession(workspace.id) })
        }
        menu.addItem(sectionTitle("Add project from"))
        menu.addItem(ShellMenuItem("Local folder or repository…", handler: addLocalFolder))
        menu.addItem(.separator())
        let remoteImage = NSImage(
            systemSymbolName: "desktopcomputer.and.arrow.down",
            accessibilityDescription: "Resume remote session"
        )
        if let resumeRemoteSession {
            let remote = ShellMenuItem("Resume remote session…", handler: resumeRemoteSession)
            remote.image = remoteImage
            menu.addItem(remote)
        } else {
            let remote = NSMenuItem(title: "Resume remote session…", action: nil, keyEquivalent: "")
            remote.isEnabled = false
            remote.image = remoteImage
            remote.toolTip = remoteSessionDisabledReason
            menu.addItem(remote)
        }
        return menu
    }

    private static func sectionTitle(_ title: String) -> NSMenuItem {
        let item = NSMenuItem.sectionHeader(title: title)
        item.isEnabled = false
        return item
    }
}
