import AppKit

/// What a pane holds. `Engine` says which *process* a terminal runs; kind says
/// whether there is a process at all. Browser is a kind, never an `Engine`
/// case — `EngineLauncher`'s exhaustive switches stay closed.
enum PaneKind: String, Equatable {
    case terminal
    case browser
}

/// The container's real contract with its content — what PaneContainerView,
/// the resize coalescer and the focus machinery actually call. A terminal
/// implements all of it; a browser no-ops the PTY-shaped half.
protocol PaneContentView: NSView {
    var isSelected: Bool { get set }
    var suspendsDrawing: Bool { get set }
    var resizeCoalescer: PaneResizeCoalescer? { get set }
    /// The view keyboard focus should land on — what
    /// `window.initialFirstResponder` and `focus()` aim at.
    var primaryResponderView: NSView { get }
    func focus()
    func scheduleResize()
    func flushResize()
}
