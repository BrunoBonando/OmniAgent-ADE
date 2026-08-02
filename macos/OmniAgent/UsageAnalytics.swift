import Foundation

/// Client-computed usage analytics — a faithful port of
/// `ui/src/state/usageAnalytics.ts`: the persisted store shape, every
/// `record*` mutator, `nextHourBoundary`'s hour-splitting accumulator, the
/// `__all__` global-project fan-out, `deriveUsageInsights`'s read-side
/// aggregation, and `parseTokenEstimateMax`.
///
/// This is activity telemetry the app derives from its own event stream —
/// counts and durations it already observes, aggregated for a readout —
/// never billing or a quota. There is no "limit" concept anywhere in this
/// codebase and this module does not invent one.
///
/// Every field is `Double`, matching the TypeScript oracle's untyped
/// `number` (JSON does not distinguish int from float either); a view
/// formats counts without decimals at render time.
struct UsageBucket: Equatable {
    var sessionsOpened: Double = 0
    var terminalsOpened: Double = 0
    var commandsSubmitted: Double = 0
    var inputChars: Double = 0
    var outputChars: Double = 0
    var tokenCount: Double = 0
    var activeMs: Double = 0
    var readyMs: Double = 0
    var thinkingMs: Double = 0
    var toolExecutionMs: Double = 0
    var awaitingApprovalMs: Double = 0
    var errorMs: Double = 0
}

struct UsageProjectAnalytics: Equatable {
    var totals = UsageBucket()
    var days: [String: UsageBucket] = [:]
    var hourActivityMs: [Double] = Array(repeating: 0, count: 24)
    var updatedAt: Double

    init(updatedAt: Double) {
        self.updatedAt = updatedAt
    }
}

/// `{version, projects}` — the shape stored under `SettingsKey.usageAnalytics`
/// (`"usage_analytics_v1"`), shared with the web/Tauri build against the same
/// `brain.db`.
struct UsageAnalyticsStore: Equatable {
    static let version = 1
    var projects: [String: UsageProjectAnalytics] = [:]
}

struct DailyUsagePoint: Equatable {
    let day: String
    let activeHours: Double
    let tokens: Double
    let sessions: Double
    let commands: Double
}

struct UsageInsights: Equatable {
    let totals: UsageBucket
    let trackedDays: Int
    let avgSessionsPerDay: Double
    let avgTokensPerDay: Double
    let avgActiveHoursPerDay: Double
    let bestHour: Int?
    let hourlyActiveHours: [Double]
    let daily: [DailyUsagePoint]
}

enum UsageAnalytics {
    /// `ui/src/state/usageAnalytics.ts`'s `GLOBAL_USAGE_PROJECT` — every
    /// metric fans out into this bucket too, so "usage across every project"
    /// is a plain read rather than a live sum over every project bucket.
    static let globalProject = "__all__"

    static func emptyProjectAnalytics(now: Double) -> UsageProjectAnalytics {
        UsageProjectAnalytics(updatedAt: now)
    }

    // MARK: - Recording

    static func recordSessionOpened(_ store: inout UsageAnalyticsStore, projectId: String, at: Double) {
        addMetric(&store, projectId: projectId, ts: at, keyPath: \.sessionsOpened, amount: 1)
    }

    static func recordTerminalOpened(_ store: inout UsageAnalyticsStore, projectId: String, at: Double) {
        addMetric(&store, projectId: projectId, ts: at, keyPath: \.terminalsOpened, amount: 1)
    }

    static func recordInput(_ store: inout UsageAnalyticsStore, projectId: String, chars: Int, commands: Int, at: Double) {
        addMetric(&store, projectId: projectId, ts: at, keyPath: \.inputChars, amount: Double(chars))
        addMetric(&store, projectId: projectId, ts: at, keyPath: \.commandsSubmitted, amount: Double(commands))
    }

    static func recordOutput(_ store: inout UsageAnalyticsStore, projectId: String, chars: Int, at: Double) {
        addMetric(&store, projectId: projectId, ts: at, keyPath: \.outputChars, amount: Double(chars))
    }

    static func recordTokens(_ store: inout UsageAnalyticsStore, projectId: String, tokens: Int, at: Double) {
        addMetric(&store, projectId: projectId, ts: at, keyPath: \.tokenCount, amount: Double(tokens))
    }

    /// Splits `[fromTs, toTs)` at every hour boundary it crosses, so an
    /// hour-long "thinking" span that starts at 11:50 attributes 10 minutes
    /// to hour 11 and 50 to hour 12 — what makes `hourActivityMs` a true
    /// "which hour of the day is this active in" histogram rather than a
    /// single bucket keyed by whichever hour the span happened to start in.
    static func recordStatusDuration(
        _ store: inout UsageAnalyticsStore,
        projectId: String,
        status: RemoteSessionStatus,
        fromTs: Double,
        toTs: Double
    ) {
        guard fromTs.isFinite, toTs.isFinite, toTs > fromTs else { return }
        var cursor = fromTs
        while cursor < toTs {
            let chunkEnd = min(toTs, nextHourBoundary(cursor))
            let chunkMs = chunkEnd - cursor
            let ids = touch(&store, projectId: projectId, ts: cursor)
            for id in ids {
                guard var project = store.projects[id] else { continue }
                addStatusMetric(&project.totals, status: status, amountMs: chunkMs)
                let day = dayKey(cursor)
                var bucket = project.days[day] ?? UsageBucket()
                addStatusMetric(&bucket, status: status, amountMs: chunkMs)
                project.days[day] = bucket
                if status != .ready {
                    project.hourActivityMs[hourComponent(cursor)] += chunkMs
                }
                store.projects[id] = project
            }
            cursor = chunkEnd
        }
    }

    /// The hour a timestamp's `nextHourBoundary` chunk starts in — a plain
    /// port of `nextHourBoundary`'s own boundary math (`setMinutes(0,0,0)`
    /// then advance one hour), in local time, matching every other
    /// `Date`-based derivation in this module.
    static func nextHourBoundary(_ ts: Double) -> Double {
        let calendar = localCalendar
        let date = Date(timeIntervalSince1970: ts / 1000)
        let hour = calendar.component(.hour, from: date)
        let hourStart = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: date) ?? date
        let next = calendar.date(byAdding: .hour, value: 1, to: hourStart) ?? hourStart
        return next.timeIntervalSince1970 * 1000
    }

    // MARK: - Reading

    /// One search hit's token estimate — the largest number that looks like
    /// a token count anywhere in `text`, across three phrasings an
    /// engine's CLI output might use. `nil` when nothing matches.
    static func parseTokenEstimateMax(_ text: String) -> Double? {
        guard !text.isEmpty else { return nil }
        let patterns = [
            #"(?:↓|down)\s*([0-9][0-9,]*)\s*tokens?"#,
            #"tokens?\s*[:=]\s*([0-9][0-9,]*)"#,
            #"\b([0-9][0-9,]*)\s*tokens?\b"#,
        ]
        var max: Double?
        let nsText = text as NSString
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
            for match in matches where match.numberOfRanges > 1 {
                let range = match.range(at: 1)
                guard range.location != NSNotFound else { continue }
                let raw = nsText.substring(with: range).replacingOccurrences(of: ",", with: "")
                guard let parsed = Double(raw), parsed > 0 else { continue }
                if max == nil || parsed > max! { max = parsed }
            }
        }
        return max
    }

    /// `DashboardOverview.tsx`'s numbers: per-day activity/tokens/sessions/
    /// commands over the trailing `rangeDays`, the best-hour-of-day and its
    /// full 24-slot histogram, and running totals/averages — everything the
    /// SwiftUI usage readout renders.
    static func deriveUsageInsights(
        _ store: UsageAnalyticsStore,
        projectId: String?,
        now: Double,
        rangeDays: Int = 14
    ) -> UsageInsights {
        let project = store.projects[projectId ?? globalProject] ?? emptyProjectAnalytics(now: now)
        let days = daySequence(now: now, days: max(1, rangeDays))
        let daily = days.map { day -> DailyUsagePoint in
            let bucket = project.days[day] ?? UsageBucket()
            return DailyUsagePoint(
                day: day,
                activeHours: bucket.activeMs / 3_600_000,
                tokens: bucket.tokenCount,
                sessions: bucket.sessionsOpened,
                commands: bucket.commandsSubmitted
            )
        }
        let trackedDays = max(1, project.days.count)
        let totals = project.totals
        let hourlyActiveHours = project.hourActivityMs.map { $0 / 3_600_000 }
        var bestHour: Int?
        var bestHourValue: Double = 0
        for (index, value) in hourlyActiveHours.enumerated() where value > bestHourValue {
            bestHourValue = value
            bestHour = index
        }
        return UsageInsights(
            totals: totals,
            trackedDays: trackedDays,
            avgSessionsPerDay: totals.sessionsOpened / Double(trackedDays),
            avgTokensPerDay: totals.tokenCount / Double(trackedDays),
            avgActiveHoursPerDay: totals.activeMs / 3_600_000 / Double(trackedDays),
            bestHour: bestHour,
            hourlyActiveHours: hourlyActiveHours,
            daily: daily
        )
    }

    // MARK: - Internals

    private static var localCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }

    static func dayKey(_ ts: Double) -> String {
        let date = Date(timeIntervalSince1970: ts / 1000)
        let components = localCalendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 1970, components.month ?? 1, components.day ?? 1)
    }

    private static func hourComponent(_ ts: Double) -> Int {
        localCalendar.component(.hour, from: Date(timeIntervalSince1970: ts / 1000))
    }

    private static func daySequence(now: Double, days: Int) -> [String] {
        let calendar = localCalendar
        let startOfToday = calendar.startOfDay(for: Date(timeIntervalSince1970: now / 1000))
        guard let start = calendar.date(byAdding: .day, value: -(days - 1), to: startOfToday) else { return [] }
        return (0..<days).compactMap { offset in
            calendar.date(byAdding: .day, value: offset, to: start).map { dayKey($0.timeIntervalSince1970 * 1000) }
        }
    }

    private static func projectIDs(for projectId: String) -> [String] {
        projectId == globalProject ? [globalProject] : [projectId, globalProject]
    }

    /// Ensures every id in `withGlobalProjects(projectId)` has a bucket and
    /// stamps its `updatedAt` — the port of `touch`. Returns the touched ids
    /// so a caller can mutate each one's totals/day bucket in place.
    @discardableResult
    private static func touch(_ store: inout UsageAnalyticsStore, projectId: String, ts: Double) -> [String] {
        let ids = projectIDs(for: projectId)
        for id in ids {
            if store.projects[id] == nil {
                store.projects[id] = emptyProjectAnalytics(now: ts)
            }
            store.projects[id]?.updatedAt = ts
        }
        return ids
    }

    private static func addMetric(
        _ store: inout UsageAnalyticsStore,
        projectId: String,
        ts: Double,
        keyPath: WritableKeyPath<UsageBucket, Double>,
        amount: Double
    ) {
        guard amount.isFinite, amount > 0 else { return }
        let ids = touch(&store, projectId: projectId, ts: ts)
        for id in ids {
            store.projects[id]?.totals[keyPath: keyPath] += amount
            let day = dayKey(ts)
            var bucket = store.projects[id]?.days[day] ?? UsageBucket()
            bucket[keyPath: keyPath] += amount
            store.projects[id]?.days[day] = bucket
        }
    }

    private static func addStatusMetric(_ bucket: inout UsageBucket, status: RemoteSessionStatus, amountMs: Double) {
        guard amountMs > 0 else { return }
        switch status {
        case .ready:
            bucket.readyMs += amountMs
        case .thinking:
            bucket.thinkingMs += amountMs
            bucket.activeMs += amountMs
        case .toolExecution:
            bucket.toolExecutionMs += amountMs
            bucket.activeMs += amountMs
        case .awaitingApproval:
            bucket.awaitingApprovalMs += amountMs
            bucket.activeMs += amountMs
        case .error:
            bucket.errorMs += amountMs
            bucket.activeMs += amountMs
        }
    }
}

/// The `usage_analytics_v1` settings row, in and out. `JSONSerialization`
/// rather than `Codable`, same house convention as `PersistedLayoutCodec`/
/// `NotificationFeedCodec`: one malformed project, day or field must cost
/// only itself, never the whole store.
enum UsageAnalyticsCodec {
    static func serialize(_ store: UsageAnalyticsStore) -> String {
        var projects: [String: Any] = [:]
        for (id, project) in store.projects {
            projects[id] = encoded(project)
        }
        let payload: [String: Any] = ["version": UsageAnalyticsStore.version, "projects": projects]
        guard
            JSONSerialization.isValidJSONObject(payload),
            let data = try? JSONSerialization.data(withJSONObject: payload),
            let json = String(data: data, encoding: .utf8)
        else {
            return #"{"version":1,"projects":{}}"#
        }
        return json
    }

    private static func encoded(_ project: UsageProjectAnalytics) -> [String: Any] {
        var days: [String: Any] = [:]
        for (day, bucket) in project.days { days[day] = encoded(bucket) }
        return [
            "totals": encoded(project.totals),
            "days": days,
            "hourActivityMs": project.hourActivityMs,
            "updatedAt": project.updatedAt,
        ]
    }

    private static func encoded(_ bucket: UsageBucket) -> [String: Any] {
        [
            "sessionsOpened": bucket.sessionsOpened,
            "terminalsOpened": bucket.terminalsOpened,
            "commandsSubmitted": bucket.commandsSubmitted,
            "inputChars": bucket.inputChars,
            "outputChars": bucket.outputChars,
            "tokenCount": bucket.tokenCount,
            "activeMs": bucket.activeMs,
            "readyMs": bucket.readyMs,
            "thinkingMs": bucket.thinkingMs,
            "toolExecutionMs": bucket.toolExecutionMs,
            "awaitingApprovalMs": bucket.awaitingApprovalMs,
            "errorMs": bucket.errorMs,
        ]
    }

    /// Never throws — a corrupt/missing row restores to an empty store
    /// rather than breaking launch, matching `parseUsageAnalyticsStore`.
    static func deserialize(_ raw: String?) -> UsageAnalyticsStore {
        guard
            let raw, !raw.isEmpty,
            let data = raw.data(using: .utf8),
            let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            number(parsed["version"]) == Double(UsageAnalyticsStore.version),
            let rawProjects = parsed["projects"] as? [String: Any]
        else {
            return UsageAnalyticsStore()
        }
        var store = UsageAnalyticsStore()
        for (id, rawProject) in rawProjects {
            guard let dict = rawProject as? [String: Any] else { continue }
            store.projects[id] = decodedProject(dict)
        }
        return store
    }

    private static func decodedProject(_ dict: [String: Any]) -> UsageProjectAnalytics {
        let updatedAt = number(dict["updatedAt"]) ?? Date().timeIntervalSince1970 * 1000
        var project = UsageProjectAnalytics(updatedAt: updatedAt)
        if let totalsRaw = dict["totals"] as? [String: Any] {
            project.totals = decodedBucket(totalsRaw)
        }
        if let daysRaw = dict["days"] as? [String: Any] {
            for (day, bucketRaw) in daysRaw {
                guard isDayKey(day), let bucketDict = bucketRaw as? [String: Any] else { continue }
                project.days[day] = decodedBucket(bucketDict)
            }
        }
        if let hours = dict["hourActivityMs"] as? [Any] {
            for index in 0..<min(24, hours.count) {
                if let value = nonNegative(hours[index]) {
                    project.hourActivityMs[index] = value
                }
            }
        }
        return project
    }

    private static func decodedBucket(_ dict: [String: Any]) -> UsageBucket {
        var bucket = UsageBucket()
        bucket.sessionsOpened = nonNegative(dict["sessionsOpened"]) ?? bucket.sessionsOpened
        bucket.terminalsOpened = nonNegative(dict["terminalsOpened"]) ?? bucket.terminalsOpened
        bucket.commandsSubmitted = nonNegative(dict["commandsSubmitted"]) ?? bucket.commandsSubmitted
        bucket.inputChars = nonNegative(dict["inputChars"]) ?? bucket.inputChars
        bucket.outputChars = nonNegative(dict["outputChars"]) ?? bucket.outputChars
        bucket.tokenCount = nonNegative(dict["tokenCount"]) ?? bucket.tokenCount
        bucket.activeMs = nonNegative(dict["activeMs"]) ?? bucket.activeMs
        bucket.readyMs = nonNegative(dict["readyMs"]) ?? bucket.readyMs
        bucket.thinkingMs = nonNegative(dict["thinkingMs"]) ?? bucket.thinkingMs
        bucket.toolExecutionMs = nonNegative(dict["toolExecutionMs"]) ?? bucket.toolExecutionMs
        bucket.awaitingApprovalMs = nonNegative(dict["awaitingApprovalMs"]) ?? bucket.awaitingApprovalMs
        bucket.errorMs = nonNegative(dict["errorMs"]) ?? bucket.errorMs
        return bucket
    }

    private static func nonNegative(_ raw: Any?) -> Double? {
        guard let value = number(raw), value.isFinite, value >= 0 else { return nil }
        return value
    }

    private static func number(_ raw: Any?) -> Double? {
        raw as? Double
    }

    private static func isDayKey(_ value: String) -> Bool {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard value.count == 10, parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2
        else { return false }
        return parts.allSatisfy { $0.allSatisfy(\.isNumber) }
    }
}
