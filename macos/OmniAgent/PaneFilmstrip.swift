import CoreGraphics
import Foundation

/// The rung past the last one `PaneGrid` can fill with comfortable cells: a
/// rail of cards down the left, and as many live panes beside it as will fit at
/// a usable size — often one, two or three when the window is tall enough.
///
/// It exists because the ladder runs out of ways to be honest. `PaneGrid`
/// trades columns for rows when the panes would be too narrow to wrap a line of
/// agent output in (`comfortablePaneWidth`), but rows have a floor of their own
/// — a terminal that cannot show a command and its answer at once is no more
/// use than one forty characters wide — and past that floor there is no
/// rectangle left that fits every pane. Rather than keep shrinking, the
/// workspace stops tiling: it shows as many panes as it can at full size and
/// the rest wait in the rail, one card each (founder brief, 2026-08-20).
///
/// Every pane has a card, **including the ones on screen** — those are drawn
/// selected rather than taken out, so the strip never shuffles under the
/// pointer and picking a pane is picking, not rearranging.
///
/// Pure geometry, exactly like `PaneGrid.layout(in:dividerThickness:)`, in the
/// same flipped space — row 0 at the top — so the whole rule is testable
/// without a window.
struct PaneFilmstrip {
    /// A card's height, fixed: it holds a mark, a name and an engine, none of
    /// which get more legible for being given more room. What the rail is a
    /// picture *of* changes; how big it is does not.
    static let itemHeight: CGFloat = 62

    struct Item: Equatable {
        let id: String
        let frame: CGRect
    }

    struct Layout: Equatable {
        /// The panes at full size, top to bottom. Never empty while there is a
        /// pane to show, and every frame the same size — a hero row is the
        /// unit this layout is measured in.
        let hero: [Item]
        /// Every pane, in pane order, already offset by `scroll`. Cards above
        /// or below `railBounds` keep their frames; clipping is the view's job,
        /// not this calculation's.
        let rail: [Item]
        /// The rail's viewport: what the wheel scrolls the cards through.
        let railBounds: CGRect
        /// How tall the rail's contents are in total.
        let contentHeight: CGFloat
        /// The offset actually applied, which is the requested one clamped to
        /// `maxScroll` — the view stores this back, so a rail that shortens
        /// under a scrolled offset does not strand its last card off-screen.
        let scroll: CGFloat

        var maxScroll: CGFloat { max(0, contentHeight - railBounds.height) }
        var heroIDs: [String] { hero.map(\.id) }

        /// The card under a point, or `nil`. Bounded by `railBounds` as well as
        /// by the card, so a click on the part of a card scrolled past the
        /// rail's edge does nothing, the way a click outside a scroll view's
        /// clip does.
        func railPane(at point: CGPoint) -> String? {
            guard railBounds.contains(point) else { return nil }
            return rail.first { $0.frame.contains(point) }?.id
        }

        /// The offset that brings one card fully inside the rail, or `nil` when
        /// it already is — what a focus command that ran off the visible end
        /// scrolls to.
        func scrollToShow(_ id: String) -> CGFloat? {
            guard let item = rail.first(where: { $0.id == id }) else { return nil }
            if item.frame.minY < railBounds.minY {
                return scroll - (railBounds.minY - item.frame.minY)
            }
            if item.frame.maxY > railBounds.maxY {
                return scroll + (item.frame.maxY - railBounds.maxY)
            }
            return nil
        }
    }

    /// `heroCount` panes at full size beside the rail, starting from
    /// `selected`. The window is shifted back at the end of the list rather
    /// than shortened — picking the last pane shows the last `heroCount`, so
    /// the column beside the rail is always as full as it can be.
    static func layout(
        ids: [String],
        selected: String,
        heroCount: Int,
        in bounds: CGRect,
        railWidth: CGFloat,
        itemHeight: CGFloat = PaneFilmstrip.itemHeight,
        gap: CGFloat,
        scroll: CGFloat
    ) -> Layout {
        let railWidth = max(0, min(railWidth, bounds.width - gap))
        let railBounds = CGRect(
            x: bounds.minX,
            y: bounds.minY,
            width: railWidth,
            height: bounds.height
        )
        let contentHeight = ids.isEmpty
            ? 0
            : CGFloat(ids.count) * itemHeight + CGFloat(ids.count - 1) * gap
        let clamped = min(max(0, scroll), max(0, contentHeight - railBounds.height))
        let rail = ids.enumerated().map { index, id in
            Item(id: id, frame: CGRect(
                x: railBounds.minX,
                y: railBounds.minY + CGFloat(index) * (itemHeight + gap) - clamped,
                width: railWidth,
                height: itemHeight
            ))
        }

        let heroX = bounds.minX + railWidth + gap
        let heroWidth = max(0, bounds.width - railWidth - gap)
        let rows = max(1, min(heroCount, ids.count))
        let rowHeight = (bounds.height - CGFloat(rows - 1) * gap) / CGFloat(rows)
        let anchor = ids.firstIndex(of: selected) ?? 0
        let start = max(0, min(anchor, ids.count - rows))
        let hero = (0..<rows).compactMap { row -> Item? in
            guard ids.indices.contains(start + row) else { return nil }
            // The last row is pinned to the bottom edge, the way `PaneGrid`
            // pins its last column: rounded rows otherwise leave a seam's worth
            // of background under the stack.
            let top = (bounds.minY + CGFloat(row) * (rowHeight + gap)).rounded()
            let bottom = row == rows - 1
                ? bounds.maxY
                : (bounds.minY + CGFloat(row) * (rowHeight + gap) + rowHeight).rounded()
            return Item(id: ids[start + row], frame: CGRect(
                x: heroX,
                y: top,
                width: heroWidth,
                height: max(0, bottom - top)
            ))
        }
        return Layout(
            hero: hero,
            rail: rail,
            railBounds: railBounds,
            contentHeight: contentHeight,
            scroll: clamped
        )
    }
}
