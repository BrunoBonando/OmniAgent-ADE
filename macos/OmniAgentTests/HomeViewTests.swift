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
    /// chip follows the selected workspace — with a calm fallback when none
    /// is selected.
    func testTheSuggestionsAndTheWorkspaceChip() {
        let home = makeHome()
        XCTAssertEqual(home.suggestionCards.count, 3)
        XCTAssertEqual(home.workspaceChipName.stringValue, "OmniAgent-ADE")

        home.refresh(workspaceID: nil, workspaceName: nil)
        XCTAssertEqual(home.workspaceChipName.stringValue, "No workspace")
    }

    /// A suggestion card and a pill wear the brighter fill under the pointer
    /// and put it back when it leaves; the pointer's paint never fires an
    /// effect because every press on this screen is an empty closure.
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

        // Inert by decision: pressing must be possible and must do nothing.
        card.onPress?()
        home.viewAllPill.onPress?()
        home.sendControl?.onPress?()
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
