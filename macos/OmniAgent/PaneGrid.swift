import Foundation

/// The native port of `ui/src/state/paneGrid.ts` — the founder's approved pane
/// ladder, its hole padding, and its two special-cased mutations, plus the
/// geometry the web build delegated to react-mosaic and the browser. One
/// deliberate divergence: `fillOrder` reads row-major here (`1 2 3 4 / 5 6 7
/// 8`) where the web build's `buildGrid` is still column-major — see
/// `fillOrder`'s own doc comment.
///
/// **Shape of the port.** The TypeScript oracle stores a react-mosaic tree
/// (`PaneTree`: a leaf id, or a row/column split). Every tree `buildGrid`
/// produces is a *complete rectangle* — a row split of `cols` column splits,
/// each `rows` tall, leftover cells padded with holes — so this port stores that
/// rectangle directly: `cols`, `rows`, and `cells` in column-major order. The
/// two are isomorphic: `cells` read in order is exactly the tree's depth-first
/// leaf order (`paneIds`), and the tree can be reconstructed from
/// `cols`/`rows`/`cells` at any time. Storing the rectangle rather than the tree
/// is what lets `layout(in:dividerThickness:)` calculate pane and divider frames
/// directly, which is Phase 4's requirement.
///
/// Split percentages the user dragged live here too, as `columnFractions` (one
/// per column, summing to 1) and `rowFractions` (one array per column, each
/// summing to 1) — the same independent-per-column split react-mosaic's nested
/// column nodes had.
enum PaneDirection: Equatable {
    case left
    case right
    case up
    case down
}

/// A cell of the rectangle: either a live pane, or `buildGrid`'s filler for a
/// cell no open session claims.
enum PaneCell: Equatable {
    case pane(String)
    case hole(Int)

    var id: String {
        switch self {
        case let .pane(id): return id
        case let .hole(index): return PaneGrid.holeID(index)
        }
    }

    var paneID: String? {
        if case let .pane(id) = self { return id }
        return nil
    }

    var isHole: Bool { paneID == nil }
}

/// `[cols, rows]` for a pane count — `gridShape`'s return value.
struct PaneGridShape: Equatable {
    let cols: Int
    let rows: Int
}

/// One draggable seam. `column`/`row` name the cell *before* the seam:
/// `.vertical` sits between `column` and `column + 1` (its `row` is unused and
/// reported as `-1`), `.horizontal` sits inside `column`, between `row` and
/// `row + 1`.
struct PaneDivider: Equatable {
    enum Axis: Equatable {
        case vertical
        case horizontal
    }

    let axis: Axis
    let column: Int
    let row: Int
    let frame: CGRect
}

/// Frames for every cell (holes included, so the rectangle stays complete) and
/// every seam, in the view's own flipped coordinate space — row 0 on top.
struct PaneLayout: Equatable {
    let frames: [String: CGRect]
    let dividers: [PaneDivider]
}

struct PaneGrid: Equatable {
    /// Prefix for a filler cell — never a real session id. Byte-identical to
    /// `paneGrid.ts`'s `HOLE_PREFIX` so the committed fixture reads the same on
    /// both sides.
    static let holePrefix = "__pane-hole-"

    /// `[cols, rows]`, ascending capacity. A grid is ALWAYS the first rung that
    /// fits its pane count (founder brief, 2026-07-26: "the only layouts
    /// possible are: 1, 1x2, 2x2, 2x3, 2x4"; extended 2026-08-18 with a third
    /// row on the widest rung: "3 rows and 4 columns").
    static let ladder: [PaneGridShape] = [
        PaneGridShape(cols: 1, rows: 1),
        PaneGridShape(cols: 2, rows: 1),
        PaneGridShape(cols: 2, rows: 2),
        PaneGridShape(cols: 3, rows: 2),
        PaneGridShape(cols: 4, rows: 2),
        PaneGridShape(cols: 4, rows: 3),
    ]

    /// Panes one workspace can hold — the last rung's capacity.
    static let maxPanes = 12

    /// The order cells are filled, as indices into `cells` (which is stored
    /// column-major): row by row, left to right within each row — so pane
    /// numbering (`paneIDs`, and the `⌘`-key hint it drives) reads the way a
    /// grid is read on screen: `1 2 3 4 / 5 6 7 8`.
    ///
    /// This is NOT free the way the old column-major fill was. Growing a rung
    /// by a COLUMN (4 panes -> 5, 6 -> 7) widens every row, so panes already in
    /// the last column shift down-left — e.g. opening a 5th pane turns what was
    /// pane "3" into pane "4". Only growing by a ROW (8 -> 9, the third-row
    /// rung) is still free: a new row appends after every earlier row's slots,
    /// so nothing already on screen moves (see `testGrowingIntoTheThirdRow…`
    /// in `PaneGridTests`). Bruno chose readable numbering over the stability
    /// guarantee (2026-08-26) — the old column-major fill (`1 3 5 7 / 2 4 6 8`)
    /// never reshuffled on ANY open/close; this trades that away for everything
    /// short of the 9th pane.
    ///
    /// Native-only: `paneGrid.ts` (the legacy web build, capped at 8 panes) still
    /// fills column-major and is not updated to match — `ui/` is frozen for new
    /// work (see the repo's `CLAUDE.md`), and porting this back would mean
    /// restructuring `buildGrid`'s row-split-of-column-splits mosaic tree into a
    /// column-split-of-row-splits, a bigger change than this native-only
    /// overlay feature needs. The committed fixture stays the TypeScript
    /// oracle's own truth unedited — every per-shape `pane_ids` entry is a
    /// round-trip identity (order-independent, so it holds either way), but
    /// `hole_repair.expected_pane_ids` IS fill-order-sensitive and is left at
    /// the column-major answer; `PaneGridTests.swift`'s fixture test asserts
    /// this side's own (different) answer for that one field inline instead of
    /// reading it off the fixture, rather than editing a file both ports share.
    static func fillOrder(cols: Int, rows: Int) -> [Int] {
        guard cols > 0, rows > 0 else { return [] }
        var order: [Int] = []
        order.reserveCapacity(cols * rows)
        for row in 0..<rows {
            for column in 0..<cols {
                order.append(column * rows + row)
            }
        }
        return order
    }

    private(set) var cols: Int
    private(set) var rows: Int
    /// Storage is column-major: column 0 top to bottom, then column 1, … The
    /// order panes are *seated* in is `fillOrder`, which reads row by row —
    /// see its doc comment for why storage order and seating order differ.
    private(set) var cells: [PaneCell]
    private(set) var columnFractions: [Double]
    private(set) var rowFractions: [[Double]]

    // MARK: - Construction

    private init(cols: Int, rows: Int, cells: [PaneCell]) {
        self.cols = cols
        self.rows = rows
        self.cells = cells
        columnFractions = Self.evenFractions(cols)
        rowFractions = Array(repeating: Self.evenFractions(rows), count: cols)
    }

    static func holeID(_ index: Int) -> String {
        "\(holePrefix)\(index)"
    }

    static func isHole(_ id: String) -> Bool {
        id.hasPrefix(holePrefix)
    }

    /// The approved shape for `count` panes. Past the cap it keeps the widest
    /// rung and grows rows rather than losing a live session (a restore of an
    /// older, uncapped workspace).
    ///
    /// `maxColumns` is the window talking back: a rung whose columns would be
    /// narrower than a terminal can comfortably wrap in is capped here and the
    /// rows grow to take the panes instead (founder brief, 2026-08-20: "if the
    /// terminal part feels squeezed, diminish the number of columns and
    /// increase the number of rows"). Unset it and this is the pure
    /// count-driven ladder the TypeScript oracle and the fixture pin.
    static func shape(count: Int, maxColumns: Int = .max) -> PaneGridShape {
        let rung = (ladder.first { $0.cols * $0.rows >= count } ?? ladder[ladder.count - 1]).cols
        let cols = max(1, min(rung, maxColumns))
        return PaneGridShape(cols: cols, rows: max(1, Int(ceil(Double(count) / Double(cols)))))
    }

    /// Arranges `ids` into their approved grid in `fillOrder`, padding leftover
    /// cells with holes — always the complete rung's rectangle, never a short
    /// row. The ONLY function here that decides a shape.
    static func build(_ ids: [String], maxColumns: Int = .max) -> PaneGrid? {
        guard !ids.isEmpty else { return nil }
        let shape = shape(count: ids.count, maxColumns: maxColumns)
        let order = fillOrder(cols: shape.cols, rows: shape.rows)
        var cells = [PaneCell](repeating: .hole(0), count: shape.cols * shape.rows)
        var holeIndex = 0
        for (slot, cell) in order.enumerated() {
            if slot < ids.count {
                cells[cell] = .pane(ids[slot])
            } else {
                cells[cell] = .hole(holeIndex)
                holeIndex += 1
            }
        }
        return PaneGrid(cols: shape.cols, rows: shape.rows, cells: cells)
    }

    /// Reconciles a grid against the desired set of open session ids — the one
    /// entry point the workspace uses for adds and closes. Mirrors
    /// `syncPaneTree`, including both of its special cases:
    ///
    /// - **2 -> 3**: the new pane lands LOWER-LEFT of the 2x2 rung; the two
    ///   existing panes stay on the top row and the hole becomes lower-right.
    ///   A plain `build` would put the newcomer top-right instead.
    /// - **1-for-1**: exactly one id out and one different id in is an in-place
    ///   replacement (an engine restart keeping its slot), not a
    ///   remove-then-append.
    ///
    /// Returns the grid unchanged — fractions and all — when membership has not
    /// moved, so a manual divider drag survives every sync that is not a real
    /// open or close.
    static func synced(_ grid: PaneGrid?, desiredIDs: [String]) -> PaneGrid? {
        let desired = Set(desiredIDs)
        let present = grid?.paneIDs() ?? []
        let presentSet = Set(present)
        let removed = present.filter { !desired.contains($0) }
        let added = desiredIDs.filter { !presentSet.contains($0) }

        if removed.isEmpty, added.isEmpty { return grid }
        if removed.isEmpty, added.count == 1, present.count == 2 {
            return PaneGrid(
                cols: 2,
                rows: 2,
                cells: [.pane(present[0]), .pane(added[0]), .pane(present[1]), .hole(0)]
            )
        }
        if removed.count == 1, added.count == 1, var replaced = grid {
            replaced.replace(removed[0], with: added[0])
            return replaced
        }
        return build(present.filter { desired.contains($0) } + added)
    }

    // MARK: - Identity

    /// Every real (non-hole) id, in `fillOrder` — row by row, left to right,
    /// top row first. This is what `⌘1…⌘0` select and what the shortcut hint
    /// numbers panes by (`AppDelegate.swift`'s Panes menu, `PaneWorkspaceView`).
    ///
    /// It has to be fill order rather than raw storage order: `synced` feeds
    /// this straight back into `build` on the next open, so any other order
    /// would rearrange the grid behind the user on a 3-row rung.
    func paneIDs() -> [String] {
        Self.fillOrder(cols: cols, rows: rows).compactMap { cells[$0].paneID }
    }

    func contains(_ id: String) -> Bool {
        cells.contains { $0.paneID == id }
    }

    func position(of id: String) -> (column: Int, row: Int)? {
        guard let index = cells.firstIndex(where: { $0.paneID == id }) else { return nil }
        return (index / rows, index % rows)
    }

    /// Swaps one leaf's id for another, keeping the rectangle, every other cell
    /// and every dragged fraction exactly as they were. No-op for an id that is
    /// not present.
    mutating func replace(_ old: String, with new: String) {
        guard let index = cells.firstIndex(where: { $0.paneID == old }) else { return }
        cells[index] = .pane(new)
    }

    /// Trades two panes' positions — the one rearrangement that cannot produce a
    /// grid `build` would not. Dropping a pane on itself, on a hole, or on an id
    /// that is not in the grid is a no-op.
    mutating func swap(_ a: String, _ b: String) {
        guard a != b,
              let first = cells.firstIndex(where: { $0.paneID == a }),
              let second = cells.firstIndex(where: { $0.paneID == b })
        else { return }
        cells.swapAt(first, second)
    }

    /// The pane one step `direction` from `id`, or `nil` at the edge — the grid
    /// never wraps.
    ///
    /// `paneGrid.ts` has no directional focus (the browser build had none), so
    /// this rule is derived from the rectangle: vertical moves walk rows inside
    /// the pane's own column and stop at the edge; horizontal moves walk columns
    /// and prefer the same row, falling back to the nearest real cell above (and
    /// then below) when that row is a hole — a hole is never a focus target, and
    /// holes only ever sit at the bottom of the last column.
    func neighbor(of id: String, direction: PaneDirection) -> String? {
        guard let (column, row) = position(of: id) else { return nil }
        switch direction {
        case .up, .down:
            let step = direction == .up ? -1 : 1
            var candidate = row + step
            while candidate >= 0, candidate < rows {
                if let pane = cells[column * rows + candidate].paneID { return pane }
                candidate += step
            }
            return nil
        case .left, .right:
            let step = direction == .left ? -1 : 1
            var candidate = column + step
            while candidate >= 0, candidate < cols {
                if let pane = nearestPane(inColumn: candidate, preferring: row) { return pane }
                candidate += step
            }
            return nil
        }
    }

    private func nearestPane(inColumn column: Int, preferring row: Int) -> String? {
        if let pane = cells[column * rows + row].paneID { return pane }
        for offset in 1..<max(rows, 1) {
            if row - offset >= 0, let pane = cells[column * rows + row - offset].paneID {
                return pane
            }
            if row + offset < rows, let pane = cells[column * rows + row + offset].paneID {
                return pane
            }
        }
        return nil
    }

    // MARK: - Geometry

    /// Pane and divider frames, calculated directly — no Auto Layout, no
    /// intermediate container views. Edges are rounded to whole points and the
    /// last edge is pinned to the content extent, so the panes tile `bounds`
    /// exactly and no pane draws on a half-pixel.
    func layout(in bounds: CGRect, dividerThickness: CGFloat) -> PaneLayout {
        let contentWidth = max(0, bounds.width - CGFloat(cols - 1) * dividerThickness)
        let contentHeight = max(0, bounds.height - CGFloat(rows - 1) * dividerThickness)
        let columnEdges = Self.edges(fractions: columnFractions, extent: contentWidth)

        var frames: [String: CGRect] = [:]
        var dividers: [PaneDivider] = []
        for column in 0..<cols {
            let x = bounds.minX + columnEdges[column] + CGFloat(column) * dividerThickness
            let width = columnEdges[column + 1] - columnEdges[column]
            let rowEdges = Self.edges(fractions: rowFractions[column], extent: contentHeight)
            for row in 0..<rows {
                let y = bounds.minY + rowEdges[row] + CGFloat(row) * dividerThickness
                let height = rowEdges[row + 1] - rowEdges[row]
                frames[cells[column * rows + row].id] = CGRect(
                    x: x,
                    y: y,
                    width: width,
                    height: height
                )
                if row < rows - 1 {
                    dividers.append(
                        PaneDivider(
                            axis: .horizontal,
                            column: column,
                            row: row,
                            frame: CGRect(x: x, y: y + height, width: width, height: dividerThickness)
                        )
                    )
                }
            }
            if column < cols - 1 {
                dividers.append(
                    PaneDivider(
                        axis: .vertical,
                        column: column,
                        row: -1,
                        frame: CGRect(
                            x: x + width,
                            y: bounds.minY,
                            width: dividerThickness,
                            height: bounds.height
                        )
                    )
                )
            }
        }
        return PaneLayout(frames: frames, dividers: dividers)
    }

    /// Slides one seam by `delta` points, clamped so neither neighbour drops
    /// below `minimumPaneSize`. Only the two cells the seam separates move —
    /// a vertical seam resizes its two columns, a horizontal seam resizes two
    /// rows inside its own column.
    mutating func moveDivider(
        _ divider: PaneDivider,
        by delta: CGFloat,
        in bounds: CGRect,
        dividerThickness: CGFloat,
        minimumPaneSize: CGSize
    ) {
        switch divider.axis {
        case .vertical:
            let extent = max(0, bounds.width - CGFloat(cols - 1) * dividerThickness)
            columnFractions = Self.slide(
                columnFractions,
                at: divider.column,
                by: delta,
                extent: extent,
                minimum: minimumPaneSize.width
            )
        case .horizontal:
            guard rowFractions.indices.contains(divider.column) else { return }
            let extent = max(0, bounds.height - CGFloat(rows - 1) * dividerThickness)
            rowFractions[divider.column] = Self.slide(
                rowFractions[divider.column],
                at: divider.row,
                by: delta,
                extent: extent,
                minimum: minimumPaneSize.height
            )
        }
    }

    // MARK: - Fractions

    private static func evenFractions(_ count: Int) -> [Double] {
        guard count > 0 else { return [] }
        return Array(repeating: 1 / Double(count), count: count)
    }

    private static func edges(fractions: [Double], extent: CGFloat) -> [CGFloat] {
        var result: [CGFloat] = [0]
        var accumulated = 0.0
        for (index, fraction) in fractions.enumerated() {
            accumulated += fraction
            result.append(
                index == fractions.count - 1 ? extent : CGFloat((accumulated * Double(extent)).rounded())
            )
        }
        return result
    }

    private static func slide(
        _ fractions: [Double],
        at index: Int,
        by delta: CGFloat,
        extent: CGFloat,
        minimum: CGFloat
    ) -> [Double] {
        guard fractions.indices.contains(index), fractions.indices.contains(index + 1), extent > 0
        else { return fractions }
        let minimumFraction = Double(minimum / extent)
        let total = fractions[index] + fractions[index + 1]
        guard total >= 2 * minimumFraction else { return fractions }
        let moved = fractions[index] + Double(delta / extent)
        let clamped = min(max(moved, minimumFraction), total - minimumFraction)
        var updated = fractions
        updated[index] = clamped
        updated[index + 1] = total - clamped
        return updated
    }
}
