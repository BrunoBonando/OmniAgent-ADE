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
    /// One scale for both axes, so the card keeps the window's own proportions
    /// rather than being letterboxed into a fixed shape.
    static let focusOverlayPadding: CGFloat = 26
    static let focusCardScale: CGFloat = 0.82
    static let focusCardMaxSize = NSSize(width: 1280, height: 800)
    /// `0 40px 100px`: 40pt of downward offset, and a CSS blur radius is about
    /// twice a layer's shadow radius, so 100px of spread is 50 here.
    static let focusCardShadowDrop: CGFloat = 40
    static let focusCardShadowBlur: CGFloat = 50

    /// How long a pane takes to grow into the zoom or shrink back out of it,
    /// with the backdrop fading over the same span. Slow enough to read as one
    /// pane lifting off the others rather than as a cut.
    static let zoomTransitionDuration: TimeInterval = 0.38

    /// The curve every part of the transition shares — the card, its shadow and
    /// the backdrop's fade. Front-loaded: about 85% of the distance is covered in
    /// the first third, then it eases out long and flat, so the card leaves fast
    /// and *settles* the way the Dock's genie does. The symmetric `easeInEaseOut`
    /// it replaces spent as long arriving as leaving, which reads as a slide.
    static let zoomTimingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)

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
            return updateLayout()
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

    /// The end of one transition's 0.32s: the card that was shrinking is back in
    /// the grid, and with nothing focused any more the overlay comes out of the
    /// window. Both directions end up here, so it acts only for the transition it
    /// was created by — see `zoomTransitionToken`.
    private func finishZoomTransition(_ token: Int) {
        guard token == zoomTransitionToken, overlayIsCollapsing, let id = overlayPaneID
        else { return }
        landCard(id)
        teardownOverlay()
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
        let height = min(host.height * fit, max(0, host.height - focusOverlayPadding * 2))
            .rounded(.down)
        return NSRect(
            x: (host.midX - width / 2).rounded(),
            y: (host.midY - height / 2).rounded(),
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
        // second pane can be focused. The other: ⌘↩ on pane A, then ⌘1…⌘8 or
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
        if lifting {
            // Only the origin changes here — the pane is the same size in the
            // host as it was in its cell — so the terminal is reflowed once, by
            // `place`, at the size it actually ends up.
            container.frame = start
        }
        // After any move, not just the lift: re-stacking a view that is already
        // there moves it too, and a move is what costs the first responder.
        if restacked { reclaimFirstResponder(container) }
        zoomBackdrop.setShown(true, duration: zoomTransition)
        let card = Self.focusCardFrame(in: host.bounds)
        moveFocusCardShadow(from: start, to: card)
        place(container, at: card)
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
    private func moveFocusCardShadow(from start: NSRect, to card: NSRect) {
        focusCardShadow.frame = card
        guard zoomTransition > 0, !start.isEmpty, start != card else { return }
        zoomLayer(
            focusCardShadow,
            fromPosition: CGPoint(x: start.midX, y: start.midY),
            fromSize: start.size,
            toSize: card.size
        )
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
        moveFocusCardShadow(from: focusCardShadow.frame, to: target)
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
        guard window.firstResponder !== container.surface.terminalView else { return }
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
    private func place(_ container: PaneContainerView, at frame: NSRect) {
        guard container.frame != frame else { return }
        let presented = (container.layer?.presentation() ?? container.layer)
            .map { (position: $0.position, bounds: $0.bounds, transform: $0.transform) }
        container.frame = frame
        if zoomTransition > 0, let layer = container.layer, let presented {
            // What is on screen right now: the presented bounds as its transform
            // is currently scaling them, so a move that begins mid-flight starts
            // from the size the eye can actually see.
            let onScreen = CGSize(
                width: presented.bounds.width * presented.transform.m11,
                height: presented.bounds.height * presented.transform.m22
            )
            zoomLayer(
                layer,
                fromPosition: presented.position,
                fromSize: onScreen,
                toSize: frame.size
            )
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

    /// 1-based, in fill order — what ⌘1…⌘8 select.
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
    /// `border-radius:12px` on the design's focused card, against 9 in the grid:
    /// the corner grows with the card it is rounding.
    static let focusedCornerRadius: CGFloat = 12
    static let borderWidth: CGFloat = 1

    /// `#0c0c0f` — the pane body behind the terminal, from the design's grid.
    static let paneBackgroundColor = NSColor(srgbRed: 12 / 255, green: 12 / 255, blue: 15 / 255, alpha: 1)
    /// Focus is the thing you look for most often in a grid of eight, so the
    /// selected pane's ring is a solid accent line and the rest recede to a
    /// hairline. At the old 0.45 the two were near enough that you had to hunt
    /// for the pane you were typing into.
    static let idleBorderColor = NSColor(white: 1, alpha: 0.06)
    static let focusedBorderColor = NSColor(srgbRed: 139 / 255, green: 149 / 255, blue: 255 / 255, alpha: 0.85)
    /// The accent wash the selected pane's header carries, so the highlight is
    /// legible even where a neighbouring pane's ring sits right beside it.
    static let focusedHeaderTint = NSColor(srgbRed: 139 / 255, green: 149 / 255, blue: 255 / 255, alpha: 0.11)
    /// `box-shadow:0 0 0 1px rgba(240,180,70,.35)` — a pane that has stopped to
    /// ask something outranks focus, because it is the one the user must act on.
    static let awaitingBorderColor = NSColor(srgbRed: 240 / 255, green: 180 / 255, blue: 70 / 255, alpha: 0.55)
    static let errorBorderColor = NSColor(srgbRed: 242 / 255, green: 85 / 255, blue: 90 / 255, alpha: 0.55)
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
        // The design's `session restore · terminal 1 of 4`. A closure rather
        // than a stored string because the ordinal is a fact about the
        // workspace, not about this pane: a sibling closing while this one is
        // zoomed changes "of 4" and nothing would tell the header to rewrite it.
        header.subtitleProvider = { [weak self] in
            guard
                let self,
                let workspace = self.workspace,
                let ordinal = workspace.paneOrdinal(of: self.paneID),
                let group = workspace.descriptor(for: self.paneID)?.group,
                // Whatever the sidebar calls this session, including the derived
                // `Session N` for one nobody has named: the subtitle is two
                // parts in the design, and a card that dropped the name half
                // for unnamed sessions would show it for hardly any of them.
                let session = workspace.sessionLabel(forGroup: group)
            else { return nil }
            return "\(session) · terminal \(ordinal.index) of \(ordinal.total)"
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
    /// `MinY` is the **top** corner pair here: this view is flipped, and a
    /// flipped superview flips its sublayers' geometry with it.
    private func roundChildren(inside radius: CGFloat) {
        let inner = max(0, radius - Self.borderWidth)
        header.wantsLayer = true
        surface.wantsLayer = true
        for (child, corners) in [
            (header, CACornerMask([.layerMinXMinYCorner, .layerMaxXMinYCorner])),
            (surface, CACornerMask([.layerMinXMaxYCorner, .layerMaxXMaxYCorner])),
        ] {
            child.layer?.cornerRadius = inner
            child.layer?.cornerCurve = .continuous
            child.layer?.maskedCorners = corners
            child.layer?.masksToBounds = true
        }
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
        // Its session's name is half the focus subtitle, so a rename has to
        // reach the bar. A no-op unless this pane is the zoomed one.
        header.refreshSubtitle()
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
    /// ⌃⌘arrows, ⌘1…⌘8) grey out, which they do not do with no card up. AppKit
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
/// the branch it is on, and the two controls. Also the drag handle — the whole
/// bar is grabbable except where a button sits.
///
/// It draws two treatments, switched by `isZoomed`: the grid pane's bar, and the
/// focused card's taller one with a bigger name, a `session · terminal N of M`
/// subtitle and a labelled way out (design line 1070). The mark, the engine
/// badge and the branch badge are identical in both — the delta is deliberately
/// only what tells you *this pane is the one blown up over the others*.
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

    var isZoomAvailable = false {
        didSet {
            guard isZoomAvailable != oldValue else { return }
            applyControlVisibility()
        }
    }

    /// The whole focus treatment, from the focused card at design line 1070: a
    /// taller bar with more air in it, a bigger and brighter title, the
    /// `session · terminal N of M` subtitle, and the labelled `Exit focus ·
    /// esc` pill where the 20pt zoom icon sits in the grid. That last swap is
    /// the point of the exercise — the control that got you in must not look
    /// like the control that gets you out.
    var isZoomed = false {
        didSet {
            guard isZoomed != oldValue else { return }
            applyEmphasis()
            applyControlVisibility()
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
    private let branchBadge = PaneBadgeView()
    private let focusButton: PaneHeaderButton
    private let exitFocusButton: PaneHeaderButton
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
        focusButton = PaneHeaderButton(glyph: .focus)
        exitFocusButton = PaneHeaderButton(glyph: .exitFocus, label: "Exit focus · esc")
        closeButton = PaneHeaderButton(glyph: .close)
        super.init(frame: .zero)
        wantsLayer = true
        titleLabel.translatesAutoresizingMaskIntoConstraints = true
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = true
        subtitleLabel.isHidden = true
        engineBadge.isHidden = true
        branchBadge.isHidden = true
        focusButton.onClick = { [weak self] in self?.onZoomRequested?() }
        // The same toggle, reached from the other side: the pill exists only
        // while this pane is zoomed, so "toggle" there can only mean "get out".
        exitFocusButton.onClick = { [weak self] in self?.onZoomRequested?() }
        closeButton.onClick = { [weak self] in self?.onCloseRequested?() }
        closeButton.hoverTint = NSColor(srgbRed: 255 / 255, green: 138 / 255, blue: 142 / 255, alpha: 1)
        closeButton.hoverFill = NSColor(srgbRed: 242 / 255, green: 85 / 255, blue: 90 / 255, alpha: 0.18)
        let views: [NSView] = [
            mark, titleLabel, subtitleLabel, engineBadge, branchBadge,
            focusButton, exitFocusButton, closeButton,
        ]
        for view in views { addSubview(view) }
        // Same reason the surface applies its cursor state up front: the header
        // starts unfocused and unzoomed, so the didSets that dim the title and
        // pick the controls never fire for a pane that is never selected.
        applyEmphasis()
        applyControlVisibility()
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
            // The muted grey the branch badge already uses — an unselected pane
            // stays perfectly readable, it just stops competing.
            : NSColor(srgbRed: 154 / 255, green: 154 / 255, blue: 164 / 255, alpha: 1)
    }

    /// Which trailing control the bar offers. Exactly one of the zoom icon and
    /// the exit pill is ever present, and the close button steps aside while
    /// zoomed (the design's focused card has none): closing the terminal you
    /// just blew up over the others is not what the card is for, and ⌘W still
    /// does it.
    private func applyControlVisibility() {
        focusButton.isHidden = !isZoomAvailable || isZoomed
        exitFocusButton.isHidden = !isZoomed
        closeButton.isHidden = isZoomed
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
            PaneContainerView.focusedBorderColor.withAlphaComponent(0.4).setFill()
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
        // the branch and then the engine rather than clipping its own name.
        var right = bounds.maxX - currentTrailingInset
        // A hidden control gives its slot back to the title rather than leaving
        // a gap where a button used to be — which is how the zoom icon's slot,
        // and the close button's while zoomed, go to the name.
        for button in [closeButton, focusButton, exitFocusButton] where !button.isHidden {
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
        for badge in [branchBadge, engineBadge] where !badge.isHidden {
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
        var titleWidth = available
        if !subtitleLabel.isHidden {
            // The design has the subtitle directly after the name, with the
            // flexible span moved to their right — so the title stops
            // stretching here and takes its natural width. The name is served
            // first: a subtitle that would leave it under its own width, or
            // under the 40pt the badges drop against, goes rather than
            // ellipsising the terminal's name to describe where it sits.
            // `fittingSize`, not `intrinsicContentSize`: a label reports an
            // intrinsic width about 4pt narrower than the cell it actually
            // draws in, so a frame taken from the intrinsic value ellipsises
            // text that fits. The grid never noticed, because there the title
            // takes the slack and is never measured.
            let subtitleSize = subtitleLabel.fittingSize
            let wanted = ceil(titleLabel.fittingSize.width)
            let subtitleWidth = ceil(subtitleSize.width)
            let room = available - gap - subtitleWidth
            if room >= max(minimumTitleWidth, wanted) {
                titleWidth = wanted
                let subtitleHeight = ceil(subtitleSize.height)
                subtitleLabel.frame = CGRect(
                    x: titleLeft + titleWidth + gap,
                    y: (bounds.height - subtitleHeight) / 2,
                    width: subtitleWidth,
                    height: subtitleHeight
                )
            } else {
                subtitleLabel.frame = .zero
            }
        }

        // `fittingSize` here too, for the same reason as the widths above and so
        // the next author never has to wonder which of the two this file trusts.
        let titleHeight = ceil(titleLabel.fittingSize.height)
        titleLabel.frame = CGRect(
            x: titleLeft,
            y: (bounds.height - titleHeight) / 2,
            width: titleWidth,
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

/// The blurred backdrop a zoomed pane sits on, and the way out of the zoom
/// that does not require finding the button again.
///
/// This was a layer background filter, to keep `NSVisualEffectView`'s
/// display-link-backed animation machine out of the test host — one that had
/// been seen spinning forever retrying `CVDisplayLinkCreateWithCGDisplays` where
/// no display exists. It bought a suite that never blurred anything: see `init`.
/// The effect view is back, and the constraint it was avoided for is now a
/// property of the *host*, not of this view — a test host with no display attached
/// must not construct one.
final class PaneZoomBackdropView: NSVisualEffectView {
    /// The design's `rgba(6,6,8,.62)` at a third of that alpha, in a subview
    /// because an `NSVisualEffectView` paints its material into its own layer and
    /// a background colour set on that layer lands underneath it.
    ///
    /// The mock's .62 is a wash over a *CSS* blur; over the system material it
    /// left the app behind the card as one dark smear — "too strong". The blur
    /// alone already makes text unreadable, which is the whole job, so the tint
    /// only has to say "not this part" and can stay light enough that you can
    /// still see the shape of what is behind.
    static let tint = NSColor(srgbRed: 6 / 255, green: 6 / 255, blue: 8 / 255, alpha: 0.22)

    var onClick: (() -> Void)?

    private var isShown = false
    private let tintView = NSView()

    /// `backdrop-filter:blur(16px) saturate(70%)` as the platform's own
    /// within-window blur, rather than the `CIGaussianBlur` in
    /// `layer.backgroundFilters` this used to carry. That is what "the background
    /// is not blurred" was: `backgroundFilters` are only composited for layers the
    /// window server can read back through, which a layer-backed view inside an
    /// ordinary window is not — the filter was installed, ramped, and drew
    /// nothing, leaving a flat 62% black wash over a perfectly sharp app.
    /// `NSVisualEffectView` with `.withinWindow` blurs the sibling views behind
    /// it, which is exactly what the design's overlay does.
    init() {
        super.init(frame: .zero)
        material = .hudWindow
        blendingMode = .withinWindow
        // `.followsWindowActiveState` would drop the blur the moment the window
        // stopped being key — including while a sheet or the palette is up.
        state = .active
        appearance = NSAppearance(named: .darkAqua)
        // Explicit, though an effect view is layer-backed anyway: it does not
        // *have* a `layer` until it joins a hierarchy, and the card's shadow is
        // inserted directly above that layer — with none there, `stackOverlay`
        // silently left the shadow out.
        wantsLayer = true
        tintView.wantsLayer = true
        tintView.layer?.backgroundColor = Self.tint.cgColor
        tintView.autoresizingMask = [.width, .height]
        addSubview(tintView)
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
        tintView.frame = bounds
    }

    /// Fades the whole backdrop, blur and tint together. Hidden only once it has
    /// faded out, never left invisible-but-present: it swallows clicks.
    func setShown(_ shown: Bool, duration: TimeInterval) {
        guard isShown != shown else { return }
        isShown = shown
        if shown {
            isHidden = false
            // Sized before the first frame is drawn: the fade starts now, and a
            // tint still at its zero frame would show one frame of untinted blur.
            tintView.frame = bounds
        }
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
    // focuses — the blurred pane underneath it.
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
    enum Glyph { case focus, exitFocus, close }

    /// The grid header's controls, `width:20px;height:20px`.
    static let iconSize: CGFloat = 20

    /// The focused card's pill (design line 1082): `padding:5px 9px`,
    /// `gap:6px`, `border-radius:6px`, a `.5px` border and a 16pt glyph.
    private static let labelHorizontalInset: CGFloat = 9
    private static let labelVerticalInset: CGFloat = 5
    private static let labelGap: CGFloat = 6
    private static let labelGlyphSize: CGFloat = 16
    private static let labelCornerRadius: CGFloat = 6
    private static let labelFont = ShellFont.ui(13.5, .medium)
    private static let labelForeground = NSColor(
        srgbRed: 216 / 255,
        green: 216 / 255,
        blue: 222 / 255,
        alpha: 1
    )
    private static let labelFill = NSColor(white: 1, alpha: 0.07)
    private static let labelHoverFill = NSColor(white: 1, alpha: 0.13)
    private static let labelStroke = NSColor(white: 1, alpha: 0.14)

    var onClick: (() -> Void)?
    var hoverTint = NSColor(srgbRed: 223 / 255, green: 226 / 255, blue: 255 / 255, alpha: 1)
    var hoverFill = NSColor(srgbRed: 139 / 255, green: 149 / 255, blue: 255 / 255, alpha: 0.22)

    private let glyph: Glyph
    /// What the button says, and `nil` for the grid's bare icon square. A label
    /// makes the button the design's bordered pill instead — same click target,
    /// but it says what it does and what key does it, which is the whole reason
    /// the focused card does not simply reuse the icon that got you there.
    let label: String?
    private var isHovered = false { didSet { needsDisplay = true } }
    private var tracking: NSTrackingArea?

    init(glyph: Glyph, label: String? = nil) {
        self.glyph = glyph
        self.label = label
        super.init(frame: .zero)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        // A labelled button is named by what it *says*: Voice Control resolves
        // "Click Exit focus · esc" against the visible text, and a control whose
        // whole job is teaching the way out must not be the one that cannot be
        // spoken. Only the bare icons need a described name, having none.
        if let label {
            setAccessibilityLabel(label)
        } else {
            // No `.exitFocus` here: it exists only as the labelled pill, so
            // there is no bare form of it left to describe.
            setAccessibilityLabel(glyph == .focus ? "Zoom this terminal" : "Close this terminal")
        }
    }

    /// Assistive presses go the same way a click does. `NSView` gives a view with
    /// `.button` role no press behaviour of its own, so without this the pill is
    /// visible and named to VoiceOver and does nothing when it is activated.
    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return onClick != nil
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        guard let label else { return NSSize(width: Self.iconSize, height: Self.iconSize) }
        let text = (label as NSString).size(withAttributes: [.font: Self.labelFont])
        return NSSize(
            width: ceil(
                Self.labelHorizontalInset * 2 + Self.labelGlyphSize + Self.labelGap + text.width
            ),
            height: ceil(Self.labelVerticalInset * 2 + max(Self.labelGlyphSize, text.height))
        )
    }

    /// The 16 unit box the glyph is drawn in: the whole button when it is a bare
    /// icon, the leading square inside the padding when it is a pill.
    private var glyphBox: NSRect {
        guard label != nil else { return bounds }
        return NSRect(
            x: Self.labelHorizontalInset,
            y: (bounds.height - Self.labelGlyphSize) / 2,
            width: Self.labelGlyphSize,
            height: Self.labelGlyphSize
        )
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

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClick?()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if let label {
            // The pill is bordered and filled at rest, not only on hover: it is
            // the card's one control, and the hover fill alone would leave it
            // invisible until the pointer found it.
            let pill = NSBezierPath(
                roundedRect: bounds.insetBy(dx: 0.25, dy: 0.25),
                xRadius: Self.labelCornerRadius,
                yRadius: Self.labelCornerRadius
            )
            (isHovered ? Self.labelHoverFill : Self.labelFill).setFill()
            pill.fill()
            Self.labelStroke.setStroke()
            pill.lineWidth = 0.5
            pill.stroke()
            let attributes: [NSAttributedString.Key: Any] = [
                .font: Self.labelFont,
                .foregroundColor: Self.labelForeground,
            ]
            let size = (label as NSString).size(withAttributes: attributes)
            (label as NSString).draw(
                at: NSPoint(
                    x: glyphBox.maxX + Self.labelGap,
                    y: (bounds.height - size.height) / 2
                ),
                withAttributes: attributes
            )
        } else if isHovered {
            hoverFill.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
        }
        // A pill's glyph keeps the label's colour through hover, where the
        // design moves only the fill; a bare icon is the thing that lights up.
        let color: NSColor
        if label != nil {
            color = Self.labelForeground
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
        func brackets(_ corners: [[(CGFloat, CGFloat)]]) {
            for corner in corners {
                path.move(to: point(corner[0].0, corner[0].1))
                for step in corner.dropFirst() { path.line(to: point(step.0, step.1)) }
            }
        }
        switch glyph {
        case .focus:
            // Four corner brackets pointing outward — "blow this pane up".
            brackets([
                [(6.2, 2.4), (2.4, 2.4), (2.4, 6.2)],
                [(9.8, 2.4), (13.6, 2.4), (13.6, 6.2)],
                [(13.6, 9.8), (13.6, 13.6), (9.8, 13.6)],
                [(6.2, 13.6), (2.4, 13.6), (2.4, 9.8)],
            ])
        case .exitFocus:
            // The same construction mirrored, so the brackets point inward —
            // "put it back". A reader tells the two apart without the label,
            // which is why the pill is not just the outward icon with words.
            brackets([
                [(2.6, 6.4), (2.6, 2.6), (6.4, 2.6)],
                [(13.4, 6.4), (13.4, 2.6), (9.6, 2.6)],
                [(9.6, 13.4), (13.4, 13.4), (13.4, 9.6)],
                [(6.4, 13.4), (2.6, 13.4), (2.6, 9.6)],
            ])
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
