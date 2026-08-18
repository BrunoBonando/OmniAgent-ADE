import AppKit

/// What a pane holds. `Engine` says which *process* a terminal runs; kind says
/// whether there is a process at all. Browser and editor are kinds, never an
/// `Engine` case — `EngineLauncher`'s exhaustive switches stay closed.
enum PaneKind: String, Equatable {
    case terminal
    case browser
    case editor
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

/// The `.editor` surface until Task 9 builds `EditorPaneView` and Task 10
/// wires it in. No entry point creates an `.editor` pane yet, so this exists
/// solely to keep `PaneKind`'s exhaustive switches (the surface factory in
/// `WorkspaceWindowController` chief among them) compiling — every use of it
/// is meant to be replaced, not extended.
final class EditorPanePlaceholderView: NSView, PaneContentView {
    var isSelected: Bool = false
    var suspendsDrawing: Bool = false
    var resizeCoalescer: PaneResizeCoalescer?
    var primaryResponderView: NSView { self }
    func focus() {}
    func scheduleResize() {}
    func flushResize() {}
}
