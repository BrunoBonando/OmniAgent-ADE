import Foundation

/// What travels on the pasteboard when a tab is dragged: which pane it left
/// and which index it held. The tab itself stays in the source model until
/// the drop commits — a cancelled drag must change nothing.
///
/// Deliberately *not* the tab's content or even its path: the destination
/// resolves the source pane by id and lifts the tab out of it at drop time,
/// so a strip that changed under a slow drag is read as it is now rather
/// than as it was when the drag started.
struct EditorTabDragPayload: Equatable, Codable {
    var paneID: String
    var index: Int

    func pasteboardString() -> String? {
        (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) }
    }

    static func decode(_ string: String?) -> EditorTabDragPayload? {
        guard let string, let data = string.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(EditorTabDragPayload.self, from: data)
    }
}

/// Where inside a pane a tab drop lands. The outer 25% bands are the
/// grid-faithful "edge split": left/top insert the new pane before the target
/// in grid order, right/bottom after; the ladder re-lays out. Everything
/// inside is a plain move into that pane's strip.
///
/// **Coordinate space:** `point` and `bounds` come from `PaneContainerView`,
/// which is **flipped** — `minY` is the pane's *top* edge on screen, so the
/// small-y band is `.insertBefore`. Both are in the same space; nothing here
/// assumes `bounds.origin` is zero.
enum EditorTabDropZone: Equatable {
    case center
    case insertBefore
    case insertAfter

    static func zone(at point: CGPoint, in bounds: CGRect) -> EditorTabDropZone {
        // A zero-size pane has no edges, and the divisions below would be NaN.
        guard bounds.width > 0, bounds.height > 0 else { return .center }
        let x = (point.x - bounds.minX) / bounds.width
        let y = (point.y - bounds.minY) / bounds.height
        // Horizontal first, so a corner resolves to the left/right split: a
        // pane is wider than it is tall on every rung of the ladder, which
        // makes the vertical bands the narrower — and the less likely to be
        // what the pointer meant.
        if x < 0.25 { return .insertBefore }
        if x > 0.75 { return .insertAfter }
        if y < 0.25 { return .insertBefore }
        if y > 0.75 { return .insertAfter }
        return .center
    }
}

/// Which side of an existing pane a new one is inserted on, in grid order.
enum PaneInsertPosition {
    case before
    case after
}
