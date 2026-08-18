import Foundation

/// What a file is, for the purpose of opening it in an editor pane: editable
/// text (possibly read-only for size), a native image/PDF preview, or a
/// binary we can only describe. SVG is deliberately text — it is XML, and
/// that is VS Code's call too.
enum EditorFileClass: Equatable {
    case text(readOnly: Bool)
    case image
    case pdf
    case binary

    static let maxEditableBytes = 10 * 1024 * 1024
    static let sniffLength = 8 * 1024

    static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "tif", "tiff", "icns", "bmp",
    ]

    var tabKind: EditorTabKind {
        switch self {
        case .image, .pdf: return .media
        case .text, .binary: return .file
        }
    }

    /// Pure core. `sniff` is the file's first bytes; a null byte anywhere in
    /// them is the classic "not text" tell (git uses the same heuristic).
    static func classify(pathExtension: String, size: Int, sniff: Data) -> EditorFileClass {
        let ext = pathExtension.lowercased()
        if imageExtensions.contains(ext) { return .image }
        if ext == "pdf" { return .pdf }
        if sniff.contains(0) { return .binary }
        return .text(readOnly: size > maxEditableBytes)
    }

    /// Filesystem form: one stat and one bounded read. An unreadable file is
    /// `.binary` — the placeholder is the honest state for "cannot show this".
    static func classify(url: URL) -> EditorFileClass {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int ?? 0
        guard let handle = try? FileHandle(forReadingFrom: url) else { return .binary }
        defer { try? handle.close() }
        let sniff = (try? handle.read(upToCount: sniffLength)) ?? Data()
        return classify(pathExtension: url.pathExtension, size: size, sniff: sniff)
    }
}
