import AppKit

/// One split of a `.text` block's raw string — see `PaneAppView.splitFences`.
/// Internal rather than `private` so `PaneAppViewTests` can assert on a split
/// directly, without going through a live row.
enum PaneAppTextSegment: Equatable {
    case prose(String)
    case code(String)
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

    private let scrollView: ShellScrollView
    private let messageStack = NSStackView()
    private let emptyStateLabel = ShellFont.label(
        "Nothing yet.",
        font: ShellFont.ui(13),
        color: ShellPalette.inkFaint
    )
    private let fieldContainer = NSView()
    private let composerField: HomeComposerField = {
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
        }
    }

    /// Where keyboard focus should land when this view is the pane's active
    /// content — the composer, so typing starts a message rather than
    /// requiring a click first.
    var primaryResponderView: NSView { composerField }

    init(sessionID: String, cwd: String, home: URL = ClaudeModel.homeDirectory) {
        self.sessionID = sessionID
        self.cwd = cwd
        self.home = home
        scrollView = ShellScrollView(documentView: messageStack)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
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

        fieldContainer.wantsLayer = true
        fieldContainer.layer?.backgroundColor = ShellPalette.fieldFill.cgColor
        fieldContainer.layer?.cornerRadius = 10
        fieldContainer.layer?.cornerCurve = .continuous
        fieldContainer.layer?.borderWidth = 1
        fieldContainer.layer?.borderColor = ShellPalette.cardStroke.cgColor
        fieldContainer.translatesAutoresizingMaskIntoConstraints = false

        let separator = ShellSeparator()

        composerField.target = self
        composerField.action = #selector(submitComposer)
        composerField.onFocusChange = { [weak self] focused in
            self?.fieldContainer.layer?.borderColor =
                (focused ? ShellPalette.accent.withAlphaComponent(0.5) : ShellPalette.cardStroke).cgColor
        }

        fieldContainer.addSubview(composerField)
        for view in [scrollView, emptyStateLabel, separator, fieldContainer] as [NSView] {
            addSubview(view)
        }

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: separator.topAnchor),

            emptyStateLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyStateLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),

            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),

            fieldContainer.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 10),
            fieldContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            fieldContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            fieldContainer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            fieldContainer.heightAnchor.constraint(equalToConstant: 36),

            composerField.leadingAnchor.constraint(equalTo: fieldContainer.leadingAnchor, constant: 10),
            composerField.trailingAnchor.constraint(equalTo: fieldContainer.trailingAnchor, constant: -10),
            composerField.centerYAnchor.constraint(equalTo: fieldContainer.centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    deinit {
        pollTimer?.invalidate()
    }

    // MARK: - Composer

    @objc private func submitComposer() {
        let text = composerField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        onSubmit?(text)
        composerField.stringValue = ""
    }

    // MARK: - Messages

    /// Appends one row per message, in order. The one path both the poll
    /// timer and the tests use to put a row on screen — a poll's messages are
    /// the ones appended to the transcript since the last call, so there is
    /// nothing to diff against and nothing already on screen is rebuilt.
    ///
    /// The single exception is a transcript Claude rewrote, which `poll()`
    /// re-reads from the start and reports as `didReset`. That is answered by
    /// `clearMessages()` *before* this runs, not by diffing here.
    func appendMessages(_ messages: [TranscriptMessage]) {
        guard !messages.isEmpty else { return }
        // Measured before a single row is added: a user already scrolled up
        // to read earlier messages must not be yanked back down by a reply
        // arriving behind their back.
        let wasAtBottom = isScrolledToBottom()
        for message in messages {
            let row = PaneAppMessageRowView(message: message)
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

    private func isScrolledToBottom() -> Bool {
        let clip = scrollView.contentView
        return clip.bounds.maxY >= messageStack.frame.height - 2
    }

    private func scrollToBottom() {
        let clip = scrollView.contentView
        clip.scroll(to: NSPoint(x: 0, y: max(0, messageStack.frame.height - clip.bounds.height)))
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

    // MARK: - Fenced code

    /// Splits a `.text` block's raw string on fenced code blocks: a line
    /// whose trimmed content starts with ``` opens a fence and the next such
    /// line closes it. The fence marker lines are dropped outright — they are
    /// syntax, not content — and an unterminated fence simply runs to the end
    /// of the text rather than being treated as an error.
    ///
    /// Internal rather than `private` so `PaneAppViewTests` can assert on the
    /// split directly.
    static func splitFences(_ text: String) -> [PaneAppTextSegment] {
        var segments: [PaneAppTextSegment] = []
        var proseLines: [String] = []
        var codeLines: [String] = []
        var inFence = false

        func flushProse() {
            guard !proseLines.isEmpty else { return }
            segments.append(.prose(proseLines.joined(separator: "\n")))
            proseLines = []
        }
        func flushCode() {
            segments.append(.code(codeLines.joined(separator: "\n")))
            codeLines = []
        }

        for line in text.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                inFence ? flushCode() : flushProse()
                inFence.toggle()
                continue
            }
            if inFence {
                codeLines.append(line)
            } else {
                proseLines.append(line)
            }
        }
        inFence ? flushCode() : flushProse()
        return segments
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
    /// Internal rather than `private` so `PaneAppViewTests` can assert on the
    /// result directly.
    static func attributedMarkdown(_ raw: String) -> NSAttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        let parsed = (try? AttributedString(markdown: raw, options: options))
            .map { NSAttributedString($0) } ?? NSAttributedString(string: raw)
        let result = NSMutableAttributedString(attributedString: parsed)
        let whole = NSRange(location: 0, length: result.length)
        result.addAttribute(.foregroundColor, value: ShellPalette.ink, range: whole)
        result.enumerateAttribute(.inlinePresentationIntent, in: whole, options: []) { value, range, _ in
            let intent: InlinePresentationIntent = (value as? NSNumber)
                .map { InlinePresentationIntent(rawValue: $0.uintValue) } ?? []
            var font = intent.contains(.code) ? ShellFont.mono(13) : ShellFont.ui(13)
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
    fileprivate static func proseLabel(_ raw: String) -> NSTextField {
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
        let flatDetail = detail.components(separatedBy: .newlines).joined(separator: " ")
        let text = detail.isEmpty ? "▸ \(name)" : "▸ \(name)  \(flatDetail)"
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
}

/// One `TranscriptMessage`, laid out once at append time and never rebuilt.
final class PaneAppMessageRowView: NSView {
    init(message: TranscriptMessage) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let body = NSStackView()
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 4
        body.translatesAutoresizingMaskIntoConstraints = false

        let roleLabel = ShellFont.label(
            message.isUser ? "You" : "Claude",
            font: ShellFont.ui(11, .semibold),
            color: message.isUser ? ShellPalette.inkTertiary : ShellPalette.accent
        )
        body.addArrangedSubview(roleLabel)

        for block in message.blocks {
            for view in Self.blockViews(for: block) {
                body.addArrangedSubview(view)
                // `.leading` alignment only pins each arranged view's leading
                // edge; without this, a wrapping prose label or a truncating
                // tool line would report its own tiny intrinsic width instead
                // of filling the row.
                view.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
            }
        }

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

    private static func blockViews(for block: TranscriptBlock) -> [NSView] {
        switch block {
        case .text(let text):
            return PaneAppView.splitFences(text).compactMap { segment in
                switch segment {
                case .prose(let prose):
                    let trimmed = prose.trimmingCharacters(in: .whitespacesAndNewlines)
                    return trimmed.isEmpty ? nil : PaneAppView.proseLabel(prose)
                case .code(let code):
                    return PaneAppView.codeBlockView(code)
                }
            }
        case .tool(let name, let detail):
            return [PaneAppView.toolLabel(name: name, detail: detail)]
        }
    }
}
