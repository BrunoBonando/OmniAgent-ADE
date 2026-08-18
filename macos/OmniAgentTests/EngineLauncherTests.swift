import XCTest

@testable import OmniAgent

/// What a terminal runs, and where it looks for it. Every test injects its own
/// resolver so nothing here depends on which agents the machine happens to
/// have installed.
final class EngineLauncherTests: XCTestCase {
    /// Resolves exactly the named binaries, to an absolute path.
    private func resolver(_ installed: Set<String>) -> (String) -> String? {
        { name in installed.contains(name) ? "/usr/local/bin/\(name)" : nil }
    }

    // MARK: - Binaries

    /// AntiGravity's CLI is `agy`; every other engine's binary is its own name.
    /// Getting this wrong means the engine silently reports "not installed".
    func testAntigravityRunsAgy() {
        XCTAssertEqual(EngineLauncher.binaryName(for: .antigravity), "agy")
        XCTAssertEqual(EngineLauncher.binaryName(for: .claude), "claude")
        XCTAssertEqual(EngineLauncher.binaryName(for: .codex), "codex")
        XCTAssertEqual(EngineLauncher.binaryName(for: .copilot), "copilot")
    }

    // MARK: - Availability

    func testAvailableAgentsKeepPreferenceOrder() {
        let agents = EngineLauncher.availableAgents(resolve: resolver(["agy", "claude"]))
        XCTAssertEqual(agents, [.claude, .antigravity])
    }

    func testAvailableAgentsNeverIncludesShell() {
        let agents = EngineLauncher.availableAgents(resolve: { _ in "/bin/zsh" })
        XCTAssertFalse(agents.contains(.shell))
    }

    /// A new terminal should come up on an agent, not a bare shell.
    func testDefaultEngineIsTheFirstInstalledAgent() {
        XCTAssertEqual(EngineLauncher.defaultEngine(resolve: resolver(["claude", "codex"])), .claude)
        XCTAssertEqual(EngineLauncher.defaultEngine(resolve: resolver(["codex"])), .codex)
        XCTAssertEqual(EngineLauncher.defaultEngine(resolve: resolver(["agy"])), .antigravity)
    }

    /// With no agent installed there is still a working terminal.
    func testDefaultEngineFallsBackToShell() {
        XCTAssertEqual(EngineLauncher.defaultEngine(resolve: { _ in nil }), .shell)
    }

    // MARK: - Command

    func testAgentCommandIsTheResolvedBinary() {
        let command = EngineLauncher.command(for: .claude, resolve: resolver(["claude"]))
        XCTAssertEqual(command, ["/usr/local/bin/claude"])
    }

    /// The shell is a *login* shell, so the user's rc files apply exactly as
    /// they would in Terminal.app.
    func testShellCommandIsALoginShell() {
        let command = EngineLauncher.command(for: .shell, resolve: { _ in "/bin/zsh" })
        XCTAssertEqual(command, ["/bin/zsh", "-l"])
    }

    /// An uninstalled engine must report nothing to run, so the caller can say
    /// so instead of quietly starting a shell under that engine's name.
    func testAnUninstalledEngineHasNoCommand() {
        XCTAssertNil(EngineLauncher.command(for: .codex, resolve: { _ in nil }))
    }

    // MARK: - Environment

    func testEnvironmentCarriesTerminalAndPath() {
        let environment = EngineLauncher.environment(path: "/opt/bin:/usr/bin")
        XCTAssertEqual(environment["TERM"], "xterm-256color")
        XCTAssertEqual(environment["COLORTERM"], "truecolor")
        XCTAssertEqual(environment["PATH"], "/opt/bin:/usr/bin")
    }

    /// A GUI-launched process often has no locale at all, and agents that draw
    /// box characters garble without one.
    func testEnvironmentGuaranteesAUTF8Locale() {
        let environment = EngineLauncher.environment(path: "/usr/bin")
        let locale = environment["LANG"] ?? ProcessInfo.processInfo.environment["LANG"] ?? ""
            + (ProcessInfo.processInfo.environment["LC_ALL"] ?? "")
            + (ProcessInfo.processInfo.environment["LC_CTYPE"] ?? "")
        XCTAssertTrue(locale.uppercased().contains("UTF-8"), "expected a UTF-8 locale, got \(locale)")
    }

    // MARK: - Resolution

    func testAnAbsolutePathResolvesOnlyWhenExecutable() {
        XCTAssertEqual(EngineLauncher.resolveBinary("/bin/zsh"), "/bin/zsh")
        XCTAssertNil(EngineLauncher.resolveBinary("/nonexistent/definitely/not/here"))
    }

    /// The search path must contain the places agents actually install to —
    /// none of which are on a GUI app's inherited PATH.
    func testSearchPathCoversTheUsualInstallLocations() {
        let path = EngineLauncher.searchPath
        for expected in ["/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"] {
            XCTAssertTrue(path.contains(expected), "expected \(expected) in \(path)")
        }
    }

    // MARK: - Claude conversation identity

    /// The namespace is not a magic constant: it is the UUIDv5 of a documented
    /// URL under the standard URL namespace, and it must stay byte-identical
    /// to `CLAUDE_CONVERSATION_NAMESPACE` in `src-tauri/src/sessions.rs`.
    /// Changing it orphans every conversation already written.
    func testTheNamespaceIsTheDocumentedDerivationNotAMagicConstant() {
        // RFC 4122's URL namespace, 6ba7b811-9dad-11d1-80b4-00c04fd430c8.
        let urlNamespace: [UInt8] = [
            0x6B, 0xA7, 0xB8, 0x11, 0x9D, 0xAD, 0x11, 0xD1,
            0x80, 0xB4, 0x00, 0xC0, 0x4F, 0xD4, 0x30, 0xC8,
        ]
        let derived = ClaudeConversation.uuid5(
            namespace: urlNamespace,
            name: "https://omni-agent.ai/ade/claude-conversation"
        )
        XCTAssertEqual(derived, "9337750e-5a2b-59c8-82f3-650bc0f53cfa")

        let literal = ClaudeConversation.namespace
            .map { String(format: "%02x", $0) }
            .joined()
        XCTAssertEqual(literal, derived.replacingOccurrences(of: "-", with: ""))
    }

    /// Cross-checked against an independent UUIDv5 implementation, so this
    /// pins the actual bytes rather than only agreeing with itself — the
    /// Rust side derives the same values for the same session ids, and a pane
    /// has to land on one conversation whichever app opened it.
    func testConversationUUIDsMatchAnIndependentImplementation() {
        XCTAssertEqual(
            ClaudeConversation.uuid(forSessionID: "sess-a"),
            "8a0239e0-70ec-5c0f-ac2b-d872ad014fc4"
        )
        XCTAssertEqual(
            ClaudeConversation.uuid(forSessionID: "DBF86AF7-5273-4449-B554-8675F0E35244"),
            "603d527c-29ae-507d-bcac-aa9a1358e137"
        )
    }

    func testConversationUUIDsAreStableAndDistinctPerTerminal() {
        let first = ClaudeConversation.uuid(forSessionID: "pane-1")
        XCTAssertEqual(first, ClaudeConversation.uuid(forSessionID: "pane-1"), "same terminal, same conversation")
        XCTAssertNotEqual(first, ClaudeConversation.uuid(forSessionID: "pane-2"))
        // Shape `claude --session-id` validates: 8-4-4-4-12 hex, version 5.
        XCTAssertEqual(first.count, 36)
        XCTAssertEqual(first.split(separator: "-").map(\.count), [8, 4, 4, 4, 12])
        XCTAssertTrue(first.split(separator: "-")[2].hasPrefix("5"), "version 5")
    }

    /// The bug this exists for: launched stock, several Claude terminals in
    /// one folder share whatever conversation Claude thinks is most recent, so
    /// `/rename` in one renames what the others show. `--session-id` is what
    /// makes a terminal own its own.
    func testClaudeIsHandedTheConversationTheTerminalOwns() {
        let resolve: (String) -> String? = { "/bin/\($0)" }
        XCTAssertEqual(
            EngineLauncher.command(for: .claude, conversationID: "abc", resolve: resolve),
            ["/bin/claude", "--session-id", "abc"]
        )
        XCTAssertEqual(
            EngineLauncher.command(for: .copilot, conversationID: "abc", resolve: resolve),
            ["/bin/copilot", "--session-id", "abc"],
            "copilot takes the same flag"
        )
        // No claim to make: stock, rather than a flag that would kill the spawn.
        XCTAssertEqual(EngineLauncher.command(for: .claude, resolve: resolve), ["/bin/claude"])
    }

    /// A restore whose daemon session is gone reopens its own conversation
    /// instead of starting blank — the `--resume` half of the ladder.
    func testResumingSwapsSessionIDForResume() {
        let resolve: (String) -> String? = { "/bin/" + $0 }
        XCTAssertEqual(
            EngineLauncher.command(for: .claude, conversationID: "abc", resuming: true, resolve: resolve),
            ["/bin/claude", "--resume", "abc"]
        )
        // The stock fallback carries neither flag.
        XCTAssertEqual(
            EngineLauncher.command(for: .claude, conversationID: nil, resuming: true, resolve: resolve),
            ["/bin/claude"]
        )
        // Engines with no conversation concept are untouched.
        XCTAssertEqual(
            EngineLauncher.command(for: .codex, conversationID: "abc", resolve: resolve),
            ["/bin/codex"]
        )
        XCTAssertEqual(
            EngineLauncher.command(for: .antigravity, conversationID: "abc", resolve: resolve),
            ["/bin/agy"]
        )
    }
}
