import XCTest
@testable import OmniAgent

/// The Home screen: the design's words, the interactive feel, and a layout
/// pass that must not throw the constraint engine. The controls hover, focus
/// and press like the real thing, and every press is deliberately inert
/// (2026-08-24) — so these tests assert the feel, never an effect.
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
        XCTAssertFalse(chip.isHidden, "no git still gets a chip")
        XCTAssertEqual(home.branchLabel.stringValue, "Set up GitHub")

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
    /// neither throws nor collapses. Drops a PNG when `PANE_RENDER_DIR` is
    /// set (`TEST_RUNNER_PANE_RENDER_DIR=/tmp/panes ./macos/build.sh test`).
    func testTheHomeScreenLaysOutOffscreen() throws {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 1280, height: 1900))
        let ground = PaneGroundView()
        let home = makeHome()
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
        defer { window.close() }
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = container
        container.layoutSubtreeIfNeeded()

        let bitmap = try XCTUnwrap(container.bitmapImageRepForCachingDisplay(in: container.bounds))
        container.cacheDisplay(in: container.bounds, to: bitmap)
        XCTAssertGreaterThan(bitmap.size.width, 0)
        saveRenderForInspection(bitmap, named: "home")
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
