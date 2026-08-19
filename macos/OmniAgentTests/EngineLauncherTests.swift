import XCTest
import AppKit

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

/// Switching the engine a terminal runs: the badge that opens the menu, the
/// menu itself, and the confirmation that stands between a live conversation
/// and losing it.
final class EngineSwitchTests: XCTestCase {
    /// The list the menu is built from. Every engine is reachable — a menu
    /// that quietly omitted one would be a dead end for whoever added it.
    func testEveryEngineIsSelectableWithTheShellLast() {
        XCTAssertEqual(Set(EngineLauncher.selectable), Set(Engine.allCases))
        XCTAssertEqual(EngineLauncher.selectable.last, .shell)
        XCTAssertEqual(EngineLauncher.selectable.count, Engine.allCases.count, "no duplicates")
    }

    func testIsInstalledReadsThePathThroughTheInjectedResolver() {
        let resolve: (String) -> String? = { $0 == "claude" ? "/bin/claude" : nil }
        XCTAssertTrue(EngineLauncher.isInstalled(.claude, resolve: resolve))
        XCTAssertFalse(EngineLauncher.isInstalled(.codex, resolve: resolve))
    }

    /// The badge is only a button in front of a terminal, and only then does
    /// it grow the chevron that says so.
    func testOnlyATerminalsEngineBadgeOpensTheMenu() {
        let badge = PaneBadgeView()
        badge.configure(
            icon: nil,
            text: "Claude Code",
            foreground: .white,
            fill: .clear,
            stroke: .clear,
            font: ShellFont.ui(12, .semibold)
        )
        let plain = badge.intrinsicContentSize.width
        var opened = false
        badge.onClick = { opened = true }
        XCTAssertGreaterThan(badge.intrinsicContentSize.width, plain, "the chevron takes room")
        XCTAssertTrue(badge.accessibilityPerformPress())
        XCTAssertTrue(opened)
    }

    func testTheMenuTicksTheRunningEngineAndRefusesToReselectIt() throws {
        let controller = makeController()
        defer { controller.close() }
        controller.showWindow(nil)
        let paneID = try XCTUnwrap(controller.workspaceView.paneIDs.first)
        controller.workspaceView.updateDescriptor(for: paneID) { $0.engine = .claude }

        let menu = controller.engineMenu(for: paneID)
        XCTAssertEqual(menu.items.count, EngineLauncher.selectable.count)
        let claude = try XCTUnwrap(menu.items.first { $0.title.hasPrefix("Claude Code") })
        XCTAssertEqual(claude.state, .on)
        XCTAssertFalse(claude.isEnabled, "the engine already running is not a choice")
        XCTAssertTrue(menu.items.filter { $0.state == .on }.count == 1)
    }

    /// Nothing typed, nothing to lose — the swap happens on the spot.
    func testAnUntypedTerminalSwitchesEngineWithoutAsking() throws {
        let controller = makeController()
        defer { controller.close() }
        controller.showWindow(nil)
        controller.sessionKiller = { _ in }
        controller.sessionEnsurer = { _ in }
        let workspace = controller.workspaceView
        let paneID = try XCTUnwrap(workspace.paneIDs.first)
        workspace.updateDescriptor(for: paneID) { $0.engine = .claude }

        controller.requestEngineSwitch(paneID, to: .shell)

        XCTAssertNil(workspace.descriptor(for: paneID), "the old pane and its conversation are gone")
        let replacement = try XCTUnwrap(workspace.paneIDs.first)
        XCTAssertNotEqual(replacement, paneID, "a new conversation needs a new session id")
        XCTAssertEqual(workspace.descriptor(for: replacement)?.engine, .shell)
        XCTAssertEqual(workspace.paneIDs.count, 1)
    }

    /// Typed in, so it asks — and changes nothing until the card is answered.
    func testATypedTerminalAsksBeforeItsConversationIsThrownAway() throws {
        let controller = makeController()
        defer { controller.close() }
        controller.showWindow(nil)
        controller.sessionKiller = { _ in }
        controller.sessionEnsurer = { _ in }
        let workspace = controller.workspaceView
        let paneID = try XCTUnwrap(workspace.paneIDs.first)
        workspace.updateDescriptor(for: paneID) { $0.engine = .claude }
        let surface = try XCTUnwrap(workspace.terminalSurface(for: paneID))
        surface.send(source: surface.terminalView, data: ArraySlice([UInt8(0x68)]))

        controller.requestEngineSwitch(paneID, to: .shell)

        let container = try XCTUnwrap(workspace.container(for: paneID))
        let card = try XCTUnwrap(container.askOverlay)
        XCTAssertEqual(workspace.descriptor(for: paneID)?.engine, .claude, "nothing has happened yet")
        // Stay, then the switch — and the card is asking about the engine it
        // is offering, not warning about the one being left.
        XCTAssertEqual(card.options.map(\.title), ["Stay", "Switch to Shell"])
        XCTAssertEqual(card.icon, Engine.shell.iconImage)

        // Cancel leaves the terminal exactly as it was.
        card.onCancel?()
        XCTAssertNil(container.askOverlay)
        XCTAssertEqual(workspace.descriptor(for: paneID)?.engine, .claude)

        // Confirm is the only path that swaps it.
        controller.requestEngineSwitch(paneID, to: .shell)
        try XCTUnwrap(container.askOverlay).options.last?.action()
        XCTAssertNil(workspace.descriptor(for: paneID))
        XCTAssertEqual(workspace.descriptor(for: workspace.paneIDs[0])?.engine, .shell)
    }

    /// The replacement lands in the cell the old pane held. A swap that seated
    /// the new terminal at the end of the grid would move every pane after it
    /// for no reason the user asked for.
    func testTheReplacementKeepsThePanesPlaceInTheGrid() throws {
        let controller = makeController()
        defer { controller.close() }
        controller.showWindow(nil)
        controller.sessionKiller = { _ in }
        controller.sessionEnsurer = { _ in }
        let workspace = controller.workspaceView
        controller.newTerminalPane(nil)
        controller.newTerminalPane(nil)
        let before = workspace.paneIDs
        XCTAssertEqual(before.count, 3)
        let target = before[1]

        XCTAssertTrue(controller.replaceEngine(target, with: .shell))

        let after = workspace.paneIDs
        XCTAssertEqual(after.count, 3)
        XCTAssertEqual(after[0], before[0])
        XCTAssertEqual(after[2], before[2])
        XCTAssertNotEqual(after[1], target)
        XCTAssertEqual(workspace.descriptor(for: after[1])?.engine, .shell)
    }

    private func makeController() -> WorkspaceWindowController {
        WorkspaceWindowController(
            connection: SessionConnection(
                socketURL: URL(fileURLWithPath: "/tmp/omniagent-engine-switch-test.sock")
            ),
            sessionID: "native-terminal"
        )
    }
}
