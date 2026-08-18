import AppKit

/// A round-capped × filling `rect`, inset by the same 4.2-of-16 proportion
/// as `PaneHeaderButton`'s `.close` glyph in `PaneWorkspaceView.swift` — the
/// pane header's close dot and this strip's tab-close accessory draw the
/// identical shape, so it lives here once rather than twice.
func drawXGlyph(in rect: NSRect, color: NSColor, lineWidth: CGFloat) {
    let insetFraction: CGFloat = 4.2 / 16
    let inset = rect.insetBy(dx: rect.width * insetFraction, dy: rect.height * insetFraction)
    let path = NSBezierPath()
    path.lineWidth = lineWidth
    path.lineCapStyle = .round
    path.move(to: NSPoint(x: inset.minX, y: inset.minY))
    path.line(to: NSPoint(x: inset.maxX, y: inset.maxY))
    path.move(to: NSPoint(x: inset.minX, y: inset.maxY))
    path.line(to: NSPoint(x: inset.maxX, y: inset.minY))
    color.setStroke()
    path.stroke()
}

/// The native tab strip over an editor pane's content — the app's first tab
/// strip, deliberately AppKit (the native-rule exception covers only the
/// editor surface below it). Renders an `EditorPaneModel`; every mutation
/// goes back up through callbacks, the strip never mutates state itself.
final class EditorTabStripView: NSView {
    static let height: CGFloat = 30

    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    var onPin: ((Int) -> Void)?
    var onSave: (() -> Void)?
    var onDiffToggle: (() -> Void)?
    var onBeginDrag: ((Int, NSEvent) -> Void)?
    /// A tab was dropped in this strip, with the index the indicator was
    /// showing. The strip never mutates anything itself — including its own
    /// pane's model — so the index is reported, not applied.
    var onTabDrop: ((EditorTabDragPayload, Int) -> Void)?

    private let scroll = NSScrollView()
    private let itemsContainer = NSView()
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)
    private let diffButton = NSButton(title: "± Diff", target: nil, action: nil)
    private let dropIndicator = NSView()
    private var items: [EditorTabItemView] = []

    private(set) var itemFrames: [CGRect] = []
    /// The titles actually drawn, in order — including the `" (deleted)"`
    /// suffix a vanished file wears. The strip has no other way to say what it
    /// rendered, and the suffix is the whole user-visible half of Task 15's
    /// deleted-on-disk rule.
    private(set) var itemTitles: [String] = []

    private static let itemSpacing: CGFloat = 1
    private static let itemHeight: CGFloat = 24
    private static let leadingInset: CGFloat = 4
    private static let trailingInset: CGFloat = 6
    private static let controlGap: CGFloat = 6

    /// The x, in `self`'s coordinates, where the scroll area must stop so it
    /// never draws under the trailing Save/± Diff buttons.
    private var scrollAreaTrailingEdge: CGFloat = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = PaneContainerView.paneBackgroundColor.cgColor

        scroll.documentView = itemsContainer
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.horizontalScrollElasticity = .allowed
        scroll.verticalScrollElasticity = .none

        saveButton.bezelStyle = .accessoryBarAction
        saveButton.controlSize = .small
        saveButton.target = self
        saveButton.action = #selector(savePressed)
        saveButton.isHidden = true

        diffButton.bezelStyle = .accessoryBarAction
        diffButton.controlSize = .small
        diffButton.target = self
        diffButton.action = #selector(diffPressed)
        diffButton.isHidden = true

        dropIndicator.wantsLayer = true
        dropIndicator.layer?.backgroundColor = PaneContainerView.focusedBorderColor.cgColor
        dropIndicator.isHidden = true

        addSubview(scroll)
        addSubview(saveButton)
        addSubview(diffButton)
        // Added last so it always draws above the tab items and the scroller.
        addSubview(dropIndicator)
        // A strip takes any editor tab: the merge/dedupe rules live in
        // `EditorPaneModel.insert`, and which pane may hold what is not a
        // question a tab strip can answer.
        registerForDraggedTypes([PaneWorkspaceView.editorTabDragType])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func layout() {
        super.layout()
        applyLayout()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        applyLayout()
    }

    private func applyLayout() {
        positionTrailingControls()
        scroll.frame = NSRect(
            x: 0,
            y: 0,
            width: max(0, scrollAreaTrailingEdge),
            height: bounds.height
        )
        layoutItems()
    }

    /// Save/± Diff sit outside the scroll view's clip so they never scroll
    /// away with the tabs; only shown while relevant, per `render`.
    private func positionTrailingControls() {
        var x = bounds.maxX - Self.trailingInset
        if !diffButton.isHidden {
            let size = diffButton.fittingSize
            x -= size.width
            diffButton.frame = NSRect(x: x, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
            x -= Self.controlGap
        }
        if !saveButton.isHidden {
            let size = saveButton.fittingSize
            x -= size.width
            saveButton.frame = NSRect(x: x, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
            x -= Self.controlGap
        }
        scrollAreaTrailingEdge = (saveButton.isHidden && diffButton.isHidden) ? bounds.maxX : x + Self.controlGap
    }

    /// Packs items left-to-right at their intrinsic width inside
    /// `itemsContainer`, which is exactly as wide as its content — the
    /// scroll view's horizontal scroller takes over once that exceeds the
    /// visible width.
    private func layoutItems() {
        var x: CGFloat = Self.leadingInset
        for item in items {
            let width = item.intrinsicWidth
            item.frame = NSRect(x: x, y: (bounds.height - Self.itemHeight) / 2, width: width, height: Self.itemHeight)
            x += width + Self.itemSpacing
        }
        let contentWidth = items.isEmpty ? 0 : x - Self.itemSpacing + Self.trailingInset
        itemsContainer.frame = NSRect(x: 0, y: 0, width: contentWidth, height: bounds.height)
    }

    static func title(for tab: EditorTab) -> String {
        switch tab.kind {
        case .changes: return "Changes"
        case .diff: return "\((tab.path as NSString).lastPathComponent) (Working Tree)"
        case .file, .media: return (tab.path as NSString).lastPathComponent
        }
    }

    static func insertionIndex(forX x: CGFloat, tabFrames: [CGRect]) -> Int {
        for (index, frame) in tabFrames.enumerated() where x < frame.midX {
            return index
        }
        return tabFrames.count
    }

    /// `deletedPaths` are the open files that have vanished from disk since
    /// they were read. Their buffers stay exactly where they are — the tab
    /// title is the only thing that changes, because at that point the buffer
    /// is the only copy of the file left.
    func render(model: EditorPaneModel, diffAvailable: Bool, deletedPaths: Set<String> = []) {
        itemsContainer.subviews.forEach { $0.removeFromSuperview() }
        itemTitles = model.tabs.map { tab in
            // `.file` only: a diff tab of a deleted file is not broken, it is
            // a deletion — showing its whole HEAD side is the point of it.
            let gone = tab.kind == .file && deletedPaths.contains(tab.path)
            return Self.title(for: tab) + (gone ? " (deleted)" : "")
        }
        items = model.tabs.enumerated().map { index, tab in
            let item = EditorTabItemView(tab: tab, title: itemTitles[index], isActiveTab: index == model.activeIndex)
            item.onPress = { [weak self] in self?.onSelect?(index) }
            item.onDoublePress = { [weak self] in self?.onPin?(index) }
            item.onClosePress = { [weak self] in self?.onClose?(index) }
            item.onDragOut = { [weak self] event in self?.onBeginDrag?(index, event) }
            return item
        }
        for item in items { itemsContainer.addSubview(item) }
        saveButton.isHidden = !(model.activeTab?.isDirty ?? false)
        diffButton.isHidden = !(diffAvailable && model.activeTab?.kind == .file)
        needsLayout = true
        layoutSubtreeIfNeeded()
        itemFrames = items.map { $0.convert($0.bounds, to: self) }
    }

    func showDropIndicator(at index: Int) {
        let x: CGFloat
        if itemFrames.isEmpty {
            x = Self.leadingInset
        } else if index <= 0 {
            x = itemFrames[0].minX
        } else if index >= itemFrames.count {
            x = itemFrames[itemFrames.count - 1].maxX
        } else {
            x = itemFrames[index].minX
        }
        dropIndicator.frame = NSRect(x: x - 1, y: 3, width: 2, height: max(0, bounds.height - 6))
        dropIndicator.isHidden = false
    }

    func clearDropIndicator() {
        dropIndicator.isHidden = true
    }

    // MARK: - Dragging destination

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let index = dropIndex(for: sender) else {
            clearDropIndicator()
            return []
        }
        showDropIndicator(at: index)
        return .move
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingEntered(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        clearDropIndicator()
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        clearDropIndicator()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        clearDropIndicator()
        guard let payload = payload(from: sender), let index = dropIndex(for: sender) else {
            return false
        }
        onTabDrop?(payload, index)
        return true
    }

    /// Where the indicator sits for the pointer's x — measured over the tabs
    /// as they stand, so for a reorder within this strip the dragged tab is
    /// still counted. `nil` when the pasteboard carries no tab at all.
    private func dropIndex(for sender: NSDraggingInfo) -> Int? {
        guard payload(from: sender) != nil else { return nil }
        let x = convert(sender.draggingLocation, from: nil).x
        return Self.insertionIndex(forX: x, tabFrames: itemFrames)
    }

    private func payload(from sender: NSDraggingInfo) -> EditorTabDragPayload? {
        EditorTabDragPayload.decode(
            sender.draggingPasteboard.string(forType: PaneWorkspaceView.editorTabDragType)
        )
    }

    // Test hooks — the real events go through EditorTabItemView's mouse handling.
    func selectForTesting(index: Int) { items[index].onPress?() }
    func closeForTesting(index: Int) { items[index].onClosePress?() }

    @objc private func savePressed() { onSave?() }
    @objc private func diffPressed() { onDiffToggle?() }
}

/// One tab: title, dirty-dot/close swap on hover, italic preview title.
/// mouseDown records, mouseUp fires press (clickCount >= 2 → double press),
/// mouseDragged past 4 pt fires onDragOut once.
final class EditorTabItemView: NSView {
    var onPress: (() -> Void)?
    var onDoublePress: (() -> Void)?
    var onClosePress: (() -> Void)?
    var onDragOut: ((NSEvent) -> Void)?

    private let tab: EditorTab
    private let titleText: String
    private let isActiveTab: Bool
    private var hovered = false {
        didSet { if hovered != oldValue { needsDisplay = true } }
    }
    private var mouseDownPoint: NSPoint?
    private var didFireDragOut = false

    private static let accessorySize: CGFloat = 16
    private static let horizontalPadding: CGFloat = 10
    private static let dragThreshold: CGFloat = 4

    private static func titleFont(preview: Bool) -> NSFont {
        let base = ShellFont.ui(12)
        guard preview else { return base }
        return NSFontManager.shared.convert(base, toHaveTrait: .italicFontMask)
    }

    /// Title width plus room for the leading/trailing padding and the
    /// trailing dirty-dot/close accessory — title + 44pt, per the brief.
    var intrinsicWidth: CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [.font: Self.titleFont(preview: !tab.isPinned)]
        let textWidth = (titleText as NSString).size(withAttributes: attributes).width
        return textWidth + Self.horizontalPadding * 2 + Self.accessorySize + 8
    }

    init(tab: EditorTab, title: String, isActiveTab: Bool) {
        self.tab = tab
        self.titleText = title
        self.isActiveTab = isActiveTab
        super.init(frame: .zero)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }

    /// The dirty-dot/close accessory's hit area, top-right-ish, vertically
    /// centred — a click landing here closes the tab instead of selecting it.
    private var accessoryRect: NSRect {
        NSRect(
            x: bounds.maxX - Self.horizontalPadding - Self.accessorySize,
            y: (bounds.height - Self.accessorySize) / 2,
            width: Self.accessorySize,
            height: Self.accessorySize
        )
    }

    /// VS Code's rule: a clean tab always shows its × (on hover it's the only
    /// affordance there is anyway); a dirty tab shows the dot until hovered.
    private var showsCloseGlyph: Bool { hovered || !tab.isDirty }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = event.locationInWindow
        didFireDragOut = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !didFireDragOut, let start = mouseDownPoint else { return }
        let distance = hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y)
        guard distance > Self.dragThreshold else { return }
        didFireDragOut = true
        // `onDragOut` pins the tab, and the pin re-renders the strip — which
        // removes and releases every item view, *this* one included, while
        // this method is still on its own stack. The extra reference keeps it
        // alive until the call returns.
        withExtendedLifetime(self) { onDragOut?(event) }
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownPoint = nil }
        guard !didFireDragOut else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        if accessoryRect.contains(point) {
            onClosePress?()
            return
        }
        if event.clickCount >= 2 {
            onDoublePress?()
        } else {
            onPress?()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if isActiveTab {
            NSColor(white: 1, alpha: 0.07).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
        }

        let color = isActiveTab ? ShellPalette.ink : ShellPalette.inkNav
        let font = Self.titleFont(preview: !tab.isPinned)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let maxTitleWidth = max(0, accessoryRect.minX - Self.horizontalPadding - Self.horizontalPadding)
        let size = (titleText as NSString).size(withAttributes: attributes)
        let titleRect = NSRect(
            x: Self.horizontalPadding,
            y: (bounds.height - size.height) / 2,
            width: min(size.width, maxTitleWidth),
            height: size.height
        )
        (titleText as NSString).draw(in: titleRect, withAttributes: attributes)

        if showsCloseGlyph {
            drawXGlyph(in: accessoryRect, color: color, lineWidth: 1.2)
        } else {
            drawDirtyDot(in: accessoryRect, color: ShellPalette.ink)
        }
    }

    private func drawDirtyDot(in rect: NSRect, color: NSColor) {
        let diameter: CGFloat = 7
        let dot = NSRect(x: rect.midX - diameter / 2, y: rect.midY - diameter / 2, width: diameter, height: diameter)
        color.setFill()
        NSBezierPath(ovalIn: dot).fill()
    }
}
