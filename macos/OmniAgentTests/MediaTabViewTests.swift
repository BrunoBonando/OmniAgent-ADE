import PDFKit
import XCTest
@testable import OmniAgent

final class MediaTabViewTests: XCTestCase {
    func testCaption() {
        XCTAssertEqual(MediaTabView.caption(pixelsWide: 1024, pixelsHigh: 768, byteCount: 2_097_152), "1024 × 768 · 2.1 MB")
    }

    func testPlaceholder() {
        XCTAssertEqual(MediaTabView.placeholderText(name: "a.bin", byteCount: 12_288), "a.bin — binary file, 12 KB")
    }

    func testShowImageOffscreen() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("dot.png")
        let image = NSImage(size: NSSize(width: 4, height: 4), flipped: false) { rect in
            NSColor.systemRed.setFill(); rect.fill(); return true
        }
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let png = try XCTUnwrap(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        try png.write(to: url)

        let view = MediaTabView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        view.show(url: url, kind: .image)
        view.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        XCTAssertGreaterThan(rep.pixelsWide, 0)
    }

    func testShowPDFSwapsResponder() {
        let view = MediaTabView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        let document = PDFDocument()
        // An empty PDFDocument written to disk is still a valid PDF file.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).pdf")
        document.write(to: url)
        view.show(url: url, kind: .pdf)
        XCTAssertTrue(view.preferredResponder is PDFView)
    }
}
