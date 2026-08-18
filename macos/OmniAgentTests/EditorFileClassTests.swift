import XCTest
@testable import OmniAgent

final class EditorFileClassTests: XCTestCase {
    func testImagesAndPDFByExtension() {
        for ext in ["png", "jpg", "jpeg", "gif", "webp", "heic", "tif", "tiff", "icns", "bmp"] {
            XCTAssertEqual(EditorFileClass.classify(pathExtension: ext, size: 10, sniff: Data([0, 1])), .image, ext)
        }
        XCTAssertEqual(EditorFileClass.classify(pathExtension: "PDF", size: 10, sniff: Data([0])), .pdf)
    }

    func testSVGIsText() {
        XCTAssertEqual(
            EditorFileClass.classify(pathExtension: "svg", size: 10, sniff: Data("<svg/>".utf8)),
            .text(readOnly: false)
        )
    }

    func testNullByteMeansBinary() {
        XCTAssertEqual(EditorFileClass.classify(pathExtension: "dat", size: 10, sniff: Data([65, 0, 66])), .binary)
    }

    func testHugeTextOpensReadOnly() {
        XCTAssertEqual(
            EditorFileClass.classify(pathExtension: "log", size: EditorFileClass.maxEditableBytes + 1, sniff: Data("a".utf8)),
            .text(readOnly: true)
        )
    }

    func testTabKinds() {
        XCTAssertEqual(EditorFileClass.text(readOnly: false).tabKind, .file)
        XCTAssertEqual(EditorFileClass.image.tabKind, .media)
        XCTAssertEqual(EditorFileClass.pdf.tabKind, .media)
        XCTAssertEqual(EditorFileClass.binary.tabKind, .file)
    }

    func testFilesystemForm() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let text = dir.appendingPathComponent("a.swift")
        try "let x = 1".write(to: text, atomically: true, encoding: .utf8)
        XCTAssertEqual(EditorFileClass.classify(url: text), .text(readOnly: false))
        let binary = dir.appendingPathComponent("a.bin")
        try Data([1, 2, 0, 4]).write(to: binary)
        XCTAssertEqual(EditorFileClass.classify(url: binary), .binary)
    }
}
