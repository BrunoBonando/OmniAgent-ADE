import Foundation

/// One rendered chunk of a `TranscriptMessage`: either prose or one tool
/// call. No `.thinking` case — the app view this feeds renders neither
/// thinking text nor tool output, so a case for it would never be
/// constructed; see `ClaudeTranscriptReader`'s decoding rules.
enum TranscriptBlock: Equatable {
    case text(String)
    /// `detail` is the one field worth showing next to the call — `Bash`'s
    /// `command`, `Read`'s `file_path` — never the whole `input` dict, which
    /// can carry an entire file (`Write`) or a diff (`Edit`). `""` when the
    /// tool carries none of the recognised fields.
    case tool(name: String, detail: String)
}

/// One assistant row's token usage, as Claude Code writes it.
///
/// Read per message rather than aggregated per project: the App view's
/// readouts are about *this conversation*, and `UsageAnalytics` buckets by
/// project, which is the wrong unit for a pane.
struct TranscriptUsage: Equatable {
    let input: Int
    let output: Int
    let cacheRead: Int
    let cacheCreation: Int

    /// What the model is currently carrying — everything that had to be sent,
    /// which is the window fill. Output is excluded: it is generated, not
    /// carried.
    var contextTokens: Int { input + cacheRead + cacheCreation }

    /// Everything this row cost, in and out.
    var totalTokens: Int { input + output + cacheRead + cacheCreation }

    static func total(of usages: [TranscriptUsage]) -> Int {
        usages.reduce(0) { $0 + $1.totalTokens }
    }

    /// The CURRENT window fill — the latest row's figure. Summing context
    /// across rows would grow without bound and mean nothing.
    static func latestContext(of usages: [TranscriptUsage]) -> Int {
        usages.last?.contextTokens ?? 0
    }
}

/// One `user` or `assistant` row of a Claude transcript, already filtered
/// down to what the app view renders. Never empty: a row left with no
/// blocks after filtering — a `tool_result`-only `user` row, a
/// `thinking`-only `assistant` row — is dropped by the reader below rather
/// than returned as a bubble with nothing in it.
struct TranscriptMessage: Equatable {
    let id: String
    let isUser: Bool
    let blocks: [TranscriptBlock]
    /// `nil` on every `user` row and on any assistant row Claude wrote
    /// without a `usage` object — a row with no figures contributes nothing
    /// rather than counting as zero-cost.
    var usage: TranscriptUsage?
}

/// What one `poll()` found: the rows it decoded, and whether the file was
/// rewritten out from under the reader before it read them.
///
/// The flag exists because those two facts mean opposite things to a caller.
/// Ordinarily a poll's messages are the ones appended since the last call, so
/// a view appends them and rebuilds nothing. After a rewrite the reader starts
/// over at byte zero, so the same poll hands back rows the view already has on
/// screen — appending those would draw the conversation twice. Reporting the
/// reset rather than quietly re-emitting is what lets the view answer it.
struct TranscriptUpdate: Equatable {
    /// Decoded from the bytes appended since the previous call — or, when
    /// `didReset`, from the start of the rewritten file.
    let messages: [TranscriptMessage]
    /// Claude rewrote the transcript (compaction, `/clear`) and this poll
    /// started over from its beginning. Everything the caller was showing is
    /// stale: it must clear it before appending `messages`.
    let didReset: Bool

    /// Nothing found, nothing to answer for — a missing file, or no new bytes.
    static let nothing = TranscriptUpdate(messages: [], didReset: false)
}

/// Turns a Claude Code transcript
/// (`~/.claude/projects/<slug(cwd)>/<uuid>.jsonl` — see
/// `ClaudeConversation`/`ClaudeModel.transcriptURL` in `EngineLauncher.swift`
/// for how a pane's transcript path is derived) into `TranscriptMessage`s for
/// that pane's chat view.
///
/// The file is a live log another process (`claude`) appends to while this
/// reads it — never opened exclusively, never assumed complete. `poll()` is
/// built entirely around that: it holds a byte offset plus a carry-over
/// buffer, so a row read while only half-written waits for its other half
/// instead of being dropped or returned twice, and a line that turns out not
/// to be valid JSON is skipped rather than treated as an error — this file is
/// written concurrently, so malformed or partial content is normal.
final class ClaudeTranscriptReader {
    private let url: URL
    private let firstReadTailBytes: UInt64
    private var offset: UInt64 = 0
    private var carry = Data()
    /// Set once a real starting offset has been established. A poll that
    /// only found the file missing must not set this — a fresh pane's
    /// transcript still gets the tail-cap treatment once it finally appears.
    private var hasStarted = false

    init(url: URL, firstReadTailBytes: UInt64 = 1 << 20) {
        self.url = url
        self.firstReadTailBytes = firstReadTailBytes
    }

    /// Messages decoded from bytes appended since the previous call — or, on
    /// the first call, from this reader's starting offset. Empty while the
    /// file does not exist yet, or once nothing new has landed since the
    /// last poll.
    ///
    /// `didReset` marks the one case where the messages are *not* merely new:
    /// a rewritten file is re-read from its start, so rows the caller already
    /// has come back with it. See `TranscriptUpdate`.
    func poll() -> TranscriptUpdate {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return .nothing }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return .nothing }

        var discardLeadingFragment = false
        var didReset = false
        if !hasStarted {
            hasStarted = true
            // ponytail: 1MB tail ≈ 200 messages; paged loading if scrollback ever matters
            if size > firstReadTailBytes {
                offset = size - firstReadTailBytes
                discardLeadingFragment = true
            }
        } else if size < offset {
            // Claude rewrote the file out from under us (compaction, /clear);
            // nothing before the new end is trustworthy, so this starts over
            // rather than staying parked past the new end forever — and says
            // so, because starting over means re-emitting rows the caller is
            // already showing.
            didReset = true
            offset = 0
            carry = Data()
        }

        guard size > offset,
              (try? handle.seek(toOffset: offset)) != nil,
              let data = try? handle.readToEnd()
        else { return TranscriptUpdate(messages: [], didReset: didReset) }
        offset = size

        var chunk = data
        if discardLeadingFragment {
            // The tail offset above landed mid-line; that leading fragment is
            // half a row and cannot be parsed, so it is thrown away at the
            // next line boundary rather than handed to the decoder.
            if let newline = chunk.firstIndex(of: Self.newline) {
                chunk = chunk[chunk.index(after: newline)...]
            } else {
                chunk = Data()
            }
        }

        var combined = carry
        combined.append(chunk)

        var messages: [TranscriptMessage] = []
        var lineStart = combined.startIndex
        while let newline = combined[lineStart...].firstIndex(of: Self.newline) {
            if let message = Self.decode(combined[lineStart..<newline]) {
                messages.append(message)
            }
            lineStart = combined.index(after: newline)
        }
        // Whatever is left after the last newline is a row still being
        // written; re-wrapped fresh so its indices start at zero again.
        carry = Data(combined[lineStart...])
        return TranscriptUpdate(messages: messages, didReset: didReset)
    }

    private static let newline = UInt8(ascii: "\n")

    // MARK: - One line

    /// One newline-delimited row, decoded and filtered per the rules above,
    /// or `nil` for anything not worth a bubble: the wrong `type`, a
    /// sidechain row, an id-less or message-less row, invalid JSON, or a row
    /// with no blocks left once thinking/tool-result/blank-text are stripped.
    private static func decode(_ line: Data) -> TranscriptMessage? {
        guard !line.isEmpty else { return nil }
        // Same trade `ClaudeModel.lastModel(inTailOf:)` makes at
        // `EngineLauncher.swift:134`: a strict UTF-8 decode can fail outright
        // on a single bad byte, and this fallback cannot.
        let text = String(data: line, encoding: .utf8) ?? String(decoding: line, as: UTF8.self)
        guard let jsonData = text.data(using: .utf8),
              let row = (try? JSONSerialization.jsonObject(with: jsonData)) as? [String: Any],
              let type = row["type"] as? String, type == "user" || type == "assistant",
              (row["isSidechain"] as? Bool) != true,
              let uuid = row["uuid"] as? String,
              let message = row["message"] as? [String: Any]
        else { return nil }

        let blocks = blocks(from: message["content"])
        guard !blocks.isEmpty else { return nil }
        let usage = (message["usage"] as? [String: Any]).map {
            TranscriptUsage(
                input: $0["input_tokens"] as? Int ?? 0,
                output: $0["output_tokens"] as? Int ?? 0,
                cacheRead: $0["cache_read_input_tokens"] as? Int ?? 0,
                cacheCreation: $0["cache_creation_input_tokens"] as? Int ?? 0
            )
        }
        return TranscriptMessage(id: uuid, isUser: type == "user", blocks: blocks, usage: usage)
    }

    /// `message.content` is either a bare string or an array of typed
    /// blocks; either shape lands here. `thinking` and `tool_result` blocks
    /// are dropped outright — the tool call itself is already visible as the
    /// assistant's own `.tool` block, and v1 renders neither.
    private static func blocks(from content: Any?) -> [TranscriptBlock] {
        if let text = content as? String {
            return textBlock(text).map { [$0] } ?? []
        }
        guard let array = content as? [Any] else { return [] }
        return array.compactMap { element in
            guard let block = element as? [String: Any], let type = block["type"] as? String
            else { return nil }
            switch type {
            case "text":
                guard let text = block["text"] as? String else { return nil }
                return textBlock(text)
            case "tool_use":
                guard let name = block["name"] as? String else { return nil }
                let input = block["input"] as? [String: Any] ?? [:]
                return .tool(name: name, detail: toolDetail(from: input))
            default:
                return nil
            }
        }
    }

    private static func textBlock(_ text: String) -> TranscriptBlock? {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : .text(text)
    }

    /// The one field worth showing next to a tool call. First match wins;
    /// in practice a tool carries at most one of these.
    private static func toolDetail(from input: [String: Any]) -> String {
        for key in ["file_path", "command", "pattern", "path", "url"] {
            if let value = input[key] as? String { return value }
        }
        return ""
    }
}

/// One conversational turn: the consecutive `TranscriptMessage`s of a single
/// role, merged.
///
/// The merge exists because Claude Code writes each `tool_use` as its own
/// assistant row, so one reply arrives as several rows and a view drawing a
/// role label per row stamps "Claude" six times down a single answer.
struct TranscriptTurn: Equatable {
    /// The first merged message's id — stable for as long as the turn grows.
    let id: String
    let isUser: Bool
    var blocks: [TranscriptBlock]
    /// Every merged message's usage, in order, so a view can sum a
    /// conversation's cost — and read its latest context fill — without
    /// re-reading the transcript. Rows that carried no figures leave no
    /// entry.
    var usages: [TranscriptUsage] = []

    static func group(_ messages: [TranscriptMessage]) -> [TranscriptTurn] {
        var turns: [TranscriptTurn] = []
        append(messages, to: &turns)
        return turns
    }

    /// Merges `messages` into `turns`, extending the last turn whenever the
    /// role matches and opening a new one when it flips.
    ///
    /// Returns the index of the first turn this changed, so a caller holding
    /// one view per turn redraws from there instead of rebuilding the whole
    /// conversation. `turns.count` when `messages` was empty — a valid
    /// "nothing from here on" for the caller's loop.
    @discardableResult
    static func append(_ messages: [TranscriptMessage], to turns: inout [TranscriptTurn]) -> Int {
        var firstChanged = turns.count
        for message in messages {
            if let last = turns.last, last.isUser == message.isUser {
                turns[turns.count - 1].blocks.append(contentsOf: message.blocks)
                if let usage = message.usage { turns[turns.count - 1].usages.append(usage) }
            } else {
                turns.append(
                    TranscriptTurn(
                        id: message.id,
                        isUser: message.isUser,
                        blocks: message.blocks,
                        usages: message.usage.map { [$0] } ?? []
                    )
                )
            }
            firstChanged = min(firstChanged, turns.count - 1)
        }
        return firstChanged
    }
}
