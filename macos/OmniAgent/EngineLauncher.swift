import Foundation

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
    static func command(for engine: Engine, resolve: (String) -> String? = resolveBinary) -> [String]? {
        guard let program = resolve(binaryName(for: engine)) else { return nil }
        switch engine {
        case .shell:
            // Login shell, so the user's own rc files and PATH apply inside the
            // terminal exactly as they would in Terminal.app.
            return [program, "-l"]
        case .claude, .codex, .copilot, .antigravity:
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
