import XCTest
@testable import OmniAgent

/// `ClaudeTranscriptReader`: turning a live JSONL transcript into
/// `TranscriptMessage`s, and `ClaudeModel`'s candidate search that the
/// reader's caller uses to find the file in the first place.
final class ClaudeTranscriptTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeTranscriptTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        tempDirectory = nil
        try super.tearDownWithError()
    }

    // MARK: - Decoding

    /// The full filtering contract in one fixture: a plain-string user
    /// message; an assistant reply with thinking/text/tool_use, where only
    /// the text and the tool call survive; an assistant row that is
    /// thinking-only, so nothing survives and the whole message is dropped;
    /// a sidechain row; a user row whose only block is a `tool_result`,
    /// dropped the same way as the thinking-only row; and unrelated
    /// metadata. Exactly two messages should come back.
    func testDecodesUserAndAssistantRowsDroppingSidechainThinkingAndMetadata() throws {
        let rows = [
            #"{"type":"user","uuid":"u1","isSidechain":false,"message":{"content":"Hello there"}}"#,
            #"{"type":"assistant","uuid":"a1","isSidechain":false,"message":{"content":[{"type":"thinking","thinking":"hmm","signature":"sig"},{"type":"text","text":"Let's read the file."},{"type":"tool_use","id":"toolu_1","name":"Read","input":{"file_path":"/some/path.swift"}}]}}"#,
            #"{"type":"assistant","uuid":"a2","isSidechain":false,"message":{"content":[{"type":"thinking","thinking":"only thinking","signature":"sig2"}]}}"#,
            #"{"type":"assistant","uuid":"a3","isSidechain":true,"message":{"content":[{"type":"text","text":"subagent chatter"}]}}"#,
            #"{"type":"user","uuid":"u2","isSidechain":false,"message":{"content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"file contents"}]}}"#,
            #"{"type":"mode","mode":"default"}"#,
        ]
        let url = try fixture(rows.joined(separator: "\n") + "\n", name: "decode.jsonl")
        let reader = ClaudeTranscriptReader(url: url)

        let messages = reader.poll()

        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0].id, "u1")
        XCTAssertTrue(messages[0].isUser)
        XCTAssertEqual(messages[0].blocks, [.text("Hello there")])
        XCTAssertEqual(messages[1].id, "a1")
        XCTAssertFalse(messages[1].isUser)
        XCTAssertEqual(messages[1].blocks, [
            .text("Let's read the file."),
            .tool(name: "Read", detail: "/some/path.swift"),
        ])
    }

    // MARK: - Streaming semantics

    /// A row split across two writes must wait for its other half rather
    /// than being parsed truncated, and must arrive exactly once, as soon as
    /// it is complete.
    func testPartialLineIsHeldBackThenReturnedExactlyOnceWhenCompleted() throws {
        let complete = #"{"type":"user","uuid":"first","isSidechain":false,"message":{"content":"one"}}"#
        let partial = #"{"type":"user","uuid":"partial","isSidechain":false,"message":{"content":"tw"#
        let url = try fixture(complete + "\n" + partial, name: "partial.jsonl")
        let reader = ClaudeTranscriptReader(url: url)

        let firstPoll = reader.poll()
        XCTAssertEqual(firstPoll.map(\.id), ["first"])

        try append(#"o"}}"# + "\n", to: url)
        let secondPoll = reader.poll()

        XCTAssertEqual(secondPoll.map(\.id), ["partial"])
        XCTAssertEqual(secondPoll.first?.blocks, [.text("two")])
    }

    /// A poll after N messages have already been returned answers only what
    /// was appended since — not the rows it already handed back.
    func testIncrementalPollReturnsOnlyRowsAppendedSinceTheLastCall() throws {
        let row1 = #"{"type":"user","uuid":"r1","isSidechain":false,"message":{"content":"one"}}"#
        let row2 = #"{"type":"user","uuid":"r2","isSidechain":false,"message":{"content":"two"}}"#
        let url = try fixture(row1 + "\n" + row2 + "\n", name: "incremental.jsonl")
        let reader = ClaudeTranscriptReader(url: url)

        XCTAssertEqual(reader.poll().map(\.id), ["r1", "r2"])

        let row3 = #"{"type":"user","uuid":"r3","isSidechain":false,"message":{"content":"three"}}"#
        try append(row3 + "\n", to: url)

        XCTAssertEqual(reader.poll().map(\.id), ["r3"])
    }

    /// A fresh pane has no transcript yet; the reader must stay ready for
    /// one rather than erroring, and pick it up the moment it exists.
    func testMissingFileReturnsEmptyThenPicksUpTheFirstRowOnceItExists() throws {
        let url = tempDirectory.appendingPathComponent("not-yet-written.jsonl")
        let reader = ClaudeTranscriptReader(url: url)

        XCTAssertEqual(reader.poll(), [])

        let row = #"{"type":"user","uuid":"r1","isSidechain":false,"message":{"content":"hi"}}"#
        try (row + "\n").write(to: url, atomically: true, encoding: .utf8)

        XCTAssertEqual(reader.poll().map(\.id), ["r1"])
    }

    /// Claude rewriting the file (compaction, `/clear`) can leave it shorter
    /// than the reader's offset; that must reset the reader rather than
    /// leaving it parked past the new end forever.
    func testFileShrinkingResetsAndRereadsFromTheStart() throws {
        let longRow = #"{"type":"user","uuid":"long","isSidechain":false,"message":{"content":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}"#
        let url = try fixture(longRow + "\n", name: "shrink.jsonl")
        let reader = ClaudeTranscriptReader(url: url)
        XCTAssertEqual(reader.poll().map(\.id), ["long"])

        let shortRow = #"{"type":"user","uuid":"short","isSidechain":false,"message":{"content":"hi"}}"#
        try (shortRow + "\n").write(to: url, atomically: true, encoding: .utf8)

        XCTAssertEqual(reader.poll().map(\.id), ["short"])
    }

    /// A small `firstReadTailBytes` forces the starting offset into the
    /// middle of the first row's bytes. The reader must walk forward to the
    /// next line boundary and drop everything before it, rather than
    /// returning a truncated fragment of that row — leaving the rows that
    /// fully fit intact.
    func testFirstReadTailCapDropsTheLeadingFragmentAtALineBoundary() throws {
        let rowA = #"{"type":"user","uuid":"first","isSidechain":false,"message":{"content":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"}}"#
        let rowB = #"{"type":"user","uuid":"middle","isSidechain":false,"message":{"content":"middle"}}"#
        let rowC = #"{"type":"user","uuid":"last","isSidechain":false,"message":{"content":"last"}}"#
        let tail = rowB + "\n" + rowC + "\n"
        let url = try fixture(rowA + "\n" + tail, name: "tail-cap.jsonl")

        // 10 bytes short of the full tail — the starting offset lands 10
        // bytes before the end of row A, inside it rather than at its start.
        let tailBytes = UInt64(tail.utf8.count) + 10
        let reader = ClaudeTranscriptReader(url: url, firstReadTailBytes: tailBytes)

        let messages = reader.poll()

        XCTAssertEqual(messages.map(\.id), ["middle", "last"])
        XCTAssertEqual(messages.last?.blocks, [.text("last")])
    }

    // MARK: - Finding the file

    /// The derived path is candidate zero; every other project directory's
    /// same-named file follows it, so a transcript Claude filed under a
    /// different slug is still found by name.
    func testTranscriptCandidatesListsDerivedFirstAndResolvedFindsTheRealFile() throws {
        let home = tempDirectory.appendingPathComponent("home")
        let sessionID = "pane-x"
        let cwd = "/Users/b/some/project"
        let expected = ClaudeModel.transcriptURL(sessionID: sessionID, cwd: cwd, home: home)

        let otherDir = home.appendingPathComponent(".claude/projects/other-project")
        try FileManager.default.createDirectory(at: otherDir, withIntermediateDirectories: true)
        let otherFile = otherDir.appendingPathComponent(
            ClaudeConversation.uuid(forSessionID: sessionID) + ".jsonl"
        )
        try #"{"type":"user"}"#.write(to: otherFile, atomically: true, encoding: .utf8)

        let candidates = ClaudeModel.transcriptCandidates(sessionID: sessionID, cwd: cwd, home: home)
        XCTAssertEqual(candidates.first, expected)
        XCTAssertTrue(candidates.contains(otherFile))

        XCTAssertEqual(
            ClaudeModel.resolvedTranscriptURL(sessionID: sessionID, cwd: cwd, home: home), otherFile
        )
    }

    /// The refactor that extracted `transcriptCandidates` from `current(...)`
    /// must keep its exact present behaviour: a transcript filed under a
    /// non-derived project slug still resolves through `current(...)`.
    func testCurrentStillResolvesThroughANonDerivedTranscriptAfterTheRefactor() throws {
        let home = tempDirectory.appendingPathComponent("home2")
        let sessionID = "pane-y"
        let cwd = "/Users/b/pane-cwd"
        let actual = ClaudeModel.transcriptURL(
            sessionID: sessionID, cwd: "/Users/b/elsewhere", home: home
        )
        try FileManager.default.createDirectory(
            at: actual.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try #"{"message":{"model":"claude-opus-5"}}"#.write(
            to: actual, atomically: true, encoding: .utf8
        )

        XCTAssertEqual(ClaudeModel.current(sessionID: sessionID, cwd: cwd, home: home), "claude-opus-5")
    }

    // MARK: - Fixtures

    private func fixture(_ text: String, name: String) throws -> URL {
        let url = tempDirectory.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        _ = try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }
}
