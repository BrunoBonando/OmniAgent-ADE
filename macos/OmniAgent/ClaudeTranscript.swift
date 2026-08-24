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

/// One `user` or `assistant` row of a Claude transcript, already filtered
/// down to what the app view renders. Never empty: a row left with no
/// blocks after filtering — a `tool_result`-only `user` row, a
/// `thinking`-only `assistant` row — is dropped by the reader below rather
/// than returned as a bubble with nothing in it.
struct TranscriptMessage: Equatable {
    let id: String
    let isUser: Bool
    let blocks: [TranscriptBlock]
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
    /// the first call, from this reader's starting offset. `[]` while the
    /// file does not exist yet, or once nothing new has landed since the
    /// last poll.
    func poll() -> [TranscriptMessage] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return [] }

        var discardLeadingFragment = false
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
            // rather than staying parked past the new end forever.
            offset = 0
            carry = Data()
        }

        guard size > offset,
              (try? handle.seek(toOffset: offset)) != nil,
              let data = try? handle.readToEnd()
        else { return [] }
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
        return messages
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
        return TranscriptMessage(id: uuid, isUser: type == "user", blocks: blocks)
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
