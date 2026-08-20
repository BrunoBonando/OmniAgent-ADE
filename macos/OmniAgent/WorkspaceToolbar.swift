import AppKit

/// The window's own title bar, drawn rather than borrowed.
///
/// `NSToolbar` used to live here. It was replaced (2026-08-20) because every
/// system title bar style reserves a row for a title this app does not show,
/// and draws a separator under itself that made the chrome read as a strip
/// bolted above the content. This view is one 38pt row with no fill and no
/// hairline, sitting on the same ground the panes do — the window is one
/// surface with controls floating at the top of it.
///
/// Left to right: the three window buttons, the sidebar toggle, the running
/// session's name. Far right: the review-panel toggle. Anything that is not a
/// button drags the window, which is the whole reason a hand-drawn bar has to
/// answer for `performDrag` itself — see `hitTest`.
///
/// The toggles target `nil` so they travel the responder chain exactly like
/// the menu items that carry the same commands, which is what keeps one
/// enablement rule (`validateMenuItem`) rather than two.
final class WorkspaceTitleBarView: NSView {
    /// Tall enough to clear the window's rounded top corners and to give the
    /// 20pt controls air; short enough that it reads as chrome, not as a bar.
    static let height: CGFloat = 38

    /// macOS's own traffic-light spacing, and the inset it uses from the
    /// window's left edge.
    private static let lightSpacing: CGFloat = 20
    private static let leadingInset: CGFloat = 13
    /// Where the three lights stop.
    private static let lightsWidth = leadingInset + lightSpacing * 2 + PaneHeaderButton.iconSize
    private static let buttonSize: CGFloat = 24
    /// How far the two toggles sit from the edge of the column each belongs to.
    private static let columnInset: CGFloat = 12

    /// The window's own ground, so the bar is not a band across the top but
    /// the same surface the panes sit on — no fill of its own to see, and no
    /// hairline under it. Matches `WorkspaceWindowController`'s
    /// `window.backgroundColor`; a view with no background at all paints
    /// white when it is rendered offscreen, which is not a risk worth
    /// carrying for one line.
    private static let ground = NSColor(srgbRed: 8 / 255, green: 10 / 255, blue: 14 / 255, alpha: 1)

    /// The sidebar column's ground at its very top, carried across the bar's
    /// left segment so the column reads as running to the window's top edge
    /// rather than starting under a strip.
    ///
    /// A flat fill rather than a 38pt slice of the gradient itself: over the
    /// bar's height `sidebarGlass` moves by well under one part in 255 — on
    /// the shortest window this app opens, under two — so the slice and its
    /// first colour are the same picture, and this one cannot drift out of
    /// alignment with the column below. Taken *from* the gradient, so a
    /// change to the palette carries here without anything to remember.
    private static let sidebarTop = ShellPalette.sidebarGlass.interpolatedColor(atLocation: 0)

    /// Where the title sits when the column is too narrow to place it — clear
    /// of the window buttons and the toggle, never under them.
    private static let afterButtons = lightsWidth + columnInset + buttonSize + columnInset

    /// The bar's share of the sidebar column: a real view with an animatable
    /// width, not a rectangle painted in `draw`. A painted one can only be
    /// redrawn at whatever moment something samples the column's width, and
    /// the collapse is an *animation* — there is no single moment to sample.
    private let sidebarSegment = NSView()
    private var segmentWidth: NSLayoutConstraint!

    private let closeButton = PaneHeaderButton(glyph: .close)
    private let minimizeButton = PaneHeaderButton(glyph: .restore)
    private let zoomButton = PaneHeaderButton(glyph: .expand)
    private let sidebarButton = WorkspaceTitleBarButton(
        symbol: "sidebar.leading",
        label: "Toggle Sidebar",
        action: #selector(WorkspaceWindowController.toggleWorkspaceSidebar(_:))
    )
    private let reviewButton = WorkspaceTitleBarButton(
        symbol: "sidebar.trailing",
        label: "Toggle Review Panel",
        action: #selector(WorkspaceWindowController.toggleReviewPanel(_:))
    )
    private let titleField = ShellFont.label(
        "",
        font: ShellFont.ui(13, .medium),
        color: ShellPalette.inkSecondary
    )

    /// The running session's name. Empty off the Desk, and empty is *empty* —
    /// the bar shows nothing rather than falling back to the app's name.
    var title: String = "" {
        didSet {
            guard title != oldValue else { return }
            titleField.stringValue = title
        }
    }

    /// Whether there is a session for the review panel to review. Absent, not
    /// disabled: a greyed-out control invites a click that will never work.
    var isReviewToggleVisible: Bool = false {
        didSet { reviewButton.isHidden = !isReviewToggleVisible }
    }

    /// The session's name starts where the sidebar column ends, so this one
    /// follows the divider — see `layout`. Held as a constraint rather than a
    /// frame so everything else in the bar stays declarative.
    ///
    /// The sidebar toggle deliberately does *not* get the same treatment: it
    /// is pinned beside the window buttons. It used to ride the column's
    /// right edge, which put it under the pointer that had just pressed it
    /// and then moved it — a control that walks away when you use it.
    private var titleLeading: NSLayoutConstraint!

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Self.ground.cgColor
        translatesAutoresizingMaskIntoConstraints = false

        sidebarSegment.wantsLayer = true
        sidebarSegment.layer?.backgroundColor = Self.sidebarTop.cgColor
        sidebarSegment.translatesAutoresizingMaskIntoConstraints = false
        addSubview(sidebarSegment)

        closeButton.trafficLight = .red
        minimizeButton.trafficLight = .yellow
        zoomButton.trafficLight = .green
        // `PaneHeaderButton` names itself for the pane header it was built
        // for. These three act on the window, so they say so — overridden
        // here rather than parameterised there, since the class has no other
        // reason to know about windows.
        closeButton.setAccessibilityLabel("Close window")
        minimizeButton.setAccessibilityLabel("Minimize window")
        zoomButton.setAccessibilityLabel("Toggle Full Screen")
        closeButton.onClick = { [weak self] in self?.window?.performClose(nil) }
        minimizeButton.onClick = { [weak self] in self?.window?.miniaturize(nil) }
        // The green button's actual contract, which is not "zoom": a click
        // enters full screen and ⌥-click zooms. Wiring it to `zoom` alone —
        // as the first cut of this bar did — silently removed the only way
        // into full screen this app has, since its menus are hand-built and
        // carry no Enter Full Screen item for AppKit to fill in.
        zoomButton.onClick = { [weak self] in
            guard let window = self?.window else { return }
            if NSEvent.modifierFlags.contains(.option) {
                window.zoom(nil)
            } else {
                window.toggleFullScreen(nil)
            }
        }

        reviewButton.isHidden = true

        for view in controls { addSubview(view) }
        addSubview(titleField)
        for view in controls { view.translatesAutoresizingMaskIntoConstraints = false }

        titleLeading = titleField.leadingAnchor.constraint(
            equalTo: leadingAnchor,
            constant: Self.afterButtons
        )
        segmentWidth = sidebarSegment.widthAnchor.constraint(equalToConstant: 0)

        var constraints: [NSLayoutConstraint] = [
            heightAnchor.constraint(equalToConstant: Self.height),

            sidebarSegment.leadingAnchor.constraint(equalTo: leadingAnchor),
            sidebarSegment.topAnchor.constraint(equalTo: topAnchor),
            sidebarSegment.bottomAnchor.constraint(equalTo: bottomAnchor),
            segmentWidth,

            closeButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.leadingInset),
            minimizeButton.leadingAnchor.constraint(
                equalTo: closeButton.leadingAnchor,
                constant: Self.lightSpacing
            ),
            zoomButton.leadingAnchor.constraint(
                equalTo: minimizeButton.leadingAnchor,
                constant: Self.lightSpacing
            ),

            sidebarButton.leadingAnchor.constraint(
                equalTo: zoomButton.trailingAnchor,
                constant: Self.columnInset
            ),
            sidebarButton.widthAnchor.constraint(equalToConstant: Self.buttonSize),
            sidebarButton.heightAnchor.constraint(equalToConstant: Self.buttonSize),

            titleLeading,
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor),

            reviewButton.leadingAnchor.constraint(
                greaterThanOrEqualTo: titleField.trailingAnchor,
                constant: 12
            ),
            reviewButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.columnInset),
            reviewButton.widthAnchor.constraint(equalToConstant: Self.buttonSize),
            reviewButton.heightAnchor.constraint(equalToConstant: Self.buttonSize),
        ]
        for view in controls {
            constraints.append(view.centerYAnchor.constraint(equalTo: centerYAnchor))
        }
        for light in [closeButton, minimizeButton, zoomButton] {
            constraints.append(light.widthAnchor.constraint(equalToConstant: PaneHeaderButton.iconSize))
            constraints.append(light.heightAnchor.constraint(equalToConstant: PaneHeaderButton.iconSize))
        }
        NSLayoutConstraint.activate(constraints)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    /// Everything that answers a click. `hitTest` consults this list, so a
    /// control missing from it would silently become draggable background.
    private var controls: [NSView] {
        [closeButton, minimizeButton, zoomButton, sidebarButton, reviewButton]
    }

    /// Puts the bar's left segment and the session's name at the column's
    /// current width. `animated` routes both through `animator()`, so when the
    /// caller runs this inside the same `NSAnimationContext` group as the
    /// collapse itself, all three move on one duration and one curve.
    ///
    /// This used to be sampled — a width read whenever something asked. That
    /// cannot be smooth: `isCollapsed` flips at the *start* of the collapse,
    /// so every sample after the first already reported the destination and
    /// the bar arrived while the column was still travelling.
    func setSidebarWidth(_ width: CGFloat, animated: Bool) {
        let column = max(0, width)
        let title = max(Self.afterButtons, column + Self.columnInset)
        guard segmentWidth.constant != column || titleLeading.constant != title else { return }
        if animated {
            segmentWidth.animator().constant = column
            titleLeading.animator().constant = title
        } else {
            segmentWidth.constant = column
            titleLeading.constant = title
        }
    }

    /// The buttons keep their clicks; everything else — the title, the empty
    /// space either side of it — belongs to the window drag. Done here rather
    /// than by `isMovableByWindowBackground`, which would also let a drag
    /// inside a terminal move the window.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        if let hit, controls.contains(where: { !$0.isHidden && hit.isDescendant(of: $0) }) {
            return hit
        }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }

    /// Test seam: the controls in the order they are laid out, so a test can
    /// assert what the bar carries without reaching into private storage.
    var controlsForTesting: [NSView] { controls }
    var titleFieldForTesting: NSTextField { titleField }
    /// The model width — what the animation is travelling *from* while it
    /// runs, which is exactly what the smoothness test needs to see.
    var sidebarSegmentWidthForTesting: CGFloat { segmentWidth.constant }
}

/// One icon control in the title bar. `ShellRowView` already owns hover, the
/// button accessibility role and keyboard activation; this adds the icon, the
/// responder-chain dispatch, and the one override the bar depends on —
/// swallowing `mouseDown` so the click does not fall through to the drag.
final class WorkspaceTitleBarButton: ShellRowView {
    let action: Selector

    init(symbol: String, label: String, action: Selector) {
        self.action = action
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        toolTip = label
        setAccessibilityLabel(label)

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        icon.contentTintColor = ShellPalette.inkNav
        icon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)
        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        onPress = { [weak self] in
            guard let self else { return }
            NSApp.sendAction(self.action, to: nil, from: self)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    /// Without this, `NSResponder`'s default forwards the press to the next
    /// responder — the bar — which starts a window drag and the button never
    /// sees its `mouseUp`.
    override func mouseDown(with event: NSEvent) {}

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}
