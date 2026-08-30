import CryptoKit
import Foundation

/// The account pointer — Swift twin of `brain_core::Store`'s
/// `current_account_file`/`account_dir_id`/`resolve_data_dir`
/// (crates/brain-core/src/store.rs). The data **root** is
/// `DaemonPaths.dataDir`; while `<root>/current-account` names an account,
/// every process resolves its data dir to `<root>/accounts/<id>`, otherwise
/// to the root (signed out).
///
/// The app is the only writer of the pointer and never creates `accounts/`
/// itself: the daemon creates the account directory when it starts, and its
/// one-time legacy migration (`Store::adopt_legacy_data`) keys off
/// `accounts/` not existing yet. The daemon reads the pointer once at
/// startup, so moving between accounts is a daemon restart
/// (`WorkspaceWindowController.switchAccount`).
enum AccountDirectory {
    static let pointerFileName = "current-account"
    static let accountsDirectoryName = "accounts"

    /// First 16 hex characters of the SHA-256 of the lower-cased, trimmed
    /// email — `Store::account_dir_id`, byte for byte (both pin the same
    /// test vector).
    static func accountID(forEmail email: String) -> String {
        let normalized = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let digest = SHA256.hash(data: Data(normalized.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    static func currentAccountFile(root: URL) -> URL {
        root.appendingPathComponent(pointerFileName)
    }

    /// The id the pointer names, or `nil` when signed out (no file, or a
    /// blank one). Anything but hex digits reads as absent — the file is
    /// user-writable and `../` in it must never leave the root.
    static func readCurrentAccount(root: URL) -> String? {
        guard let raw = try? String(contentsOf: currentAccountFile(root: root), encoding: .utf8) else {
            return nil
        }
        let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, id.allSatisfy(\.isHexDigit) else { return nil }
        return id
    }

    /// One id and a trailing newline; atomic, so a daemon starting mid-write
    /// sees either the old pointer or the new one.
    static func writeCurrentAccount(_ id: String, root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try (id + "\n").write(to: currentAccountFile(root: root), atomically: true, encoding: .utf8)
    }

    /// Signed out. Removing a pointer that is already gone is not an error.
    static func clearCurrentAccount(root: URL) throws {
        let file = currentAccountFile(root: root)
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        try FileManager.default.removeItem(at: file)
    }

    /// `Store::resolve_data_dir`: the account directory, or the root.
    static func dataDir(root: URL) -> URL {
        guard let id = readCurrentAccount(root: root) else { return root }
        return root
            .appendingPathComponent(accountsDirectoryName, isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
    }
}
