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
    /// The active `/color` name for a Claude terminal. Sent as a slash command
    /// and reflected back here so the header's color badge stays in sync.
    var claudeColor: String = "default"
    /// Which "Claude 2" this terminal is, within its session. Derived on the
    /// way in and never persisted — the number is a placeholder, and storing
    /// it would make it outlive the moment it is useful for.
    var autoNumber: Int = 1
    /// What this pane holds. `engine`/`cwd` describe a `.terminal`;
    /// `browserURL` takes cwd's role for a `.browser`.
    var kind: PaneKind
    var browserURL: String
    /// What an `.editor` pane holds: its persisted tab list and active index,
    /// kept on the descriptor for exactly `browserURL`'s reason — so
    /// `persistEditorPanes` can write live panes back to their row without a
    /// second bookkeeping collection.
    var editorTabs: [PersistedEditorTab]
    var editorActiveIndex: Int

    init(
        sessionID: String,
        group: String,
        groupLabel: String? = nil,
        title: String = "",
        project: String = "",
        engine: Engine = .shell,
        cwd: String = "",
        label: String? = nil,
        themeId: TerminalThemeId? = nil,
        kind: PaneKind = .terminal,
        browserURL: String = "",
        editorTabs: [PersistedEditorTab] = [],
        editorActiveIndex: Int = 0
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
        self.kind = kind
        self.browserURL = browserURL
        self.editorTabs = editorTabs
        self.editorActiveIndex = editorActiveIndex
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
            themeId: pane.themeId,
            kind: pane.kind,
            browserURL: pane.browserURL,
            editorTabs: pane.editorTabs,
            editorActiveIndex: pane.editorActiveIndex
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
    /// An editor *tab* in flight. A separate type from `paneDragType` on
    /// purpose: every destination can then say yes to one and no to the other
    /// without inspecting a payload, which is what gives a terminal pane the
    /// no-drop cursor for a tab and the drop highlight for a pane.
    static let editorTabDragType = NSPasteboard.PasteboardType("digital.bruno.omniagent.editor-tab")
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
    /// The hole tile's second, fainter affordance: a browser in that cell.
    var onRequestNewBrowserPane: (() -> Void)?
    /// The hole tile's third affordance: an editor in that cell.
    var onRequestNewEditorPane: (() -> Void)?
    /// An editor tab was dropped on a pane: the payload, the pane it landed
    /// on, and which band of it. Routed up rather than applied here — moving
    /// a tab can prompt about unsaved work and can create a pane, and both are
    /// the window controller's to decide.
    var onEditorTabDropOnPane: ((EditorTabDragPayload, String, EditorTabDropZone) -> Void)?
    /// An editor tab was dropped on an empty grid cell.
    var onEditorTabDropOnHole: ((EditorTabDragPayload) -> Void)?
    /// The header's close button. Closing a pane ends its PTY, which only the
    /// window controller may do — this view never kills a session itself.
    var onRequestClosePane: ((String) -> Void)?
    /// The header's pencil button tapped — prompt the user to rename.
    var onRequestRenamePane: ((String) -> Void)?
    /// The header's color badge clicked on a Claude pane — open the color menu.
    var onRequestColorMenu: ((String, NSView) -> Void)?
    /// The header's engine badge, clicked — same shape as the old ⋯ menu, and for
    /// the same reason: which engines exist and what swapping one costs is
    /// the window controller's business, not this view's.
    var onRequestEngineMenu: ((String, NSView) -> Void)?
    var onFocusedPaneChanged: ((String?) -> Void)?
    /// Raised when the set of panes, their order, or one pane's metadata
    /// changed — i.e. exactly when the `layout` settings row would no longer
    /// describe what is on screen. Deliberately *not* raised from
    /// `updateLayout`, which runs on every frame of a divider drag and whose
    /// pixel geometry the persisted shape does not carry anyway.
    var onPanesChanged: (() -> Void)?

    private let makeSurface: (PaneDescriptor) -> any PaneContentView
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

    init(makeSurface: @escaping (PaneDescriptor) -> any PaneContentView) {
        self.makeSurface = makeSurface
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(srgbRed: 4 / 255, green: 6 / 255, blue: 9 / 255, alpha: 1).cgColor
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        // Kind-neutral: the grid holds browsers as well as terminals now.
        setAccessibilityLabel("Workspace panes")
        // The overlay host carries the pane commands back to this view while a
        // card is up — see `PaneFocusOverlayView.commandTarget`.
        focusOverlay.commandTarget = self
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
    /// focus, ⌘1…⌘9 and drag-and-drop all mean this one.
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
    /// is measured against, since twelve is what a single grid can draw and a
    /// session is what a grid holds.
    func paneCount(inGroup group: String) -> Int {
        grids[group]?.paneIDs().count ?? 0
    }

    /// Whether `sessionID`'s own session can hold one more pane — the same
    /// `PaneGrid.maxPanes` bound every creation path checks, asked from the
    /// side of an existing pane. The drop destinations use it to refuse an
    /// edge or hole drop *before* the cursor says yes.
    func hasRoomForAnotherPane(inGroupOf sessionID: String) -> Bool {
        guard let group = descriptors[sessionID]?.group else { return false }
        return paneCount(inGroup: group) < PaneGrid.maxPanes
    }

    /// The most terminals the app will run at once across *every* session —
    /// the mirror of `omniagent-pty-daemon`'s `MAX_SESSIONS`, and the only
    /// cap that is about the whole app rather than one session. Eight
    /// sessions of twelve panes is the most the UI can draw, so that is the
    /// number both sides carry. (It was 64 while a grid topped out at eight
    /// panes; the 4x3 rung raised the product, and a ceiling below it would
    /// silently turn the per-session cap back into a whole-app one.)
    ///
    /// Not a limit anyone should meet in normal use: the per-session cap is
    /// `PaneGrid.maxPanes`, and this exists so a runaway client cannot ask
    /// the daemon for unbounded PTYs.
    static let maxTerminals = 96

    /// The panes that actually hold a PTY — what `maxTerminals` is measured
    /// against. Browser panes cost WebKit memory, not daemon slots.
    var terminalPaneCount: Int {
        allPaneIDs.filter { descriptors[$0]?.kind == .terminal }.count
    }

    func descriptor(for sessionID: String) -> PaneDescriptor? { descriptors[sessionID] }

    func container(for sessionID: String) -> PaneContainerView? { containers[sessionID] }

    func surface(for sessionID: String) -> (any PaneContentView)? { containers[sessionID]?.surface }

    /// The concrete terminal behind a pane, for the PTY-shaped call sites
    /// (feed, resize counts, interrupt/reattach). `nil` for any other kind.
    func terminalSurface(for sessionID: String) -> TerminalSurfaceView? {
        containers[sessionID]?.surface as? TerminalSurfaceView
    }

    /// The concrete browser behind a pane, for the browser-shaped call sites
    /// (title/URL wiring). `nil` for any other kind.
    func browserPane(for sessionID: String) -> BrowserPaneView? {
        containers[sessionID]?.surface as? BrowserPaneView
    }

    /// The concrete editor behind a pane, for the editor-shaped call sites
    /// (tab-state/title wiring, drop routing). `nil` for any other kind.
    func editorPane(for sessionID: String) -> EditorPaneView? {
        containers[sessionID]?.surface as? EditorPaneView
    }

    // MARK: - Mutating the workspace

    /// Adds a pane and gives it focus. Refused once its **own session** holds
    /// `PaneGrid.maxPanes`, once the app as a whole holds `maxTerminals`
    /// terminal panes (a PTY budget — non-terminal kinds are exempt), and
    /// for a session id already on screen.
    @discardableResult
    func addPane(_ descriptor: PaneDescriptor) -> Bool {
        insertPane(descriptor) { existing, grid in
            PaneGrid.synced(grid, desiredIDs: existing + [descriptor.sessionID])
        }
    }

    /// The edge-drop insertion: the new pane lands adjacent to `targetID` in
    /// grid order and the ladder re-lays out around it. Every refusal
    /// `addPane(_:)` makes it makes too, plus its own — an anchor in another
    /// session's grid has no cell here to sit beside.
    ///
    /// `PaneGrid.build` rather than `synced` on purpose: order is the whole
    /// point of this call, and dragged fractions reset exactly as they do for
    /// any other change of rung.
    @discardableResult
    func addPane(
        _ descriptor: PaneDescriptor,
        inserting position: PaneInsertPosition,
        of targetID: String
    ) -> Bool {
        guard descriptors[targetID]?.group == descriptor.group else { return false }
        return insertPane(descriptor) { existing, _ in
            var ids = existing
            let anchor = ids.firstIndex(of: targetID) ?? ids.count - 1
            let slot = position == .before ? anchor : anchor + 1
            ids.insert(descriptor.sessionID, at: min(max(0, slot), ids.count))
            return PaneGrid.build(ids)
        }
    }

    /// Everything an add does except decide the new shape, which is the one
    /// thing an append and an insert disagree about. `shapeGrid` is handed the
    /// group's current pane ids (in fill order) and its current grid.
    private func insertPane(
        _ descriptor: PaneDescriptor,
        shapeGrid: ([String], PaneGrid?) -> PaneGrid?
    ) -> Bool {
        // Per session, not per app: twelve is what one grid can draw, and each
        // session has its own grid. A full session must not stop a different
        // one from opening a terminal.
        guard
            paneCount(inGroup: descriptor.group) < PaneGrid.maxPanes,
            descriptor.kind != .terminal || terminalPaneCount < Self.maxTerminals,
            descriptors[descriptor.sessionID] == nil
        else {
            return false
        }
        descriptors[descriptor.sessionID] = descriptor
        let container = PaneContainerView(
            paneID: descriptor.sessionID,
            surface: makeSurface(descriptor),
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
        grids[group] = shapeGrid(grids[group]?.paneIDs() ?? [], grids[group])
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

    /// The design's overlay is full-bleed over the app frame —
    /// `position:absolute;top:30px;left:0;right:0;bottom:24px` in
    /// `design/OmniAgent ADE.dc.html`, the whole 1440×900 mock less its title
    /// bar and its status strip — and the sidebar sits *inside* it, blurred. So
    /// neither the backdrop nor the card can be a subview of this view, which is
    /// only the pane grid: they go in this host, installed over the window's
    /// entire content view. With no full-size content view and no status strip
    /// of our own, `contentView.bounds` is that rect exactly, and nothing needs
    /// the mock's manual 30/24 inset.
    ///
    /// Installed only while a pane is focused and taken back out on the way down
    /// (`teardownOverlay`): a plain view over the content view hit-tests as
    /// itself, so one left behind would swallow every click meant for the
    /// sidebar or a pane.
    private let focusOverlay: PaneFocusOverlayView = {
        let view = PaneFocusOverlayView()
        view.wantsLayer = true
        view.autoresizingMask = [.width, .height]
        // A container, not somewhere to land: the backdrop inside it is the
        // element that offers the way out of focus.
        view.setAccessibilityElement(false)
        return view
    }()

    /// The card's drop shadow (`box-shadow:0 40px 100px rgba(0,0,0,.75)`), as a
    /// layer of the overlay host under the card rather than the card's own
    /// shadow: `PaneContainerView` masks to bounds — that mask is what rounds
    /// the terminal's corners, so it stays — and a mask clips a shadow away with
    /// everything else outside the layer. Opaque black because a layer casts the
    /// shadow of what it actually paints; the card covers it completely.
    private lazy var focusCardShadow: CALayer = {
        let layer = CALayer()
        layer.backgroundColor = NSColor.black.cgColor
        layer.cornerRadius = PaneContainerView.focusedCornerRadius
        layer.cornerCurve = .continuous
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowOpacity = 0.75
        layer.shadowRadius = Self.focusCardShadowBlur
        // `0 40px` is 40pt *down*, and down is negative here whatever the host's
        // geometry: rendering a shadowed layer offscreen with
        // `isGeometryFlipped` both ways puts -40 below the layer either time, so
        // the offset is *not* flipped with a flipped view's sublayer frames.
        // Same reason CALayer's own (0,-3) default falls downward on macOS.
        layer.shadowOffset = CGSize(width: 0, height: -Self.focusCardShadowDrop)
        return layer
    }()

    /// The pane parented in the overlay host — the card, or the pane that was
    /// the card until its shrink started. Kept apart from `zoomedPaneID` because
    /// the view hierarchy outlives the state by one animation, and it is
    /// *parentage* rather than zoom state that says whose frame the grid may
    /// set: while a pane is in here its frame is in the host's coordinates, and
    /// a layout pass applying grid geometry to it would tear the transition in
    /// half.
    private var overlayPaneID: String?

    /// Whether that pane's shrink back into the grid is already in flight, so a
    /// second layout pass does not start it again and the transition's
    /// completion knows there is a card to land.
    private var overlayIsCollapsing = false

    /// Which transition is current. Every zoom change takes the next number, and
    /// a transition's completion does nothing unless the number it was given is
    /// still this one — the completions are indistinguishable otherwise, and an
    /// *entry* transition's completion arriving after a later exit had started would
    /// finish that exit early: the card would snap home instead of shrinking and
    /// the overlay would be pulled out from under the fade.
    private var zoomTransitionToken = 0

    /// `padding:26px` on the overlay, and the card as a share of the window with
    /// a ceiling on it. Neither half alone works: the mock's flat 1080×720 was
    /// nearly the whole overlay on the 1440×900 it was measured from and a
    /// postage stamp on anything bigger, while a pure fraction of a large display
    /// is so wide there is nothing to focus *on*. So the card takes
    /// `focusCardScale` of the window until that would exceed `focusCardMaxSize`,
    /// and never more than that.
    ///
    /// The width's scale is what keeps the card the window's own shape rather
    /// than a letterbox; height then takes a little more of what is left, since
    /// vertical room is rows of terminal — see `focusCardHeightScale`.
    static let focusOverlayPadding: CGFloat = 26
    static let focusCardScale: CGFloat = 0.88
    /// Height gets its own, larger share. A window is wider than the thing being
    /// read inside it needs to be, so the width scale is about leaving the
    /// surround visible — while every point of height is a row of terminal, and
    /// the vertical slack the single scale left over was the one dimension worth
    /// spending it on. Still bounded by the overlay's padding and by
    /// `focusCardMaxSize`, and never *less* than the width's share, so the card
    /// is only ever taller than proportional, never letterboxed.
    static let focusCardHeightScale: CGFloat = 0.94
    static let focusCardMaxSize = NSSize(width: 1760, height: 1100)
    /// `0 40px 100px`: 40pt of downward offset, and a CSS blur radius is about
    /// twice a layer's shadow radius, so 100px of spread is 50 here.
    static let focusCardShadowDrop: CGFloat = 40
    static let focusCardShadowBlur: CGFloat = 50

    /// How long a pane takes to grow into the zoom or shrink back out of it,
    /// with the backdrop fading over the same span. Slow enough to read as one
    /// pane lifting off the others rather than as a cut.
    static let zoomTransitionDuration: TimeInterval = 0.38

    /// How long two panes take to trade cells after a drop. Shorter than a zoom:
    /// nothing is lifting off the grid, the two are just changing places, and at
    /// the zoom's length that reads as sluggish.
    static let swapTransitionDuration: TimeInterval = 0.26

    /// The curve every part of the transition shares — the card, its shadow and
    /// the backdrop's fade. Front-loaded: about 85% of the distance is covered in
    /// the first third, then it eases out long and flat, so the card leaves fast
    /// and *settles* the way the Dock's genie does. The symmetric `easeInEaseOut`
    /// it replaces spent as long arriving as leaving, which reads as a slide.
    static let zoomTimingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)

    /// Non-zero only for the one layout pass a zoom change or a pane swap kicks
    /// off, so the panes' moves are animated there and nowhere else: every other
    /// pass (window resize, divider drag, session switch) has to land instantly.
    private var zoomTransition: TimeInterval = 0

    @discardableResult
    func toggleZoom(_ sessionID: String) -> Bool {
        guard paneIDs.count >= 2, paneIDs.contains(sessionID) else { return false }
        setZoomed(zoomedPaneID == sessionID ? nil : sessionID)
        return true
    }

    func setZoomed(_ sessionID: String?) {
        // The two conditions `toggleZoom` refuses on, checked here too because
        // this is the entry point ⌘↩, the palette and `revealPane` all reach:
        // a pane that is not on screen has nothing to be zoomed over, and with
        // one terminal the pane already fills the workspace. `nil` always goes
        // through — it is the way out, and must never be refusable.
        if let sessionID, paneIDs.count < 2 || !paneIDs.contains(sessionID) { return }
        guard zoomedPaneID != sessionID else { return }
        // Before anything else, so a transition still in flight — animated or the
        // instant Reduce Motion kind — can no longer finish on this one's behalf.
        zoomTransitionToken += 1
        let token = zoomTransitionToken
        zoomedPaneID = sessionID
        if let sessionID { focusPane(sessionID) }
        updateZoomAvailability()
        // Reduced motion still zooms, it just lands instantly — and so does a zoom
        // in a view with no window, where there is nothing on screen to animate
        // and an animation group's completion is not guaranteed to arrive at all.
        // Sequencing the landing behind one that never comes would strand the
        // transition half-done: the card left in the overlay, the backdrop parked
        // in the grid. True of the windowless tests, and of a window closed from
        // under a card.
        guard window != nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            updateLayout()
            return
        }
        zoomTransition = Self.zoomTransitionDuration
        // No `NSAnimationContext` group: every frame in the transition is animated
        // on its own layer instead (see `place`), and the transition's end is
        // scheduled below rather than handed to a group's completion handler.
        updateLayout()
        zoomTransition = 0
        // The end of the transition is scheduled rather than handed to an
        // animation group's completion, because there is no group left to hand it
        // to. A stale timer is harmless: `finishZoomTransition` refuses any token
        // but the current one.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.zoomTransitionDuration) {
            [weak self] in
            self?.finishZoomTransition(token)
        }
    }

    /// The end of one transition's 0.38s. Two outcomes, gated on the token
    /// so it only ever acts for the transition it was created by — see
    /// `zoomTransitionToken` — since a second transition starting invalidates
    /// whichever of these was still pending:
    /// - Shrink completed: the card that was shrinking lands back in the
    ///   grid, and with nothing focused any more the overlay comes out of
    ///   the window.
    /// - Anything else — a grow that settled, or a target changed since this
    ///   transition began: nothing to do.
    private func finishZoomTransition(_ token: Int) {
        guard token == zoomTransitionToken else { return }
        if overlayIsCollapsing, let id = overlayPaneID {
            landCard(id)
            teardownOverlay()
        }
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

    /// The card's rect inside the overlay: the host scaled down by one factor —
    /// so it keeps the window's proportions — centred, capped at
    /// `focusCardMaxSize`, and never closer than 26 to an edge. A window too
    /// small for the padding gives up the card's size rather than the padding,
    /// and never goes negative: the padding is what keeps the blur reading as a
    /// surround rather than a frame the card is jammed into.
    ///
    /// Static and pure so the geometry can be checked without a window.
    static func focusCardFrame(in host: NSRect) -> NSRect {
        // The most the card may take of this host on either axis, as one factor
        // applied to both. A per-axis cap would stretch the card away from the
        // window's shape on any display that is not 16:10.
        let fit = min(
            focusCardScale,
            host.width > 0 ? focusCardMaxSize.width / host.width : focusCardScale,
            host.height > 0 ? focusCardMaxSize.height / host.height : focusCardScale
        )
        let width = min(host.width * fit, max(0, host.width - focusOverlayPadding * 2))
            .rounded(.down)
        // Height's own fit, from `focusCardHeightScale` and the same cap. Always
        // at least `fit`, since that is bounded by the smaller scale and by this
        // very cap — so this only ever gives the card back vertical room the
        // width's share was never using.
        let heightFit = min(
            focusCardHeightScale,
            host.height > 0 ? focusCardMaxSize.height / host.height : focusCardHeightScale
        )
        let height = min(host.height * heightFit, max(0, host.height - focusOverlayPadding * 2))
            .rounded(.down)
        // Not rounded: `width`/`height` are already whole, and rounding an
        // origin derived from an *odd* one would land up to half a point off
        // true centre — invisible at the old 1280×800 cap, which happened to
        // divide evenly for every size a test asked for, but not a property
        // the geometry actually guaranteed.
        return NSRect(
            x: host.midX - width / 2,
            y: host.midY - height / 2,
            width: width,
            height: height
        )
    }

    /// Puts the overlay over the window's whole content view — the sidebar
    /// included — and hands back the view the backdrop and the card go in. A
    /// function rather than a computed property because reading it *installs*
    /// something, and only the zoom paths may ask for that.
    ///
    /// Falls back to this view when there is no window, which only happens in
    /// tests: the geometry is the same and the reparenting becomes a no-op.
    private func installOverlayHost() -> NSView {
        guard let content = window?.contentView else { return self }
        // Re-stacked only when something has landed on top of it, because
        // `addSubview` *moves* a view that is already there and moving one
        // resigns any first responder inside it — and the card in here holds the
        // terminal being typed into.
        if content.subviews.last !== focusOverlay {
            content.addSubview(focusOverlay, positioned: .above, relativeTo: nil)
        }
        // Re-asserted rather than left to the autoresizing mask alone: the
        // overlay is a subview the content view knows nothing about — that view
        // is the plain wrapper AppKit puts around the window's content view
        // controller, and the split view it manages is its own single child.
        focusOverlay.frame = content.bounds
        return focusOverlay
    }

    private func applyZoom() {
        guard let id = zoomedPaneID, let container = containers[id] else {
            return collapseZoom()
        }
        // Whatever card is in the overlay goes back to the grid before this one
        // lifts — unconditionally, whether it was shrinking or not.
        //
        // Gating this on `overlayIsCollapsing` covered only one of the two ways a
        // second pane can be focused. The other: ⌘↩ on pane A, then ⌘1…⌘9 or
        // ⌥arrow to move focus, neither of which clears the zoom, then ⌘↩ on pane
        // B. A is not collapsing, so it was skipped — and once `overlayPaneID`
        // named B instead, A was a pane nobody owned: the grid fed it cell rects
        // in the host's coordinates, and the next `teardownOverlay` carried it out
        // of the window for good, since nothing re-adds a container as a subview.
        // A live terminal and its session, off screen with no way back.
        //
        // This pane, if it is the one that was shrinking, is taken over mid-flight
        // rather than landed and lifted again: `leaving != id` leaves it alone and
        // the frame animation below picks it up from wherever the shrink got to.
        if let leaving = overlayPaneID, leaving != id {
            landCard(leaving)
        }
        overlayIsCollapsing = false
        let host = installOverlayHost()
        overlayPaneID = id
        // The lift starts where the pane already is, read in the host's
        // coordinates: the grid and the overlay are different views in the real
        // window, and a frame carried across unconverted would jump the length
        // of the sidebar.
        let lifting = container.superview !== host
        let start = lifting ? convert(container.frame, to: host) : focusCardShadow.frame
        let restacked = stackOverlay(container, in: host)
        // After any move, not just the lift: re-stacking a view that is already
        // there moves it too, and a move is what costs the first responder.
        if restacked { reclaimFirstResponder(container) }
        zoomBackdrop.setShown(true, duration: zoomTransition)
        let card = Self.focusCardFrame(in: host.bounds)
        moveFocusCardShadow(from: start, to: card)
        // The cell it is leaving, handed over rather than left for `place` to
        // read off the presentation layer: the pane has just changed superview,
        // and until the next commit that layer still presents the position it
        // held in the grid. Read in the host, a grid position is a rect a
        // sidebar's width away — which is where the lift used to appear to begin.
        place(container, at: card, from: lifting ? start : nil)
    }

    /// The overlay's two views as the host's top-most pair — the backdrop
    /// directly under the card, everything else behind both — with the card's
    /// shadow re-seated between them, since AppKit rebuilds the sublayer order
    /// from the subview order whenever that changes. Re-stacked only when
    /// something has landed on top, for the first-responder reason above.
    @discardableResult
    private func stackOverlay(_ container: PaneContainerView, in host: NSView) -> Bool {
        zoomBackdrop.frame = host.bounds
        guard Array(host.subviews.suffix(2)) != [zoomBackdrop, container] as [NSView] else {
            return false
        }
        host.addSubview(zoomBackdrop, positioned: .above, relativeTo: nil)
        host.addSubview(container, positioned: .above, relativeTo: zoomBackdrop)
        if let backdrop = zoomBackdrop.layer {
            host.layer?.insertSublayer(focusCardShadow, above: backdrop)
        }
        return true
    }

    /// Keeps the shadow on the card: the same rect, the same duration, the same
    /// curve, the same scale. Spelled out because a hand-added sublayer gets none
    /// of AppKit's view animation. Without it the shadow would sit at the card's
    /// final size while the card was still small — an opaque black rectangle
    /// around a growing pane. Scaled rather than resized for the same reason the
    /// card is, and so the two interpolate identically and stay locked together.
    ///
    /// `fadingOut` is the shrink, and it fades the shadow away over the same span
    /// rather than carrying it all the way down to the cell: a card's shadow
    /// around a grid-sized pane is a dark halo no pane ever has, and the overlay
    /// is torn down by a timer that cannot land on the exact frame the animation
    /// ends — so a shadow still at full strength there flickers, one way on
    /// either side of that timer. Faded, there is nothing left to catch the eye
    /// whichever side it falls on.
    private func moveFocusCardShadow(from start: NSRect, to card: NSRect, fadingOut: Bool = false) {
        focusCardShadow.frame = card
        focusCardShadow.opacity = fadingOut ? 0 : 1
        guard zoomTransition > 0, !start.isEmpty, start != card else { return }
        zoomLayer(
            focusCardShadow,
            fromPosition: CGPoint(x: start.midX, y: start.midY),
            fromSize: start.size,
            toSize: card.size
        )
        guard fadingOut else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.duration = zoomTransition
        fade.timingFunction = Self.zoomTimingFunction
        focusCardShadow.add(fade, forKey: "opacity")
    }

    /// Undoes the overlay: the backdrop fades, the card shrinks back to its grid
    /// cell — still in the host's coordinates, so the whole move happens in one
    /// space — and only once it has landed does it go back into this view, where
    /// `updateLayout` owns its frame again. Cheap and idempotent: every layout
    /// pass with nothing focused comes through here.
    private func collapseZoom() {
        zoomBackdrop.setShown(false, duration: zoomTransition)
        guard let id = overlayPaneID else { return }
        guard
            let container = containers[id],
            let host = container.superview,
            let cell = gridFrame(for: id),
            zoomTransition > 0 || overlayIsCollapsing
        else {
            // Nothing to shrink: the pane was closed out from under the card, or
            // its session left the screen and has no cell on this one to shrink
            // into, or motion is reduced and a zoom lands instantly.
            landCard(id)
            return teardownOverlay()
        }
        let target = convert(cell, to: host)
        if overlayIsCollapsing {
            // A shrink already in flight. It is aimed at the cell it was started
            // for, and the frame `place` left in the model *is* that aim, so an
            // unchanged target means this pass changed nothing the animation
            // cares about and it is left to finish. A changed one means the grid
            // reflowed under it — ⌘T in the 0.32s the card is still flying — and
            // the card goes home now rather than gliding to a cell that has
            // moved.
            guard container.frame != target else { return }
            landCard(id)
            return teardownOverlay()
        }
        // `place` rather than a frame assignment of its own: it animates inside
        // the transition's one animation group, and it schedules the PTY resize
        // the shrink needs — without it a full-screen TUI stays at the card's
        // ~1080 columns for 0.32s while the view is already cell-sized, and every
        // exit tears its output.
        overlayIsCollapsing = true
        moveFocusCardShadow(from: focusCardShadow.frame, to: target, fadingOut: true)
        place(container, at: target)
    }

    /// Puts the card back where the grid can have it: a subview of this view
    /// again, at its cell, reflowed, with the first responder the move cost it
    /// asked back. The completion of the shrink, and the direct path wherever
    /// there is nothing to animate.
    private func landCard(_ id: String) {
        if overlayPaneID == id {
            overlayPaneID = nil
            overlayIsCollapsing = false
        }
        guard let container = containers[id] else { return }
        // The shrink is over the moment the grid owns this frame again, so the
        // animation still in flight has to go with it — a surviving one replays the
        // host-space move after the reparent and slides the pane the width of the
        // sidebar. By key rather than `removeAllAnimations()`: these two are the
        // only ones this code adds, and yanking whatever else a layer happens to
        // be running is how you break something you did not write.
        container.layer?.removeAnimation(forKey: "position")
        container.layer?.removeAnimation(forKey: "transform")
        if container.superview !== self { addSubview(container) }
        if let cell = gridFrame(for: id) { container.frame = cell }
        container.surface.scheduleResize()
        reclaimFirstResponder(container)
    }

    /// Takes the overlay back out of the window once nothing is focused: the
    /// card's shadow, and the host with the backdrop still inside it. Nothing
    /// may be left over the app while the grid is unfocused — a plain view
    /// covering the content view hit-tests as itself, and would swallow every
    /// click meant for the sidebar or a pane.
    private func teardownOverlay() {
        focusCardShadow.removeFromSuperlayer()
        // The backdrop explicitly, not only with the host: where there is no
        // window the host is never installed and this view *is* the host, so
        // removing the host alone left a hidden backdrop parked in the grid for
        // the rest of the process. `stackOverlay` adds it back on the next zoom.
        zoomBackdrop.removeFromSuperview()
        focusOverlay.removeFromSuperview()
    }

    /// Moving a view between superviews resigns the first responder if it or a
    /// descendant held it. The card carries the terminal being typed into, so it
    /// is asked back — and only for the focused pane, so lifting or landing one
    /// card never takes the keyboard off another.
    private func reclaimFirstResponder(_ container: PaneContainerView) {
        guard let window, focusedPaneID == container.paneID else { return }
        // A descendant check rather than identity against one known view: a
        // WKWebView's actual responder is an internal content view, so identity
        // could never hold for it — and the terminal's `terminalView` is a
        // descendant of its surface, so the same rule covers both kinds.
        if let view = window.firstResponder as? NSView, view.isDescendant(of: container.surface) {
            return
        }
        container.surface.focus()
    }

    /// The cell a pane occupies in the grid as it stands — where a card being
    /// shrunk out of focus is heading, and the only thing the overlay needs from
    /// the grid it is covering.
    private func gridFrame(for sessionID: String) -> NSRect? {
        grid?.layout(in: gridBounds, dividerThickness: Self.dividerThickness).frames[sessionID]
    }

    /// The overlay lives in the window rather than in this view, so it does not
    /// go away when this view does: the shell hides the whole pane workspace
    /// when it switches away from Terminals (`applyDestination`), and a
    /// full-window blur left over a hidden grid would cover the app. The zoom
    /// itself is untouched, so coming back to Terminals shows the card again.
    override func viewDidHide() {
        super.viewDidHide()
        focusOverlay.isHidden = true
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        focusOverlay.isHidden = false
    }

    /// Moves a pane. The frame lands in the model immediately either way — so the
    /// terminal reflows once, at the size it ends up — and during a zoom
    /// transition the *layer* is animated into it from where it is currently
    /// presented.
    ///
    /// Deliberately not `NSView.animator()`, which is what this used to be, and
    /// this is hardening rather than a fix for anything that was failing. The
    /// animator wraps each group's frame change in an
    /// `_NSWindowTransformAnimation`, and instrumenting the transitions showed two
    /// of those alive on one view whenever a second transition began inside the
    /// first's 0.32s — a second ⌘↩, a ⌘2 hand-over, or a close. Nothing was
    /// observed to go wrong because of it, but it is AppKit bookkeeping this code
    /// has no need to stress: a CA animation of our own carries no such wrapper,
    /// and adding one under a key that already holds one *replaces* it, which is
    /// defined behaviour.
    ///
    /// `start` is where the move begins, for the one case the presentation layer
    /// cannot answer: a pane that has just been reparented, whose presented
    /// position is still the one it had in the view it left. Everywhere else it
    /// is `nil` and the presented value is exactly right — including a move that
    /// begins while another is still in flight.
    private func place(_ container: PaneContainerView, at frame: NSRect, from start: NSRect? = nil) {
        guard container.frame != frame || start != nil else { return }
        let from: (position: CGPoint, size: CGSize)?
        if let start, let layer = container.layer {
            // Through the frame rather than by computing a centre: `position` is
            // the layer's anchor point, and letting AppKit put the layer at
            // `start` is what makes this right for whatever anchor and whatever
            // flipped geometry the container happens to have.
            container.frame = start
            from = (layer.position, start.size)
        } else if let presented = (container.layer?.presentation() ?? container.layer) {
            // What is on screen right now: the presented bounds as its transform
            // is currently scaling them, so a move that begins mid-flight starts
            // from the size the eye can actually see.
            from = (
                presented.position,
                CGSize(
                    width: presented.bounds.width * presented.transform.m11,
                    height: presented.bounds.height * presented.transform.m22
                )
            )
        } else {
            from = nil
        }
        container.frame = frame
        if zoomTransition > 0, let layer = container.layer, let from {
            zoomLayer(layer, fromPosition: from.position, fromSize: from.size, toSize: frame.size)
        }
        container.surface.scheduleResize()
    }

    /// One move of the transition, as the pair of layer animations that expresses
    /// it: the transition's duration and curve, starting from wherever the layer
    /// is presented right now so a move that begins mid-flight carries on from
    /// what the eye can see instead of snapping back to the model value.
    ///
    /// A **scale**, not the `bounds` animation this used to be, and that is the
    /// whole of "the animation is off". Animating a container's bounds resizes
    /// only the container: its header and its terminal are laid out at the final
    /// size the instant the frame lands, so the card did not grow — a
    /// full-size pane was revealed through a widening window, with the terminal's
    /// text sitting still at its final position throughout. Scaling the layer
    /// carries everything drawn inside it, which is what reads as a zoom.
    ///
    /// Position comes from the presented value rather than a computed centre, so
    /// this is right for any `anchorPoint`: a scale is about the anchor and the
    /// position *is* the anchor, so the two interpolate the same rect either way.
    private func zoomLayer(
        _ layer: CALayer,
        fromPosition: CGPoint,
        fromSize: CGSize,
        toSize: CGSize
    ) {
        let move = CABasicAnimation(keyPath: "position")
        move.fromValue = NSValue(point: fromPosition)
        let zoom = CABasicAnimation(keyPath: "transform")
        zoom.fromValue = NSValue(caTransform3D: CATransform3DMakeScale(
            toSize.width > 0 ? fromSize.width / toSize.width : 1,
            toSize.height > 0 ? fromSize.height / toSize.height : 1,
            1
        ))
        zoom.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        for animation in [move, zoom] {
            animation.duration = zoomTransition
            animation.timingFunction = Self.zoomTimingFunction
            layer.add(animation, forKey: animation.keyPath)
        }
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
                // Closing re-homes focus, which is the same moment as a focus
                // command by another door — the palette closes a pane that is not
                // the card, and focus lands on a neighbour the card is not
                // showing. Where the *card* was closed, `validateZoom` has already
                // ended the zoom above and this does nothing.
                carryCardToFocusedPane()
            } else {
                updateFocusRings()
                onFocusedPaneChanged?(nil)
            }
        }
        onPanesChanged?()
        return true
    }

    /// Seats each session's panes in `order` — the saved order, restored.
    ///
    /// Restoration adds panes one at a time, and `PaneGrid.synced`'s 2 -> 3
    /// rule deliberately seats a *newly opened* third pane lower-left, ahead
    /// of the pane that was already there. Replayed over a saved layout that
    /// is not new, that rule swapped panes 2 and 3 on every launch — and,
    /// because the swapped order is what gets written back, swapped them
    /// again on the next one. A session whose panes are not all named in
    /// `order` is left exactly as it is.
    func reorderPanes(_ order: [String]) {
        for group in groupOrder {
            let ids = order.filter { descriptors[$0]?.group == group }
            guard let current = grids[group]?.paneIDs(), ids.count == current.count, ids != current else {
                continue
            }
            grids[group] = PaneGrid.build(ids)
        }
        updateVisibility()
        updateLayout()
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
        // The card's subtitle names its *session*, and the derived `Session N`
        // for unnamed ones is a position in a list — so naming any session
        // renumbers the rest, and a card showing one of those was left saying
        // the old number. Nothing else here refreshes it: this path changes one
        // pane's descriptor without a layout pass, and the layout pass is the
        // other place the subtitle is re-derived.
        refreshFocusSubtitles()
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
        carryCardToFocusedPane()
        return true
    }

    @discardableResult
    func swapWithNeighbor(_ direction: PaneDirection) -> Bool {
        guard let focusedPaneID, let neighbor = grid?.neighbor(of: focusedPaneID, direction: direction)
        else { return false }
        return swapPanes(focusedPaneID, neighbor)
    }

    /// 1-based, in fill order — what ⌘1…⌘9 select.
    @discardableResult
    func focusPane(at index: Int) -> Bool {
        let ids = paneIDs
        guard index >= 1, index <= ids.count else { return false }
        focusPane(ids[index - 1])
        carryCardToFocusedPane()
        return true
    }

    /// In focus mode the card is the only terminal on screen, so a command that
    /// moves *focus* moves the card with it: ask for pane 3 and you get pane 3, in
    /// the card. Without it the caret goes behind the blur and what the user types
    /// lands in a terminal they cannot see — the same harm `revealPane` fixes on
    /// its own path, so this makes "the card shows the focused pane" one rule
    /// everywhere rather than true on one path and not another.
    ///
    /// Called from the command entry points, never from `focusPane(_:)`, which
    /// `setZoomed` calls itself and would re-enter. Off-screen and cross-session
    /// targets need nothing extra: `setZoomed`'s own refusal and `validateZoom`
    /// already decide those, and this adds no third behaviour.
    ///
    /// The card is not the only thing riding on this. The blinking cursor follows
    /// `PaneContainerView.isFocused` into `TerminalSurfaceView.isSelected`, so
    /// "the terminal whose cursor blinks" and "the terminal in the card" are the
    /// same one *because* this holds — a focus-moving path that skips this helper
    /// leaves the blink behind the blur on a pane nobody can see, and reads as a
    /// cursor bug rather than a focus-mode one.
    private func carryCardToFocusedPane() {
        guard zoomedPaneID != nil, let focusedPaneID, zoomedPaneID != focusedPaneID else { return }
        setZoomed(focusedPaneID)
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

    /// The name the sidebar prints for a session: the one stored on its panes,
    /// else the same derived `Session N` the tree derives. Asked through
    /// `SessionOutline` rather than read off a descriptor, because the derived
    /// number is chosen against every *other* session's name in the project —
    /// a header that numbered sessions on its own would sooner or later
    /// disagree with the row the user picked the terminal from.
    func sessionLabel(forGroup group: String) -> String? {
        let panes = allPaneIDs.compactMap { descriptors[$0] }
        return SessionOutline.group(panes, focusedPaneID: focusedPaneID)
            .flatMap(\.sessions)
            .first { $0.id == group }?
            .label
    }

    /// The pane's 1-based position among the on-screen panes of its own session,
    /// and how many there are — the design's "terminal 1 of 4".
    ///
    /// Fill order, so the number matches what the eye counts across the grid.
    /// `nil` for a pane that is not on screen: a session sitting behind another
    /// one has no position in what you are looking at.
    func paneOrdinal(of sessionID: String) -> (index: Int, total: Int)? {
        guard let group = descriptors[sessionID]?.group else { return nil }
        // The filter is about the *session*, not the grid: a grid holds one
        // session's panes today, and reading the group here means this number
        // stays right if that ever stops being true.
        let siblings = paneIDs.filter { descriptors[$0]?.group == group }
        guard let index = siblings.firstIndex(of: sessionID) else { return nil }
        return (index + 1, siblings.count)
    }

    // MARK: - Drag and drop

    /// The one place a drop can mutate the grid: both ids must be live panes and
    /// they must differ.
    @discardableResult
    func performPaneDrop(from sourceID: String, onto targetID: String) -> Bool {
        guard canAcceptDrop(from: sourceID, onto: targetID) else { return false }
        let wasFocused = focusedPaneID
        // The two cells trade places on a glide rather than a cut. `place`
        // already animates every pane whose frame moves during a transition
        // window — position *and* scale, so cells of different sizes morph into
        // each other rather than jumping — and this borrows that for the one
        // layout pass the swap costs. Skipped under Reduce Motion, and with no
        // window there is nothing on screen to animate.
        if window != nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            zoomTransition = Self.swapTransitionDuration
        }
        defer { zoomTransition = 0 }
        // Both movers to the top of the stack first, or the glide passes *under*
        // whichever panes sit later in the subview order — a pane sliding behind
        // its neighbours, half of it gone for a quarter second. Source last, so
        // the pane you dragged is the one on top. They stay raised: settled panes
        // never overlap, so the order stops mattering the moment they land, and
        // re-stacking them again afterwards would only cost the terminal its
        // first responder a second time.
        for id in [targetID, sourceID] {
            guard let container = containers[id] else { continue }
            addSubview(container, positioned: .above, relativeTo: nil)
            // A moved view is removed and re-added, which is what loses focus.
            reclaimFirstResponder(container)
        }
        // Where each mover is leaving from, read before the grid changes under
        // them: the swap lays out immediately, so by the next line these frames
        // are the cells they are gliding *out* of.
        let flight = [targetID, sourceID].compactMap { id in containers[id].map { ($0, $0.frame) } }
        guard swapPanes(sourceID, targetID) else { return false }
        for (container, start) in flight { castGlideShadow(under: container, from: start) }
        if let wasFocused { focusPane(wasFocused) }
        return true
    }

    /// The soft drop a pane casts while it is in flight — faded in and back out
    /// across the glide, so a mover reads as lifted off the grid for the moment
    /// it is crossing it and flat again the instant it lands.
    ///
    /// Its own view sitting directly under the pane, rather than a shadow on
    /// the pane: `PaneContainerView` masks to bounds — that mask is what rounds
    /// its corners — and a mask clips its layer's own shadow away, the same
    /// reason the focus card's shadow is a separate layer. It carries the
    /// pane's exact frame and the same animation, so the pane covers its body
    /// completely and only the blur past the edges is ever seen.
    ///
    /// No-op outside a transition, which is what keeps this to the swap.
    private func castGlideShadow(under container: PaneContainerView, from start: NSRect) {
        guard zoomTransition > 0 else { return }
        let end = container.frame
        // A view rather than a hand-added layer, and inserted by subview order:
        // AppKit rebuilds the sublayer order from the subview order whenever
        // that changes, so a layer placed by index is a layer that can end up
        // anywhere. Below its own pane and above everything under it, which is
        // where a cast shadow belongs — the mover's falls across the pane it is
        // crossing, and its own body stays hidden beneath it.
        let shadow = NSView(frame: end)
        addSubview(shadow, positioned: .below, relativeTo: container)
        // In the hierarchy *before* `wantsLayer`, or there is no layer to
        // configure: a view has none until it joins one, and configuring nothing
        // is how the focus card's shadow silently went missing once already.
        shadow.wantsLayer = true
        guard let layer = shadow.layer else { return }
        layer.backgroundColor = NSColor.black.cgColor
        layer.cornerRadius = PaneContainerView.cornerRadius
        layer.cornerCurve = .continuous
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowOpacity = 1
        layer.shadowRadius = 16
        // Positive is *down*: this view is flipped, so AppKit flips its backing
        // layer's geometry to match, and the shadow is cast in that space.
        layer.shadowOffset = CGSize(width: 0, height: 8)
        // Spelled out rather than derived from the layer's alpha, which would
        // cost an offscreen pass a frame for both movers.
        layer.shadowPath = CGPath(
            roundedRect: CGRect(origin: .zero, size: end.size),
            cornerWidth: PaneContainerView.cornerRadius,
            cornerHeight: PaneContainerView.cornerRadius,
            transform: nil
        )
        // The model value stays 0, so the fade below is the only time this shows
        // at all — it is back to nothing before the teardown, whatever a dropped
        // frame does to the timing.
        layer.opacity = 0
        zoomLayer(
            layer,
            fromPosition: CGPoint(x: start.midX, y: start.midY),
            fromSize: start.size,
            toSize: end.size
        )
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 0.45
        fade.duration = zoomTransition / 2
        fade.autoreverses = true
        fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(fade, forKey: "opacity")
        // Scheduled rather than handed to a transaction's completion, for the
        // reason `setZoomed` gives: a completion that never arrives would leave
        // this behind for good, and a stale timer can only take away a view that
        // is already invisible.
        DispatchQueue.main.asyncAfter(deadline: .now() + zoomTransition) {
            shadow.removeFromSuperview()
        }
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
            // Whatever is in the overlay host — the card, or one still shrinking
            // out of it — has a frame in that host's coordinates, and `applyZoom`
            // is what sets it. Guarded on parentage rather than on zoom state,
            // which changes one layout pass earlier: `addPane` nils
            // `zoomedPaneID`, and a grid cell assigned to a pane still living in
            // the overlay slides it the width of the sidebar. Skipped rather than
            // assigned twice: each assignment schedules a PTY resize, and this
            // runs on every frame of a divider drag.
            guard id != overlayPaneID, let frame = layout.frames[id] else { continue }
            place(container, at: frame)
        }
        syncDividerViews(layout.dividers)
        syncHolePlaceholders(layout, holeIDs: grid.cells.filter(\.isHole).map(\.id))
        applyZoom()
        updateAccessibilityLabels()
        refreshFocusSubtitles()
    }

    /// The focused card's subtitle counts panes ("terminal 3 of 4"), so it goes
    /// stale whenever the on-screen set changes without anything touching the
    /// zoomed pane's own descriptor — closing a sibling renumbers the rest.
    ///
    /// Hooked to the layout pass, which is the pass that *means* "the panes
    /// changed", rather than to `updateAccessibilityLabels`: that one exists to
    /// serve assistive clients and is the sort of work a future author might
    /// reasonably skip when none is listening, which would take the subtitle
    /// quietly down with it.
    ///
    /// Only the zoomed pane, because only it can be showing a subtitle — and
    /// this runs on every frame of a divider drag or a live window resize, where
    /// re-deriving every session's name eight times a frame would be work for
    /// nothing.
    private func refreshFocusSubtitles() {
        guard let zoomedPaneID else { return }
        containers[zoomedPaneID]?.header.refreshSubtitle()
    }

    private func syncHolePlaceholders(_ layout: PaneLayout, holeIDs: [String]) {
        while holePlaceholders.count > holeIDs.count {
            holePlaceholders.removeLast().removeFromSuperview()
        }
        while holePlaceholders.count < holeIDs.count {
            let placeholder = PaneHolePlaceholderView(
                onActivate: { [weak self] in self?.onRequestNewPane?() },
                onActivateBrowser: { [weak self] in self?.onRequestNewBrowserPane?() },
                onActivateEditor: { [weak self] in self?.onRequestNewEditorPane?() }
            )
            placeholder.onDropEditorTab = { [weak self] payload in
                self?.onEditorTabDropOnHole?(payload)
            }
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

    /// ⌘1…⌘9 — the menu item's `tag` is the 1-based pane index in fill order.
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
    let surface: any PaneContentView
    let header: PaneHeaderView

    /// The pane's border, drawn as the container's own background showing
    /// through a 1pt gap around the header and terminal rather than as a
    /// `borderWidth`. Both children are opaque and tile the container, so a
    /// real border would be buried under them — and this way the rounded
    /// corner, the border and the "working" animation are all one layer.
    static let cornerRadius: CGFloat = 9
    /// `border-radius:12px` on the design's focused card, against 9 in the grid:
    /// the corner grows with the card it is rounding.
    static let focusedCornerRadius: CGFloat = 12
    static let borderWidth: CGFloat = 1

    /// `#0c0c0f` — the pane body behind the terminal, from the design's grid.
    static let paneBackgroundColor = NSColor(srgbRed: 12 / 255, green: 12 / 255, blue: 15 / 255, alpha: 1)
    /// Focus is the thing you look for most often in a grid of eight, so the
    /// selected pane's ring is a solid line and the rest recede to a
    /// hairline. At the old 0.45 the two were near enough that you had to hunt
    /// for the pane you were typing into.
    static let idleBorderColor = NSColor(white: 1, alpha: 0.06)
    /// What the focused ring falls back to while nothing has been reported
    /// yet — with a live status the ring wears that status's own colour
    /// instead (see `borderColor`).
    static let focusedBorderColor = NSColor(srgbRed: 139 / 255, green: 149 / 255, blue: 255 / 255, alpha: 0.85)
    /// The accent wash the selected pane's header carries, so the highlight is
    /// legible even where a neighbouring pane's ring sits right beside it.
    static let focusedHeaderTint = NSColor(srgbRed: 139 / 255, green: 149 / 255, blue: 255 / 255, alpha: 0.11)
    /// How solid the status-coloured ring is: bright on the focused pane, and
    /// still clearly visible on an unfocused one that has stopped to ask
    /// something or errored — urgency outranks focus, because that pane is
    /// the one the user must act on.
    static let focusedRingAlpha: CGFloat = 0.85
    static let urgentRingAlpha: CGFloat = 0.55
    static let dropTargetBorderColor = NSColor(srgbRed: 139 / 255, green: 149 / 255, blue: 255 / 255, alpha: 1)

    var isFocused = false {
        didSet {
            guard isFocused != oldValue else { return }
            header.isFocused = isFocused
            // The cursor is part of "which pane am I typing into": only this
            // one blinks (see `TerminalSurfaceView.isSelected`).
            surface.isSelected = isFocused
            updateChrome()
        }
    }

    /// The pane's live agent status, which drives the header's mark and the
    /// border. `nil` is "nothing reported yet", drawn as idle.
    var status: RemoteSessionStatus? {
        didSet {
            guard status != oldValue else { return }
            header.status = status
            // The unselected pane's veil is tinted by the same status.
            (surface as? TerminalSurfaceView)?.wash.status = status
            updateApprovalBar()
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
            // The card's corner is the design's 12, the grid pane's is 9.
            updateChrome()
        }
    }

    /// The drop tint, as a top-most sibling rather than a fill in `draw(_:)`,
    /// for the same compositing reason.
    let dropHighlight = PaneDropOverlayView()

    /// The design's amber strip along the bottom while the agent is blocked on
    /// a question — the question text plus one clickable button per on-screen
    /// option. Only a terminal pane ever shows it.
    let approvalBar = PaneApprovalBarView()

    /// Re-reads the dialog off the screen while the bar is up: an answered
    /// AskUserQuestion advances to its next question with the status still
    /// `awaitingApproval`, and nothing else would tell the buttons to change.
    private var approvalPollTimer: Timer?

    /// The pane ask on screen, while one is up — see `PaneAskOverlayView` for
    /// what a pane ask is and when something belongs in one.
    private(set) var askOverlay: PaneAskOverlayView?

    /// What a still-unanswered ask owes its caller. Cleared the instant an
    /// option or the cancel fires, so only a card torn down *without* an
    /// answer pays it — see `dismissAsk`.
    private var unansweredCancel: (() -> Void)?

    /// Puts `title`/`message` on glass over this pane and waits. Exactly one
    /// of `options` runs, or `onCancel` if the card is dismissed with Esc, a
    /// click outside it, or another ask taking its place — so a caller with an
    /// in-flight decision to settle (the editor's save prompt) always hears
    /// back exactly once.
    func presentAsk(
        title: String,
        message: String,
        icon: NSImage?,
        options: [PaneAskOption],
        onCancel: @escaping () -> Void = {}
    ) {
        dismissAsk()
        // A question nobody can see is a question nobody answers. This pane
        // may be in a session that is not on screen (`allPaneIDs` — the quit
        // walk asks about every pane in every session), in a window that is
        // behind another app, or behind a miniaturised one; the `NSAlert` this
        // replaced was app-modal and could be none of those. `focusPane` is
        // what brings another session to the screen, and the window and the
        // app are brought forward the way that alert brought them.
        workspace?.focusPane(paneID)
        if let window {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate()
        // Every answer takes the card down first: an option that reopens the
        // pane's own prompt (the editor's "save, then it is still dirty, ask
        // again") would otherwise be dismissed by the ask it just replaced.
        let overlay = PaneAskOverlayView(
            title: title,
            message: message,
            icon: icon,
            options: options.map { option in
                PaneAskOption(option.title, isPrimary: option.isPrimary) { [weak self] in
                    self?.unansweredCancel = nil
                    self?.dismissAsk()
                    option.action()
                }
            }
        )
        overlay.onCancel = { [weak self] in
            self?.unansweredCancel = nil
            self?.dismissAsk()
            onCancel()
        }
        addSubview(overlay, positioned: .above, relativeTo: nil)
        askOverlay = overlay
        unansweredCancel = onCancel
        needsLayout = true
        window?.makeFirstResponder(overlay)
    }

    func dismissAsk() {
        guard let overlay = askOverlay else { return }
        let hadKeyboard = window?.firstResponder === overlay
        overlay.removeFromSuperview()
        askOverlay = nil
        // Whoever asked hears back even when the card goes away without being
        // answered — a second ask replacing it, or a caller taking it down.
        // The editor has two independent askers (the save walk and the
        // watcher's on-disk conflict), and they were only ever safe together
        // because both were a blocking `runModal`. Dropping one silently
        // stranded its completion: `editorPaneDrainInFlight` stuck on, editor
        // persistence off for the session, and a ⌘Q that never gets its answer.
        let owed = unansweredCancel
        unansweredCancel = nil
        // Hand the keyboard back to whatever the pane holds — a cancelled
        // question must leave the terminal exactly as it found it.
        if hadKeyboard { workspace?.focusPane(paneID) }
        owed?()
    }

    private weak var workspace: PaneWorkspaceView?
    private var workingRing: CAGradientLayer?

    init(paneID: String, surface: any PaneContentView, workspace: PaneWorkspaceView) {
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
        header.onRenameRequested = { [weak self] in
            guard let self else { return }
            self.workspace?.focusPane(self.paneID)
            self.workspace?.onRequestRenamePane?(self.paneID)
        }
        header.onColorMenuRequested = { [weak self] anchor in
            guard let self else { return }
            self.workspace?.focusPane(self.paneID)
            self.workspace?.onRequestColorMenu?(self.paneID, anchor)
        }
        header.onEngineMenuRequested = { [weak self] anchor in
            guard let self else { return }
            self.workspace?.focusPane(self.paneID)
            self.workspace?.onRequestEngineMenu?(self.paneID, anchor)
        }
        // The design's `session restore · terminal 1 of 4`. A closure rather
        // than a stored string because the ordinal is a fact about the
        // workspace, not about this pane: a sibling closing while this one is
        // zoomed changes "of 4" and nothing would tell the header to rewrite it.
        header.subtitleProvider = { [weak self] in
            guard
                let self,
                let workspace = self.workspace,
                let ordinal = workspace.paneOrdinal(of: self.paneID),
                let descriptor = workspace.descriptor(for: self.paneID),
                // Whatever the sidebar calls this session, including the derived
                // `Session N` for one nobody has named: the subtitle is two
                // parts in the design, and a card that dropped the name half
                // for unnamed sessions would show it for hardly any of them.
                let session = workspace.sessionLabel(forGroup: descriptor.group)
            else { return nil }
            let noun: String
            switch descriptor.kind {
            case .browser: noun = "browser"
            case .editor: noun = "editor"
            case .terminal: noun = "terminal"
            }
            return "\(session) · \(noun) \(ordinal.index) of \(ordinal.total)"
        }
        addSubview(header)
        // Opaque for the same reason the header is: the container's background
        // is the border colour, and a terminal theme with any transparency
        // would let it wash across the whole pane.
        surface.wantsLayer = true
        surface.layer?.backgroundColor = Self.paneBackgroundColor.cgColor
        addSubview(surface)
        approvalBar.isHidden = true
        approvalBar.onChoose = { [weak self] input in
            (self?.surface as? TerminalSurfaceView)?.sendInput(input)
        }
        addSubview(approvalBar)
        addSubview(dropHighlight, positioned: .above, relativeTo: nil)
        updateChrome()
        registerForDraggedTypes([PaneWorkspaceView.paneDragType, PaneWorkspaceView.editorTabDragType])
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
        // The header's own height, not the grid constant: focus mode makes the
        // bar taller, and only the header knows which treatment it is wearing.
        let headerHeight = header.currentHeight
        let width = max(0, bounds.width - inset * 2)
        header.frame = CGRect(
            x: inset,
            y: inset,
            width: width,
            height: min(headerHeight, max(0, bounds.height - inset * 2))
        )
        let barHeight = approvalBar.isHidden ? 0 : PaneApprovalBarView.height
        surface.frame = CGRect(
            x: inset,
            y: inset + headerHeight,
            width: width,
            height: max(0, bounds.height - headerHeight - barHeight - inset * 2)
        )
        approvalBar.frame = CGRect(
            x: inset,
            y: inset + headerHeight + surface.frame.height,
            width: width,
            height: barHeight
        )
        dropHighlight.frame = bounds
        askOverlay?.frame = bounds
        workingRing?.frame = bounds
    }

    private func updateChrome() {
        let radius = isZoomed ? Self.focusedCornerRadius : Self.cornerRadius
        layer?.cornerRadius = radius
        layer?.cornerCurve = .continuous
        // The mask is what rounds the terminal's own square corners. It costs
        // one offscreen pass per pane, which is why nothing else here (no
        // shadow, no filter) adds a second one — the focused card's
        // `box-shadow` is a layer of the overlay host for exactly this reason,
        // since this mask would clip a shadow of its own away.
        layer?.masksToBounds = true
        layer?.backgroundColor = borderColor.cgColor
        roundChildren(inside: radius)
        dropHighlight.isHidden = !isDropTarget
        updateWorkingRing()
    }

    /// The two children get the corner the container's mask would otherwise cut
    /// out of the ring. Both are square and inset by exactly `borderWidth`, so
    /// along a straight edge the container's background shows through as a 1pt
    /// border — but at a corner the child's square corner runs straight into the
    /// mask's arc and the ring pinches out to nothing there. Rounding each child
    /// one radius smaller, concentric inside the container's, keeps the gap the
    /// same 1pt the whole way round.
    ///
    /// `maskedCorners` is resolved in each child's **own** coordinate space —
    /// AppKit manages the backing layers' geometry flips to preserve every
    /// view's own convention, so this container being flipped says nothing
    /// about which literal pair a child needs. Naming `MaxY` "the bottom" for
    /// every child put the unflipped terminal surface's rounding at its *top*
    /// on screen: an accent wedge under the header's hairline, and the ring
    /// pinching out to nothing at the pane's bottom corners — while the same
    /// literal pair was correct on the flipped browser surface. The offscreen
    /// render harness cannot show the difference (`CALayer.render(in:)` skips
    /// the compositor's geometry flips), which is how it went unseen.
    private func roundChildren(inside radius: CGFloat) {
        let inner = max(0, radius - Self.borderWidth)
        header.wantsLayer = true
        surface.wantsLayer = true
        // The screen-bottom corner pair belongs to whichever child sits on the
        // bottom edge — the approval bar takes it over while it is showing.
        func screenBottom(of child: NSView) -> CACornerMask {
            child.isFlipped
                ? [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
                : [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        }
        func screenTop(of child: NSView) -> CACornerMask {
            child.isFlipped
                ? [.layerMinXMinYCorner, .layerMaxXMinYCorner]
                : [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        }
        for (child, corners) in [
            (header as NSView, screenTop(of: header)),
            (surface as NSView, approvalBar.isHidden ? screenBottom(of: surface) : []),
            (approvalBar as NSView, screenBottom(of: approvalBar)),
        ] {
            child.layer?.cornerRadius = inner
            child.layer?.cornerCurve = .continuous
            child.layer?.maskedCorners = corners
            child.layer?.masksToBounds = true
        }
    }

    /// Shows the approval bar while a terminal's agent is blocked on a dialog,
    /// and keeps its buttons matching the screen: a 0.5s re-parse while up,
    /// because the status event arrives once but the dialog keeps changing
    /// (an answered question advances to the next one, still awaiting).
    private func updateApprovalBar() {
        guard status == .awaitingApproval, surface is TerminalSurfaceView else {
            guard !approvalBar.isHidden else { return }
            approvalPollTimer?.invalidate()
            approvalPollTimer = nil
            approvalBar.isHidden = true
            needsLayout = true
            return
        }
        approvalBar.isHidden = false
        refreshApprovalPrompt()
        if approvalPollTimer == nil {
            let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
                self?.refreshApprovalPrompt()
            }
            timer.tolerance = 0.2
            RunLoop.main.add(timer, forMode: .common)
            approvalPollTimer = timer
        }
        needsLayout = true
    }

    func refreshApprovalPrompt() {
        guard let terminal = surface as? TerminalSurfaceView else { return }
        approvalBar.prompt = ApprovalPrompt.parse(lines: terminal.visibleTailLines())
    }

    deinit {
        approvalPollTimer?.invalidate()
    }

    /// Which colour the 1pt ring takes: a drop in flight first, then the
    /// pane's live status in the sidebar's own palette — the ring, the
    /// header's mark and the tree's dots must never disagree, which is why
    /// this reads `PaneStatusMarkView.color(for:)` instead of keeping its own
    /// copies. Focus brightens the ring; a question or an error keeps it
    /// visible even on an unfocused pane, whose other statuses recede to the
    /// hairline (the mark and the wash still carry them there).
    private var borderColor: NSColor {
        if isDropTarget { return Self.dropTargetBorderColor }
        if isFocused {
            guard let status else { return Self.focusedBorderColor }
            return PaneStatusMarkView.color(for: status).withAlphaComponent(Self.focusedRingAlpha)
        }
        switch status {
        case .awaitingApproval, .error:
            return PaneStatusMarkView.color(for: status).withAlphaComponent(Self.urgentRingAlpha)
        default:
            return Self.idleBorderColor
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
        header.engine = descriptor.kind == .terminal ? descriptor.engine : nil
        header.isEngineMenuAvailable = descriptor.kind == .terminal
        header.isRenameAvailable = descriptor.kind == .terminal
        // Color badge: only Claude terminals support `/color`.
        header.claudeColor = descriptor.kind == .terminal && descriptor.engine == .claude
            ? descriptor.claudeColor : nil
        // Its session's name is half the focus subtitle, so a rename has to
        // reach the bar. A no-op unless this pane is the zoomed one.
        header.refreshSubtitle()
    }

    func updateAccessibilityLabel(index: Int, of total: Int) {
        let noun: String
        switch workspace?.descriptor(for: paneID)?.kind {
        case .browser: noun = "browser"
        case .editor: noun = "editor"
        case .terminal, nil: noun = "terminal"
        }
        let position = "\(noun) pane \(index) of \(total)"
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
        if editorTabPayload(from: sender) != nil {
            // Assigned either way: the answer changes as the pointer crosses
            // from a pane's centre into an edge band on a full grid, and a
            // highlight left up under a no-drop cursor is a lie.
            isDropTarget = editorTabDropZone(for: sender) != nil
            return isDropTarget ? .move : []
        }
        guard let source = sender.draggingPasteboard.string(forType: PaneWorkspaceView.paneDragType),
              workspace?.canAcceptDrop(from: source, onto: paneID) == true
        else { return [] }
        isDropTarget = true
        return .move
    }

    /// AppKit only reuses `draggingEntered`'s answer while a destination does
    /// not implement this — and an editor tab's answer changes as the pointer
    /// crosses from a pane's edge band into its centre on a full grid.
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingEntered(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        isDropTarget = false
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        isDropTarget = false
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isDropTarget = false
        if let payload = editorTabPayload(from: sender) {
            // Re-asked rather than remembered: a refusal must mutate nothing,
            // and `performDragOperation` is reachable without an `entered`.
            guard let zone = editorTabDropZone(for: sender) else { return false }
            workspace?.onEditorTabDropOnPane?(payload, paneID, zone)
            return true
        }
        guard let source = sender.draggingPasteboard.string(forType: PaneWorkspaceView.paneDragType)
        else { return false }
        return workspace?.performPaneDrop(from: source, onto: paneID) ?? false
    }

    private func editorTabPayload(from sender: NSDraggingInfo) -> EditorTabDragPayload? {
        EditorTabDragPayload.decode(
            sender.draggingPasteboard.string(forType: PaneWorkspaceView.editorTabDragType)
        )
    }

    /// What a tab dropped at the pointer would do here, or `nil` for the
    /// no-drop cursor. Two refusals, both the spec's: a terminal or browser
    /// pane never grows tabs, and an edge drop needs a free grid cell —
    /// `PaneGrid.maxPanes`, the same bound ⇧⌘E is refused by.
    private func editorTabDropZone(for sender: NSDraggingInfo) -> EditorTabDropZone? {
        guard workspace?.descriptor(for: paneID)?.kind == .editor else { return nil }
        let zone = EditorTabDropZone.zone(at: convert(sender.draggingLocation, from: nil), in: bounds)
        guard zone == .center || workspace?.hasRoomForAnotherPane(inGroupOf: paneID) == true else {
            return nil
        }
        return zone
    }
}

/// The view the focus overlay's backdrop and card live in, covering the window's
/// whole content view.
///
/// Hit-transparent on its own account: `super.hitTest` still answers with the
/// backdrop or the card when the point is over one of them, but the host itself
/// is never the answer. Without that it swallows every click meant for the
/// sidebar or a pane for the 0.32s of an exit — it stays mounted until the
/// transition's completion tears it down, and the backdrop stops taking clicks
/// as soon as the fade starts, so for that third of a second an invisible plain
/// view is all there is over the app.
final class PaneFocusOverlayView: NSView {
    /// The workspace the pane commands belong to.
    ///
    /// While a card is up the responder chain from the terminal runs
    /// `terminalView → card → this host → the window's content view`, and
    /// `PaneWorkspaceView` is not on it — so the nine pane selectors it
    /// implements answer to nothing and all sixteen Panes-menu items (⌘⌥arrows,
    /// ⌃⌘arrows, ⌘1…⌘9) grey out, which they do not do with no card up. AppKit
    /// asks each responder for a supplemental target when it does not handle an
    /// action itself, and uses the answer for validation as well as dispatch,
    /// which is exactly what is wanted here.
    ///
    /// Not `nextResponder`: AppKit reassigns that whenever a view is reparented,
    /// and this host's whole job is to hold a view that is being reparented.
    weak var commandTarget: PaneWorkspaceView?

    /// The nine pane commands, and nothing else. Forwarding whatever the
    /// workspace merely *responds to* would also forward the selectors it
    /// inherits from `NSView` — `print:` is the classic — so a Print item added
    /// later would resolve to the pane grid while a card is up and to the window
    /// the rest of the time, which is the kind of difference that gets diagnosed
    /// slowly. The set is closed, greppable, and cannot drift with the class.
    private static let forwardedCommands: Set<Selector> = [
        #selector(PaneWorkspaceView.focusPaneLeft(_:)),
        #selector(PaneWorkspaceView.focusPaneRight(_:)),
        #selector(PaneWorkspaceView.focusPaneUp(_:)),
        #selector(PaneWorkspaceView.focusPaneDown(_:)),
        #selector(PaneWorkspaceView.swapPaneLeft(_:)),
        #selector(PaneWorkspaceView.swapPaneRight(_:)),
        #selector(PaneWorkspaceView.swapPaneUp(_:)),
        #selector(PaneWorkspaceView.swapPaneDown(_:)),
        #selector(PaneWorkspaceView.selectPane(_:)),
    ]

    override func supplementalTarget(forAction action: Selector, sender: Any?) -> Any? {
        if Self.forwardedCommands.contains(action), let commandTarget { return commandTarget }
        return super.supplementalTarget(forAction: action, sender: sender)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
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
/// the branch it is on, and the controls: a ⋯ menu and a macOS traffic-light
/// cluster — yellow, green, red. Also the drag handle — the whole bar is
/// grabbable except where a button sits.
///
/// It draws two treatments, switched by `isZoomed`: the grid pane's bar, and the
/// focused card's taller one with a bigger name and a `session · terminal N of
/// M` subtitle (design line 1070). The mark, the engine badge, the branch badge
/// and the cluster are identical in both — the delta is deliberately only what
/// tells you *this pane is the one blown up over the others*.
final class PaneHeaderView: NSView {
    /// A grid pane's bar is `height:30px`; the focused card's is `34px` (design
    /// line 1070). A pane reads `currentHeight` rather than either static: the
    /// header is the only thing that knows which treatment it is wearing.
    static let height: CGFloat = 30
    static let focusHeight: CGFloat = 34

    /// `padding:0 6px 0 10px;gap:8px` in the grid against `0 7px 0 12px` and
    /// `gap:9px` on the focused card. The focus bar is not the grid's scaled
    /// up — it is the same bar with more air in it.
    private static let leadingInset: CGFloat = 10
    private static let trailingInset: CGFloat = 6
    private static let gap: CGFloat = 8
    private static let focusLeadingInset: CGFloat = 12
    private static let focusTrailingInset: CGFloat = 7
    private static let focusGap: CGFloat = 9
    private static let markSize: CGFloat = 15

    var currentHeight: CGFloat { isZoomed ? Self.focusHeight : Self.height }
    private var currentLeadingInset: CGFloat { isZoomed ? Self.focusLeadingInset : Self.leadingInset }
    private var currentTrailingInset: CGFloat { isZoomed ? Self.focusTrailingInset : Self.trailingInset }
    private var currentGap: CGFloat { isZoomed ? Self.focusGap : Self.gap }

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
            // The focused bar's bottom hairline wears the status colour too.
            needsDisplay = true
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

    /// The design's `session restore · terminal 1 of 4`, drawn only while
    /// zoomed. Never assigned from outside: it is resolved through
    /// `subtitleProvider` every time the bar could be showing it, because the
    /// count in it goes stale on its own — a sibling closing changes "of 4"
    /// without touching *this* pane's descriptor, so nothing would tell a
    /// stored string to update.
    private(set) var subtitle: String? {
        didSet {
            guard subtitle != oldValue else { return }
            subtitleLabel.stringValue = subtitle ?? ""
            subtitleLabel.isHidden = subtitle == nil
            needsLayout = true
        }
    }

    /// Asked for the subtitle on the way into focus and whenever the pane's
    /// metadata moves under it. `PaneContainerView` supplies it, since the
    /// ordinal is a fact about the workspace and not about one pane.
    var subtitleProvider: (() -> String?)?

    var onDragOut: ((NSEvent) -> Void)?
    var onZoomRequested: (() -> Void)?
    var onCloseRequested: (() -> Void)?
    /// The pencil button — fires when the user clicks ✏️ to rename. The bar
    /// builds no dialog itself; the window controller owns the prompt.
    var onRenameRequested: (() -> Void)?
    /// The color badge, clicked — opens the Claude color picker menu.
    var onColorMenuRequested: ((NSView) -> Void)?
    /// The engine badge, clicked — the badge says which agent drives this
    /// PTY, so it is also where you change it.
    var onEngineMenuRequested: ((NSView) -> Void)?

    var isZoomAvailable = false {
        didSet {
            guard isZoomAvailable != oldValue else { return }
            applyControlState()
        }
    }

    /// Whether the pencil rename affordance is live. Only terminal panes can
    /// be renamed — a browser or editor pane has no conversation to give a name.
    var isRenameAvailable = false {
        didSet {
            guard isRenameAvailable != oldValue else { return }
            applyControlState()
        }
    }

    /// The active Claude color for this terminal, or `nil` when the pane does
    /// not run Claude. Setting it shows/hides and updates the color badge.
    var claudeColor: String? {
        didSet {
            guard claudeColor != oldValue else { return }
            colorBadge.isHidden = claudeColor == nil
            if let claudeColor {
                colorBadge.configure(
                    icon: PaneHeaderView.colorDotImage(for: claudeColor),
                    text: "",
                    foreground: NSColor(white: 1, alpha: 0.55),
                    fill: NSColor(white: 1, alpha: 0.07),
                    stroke: .clear,
                    font: ShellFont.ui(12, .medium)
                )
            }
            needsLayout = true
        }
    }

    /// A 10×10 filled circle in the colour `/color` uses for this name.
    static func colorDotImage(for color: String) -> NSImage {
        let fill: NSColor
        switch color {
        case "red": fill = .systemRed
        case "blue": fill = .systemBlue
        case "green": fill = .systemGreen
        case "yellow": fill = .systemYellow
        case "purple": fill = .systemPurple
        case "orange": fill = .systemOrange
        case "pink": fill = .systemPink
        case "cyan": fill = .systemTeal
        default: fill = NSColor(white: 1, alpha: 0.4)
        }
        return NSImage(size: NSSize(width: 10, height: 10), flipped: false) { rect in
            fill.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).fill()
            return true
        }
    }

    /// Whether the engine badge opens the engine menu. Only a terminal runs an
    /// engine — a browser or editor pane carries a placeholder `.shell` the
    /// badge already hides, and a badge that opened a menu about it would be
    /// offering to swap an engine the pane does not have.
    var isEngineMenuAvailable = false {
        didSet {
            guard isEngineMenuAvailable != oldValue else { return }
            engineBadge.onClick = isEngineMenuAvailable
                ? { [weak self] in
                    guard let self else { return }
                    self.onEngineMenuRequested?(self.engineBadge)
                }
                : nil
            // The chevron changes the badge's width.
            needsLayout = true
        }
    }

    /// The whole focus treatment, from the focused card at design line 1070: a
    /// taller bar with more air in it, a bigger and brighter title, and the
    /// `session · terminal N of M` subtitle. The controls do not move — the
    /// cluster answers a zoom by swapping which discs are live, which is the
    /// point of a cluster: the way out is already on screen, in the place it
    /// will always be, rather than a control that appears where another was.
    var isZoomed = false {
        didSet {
            guard isZoomed != oldValue else { return }
            applyEmphasis()
            applyControlState()
            refreshSubtitle()
            // The pane's layout reads `currentHeight`, and a subview growing
            // does not invalidate its parent's layout by itself.
            superview?.needsLayout = true
            needsDisplay = true
        }
    }

    private let mark = PaneStatusMarkView()
    private let titleLabel: NSTextField
    private let subtitleLabel: NSTextField
    private let engineBadge = PaneBadgeView()
    /// Color dot + chevron badge shown on Claude panes — opens the `/color` menu.
    private let colorBadge = PaneBadgeView()
    /// ✏️ button shown immediately after the title — tap to rename the conversation.
    private let renamePencilButton = PanePencilButton()
    /// The cluster, in the order it reads: yellow restores the pane from a
    /// zoom, green blows it up, red closes it.
    private let restoreButton: PaneHeaderButton
    private let zoomButton: PaneHeaderButton
    private let closeButton: PaneHeaderButton

    private var mouseDownEvent: NSEvent?

    init(title: String) {
        self.title = title
        titleLabel = ShellFont.label(
            title,
            font: ShellFont.ui(14.5, .medium),
            color: NSColor(srgbRed: 208 / 255, green: 208 / 255, blue: 216 / 255, alpha: 1)
        )
        // `400 14px`, `#5c5c66` — quieter than the title it follows, because it
        // says where the terminal sits rather than what it is.
        subtitleLabel = ShellFont.label(
            "",
            font: ShellFont.ui(14),
            color: NSColor(srgbRed: 92 / 255, green: 92 / 255, blue: 102 / 255, alpha: 1)
        )
        restoreButton = PaneHeaderButton(glyph: .restore)
        zoomButton = PaneHeaderButton(glyph: .expand)
        closeButton = PaneHeaderButton(glyph: .close)
        super.init(frame: .zero)
        wantsLayer = true
        titleLabel.translatesAutoresizingMaskIntoConstraints = true
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = true
        subtitleLabel.isHidden = true
        engineBadge.isHidden = true
        colorBadge.isHidden = true
        renamePencilButton.isHidden = true
        renamePencilButton.onClick = { [weak self] in self?.onRenameRequested?() }
        colorBadge.onClick = { [weak self] in
            guard let self else { return }
            self.onColorMenuRequested?(self.colorBadge)
        }
        zoomButton.onClick = { [weak self] in self?.onZoomRequested?() }
        // The same toggle, reached from the other side: yellow is live only
        // while this pane is zoomed, so "toggle" there can only mean "get out".
        restoreButton.onClick = { [weak self] in self?.onZoomRequested?() }
        closeButton.onClick = { [weak self] in self?.onCloseRequested?() }
        restoreButton.trafficLight = .yellow
        zoomButton.trafficLight = .green
        closeButton.trafficLight = .red
        // Added left to right, the order they are laid out in, so the subview
        // order a reader — or a test — walks is the order on screen.
        let views: [NSView] = [
            mark, titleLabel, renamePencilButton, subtitleLabel, colorBadge, engineBadge,
            restoreButton, zoomButton, closeButton,
        ]
        for view in views { addSubview(view) }
        // Same reason the surface applies its cursor state up front: the header
        // starts unfocused and unzoomed, so the didSets that dim the title and
        // pick the controls never fire for a pane that is never selected.
        applyEmphasis()
        applyControlState()
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override var isFlipped: Bool { true }

    private func applyEmphasis() {
        // `600 15.5px` / `#f0f0f4` zoomed against `500 14.5px` in the grid: the
        // focused card's name is the only terminal name on screen, so it stops
        // being one label among eight and carries the card.
        titleLabel.font = isZoomed ? ShellFont.ui(15.5, .semibold) : ShellFont.ui(14.5, .medium)
        if isZoomed {
            titleLabel.textColor = NSColor(srgbRed: 240 / 255, green: 240 / 255, blue: 244 / 255, alpha: 1)
            return
        }
        titleLabel.textColor = isFocused
            ? NSColor(srgbRed: 240 / 255, green: 241 / 255, blue: 248 / 255, alpha: 1)
            // An unselected pane stays perfectly readable, it just stops competing.
            : NSColor(srgbRed: 154 / 255, green: 154 / 255, blue: 164 / 255, alpha: 1)
    }

    /// Which discs are live. All three are always *there*: a cluster is read by
    /// position, so a control that cannot act right now greys out where it
    /// stands rather than letting the others slide into its place.
    ///
    /// - Yellow only means something once there is a zoom to come back from.
    /// - Green is the way in, so it is off while you are already in — and off
    ///   entirely with a single pane on screen, which has nothing to zoom over.
    /// - Red goes off while zoomed for the reason the design's focused card
    ///   carried no close button at all: closing the terminal you just blew up
    ///   over the others is not what the card is for, and ⌘W still does it.
    private func applyControlState() {
        restoreButton.isEnabled = isZoomed
        zoomButton.isEnabled = isZoomAvailable && !isZoomed
        closeButton.isEnabled = !isZoomed
        renamePencilButton.isHidden = !isRenameAvailable
        needsLayout = true
    }

    /// Re-asks `subtitleProvider`, which is also how the subtitle is cleared on
    /// the way out of focus. Cheap enough to call on any metadata change: a
    /// rename while zoomed has to reach the bar you are looking at.
    func refreshSubtitle() {
        subtitle = isZoomed ? subtitleProvider?() : nil
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // Opaque, because the container's own background is now the pane's
        // border colour and would otherwise show straight through.
        PaneContainerView.paneBackgroundColor.setFill()
        bounds.fill()
        // The focused card's own `rgba(255,255,255,.05)` over a `.5px
        // rgba(255,255,255,.08)` hairline, with the accent wash a selected pane
        // wears in the grid stepping aside: that wash is there to pick one pane
        // out of eight, and with a single card on a blurred backdrop the
        // question answers itself — the pane's own accent ring still says it.
        if isZoomed {
            NSColor(white: 1, alpha: 0.05).setFill()
            bounds.fill()
            NSColor(white: 1, alpha: 0.08).setFill()
            NSRect(x: 0, y: bounds.maxY - 0.5, width: bounds.width, height: 0.5).fill()
            return
        }
        if isFocused {
            PaneContainerView.focusedHeaderTint.setFill()
        } else {
            NSColor(white: 1, alpha: 0.03).setFill()
        }
        bounds.fill()
        if isFocused {
            // The ring's own colour, dimmed — status first, accent while
            // nothing has been reported yet, same rule as the border.
            let ring = status.map(PaneStatusMarkView.color(for:))
                ?? PaneContainerView.focusedBorderColor
            ring.withAlphaComponent(0.4).setFill()
        } else {
            NSColor(white: 1, alpha: 0.07).setFill()
        }
        NSRect(x: 0, y: bounds.maxY - 0.5, width: bounds.width, height: 0.5).fill()
    }

    override func layout() {
        super.layout()
        let gap = currentGap
        let middle = (bounds.height - Self.markSize) / 2
        mark.frame = CGRect(
            x: currentLeadingInset,
            y: middle,
            width: Self.markSize,
            height: Self.markSize
        )

        // Right to left: the controls first, then whichever badges still fit.
        // The title takes what is left, which is what makes a narrow pane drop
        // the engine rather than clipping its own name.
        var right = bounds.maxX - currentTrailingInset
        // Right to left, so the cluster reads yellow, green, red — and abutting,
        // which puts 20pt between disc centres exactly as macOS does.
        for button in [closeButton, zoomButton, restoreButton] where !button.isHidden {
            let size = button.intrinsicContentSize
            right -= size.width
            button.frame = CGRect(
                x: right,
                y: (bounds.height - size.height) / 2,
                width: size.width,
                height: size.height
            )
        }

        let titleLeft = mark.frame.maxX + gap
        let minimumTitleWidth: CGFloat = 40
        // Color badge (Claude only) sits left of the engine badge, same as the
        // old branch badge — it drops before the engine if there is no room.
        for badge in [colorBadge, engineBadge] where !badge.isHidden {
            let size = badge.intrinsicContentSize
            let candidate = right - gap - size.width
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

        let available = max(0, right - gap - titleLeft)

        // Pencil button reservation: placed immediately after the title text.
        let pencilSize = renamePencilButton.fittingSize
        let pencilGap: CGFloat = 4
        let pencilReserve: CGFloat = renamePencilButton.isHidden ? 0 : pencilSize.width + pencilGap

        let titleNatural = ceil(titleLabel.fittingSize.width)
        let titleHeight = ceil(titleLabel.fittingSize.height)
        var titleWidth: CGFloat
        if !subtitleLabel.isHidden {
            // Zoomed: title + pencil + subtitle. The subtitle describes where
            // the pane sits; the pencil sits between name and subtitle so it is
            // still visually coupled to the title.
            let subtitleSize = subtitleLabel.fittingSize
            let subtitleWidth = ceil(subtitleSize.width)
            let subtitleHeight = ceil(subtitleSize.height)
            let room = available - pencilReserve - gap - subtitleWidth
            if room >= max(minimumTitleWidth, titleNatural) {
                titleWidth = titleNatural
                var afterTitle: CGFloat
                if !renamePencilButton.isHidden {
                    let pencilX = titleLeft + titleWidth + pencilGap
                    renamePencilButton.frame = CGRect(
                        x: pencilX,
                        y: (bounds.height - pencilSize.height) / 2,
                        width: pencilSize.width,
                        height: pencilSize.height
                    )
                    afterTitle = pencilX + pencilSize.width + gap
                } else {
                    // Pencil absent: subtitle directly after the name at the
                    // design's own gap, not the smaller pencil gap.
                    afterTitle = titleLeft + titleWidth + gap
                }
                subtitleLabel.frame = CGRect(
                    x: afterTitle,
                    y: (bounds.height - subtitleHeight) / 2,
                    width: subtitleWidth,
                    height: subtitleHeight
                )
            } else {
                // Not enough space — drop subtitle and pencil; just the title.
                subtitleLabel.frame = .zero
                renamePencilButton.frame = .zero
                titleWidth = min(titleNatural, available)
            }
        } else {
            // Non-zoomed: title at natural width, pencil immediately after.
            titleWidth = min(titleNatural, max(0, available - pencilReserve))
            if !renamePencilButton.isHidden {
                let pencilX = titleLeft + titleWidth + pencilGap
                if pencilX + pencilSize.width <= right {
                    renamePencilButton.frame = CGRect(
                        x: pencilX,
                        y: (bounds.height - pencilSize.height) / 2,
                        width: pencilSize.width,
                        height: pencilSize.height
                    )
                } else {
                    renamePencilButton.frame = .zero
                }
            }
        }

        titleLabel.frame = CGRect(
            x: titleLeft,
            y: (bounds.height - titleHeight) / 2,
            width: max(0, titleWidth),
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
        // Tool execution shares thinking's blue and differs only in motion: the
        // same pulse, run faster. Colour says "the agent is working"; the tempo
        // says which kind of work.
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1
        pulse.toValue = 0.45
        switch status {
        case .toolExecution: pulse.duration = 0.35
        case .thinking: pulse.duration = 0.9
        default: pulse.duration = 1.1
        }
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
    private static let chevron: CGFloat = 7

    private var icon: NSImage?
    private var text = ""
    private var foreground: NSColor = .labelColor
    private var fill: NSColor = .clear
    private var stroke: NSColor = .clear
    private var font: NSFont = .systemFont(ofSize: 12)

    /// Set to make the badge a button: it grows a chevron, lights under the
    /// pointer and drops a menu. The engine badge has one, the branch badge
    /// does not — a branch is a fact, an engine is a choice.
    var onClick: (() -> Void)? {
        didSet {
            let clickable = onClick != nil
            setAccessibilityElement(clickable)
            setAccessibilityRole(clickable ? .popUpButton : .unknown)
            invalidateIntrinsicContentSize()
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
            // The badge learns it is a button *after* it is in the hierarchy —
            // the header only hears which engine a pane runs once the
            // descriptor arrives — so its hover region has to be built now
            // rather than at whatever frame change happens to come next.
            updateTrackingAreas()
        }
    }

    private var isHovered = false { didSet { needsDisplay = true } }
    private var tracking: NSTrackingArea?

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
            width: ceil(Self.horizontalInset * 2 + iconWidth + textWidth + chevronWidth),
            height: Self.height
        )
    }

    private var chevronWidth: CGFloat { onClick == nil ? 0 : Self.chevron + Self.gap }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        guard onClick != nil else { return }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = onClick != nil }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { onClick != nil }

    override func resetCursorRects() {
        guard onClick != nil else { return }
        addCursorRect(bounds, cursor: .pointingHand)
    }

    /// On the way *down*, the way every menu button on macOS opens — and the
    /// click is swallowed either way so it never reaches the header's
    /// drag-the-pane-out handler behind it.
    override func mouseDown(with event: NSEvent) {
        guard let onClick else { return }
        isHovered = false
        onClick()
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return onClick != nil
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.25, dy: 0.25), xRadius: 5, yRadius: 5)
        fill.setFill()
        path.fill()
        // The hover lift, on the badge's own hue: a pill that opens a menu has
        // to say so before it is clicked, and the engine colours are the whole
        // point of the badge — brightening them beats a grey wash over them.
        if isHovered {
            foreground.withAlphaComponent(0.16).setFill()
            path.fill()
        }
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
        guard onClick != nil else { return }
        // A 7pt ⌄ in the badge's own colour, dimmed — the affordance, not a
        // second thing to read.
        let x = left + ceil(size.width) + Self.gap
        let mid = bounds.height / 2
        let chevron = NSBezierPath()
        chevron.move(to: NSPoint(x: x, y: mid - 1.5))
        chevron.line(to: NSPoint(x: x + Self.chevron / 2, y: mid + 2))
        chevron.line(to: NSPoint(x: x + Self.chevron, y: mid - 1.5))
        chevron.lineWidth = 1.3
        chevron.lineCapStyle = .round
        chevron.lineJoinStyle = .round
        foreground.withAlphaComponent(0.75).setStroke()
        chevron.stroke()
    }
}

/// The ✏️ button that appears to the right of the pane title, indicating the
/// conversation can be renamed. Dims at rest, brightens on hover, and shows
/// a "Rename conversation" tooltip for discoverability.
final class PanePencilButton: NSView {
    var onClick: (() -> Void)?

    private var isHovered = false {
        didSet { alphaValue = isHovered ? 1 : 0.5 }
    }
    private var tracking: NSTrackingArea?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        alphaValue = 0.5
        toolTip = "Rename conversation"
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Rename conversation")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize { NSSize(width: 16, height: 16) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = onClick != nil }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseDown(with event: NSEvent) {
        isHovered = false
        onClick?()
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let emoji = "✏️"
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11)]
        let size = (emoji as NSString).size(withAttributes: attrs)
        (emoji as NSString).draw(
            at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2),
            withAttributes: attrs
        )
    }
}

/// One answer on a **pane ask** — the label, and what pressing it does.
struct PaneAskOption {
    let title: String
    /// The filled accent button. At most one per ask, always drawn rightmost,
    /// and the one Return activates.
    let isPrimary: Bool
    let action: () -> Void

    init(_ title: String, isPrimary: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.isPrimary = isPrimary
        self.action = action
    }
}

/// # Pane ask
///
/// The one way a pane asks a question that must be answered before it can go
/// on: the pane itself goes behind Liquid Glass and the question sits in the
/// middle of it. Which of twelve panes is asking is then answered by *where
/// the card is*, before a word of it is read.
///
/// Deliberately not an `NSAlert`. A sheet hangs off the window and says
/// nothing about which pane it means — and what is being decided (this
/// terminal's conversation, this editor's unsaved buffer) is on screen right
/// behind the glass, which is the whole argument for the decision.
///
/// **Every blocking pane-scoped question goes through here**: swapping a
/// terminal's engine, closing an editor tab over unsaved edits, a file that
/// changed on disk under a dirty buffer. Anything new that the user must
/// answer before *their pane* can continue belongs here too, not in an alert.
/// Window-scoped questions (quitting, "which pane should this link open in?")
/// are not pane asks and stay alerts — they are not about one pane.
///
/// Two deliberate departures from the amber card this replaced. The glass is
/// navy, the same wash Spotlight (`CommandPaletteController`) wears, because
/// amber in this app means "an agent is blocked and waiting" and a question
/// about the user's own next move is not that. And the icon is the *subject*
/// of the question — the engine being switched to, the file about to be lost —
/// not a warning triangle, which said "danger" where the answer is a choice.
final class PaneAskOverlayView: NSView {
    /// Esc, or a click on the glass outside the card — the way clicking
    /// outside a popover dismisses it.
    var onCancel: (() -> Void)?

    /// The answers, left to right as they are drawn.
    private(set) var options: [PaneAskOption]

    /// The pane accent, not the approval bar's amber. See the note above.
    static let accent = NSColor(srgbRed: 139 / 255, green: 149 / 255, blue: 255 / 255, alpha: 1)

    private static let cardWidth: CGFloat = 330
    private static let padding: CGFloat = 22
    private static let iconSize: CGFloat = 30
    private static let buttonHeight: CGFloat = 26
    private static let cardRadius: CGFloat = 16

    /// The glass, on macOS 26. Two panels: the pane-sized one that puts the
    /// pane behind glass, and the card's own. `nil` before 26, where `draw`
    /// paints flat navy instead — every pre-26 stand-in for glass inside one
    /// window's compositing tree is a flat tint with no blur anyway (see
    /// `PaneZoomBackdropView`), so it may as well be an honest fill.
    private let scrim: NSView?
    private let cardGlass: NSView?
    /// The navy wash over the card's glass, as its own view so it can sit
    /// between the glass and the text. Spotlight's construction exactly:
    /// `.regular` glass with a gradient tint in front of it, rather than the
    /// glass view's flat `tintColor`.
    private let cardTint = NSView()
    private let cardTintLayer = CAGradientLayer()
    /// Spotlight's own navy, top-down, copied rather than shared: the palette
    /// is a separate window with a separate life, and reaching into it for two
    /// colours would tie a pane's overlay to whatever that panel does next.
    private static let navyTint = [
        NSColor(srgbRed: 0.11, green: 0.16, blue: 0.38, alpha: 0.40).cgColor,
        NSColor(srgbRed: 0.05, green: 0.08, blue: 0.22, alpha: 0.14).cgColor,
    ]
    /// The subject of the question, for the test that the right one is shown.
    var icon: NSImage? { iconView.image }

    private let iconView = NSImageView()
    private let titleLabel: NSTextField
    private let messageLabel: NSTextField
    private let buttons: [PaneApprovalButton]
    private var cardFrame: NSRect = .zero

    init(title: String, message: String, icon: NSImage?, options: [PaneAskOption]) {
        self.options = options
        titleLabel = Self.label(title, font: ShellFont.ui(15, .semibold), color: NSColor(
            srgbRed: 240 / 255, green: 240 / 255, blue: 244 / 255, alpha: 1
        ))
        messageLabel = Self.label(message, font: ShellFont.ui(13), color: NSColor(
            srgbRed: 176 / 255, green: 180 / 255, blue: 198 / 255, alpha: 1
        ))
        buttons = options.map {
            PaneApprovalButton(title: $0.title, isPrimary: $0.isPrimary, tint: Self.accent)
        }
        if #available(macOS 26.0, *) {
            let pane = NSGlassEffectView()
            // `.clear`, untinted — the same call focus mode makes, for the same
            // reason: the pane behind the question is glassed, not coloured and
            // not dimmed. A tint here is a wash over everything behind the
            // panel, which puts the card's navy on the surroundings too.
            pane.style = .clear
            pane.tintColor = nil
            scrim = pane
            let card = NSGlassEffectView()
            card.style = .regular
            card.cornerRadius = Self.cardRadius
            // No tint: `cardTint` is the card's colour, gradient like Spotlight's.
            card.tintColor = nil
            cardGlass = card
        } else {
            scrim = nil
            cardGlass = nil
        }
        super.init(frame: .zero)
        wantsLayer = true
        iconView.image = icon
        // Only reaches the template engine marks (Shell, Copilot) and the SF
        // symbols the editor asks with; the colour brand logos ignore it.
        iconView.contentTintColor = NSColor(white: 1, alpha: 0.92)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        cardTint.wantsLayer = true
        cardTintLayer.colors = Self.navyTint
        cardTintLayer.startPoint = CGPoint(x: 0.5, y: 1)
        cardTintLayer.endPoint = CGPoint(x: 0.5, y: 0)
        cardTint.layer?.addSublayer(cardTintLayer)
        cardTint.layer?.cornerRadius = Self.cardRadius
        cardTint.layer?.cornerCurve = .continuous
        cardTint.layer?.masksToBounds = true
        cardTint.layer?.borderWidth = 1
        cardTint.layer?.borderColor = NSColor(white: 1, alpha: 0.16).cgColor
        for (index, button) in buttons.enumerated() {
            button.onClick = { [weak self] in self?.options[index].action() }
        }
        for view in [scrim, cardGlass, cardTint, iconView, titleLabel, messageLabel].compactMap({ $0 })
            + (buttons as [NSView])
        {
            addSubview(view)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(title)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    private static func label(_ text: String, font: NSFont, color: NSColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = font
        field.textColor = color
        field.alignment = .center
        field.lineBreakMode = .byWordWrapping
        field.maximumNumberOfLines = 0
        return field
    }

    override var isFlipped: Bool { true }

    /// The card takes the keyboard while it is up, so Return and Esc answer
    /// it and nothing else reaches the pane underneath — a question about
    /// throwing work away must not be answered by typing into it.
    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: // Return, Enter
            guard let primary = options.first(where: { $0.isPrimary }) else { return NSSound.beep() }
            primary.action()
        case 53: onCancel?() // Esc
        default: NSSound.beep()
        }
    }

    /// A click on the glass is a cancel. Inside the card it is swallowed and
    /// nothing else.
    override func mouseDown(with event: NSEvent) {
        guard !cardFrame.contains(convert(event.locationInWindow, from: nil)) else { return }
        onCancel?()
    }

    override func layout() {
        super.layout()
        scrim?.frame = bounds
        let padding = Self.padding
        let width = min(Self.cardWidth, max(160, bounds.width - 32))
        let content = width - padding * 2
        let titleHeight = Self.height(of: titleLabel, width: content)
        let messageHeight = Self.height(of: messageLabel, width: content)
        let height = padding + Self.iconSize + 12 + titleHeight + 8 + messageHeight
            + 18 + Self.buttonHeight + padding
        cardFrame = NSRect(
            x: ((bounds.width - width) / 2).rounded(),
            y: max(0, ((bounds.height - height) / 2)).rounded(),
            width: width,
            height: height
        )
        cardGlass?.frame = cardFrame
        cardTint.frame = cardFrame
        cardTintLayer.frame = cardTint.bounds
        var y = cardFrame.minY + padding
        iconView.frame = NSRect(
            x: cardFrame.midX - Self.iconSize / 2,
            y: y,
            width: Self.iconSize,
            height: Self.iconSize
        )
        y += Self.iconSize + 12
        titleLabel.frame = NSRect(x: cardFrame.minX + padding, y: y, width: content, height: titleHeight)
        y += titleHeight + 8
        messageLabel.frame = NSRect(x: cardFrame.minX + padding, y: y, width: content, height: messageHeight)
        y += messageHeight + 18
        // Given order, left to right, with the primary last — where every
        // macOS dialog puts the button you are most likely to want, so the
        // muscle memory is already correct.
        let gap: CGFloat = 9
        let widths = buttons.map { $0.intrinsicContentSize.width }
        let total = widths.reduce(0, +) + gap * CGFloat(max(0, buttons.count - 1))
        var x = cardFrame.midX - total / 2
        for (button, buttonWidth) in zip(buttons, widths) {
            button.frame = NSRect(x: x, y: y, width: buttonWidth, height: Self.buttonHeight)
            x += buttonWidth + gap
        }
    }

    /// Wrapped-text height, measured off the string rather than asked of the
    /// cell: the message is two or three lines and the card's height is built
    /// from it, so it has to be right before the field is ever laid out.
    private static func height(of field: NSTextField, width: CGFloat) -> CGFloat {
        let font = field.font ?? ShellFont.ui(13)
        let rect = (field.stringValue as NSString).boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        )
        return ceil(rect.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // Only before macOS 26, where there is no glass to ask for. With the
        // panels present this would be painting *behind* them, and the scrim
        // samples the window backing — so it would darken its own input.
        guard scrim == nil else { return }
        // Neutral, not navy: only the card is tinted.
        NSColor(white: 0, alpha: 0.62).setFill()
        bounds.fill()
        let card = NSBezierPath(
            roundedRect: cardFrame,
            xRadius: Self.cardRadius,
            yRadius: Self.cardRadius
        )
        NSColor(srgbRed: 0.09, green: 0.12, blue: 0.26, alpha: 1).setFill()
        card.fill()
        NSColor(white: 1, alpha: 0.16).setStroke()
        let ring = NSBezierPath(
            roundedRect: cardFrame.insetBy(dx: 0.5, dy: 0.5),
            xRadius: Self.cardRadius,
            yRadius: Self.cardRadius
        )
        ring.lineWidth = 1
        ring.stroke()
    }
}

/// The one sheet of glass this app lays over the workspace.
///
/// Focus mode's backdrop and the spotlight's surround are the same material at
/// the same strength, from here — they are the same gesture ("push the
/// workspace back, keep it readable") and had drifted into two settings of it.
///
/// `.clear`, untinted, and just short of full strength. `strength` is the one
/// knob, and it was found by walking it: at `1` the material frosts hard enough
/// that you stop recognising which pane is which, and at `0.62` so much of the
/// sharp original comes back through that it reads as a transparent wash rather
/// than as glass. `0.85` is the frost that still leaves the workspace legible.
enum WorkspaceGlass {
    static let strength: CGFloat = 0.85

    /// The sheet, or `nil` before macOS 26 — where there is no glass to ask
    /// for and every stand-in dims rather than refracts, so the callers leave
    /// it out entirely.
    static func sheet(cornerRadius: CGFloat = 0) -> NSView? {
        guard #available(macOS 26.0, *) else { return nil }
        let glass = NSGlassEffectView()
        glass.style = .clear
        // Explicitly none: a tint is a wash of colour over everything behind
        // the sheet, which is exactly the darkening this exists without.
        glass.tintColor = nil
        glass.cornerRadius = cornerRadius
        glass.alphaValue = strength
        return glass
    }
}

/// The glass a zoomed pane sits on: one panel the size of the window, with the
/// card in front of it — macOS 26's own Liquid Glass (`NSGlassEffectView`), the
/// system material itself rather than a stand-in for it, so what is behind it in
/// this window is what it refracts: the panes, the sidebar, everything the card
/// does not cover.
///
/// `.clear` rather than `.regular`, and no tint, no forced dark appearance:
/// focus mode refracts the workspace, it does not darken it. `.regular` carries
/// the material's own dimming fill, which is the one thing this panel must not
/// do — the surroundings stay as bright as they were, just glassed.
///
/// Before macOS 26 there is no glass to ask for and the panel is left out
/// entirely, because every pre-26 stand-in dims: `.withinWindow` blending
/// samples sibling views inside one window's private compositing tree, which in
/// this window produces a flat tint and no blur at all (confirmed on screen),
/// and real blur without glass needed auxiliary windows tiling the region around
/// the card — that existed, read as seams and square corners rather than as
/// blur, and was removed. So on older systems the backdrop is nothing but the
/// click-catcher that gets you out of focus.
final class PaneZoomBackdropView: NSView {
    var onClick: (() -> Void)?

    /// The panel itself, on macOS 26. Sized in `layout` rather than by an
    /// autoresizing mask, which starts from this view's own zero frame and has
    /// nothing to scale.
    private let effect: NSView?

    private var isShown = false

    init() {
        effect = WorkspaceGlass.sheet()
        super.init(frame: .zero)
        // Explicit, though an effect view is layer-backed anyway: this view does
        // not *have* a `layer` until it joins a hierarchy, and the card's shadow
        // is inserted directly above that layer — with none there, `stackOverlay`
        // silently left the shadow out.
        wantsLayer = true
        if let effect { addSubview(effect) }
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

    override func layout() {
        super.layout()
        effect?.frame = bounds
    }

    /// Fades the panel in and out, in step with the card's own flight. Hidden
    /// only once it has faded out, never left invisible-but-present: it swallows
    /// clicks.
    func setShown(_ shown: Bool, duration: TimeInterval) {
        guard isShown != shown else { return }
        isShown = shown
        if shown { isHidden = false }
        // Glass is made to be looked through and carries its own translucency,
        // so it shows at full strength.
        let alpha: CGFloat = shown ? 1 : 0
        guard duration > 0 else {
            alphaValue = alpha
            isHidden = !shown
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = PaneWorkspaceView.zoomTimingFunction
            animator().alphaValue = alpha
        }, completionHandler: { [weak self] in
            // Checked again: a zoom started mid-fade-out must not be hidden.
            guard let self, !self.isShown else { return }
            self.isHidden = true
        })
    }

    // Swallowed, so a click meant for "get me out of here" never reaches — or
    // focuses — the pane behind it.
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) { onClick?() }

    /// Transparent to the mouse unless it is actually showing. `isHidden` only
    /// becomes true once the fade-out has landed, and for those 0.32s an
    /// invisible backdrop would still hit-test as itself and swallow the click —
    /// which now means every click in the window, sidebar included, since this
    /// covers the whole content view rather than the pane grid. The same idiom
    /// `PaneDropOverlayView` uses, conditioned on being shown rather than flat.
    override func hitTest(_ point: NSPoint) -> NSView? {
        isShown ? super.hitTest(point) : nil
    }
}

/// A control in the pane header, in one of two shapes: the grid's bare 20pt icon
/// square, or — given a `label` — the focused card's bordered pill. Hand-drawn
/// rather than an `NSButton` + SF Symbol so the glyphs match the design's own
/// strokes, the same way `ShellGlyph` does for the sidebar.
final class PaneHeaderButton: NSView {
    enum Glyph { case expand, restore, close, menu }

    /// Which disc of the header's cluster this is. The colours are macOS's own
    /// because the whole point of borrowing the shape is that nobody has to be
    /// taught what three coloured dots in a title bar do.
    enum TrafficLight {
        case yellow, green, red

        var fill: NSColor {
            switch self {
            case .yellow: return NSColor(srgbRed: 254 / 255, green: 188 / 255, blue: 46 / 255, alpha: 1)
            case .green: return NSColor(srgbRed: 40 / 255, green: 200 / 255, blue: 64 / 255, alpha: 1)
            case .red: return NSColor(srgbRed: 255 / 255, green: 95 / 255, blue: 87 / 255, alpha: 1)
            }
        }

        /// The glyph riding on the disc: a dark tint of the disc itself, the way
        /// macOS draws its own, rather than black on colour.
        var glyphColor: NSColor {
            switch self {
            case .yellow: return NSColor(srgbRed: 89 / 255, green: 51 / 255, blue: 0, alpha: 0.72)
            case .green: return NSColor(srgbRed: 0, green: 61 / 255, blue: 7 / 255, alpha: 0.72)
            case .red: return NSColor(srgbRed: 77 / 255, green: 0, blue: 0, alpha: 0.72)
            }
        }
    }

    /// The grid header's controls, `width:20px;height:20px`.
    static let iconSize: CGFloat = 20

    /// A disc that cannot act right now: grey, with its glyph still faintly on
    /// it. It keeps its place in the cluster rather than vanishing, so the three
    /// positions never shuffle and you can still see *which* control is off.
    private static let disabledFill = NSColor(srgbRed: 72 / 255, green: 72 / 255, blue: 80 / 255, alpha: 1)
    private static let disabledGlyph = NSColor(white: 1, alpha: 0.26)

    var onClick: (() -> Void)?
    var hoverTint = NSColor(srgbRed: 223 / 255, green: 226 / 255, blue: 255 / 255, alpha: 1)
    var hoverFill = NSColor(srgbRed: 139 / 255, green: 149 / 255, blue: 255 / 255, alpha: 0.22)

    /// macOS's traffic-light treatment: a filled disc of this colour. Unlike a
    /// window's own, the glyph is drawn at rest rather than only under the
    /// pointer — a pane's cluster is one small thing in a busy bar, and it has
    /// to say what it does without being hunted for first.
    var trafficLight: TrafficLight? { didSet { needsDisplay = true } }

    /// Whether pressing it means anything right now. A disabled control still
    /// draws and still reserves its slot; it just goes grey, stops answering the
    /// pointer, and tells assistive technology it is unavailable.
    var isEnabled = true {
        didSet {
            guard isEnabled != oldValue else { return }
            // Otherwise a control disabled with the pointer resting on it keeps
            // the hover it can no longer act on.
            if !isEnabled { isHovered = false }
            setAccessibilityEnabled(isEnabled)
            needsDisplay = true
        }
    }

    private let glyph: Glyph
    private var isHovered = false { didSet { needsDisplay = true } }
    private var tracking: NSTrackingArea?

    init(glyph: Glyph) {
        self.glyph = glyph
        super.init(frame: .zero)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        // A coloured disc draws no words, so the name is the only thing Voice
        // Control and VoiceOver have to go on — and the yellow one is the only
        // place the escape hatch is spelled out at all. Kind-neutral wording,
        // since the pane may hold a browser as well as a terminal.
        switch glyph {
        case .expand: setAccessibilityLabel("Zoom this pane")
        case .restore: setAccessibilityLabel("Restore this pane · esc")
        case .menu: setAccessibilityLabel("Pane options")
        case .close: setAccessibilityLabel("Close this pane")
        }
    }

    /// Assistive presses go the same way a click does. `NSView` gives a view with
    /// `.button` role no press behaviour of its own, so without this a disc is
    /// visible and named to VoiceOver and does nothing when it is activated —
    /// and it refuses for the same reason a click does while it is disabled.
    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        onClick?()
        return onClick != nil
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Self.iconSize, height: Self.iconSize)
    }

    /// The 16 unit box the glyph is drawn in: the whole button for the bare ⋯
    /// icon, and inside the disc for a traffic light. Three abutting 20pt
    /// squares put 20pt between disc centres, which is macOS's own spacing.
    private var glyphBox: NSRect {
        // The disc is 12pt inside the 20pt square, and the glyph sits inside it.
        trafficLight == nil ? bounds : bounds.insetBy(dx: 6, dy: 6)
    }

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

    override func mouseEntered(with event: NSEvent) { isHovered = isEnabled }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard isEnabled, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClick?()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if let trafficLight {
            (isEnabled
                ? trafficLight.fill.withAlphaComponent(isHovered ? 1 : 0.92)
                : Self.disabledFill).setFill()
            NSBezierPath(ovalIn: bounds.insetBy(dx: 4, dy: 4)).fill()
        } else if isHovered {
            hoverFill.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
        }
        // A disc's glyph is a dark tint of the disc and is always on it; the
        // bare ⋯ icon is the one that lights up under the pointer instead.
        let color: NSColor
        if let trafficLight {
            color = isEnabled ? trafficLight.glyphColor : Self.disabledGlyph
        } else {
            color = isHovered
                ? hoverTint
                : NSColor(srgbRed: 130 / 255, green: 130 / 255, blue: 140 / 255, alpha: 1)
        }
        color.setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1.4
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        // Every glyph is drawn in the design's own 16x16 box and scaled to fit.
        let box = glyphBox
        let scale = box.width / 16
        func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            NSPoint(x: box.minX + x * scale, y: box.minY + y * scale)
        }
        /// A filled right triangle. Solid, not stroked: inside a 12pt disc the
        /// glyph gets an 8pt box, and at that size a stroked bracket is mush
        /// where a wedge still reads.
        func wedge(_ corners: [(CGFloat, CGFloat)]) {
            let shape = NSBezierPath()
            shape.move(to: point(corners[0].0, corners[0].1))
            for step in corners.dropFirst() { shape.line(to: point(step.0, step.1)) }
            shape.close()
            color.setFill()
            shape.fill()
        }
        switch glyph {
        case .expand:
            // macOS's own fullscreen glyph: two wedges shouldered into opposite
            // corners, mass at the outside — "blow this pane up over the rest".
            wedge([(2.2, 2.2), (9.2, 2.2), (2.2, 9.2)])
            wedge([(13.8, 13.8), (6.8, 13.8), (13.8, 6.8)])
        case .restore:
            // macOS's minimize bar. Inside an 8pt disc a single stroke reads
            // where a wedge pair does not.
            path.move(to: point(3.6, 8))
            path.line(to: point(12.4, 8))
        case .close:
            // Shared with EditorTabStripView's tab-close accessory — see
            // drawXGlyph in EditorTabStripView.swift — so the two × glyphs
            // cannot drift apart.
            drawXGlyph(in: box, color: color, lineWidth: path.lineWidth)
        case .menu:
            // Three dots — filled rather than stroked, which is the only way
            // they read at this size.
            color.setFill()
            for x in [4.4, 8.0, 11.6] as [CGFloat] {
                let dot = point(x, 8)
                NSBezierPath(ovalIn: NSRect(x: dot.x - 1.2, y: dot.y - 1.2, width: 2.4, height: 2.4))
                    .fill()
            }
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
/// deliberate empty slot rather than a rendering bug) and clickable: a row of
/// icon buttons in the middle of the cell — Terminal, Browser, Editor —
/// laid out like the Dock, each its own hit target.
///
/// Drawn rather than composed from subviews: three plates and three labels are
/// less code as geometry than as views to keep in layout sync. The "blurred"
/// backdrop is three radial gradients — a real blur filter buys nothing over a
/// gradient whose edge is already transparent.
final class PaneHolePlaceholderView: NSView {
    private struct Item {
        let symbol: String
        let label: NSString
        /// `nil` for an affordance that does not exist yet: the button draws
        /// dimmed and refuses the click, rather than lying about being live.
        let action: (() -> Void)?
    }

    private let items: [Item]

    /// An editor tab dropped in this empty cell. The cell is a hole precisely
    /// because the grid is not full, so the pane it asks for always fits.
    var onDropEditorTab: ((EditorTabDragPayload) -> Void)?

    private static let accent = NSColor(srgbRed: 139 / 255, green: 149 / 255, blue: 255 / 255, alpha: 1)
    private static let labelAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 11, weight: .medium),
        .foregroundColor: NSColor(srgbRed: 150 / 255, green: 157 / 255, blue: 186 / 255, alpha: 1),
    ]
    private static let labelHoverAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 11, weight: .medium),
        .foregroundColor: NSColor(srgbRed: 214 / 255, green: 218 / 255, blue: 240 / 255, alpha: 1),
    ]
    private static let labelHeight =
        ("Ag" as NSString).size(withAttributes: labelAttributes).height
    private static let plateSize: CGFloat = 54
    private static let plateGap: CGFloat = 16
    private static let labelGap: CGFloat = 9

    private var hoveredIndex: Int? {
        didSet { if hoveredIndex != oldValue { needsDisplay = true } }
    }

    init(
        onActivate: @escaping () -> Void,
        onActivateBrowser: (() -> Void)? = nil,
        onActivateEditor: (() -> Void)? = nil
    ) {
        items = [
            Item(symbol: "terminal", label: "Terminal", action: onActivate),
            Item(symbol: "globe", label: "Browser", action: onActivateBrowser),
            Item(symbol: "doc.text", label: "Editor", action: onActivateEditor),
        ]
        super.init(frame: .zero)
        wantsLayer = true
        registerForDraggedTypes([PaneWorkspaceView.editorTabDragType])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        // The single assistive press stays "Add terminal": the other kinds
        // remain reachable through the menu, palette, toolbar and sidebar.
        setAccessibilityLabel("Add terminal")
    }

    // MARK: - Dragging destination

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        payload(from: sender) == nil ? [] : .move
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingEntered(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let payload = payload(from: sender) else { return false }
        onDropEditorTab?(payload)
        return true
    }

    private func payload(from sender: NSDraggingInfo) -> EditorTabDragPayload? {
        EditorTabDragPayload.decode(
            sender.draggingPasteboard.string(forType: PaneWorkspaceView.editorTabDragType)
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    /// How much of the full-size dock this cell can hold. A hole in an
    /// eight-pane grid is small, so the row shrinks with it rather than
    /// spilling past the card's edges.
    private var scale: CGFloat {
        let full = CGFloat(items.count) * Self.plateSize
            + CGFloat(items.count - 1) * Self.plateGap
        return min(1, (bounds.width - 40) / full)
    }

    /// Labels are the first thing to go: below this the plates alone still
    /// read, and the text would collide with its neighbour's.
    private var showsLabels: Bool { scale > 0.85 && bounds.height > 130 }

    /// The icon plates, left to right, centred as one block. Derived from
    /// `bounds` rather than recorded during `draw(_:)`, so click dispatch is
    /// testable on a view nothing has rendered yet.
    var itemRects: [NSRect] {
        let scale = self.scale
        guard scale > 0 else { return [] }
        let plate = Self.plateSize * scale
        let gap = Self.plateGap * scale
        let block = plate + (showsLabels ? Self.labelGap + Self.labelHeight : 0)
        let width = CGFloat(items.count) * plate + CGFloat(items.count - 1) * gap
        // Not flipped: the plates sit at the top of the block, labels under.
        let y = bounds.midY + block / 2 - plate
        return items.indices.map { index in
            NSRect(
                x: bounds.midX - width / 2 + CGFloat(index) * (plate + gap),
                y: y,
                width: plate,
                height: plate
            )
        }
    }

    /// One button's hit area — plate plus its label, with enough slack to feel
    /// like a button and enough gap left between neighbours that a click never
    /// lands ambiguously.
    func hitRect(at index: Int) -> NSRect {
        let rects = itemRects
        guard rects.indices.contains(index) else { return .zero }
        let label = showsLabels ? Self.labelGap + Self.labelHeight : 0
        return NSRect(
            x: rects[index].minX - 6,
            y: rects[index].minY - label - 5,
            width: rects[index].width + 12,
            height: rects[index].height + label + 10
        )
    }

    /// The button under a point, if it is one that can actually be pressed.
    private func index(at point: NSPoint) -> Int? {
        items.indices.first { items[$0].action != nil && hitRect(at: $0).contains(point) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        ))
        // The hit rects are derived from `bounds`, so a resized cell needs its
        // cursor rects recomputed too — `updateTrackingAreas` is the one hook
        // that already fires on exactly that.
        window?.invalidateCursorRects(for: self)
    }

    override func resetCursorRects() {
        for index in items.indices where items[index].action != nil {
            addCursorRect(hitRect(at: index), cursor: .pointingHand)
        }
    }

    override func mouseMoved(with event: NSEvent) {
        hoveredIndex = index(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        hoveredIndex = nil
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let card = bounds.insetBy(dx: 8, dy: 8)
        guard card.width > 2, card.height > 2 else { return }
        let outline = NSBezierPath(roundedRect: card, xRadius: 14, yRadius: 14)

        NSGraphicsContext.saveGraphicsState()
        outline.addClip()
        NSGradient(
            starting: NSColor(srgbRed: 17 / 255, green: 19 / 255, blue: 28 / 255, alpha: 1),
            ending: NSColor(srgbRed: 7 / 255, green: 8 / 255, blue: 12 / 255, alpha: 1)
        )?.draw(in: card, angle: -90)
        // The abstract backdrop: soft blobs bled off the corners, each one a
        // radial gradient that fades to fully transparent — which is what a
        // blurred shape looks like anyway, minus the filter.
        let span = max(card.width, card.height)
        let blobs: [(NSColor, NSPoint, CGFloat, CGFloat)] = [
            (Self.accent,
             NSPoint(x: card.minX + card.width * 0.1, y: card.maxY - card.height * 0.05),
             span * 0.85, 0.30),
            (NSColor(srgbRed: 186 / 255, green: 116 / 255, blue: 255 / 255, alpha: 1),
             NSPoint(x: card.maxX - card.width * 0.05, y: card.minY + card.height * 0.1),
             span * 0.8, 0.26),
            (NSColor(srgbRed: 86 / 255, green: 198 / 255, blue: 214 / 255, alpha: 1),
             NSPoint(x: card.maxX + card.width * 0.05, y: card.maxY),
             span * 0.55, 0.20),
        ]
        for (color, center, radius, alpha) in blobs {
            NSGradient(
                starting: color.withAlphaComponent(alpha),
                ending: color.withAlphaComponent(0)
            )?.draw(fromCenter: center, radius: 0, toCenter: center, radius: radius, options: [])
        }
        NSGraphicsContext.restoreGraphicsState()

        outline.lineWidth = 1
        Self.accent.withAlphaComponent(0.16).setStroke()
        outline.stroke()

        let scale = self.scale
        for (index, rect) in itemRects.enumerated() {
            let item = items[index]
            let hovered = hoveredIndex == index
            NSGraphicsContext.saveGraphicsState()
            // A kind that does not exist yet is drawn faded — it reads as "not
            // yet" rather than as a button that swallows clicks; `dispatch`
            // refuses it for real.
            if item.action == nil { NSGraphicsContext.current?.cgContext.setAlpha(0.4) }

            let plate = NSBezierPath(roundedRect: rect, xRadius: 15 * scale, yRadius: 15 * scale)
            Self.accent.withAlphaComponent(hovered ? 0.20 : 0.10).setFill()
            plate.fill()
            plate.lineWidth = 1
            Self.accent.withAlphaComponent(hovered ? 0.55 : 0.26).setStroke()
            plate.stroke()
            draw(symbol: item.symbol, in: rect, size: 22 * scale, weight: .regular, alpha: hovered ? 1 : 0.85)

            if showsLabels {
                let attributes = hovered ? Self.labelHoverAttributes : Self.labelAttributes
                let size = item.label.size(withAttributes: attributes)
                item.label.draw(
                    at: NSPoint(
                        x: rect.midX - size.width / 2,
                        y: rect.minY - Self.labelGap - size.height
                    ),
                    withAttributes: attributes
                )
            }
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    /// SF Symbol, tinted with the accent and centred in `rect`. A missing
    /// symbol simply draws nothing — the labels still say what the cell does.
    private func draw(symbol: String, in rect: NSRect, size: CGFloat, weight: NSFont.Weight, alpha: CGFloat) {
        guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: weight)) else { return }
        let target = NSRect(
            x: rect.midX - image.size.width / 2,
            y: rect.midY - image.size.height / 2,
            width: image.size.width,
            height: image.size.height
        )
        // Tint inside an image of the glyph's own size: `.sourceAtop` needs a
        // destination whose alpha *is* the glyph, and the card underneath is
        // opaque, so tinting in place would just paint a filled rectangle.
        let tinted = NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect)
            Self.accent.withAlphaComponent(alpha).set()
            rect.fill(using: .sourceAtop)
            return true
        }
        tinted.draw(in: target)
    }

    override func mouseUp(with event: NSEvent) {
        dispatch(at: convert(event.locationInWindow, from: nil))
    }

    /// The click rule, split from `mouseUp` so it is testable without
    /// synthesising events: each button acts for itself, and the space around
    /// them does nothing — these are buttons, not one cell-sized target.
    func dispatch(at point: NSPoint) {
        guard let index = index(at: point) else { return }
        items[index].action?()
    }

    override func accessibilityPerformPress() -> Bool {
        activate()
        return true
    }

    func activate() {
        items[0].action?()
    }
}
