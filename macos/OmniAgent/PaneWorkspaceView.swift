import AppKit
import QuartzCore

final class PaneWorkspaceView: NSView, NSDraggingSource {
    private static let pasteboardType = NSPasteboard.PasteboardType(
        "digital.bruno.omniagent.pane"
    )
    private static let dividerWidth: CGFloat = 6
    private static let minimumPaneLength: CGFloat = 100

    private let connection: SessionConnection
    private var surfaces: [String: TerminalSurfaceView] = [:]
    private var columnFractions: [CGFloat]
    private var rowFraction: CGFloat = 0.5
    private var displayLink: CADisplayLink?
    private var activeColumnDivider: Int?
    private var activeRowDivider = false

    private(set) var paneLayout: PaneLayout
    var onAddPane: (() -> Void)?
    var onClosePane: ((PaneDescriptor) -> Void)?

    init(connection: SessionConnection, panes: [PaneDescriptor]) throws {
        self.connection = connection
        paneLayout = try PaneLayout(panes: panes)
        columnFractions = Self.equalFractions(paneLayout.shape.columns)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(
            srgbRed: 8 / 255,
            green: 10 / 255,
            blue: 14 / 255,
            alpha: 1
        ).cgColor
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Terminal workspace")
        registerForDraggedTypes([Self.pasteboardType])
        for pane in panes { installSurface(for: pane) }
        updateAccessibility()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    deinit {
        displayLink?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        displayLink?.invalidate()
        displayLink = nil
        NotificationCenter.default.removeObserver(
            self,
            name: NSWindow.didBecomeKeyNotification,
            object: nil
        )
        NotificationCenter.default.removeObserver(
            self,
            name: NSWindow.didChangeOcclusionStateNotification,
            object: nil
        )
        guard let window else { return }
        let displayLink = displayLink(target: self, selector: #selector(displayLinkFired(_:)))
        displayLink.add(to: .main, forMode: .common)
        self.displayLink = displayLink
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowBecameKey(_:)),
            name: NSWindow.didBecomeKeyNotification,
            object: window
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowOcclusionChanged(_:)),
            name: NSWindow.didChangeOcclusionStateNotification,
            object: window
        )
        restoreFocus()
    }

    override func viewDidHide() {
        super.viewDidHide()
        updateDrawingSuspension()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        updateDrawingSuspension()
    }

    override func layout() {
        super.layout()
        let frames = cellFrames()
        for (index, id) in paneLayout.cells.enumerated() {
            guard let id, let surface = surfaces[id] else { continue }
            surface.frame = frames[index]
        }
        updateAccessibility()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        for rect in columnDividerRects() { addCursorRect(rect, cursor: .resizeLeftRight) }
        if let rect = rowDividerRect() { addCursorRect(rect, cursor: .resizeUpDown) }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        activeColumnDivider = columnDividerRects().firstIndex { $0.contains(point) }
        activeRowDivider = rowDividerRect()?.contains(point) == true
        if activeColumnDivider == nil, !activeRowDivider { super.mouseDown(with: event) }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let activeColumnDivider {
            _ = setColumnDivider(activeColumnDivider, position: point.x)
        } else if activeRowDivider {
            _ = setRowDivider(position: point.y)
        } else {
            super.mouseDragged(with: event)
        }
    }

    override func mouseUp(with event: NSEvent) {
        activeColumnDivider = nil
        activeRowDivider = false
        super.mouseUp(with: event)
    }

    func surface(forPaneID id: String) -> TerminalSurfaceView? {
        surfaces[id]
    }

    func surface(forSessionID id: String) -> TerminalSurfaceView? {
        guard let pane = paneLayout.panes.values.first(where: { $0.sessionID == id }) else {
            return nil
        }
        return surfaces[pane.id]
    }

    func addPane(_ pane: PaneDescriptor) throws {
        let oldShape = paneLayout.shape
        try paneLayout.add(pane)
        installSurface(for: pane)
        if paneLayout.shape != oldShape {
            columnFractions = Self.equalFractions(paneLayout.shape.columns)
            rowFraction = 0.5
        }
        needsLayout = true
        layoutSubtreeIfNeeded()
        restoreFocus()
    }

    @discardableResult
    func removePane(_ id: String) -> PaneDescriptor? {
        let oldShape = paneLayout.shape
        guard let pane = paneLayout.remove(id) else { return nil }
        surfaces.removeValue(forKey: id)?.removeFromSuperview()
        if paneLayout.shape != oldShape {
            columnFractions = Self.equalFractions(paneLayout.shape.columns)
            rowFraction = 0.5
        }
        needsLayout = true
        layoutSubtreeIfNeeded()
        restoreFocus()
        return pane
    }

    @discardableResult
    func swapPanes(_ first: String, _ second: String) -> Bool {
        guard paneLayout.swap(first, second) else { return false }
        needsLayout = true
        layoutSubtreeIfNeeded()
        restoreFocus()
        return true
    }

    @discardableResult
    func swapDroppedPane(sourceID: String, targetID: String) -> Bool {
        swapPanes(sourceID, targetID)
    }

    @discardableResult
    func focusPane(_ direction: PaneDirection) -> Bool {
        guard paneLayout.focus(direction) != nil else { return false }
        restoreFocus()
        return true
    }

    @discardableResult
    func focusPane(at oneBasedIndex: Int) -> Bool {
        let ids = paneLayout.paneIDs
        guard ids.indices.contains(oneBasedIndex - 1) else { return false }
        guard paneLayout.focus(ids[oneBasedIndex - 1]) else { return false }
        restoreFocus()
        return true
    }

    func focusCurrentPane() {
        restoreFocus()
    }

    func updatePaneMetadata(
        id: String,
        label: String?,
        group: String?,
        groupLabel: String?
    ) {
        paneLayout.updateMetadata(
            id: id,
            label: label,
            group: group,
            groupLabel: groupLabel
        )
        updateAccessibility()
    }

    @discardableResult
    func setColumnDivider(_ index: Int, position: CGFloat) -> Bool {
        let widths = columnWidths()
        guard widths.indices.contains(index), widths.indices.contains(index + 1) else {
            return false
        }
        let origin = widths.prefix(index).reduce(0, +)
            + CGFloat(index) * Self.dividerWidth
        let pairWidth = widths[index] + widths[index + 1]
        let minimum = min(Self.minimumPaneLength, pairWidth / 2)
        let left = min(
            max(position - origin - Self.dividerWidth / 2, minimum),
            pairWidth - minimum
        )
        var updated = widths
        updated[index] = left
        updated[index + 1] = pairWidth - left
        let available = max(1, updated.reduce(0, +))
        columnFractions = updated.map { $0 / available }
        needsLayout = true
        layoutSubtreeIfNeeded()
        return true
    }

    @discardableResult
    func setRowDivider(position: CGFloat) -> Bool {
        guard paneLayout.shape.rows == 2 else { return false }
        let available = max(1, bounds.height - Self.dividerWidth)
        let minimum = min(Self.minimumPaneLength, available / 2)
        let bottom = min(
            max(position - Self.dividerWidth / 2, minimum),
            available - minimum
        )
        rowFraction = 1 - bottom / available
        needsLayout = true
        layoutSubtreeIfNeeded()
        return true
    }

    @objc func displayRefresh() {
        for surface in surfaces.values { surface.flushPendingResize() }
        updateDrawingSuspension()
    }

    @objc func focusPaneLeft(_ sender: Any?) { _ = focusPane(.left) }
    @objc func focusPaneRight(_ sender: Any?) { _ = focusPane(.right) }
    @objc func focusPaneUp(_ sender: Any?) { _ = focusPane(.up) }
    @objc func focusPaneDown(_ sender: Any?) { _ = focusPane(.down) }
    @objc func addPaneCommand(_ sender: Any?) { onAddPane?() }

    @objc func closePane(_ sender: Any?) {
        guard
            let id = paneLayout.focusedPaneID,
            let pane = paneLayout.panes[id]
        else { return }
        if let onClosePane {
            onClosePane(pane)
        } else {
            _ = removePane(id)
        }
    }

    @objc func selectPane(_ sender: NSMenuItem) {
        _ = focusPane(at: sender.tag)
    }

    @objc func swapPaneLeft(_ sender: Any?) { swapFocusedPane(.left) }
    @objc func swapPaneRight(_ sender: Any?) { swapFocusedPane(.right) }
    @objc func swapPaneUp(_ sender: Any?) { swapFocusedPane(.up) }
    @objc func swapPaneDown(_ sender: Any?) { swapFocusedPane(.down) }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .move
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool {
        true
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        dropPair(sender) == nil ? [] : .move
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let (source, target) = dropPair(sender) else { return false }
        return swapDroppedPane(sourceID: source, targetID: target)
    }

    private func installSurface(for pane: PaneDescriptor) {
        let surface = TerminalSurfaceView(connection: connection, sessionID: pane.sessionID)
        surface.setResizeCoalescing(true)
        surface.terminalView.onFocus = { [weak self] in
            _ = self?.paneLayout.focus(pane.id)
        }
        surface.terminalView.onCommandDrag = { [weak self, weak terminal = surface.terminalView] event in
            guard let self, let terminal else { return }
            beginDrag(paneID: pane.id, from: terminal, event: event)
        }
        surfaces[pane.id] = surface
        addSubview(surface)
    }

    private func beginDrag(paneID: String, from view: NSView, event: NSEvent) {
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(paneID, forType: Self.pasteboardType)
        let item = NSDraggingItem(pasteboardWriter: pasteboardItem)
        item.setDraggingFrame(
            NSRect(origin: view.convert(event.locationInWindow, from: nil), size: NSSize(width: 1, height: 1)),
            contents: NSImage(size: NSSize(width: 1, height: 1))
        )
        view.beginDraggingSession(with: [item], event: event, source: self)
    }

    private func dropPair(_ sender: NSDraggingInfo) -> (String, String)? {
        guard
            let source = sender.draggingPasteboard.string(forType: Self.pasteboardType),
            let target = paneID(at: convert(sender.draggingLocation, from: nil)),
            source != target,
            paneLayout.panes[source] != nil
        else { return nil }
        return (source, target)
    }

    private func paneID(at point: NSPoint) -> String? {
        surfaces.first { $0.value.frame.contains(point) }?.key
    }

    private func swapFocusedPane(_ direction: PaneDirection) {
        guard
            let focused = paneLayout.focusedPaneID,
            let neighbor = paneLayout.neighbor(in: direction)
        else { return }
        _ = swapPanes(focused, neighbor)
    }

    private func restoreFocus() {
        if paneLayout.focusedPaneID == nil {
            window?.makeFirstResponder(self)
            return
        }
        guard
            let id = paneLayout.focusedPaneID,
            let surface = surfaces[id],
            window != nil
        else { return }
        surface.focus()
    }

    @objc private func windowBecameKey(_ notification: Notification) {
        restoreFocus()
    }

    @objc private func windowOcclusionChanged(_ notification: Notification) {
        updateDrawingSuspension()
    }

    @objc private func displayLinkFired(_ displayLink: CADisplayLink) {
        displayRefresh()
    }

    private func updateDrawingSuspension() {
        let windowOccluded = window.map { !$0.occlusionState.contains(.visible) } ?? false
        for surface in surfaces.values {
            surface.setDrawingSuspended(
                windowOccluded || isHiddenOrHasHiddenAncestor || surface.visibleRect.isEmpty
            )
        }
    }

    private func updateAccessibility() {
        let ids = paneLayout.paneIDs
        for (index, id) in ids.enumerated() {
            guard let surface = surfaces[id], let pane = paneLayout.panes[id] else { continue }
            surface.describePane(index: index + 1, count: ids.count, descriptor: pane)
        }
    }

    private func cellFrames() -> [NSRect] {
        guard !paneLayout.cells.isEmpty else { return [] }
        let shape = paneLayout.shape
        let widths = columnWidths()
        let availableHeight = max(
            0,
            bounds.height - CGFloat(shape.rows - 1) * Self.dividerWidth
        )
        let topHeight = shape.rows == 1 ? availableHeight : availableHeight * rowFraction
        let rowHeights = shape.rows == 1 ? [availableHeight] : [topHeight, availableHeight - topHeight]
        var frames: [NSRect] = []
        var x = bounds.minX
        for column in 0..<shape.columns {
            for row in 0..<shape.rows {
                let height = rowHeights[row]
                let y = row == 0
                    ? bounds.maxY - height
                    : bounds.minY
                frames.append(NSRect(x: x, y: y, width: widths[column], height: height))
            }
            x += widths[column] + Self.dividerWidth
        }
        return frames
    }

    private func columnWidths() -> [CGFloat] {
        let count = paneLayout.shape.columns
        if columnFractions.count != count {
            columnFractions = Self.equalFractions(count)
        }
        let available = max(
            0,
            bounds.width - CGFloat(count - 1) * Self.dividerWidth
        )
        let total = max(1, columnFractions.reduce(0, +))
        return columnFractions.map { available * $0 / total }
    }

    private func columnDividerRects() -> [NSRect] {
        let widths = columnWidths()
        var x = bounds.minX
        return widths.dropLast().map { width in
            x += width
            defer { x += Self.dividerWidth }
            return NSRect(
                x: x,
                y: bounds.minY,
                width: Self.dividerWidth,
                height: bounds.height
            )
        }
    }

    private func rowDividerRect() -> NSRect? {
        guard paneLayout.shape.rows == 2 else { return nil }
        let topHeight = max(0, bounds.height - Self.dividerWidth) * rowFraction
        return NSRect(
            x: bounds.minX,
            y: bounds.maxY - topHeight - Self.dividerWidth,
            width: bounds.width,
            height: Self.dividerWidth
        )
    }

    private static func equalFractions(_ count: Int) -> [CGFloat] {
        Array(repeating: 1 / CGFloat(count), count: count)
    }
}
