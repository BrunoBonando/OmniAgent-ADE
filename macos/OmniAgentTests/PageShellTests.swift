import XCTest
@testable import OmniAgent

/// `PageShellView` — the frame every page destination wears (title, optional
/// tab strip, optional trailing accessory, scrolling body). Spec §5,
/// `docs/superpowers/specs/2026-09-01-flow-layout-design.md`.
final class PageShellTests: XCTestCase {
    private func makeShell(title: String = "Insights", tabs: [String] = ["Usage", "Activity"]) -> PageShellView {
        let body = NSView()
        body.translatesAutoresizingMaskIntoConstraints = false
        body.heightAnchor.constraint(equalToConstant: 300).isActive = true
        return PageShellView(title: title, tabs: tabs, body: body)
    }

    /// `PageShellView` has no superview in these tests, so its own frame
    /// stands in for what a real window would otherwise constrain it to —
    /// Auto Layout needs real numbers to resolve tab widths and the underline
    /// against.
    private func layout(_ shell: PageShellView, width: CGFloat = 900, height: CGFloat = 600) {
        shell.frame = NSRect(x: 0, y: 0, width: width, height: height)
        shell.layoutSubtreeIfNeeded()
    }

    func testTheTitleReadsBack() {
        let shell = makeShell(title: "Insights")
        XCTAssertEqual(shell.titleField.stringValue, "Insights")
    }

    func testPressingATabFiresAndMovesTheUnderline() {
        let shell = makeShell()
        var selected: Int?
        shell.onSelectTab = { selected = $0 }
        shell.tabButtons[1].onPress?()
        layout(shell)
        XCTAssertEqual(selected, 1)
        XCTAssertEqual(shell.selectedTab, 1)
        XCTAssertEqual(shell.underline.frame.midX, shell.tabButtons[1].frame.midX, accuracy: 0.5)
    }

    func testSelectTabMovesTheUnderlineWithoutFiring() {
        let shell = makeShell()
        var fired = false
        shell.onSelectTab = { _ in fired = true }
        shell.select(tab: 1)
        layout(shell)
        XCTAssertEqual(shell.selectedTab, 1)
        XCTAssertEqual(shell.underline.frame.midX, shell.tabButtons[1].frame.midX, accuracy: 0.5)
        XCTAssertFalse(fired)
    }

    func testTheAccessorySitsFortyPointsInFromTheHeadersTrailingEdge() {
        let shell = makeShell()
        let accessory = NSView()
        accessory.translatesAutoresizingMaskIntoConstraints = false
        accessory.widthAnchor.constraint(equalToConstant: 80).isActive = true
        accessory.heightAnchor.constraint(equalToConstant: 24).isActive = true
        shell.trailingAccessory = accessory
        layout(shell)
        XCTAssertEqual(accessory.frame.maxX, shell.header.frame.maxX - 40, accuracy: 0.5)
    }

    /// Repo convention: verify AppKit layout by offscreen render. A crash or
    /// a zero-size layout fails loudly here; `PANE_RENDER_DIR` drops a PNG
    /// for inspection.
    func testPageShellRendersOffscreen() throws {
        let shell = makeShell()
        shell.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800))
        container.addSubview(shell)
        NSLayoutConstraint.activate([
            shell.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            shell.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            shell.topAnchor.constraint(equalTo: container.topAnchor),
            shell.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
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
        saveRenderForInspection(bitmap, named: "page-shell")
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
