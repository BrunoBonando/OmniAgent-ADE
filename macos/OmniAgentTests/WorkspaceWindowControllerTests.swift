import XCTest
import MetalKit
import SwiftTerm
@testable import OmniAgent

final class WorkspaceWindowControllerTests: XCTestCase {
    func testWindowOwnsExactlyOneTerminalAndFocusReturnsToIt() {
        let connection = SessionConnection(
            socketURL: URL(fileURLWithPath: "/tmp/omniagent-controller-test.sock")
        )
        let controller = WorkspaceWindowController(
            connection: connection,
            sessionID: "native-terminal"
        )

        controller.showWindow(nil)
        let surfaces = controller.window?.contentView?.subviews.compactMap {
            $0 as? TerminalSurfaceView
        }
        XCTAssertEqual(surfaces?.count, 1)

        controller.focusTerminal(nil)
        XCTAssertTrue(controller.window?.firstResponder === surfaces?.first?.terminalView)
        controller.close()
    }

    func testTerminalPreservesComposedTextInsteadOfTreatingOptionAsMeta() {
        let surface = makeSurface()
        let delegate = RecordingTerminalDelegate()
        surface.terminalView.terminalDelegate = delegate

        surface.terminalView.insertText(
            "é",
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )

        XCTAssertFalse(surface.terminalView.optionAsMetaKey)
        XCTAssertEqual(delegate.bytes, Array("é".utf8))
    }

    func testOptionAsMetaHasVisibleNilTargetMenuCommandAndCheckedState() {
        ApplicationMenus.install()
        let command = NSApp.mainMenu?
            .item(withTitle: "Session")?
            .submenu?
            .item(withTitle: "Use Option as Meta")
        let surface = makeSurface()

        XCTAssertNotNil(command)
        XCTAssertNil(command?.target)
        XCTAssertEqual(command?.keyEquivalent, "o")
        XCTAssertEqual(command?.keyEquivalentModifierMask, [.command, .option])
        XCTAssertFalse(surface.terminalView.optionAsMetaKey)

        surface.terminalView.toggleOptionAsMeta(command)
        XCTAssertTrue(surface.terminalView.optionAsMetaKey)
        XCTAssertTrue(surface.terminalView.validateMenuItem(try! XCTUnwrap(command)))
        XCTAssertEqual(command?.state, .on)
    }

    func testTerminalExposesMinimumNativeAccessibilityContract() {
        let surface = makeSurface()
        surface.feed(Data("ready".utf8), isSnapshot: false)

        XCTAssertTrue(surface.terminalView.isAccessibilityElement())
        XCTAssertEqual(surface.terminalView.accessibilityRole(), .textArea)
        XCTAssertEqual(surface.terminalView.accessibilityLabel(), "Terminal")
        XCTAssertTrue((surface.terminalView.accessibilityValue() as? String)?.contains("ready") == true)
        XCTAssertTrue(surface.terminalView.accessibilityPerformPress())
    }

    func testFrameDecodeFeedAndRendererSubmissionBenchmark() throws {
        let (surface, window) = makeAttachedSurface()
        defer { window.close() }
        let encoded = try SessionFrame(
            kind: .output,
            requestOrSequence: 42,
            payload: RawPayload.encode(
                sessionID: "native-terminal",
                bytes: Data("\u{1b}[2J\u{1b}[Hbenchmark".utf8)
            )
        ).encoded()

        measure(metrics: [XCTClockMetric(), XCTCPUMetric()]) {
            for _ in 0..<100 {
                var decoder = FrameDecoder()
                let frame = try! XCTUnwrap(try! decoder.append(encoded).first)
                let raw = try! RawPayload.decode(frame.payload)
                surface.feed(
                    raw.bytes,
                    isSnapshot: false,
                    sequence: frame.requestOrSequence
                )
                _ = surface.submitRendererFrame()
            }
        }
    }

    func testAttachedMetalTerminalSubmitsThroughItsRendererWhenAvailable() throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal is unavailable on this host")
        }
        let (surface, window) = makeAttachedSurface()
        defer { window.close() }

        XCTAssertTrue(
            surface.terminalView.descendants.contains { $0 is MTKView },
            "Metal-capable attached terminal should own SwiftTerm's MTKView"
        )
        XCTAssertTrue(surface.submitRendererFrame())
    }

    private func makeSurface() -> TerminalSurfaceView {
        TerminalSurfaceView(
            connection: SessionConnection(
                socketURL: URL(fileURLWithPath: "/tmp/omniagent-controller-test.sock")
            ),
            sessionID: "native-terminal"
        )
    }

    private func makeAttachedSurface() -> (TerminalSurfaceView, NSWindow) {
        let surface = makeSurface()
        let window = WorkspaceWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = surface
        window.makeKeyAndOrderFront(nil)
        return (surface, window)
    }
}

private extension NSView {
    var descendants: [NSView] {
        subviews + subviews.flatMap(\.descendants)
    }
}

private final class RecordingTerminalDelegate: TerminalViewDelegate {
    var bytes: [UInt8] = []

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        bytes.append(contentsOf: data)
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
