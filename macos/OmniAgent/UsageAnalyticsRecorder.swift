import Foundation

/// The stateful shell around `UsageAnalytics`'s pure store: tracks which
/// panes/sessions have already been counted as "opened" and each live
/// session's current status/since, so `UsageAnalytics.recordStatusDuration`
/// can be fed incrementally as events arrive, then persists the store
/// through the derive-then-persist shape `SessionNotifier` already
/// established for the notification feed.
///
/// Fed from `WorkspaceWindowController`'s existing `SessionConnection`
/// callbacks (`onStatus`/`onExit`) plus its own pane-creation call site
/// (`recordPaneOpened`) — `SessionConnection` has no "session opened" event
/// of its own; a pane coming into existence IS that event, exactly as it is
/// in the web build's own `state.tabs` diff. `UsageAnalytics.recordInput`/
/// `recordOutput`/`recordTokens` are ported (faithfully, see that file) but
/// deliberately not wired to a live byte stream here: that needs
/// intercepting every pane's terminal I/O, a materially larger seam than the
/// status/exit callbacks this task's brief named as the wiring source.
final class UsageAnalyticsRecorder {
    private(set) var store: UsageAnalyticsStore
    /// Raised only when `store` actually changed — the persistence hook.
    var onStoreChanged: ((UsageAnalyticsStore) -> Void)?

    private var seenTerminals: Set<String> = []
    private var seenSessions: Set<String> = []
    private var activeStatus: [String: (project: String, status: RemoteSessionStatus, since: Double)] = [:]

    init(store: UsageAnalyticsStore = UsageAnalyticsStore()) {
        self.store = store
    }

    /// Adopts a persisted store (a fresh read of `SettingsKey.usageAnalytics`).
    /// A wholesale replace, not a merge: unlike the notification feed, there
    /// is no user-visible side effect (a banner) a restore could double, so
    /// there is nothing an in-flight recording needs reconciling against.
    func restore(_ restored: UsageAnalyticsStore) {
        store = restored
    }

    /// A pane came into existence — the native mirror of `App.tsx`'s "first
    /// time this tab id/session key has been seen" check. `sessionKey`
    /// identifies the *session* (pane group), so a second pane opened in an
    /// already-open session counts only as a new terminal, not a new session
    /// too.
    func recordPaneOpened(paneID: String, sessionKey: String, project: String, at: Double) {
        var changed = false
        if !seenTerminals.contains(paneID) {
            seenTerminals.insert(paneID)
            UsageAnalytics.recordTerminalOpened(&store, projectId: project, at: at)
            changed = true
        }
        if !seenSessions.contains(sessionKey) {
            seenSessions.insert(sessionKey)
            UsageAnalytics.recordSessionOpened(&store, projectId: project, at: at)
            changed = true
        }
        if changed { onStoreChanged?(store) }
    }

    /// A session's status changed. Flushes the duration of whatever status
    /// it was previously in before starting to track the new one — nothing
    /// to flush (and nothing to persist) the first time a session is seen.
    func recordStatus(sessionID: String, project: String, status: RemoteSessionStatus, at: Double) {
        if let previous = activeStatus[sessionID] {
            UsageAnalytics.recordStatusDuration(
                &store, projectId: previous.project, status: previous.status, fromTs: previous.since, toTs: at
            )
            onStoreChanged?(store)
        }
        activeStatus[sessionID] = (project, status, at)
    }

    /// A session ended — flushes whatever status it was last tracked in,
    /// since nothing will ever report its next transition. A no-op for a
    /// session `recordStatus` was never called for (a shell pane that never
    /// reported a status).
    func recordExit(sessionID: String, at: Double) {
        guard let previous = activeStatus.removeValue(forKey: sessionID) else { return }
        UsageAnalytics.recordStatusDuration(
            &store, projectId: previous.project, status: previous.status, fromTs: previous.since, toTs: at
        )
        onStoreChanged?(store)
    }
}
