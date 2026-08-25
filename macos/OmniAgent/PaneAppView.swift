import AppKit
import CoreImage
import QuartzCore

/// One block of a `.text` block's raw string — see `MarkdownBlock.parse`.
/// Internal rather than `private` so `PaneAppViewTests` can assert on a parse
/// directly, without going through a live row.
enum MarkdownBlock: Equatable {
    case paragraph(String)
    case heading(level: Int, text: String)
    case list(items: [String], ordered: Bool)
    case code(String)
    case table(header: [String], rows: [[String]])

    /// Splits raw assistant text into blocks by scanning it a line at a time.
    ///
    /// A line scanner, not a markdown parser: a line's prefix decides its
    /// block and consecutive lines of a kind accumulate. Deliberately
    /// forgiving, because this runs against a reply another process is still
    /// writing — an unterminated fence runs to the end, and anything that
    /// fails to be a table falls back to the prose it came from rather than
    /// being dropped.
    ///
    /// Inline emphasis inside a block is left to
    /// `PaneAppView.attributedMarkdown`; block structure is this function's
    /// job alone.
    static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var code: [String] = []
        var items: [String] = []
        var ordered = false
        var pipes: [String] = []
        var inFence = false

        func flushParagraph() {
            let joined = paragraph.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            paragraph = []
            guard !joined.isEmpty else { return }
            blocks.append(.paragraph(joined))
        }
        func flushList() {
            guard !items.isEmpty else { return }
            blocks.append(.list(items: items, ordered: ordered))
            items = []
        }
        func flushPipes() {
            guard !pipes.isEmpty else { return }
            blocks.append(table(from: pipes) ?? .paragraph(pipes.joined(separator: "\n")))
            pipes = []
        }
        // Only ever called from a branch that is not itself accumulating, so
        // the fixed order here can never reorder two live accumulators.
        func flushAll() {
            flushParagraph()
            flushList()
            flushPipes()
        }

        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                if inFence {
                    blocks.append(.code(code.joined(separator: "\n")))
                    code = []
                } else {
                    flushAll()
                }
                inFence.toggle()
                continue
            }
            if inFence {
                code.append(line)
                continue
            }
            if trimmed.isEmpty {
                flushAll()
                continue
            }
            if let heading = heading(from: trimmed) {
                flushAll()
                blocks.append(heading)
                continue
            }
            if let item = listItem(from: trimmed) {
                flushParagraph()
                flushPipes()
                // A bullet list running straight into a numbered one is two
                // lists, not one with a confused marker.
                if !items.isEmpty, ordered != item.ordered { flushList() }
                ordered = item.ordered
                items.append(item.text)
                continue
            }
            if trimmed.hasPrefix("|") {
                flushParagraph()
                flushList()
                pipes.append(trimmed)
                continue
            }
            flushList()
            flushPipes()
            paragraph.append(line)
        }

        if inFence {
            blocks.append(.code(code.joined(separator: "\n")))
        }
        flushAll()
        return blocks
    }

    /// The cells of one `|`-delimited row, outer pipes dropped and each cell
    /// trimmed. `private`: nothing outside this scanner splits a pipe row —
    /// the table tests assert on the `.table` case `parse` hands back, which
    /// is the shape that actually reaches a view.
    private static func cells(_ line: String) -> [String] {
        var text = line.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("|") { text.removeFirst() }
        if text.hasSuffix("|") { text.removeLast() }
        return text.components(separatedBy: "|")
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// A run of pipe lines as a table, or nil when it is not one.
    ///
    /// The delimiter row is what decides it: markdown requires `|---|---|`
    /// under the header, and prose can easily contain pipe characters. Ragged
    /// body rows are *not* disqualifying — they are ordinary markdown, and
    /// `PaneAppView.renderTable` pads them.
    private static func table(from lines: [String]) -> MarkdownBlock? {
        guard lines.count >= 2 else { return nil }
        let delimiter = cells(lines[1])
        guard !delimiter.isEmpty,
              delimiter.allSatisfy({ cell in
                  !cell.isEmpty && cell.allSatisfy { $0 == "-" || $0 == ":" }
              })
        else { return nil }
        return .table(
            header: cells(lines[0]),
            rows: lines.dropFirst(2).map { cells($0) }
        )
    }

    private static func heading(from trimmed: String) -> MarkdownBlock? {
        let hashes = trimmed.prefix { $0 == "#" }
        guard (1...6).contains(hashes.count),
              trimmed.dropFirst(hashes.count).hasPrefix(" ")
        else { return nil }
        return .heading(
            level: hashes.count,
            text: String(trimmed.dropFirst(hashes.count)).trimmingCharacters(in: .whitespaces)
        )
    }

    private static func listItem(from trimmed: String) -> (text: String, ordered: Bool)? {
        for marker in ["- ", "* "] where trimmed.hasPrefix(marker) {
            return (String(trimmed.dropFirst(marker.count)), false)
        }
        let digits = trimmed.prefix { $0.isNumber }
        guard !digits.isEmpty, trimmed.dropFirst(digits.count).hasPrefix(". ") else { return nil }
        return (String(trimmed.dropFirst(digits.count + 2)), true)
    }
}

/// The App view: a native chat rendering of a Claude pane's own transcript,
/// read straight from Claude Code's JSONL log via `ClaudeTranscriptReader`
/// rather than scraped off the terminal screen. It is drawn as a *sibling* of
/// the pane's terminal, not a replacement for it — Task 3 owns which of the
/// two is on screen and toggles `isLive` to match, which is why this
/// deliberately does not conform to `PaneContentView`: it is never, itself,
/// the thing a pane shows in place of the other.
///
/// Two moving parts: a scrolling message list fed by a 0.3s poll of the
/// transcript file — grown by appending, and only ever emptied whole, when
/// Claude rewrites the transcript out from under the reader — and a
/// single-line composer whose `onSubmit` Task 3 routes into the live PTY.
final class PaneAppView: NSView {
    private let sessionID: String
    private let cwd: String
    /// Where `~/.claude/projects` is looked for — `ClaudeModel`'s own seam,
    /// carried here for the same reason it exists there: the polling tests
    /// point a real view at a transcript they own instead of the real one.
    private let home: URL

    /// Internal rather than `private` so the composer-layout tests can
    /// measure the inset the glass overlay depends on. Still a `let` — only
    /// its visibility widens.
    let scrollView: ShellScrollView
    private let messageStack = NSStackView()
    private let emptyStateLabel = ShellFont.label(
        "Nothing yet.",
        font: ShellFont.ui(13),
        color: ShellPalette.inkFaint
    )
    /// `WorkspaceGlass.sheet`, not a hand-rolled `NSVisualEffectView`: the
    /// approval card's own pane panel is built from that same helper
    /// (`PaneAsk.swift`, `NSGlassEffectView` with `.style = .regular`), and
    /// its doc comment ties `.regular` explicitly to "the same material as
    /// the approval card's pane panel" — the two have to agree when both are
    /// on screen, and calling the shared helper is what guarantees that
    /// rather than a second hand-picked material drifting from it.
    ///
    /// `nil` before macOS 26 — there is no glass to ask for and every
    /// stand-in dims rather than refracts, so, like every other caller of
    /// this helper (`SidebarAccountRowView` is the closest analogue: a
    /// small, always-visible card, not an optional backdrop that can just be
    /// left out), the fallback is a plain flat card: `ShellPalette.fieldFill`
    /// over a `hairlineStrong` stroke. Deliberately not `.hudWindow` — that
    /// is dark HUD chrome for a floating *window* panel
    /// (`CommandPaletteController`'s own pre-26 fallback), and reads wrong
    /// pasted onto in-pane content.
    private let composerGlass: NSView = {
        let container = NSView()
        container.wantsLayer = true
        container.translatesAutoresizingMaskIntoConstraints = false
        // Set on both branches, not just the flat-card one: the focus stroke
        // (`setComposerFocused`) rides on *this* layer's border, and a border
        // with no radius would square off the glass's rounded corners. Also
        // what `updateComposerGlow`'s mask cuts its own inner (unbled) edge
        // to, via `composerGlassCornerRadius` — the same number, not a
        // second one that could drift from it.
        container.layer?.cornerRadius = PaneAppView.composerGlassCornerRadius
        container.layer?.cornerCurve = .continuous
        if let glass = WorkspaceGlass.sheet(cornerRadius: PaneAppView.composerGlassCornerRadius) {
            glass.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(glass)
            NSLayoutConstraint.activate([
                glass.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                glass.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                glass.topAnchor.constraint(equalTo: container.topAnchor),
                glass.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
        } else {
            container.layer?.backgroundColor = ShellPalette.fieldFill.cgColor
            container.layer?.borderWidth = 1
            container.layer?.borderColor = ShellPalette.hairlineStrong.cgColor
        }
        return container
    }()
    /// The glass container's stroke while the composer is *not* focused —
    /// captured in `init` from whichever branch above built it (nothing at
    /// all over real glass, the flat card's hairline before macOS 26) so
    /// `setComposerFocused` can put it back exactly rather than guessing.
    private var composerRestingBorder: (width: CGFloat, color: CGColor?) = (0, nil)
    /// The focus glow's non-rotating *container* (see `updateComposerGlow`):
    /// a plain `CALayer` carrying a `CAShapeLayer` mask and, inside it, the
    /// spinning gradient — created only while wanted and removed from its
    /// superlayer entirely otherwise, never left paused. `nil` whenever it
    /// is not on screen, which is most of the time.
    private var composerGlow: CALayer?
    /// Observers for the window's key-status notifications —
    /// `updateComposerGlow`'s key-window gate needs to be re-evaluated on
    /// every change, not just read once. Rebuilt in `viewDidMoveToWindow`
    /// the same way `PaneWorkspaceView`'s own `occlusionObserver` is: torn
    /// down and, if there is a new window, rebuilt against it.
    private var keyWindowObservers: [NSObjectProtocol] = []
    /// Internal rather than `private` so the composer tests can read and set
    /// the draft directly.
    let composerField: HomeComposerField = {
        let field = HomeComposerField()
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = ShellFont.ui(14)
        field.textColor = ShellPalette.ink
        field.placeholderAttributedString = NSAttributedString(
            string: "Ask anything…",
            attributes: [.foregroundColor: ShellPalette.inkFaint, .font: ShellFont.ui(14)]
        )
        // ponytail: single-line; the PTY takes one line per send anyway
        field.lineBreakMode = .byTruncatingTail
        field.usesSingleLineMode = true
        field.translatesAutoresizingMaskIntoConstraints = false
        return field
    }()

    /// Nil until the transcript file first exists. Created once
    /// `ClaudeModel.resolvedTranscriptURL` finds it — on the background queue,
    /// never here — and never torn down afterwards: the reader's own byte
    /// offset is what keeps every later poll cheap.
    ///
    /// Internal rather than `private` so the polling tests can see both that
    /// it eventually appears *and* that it is not there the instant a tick is
    /// fired, which is the whole observable content of that background hop.
    private(set) var reader: ClaudeTranscriptReader?
    /// Internal rather than `private` so the timer test can see a tick get
    /// scheduled and invalidated without sitting through real 0.3s ticks.
    private(set) var pollTimer: Timer?
    /// One read in flight at a time — a slow disk must not pile up polls
    /// behind it. Internal rather than `private` so the polling tests can see
    /// that going live fires its first tick in that same turn rather than
    /// 0.3s later.
    private(set) var pollInFlight = false

    /// The conversation as turns, mirroring `messageStack`'s arranged
    /// subviews one-for-one. Held because a turn *grows*: a poll landing
    /// another assistant row extends the last turn, and its row view has to
    /// be rebuilt from the merged blocks rather than appended beside.
    private var turns: [TranscriptTurn] = []

    /// Called on the main queue at the end of every poll cycle, whatever it
    /// found and whatever it did with it. Nil in the app: this is the seam the
    /// polling tests wait on, so they can drive the real timer path as an
    /// event instead of sleeping on the run loop.
    var onPollLanded: (() -> Void)?

    /// The composer's text, on Enter. Task 3 routes it into the live PTY.
    var onSubmit: ((String) -> Void)?

    /// Whether the transcript is being polled. `false` at construction, so a
    /// pane created in Terminal mode never opens a reader or a timer for a
    /// view nobody is looking at.
    var isLive = false {
        didSet {
            guard isLive != oldValue else { return }
            isLive ? startPolling() : stopPolling()
            // A pane can go non-live (Task 3 flips this on the Terminal ⇄ App
            // toggle) while the composer still holds focus — the glow must
            // not keep spinning on a view nobody is looking at.
            updateComposerGlow()
        }
    }

    /// Whether `composerField` currently holds first responder — the glow's
    /// other gate, alongside `isLive` and Reduce Motion. Set from
    /// `setComposerFocused`, the one place focus changes land.
    private var isComposerFocused = false

    /// Test seam: `ShellMotion.reduced` reads a live, global accessibility
    /// setting nothing in a unit test can flip. This codebase's existing
    /// precedent for that (`throw XCTSkip("under Reduce Motion …")` when the
    /// live setting is already off — `DeskCameraFlightTests.swift:59-60`,
    /// `DeskCanvasInputTests.swift:62`) only ever *skips*, which would leave
    /// the composer glow's Reduce-Motion path untested on any runner that
    /// happens to have it off. `nil` — every real pane — defers to the real
    /// setting.
    var reducedMotionForTesting: Bool?
    private var reducedMotion: Bool { reducedMotionForTesting ?? ShellMotion.reduced }

    /// Test seam for `updateComposerGlow`'s key-window gate, for the same
    /// reason `reducedMotionForTesting` exists: `window?.isKeyWindow` is a
    /// live, external condition a unit test cannot produce either. Worse
    /// than `ShellMotion.reduced` here, in fact — confirmed directly rather
    /// than assumed, `NSApplication.shared.isActive` reads `false` under
    /// `xcodebuild test`, so no window this test host creates ever becomes
    /// genuinely key no matter how it is shown (`window.makeKeyAndOrderFront(nil)`
    /// included — a real window is still enough for everything else this
    /// test file's own `show(_:)` needs, since first-responder changes and
    /// `draw(_:)` do not require true key status), which would leave the
    /// key-window gate itself entirely untested rather than merely
    /// untested under one motion setting. `didSet` re-runs
    /// `updateComposerGlow` the same way a real `NSWindow`
    /// did-become/resign-key notification does. `nil` — every real pane —
    /// defers to the real window.
    var isKeyWindowForTesting: Bool? {
        didSet { updateComposerGlow() }
    }
    private var isComposerWindowKey: Bool { isKeyWindowForTesting ?? (window?.isKeyWindow ?? false) }

    /// Where keyboard focus should land when this view is the pane's active
    /// content — the composer, so typing starts a message rather than
    /// requiring a click first.
    var primaryResponderView: NSView { composerField }

    init(sessionID: String, cwd: String, home: URL = ClaudeModel.homeDirectory) {
        self.sessionID = sessionID
        self.cwd = cwd
        self.home = home
        // The scroll view's real document view — pinned to the clip's full
        // width by `ShellScrollView` itself, exactly like `HomeView`'s own
        // `content` — with `messageStack` centred inside it as the 880pt
        // column. Local rather than stored: nothing outside `init` touches
        // it, since rows are added to `messageStack` directly.
        let transcriptContent = NSView()
        transcriptContent.translatesAutoresizingMaskIntoConstraints = false
        transcriptContent.addSubview(messageStack)
        scrollView = ShellScrollView(documentView: transcriptContent)
        super.init(frame: .zero)
        // `translatesAutoresizingMaskIntoConstraints` deliberately left at
        // its default `true` — NOT set `false` the way most Auto-Layout-
        // internal views in this file are. `PaneWorkspaceView.makeAppViewIfNeeded`
        // already sets this back to `true` itself, one line after
        // constructing this view — so production was never actually
        // exposed to what `false` here would have meant. But
        // `PaneAppViewTests` constructs this view directly, without going
        // through that line, and `false` there is genuinely unsafe:
        // `PaneContainerView.applyLayout` positions this view by assigning
        // `.frame` directly (`appView?.frame = surface.frame`), never
        // through an `NSLayoutConstraint` from its superview, so with
        // nothing external pinning this view's own size either,
        // `messageStack`/`composerGlass`'s new `.defaultHigh` 880pt
        // preference (below) is free to satisfy itself by growing this
        // view's own frame outward — confirmed with a throwaway offscreen
        // probe: a `PaneAppView` framed 500×600, `false` here, and added as
        // an ordinary frame-positioned subview of a plain host in a real
        // window (the shape `PaneContainerView` actually embeds it in) grew
        // itself to 960×117 the moment `appendMessages`' own
        // `layoutSubtreeIfNeeded()` ran. Leaving TAMIC at its default here
        // makes this view's own construction match the shape it actually
        // runs in, rather than depending on that one call site alone to
        // correct it — the same probe, otherwise identical, stayed at
        // 500×600 with the column correctly capped to 420pt.
        wantsLayer = true
        // Opaque, and the same background every real pane-content view uses
        // (`PaneContainerView.paneBackgroundColor` — see `BrowserPaneView`,
        // `EditorPaneView`, et al.): this view is drawn *over* the
        // still-running terminal, and a translucent one would show both at
        // once, while `ShellPalette.content` (the workspace-chrome panels'
        // own background) would show a visible seam against the pane around
        // it.
        layer?.backgroundColor = PaneContainerView.paneBackgroundColor.cgColor

        messageStack.orientation = .vertical
        messageStack.alignment = .leading
        messageStack.spacing = 10
        messageStack.translatesAutoresizingMaskIntoConstraints = false

        composerField.target = self
        composerField.action = #selector(submitComposer)
        composerRestingBorder = (composerGlass.layer?.borderWidth ?? 0, composerGlass.layer?.borderColor)
        composerField.onFocusChange = { [weak self] focused in
            self?.setComposerFocused(focused)
        }
        // Left `false` (the layer default) deliberately, not just left
        // alone: the focus glow (`updateComposerGlow`) is inset *outside*
        // this layer's own bounds on purpose, and `true` here would clip it
        // back down to a hard-edged ring at the glass's corner radius —
        // exactly the "not a soft halo" failure mode.
        composerGlass.layer?.masksToBounds = false

        let attachButton = Self.composerButton(symbol: "paperclip", accessibility: "Attach a file")
        attachButton.target = self
        attachButton.action = #selector(chooseAttachment)

        let sendButton = Self.composerButton(symbol: "arrow.up", accessibility: "Send")
        sendButton.target = self
        sendButton.action = #selector(submitComposer)

        let controls = NSStackView(views: [attachButton, NSView(), sendButton])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 8
        controls.translatesAutoresizingMaskIntoConstraints = false

        composerGlass.addSubview(composerField)
        composerGlass.addSubview(controls)
        for view in [scrollView, emptyStateLabel, composerGlass] as [NSView] {
            addSubview(view)
        }

        // What the reader can actually see: the scroll view runs the full
        // height *behind* the glass, so centring "Nothing yet." in it would
        // sit it a glass-height below the optical centre.
        let readableArea = NSLayoutGuide()
        addLayoutGuide(readableArea)

        NSLayoutConstraint.activate([
            readableArea.topAnchor.constraint(equalTo: topAnchor),
            readableArea.leadingAnchor.constraint(equalTo: leadingAnchor),
            readableArea.trailingAnchor.constraint(equalTo: trailingAnchor),
            readableArea.bottomAnchor.constraint(equalTo: composerGlass.topAnchor),

            // Full height: the transcript scrolls *behind* the glass, and the
            // content inset below is what keeps the last message reachable.
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            // `HomeView.swift:275-292`'s own centred column, reused exactly:
            // a `.defaultHigh` fixed width (below) so the required
            // `leadingAnchor` floor here is what gives on a narrow window
            // instead of the column clipping.
            messageStack.topAnchor.constraint(equalTo: transcriptContent.topAnchor),
            messageStack.bottomAnchor.constraint(equalTo: transcriptContent.bottomAnchor),
            messageStack.centerXAnchor.constraint(equalTo: transcriptContent.centerXAnchor),
            messageStack.leadingAnchor.constraint(
                greaterThanOrEqualTo: transcriptContent.leadingAnchor, constant: 40
            ),

            emptyStateLabel.centerXAnchor.constraint(equalTo: readableArea.centerXAnchor),
            emptyStateLabel.centerYAnchor.constraint(equalTo: readableArea.centerYAnchor),

            // The same column, centred the same way, so the composer's edges
            // line up with the transcript's rather than spanning the pane.
            composerGlass.centerXAnchor.constraint(equalTo: centerXAnchor),
            composerGlass.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 40),
            composerGlass.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.composerGlassMargin),

            // Vertical rhythm scaled up from `HomeView`'s own composer card
            // (`buildComposer()`: prompt inset 20 from the top, controls 18
            // below it) rather than copied verbatim — that card has a third
            // meta row this composer doesn't, so its proportions, not its
            // numbers, are what carry over. Measured on a real layout pass:
            // 22 + a single-line field's own ~17pt intrinsic height + 18 +
            // the 26pt controls row + 24 lands at 107pt, inside the target
            // ~100-115pt band with room either side of an intrinsic-height
            // guess.
            composerField.topAnchor.constraint(equalTo: composerGlass.topAnchor, constant: 22),
            composerField.leadingAnchor.constraint(equalTo: composerGlass.leadingAnchor, constant: 14),
            composerField.trailingAnchor.constraint(equalTo: composerGlass.trailingAnchor, constant: -14),

            controls.topAnchor.constraint(equalTo: composerField.bottomAnchor, constant: 18),
            controls.leadingAnchor.constraint(equalTo: composerGlass.leadingAnchor, constant: 10),
            controls.trailingAnchor.constraint(equalTo: composerGlass.trailingAnchor, constant: -10),
            controls.bottomAnchor.constraint(equalTo: composerGlass.bottomAnchor, constant: -24),
            controls.heightAnchor.constraint(equalToConstant: 26),
        ])
        // Above every *content* priority but below required, which is the
        // only band that means what this cap means: "as wide as 880pt unless
        // a required constraint says otherwise".
        //
        // `.defaultHigh` — the obvious-looking choice, and what this was —
        // is a bug, because 750 is also AppKit's default horizontal
        // *compression resistance* for every label. A wrapping `NSTextField`
        // publishes an `NSContentSizeLayoutConstraint` for its **single-line**
        // width (a paragraph of Claude's prose measures ~1500pt), and the
        // chain from that label up to `messageStack` — label width == body
        // width == row width == stack width — is required at every link. So
        // at 750 the cap and the label's own width sat at *equal* priority
        // with no way to satisfy both, and the solver was free to drop
        // either: it dropped the cap, and the transcript ran full width.
        // (Confirmed by dumping `constraintsAffectingLayout(for: .horizontal)`
        // on the column: the label's `CompressionResistance:750` content-size
        // constraint was in the resolved layout and the 880pt cap was not,
        // leaving a 1537.5pt column on a 2000pt pane — the label's 1509.5pt
        // intrinsic width plus the row's 14pt insets.)
        //
        // Both columns, one rule, deliberately: the composer only *looks*
        // immune. `composerField` reports `noIntrinsicMetric` horizontally,
        // so it publishes no content-size constraint and nothing pushes its
        // glass outward — the identical 750-against-750 tie is sitting under
        // it unresolved, waiting for a field that does report a width.
        // Raising only the transcript would leave that trap armed.
        for column in [messageStack, composerGlass] {
            let width = column.widthAnchor.constraint(equalToConstant: Self.transcriptColumnWidth)
            width.priority = Self.transcriptColumnWidthPriority
            width.isActive = true
        }

        // AppKit would otherwise fold its own automatic insets into these and
        // the inset would not match the glass.
        scrollView.automaticallyAdjustsContentInsets = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    deinit {
        pollTimer?.invalidate()
        for observer in keyWindowObservers { NotificationCenter.default.removeObserver(observer) }
    }

    /// The composer glow's key-window gate (`updateComposerGlow`) needs to
    /// be re-evaluated on every key-status change, not just read once at
    /// focus time — a window resigning key runs neither `setComposerFocused`
    /// nor any other callback already wired here (`HomeComposerField` only
    /// calls `onFocusChange` from `textDidEndEditing`, which a window
    /// merely losing key status does not trigger). Same shape as
    /// `PaneWorkspaceView`'s own `occlusionObserver`: torn down here first,
    /// then rebuilt against whatever window this view now has, if any.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        for observer in keyWindowObservers { NotificationCenter.default.removeObserver(observer) }
        keyWindowObservers = []
        if let window {
            let center = NotificationCenter.default
            keyWindowObservers = [
                center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) {
                    [weak self] _ in self?.updateComposerGlow()
                },
                center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) {
                    [weak self] _ in self?.updateComposerGlow()
                },
            ]
        }
        // Rewiring the observers above only catches the *next* key-status
        // change. Moving to a nil window, or to a second window that is not
        // itself key, has to stop the glow right now — `isComposerWindowKey`
        // reads whatever window this view has this instant, and a nil
        // window in particular posts no notification at all to ever catch.
        updateComposerGlow()
    }

    /// Reconciles the transcript's bottom clearance against the glass
    /// composer's *real*, laid-out height every pass, rather than an authored
    /// constant that could silently drift from it (a font-size change, a
    /// controls-row tweak, an OS metrics update). `super.layout()` first: it
    /// is what resolves `composerGlass`'s own Auto Layout constraints, so its
    /// `frame` is only trustworthy after that call returns.
    override func layout() {
        super.layout()
        let clearance = composerGlass.frame.height + Self.composerGlassMargin
        // `composerGlow`'s geometry (the container's frame, its mask's path,
        // and the spinning gradient's own frame inside it) is all derived
        // from the glass's bounds, so it has to be resynced on every pass
        // too — the same reason `clearance` above is read from
        // `frame.height` rather than kept as an authored constant.
        // Unconditional, unlike the block below: a resize can move the
        // glass without changing its height, and the guard beneath would
        // then skip a glow that needs to move with it.
        if let composerGlow { layOutComposerGlow(composerGlow) }
        guard scrollView.contentInsets.bottom != clearance else { return }
        scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: clearance, right: 0)
        // Negative, verified rather than assumed: `contentInsets.bottom`
        // alone already shrinks the vertical scroller's frame by that same
        // amount (confirmed with a throwaway offscreen probe — a 300pt-tall
        // scroll view's scroller measured 213pt with `scrollerInsets` left at
        // zero). This negative inset exactly cancels that automatic shrink,
        // restoring the scroller to the view's full height so its track still
        // represents the whole scrollable range — including the padded tail
        // under the glass — rather than being pushed up and truncated.
        scrollView.scrollerInsets = NSEdgeInsets(top: 0, left: 0, bottom: -clearance, right: 0)
    }

    // MARK: - Composer

    /// `HomeView.swift:275-292`'s own 880pt column width, reused for both
    /// the transcript (`messageStack`) and the composer (`composerGlass`) so
    /// the two line up.
    private static let transcriptColumnWidth: CGFloat = 880

    /// One below `.required`, so the cap yields to required constraints —
    /// the 40pt leading floor on a narrow pane — and to nothing else. In
    /// particular it must outrank content: see the width constraints in
    /// `init` for why `.defaultHigh` was not high enough to be a cap at all.
    private static let transcriptColumnWidthPriority = NSLayoutConstraint.Priority(999)

    /// The glass's own margin off the view's *bottom* edge — the single
    /// authored number the clearance in `layout()` is built from, rather
    /// than a second constant that could disagree with it. (Leading and
    /// trailing no longer share this: the glass is centred in its own
    /// 880pt column now, with its own 40pt escape-hatch floor, rather than a
    /// fixed margin off the pane's edges.)
    private static let composerGlassMargin: CGFloat = 20

    /// The only thing on screen that says where keystrokes are going. The
    /// field's own bordered container is gone — it folded into the glass —
    /// and `focusRingType` is `.none`, so without this a focused and an
    /// unfocused composer are pixel-identical.
    ///
    /// The stroke rides on the glass *container's* layer, which is the
    /// composer's outer edge now that the inner one is gone: a layer's border
    /// draws over its own sublayers, so it stays visible above the glass
    /// panel filling it.
    private func setComposerFocused(_ focused: Bool) {
        composerGlass.layer?.borderWidth = focused ? 1 : composerRestingBorder.width
        composerGlass.layer?.borderColor = focused
            ? ShellPalette.accent.withAlphaComponent(0.5).cgColor
            : composerRestingBorder.color
        // The stroke above is the Reduce-Motion / no-window fallback and
        // stays regardless — `updateComposerGlow` decides for itself whether
        // the glow on top of it is also wanted.
        isComposerFocused = focused
        updateComposerGlow()
    }

    /// The glass's own corner radius — also what `updateComposerGlow`'s
    /// mask cuts its inner (unbled) edge to, so the two agree.
    private static let composerGlassCornerRadius: CGFloat = 14

    /// How far the glow bleeds past the glass's own edge on every side, and
    /// how strongly it is blurred — chosen together, not independently.
    ///
    /// Bleed is kept `<=` `composerGlassMargin` (10 against 20) rather than
    /// past it: `PaneWorkspaceView.roundChildren` masks every pane, this
    /// view included, to its own rounded rect (`appView.layer?.masksToBounds
    /// = true`), so bleed past the glass's own margin off the pane's bottom
    /// edge is not a fade at all there — it is a straight cut across the
    /// halo at the pane's edge. Verified by inspection of that call, not
    /// assumed safe by construction. It is a hard ceiling: the softness
    /// below has to fit inside it, not ask for more room.
    ///
    /// The blur radius is roughly half the bleed, deliberately, and both
    /// `layOutComposerGlow`'s mask and `updateComposerGlow`'s gradient share
    /// this one number rather than each picking its own: a `CIGaussianBlur`'s
    /// visible spread runs a few multiples of its radius, and a mask blurred
    /// wider than the band it lives in has nothing further to spread into —
    /// its own layer bounds (`outerRect.size`, the same size as the band)
    /// already cut it off there, which is exactly the hard edge this radius
    /// exists to avoid reintroducing. Half the band's width is comfortably
    /// inside that limit while still tapering across a real fraction of it.
    /// (28 was tuned for the 36pt bleed two revisions back; halving the bleed
    /// without also lowering this left a 28pt blur mostly clipped by the
    /// band — a smear, not a glow, which is what sent both numbers back for
    /// reconsideration together. They have moved together ever since: 36/28,
    /// then 18/9, and now 10/5, the glow on screen still reading as too
    /// thick a band at 18.)
    private static let composerGlowBleed: CGFloat = 10
    private static let composerGlowBlurRadius: CGFloat = 5

    /// The design's signature glow, reused for the composer: "make it shiny
    /// with a nice circling effect with blue and purple out of focus." Same
    /// idiom as `PaneWorkspaceView.updateWorkingRing` at its core — a
    /// `CAGradientLayer` of type `.conic` spun by an `om-spin`
    /// `CABasicAnimation`, created only while wanted and removed from its
    /// superlayer (not merely hidden, and never left paused) otherwise, so
    /// an unfocused composer costs nothing.
    ///
    /// Structured as two layers rather than one, which the working ring
    /// does not need: a non-rotating `container` sized to the glass's own
    /// bled (non-square) rect, masked by a blurred `CAShapeLayer` even-odd
    /// path — the bled rounded rect minus the glass's own rounded rect —
    /// and, inside it, the spinning gradient itself, square and sized to
    /// the container's diagonal so no rotation angle can uncover a corner.
    ///
    /// Both halves answer the same mistake a single rotated, bled-rect-
    /// shaped `CAGradientLayer` makes: a layer's *shape* rotates with its
    /// `transform`, so a non-square layer rotated in place sweeps its own
    /// corners through the frame as it turns — at ~90° a 952×179 bled rect
    /// becomes a 179×952 column reaching hundreds of points into the
    /// transcript, while the band at the glass's left and right ends falls
    /// outside the layer and goes transparent. The working ring's own layer
    /// rotates too, but gets away with it only because its comment says
    /// opaque pane chrome covers everything but its own 1pt border; this
    /// glass has no such occluder on either branch (`WorkspaceGlass.sheet`
    /// returns `nil` below macOS 26, and the flat-card fallback's own fill
    /// is this layer's `backgroundColor`, which paints *under* every
    /// sublayer here — nothing hides an unmasked layer's full bounds
    /// there), so confinement has to come from the mask rather than from
    /// anything sitting over it. The container never rotates and the mask
    /// confines its paint regardless of angle; only the square gradient
    /// inside spins, and being square, its conic hue sweep reads as an
    /// actual circle rather than the ellipse a non-square layer would bake
    /// into it.
    ///
    /// The mask's own path is blurred (`layOutComposerGlow`), not left as a
    /// solid even-odd fill: a plain fill clips at a hard boundary — the
    /// design asked for the halo to read "out of focus", and a ring with a
    /// crisp edge on both sides is the opposite of that. Blurring the
    /// mask's own rendered alpha softens both boundaries of the band at
    /// once, and — being a blur of the exact rounded-rect band shape rather
    /// than a generic radial falloff — follows that shape's silhouette
    /// exactly rather than an ellipse shaped by the container's own
    /// (markedly non-square) aspect ratio.
    ///
    /// Gated on focus, `isLive`, Reduce Motion and the window's own key
    /// status together: an always-spinning blurred gradient on every open
    /// App-mode pane is exactly the cost `updateWorkingRing`'s own comment
    /// warns a permanent animation would be, and a window resigning key
    /// runs none of this view's own focus callbacks (`HomeComposerField`
    /// only calls `onFocusChange` from `textDidEndEditing`), so without the
    /// key check the glow would keep spinning on a background window.
    private func updateComposerGlow() {
        let wanted = isComposerFocused && isLive && !reducedMotion && isComposerWindowKey
        guard wanted else {
            composerGlow?.removeFromSuperlayer()
            composerGlow = nil
            return
        }
        guard composerGlow == nil else { return }

        let container = CALayer()
        let gradient = CAGradientLayer()
        gradient.type = .conic
        gradient.startPoint = CGPoint(x: 0.5, y: 0.5)
        gradient.endPoint = CGPoint(x: 0.5, y: 0)
        gradient.colors = [
            ShellPalette.accent.withAlphaComponent(0).cgColor,
            ShellPalette.accent.withAlphaComponent(0.55).cgColor,
            ShellPalette.accentPurple.withAlphaComponent(0.9).cgColor,
            ShellPalette.accent.withAlphaComponent(0.55).cgColor,
            ShellPalette.accent.withAlphaComponent(0).cgColor,
        ]
        gradient.locations = [0, 0.25, 0.5, 0.75, 1]
        // A `CIFilter` on a layer costs an offscreen pass — the one other
        // filter/shadow in this file (`PaneContainerView.updateChrome`'s own
        // comment) avoids exactly that cost by never adding a second one.
        // This glow spends it twice over, deliberately rather than by
        // accident: once here (softens the conic gradient's own colour
        // steps) and again on the mask built in `layOutComposerGlow`
        // (softens the band's edges) — both small (`composerGlowBlurRadius`,
        // 9), both alive only while a composer is focused on a live, key,
        // motion-enabled pane, and both animated only via
        // `transform.rotation.z` on `gradient`, not via anything the
        // filters themselves read, so Core Animation rasterises each once
        // and spins the cached result rather than re-running either filter
        // every frame.
        if let blur = CIFilter(name: "CIGaussianBlur") {
            blur.setValue(Self.composerGlowBlurRadius, forKey: kCIInputRadiusKey)
            gradient.filters = [blur]
        }
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = 2 * Double.pi
        spin.duration = 3
        spin.repeatCount = .infinity
        spin.isRemovedOnCompletion = false
        gradient.add(spin, forKey: "om-spin")

        container.addSublayer(gradient)
        layOutComposerGlow(container)
        // Index doesn't matter for confinement any more — the mask does
        // that — but `at: 0` keeps it behind the glass panel for the same
        // reason it always was: never clipped, since
        // `composerGlass.layer?.masksToBounds` is left `false` in `init`
        // for exactly this.
        composerGlass.layer?.insertSublayer(container, at: 0)
        composerGlow = container
        // Created before this view's first layout pass — while
        // `composerGlass.bounds` still reads `.zero` — would otherwise sit
        // at that size until something else happens to schedule a layout;
        // this makes it certain rather than incidental.
        needsLayout = true
    }

    /// (Re)computes `composerGlow`'s geometry from `composerGlass`'s
    /// current, real bounds: the container's own frame, its mask's path,
    /// and the spinning gradient's frame inside it. Called both from
    /// `updateComposerGlow` (to lay a freshly built container out for the
    /// first time) and from `layout()` (to keep it in step with the glass
    /// on every later pass) — one seam rather than the same maths kept in
    /// sync by hand in two places.
    private func layOutComposerGlow(_ container: CALayer) {
        // These are plain data layers this method drives by hand every
        // layout pass, not view-backed layers reacting to a user gesture —
        // without this, Core Animation's default 0.25s implicit action
        // would fire on every frame/mask assignment below, and the halo
        // would visibly lag the glass while a pane resizes.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let bleed = Self.composerGlowBleed
        let glassBounds = composerGlass.bounds
        let outerRect = glassBounds.insetBy(dx: -bleed, dy: -bleed)
        container.frame = outerRect

        // Rebuilt only when the size actually changed, not on every pass —
        // a live pane resize calls this every frame, and neither the path
        // nor the blur filter depend on anything but `outerRect.size`
        // (`glassBounds.size` moves in lockstep with it, offset by the
        // constant `bleed`, so comparing this one size covers both).
        let existingMask = container.mask as? CAShapeLayer
        if existingMask == nil || existingMask?.frame.size != outerRect.size {
            let mask = CAShapeLayer()
            let path = CGMutablePath()
            let outerCornerRadius = Self.composerGlassCornerRadius + bleed
            path.addRoundedRect(
                in: CGRect(origin: .zero, size: outerRect.size),
                cornerWidth: outerCornerRadius, cornerHeight: outerCornerRadius
            )
            path.addRoundedRect(
                in: CGRect(x: bleed, y: bleed, width: glassBounds.width, height: glassBounds.height),
                cornerWidth: Self.composerGlassCornerRadius, cornerHeight: Self.composerGlassCornerRadius
            )
            // Even-odd, not the default nonzero rule: two closed subpaths
            // added independently (an outer rounded rect, an inner one)
            // both wind the same direction, and nonzero would fill *both*
            // solid rather than punching the inner one out of the outer —
            // even-odd only cares about crossing parity, not winding
            // direction, so it does not matter that neither path was built
            // to wind the other way.
            mask.path = path
            mask.fillRule = .evenOdd
            mask.frame = CGRect(origin: .zero, size: outerRect.size)
            // Blurred — see `updateComposerGlow`'s own doc comment for why:
            // an even-odd fill alone is a hard edge on both the outer
            // silhouette and the inner hole it punches, and blurring the
            // mask's own rendered alpha softens both in the one pass,
            // following the band's actual rounded-rect shape rather than
            // an ellipse a `CAGradientLayer` mask would impose instead.
            if let blur = CIFilter(name: "CIGaussianBlur") {
                blur.setValue(Self.composerGlowBlurRadius, forKey: kCIInputRadiusKey)
                mask.filters = [blur]
            }
            container.mask = mask
        }

        guard let gradient = container.sublayers?.first as? CAGradientLayer else { return }
        // Square, and sized to the container's own diagonal — the longest
        // distance from its centre to any point in it — so no rotation
        // angle can ever turn a corner of `gradient` inside the container's
        // own bounds into daylight.
        let side = hypot(outerRect.width, outerRect.height)
        gradient.frame = CGRect(
            x: (outerRect.width - side) / 2, y: (outerRect.height - side) / 2, width: side, height: side
        )
    }

    private static func composerButton(symbol: String, accessibility: String) -> NSButton {
        let button = NSButton()
        button.bezelStyle = .regularSquare
        button.isBordered = false
        button.image = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: accessibility
        )
        button.contentTintColor = ShellPalette.inkTertiary
        button.imageScaling = .scaleProportionallyDown
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 26).isActive = true
        return button
    }

    @objc private func chooseAttachment() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        insertAttachment(path: url.path)
    }

    /// Puts a file's path into the draft. A path is what the transport can
    /// carry — the composer's text goes into a live PTY — and what Claude
    /// Code already knows how to open.
    func insertAttachment(path: String) {
        let draft = composerField.stringValue.trimmingCharacters(in: .whitespaces)
        composerField.stringValue = draft.isEmpty ? path : "\(draft) \(path)"
        window?.makeFirstResponder(composerField)
    }

    @objc private func submitComposer() {
        let text = composerField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        onSubmit?(text)
        composerField.stringValue = ""
    }

    // MARK: - Messages

    /// Folds `messages` into the conversation and redraws whatever that
    /// changed. The one path both the poll timer and the tests use to put a
    /// row on screen.
    ///
    /// Rows are per *turn*, not per message, so this is not a pure append:
    /// Claude Code writes each `tool_use` as its own assistant row and the
    /// reader drops `tool_result` rows entirely, so an entire reply is one
    /// turn that *grows* across polls. A message extending the turn already
    /// on screen destroys that turn's row and rebuilds it from the merged
    /// blocks; only a role flip adds a row beside. At most one existing row
    /// is ever touched — the last one — because a batch either extends the
    /// last turn or opens a new one.
    ///
    /// A transcript Claude rewrote is the one case this does not answer:
    /// `poll()` re-reads it from the start and reports `didReset`, which
    /// `clearMessages()` handles *before* this runs.
    func appendMessages(_ messages: [TranscriptMessage]) {
        guard !messages.isEmpty else { return }
        // Measured before a single row is added: a user already scrolled up
        // to read earlier messages must not be yanked back down by a reply
        // arriving behind their back.
        let wasAtBottom = isScrolledToBottom()

        let firstChanged = TranscriptTurn.append(messages, to: &turns)
        // Everything from the first changed turn onwards is redrawn. In
        // practice that is one row: a poll either extends the last turn or
        // opens one.
        //
        // Work groups the user expanded are the one piece of view state that
        // has to survive that rebuild: a reply lands a row every ~0.3s for as
        // long as it runs, so a group opened mid-reply would otherwise snap
        // shut on the very next poll, and go on doing it forever.
        var expansion: [Bool] = []
        while messageStack.arrangedSubviews.count > firstChanged,
              let row = messageStack.arrangedSubviews.last {
            expansion = (row as? PaneAppMessageRowView)?.workGroups.map(\.isExpanded) ?? []
            messageStack.removeArrangedSubview(row)
            row.removeFromSuperview()
        }
        // ponytail: whole-row rebuild per poll; append-in-place if long turns
        // get slow. Two costs are accepted deliberately here, not overlooked:
        // a text selection inside the in-progress turn is destroyed with its
        // views on every poll, and rebuilding the whole turn each time makes
        // the work quadratic in its length. The fix for both is the same —
        // `PaneAppMessageRowView.append(blocks:)`, adding only the new blocks
        // to the row already standing — and it is its own task, not a
        // drive-by here.
        for (offset, turn) in turns[firstChanged...].enumerated() {
            let row = PaneAppMessageRowView(turn: turn)
            // By index: the rebuilt row's groups are the same runs in the
            // same order, plus any the new blocks added on the end.
            if offset == 0 {
                for (group, wasExpanded) in zip(row.workGroups, expansion) where wasExpanded {
                    group.toggle()
                }
            }
            messageStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: messageStack.widthAnchor).isActive = true
        }

        emptyStateLabel.isHidden = true
        // Forced unconditionally, not just when scrolling: `messageStack`'s
        // height must be current the *next* time this runs too, and a user
        // scrolled up (who skips the `scrollToBottom()` below) would
        // otherwise leave it stale until AppKit's own next display pass.
        layoutSubtreeIfNeeded()
        if wasAtBottom {
            scrollToBottom()
        }
    }

    /// Empties the conversation, back to the state a fresh view opens in.
    ///
    /// Only ever for a transcript Claude rewrote out from under the reader
    /// (compaction, `/clear`): `poll()` answers that by starting over at byte
    /// zero, so the rows it hands back include ones already on screen, and
    /// appending them to what is there would draw the conversation twice.
    private func clearMessages() {
        turns = []
        for row in messageStack.arrangedSubviews {
            // Both halves: `removeArrangedSubview` only stops the stack
            // *arranging* the view, it leaves it a subview drawing where it
            // last sat.
            messageStack.removeArrangedSubview(row)
            row.removeFromSuperview()
        }
        // Whatever follows in the same pass re-hides this; a rewrite that left
        // nothing behind correctly reads as an empty conversation again.
        emptyStateLabel.isHidden = false
    }

    /// The scroll offset at which the newest message sits clear of the glass
    /// composer — the end of the scrollable range, which is *not* the
    /// document's bottom edge.
    ///
    /// `layout()` pads the range with `contentInsets.bottom` precisely so the
    /// last row can travel past the glass. Scrolling to
    /// `documentHeight - clipHeight` stops one clearance short of that and
    /// parks the newest reply under the composer, which is exactly what the
    /// inset exists to prevent.
    private var bottomScrollOffset: CGFloat {
        let clip = scrollView.contentView
        let range = messageStack.frame.height + scrollView.contentInsets.bottom
        return max(0, range - clip.bounds.height)
    }

    /// Measured against the same target `scrollToBottom` moves to. Anything
    /// looser reads a user scrolled up by less than the glass's clearance as
    /// "at bottom" and yanks them down on the next poll.
    private func isScrolledToBottom() -> Bool {
        scrollView.contentView.bounds.origin.y >= bottomScrollOffset - 2
    }

    private func scrollToBottom() {
        let clip = scrollView.contentView
        clip.scroll(to: NSPoint(x: 0, y: bottomScrollOffset))
        scrollView.reflectScrolledClipView(clip)
    }

    // MARK: - Polling

    private func startPolling() {
        guard pollTimer == nil else { return }
        // Same shape as `approvalPollTimer` in `PaneWorkspaceView.swift`.
        let timer = Timer(timeInterval: 0.3, repeats: true) { [weak self] _ in
            self?.tick()
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
        // A repeating `Timer` first fires one interval in, so without this
        // every switch into App view shows "Nothing yet." for a third of a
        // second before the whole conversation pops in at once.
        tick()
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func tick() {
        guard !pollInFlight else { return }
        pollInFlight = true
        let (sessionID, cwd, home) = (self.sessionID, self.cwd, self.home)
        let existing = reader
        DispatchQueue.global(qos: .utility).async { [weak self] in
            // Finding the file is background work too, not just reading it.
            // The transcript does not exist until the pane's first exchange,
            // so this runs on *every* tick until it does — indefinitely, per
            // App-mode pane — and `resolvedTranscriptURL` lists
            // `~/.claude/projects` and stats a candidate under every directory
            // in it, ~40 syscalls a time. `EngineModel`'s header states the
            // rule that applies (`EngineLauncher.swift`): everything there
            // reads the filesystem, so call it from a background queue.
            let reader = existing ?? ClaudeModel.resolvedTranscriptURL(
                sessionID: sessionID, cwd: cwd, home: home
            ).map { ClaudeTranscriptReader(url: $0) }
            let update = reader?.poll() ?? .nothing
            DispatchQueue.main.async {
                guard let self else { return }
                // Whatever this cycle did with what it found, it landed.
                defer { self.onPollLanded?() }
                self.pollInFlight = false
                self.reader = reader
                // Deliberately *not* gated on `isLive`. `poll()` advanced the
                // reader's byte offset on the background queue, so these rows
                // exist nowhere but this closure and no later poll will ever
                // hand them back — dropping them because the pane went down
                // mid-read leaves a permanent hole in the middle of the
                // conversation. And a pane goes down mid-read routinely, not
                // by a millisecond race: `camera`'s didSet runs a visibility
                // pass per pinch event, so any zoom-out with a read in flight
                // would do it. Landing them anyway is safe — arranged
                // subviews and a layout pass, no drawing, on a view AppKit is
                // not compositing — and `stopPolling` has already invalidated
                // the timer, so at most one poll can ever arrive this way.
                if update.didReset { self.clearMessages() }
                self.appendMessages(update.messages)
            }
        }
    }

    // MARK: - Markdown

    /// Runs `raw` through `NSAttributedString(markdown:)` for inline
    /// emphasis, strong emphasis and inline code, then reapplies this view's
    /// own typography. Verified directly against what the parser actually
    /// hands back: an `NSInlinePresentationIntent` marker on each emphasised
    /// run and no `.font` or `.foregroundColor` of its own — so every run
    /// needs both set here, and a bold/italic/code run needs its trait
    /// carried over from that intent rather than from a font markdown never
    /// supplied.
    ///
    /// `baseFont` is what every non-code run gets, and what a bold or italic
    /// run is derived from — so a heading can run through here too and have
    /// its inline `` `code` `` rendered rather than printed with its
    /// backticks, which is routine in Claude's output.
    ///
    /// Internal rather than `private` so `PaneAppViewTests` can assert on the
    /// result directly.
    static func attributedMarkdown(
        _ raw: String,
        baseFont: NSFont = ShellFont.ui(13)
    ) -> NSAttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        let parsed = (try? AttributedString(markdown: raw, options: options))
            .map { NSAttributedString($0) } ?? NSAttributedString(string: raw)
        let result = NSMutableAttributedString(attributedString: parsed)
        let whole = NSRange(location: 0, length: result.length)
        result.addAttribute(.foregroundColor, value: ShellPalette.ink, range: whole)
        result.enumerateAttribute(.inlinePresentationIntent, in: whole, options: []) { value, range, _ in
            let intent: InlinePresentationIntent = (value as? NSNumber)
                .map { InlinePresentationIntent(rawValue: $0.uintValue) } ?? []
            // Monospaced at the base font's own size, so inline code in a
            // heading is the heading's size rather than body size.
            var font = intent.contains(.code) ? ShellFont.mono(baseFont.pointSize) : baseFont
            var traits: NSFontTraitMask = []
            if intent.contains(.stronglyEmphasized) { traits.insert(.boldFontMask) }
            if intent.contains(.emphasized) { traits.insert(.italicFontMask) }
            if !traits.isEmpty { font = NSFontManager.shared.convert(font, toHaveTrait: traits) }
            result.addAttribute(.font, value: font, range: range)
        }
        return result
    }

    // MARK: - Block views

    /// A wrapping, selectable prose label — markdown rendered, but block
    /// structure left as literal lines per `attributedMarkdown`.
    ///
    /// Internal rather than `fileprivate` so `PaneAppViewTests` can call it
    /// directly.
    static func proseLabel(_ raw: String) -> NSTextField {
        let field = NSTextField(labelWithString: "")
        field.isSelectable = true
        field.isEditable = false
        field.drawsBackground = false
        field.isBordered = false
        field.maximumNumberOfLines = 0
        field.lineBreakMode = .byWordWrapping
        field.attributedStringValue = attributedMarkdown(raw)
        field.translatesAutoresizingMaskIntoConstraints = false
        return field
    }

    /// A fenced code span: monospaced, on its own card, scrolling sideways
    /// rather than wrapping a long line.
    ///
    /// `fileprivate` rather than `private` so `PaneAppMessageRowView` can
    /// reach it, and so `renderTable`'s output can be drawn into the same
    /// card a fenced code block gets. Nothing outside this file builds one:
    /// the tests assert on the card through a rendered row.
    fileprivate static func codeBlockView(_ code: String) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = ShellPalette.cardFill.cgColor
        container.layer?.cornerRadius = 6
        container.layer?.cornerCurve = .continuous
        container.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: code)
        label.isSelectable = true
        label.isEditable = false
        label.drawsBackground = false
        label.isBordered = false
        label.maximumNumberOfLines = 0
        // No word-wrap: an overlong line stays one line and the scroll view
        // below handles the overflow, rather than AppKit breaking it for us.
        label.cell?.wraps = false
        label.lineBreakMode = .byClipping
        label.font = ShellFont.mono(12)
        label.textColor = ShellPalette.inkTerminal
        label.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = false
        scroll.autohidesScrollers = true
        scroll.documentView = label
        scroll.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
            // The label's own (unwrapped) intrinsic height drives the
            // scroll's — the reverse would be circular, since nothing else
            // gives the scroll view a height to hand down.
            scroll.heightAnchor.constraint(equalTo: label.heightAnchor),
            label.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            label.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
        ])
        return container
    }

    /// A markdown table as one monospaced, column-padded string — the same
    /// shape the terminal draws, and drawn into the same card a fenced code
    /// block gets.
    ///
    /// Deliberately not `NSGridView`/`NSTableView`: those are an order of
    /// magnitude more code, they have to negotiate width with the enclosing
    /// stack (a fight `codeBlockView`'s width constraint already documents),
    /// and they buy selectable cells nobody asked for.
    ///
    /// Not solved, only improved: `cell.count` counts *characters*, which is
    /// closer to the truth than the UTF-16 units `String.padding(toLength:)`
    /// would have used, but it is still not the width a monospaced font
    /// draws. A CJK ideograph or an emoji is one character and two columns
    /// wide, so a table containing either is padded short and its columns
    /// step right from there. Left as is: the terminal's own table misaligns
    /// the same way, and measuring true display width needs an East-Asian
    /// width table nothing in this app has.
    static func renderTable(header: [String], rows: [[String]]) -> String {
        let all = [header] + rows
        let columns = all.map(\.count).max() ?? 0
        guard columns > 0 else { return "" }

        // Ragged rows are ordinary markdown; they are padded out rather than
        // rejected, so a short row cannot index past a column width below.
        let padded = all.map { row in
            row + Array(repeating: "", count: columns - row.count)
        }
        var widths = Array(repeating: 0, count: columns)
        for row in padded {
            for (index, cell) in row.enumerated() {
                widths[index] = max(widths[index], cell.count)
            }
        }

        // Not `String.padding(toLength:)`: that counts UTF-16 units while
        // `cell.count` counts characters, and the two disagree the moment a
        // cell contains an emoji or a combining mark.
        func pad(_ cell: String, to width: Int) -> String {
            cell + String(repeating: " ", count: max(0, width - cell.count))
        }
        func line(_ row: [String]) -> String {
            row.enumerated()
                .map { pad($0.element, to: widths[$0.offset]) }
                .joined(separator: "  ")
                .replacingOccurrences(of: " +$", with: "", options: .regularExpression)
        }

        let rule = widths.map { String(repeating: "─", count: $0) }.joined(separator: "  ")
        return ([line(padded[0]), rule] + padded.dropFirst().map(line))
            .joined(separator: "\n")
    }

    /// A heading: body prose, scaled up and weighted by level. Levels below
    /// 3 flatten together — a transcript is not a document outline, and three
    /// distinguishable sizes is as far as the difference stays useful.
    static func headingLabel(level: Int, text: String) -> NSTextField {
        let size: CGFloat = level <= 1 ? 17 : (level == 2 ? 15 : 13)
        let font = ShellFont.ui(size, .semibold)
        let field = NSTextField(labelWithString: text)
        field.isSelectable = true
        field.isEditable = false
        field.drawsBackground = false
        field.isBordered = false
        field.maximumNumberOfLines = 0
        field.lineBreakMode = .byWordWrapping
        field.font = font
        field.textColor = ShellPalette.ink
        // Through the same inline parser paragraphs and list items use, at
        // the heading's own weight and size: `### The \`parse\` scanner` is
        // ordinary Claude output, and a plain label prints its backticks.
        field.attributedStringValue = attributedMarkdown(text, baseFont: font)
        field.translatesAutoresizingMaskIntoConstraints = false
        return field
    }

    /// A list: one row per item, marker in its own column so a wrapping item
    /// hangs under itself rather than under the marker above it.
    static func listView(items: [String], ordered: Bool) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.translatesAutoresizingMaskIntoConstraints = false

        for (index, item) in items.enumerated() {
            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .firstBaseline
            row.spacing = 6
            row.translatesAutoresizingMaskIntoConstraints = false

            let marker = ShellFont.label(
                ordered ? "\(index + 1)." : "•",
                font: ShellFont.ui(13),
                color: ShellPalette.inkTertiary
            )
            marker.setContentHuggingPriority(.required, for: .horizontal)
            let body = proseLabel(item)

            row.addArrangedSubview(marker)
            row.addArrangedSubview(body)
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return stack
    }

    /// The `▸ name  detail` line a tool call renders as — no box, no fill,
    /// truncated at the tail rather than wrapped, since a long shell command
    /// is a line to skim, not read in full.
    ///
    /// Internal rather than `fileprivate` so `PaneAppViewTests` can measure
    /// the label directly.
    static func toolLabel(name: String, detail: String) -> NSTextField {
        // `maximumNumberOfLines` caps *wrapping*, not hard newlines — a
        // `Bash` command is routinely a multi-line script, and without this
        // collapse one tool call used to spill twenty lines into the
        // transcript. (`usesSingleLineMode` does not help here: AppKit still
        // sizes a text field's intrinsic content around embedded newlines
        // regardless of that flag, so the newlines have to go before the
        // string ever reaches the field.)
        //
        // `split` rather than `components(separatedBy:)`: it drops the empty
        // pieces, so a blank line does not become a double space, a `\r\n`
        // does not become a stray one, and a detail that starts or ends with
        // a newline does not pad the label with whitespace.
        let flatDetail = detail.split(whereSeparator: \.isNewline).joined(separator: " ")
        let text = flatDetail.isEmpty ? "▸ \(name)" : "▸ \(name)  \(flatDetail)"
        let field = NSTextField(labelWithString: text)
        field.isSelectable = true
        field.isEditable = false
        field.drawsBackground = false
        field.isBordered = false
        field.maximumNumberOfLines = 1
        field.lineBreakMode = .byTruncatingTail
        field.font = ShellFont.ui(12)
        field.textColor = ShellPalette.inkMuted
        field.translatesAutoresizingMaskIntoConstraints = false
        return field
    }

    /// The header a collapsed run of tool calls reads as.
    ///
    /// A homogeneous run can name its tool honestly; a mixed one cannot, and
    /// listing every name would rebuild the wall of text this collapse
    /// exists to remove — so it counts steps instead.
    ///
    /// Only ever called with two or more names: a run of one renders inline
    /// and never becomes a group at all (`PaneAppMessageRowView.flushRun`).
    /// The single-name branch is defensive, kept so a future caller cannot
    /// get "1 Bash calls" out of it, and its test pins that rather than a
    /// group that exists.
    static func workSummary(for names: [String]) -> String {
        guard let first = names.first else { return "" }
        if names.count == 1 { return first }
        if names.allSatisfy({ $0 == first }) { return "\(names.count) \(first) calls" }
        return "\(names.count) steps"
    }
}

/// One `TranscriptTurn`, laid out whole in `init` from the blocks it is
/// handed.
///
/// A row is *not* built once and kept: a turn grows as its reply lands, and
/// `PaneAppView.appendMessages` answers that by throwing this view away and
/// constructing a new one from the merged blocks. Nothing here mutates after
/// `init`, which is what makes that safe — and why the only view state worth
/// keeping, a work group's expansion, is carried across by the caller through
/// `workGroups` rather than living in here.
final class PaneAppMessageRowView: NSView {
    /// This row's work groups, in the order they were built — the handle
    /// `PaneAppView.appendMessages` restores expansion state through when it
    /// rebuilds a growing turn. (A traversal would do as well; this is the
    /// one the row already knows for free, and the recursive `descendants`
    /// helper the tests use is test-only.)
    private(set) var workGroups: [PaneAppWorkGroupView] = []

    init(turn: TranscriptTurn) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let body = NSStackView()
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 4
        body.translatesAutoresizingMaskIntoConstraints = false

        let roleLabel = ShellFont.label(
            turn.isUser ? "You" : "Claude",
            font: ShellFont.ui(11, .semibold),
            color: turn.isUser ? ShellPalette.inkTertiary : ShellPalette.accent
        )
        body.addArrangedSubview(roleLabel)

        // Consecutive tool calls are one run and collapse together; anything
        // else flushes the run in progress first, so work keeps its place
        // between the prose either side of it.
        var run: [(name: String, detail: String)] = []
        func flushRun() {
            guard !run.isEmpty else { return }
            // A run of one is not the wall of shell commands the collapse
            // exists to remove — it renders inline, exactly as it did before
            // work groups existed. Only two or more calls collapse.
            if run.count == 1 {
                let call = run[0]
                for view in Self.blockViews(for: .tool(name: call.name, detail: call.detail)) {
                    add(view, to: body)
                }
            } else {
                let group = PaneAppWorkGroupView(calls: run)
                workGroups.append(group)
                add(group, to: body)
            }
            run = []
        }
        for block in turn.blocks {
            switch block {
            case .tool(let name, let detail):
                run.append((name, detail))
            case .text(let text):
                flushRun()
                for view in Self.blockViews(for: .text(text)) { add(view, to: body) }
            }
        }
        flushRun()

        addSubview(body)
        NSLayoutConstraint.activate([
            body.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            body.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            body.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            body.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    /// `.leading` alignment only pins each arranged view's leading edge;
    /// without the width constraint, a wrapping prose label or a truncating
    /// tool line reports its own tiny intrinsic width instead of filling the
    /// row.
    private func add(_ view: NSView, to body: NSStackView) {
        body.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
    }

    private static func blockViews(for block: TranscriptBlock) -> [NSView] {
        switch block {
        case .text(let text):
            return MarkdownBlock.parse(text).map { markdown -> NSView in
                switch markdown {
                case .paragraph(let prose):
                    return PaneAppView.proseLabel(prose)
                case .heading(let level, let text):
                    return PaneAppView.headingLabel(level: level, text: text)
                case .list(let items, let ordered):
                    return PaneAppView.listView(items: items, ordered: ordered)
                case .code(let code):
                    return PaneAppView.codeBlockView(code)
                case .table(let header, let rows):
                    return PaneAppView.codeBlockView(
                        PaneAppView.renderTable(header: header, rows: rows)
                    )
                }
            }
        case .tool(let name, let detail):
            return [PaneAppView.toolLabel(name: name, detail: detail)]
        }
    }
}

/// A run of consecutive tool calls in one turn, collapsed to a summary line
/// that expands on click.
///
/// The detail is built up front and merely hidden, never built on expand.
/// Not because rows are never rebuilt — a growing turn's row *is* rebuilt on
/// every poll — but because expansion state survives those rebuilds
/// (`PaneAppView.appendMessages` reapplies it), so a group can be expanded
/// from its first frame and the toggle must be a plain `isHidden` flip on a
/// tree that is already there rather than a mid-scroll construction.
final class PaneAppWorkGroupView: NSView {
    private(set) var isExpanded = false
    private let chevron: NSTextField
    private let detail = NSStackView()
    /// The clickable strip, kept for the cursor tracking area below: only the
    /// header toggles, so the pointing hand must not cover the detail lines.
    private let header: NSStackView
    private var cursorTracking: NSTrackingArea?

    init(calls: [(name: String, detail: String)]) {
        chevron = ShellFont.label("⌄", font: ShellFont.ui(11), color: ShellPalette.inkFaint)
        let summaryText = PaneAppView.workSummary(for: calls.map(\.name))
        let summary = ShellFont.label(
            summaryText,
            font: ShellFont.ui(12),
            color: ShellPalette.inkMuted
        )
        header = NSStackView(views: [chevron, summary])
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        // The header looks like a line of text and behaves like a control.
        // Without this it is invisible to VoiceOver and gives the pointer no
        // hint that it does anything.
        setAccessibilityElement(true)
        setAccessibilityRole(.disclosureTriangle)
        setAccessibilityLabel(summaryText)
        setAccessibilityExpanded(isExpanded)

        header.orientation = .horizontal
        header.alignment = .firstBaseline
        header.spacing = 6
        header.translatesAutoresizingMaskIntoConstraints = false

        detail.orientation = .vertical
        detail.alignment = .leading
        detail.spacing = 2
        detail.isHidden = true
        detail.translatesAutoresizingMaskIntoConstraints = false
        for call in calls {
            let label = PaneAppView.toolLabel(name: call.name, detail: call.detail)
            detail.addArrangedSubview(label)
            label.widthAnchor.constraint(equalTo: detail.widthAnchor).isActive = true
        }

        let body = NSStackView(views: [header, detail])
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 4
        body.translatesAutoresizingMaskIntoConstraints = false

        addSubview(body)
        NSLayoutConstraint.activate([
            body.topAnchor.constraint(equalTo: topAnchor),
            body.leadingAnchor.constraint(equalTo: leadingAnchor),
            body.trailingAnchor.constraint(equalTo: trailingAnchor),
            body.bottomAnchor.constraint(equalTo: bottomAnchor),
            header.widthAnchor.constraint(equalTo: body.widthAnchor),
            detail.widthAnchor.constraint(equalTo: body.widthAnchor),
        ])

        let click = NSClickGestureRecognizer(target: self, action: #selector(handleClick))
        header.addGestureRecognizer(click)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    /// The pointing hand over the header only — the detail lines below are
    /// selectable text and must keep the I-beam. `.cursorUpdate` on an
    /// explicit rect rather than a cursor rect for the same reason
    /// `PaneApprovalBar`'s buttons use one: these views are laid out by a
    /// stack that moves them, and a cursor rect is a frame the window caches.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let cursorTracking { removeTrackingArea(cursorTracking) }
        let area = NSTrackingArea(
            rect: convert(header.bounds, from: header),
            options: [.cursorUpdate, .activeInKeyWindow],
            owner: self
        )
        addTrackingArea(area)
        cursorTracking = area
    }

    override func cursorUpdate(with event: NSEvent) { NSCursor.pointingHand.set() }

    @objc private func handleClick() { toggle() }

    /// Internal rather than private so the tests can drive expansion without
    /// synthesising a click.
    func toggle() {
        isExpanded.toggle()
        detail.isHidden = !isExpanded
        chevron.stringValue = isExpanded ? "⌃" : "⌄"
        setAccessibilityExpanded(isExpanded)
    }
}
