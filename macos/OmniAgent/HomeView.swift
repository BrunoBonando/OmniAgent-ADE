import AppKit
import CoreImage

// The Home destination's real screen — the 2026-08-22 home design: the
// OmniAgent mark over a composer, three suggestion cards, an "Up next" empty
// state, two "Extend your experience" cards and the release notes. Replaces
// the "Under development" placeholder for `.home` only; To Do List keeps the
// placeholder.
//
// Interactive but inert, by decision (2026-08-24 revision of the 2026-08-22
// design-only rule): every control hovers, focuses and presses like the real
// thing — the composer takes typing — but every press lands in a deliberately
// empty `onPress`. The behavior comes as its own step, on top of this screen.
// First exception (2026-08-27): the suggestion cards now type their prompt
// into the composer on press — everything else on the screen is still inert.
//
// Deliberately all AppKit, on the same `ShellPalette`/`ShellFont` tokens the
// sidebar wears, and transparent throughout — `PaneGroundView` behind it is
// the ground, exactly as it is for the placeholder, so switching destinations
// never looks like switching apps.

// MARK: - Small parts

/// The hover, cursor, key and press machinery every interactive Home element
/// shares — `ShellRowView`'s idiom, without the row. A view with no `onPress`
/// is scenery: no hover paint, no hand cursor, no key handling. Presses fire,
/// and most presses on this screen are wired to an empty closure on purpose —
/// the feel ships now, the behavior later.
class HomeInteractiveView: NSView {
    var onPress: (() -> Void)?
    private(set) var isHovered = false
    private var tracking: NSTrackingArea?

    override var acceptsFirstResponder: Bool { onPress != nil }

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

    override func mouseEntered(with event: NSEvent) { setHovered(true) }
    override func mouseExited(with event: NSEvent) { setHovered(false) }

    /// The tests' way in, and the tracking area's: one path for both.
    func setHovered(_ hovered: Bool) {
        guard onPress != nil, hovered != isHovered else { return }
        isHovered = hovered
        applyHover()
    }

    /// Override point: paint the hovered/base state from `isHovered`.
    func applyHover() {}

    override func resetCursorRects() {
        guard onPress != nil else { return }
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseUp(with event: NSEvent) {
        guard onPress != nil,
              bounds.contains(convert(event.locationInWindow, from: nil))
        else { return super.mouseUp(with: event) }
        onPress?()
    }

    override func keyDown(with event: NSEvent) {
        let key = event.charactersIgnoringModifiers
        if onPress != nil, key == "\r" || key == " " {
            onPress?()
            return
        }
        super.keyDown(with: event)
    }
}

/// A rounded token-styled card — the composer, the suggestions, and every
/// section body wear this. With an `onPress` it hovers into the brighter
/// fill-and-stroke pair the design gives clickable cards.
final class HomeCardView: HomeInteractiveView {
    private let baseFill: NSColor

    init(cornerRadius: CGFloat = 12, fill: NSColor = ShellPalette.cardFill) {
        baseFill = fill
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        layer?.cornerRadius = cornerRadius
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = fill.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = ShellPalette.cardStroke.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func applyHover() {
        layer?.backgroundColor = (isHovered ? ShellPalette.cardFillHover : baseFill).cgColor
        layer?.borderColor = (isHovered ? ShellPalette.cardStrokeHover : ShellPalette.cardStroke).cgColor
    }

    /// The composer's editing state wears the hover stroke without the hover
    /// fill — a focus ring in the design's own vocabulary.
    func setFocused(_ focused: Bool) {
        layer?.borderColor = (focused ? ShellPalette.cardStrokeHover : ShellPalette.cardStroke).cgColor
    }
}

/// An invisible hover tile around an inline control — the composer's plus,
/// engine chip, "Auto" and send, the meta strip's "Add workspace", the
/// release card's changelog link. Base and hover fills are configurable so
/// the send circle can keep its accent pair.
final class HomeHotspotView: HomeInteractiveView {
    private let baseFill: NSColor
    private let hoverFill: NSColor

    init(
        wrapping content: NSView,
        padding: NSEdgeInsets = NSEdgeInsets(top: 4, left: 6, bottom: 4, right: 6),
        cornerRadius: CGFloat = 6,
        baseFill: NSColor = .clear,
        hoverFill: NSColor = ShellPalette.hover,
        accessibilityLabel: String
    ) {
        self.baseFill = baseFill
        self.hoverFill = hoverFill
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        layer?.cornerRadius = cornerRadius
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = baseFill.cgColor
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padding.left),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padding.right),
            content.topAnchor.constraint(equalTo: topAnchor, constant: padding.top),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -padding.bottom),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(accessibilityLabel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func applyHover() {
        layer?.backgroundColor = (isHovered ? hoverFill : baseFill).cgColor
    }
}

/// The composer's real text field: type into it and it takes the words; only
/// sending them anywhere is still to come. Focus is surfaced so the card can
/// wear its editing stroke.
final class HomeComposerField: NSTextField {
    var onFocusChange: ((Bool) -> Void)?

    /// Turns the field into a wrapping, multi-line one. Opt-in rather than
    /// the default: the Home screen's composer is a single-line design
    /// surface and this same class draws it, so flipping the class over
    /// would resize a screen that never asked to grow.
    ///
    /// The field editor scrolls within whatever height its owner constrains
    /// the field to, so the caller caps the height and lets long drafts
    /// scroll rather than clipping them.
    func allowMultipleLines() {
        usesSingleLineMode = false
        lineBreakMode = .byWordWrapping
        maximumNumberOfLines = 0
        cell?.wraps = true
        cell?.isScrollable = false
    }

    /// The height this field's current text wants at `width`, which is what
    /// a growing composer sizes itself from. Never below one line: an empty
    /// draft still needs somewhere to put the caret.
    func fittingHeight(forWidth width: CGFloat) -> CGFloat {
        guard let cell, width > 0 else { return 0 }
        let bounds = NSRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude)
        let measured = cell.cellSize(forBounds: bounds).height
        // `cellSize(forBounds:)` measures the *text*, and an empty field has
        // none — it would collapse to nothing without this floor.
        let oneLine = (font?.boundingRectForFont.height ?? 17).rounded(.up)
        return max(measured, oneLine)
    }

    /// Whether the keyboard is actually in this field.
    ///
    /// `window?.firstResponder === self` is the wrong question and answers
    /// `false` on a focused field: an `NSTextField` hands first responder
    /// straight on to the window's shared *field editor*, so the responder
    /// the window reports while you type into this field is an `NSTextView`,
    /// not the field. This asks about that editor instead — and about this
    /// field's own (`currentEditor()` returns `nil` unless the field is the
    /// one editing), so a second field being edited does not read as this
    /// one. `window.isKeyWindow` is deliberately not part of it: it is
    /// unusable under `xcodebuild test`, where no window this host makes ever
    /// genuinely becomes key.
    var currentEditorIsFirstResponder: Bool {
        guard let editor = currentEditor() else { return false }
        return window?.firstResponder === editor
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onFocusChange?(true) }
        return became
    }

    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        onFocusChange?(false)
    }
}

/// The design's small secondary button: icon-tile fill, card stroke, 12.5pt
/// medium label, and the brighter fill on hover.
final class HomePillView: HomeInteractiveView {
    let label: NSTextField

    init(_ title: String) {
        label = ShellFont.label(title, font: ShellFont.ui(12.5, .medium), color: ShellPalette.ink)
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        layer?.cornerRadius = 7
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = ShellPalette.iconTile.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = ShellPalette.cardStroke.cgColor
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 13),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -13),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
        // Interactive from birth — and inert from birth, like the rest of
        // the screen.
        onPress = {}
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func applyHover() {
        layer?.backgroundColor = (isHovered ? ShellPalette.cardFillHover : ShellPalette.iconTile).cgColor
    }
}

/// A tilted rainbow beam, masked to the OmniAgent mark's own silhouette, that
/// drifts through it once every 9 seconds — stack this directly over the
/// glyph at the same size. One looping `CAKeyframeAnimation` drives the
/// whole thing; nothing to schedule or invalidate.
final class HomeMarkShimmerView: NSView {
    /// `size` must match the glyph view this sits over, pixel for pixel —
    /// the mask is built once, at this size, not re-derived from layout.
    init(size: CGFloat) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        guard let layer else { return }

        let mask = CALayer()
        mask.frame = CGRect(x: 0, y: 0, width: size, height: size)
        mask.contentsGravity = .resizeAspect
        mask.contents = OmniAgentMark.image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        layer.mask = mask

        // A soft, blurred rainbow glint — light catching glass and
        // refracting, not a flag. Pastel and feathered at both ends (clear
        // -> hue -> clear), then gaussian-blurred so the hues bleed into one
        // another instead of banding.
        let band = CAGradientLayer()
        band.type = .axial
        band.startPoint = CGPoint(x: 0.5, y: 0)
        band.endPoint = CGPoint(x: 0.5, y: 1)
        band.colors = HomeMarkShimmerView.spectrum
        band.bounds = CGRect(x: 0, y: 0, width: size * 0.55, height: size * 2.4)
        band.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        band.transform = CATransform3DMakeRotation(-0.45, 0, 0, 1)
        // Blurring the band, not the mask above it: the icon's own silhouette
        // stays crisp, only the light inside it goes soft. Only `position`
        // animates below, never a filter input, so Core Animation rasterises
        // the blur once and moves the cached result — one offscreen pass,
        // not one per frame.
        if let blur = CIFilter(name: "CIGaussianBlur") {
            blur.setValue(size * 0.22, forKey: kCIInputRadiusKey)
            band.filters = [blur]
        }
        layer.addSublayer(band)

        let travel = size * 2.2
        let parkedLeft = -travel / 2
        let parkedRight = size + travel / 2
        band.position = CGPoint(x: parkedLeft, y: size / 2)

        // One loop, nine seconds: parked off-glyph (invisible, since the mask
        // has no coverage outside `size`) for a bit over half of it, then a
        // slow, eased four-second drift across. Repeats forever.
        let ease = CAMediaTimingFunction(name: .easeInEaseOut)
        let sweep = CAKeyframeAnimation(keyPath: "position.x")
        sweep.keyTimes = [0, 0.55, 1.0]
        sweep.values = [parkedLeft, parkedLeft, parkedRight]
        sweep.timingFunctions = [ease, ease]
        sweep.duration = 9
        sweep.repeatCount = .infinity
        band.add(sweep, forKey: "sweep")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    /// Feathered pastel spectrum: clear, eight hues at low saturation and
    /// high brightness — a glassy reflection, not a rainbow flag — back to
    /// clear.
    private static let spectrum: [CGColor] = {
        let hues: [CGFloat] = [0, 1 / 7, 2 / 7, 3 / 7, 4 / 7, 5 / 7, 6 / 7, 1]
        let vivid = hues.map { NSColor(hue: $0, saturation: 0.45, brightness: 1, alpha: 0.85).cgColor }
        let clear = NSColor(hue: 0, saturation: 0, brightness: 1, alpha: 0).cgColor
        return [clear] + vivid + [clear]
    }()
}

/// One entry in `home-suggestions.json`: the card's icon and short title, and
/// the full prompt a click types into the composer.
struct HomeSuggestion: Decodable {
    /// Which of the three things a suggestion is for. The daily pick takes
    /// one of each, in this order, so the three cards always cover the
    /// three reasons someone opens Home rather than three variations on one.
    enum Kind: String, Decodable, CaseIterable {
        /// Work on the codebase that is open — the current project.
        case project
        /// Build something that does not exist yet: a new project, a
        /// watcher agent, a research report, a news dashboard.
        case create
        /// Just talk — a thinking partner, no code. ponytail: these are
        /// meant to run in a scratch session under
        /// `~/Documents/OmniAgent/Chats/` rather than a code workspace;
        /// that lands with Send, which is not wired yet.
        case chat
    }

    let kind: Kind
    let icon: String
    let title: String
    let prompt: String
}

/// A tiny xorshift64 PRNG — deterministic from a seed, unlike
/// `SystemRandomNumberGenerator`, which is what lets the same day pick the
/// same three suggestions on every launch.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: Int) {
        state = UInt64(bitPattern: Int64(seed)) &+ 0x9E37_79B9_7F4A_7C15
        if state == 0 { state = 0x9E37_79B9_7F4A_7C15 }
    }

    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}

/// The scratch "workspace" a plain chat runs in — not a project, just a
/// folder under Documents so a conversation has somewhere to keep its
/// transcript without landing inside someone's repo. Listed first in Home's
/// project dropdown (the design's "Chat" row); never in the sidebar, which
/// only shows the brain's real projects.
enum HomeChatWorkspace {
    static let id = "omniagent-home-chat"
    static let label = "Chat"
    static var directory: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/OmniAgent/Chats", isDirectory: true).path
    }
}

// MARK: - Home

final class HomeSurfaceView: NSView {
    /// Shared by the card's own corner and the focus glow wrapped around it
    /// — one number, so the glow's band always sits flush.
    private static let composerCornerRadius: CGFloat = 14

    // Exposed for the tests, which assert the design's words without walking
    // the whole tree.
    let composerCard = HomeCardView(cornerRadius: HomeSurfaceView.composerCornerRadius, fill: ShellPalette.fieldFill)
    let composerPrompt: HomeComposerField = {
        let field = HomeComposerField()
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = ShellFont.ui(14)
        field.textColor = ShellPalette.ink
        field.placeholderAttributedString = NSAttributedString(
            string: "Ask anything, or start a session. Use / for commands…",
            attributes: [
                .foregroundColor: ShellPalette.inkMuted,
                .font: ShellFont.ui(14),
            ]
        )
        field.allowMultipleLines()
        field.translatesAutoresizingMaskIntoConstraints = false
        return field
    }()
    /// The composer's own focus ring — `PaneFocusGlowView` is the exact
    /// class a focused terminal pane uses, reused rather than reimplemented.
    private let composerGlow = PaneFocusGlowView()
    private(set) var suggestionCards: [HomeCardView] = []
    let viewAllPill = HomePillView("View all")
    let markImageView = NSImageView()
    /// The sidebar's own folder glyph — open, since the chip *is* the chosen
    /// workspace — in the sidebar's colour for it, so the two surfaces
    /// agree on what a workspace looks like.
    let workspaceChipFolder = ShellGlyphView(.folderOpen, color: ShellPalette.folderGlyph, size: 17, lineWidth: 1.1)
    /// Stands in for the tile when the Chat scratch workspace is picked.
    let workspaceChipIcon: NSImageView = {
        let view = NSImageView()
        view.image = NSImage(systemSymbolName: "bubble.left", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
        view.contentTintColor = ShellPalette.accentBright
        view.translatesAutoresizingMaskIntoConstraints = false
        view.isHidden = true
        return view
    }()
    let workspaceChipName = ShellFont.label(
        font: ShellFont.ui(12.5, .medium),
        color: ShellPalette.inkSecondary
    )
    /// The session picked (or "New session") for whatever the composer would
    /// start — updated by whoever owns `onRequestSessionMenu`, same as the
    /// workspace chip is updated by `refresh`.
    let sessionChipLabel = ShellFont.label(
        "New session",
        font: ShellFont.ui(12.5, .medium),
        color: ShellPalette.inkSecondary
    )
    /// The branch that session would run on — "main", or "main → new-name"
    /// for a branch to be created off it. With no git repo behind the
    /// workspace it reads "Set up GitHub" instead of hiding: not every
    /// OmniAgent user has git, and the chip is where they learn the app can
    /// connect for them.
    let branchLabel = ShellFont.label(font: ShellFont.ui(12.5, .medium), color: ShellPalette.inkSecondary)
    private(set) var branchChip: HomeHotspotView?
    /// The existing branch the session would use — or, when `newBranchName`
    /// is set, the one it would branch *from*.
    private(set) var selectedBranch: String?
    private(set) var newBranchName: String?
    let versionLabel = ShellFont.label(
        font: ShellFont.ui(13.5, .semibold),
        color: ShellPalette.ink
    )
    private(set) var sendControl: HomeHotspotView?
    /// Local to the composer, not yet wired to Send — the same "feel now,
    /// behavior later" position the whole screen started from. Defaults
    /// match what a fresh terminal pane defaults to.
    private var selectedEngine = EngineLauncher.defaultEngine()
    private var selectedModel: ModelChoice?
    private let engineIconView = NSImageView()
    private let engineNameLabel = ShellFont.label(font: ShellFont.ui(12.5, .medium), color: ShellPalette.inkSecondary)
    private let modelLabel = ShellFont.label(font: ShellFont.ui(12.5), color: ShellPalette.inkTertiary)
    /// Fired with the anchor to pop a menu from — the owner builds it, since
    /// only it holds the live workspace/session lists (the exact split
    /// `onRequestEngineMenu`/`onRequestModelMenu` already draw on a pane).
    var onRequestProjectMenu: ((NSView) -> Void)?
    var onRequestSessionMenu: ((NSView) -> Void)?
    var onRequestBranchMenu: ((NSView) -> Void)?
    /// The suggestion cards' reveal-loop timer — one at a time; pressing a
    /// second card mid-type invalidates and restarts it.
    private var typingTimer: Timer?
    /// Test seam only, same convention as `PaneFocusGlowView.gradientForTesting`.
    var typingTimerForTesting: Timer? { typingTimer }

    private let column = NSStackView()

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        column.orientation = .vertical
        column.alignment = .centerX
        column.spacing = 0
        column.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(column)

        let scroll = ShellScrollView(documentView: content)
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),

            // The design's centred 880pt column, giving way on thin windows.
            // 200pt of top air (up from the design's original 120) is what
            // actually reads as "higher than middle" — tying it to the
            // scroll view's own visible height instead read fine in an
            // offscreen render, but in the real window it left everything
            // below the composer sitting in a near-empty stretch down to
            // the fold. A fixed number can't perfectly centre on every
            // window height, but it can't produce that dead zone either.
            column.topAnchor.constraint(equalTo: content.topAnchor, constant: 200),
            column.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -36),
            column.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            column.leadingAnchor.constraint(greaterThanOrEqualTo: content.leadingAnchor, constant: 40),
        ])
        let width = column.widthAnchor.constraint(equalToConstant: 880)
        width.priority = .defaultHigh
        width.isActive = true

        let heroIcon = buildHeroIcon()
        column.addArrangedSubview(heroIcon)
        column.setCustomSpacing(48, after: heroIcon)

        let composer = buildComposer()
        column.addArrangedSubview(composer)
        composer.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        column.addSubview(composerGlow, positioned: .above, relativeTo: composer)
        column.setCustomSpacing(40, after: composer)
        buildSuggestions()
        buildUpNext()
        buildExtend()
        buildWhatsNew()
        buildFooter()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    deinit { typingTimer?.invalidate() }

    /// What the meta strip says a new session lands in. Called on every visit
    /// so a workspace switch shows up without any observing. `sessionLabel`
    /// and `branch` are the owner's freshly computed default (first session,
    /// or "New session" when the workspace has none) — Home never derives
    /// them itself, the same split as the workspace name/id it already took.
    func refresh(
        workspaceID: String?,
        workspaceName: String?,
        tint: NSColor? = nil,
        sessionLabel: String = "New session",
        branch: String? = nil
    ) {
        workspaceChipName.stringValue = workspaceName ?? "Select workspace"
        // The Chat scratch workspace wears a speech bubble, not a folder —
        // it is not a project. No workspace at all wears neither.
        let isChat = workspaceID == HomeChatWorkspace.id
        workspaceChipFolder.isHidden = isChat || workspaceID == nil
        workspaceChipIcon.isHidden = !isChat
        workspaceChipFolder.color = tint ?? ShellPalette.folderGlyph
        sessionChipLabel.stringValue = sessionLabel
        updateBranchChip(existing: branch)
        // Chat is not a project: no branch, and nothing to set up either.
        branchChip?.isHidden = isChat
    }

    /// The session chip after a pick from `onRequestSessionMenu`'s menu — the
    /// owner calls this directly rather than routing back through `refresh`,
    /// which would also re-derive the workspace chip for no reason.
    func updateSessionChip(label: String, branch: String?) {
        sessionChipLabel.stringValue = label
        updateBranchChip(existing: branch)
    }

    /// An existing branch picked (or the workspace's current one on
    /// refresh) — clears any pending new-branch name. `nil` means no git:
    /// the chip offers to set up GitHub instead.
    func updateBranchChip(existing branch: String?) {
        selectedBranch = branch
        newBranchName = nil
        branchLabel.stringValue = branch ?? Self.setUpGitHubTitle
        branchChip?.isHidden = false
    }

    static let setUpGitHubTitle = "Set up GitHub"

    /// A branch to be created off `base` when the session starts — shown as
    /// "base → name", the arrow being the whole point: it says "this does
    /// not exist yet" without a word of explanation.
    func updateBranchChip(new name: String, from base: String) {
        selectedBranch = base
        newBranchName = name
        branchLabel.stringValue = "\(base) → \(name)"
        branchChip?.isHidden = false
    }

    /// Every selectable engine, icon and all, greying the ones not on
    /// `PATH` and checking the current one — a `HomeDropdown`, not a stock
    /// `NSMenu`. No paneID, unlike a terminal pane's `engineMenu(for:)`:
    /// Home has no conversation to lose by switching, so there is nothing
    /// to ask about first.
    private func presentEngineMenu(from anchor: NSView) {
        let rows = EngineLauncher.selectable.map { engine -> HomeDropdown.Row in
            let installed = EngineLauncher.isInstalled(engine)
            return HomeDropdown.Row(
                icon: engine.iconImage,
                title: installed ? engine.badgeTitle : "\(engine.badgeTitle) — not installed",
                isCurrent: engine == selectedEngine,
                isEnabled: installed
            ) { [weak self] in self?.applyEngine(engine) }
        }
        HomeDropdown.show([HomeDropdown.Section(rows: rows)], searchPlaceholder: "Search engines…", from: anchor)
    }

    private func applyEngine(_ engine: Engine) {
        selectedEngine = engine
        engineIconView.image = engine.iconImage
        engineNameLabel.stringValue = engine.displayName
        // A new engine invalidates whatever model was picked for the old
        // one — back to "Auto" rather than carrying over a choice that may
        // not even exist on the new engine's list.
        selectedModel = nil
        modelLabel.stringValue = "Auto"
    }

    /// `EngineModelList.cached(for:)`, or a "Loading models…" row that
    /// re-shows itself filled in once the (async, first-run-only) fetch
    /// lands — identical data source to a pane's `modelMenu(for:)`, just a
    /// `HomeDropdown` instead of an `NSMenu`.
    private func presentModelMenu(from anchor: NSView) {
        let engine = selectedEngine
        let placeholder = "Search models…"
        guard engine != .shell else {
            HomeDropdown.show(
                [HomeDropdown.Section(rows: [HomeDropdown.Row(title: "Shell has no model", isEnabled: false) {}])],
                searchPlaceholder: placeholder,
                from: anchor
            )
            return
        }
        if let choices = EngineModelList.cached(for: engine) {
            HomeDropdown.show([modelSection(choices)], searchPlaceholder: placeholder, from: anchor)
            return
        }
        let dropdown = HomeDropdown.show(
            [HomeDropdown.Section(rows: [HomeDropdown.Row(title: "Loading models…", isEnabled: false) {}])],
            searchPlaceholder: placeholder,
            from: anchor
        )
        DispatchQueue.global(qos: .userInitiated).async { [weak self, weak dropdown] in
            let choices = EngineModelList.fetch(for: engine)
            DispatchQueue.main.async {
                // The user may have switched engines, or closed the
                // dropdown (`dropdown` gone), while this was in flight — a
                // stale answer must not land anywhere. Swapped in place,
                // never re-presented: no flicker.
                guard let self, let dropdown, self.selectedEngine == engine else { return }
                dropdown.sections = choices.isEmpty
                    ? [HomeDropdown.Section(rows: [
                        HomeDropdown.Row(title: "Could not reach \(engine.displayName)", isEnabled: false) {},
                    ])]
                    : [self.modelSection(choices)]
            }
        }
    }

    private func modelSection(_ choices: [ModelChoice]) -> HomeDropdown.Section {
        HomeDropdown.Section(rows: choices.map { choice in
            HomeDropdown.Row(title: choice.label, isCurrent: choice.id == selectedModel?.id) { [weak self] in
                self?.selectedModel = choice
                self?.modelLabel.stringValue = choice.label
            }
        })
    }

    /// Clears the composer and reveals `text` one character at a time — the
    /// suggestion cards' "this is what I'd ask" gesture. One `Timer`;
    /// pressing another card mid-type invalidates and restarts it rather
    /// than layering two reveals.
    private func typeIntoComposer(_ text: String) {
        typingTimer?.invalidate()
        composerPrompt.stringValue = ""
        guard !text.isEmpty else { return }
        let characters = Array(text)
        var length = 0
        let timer = Timer(timeInterval: 0.006, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            length += 1
            self.composerPrompt.stringValue = String(characters[0..<length])
            if length == characters.count {
                timer.invalidate()
                self.typingTimer = nil
            }
        }
        timer.tolerance = 0.002
        RunLoop.main.add(timer, forMode: .common)
        typingTimer = timer
    }

    /// `home-suggestions.json`, bundled with the app — the pool the daily
    /// three suggestion cards are drawn from. Empty (not a crash) if the
    /// resource is somehow missing or malformed.
    static func loadSuggestionPool() -> [HomeSuggestion] {
        guard
            let url = Bundle.main.url(forResource: "home-suggestions", withExtension: "json"),
            let data = try? Data(contentsOf: url),
            let pool = try? JSONDecoder().decode([HomeSuggestion].self, from: data)
        else { return [] }
        return pool
    }

    /// One suggestion per `Kind`, in `Kind.allCases` order (project, create,
    /// chat), deterministic for a given `seed` — the call site seeds with
    /// today's date so the same three show all day and a fresh three appear
    /// tomorrow, with no state to persist. A kind with nothing in the pool
    /// is simply skipped rather than padded from another.
    static func dailySuggestions(
        from pool: [HomeSuggestion],
        seed: Int = Calendar.current.ordinality(of: .day, in: .era, for: Date()) ?? 0
    ) -> [HomeSuggestion] {
        var rng = SeededGenerator(seed: seed)
        return HomeSuggestion.Kind.allCases.compactMap { kind in
            pool.filter { $0.kind == kind }.randomElement(using: &rng)
        }
    }

    // MARK: Sections

    private func buildHeroIcon() -> NSView {
        // The OmniAgent mark alone — no tile, no fill. The glow comes from
        // the glyph's own alpha (no `shadowPath`, so it hugs the mark's
        // shape rather than a box), and a rainbow beam drifts through the
        // same silhouette every 9 seconds via `HomeMarkShimmerView`.
        let size: CGFloat = 44
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        markImageView.image = OmniAgentMark.image
        markImageView.contentTintColor = .white
        markImageView.imageScaling = .scaleProportionallyUpOrDown
        markImageView.translatesAutoresizingMaskIntoConstraints = false
        markImageView.wantsLayer = true
        markImageView.layer?.shadowColor = ShellPalette.accent.cgColor
        markImageView.layer?.shadowOpacity = 0.55
        markImageView.layer?.shadowRadius = 22
        markImageView.layer?.shadowOffset = .zero

        let shimmer = HomeMarkShimmerView(size: size)

        container.addSubview(markImageView)
        container.addSubview(shimmer)
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: size),
            container.heightAnchor.constraint(equalToConstant: size),
            markImageView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            markImageView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            markImageView.topAnchor.constraint(equalTo: container.topAnchor),
            markImageView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            shimmer.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            shimmer.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            shimmer.topAnchor.constraint(equalTo: container.topAnchor),
            shimmer.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    private func buildComposer() -> NSView {
        composerPrompt.onFocusChange = { [weak self] focused in
            guard let self else { return }
            self.composerCard.setFocused(focused)
            // The same glow a focused terminal pane wears in the workspace
            // grid (`PaneFocusGlowView`) — not a lookalike, the identical
            // class and animation, so the composer reads as the same kind
            // of "this is the live one" focus the rest of the app uses.
            if focused {
                self.composerGlow.apply(
                    around: self.composerCard.frame,
                    cornerRadius: Self.composerCornerRadius,
                    edge: ShellPalette.accent,
                    peak: ShellPalette.accentPurple,
                    paneID: "home-composer"
                )
            } else {
                self.composerGlow.apply(around: nil, cornerRadius: 0, edge: nil, peak: nil, paneID: nil)
            }
        }

        engineIconView.image = selectedEngine.iconImage
        // Full ink, never a muted grey: brand marks ignore the tint anyway,
        // and the template ones (Shell, Copilot) should read as vividly as
        // the coloured ones beside them.
        engineIconView.contentTintColor = ShellPalette.ink
        engineIconView.imageScaling = .scaleProportionallyDown
        engineIconView.translatesAutoresizingMaskIntoConstraints = false
        engineNameLabel.stringValue = selectedEngine.displayName
        let chipStack = NSStackView(views: [engineIconView, engineNameLabel])
        chipStack.orientation = .horizontal
        chipStack.spacing = 7
        let engineChip = HomeHotspotView(
            wrapping: chipStack,
            accessibilityLabel: "Engine: \(selectedEngine.displayName)"
        )
        engineChip.onPress = { [weak self, weak engineChip] in
            guard let self, let engineChip else { return }
            self.presentEngineMenu(from: engineChip)
        }

        let plus = HomeHotspotView(
            wrapping: symbol("plus", pointSize: 13, weight: .medium, color: ShellPalette.inkTertiary),
            accessibilityLabel: "Attach"
        )
        plus.onPress = {}

        modelLabel.stringValue = "Auto"
        let auto = HomeHotspotView(
            wrapping: modelLabel,
            accessibilityLabel: "Model: Auto"
        )
        auto.onPress = { [weak self, weak auto] in
            guard let self, let auto else { return }
            self.presentModelMenu(from: auto)
        }

        let sendBox = NSView()
        sendBox.translatesAutoresizingMaskIntoConstraints = false
        let arrow = symbol("arrow.up", pointSize: 13, weight: .semibold, color: ShellPalette.accentBright)
        sendBox.addSubview(arrow)
        let send = HomeHotspotView(
            wrapping: sendBox,
            padding: NSEdgeInsets(),
            cornerRadius: 16,
            baseFill: ShellPalette.accentIconTile,
            hoverFill: ShellPalette.accentRail,
            accessibilityLabel: "Send"
        )
        send.onPress = {}
        sendControl = send

        let separator = NSView()
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.wantsLayer = true
        separator.layer?.backgroundColor = ShellPalette.cardStroke.cgColor

        let controls = NSStackView(views: [plus, engineChip, separator, auto, NSView(), send])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 8
        controls.translatesAutoresizingMaskIntoConstraints = false

        let meta = buildComposerMeta()

        composerCard.addSubview(composerPrompt)
        composerCard.addSubview(controls)
        composerCard.addSubview(meta)
        composerPrompt.translatesAutoresizingMaskIntoConstraints = false
        // Three lines tall at rest, scrolling internally past that — see
        // `allowMultipleLines()`'s own comment on why a fixed height is what
        // makes the field editor scroll instead of the field growing.
        let promptLineHeight = (composerPrompt.font ?? ShellFont.ui(14)).boundingRectForFont.height.rounded(.up)
        NSLayoutConstraint.activate([
            engineIconView.widthAnchor.constraint(equalToConstant: 16),
            engineIconView.heightAnchor.constraint(equalToConstant: 16),
            separator.widthAnchor.constraint(equalToConstant: 1),
            separator.heightAnchor.constraint(equalToConstant: 16),
            sendBox.widthAnchor.constraint(equalToConstant: 32),
            sendBox.heightAnchor.constraint(equalToConstant: 32),
            arrow.centerXAnchor.constraint(equalTo: sendBox.centerXAnchor),
            arrow.centerYAnchor.constraint(equalTo: sendBox.centerYAnchor),

            composerPrompt.topAnchor.constraint(equalTo: composerCard.topAnchor, constant: 20),
            composerPrompt.leadingAnchor.constraint(equalTo: composerCard.leadingAnchor, constant: 20),
            composerPrompt.trailingAnchor.constraint(equalTo: composerCard.trailingAnchor, constant: -20),
            composerPrompt.heightAnchor.constraint(equalToConstant: promptLineHeight * 3),
            controls.topAnchor.constraint(equalTo: composerPrompt.bottomAnchor, constant: 18),
            controls.leadingAnchor.constraint(equalTo: composerCard.leadingAnchor, constant: 16),
            controls.trailingAnchor.constraint(equalTo: composerCard.trailingAnchor, constant: -14),
            meta.topAnchor.constraint(equalTo: controls.bottomAnchor, constant: 14),
            meta.leadingAnchor.constraint(equalTo: composerCard.leadingAnchor),
            meta.trailingAnchor.constraint(equalTo: composerCard.trailingAnchor),
            meta.bottomAnchor.constraint(equalTo: composerCard.bottomAnchor),
        ])

        return composerCard
    }

    /// The strip under the composer: where a session would land. ponytail:
    /// the design's worktree and branch chips wait until Home can actually
    /// make worktrees / read the branch.
    /// The strip under the composer: the workspace a new session would land
    /// in, which of its sessions (or a new one), and the branch that implies
    /// — "Add workspace" is gone, folded into the project dropdown's own
    /// "Local folder or repository…" entry.
    private func buildComposerMeta() -> NSView {
        let strip = NSView()
        strip.translatesAutoresizingMaskIntoConstraints = false
        strip.wantsLayer = true
        strip.layer?.backgroundColor = ShellPalette.backRowFill.cgColor

        let rule = ShellSeparator()

        let projectStack = NSStackView(views: [workspaceChipFolder, workspaceChipIcon, workspaceChipName])
        projectStack.orientation = .horizontal
        projectStack.spacing = 7
        let project = HomeHotspotView(wrapping: projectStack, accessibilityLabel: "Project")
        project.onPress = { [weak self, weak project] in
            guard let self, let project else { return }
            self.onRequestProjectMenu?(project)
        }

        let divider = NSView()
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.wantsLayer = true
        divider.layer?.backgroundColor = ShellPalette.cardStroke.cgColor

        let chevron = symbol("chevron.up.chevron.down", pointSize: 8.5, weight: .semibold, color: ShellPalette.inkMuted)
        let sessionStack = NSStackView(views: [sessionChipLabel, chevron])
        sessionStack.orientation = .horizontal
        sessionStack.spacing = 5
        let session = HomeHotspotView(wrapping: sessionStack, accessibilityLabel: "Session")
        session.onPress = { [weak self, weak session] in
            guard let self, let session else { return }
            self.onRequestSessionMenu?(session)
        }

        // The branch chip — same button treatment as the session chip, with
        // the design's branch glyph in front. Hidden until a git repo says
        // otherwise (`updateBranchChip`).
        let branchIcon = symbol("arrow.triangle.branch", pointSize: 11, weight: .medium, color: ShellPalette.inkTertiary)
        let branchStack = NSStackView(views: [branchIcon, branchLabel])
        branchStack.orientation = .horizontal
        branchStack.spacing = 6
        let branch = HomeHotspotView(wrapping: branchStack, accessibilityLabel: "Branch")
        branch.onPress = { [weak self, weak branch] in
            guard let self, let branch else { return }
            self.onRequestBranchMenu?(branch)
        }
        branch.isHidden = true
        branchChip = branch

        let row = NSStackView(views: [project, divider, session, branch, NSView()])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        strip.addSubview(rule)
        strip.addSubview(row)
        NSLayoutConstraint.activate([
            rule.topAnchor.constraint(equalTo: strip.topAnchor),
            rule.leadingAnchor.constraint(equalTo: strip.leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: strip.trailingAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),
            divider.heightAnchor.constraint(equalToConstant: 14),
            row.topAnchor.constraint(equalTo: strip.topAnchor, constant: 9),
            row.bottomAnchor.constraint(equalTo: strip.bottomAnchor, constant: -9),
            row.leadingAnchor.constraint(equalTo: strip.leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(equalTo: strip.trailingAnchor, constant: -16),
        ])

        return strip
    }

    private func buildSuggestions() {
        let suggestions = HomeSurfaceView.dailySuggestions(from: HomeSurfaceView.loadSuggestionPool())
        let cards = suggestions.map { suggestion in
            let card = HomeCardView()
            card.onPress = { [weak self] in self?.typeIntoComposer(suggestion.prompt) }
            let icon = symbol(suggestion.icon, pointSize: 15, weight: .regular, color: ShellPalette.inkTertiary)
            let body = wrapping(suggestion.title, font: ShellFont.ui(13), color: ShellPalette.inkSecondary)
            card.addSubview(icon)
            card.addSubview(body)
            NSLayoutConstraint.activate([
                icon.topAnchor.constraint(equalTo: card.topAnchor, constant: 18),
                icon.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
                body.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 14),
                body.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
                body.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -18),
                body.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -20),
            ])
            return card
        }
        suggestionCards = cards
        let row = NSStackView(views: cards)
        row.orientation = .horizontal
        row.distribution = .fillEqually
        row.spacing = 16
        column.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        // Equal height, not just equal width — `NSStackView.alignment` has
        // no AppKit "fill the cross axis" case (that's a UIKit-only value),
        // so a two-line title must be kept from leaving its neighbours
        // shorter by pinning every card's height to the first one's. Only
        // legal now that every card shares `row`'s hierarchy.
        for card in cards.dropFirst() {
            card.heightAnchor.constraint(equalTo: cards[0].heightAnchor).isActive = true
        }
        column.setCustomSpacing(72, after: row)
    }

    private func buildUpNext() {
        addSectionHeader(
            "Up next",
            sub: "Recently updated sessions and tasks across your workspaces."
        )
        let card = HomeCardView()
        let icon = symbol("checkmark.circle", pointSize: 20, weight: .regular, color: ShellPalette.inkTertiary)
        let title = ShellFont.label(
            "You're all caught up",
            font: ShellFont.ui(15, .semibold),
            color: ShellPalette.ink
        )
        let stack = NSStackView(views: [icon, title, viewAllPill])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 56),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -56),
            stack.centerXAnchor.constraint(equalTo: card.centerXAnchor),
        ])
        column.addArrangedSubview(card)
        card.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        column.setCustomSpacing(72, after: card)
    }

    private func buildExtend() {
        addSectionHeader(
            "Extend your experience",
            sub: "Find new ways to work with the app, from connecting your tools to growing its memory."
        )
        let extras: [(String, String, String, String)] = [
            (
                "puzzlepiece.extension",
                "Extend with MCP servers",
                "Connect tools like Figma, Playwright, or Linear so agents can take actions beyond your codebase.",
                "Add MCP server"
            ),
            (
                "brain",
                "Grow the brain",
                "Ingest repositories into the knowledge graph so every agent answers with your code's context.",
                "Add repository"
            ),
        ]
        let cards = extras.map { name, title, body, pillTitle in
            let card = HomeCardView()
            let icon = symbol(name, pointSize: 17, weight: .regular, color: ShellPalette.accent)
            let heading = ShellFont.label(title, font: ShellFont.ui(14, .semibold), color: ShellPalette.ink)
            let text = wrapping(body, font: ShellFont.ui(13), color: ShellPalette.inkTertiary)
            let pill = HomePillView(pillTitle)
            for view in [icon, heading, text, pill] { card.addSubview(view) }
            NSLayoutConstraint.activate([
                icon.topAnchor.constraint(equalTo: card.topAnchor, constant: 22),
                icon.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 22),
                heading.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 12),
                heading.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 22),
                text.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 8),
                text.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 22),
                text.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -22),
                pill.topAnchor.constraint(equalTo: text.bottomAnchor, constant: 14),
                pill.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 22),
                pill.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -20),
            ])
            return card
        }
        let row = NSStackView(views: cards)
        row.orientation = .horizontal
        row.distribution = .fillEqually
        row.spacing = 16
        column.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        // Same reasoning as `buildSuggestions()`'s cards: equal height, pinned
        // card-to-card since `NSStackView.alignment` has no AppKit fill case.
        // Only legal now that every card shares `row`'s hierarchy.
        for card in cards.dropFirst() {
            card.heightAnchor.constraint(equalTo: cards[0].heightAnchor).isActive = true
        }
        column.setCustomSpacing(72, after: row)
    }

    private func buildWhatsNew() {
        addSectionHeader("What's new", sub: "Explore the changes included in the latest release.")

        let card = HomeCardView()

        let releaseTile = NSView()
        releaseTile.translatesAutoresizingMaskIntoConstraints = false
        releaseTile.wantsLayer = true
        let gradient = CAGradientLayer()
        gradient.colors = [ShellPalette.avatarGradients[0].0, ShellPalette.avatarGradients[0].1]
            .map(\.cgColor)
        gradient.startPoint = CGPoint(x: 0.25, y: 1)
        gradient.endPoint = CGPoint(x: 0.75, y: 0)
        gradient.cornerRadius = 10
        gradient.cornerCurve = .continuous
        releaseTile.layer = gradient
        let smallMark = NSImageView()
        smallMark.image = OmniAgentMark.image
        smallMark.contentTintColor = .white
        smallMark.imageScaling = .scaleProportionallyUpOrDown
        smallMark.translatesAutoresizingMaskIntoConstraints = false
        releaseTile.addSubview(smallMark)

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        versionLabel.stringValue = "OmniAgent ADE \(version ?? "")"
        let release = NSStackView(views: [releaseTile, versionLabel, HomePillView("Check for updates")])
        release.orientation = .vertical
        release.alignment = .leading
        release.spacing = 14
        release.translatesAutoresizingMaskIntoConstraints = false

        let divider = NSView()
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.wantsLayer = true
        divider.layer?.backgroundColor = ShellPalette.hairline.cgColor

        let notes = [
            "The sidebar keeps an eye on the machine — CPU, memory, and GPU live in the session hover card.",
            "The git tab now leads with the diff: files changed, insertions, and deletions at a glance.",
            "Engine badges follow a hand-typed /model, and every Claude pane wears one.",
        ]
        let bullets = notes.map { note -> NSView in
            let dot = NSView()
            dot.translatesAutoresizingMaskIntoConstraints = false
            dot.wantsLayer = true
            dot.layer?.cornerRadius = 2.5
            dot.layer?.backgroundColor = ShellPalette.inkFaint.cgColor
            let text = wrapping(note, font: ShellFont.ui(13), color: ShellPalette.inkSecondary)
            let row = NSView()
            row.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(dot)
            row.addSubview(text)
            NSLayoutConstraint.activate([
                dot.widthAnchor.constraint(equalToConstant: 5),
                dot.heightAnchor.constraint(equalToConstant: 5),
                dot.leadingAnchor.constraint(equalTo: row.leadingAnchor),
                dot.topAnchor.constraint(equalTo: row.topAnchor, constant: 7),
                text.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 12),
                text.trailingAnchor.constraint(equalTo: row.trailingAnchor),
                text.topAnchor.constraint(equalTo: row.topAnchor),
                text.bottomAnchor.constraint(equalTo: row.bottomAnchor),
            ])
            return row
        }
        let changelogLabel = ShellFont.label(
            "Read changelog ↗",
            font: ShellFont.ui(13, .medium),
            color: ShellPalette.accentBright
        )
        let changelog = HomeHotspotView(wrapping: changelogLabel, accessibilityLabel: "Read changelog")
        changelog.onPress = {}
        let changes = NSStackView(views: bullets + [changelog])
        changes.orientation = .vertical
        changes.alignment = .leading
        changes.spacing = 13
        changes.translatesAutoresizingMaskIntoConstraints = false
        for bullet in bullets {
            bullet.widthAnchor.constraint(equalTo: changes.widthAnchor).isActive = true
        }

        card.addSubview(release)
        card.addSubview(divider)
        card.addSubview(changes)
        NSLayoutConstraint.activate([
            releaseTile.widthAnchor.constraint(equalToConstant: 40),
            releaseTile.heightAnchor.constraint(equalToConstant: 40),
            smallMark.widthAnchor.constraint(equalToConstant: 22),
            smallMark.heightAnchor.constraint(equalToConstant: 22),
            smallMark.centerXAnchor.constraint(equalTo: releaseTile.centerXAnchor),
            smallMark.centerYAnchor.constraint(equalTo: releaseTile.centerYAnchor),

            release.topAnchor.constraint(equalTo: card.topAnchor, constant: 26),
            release.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 24),
            release.widthAnchor.constraint(equalToConstant: 232),
            release.bottomAnchor.constraint(lessThanOrEqualTo: card.bottomAnchor, constant: -26),

            divider.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 280),
            divider.topAnchor.constraint(equalTo: card.topAnchor),
            divider.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),

            changes.topAnchor.constraint(equalTo: card.topAnchor, constant: 26),
            changes.leadingAnchor.constraint(equalTo: divider.trailingAnchor, constant: 28),
            changes.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -28),
            changes.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -26),
        ])

        column.addArrangedSubview(card)
        card.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        column.setCustomSpacing(88, after: card)
    }

    private func buildFooter() {
        let footer = ShellFont.label(
            "OmniAgent uses AI. Check for mistakes.",
            font: ShellFont.ui(12),
            color: ShellPalette.inkFaint
        )
        column.addArrangedSubview(footer)
    }

    // MARK: Shared pieces

    private func addSectionHeader(_ title: String, sub: String) {
        let heading = ShellFont.label(title, font: ShellFont.ui(15, .semibold), color: ShellPalette.ink)
        let subtitle = ShellFont.label(sub, font: ShellFont.ui(13), color: ShellPalette.inkMuted)
        let stack = NSStackView(views: [heading, subtitle])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 5
        column.addArrangedSubview(stack)
        stack.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        column.setCustomSpacing(22, after: stack)
    }

    private func symbol(
        _ name: String,
        pointSize: CGFloat,
        weight: NSFont.Weight,
        color: NSColor
    ) -> NSImageView {
        let view = NSImageView()
        view.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: pointSize, weight: weight))
        view.contentTintColor = color
        view.translatesAutoresizingMaskIntoConstraints = false
        view.setContentHuggingPriority(.required, for: .horizontal)
        return view
    }

    private func wrapping(_ text: String, font: NSFont, color: NSColor) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = font
        field.textColor = color
        field.isSelectable = false
        field.translatesAutoresizingMaskIntoConstraints = false
        return field
    }
}
