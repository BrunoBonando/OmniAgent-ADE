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
    /// `"true"` once the gate has been shown and resolved either path — see
    /// `AuthGate.alreadyResolved(_:)`.
    static let authGateResolved = "auth_gate_resolved"

    /// `ui/src/onboarding/authGateState.ts`'s `AUTH_SIGNED_IN_SETTING_KEY`.
    /// `"true"`/`"false"`; unset reads as signed in — see
    /// `AuthGate.resolveSignedIn(_:)`.
    static let authSignedIn = "auth_signed_in"

    /// `ui/src/onboarding/authGateState.ts`'s `AUTH_PERSONA_SETTING_KEY`. The
    /// chosen `PersonaOption.id`, or `""`.
    static let authPersona = "auth_persona"

    /// `ui/src/state/closedWorkspaces.ts`'s `CLOSED_WORKSPACES_SETTING_KEY`.
    /// Declared for schema completeness (it is one shared `brain.db` row,
    /// same as every other key here) but not read or written by this build:
    /// "closed workspaces" names the web app's closeable per-project tab
    /// strip, a concept this build's session-outline/pane model does not
    /// have. A future native project picker is the natural place to wire it,
    /// not this task's settings/onboarding/usage/inspector surface.
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
}
