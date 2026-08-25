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
    /// worse than losing formatting.
    static func split(_ text: String) -> [SystemBlockSegment] {
        var segments: [SystemBlockSegment] = []
        var prose = ""
        var rest = Substring(text)

        while let open = nextOpening(in: rest) {
            let close = "</\(open.kind.rawValue)>"
            guard let closeRange = rest[open.range.upperBound...].range(of: close) else {
                break
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
        in text: Substring
    ) -> (kind: SystemBlockKind, range: Range<Substring.Index>)? {
        var best: (kind: SystemBlockKind, range: Range<Substring.Index>)?
        for kind in SystemBlockKind.allCases {
            guard let found = text.range(of: "<\(kind.rawValue)>") else { continue }
            if best == nil || found.lowerBound < best!.range.lowerBound {
                best = (kind, found)
            }
        }
        return best
    }
}
