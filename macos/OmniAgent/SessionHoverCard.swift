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
    /// Epoch ms this pane was first heard from — the card's "age".
    ///
    /// The app's own first sight of it, not a durable creation stamp: nothing
    /// persists one, and the daemon's sessions carry an `Instant`, which does
    /// not survive a daemon restart either. A restored pane therefore reads as
    /// young, which is the honest answer to "how long has this been running".
    var firstSeen: Double?
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
        if activity.firstSeen == nil { activity.firstSeen = now }
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

/// One line of the session card's "Working now" table: a pane that is *not*
/// ready, and the last thing it said.
struct HoverWorkRow: Equatable {
    var paneID: String
    var title: String
    /// What is driving the pane, and only that. Not a model name: nothing in
    /// the app knows which model an engine picked, and a made-up one is worse
    /// than none. And not the status either — the caret, the colour and the
    /// table's own title all say it already, three times over.
    var detail: String
    /// The pane's own last output line, always ending in an ellipsis: the pane
    /// is mid-sentence, and the line should read like one. Empty for a pane
    /// that has printed nothing yet — the row is still worth showing, it is
    /// working.
    var line: String
    var accent: NSColor
    var pulses: Bool
    var engine: Engine?

    /// Shorter than a pane card's `tail`: this is one line of a table, and the
    /// table matters more than any single row in it.
    static let lineLimit = 90
}

/// The session card's KPI strip and its table — everything a pane card does
/// not have. A session is a fleet; the card is its dashboard.
struct SessionDashboard: Equatable {
    /// One colour per terminal, worst state first. The bar's filled pills:
    /// count them and you have the session's size, read them and you have its
    /// state. `capacity` is the rest of the bar, drawn empty — which is the
    /// one thing a donut cannot say at all.
    var pills: [NSColor]
    var capacity: Int
    /// The headline number: how many are working right now.
    var working: Int
    /// `2 waiting · 1 ready` — the rest of the mix, beside the headline.
    var mix: String
    /// `2h`, `3d`, `5mo` — the oldest pane in the session.
    var age: String?
    var branch: String?
    /// `nil` until the first `git diff` lands, and hidden when the tree is
    /// clean.
    var git: GitDiffStat?
    /// The four most urgent, most recent panes that are doing something.
    var rows: [HoverWorkRow]

    /// How many rows the table ever shows. Four is what fits beside a sidebar
    /// row without the card running off the screen.
    static let maxRows = 4
}

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
    /// The session card's dashboard. `nil` for a pane card, which is one pane
    /// and has nothing to summarise.
    var dashboard: SessionDashboard?

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
                meta: pane.cwd.isEmpty ? nil : ShellPath.abbreviate(pane.cwd),
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

    /// A session row's card: the fleet, as a dashboard.
    ///
    /// Everything here is derived from what the window already holds — no new
    /// bookkeeping, except `git`, which is a subprocess the caller caches
    /// (`GitDiffStat.cached`). Nothing on this path may block: it runs ten
    /// times a second while the card is open.
    static func session(
        _ session: SessionGroupNode,
        panes: [String: PaneDescriptor],
        statuses: [String: RemoteSessionStatus],
        ledger: PaneActivityLedger,
        eventTimes: [String: Double] = [:],
        tails: (String) -> String? = { _ in nil },
        git: GitDiffStat? = nil,
        branch: String? = nil,
        capacity: Int = PaneGrid.maxPanes,
        now: Double
    ) -> HoverCardModel {
        let live = session.paneIDs.filter { panes[$0]?.kind == .terminal }
        let waiting = live.filter { statuses[$0] == .awaitingApproval }.count
        let working = live.filter { PaneActivityLedger.isBusy(statuses[$0]) }.count
        let ready = live.filter { statuses[$0] == .ready }.count
        let errored = live.filter { statuses[$0] == .error }.count

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

        // Worst first, so a bar read left to right is a bar read in order of
        // how much it wants from you.
        let pills = live
            .sorted { severity(statuses[$0]) < severity(statuses[$1]) }
            .map { ShellDotsView.color(for: statuses[$0]) }

        var mix: [String] = []
        if errored > 0 { mix.append("\(errored) error") }
        if waiting > 0 { mix.append("\(waiting) waiting") }
        if ready > 0 { mix.append("\(ready) ready") }
        let idle = live.count - working - waiting - ready - errored
        if idle > 0 { mix.append("\(idle) idle") }

        // A ready pane is not news — the ask was the panes that are *doing*
        // something. Urgent first, then whichever spoke most recently.
        let rows = live
            .filter { severity(statuses[$0]) < severity(.ready) }
            .sorted {
                let left = severity(statuses[$0]), right = severity(statuses[$1])
                if left != right { return left < right }
                return (eventTimes[$0] ?? 0) > (eventTimes[$1] ?? 0)
            }
            .prefix(SessionDashboard.maxRows)
            .compactMap { id -> HoverWorkRow? in
                guard let pane = panes[id] else { return nil }
                let status = statuses[id]
                return HoverWorkRow(
                    paneID: id,
                    title: SessionOutline.paneLabel(pane),
                    detail: pane.engine.displayName,
                    line: tails(id)
                        .flatMap { snippet($0, limit: HoverWorkRow.lineLimit) }
                        .map { $0.hasSuffix("…") ? $0 : $0 + "…" } ?? "",
                    accent: ShellDotsView.color(for: status),
                    pulses: ShellDotsView.pulses(status),
                    engine: pane.engine
                )
            }

        let born = live.compactMap { ledger.activity(for: $0)?.firstSeen }.min()
        let age = born.map { Self.age(now - $0) }
        // The age rides on the path line rather than taking a row of its own:
        // it is one word, and a row for one word is how a card becomes a form.
        let meta = [
            session.cwd.isEmpty ? nil : ShellPath.abbreviate(session.cwd),
            age.map { "\($0) old" },
        ].compactMap { $0 }.joined(separator: "  ·  ")

        return HoverCardModel(
            title: session.label,
            status: word,
            accent: accent,
            pulses: working > 0,
            engine: nil,
            meta: meta.isEmpty ? nil : meta,
            timing: nil,
            totals: nil,
            tail: nil,
            dashboard: SessionDashboard(
                pills: pills,
                capacity: max(capacity, live.count),
                working: working,
                mix: mix.joined(separator: " · "),
                age: age,
                branch: branch,
                git: (git?.isEmpty ?? true) ? nil : git,
                rows: Array(rows)
            )
        )
    }

    /// Worst first: an error, then something waiting on you, then something
    /// working, then a settled pane, then one that has never said anything.
    /// The one ordering the pill bar and the table both sort by.
    static func severity(_ status: RemoteSessionStatus?) -> Int {
        switch status {
        case .error: return 0
        case .awaitingApproval: return 1
        case .thinking, .toolExecution: return 2
        case .ready: return 3
        case nil: return 4
        }
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
            return ShellPath.abbreviate(path)
        }
        let persisted = pane.editorTabs.indices.contains(pane.editorActiveIndex)
            ? pane.editorTabs[pane.editorActiveIndex].path
            : pane.editorTabs.first?.path
        guard let persisted, !persisted.isEmpty else { return nil }
        return ShellPath.abbreviate(persisted)
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

    /// `12s`, `4m`, `3h`, `2d`, `3w`, `5mo`, `2y` — one unit, the biggest
    /// that fits. Deliberately coarser than `duration`: that one is a running
    /// clock and has to tick, this one answers "how old is this" and a second
    /// hand on it would be noise.
    static func age(_ ms: Double) -> String {
        let seconds = max(0, ms) / 1000
        let minutes = seconds / 60, hours = minutes / 60, days = hours / 24
        if seconds < 60 { return "\(Int(seconds))s" }
        if minutes < 60 { return "\(Int(minutes))m" }
        if hours < 24 { return "\(Int(hours))h" }
        if days < 7 { return "\(Int(days))d" }
        if days < 30 { return "\(Int(days / 7))w" }
        // Calendar months and years, averaged. The card says "5mo", not a date
        // — nobody reading a hover card is counting the days in February.
        if days < 365 { return "\(Int(days / 30))mo" }
        return "\(Int(days / 365))y"
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

/// The blinking caret in front of a working pane's last line — a terminal's
/// own cursor, borrowed. With the ellipsis at the end of that line it is the
/// card saying "this sentence is not finished", which is exactly what a pane
/// that is still working is doing.
final class HoverCaretView: NSView {
    static let width: CGFloat = 2
    static let height: CGFloat = 13

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = Self.width / 2
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.width),
            heightAnchor.constraint(equalToConstant: Self.height),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func apply(color: NSColor, blinks: Bool) {
        layer?.backgroundColor = color.cgColor
        layer?.removeAnimation(forKey: "om-blink")
        guard blinks, !ShellMotion.reduced else {
            layer?.opacity = 1
            return
        }
        // Discrete, not eased: a caret is on or off. A fading one reads as a
        // pulse, which is what the mark at the head of the row already does.
        let blink = CAKeyframeAnimation(keyPath: "opacity")
        blink.values = [1, 0]
        blink.keyTimes = [0, 0.5, 1]
        blink.calculationMode = .discrete
        blink.duration = 1.06
        blink.repeatCount = .infinity
        layer?.add(blink, forKey: "om-blink")
    }
}

/// The branch, top right: its name and then the git-branch glyph, in green.
/// A fact about the whole card, so it sits on the title's line rather than
/// inside the tile that happens to count its diff.
final class HoverBranchView: NSView {
    private let field = ShellFont.label(font: ShellFont.ui(11.5, .medium), color: ShellPalette.green)
    private let icon = NSImageView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.image = NSImage(
            systemSymbolName: "arrow.triangle.branch",
            accessibilityDescription: "branch"
        )
        icon.image?.isTemplate = true
        icon.contentTintColor = ShellPalette.green
        addSubview(field)
        addSubview(icon)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.leadingAnchor.constraint(equalTo: field.trailingAnchor, constant: 5),
            icon.trailingAnchor.constraint(equalTo: trailingAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 12),
            icon.heightAnchor.constraint(equalToConstant: 12),
            heightAnchor.constraint(equalToConstant: 15),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func apply(_ branch: String?) {
        field.stringValue = branch ?? ""
        isHidden = (branch == nil)
        setAccessibilityLabel(branch.map { "on branch \($0)" })
    }
}

/// The pane bar: one filled pill per terminal in the session, and an empty one
/// for every slot it has not used.
///
/// The alternative was a half-donut with the count in the hole. A donut of four
/// slices at this size is a pie chart nobody can read: arc angles do not
/// answer "how many", and the number in the middle only repeats what the ring
/// failed to say. One pill per pane answers it by counting, colours it by
/// status, and shows the empty slots as well — which no donut can.
final class HoverPillBarView: NSView {
    static let height: CGFloat = 6
    static let gap: CGFloat = 3
    /// Below this a pill is a dash, so the bar stops adding slots and simply
    /// shows what it can. A twelve-pane session is already off the design's map.
    static let minPill: CGFloat = 4

    private(set) var pills: [NSColor] = []
    private(set) var capacity = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: Self.height).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func apply(pills: [NSColor], capacity: Int) {
        guard pills != self.pills || capacity != self.capacity else { return }
        self.pills = pills
        self.capacity = capacity
        needsDisplay = true
    }

    /// How many slots actually fit. The filled ones always do — an empty slot
    /// is the first thing to give up when the bar runs out of room.
    func slotCount(width: CGFloat) -> Int {
        let wanted = max(capacity, pills.count)
        guard wanted > 0, width > 0 else { return 0 }
        let fits = Int((width + Self.gap) / (Self.minPill + Self.gap))
        return max(pills.count, min(wanted, fits))
    }

    override func draw(_ dirtyRect: NSRect) {
        let slots = slotCount(width: bounds.width)
        guard slots > 0 else { return }
        let pill = (bounds.width - Self.gap * CGFloat(slots - 1)) / CGFloat(slots)
        guard pill > 0 else { return }
        for index in 0..<slots {
            let color = index < pills.count ? pills[index] : Self.emptySlot
            color.setFill()
            let rect = NSRect(
                x: (pill + Self.gap) * CGFloat(index),
                y: 0,
                width: pill,
                height: bounds.height
            )
            NSBezierPath(
                roundedRect: rect,
                xRadius: min(bounds.height / 2, pill / 2),
                yRadius: bounds.height / 2
            ).fill()
        }
    }

    private static let emptySlot = NSColor(white: 1, alpha: 0.09)
}

/// The diff bar: how much of the uncommitted work is added versus removed.
/// The numbers beside it carry the magnitude; this carries the ratio.
final class HoverDiffBarView: NSView {
    static let height: CGFloat = 6
    static let gap: CGFloat = 2
    /// A one-line deletion in a thousand-line diff still gets a visible sliver
    /// — a bar that rounds a real number to nothing is lying.
    static let minSlice: CGFloat = 5

    private var added = 0
    private var removed = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: Self.height).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func apply(added: Int, removed: Int) {
        guard added != self.added || removed != self.removed else { return }
        self.added = added
        self.removed = removed
        needsDisplay = true
    }

    /// The green slice's width, clamped so neither side vanishes while it still
    /// has lines in it.
    func greenWidth(total width: CGFloat) -> CGFloat {
        let sum = added + removed
        guard sum > 0, width > 0 else { return 0 }
        if removed == 0 { return width }
        if added == 0 { return 0 }
        let usable = width - Self.gap
        let raw = usable * CGFloat(added) / CGFloat(sum)
        return min(max(raw, Self.minSlice), max(usable - Self.minSlice, 0))
    }

    override func draw(_ dirtyRect: NSRect) {
        let radius = bounds.height / 2
        guard added + removed > 0 else {
            NSColor(white: 1, alpha: 0.09).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
            return
        }
        let green = greenWidth(total: bounds.width)
        if green > 0 {
            ShellPalette.green.setFill()
            NSBezierPath(
                roundedRect: NSRect(x: 0, y: 0, width: green, height: bounds.height),
                xRadius: radius,
                yRadius: radius
            ).fill()
        }
        let redX = green > 0 ? green + Self.gap : 0
        let redWidth = bounds.width - redX
        if redWidth > 0 {
            ShellPalette.red.setFill()
            NSBezierPath(
                roundedRect: NSRect(x: redX, y: 0, width: redWidth, height: bounds.height),
                xRadius: radius,
                yRadius: radius
            ).fill()
        }
    }
}

/// One KPI tile: a caption, a hint on the right, a big number with a label
/// beside it, and a bar underneath. Both tiles on the card are this — the
/// terminals one and the uncommitted one differ only by what they hand it.
final class HoverKPITileView: NSView {
    static let corner: CGFloat = 10
    static let padding: CGFloat = 10

    private let captionField = ShellFont.label(
        font: ShellFont.ui(10, .semibold),
        color: ShellPalette.inkTertiary,
        tracking: 0.9
    )
    private let hintField = ShellFont.label(font: ShellFont.ui(10), color: ShellPalette.inkTertiary)
    private let valueField = ShellFont.label(
        font: ShellFont.ui(23, .semibold),
        color: ShellPalette.inkSecondary
    )
    private let labelField = ShellFont.label(font: ShellFont.ui(11.5), color: ShellPalette.inkSecondary)

    init(caption: String, accessory: NSView) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 1, alpha: 0.045).cgColor
        layer?.cornerRadius = Self.corner
        layer?.borderWidth = 1
        layer?.borderColor = ShellPalette.hairline.cgColor

        captionField.stringValue = caption.uppercased()
        // The caption must never be the thing that gets squeezed: it is two
        // words, and the hint beside it is the one that can go.
        captionField.setContentCompressionResistancePriority(.required, for: .horizontal)
        hintField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        hintField.alignment = .right

        let header = NSStackView(views: [captionField, NSView(), hintField])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 6

        // First baseline, so `14` and `files` sit on one line the way a
        // sentence does rather than being centred against each other.
        let value = NSStackView(views: [valueField, labelField, NSView()])
        value.orientation = .horizontal
        value.alignment = .firstBaseline
        value.spacing = 5

        // The caption and the number sit at the top, the bar at the *bottom*.
        // The two tiles are held to one height, and a bar pinned under its own
        // number would then float at two different levels — which is the one
        // thing that makes a pair of tiles look thrown together.
        let top = NSStackView(views: [header, value])
        top.orientation = .vertical
        top.alignment = .leading
        top.spacing = 3
        top.translatesAutoresizingMaskIntoConstraints = false
        accessory.translatesAutoresizingMaskIntoConstraints = false
        addSubview(top)
        addSubview(accessory)

        // The gap is a floor plus a preference: the natural height is the
        // preference, and the taller of the two tiles pushes past it.
        let hug = accessory.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 9)
        hug.priority = .defaultLow

        NSLayoutConstraint.activate([
            top.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.padding),
            top.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.padding),
            top.topAnchor.constraint(equalTo: topAnchor, constant: Self.padding - 1),
            accessory.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.padding),
            accessory.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.padding),
            accessory.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.padding),
            accessory.topAnchor.constraint(greaterThanOrEqualTo: top.bottomAnchor, constant: 9),
            hug,
            header.widthAnchor.constraint(equalTo: top.widthAnchor),
            value.widthAnchor.constraint(equalTo: top.widthAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func apply(value: String, label: String, hint: String?) {
        valueField.stringValue = value
        labelField.stringValue = label
        hintField.stringValue = hint ?? ""
        hintField.isHidden = (hint == nil)
    }
}

/// One line of the "Working now" table: the OmniAgent mark in the pane's own
/// status colour, the pane's name and what is driving it, and under it the last
/// line that pane printed.
final class HoverWorkRowView: NSView {
    static let markGap: CGFloat = 8

    private let mark = HoverWorkingMarkView()
    private let headerField = ShellFont.label(font: ShellFont.ui(12.5, .semibold), color: ShellPalette.ink)
    private let lineField = ShellFont.label(font: ShellFont.ui(11.5), color: ShellPalette.blue)
    private let caret = HoverCaretView()
    private let lineRow = NSStackView()
    private var row: HoverWorkRow?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false

        // Name and engine are one attributed field rather than two labels in a
        // stack: two labels need baseline alignment and a spacer to keep from
        // being centred against each other, and one string gets both for free.
        lineRow.orientation = .horizontal
        lineRow.alignment = .centerY
        lineRow.spacing = 6
        lineRow.addArrangedSubview(caret)
        lineRow.addArrangedSubview(lineField)

        let text = NSStackView(views: [headerField, lineRow])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        text.translatesAutoresizingMaskIntoConstraints = false
        addSubview(mark)
        addSubview(text)

        NSLayoutConstraint.activate([
            mark.leadingAnchor.constraint(equalTo: leadingAnchor),
            mark.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            text.leadingAnchor.constraint(equalTo: mark.trailingAnchor, constant: Self.markGap),
            text.trailingAnchor.constraint(equalTo: trailingAnchor),
            text.topAnchor.constraint(equalTo: topAnchor),
            text.bottomAnchor.constraint(equalTo: bottomAnchor),
            headerField.widthAnchor.constraint(equalTo: text.widthAnchor),
            lineRow.widthAnchor.constraint(equalTo: text.widthAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func apply(_ row: HoverWorkRow) {
        guard row != self.row else { return }
        self.row = row
        headerField.attributedStringValue = Self.header(title: row.title, detail: row.detail)
        lineField.stringValue = row.line
        // The status colour, softened a touch: it is a subtitle under a white
        // name, and full-strength blue on glass at 11.5pt glares rather than
        // reads. Not softened further — it still has to be legible.
        lineField.textColor = row.accent.withAlphaComponent(0.88)
        lineRow.isHidden = row.line.isEmpty
        caret.apply(color: row.accent, blinks: true)
        mark.apply(color: row.accent, pulses: row.pulses)
        setAccessibilityLabel("\(row.title). \(row.detail). \(row.line)")
    }

    /// The name in white, what is driving it in grey, on one line.
    static func header(title: String, detail: String) -> NSAttributedString {
        let string = NSMutableAttributedString(
            string: title,
            attributes: [
                .font: ShellFont.ui(12.5, .semibold),
                .foregroundColor: ShellPalette.ink,
            ]
        )
        string.append(NSAttributedString(
            string: "  \(detail)",
            attributes: [
                .font: ShellFont.ui(11.5),
                .foregroundColor: ShellPalette.inkTertiary,
            ]
        ))
        return string
    }
}

/// The session card's dashboard: two KPI tiles, and the table of everything
/// that is doing something right now.
///
/// The table's rows are a fixed pool of four, shown and hidden rather than
/// built and destroyed — which is what lets the card *grow* when a fifth
/// terminal starts working instead of snapping to a new size.
final class HoverDashboardView: NSView {
    private let panesBar = HoverPillBarView()
    private let diffBar = HoverDiffBarView()
    private let panesTile: HoverKPITileView
    private let gitTile: HoverKPITileView
    private let addedField = ShellFont.label(font: ShellFont.ui(11, .medium), color: ShellPalette.green)
    private let removedField = ShellFont.label(font: ShellFont.ui(11, .medium), color: ShellPalette.red)
    private let tableCaption = ShellFont.label(
        "WORKING NOW",
        font: ShellFont.ui(10, .semibold),
        color: ShellPalette.inkTertiary,
        tracking: 0.9
    )
    private let tableCount = ShellFont.label(font: ShellFont.ui(10), color: ShellPalette.inkTertiary)
    private let tableHeader = NSStackView()
    private let rowViews = (0..<SessionDashboard.maxRows).map { _ in HoverWorkRowView() }
    private let rows = NSStackView()
    private let tiles = NSStackView()

    override init(frame frameRect: NSRect) {
        let diffNumbers = NSStackView(views: [addedField, removedField, diffBar])
        diffNumbers.orientation = .horizontal
        diffNumbers.alignment = .centerY
        diffNumbers.spacing = 6
        // The bar takes whatever the two numbers leave; the numbers are the
        // fact and must never be the thing that truncates.
        addedField.setContentHuggingPriority(.required, for: .horizontal)
        removedField.setContentHuggingPriority(.required, for: .horizontal)
        addedField.setContentCompressionResistancePriority(.required, for: .horizontal)
        removedField.setContentCompressionResistancePriority(.required, for: .horizontal)

        panesTile = HoverKPITileView(caption: "Terminals", accessory: panesBar)
        gitTile = HoverKPITileView(caption: "Uncommitted", accessory: diffNumbers)
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false

        tiles.orientation = .horizontal
        tiles.distribution = .fillEqually
        tiles.alignment = .top
        tiles.spacing = 8
        tiles.addArrangedSubview(panesTile)
        tiles.addArrangedSubview(gitTile)
        // One height for both, whichever's contents are taller. Below
        // `.required` so that a hidden tile — which the stack collapses on a
        // clean tree — can never make the layout unsatisfiable.
        let equalHeights = gitTile.heightAnchor.constraint(equalTo: panesTile.heightAnchor)
        equalHeights.priority = .defaultHigh
        equalHeights.isActive = true

        tableCount.alignment = .right
        tableHeader.orientation = .horizontal
        tableHeader.alignment = .centerY
        tableHeader.spacing = 6
        for view in [tableCaption, NSView(), tableCount] { tableHeader.addArrangedSubview(view) }

        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 9
        for view in rowViews { rows.addArrangedSubview(view) }

        let stack = NSStackView(views: [tiles, tableHeader, rows])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.setCustomSpacing(11, after: tiles)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            tiles.widthAnchor.constraint(equalTo: stack.widthAnchor),
            tableHeader.widthAnchor.constraint(equalTo: stack.widthAnchor),
            rows.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ] + rowViews.map { $0.widthAnchor.constraint(equalTo: rows.widthAnchor) })
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    /// For tests: which rows the table is actually showing.
    var visibleRowCount: Int { rowViews.filter { !$0.isHidden }.count }

    func apply(_ dashboard: SessionDashboard, animated: Bool) {
        panesTile.apply(
            value: "\(dashboard.working)",
            label: dashboard.mix.isEmpty ? "working" : "working · \(dashboard.mix)",
            hint: "of \(dashboard.capacity) max"
        )
        panesBar.apply(pills: dashboard.pills, capacity: dashboard.capacity)

        if let git = dashboard.git {
            gitTile.isHidden = false
            gitTile.apply(
                value: "\(git.files)",
                label: git.files == 1 ? "file" : "files",
                hint: nil
            )
            addedField.stringValue = "+\(git.added)"
            // A real minus sign, not a hyphen: it sits beside a `+` at the same
            // optical weight, which a hyphen does not.
            removedField.stringValue = "\u{2212}\(git.removed)"
            diffBar.apply(added: git.added, removed: git.removed)
        } else {
            gitTile.isHidden = true
        }

        let count = dashboard.rows.count
        tableCount.stringValue = count == 1 ? "1 agent" : "\(count) agents"
        for (index, view) in rowViews.enumerated() {
            if index < count { view.apply(dashboard.rows[index]) }
            let hidden = index >= count
            guard view.isHidden != hidden else { continue }
            setHidden(view, hidden, animated: animated)
        }
        let empty = count == 0
        setHidden(tableHeader, empty, animated: animated)
        setHidden(rows, empty, animated: animated)
    }

    /// Shown or hidden *now*, and faded in on the way. Not through
    /// `animator().isHidden`: that collapses the row over its own duration, and
    /// the card is measured the instant this returns — so the panel would size
    /// itself to the shape the table had a moment ago and catch up in jerks.
    /// The smooth growth is the panel's frame animation; this is only the row
    /// arriving softly inside it.
    private func setHidden(_ view: NSView, _ hidden: Bool, animated: Bool) {
        guard view.isHidden != hidden else { return }
        view.isHidden = hidden
        guard animated, !hidden else {
            view.alphaValue = 1
            return
        }
        view.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            view.animator().alphaValue = 1
        }
    }
}

/// Everything inside the glass. Rows the model has nothing for are hidden,
/// which in a stack view is the same as not being there — so a ready terminal's
/// card is genuinely three lines tall, not three lines and four gaps.
final class HoverCardBodyView: NSView {
    /// A pane's card: a name and three lines.
    static let width: CGFloat = 280
    /// A session's card: two KPI tiles side by side, and a table under them.
    /// The one card in the app that is a dashboard rather than a label.
    static let sessionWidth: CGFloat = 404
    static let inset: CGFloat = 14
    /// Between the mark and the line it marks.
    static let markGap: CGFloat = 6

    let titleField = ShellFont.label(font: ShellFont.ui(15, .semibold), color: ShellPalette.ink)
    let metaField = ShellFont.label(font: ShellFont.ui(11.5), color: ShellPalette.inkTertiary)
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
    /// The branch, top right. A session card's; a pane card wears its engine
    /// mark in the same corner and never both.
    let branchView = HoverBranchView()
    /// The session card's KPI tiles and "Working now" table. Hidden — and so,
    /// in a stack view, absent — on a pane's card.
    let dashboardView = HoverDashboardView()
    private let rule = NSView()
    private let tailRow = NSView()
    private let stack = NSStackView()
    /// The navy wash over the system material: a flat fill reads as paint, a
    /// gradient as glass.
    ///
    /// Top to bottom, and framed in `layout()`. It used to run corner to corner
    /// and rely on layer autoresizing from a frame nobody ever set — which was
    /// invisible on a card of one size and became a dark blotch across the
    /// bottom-left corner the moment the card could be 404 points wide and
    /// change height a row at a time.
    private let tint = CAGradientLayer()

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 120))
        wantsLayer = true
        tint.colors = [
            NSColor(srgbRed: 0.085, green: 0.095, blue: 0.15, alpha: 0.52).cgColor,
            NSColor(srgbRed: 0.05, green: 0.055, blue: 0.09, alpha: 0.52).cgColor,
        ]
        tint.startPoint = CGPoint(x: 0.5, y: 1)
        tint.endPoint = CGPoint(x: 0.5, y: 0)
        tint.cornerRadius = SessionHoverCardController.cornerRadius
        layer?.insertSublayer(tint, at: 0)

        engineIcon.translatesAutoresizingMaskIntoConstraints = false
        engineIcon.imageScaling = .scaleProportionallyUpOrDown

        // The engine's mark rides on the title now that the status pill is
        // gone: what the pane is is a property of its name, not a row of its
        // own.
        let header = NSStackView(views: [titleField, NSView(), branchView, engineIcon])
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
        for view in [header, metaField, timingField, totalsField, dashboardView, rule, tailRow] {
            stack.addArrangedSubview(view)
        }
        stack.setCustomSpacing(5, after: header)
        stack.setCustomSpacing(9, after: totalsField)
        stack.setCustomSpacing(8, after: rule)
        addSubview(stack)

        // Set before anything measures with it: the field has to break lines at
        // the width the layout gives it, and an unset one measures as a single
        // endless line.
        stackWidth = stack.widthAnchor.constraint(equalToConstant: contentWidth)
        tailField.preferredMaxLayoutWidth = contentWidth - HoverWorkingMarkView.size - Self.markGap

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.inset),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: Self.inset - 1),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -(Self.inset - 1)),
            stackWidth,
            engineIcon.widthAnchor.constraint(equalToConstant: 15),
            engineIcon.heightAnchor.constraint(equalToConstant: 15),
            rule.heightAnchor.constraint(equalToConstant: 1),
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
        ] + [header, metaField, timingField, totalsField, dashboardView, rule, tailRow].map {
            $0.widthAnchor.constraint(equalTo: stack.widthAnchor)
        })
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    /// What the last `apply` drew, so the panel knows when the card changed
    /// shape and has to be resized.
    private(set) var model: HoverCardModel?

    /// The width the card is currently drawn at — one of the two constants,
    /// picked by whether the model carries a dashboard.
    private(set) var currentWidth = HoverCardBodyView.width
    private var contentWidth: CGFloat { currentWidth - Self.inset * 2 }
    private var stackWidth: NSLayoutConstraint!

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

        branchView.apply(model.dashboard?.branch)

        if let engine = model.engine, let image = engine.iconImage {
            engineIcon.image = image
            if image.isTemplate { engineIcon.contentTintColor = ShellPalette.inkTertiary }
            engineIcon.isHidden = false
        } else {
            engineIcon.isHidden = true
        }

        if currentWidth != (model.dashboard == nil ? Self.width : Self.sessionWidth) {
            currentWidth = model.dashboard == nil ? Self.width : Self.sessionWidth
            stackWidth.constant = contentWidth
            tailField.preferredMaxLayoutWidth =
                contentWidth - HoverWorkingMarkView.size - Self.markGap
            tailField.invalidateIntrinsicContentSize()
        }

        if let dashboard = model.dashboard {
            dashboardView.isHidden = false
            // Only while the card stays put: a card that has just slid to
            // another row is already moving, and rows fading in behind that
            // read as lag rather than as the table growing.
            dashboardView.apply(dashboard, animated: sameRow && !ShellMotion.reduced)
        } else {
            dashboardView.isHidden = true
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

    override func layout() {
        super.layout()
        // Explicitly, every pass: the card has two widths and a height that
        // moves with the table, and a gradient sized to any of the others is a
        // stain rather than a wash.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tint.frame = bounds
        CATransaction.commit()
    }

    private func set(_ field: NSTextField, _ text: String?) {
        field.stringValue = text ?? ""
        field.isHidden = (text == nil)
    }

    /// The height this card wants at its fixed width.
    var cardSize: NSSize {
        layoutSubtreeIfNeeded()
        return NSSize(width: currentWidth, height: max(fittingSize.height, 44))
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

    /// Where the drop points, in this view's coordinates. The card is
    /// top-aligned with its row but gets pushed around by the screen edges, so
    /// the row's centre is not a fixed place on the card.
    private(set) var dropCenterY: CGFloat = 0

    override init(frame frameRect: NSRect) {
        // The navy wash over the material lives on the body itself, which is
        // the view that resizes — see `HoverCardBodyView.tint`.
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
        if !frame.equalTo(panel.frame) {
            // A pane started or stopped working and the table gained or lost a
            // row: animate the height so the card grows to cover it rather than
            // snapping to a new size under a stationary pointer. A move with no
            // resize is just the row scrolling, and animating that lags.
            if ShellMotion.reduced || frame.size.equalTo(panel.frame.size) {
                panel.setFrame(frame, display: true)
            } else {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.2
                    context.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 0.85, 0.25, 1)
                    panel.animator().setFrame(frame, display: true)
                }
            }
        }
        // The row moves under the card as the sidebar reloads; the drop keeps
        // pointing at it.
        let centerY = row.midY - frame.minY
        if abs(centerY - shell.dropCenterY) > 0.5 { shell.pointDrop(at: centerY, animated: true) }
    }
}
