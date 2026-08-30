import XCTest
@testable import OmniAgent

/// `AccountDirectory` is the Swift twin of `brain_core::Store`'s pointer
/// resolution (crates/brain-core/src/store.rs, `account_scope_tests`). The
/// app writes the pointer, the daemon reads it — so the id derivation and
/// the file's shape are pinned to the same vectors on both sides.
final class AccountDirectoryTests: XCTestCase {
    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("omniagent-account-root-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testAccountIDMatchesTheRustVector() {
        // The same vector `Store::account_dir_id` pins: SHA-256 of the
        // lower-cased, trimmed email, first 16 hex characters.
        XCTAssertEqual(AccountDirectory.accountID(forEmail: "Bruno@Bonando.com "), "fc44b18d5588b1d6")
        XCTAssertEqual(AccountDirectory.accountID(forEmail: "bruno@bonando.com"), "fc44b18d5588b1d6")
        XCTAssertEqual(AccountDirectory.accountID(forEmail: "bruno@bonando.com").count, 16)
        XCTAssertNotEqual(AccountDirectory.accountID(forEmail: "other@bonando.com"), "fc44b18d5588b1d6")
    }

    func testThePointerFileLivesAtTheRoot() {
        let root = URL(fileURLWithPath: "/x/root", isDirectory: true)
        XCTAssertEqual(AccountDirectory.currentAccountFile(root: root).path, "/x/root/current-account")
    }

    func testReadingTrimsAndRejectsBlankOrUnsafeIDs() throws {
        let root = try temporaryRoot()
        XCTAssertNil(AccountDirectory.readCurrentAccount(root: root), "no file")

        try "  fc44b18d5588b1d6\n".write(to: AccountDirectory.currentAccountFile(root: root), atomically: true, encoding: .utf8)
        XCTAssertEqual(AccountDirectory.readCurrentAccount(root: root), "fc44b18d5588b1d6")

        try "   \n".write(to: AccountDirectory.currentAccountFile(root: root), atomically: true, encoding: .utf8)
        XCTAssertNil(AccountDirectory.readCurrentAccount(root: root), "blank means signed out")

        try "../../etc".write(to: AccountDirectory.currentAccountFile(root: root), atomically: true, encoding: .utf8)
        XCTAssertNil(AccountDirectory.readCurrentAccount(root: root), "only hex ids are ever joined onto the root")
    }

    func testWriteThenReadThenClearRoundTrips() throws {
        let root = try temporaryRoot()
        try AccountDirectory.writeCurrentAccount("fc44b18d5588b1d6", root: root)
        XCTAssertEqual(
            try String(contentsOf: AccountDirectory.currentAccountFile(root: root), encoding: .utf8),
            "fc44b18d5588b1d6\n",
            "one id, one trailing newline — what the Rust reader trims"
        )
        XCTAssertEqual(AccountDirectory.readCurrentAccount(root: root), "fc44b18d5588b1d6")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: root.appendingPathComponent("accounts").path),
            "the app never creates accounts/ — that would defeat the daemon's one-time legacy migration"
        )

        try AccountDirectory.clearCurrentAccount(root: root)
        XCTAssertNil(AccountDirectory.readCurrentAccount(root: root))
        XCTAssertNoThrow(try AccountDirectory.clearCurrentAccount(root: root), "clearing twice is fine")
    }

    func testWriteCreatesAMissingRoot() throws {
        let root = try temporaryRoot().appendingPathComponent("not-yet", isDirectory: true)
        try AccountDirectory.writeCurrentAccount("fc44b18d5588b1d6", root: root)
        XCTAssertEqual(AccountDirectory.readCurrentAccount(root: root), "fc44b18d5588b1d6")
    }

    func testDataDirFollowsThePointerAndFallsBackToTheRoot() throws {
        let root = try temporaryRoot()
        XCTAssertEqual(AccountDirectory.dataDir(root: root).path, root.path)
        try AccountDirectory.writeCurrentAccount("fc44b18d5588b1d6", root: root)
        XCTAssertEqual(
            AccountDirectory.dataDir(root: root).path,
            root.appendingPathComponent("accounts").appendingPathComponent("fc44b18d5588b1d6").path
        )
    }
}
