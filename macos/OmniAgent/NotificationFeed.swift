import Foundation

/// One recorded attention event — the native port of
/// `ui/src/state/notifications.ts`'s `NotificationEntry`, field-for-field, so
/// the `notifications` settings row stays readable by both builds.
struct NotificationEntry: Equatable {
    /// Stable id for dismissal: session id + the moment it fired. Also the
    /// Notification Center request identifier — see `uniqueID`.
    var id: String
    let sessionID: String
    let project: String
    let projectLabel: String
    /// The pane's cwd — what keeps a row meaningful after its session is gone.
    let cwd: String
    let engine: String
    let status: RemoteSessionStatus
    /// The session's own name at the moment it fired, so a later rename never
    /// rewrites history.
    let title: String
    let sessionLabel: String?
    /// Epoch milliseconds, matching the web row's `Date.now()` values.
    let createdAt: Double
    /// False until the feed has been shown since this arrived.
    var read: Bool
}

/// Everything `NotificationFeed.derive` needs to answer "does this event
/// become a notification, and what does it say".
///
/// Passed in whole rather than read from anywhere, which is what keeps the
/// suppression rule testable without an app.
struct NotificationContext {
    let event: SessionStatusEvent
    /// The pane this event belongs to. `nil` — an event for a session this
    /// window has no pane for — produces nothing: a notification that cannot
    /// name its session, or navigate to it, is noise.
    let pane: PaneDescriptor?
    let projectLabel: String
    let focusedPaneID: String?
    /// The window is on screen and not fully occluded.
    let windowVisible: Bool
    /// The app is the active application.
    let appActive: Bool
    /// The pane's status *before* this event — how an approval's outcome is
    /// told apart from an unrelated status change.
    let previousStatus: RemoteSessionStatus?
    let now: Double
}

/// The notification feed: which status events become entries, what the entry
/// says, how the list is kept, and how it survives a relaunch.
///
/// A direct port of `ui/src/state/notifications.ts`, minus the parts that
/// describe a browser (`document.visibilityState`) or the web shell's second
/// view. Delivery to Notification Center is `SessionNotifier`'s job — this
/// module never imports `UserNotifications`, so every rule below is testable
/// without a notification authorization prompt.
enum NotificationFeed {
    /// How many entries are kept and persisted. The row is rewritten on every
    /// notification, so a few dozen keeps the write cost irrelevant.
    static let maxEntries = 40

    /// The statuses that can ever produce an entry — the Rust-side `notify`
    /// definition, mirrored here **only** as a validation guard when
    /// restoring persisted entries (a hand-edited row saying `thinking` must
    /// not resurrect a notification the rule never allowed). A live event's
    /// `event.notify` is always what decides; this never re-derives it.
    static let notifiable: Set<RemoteSessionStatus> = [.ready, .awaitingApproval, .error]

    /// One plain past-tense sentence for what happened.
    static func subtitle(for status: RemoteSessionStatus) -> String {
        switch status {
        case .ready: return "Approved."
        case .awaitingApproval: return "Needs your approval."
        case .error: return "Rejected."
        // Unreachable via `notify`, total anyway so a future sixth state
        // cannot crash the feed.
        case .thinking, .toolExecution: return "Status changed."
        }
    }

    /// Whether the user is demonstrably looking at this session right now.
    ///
    /// The web rule has four clauses; two of them describe a shell this build
    /// does not have. There is no project filter and no second view natively
    /// — every pane in the window is on screen at once — so "the pane in the
    /// project on screen, in the workspace view" collapses into "the focused
    /// pane". The two that do survive are the ones that carry the actual
    /// requirement: a hidden window or a backgrounded app means the user is,
    /// definitionally, somewhere else.
    static func isSessionOnScreen(_ ctx: NotificationContext) -> Bool {
        ctx.pane != nil
            && ctx.event.id == ctx.focusedPaneID
            && ctx.windowVisible
            && ctx.appActive
    }

    /// `nil` = no notification (not notifiable, unknown session, not an
    /// attention event, or the user is already looking at it).
    static func derive(_ ctx: NotificationContext) -> NotificationEntry? {
        guard ctx.event.notify, let pane = ctx.pane, !isSessionOnScreen(ctx) else { return nil }

        let isPending = ctx.event.status == .awaitingApproval
        let isResolution = ctx.previousStatus == .awaitingApproval
            && (ctx.event.status == .ready || ctx.event.status == .error)
        // Attention-only feed: pending approvals, and the immediate
        // approved/rejected outcome of those approvals.
        guard isPending || isResolution else { return nil }

        let title = pane.label.flatMap { $0.isEmpty ? nil : $0 } ?? pane.engine.rawValue
        return NotificationEntry(
            id: "\(ctx.event.id):\(Int(ctx.now))",
            sessionID: ctx.event.id,
            project: pane.project,
            projectLabel: ctx.projectLabel,
            cwd: pane.cwd,
            engine: ctx.event.engine.isEmpty ? pane.engine.rawValue : ctx.event.engine,
            status: ctx.event.status,
            title: title,
            sessionLabel: pane.groupLabel,
            createdAt: ctx.now,
            read: false
        )
    }

    /// Two events for one session inside the same millisecond derive the
    /// same `${sessionId}:${now}` id. Harmless in a list, but the id is also
    /// the Notification Center request identifier, where a duplicate
    /// silently *replaces* the banner it collided with — so the second one
    /// is suffixed rather than swallowing the first.
    static func uniqueID(_ id: String, among entries: [NotificationEntry]) -> String {
        guard entries.contains(where: { $0.id == id }) else { return id }
        var suffix = 2
        while entries.contains(where: { $0.id == "\(id)#\(suffix)" }) { suffix += 1 }
        return "\(id)#\(suffix)"
    }

    /// Prepends an entry, collapsing an *immediate* repeat of the same status
    /// for the same session into one row refreshed to the newer time.
    /// Anything else in between keeps both rows, because then the older one
    /// carries information the newer one does not.
    static func adding(_ entry: NotificationEntry, to entries: [NotificationEntry]) -> [NotificationEntry] {
        var rest = entries
        if let newest = rest.first, newest.sessionID == entry.sessionID, newest.status == entry.status {
            rest.removeFirst()
        }
        return Array(([entry] + rest).prefix(maxEntries))
    }

    /// This session's pending yes/no prompt was answered — from the pane,
    /// from the feed, anywhere. Its `awaiting_approval` rows are obsolete the
    /// moment the session reports any other status. Other statuses' rows are
    /// untouched: they are history, not a pending ask.
    static func resolvingApproval(
        forSession sessionID: String,
        in entries: [NotificationEntry]
    ) -> [NotificationEntry] {
        entries.filter { !($0.sessionID == sessionID && $0.status == .awaitingApproval) }
    }

    static func markingRead(_ entries: [NotificationEntry]) -> [NotificationEntry] {
        entries.map { entry in
            var read = entry
            read.read = true
            return read
        }
    }

    static func unreadCount(_ entries: [NotificationEntry]) -> Int {
        entries.filter { !$0.read }.count
    }

    /// Relative timestamps in the panel's own coarse vocabulary — a
    /// notification list is scanned, not read, and second-level precision
    /// would make every row twitch.
    static func relativeTime(_ createdAt: Double, now: Double) -> String {
        let seconds = max(0, Int((now - createdAt) / 1000))
        if seconds < 60 { return "Just now" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h" }
        let days = hours / 24
        return days == 1 ? "1 day" : "\(days) days"
    }
}

/// The `notifications` settings row, in and out.
///
/// `JSONSerialization` rather than `Codable` for the same reason
/// `PersistedLayoutCodec` is: one malformed entry must cost only itself, and
/// a throwing decode of an array fails the whole array.
enum NotificationFeedCodec {
    static func serialize(_ entries: [NotificationEntry]) -> String {
        let payload: [String: Any] = [
            "entries": entries.prefix(NotificationFeed.maxEntries).map(encoded),
        ]
        guard
            JSONSerialization.isValidJSONObject(payload),
            let data = try? JSONSerialization.data(withJSONObject: payload),
            let json = String(data: data, encoding: .utf8)
        else {
            return #"{"entries":[]}"#
        }
        return json
    }

    private static func encoded(_ entry: NotificationEntry) -> [String: Any] {
        var dict: [String: Any] = [
            "id": entry.id,
            "sessionId": entry.sessionID,
            "project": entry.project,
            "projectLabel": entry.projectLabel,
            "cwd": entry.cwd,
            "engine": entry.engine,
            "status": entry.status.rawValue,
            "title": entry.title,
            "createdAt": entry.createdAt,
            "read": entry.read,
        ]
        if let sessionLabel = entry.sessionLabel {
            dict["sessionLabel"] = sessionLabel
        }
        return dict
    }

    /// Never throws: a corrupt row restores as "no notifications" rather than
    /// breaking launch, and one malformed entry costs only itself.
    static func deserialize(_ raw: String?) -> [NotificationEntry] {
        guard
            let raw, !raw.isEmpty,
            let data = raw.data(using: .utf8),
            let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let rawEntries = parsed["entries"] as? [Any]
        else {
            return []
        }
        return Array(rawEntries.compactMap(decoded).prefix(NotificationFeed.maxEntries))
    }

    private static func decoded(_ element: Any) -> NotificationEntry? {
        guard
            let dict = element as? [String: Any],
            let id = dict["id"] as? String,
            let sessionID = dict["sessionId"] as? String,
            let project = dict["project"] as? String,
            let projectLabel = dict["projectLabel"] as? String,
            let cwd = dict["cwd"] as? String,
            let engine = dict["engine"] as? String,
            let title = dict["title"] as? String,
            let createdAt = dict["createdAt"] as? Double, createdAt.isFinite,
            let statusRaw = dict["status"] as? String,
            let status = RemoteSessionStatus(rawValue: statusRaw),
            NotificationFeed.notifiable.contains(status)
        else {
            return nil
        }
        // Present-but-wrong-typed costs the whole entry, exactly as it does
        // in the web validator; absent is fine.
        if let sessionLabel = dict["sessionLabel"], !(sessionLabel is String) { return nil }
        return NotificationEntry(
            id: id,
            sessionID: sessionID,
            project: project,
            projectLabel: projectLabel,
            cwd: cwd,
            engine: engine,
            status: status,
            title: title,
            sessionLabel: dict["sessionLabel"] as? String,
            createdAt: createdAt,
            read: dict["read"] as? Bool == true
        )
    }
}
