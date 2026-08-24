import AppKit

/// What a pane holds. `Engine` says which *process* a terminal runs; kind says
/// whether there is a process at all. Browser and editor are kinds, never an
/// `Engine` case — `EngineLauncher`'s exhaustive switches stay closed.
enum PaneKind: String, Equatable {
    case terminal
    case browser
    case editor
}

/// Which way a terminal pane is being looked at. The PTY is the base either
/// way — App mode hides the terminal, it never ends it, so the scrollback, the
/// daemon attachment and the approval bar reading off the live screen all
/// carry on behind the chat. Deliberately not on `PaneDescriptor`: the mode is
/// not persisted in v1, and putting it there would couple it to the
/// restoration codecs for nothing gained.
enum PaneViewMode: String, Equatable {
    case terminal
    case app
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
