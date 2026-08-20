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

    /// The sidebar column's width right now — 0 when it is collapsed. Read at
    /// draw time rather than stored, so a divider drag needs nothing but a
    /// redraw.
    var sidebarWidthProvider: (() -> CGFloat)?

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

    /// Both are driven by the live sidebar width in `layout`: the toggle sits
    /// at the column's right edge, inside it, and the name starts after the
    /// column ends. Held as constraints rather than frames so everything else
    /// in the bar stays declarative.
    private var sidebarButtonLeading: NSLayoutConstraint!
    private var titleLeading: NSLayoutConstraint!

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

        closeButton.trafficLight = .red
        minimizeButton.trafficLight = .yellow
        zoomButton.trafficLight = .green
        // `PaneHeaderButton` names itself for the pane header it was built
        // for. These three act on the window, so they say so — overridden
        // here rather than parameterised there, since the class has no other
        // reason to know about windows.
        closeButton.setAccessibilityLabel("Close window")
        minimizeButton.setAccessibilityLabel("Minimize window")
        zoomButton.setAccessibilityLabel("Zoom window")
        closeButton.onClick = { [weak self] in self?.window?.performClose(nil) }
        minimizeButton.onClick = { [weak self] in self?.window?.miniaturize(nil) }
        zoomButton.onClick = { [weak self] in self?.window?.zoom(nil) }

        reviewButton.isHidden = true

        for view in controls { addSubview(view) }
        addSubview(titleField)
        for view in controls { view.translatesAutoresizingMaskIntoConstraints = false }

        sidebarButtonLeading = sidebarButton.leadingAnchor.constraint(
            equalTo: leadingAnchor,
            constant: Self.lightsWidth + 16
        )
        titleLeading = titleField.leadingAnchor.constraint(equalTo: leadingAnchor)

        var constraints: [NSLayoutConstraint] = [
            heightAnchor.constraint(equalToConstant: Self.height),

            closeButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.leadingInset),
            minimizeButton.leadingAnchor.constraint(
                equalTo: closeButton.leadingAnchor,
                constant: Self.lightSpacing
            ),
            zoomButton.leadingAnchor.constraint(
                equalTo: minimizeButton.leadingAnchor,
                constant: Self.lightSpacing
            ),

            sidebarButtonLeading,
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

    /// The sidebar toggle rides the column's right edge, from the inside, and
    /// the session's name starts where the column ends. With the column
    /// collapsed both fall back to sitting after the lights, so neither ends
    /// up off the left of the bar.
    override func layout() {
        let column = max(0, sidebarWidthProvider?() ?? 0)
        let afterLights = Self.lightsWidth + 16
        sidebarButtonLeading.constant = max(afterLights, column - Self.columnInset - Self.buttonSize)
        titleLeading.constant = max(
            sidebarButtonLeading.constant + Self.buttonSize + Self.columnInset,
            column + Self.columnInset
        )
        super.layout()
    }

    /// The bar's ground is the window's, except across the sidebar's own
    /// width, where it is the column's — which is what makes the column read
    /// as running to the top edge of the window rather than starting under a
    /// strip of chrome.
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        Self.ground.setFill()
        dirtyRect.fill()
        let column = max(0, sidebarWidthProvider?() ?? 0)
        guard column > 0 else { return }
        Self.sidebarTop.setFill()
        NSRect(x: 0, y: 0, width: column, height: bounds.height).intersection(dirtyRect).fill()
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
