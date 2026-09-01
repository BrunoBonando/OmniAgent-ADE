import AppKit

/// The window's own title bar, drawn rather than borrowed.
///
/// `NSToolbar` used to live here. It was replaced (2026-08-20) because every
/// system title bar style reserves a row for a title this app does not show,
/// and draws a separator under itself that made the chrome read as a strip
/// bolted above the content. This view paints nothing at all: it is a 38pt
/// transparent overlay across the top of the split, so each column's own
/// background runs up to the window's top edge underneath it.
///
/// It carries only what must never move: the three window buttons and the
/// sidebar toggle on the left, and — right to left — the account avatar, the
/// notifications bell and the review-panel toggle on the right. The
/// session's name is deliberately NOT here — it lives in the content column
/// (`WorkspaceWindowController.sessionTitleField`), so that a sidebar collapse
/// carries it by moving the column it sits in, rather than by any code here
/// keeping a second copy of the column's width in step.
///
/// Anything that is not a button drags the window, which is the whole reason a
/// hand-drawn bar has to answer for `performDrag` itself — see `hitTest`.
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
    /// How far the outermost control sits from the edge of the column it
    /// belongs to, and how much air the top-right cluster keeps between its
    /// controls.
    private static let columnInset: CGFloat = 12
    private static let controlSpacing: CGFloat = 8

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
    /// The flow layout's top-right pair (`2026-09-01-flow-layout-design.md`
    /// §1): the feed's bell, and the account that used to sit in the
    /// sidebar's foot. Both travel the responder chain like the toggles.
    let notificationsButton = WorkspaceTitleBarButton(
        symbol: "bell",
        label: "Notifications",
        action: #selector(WorkspaceWindowController.showNotifications(_:))
    )
    let accountButton = TitleBarAccountButton()

    /// Whether there is a session for the review panel to review. Absent, not
    /// disabled: a greyed-out control invites a click that will never work.
    var isReviewToggleVisible: Bool = false {
        didSet { reviewButton.isHidden = !isReviewToggleVisible }
    }

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
        for view in controls { view.translatesAutoresizingMaskIntoConstraints = false }

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

            sidebarButton.leadingAnchor.constraint(
                equalTo: zoomButton.trailingAnchor,
                constant: Self.columnInset
            ),
            sidebarButton.widthAnchor.constraint(equalToConstant: Self.buttonSize),
            sidebarButton.heightAnchor.constraint(equalToConstant: Self.buttonSize),

            // Right to left, 8pt apart: the account at the trailing edge,
            // then the bell, then the review toggle — which is the only one
            // of the three that comes and goes, so it is the one that must
            // sit innermost or its absence would leave a hole.
            accountButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.columnInset),
            notificationsButton.trailingAnchor.constraint(
                equalTo: accountButton.leadingAnchor,
                constant: -Self.controlSpacing
            ),
            notificationsButton.widthAnchor.constraint(equalToConstant: Self.buttonSize),
            notificationsButton.heightAnchor.constraint(equalToConstant: Self.buttonSize),
            reviewButton.trailingAnchor.constraint(
                equalTo: notificationsButton.leadingAnchor,
                constant: -Self.controlSpacing
            ),
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
        [closeButton, minimizeButton, zoomButton, sidebarButton, reviewButton, notificationsButton, accountButton]
    }

    /// The buttons keep their clicks; everything else — the whole transparent
    /// span between and around them — belongs to the window drag. Done here rather
    /// than by `isMovableByWindowBackground`, which would also let a drag
    /// inside a terminal move the window.
    ///
    /// "Everything else" means everything else *in the bar*, and the guard is
    /// what says so. A parent asks each of its subviews to hit-test every
    /// point, outside their frames included, and answers with the first one
    /// that does not return nil — so an unconditional `return self` here
    /// claimed the whole window. Harmless while the bar was laid out above the
    /// split (the split was asked first), fatal the moment it became the
    /// overlay on top of it: every click anywhere went to `performDrag`.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        if controls.contains(where: { !$0.isHidden && hit.isDescendant(of: $0) }) {
            return hit
        }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }

    /// The leftmost edge the session's name may claim. The name lives in the
    /// content column and slides with it, so when the sidebar collapses that
    /// column reaches the window's left edge and would take the name under
    /// these buttons — this is what the name's own constraint holds it clear of.
    var titleClearanceAnchor: NSLayoutXAxisAnchor { sidebarButton.trailingAnchor }

    /// Test seam: the controls in the order they are laid out, so a test can
    /// assert what the bar carries without reaching into private storage.
    var controlsForTesting: [NSView] { controls }
}

/// One icon control in the title bar. `ShellRowView` already owns hover, the
/// button accessibility role and keyboard activation; this adds the icon, the
/// responder-chain dispatch, and the one override the bar depends on —
/// swallowing `mouseDown` so the click does not fall through to the drag.
final class WorkspaceTitleBarButton: ShellRowView {
    let action: Selector

    /// Whether this button is carrying something unanswered — the bell's
    /// red dot. Opt-in rather than built for every button: the layer only
    /// exists once a caller has said there is something to mark, so the
    /// buttons that never carry one stay exactly one thing.
    var isUnread = false {
        didSet {
            guard isUnread || unreadDot != nil else { return }
            unreadDotLayer().isHidden = !isUnread
        }
    }

    /// Test seam: the dot itself, `nil` until something has been unread.
    private(set) var unreadDot: CALayer?

    /// Big enough to read at a glance over a 13pt symbol, small enough not
    /// to become a badge — the spec's 6pt.
    private static let unreadDotSize: CGFloat = 6

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

    override func layout() {
        super.layout()
        // Its frame, not a constraint: a `CALayer` has none. Placed off the
        // button's centre rather than its corner so the dot sits on the
        // icon's top-right shoulder — the icon is centred and the button is
        // wider than it is.
        unreadDot?.frame = NSRect(
            x: bounds.midX + 2,
            y: bounds.midY + 2,
            width: Self.unreadDotSize,
            height: Self.unreadDotSize
        )
    }

    private func unreadDotLayer() -> CALayer {
        if let unreadDot { return unreadDot }
        let dot = CALayer()
        dot.backgroundColor = ShellPalette.red.cgColor
        dot.cornerRadius = Self.unreadDotSize / 2
        layer?.addSublayer(dot)
        unreadDot = dot
        needsLayout = true
        return dot
    }
}

/// The title bar's account control: the same circle the sidebar's account
/// row wears, in a 24pt hover square, opening the account popover. Not a
/// `WorkspaceTitleBarButton` because it draws no symbol — but the same
/// contract in every way the bar depends on: the responder-chain dispatch,
/// the swallowed `mouseDown` so the click is not taken by the window drag,
/// and the pointing hand.
final class TitleBarAccountButton: ShellRowView {
    private let avatar = AccountAvatarView(diameter: 22)

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous
        toolTip = "Account"
        setAccessibilityLabel("Account")

        avatar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(avatar)
        NSLayoutConstraint.activate([
            avatar.centerXAnchor.constraint(equalTo: centerXAnchor),
            avatar.centerYAnchor.constraint(equalTo: centerYAnchor),
            widthAnchor.constraint(equalToConstant: 24),
            heightAnchor.constraint(equalToConstant: 24),
        ])

        onPress = { [weak self] in
            NSApp.sendAction(#selector(WorkspaceWindowController.showAccountMenu(_:)), to: nil, from: self)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func apply(name: String?, picture: NSImage?) {
        avatar.apply(name: name, picture: picture)
    }

    var modeForTesting: AccountAvatarView.AvatarMode { avatar.mode }

    override func mouseDown(with event: NSEvent) {}

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}
