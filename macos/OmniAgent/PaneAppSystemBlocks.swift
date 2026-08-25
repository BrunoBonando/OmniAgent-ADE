import Foundation

/// The system blocks the App view folds away. A fixed list, deliberately:
/// the transcript corpus also contains `<div>`, `<path>`, `<string>` and
/// `<private>` as *content* — SVG, HTML and plist in code under discussion —
/// so a generic tag matcher would silently delete the user's own work. A tag
/// not named here is prose and stays prose, verbatim.
enum SystemBlockKind: String, CaseIterable {
    case taskNotification = "task-notification"
    case systemReminder = "system-reminder"
    case commandName = "command-name"
    case commandMessage = "command-message"
    case commandArgs = "command-args"
    case localCommandStdout = "local-command-stdout"
    case totalTokens = "total_tokens"
}

struct SystemBlock: Equatable {
    let kind: SystemBlockKind
    let body: String
}

enum SystemBlockSegment: Equatable {
    case prose(String)
    case system(SystemBlock)
}

enum SystemBlockSplitter {
    /// Splits raw assistant text into prose and recognised system blocks.
    ///
    /// Scans for an opening tag from the allowlist and its matching close.
    /// An unclosed block is not a block — the text stays prose, because a
    /// reply still being written ends mid-anything and losing content is
    /// worse than losing formatting. The scan then carries on past that
    /// opening rather than abandoning the message: a later, well-formed block
    /// in the same reply would otherwise stay raw prose because of it.
    ///
    /// Fenced code is invisible to the scan. An allowlisted name *quoted*
    /// inside a ``` fence is the allowlist trap's second half: this repo's own
    /// transcripts quote `<total_tokens>` and `<system-reminder>` constantly,
    /// and tearing one out of the middle of a fence deletes it (`total_tokens`
    /// renders as nothing at all) and leaves the fence unbalanced, so
    /// `MarkdownBlock.parse` renders the whole rest of the message as one code
    /// block.
    static func split(_ text: String) -> [SystemBlockSegment] {
        var segments: [SystemBlockSegment] = []
        var prose = ""
        var rest = Substring(text)
        let fences = fenceRanges(in: text)

        while let open = nextOpening(in: rest, outside: fences) {
            let close = "</\(open.kind.rawValue)>"
            guard let closeRange = firstOccurrence(
                of: close, in: rest[open.range.upperBound...], outside: fences
            ) else {
                prose += rest[rest.startIndex..<open.range.upperBound]
                rest = rest[open.range.upperBound...]
                continue
            }
            prose += rest[rest.startIndex..<open.range.lowerBound]
            flush(&prose, into: &segments)
            let body = rest[open.range.upperBound..<closeRange.lowerBound]
            segments.append(.system(SystemBlock(
                kind: open.kind,
                body: body.trimmingCharacters(in: .whitespacesAndNewlines)
            )))
            rest = rest[closeRange.upperBound...]
        }

        prose += rest
        flush(&prose, into: &segments)
        return segments.isEmpty ? [.prose(text)] : segments
    }

    private static func flush(_ prose: inout String, into segments: inout [SystemBlockSegment]) {
        let trimmed = prose.trimmingCharacters(in: .whitespacesAndNewlines)
        prose = ""
        guard !trimmed.isEmpty else { return }
        segments.append(.prose(trimmed))
    }

    private static func nextOpening(
        in text: Substring,
        outside fences: [Range<String.Index>]
    ) -> (kind: SystemBlockKind, range: Range<Substring.Index>)? {
        var best: (kind: SystemBlockKind, range: Range<Substring.Index>)?
        for kind in SystemBlockKind.allCases {
            guard let found = firstOccurrence(
                of: "<\(kind.rawValue)>", in: text, outside: fences
            ) else { continue }
            if best == nil || found.lowerBound < best!.range.lowerBound {
                best = (kind, found)
            }
        }
        return best
    }

    /// The first match of `needle` that is not inside a fence. A match that is
    /// gets skipped over, not abandoned — the same tag may well occur for real
    /// further down the reply.
    ///
    /// `fences` are indices into the original `String`, and every `Substring`
    /// here is a slice of it, so the two are directly comparable.
    private static func firstOccurrence(
        of needle: String,
        in text: Substring,
        outside fences: [Range<String.Index>]
    ) -> Range<Substring.Index>? {
        var searchFrom = text.startIndex
        while let found = text[searchFrom...].range(of: needle) {
            guard fences.contains(where: { $0.contains(found.lowerBound) }) else { return found }
            searchFrom = found.upperBound
        }
        return nil
    }

    /// Every fenced region, one range per fence, by the same rule
    /// `MarkdownBlock.parse` uses: a line whose first non-space run is ```
    /// opens or closes one. An unterminated fence runs to the end of the text,
    /// which is what a reply caught mid-write looks like.
    private static func fenceRanges(in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var openedAt: String.Index?
        var lineStart = text.startIndex
        while lineStart < text.endIndex {
            let lineEnd = text[lineStart...].firstIndex(of: "\n") ?? text.endIndex
            let line = text[lineStart..<lineEnd].trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if let start = openedAt {
                    ranges.append(start..<lineEnd)
                    openedAt = nil
                } else {
                    openedAt = lineStart
                }
            }
            lineStart = lineEnd < text.endIndex ? text.index(after: lineEnd) : text.endIndex
        }
        if let start = openedAt { ranges.append(start..<text.endIndex) }
        return ranges
    }
}
