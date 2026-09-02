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

    // MARK: - Command (isDrivingRemote, Task 28's carried gap)

    /// While driving, argv[0] is the bare name — this Mac's own resolved
    /// path names a file on the wrong disk, and the daemon resolves the
    /// name against its own (the HOST's) instead.
    func testDrivingRemoteSendsTheBareNameNotAResolvedPath() {
        let command = EngineLauncher.command(
            for: .claude,
            isDrivingRemote: true,
            resolve: resolver(["claude"])
        )
        XCTAssertEqual(command, ["claude"])
    }

    /// `resolve` is this Mac's own `PATH` lookup — irrelevant to what the
    /// HOST has, so it is never even consulted while driving. Proven by
    /// handing it a resolver that always fails: a command still comes back.
    func testDrivingRemoteNeverConsultsThisMachinesOwnResolver() {
        var resolveCalls = 0
        let command = EngineLauncher.command(
            for: .codex,
            isDrivingRemote: true,
            resolve: { _ in
                resolveCalls += 1
                return nil
            }
        )
        XCTAssertEqual(command, ["codex"])
        XCTAssertEqual(resolveCalls, 0)
    }

    /// The conversation flags still land on the bare name exactly as they do
    /// on a resolved one — only *how* argv[0] was produced changes.
    func testDrivingRemoteStillCarriesTheConversationFlags() {
        XCTAssertEqual(
            EngineLauncher.command(
                for: .claude,
                conversationID: "abc",
                isDrivingRemote: true,
                resolve: { _ in nil }
            ),
            ["claude", "--session-id", "abc"]
        )
        XCTAssertEqual(
            EngineLauncher.command(
                for: .claude,
                conversationID: "abc",
                resuming: true,
                isDrivingRemote: true,
                resolve: { _ in nil }
            ),
            ["claude", "--resume", "abc"]
        )
    }

    /// The default (`isDrivingRemote: false`, every pre-existing call and
    /// test) is untouched: still a resolved path, still `nil` when this
    /// machine does not have the binary. The local case is proven and
    /// shipped; this is the regression guard that it stays that way.
    func testNotDrivingRemoteIsUnchanged() {
        XCTAssertEqual(EngineLauncher.command(for: .claude, resolve: resolver(["claude"])), ["/usr/local/bin/claude"])
        XCTAssertNil(EngineLauncher.command(for: .claude, isDrivingRemote: false, resolve: { _ in nil }))
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
        try XCTUnwrap(container.askOverlay).choose(1)
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

    // MARK: - ClaudeModel

    /// Every character outside `[A-Za-z0-9-]` collapses to a dash — `/`, `.`
    /// and `_` alike. Asserted against the exact encoding this machine's real
    /// `~/.claude/projects` uses, because a slug that is one character off
    /// finds no transcript and the badge silently never appears.
    func testProjectSlugCollapsesEverythingButLettersDigitsAndDashes() {
        XCTAssertEqual(
            ClaudeModel.projectSlug(for: "/Users/b/Documents/Bruno.Digital/OmniAgent-ADE"),
            "-Users-b-Documents-Bruno-Digital-OmniAgent-ADE"
        )
        XCTAssertEqual(
            ClaudeModel.projectSlug(for: "/Users/b/Documents/HomeBridge_UniFi"),
            "-Users-b-Documents-HomeBridge-UniFi"
        )
    }

    /// The badge's whole text. A release-date suffix is a snapshot, not a
    /// model; `[1m]` is a fact worth keeping.
    func testModelLabelReadsAsAName() {
        XCTAssertEqual(ClaudeModel.label(for: "claude-opus-5"), "Opus 5")
        XCTAssertEqual(ClaudeModel.label(for: "claude-haiku-4-5-20251001"), "Haiku 4.5")
        XCTAssertEqual(ClaudeModel.label(for: "claude-opus-4-8[1m]"), "Opus 4.8 · 1M")
        XCTAssertEqual(ClaudeModel.label(for: "claude-fable-5"), "Fable 5")
        // Bedrock/Vertex ids carry a vendor prefix.
        XCTAssertEqual(ClaudeModel.label(for: "us.anthropic.claude-sonnet-5"), "Sonnet 5")
        // Something this has never seen still reads as its own name.
        XCTAssertEqual(ClaudeModel.label(for: "claude-newthing-9-1"), "Newthing 9.1")
    }

    /// The last model *Claude* answered with — not the last `"model":"…"` in
    /// the file, which a user can put there by pasting JSON at the prompt.
    func testLastModelSkipsPastedTextAndTakesTheLatestReply() {
        let tail = """
        {"type":"assistant","message":{"model":"claude-sonnet-5"}}
        {"type":"assistant","message":{"model":"claude-opus-5"}}
        {"type":"user","message":{"content":"see this config: {\\"model\\":\\"gpt-4\\"}"}}
        """
        XCTAssertEqual(ClaudeModel.lastModel(inTail: tail), "claude-opus-5")
        XCTAssertNil(ClaudeModel.lastModel(inTail: "no model here"))
    }

    /// End to end against a real file at the real path, with a fake home: the
    /// path is derived from the pane's session id the same way the launcher
    /// derives `--session-id`, so a change to either has to keep them agreeing.
    func testCurrentModelReadsTheTailOfTheRealTranscriptPath() throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("omniagent-model-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let cwd = "/Users/b/Bruno.Digital/proj"
        let url = ClaudeModel.transcriptURL(sessionID: "pane-1", cwd: cwd, home: home)
        XCTAssertEqual(
            url.lastPathComponent,
            ClaudeConversation.uuid(forSessionID: "pane-1") + ".jsonl"
        )
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )

        // Nothing written yet: a fresh terminal has no model, and no badge is
        // better than a guess at the one it will pick.
        XCTAssertNil(ClaudeModel.current(sessionID: "pane-1", cwd: cwd, home: home))

        // Padded past the tail window, so this also proves the read is bounded
        // to the end of the file rather than scanning all of it.
        let filler = String(repeating: "{\"type\":\"user\",\"x\":\"y\"}\n", count: 8000)
        try (filler + "{\"message\":{\"model\":\"claude-opus-4-8[1m]\"}}\n")
            .write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(
            ClaudeModel.current(sessionID: "pane-1", cwd: cwd, home: home),
            "claude-opus-4-8[1m]"
        )
        XCTAssertNil(ClaudeModel.current(sessionID: "pane-2", cwd: cwd, home: home))
    }

    /// A hand-typed `/model` prints a confirmation and makes no API call, so
    /// between the switch and the next reply that line is the only record —
    /// and recency decides between it and the last reply. Prose merely
    /// mentioning "Set model to" is not a confirmation.
    func testAHandTypedSwitchMovesTheModelBeforeAnyReplyLands() {
        let switched = """
        {"message":{"model":"claude-opus-5"}}
        {"type":"user","message":{"content":"<local-command-stdout>Set model to \\u001b[1mFable 5\\u001b[22m and saved as your default for new sessions</local-command-stdout>"}}
        """
        XCTAssertEqual(ClaudeModel.lastModel(inTail: switched), "Fable 5")

        // The next reply is newer than the confirmation, and wins.
        let replied = switched + "\n{\"message\":{\"model\":\"claude-fable-5\"}}"
        XCTAssertEqual(ClaudeModel.lastModel(inTail: replied), "claude-fable-5")

        // Talk about the confirmation is not the confirmation.
        let prose = """
        {"message":{"model":"claude-opus-5"}}
        {"message":{"content":"the terminal prints Set model to X when you switch"}}
        """
        XCTAssertEqual(ClaudeModel.lastModel(inTail: prose), "claude-opus-5")

        // A display name passes through the label untouched, and ticks the
        // alias it names.
        XCTAssertEqual(ClaudeModel.label(for: "Fable 5"), "Fable 5")
        XCTAssertTrue(
            EngineModelList.choice(ModelChoice(id: "fable"), isCurrent: "Fable 5", engine: .claude)
        )
    }

    /// The transcript is filed under the directory Claude was *launched* in,
    /// which is not always the pane's cwd — `cd elsewhere && claude` files it
    /// under another slug. The conversation id is ours either way, so the
    /// search falls back to every project directory by name.
    func testDiscoveryFindsATranscriptFiledUnderAnotherProjectSlug() throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("omniagent-drift-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let paneCwd = "/Users/b/pane-cwd"
        // Filed where claude was launched, not where the pane lives.
        let actual = ClaudeModel.transcriptURL(sessionID: "p1", cwd: "/Users/b/elsewhere", home: home)
        try FileManager.default.createDirectory(
            at: actual.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try "{\"message\":{\"model\":\"claude-opus-5\"}}\n".write(
            to: actual, atomically: true, encoding: .utf8
        )
        XCTAssertEqual(
            ClaudeModel.current(sessionID: "p1", cwd: paneCwd, home: home), "claude-opus-5"
        )
        // A different conversation's file is never this pane's answer.
        XCTAssertNil(ClaudeModel.current(sessionID: "p2", cwd: paneCwd, home: home))
    }

    // MARK: - Every engine

    /// Claude's transcript outranks a remembered pick, because it is the only
    /// per-pane source that follows a `/model` typed by hand. Every other
    /// engine's disk answer is machine-wide, so the pick — the one fact known
    /// to be about *this* terminal — wins there instead.
    func testTranscriptOutranksThePickForClaudeAndNotForTheRest() throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("omniagent-engine-model-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let cwd = "/Users/b/proj"
        let url = ClaudeModel.transcriptURL(sessionID: "p1", cwd: cwd, home: home)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try "{\"message\":{\"model\":\"claude-opus-5\"}}\n".write(
            to: url, atomically: true, encoding: .utf8
        )

        XCTAssertEqual(
            ClaudeModel.current(sessionID: "p1", cwd: cwd, home: home), "claude-opus-5"
        )
        // The pick is a request Claude can refuse; only its transcript settles
        // it. Everything else has nothing that could disagree.
        XCTAssertFalse(EngineModel.pickIsAuthoritative(for: .claude))
        for engine in [Engine.codex, .copilot, .antigravity] {
            XCTAssertTrue(EngineModel.pickIsAuthoritative(for: engine), "\(engine)")
        }
        // A shell has no model to report, whatever was picked.
        XCTAssertNil(
            EngineModel.current(engine: .shell, sessionID: "p1", cwd: cwd, picked: "opus")
        )
        // Nothing on disk for AntiGravity — the pick is the whole answer.
        XCTAssertEqual(
            EngineModel.current(engine: .antigravity, sessionID: "p1", cwd: cwd, picked: "x"),
            "x"
        )
        XCTAssertNil(
            EngineModel.current(engine: .antigravity, sessionID: "p1", cwd: cwd, picked: nil)
        )
        // A Claude pane that has answered nothing reports nothing — not the
        // model the user just asked for and may have then declined. This is
        // the bug the badge had: a rejected switch left it claiming a model
        // the terminal was not running.
        XCTAssertNil(
            EngineModel.current(engine: .claude, sessionID: "unanswered", cwd: cwd, picked: "haiku")
        )
        // Copilot's documented default, until this app sets otherwise.
        XCTAssertEqual(
            EngineModel.current(engine: .copilot, sessionID: "p1", cwd: cwd, picked: nil),
            "auto"
        )
    }

    /// The top-level `model`, not `model_reasoning_effort` beside it and not a
    /// `[projects."…"]` section's own settings below it.
    func testCodexConfigReadsTheModelInForce() throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("omniagent-codex-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".codex"), withIntermediateDirectories: true
        )
        try """
        notify = ["thing"]
        model = "gpt-5.6-sol"
        model_reasoning_effort = "medium"

        [projects."/somewhere"]
        model = "not-this-one"

        [tui.model_availability_nux]
        "gpt-5.6-sol" = 4
        "gpt-5.4" = 1
        """.write(
            to: home.appendingPathComponent(".codex/config.toml"),
            atomically: true, encoding: .utf8
        )
        XCTAssertEqual(EngineModel.codexConfiguredModel(home: home), "gpt-5.6-sol")
        XCTAssertEqual(
            EngineModel.codexKnownModels(home: home).map(\.id), ["gpt-5.6-sol", "gpt-5.4"]
        )
        // No config at all is a missing answer, not a crash.
        XCTAssertNil(EngineModel.codexConfiguredModel(home: home.appendingPathComponent("nope")))
    }

    /// Claude's menu offers aliases and its transcript answers full ids, so
    /// the tick is a containment match there and an exact one everywhere else
    /// — and `default`, which names a preference rather than a model, never
    /// ticks at all.
    func testTheTickMarksWhereTheMenuAndTheTranscriptAgree() {
        let opus = ModelChoice(id: "opus")
        XCTAssertTrue(
            EngineModelList.choice(opus, isCurrent: "claude-opus-5", engine: .claude)
        )
        XCTAssertFalse(
            EngineModelList.choice(opus, isCurrent: "claude-sonnet-5", engine: .claude)
        )
        XCTAssertFalse(
            EngineModelList.choice(
                ModelChoice(id: "default"), isCurrent: "claude-opus-5", engine: .claude
            )
        )
        // Codex round-trips its own ids, so a substring must not be enough.
        let sol = ModelChoice(id: "gpt-5.6-sol")
        XCTAssertTrue(EngineModelList.choice(sol, isCurrent: "gpt-5.6-sol", engine: .codex))
        XCTAssertFalse(EngineModelList.choice(sol, isCurrent: "gpt-5.6", engine: .codex))
        XCTAssertFalse(EngineModelList.choice(sol, isCurrent: nil, engine: .codex))
    }

    /// Only the engines that have to be asked open a menu that says so.
    /// Claude and Copilot answer from a list in the source, and a shell has
    /// no menu at all.
    func testOnlyTheEnginesThatMustBeAskedOpenWithoutTheirList() {
        EngineModelList.resetMemos()
        let defaults = UserDefaults(suiteName: "omniagent-models-\(UUID().uuidString)")!
        XCTAssertEqual(
            EngineModelList.cached(for: .claude, defaults: defaults)?.map(\.id),
            EngineModelList.claudeAliases
        )
        XCTAssertEqual(EngineModelList.cached(for: .copilot, defaults: defaults)?.map(\.id), ["auto"])
        XCTAssertEqual(EngineModelList.cached(for: .shell, defaults: defaults), [])
        XCTAssertNil(EngineModelList.cached(for: .codex, defaults: defaults))
        XCTAssertNil(EngineModelList.cached(for: .antigravity, defaults: defaults))
    }

    /// A day-old answer is served from disk; a stale one is not. The stamp is
    /// the whole point — without it the menu either re-runs a network call
    /// every time it opens or never notices a new model again.
    func testTheAntigravityListIsServedForADayAndNoLonger() {
        EngineModelList.resetMemos()
        let defaults = UserDefaults(suiteName: "omniagent-models-\(UUID().uuidString)")!
        defaults.set([["gemini-3.7-flash-high", "Gemini 3.7 Flash (High)"]],
                     forKey: "omniagent.models.antigravity")
        defaults.set(Date().timeIntervalSince1970, forKey: "omniagent.models.antigravity.fetchedAt")
        XCTAssertEqual(
            EngineModelList.cached(for: .antigravity, defaults: defaults)?.map(\.label),
            ["Gemini 3.7 Flash (High)"]
        )

        defaults.set(
            Date().timeIntervalSince1970 - EngineModelList.refreshInterval - 1,
            forKey: "omniagent.models.antigravity.fetchedAt"
        )
        XCTAssertNil(EngineModelList.cached(for: .antigravity, defaults: defaults))
    }

    /// A shell is not switchable; every agent is.
    func testOnlyAShellHasNoSwitchCommand() {
        XCTAssertNil(EngineModel.switchCommand(engine: .shell, model: "x"))
        XCTAssertEqual(
            EngineModel.switchCommand(engine: .antigravity, model: "gemini-3.7-flash-high"),
            "/model gemini-3.7-flash-high"
        )
        XCTAssertEqual(EngineModel.label(for: "claude-opus-5", engine: .claude), "Opus 5")
        XCTAssertEqual(EngineModel.label(for: "gpt-5.6-sol", engine: .codex), "gpt-5.6-sol")
        XCTAssertEqual(EngineModel.label(for: "auto", engine: .copilot), "Auto")
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
