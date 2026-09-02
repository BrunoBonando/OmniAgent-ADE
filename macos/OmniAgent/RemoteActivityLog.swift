import Foundation

/// The wire shape of one activity row — `ActivityEntry`'s JSON, both inside a
/// `RemoteActivity` push (`SessionConnection`'s `onRemoteActivity`) and one
/// line of `remote-activity.jsonl` (`RemoteActivityLog.history(from:limit:)`).
/// Kept separate from `RemoteActivityLog.Entry`: the wire's `ts` is a raw
/// RFC 3339 string, and turning it into a `Date` is a fallible step this type
/// does not have to know how to do.
struct RemoteActivityWireEntry: Decodable {
    let ts: String
    let kind: String
    let summary: String
    let detail: String?
}

/// The `RemoteActivity` (`0x8f`) push payload — `{"entries":[…]}` (spec §8).
struct RemoteActivityPushPayload: Decodable {
    let entries: [RemoteActivityWireEntry]
}

/// The daemon-witnessed remote activity log (2026-09-01 remote environment
/// sharing spec §8) — daemon-witnessed only, never self-reported: every row
/// in here came from a `RemoteActivity` push or, for history, from
/// `remote-activity.jsonl`, both written by the daemon from frames it
/// actually received.
///
/// Two lives, two orderings. **Live** (`entries`, `append(_:)`): fed by
/// `SessionConnection.onRemoteActivity` while a remote session is connected,
/// newest **last** — the order the takeover panel's table (Task 20) renders
/// top-to-bottom, oldest at top. **After the fact** (`history(from:limit:)`):
/// reads the durable file back for Settings › Remote › Activity, newest
/// **first** — the order a history list reads, most recent connection on top.
@MainActor
final class RemoteActivityLog: ObservableObject {
    /// One row, resolved into the shape both the live table and the history
    /// list render. `detail == nil` means the row has nothing to expand
    /// (spec §8: "clicking a session is one line and no detail") — the table
    /// must not draw a disclosure chevron for one, and must not respond to
    /// clicks on it.
    struct Entry: Identifiable, Equatable {
        let id: UUID
        let ts: Date
        let kind: String
        let summary: String
        let detail: String?

        init(id: UUID = UUID(), ts: Date, kind: String, summary: String, detail: String?) {
            self.id = id
            self.ts = ts
            self.kind = kind
            self.summary = summary
            self.detail = detail
        }

        /// `nil` when `wire.ts` is not a timestamp this build can parse — a
        /// daemon/app skew, not a row worth showing with a made-up date.
        init?(wire: RemoteActivityWireEntry) {
            guard let ts = RemoteActivityLog.parseTimestamp(wire.ts) else { return nil }
            self.init(ts: ts, kind: wire.kind, summary: wire.summary, detail: wire.detail)
        }
    }

    /// Live rows for the current (or most recent) remote session, newest
    /// last. Reset by whoever owns this log when a new remote connection
    /// starts (the takeover panel, Task 20) — this type has no notion of
    /// "connection" on its own, only a stream of rows.
    @Published private(set) var entries: [Entry] = []

    /// Appends one push's worth of rows — always at the end, since `entries`
    /// is newest-last.
    func append(_ pushed: [Entry]) {
        guard !pushed.isEmpty else { return }
        entries.append(contentsOf: pushed)
    }

    /// Clears the live feed — a new remote connection starting, or the panel
    /// going away. History is unaffected: it is `remote-activity.jsonl`, not
    /// this array.
    func reset() {
        entries.removeAll()
    }

    /// Reads `remote-activity.jsonl` back for Settings › Remote › Activity
    /// (Task 20): newest first, tolerant of a line that fails to parse (a
    /// torn write at the tail of the file, a future field this build does not
    /// know), and capped at the most recent `limit` rows.
    ///
    /// A missing or unreadable file returns no rows rather than throwing —
    /// "no remote sessions yet" and "the file could not be read" render the
    /// same empty state, and neither is a reason to crash Settings.
    static func history(from url: URL, limit: Int) -> [Entry] {
        guard let data = try? Data(contentsOf: url),
            let text = String(data: data, encoding: .utf8)
        else {
            return []
        }
        let decoder = JSONDecoder()
        var parsed: [Entry] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let lineData = line.data(using: .utf8),
                let wire = try? decoder.decode(RemoteActivityWireEntry.self, from: lineData),
                let entry = Entry(wire: wire)
            else {
                continue
            }
            parsed.append(entry)
        }
        // `parsed` is in file order (oldest first, since the daemon appends);
        // the *most recent* `limit` rows are its tail, and the caller wants
        // them newest first.
        return Array(parsed.suffix(max(0, limit)).reversed())
    }

    /// The daemon writes RFC 3339 (`chrono`'s `to_rfc3339()`: a numeric
    /// `+00:00` offset, fractional seconds only when the original timestamp
    /// actually has sub-second precision) — the same shape
    /// `RemoteTakeoverPanel.RemoteConnectionInfo`/`RemoteViewersView` already
    /// parse the daemon's other RFC 3339 fields with: try without fractional
    /// seconds first, then with, so both shapes of the same format decode.
    ///
    /// `nonisolated`: everything declared inside `RemoteActivityLog`
    /// inherits its `@MainActor` isolation by default, but `Entry.init?(wire:)`
    /// — where this is called from — is a plain struct initializer with no
    /// isolation of its own, and `ISO8601DateFormatter` holds no state this
    /// type needs to serialize access to. Without this, decoding a wire
    /// entry (on a background queue, in `SessionConnection`'s frame handler)
    /// would need to hop to the main actor just to parse a string.
    fileprivate nonisolated static func parseTimestamp(_ raw: String) -> Date? {
        iso8601.date(from: raw) ?? iso8601Fractional.date(from: raw)
    }

    private nonisolated static let iso8601 = ISO8601DateFormatter()
    private nonisolated static let iso8601Fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
