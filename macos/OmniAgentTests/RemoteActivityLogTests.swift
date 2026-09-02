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
}
