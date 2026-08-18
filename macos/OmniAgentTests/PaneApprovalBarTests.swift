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
