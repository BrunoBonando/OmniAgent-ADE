import AppKit
import QuartzCore
import os.signpost

/// One pane's identity and the metadata that travels with it — the native
/// equivalent of `TabInfo`'s `id` / `group` / `groupLabel`. Held in a dictionary
/// keyed by session id, so a pane keeps its grouping no matter which cell of the
/// rectangle it currently occupies.
struct PaneDescriptor: Equatable {
    let sessionID: String
    var group: String
    var groupLabel: String?
    var title: String
}

/// Batches PTY resizes so a live divider drag sends at most one `resize` per
/// display refresh. Frames move on every mouse event; the daemon hears about it
/// once per frame.
final class PaneResizeCoalescer {
    private(set) var pending: Set<String> = []
    private(set) var flushCount = 0
    var onSchedule: (() -> Void)?
    var onFlush: ((Set<String>) -> Void)?

    var hasPending: Bool { !pending.isEmpty }

    func schedule(_ sessionID: String) {
        pending.insert(sessionID)
        onSchedule?()
    }

    func cancel(_ sessionID: String) {
        pending.remove(sessionID)
    }

    @discardableResult
    func flush() -> Bool {
        guard !pending.isEmpty else { return false }
        let sessions = pending
        pending.removeAll()
        flushCount += 1
        onFlush?(sessions)
        return true
    }
}

/// The workspace content view: a `PaneGrid` rectangle of live terminals, laid
/// out by direct frame calculation.
///
/// Pane identity is a dictionary (`containers`) keyed by session id; the grid
/// only ever moves *ids* between cells. A reshape, a swap or a drop therefore
/// reframes existing `TerminalSurfaceView`s and never builds a new one — the
/// scrollback loss react-mosaic's path-keyed remounts caused (see
/// `paneGrid.ts`'s ponytail note) cannot happen here.
final class PaneWorkspaceView: NSView, NSMenuItemValidation {
    static let paneDragType = NSPasteboard.PasteboardType("digital.bruno.omniagent.pane")
    static let dividerThickness: CGFloat = 6
    static let minimumPaneSize = CGSize(width: 160, height: 96)

    private(set) var grid: PaneGrid?
    private(set) var focusedPaneID: String?
    let resizeCoalescer = PaneResizeCoalescer()

    /// Raised when a pane wants to exist or stop existing — the window
    /// controller owns session lifecycle, this view owns layout and identity.
    var onRequestNewPane: (() -> Void)?
    var onFocusedPaneChanged: ((String?) -> Void)?

    private let makeSurface: (String) -> TerminalSurfaceView
    private var containers: [String: PaneContainerView] = [:]
    private var descriptors: [String: PaneDescriptor] = [:]
    private var dividerViews: [PaneDividerView] = []
    /// One per hole cell — the empty cell of an incomplete rectangle, which
    /// doubles as the "Add Terminal" affordance exactly as the web grid's
    /// hole tile does.
    private(set) var holePlaceholders: [PaneHolePlaceholderView] = []
    private var resizeDisplayLink: CADisplayLink?
    private var asyncFlushScheduled = false
    private var occlusionObserver: NSObjectProtocol?
    private var suspendsDrawing = false

    init(makeSurface: @escaping (String) -> TerminalSurfaceView) {
        self.makeSurface = makeSurface
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(srgbRed: 4 / 255, green: 6 / 255, blue: 9 / 255, alpha: 1).cgColor
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Terminal panes")
        resizeCoalescer.onSchedule = { [weak self] in self?.resizeScheduled() }
        resizeCoalescer.onFlush = { [weak self] sessions in
            guard let self else { return }
            for session in sessions {
                containers[session]?.surface.flushResize()
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    /// Row 0 on top, matching `PaneGrid.layout(in:dividerThickness:)`.
    override var isFlipped: Bool { true }

    // MARK: - Reading the workspace

    var paneIDs: [String] { grid?.paneIDs() ?? [] }

    func descriptor(for sessionID: String) -> PaneDescriptor? { descriptors[sessionID] }

    func container(for sessionID: String) -> PaneContainerView? { containers[sessionID] }

    func surface(for sessionID: String) -> TerminalSurfaceView? { containers[sessionID]?.surface }

    // MARK: - Mutating the workspace

    /// Adds a pane and gives it focus. Refused past `PaneGrid.maxPanes`, and
    /// refused for a session id already on screen.
    @discardableResult
    func addPane(_ descriptor: PaneDescriptor) -> Bool {
        guard paneIDs.count < PaneGrid.maxPanes, descriptors[descriptor.sessionID] == nil else {
            return false
        }
        descriptors[descriptor.sessionID] = descriptor
        let container = PaneContainerView(
            paneID: descriptor.sessionID,
            surface: makeSurface(descriptor.sessionID),
            workspace: self
        )
        container.surface.resizeCoalescer = resizeCoalescer
        container.surface.suspendsDrawing = suspendsDrawing
        containers[descriptor.sessionID] = container
        addSubview(container)
        grid = PaneGrid.synced(grid, desiredIDs: paneIDs + [descriptor.sessionID])
        updateLayout()
        focusPane(descriptor.sessionID)
        return true
    }

    /// Removes a pane, reflowing the grid down a rung when the count drops. If
    /// the closed pane had focus, focus falls to its previous neighbour in fill
    /// order (its left/above sibling), else the next one.
    @discardableResult
    func closePane(_ sessionID: String) -> Bool {
        guard let container = containers[sessionID] else { return false }
        let successor = focusSuccessor(after: sessionID)
        resizeCoalescer.cancel(sessionID)
        container.removeFromSuperview()
        containers.removeValue(forKey: sessionID)
        descriptors.removeValue(forKey: sessionID)
        grid = PaneGrid.synced(grid, desiredIDs: paneIDs.filter { $0 != sessionID })
        updateLayout()
        if focusedPaneID == sessionID {
            focusedPaneID = nil
            if let successor {
                focusPane(successor)
            } else {
                updateFocusRings()
                onFocusedPaneChanged?(nil)
            }
        }
        return true
    }

    /// Trades two panes' cells. Everything else — the shape, every dragged
    /// fraction, both terminals — is untouched.
    @discardableResult
    func swapPanes(_ first: String, _ second: String) -> Bool {
        guard var grid, grid.contains(first), grid.contains(second), first != second else {
            return false
        }
        grid.swap(first, second)
        self.grid = grid
        updateLayout()
        return true
    }

    func updateDescriptor(for sessionID: String, _ mutate: (inout PaneDescriptor) -> Void) {
        guard var descriptor = descriptors[sessionID] else { return }
        mutate(&descriptor)
        descriptors[sessionID] = descriptor
        containers[sessionID]?.descriptorChanged(descriptor)
        updateAccessibilityLabels()
    }

    // MARK: - Focus

    func focusPane(_ sessionID: String) {
        guard containers[sessionID] != nil, grid?.contains(sessionID) == true else { return }
        let changed = focusedPaneID != sessionID
        focusedPaneID = sessionID
        updateFocusRings()
        containers[sessionID]?.surface.focus()
        if changed { onFocusedPaneChanged?(sessionID) }
    }

    /// Re-applies the focused pane's first-responder status — used on window
    /// activation, where AppKit restores the window but not our intent.
    func restoreFocus() {
        guard let focusedPaneID, containers[focusedPaneID] != nil else {
            if let first = paneIDs.first { focusPane(first) }
            return
        }
        containers[focusedPaneID]?.surface.focus()
    }

    /// Adopts the pane that actually holds the first responder — click-to-focus,
    /// routed through `WorkspaceWindow.makeFirstResponder`.
    func adoptFocus(from responder: NSResponder?) {
        var view = responder as? NSView
        while let current = view {
            if let container = current as? PaneContainerView {
                if focusedPaneID != container.paneID {
                    focusedPaneID = container.paneID
                    updateFocusRings()
                    onFocusedPaneChanged?(container.paneID)
                }
                return
            }
            view = current.superview
        }
    }

    @discardableResult
    func focusNeighbor(_ direction: PaneDirection) -> Bool {
        guard let focusedPaneID, let neighbor = grid?.neighbor(of: focusedPaneID, direction: direction)
        else { return false }
        focusPane(neighbor)
        return true
    }

    @discardableResult
    func swapWithNeighbor(_ direction: PaneDirection) -> Bool {
        guard let focusedPaneID, let neighbor = grid?.neighbor(of: focusedPaneID, direction: direction)
        else { return false }
        return swapPanes(focusedPaneID, neighbor)
    }

    /// 1-based, in fill order — what ⌘1…⌘8 select.
    @discardableResult
    func focusPane(at index: Int) -> Bool {
        let ids = paneIDs
        guard index >= 1, index <= ids.count else { return false }
        focusPane(ids[index - 1])
        return true
    }

    private func focusSuccessor(after sessionID: String) -> String? {
        let ids = paneIDs
        guard let index = ids.firstIndex(of: sessionID) else { return nil }
        if index > 0 { return ids[index - 1] }
        return index + 1 < ids.count ? ids[index + 1] : nil
    }

    private func updateFocusRings() {
        for (id, container) in containers {
            container.isFocused = id == focusedPaneID
        }
    }

    // MARK: - Drag and drop

    /// The one place a drop can mutate the grid: both ids must be live panes and
    /// they must differ.
    @discardableResult
    func performPaneDrop(from sourceID: String, onto targetID: String) -> Bool {
        guard canAcceptDrop(from: sourceID, onto: targetID) else { return false }
        let wasFocused = focusedPaneID
        guard swapPanes(sourceID, targetID) else { return false }
        if let wasFocused { focusPane(wasFocused) }
        return true
    }

    func canAcceptDrop(from sourceID: String, onto targetID: String) -> Bool {
        sourceID != targetID && grid?.contains(sourceID) == true && grid?.contains(targetID) == true
    }

    // MARK: - Occlusion

    /// Fully occluded panes stop asking for draws. Output keeps being parsed
    /// into SwiftTerm's bounded buffer, so nothing is lost and nothing grows
    /// without bound — only the drawing is skipped.
    func setSuspendsDrawing(_ suspends: Bool) {
        guard suspendsDrawing != suspends else { return }
        suspendsDrawing = suspends
        for container in containers.values {
            container.surface.suspendsDrawing = suspends
        }
    }

    // MARK: - Layout

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateLayout()
    }

    override func layout() {
        super.layout()
        updateLayout()
    }

    /// Applies the grid's calculated frames. Every pane whose frame actually
    /// moved schedules a coalesced PTY resize.
    func updateLayout() {
        guard let grid else {
            dividerViews.forEach { $0.removeFromSuperview() }
            dividerViews = []
            return
        }
        let layout = grid.layout(in: bounds, dividerThickness: Self.dividerThickness)
        for (id, container) in containers {
            guard let frame = layout.frames[id] else { continue }
            guard container.frame != frame else { continue }
            container.frame = frame
            container.surface.scheduleResize()
        }
        syncDividerViews(layout.dividers)
        syncHolePlaceholders(layout, holeIDs: grid.cells.filter(\.isHole).map(\.id))
        updateAccessibilityLabels()
    }

    private func syncHolePlaceholders(_ layout: PaneLayout, holeIDs: [String]) {
        while holePlaceholders.count > holeIDs.count {
            holePlaceholders.removeLast().removeFromSuperview()
        }
        while holePlaceholders.count < holeIDs.count {
            let placeholder = PaneHolePlaceholderView { [weak self] in self?.onRequestNewPane?() }
            holePlaceholders.append(placeholder)
            addSubview(placeholder, positioned: .below, relativeTo: subviews.first)
        }
        for (placeholder, id) in zip(holePlaceholders, holeIDs) {
            placeholder.frame = layout.frames[id] ?? .zero
        }
    }

    private func syncDividerViews(_ dividers: [PaneDivider]) {
        while dividerViews.count > dividers.count {
            dividerViews.removeLast().removeFromSuperview()
        }
        while dividerViews.count < dividers.count {
            let view = PaneDividerView(workspace: self)
            dividerViews.append(view)
            addSubview(view)
        }
        for (view, divider) in zip(dividerViews, dividers) {
            view.divider = divider
            view.frame = divider.frame
        }
    }

    /// Slides one seam and reframes immediately; the PTY hears about it on the
    /// next display refresh.
    func moveDivider(_ divider: PaneDivider, by delta: CGFloat) {
        guard var grid else { return }
        grid.moveDivider(
            divider,
            by: delta,
            in: bounds,
            dividerThickness: Self.dividerThickness,
            minimumPaneSize: Self.minimumPaneSize
        )
        self.grid = grid
        updateLayout()
    }

    /// The seam matching an in-flight drag, re-read after each step so the view
    /// tracks the pointer rather than a stale frame.
    func currentDivider(matching divider: PaneDivider) -> PaneDivider? {
        grid?.layout(in: bounds, dividerThickness: Self.dividerThickness)
            .dividers
            .first { $0.axis == divider.axis && $0.column == divider.column && $0.row == divider.row }
    }

    // MARK: - Display refresh

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        resizeDisplayLink?.invalidate()
        resizeDisplayLink = nil
        occlusionObserver.map(NotificationCenter.default.removeObserver)
        occlusionObserver = nil
        guard let window else { return }
        let link = displayLink(target: self, selector: #selector(displayRefreshed))
        link.add(to: .main, forMode: .common)
        link.isPaused = !resizeCoalescer.hasPending
        resizeDisplayLink = link
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: window,
            queue: .main
        ) { [weak self] notification in
            guard let window = notification.object as? NSWindow else { return }
            self?.setSuspendsDrawing(!window.occlusionState.contains(.visible))
        }
        restoreFocus()
    }

    @objc private func displayRefreshed() {
        resizeCoalescer.flush()
        resizeDisplayLink?.isPaused = true
    }

    private func resizeScheduled() {
        if let resizeDisplayLink {
            resizeDisplayLink.isPaused = false
            return
        }
        // No window, no display link: still coalesce the burst into one send at
        // the end of this run-loop turn rather than one per size change.
        guard !asyncFlushScheduled else { return }
        asyncFlushScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            asyncFlushScheduled = false
            resizeCoalescer.flush()
        }
    }

    // MARK: - Accessibility

    override func accessibilityChildren() -> [Any]? {
        paneIDs.compactMap { containers[$0] }
    }

    private func updateAccessibilityLabels() {
        let ids = paneIDs
        for (index, id) in ids.enumerated() {
            containers[id]?.updateAccessibilityLabel(index: index + 1, of: ids.count)
        }
    }

    // MARK: - Responder-chain commands

    @objc func focusPaneLeft(_ sender: Any?) { focusNeighbor(.left) }
    @objc func focusPaneRight(_ sender: Any?) { focusNeighbor(.right) }
    @objc func focusPaneUp(_ sender: Any?) { focusNeighbor(.up) }
    @objc func focusPaneDown(_ sender: Any?) { focusNeighbor(.down) }

    @objc func swapPaneLeft(_ sender: Any?) { swapWithNeighbor(.left) }
    @objc func swapPaneRight(_ sender: Any?) { swapWithNeighbor(.right) }
    @objc func swapPaneUp(_ sender: Any?) { swapWithNeighbor(.up) }
    @objc func swapPaneDown(_ sender: Any?) { swapWithNeighbor(.down) }

    /// ⌘1…⌘8 — the menu item's `tag` is the 1-based pane index in fill order.
    @objc func selectPane(_ sender: Any?) {
        guard let tag = (sender as? NSMenuItem)?.tag else { return }
        focusPane(at: tag)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(focusPaneLeft(_:)), #selector(swapPaneLeft(_:)):
            return hasNeighbor(.left)
        case #selector(focusPaneRight(_:)), #selector(swapPaneRight(_:)):
            return hasNeighbor(.right)
        case #selector(focusPaneUp(_:)), #selector(swapPaneUp(_:)):
            return hasNeighbor(.up)
        case #selector(focusPaneDown(_:)), #selector(swapPaneDown(_:)):
            return hasNeighbor(.down)
        case #selector(selectPane(_:)):
            return menuItem.tag >= 1 && menuItem.tag <= paneIDs.count
        default:
            return true
        }
    }

    private func hasNeighbor(_ direction: PaneDirection) -> Bool {
        guard let focusedPaneID else { return false }
        return grid?.neighbor(of: focusedPaneID, direction: direction) != nil
    }
}

/// One pane: a drag-handle header over one `TerminalSurfaceView`. Both a
/// dragging source (grab the header) and a dragging destination (drop another
/// pane on it to trade places).
final class PaneContainerView: NSView, NSDraggingSource {
    let paneID: String
    let surface: TerminalSurfaceView
    let header: PaneHeaderView

    var isFocused = false {
        didSet { guard isFocused != oldValue else { return }; header.isFocused = isFocused; needsDisplay = true }
    }

    private(set) var isDropTarget = false

    private weak var workspace: PaneWorkspaceView?

    init(paneID: String, surface: TerminalSurfaceView, workspace: PaneWorkspaceView) {
        self.paneID = paneID
        self.surface = surface
        self.workspace = workspace
        header = PaneHeaderView(title: paneID)
        super.init(frame: .zero)
        wantsLayer = true
        header.onDragOut = { [weak self] event in self?.beginPaneDrag(with: event) }
        addSubview(header)
        addSubview(surface)
        registerForDraggedTypes([PaneWorkspaceView.paneDragType])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Terminal pane")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

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
        let headerHeight = PaneHeaderView.height
        header.frame = CGRect(x: 0, y: 0, width: bounds.width, height: min(headerHeight, bounds.height))
        surface.frame = CGRect(
            x: 0,
            y: headerHeight,
            width: bounds.width,
            height: max(0, bounds.height - headerHeight)
        )
    }

    func descriptorChanged(_ descriptor: PaneDescriptor) {
        header.title = descriptor.title.isEmpty ? descriptor.sessionID : descriptor.title
    }

    func updateAccessibilityLabel(index: Int, of total: Int) {
        let position = "terminal pane \(index) of \(total)"
        if let group = workspace?.descriptor(for: paneID)?.groupLabel, !group.isEmpty {
            setAccessibilityLabel("\(group), \(position)")
        } else {
            setAccessibilityLabel(position.prefix(1).uppercased() + position.dropFirst())
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let border = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = 1
        if isDropTarget {
            NSColor(srgbRed: 65 / 255, green: 132 / 255, blue: 255 / 255, alpha: 0.22).setFill()
            bounds.fill(using: .sourceOver)
            NSColor(srgbRed: 65 / 255, green: 132 / 255, blue: 255 / 255, alpha: 1).setStroke()
        } else if isFocused {
            NSColor(srgbRed: 65 / 255, green: 132 / 255, blue: 255 / 255, alpha: 0.85).setStroke()
        } else {
            NSColor(srgbRed: 30 / 255, green: 36 / 255, blue: 48 / 255, alpha: 1).setStroke()
        }
        border.stroke()
    }

    // MARK: - Dragging source

    func pasteboardItemForDragging() -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setString(paneID, forType: PaneWorkspaceView.paneDragType)
        return item
    }

    private func beginPaneDrag(with event: NSEvent) {
        let item = NSDraggingItem(pasteboardWriter: pasteboardItemForDragging())
        item.setDraggingFrame(bounds, contents: snapshot())
        beginDraggingSession(with: [item], event: event, source: self)
    }

    private func snapshot() -> NSImage {
        let image = NSImage(size: bounds.size)
        guard bounds.width > 0, bounds.height > 0,
              let rep = bitmapImageRepForCachingDisplay(in: bounds)
        else { return image }
        cacheDisplay(in: bounds, to: rep)
        image.addRepresentation(rep)
        return image
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    // MARK: - Dragging destination

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let source = sender.draggingPasteboard.string(forType: PaneWorkspaceView.paneDragType),
              workspace?.canAcceptDrop(from: source, onto: paneID) == true
        else { return [] }
        isDropTarget = true
        needsDisplay = true
        return .move
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        isDropTarget = false
        needsDisplay = true
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        isDropTarget = false
        needsDisplay = true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isDropTarget = false
        needsDisplay = true
        guard let source = sender.draggingPasteboard.string(forType: PaneWorkspaceView.paneDragType)
        else { return false }
        return workspace?.performPaneDrop(from: source, onto: paneID) ?? false
    }
}

/// The pane's drag handle and label. Deliberately thin: the session outline,
/// per-pane menus and rename all belong to Task 6.
final class PaneHeaderView: NSView {
    static let height: CGFloat = 22

    var title: String { didSet { needsDisplay = true } }
    var isFocused = false { didSet { needsDisplay = true } }
    var onDragOut: ((NSEvent) -> Void)?

    private var mouseDownEvent: NSEvent?

    init(title: String) {
        self.title = title
        super.init(frame: .zero)
        wantsLayer = true
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        (isFocused
            ? NSColor(srgbRed: 20 / 255, green: 28 / 255, blue: 44 / 255, alpha: 1)
            : NSColor(srgbRed: 14 / 255, green: 17 / 255, blue: 23 / 255, alpha: 1)
        ).setFill()
        bounds.fill()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: isFocused
                ? NSColor(srgbRed: 224 / 255, green: 229 / 255, blue: 237 / 255, alpha: 1)
                : NSColor(srgbRed: 140 / 255, green: 150 / 255, blue: 168 / 255, alpha: 1),
        ]
        let text = title as NSString
        let size = text.size(withAttributes: attributes)
        text.draw(
            at: NSPoint(x: 8, y: (bounds.height - size.height) / 2),
            withAttributes: attributes
        )
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownEvent = event
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownEvent else { return }
        let travelled = hypot(
            event.locationInWindow.x - start.locationInWindow.x,
            event.locationInWindow.y - start.locationInWindow.y
        )
        guard travelled > 4 else { return }
        mouseDownEvent = nil
        onDragOut?(start)
    }

    override func mouseUp(with event: NSEvent) {
        mouseDownEvent = nil
        (superview as? PaneContainerView).map { $0.surface.focus() }
    }
}

/// One draggable seam. Frames follow the pointer on every mouse event; the PTY
/// resize behind them is coalesced by `PaneResizeCoalescer`.
final class PaneDividerView: NSView {
    var divider: PaneDivider?

    private weak var workspace: PaneWorkspaceView?
    private var lastLocation: NSPoint?

    init(workspace: PaneWorkspaceView) {
        self.workspace = workspace
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(
            srgbRed: 4 / 255,
            green: 6 / 255,
            blue: 9 / 255,
            alpha: 1
        ).cgColor
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func resetCursorRects() {
        guard let divider else { return }
        addCursorRect(bounds, cursor: divider.axis == .vertical ? .resizeLeftRight : .resizeUpDown)
    }

    override func mouseDown(with event: NSEvent) {
        lastLocation = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        guard let workspace,
              let divider,
              let last = lastLocation,
              let current = workspace.currentDivider(matching: divider)
        else { return }
        let location = event.locationInWindow
        // The workspace view is flipped, the window is not: a downward drag is a
        // *smaller* window y but a *larger* workspace y.
        let delta = divider.axis == .vertical
            ? location.x - last.x
            : last.y - location.y
        guard delta != 0 else { return }
        lastLocation = location
        os_signpost(
            .event,
            log: Instrumentation.log,
            name: "Pane Divider Drag",
            "%{public}s delta=%.1f",
            divider.axis == .vertical ? "vertical" : "horizontal",
            delta
        )
        workspace.moveDivider(current, by: delta)
    }

    override func mouseUp(with event: NSEvent) {
        lastLocation = nil
        workspace?.resizeCoalescer.flush()
    }
}


/// The empty cell of an incomplete rectangle. Visible (so a hole reads as a
/// deliberate empty slot rather than a rendering bug) and clickable, which is
/// the same double duty the web grid's hole tile does.
final class PaneHolePlaceholderView: NSView {
    private let onActivate: () -> Void

    init(onActivate: @escaping () -> Void) {
        self.onActivate = onActivate
        super.init(frame: .zero)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Add terminal")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 8, dy: 8), xRadius: 8, yRadius: 8)
        outline.lineWidth = 1
        outline.setLineDash([6, 5], count: 2, phase: 0)
        NSColor(srgbRed: 36 / 255, green: 43 / 255, blue: 57 / 255, alpha: 1).setStroke()
        outline.stroke()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor(srgbRed: 110 / 255, green: 120 / 255, blue: 138 / 255, alpha: 1),
        ]
        let text = "+ New terminal" as NSString
        let size = text.size(withAttributes: attributes)
        text.draw(
            at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2),
            withAttributes: attributes
        )
    }

    override func mouseUp(with event: NSEvent) {
        activate()
    }

    override func accessibilityPerformPress() -> Bool {
        activate()
        return true
    }

    func activate() {
        onActivate()
    }
}
