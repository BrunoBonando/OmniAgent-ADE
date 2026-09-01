import XCTest

@testable import OmniAgent

/// The machine-wide sharing switch — the 2026-09-01 remote environment
/// sharing spec's §2, replacing the per-workspace `Enable Remote Control`
/// toggle. `FakeSettingsClient` (`SettingsStoreTests.swift`) is the existing
/// settings test double, resolving synchronously with no socket — the same
/// one `SettingsViewModelTests` uses.
@MainActor
final class RemoteSharingModelTests: XCTestCase {
    /// `setSharing` writes `remote_sharing` byte for byte — the daemon's
    /// `remote_control_active` (Task 1) reads this exact row and shape, and
    /// a mismatch silently disables remote sharing.
    func testSetSharingWritesTheFlagRow() throws {
        let client = FakeSettingsClient()
        let store = SettingsStore(client: client)
        let model = RemoteSharingModel(store: store)

        model.setSharing(true)
        XCTAssertEqual(client.rows["remote_sharing"], #"{"enabled":true}"#)
        XCTAssertTrue(model.isSharing)

        model.setSharing(false)
        XCTAssertEqual(client.rows["remote_sharing"], #"{"enabled":false}"#)
        XCTAssertFalse(model.isSharing)
    }

    /// `unblock` rewrites `remote_control_blocked` with exactly that one id
    /// gone — the only way the app ever removes an entry from a row the
    /// daemon otherwise only ever adds to.
    func testUnblockRemovesOnlyThatViewer() throws {
        let client = FakeSettingsClient(rows: ["remote_control_blocked": #"["mac-a","mac-b"]"#])
        let store = SettingsStore(client: client)
        let model = RemoteSharingModel(store: store)
        XCTAssertEqual(model.blockedViewerIDs, ["mac-a", "mac-b"])

        model.unblock("mac-a")

        XCTAssertEqual(client.rows["remote_control_blocked"], #"["mac-b"]"#)
        XCTAssertEqual(model.blockedViewerIDs, ["mac-b"])
    }

    /// Unblocking an id that was never blocked is a no-op: no write, and the
    /// stored list is untouched.
    func testUnblockingAnUnlistedIDWritesNothing() throws {
        let client = FakeSettingsClient(rows: ["remote_control_blocked": #"["mac-a"]"#])
        let store = SettingsStore(client: client)
        let model = RemoteSharingModel(store: store)

        model.unblock("mac-z")

        XCTAssertTrue(client.setCalls.isEmpty)
        XCTAssertEqual(model.blockedViewerIDs, ["mac-a"])
    }

    /// The switch no longer forgives blocked machines — that was phase 2's
    /// rule ("Enabling Remote Control clears the blocklist"). The
    /// 2026-09-01 remote environment sharing spec deliberately drops it
    /// (§2, §7): blocking is now only undone by an explicit `unblock(_:)`.
    /// Do not "fix" `setSharing` to clear `remote_control_blocked` again —
    /// this is the point, not a regression.
    func testTurningSharingOnDoesNotClearTheBlockedList() throws {
        let client = FakeSettingsClient(rows: ["remote_control_blocked": #"["mac-a"]"#])
        let store = SettingsStore(client: client)
        let model = RemoteSharingModel(store: store)

        model.setSharing(true)

        XCTAssertEqual(client.rows["remote_control_blocked"], #"["mac-a"]"#)
        XCTAssertEqual(model.blockedViewerIDs, ["mac-a"], "still blocked — sharing does not forgive it")
        XCTAssertFalse(
            client.setCalls.map(\.key).contains(SettingsKey.remoteControlBlocked),
            "setSharing must never touch the blocked-list row at all"
        )
    }

    /// Both rows are read once at construction, synchronously here because
    /// the fake resolves without a socket — a real connection restores the
    /// same way, just later.
    func testConstructionRestoresBothRowsFromWhateverIsAlreadyStored() throws {
        let client = FakeSettingsClient(rows: [
            "remote_sharing": #"{"enabled":true}"#,
            "remote_control_blocked": #"["mac-a","mac-b"]"#,
        ])
        let store = SettingsStore(client: client)
        let model = RemoteSharingModel(store: store)

        XCTAssertTrue(model.isSharing)
        XCTAssertEqual(model.blockedViewerIDs, ["mac-a", "mac-b"])
    }

    /// Fails closed: an absent row, garbage JSON, and a non-bool `enabled`
    /// all read as sharing off — never as sharing on by accident. Mirrors
    /// the daemon's own `remote_control_active` decode exactly.
    func testUnreadableSharingRowReadsAsOff() throws {
        for rawSharing in [nil, "not json", #"{"enabled":"yes"}"#, "{}"] {
            var rows: [String: String] = [:]
            if let rawSharing { rows["remote_sharing"] = rawSharing }
            let client = FakeSettingsClient(rows: rows)
            let store = SettingsStore(client: client)
            let model = RemoteSharingModel(store: store)
            XCTAssertFalse(model.isSharing, "\(String(describing: rawSharing)) must read as off")
        }
    }
}
