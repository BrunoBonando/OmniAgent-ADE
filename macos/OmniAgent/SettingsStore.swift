import Foundation

/// What `SettingsStore` needs from the daemon connection — exactly
/// `SessionConnection`'s existing `getSetting`/`setSetting` signatures (Task
/// 6a), narrowed to a protocol so every screen this task adds can be tested
/// without a socket, the same seam `NotificationDelivering` gives
/// `SessionNotifier`.
protocol SettingsClient: AnyObject {
    func getSetting(key: String, completion: @escaping (Result<String?, Error>) -> Void)
    func setSetting(key: String, value: String, completion: ((Result<Void, Error>) -> Void)?)
}

extension SessionConnection: SettingsClient {}

/// A typed facade over the `settings` table's raw string rows — every
/// SwiftUI screen this task adds (settings, usage, auth gate, first run)
/// reads/writes through this rather than calling `SettingsClient` directly,
/// so the "true"/"false" and JSON-blob conventions each key uses live in one
/// place instead of being re-decided at every call site.
final class SettingsStore {
    private let client: SettingsClient

    init(client: SettingsClient) {
        self.client = client
    }

    /// The raw row, exactly as stored — `nil` when unset.
    func get(_ key: String, completion: @escaping (Result<String?, Error>) -> Void) {
        client.getSetting(key: key, completion: completion)
    }

    func set(_ key: String, _ value: String, completion: ((Result<Void, Error>) -> Void)? = nil) {
        client.setSetting(key: key, value: value, completion: completion)
    }

    /// `"true"`/`"false"` rows, read with an explicit default for the unset
    /// case — the one place that convention (`review_memory`'s "unset means
    /// off", `auth_signed_in`'s "unset means on") is spelled out per call
    /// site rather than guessed.
    ///
    /// **`nil` means the read failed, and is not the same as unset.** This
    /// used to be `switch try? result.get()`, which collapsed a `.failure`
    /// (daemon down, socket dropped, database locked) into "no such row" and
    /// handed back the default — so a transient error at Settings-open time
    /// rendered the control in its default position, and the user's next
    /// interaction wrote that default over the real row in the shared
    /// `brain.db` (final whole-branch review, Minor #11). That is exactly the
    /// failure class `WorkspaceWindowController.layoutReadFailed` exists to
    /// prevent for the `layout` row; the caller is expected to hold the same
    /// kind of write gate — see `SettingsViewModel.setReviewMemory`.
    func getBool(_ key: String, default defaultValue: Bool, completion: @escaping (Bool?) -> Void) {
        get(key) { result in
            switch result {
            case let .success(value?): completion(value == "true")
            case .success(nil): completion(defaultValue)
            case .failure: completion(nil)
            }
        }
    }

    func setBool(_ key: String, _ value: Bool, completion: ((Result<Void, Error>) -> Void)? = nil) {
        set(key, value ? "true" : "false", completion: completion)
    }
}
