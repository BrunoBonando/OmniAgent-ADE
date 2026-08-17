import Foundation

/// One pane a launch should rebuild, derived from the persisted `layout`
/// row. Everything needed to make the pane exist again, and nothing about
/// how it is drawn — `PaneWorkspaceView` owns that.
struct RestoredPane: Equatable {
    /// The id the pane's session will be addressed by. Either the id the
    /// persisted tab carried, or a freshly minted one.
    let sessionID: String
    /// True when the persisted tab carried a usable id, i.e. the daemon may
    /// still own a live session under it and the pane should reattach
    /// rather than start something new.
    ///
    /// False means the id was missing, malformed or a duplicate and a fresh
    /// one was minted — the same "restore as a new session rather than
    /// disappear" repair `PersistedLayoutCodec.deserialize` applies one
    /// level down, carried through to the pane that repair produced.
    let reattaches: Bool
    let project: String
    let engine: Engine
    let cwd: String
    let label: String?
    let themeId: TerminalThemeId?
    /// Never `nil`: an ungrouped tab restores into
    /// `WorkspaceRestoration.ungroupedSessionID`, exactly as the web build's
    /// `tab.group ?? UNGROUPED_SESSION_ID` reads it.
    let group: String
    let groupLabel: String?
    /// What the pane holds. The shared `layout` row only ever describes
    /// terminals; a `.browser` pane restores from its own native-only row.
    let kind: PaneKind
    /// The URL a `.browser` pane last showed — cwd's role, for a browser.
    let browserURL: String

    /// Explicit, with defaults on the two kind fields, so every call site
    /// written against the old memberwise init compiles unchanged.
    init(
        sessionID: String,
        reattaches: Bool,
        project: String,
        engine: Engine,
        cwd: String,
        label: String?,
        themeId: TerminalThemeId?,
        group: String,
        groupLabel: String?,
        kind: PaneKind = .terminal,
        browserURL: String = ""
    ) {
        self.sessionID = sessionID
        self.reattaches = reattaches
        self.project = project
        self.engine = engine
        self.cwd = cwd
        self.label = label
        self.themeId = themeId
        self.group = group
        self.groupLabel = groupLabel
        self.kind = kind
        self.browserURL = browserURL
    }
}

/// Reads and writes the `layout` settings row on behalf of the workspace —
/// the launch-time "which panes existed last time" question, and its
/// inverse.
///
/// Deliberately pure and free of `SessionConnection`: the transport belongs
/// to `WorkspaceWindowController`, the repair rules belong here, and that
/// split is what makes every rule below testable without a socket.
enum WorkspaceRestoration {
    /// `ui/src/state/sessions.ts`'s `UNGROUPED_SESSION_ID` — the sentinel a
    /// pane with no stored `group` reads as. It is deliberately a valid
    /// `SessionIdentifier` (`[A-Za-z0-9_-]`), so it can travel through the
    /// same pane-descriptor field a real group id does.
    static let ungroupedSessionID = "__ungrouped__"

    /// The panes to rebuild from a raw `layout` settings value.
    ///
    /// Layered on top of `PersistedLayoutCodec.deserialize`'s per-field
    /// repair (a bad `themeId` costs the field, a bad `engine` costs the
    /// tab) rather than re-implementing any of it. What this adds is the
    /// two repairs that only make sense once tabs become *panes*:
    ///
    /// - **the pane cap** — a layout claiming more panes than the app will
    ///   run restores its first `limit` rather than being rejected wholesale.
    ///   This is the app-wide `PaneWorkspaceView.maxTerminals`; the
    ///   eight-per-*session* cap is enforced by `PaneWorkspaceView.addPane`
    ///   at the other end, which is the only place that knows which session
    ///   each pane is joining;
    /// - **a fresh id for every tab that lost its own** — the tab still
    ///   restores, as a new session, which is the whole point of
    ///   `deserialize` keeping an id-less tab in the first place.
    static func plan(
        fromLayout raw: String?,
        limit: Int = PaneWorkspaceView.maxTerminals,
        makeSessionID: () -> String = { UUID().uuidString }
    ) -> [RestoredPane] {
        plan(from: PersistedLayoutCodec.deserialize(raw), limit: limit, makeSessionID: makeSessionID)
    }

    static func plan(
        from tabs: [PersistedTab],
        limit: Int = PaneWorkspaceView.maxTerminals,
        makeSessionID: () -> String = { UUID().uuidString }
    ) -> [RestoredPane] {
        guard limit > 0 else { return [] }
        var used = Set(tabs.compactMap(\.id))
        return tabs.prefix(limit).map { tab in
            var reattaches = true
            var sessionID = tab.id
            if sessionID == nil {
                sessionID = mintSessionID(makeSessionID, avoiding: &used)
                reattaches = false
            }
            return RestoredPane(
                sessionID: sessionID ?? UUID().uuidString,
                reattaches: reattaches,
                project: tab.project,
                engine: tab.engine,
                cwd: tab.cwd,
                label: tab.label,
                themeId: tab.themeId,
                group: tab.group ?? ungroupedSessionID,
                groupLabel: tab.groupLabel
            )
        }
    }

    /// A minted id must clear the same two bars a restored one already
    /// cleared: the backend's `[A-Za-z0-9_-]{1,96}` gate, and uniqueness
    /// within this plan (a duplicate would make `PaneWorkspaceView.addPane`
    /// silently refuse the second pane). An injected generator that fails
    /// either falls back to a UUID, which always passes both.
    private static func mintSessionID(
        _ makeSessionID: () -> String,
        avoiding used: inout Set<String>
    ) -> String {
        var candidate = makeSessionID()
        if !SessionIdentifier.isValid(candidate) || used.contains(candidate) {
            repeat { candidate = UUID().uuidString } while used.contains(candidate)
        }
        used.insert(candidate)
        return candidate
    }

    /// The panes, back in the shape the `layout` row stores — the inverse of
    /// `plan`, so closing, reordering or renaming a pane survives the next
    /// launch.
    ///
    /// **A pane with no project is not persisted.** `PersistedTab.project`
    /// names a project in the brain, and this build has no project picker
    /// yet (the `roots_*` surface is not routed through the daemon), so a
    /// natively-opened ad-hoc pane has no honest value to put there.
    /// Writing `""` would hand the web build a nameless workspace row in a
    /// database the two apps share; dropping the pane instead keeps the row
    /// truthful and costs only that pane's restoration, which is a session
    /// the native build could not have restored into a project anyway.
    static func persistedTabs(from panes: [PaneDescriptor]) -> [PersistedTab] {
        panes.compactMap { pane in
            guard !pane.project.isEmpty else { return nil }
            return PersistedTab(
                project: pane.project,
                engine: pane.engine,
                cwd: pane.cwd,
                id: pane.sessionID,
                label: pane.label,
                themeId: pane.themeId,
                // The ungrouped sentinel is the *absence* of a group, and
                // the web build stores absence by omitting the field.
                group: pane.group == ungroupedSessionID ? nil : pane.group,
                groupLabel: pane.groupLabel
            )
        }
    }

    /// The one pane a launch with nothing to restore opens on — the same
    /// shell, home directory and ungrouped session the Task 4/5 bootstrap
    /// pane already used, expressed as a plan so there is exactly one code
    /// path from "a list of `RestoredPane`" to "panes on screen".
    static func bootstrapPane(sessionID: String = UUID().uuidString) -> RestoredPane {
        RestoredPane(
            sessionID: sessionID,
            reattaches: false,
            project: "",
            engine: .shell,
            cwd: FileManager.default.homeDirectoryForCurrentUser.path,
            label: nil,
            themeId: nil,
            group: ungroupedSessionID,
            groupLabel: nil
        )
    }
}
