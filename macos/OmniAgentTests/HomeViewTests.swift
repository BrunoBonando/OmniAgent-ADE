import XCTest
@testable import OmniAgent

/// The Home screen: the design's words and a layout pass that must not throw
/// the constraint engine. Deliberately no behavior tests — the screen is a
/// pure design surface for now (2026-08-22): nothing on it acts.
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
        let labels = allLabels(in: makeHome())
        for expected in [
            "Ask anything, or start a session. Use / for commands…",
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
