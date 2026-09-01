import XCTest
@testable import OmniAgent

/// The Home screen: the design's words, the interactive feel, and a layout
/// pass that must not throw the constraint engine. The controls hover, focus
/// and press like the real thing; Home now reports Send so the controller can
/// run the branch/session setup flow.
final class HomeViewTests: XCTestCase {
    private func makeHome() -> HomeSurfaceView {
        let home = HomeSurfaceView()
        home.refresh(workspaceID: "omniagent-ade", workspaceName: "OmniAgent-ADE")
        return home
    }

    private func allLabels(in view: NSView) -> [String] {
        var texts: [String] = []
        func walk(_ view: NSView) {
            if let field = view as? NSTextField { texts.append(field.stringValue) }
            view.subviews.forEach(walk)
        }
        walk(view)
        return texts
    }

    /// The design's sections and copy are on screen.
    func testTheHomeScreenSaysWhatTheDesignSays() {
        let home = makeHome()
        XCTAssertEqual(
            home.composerPrompt.placeholderAttributedString?.string,
            "Ask anything, or start a session. Use / for commands…"
        )
        let labels = allLabels(in: home)
        for expected in [
            "Up next",
            "You're all caught up",
            "Extend your experience",
            "Extend with MCP servers",
            "Grow the brain",
            "What's new",
            "OmniAgent uses AI. Check for mistakes.",
            "OmniAgent-ADE",
        ] {
            XCTAssertTrue(labels.contains(expected), "missing: \(expected)")
        }
    }

    /// The hero wears the OmniAgent mark, not initials and not another brand.
    func testTheHeroWearsTheOmniAgentMark() {
        let home = makeHome()
        XCTAssertNotNil(home.markImageView.image)
        XCTAssertEqual(home.markImageView.image?.name(), OmniAgentMark.image?.name())
    }

    /// The design's three suggestion cards are all present, and the workspace
    /// chip follows the selected workspace — asking for one, tile-less, when
    /// none is selected.
    func testTheSuggestionsAndTheWorkspaceChip() {
        let home = makeHome()
        XCTAssertEqual(home.suggestionCards.count, 3)
        XCTAssertEqual(home.workspaceChipName.stringValue, "OmniAgent-ADE")
        XCTAssertFalse(home.workspaceChipFolder.isHidden)

        home.refresh(workspaceID: nil, workspaceName: nil)
        XCTAssertEqual(home.workspaceChipName.stringValue, "Select workspace")
        XCTAssertTrue(home.workspaceChipFolder.isHidden, "no folder for a workspace that is not there")
    }

    /// A suggestion card and a pill wear the brighter fill under the pointer
    /// and put it back when it leaves — hover painting is independent of
    /// what a press does, wired or (still, for these two) inert.
    func testHoverPaintsAndUnpaintsTheInteractiveFills() throws {
        let home = makeHome()
        let card = try XCTUnwrap(home.suggestionCards.first)
        XCTAssertNotNil(card.onPress, "a suggestion card is interactive")
        card.setHovered(true)
        XCTAssertEqual(card.layer?.backgroundColor, ShellPalette.cardFillHover.cgColor)
        XCTAssertEqual(card.layer?.borderColor, ShellPalette.cardStrokeHover.cgColor)
        card.setHovered(false)
        XCTAssertEqual(card.layer?.backgroundColor, ShellPalette.cardFill.cgColor)
        XCTAssertEqual(card.layer?.borderColor, ShellPalette.cardStroke.cgColor)

        home.viewAllPill.setHovered(true)
        XCTAssertEqual(home.viewAllPill.layer?.backgroundColor, ShellPalette.cardFillHover.cgColor)
        home.viewAllPill.setHovered(false)
        XCTAssertEqual(home.viewAllPill.layer?.backgroundColor, ShellPalette.iconTile.cgColor)

        // Still inert by decision: pressing must be possible and must do
        // nothing. The suggestion card's own press is wired now — see
        // `testASuggestionCardTypesItsPromptIntoTheComposer`.
        home.viewAllPill.onPress?()
        home.sendControl?.onPress?()
    }

    /// A suggestion card fills the composer with its full prompt, one
    /// character at a time, replacing whatever draft was already there —
    /// proven by running the reveal loop to completion by hand instead of
    /// waiting on the real clock.
    func testASuggestionCardTypesItsPromptIntoTheComposer() throws {
        let home = makeHome()
        home.composerPrompt.stringValue = "leftover draft"
        let card = try XCTUnwrap(home.suggestionCards.first)

        card.onPress?()
        XCTAssertEqual(home.composerPrompt.stringValue, "", "the old draft is cleared immediately")
        XCTAssertNotNil(home.typingTimerForTesting, "typing starts a timer")

        var guardCount = 0
        while let timer = home.typingTimerForTesting, guardCount < 500 {
            timer.fire()
            guardCount += 1
        }
        XCTAssertNil(home.typingTimerForTesting, "the reveal loop ran to completion")
        XCTAssertFalse(home.composerPrompt.stringValue.isEmpty)
    }

    /// The pool `buildSuggestions()` draws from bundles cleanly and holds
    /// every entry — a JSON typo or a bundling mistake fails loudly here
    /// instead of silently emptying the Home screen's suggestion cards.
    func testTheSuggestionPoolBundlesAllTwentyOneEntries() {
        XCTAssertEqual(HomeSurfaceView.loadSuggestionPool().count, 21)
    }

    /// The daily pick is deterministic for a given day (same seed twice
    /// matches), and always one of each kind in project/create/chat order —
    /// never three codebase chores and nothing to just talk about.
    func testDailySuggestionsAreStableAndCoverEveryKind() {
        let pool = HomeSurfaceView.loadSuggestionPool()
        let a = HomeSurfaceView.dailySuggestions(from: pool, seed: 42)
        let b = HomeSurfaceView.dailySuggestions(from: pool, seed: 42)
        XCTAssertEqual(a.map(\.title), b.map(\.title))
        XCTAssertEqual(a.map(\.kind), [.project, .create, .chat])
    }

    /// The branch chip: "Set up GitHub" with no git, "main" for an existing
    /// branch, "main → name" for one to be created — and picking an existing
    /// branch again clears the pending new one rather than keeping both.
    /// Only the Chat scratch workspace hides it: nothing to branch, nothing
    /// to set up.
    func testTheBranchChipShowsExistingNewAndNothing() throws {
        let home = makeHome()
        let chip = try XCTUnwrap(home.branchChip)

        home.refresh(workspaceID: HomeChatWorkspace.id, workspaceName: "Chat", branch: nil)
        XCTAssertTrue(chip.isHidden, "Chat is not a project")

        home.refresh(workspaceID: "x", workspaceName: "X", branch: nil)
        XCTAssertTrue(chip.isHidden, "no git, no branch to pick — no chip")

        home.refresh(workspaceID: "x", workspaceName: "X", branch: "main")
        XCTAssertFalse(chip.isHidden)
        XCTAssertEqual(home.branchLabel.stringValue, "main")
        XCTAssertNil(home.newBranchName)

        home.updateBranchChip(new: "feature-x", from: "main")
        XCTAssertEqual(home.branchLabel.stringValue, "main → feature-x")
        XCTAssertEqual(home.selectedBranch, "main")
        XCTAssertEqual(home.newBranchName, "feature-x")

        home.updateBranchChip(existing: "develop")
        XCTAssertEqual(home.branchLabel.stringValue, "develop")
        XCTAssertNil(home.newBranchName, "an existing pick drops the pending new branch")
    }

    /// Nothing to pick a session or branch *for* until a workspace is
    /// picked; an existing session's branch is shown but not pickable; a
    /// new session in a folder with no git has no branch chip at all.
    func testTheSessionAndBranchChipsFollowTheWorkspaceAndSessionPicks() throws {
        let home = HomeSurfaceView()
        let session = try XCTUnwrap(home.sessionChip)
        let branch = try XCTUnwrap(home.branchChip)

        home.refresh(workspaceID: nil, workspaceName: nil, branch: "main")
        XCTAssertTrue(session.isHidden, "no workspace: no session chip")
        XCTAssertTrue(branch.isHidden, "no workspace: no branch chip")

        home.refresh(workspaceID: "x", workspaceName: "X", sessionLabel: "Session 1", branch: "main", sessionLocked: true)
        XCTAssertFalse(session.isHidden)
        XCTAssertFalse(branch.isHidden)
        XCTAssertTrue(home.isBranchLocked)
        XCTAssertNil(branch.onPress, "an existing session's branch is a fact, not a choice")
        XCTAssertEqual(home.branchLabel.stringValue, "main")

        home.updateSessionChip(label: "New session", branch: "main")
        XCTAssertFalse(home.isBranchLocked)
        XCTAssertNotNil(branch.onPress, "a new session picks its branch")

        home.updateSessionChip(label: "New session", branch: nil)
        XCTAssertTrue(branch.isHidden, "no git: no branch chip")
    }

    /// Return in the composer is Send; Option-Return is left to the field
    /// editor, which breaks the line.
    func testReturnInTheComposerSends() {
        let home = makeHome()
        var sends = 0
        home.onSend = { sends += 1 }
        let textView = NSTextView()

        XCTAssertTrue(home.control(home.composerPrompt, textView: textView, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        XCTAssertFalse(home.control(
            home.composerPrompt, textView: textView, doCommandBy: #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:))
        ))
        XCTAssertEqual(sends, 1)
    }

    /// The launch runs its steps off the pane's own output: the first byte
    /// is "engine loading", quiet after it sets the model, quiet after
    /// *that* sends the message, a beat later the glass lifts. No model
    /// picked skips the model step; an exit cancels without sending.
    func testTheLaunchSetsTheModelThenSendsTheMessageOnQuiet() {
        var shown: [HomeLaunch.Step] = []
        var sent: [String] = []
        var finished = false
        let launch = HomeLaunch(
            modelCommand: "/model opus", message: "hello", quiet: 0.02,
            show: { shown.append($0) }, send: { sent.append($0) }, finish: { finished = true }
        )
        XCTAssertEqual(shown, [.preparing])
        launch.noteOutput()
        XCTAssertEqual(shown, [.preparing, .loading])
        XCTAssertEqual(sent, [], "nothing goes in while the engine is still drawing")
        spin(0.08)
        XCTAssertEqual(sent, ["/model opus"])
        XCTAssertEqual(shown.last, .model)
        launch.noteOutput()
        spin(0.08)
        XCTAssertEqual(sent, ["/model opus", "hello"])
        XCTAssertEqual(shown.last, .conversation)
        XCTAssertFalse(finished, "a beat for the last line to type before the glass lifts")
        spin(1.0)
        XCTAssertTrue(finished)

        sent = []
        shown = []
        let plain = HomeLaunch(
            modelCommand: nil, message: "hi", quiet: 0.02,
            show: { shown.append($0) }, send: { sent.append($0) }, finish: {}
        )
        plain.noteOutput()
        spin(0.08)
        XCTAssertEqual(sent, ["hi"], "no model picked: straight to the conversation")
        XCTAssertEqual(shown, [.preparing, .loading, .conversation])

        sent = []
        var cancelled = false
        let dead = HomeLaunch(
            modelCommand: "/model opus", message: "hi", quiet: 0.02,
            show: { _ in }, send: { sent.append($0) }, finish: { cancelled = true }
        )
        dead.cancel()
        dead.noteOutput()
        spin(0.08)
        XCTAssertTrue(cancelled)
        XCTAssertEqual(sent, [], "a pane that exited gets nothing typed into it")
    }

    /// Each step is its own line; earlier ones stay, ticked. And the whole
    /// card renders offscreen.
    func testTheLaunchOverlayTypesEachStepOnItsOwnLine() throws {
        let overlay = HomeLaunchOverlayView()
        overlay.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        overlay.type(HomeLaunch.Step.preparing.rawValue)
        overlay.type(HomeLaunch.Step.loading.rawValue)
        XCTAssertEqual(overlay.lines, ["Preparing terminal", "Loading engine"])

        let window = NSWindow(contentRect: overlay.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = overlay
        spin(0.5)
        overlay.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(overlay.bitmapImageRepForCachingDisplay(in: overlay.bounds))
        overlay.cacheDisplay(in: overlay.bounds, to: bitmap)
        XCTAssertGreaterThan(bitmap.size.width, 0)
        saveRenderForInspection(bitmap, named: "home-launch")
    }

    private func spin(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    /// The branch dropdown's GitHub section must not keep saying "not
    /// connected" once Settings › Accounts says otherwise — that was the bug:
    /// a hardcoded string that never re-checked the real account state.
    func testGitHubSectionTextReflectsConnectionState() throws {
        let disconnected = HomeSurfaceView.gitHubSectionText(connected: false, login: "")
        XCTAssertEqual(disconnected.header, "GitHub · Not connected")
        XCTAssertEqual(disconnected.action, "Set up GitHub…")

        let connected = HomeSurfaceView.gitHubSectionText(connected: true, login: "brunobonando")
        XCTAssertEqual(connected.header, "GitHub · Connected as @brunobonando")
        XCTAssertEqual(connected.action, "Manage GitHub…")
    }

    func testSendControlReportsPressToOwner() throws {
        let home = makeHome()
        var sends = 0
        home.onSend = { sends += 1 }

        let send = try XCTUnwrap(home.sendControl)
        send.performPressForTesting()

        XCTAssertEqual(sends, 1)
    }

    /// The Chat scratch workspace wears a speech bubble where a project
    /// wears the sidebar's open folder, in the sidebar's colour for it.
    func testTheChatWorkspaceWearsABubbleNotAFolder() {
        let home = makeHome()
        XCTAssertFalse(home.workspaceChipFolder.isHidden)
        XCTAssertTrue(home.workspaceChipIcon.isHidden)

        home.refresh(workspaceID: HomeChatWorkspace.id, workspaceName: HomeChatWorkspace.label)
        XCTAssertTrue(home.workspaceChipFolder.isHidden)
        XCTAssertFalse(home.workspaceChipIcon.isHidden)
        XCTAssertEqual(home.workspaceChipName.stringValue, "Chat")

        home.refresh(workspaceID: "omniagent-ade", workspaceName: "OmniAgent-ADE", tint: WorkspaceColor.pink.tint)
        XCTAssertFalse(home.workspaceChipFolder.isHidden, "back to a project, back to the folder")
        XCTAssertTrue(home.workspaceChipIcon.isHidden)
        XCTAssertEqual(home.workspaceChipFolder.glyph, .folderOpen)
        XCTAssertEqual(home.workspaceChipFolder.color, WorkspaceColor.pink.tint)

        home.refresh(workspaceID: "omniagent-ade", workspaceName: "OmniAgent-ADE")
        XCTAssertEqual(home.workspaceChipFolder.color, ShellPalette.folderGlyph, "no colour picked, the sidebar's default")
    }

    /// The pool carries every kind in equal measure, so no kind ever runs
    /// out of variety before the others.
    func testTheSuggestionPoolHasSevenOfEachKind() {
        let pool = HomeSurfaceView.loadSuggestionPool()
        for kind in HomeSuggestion.Kind.allCases {
            XCTAssertEqual(pool.filter { $0.kind == kind }.count, 7, "\(kind)")
        }
    }

    /// The composer takes typing, and editing wears the design's focus
    /// stroke on the card.
    func testTheComposerTakesTypingAndWearsTheFocusStroke() {
        let home = makeHome()
        XCTAssertTrue(home.composerPrompt.isEditable)

        home.composerCard.setFocused(true)
        XCTAssertEqual(home.composerCard.layer?.borderColor, ShellPalette.cardStrokeHover.cgColor)
        home.composerCard.setFocused(false)
        XCTAssertEqual(home.composerCard.layer?.borderColor, ShellPalette.cardStroke.cgColor)

        // The card itself is scenery — no press, so no hover paint and no
        // hand cursor.
        XCTAssertNil(home.composerCard.onPress)
        home.composerCard.setHovered(true)
        XCTAssertEqual(home.composerCard.layer?.backgroundColor, ShellPalette.fieldFill.cgColor)
    }

    /// A full layout pass at a real window size, over the real pane ground,
    /// neither throws nor collapses — at a wide window and at a small laptop
    /// one, since the column is no longer a fixed lane but the card's own
    /// width less its margins. Drops a PNG when `PANE_RENDER_DIR` is set
    /// (`TEST_RUNNER_PANE_RENDER_DIR=/tmp/panes ./macos/build.sh test`).
    func testTheHomeScreenLaysOutOffscreen() throws {
        for (width, height, name) in [
            (CGFloat(1280), CGFloat(1900), "home"),
            (CGFloat(1000), CGFloat(700), "home-narrow"),
        ] {
            let home = makeHome()
            let laid = layOut(home, width: width, height: height)
            defer { laid.window.close() }
            XCTAssertEqual(home.shell.titleField.stringValue, "Home")
            XCTAssertFalse(home.hasAmbiguousLayout, "ambiguous at \(width)×\(height)")

            let bitmap = try XCTUnwrap(
                laid.container.bitmapImageRepForCachingDisplay(in: laid.container.bounds)
            )
            laid.container.cacheDisplay(in: laid.container.bounds, to: bitmap)
            XCTAssertGreaterThan(bitmap.size.width, 0)
            saveRenderForInspection(bitmap, named: name)
        }
    }

    /// Up next and What's new are one row, not two sections: the same row
    /// stack holds both halves, and `fillEqually` gives their cards the same
    /// width — with the same height, pinned card-to-card, so neither ends
    /// shorter than its neighbour.
    func testUpNextAndWhatsNewShareARow() throws {
        let home = makeHome()
        let laid = layOut(home, width: 1280, height: 1900)
        defer { laid.window.close() }

        let upNextHalf = try XCTUnwrap(home.upNextCard.superview)
        let whatsNewHalf = try XCTUnwrap(home.whatsNewCard.superview)
        let row = try XCTUnwrap(upNextHalf.superview as? NSStackView)
        XCTAssertTrue(whatsNewHalf.superview === row, "both halves hang off one row")
        XCTAssertEqual(row.orientation, .horizontal)
        XCTAssertEqual(row.spacing, 16)
        XCTAssertEqual(row.distribution, .fillEqually)

        XCTAssertEqual(home.upNextCard.frame.width, home.whatsNewCard.frame.width, accuracy: 0.5)
        XCTAssertEqual(home.upNextCard.frame.height, home.whatsNewCard.frame.height, accuracy: 0.5)
        XCTAssertGreaterThan(home.upNextCard.frame.width, 0)
        XCTAssertNotEqual(
            upNextHalf.frame.minX, whatsNewHalf.frame.minX,
            "side by side, not stacked"
        )
    }

    /// The screen laid out inside a window, over the real pane ground —
    /// what every layout assertion here needs before it can read a frame.
    private func layOut(
        _ home: HomeSurfaceView,
        width: CGFloat,
        height: CGFloat
    ) -> (container: NSView, window: NSWindow) {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        let ground = PaneGroundView()
        ground.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(ground)
        container.addSubview(home)
        for view in [ground, home] as [NSView] {
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                view.topAnchor.constraint(equalTo: container.topAnchor),
                view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
        }
        let window = NSWindow(
            contentRect: container.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = container
        container.layoutSubtreeIfNeeded()
        return (container, window)
    }

    /// The repo's render-drop seam: a PNG per named render when the runner
    /// exports `PANE_RENDER_DIR`; unset, a no-op.
    private func saveRenderForInspection(_ rep: NSBitmapImageRep, named name: String) {
        guard
            let dir = ProcessInfo.processInfo.environment["PANE_RENDER_DIR"],
            let png = rep.representation(using: .png, properties: [:])
        else { return }
        let directory = URL(fileURLWithPath: dir, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? png.write(to: directory.appendingPathComponent("\(name).png"))
    }
}
