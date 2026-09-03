import CryptoKit
import Foundation
import Security

/// A transform applied to a few settings rows on their way to and from the
/// daemon, so the values the daemon — and its on-disk SQLite store — ever see
/// are ciphertext. Attached only to the **local** daemon connection
/// (`AppDelegate`); a connection driving another Mac carries none, so that
/// Mac's own rows are read exactly as it stored them.
protocol SettingsCipher: AnyObject {
    /// The value to store: encrypted when the key is one this cipher covers
    /// and an account is signed in, unchanged otherwise. Throws only on a
    /// genuine crypto failure — never silently store plaintext for a covered
    /// key.
    func encode(key: String, value: String) throws -> String
    /// The plaintext: decrypted for a covered key whose value carries the
    /// ciphertext marker, unchanged otherwise (a legacy plaintext row, or a
    /// key this cipher does not cover). Throws when a value is ciphertext it
    /// cannot open, so the caller treats it as a *read failure* rather than an
    /// empty row and its write gate does not overwrite it.
    func decode(key: String, value: String) throws -> String
}

/// Where `LayoutCipher` gets the per-account symmetric key. A protocol so the
/// crypto is unit-testable with an in-memory store instead of the Keychain.
protocol LayoutKeyStore {
    func key(forAccount accountID: String) throws -> SymmetricKey
}

enum SettingsCipherError: Error, Equatable {
    /// A covered row is ciphertext, but no account is signed in to name the
    /// key that would open it. A read failure, deliberately — not "unset".
    case notSignedIn
    /// The marker was present but the bytes after it are not valid base64.
    case corrupt
}

/// Encrypts the "what's open" rows — the workspace/pane layout — app-side with
/// AES-GCM under a per-account key, so the settings store holds only ciphertext
/// and only a signed-in user (whose account owns the key) can read it back.
///
/// Rows are left untouched when signed out (no account, e.g. the pre-account
/// scratch root) or for any key outside `encryptedKeys`, and a value with no
/// `enc1:` marker is returned as-is — the legacy plaintext rows the
/// `native-macos-compat` fixtures pin, which migrate to ciphertext on their
/// next write with no separate migration pass.
///
/// The key is per-account and per-Mac (`KeychainLayoutKeyStore`), which is the
/// deliberate trade of the Keychain model: a Mac driving another over the relay
/// cannot decrypt that Mac's layout, so the cipher is never attached to a
/// remote connection.
final class LayoutCipher: SettingsCipher {
    static let defaultEncryptedKeys: Set<String> = [
        SettingsKey.layout, SettingsKey.editorPanes, SettingsKey.browserPanes,
    ]
    /// Versioned so a future scheme can be told apart from this one; also what
    /// distinguishes ciphertext from a legacy plaintext JSON row (which starts
    /// with `{` or `[`, never this).
    private static let marker = "enc1:"

    private let keyStore: LayoutKeyStore
    private let accountID: () -> String?
    private let encryptedKeys: Set<String>

    init(
        keyStore: LayoutKeyStore,
        encryptedKeys: Set<String> = LayoutCipher.defaultEncryptedKeys,
        accountID: @escaping () -> String?
    ) {
        self.keyStore = keyStore
        self.encryptedKeys = encryptedKeys
        self.accountID = accountID
    }

    func encode(key: String, value: String) throws -> String {
        guard encryptedKeys.contains(key), let account = accountID() else { return value }
        let sealed = try AES.GCM.seal(Data(value.utf8), using: keyStore.key(forAccount: account))
        guard let combined = sealed.combined else { return value }
        return Self.marker + combined.base64EncodedString()
    }

    func decode(key: String, value: String) throws -> String {
        guard encryptedKeys.contains(key), value.hasPrefix(Self.marker) else { return value }
        guard let account = accountID() else { throw SettingsCipherError.notSignedIn }
        guard let data = Data(base64Encoded: String(value.dropFirst(Self.marker.count))) else {
            throw SettingsCipherError.corrupt
        }
        let sealed = try AES.GCM.SealedBox(combined: data)
        let plain = try AES.GCM.open(sealed, using: keyStore.key(forAccount: account))
        return String(decoding: plain, as: UTF8.self)
    }
}

/// The production `LayoutKeyStore`: a per-account AES-256 key in the login
/// Keychain (this app's own generic-password item, released after first
/// unlock), minted on first use. Cached in memory so a burst of layout
/// reads/writes is one Keychain round trip.
final class KeychainLayoutKeyStore: LayoutKeyStore {
    enum KeychainError: Error { case unexpectedStatus(OSStatus) }

    private let service: String
    private let lock = NSLock()
    private var cache: [String: SymmetricKey] = [:]

    init(service: String = "digital.bruno.omniagent.layout-key") {
        self.service = service
    }

    func key(forAccount accountID: String) throws -> SymmetricKey {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[accountID] { return cached }
        if let existing = try read(accountID) {
            let key = SymmetricKey(data: existing)
            cache[accountID] = key
            return key
        }
        let key = SymmetricKey(size: .bits256)
        try store(accountID, key.withUnsafeBytes { Data($0) })
        cache[accountID] = key
        return key
    }

    private func baseQuery(_ accountID: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountID,
        ]
    }

    private func read(_ accountID: String) throws -> Data? {
        var query = baseQuery(accountID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess: return item as? Data
        case errSecItemNotFound: return nil
        default: throw KeychainError.unexpectedStatus(status)
        }
    }

    private func store(_ accountID: String, _ data: Data) throws {
        var attributes = baseQuery(accountID)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
    }
}

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
