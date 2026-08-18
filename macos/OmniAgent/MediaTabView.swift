import AppKit
import PDFKit

/// Native read-only preview for the tabs Monaco should never touch: images
/// (zoomable NSImageView over a checkerboard, with a dimensions·size caption)
/// and PDFs (PDFKit, which brings scroll/zoom/selection/⌘F for free). Also
/// renders the binary-file placeholder. All AppKit — the native-rule
/// exception stops at the Monaco surface.
final class MediaTabView: NSView {
    private let scroll = NSScrollView()
    private let imageView = NSImageView()
    private let pdfView = PDFView()
    private let captionField = NSTextField(labelWithString: "")
    private let placeholderField = NSTextField(labelWithString: "")

    /// The `PDFView` for PDFs (so ⌘F / selection / scroll keys land on it),
    /// `self` otherwise.
    var preferredResponder: NSView { pdfView.isHidden ? self : pdfView }

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    /// `ByteCountFormatter` follows `Locale.current`, which is what a caption
    /// beside every other number in the OS should do. It used to be forced to
    /// a "." decimal point so a test could compare the string verbatim; on a
    /// comma-decimal machine that made the caption the one thing on screen
    /// disagreeing with the rest of the system. The test is locale-tolerant
    /// instead.
    private static func formattedBytes(_ byteCount: Int) -> String {
        byteFormatter.string(fromByteCount: Int64(byteCount))
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = PaneContainerView.paneBackgroundColor.cgColor

        scroll.documentView = imageView
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = true
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.25
        scroll.maxMagnification = 8
        scroll.drawsBackground = true
        scroll.backgroundColor = NSColor(patternImage: Self.checkerboard())
        imageView.imageScaling = .scaleNone

        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous

        captionField.font = ShellFont.mono(11)
        captionField.textColor = .secondaryLabelColor
        captionField.alignment = .center
        captionField.lineBreakMode = .byTruncatingTail
        captionField.maximumNumberOfLines = 1

        placeholderField.font = ShellFont.ui(13)
        placeholderField.textColor = ShellPalette.inkMuted
        placeholderField.alignment = .center
        placeholderField.lineBreakMode = .byTruncatingTail
        placeholderField.maximumNumberOfLines = 1

        for view in [scroll, pdfView, captionField, placeholderField] { addSubview(view) }
        setVisible(image: false, pdf: false, placeholder: false)

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Media preview")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        applyLayout()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        applyLayout()
    }

    private func applyLayout() {
        scroll.frame = bounds
        pdfView.frame = bounds

        let captionSize = captionField.intrinsicContentSize
        captionField.frame = NSRect(
            x: (bounds.width - captionSize.width) / 2,
            y: bounds.height - captionSize.height - 10,
            width: min(captionSize.width, bounds.width),
            height: captionSize.height
        )

        let placeholderSize = placeholderField.intrinsicContentSize
        placeholderField.frame = NSRect(
            x: (bounds.width - placeholderSize.width) / 2,
            y: (bounds.height - placeholderSize.height) / 2,
            width: min(placeholderSize.width, bounds.width),
            height: placeholderSize.height
        )
    }

    /// `"1024 × 768 · 2.1 MB"` — dimensions in device pixels, then the file's
    /// on-disk size via the one shared formatter, so this and
    /// `placeholderText` always agree on what "2.1 MB" means.
    static func caption(pixelsWide: Int, pixelsHigh: Int, byteCount: Int) -> String {
        "\(pixelsWide) × \(pixelsHigh) · \(formattedBytes(byteCount))"
    }

    /// `"a.bin — binary file, 12 KB"`.
    static func placeholderText(name: String, byteCount: Int) -> String {
        "\(name) — binary file, \(formattedBytes(byteCount))"
    }

    /// A 16×16 two-tone tile, tiled by `NSColor(patternImage:)` behind a
    /// transparent image — the standard "this has alpha" checkerboard.
    static func checkerboard() -> NSImage {
        NSImage(size: NSSize(width: 16, height: 16), flipped: false) { _ in
            NSColor(white: 0.10, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: 16, height: 16).fill()
            NSColor(white: 0.14, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: 8, height: 8).fill()
            NSRect(x: 8, y: 8, width: 8, height: 8).fill()
            return true
        }
    }

    /// Loads `url` per `kind`: an image into the zoomable `NSImageView`, a
    /// PDF into `PDFView`, anything else (including plain `.text`/`.binary`
    /// misdirected here) as the binary placeholder.
    func show(url: URL, kind: EditorFileClass) {
        let byteCount = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0
        switch kind {
        case .image:
            let image = NSImage(contentsOf: url)
            imageView.image = image
            let rep = image?.representations.first
            let pixelsWide = rep?.pixelsWide ?? Int(image?.size.width ?? 0)
            let pixelsHigh = rep?.pixelsHigh ?? Int(image?.size.height ?? 0)
            imageView.frame = NSRect(
                origin: .zero,
                size: NSSize(width: max(1, pixelsWide), height: max(1, pixelsHigh))
            )
            captionField.stringValue = Self.caption(pixelsWide: pixelsWide, pixelsHigh: pixelsHigh, byteCount: byteCount)
            setVisible(image: true, pdf: false, placeholder: false)
        case .pdf:
            pdfView.document = PDFDocument(url: url)
            setVisible(image: false, pdf: true, placeholder: false)
        case .text, .binary:
            placeholderField.stringValue = Self.placeholderText(name: url.lastPathComponent, byteCount: byteCount)
            setVisible(image: false, pdf: false, placeholder: true)
        }
        needsLayout = true
    }

    private func setVisible(image: Bool, pdf: Bool, placeholder: Bool) {
        scroll.isHidden = !image
        captionField.isHidden = !image
        pdfView.isHidden = !pdf
        placeholderField.isHidden = !placeholder
    }
}
