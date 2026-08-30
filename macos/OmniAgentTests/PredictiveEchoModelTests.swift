import AppKit
import XCTest
@testable import OmniAgent

final class PredictiveEchoModelTests: XCTestCase {
    func testFirstKeystrokeIsRecordedButNotDrawnUntilConfirmed() {
        var m = PredictiveEchoModel(); m.syncCursor(row: 0, col: 0)
        m.predict([UInt8(ascii: "a")], now: 0, cols: 80)
        XCTAssertEqual(m.pending.count, 1); XCTAssertTrue(m.drawn.isEmpty)
        m.reconcile(now: 0.1) { r, c in (r, c) == (0, 0) ? "a" : nil }
        XCTAssertEqual(m.confidence, .confirmed); XCTAssertTrue(m.pending.isEmpty)
        m.predict([UInt8(ascii: "b")], now: 0.2, cols: 80)
        XCTAssertEqual(m.drawn.map(\.character), ["b"]); XCTAssertEqual(m.drawn[0].col, 1)
    }
    func testMismatchClearsEverythingAndResetsConfidence() {
        var m = confirmedModel()
        m.predict([UInt8(ascii: "x")], now: 1, cols: 80)
        m.reconcile(now: 1.1) { _, _ in "y" }
        XCTAssertTrue(m.pending.isEmpty); XCTAssertEqual(m.confidence, .unknown)
    }
    func testControlBytesAndEscapeSequencesClear() {
        var m = confirmedModel()
        m.predict([UInt8(ascii: "x")], now: 1, cols: 80)
        m.predict([0x1b, 0x5b, 0x41], now: 1.1, cols: 80)   // arrow up
        XCTAssertTrue(m.pending.isEmpty); XCTAssertEqual(m.confidence, .unknown)
        m = confirmedModel(); m.predict([0x0d], now: 1, cols: 80)   // Enter is never predicted
        XCTAssertTrue(m.pending.isEmpty)
    }
    func testTimeoutClears() {
        var m = confirmedModel()
        m.predict([UInt8(ascii: "x")], now: 1, cols: 80)
        m.reconcile(now: 2.5) { _, _ in nil }
        XCTAssertTrue(m.pending.isEmpty); XCTAssertEqual(m.confidence, .unknown)
    }
    func testUnechoedCellsKeepPredictionsWaiting() {
        var m = confirmedModel()
        m.predict([UInt8(ascii: "x")], now: 1, cols: 80)
        m.reconcile(now: 1.2) { _, _ in nil }
        XCTAssertEqual(m.pending.count, 1); XCTAssertEqual(m.confidence, .confirmed)
    }
    func testBackspaceOnlyUndoesOwnPredictions() {
        var m = confirmedModel()
        m.predict([UInt8(ascii: "x")], now: 1, cols: 80)
        m.predict([0x7f], now: 1.1, cols: 80)
        XCTAssertTrue(m.pending.isEmpty); XCTAssertEqual(m.confidence, .confirmed)
        m.predict([0x7f], now: 1.2, cols: 80)   // nothing of ours to undo → unknown
        XCTAssertEqual(m.confidence, .unknown)
    }
    func testWrapsAtLineEnd() {
        var m = confirmedModel(); m.syncCursor(row: 3, col: 79)
        m.predict([UInt8(ascii: "x")], now: 1, cols: 80); m.predict([UInt8(ascii: "y")], now: 1, cols: 80)
        XCTAssertEqual(m.pending.map { [$0.row, $0.col] }, [[3, 79], [4, 0]])
    }
    private func confirmedModel() -> PredictiveEchoModel {
        var m = PredictiveEchoModel(); m.syncCursor(row: 0, col: 0)
        m.predict([UInt8(ascii: "a")], now: 0, cols: 80)
        m.reconcile(now: 0.1) { _, _ in "a" }
        return m
    }

    // MARK: - Overlay

    /// The glyph lands inside its own cell and nowhere else — the overlay
    /// mirrors SwiftTerm's row math (row 0 at the top), so a prediction drawn
    /// one row off would be the bug this pins.
    func testOverlayDrawsTheGlyphInsideItsCell() throws {
        let overlay = PredictiveEchoOverlayView(frame: NSRect(x: 0, y: 0, width: 160, height: 80))
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        XCTAssertTrue(overlay.isHidden, "nothing to draw yet")
        overlay.render(
            [.init(row: 1, col: 3, character: "W", madeAt: 0)],
            cols: 20, rows: 4, font: font, color: .white
        )
        XCTAssertFalse(overlay.isHidden)

        let rep = try XCTUnwrap(overlay.bitmapImageRepForCachingDisplay(in: overlay.bounds))
        overlay.cacheDisplay(in: overlay.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / overlay.bounds.width
        // Cell (row 1, col 3) is 8pt wide and 20pt tall, measured from the top.
        let cell = CGRect(x: 24, y: 20, width: 8, height: 20).insetBy(dx: -1, dy: -1)
        var inside = 0, outside = 0
        for py in 0..<rep.pixelsHigh {
            for px in 0..<rep.pixelsWide {
                guard let c = rep.colorAt(x: px, y: py), c.alphaComponent > 0.05 else { continue }
                let point = CGPoint(x: CGFloat(px) / scale, y: CGFloat(py) / scale)
                if cell.contains(point) { inside += 1 } else { outside += 1 }
            }
        }
        XCTAssertGreaterThan(inside, 0, "the glyph was drawn")
        XCTAssertEqual(outside, 0, "and only inside its cell")

        overlay.render([], cols: 20, rows: 4, font: font, color: .white)
        XCTAssertTrue(overlay.isHidden, "an empty prediction set hides the overlay")
    }

    func testOverlayNeverTakesTheClick() {
        let overlay = PredictiveEchoOverlayView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        overlay.render(
            [.init(row: 0, col: 0, character: "a", madeAt: 0)],
            cols: 10, rows: 5, font: .monospacedSystemFont(ofSize: 13, weight: .regular), color: .white
        )
        XCTAssertNil(overlay.hitTest(NSPoint(x: 5, y: 5)))
    }

    // MARK: - Hookup

    /// Off by default, and while off neither hook touches the model or the
    /// overlay — local panes must not change at all.
    func testSurfaceLeavesLocalPanesAlone() {
        let surface = makeSurface()
        XCTAssertFalse(surface.predictiveEchoEnabled)
        surface.send(source: surface.terminalView, data: ArraySlice(Array("a".utf8)))
        surface.feed(Data("a".utf8), isSnapshot: false)
        surface.send(source: surface.terminalView, data: ArraySlice(Array("b".utf8)))
        XCTAssertTrue(surface.echoOverlay.isHidden)
        XCTAssertTrue(surface.echoOverlay.predictions.isEmpty)
    }

    /// The first keystroke is not drawn; once its echo confirms, the next one
    /// is drawn at the cell right after the real cursor — and its own echo
    /// takes it down again. The terminal buffer is SwiftTerm's, fed real bytes.
    func testSurfacePredictsAfterTheFirstConfirmationAndClearsOnEcho() {
        let surface = makeSurface()
        surface.predictiveEchoEnabled = true

        surface.send(source: surface.terminalView, data: ArraySlice(Array("a".utf8)))
        XCTAssertTrue(surface.echoOverlay.predictions.isEmpty, "unknown confidence draws nothing")
        surface.feed(Data("a".utf8), isSnapshot: false)

        surface.send(source: surface.terminalView, data: ArraySlice(Array("b".utf8)))
        XCTAssertEqual(surface.echoOverlay.predictions.map(\.character), ["b"])
        XCTAssertEqual(surface.echoOverlay.predictions.first?.row, 0)
        XCTAssertEqual(surface.echoOverlay.predictions.first?.col, 1)
        XCTAssertFalse(surface.echoOverlay.isHidden)

        surface.feed(Data("b".utf8), isSnapshot: false)
        XCTAssertTrue(surface.echoOverlay.predictions.isEmpty)
        XCTAssertTrue(surface.echoOverlay.isHidden)

        surface.predictiveEchoEnabled = false
        surface.send(source: surface.terminalView, data: ArraySlice(Array("c".utf8)))
        XCTAssertTrue(surface.echoOverlay.predictions.isEmpty, "disabling stops predicting")
    }

    private func makeSurface() -> TerminalSurfaceView {
        let connection = SessionConnection(
            socketURL: URL(fileURLWithPath: "/tmp/omniagent-predictive-echo-test.sock")
        )
        let surface = TerminalSurfaceView(connection: connection, sessionID: "echo-1")
        surface.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        return surface
    }
}
