import AppKit

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
    /// trimmed. Internal so the table tests can build expectations with it.
    static func cells(_ line: String) -> [String] {
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
    ///
    /// Rows are per *turn*, not per message, so a message that extends the
    /// turn already on screen rebuilds that one row rather than adding one.
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
        while messageStack.arrangedSubviews.count > firstChanged,
              let row = messageStack.arrangedSubviews.last {
            messageStack.removeArrangedSubview(row)
            row.removeFromSuperview()
        }
        for turn in turns[firstChanged...] {
            let row = PaneAppMessageRowView(turn: turn)
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
    /// Internal rather than `fileprivate` so `PaneAppViewTests` can call it
    /// directly, and so `renderTable`'s output can be drawn into the same
    /// card a fenced code block gets.
    static func codeBlockView(_ code: String) -> NSView {
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
        let field = NSTextField(labelWithString: text)
        field.isSelectable = true
        field.isEditable = false
        field.drawsBackground = false
        field.isBordered = false
        field.maximumNumberOfLines = 0
        field.lineBreakMode = .byWordWrapping
        field.font = ShellFont.ui(size, .semibold)
        field.textColor = ShellPalette.ink
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

    /// The header a collapsed run of tool calls reads as.
    ///
    /// A homogeneous run can name its tool honestly; a mixed one cannot, and
    /// listing every name would rebuild the wall of text this collapse
    /// exists to remove — so it counts steps instead.
    static func workSummary(for names: [String]) -> String {
        guard let first = names.first else { return "" }
        if names.count == 1 { return first }
        if names.allSatisfy({ $0 == first }) { return "\(names.count) \(first) calls" }
        return "\(names.count) steps"
    }
}

/// One `TranscriptTurn`, laid out once at append time and never rebuilt.
final class PaneAppMessageRowView: NSView {
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
            add(PaneAppWorkGroupView(calls: run), to: body)
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
/// The detail is built up front and merely hidden, never built on expand:
/// `PaneAppMessageRowView` lays a row out once and never rebuilds it, and
/// growing the view tree mid-scroll is exactly the kind of relayout that
/// contract exists to avoid.
final class PaneAppWorkGroupView: NSView {
    private(set) var isExpanded = false
    private let chevron: NSTextField
    private let detail = NSStackView()

    init(calls: [(name: String, detail: String)]) {
        chevron = ShellFont.label("⌄", font: ShellFont.ui(11), color: ShellPalette.inkFaint)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let summary = ShellFont.label(
            PaneAppView.workSummary(for: calls.map(\.name)),
            font: ShellFont.ui(12),
            color: ShellPalette.inkMuted
        )

        let header = NSStackView(views: [chevron, summary])
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

    @objc private func handleClick() { toggle() }

    /// Internal rather than private so the tests can drive expansion without
    /// synthesising a click.
    func toggle() {
        isExpanded.toggle()
        detail.isHidden = !isExpanded
        chevron.stringValue = isExpanded ? "⌃" : "⌄"
    }
}
