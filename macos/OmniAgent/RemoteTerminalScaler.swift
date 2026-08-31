import CoreGraphics
import Foundation

/// How a viewer draws a session whose grid belongs to the other Mac.
///
/// Remote session control phase 2, §1 "Terminal sizing": a session is one
/// program painting one screen buffer of N columns × M rows, and its updates
/// are absolute — so the grid cannot be re-laid-out for a second window, and
/// the only honest way to give a viewer its own column count is to resize the
/// shared PTY, which is exactly the defect this phase removes. The grid
/// therefore belongs to the host, and the viewer shows all of it by scaling:
/// the terminal view keeps the frame that its own `bounds ÷ cell` arithmetic
/// turns back into the host's cols and rows, and the container around it is
/// scaled into the space the pane has.
///
/// Pure geometry — no view, no SwiftTerm — so the arithmetic is testable on
/// its own and `TerminalSurfaceView` is left with nothing but applying it.
struct RemoteTerminalScaler: Equatable {
    /// One pane's answer: the size to give the terminal, what to multiply it
    /// by, and where to put it.
    struct Fit: Equatable {
        /// The host's grid at its true size, in points (`cols × cellW` by
        /// `rows × cellH`) — the frame the terminal view must have for
        /// SwiftTerm to compute the host's numbers rather than the viewer's.
        let terminalSize: CGSize
        /// What that size is multiplied by on screen. A fit never magnifies
        /// (ceiling 1); `zoom` overrides it up to ``maxZoom``.
        let scale: CGFloat
        /// Where the grid sits in the pane **at its true size**, centred and
        /// never negative — so a grid wider than the pane starts at the
        /// corner and is shrunk by `scale` instead of hanging off the edge.
        /// Once `scale` has shrunk it the view letterboxes the remainder,
        /// which is never above this origin.
        let origin: CGPoint
    }

    /// `0` means "fit the pane". Anything above overrides the fit and is
    /// clamped to *the fit*...``maxZoom`` — ⌘+ / ⌘− set it, ⌘0 clears it.
    var zoom: CGFloat = 0

    /// "Scale ceiling 2.0, floor is fit-to-pane" (spec §1). There is no
    /// absolute floor: below the fit a viewer would be shrinking the host's
    /// screen inside a pane that already shows all of it, which is nothing
    /// anybody asked for — so ⌘− stops at the whole screen.
    static let maxZoom: CGFloat = 2

    static func fit(hostCols: Int, hostRows: Int, cell: CGSize, pane: CGSize, zoom: CGFloat) -> Fit {
        let width = CGFloat(max(0, hostCols)) * max(0, cell.width)
        let height = CGFloat(max(0, hostRows)) * max(0, cell.height)
        // A grid or a cell we do not have yet — a pane whose first
        // `SessionResized` has not arrived, a terminal asked before it has a
        // font, a pane laid out at zero — draws the pane as it is rather than
        // dividing by zero.
        guard width > 0, height > 0, pane.width > 0, pane.height > 0 else {
            return Fit(terminalSize: pane, scale: 1, origin: .zero)
        }
        let fitted = min(1, min(pane.width / width, pane.height / height))
        return Fit(
            terminalSize: CGSize(width: width, height: height),
            scale: zoom > 0 ? min(max(zoom, fitted), maxZoom) : fitted,
            origin: CGPoint(
                x: max(0, (pane.width - width) / 2),
                y: max(0, (pane.height - height) / 2)
            )
        )
    }

    /// One press of ⌘+ or ⌘−.
    ///
    /// `current` is the scale on screen right now, so the first press
    /// magnifies what the eye can see: stepping `zoom` itself would multiply
    /// its "fit the pane" 0 by 1.25 and stay at the fit forever. `fitted` is
    /// the floor — ⌘− walks back down to the whole screen and stops there,
    /// which is also the only way back to the fit if ⌘0 is ever unreachable.
    mutating func stepZoom(by factor: CGFloat, from current: CGFloat, fit fitted: CGFloat) {
        zoom = min(max((zoom > 0 ? zoom : current) * factor, fitted), Self.maxZoom)
    }

    /// ⌘0: back to whatever fits. Deliberately `0` rather than the fit's
    /// current value — the pane keeps fitting as it is resized.
    mutating func resetZoom() {
        zoom = 0
    }
}
