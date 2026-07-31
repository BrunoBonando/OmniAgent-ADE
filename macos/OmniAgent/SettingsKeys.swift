import Foundation

/// The `settings` table rows the native app shares with the web/Tauri build.
///
/// Both builds open the same `brain.db` (Task 6a pinned the daemon to
/// `Store::default_data_dir()` for exactly this reason), so a row written by
/// one is read by the other. Every constant here therefore has to be the
/// exact string its TypeScript twin declares, and each doc comment names
/// that twin so the pair cannot drift silently.
///
/// Only the keys this build actually reads or writes live here. The rest of
/// the settings surface the web app owns — `review_memory`,
/// `auth_gate_resolved`/`auth_signed_in`/`auth_persona`,
/// `closed_workspaces`, `file_tree_visible`/`file_tree_width`,
/// `code_review_width`, `usage_analytics_v1` — is deliberately absent rather
/// than declared-and-unused: a constant nothing reads is a claim this build
/// honours a setting it does not.
enum SettingsKey {
    /// `ui/src/state/sessions.ts`'s `LAYOUT_SETTING_KEY`. One JSON object,
    /// `{"tabs": PersistedTab[]}` — see `PersistedLayoutCodec`.
    static let layout = "layout"

    /// `ui/src/state/notifications.ts`'s `NOTIFICATIONS_SETTING_KEY`. One
    /// JSON object, `{"entries": NotificationEntry[]}` — see
    /// `NotificationFeedCodec`.
    static let notifications = "notifications"
}
