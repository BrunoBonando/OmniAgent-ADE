import CoreGraphics
import Foundation

/// The rung past the last one `PaneGrid` can fill with comfortable cells: one
/// pane at full size, and every other pane as a chip in a rail down the left
/// that scrolls.
///
/// It exists because the ladder runs out of ways to be honest. `PaneGrid`
/// trades columns for rows when the panes would be too narrow to wrap a line of
/// agent output in (`comfortablePaneWidth`), but rows have a floor of their own
/// — a terminal that cannot show a command and its answer at once is no more
/// use than one forty characters wide — and past that floor there is no
/// rectangle left that fits. Rather than keep shrinking, the workspace stops
/// tiling: the pane you are reading gets the whole width, the rest wait in the
/// rail, and the space that would have been squeezed out of them becomes
/// scroll (founder brief, 2026-08-20).
///
/// Pure geometry, exactly like `PaneGrid.layout(in:dividerThickness:)`, in the
/// same flipped space — row 0 at the top — so the whole rule is testable
/// without a window.
struct PaneFilmstrip {
    struct Item: Equatable {
        let id: String
        let frame: CGRect
    }

    struct Layout: Equatable {
        /// The pane at full size.
        let hero: CGRect
        /// Every other pane, top to bottom in pane order, already offset by
        /// `scroll`. Items above or below `railBounds` keep their frames —
        /// clipping is the view's job, not this calculation's.
        let rail: [Item]
        /// The rail's viewport: what the wheel scrolls the items through.
        let railBounds: CGRect
        /// How tall the rail's contents are in total.
        let contentHeight: CGFloat
        /// The offset actually applied, which is `scroll` clamped to
        /// `maxScroll` — the view stores this back, so a rail that shortens
        /// under a scrolled offset does not strand its last item off-screen.
        let scroll: CGFloat

        var maxScroll: CGFloat { max(0, contentHeight - railBounds.height) }

        /// The rail item under a point, or `nil` — the click that promotes a
        /// chip to hero. Bounded by `railBounds` as well as by the item, so a
        /// click on the part of an item scrolled past the rail's edge does
        /// nothing, the way a click outside a scroll view's clip does.
        func railPane(at point: CGPoint) -> String? {
            guard railBounds.contains(point) else { return nil }
            return rail.first { $0.frame.contains(point) }?.id
        }
    }

    static func layout(
        ids: [String],
        hero: String,
        in bounds: CGRect,
        railWidth: CGFloat,
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
        let heroFrame = CGRect(
            x: bounds.minX + railWidth + gap,
            y: bounds.minY,
            width: max(0, bounds.width - railWidth - gap),
            height: bounds.height
        )
        let members = ids.filter { $0 != hero }
        // Each chip is the hero's own shape at the rail's width rather than a
        // fixed tile: what the rail shows is *this pane, made small*, and a
        // miniature that does not share the aspect ratio of the thing it stands
        // for is a different picture, not a smaller one.
        let itemHeight = heroFrame.width > 0
            ? (railWidth * heroFrame.height / heroFrame.width).rounded()
            : railWidth
        let contentHeight = members.isEmpty
            ? 0
            : CGFloat(members.count) * itemHeight + CGFloat(members.count - 1) * gap
        let clamped = min(max(0, scroll), max(0, contentHeight - railBounds.height))
        let rail = members.enumerated().map { index, id in
            Item(id: id, frame: CGRect(
                x: railBounds.minX,
                y: railBounds.minY + CGFloat(index) * (itemHeight + gap) - clamped,
                width: railWidth,
                height: itemHeight
            ))
        }
        return Layout(
            hero: heroFrame,
            rail: rail,
            railBounds: railBounds,
            contentHeight: contentHeight,
            scroll: clamped
        )
    }
}
