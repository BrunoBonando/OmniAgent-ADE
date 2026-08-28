import Foundation

/// The `settings` table rows the native app shares with the web/Tauri build.
///
/// Both builds open the same `brain.db` (Task 6a pinned the daemon to
/// `Store::default_data_dir()` for exactly this reason), so a row written by
/// one is read by the other. Every constant here therefore has to be the
/// exact string its TypeScript twin declares, and each doc comment names
/// that twin so the pair cannot drift silently.
///
/// 6b-1 declared only `layout`/`notifications` here — the two rows that
/// build read/wrote — deliberately leaving the rest absent rather than
/// declared-and-unused ("a constant nothing reads is a claim this build
/// honours a setting it does not"). Task 6b-2 adds the rest as it consumes
/// them: every key below now has at least one reader or writer somewhere in
/// `SettingsStore`'s callers, except `closedWorkspaces` and `fileTreeVisible`
/// — see their own doc comments for why those two are declared without one.
enum SettingsKey {
    /// `ui/src/state/sessions.ts`'s `LAYOUT_SETTING_KEY`. One JSON object,
    /// `{"tabs": PersistedTab[]}` — see `PersistedLayoutCodec`.
    static let layout = "layout"

    /// `ui/src/state/notifications.ts`'s `NOTIFICATIONS_SETTING_KEY`. One
    /// JSON object, `{"entries": NotificationEntry[]}` — see
    /// `NotificationFeedCodec`.
    static let notifications = "notifications"

    /// `ui/src/lib/tauri.ts`'s `REVIEW_MEMORY_SETTING_KEY`. `"true"`/`"false"`
    /// — the Settings screen's Review section toggle.
    static let reviewMemory = "review_memory"

    /// `ui/src/onboarding/authGateState.ts`'s `AUTH_GATE_RESOLVED_SETTING_KEY`.
    /// `"true"` once the gate has been shown and resolved either path. Still
    /// written for the web build and for Settings, but no longer what the
    /// native launch gate latches on — that is `authSignedIn`, mirrored into
    /// `UserDefaults`; see `AuthGate.needsSignIn(_:)`.
    static let authGateResolved = "auth_gate_resolved"

    /// `ui/src/onboarding/authGateState.ts`'s `AUTH_SIGNED_IN_SETTING_KEY`.
    /// `"true"`/`"false"`; unset reads as signed in — see
    /// `AuthGate.resolveSignedIn(_:)`.
    static let authSignedIn = "auth_signed_in"

    /// `ui/src/onboarding/authGateState.ts`'s `AUTH_PERSONA_SETTING_KEY`. The
    /// chosen `PersonaOption.id`, or `""`.
    static let authPersona = "auth_persona"

    /// **No TypeScript twin yet — this is a native-first row.** Real login
    /// (Core's `/v1/auth/login` via `AuthClient`) shipped in the native app
    /// only; `ui/src/onboarding/authGateState.ts` still implements the fake
    /// gate and declares no key for this. The signed-in account's email
    /// address, or `""` when sign-in was skipped. If the web build ever gains
    /// real login, its constant must be this exact string.
    static let authAccountEmail = "auth_account_email"

    /// **No TypeScript twin yet — this is a native-first row**, for the same
    /// reason as `authAccountEmail` above. The account's display name
    /// ("Bruno Bonando"), or `""` when the server has none or sign-in was
    /// skipped.
    static let authAccountName = "auth_account_name"

    /// **No TypeScript twin yet — this is a native-first row**, for the same
    /// reason as `authAccountEmail` above. The URL of the account's profile
    /// picture as Core reports it (`picture` on `UserResponse`), or `""` when
    /// the account has none or sign-in was skipped. The URL rather than the
    /// image bytes: the row is a settings string, and the sidebar fetches
    /// and caches what it points at itself.
    static let authAccountPicture = "auth_account_picture"

    /// **No TypeScript twin yet — this is a native-first row**, for the same
    /// reason as `authAccountEmail` above. The GitHub handle linked to the
    /// account ("brunobonando"), written without the `@` the Accounts
    /// section prints, or `""` when GitHub is not connected. Written by
    /// `AuthGateCoordinator.persist` from `AuthUser.githubLogin` and by
    /// Settings › Accounts' own Connect/Disconnect pair.
    static let authGithubLogin = "auth_github_login"

    /// `ui/src/state/closedWorkspaces.ts`'s `CLOSED_WORKSPACES_SETTING_KEY`.
    /// One JSON array of workspace ids — see `ClosedWorkspacesCodec`, which
    /// matches the web codec's shape exactly because the row is shared.
    /// Wired here by the sidebar's Remove-workspace path (the 2026-08-20
    /// redesign's workspace context menu): removing a workspace closes its
    /// sessions and records the id here, exactly what the web app's
    /// close-workspace control writes — a window-close, never a delete; the
    /// folder and everything ingested from it stay untouched.
    static let closedWorkspaces = "closed_workspaces"

    /// `ui/src/lib/tauri.ts`'s `FILE_TREE_VISIBLE_SETTING_KEY`. Declared for
    /// schema completeness only, matching that file's own doc comment: the
    /// key has been dead in the web app itself since the left-pane redesign
    /// embedded the file tree permanently in the sidebar. Nothing here reads
    /// or writes it either, for the same reason.
    static let fileTreeVisible = "file_tree_visible"

    /// `ui/src/lib/tauri.ts`'s `FILE_TREE_WIDTH_SETTING_KEY`. Decimal-string
    /// pixels — the Settings screen's Panels section.
    static let fileTreeWidth = "file_tree_width"

    /// `ui/src/lib/tauri.ts`'s `CODE_REVIEW_WIDTH_SETTING_KEY`. Decimal-string
    /// pixels — the Settings screen's Panels section.
    static let codeReviewWidth = "code_review_width"

    /// `ui/src/state/usageAnalytics.ts`'s `USAGE_ANALYTICS_SETTING_KEY`. One
    /// JSON object, `{version, projects}` — see `UsageAnalyticsCodec`.
    static let usageAnalytics = "usage_analytics_v1"

    /// Native-only — deliberately NOT shared with the web build. Browser panes
    /// must stay out of the shared `layout` row: the web codec drops
    /// unknown-engine tabs and strips unknown fields on rewrite, so a browser
    /// tab persisted there would be destroyed by the next web-side save. One
    /// JSON object, `{"panes":[{url, group?, groupLabel?}]}` — see
    /// `BrowserPanesCodec`. No TypeScript twin, by design.
    static let browserPanes = "browser_panes_native"

    /// Native-only — `browserPanes`'s reasoning applied to editor panes: the
    /// web codec would destroy this shape on its next `layout` rewrite. One
    /// JSON object, `{"panes":[{tabs:[{path,kind,pinned}],active,group?,groupLabel?}]}`
    /// — see `EditorPanesCodec`. No TypeScript twin, by design.
    static let editorPanes = "editor_panes_native"

    /// Native-only — the sidebar's per-workspace customizations (the
    /// 2026-08-20 redesign's Customize… dialog): display name and folder
    /// colour, keyed by workspace path. One JSON object,
    /// `{"workspaces":{"<path>":{"name"?,"color"?}}}` — see
    /// `WorkspaceCustomizationsCodec`. No TypeScript twin, by design.
    static let workspaceCustomizations = "workspace_customizations_native"

    /// Native-only — the session context menu's per-session facts (the
    /// 2026-08-20 redesign's §3): the pin and the nested-session parent,
    /// keyed by session group id. Its own row for `browserPanes`'s reason —
    /// fields on the shared `layout` row would be stripped by the web
    /// build's next rewrite. One JSON object,
    /// `{"sessions":{"<group id>":{"pinned"?,"parent"?}}}` — see
    /// `SessionMetaCodec`. No TypeScript twin, by design.
    static let sessionMeta = "session_meta_native"

    /// Native-only — the review panel's per-session state (the 2026-08-20
    /// redesign's §5): open/closed, the open tabs and the active one, the
    /// panel width, and the Files tab's preferences, keyed by session group
    /// id. Its own row for `browserPanes`'s reason. One JSON object,
    /// `{"sessions":{"<group id>":{open,tabs,activeTab,width?,openFile?,treePosition?,showHidden?}}}`
    /// — see `ReviewPanelStateCodec`. No TypeScript twin, by design.
    static let reviewPanel = "review_panel_native"

    /// Native-only — `browserPanes`'s reasoning a third time: the web build
    /// rewrites the shared `layout` row and strips the fields it does not
    /// know, and it knows nothing about a canvas. The Desk canvas's pinned
    /// node positions and last camera; unpinned nodes are recomputed by
    /// `DeskCanvas.layout` every launch and are not stored. One JSON object,
    /// `{"version":1,"pinned":{<node id>:{x,y}},"camera":{scale,x,y}}` — see
    /// `DeskCanvasCodec`. No TypeScript twin, by design.
    static let deskCanvas = "desk_canvas_native"
}
