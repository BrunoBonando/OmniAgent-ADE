import Foundation

/// Claude's rate-limit windows, as `/usage` reports them.
///
/// Every field optional: a failed fetch, a timeout, or a changed output format
/// must leave the readout stale rather than blank, and must never throw.
struct ClaudeUsageLimits: Equatable {
    let sessionPercent: Int?
    let sessionResets: String?
    let weekPercent: Int?
    let weekResets: String?
    let modelName: String?
    let modelPercent: Int?

    static let empty = ClaudeUsageLimits(
        sessionPercent: nil, sessionResets: nil,
        weekPercent: nil, weekResets: nil,
        modelName: nil, modelPercent: nil
    )

    /// Line-oriented, because the output is line-oriented. Anything that does
    /// not match is ignored rather than treated as an error.
    static func parse(_ output: String) -> ClaudeUsageLimits {
        var session: (Int, String?)?
        var week: (Int, String?)?
        var model: (String, Int)?

        for raw in output.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let percent = percent(in: line) else { continue }
            let resets = resetPhrase(in: line)
            if line.hasPrefix("Current session:") {
                session = (percent, resets)
            } else if line.hasPrefix("Current week (all models)") {
                week = (percent, resets)
            } else if line.hasPrefix("Current week ("),
                      let open = line.firstIndex(of: "("),
                      let close = line.firstIndex(of: ")") {
                model = (String(line[line.index(after: open)..<close]), percent)
            }
        }

        return ClaudeUsageLimits(
            sessionPercent: session?.0, sessionResets: session?.1,
            weekPercent: week?.0, weekResets: week?.1,
            modelName: model?.0, modelPercent: model?.1
        )
    }

    /// The integer immediately before "% used".
    private static func percent(in line: String) -> Int? {
        guard let range = line.range(of: "% used") else { return nil }
        let digits = line[line.startIndex..<range.lowerBound].reversed()
            .prefix { $0.isNumber }
        return Int(String(digits.reversed()))
    }

    /// What follows "resets ", minus any trailing parenthesised timezone.
    private static func resetPhrase(in line: String) -> String? {
        guard let range = line.range(of: "resets ") else { return nil }
        var phrase = String(line[range.upperBound...])
        if let paren = phrase.range(of: " (") {
            phrase = String(phrase[phrase.startIndex..<paren.lowerBound])
        }
        return phrase.trimmingCharacters(in: .whitespaces)
    }
}

/// One app-wide poller for `/usage`.
///
/// Deliberately a singleton with a long interval: `/usage` is a real request
/// against the very limits it reports, so measuring usage consumes usage.
/// The limits are account-global and identical in every pane, so eight panes
/// polling would be eight times the cost for one number.
final class ClaudeUsageLimitsPoller {
    static let shared = ClaudeUsageLimitsPoller()

    private(set) var latest: ClaudeUsageLimits?
    var onChange: (() -> Void)?

    /// Minutes, not seconds. See the type's own comment.
    static let interval: TimeInterval = 300

    private var inFlight = false
    private let queue = DispatchQueue(label: "com.omniagent.usage-limits")

    /// Overridden by tests so the suite never shells out to `claude`.
    var runnerForTesting: (() -> String)?

    func refresh() {
        guard !inFlight else { return }
        inFlight = true
        queue.async { [weak self] in
            guard let self else { return }
            let output = self.runnerForTesting?() ?? Self.runUsage()
            let parsed = ClaudeUsageLimits.parse(output)
            DispatchQueue.main.async {
                self.inFlight = false
                // A fetch that parsed nothing leaves the last good value in
                // place: stale beats blank.
                if parsed != .empty { self.latest = parsed }
                self.onChange?()
            }
        }
    }

    private static func runUsage() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["claude", "-p", "/usage"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return ""
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
