import AppKit
import SwiftTerm
import XCTest

@testable import OmniAgent

/// The approval bar's parser is pinned against *captured* Claude Code 2.1.234
/// screens (tmux, 2026-08-18), not invented shapes — the same discipline as
/// the daemon's markers.
final class ApprovalPromptTests: XCTestCase {
    func testParsesAnAskUserQuestionDialog() {
        let prompt = ApprovalPrompt.parse(lines: [
            " ☐ Color",
            "Which color do you prefer?",
            "❯ 1. Red",
            "     Prefer red",
            "  2. Blue",
            "     Prefer blue",
            "  3. Type something.",
            "────────────────────────────────",
            "  4. Chat about this",
            "Enter to select · ↑/↓ to navigate · Esc to cancel",
        ])
        XCTAssertEqual(prompt?.question, "Which color do you prefer?")
        XCTAssertEqual(
            prompt?.options,
            [
                ApprovalPrompt.Option(number: 1, label: "Red"),
                ApprovalPrompt.Option(number: 2, label: "Blue"),
                ApprovalPrompt.Option(number: 3, label: "Type something."),
                ApprovalPrompt.Option(number: 4, label: "Chat about this"),
            ]
        )
    }

    func testParsesAPermissionDialog() {
        let prompt = ApprovalPrompt.parse(lines: [
            " Do you want to create notes.txt?",
            " ❯ 1. Yes",
            "   2. Yes, and don't ask again this session",
            "   3. No, and tell Claude what to do differently",
            " Esc to cancel",
        ])
        XCTAssertEqual(prompt?.question, "Do you want to create notes.txt?")
        XCTAssertEqual(prompt?.options.count, 3)
        XCTAssertEqual(prompt?.options.first?.label, "Yes")
    }

    /// The trust dialog's prose ends mid-sentence lines, none ending in `?` —
    /// the options still parse and the bar falls back to its generic label.
    func testTheTrustDialogParsesItsOptionsWithoutAQuestion() {
        let prompt = ApprovalPrompt.parse(lines: [
            " Claude Code'll be able to read, edit, and execute files here.",
            " Security guide",
            " ❯ 1. Yes, I trust this folder",
            "   2. No, exit",
            " Enter to confirm · Esc to cancel",
        ])
        XCTAssertNil(prompt?.question)
        XCTAssertEqual(prompt?.options.map(\.number), [1, 2])
    }

    func testAPlainScreenParsesToNothing() {
        XCTAssertNil(
            ApprovalPrompt.parse(lines: [
                "❯ cargo test -p brain-ingest",
                "running 12 tests",
                "test result: ok. 12 passed",
            ])
        )
    }

    /// Numbered rows above the live dialog — an old answered dialog, a
    /// numbered list in output — must not leak into the buttons: the row
    /// nearest the footer wins each number.
    func testTheDialogNearestTheFooterWinsEachNumber() {
        let prompt = ApprovalPrompt.parse(lines: [
            "  1. stale earlier option",
            "  2. stale earlier option",
            "Do you want to proceed?",
            "❯ 1. Yes",
            "  2. No",
            " Esc to cancel",
        ])
        XCTAssertEqual(prompt?.options.map(\.label), ["Yes", "No"])
    }
}

final class PaneApprovalBarViewTests: XCTestCase {
    func testOneButtonPerOptionAndAClickSendsItsDigit() {
        let bar = PaneApprovalBarView()
        var sent: [String] = []
        bar.onChoose = { sent.append($0) }
        bar.prompt = ApprovalPrompt(
            question: "Which color do you prefer?",
            options: [
                ApprovalPrompt.Option(number: 1, label: "Red"),
                ApprovalPrompt.Option(number: 2, label: "Blue"),
            ]
        )
        let buttons = bar.subviews.compactMap { $0 as? PaneApprovalButton }
        XCTAssertEqual(buttons.map(\.title), ["Red", "Blue"])
        XCTAssertEqual(buttons.map(\.isPrimary), [true, false])
        XCTAssertTrue(buttons[1].accessibilityPerformPress())
        XCTAssertEqual(sent, ["2"])
    }

    /// No parsed options still leaves the two universal answers: Enter
    /// confirms the dialog's own highlighted default, Esc backs out.
    func testWithNoOptionsTheBarFallsBackToApproveAndDeny() {
        let bar = PaneApprovalBarView()
        var sent: [String] = []
        bar.onChoose = { sent.append($0) }
        bar.prompt = nil
        let buttons = bar.subviews.compactMap { $0 as? PaneApprovalButton }
        XCTAssertEqual(buttons.map(\.title), ["Approve", "Deny"])
        buttons.forEach { _ = $0.accessibilityPerformPress() }
        XCTAssertEqual(sent, ["\r", "\u{1b}"])
    }
}

final class PaneContainerApprovalTests: XCTestCase {
    func testAwaitingApprovalShowsTheBarAndTakesItsHeightFromTheTerminal() throws {
        let workspace = makeWorkspace()
        let container = try XCTUnwrap(workspace.container(for: "pane-1"))
        XCTAssertTrue(container.approvalBar.isHidden, "born without the bar")
        let plainHeight = container.terminalSurfaceFrame.height

        workspace.setStatus(.awaitingApproval, for: "pane-1")
        container.layoutSubtreeIfNeeded()
        XCTAssertFalse(container.approvalBar.isHidden)
        XCTAssertEqual(container.approvalBar.frame.height, PaneApprovalBarView.height)
        XCTAssertEqual(
            container.terminalSurfaceFrame.height,
            plainHeight - PaneApprovalBarView.height,
            "the terminal gives the bar its strip"
        )

        workspace.setStatus(.ready, for: "pane-1")
        container.layoutSubtreeIfNeeded()
        XCTAssertTrue(container.approvalBar.isHidden)
        XCTAssertEqual(container.terminalSurfaceFrame.height, plainHeight)
    }

    private func makeWorkspace() -> PaneWorkspaceView {
        let connection = SessionConnection(
            socketURL: URL(fileURLWithPath: "/tmp/omniagent-approval-bar-test.sock")
        )
        let workspace = PaneWorkspaceView { descriptor in
            TerminalSurfaceView(connection: connection, sessionID: descriptor.sessionID)
        }
        workspace.frame = CGRect(x: 0, y: 0, width: 1200, height: 800)
        XCTAssertTrue(
            workspace.addPane(
                PaneDescriptor(sessionID: "pane-1", group: "sess-grp-1", groupLabel: nil, title: "")
            )
        )
        workspace.layoutSubtreeIfNeeded()
        return workspace
    }
}

private extension PaneContainerView {
    var terminalSurfaceFrame: CGRect { (surface as! TerminalSurfaceView).frame }
}

/// The fixtures above are tmux captures, where the gaps between words are real
/// spaces. What reaches the bar in the app is a SwiftTerm buffer, and that is
/// not the same text: Claude's TUI paints a line by jumping to absolute columns
/// rather than writing the spaces, and SwiftTerm renders a never-written cell
/// as U+0000. These drive a real terminal the way Claude drives one.
final class ApprovalPromptSwiftTermTests: XCTestCase {
    private final class SilentTerminalDelegate: TerminalDelegate {
        func send(source: Terminal, data: ArraySlice<UInt8>) {}
    }

    /// `Enter to select · ↑/↓ to navigate · Esc to cancel` as Claude Code
    /// 2.1.234 actually writes it, and the option rows likewise.
    private func terminalShowingADialog() -> Terminal {
        let terminal = Terminal(
            delegate: SilentTerminalDelegate(),
            options: TerminalOptions(cols: 100, rows: 12)
        )
        terminal.feed(text: "\u{1b}[H\u{1b}[2J")
        terminal.feed(text: "\u{1b}[2;1HWhat\u{1b}[2;6Hdo\u{1b}[2;9Hyou\u{1b}[2;13Hwant\u{1b}[2;18Hdone?")
        terminal.feed(text: "\u{1b}[4;1H❯\u{1b}[4;3H1.\u{1b}[4;6HLeave\u{1b}[4;12Hit\u{1b}[4;15Has-is")
        terminal.feed(text: "\u{1b}[5;3H2.\u{1b}[5;6HAdd\u{1b}[5;10Hgit\u{1b}[5;14Hbranch")
        terminal.feed(
            text: "\u{1b}[7;1HEnter\u{1b}[7;7Hto\u{1b}[7;10Hselect\u{1b}[7;18H·"
                + "\u{1b}[7;20HEsc\u{1b}[7;24Hto\u{1b}[7;27Hcancel"
        )
        return terminal
    }

    func testTheBufferComesBackWithSpacesNotNulls() {
        let lines = TerminalSurfaceView.tailLines(of: terminalShowingADialog())
        XCTAssertFalse(
            lines.contains { $0.contains("\0") },
            "a NUL in the text is a gap SwiftTerm never filled: \(lines)"
        )
        XCTAssertTrue(
            lines.contains { $0.contains("Esc to cancel") },
            "the footer every attention marker keys off: \(lines)"
        )
    }

    func testADialogClaudeActuallyPaintedParsesIntoOptions() {
        let prompt = ApprovalPrompt.parse(
            lines: TerminalSurfaceView.tailLines(of: terminalShowingADialog())
        )
        XCTAssertEqual(prompt?.question, "What do you want done?")
        XCTAssertEqual(
            prompt?.options,
            [
                ApprovalPrompt.Option(number: 1, label: "Leave it as-is"),
                ApprovalPrompt.Option(number: 2, label: "Add git branch"),
            ]
        )
    }
}

/// `accessibilityPerformPress` proves the wiring, not the click: it calls
/// `onClick` directly and never asks AppKit to route a mouse event. These do,
/// through a real window, because a button nobody can click is the bug.
final class PaneApprovalButtonClickTests: XCTestCase {
    private func barInAWindow() -> (PaneApprovalBarView, NSWindow) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let bar = PaneApprovalBarView()
        bar.frame = NSRect(x: 0, y: 0, width: 600, height: PaneApprovalBarView.height)
        window.contentView?.addSubview(bar)
        // On screen, and through `NSApp`: a mouse-up is routed to the view
        // that took the mouse-down by AppKit's own bookkeeping, and an
        // unordered window sending its own events never sets that up.
        window.makeKeyAndOrderFront(nil)
        bar.layoutSubtreeIfNeeded()
        return (bar, window)
    }

    private func click(_ button: PaneApprovalButton, in window: NSWindow) {
        let center = button.convert(
            NSPoint(x: button.bounds.midX, y: button.bounds.midY),
            to: nil
        )
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(
                with: type,
                location: center,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: type == .leftMouseDown ? 1 : 0
            )
            guard let event else {
                return XCTFail("could not synthesise a \(type) event")
            }
            NSApp.sendEvent(event)
        }
    }

    func testTheClickLandsOnTheButtonAndNotThroughIt() throws {
        let (bar, window) = barInAWindow()
        bar.prompt = ApprovalPrompt(
            question: "Which color?",
            options: [ApprovalPrompt.Option(number: 1, label: "Red")]
        )
        bar.layoutSubtreeIfNeeded()
        let button = try XCTUnwrap(bar.subviews.compactMap { $0 as? PaneApprovalButton }.first)
        let center = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        let content = try XCTUnwrap(window.contentView)
        // `hitTest` takes its point in the receiver's *superview* space, which
        // for a content view is window space — what `center` already is.
        // Converting into the content view first mirrors the y whenever that
        // view is flipped, and both of the ones here are.
        let hit = content.hitTest(center)
        XCTAssertTrue(hit === button, "hit testing returned \(String(describing: hit))")
    }

    func testClickingAnOptionSendsItsDigit() {
        let (bar, window) = barInAWindow()
        var sent: [String] = []
        bar.onChoose = { sent.append($0) }
        bar.prompt = ApprovalPrompt(
            question: "Which color?",
            options: [
                ApprovalPrompt.Option(number: 1, label: "Red"),
                ApprovalPrompt.Option(number: 2, label: "Blue"),
            ]
        )
        bar.layoutSubtreeIfNeeded()
        let buttons = bar.subviews.compactMap { $0 as? PaneApprovalButton }
        click(buttons[1], in: window)
        XCTAssertEqual(sent, ["2"])
    }

    func testClickingApproveSendsEnter() {
        let (bar, window) = barInAWindow()
        var sent: [String] = []
        bar.onChoose = { sent.append($0) }
        bar.prompt = nil
        bar.layoutSubtreeIfNeeded()
        let buttons = bar.subviews.compactMap { $0 as? PaneApprovalButton }
        click(buttons[0], in: window)
        XCTAssertEqual(sent, ["\r"])
    }
}

/// The bar in the place it actually lives. A button that answers a click on a
/// bench and not in the app is the bug the user reported, so this drives the
/// whole hierarchy — workspace, container, zoom overlay — through `NSApp`.
final class PaneApprovalBarInWorkspaceTests: XCTestCase {
    private func makeWindowedWorkspace() -> (PaneWorkspaceView, NSWindow) {
        let connection = SessionConnection(
            socketURL: URL(fileURLWithPath: "/tmp/omniagent-approval-click-test.sock")
        )
        let workspace = PaneWorkspaceView { descriptor in
            TerminalSurfaceView(connection: connection, sessionID: descriptor.sessionID)
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = workspace
        window.makeKeyAndOrderFront(nil)
        _ = workspace.addPane(
            PaneDescriptor(sessionID: "pane-1", group: "sess-grp-1", groupLabel: nil, title: "")
        )
        workspace.setStatus(.awaitingApproval, for: "pane-1")
        workspace.layoutSubtreeIfNeeded()
        return (workspace, window)
    }

    private func clickApprove(in workspace: PaneWorkspaceView, window: NSWindow) throws -> NSView? {
        let container = try XCTUnwrap(workspace.container(for: "pane-1"))
        container.layoutSubtreeIfNeeded()
        let button = try XCTUnwrap(
            container.approvalBar.subviews.compactMap { $0 as? PaneApprovalButton }.first
        )
        let center = button.convert(
            NSPoint(x: button.bounds.midX, y: button.bounds.midY),
            to: nil
        )
        let content = try XCTUnwrap(window.contentView)
        // Window space already, as in `PaneApprovalButtonClickTests`. The
        // convert this used to do landed on the header's badges: the workspace
        // is flipped, so it probed the mirrored y, near the top of the pane.
        let hit = content.hitTest(center)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(
                NSEvent.mouseEvent(
                    with: type,
                    location: center,
                    modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber,
                    context: nil,
                    eventNumber: 0,
                    clickCount: 1,
                    pressure: type == .leftMouseDown ? 1 : 0
                )
            )
            NSApp.sendEvent(event)
        }
        return hit
    }

    func testAClickOnTheBarReachesTheButton() throws {
        let (workspace, window) = makeWindowedWorkspace()
        var sent: [String] = []
        let container = try XCTUnwrap(workspace.container(for: "pane-1"))
        container.approvalBar.onChoose = { sent.append($0) }
        let hit = try clickApprove(in: workspace, window: window)
        XCTAssertTrue(hit is PaneApprovalButton, "the click landed on \(String(describing: hit))")
        XCTAssertEqual(sent, ["\r"])
    }

    func testAClickOnTheBarReachesTheButtonWhileZoomed() throws {
        let (workspace, window) = makeWindowedWorkspace()
        _ = workspace.toggleZoom("pane-1")
        workspace.layoutSubtreeIfNeeded()
        var sent: [String] = []
        let container = try XCTUnwrap(workspace.container(for: "pane-1"))
        container.approvalBar.onChoose = { sent.append($0) }
        let hit = try clickApprove(in: workspace, window: window)
        XCTAssertTrue(hit is PaneApprovalButton, "the click landed on \(String(describing: hit))")
        XCTAssertEqual(sent, ["\r"])
    }
}

/// ⇧⏎ has to reach the agent as something other than a bare CR, or it submits
/// the prompt instead of adding a line to it.
final class TerminalReturnKeyTests: XCTestCase {
    func testShiftReturnSendsEscapeCR() {
        XCTAssertEqual(
            NativeTerminalView.overrideBytes(keyCode: 36, modifiers: .shift, kittyActive: false),
            [0x1b, 0x0d]
        )
        XCTAssertEqual(
            NativeTerminalView.overrideBytes(keyCode: 76, modifiers: .shift, kittyActive: false),
            [0x1b, 0x0d]
        )
    }

    func testEverythingElseIsLeftToSwiftTerm() {
        // Plain ⏎, ⌃⏎/⌥⏎ (SwiftTerm's own meta path), a non-return key, and
        // ⇧⏎ while the app drives the kitty keyboard protocol itself.
        XCTAssertNil(NativeTerminalView.overrideBytes(keyCode: 36, modifiers: [], kittyActive: false))
        XCTAssertNil(NativeTerminalView.overrideBytes(keyCode: 36, modifiers: [.shift, .option], kittyActive: false))
        XCTAssertNil(NativeTerminalView.overrideBytes(keyCode: 0, modifiers: .shift, kittyActive: false))
        XCTAssertNil(NativeTerminalView.overrideBytes(keyCode: 36, modifiers: .shift, kittyActive: true))
        // Caps lock / numeric-pad bits ride along and must not defeat it.
        XCTAssertEqual(
            NativeTerminalView.overrideBytes(
                keyCode: 76, modifiers: [.shift, .numericPad, .capsLock], kittyActive: false),
            [0x1b, 0x0d]
        )
    }

    /// ⌥ is Meta, so a layout whose brackets live on ⌥8/⌥9 could not type
    /// one at all until the composed character was let through.
    func testOptionComposedPunctuationIsSentLiterally() {
        XCTAssertEqual(
            NativeTerminalView.composedOptionText(modifiers: .option, characters: "]"),
            "]"
        )
        XCTAssertEqual(
            NativeTerminalView.composedOptionText(modifiers: [.option, .shift], characters: "}"),
            "}"
        )
    }

    func testMetaChordsStillReachSwiftTerm() {
        // ⌥b/⌥f compose a letter, ⌥⌫ composes nothing, ⌥⏎ composes CR, and
        // ⌃/⌘ chords are not this at all. Bare punctuation has no ⌥ to pass.
        XCTAssertNil(NativeTerminalView.composedOptionText(modifiers: .option, characters: "∫"))
        XCTAssertNil(NativeTerminalView.composedOptionText(modifiers: .option, characters: ""))
        XCTAssertNil(NativeTerminalView.composedOptionText(modifiers: .option, characters: "\r"))
        XCTAssertNil(NativeTerminalView.composedOptionText(modifiers: .option, characters: "9"))
        XCTAssertNil(
            NativeTerminalView.composedOptionText(modifiers: [.option, .control], characters: "]")
        )
        XCTAssertNil(NativeTerminalView.composedOptionText(modifiers: [], characters: "]"))
    }

    /// The routing half. `performKeyEquivalent` looked like the hook and is
    /// not one: AppKit offers it only for ⌘ chords, so a bare ⇧⏎ or ⌥ chord
    /// went straight to SwiftTerm's `keyDown` and both overrides were dead
    /// code in the shipped app. `WorkspaceWindow.sendEvent` is the hook that
    /// actually runs — this pins the decision it delegates to.
    func testTheTerminalConsumesShiftReturnAndComposedOptionOnKeyDown() {
        let surface = TerminalSurfaceView(
            connection: SessionConnection(
                socketURL: URL(fileURLWithPath: "/tmp/omniagent-key-intercept-test.sock")
            ),
            sessionID: "pane-1"
        )
        let terminal = surface.terminalView
        XCTAssertTrue(terminal.interceptKeyDown(returnEvent(shift: true)), "⇧⏎")
        XCTAssertTrue(terminal.interceptKeyDown(optionEvent(characters: "}", keyCode: 25)), "⌥9")
        XCTAssertFalse(terminal.interceptKeyDown(returnEvent(shift: false)), "plain ⏎ is SwiftTerm's")
        XCTAssertFalse(
            terminal.interceptKeyDown(optionEvent(characters: "∫", keyCode: 11)),
            "⌥b is Meta and stays SwiftTerm's"
        )
    }

    /// A `WorkspaceWindow` sees its focused terminal as the concrete class
    /// `sendEvent` type-checks for — the cast that carries the fix.
    func testTheWorkspaceWindowSeesAFocusedTerminalAsNativeTerminalView() {
        let surface = TerminalSurfaceView(
            connection: SessionConnection(
                socketURL: URL(fileURLWithPath: "/tmp/omniagent-key-intercept-test.sock")
            ),
            sessionID: "pane-1"
        )
        let window = WorkspaceWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = surface
        window.makeKeyAndOrderFront(nil)
        XCTAssertTrue(window.makeFirstResponder(surface.terminalView))
        XCTAssertTrue(window.firstResponder is NativeTerminalView)
    }

    private func optionEvent(characters: String, keyCode: UInt16) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: .option,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: keyCode
        )!
    }

    private func returnEvent(shift: Bool) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: shift ? .shift : [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "\r",
            charactersIgnoringModifiers: "\r",
            isARepeat: false,
            keyCode: 36
        )!
    }
}
