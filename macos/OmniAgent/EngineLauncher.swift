import CryptoKit
import Foundation

/// Which Claude conversation an OmniAgent terminal owns.
///
/// The native port of `src-tauri/src/sessions.rs`'s `claude_conversation_uuid`
/// — and of the bug that produced it, which this app had reintroduced by
/// launching `claude` stock. Claude's own conversation picking is *directory
/// scoped*: several Claude terminals in one project folder end up talking
/// about the same conversation, so `/rename` inside one renames what every
/// other one is showing, and they all read the same. This app's whole shape
/// encourages several Claude terminals in one folder, so it is not an edge
/// case here — it is the normal case.
///
/// The fix is to stop letting "most recent in this directory" decide:
/// `--session-id <uuid>` hands Claude the conversation the pane owns.
///
/// **Derived, never stored.** A UUIDv5 (RFC 4122, SHA-1) of the OmniAgent
/// session id under a fixed namespace, so the same terminal always maps to
/// the same conversation, on any machine, with nothing new persisted. The
/// namespace is deliberately byte-identical to the Rust one: a pane opened in
/// either app has to land on the same conversation, and changing it would
/// orphan every conversation already written.
enum ClaudeConversation {
    /// `uuid5(NAMESPACE_URL, "https://omni-agent.ai/ade/claude-conversation")`
    /// = `9337750e-5a2b-59c8-82f3-650bc0f53cfa`, the same literal
    /// `CLAUDE_CONVERSATION_NAMESPACE` carries on the Rust side. Written out
    /// as bytes rather than parsed from a string so there is no optional to
    /// unwrap and no way for it to be silently wrong at runtime.
    static let namespace: [UInt8] = [
        0x93, 0x37, 0x75, 0x0E, 0x5A, 0x2B, 0x59, 0xC8,
        0x82, 0xF3, 0x65, 0x0B, 0xC0, 0xF5, 0x3C, 0xFA,
    ]

    /// The `<uuid>` for `claude --session-id` / `claude --resume`.
    static func uuid(forSessionID sessionID: String) -> String {
        uuid5(namespace: namespace, name: sessionID)
    }

    /// RFC 4122 name-based (SHA-1) UUID. Generic so the suite can rederive
    /// `namespace` itself from the URL it is documented as, rather than
    /// trusting the literal above because a comment says so.
    static func uuid5(namespace: [UInt8], name: String) -> String {
        var input = Data(namespace)
        input.append(contentsOf: Array(name.utf8))
        var digest = Array(Insecure.SHA1.hash(data: input).prefix(16))
        digest[6] = (digest[6] & 0x0F) | 0x50 // version 5
        digest[8] = (digest[8] & 0x3F) | 0x80 // RFC 4122 variant
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        let groups = [0..<8, 8..<12, 12..<16, 16..<20, 20..<32].map { range in
            String(hex[hex.index(hex.startIndex, offsetBy: range.lowerBound)
                    ..< hex.index(hex.startIndex, offsetBy: range.upperBound)])
        }
        return groups.joined(separator: "-")
    }
}

/// Which model a Claude terminal is running, and the aliases `/model` takes.
///
/// **Read, never tracked.** Claude Code writes every reply to
/// `~/.claude/projects/<slug(cwd)>/<conversation>.jsonl` with the model that
/// served it on the line, and the conversation is the one this pane already
/// hands `claude --session-id` — so the transcript *is* the answer and there
/// is nothing to keep in sync. A `/model` the user typed by hand shows up
/// here on its own, as does one typed before this app was ever launched.
///
/// The alternative — running `/model` in the PTY and scraping the reply — is
/// not available: with no argument it opens an interactive arrow-key picker,
/// which is not something a machine can read.
enum ClaudeModel {
    /// Claude Code's own directory encoding: every character outside
    /// `[A-Za-z0-9-]` becomes `-`. Confirmed against this machine's real
    /// `~/.claude/projects` — `/`, `.` and `_` all collapse to a dash, and all
    /// 36 directories there contain nothing else. The same encoding
    /// `crates/brain-ingest/src/import_detect.rs` decodes in the other
    /// direction; this only ever encodes, so its lossiness does not apply.
    static func projectSlug(for cwd: String) -> String {
        String(cwd.map { char in
            char.isASCII && (char.isLetter || char.isNumber || char == "-") ? char : "-"
        })
    }

    /// Where Claude Code keeps this pane's conversation.
    static func transcriptURL(sessionID: String, cwd: String, home: URL = homeDirectory) -> URL {
        home
            .appendingPathComponent(".claude")
            .appendingPathComponent("projects")
            .appendingPathComponent(projectSlug(for: cwd))
            .appendingPathComponent(ClaudeConversation.uuid(forSessionID: sessionID) + ".jsonl")
    }

    static var homeDirectory: URL { URL(fileURLWithPath: NSHomeDirectory()) }

    /// Every place this pane's transcript could be: the derived path first,
    /// then the same conversation filename under every other project
    /// directory.
    ///
    /// The derived path is only where the transcript *usually* is: Claude
    /// slugs the directory it was **launched** in, and a `cd elsewhere &&
    /// claude` — or a cwd recorded differently than the shell resolved it —
    /// files the conversation under another slug. The conversation id is ours
    /// either way, so every project directory is offered by the same name.
    static func transcriptCandidates(
        sessionID: String, cwd: String, home: URL = homeDirectory
    ) -> [URL] {
        let expected = transcriptURL(sessionID: sessionID, cwd: cwd, home: home)
        let name = expected.lastPathComponent
        let projects = home.appendingPathComponent(".claude").appendingPathComponent("projects")
        let dirs = (try? FileManager.default.contentsOfDirectory(
            at: projects, includingPropertiesForKeys: nil
        )) ?? []
        // `.standardizedFileURL`: directory enumeration can hand back a
        // `/private/var/…` a caller-built URL never carries (macOS resolves
        // `/var`, `/tmp` and `/etc` through their real path here but not in
        // `URL.appendingPathComponent`), which would otherwise make an
        // identical path fail `==` against `expected` or a caller's own copy.
        let others = dirs
            .map { $0.appendingPathComponent(name).standardizedFileURL }
            .filter { $0 != expected }
        return [expected] + others
    }

    /// The first candidate that exists on disk, or `nil` while nothing has
    /// been written yet.
    static func resolvedTranscriptURL(
        sessionID: String, cwd: String, home: URL = homeDirectory
    ) -> URL? {
        transcriptCandidates(sessionID: sessionID, cwd: cwd, home: home)
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// The model this pane is running, or `nil` while nothing on disk can say
    /// yet — a fresh terminal has no transcript. Walks every candidate rather
    /// than stopping at the first one that merely *exists*: a stale file with
    /// no reply on it yet says nothing either, and the next candidate might.
    /// ~40 stats on a background queue, and only while the badge still says
    /// `Loading…`.
    static func current(sessionID: String, cwd: String, home: URL = homeDirectory) -> String? {
        for candidate in transcriptCandidates(sessionID: sessionID, cwd: cwd, home: home) {
            if let model = lastModel(inTailOf: candidate) { return model }
        }
        return nil
    }

    /// Reads the **tail** rather than the file: a long conversation's
    /// transcript runs to tens of megabytes and the answer is always in the
    /// last few lines, so this must not be an amount of work that grows with
    /// how long the terminal has been open.
    static func lastModel(inTailOf url: URL, bytes: UInt64 = 64 * 1024) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return nil }
        guard (try? handle.seek(toOffset: end > bytes ? end - bytes : 0)) != nil,
              let data = try? handle.readToEnd()
        else { return nil }
        // A byte offset lands mid-character as often as not, which makes
        // strict UTF-8 decoding fail on the whole tail. Latin-1 cannot fail
        // and model ids are ASCII either way.
        let tail = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        return lastModel(inTail: tail)
    }

    /// The most recent statement of the model in a chunk of transcript,
    /// scanned as text rather than parsed: the tail starts mid-line, so most
    /// of it is not valid JSON.
    ///
    /// Two records can say it, and **recency decides between them**:
    ///
    /// - `"model":"claude-…"` — the model that actually served a reply.
    /// - `<local-command-stdout>Set model to …` — the confirmation a
    ///   hand-typed `/model` prints. This is the only record that exists
    ///   *between* the switch and the next reply — a local command makes no
    ///   API call — and it is exactly the record a declined picker never
    ///   writes, which is what keeps a refused switch off the badge.
    ///
    /// A transcript records what the user typed as well, so `"model":"…"` can
    /// be something somebody pasted — hence the walk backwards until a value
    /// that names Claude.
    static func lastModel(inTail tail: String) -> String? {
        let reply = lastReply(inTail: tail)
        let switched = lastSwitchConfirmation(inTail: tail)
        switch (reply, switched) {
        case let (reply?, switched?):
            return switched.at > reply.at ? switched.value : reply.value
        case let (reply?, nil): return reply.value
        case let (nil, switched?): return switched.value
        case (nil, nil): return nil
        }
    }

    private static func lastReply(inTail tail: String) -> (at: String.Index, value: String)? {
        var searchEnd = tail.endIndex
        while let key = tail.range(
            of: "\"model\":\"", options: .backwards, range: tail.startIndex..<searchEnd
        ) {
            searchEnd = key.lowerBound
            let rest = tail[key.upperBound...]
            guard let close = rest.firstIndex(of: "\"") else { continue }
            let value = String(rest[..<close])
            if value.contains("claude") { return (key.lowerBound, value) }
        }
        return nil
    }

    /// `<local-command-stdout>Set model to \u001b[1mFable 5\u001b[22m and
    /// saved as…` — anchored on the stdout marker so prose merely *mentioning*
    /// "Set model to" cannot move the badge. The name it carries is a display
    /// name ("Fable 5"), not an id; `label(for:)` passes those through.
    private static func lastSwitchConfirmation(
        inTail tail: String
    ) -> (at: String.Index, value: String)? {
        let marker = "<local-command-stdout>Set model to "
        guard let key = tail.range(of: marker, options: .backwards) else { return nil }
        let rest = tail[key.upperBound...]
        guard let close = rest.firstIndex(of: "\"") else { return nil }
        var value = String(rest[..<close])
        if let tag = value.range(of: "</local-command-stdout>") {
            value = String(value[..<tag.lowerBound])
        }
        // ANSI colour, in the JSON-escaped form it has on disk (`\u001b[1m`)
        // and raw, should the encoding ever change.
        value = value.replacingOccurrences(
            of: "(\\\\u001b|\u{1b})\\[[0-9;]*m", with: "", options: .regularExpression
        )
        // "…and saved as your default for new sessions", or any variant —
        // the name never contains " and ".
        if let cut = value.range(of: " and ") { value = String(value[..<cut.lowerBound]) }
        value = value.trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : (key.lowerBound, value)
    }

    /// What the badge prints: `claude-opus-4-8[1m]` → `Opus 4.8 · 1M`,
    /// `claude-haiku-4-5-20251001` → `Haiku 4.5`. Derived rather than looked
    /// up in a table, so a model released after this ships still reads as its
    /// own name instead of falling through to a blank.
    static func label(for model: String) -> String {
        // A switch confirmation's value is already a display name ("Fable 5",
        // "Opus 4.5"); only ids need unpacking.
        guard !model.contains(" ") else { return model }
        var id = model
        var suffix = ""
        if id.hasSuffix("[1m]") {
            id = String(id.dropLast(4))
            suffix = " · 1M"
        }
        // Bedrock and Vertex prefix their ids (`us.anthropic.claude-…`).
        if let claude = id.range(of: "claude-") { id = String(id[claude.upperBound...]) }
        var parts = id.split(separator: "-").map(String.init)
        // A trailing release date says which snapshot, not which model.
        if let last = parts.last, last.count == 8, last.allSatisfy(\.isNumber) {
            parts.removeLast()
        }
        guard let family = parts.first, !family.isEmpty else { return model }
        let name = family.prefix(1).uppercased() + family.dropFirst()
        let version = parts.dropFirst().joined(separator: ".")
        return (version.isEmpty ? name : "\(name) \(version)") + suffix
    }
}


/// One row of a model menu: the id the engine takes, and what a person reads.
struct ModelChoice: Equatable {
    let id: String
    let label: String

    init(id: String, label: String? = nil) {
        self.id = id
        self.label = label ?? id
    }
}

/// Which model an engine is running, and which ones it will accept.
///
/// The four engines answer those two questions in four different places, and
/// two of them do not answer one of them at all — so this is a dispatch table
/// with the gaps left visible, rather than a uniform pretence that they are
/// the same kind of tool:
///
/// | engine | what it is running | what it accepts |
/// | --- | --- | --- |
/// | Claude | its own transcript, exactly, per pane | five aliases — `/model` alone opens an interactive picker |
/// | Codex | `~/.codex/config.toml`'s `model`, machine-wide | the models that file records having been offered |
/// | Copilot | `auto`, unless this app set otherwise | nothing readable without opening its live SQLite database |
/// | AntiGravity | nothing on disk at all | `agy models`, over the network |
///
/// Only Claude's answer is exact per pane, because only Claude is handed a
/// conversation id this app chose. For the rest, a model the user picked *in
/// this pane's menu* is the better answer than anything on disk — it is the
/// one thing known to be about this terminal — so it wins where it exists.
///
/// Everything here reads the filesystem or spawns a process. **Call it from a
/// background queue.**
enum EngineModel {
    /// What this pane is running, or `nil` when nothing can say yet.
    /// `picked` is the choice made in this pane's own menu, which outranks a
    /// machine-wide config for every engine whose disk answer is not per-pane.
    static func current(
        engine: Engine, sessionID: String, cwd: String, picked: String?
    ) -> String? {
        switch engine {
        // The transcript is per-pane and follows a `/model` typed by hand,
        // which a remembered pick cannot — so here the disk is the whole
        // answer. Deliberately no `?? picked` fallback: a pick Claude has not
        // acted on is exactly the one that can turn out to be false, and a
        // pane that has answered nothing has no model to report.
        case .claude: return ClaudeModel.current(sessionID: sessionID, cwd: cwd)
        case .codex: return picked ?? codexConfiguredModel()
        // Copilot's default is `auto` and its real answer lives in a live
        // WAL-mode SQLite database this app is not going to open for a badge.
        case .copilot: return picked ?? "auto"
        case .antigravity: return picked
        case .shell: return nil
        }
    }

    /// Whether a model picked in the menu is *the answer* for this engine, or
    /// only a request it may refuse.
    ///
    /// Claude names the model that actually served each reply in its
    /// transcript, and `/model` can be turned down — the switch asks the user
    /// to confirm, and Escape leaves the terminal on the model it was already
    /// running. A badge that moved on the pick would then be claiming
    /// something the terminal is not doing, and nothing would correct it until
    /// the next reply landed. So for Claude the pick is a request and the
    /// transcript is the answer.
    ///
    /// No other engine has a source that can disagree, so there the pick is
    /// the only answer there is.
    static func pickIsAuthoritative(for engine: Engine) -> Bool { engine != .claude }

    /// What to type at the terminal to switch, or `nil` for an engine with no
    /// in-session switch.
    static func switchCommand(engine: Engine, model: String) -> String? {
        switch engine {
        case .claude, .codex, .copilot, .antigravity: return "/model \(model)"
        case .shell: return nil
        }
    }

    /// What the badge prints. Only Claude's ids need unpacking — the rest
    /// already read as names (`gpt-5.6-sol`, `auto`).
    static func label(for model: String, engine: Engine) -> String {
        switch engine {
        case .claude: return ClaudeModel.label(for: model)
        case .copilot where model == "auto": return "Auto"
        default: return model
        }
    }

    // MARK: - Codex

    /// The top-level `model = "…"` in `~/.codex/config.toml`. Stops at the
    /// first section header, so a `[projects."…"]` block's own settings — or
    /// `[tui.model_availability_nux]` below it — cannot be mistaken for the
    /// one in force.
    static func codexConfiguredModel(home: URL = ClaudeModel.homeDirectory) -> String? {
        guard let text = try? String(
            contentsOf: home.appendingPathComponent(".codex/config.toml"), encoding: .utf8
        ) else { return nil }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") { return nil }
            guard trimmed.hasPrefix("model") else { continue }
            let rest = trimmed.dropFirst("model".count).trimmingCharacters(in: .whitespaces)
            guard rest.hasPrefix("=") else { continue }  // `model_reasoning_effort`
            return quoted(rest.dropFirst())
        }
        return nil
    }

    /// The models Codex's own config records having offered — its
    /// `[tui.model_availability_nux]` keys. Not a list Codex publishes, but a
    /// real one it wrote, which beats a list invented here.
    static func codexKnownModels(home: URL = ClaudeModel.homeDirectory) -> [ModelChoice] {
        guard let text = try? String(
            contentsOf: home.appendingPathComponent(".codex/config.toml"), encoding: .utf8
        ) else { return [] }
        var models: [String] = []
        var inSection = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                inSection = trimmed == "[tui.model_availability_nux]"
                continue
            }
            guard inSection, let key = quoted(trimmed), !models.contains(key) else { continue }
            models.append(key)
        }
        if let configured = codexConfiguredModel(home: home), !models.contains(configured) {
            models.insert(configured, at: 0)
        }
        return models.map { ModelChoice(id: $0) }
    }

    /// The contents of the first `"…"` in a fragment, or nil.
    private static func quoted(_ fragment: some StringProtocol) -> String? {
        guard let open = fragment.firstIndex(of: "\"") else { return nil }
        let rest = fragment[fragment.index(after: open)...]
        guard let close = rest.firstIndex(of: "\"") else { return nil }
        let value = String(rest[..<close])
        return value.isEmpty ? nil : value
    }

    // MARK: - AntiGravity

    /// `agy models`, which prints `id<TAB>Display Name` per line — and makes a
    /// network call to do it ("Fetching available models…"), which is the
    /// whole reason the menu has a loading state and a cache.
    static func fetchAntigravityModels(
        resolve: (String) -> String? = EngineLauncher.resolveBinary
    ) -> [ModelChoice] {
        guard let binary = resolve("agy"),
              let output = run(binary, ["models"], timeout: 20)
        else { return [] }
        return output.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t", maxSplits: 1)
            guard let id = fields.first?.trimmingCharacters(in: .whitespaces), !id.isEmpty,
                  !id.contains(" ")  // the "Fetching available models..." banner
            else { return nil }
            let label = fields.count > 1
                ? fields[1].trimmingCharacters(in: .whitespaces) : id
            return ModelChoice(id: id, label: label)
        }
    }

    /// Runs a binary and returns its stdout, or `nil` on failure or timeout.
    /// The timeout is the point: this exists to run a command that goes to the
    /// network, and a hung fetch must not hold a thread forever.
    private static func run(_ path: String, _ arguments: [String], timeout: Int) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let finished = DispatchSemaphore(value: 0)
        var data = Data()
        DispatchQueue.global(qos: .utility).async {
            data = stdout.fileHandleForReading.readDataToEndOfFile()
            finished.signal()
        }
        if finished.wait(timeout: .now() + .seconds(timeout)) == .timedOut {
            process.terminate()
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// The model menu's contents, and the caches behind the engines that have to
/// be asked for them.
///
/// Claude and Copilot answer from a list in this file, because neither
/// publishes anything to enumerate — `/model` alone opens an interactive
/// picker, and Copilot's list lives in a live SQLite database. The other two
/// have to be asked, so their menus open saying so and fill themselves in:
///
/// - **Codex** — its config records the models it has offered. A file read,
///   memoised for the run: fast, but not free, and not on the main thread.
/// - **AntiGravity** — `agy models` is a *network* round trip, so its answer
///   is written to `UserDefaults` with the day it was taken and served from
///   there until tomorrow.
enum EngineModelList {
    static let refreshInterval: TimeInterval = 24 * 60 * 60

    /// The aliases `/model` takes in Claude Code. A fixed list because there
    /// is nothing to enumerate, and one that changes about twice a year.
    /// Nothing *displayed* comes from here — the badge reads the transcript —
    /// so a stale entry costs a menu row, never a wrong label.
    static let claudeAliases = ["default", "opus", "sonnet", "haiku", "fable"]

    /// What to show right now, or `nil` when this engine has to be asked
    /// first — the state the menu draws as "Loading models…".
    static func cached(for engine: Engine, defaults: UserDefaults = .standard) -> [ModelChoice]? {
        switch engine {
        case .claude: return claudeAliases.map { ModelChoice(id: $0, label: $0.capitalized) }
        // Copilot's list lives in a table this app does not open, so the menu
        // offers the one value its CLI documents: let Copilot choose.
        case .copilot: return [ModelChoice(id: "auto", label: "Auto")]
        case .codex: return memo(for: .codex)
        case .antigravity: return memo(for: .antigravity) ?? fresh(defaults: defaults)
        case .shell: return []
        }
    }

    /// **Blocking — reads files and spawns processes. Background only.**
    /// A failed fetch is never stored: better to ask again next time than to
    /// cache emptiness for a day and call it the answer.
    static func fetch(for engine: Engine, defaults: UserDefaults = .standard) -> [ModelChoice] {
        if let cached = cached(for: engine, defaults: defaults) { return cached }
        let models: [ModelChoice]
        switch engine {
        case .codex: models = EngineModel.codexKnownModels()
        case .antigravity: models = EngineModel.fetchAntigravityModels()
        default: return []
        }
        guard !models.isEmpty else { return [] }
        setMemo(models, for: engine)
        if engine == .antigravity {
            defaults.set(models.map { [$0.id, $0.label] }, forKey: listKey)
            defaults.set(Date().timeIntervalSince1970, forKey: stampKey)
        }
        return models
    }

    /// Whether `current` is the model this row offers. The two are not always
    /// the same vocabulary — Claude's menu offers `opus` while its transcript
    /// answers `claude-opus-5` — so that one pair matches by containment and
    /// every other engine, which round-trips its own ids, matches exactly.
    static func choice(_ choice: ModelChoice, isCurrent current: String?, engine: Engine) -> Bool {
        guard let current else { return false }
        guard engine == .claude else { return choice.id == current }
        // `default` names a preference, not a model; the transcript only ever
        // records what it resolved to, so that row never ticks. Lowercased
        // because the transcript answers two vocabularies — `claude-fable-5`
        // after a reply, `Fable 5` straight after a hand-typed switch — and
        // the alias must tick against both.
        return choice.id != "default" && current.lowercased().contains(choice.id)
    }

    // MARK: - Caches

    private static let listKey = "omniagent.models.antigravity"
    private static let stampKey = "omniagent.models.antigravity.fetchedAt"
    private static let lock = NSLock()
    private static var memos: [Engine: [ModelChoice]] = [:]

    static func memo(for engine: Engine) -> [ModelChoice]? {
        lock.lock()
        defer { lock.unlock() }
        return memos[engine]
    }

    private static func setMemo(_ models: [ModelChoice], for engine: Engine) {
        lock.lock()
        memos[engine] = models
        lock.unlock()
    }

    /// Only for the suite: a memo that outlived its test would make the next
    /// one pass on yesterday's answer.
    static func resetMemos() {
        lock.lock()
        memos.removeAll()
        lock.unlock()
    }

    private static func fresh(defaults: UserDefaults) -> [ModelChoice]? {
        let stamp = defaults.double(forKey: stampKey)
        guard stamp > 0, Date().timeIntervalSince1970 - stamp < refreshInterval,
              let rows = defaults.array(forKey: listKey) as? [[String]], !rows.isEmpty
        else { return nil }
        return rows.compactMap { row in
            guard let id = row.first else { return nil }
            return ModelChoice(id: id, label: row.count > 1 ? row[1] : id)
        }
    }
}

/// Turns an `Engine` into something the PTY daemon can exec.
///
/// The daemon has always accepted an arbitrary argv, cwd and environment
/// (`CreateSession` in `crates/omniagent-pty-daemon/src/session.rs`); what the
/// native app was missing is the half that *builds* them, which until now only
/// existed in `src-tauri/src/sessions.rs`'s `build_engine_argv`. This is the
/// port of that, minus the pieces that need a bundled helper — see
/// `mcpConfigNote` below.
///
/// The `PATH` problem is the reason this file exists at all: a GUI app
/// inherits `launchd`'s minimal `PATH`, not the shell's, so `claude`, `codex`
/// and `agy` — which live in `~/.local/bin`, `/opt/homebrew/bin` and friends —
/// are invisible to it. Every lookup here goes through the login shell's own
/// `PATH`, resolved once and cached.
enum EngineLauncher {
    // MARK: - Engines

    /// Which engines are agents, in the order a fresh terminal should prefer
    /// them. `shell` is not in here — it is the fallback, not a choice.
    static let agentPreference: [Engine] = [.claude, .codex, .antigravity, .copilot]

    /// Every engine a terminal may be switched to, in the order the engine
    /// menu lists them — the agents first, the plain shell last. This is the
    /// one list that menu is built from, so an engine added here appears
    /// there without touching the UI.
    static let selectable: [Engine] = agentPreference + [.shell]

    /// The binary each engine runs. AntiGravity's CLI is `agy`, not its own
    /// name — the one case where the mapping is not the identity.
    static func binaryName(for engine: Engine) -> String {
        switch engine {
        case .claude: return "claude"
        case .codex: return "codex"
        case .copilot: return "copilot"
        case .antigravity: return "agy"
        case .shell: return shellBinaryName
        }
    }

    private static var shellBinaryName: String {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        return (shell as NSString).lastPathComponent
    }

    // MARK: - Availability

    /// Whether this engine's CLI is on the `PATH`. The engine menu greys the
    /// ones that are not rather than hiding them: "Codex — not installed" is
    /// a fact worth reading, a silently missing row is not.
    static func isInstalled(_ engine: Engine, resolve: (String) -> String? = resolveBinary) -> Bool {
        resolve(binaryName(for: engine)) != nil
    }

    /// Every agent whose CLI is actually installed.
    static func availableAgents(resolve: (String) -> String? = resolveBinary) -> [Engine] {
        agentPreference.filter { isInstalled($0, resolve: resolve) }
    }

    /// What a new terminal should run: the first installed agent, or a plain
    /// shell when the machine has none. A terminal that silently opens a shell
    /// when the user expected an agent is worse than one that says which agent
    /// it picked, which is why the pane label records the engine either way.
    static func defaultEngine(resolve: (String) -> String? = resolveBinary) -> Engine {
        availableAgents(resolve: resolve).first ?? .shell
    }

    // MARK: - Command

    /// The argv for one engine, or `nil` when its binary is not installed.
    ///
    /// Deliberately *not* ported from the Tauri builder: Claude's
    /// `--mcp-config` and `--append-system-prompt` pre-briefing, and Codex's
    /// `--config mcp_servers.omniagent=…`. Both need the `omniagent-mcp`
    /// helper, which the Tauri bundle ships and this app's bundle does not
    /// (`Contents/Resources` holds only the icon, assets and SwiftTerm). Adding
    /// the flag without the binary would make every agent fail to start, so the
    /// agents launch stock here until the helper is bundled.
    /// `conversationID` names the Claude conversation this terminal owns (see
    /// `ClaudeConversation`), and `resuming` picks which flag carries it:
    ///
    /// - `--session-id <U>` (`resuming: false`) — a *fresh* pane claiming an
    ///   id nothing has written under yet. Naming one that already exists
    ///   makes `claude` exit 1 with "Session ID … is already in use", so this
    ///   is only for ids the caller knows are free.
    /// - `--resume <U>` (`resuming: true`) — a pane whose daemon session is
    ///   gone (the PTY daemon was killed, the app reopened) reopening *its
    ///   own* conversation rather than starting a blank one. Naming a
    ///   conversation that does not exist exits 1 after ~1.25 s, which the
    ///   caller catches and respawns stock — see
    ///   `WorkspaceWindowController.createSession`.
    ///
    /// `codex`/`shell`/`agy` have no conversation concept and are untouched.
    /// `copilot` takes the same flag as `claude`.
    static func command(
        for engine: Engine,
        conversationID: String? = nil,
        resuming: Bool = false,
        resolve: (String) -> String? = resolveBinary
    ) -> [String]? {
        guard let program = resolve(binaryName(for: engine)) else { return nil }
        switch engine {
        case .shell:
            // Login shell, so the user's own rc files and PATH apply inside the
            // terminal exactly as they would in Terminal.app.
            return [program, "-l"]
        case .claude, .copilot:
            guard let conversationID else { return [program] }
            return [program, resuming ? "--resume" : "--session-id", conversationID]
        case .codex, .antigravity:
            return [program]
        }
    }

    /// The environment every session gets. `TERM`/`COLORTERM` are what make
    /// SwiftTerm render colour, and `PATH` is what lets the agent shell out to
    /// its own tooling once it is running.
    static func environment(path: String? = nil) -> [String: String] {
        var environment = [
            "TERM": "xterm-256color",
            "COLORTERM": "truecolor",
            "PATH": path ?? searchPath,
        ]
        // A CLI that prints a box-drawing UI garbles without a UTF-8 locale,
        // and a GUI-launched process often has none set at all.
        let current = ProcessInfo.processInfo.environment
        let hasUTF8 = [current["LC_ALL"], current["LC_CTYPE"], current["LANG"]]
            .compactMap { $0 }
            .contains { $0.uppercased().contains("UTF-8") }
        if !hasUTF8 { environment["LANG"] = "en_US.UTF-8" }
        return environment
    }

    // MARK: - PATH

    /// The login shell's `PATH`, resolved once. Falls back to the usual
    /// install locations rather than to `launchd`'s `PATH`, which contains
    /// none of them.
    private static let fallbackPath: String = {
        let home = NSHomeDirectory()
        return [
            "\(home)/.local/bin",
            "\(home)/.bun/bin",
            "\(home)/.cargo/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
        ].joined(separator: ":")
    }()

    private static let lock = NSLock()
    private static var cachedPath: String?
    private static var prewarmStarted = false

    /// Resolved off the main thread by `prewarm()`; reading it before that
    /// finishes just uses the fallback, which is correct for the standard
    /// install locations and only misses an unusual one.
    static var searchPath: String {
        lock.lock()
        defer { lock.unlock() }
        return cachedPath ?? fallbackPath
    }

    /// Asks the login shell for its `PATH`. Off the main thread, and **once
    /// per process** — a login shell sources the user's whole rc chain (nvm,
    /// rbenv, the lot), so this is expensive, and it is per-machine state, not
    /// per-window. Calling it per window controller spawned one shell per
    /// window, which was enough to take the test runner down.
    static func prewarm(_ completion: (() -> Void)? = nil) {
        // Never under XCTest. The suite builds a window controller per test,
        // and an interactive login shell in a process with no controlling
        // terminal is exactly the kind of thing that hangs a test runner. The
        // fallback path resolves every standard install location anyway.
        guard NSClassFromString("XCTestCase") == nil else {
            completion?()
            return
        }
        lock.lock()
        let alreadyStarted = prewarmStarted
        prewarmStarted = true
        lock.unlock()
        guard !alreadyStarted else {
            completion?()
            return
        }
        DispatchQueue.global(qos: .utility).async {
            let resolved = loginShellPath()
            lock.lock()
            cachedPath = resolved ?? fallbackPath
            lock.unlock()
            completion?()
        }
    }

    /// `$SHELL -ilc 'printf %s "$PATH"'`. Interactive **and** login, because
    /// the tools people install with `curl | sh` tend to append to `.zshrc`
    /// rather than `.zprofile`.
    static func loginShellPath() -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-ilc", "printf %s \"$PATH\""]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        // A shell that never returns must not strand this thread: `-i` sources
        // the user's whole rc chain, and anything in there that waits on input
        // would hang forever without a controlling terminal.
        let finished = DispatchSemaphore(value: 0)
        var data = Data()
        DispatchQueue.global(qos: .utility).async {
            data = stdout.fileHandleForReading.readDataToEndOfFile()
            finished.signal()
        }
        if finished.wait(timeout: .now() + 5) == .timedOut {
            process.terminate()
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty
        else { return nil }
        return text
    }

    /// An absolute path for `name`, searching the login shell's `PATH`. An
    /// absolute name is taken as-is so a user-configured `$SHELL` works.
    static func resolveBinary(_ name: String) -> String? {
        if name.hasPrefix("/") {
            return FileManager.default.isExecutableFile(atPath: name) ? name : nil
        }
        for directory in searchPath.split(separator: ":") where !directory.isEmpty {
            let candidate = (String(directory) as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }
}

/// Whether an engine can be picked right now, and why not (2026-09-01 remote
/// environment sharing spec §4, Task 26).
///
/// While `isDrivingRemote`, "installed" means installed on the **host** —
/// this machine's own `PATH` answers for the wrong computer, so an engine the
/// host does not have must show as unavailable even when it sits right here
/// on this Mac's disk. Every engine picker (`HomeView.presentEngineMenu`,
/// `WorkspaceWindowController.engineMenu(for:)`) builds one of these instead
/// of calling `EngineLauncher.isInstalled` directly.
struct EnginePickerModel {
    /// The window's own reading of the host, or `nil` before the first
    /// `HostState` has landed. `isAvailable`/`unavailableReason` fall back to
    /// the local answer whenever this is `nil`, the same "stale beats blank"
    /// rule the rest of `HostStateModel` follows — a picker must never grey
    /// out every engine for the one tick before the first push arrives.
    let hostState: HostStateModel?
    let isDrivingRemote: Bool
    /// Seam for tests — `EngineLauncher.isInstalled` in production.
    var localAvailability: (Engine) -> Bool = { EngineLauncher.isInstalled($0) }

    /// Whether `engine` can be picked right now.
    ///
    /// An engine the host has never reported at all — `.shell`/`.copilot`,
    /// which `HostStatePublisher.Engines` does not carry — has no host
    /// reading to contradict the local one, so this falls back to it rather
    /// than blocking an engine the host was simply never asked about.
    func isAvailable(_ engine: Engine) -> Bool {
        guard isDrivingRemote,
              let available = hostState?.engineAvailability[engine.rawValue]
        else { return localAvailability(engine) }
        return available
    }

    /// Why `engine` is greyed out, or `nil` when it is not. Names the host
    /// only while this is actually reading the host's own "not available"
    /// answer; the local fallback (an engine the host never mentioned, or
    /// not driving at all) gets the plain local wording instead, since there
    /// is no other machine to name.
    func unavailableReason(_ engine: Engine) -> String? {
        guard !isAvailable(engine) else { return nil }
        if isDrivingRemote,
           hostState?.engineAvailability[engine.rawValue] == false,
           let name = hostState?.host?.name {
            return "Not installed on \(name)"
        }
        return "\(engine.badgeTitle) is not installed"
    }
}
