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
}
