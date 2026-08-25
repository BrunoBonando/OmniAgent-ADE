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

    /// Minutes, not seconds. See the type's own comment.
    static let interval: TimeInterval = 300

    /// How long one fetch may take before it is abandoned and the child
    /// killed. `claude -p /usage` is a network round trip and normally takes
    /// seconds; anything past this is hung, not slow.
    static let fetchTimeout: TimeInterval = 20

    private var inFlight = false
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.omniagent.usage-limits")

    /// Every live App pane that wants the push, keyed by its own identity.
    ///
    /// A single `onChange` closure was the original shape and it was wrong
    /// with more than one App pane open: registering silently replaced the
    /// previous pane's closure, so only the pane that went live *last* was
    /// ever told, and every other pane sat on whatever it had last pulled.
    private var observers: [ObjectIdentifier: () -> Void] = [:]

    /// A stand-in for the subprocess. Nil in the app; setting it is also what
    /// lets `refresh()` run at all under XCTest — see the guard there.
    var runnerForTesting: (() -> String)?

    /// Whether the repeating refresh is armed.
    var isRepeating: Bool { timer != nil }

    /// Registers `owner` for the push. Idempotent per owner: re-registering
    /// replaces that owner's block and nobody else's.
    func addObserver(_ owner: AnyObject, _ block: @escaping () -> Void) {
        observers[ObjectIdentifier(owner)] = block
    }

    func removeObserver(_ owner: AnyObject) {
        observers.removeValue(forKey: ObjectIdentifier(owner))
    }

    /// Fetches once now and arms the repeating refresh. Idempotent: the timer
    /// is app-wide like the poller, so the second pane to go live joins the
    /// one already running rather than starting a second.
    func start() {
        refresh()
        guard timer == nil else { return }
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(
            deadline: .now() + Self.interval,
            repeating: Self.interval,
            leeway: .seconds(30)
        )
        source.setEventHandler { [weak self] in self?.refresh() }
        source.resume()
        timer = source
    }

    /// One fetch. Safe to call from anywhere — the state it guards
    /// (`inFlight`, `latest`, `observers`) is main-queue-only, and the timer
    /// fires on `queue`, so an off-main call hops rather than racing.
    func refresh() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.refresh() }
            return
        }
        // Never shells out from the suite, the same rule and for the same
        // reason as `EngineLauncher.prewarm`: `/usage` is a real request
        // against the account's real quota, and a suite that spawns it once
        // per App-view test both burns that quota and leaves children behind.
        // In `refresh()` rather than in one caller, so the property holds for
        // every caller — the manual-refresh button included.
        guard runnerForTesting != nil || NSClassFromString("XCTestCase") == nil else { return }
        guard !inFlight else { return }
        inFlight = true
        let runner = runnerForTesting
        queue.async { [weak self] in
            guard let self else { return }
            let output = runner?() ?? Self.runUsage()
            let parsed = ClaudeUsageLimits.parse(output)
            DispatchQueue.main.async {
                self.inFlight = false
                // A fetch that parsed nothing leaves the last good value in
                // place: stale beats blank.
                if parsed != .empty { self.latest = parsed }
                for observer in self.observers.values { observer() }
            }
        }
    }

    /// Only for the suite: the poller is app-wide, so an observer or a stub
    /// runner left behind by one test would otherwise be inherited by the
    /// next one.
    func resetForTesting() {
        observers.removeAll()
        runnerForTesting = nil
        latest = nil
        timer?.cancel()
        timer = nil
        inFlight = false
    }

    private static func runUsage() -> String {
        // Through `EngineLauncher`, not `/usr/bin/env`. A Finder-launched
        // bundle inherits `launchd`'s minimal `PATH`, which holds none of the
        // places `claude` installs to, so `env claude` exits 127, stdout is
        // empty and both account-global readouts sit on "—" forever. That is
        // the exact problem `EngineLauncher` exists to solve (see its header):
        // `resolveBinary` searches the login shell's own `PATH`.
        guard let claude = EngineLauncher.resolveBinary("claude") else { return "" }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: claude)
        process.arguments = ["-p", "/usage"]
        // Merged onto this process's own environment, not assigned over it.
        // `EngineLauncher.environment()` is an *overlay* everywhere else it is
        // used — the daemon applies it key by key onto what it inherited
        // (`session.rs`'s `command.env(key, value)`, no `env_clear`) — and it
        // carries only `PATH`/`TERM`/`COLORTERM`/`LANG`. Assigning it wholesale
        // would hand `claude` an environment with no `HOME`, `USER` or
        // `TMPDIR`, which is a second way to get an empty reading and no test
        // can see either.
        process.environment = ProcessInfo.processInfo.environment
            .merging(EngineLauncher.environment()) { _, overlay in overlay }
        let pipe = Pipe()
        process.standardOutput = pipe
        // Discarded rather than piped: nothing reads a stderr `Pipe`, and a
        // child that fills its 64K buffer would block forever writing to it.
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return ""
        }
        // Bounded, the same shape as `EngineLauncher.loginShellPath`: an
        // unbounded `readDataToEndOfFile` on a hung `claude` wedges this
        // serial queue for the life of the app with `inFlight` stuck true and
        // the child leaked, which is worse than one missed reading.
        let finished = DispatchSemaphore(value: 0)
        var data = Data()
        DispatchQueue.global(qos: .utility).async {
            data = pipe.fileHandleForReading.readDataToEndOfFile()
            finished.signal()
        }
        if finished.wait(timeout: .now() + Self.fetchTimeout) == .timedOut {
            process.terminate()
            return ""
        }
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
