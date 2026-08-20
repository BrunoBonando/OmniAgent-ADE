import AppKit

// The sidebar's hover card: rest on a terminal, session, editor or browser row
// and a glass card slides out beside it saying what that one is doing — ready
// or working, since when, for how long, and the last line it printed, typed
// out live.
//
// Three parts, in order: a ledger (when did this pane start working), a model
// (what the card says), and the panel (glass, placement, motion). The first two
// are pure and tested without a window; only the third needs AppKit on screen.

// MARK: - Activity ledger

/// One pane's working life. Nothing else in the app knows this:
/// `WorkspaceWindowController.lastStatus` holds the current status and no
/// history, and `UsageAnalytics` buckets per *project*, which cannot answer a
/// question about one terminal.
struct PaneActivity: Equatable {
    /// Epoch ms the current run of work began, `nil` when the pane is not busy.
    var busySince: Double?
    /// Busy time from runs that have already ended.
    var settledActiveMs: Double = 0
    /// How many times this pane has gone off to run a tool.
    var toolRuns: Int = 0

    /// Total busy time including the run in progress.
    func activeMs(now: Double) -> Double {
        settledActiveMs + (busySince.map { max(0, now - $0) } ?? 0)
    }

    /// How long the current run has been going, or `nil` when nothing is.
    func runMs(now: Double) -> Double? {
        busySince.map { max(0, now - $0) }
    }
}

/// The status events, accumulated per pane.
struct PaneActivityLedger: Equatable {
    private(set) var panes: [String: PaneActivity] = [:]
    private var last: [String: RemoteSessionStatus] = [:]

    /// Working = thinking or running a tool — the same family the sidebar dot
    /// paints blue (`ShellDotsView.color(for:)`). An agent running a build for
    /// five minutes is working, and the card has to agree with the dot.
    static func isBusy(_ status: RemoteSessionStatus?) -> Bool {
        status == .thinking || status == .toolExecution
    }

    func activity(for paneID: String) -> PaneActivity? { panes[paneID] }

    /// One status event. Keeps its own previous-status map rather than being
    /// handed one: a repeated event must not restart the clock or count a
    /// second tool run, and the caller overwrites its own `lastStatus` on a
    /// schedule this has no say in.
    mutating func record(paneID: String, status: RemoteSessionStatus, at now: Double) {
        let previous = last[paneID]
        guard previous != status else { return }
        last[paneID] = status

        var activity = panes[paneID] ?? PaneActivity()
        let wasBusy = Self.isBusy(previous)
        let isBusy = Self.isBusy(status)
        // thinking -> tool -> thinking is *one* run, not three: "since" is
        // asked to mean the moment work began, not the moment of the latest
        // hop between two busy states.
        if isBusy, !wasBusy { activity.busySince = now }
        if !isBusy, wasBusy, let since = activity.busySince {
            activity.settledActiveMs += max(0, now - since)
            activity.busySince = nil
        }
        if status == .toolExecution { activity.toolRuns += 1 }
        panes[paneID] = activity
    }

    /// A closed pane's history goes with it — the ids are reused by nothing,
    /// but a ledger that only ever grows is a leak with a slow fuse.
    mutating func forget(paneID: String) {
        panes.removeValue(forKey: paneID)
        last.removeValue(forKey: paneID)
    }
}

// MARK: - What the card says

/// The card's content, derived and then rendered. Everything here is a string
/// the view prints as-is, so the shape of the card is decided in one testable
/// place instead of inside a stack of labels.
struct HoverCardModel: Equatable {
    var title: String
    /// "Working", "Waiting for you", "Ready" — the row's own status in words.
    var status: String
    var accent: NSColor
    var pulses: Bool
    var engine: Engine?
    /// `~/Code/thing`, or a browser's address.
    var meta: String?
    /// `started 20:14 · 4m 12s`.
    var timing: String?
    /// `42 tool runs`.
    var totals: String?
    /// The live output line — only while the pane is working. `nil` otherwise,
    /// and for anything that is not a terminal.
    var tail: String?
    /// Whether the card carries a working line at all. A terminal always does:
    /// working, it is the mark and the line; ready, it is the mark alone, green,
    /// which is the card saying "nothing running" without spending a word on it.
    var mark: Bool = false

    /// How much of the output line the card shows. The ask was the beginning
    /// of the line and an ellipsis, not the line.
    /// Three lines' worth of the card's own width. Past that the field
    /// truncates where the third line actually ends, which no character
    /// count can know; this only stops a runaway line being typed out in
    /// full behind the truncation.
    static let tailLimit = 120
}

extension HoverCardModel {
    // MARK: Builders

    /// One pane's card.
    static func pane(
        _ pane: PaneDescriptor,
        status: RemoteSessionStatus?,
        activity: PaneActivity?,
        editor: EditorPaneModel? = nil,
        tail: String? = nil,
        now: Double
    ) -> HoverCardModel {
        switch pane.kind {
        case .browser:
            return HoverCardModel(
                title: SessionOutline.paneLabel(pane),
                status: "Browser",
                accent: ShellPalette.idle,
                pulses: false,
                engine: nil,
                meta: pane.browserURL.isEmpty ? nil : pane.browserURL,
                timing: nil,
                totals: nil,
                tail: nil
            )
        case .editor:
            return HoverCardModel(
                title: SessionOutline.paneLabel(pane),
                status: "Editor",
                accent: editorIsDirty(editor) ? ShellPalette.amber : ShellPalette.idle,
                pulses: false,
                engine: nil,
                meta: editorMeta(pane: pane, editor: editor),
                timing: nil,
                totals: editorTotals(pane: pane, editor: editor),
                tail: nil
            )
        case .terminal:
            return HoverCardModel(
                title: SessionOutline.paneLabel(pane),
                status: word(for: status),
                accent: ShellDotsView.color(for: status),
                pulses: ShellDotsView.pulses(status),
                engine: pane.engine,
                meta: pane.cwd.isEmpty ? nil : WorkspaceBackRowView.abbreviate(pane.cwd),
                timing: timingLine(activity, now: now),
                totals: totalsLine(activity, now: now),
                // Only while it is working. A settled pane's last line is not
                // news, and a mark pulsing beside it would be a lie about what
                // the pane is doing.
                tail: PaneActivityLedger.isBusy(status) ? tail.flatMap { snippet($0) } : nil,
                mark: true
            )
        }
    }

    /// A session row's card: its panes, summarised.
    static func session(
        _ session: SessionGroupNode,
        panes: [String: PaneDescriptor],
        statuses: [String: RemoteSessionStatus],
        ledger: PaneActivityLedger,
        now: Double
    ) -> HoverCardModel {
        let live = session.paneIDs.filter { panes[$0]?.kind == .terminal }
        let waiting = live.filter { statuses[$0] == .awaitingApproval }.count
        let working = live.filter { PaneActivityLedger.isBusy(statuses[$0]) }.count
        let ready = live.filter { statuses[$0] == .ready }.count

        // The worst state wins, the same order the row's own dots read in:
        // something asking beats something working beats something done.
        let accent: NSColor
        let word: String
        if waiting > 0 {
            accent = ShellPalette.amber
            word = waiting == 1 ? "1 terminal is waiting" : "\(waiting) terminals are waiting"
        } else if working > 0 {
            accent = ShellPalette.blue
            word = working == 1 ? "1 terminal is working" : "\(working) terminals are working"
        } else if ready > 0 {
            accent = ShellPalette.green
            word = "Ready"
        } else {
            accent = ShellPalette.idle
            word = "Idle"
        }

        // The longest-running of them: the session's "how long has this been
        // going", which is the oldest start, not the newest.
        let longest = live
            .compactMap { ledger.activity(for: $0)?.runMs(now: now) }
            .max()

        var counts: [String] = [count(session.paneIDs.count, "pane")]
        if working > 0 { counts.append("\(working) working") }
        if waiting > 0 { counts.append("\(waiting) waiting") }
        if ready > 0 { counts.append("\(ready) ready") }

        return HoverCardModel(
            title: session.label,
            status: word,
            accent: accent,
            pulses: working > 0,
            engine: nil,
            meta: session.cwd.isEmpty ? nil : WorkspaceBackRowView.abbreviate(session.cwd),
            timing: longest.map { "working \(duration($0))" },
            totals: counts.joined(separator: " · "),
            tail: nil
        )
    }

    // MARK: Pieces

    static func word(for status: RemoteSessionStatus?) -> String {
        switch status {
        case .ready: return "Ready"
        case .thinking: return "Working"
        case .toolExecution: return "Running a tool"
        case .awaitingApproval: return "Waiting for you"
        case .error: return "Error"
        case nil: return "Idle"
        }
    }

    /// `started 20:14 · 4m 12s`, and nothing at all when the pane is not
    /// working — a stopped clock on a card that updates every tenth of a
    /// second reads as broken.
    static func timingLine(_ activity: PaneActivity?, now: Double) -> String? {
        guard let activity, let since = activity.busySince, let run = activity.runMs(now: now) else {
            return nil
        }
        return "started \(clock(since)) · \(duration(run))"
    }

    /// `42 tool runs`, and only that.
    ///
    /// Not tokens: nothing in the native app counts them
    /// (`UsageAnalytics.recordTokens` is ported but never called, and its
    /// buckets are per project), and a number the app cannot actually know is
    /// worse than no number. And not the active total either — the line above
    /// is already a clock, and two durations stacked one on the other read as
    /// the same fact printed twice.
    static func totalsLine(_ activity: PaneActivity?, now: Double) -> String? {
        guard let activity, activity.toolRuns > 0 else { return nil }
        return count(activity.toolRuns, "tool run")
    }

    private static func editorIsDirty(_ editor: EditorPaneModel?) -> Bool {
        editor?.tabs.contains(where: \.isDirty) ?? false
    }

    private static func editorMeta(pane: PaneDescriptor, editor: EditorPaneModel?) -> String? {
        if let path = editor?.activeTab?.path, !path.isEmpty {
            return WorkspaceBackRowView.abbreviate(path)
        }
        let persisted = pane.editorTabs.indices.contains(pane.editorActiveIndex)
            ? pane.editorTabs[pane.editorActiveIndex].path
            : pane.editorTabs.first?.path
        guard let persisted, !persisted.isEmpty else { return nil }
        return WorkspaceBackRowView.abbreviate(persisted)
    }

    private static func editorTotals(pane: PaneDescriptor, editor: EditorPaneModel?) -> String? {
        let tabs = editor?.tabs.count ?? pane.editorTabs.count
        guard tabs > 0 else { return nil }
        var parts = [count(tabs, "tab")]
        let dirty = editor?.tabs.filter(\.isDirty).count ?? 0
        if dirty > 0 { parts.append("\(dirty) unsaved") }
        return parts.joined(separator: " · ")
    }

    /// The beginning of the line, an ellipsis for the rest.
    static func snippet(_ line: String, limit: Int = HoverCardModel.tailLimit) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit)) + "…"
    }

    /// `12s`, `4m 12s`, `1h 04m` — the running clock, seconds included so it
    /// visibly ticks.
    static func duration(_ ms: Double) -> String {
        let total = Int(max(0, ms) / 1000)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 { return String(format: "%dh %02dm", hours, minutes) }
        if minutes > 0 { return "\(minutes)m \(seconds)s" }
        return "\(seconds)s"
    }

    /// Fixed 24-hour clock rather than the user's locale: the card sits beside
    /// a duration in the same line, and `8:14 PM · 4m 12s` reads as two
    /// different kinds of thing.
    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    static func clock(_ ms: Double) -> String {
        clockFormatter.string(from: Date(timeIntervalSince1970: ms / 1000))
    }

    private static func count(_ n: Int, _ noun: String) -> String {
        "\(n) \(noun)\(n == 1 ? "" : "s")"
    }
}

// MARK: - The typed-out line

/// The live output line, typed rather than swapped. When the line changes it
/// keeps whatever prefix the two share, erases only the part that differs, and
/// types the rest — so a line that merely grows continues instead of starting
/// over, which is what makes it read as the agent typing into the card rather
/// than as a label being reassigned.
final class TypingTextField: NSTextField {
    /// Fast enough to feel like a machine, slow enough to see. Typed in
    /// batches on a 60Hz timer rather than one timer per character.
    static let charactersPerSecond: Double = 600
    private static let tick: TimeInterval = 1.0 / 60
    /// How long the caret lingers after the last character.
    static let caretLinger: TimeInterval = 0.4
    /// How many lines the agent's line may run to before it is truncated.
    static let maximumLines = 3

    /// Off under Reduce Motion and in tests: the text lands whole.
    var animates = true

    private var goal = ""
    private var shown = ""
    private var timer: Timer?
    private var caretTimer: Timer?
    private let caret = CALayer()
    /// One text layout, asked two questions: how tall the finished line will
    /// be, and where its last glyph ends. Both need real line breaking — the
    /// field wraps, so neither is a width division.
    private let measured = (
        storage: NSTextStorage(),
        manager: NSLayoutManager(),
        container: NSTextContainer(size: .zero)
    )
    /// A cell configured exactly like this field's own, asked how tall a
    /// string wants to be. The layout above breaks lines the same way, but not
    /// to the same *height* — a text field's cell has padding of its own, and
    /// reserving three of the wrong unit is what leaves the third row drawn
    /// past the bottom of the field and truncated away.
    private let probe = NSTextFieldCell(textCell: "")

    init(font: NSFont, color: NSColor) {
        super.init(frame: .zero)
        isEditable = false
        isBordered = false
        isSelectable = false
        drawsBackground = false
        usesSingleLineMode = false
        cell?.wraps = true
        cell?.truncatesLastVisibleLine = true
        maximumNumberOfLines = Self.maximumLines
        // Word wrapping *plus* `truncatesLastVisibleLine` is what gives "wrap
        // to three rows, then an ellipsis". `.byTruncatingTail` on its own
        // never wraps at all — it ellipsises the first line and stops.
        lineBreakMode = .byWordWrapping
        self.font = font
        textColor = color
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        measured.container.lineFragmentPadding = 0
        measured.container.maximumNumberOfLines = Self.maximumLines
        probe.wraps = true
        probe.truncatesLastVisibleLine = true
        probe.lineBreakMode = .byWordWrapping
        measured.manager.addTextContainer(measured.container)
        measured.storage.addLayoutManager(measured.manager)
        caret.backgroundColor = color.withAlphaComponent(0.85).cgColor
        caret.cornerRadius = 0.75
        caret.opacity = 0
        layer?.addSublayer(caret)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    deinit {
        timer?.invalidate()
        caretTimer?.invalidate()
    }

    /// What is on screen right now — mid-type, so a test can watch it fill in.
    var typedText: String { shown }
    var isTyping: Bool { timer != nil }

    func setLine(_ next: String) {
        guard next != goal else { return }
        goal = next
        guard animates, !ShellMotion.reduced else {
            stop()
            shown = next
            render()
            return
        }
        shown = String(next.commonPrefix(with: shown))
        invalidateIntrinsicContentSize()
        render()
        startTyping()
    }

    /// Tall enough for the *finished* line, not the prefix on screen. Typing
    /// grows the string a line at a time, and a card sized to what is typed so
    /// far would grow a row under the reader twice on the way through every
    /// message.
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: height(of: goal))
    }

    /// One line as the cell itself measures one — the unit every height here
    /// is counted in, and what the mark beside the line is centred on.
    var singleLineHeight: CGFloat { probeHeight("M") }

    private func probeHeight(_ text: String) -> CGFloat {
        guard let font else { return 0 }
        probe.font = font
        probe.stringValue = text
        let width = wrapWidth > 0 ? wrapWidth : .greatestFiniteMagnitude
        return ceil(
            probe.cellSize(
                forBounds: NSRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude)
            ).height
        )
    }

    private var wrapWidth: CGFloat {
        preferredMaxLayoutWidth > 0 ? preferredMaxLayoutWidth : bounds.width
    }

    private func layOut(_ text: String) -> NSLayoutManager? {
        guard let font, wrapWidth > 0 else { return nil }
        measured.container.size = NSSize(width: wrapWidth, height: .greatestFiniteMagnitude)
        measured.storage.setAttributedString(
            NSAttributedString(string: text, attributes: [.font: font])
        )
        measured.manager.ensureLayout(for: measured.container)
        return measured.manager
    }

    private func height(of text: String) -> CGFloat {
        let unit = singleLineHeight
        guard unit > 0 else { return NSView.noIntrinsicMetric }
        guard !text.isEmpty else { return unit }
        let rows = min(Self.maximumLines, max(1, Int((probeHeight(text) / unit).rounded())))
        return unit * CGFloat(rows)
    }

    /// The line's colour, caret included — blue while the agent is working,
    /// the status colour when it is not.
    func setColor(_ color: NSColor) {
        guard textColor != color else { return }
        textColor = color
        caret.backgroundColor = color.withAlphaComponent(0.85).cgColor
    }

    /// Drops what is on screen without animating — used when the card swaps to
    /// a different row, where continuing to type would splice two panes'
    /// output into one sentence.
    func reset() {
        stop()
        goal = ""
        shown = ""
        caret.opacity = 0
        invalidateIntrinsicContentSize()
        render()
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        caretTimer?.invalidate()
        caretTimer = nil
    }

    private func startTyping() {
        stop()
        caret.opacity = 1
        guard shown.count < goal.count else {
            fadeCaret()
            return
        }
        let step = max(1, Int((Self.charactersPerSecond * Self.tick).rounded()))
        let timer = Timer(timeInterval: Self.tick, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            guard shown.count < goal.count else {
                timer.invalidate()
                self.timer = nil
                fadeCaret()
                return
            }
            shown = String(goal.prefix(shown.count + step))
            render()
        }
        // `.common` so typing does not stall while the sidebar is scrolled.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func fadeCaret() {
        caretTimer?.invalidate()
        caretTimer = Timer.scheduledTimer(withTimeInterval: Self.caretLinger, repeats: false) {
            [weak self] _ in
            guard let self else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                self.caret.opacity = 0
            }
        }
    }

    private func render() {
        stringValue = shown
        layoutCaret()
    }

    override func layout() {
        super.layout()
        layoutCaret()
    }

    private func layoutCaret() {
        guard font != nil else { return }
        let unit = singleLineHeight
        var frame = NSRect(x: 0, y: bounds.height - unit, width: 1.5, height: unit)
        if !shown.isEmpty, let manager = layOut(shown), manager.numberOfGlyphs > 0 {
            let last = NSRange(location: manager.numberOfGlyphs - 1, length: 1)
            let glyph = manager.boundingRect(forGlyphRange: last, in: measured.container)
            let fragment = manager.lineFragmentRect(forGlyphAt: last.location, effectiveRange: nil)
            // Which row the last glyph landed on, counted in the layout's own
            // line height and then paid out in the cell's — the two agree on
            // where words break, not on how tall a row is.
            let row = fragment.height > 0 ? Int((fragment.minY / fragment.height).rounded()) : 0
            // Never past the right edge: a truncated line has nowhere left to
            // put a caret, and one sitting outside the card would look like a
            // bug.
            frame.origin.x = min(glyph.maxX + 2, max(0, bounds.width - 2))
            // The layout is top-down and the field is not flipped.
            frame.origin.y = bounds.height - unit * CGFloat(row + 1)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        caret.frame = frame
        CATransaction.commit()
    }
}

// MARK: - The card's body

/// The OmniAgent mark in front of the working line, tinted and pulsing the way
/// the sidebar row's own mark does — the card's stand-in for the blinking
/// bullet the agent prints beside whatever it is currently doing.
final class HoverWorkingMarkView: NSImageView {
    static let size: CGFloat = 11

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.size, height: Self.size))
        image = OmniAgentMark.image
        imageScaling = .scaleProportionallyUpOrDown
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.size),
            heightAnchor.constraint(equalToConstant: Self.size),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func apply(color: NSColor, pulses: Bool) {
        contentTintColor = color
        shadow = {
            let glow = NSShadow()
            glow.shadowColor = color.withAlphaComponent(0.53)
            glow.shadowBlurRadius = 4
            glow.shadowOffset = .zero
            return glow
        }()
        layer?.removeAnimation(forKey: "om-pulse")
        guard pulses, !ShellMotion.reduced else { return }
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 0.45
        pulse.toValue = 1
        pulse.duration = 0.9
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        layer?.add(pulse, forKey: "om-pulse")
    }
}

/// Everything inside the glass. Rows the model has nothing for are hidden,
/// which in a stack view is the same as not being there — so a ready terminal's
/// card is genuinely three lines tall, not three lines and four gaps.
final class HoverCardBodyView: NSView {
    static let width: CGFloat = 280
    static let inset: CGFloat = 14
    /// Between the mark and the line it marks.
    static let markGap: CGFloat = 6

    let titleField = ShellFont.label(font: ShellFont.ui(15, .semibold), color: ShellPalette.ink)
    let metaField = ShellFont.label(font: ShellFont.ui(11.5), color: ShellPalette.inkMuted)
    let timingField = ShellFont.label(font: ShellFont.ui(11.5), color: ShellPalette.inkTertiary)
    let totalsField = ShellFont.label(font: ShellFont.ui(11.5), color: ShellPalette.inkFaint)
    /// The state line. Working, it is the agent's own current line, in blue —
    /// the one thing on the card that is happening rather than being reported.
    /// Otherwise it is the state in a word, in that state's colour: `Ready`
    /// green, `Waiting for you` amber.
    let tailField = TypingTextField(font: ShellFont.mono(11.5), color: ShellPalette.blue)
    /// The OmniAgent mark in front of that line, pulsing — standing in for the
    /// blinking bullet the agent puts there itself. Same glyph, same pulse and
    /// same blue as the sidebar row's own mark, so the card and the row are
    /// visibly saying one thing.
    let workingMark = HoverWorkingMarkView()
    let engineIcon = NSImageView()
    private let rule = NSView()
    private let tailRow = NSView()
    private let stack = NSStackView()

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 120))
        wantsLayer = true

        engineIcon.translatesAutoresizingMaskIntoConstraints = false
        engineIcon.imageScaling = .scaleProportionallyUpOrDown

        // The engine's mark rides on the title now that the status pill is
        // gone: what the pane is is a property of its name, not a row of its
        // own.
        let header = NSStackView(views: [titleField, NSView(), engineIcon])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8
        header.translatesAutoresizingMaskIntoConstraints = false

        rule.wantsLayer = true
        rule.layer?.backgroundColor = ShellPalette.hairlineStrong.cgColor
        rule.translatesAutoresizingMaskIntoConstraints = false

        // Not a stack, because the mark belongs on the *first* line of a line
        // that may run to three — a fixed drop from the top, not a centring.
        tailRow.translatesAutoresizingMaskIntoConstraints = false
        tailRow.addSubview(workingMark)
        tailRow.addSubview(tailField)

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.translatesAutoresizingMaskIntoConstraints = false
        for view in [header, metaField, timingField, totalsField, rule, tailRow] {
            stack.addArrangedSubview(view)
        }
        stack.setCustomSpacing(5, after: header)
        stack.setCustomSpacing(9, after: totalsField)
        stack.setCustomSpacing(8, after: rule)
        addSubview(stack)

        let content = Self.width - Self.inset * 2
        // Fixed, and set before anything measures with it: the field has to
        // break lines at the width the layout gives it, and an unset one
        // measures as a single endless line.
        tailField.preferredMaxLayoutWidth = content - HoverWorkingMarkView.size - Self.markGap

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.inset),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: Self.inset - 1),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -(Self.inset - 1)),
            stack.widthAnchor.constraint(equalToConstant: content),
            header.widthAnchor.constraint(equalToConstant: content),
            engineIcon.widthAnchor.constraint(equalToConstant: 15),
            engineIcon.heightAnchor.constraint(equalToConstant: 15),
            rule.widthAnchor.constraint(equalToConstant: content),
            rule.heightAnchor.constraint(equalToConstant: 1),
            metaField.widthAnchor.constraint(equalToConstant: content),
            timingField.widthAnchor.constraint(equalToConstant: content),
            totalsField.widthAnchor.constraint(equalToConstant: content),
            tailRow.widthAnchor.constraint(equalToConstant: content),
            workingMark.leadingAnchor.constraint(equalTo: tailRow.leadingAnchor),
            workingMark.topAnchor.constraint(
                equalTo: tailRow.topAnchor,
                constant: (tailField.singleLineHeight - HoverWorkingMarkView.size) / 2
            ),
            tailField.leadingAnchor.constraint(
                equalTo: workingMark.trailingAnchor,
                constant: Self.markGap
            ),
            tailField.trailingAnchor.constraint(equalTo: tailRow.trailingAnchor),
            tailField.topAnchor.constraint(equalTo: tailRow.topAnchor),
            tailField.bottomAnchor.constraint(equalTo: tailRow.bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    /// What the last `apply` drew, so the panel knows when the card changed
    /// shape and has to be resized.
    private(set) var model: HoverCardModel?

    func apply(_ model: HoverCardModel) {
        let sameRow = self.model?.title == model.title
        self.model = model

        titleField.stringValue = model.title
        // The status is not printed any more — the working line says it, and
        // says what the work *is*. It stays as the card's spoken label.
        setAccessibilityLabel("\(model.title). \(model.status)")

        set(metaField, model.meta)
        set(timingField, model.timing)
        set(totalsField, model.totals)

        if let engine = model.engine, let image = engine.iconImage {
            engineIcon.image = image
            if image.isTemplate { engineIcon.contentTintColor = ShellPalette.inkTertiary }
            engineIcon.isHidden = false
        } else {
            engineIcon.isHidden = true
        }

        rule.isHidden = !model.mark
        tailRow.isHidden = !model.mark
        workingMark.apply(color: model.accent, pulses: model.pulses)
        if model.mark {
            // Working: the agent's line, blue. Otherwise the state itself,
            // wearing the same colour as the mark beside it.
            tailField.setColor(model.tail == nil ? model.accent : ShellPalette.blue)
            // A different row is a different sentence: continuing the type
            // would splice two panes' output together.
            if !sameRow { tailField.reset() }
            tailField.setLine(model.tail ?? model.status)
        } else {
            tailField.reset()
        }
        needsLayout = true
    }

    private func set(_ field: NSTextField, _ text: String?) {
        field.stringValue = text ?? ""
        field.isHidden = (text == nil)
    }

    /// The height this card wants at its fixed width.
    var cardSize: NSSize {
        layoutSubtreeIfNeeded()
        return NSSize(width: Self.width, height: max(fittingSize.height, 44))
    }
}

// MARK: - The glass, and the drop

/// Everything inside the panel: the card, and the drop of glass beside it that
/// says which row this belongs to.
///
/// The drop is not drawn. It is a second `NSGlassEffectView`, and both of them
/// live inside an `NSGlassEffectContainerView` whose `spacing` is wide enough
/// that the system merges them — so what appears between the card and the row
/// is macOS 26's own liquid bridge, stretching and necking as the card moves
/// down the sidebar. A drawn triangle would be a shape stuck on the side of a
/// material; this is the material.
///
/// Below macOS 26 there is nothing to merge: the card falls back to the blur
/// `CommandPaletteController.glassHost` uses, and the drop to a tinted circle,
/// which points without pretending to flow.
final class HoverCardShellView: NSView {
    /// The arrowhead is a square of glass turned 45°, so its leading corner is
    /// a point. `NSGlassEffectView` offers a rounded rectangle and nothing
    /// else, and a rounded rectangle on its corner is an arrow — the merge with
    /// the card swallows the two corners facing it, which leaves a tapered head
    /// on a liquid neck rather than a diamond stuck to a box.
    static let dropSize: CGFloat = 13
    /// Rounded just enough not to alias. This is the "sharper" in the tip.
    static let dropCorner: CGFloat = 2
    /// The turned square's bounding box — the width the head really occupies.
    static var tipSpan: CGFloat { dropSize * 2.squareRoot() }
    /// Between the head and the card. Wide enough to read as two things
    /// joined, narrow enough that they *do* join.
    static let neck: CGFloat = 4
    /// The column the head lives in, left of the card, plus a point of air so
    /// the tip is never flush against the window's own edge.
    static var lane: CGFloat { tipSpan + neck + 1 }
    /// How far below the card's top edge the tip sits. Clear of the corner, so
    /// the bridge always leaves from a straight edge — and the card is placed
    /// *from this*, which is what makes the tip line up with the row's icon
    /// instead of being shoved down by its own clamp.
    static var tipInset: CGFloat { SessionHoverCardController.cornerRadius + tipSpan / 2 }

    let body = HoverCardBodyView()
    private let card: NSView
    /// The arrowhead's bounding box. The head is rotated inside it and never
    /// moved again: setting `frame` on a view with a `frameCenterRotation`
    /// resizes its *bounds* to keep the bounding box, which would quietly
    /// shrink the arrow every time the card slid to another row.
    private let dropBox = NSView()
    private let drop: NSView
    private let host: NSView
    private let wrapper = NSView()
    private let tint = CAGradientLayer()

    /// Where the drop points, in this view's coordinates. The card is
    /// top-aligned with its row but gets pushed around by the screen edges, so
    /// the row's centre is not a fixed place on the card.
    private(set) var dropCenterY: CGFloat = 0

    override init(frame frameRect: NSRect) {
        // The palette's treatment: the system material, with a slight navy
        // gradient over it — a flat wash reads as paint, a gradient as glass.
        body.wantsLayer = true
        tint.colors = [
            NSColor(srgbRed: 0.09, green: 0.10, blue: 0.16, alpha: 0.55).cgColor,
            NSColor(srgbRed: 0.05, green: 0.05, blue: 0.09, alpha: 0.42).cgColor,
        ]
        tint.startPoint = CGPoint(x: 0.1, y: 1)
        tint.endPoint = CGPoint(x: 0.9, y: 0)
        tint.cornerRadius = SessionHoverCardController.cornerRadius
        tint.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        body.layer?.insertSublayer(tint, at: 0)
        body.autoresizingMask = [.width, .height]

        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = SessionHoverCardController.cornerRadius
            glass.contentView = body
            card = glass

            let bead = NSGlassEffectView()
            bead.cornerRadius = Self.dropCorner
            // The same navy the card's gradient settles on, so the bridge
            // between them is one material rather than two.
            bead.tintColor = NSColor(srgbRed: 0.07, green: 0.08, blue: 0.13, alpha: 0.5)
            drop = bead

            let container = NSGlassEffectContainerView()
            // Comfortably more than `neck`: the merge begins at this distance,
            // and starting it early is what gives the bridge its curve.
            container.spacing = 24
            container.contentView = wrapper
            host = container
        } else {
            card = CommandPaletteController.glassHost(
                body,
                size: NSSize(width: HoverCardBodyView.width, height: 120),
                cornerRadius: SessionHoverCardController.cornerRadius
            )
            let bead = NSView()
            bead.wantsLayer = true
            bead.layer?.cornerRadius = Self.dropCorner
            bead.layer?.backgroundColor = NSColor(
                srgbRed: 0.12,
                green: 0.13,
                blue: 0.20,
                alpha: 0.92
            ).cgColor
            drop = bead
            host = NSView()
        }

        super.init(frame: frameRect)
        wantsLayer = true
        addSubview(host)
        // The container's `contentView` setter parents the wrapper itself; the
        // fallback's plain host does not.
        if wrapper.superview == nil { host.addSubview(wrapper) }
        wrapper.addSubview(card)
        wrapper.addSubview(dropBox)
        dropBox.addSubview(drop)
        // Turned once, here, and thereafter only ever moved by its box.
        drop.frame = NSRect(
            x: (Self.tipSpan - Self.dropSize) / 2,
            y: (Self.tipSpan - Self.dropSize) / 2,
            width: Self.dropSize,
            height: Self.dropSize
        )
        drop.frameCenterRotation = 45
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func layout() {
        super.layout()
        host.frame = bounds
        wrapper.frame = bounds
        card.frame = NSRect(x: Self.lane, y: 0, width: max(0, bounds.width - Self.lane), height: bounds.height)
        dropBox.frame = dropFrame(centerY: dropCenterY)
    }

    /// Points the drop at `centerY`. Animated when the card slides from one row
    /// to the next — the bridge necks and stretches on its own, which is the
    /// whole reason the drop is glass and not a triangle.
    func pointDrop(at centerY: CGFloat, animated: Bool) {
        dropCenterY = centerY
        let frame = dropFrame(centerY: centerY)
        guard animated, !ShellMotion.reduced else {
            dropBox.frame = frame
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 0.85, 0.25, 1)
            dropBox.animator().frame = frame
        }
    }

    /// Where the arrowhead sits for a given row centre. The clamp only bites
    /// when a screen edge has already pushed the card off its natural place —
    /// `SessionHoverCardController.frame` positions the card so the tip lands
    /// exactly on the row's centre, which is where its icon is.
    func dropFrame(centerY: CGFloat) -> NSRect {
        let inset = Self.tipInset
        let y = min(max(centerY, min(inset, bounds.height / 2)), max(bounds.height - inset, bounds.height / 2))
        return NSRect(
            x: Self.lane - Self.neck - Self.tipSpan,
            y: y - Self.tipSpan / 2,
            width: Self.tipSpan,
            height: Self.tipSpan
        )
    }
}

// MARK: - The panel

/// The hover card itself: a borderless glass panel that follows the pointer
/// down the sidebar.
///
/// A child window rather than a view inside the workspace, for two reasons.
/// The card reaches past the sidebar over the panes, which a subview would be
/// clipped by; and real Liquid Glass needs something behind it to refract, so
/// it has to be its own window (the same reason the spotlight is one — see
/// `CommandPaletteController`).
///
/// It never takes the mouse. `ignoresMouseEvents` is the whole interaction
/// model: rest on a row and it appears, move on and it goes, and it can never
/// swallow a click meant for the pane underneath it.
final class SessionHoverCardController {
    /// Which row the pointer is on.
    enum Target: Equatable {
        case pane(String)
        case session(String)
    }

    /// The card's content, asked for fresh on every tick. The sidebar rebuilds
    /// its rows on every status change, so nothing here may hold one.
    var provider: ((Target) -> HoverCardModel?)?
    /// Where that row is *now*, in screen coordinates — `nil` when it is gone,
    /// which takes the card with it. Re-read every tick for the same reason:
    /// a row rebuilt under a stationary pointer must not drop the card.
    var rowFrame: ((Target) -> NSRect?)?

    /// Barely a delay at all — enough to keep a pointer crossing the list from
    /// firing a card per row, and no more. Anything longer reads as the card
    /// deciding whether to come.
    static let openDelay: TimeInterval = 0.12
    static let tickInterval: TimeInterval = 0.1
    /// Between the row's right edge and the card — the arrowhead's lane, plus
    /// enough that its tip lands just off the row rather than on top of it.
    static var gap: CGFloat { HoverCardShellView.lane + 4 }
    static let cornerRadius: CGFloat = 16
    /// How far the card slides in, and back out.
    static let slide: CGFloat = 6

    private(set) var target: Target?
    private let shell = HoverCardShellView()
    private var body: HoverCardBodyView { shell.body }
    private let panel: NSPanel
    private var openTimer: Timer?
    private var tickTimer: Timer?
    private weak var parent: NSWindow?

    var isOpen: Bool { panel.isVisible }
    /// For tests: what the card is currently showing.
    var shownModel: HoverCardModel? { body.model }

    init() {
        panel = NSPanel(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: HoverCardBodyView.width + HoverCardShellView.lane,
                height: 120
            ),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.transient, .ignoresCycle]
        panel.contentView = shell
    }

    deinit {
        openTimer?.invalidate()
        tickTimer?.invalidate()
    }

    /// The pointer entered a row, or left one (`nil`).
    func hover(_ next: Target?, in parent: NSWindow?) {
        self.parent = parent
        guard let next else {
            openTimer?.invalidate()
            openTimer = nil
            dismiss()
            return
        }
        guard next != target || !isOpen else { return }
        target = next
        // Already showing something: slide to the new row now. The delay is
        // there to stop a card appearing at all while the pointer travels, not
        // to slow down one that is already on screen.
        if isOpen {
            present()
            return
        }
        openTimer?.invalidate()
        openTimer = Timer.scheduledTimer(withTimeInterval: Self.openDelay, repeats: false) {
            [weak self] _ in
            self?.present()
        }
    }

    func dismiss() {
        openTimer?.invalidate()
        openTimer = nil
        tickTimer?.invalidate()
        tickTimer = nil
        target = nil
        guard panel.isVisible else { return }
        let panel = panel
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = ShellMotion.reduced ? 0 : 0.09
            panel.animator().alphaValue = 0
        }, completionHandler: {
            // A second hover may have re-opened it in the meantime.
            guard panel.alphaValue == 0 else { return }
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        })
    }

    /// Where the panel goes: the arrowhead level with the row's centre — which
    /// is where the row's icon is, both being centred on it — and the card
    /// `gap` past the sidebar's edge, always fully inside the window.
    ///
    /// Placed from the tip rather than from the card's top edge. Top-aligning
    /// the card put the row's centre inside the corner radius, where the head
    /// cannot go, so its own clamp shoved it a few points down: the arrow was
    /// always slightly below the icon it was pointing at.
    ///
    /// `size` is the whole panel, arrow lane included, so the lane comes back
    /// off the left — the head belongs in the space between the row and the
    /// card, which is exactly what it is pointing across.
    static func frame(size: NSSize, row: NSRect, container: NSRect) -> NSRect {
        var origin = NSPoint(
            x: row.maxX + gap - HoverCardShellView.lane,
            y: row.midY + HoverCardShellView.tipInset - size.height
        )
        origin.x = min(origin.x, container.maxX - size.width - 8)
        origin.x = max(origin.x, container.minX + 8)
        origin.y = min(origin.y, container.maxY - size.height - 8)
        origin.y = max(origin.y, container.minY + 8)
        return NSRect(origin: origin, size: size)
    }

    /// The whole panel for a card of `size` — the drop needs a lane of its own.
    static func panelSize(card: NSSize) -> NSSize {
        NSSize(width: card.width + HoverCardShellView.lane, height: card.height)
    }

    private func present() {
        openTimer?.invalidate()
        openTimer = nil
        guard let target,
              let model = provider?(target),
              let row = rowFrame?(target),
              let parent
        else {
            dismiss()
            return
        }

        let wasOpen = panel.isVisible
        body.apply(model)
        body.tailField.animates = !ShellMotion.reduced
        let size = Self.panelSize(card: body.cardSize)
        let frame = Self.frame(size: size, row: row, container: parent.frame)

        if !wasOpen {
            panel.setFrame(frame.offsetBy(dx: -Self.slide, dy: 0), display: false)
            panel.alphaValue = 0
            if panel.parent !== parent {
                panel.parent?.removeChildWindow(panel)
                parent.addChildWindow(panel, ordered: .above)
            }
            panel.orderFront(nil)
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = ShellMotion.reduced ? 0 : (wasOpen ? 0.14 : 0.12)
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            panel.animator().setFrame(frame, display: true)
        }
        // Animated only when sliding between rows: on the way in the card is
        // moving anyway, and a drop crawling into place behind it reads as lag.
        shell.pointDrop(at: row.midY - frame.minY, animated: wasOpen)
        startTicking()
    }

    private func startTicking() {
        guard tickTimer == nil else { return }
        let timer = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    /// The card's whole life after it opens: fresh content, a re-read row
    /// frame, and the pointer test that closes it.
    private func tick() {
        guard let target, let parent, panel.isVisible else {
            dismiss()
            return
        }
        guard let row = rowFrame?(target), let model = provider?(target) else {
            dismiss()
            return
        }
        // The pointer, not `mouseExited`: a row destroyed by a reload never
        // sends one, and the card would be stranded on screen.
        guard row.contains(NSEvent.mouseLocation) else {
            dismiss()
            return
        }
        body.apply(model)
        let frame = Self.frame(size: Self.panelSize(card: body.cardSize), row: row, container: parent.frame)
        if !frame.equalTo(panel.frame) { panel.setFrame(frame, display: true) }
        // The row moves under the card as the sidebar reloads; the drop keeps
        // pointing at it.
        let centerY = row.midY - frame.minY
        if abs(centerY - shell.dropCenterY) > 0.5 { shell.pointDrop(at: centerY, animated: true) }
    }
}
