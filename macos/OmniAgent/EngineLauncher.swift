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

    /// Every agent whose CLI is actually installed.
    static func availableAgents(resolve: (String) -> String? = resolveBinary) -> [Engine] {
        agentPreference.filter { resolve(binaryName(for: $0)) != nil }
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
    /// `conversationID` claims a specific Claude conversation for this
    /// terminal (see `ClaudeConversation`). Pass it only for a spawn that
    /// cannot already own one: `--session-id` naming a conversation that
    /// exists makes `claude` exit 1 with "Session ID … is already in use",
    /// which turns opening a terminal into a terminal that is instantly dead —
    /// strictly worse than a stock `claude`. Recovering from that needs the
    /// liveness-probed `--resume` → `--session-id` → stock ladder the Tauri
    /// build carries (`ClaudeIdentity::ladder`), which this app does not have
    /// yet, so it only claims identities it knows are free.
    ///
    /// `codex`/`shell`/`agy` have no conversation concept and are untouched.
    /// `copilot` takes the same flag as `claude`.
    static func command(
        for engine: Engine,
        conversationID: String? = nil,
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
            return [program, "--session-id", conversationID]
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
