import XCTest

@testable import OmniAgent

/// `RemoteActivityLog` — the daemon-witnessed remote activity log reaching
/// the host app (2026-09-01 remote environment sharing spec §8, Task 19),
/// and the panel table built on top of it (Task 20).
@MainActor
final class RemoteActivityLogTests: XCTestCase {
    private func writeTempJSONL(_ lines: [String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    // MARK: - Task 19: history reads the file back

    func testHistoryReadsNewestFirstAndTolerantOfGarbageLines() throws {
        let url = try writeTempJSONL([
            #"{"ts":"2026-09-01T10:00:00Z","kind":"attach","summary":"Opened Terminal 1","detail":null}"#,
            "not json at all",
            #"{"ts":"2026-09-01T10:01:00Z","kind":"input","summary":"Sent a prompt","detail":"hello"}"#,
        ])
        let entries = RemoteActivityLog.history(from: url, limit: 10)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries.first?.summary, "Sent a prompt")
        XCTAssertEqual(entries.last?.summary, "Opened Terminal 1")
    }

    func testHistoryParsesTheDaemonsFractionalRfc3339Timestamps() throws {
        // `chrono`'s `to_rfc3339()`: a numeric offset, and fractional seconds
        // when the timestamp actually has sub-second precision.
        let url = try writeTempJSONL([
            #"{"ts":"2026-09-01T10:00:00.123456789+00:00","kind":"kill","summary":"Closed Terminal 1","detail":null}"#
        ])
        let entries = RemoteActivityLog.history(from: url, limit: 10)
        XCTAssertEqual(entries.count, 1)
    }

    func testHistoryOfAMissingFileIsEmptyNotAnError() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString).jsonl")
        XCTAssertEqual(RemoteActivityLog.history(from: missing, limit: 10), [])
    }

    func testHistoryCapsAtTheMostRecentLimitRows() throws {
        let lines = (0..<5).map {
            #"{"ts":"2026-09-01T10:00:0\#($0)Z","kind":"kill","summary":"row \#($0)","detail":null}"#
        }
        let url = try writeTempJSONL(lines)
        let entries = RemoteActivityLog.history(from: url, limit: 2)
        // The two most recent, newest first.
        XCTAssertEqual(entries.map(\.summary), ["row 4", "row 3"])
    }

    // MARK: - Task 19: the live feed

    func testAppendAddsToTheEndNewestLast() {
        let log = RemoteActivityLog()
        log.append([.init(ts: Date(), kind: "attach", summary: "Opened Terminal 1", detail: nil)])
        log.append([.init(ts: Date(), kind: "kill", summary: "Closed Terminal 1", detail: nil)])
        XCTAssertEqual(log.entries.map(\.kind), ["attach", "kill"])
    }

    func testResetClearsTheLiveFeed() {
        let log = RemoteActivityLog()
        log.append([.init(ts: Date(), kind: "attach", summary: "Opened Terminal 1", detail: nil)])
        log.reset()
        XCTAssertTrue(log.entries.isEmpty)
    }

    // MARK: - Task 20: only rows with a detail are expandable

    func testOnlyRowsWithDetailAreExpandable() {
        let table = RemoteActivityTable(entries: [
            .init(id: .init(), ts: .now, kind: "attach", summary: "Opened Terminal 1", detail: nil),
            .init(
                id: .init(), ts: .now, kind: "input", summary: "Sent a prompt to Terminal 1",
                detail: "hello there"
            ),
        ])
        XCTAssertFalse(table.isExpandable(at: 0))
        XCTAssertTrue(table.isExpandable(at: 1))
    }

    // MARK: - Task 20: RemoteActivityHistoryGroup.grouped — no test before fix round 1

    private func row(_ kind: String, _ summary: String) -> RemoteActivityLog.Entry {
        .init(ts: Date(), kind: kind, summary: summary, detail: nil)
    }

    /// `history(from:limit:)`'s own order (newest first): reading backwards,
    /// a "connected" row is the *oldest* fact about its connection, so it is
    /// what closes the group being built rather than what opens it. Two full
    /// connections, newest first, each ending at its own "connected" row.
    func testGroupedSplitsAtConnectedRowsReadingNewestFirst() {
        let entries = [
            row("disconnected", "Disconnected · 2m 00s"),  // B, newest
            row("input", "Sent a prompt to Terminal 1"),  // B
            row("connected", "Connected from Air (203.0.113.7)"),  // B, oldest
            row("disconnected", "Disconnected · 1m 00s"),  // A
            row("attach", "Opened Terminal 1"),  // A
            row("connected", "Connected from Studio (203.0.113.8)"),  // A, oldest
        ]
        let groups = RemoteActivityHistoryGroup.grouped(from: entries)
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].rows.map(\.kind), ["disconnected", "input", "connected"])
        XCTAssertEqual(groups[0].rows.last?.summary, "Connected from Air (203.0.113.7)")
        XCTAssertEqual(groups[1].rows.map(\.kind), ["disconnected", "attach", "connected"])
        XCTAssertEqual(groups[1].rows.last?.summary, "Connected from Studio (203.0.113.8)")
    }

    /// The trailing-group case: rows with no "connected" row of their own —
    /// a file predating that row, or one torn at the tail — still form a
    /// group rather than being silently dropped.
    func testGroupedKeepsATrailingGroupWithNoConnectedRowOfItsOwn() {
        let entries = [
            row("input", "Sent a prompt to Terminal 1"),
            row("attach", "Opened Terminal 1"),
        ]
        let groups = RemoteActivityHistoryGroup.grouped(from: entries)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].rows.map(\.kind), ["input", "attach"])
    }

    /// A trailing, connection-less group can only realistically follow a
    /// complete one, never precede it: the file is written in true
    /// chronological order and `history` only reverses it, so a torn or
    /// pre-Task-19 prefix with no "connected" row of its own is always the
    /// *oldest* material — the last group in this newest-first list, not
    /// the first. Both groups must survive, in order, not merge into one.
    func testGroupedKeepsATrailingGroupAfterACompleteOne() {
        let entries = [
            row("disconnected", "Disconnected · 1m 00s"),  // B, complete, newest
            row("connected", "Connected from Studio (203.0.113.8)"),  // B, complete
            row("input", "Sent a prompt to Terminal 1"),  // A, torn — oldest, trailing
        ]
        let groups = RemoteActivityHistoryGroup.grouped(from: entries)
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].rows.map(\.kind), ["disconnected", "connected"])
        XCTAssertEqual(groups[1].rows.map(\.kind), ["input"])
    }

    func testGroupedOfNoEntriesIsNoGroups() {
        XCTAssertEqual(RemoteActivityHistoryGroup.grouped(from: []), [])
    }
}
