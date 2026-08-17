import AppKit
import CoreImage
import QuartzCore
import os.signpost

/// One pane's identity and the metadata that travels with it — the native
/// equivalent of `TabInfo`. Held in a dictionary keyed by session id, so a pane
/// keeps its grouping no matter which cell of the rectangle it currently
/// occupies.
///
/// The `project`/`engine`/`cwd`/`label`/`themeId` fields are exactly the ones
/// `PersistedTab` stores, kept here so `WorkspaceRestoration.persistedTabs` can
/// write a live pane back to the `layout` row without a second bookkeeping
/// collection to keep in sync — the same "restore the tabs and everything else
/// comes back with them" property `ui/src/state/sessionGroups.ts` relies on.
/// `title` is separate and deliberately not persisted: it is the terminal's own
/// live OSC title, not something the user named.
struct PaneDescriptor: Equatable {
    let sessionID: String
    var group: String
    var groupLabel: String?
    var title: String
    var project: String
    var engine: Engine
    var cwd: String
    /// The name the **user** typed, and only that. A generated placeholder is
    /// never stored here: `SessionOutline.paneLabel` derives one when this is
    /// empty, so a terminal that has not been named by hand is free to show
    /// whatever the agent reports it is working on.
    var label: String?
    var themeId: TerminalThemeId?
    /// Which "Claude 2" this terminal is, within its session. Derived on the
    /// way in and never persisted — the number is a placeholder, and storing
    /// it would make it outlive the moment it is useful for.
    var autoNumber: Int = 1

    init(
        sessionID: String,
        group: String,
        groupLabel: String? = nil,
        title: String = "",
        project: String = "",
        engine: Engine = .shell,
        cwd: String = "",
        label: String? = nil,
        themeId: TerminalThemeId? = nil
    ) {
        self.sessionID = sessionID
        self.group = group
        self.groupLabel = groupLabel
        self.title = title
        self.project = project
        self.engine = engine
        self.cwd = cwd
        self.label = label
        self.themeId = themeId
    }

    /// The pane's own restored shape, so a plan can be applied without the
    /// caller re-typing every field.
    init(_ pane: RestoredPane) {
        self.init(
            sessionID: pane.sessionID,
            group: pane.group,
            groupLabel: pane.groupLabel,
            title: "",
            project: pane.project,
            engine: pane.engine,
            cwd: pane.cwd,
            label: pane.label,
            themeId: pane.themeId
        )
    }
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
    /// `padding:7px` around the design's pane grid — without it the outermost
    /// panes' rounded corners are cut off by the window edge.
    static let gridInset: CGFloat = 7

    /// The rect the grid is actually laid out in. Every calculation that reads
    /// geometry — the frames, a divider drag, the divider currently under the
    /// pointer — has to use this same rect or a drag drifts against the panes
    /// it is moving.
    var gridBounds: NSRect {
        bounds.insetBy(dx: Self.gridInset, dy: Self.gridInset)
    }

    /// One grid per session, plus the session currently on screen.
    ///
    /// A session owns its own shape and its own dragged fractions, so coming
    /// back to one shows the layout you left it in. `containers`/`descriptors`
    /// hold *every* pane; only the active session's are in a grid, laid out
    /// and visible. The rest keep running — a PTY belongs to the daemon, not
    /// to this view — they are simply not on screen. That is the whole of
    /// "each session holds its own terminals": a second session with one
    /// terminal shows one terminal, not the first session's as well.
    private var grids: [String: PaneGrid] = [:]
    /// Session ids in first-seen order, so `allPaneIDs` — and everything built
    /// from it, the sidebar tree and the persisted layout included — has a
    /// stable order rather than a dictionary's.
    private var groupOrder: [String] = []
    private(set) var activeGroup: String?

    /// The active session's grid; assigning replaces that session's.
    var grid: PaneGrid? {
        get { activeGroup.flatMap { grids[$0] } }
        set {
            guard let activeGroup else { return }
            grids[activeGroup] = newValue
        }
    }
    private(set) var focusedPaneID: String?
    let resizeCoalescer = PaneResizeCoalescer()

    /// Raised when a pane wants to exist or stop existing — the window
    /// controller owns session lifecycle, this view owns layout and identity.
    var onRequestNewPane: (() -> Void)?
    /// The header's close button. Closing a pane ends its PTY, which only the
    /// window controller may do — this view never kills a session itself.
    var onRequestClosePane: ((String) -> Void)?
    var onFocusedPaneChanged: ((String?) -> Void)?
    /// Raised when the set of panes, their order, or one pane's metadata
    /// changed — i.e. exactly when the `layout` settings row would no longer
    /// describe what is on screen. Deliberately *not* raised from
    /// `updateLayout`, which runs on every frame of a divider drag and whose
    /// pixel geometry the persisted shape does not carry anyway.
    var onPanesChanged: (() -> Void)?

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

    /// The panes **on screen**: the active session's, in fill order. Layout,
    /// focus, ⌘1…⌘8 and drag-and-drop all mean this one.
    var paneIDs: [String] { grid?.paneIDs() ?? [] }

    /// **Every** pane that exists, across every session, in a stable order.
    /// Persistence, the sidebar tree, the pane cap and session lifecycle all
    /// mean this one: a pane in another session is off screen, not gone — its
    /// PTY is still running, and it must still be saved, listed and
    /// reattached on the next launch.
    var allPaneIDs: [String] { groupOrder.flatMap { grids[$0]?.paneIDs() ?? [] } }

    /// The sessions that currently hold at least one pane, in first-seen order.
    var groupIDs: [String] { groupOrder }

    /// How many terminals one session is holding — what `PaneGrid.maxPanes`
    /// is measured against, since eight is what a single grid can draw and a
    /// session is what a grid holds.
    func paneCount(inGroup group: String) -> Int {
        grids[group]?.paneIDs().count ?? 0
    }

    /// The most terminals the app will run at once across *every* session —
    /// the mirror of `omniagent-pty-daemon`'s `MAX_SESSIONS`, and the only
    /// cap that is about the whole app rather than one session. Eight
    /// sessions of eight panes is the most the UI can draw, so that is the
    /// number both sides carry.
    ///
    /// Not a limit anyone should meet in normal use: the per-session cap is
    /// `PaneGrid.maxPanes`, and this exists so a runaway client cannot ask
    /// the daemon for unbounded PTYs.
    static let maxTerminals = 64

    func descriptor(for sessionID: String) -> PaneDescriptor? { descriptors[sessionID] }

    func container(for sessionID: String) -> PaneContainerView? { containers[sessionID] }

    func surface(for sessionID: String) -> TerminalSurfaceView? { containers[sessionID]?.surface }

    // MARK: - Mutating the workspace

    /// Adds a pane and gives it focus. Refused once its **own session** holds
    /// `PaneGrid.maxPanes`, once the app as a whole holds `maxTerminals`, and
    /// for a session id already on screen.
    @discardableResult
    func addPane(_ descriptor: PaneDescriptor) -> Bool {
        // Per session, not per app: eight is what one grid can draw, and each
        // session has its own grid. A full session must not stop a different
        // one from opening a terminal.
        guard
            paneCount(inGroup: descriptor.group) < PaneGrid.maxPanes,
            allPaneIDs.count < Self.maxTerminals,
            descriptors[descriptor.sessionID] == nil
        else {
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
        // The header's engine and branch come from the descriptor, and until
        // this was here they arrived only when something later *mutated* it —
        // so a freshly opened pane showed no engine badge at all, which is the
        // one piece of chrome that says what the terminal is actually running.
        container.descriptorChanged(descriptor)
        addSubview(container)
        let group = descriptor.group
        if !groupOrder.contains(group) { groupOrder.append(group) }
        grids[group] = PaneGrid.synced(
            grids[group],
            desiredIDs: (grids[group]?.paneIDs() ?? []) + [descriptor.sessionID]
        )
        // A pane you just opened is one you are about to type in, so its
        // session comes to the screen. `focusPane` below would switch to it
        // regardless; doing it here keeps `updateVisibility` from running
        // against the outgoing session's grid first.
        activeGroup = group
        // A terminal you just opened is the one you want to look at, so a
        // zoom in progress ends here rather than hiding it behind the blur.
        zoomedPaneID = nil
        updateVisibility()
        updateLayout()
        focusPane(descriptor.sessionID)
        onPanesChanged?()
        return true
    }

    // MARK: - Zoom

    /// The pane currently blown up over the others, if any. Never set while
    /// fewer than two panes are on screen: with one terminal the pane already
    /// fills the workspace, so there is nothing to zoom away from — which is
    /// why the control is not even offered.
    private(set) var zoomedPaneID: String?

    private lazy var zoomBackdrop: PaneZoomBackdropView = {
        let view = PaneZoomBackdropView()
        view.onClick = { [weak self] in self?.setZoomed(nil) }
        return view
    }()

    /// How long a pane takes to grow into the zoom or shrink back out of it,
    /// with the backdrop's blur ramping over the same span. Slow enough to read
    /// as one pane lifting off the others rather than as a cut.
    static let zoomTransitionDuration: TimeInterval = 0.32

    /// Non-zero only for the one layout pass a zoom change kicks off, so the
    /// pane's move is animated there and nowhere else: every other pass (window
    /// resize, divider drag, session switch) has to land instantly.
    private var zoomTransition: TimeInterval = 0

    @discardableResult
    func toggleZoom(_ sessionID: String) -> Bool {
        guard paneIDs.count >= 2, paneIDs.contains(sessionID) else { return false }
        setZoomed(zoomedPaneID == sessionID ? nil : sessionID)
        return true
    }

    func setZoomed(_ sessionID: String?) {
        guard zoomedPaneID != sessionID else { return }
        zoomedPaneID = sessionID
        if let sessionID { focusPane(sessionID) }
        updateZoomAvailability()
        // Reduced motion still zooms, it just lands instantly.
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            return updateLayout()
        }
        zoomTransition = Self.zoomTransitionDuration
        NSAnimationContext.runAnimationGroup { context in
            context.duration = zoomTransition
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            updateLayout()
        }
        zoomTransition = 0
    }

    /// Zoom only survives while it still means something: the pane has to be
    /// on screen, and there has to be more than one pane for it to cover.
    /// Switching sessions, closing its last sibling or opening a new terminal
    /// all end it — leaving it on would hide the very pane you just asked for
    /// behind the blur.
    private func validateZoom() {
        guard let id = zoomedPaneID else { return }
        if paneIDs.count < 2 || !paneIDs.contains(id) { zoomedPaneID = nil }
    }

    private func updateZoomAvailability() {
        let available = paneIDs.count >= 2
        for (id, container) in containers {
            container.isZoomAvailable = available && paneIDs.contains(id)
            container.isZoomed = id == zoomedPaneID
        }
    }

    /// "Almost the entire terminal place": the zoomed pane takes the workspace
    /// less a margin, so the blurred grid still shows around the edge. It reads
    /// as one pane lifted off the others rather than a different screen, which
    /// is the difference between a zoom and a mode you have to find your way
    /// back out of.
    private func zoomFrame() -> NSRect {
        let area = gridBounds
        let inset = min(30, min(area.width, area.height) * 0.045)
        return area.insetBy(dx: inset, dy: inset)
    }

    private func applyZoom() {
        guard let id = zoomedPaneID, let container = containers[id] else {
            zoomBackdrop.setShown(false, duration: zoomTransition)
            return
        }
        zoomBackdrop.setShown(true, duration: zoomTransition)
        // Re-stacked on every pass because `syncDividerViews`/`addPane` add
        // their own subviews on top; the backdrop has to stay directly under
        // the zoomed pane and above everything else.
        addSubview(zoomBackdrop, positioned: .above, relativeTo: nil)
        addSubview(container, positioned: .above, relativeTo: zoomBackdrop)
        zoomBackdrop.frame = bounds
        place(container, at: zoomFrame())
    }

    /// Moves a pane, animating the move only during a zoom transition — where
    /// AppKit's animator lands the frame in the model at once (so the terminal
    /// reflows once, at its final size) and animates the layer into it.
    private func place(_ container: PaneContainerView, at frame: NSRect) {
        guard container.frame != frame else { return }
        if zoomTransition > 0 {
            container.animator().frame = frame
        } else {
            container.frame = frame
        }
        container.surface.scheduleResize()
    }

    /// Brings one session to the screen, hiding whichever was there. Focus
    /// follows to that session's first pane, since the focused pane is always
    /// one of the visible ones.
    @discardableResult
    func activateGroup(_ group: String) -> Bool {
        guard grids[group] != nil, activeGroup != group else { return false }
        activeGroup = group
        updateVisibility()
        updateLayout()
        if let first = paneIDs.first { focusPane(first) }
        return true
    }

    /// Only the active session's panes are on screen. The others are hidden,
    /// never torn down: closing a pane is what ends a PTY, and switching
    /// sessions must not. A hidden pane keeps parsing output into SwiftTerm's
    /// bounded buffer — so its scrollback is intact when you come back — and
    /// only stops drawing, the same trade an occluded window makes.
    private func updateVisibility() {
        validateZoom()
        updateZoomAvailability()
        let visible = Set(paneIDs)
        for (id, container) in containers {
            let onScreen = visible.contains(id)
            container.isHidden = !onScreen
            container.surface.suspendsDrawing = suspendsDrawing || !onScreen
        }
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
        let group = descriptors[sessionID]?.group
        containers.removeValue(forKey: sessionID)
        descriptors.removeValue(forKey: sessionID)
        if let group, let existing = grids[group] {
            let remaining = existing.paneIDs().filter { $0 != sessionID }
            if remaining.isEmpty {
                // A session with no panes left is not a session any more —
                // drop it rather than leaving an empty grid the sidebar would
                // still draw a row for.
                grids.removeValue(forKey: group)
                groupOrder.removeAll { $0 == group }
                if activeGroup == group { activeGroup = groupOrder.first }
            } else {
                grids[group] = PaneGrid.synced(existing, desiredIDs: remaining)
            }
        }
        updateVisibility()
        updateLayout()
        if focusedPaneID == sessionID {
            focusedPaneID = nil
            // Its own session first, then whatever session is on screen now —
            // closing the last pane of one lands you in another rather than
            // on an empty workspace with a stale focus.
            if let next = successor ?? paneIDs.first {
                focusPane(next)
            } else {
                updateFocusRings()
                onFocusedPaneChanged?(nil)
            }
        }
        onPanesChanged?()
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
        onPanesChanged?()
        return true
    }

    /// Publishes one pane's live agent status to its chrome. The window
    /// controller owns the status feed; this is the only way it reaches a pane.
    func setStatus(_ status: RemoteSessionStatus?, for sessionID: String) {
        containers[sessionID]?.status = status
    }

    func updateDescriptor(for sessionID: String, _ mutate: (inout PaneDescriptor) -> Void) {
        guard var descriptor = descriptors[sessionID] else { return }
        mutate(&descriptor)
        guard descriptors[sessionID] != descriptor else { return }
        descriptors[sessionID] = descriptor
        containers[sessionID]?.descriptorChanged(descriptor)
        updateAccessibilityLabels()
        onPanesChanged?()
    }

    // MARK: - Focus

    func focusPane(_ sessionID: String) {
        guard
            containers[sessionID] != nil,
            let group = descriptors[sessionID]?.group,
            grids[group]?.contains(sessionID) == true
        else { return }
        // Focusing a pane in another session brings that session to the
        // screen. This is the single rule that makes the sidebar work: its
        // session rows and pane rows both already call through here, so
        // selecting either one switches sessions without a second code path.
        if activeGroup != group {
            activeGroup = group
            updateVisibility()
            updateLayout()
        }
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

    /// Within the closing pane's own session — a pane never hands focus to
    /// another session's terminal while one of its own siblings is still open.
    private func focusSuccessor(after sessionID: String) -> String? {
        guard
            let group = descriptors[sessionID]?.group,
            let ids = grids[group]?.paneIDs(),
            let index = ids.firstIndex(of: sessionID)
        else { return nil }
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
        // Through `updateVisibility` rather than straight onto every surface:
        // an off-screen session's panes must stay suspended when the window
        // becomes visible again, and assigning the flag directly un-suspended
        // them.
        updateVisibility()
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
        let layout = grid.layout(in: gridBounds, dividerThickness: Self.dividerThickness)
        for (id, container) in containers {
            // The zoomed pane is placed by `applyZoom` instead. Skipped rather
            // than assigned twice: each assignment schedules a PTY resize, and
            // this runs on every frame of a divider drag.
            guard id != zoomedPaneID, let frame = layout.frames[id] else { continue }
            place(container, at: frame)
        }
        syncDividerViews(layout.dividers)
        syncHolePlaceholders(layout, holeIDs: grid.cells.filter(\.isHole).map(\.id))
        applyZoom()
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
            in: gridBounds,
            dividerThickness: Self.dividerThickness,
            minimumPaneSize: Self.minimumPaneSize
        )
        self.grid = grid
        updateLayout()
    }

    /// The seam matching an in-flight drag, re-read after each step so the view
    /// tracks the pointer rather than a stale frame.
    func currentDivider(matching divider: PaneDivider) -> PaneDivider? {
        grid?.layout(in: gridBounds, dividerThickness: Self.dividerThickness)
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

    /// The pane's border, drawn as the container's own background showing
    /// through a 1pt gap around the header and terminal rather than as a
    /// `borderWidth`. Both children are opaque and tile the container, so a
    /// real border would be buried under them — and this way the rounded
    /// corner, the border and the "working" animation are all one layer.
    static let cornerRadius: CGFloat = 9
    static let borderWidth: CGFloat = 1

    /// `#0c0c0f` — the pane body behind the terminal, from the design's grid.
    static let paneBackgroundColor = NSColor(srgbRed: 12 / 255, green: 12 / 255, blue: 15 / 255, alpha: 1)
    static let idleBorderColor = NSColor(white: 1, alpha: 0.08)
    static let focusedBorderColor = NSColor(srgbRed: 139 / 255, green: 149 / 255, blue: 255 / 255, alpha: 0.45)
    /// `box-shadow:0 0 0 1px rgba(240,180,70,.35)` — a pane that has stopped to
    /// ask something outranks focus, because it is the one the user must act on.
    static let awaitingBorderColor = NSColor(srgbRed: 240 / 255, green: 180 / 255, blue: 70 / 255, alpha: 0.55)
    static let errorBorderColor = NSColor(srgbRed: 242 / 255, green: 85 / 255, blue: 90 / 255, alpha: 0.55)
    static let dropTargetBorderColor = NSColor(srgbRed: 139 / 255, green: 149 / 255, blue: 255 / 255, alpha: 1)

    var isFocused = false {
        didSet {
            guard isFocused != oldValue else { return }
            header.isFocused = isFocused
            updateChrome()
        }
    }

    /// The pane's live agent status, which drives the header's mark and the
    /// border. `nil` is "nothing reported yet", drawn as idle.
    var status: RemoteSessionStatus? {
        didSet {
            guard status != oldValue else { return }
            header.status = status
            updateChrome()
        }
    }

    private(set) var isDropTarget = false {
        didSet {
            guard isDropTarget != oldValue else { return }
            updateChrome()
        }
    }

    /// Whether this pane may be zoomed at all — false with a single terminal
    /// on screen, which hides the control rather than offering a no-op.
    var isZoomAvailable = false {
        didSet {
            guard isZoomAvailable != oldValue else { return }
            header.isZoomAvailable = isZoomAvailable
        }
    }

    var isZoomed = false {
        didSet {
            guard isZoomed != oldValue else { return }
            header.isZoomed = isZoomed
        }
    }

    /// The drop tint, as a top-most sibling rather than a fill in `draw(_:)`,
    /// for the same compositing reason.
    let dropHighlight = PaneDropOverlayView()

    private weak var workspace: PaneWorkspaceView?
    private var workingRing: CAGradientLayer?
    /// The cwd the header's branch was last resolved for, so a repeated OSC 7
    /// carrying the same directory does not re-read `.git/HEAD`.
    private var branchDirectory: String?

    init(paneID: String, surface: TerminalSurfaceView, workspace: PaneWorkspaceView) {
        self.paneID = paneID
        self.surface = surface
        self.workspace = workspace
        // Seeded blank rather than with the pane id: `descriptorChanged`
        // fills it in, and a UUID flashing in the header first is the bug this
        // header had.
        header = PaneHeaderView(title: "")
        super.init(frame: .zero)
        wantsLayer = true
        header.onDragOut = { [weak self] event in self?.beginPaneDrag(with: event) }
        header.onZoomRequested = { [weak self] in
            guard let self else { return }
            // Focus first: the button used to *be* the focus control, and a
            // pane you zoom is one you are about to type in. Clicking anywhere
            // in a pane already focuses it, but the header's buttons swallow
            // their own clicks, so this is the one path that would not.
            self.workspace?.focusPane(self.paneID)
            self.workspace?.toggleZoom(self.paneID)
        }
        header.onCloseRequested = { [weak self] in
            guard let self else { return }
            self.workspace?.onRequestClosePane?(self.paneID)
        }
        addSubview(header)
        // Opaque for the same reason the header is: the container's background
        // is the border colour, and a terminal theme with any transparency
        // would let it wash across the whole pane.
        surface.wantsLayer = true
        surface.layer?.backgroundColor = Self.paneBackgroundColor.cgColor
        addSubview(surface)
        addSubview(dropHighlight, positioned: .above, relativeTo: nil)
        updateChrome()
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
        // Inset by the border width on every side: the gap this leaves is the
        // border (see `borderWidth`), and it keeps both children clear of the
        // rounded corners the container's layer mask cuts.
        let inset = Self.borderWidth
        let headerHeight = PaneHeaderView.height
        let width = max(0, bounds.width - inset * 2)
        header.frame = CGRect(
            x: inset,
            y: inset,
            width: width,
            height: min(headerHeight, max(0, bounds.height - inset * 2))
        )
        surface.frame = CGRect(
            x: inset,
            y: inset + headerHeight,
            width: width,
            height: max(0, bounds.height - headerHeight - inset * 2)
        )
        dropHighlight.frame = bounds
        workingRing?.frame = bounds
    }

    private func updateChrome() {
        layer?.cornerRadius = Self.cornerRadius
        layer?.cornerCurve = .continuous
        // The mask is what rounds the terminal's own square corners. It costs
        // one offscreen pass per pane, which is why nothing else here (no
        // shadow, no filter) adds a second one.
        layer?.masksToBounds = true
        layer?.backgroundColor = borderColor.cgColor
        dropHighlight.isHidden = !isDropTarget
        updateWorkingRing()
    }

    /// Which colour the 1pt ring takes. Ordered by urgency: a drop in flight,
    /// then a question the agent is blocked on, then an error, then focus.
    private var borderColor: NSColor {
        if isDropTarget { return Self.dropTargetBorderColor }
        switch status {
        case .awaitingApproval: return Self.awaitingBorderColor
        case .error: return Self.errorBorderColor
        default: return isFocused ? Self.focusedBorderColor : Self.idleBorderColor
        }
    }

    /// The design's signature: while an agent is actually thinking, a bright
    /// arc travels around the pane's edge (`animation:om-spin 3s linear
    /// infinite` over a conic gradient). It exists only for that state, only on
    /// the focused pane, and not at all under Reduce Motion — an animation that
    /// never stops is the one thing that would make eight open panes expensive.
    private func updateWorkingRing() {
        let wanted = status == .thinking && isFocused && !ShellMotion.reduced
        guard wanted else {
            workingRing?.removeFromSuperlayer()
            workingRing = nil
            return
        }
        guard workingRing == nil else { return }
        let ring = CAGradientLayer()
        ring.type = .conic
        ring.frame = bounds
        ring.startPoint = CGPoint(x: 0.5, y: 0.5)
        ring.endPoint = CGPoint(x: 0.5, y: 0)
        ring.colors = [
            NSColor(srgbRed: 139 / 255, green: 149 / 255, blue: 255 / 255, alpha: 0).cgColor,
            NSColor(srgbRed: 139 / 255, green: 149 / 255, blue: 255 / 255, alpha: 0).cgColor,
            NSColor(srgbRed: 139 / 255, green: 149 / 255, blue: 255 / 255, alpha: 0.35).cgColor,
            NSColor(srgbRed: 167 / 255, green: 175 / 255, blue: 255 / 255, alpha: 1).cgColor,
            NSColor(srgbRed: 139 / 255, green: 149 / 255, blue: 255 / 255, alpha: 0).cgColor,
        ]
        ring.locations = [0, 0.69, 0.875, 0.97, 1]
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = 2 * Double.pi
        spin.duration = 3
        spin.repeatCount = .infinity
        spin.isRemovedOnCompletion = false
        ring.add(spin, forKey: "om-spin")
        // Below the header and the surface, which cover everything but the 1pt
        // ring the inset in `applyLayout` leaves exposed.
        layer?.insertSublayer(ring, at: 0)
        workingRing = ring
    }

    func descriptorChanged(_ descriptor: PaneDescriptor) {
        // Never the session id. A pane that has not emitted an OSC title yet —
        // which is most of a login shell's life, and all of an agent's before
        // its first prompt — was rendering a raw UUID in its header.
        // `SessionOutline.paneLabel` is the one place that decides what a pane
        // is called, and the sidebar already used it.
        header.title = SessionOutline.paneLabel(descriptor)
        header.engine = descriptor.engine
        updateBranch(for: descriptor.cwd)
    }

    /// Resolves the pane's branch off the main thread and hands it to the
    /// header. Repeats for the same directory are dropped — a pane's cwd is
    /// re-published on every OSC 7, which for a shell is every prompt.
    private func updateBranch(for cwd: String) {
        guard cwd != branchDirectory else { return }
        branchDirectory = cwd
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let branch = GitBranch.forDirectory(cwd)
            DispatchQueue.main.async {
                guard let self, self.branchDirectory == cwd else { return }
                self.header.branch = branch
            }
        }
    }

    func updateAccessibilityLabel(index: Int, of total: Int) {
        let position = "terminal pane \(index) of \(total)"
        if let group = workspace?.descriptor(for: paneID)?.groupLabel, !group.isEmpty {
            setAccessibilityLabel("\(group), \(position)")
        } else {
            setAccessibilityLabel(position.prefix(1).uppercased() + position.dropFirst())
        }
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
        return .move
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        isDropTarget = false
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        isDropTarget = false
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isDropTarget = false
        guard let source = sender.draggingPasteboard.string(forType: PaneWorkspaceView.paneDragType)
        else { return false }
        return workspace?.performPaneDrop(from: source, onto: paneID) ?? false
    }
}

/// The drop tint. A view rather than a `draw(_:)` fill so it composites above
/// the opaque terminal, and transparent to hit testing so it never swallows a
/// click or a drag that belongs to the pane underneath.
final class PaneDropOverlayView: NSView {
    init() {
        super.init(frame: .zero)
        wantsLayer = true
        isHidden = true
        layer?.backgroundColor = NSColor(
            srgbRed: 65 / 255,
            green: 132 / 255,
            blue: 255 / 255,
            alpha: 0.22
        ).cgColor
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The pane's chrome, from the design's terminal grid: a status mark that says
/// what the agent is doing, the terminal's name, which engine is driving it,
/// the branch it is on, and the two controls. Also the drag handle — the whole
/// bar is grabbable except where a button sits.
final class PaneHeaderView: NSView {
    static let height: CGFloat = 30

    private static let leadingInset: CGFloat = 10
    private static let trailingInset: CGFloat = 6
    private static let gap: CGFloat = 8
    private static let markSize: CGFloat = 15
    private static let buttonSize: CGFloat = 20

    var title: String {
        didSet {
            guard title != oldValue else { return }
            titleLabel.stringValue = title
            needsLayout = true
        }
    }

    var isFocused = false {
        didSet {
            guard isFocused != oldValue else { return }
            applyEmphasis()
            needsDisplay = true
        }
    }

    var status: RemoteSessionStatus? {
        didSet {
            guard status != oldValue else { return }
            mark.status = status
        }
    }

    var engine: Engine? {
        didSet {
            guard engine != oldValue else { return }
            engineBadge.isHidden = engine == nil
            if let engine {
                engineBadge.configure(
                    icon: engine.iconImage,
                    text: engine.badgeTitle,
                    foreground: engine.badgeForeground,
                    fill: engine.badgeFill,
                    stroke: engine.badgeStroke,
                    font: ShellFont.ui(12, .semibold)
                )
            }
            needsLayout = true
        }
    }

    /// The git branch, or `nil` outside a repository — in which case the badge
    /// simply is not there, rather than showing an empty pill.
    var branch: String? {
        didSet {
            guard branch != oldValue else { return }
            branchBadge.isHidden = branch == nil
            if let branch {
                branchBadge.configure(
                    icon: nil,
                    text: branch,
                    foreground: NSColor(srgbRed: 154 / 255, green: 154 / 255, blue: 164 / 255, alpha: 1),
                    fill: NSColor(white: 1, alpha: 0.055),
                    stroke: .clear,
                    font: ShellFont.mono(12, .medium)
                )
            }
            needsLayout = true
        }
    }

    var onDragOut: ((NSEvent) -> Void)?
    var onZoomRequested: (() -> Void)?
    var onCloseRequested: (() -> Void)?

    var isZoomAvailable = false {
        didSet {
            guard isZoomAvailable != oldValue else { return }
            focusButton.isHidden = !isZoomAvailable
            needsLayout = true
        }
    }

    var isZoomed = false {
        didSet {
            guard isZoomed != oldValue else { return }
            focusButton.setAccessibilityLabel(
                isZoomed ? "Shrink this terminal back into the grid" : "Zoom this terminal"
            )
        }
    }

    private let mark = PaneStatusMarkView()
    private let titleLabel: NSTextField
    private let engineBadge = PaneBadgeView()
    private let branchBadge = PaneBadgeView()
    private let focusButton: PaneHeaderButton
    private let closeButton: PaneHeaderButton

    private var mouseDownEvent: NSEvent?

    init(title: String) {
        self.title = title
        titleLabel = ShellFont.label(
            title,
            font: ShellFont.ui(14.5, .medium),
            color: NSColor(srgbRed: 208 / 255, green: 208 / 255, blue: 216 / 255, alpha: 1)
        )
        focusButton = PaneHeaderButton(glyph: .focus)
        closeButton = PaneHeaderButton(glyph: .close)
        super.init(frame: .zero)
        wantsLayer = true
        titleLabel.translatesAutoresizingMaskIntoConstraints = true
        engineBadge.isHidden = true
        branchBadge.isHidden = true
        focusButton.isHidden = true
        focusButton.onClick = { [weak self] in self?.onZoomRequested?() }
        closeButton.onClick = { [weak self] in self?.onCloseRequested?() }
        closeButton.hoverTint = NSColor(srgbRed: 255 / 255, green: 138 / 255, blue: 142 / 255, alpha: 1)
        closeButton.hoverFill = NSColor(srgbRed: 242 / 255, green: 85 / 255, blue: 90 / 255, alpha: 0.18)
        for view in [mark, titleLabel, engineBadge, branchBadge, focusButton, closeButton] as [NSView] {
            addSubview(view)
        }
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override var isFlipped: Bool { true }

    private func applyEmphasis() {
        titleLabel.textColor = isFocused
            ? NSColor(srgbRed: 234 / 255, green: 234 / 255, blue: 240 / 255, alpha: 1)
            : NSColor(srgbRed: 208 / 255, green: 208 / 255, blue: 216 / 255, alpha: 1)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // Opaque, because the container's own background is now the pane's
        // border colour and would otherwise show straight through.
        PaneContainerView.paneBackgroundColor.setFill()
        bounds.fill()
        NSColor(white: 1, alpha: isFocused ? 0.045 : 0.03).setFill()
        bounds.fill()
        NSColor(white: 1, alpha: 0.07).setFill()
        NSRect(x: 0, y: bounds.maxY - 0.5, width: bounds.width, height: 0.5).fill()
    }

    override func layout() {
        super.layout()
        let middle = (bounds.height - Self.markSize) / 2
        mark.frame = CGRect(
            x: Self.leadingInset,
            y: middle,
            width: Self.markSize,
            height: Self.markSize
        )

        // Right to left: the controls first, then whichever badges still fit.
        // The title takes what is left, which is what makes a narrow pane drop
        // the branch and then the engine rather than clipping its own name.
        var right = bounds.maxX - Self.trailingInset
        // A hidden zoom button gives its slot back to the title rather than
        // leaving a gap where a control used to be.
        for button in [closeButton, focusButton] where !button.isHidden {
            right -= Self.buttonSize
            button.frame = CGRect(
                x: right,
                y: (bounds.height - Self.buttonSize) / 2,
                width: Self.buttonSize,
                height: Self.buttonSize
            )
        }

        let titleLeft = mark.frame.maxX + Self.gap
        let minimumTitleWidth: CGFloat = 40
        for badge in [branchBadge, engineBadge] where !badge.isHidden {
            let size = badge.intrinsicContentSize
            let candidate = right - Self.gap - size.width
            guard candidate - titleLeft >= minimumTitleWidth else {
                badge.frame = .zero
                continue
            }
            right = candidate
            badge.frame = CGRect(
                x: right,
                y: (bounds.height - size.height) / 2,
                width: size.width,
                height: size.height
            )
        }

        let titleHeight = ceil(titleLabel.intrinsicContentSize.height)
        titleLabel.frame = CGRect(
            x: titleLeft,
            y: (bounds.height - titleHeight) / 2,
            width: max(0, right - Self.gap - titleLeft),
            height: titleHeight
        )
    }

    // MARK: - Dragging

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

/// The OmniAgent mark, tinted by what the agent is doing and glowing faintly in
/// that colour — the design's `filter:drop-shadow(0 0 5px …)`. It pulses while
/// the agent is busy, which is the one place in a pane where "something is
/// happening" has to read from across the room.
final class PaneStatusMarkView: NSView {
    var status: RemoteSessionStatus? {
        didSet {
            guard status != oldValue else { return }
            apply()
        }
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        setAccessibilityElement(false)
        apply()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    /// Literally the sidebar's own mapping, not a copy of it: a session that
    /// reads amber in the tree has to read amber in its terminal's header, and
    /// two switch statements over the same enum are how that stops being true.
    static func color(for status: RemoteSessionStatus?) -> NSColor {
        ShellDotsView.color(for: status)
    }

    private func apply() {
        let color = Self.color(for: status)
        layer?.contents = OmniAgentMark.image?.tinted(color)
        layer?.contentsGravity = .resizeAspect
        layer?.shadowColor = color.cgColor
        layer?.shadowRadius = 2.5
        layer?.shadowOpacity = status == nil ? 0 : 0.55
        layer?.shadowOffset = .zero
        layer?.removeAnimation(forKey: "om-pulse")
        let busy = status == .thinking || status == .toolExecution || status == .awaitingApproval
        guard busy, !ShellMotion.reduced else {
            layer?.opacity = 1
            return
        }
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1
        pulse.toValue = 0.45
        pulse.duration = status == .thinking ? 0.9 : 1.1
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        layer?.add(pulse, forKey: "om-pulse")
    }
}

/// One pill in the pane header — the engine badge and the branch badge are the
/// same shape with different contents.
final class PaneBadgeView: NSView {
    private static let height: CGFloat = 19
    private static let iconSize: CGFloat = 15
    private static let horizontalInset: CGFloat = 7
    private static let gap: CGFloat = 5

    private var icon: NSImage?
    private var text = ""
    private var foreground: NSColor = .labelColor
    private var fill: NSColor = .clear
    private var stroke: NSColor = .clear
    private var font: NSFont = .systemFont(ofSize: 12)

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override var isFlipped: Bool { true }

    func configure(
        icon: NSImage?,
        text: String,
        foreground: NSColor,
        fill: NSColor,
        stroke: NSColor,
        font: NSFont
    ) {
        self.icon = icon
        self.text = text
        self.foreground = foreground
        self.fill = fill
        self.stroke = stroke
        self.font = font
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    override var intrinsicContentSize: NSSize {
        let textWidth = (text as NSString).size(withAttributes: [.font: font]).width
        let iconWidth = icon == nil ? 0 : Self.iconSize + Self.gap
        return NSSize(
            width: ceil(Self.horizontalInset * 2 + iconWidth + textWidth),
            height: Self.height
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.25, dy: 0.25), xRadius: 5, yRadius: 5)
        fill.setFill()
        path.fill()
        if stroke != .clear {
            stroke.setStroke()
            path.lineWidth = 0.5
            path.stroke()
        }
        var left = Self.horizontalInset
        if let icon {
            let box = NSRect(
                x: left,
                y: (bounds.height - Self.iconSize) / 2,
                width: Self.iconSize,
                height: Self.iconSize
            )
            icon.tinted(foreground).draw(in: box)
            left = box.maxX + Self.gap
        }
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: foreground]
        let size = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(
            at: NSPoint(x: left, y: (bounds.height - size.height) / 2),
            withAttributes: attributes
        )
    }
}

/// A 20pt icon button in the pane header. Hand-drawn rather than an
/// `NSButton` + SF Symbol so the glyphs match the design's own strokes, the
/// same way `ShellGlyph` does for the sidebar.
/// The blurred backdrop a zoomed pane sits on, and the way out of the zoom
/// that does not require finding the button again.
///
/// A layer background filter rather than an `NSVisualEffectView`: the effect
/// view brings a display-link-backed animation machine with it, and on a
/// headless test host that spins forever retrying
/// `CVDisplayLinkCreateWithCGDisplays` — merely constructing one hung the
/// suite. A Gaussian blur over the layers behind this one is the whole of
/// what is wanted here, and `backgroundFilters` is exactly that.
final class PaneZoomBackdropView: NSView {
    /// The blur the grid ends up under. Ramped up from zero on the way in and
    /// back down on the way out, so the background blurs in and out with the
    /// pane rather than snapping — a plain alpha fade would cross-dissolve a
    /// sharp grid with a blurred one, which reads as double vision on text.
    static let blurRadius: CGFloat = 14
    /// The filter is named so this key path can address it; `CIFilter.name`
    /// exists for exactly this.
    private static let blurKeyPath = "backgroundFilters.blur.inputRadius"

    var onClick: (() -> Void)?

    private var isShown = false

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(srgbRed: 4 / 255, green: 6 / 255, blue: 9 / 255, alpha: 0.5)
            .cgColor
        if let blur = CIFilter(name: "CIGaussianBlur", parameters: ["inputRadius": 0]) {
            blur.name = "blur"
            layer?.backgroundFilters = [blur]
        }
        alphaValue = 0
        isHidden = true
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Shrink the zoomed terminal back into the grid")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    /// Fades the tint and ramps the blur with it. Hidden only once it has faded
    /// out, never left invisible-but-present: it swallows clicks.
    func setShown(_ shown: Bool, duration: TimeInterval) {
        guard isShown != shown else { return }
        isShown = shown
        if shown { isHidden = false }
        let radius = shown ? Self.blurRadius : 0
        let alpha: CGFloat = shown ? 1 : 0
        guard duration > 0 else {
            layer?.setValue(radius, forKeyPath: Self.blurKeyPath)
            alphaValue = alpha
            isHidden = !shown
            return
        }
        if let layer {
            let ramp = CABasicAnimation(keyPath: Self.blurKeyPath)
            ramp.fromValue = layer.value(forKeyPath: Self.blurKeyPath)
            ramp.toValue = radius
            ramp.duration = duration
            ramp.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.setValue(radius, forKeyPath: Self.blurKeyPath)
            layer.add(ramp, forKey: "blur")
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            animator().alphaValue = alpha
        }, completionHandler: { [weak self] in
            // Checked again: a zoom started mid-fade-out must not be hidden.
            guard let self, !self.isShown else { return }
            self.isHidden = true
        })
    }

    // Swallowed, so a click meant for "get me out of here" never reaches — or
    // focuses — the blurred pane underneath it.
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) { onClick?() }
}

final class PaneHeaderButton: NSView {
    enum Glyph { case focus, close }

    var onClick: (() -> Void)?
    var hoverTint = NSColor(srgbRed: 223 / 255, green: 226 / 255, blue: 255 / 255, alpha: 1)
    var hoverFill = NSColor(srgbRed: 139 / 255, green: 149 / 255, blue: 255 / 255, alpha: 0.22)

    private let glyph: Glyph
    private var isHovered = false { didSet { needsDisplay = true } }
    private var tracking: NSTrackingArea?

    init(glyph: Glyph) {
        self.glyph = glyph
        super.init(frame: .zero)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(glyph == .focus ? "Focus this terminal" : "Close this terminal")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        tracking.map(removeTrackingArea)
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClick?()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if isHovered {
            hoverFill.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
        }
        let color = isHovered
            ? hoverTint
            : NSColor(srgbRed: 130 / 255, green: 130 / 255, blue: 140 / 255, alpha: 1)
        color.setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1.4
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        // Both glyphs are drawn in the design's own 16x16 box and scaled to fit.
        let scale = bounds.width / 16
        func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            NSPoint(x: x * scale, y: y * scale)
        }
        switch glyph {
        case .focus:
            // Four corner brackets — "zoom this pane".
            let corners: [[(CGFloat, CGFloat)]] = [
                [(6.2, 2.4), (2.4, 2.4), (2.4, 6.2)],
                [(9.8, 2.4), (13.6, 2.4), (13.6, 6.2)],
                [(13.6, 9.8), (13.6, 13.6), (9.8, 13.6)],
                [(6.2, 13.6), (2.4, 13.6), (2.4, 9.8)],
            ]
            for corner in corners {
                path.move(to: point(corner[0].0, corner[0].1))
                for step in corner.dropFirst() { path.line(to: point(step.0, step.1)) }
            }
        case .close:
            path.move(to: point(4.2, 4.2))
            path.line(to: point(11.8, 11.8))
            path.move(to: point(11.8, 4.2))
            path.line(to: point(4.2, 11.8))
        }
        path.stroke()
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
