import AppKit

/// Paints `PredictiveEchoModel.drawn` above a SwiftTerm view: each predicted
/// character at its cell, faintly underlined so a prediction reads as one.
/// Transparent, hidden whenever there is nothing to draw, and invisible to
/// hit-testing — the terminal underneath keeps every click. It never touches
/// the terminal buffer; it only draws over it.
///
/// Row math mirrors SwiftTerm's `drawTerminalContents`: row 0 is the top
/// cell row, a line's origin is `height - (row + 1) * cellHeight`, and the
/// baseline sits `ceil(descent + leading)` above that — so a prediction lands
/// on the pixels the real glyph will take when its echo arrives.
final class PredictiveEchoOverlayView: NSView {
    private(set) var predictions: [PredictiveEchoModel.Prediction] = []
    private var cols = 0
    private var rows = 0
    private var cellSize: CGSize?
    private var font: NSFont = .monospacedSystemFont(ofSize: 13, weight: .regular)
    private var color: NSColor = .secondaryLabelColor

    override init(frame: NSRect) {
        super.init(frame: frame)
        isHidden = true
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Stores what to draw and asks for a redraw. `cellSize` is the real cell
    /// geometry when the caller knows it; otherwise the cells divide the
    /// bounds evenly, which drifts by up to a cell at the far edge.
    func render(
        _ predictions: [PredictiveEchoModel.Prediction],
        cols: Int,
        rows: Int,
        font: NSFont,
        color: NSColor,
        cellSize: CGSize? = nil
    ) {
        self.predictions = predictions
        self.cols = cols
        self.rows = rows
        self.font = font
        self.color = color
        self.cellSize = cellSize
        isHidden = predictions.isEmpty
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !predictions.isEmpty, cols > 0, rows > 0,
              let context = NSGraphicsContext.current?.cgContext
        else { return }
        let cellW = cellSize?.width ?? bounds.width / CGFloat(cols)
        let cellH = cellSize?.height ?? bounds.height / CGFloat(rows)
        let baselineOffset = ceil(CTFontGetDescent(font) + CTFontGetLeading(font))
        let underlineY = font.underlinePosition
        let underlineH = max(font.underlineThickness, 1)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]

        context.saveGState()
        context.textMatrix = .identity
        for p in predictions where p.row < rows && p.col < cols {
            let x = CGFloat(p.col) * cellW
            let lineOrigin = bounds.height - CGFloat(p.row + 1) * cellH
            let baseline = lineOrigin + baselineOffset
            let line = CTLineCreateWithAttributedString(
                NSAttributedString(string: String(p.character), attributes: attributes)
            )
            context.textPosition = CGPoint(x: x, y: baseline)
            CTLineDraw(line, context)
            context.setFillColor(color.withAlphaComponent(0.55).cgColor)
            context.fill(CGRect(x: x, y: baseline + underlineY, width: cellW, height: underlineH))
        }
        context.restoreGState()
    }
}
