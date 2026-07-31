import AppKit
import UserNotifications

/// What `SessionNotifier` needs from Notification Center.
///
/// A protocol rather than `UNUserNotificationCenter` directly so the feed's
/// behaviour can be tested without asking a real user for notification
/// authorization, and so a test run never posts a banner on the developer's
/// screen.
protocol NotificationDelivering: AnyObject {
    /// Asked once, at launch. A refusal is not an error: the in-app feed
    /// keeps working, only the system banners stop.
    func requestAuthorization()
    func deliver(_ entry: NotificationEntry)
    /// Pulls already-delivered banners back out of Notification Center — what
    /// answering a prompt in the terminal does to the "needs your approval"
    /// banner it produced.
    func withdraw(identifiers: [String])
    /// A one-off that is never part of the persisted feed (a session ending).
    func deliverTransient(identifier: String, title: String, body: String, sessionID: String)
}

/// The real `UNUserNotificationCenter` backing, and the tap handler that
/// brings the right pane forward.
final class UserNotificationDelivery: NSObject, NotificationDelivering, UNUserNotificationCenterDelegate {
    /// Raised when the user clicks a notification: the session id it named.
    var onActivate: ((String) -> Void)?

    private let center: UNUserNotificationCenter
    private static let sessionIDKey = "sessionID"

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
        super.init()
        center.delegate = self
    }

    func requestAuthorization() {
        center.requestAuthorization(options: [.alert, .sound]) { _, error in
            if let error {
                NSLog("notification authorization failed: %@", error.localizedDescription)
            }
        }
    }

    func deliver(_ entry: NotificationEntry) {
        let content = UNMutableNotificationContent()
        content.title = entry.sessionLabel.map { "\($0) — \(entry.title)" } ?? entry.title
        content.subtitle = entry.projectLabel
        content.body = NotificationFeed.subtitle(for: entry.status)
        // Grouped per session, so a chatty pane stacks into one Notification
        // Center group instead of burying every other pane's news.
        content.threadIdentifier = entry.sessionID
        content.userInfo = [Self.sessionIDKey: entry.sessionID]
        if entry.status == .awaitingApproval {
            content.sound = .default
        }
        add(identifier: entry.id, content: content)
    }

    func deliverTransient(identifier: String, title: String, body: String, sessionID: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.threadIdentifier = sessionID
        content.userInfo = [Self.sessionIDKey: sessionID]
        add(identifier: identifier, content: content)
    }

    func withdraw(identifiers: [String]) {
        guard !identifiers.isEmpty else { return }
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    private func add(identifier: String, content: UNNotificationContent) {
        // `trigger: nil` delivers immediately.
        center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil)) { error in
            if let error {
                NSLog("notification delivery failed: %@", error.localizedDescription)
            }
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// The feed only records events the user could have missed (see
    /// `NotificationFeed.isSessionOnScreen`), so anything that reaches here
    /// while the app happens to be frontmost is still news worth showing.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if let sessionID = response.notification.request.content.userInfo[Self.sessionIDKey] as? String {
            DispatchQueue.main.async { self.onActivate?(sessionID) }
        }
        completionHandler()
    }
}

/// Owns the notification feed: derives entries from status events, delivers
/// them, keeps the list, and persists it to the shared `notifications`
/// settings row.
///
/// The rules all live in `NotificationFeed`; this is the stateful shell
/// around them plus the two side effects (deliver, persist).
final class SessionNotifier {
    private(set) var entries: [NotificationEntry] = []
    /// Raised whenever `entries` changed — the persistence hook, and what a
    /// badge would read.
    var onEntriesChanged: (([NotificationEntry]) -> Void)?

    private let delivery: NotificationDelivering

    init(delivery: NotificationDelivering) {
        self.delivery = delivery
    }

    var unreadCount: Int { NotificationFeed.unreadCount(entries) }

    func requestAuthorization() {
        delivery.requestAuthorization()
    }

    /// Adopts the persisted row. Deliberately does not re-deliver anything:
    /// a banner for a prompt from last week, replayed at launch, would be
    /// noise — the row is a log, not a queue.
    func restore(_ restored: [NotificationEntry]) {
        entries = Array(restored.prefix(NotificationFeed.maxEntries))
        onEntriesChanged?(entries)
    }

    /// The one entry point for a status event. Returns the entry it recorded,
    /// or `nil` when the event produced none.
    @discardableResult
    func record(_ context: NotificationContext) -> NotificationEntry? {
        guard var entry = NotificationFeed.derive(context) else { return nil }
        entry.id = NotificationFeed.uniqueID(entry.id, among: entries)
        entries = NotificationFeed.adding(entry, to: entries)
        delivery.deliver(entry)
        onEntriesChanged?(entries)
        return entry
    }

    /// This session's pending prompt was answered — anywhere, including by
    /// typing in the pane. The rows go, and so do the banners they produced:
    /// a "needs your approval" notification for a question already answered
    /// is worse than none.
    func resolveApproval(sessionID: String) {
        let obsolete = entries.filter { $0.sessionID == sessionID && $0.status == .awaitingApproval }
        guard !obsolete.isEmpty else { return }
        entries = NotificationFeed.resolvingApproval(forSession: sessionID, in: entries)
        delivery.withdraw(identifiers: obsolete.map(\.id))
        onEntriesChanged?(entries)
    }

    /// A session's PTY ended. Not part of the persisted feed — the shared row
    /// only accepts the three notifiable statuses, and "ended" is not one of
    /// them — so this is delivered and forgotten.
    func recordExit(sessionID: String, paneTitle: String, exitCode: UInt32?) {
        delivery.deliverTransient(
            identifier: "exit:\(sessionID)",
            title: paneTitle.isEmpty ? "Session ended" : paneTitle,
            body: exitCode.map { "Session ended (exit \($0))" } ?? "Session ended",
            sessionID: sessionID
        )
        // A dead session cannot still be waiting on an approval.
        resolveApproval(sessionID: sessionID)
    }

    func markAllRead() {
        guard unreadCount > 0 else { return }
        entries = NotificationFeed.markingRead(entries)
        onEntriesChanged?(entries)
    }

    func clear() {
        guard !entries.isEmpty else { return }
        delivery.withdraw(identifiers: entries.map(\.id))
        entries = []
        onEntriesChanged?(entries)
    }
}
