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

/// One line of the git tab's commit list: the short hash, the subject, and
/// how long ago it landed.
struct HoverCommitRow: Equatable {
    var hash: String
    var subject: String
    var age: String

    /// Longer than a work row's: a commit subject is written to be read, and
    /// the git tab has no second column competing for the width.
    static let subjectLimit = 46
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
    /// The git tab's commit list, already aged against the card's own clock —
    /// a string the view prints, like everything else here, so that the model
    /// only changes when the card's *text* does and not ten times a second.
    var commits: [HoverCommitRow] = []

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
                rows: Array(rows),
                commits: (git?.recent ?? []).map {
                    HoverCommitRow(
                        hash: $0.hash,
                        subject: snippet($0.subject, limit: HoverCommitRow.subjectLimit) ?? "",
                        age: Self.age(now - $0.at * 1000)
                    )
                }
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

    /// `showsHeadline` off drops the big value/label row entirely — the git
    /// tile has three peer numbers of its own in its accessory now, and a
    /// headline above them would just be a fourth, redundant one.
    /// `showsCaption` off drops the tile's own title too, for the same tile:
    /// three labelled numbers already say what they are.
    init(caption: String, accessory: NSView, showsHeadline: Bool = true, showsCaption: Bool = true) {
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
        header.isHidden = !showsCaption

        // First baseline, so `14` and `files` sit on one line the way a
        // sentence does rather than being centred against each other.
        let value = NSStackView(views: [valueField, labelField, NSView()])
        value.orientation = .horizontal
        value.alignment = .firstBaseline
        value.spacing = 5
        value.isHidden = !showsHeadline

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
        // preference, and the taller of the two tiles pushes past it. With
        // neither caption nor headline there is nothing for `accessory` to
        // clear, and the same 9pt would just be dead air above the numbers —
        // so this tile's height stays closer to its neighbour's, rather than
        // both stretching to match whichever grew, which is how a tile with
        // half the content ends up with none of the difference to show for it.
        let gap: CGFloat = (showsHeadline || showsCaption) ? 9 : 1
        let hug = accessory.topAnchor.constraint(equalTo: top.bottomAnchor, constant: gap)
        hug.priority = .defaultLow

        NSLayoutConstraint.activate([
            top.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.padding),
            top.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.padding),
            top.topAnchor.constraint(equalTo: topAnchor, constant: Self.padding - 1),
            accessory.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.padding),
            accessory.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.padding),
            accessory.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.padding),
            accessory.topAnchor.constraint(greaterThanOrEqualTo: top.bottomAnchor, constant: gap),
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

    // MARK: The tile as a tab

    /// Hovering a tile is what selects it. A hover card asking for a click to
    /// show more of what the pointer is already resting on is a click that
    /// buys nothing.
    var onHover: (() -> Void)?

    private(set) var isSelected = false
    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        // `.activeAlways`: the card is a non-activating panel and is never the
        // key window, so `.activeInKeyWindow` would never fire in it.
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { onHover?() }

    /// Instant, not faded: this tile sits above `page` and is meant to read
    /// as fixed while a tab switch turns the content underneath it — a
    /// half-second cross-fade on its own background, landing in the same
    /// moment as `page`'s push transition, is what made the fixed row look
    /// like it was repainting along with the part that actually moves.
    func setSelected(_ selected: Bool) {
        guard isSelected != selected else { return }
        isSelected = selected
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.backgroundColor = (selected
            ? ShellPalette.cardFillHover
            : NSColor(white: 1, alpha: 0.045)).cgColor
        layer?.borderColor = (selected
            ? NSColor(white: 1, alpha: 0.16)
            : ShellPalette.hairline).cgColor
        CATransaction.commit()
    }
}

/// One line of the "Working now" table.
///
/// Two rows of two columns. On the left a lane of marks: the engine's logo
/// beside the pane's name, and under it the OmniAgent mark in the pane's own
/// status colour, pulsing — which is where a blinking caret used to be, and
/// says the same thing without a second blinking object in every row. On the
/// right the name and what is driving it, and under it the last line the pane
/// printed. Both text rows start at the same x: the lane is a fixed width, so
/// the two read as one left-aligned column rather than two indents.
final class HoverWorkRowView: NSView {
    /// The marks' lane. Wide enough for the larger of the two glyphs, and the
    /// same for every row whatever engine it is running.
    static let lane: CGFloat = 15
    static let laneGap: CGFloat = 9
    static let engineSize: CGFloat = 13

    private let engineIcon = NSImageView()
    private let mark = HoverWorkingMarkView()
    private let headerField = ShellFont.label(font: ShellFont.ui(12.5, .semibold), color: ShellPalette.ink)
    private let lineField = ShellFont.label(font: ShellFont.ui(11.5), color: ShellPalette.blue)
    private var row: HoverWorkRow?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        engineIcon.translatesAutoresizingMaskIntoConstraints = false
        engineIcon.imageScaling = .scaleProportionallyUpOrDown

        // Name and engine are one attributed field rather than two labels in a
        // stack: two labels need baseline alignment and a spacer to keep from
        // being centred against each other, and one string gets both for free.
        let text = NSStackView(views: [headerField, lineField])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        text.translatesAutoresizingMaskIntoConstraints = false
        addSubview(engineIcon)
        addSubview(mark)
        addSubview(text)

        NSLayoutConstraint.activate([
            engineIcon.centerXAnchor.constraint(equalTo: leadingAnchor, constant: Self.lane / 2),
            engineIcon.centerYAnchor.constraint(equalTo: headerField.centerYAnchor),
            engineIcon.widthAnchor.constraint(equalToConstant: Self.engineSize),
            engineIcon.heightAnchor.constraint(equalToConstant: Self.engineSize),
            mark.centerXAnchor.constraint(equalTo: leadingAnchor, constant: Self.lane / 2),
            mark.centerYAnchor.constraint(equalTo: lineField.centerYAnchor),
            text.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.lane + Self.laneGap),
            text.trailingAnchor.constraint(equalTo: trailingAnchor),
            text.topAnchor.constraint(equalTo: topAnchor),
            text.bottomAnchor.constraint(equalTo: bottomAnchor),
            headerField.widthAnchor.constraint(equalTo: text.widthAnchor),
            lineField.widthAnchor.constraint(equalTo: text.widthAnchor),
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
        lineField.isHidden = row.line.isEmpty
        mark.isHidden = row.line.isEmpty
        mark.apply(color: row.accent, pulses: row.pulses)
        if let engine = row.engine, let image = engine.iconImage {
            engineIcon.image = image
            // Shell and Copilot ship as near-black art and are templates; the
            // rest are brand marks and keep their own palettes.
            if image.isTemplate { engineIcon.contentTintColor = ShellPalette.inkTertiary }
            engineIcon.isHidden = false
        } else {
            engineIcon.isHidden = true
        }
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
/// A 1pt hairline between two stat numbers — the git tab's trio and the git
/// tile's own both separate their numbers with one.
private func hoverDivider(height: CGFloat = 30) -> NSView {
    let view = NSView()
    view.wantsLayer = true
    view.layer?.backgroundColor = ShellPalette.hairlineStrong.cgColor
    view.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
        view.widthAnchor.constraint(equalToConstant: 1),
        view.heightAnchor.constraint(equalToConstant: height),
    ])
    return view
}

/// One of the git tab's three headline numbers: the figure in the colour of
/// what it means — amber for work not committed, green for work staged, the
/// accent for work already landed — and under it the noun it counts.
final class HoverGitStatView: NSView {
    private let valueField: NSTextField
    private let captionField: NSTextField

    /// `size` is the value's own point size — 21 for the git tab's three
    /// headline stats, smaller for the KPI tile's own trio, which has a third
    /// the width to fit them in. `captionWidth`, given, lets the caption wrap
    /// onto a second line at that width instead of truncating on one — the
    /// tile's own trio needs it to fit "files changed" under a 46pt number;
    /// the git tab's three wider stats have room and leave it unset.
    init(caption: String, color: NSColor, size: CGFloat = 21, captionWidth: CGFloat? = nil) {
        valueField = ShellFont.label(font: ShellFont.ui(size, .semibold), color: color)
        captionField = ShellFont.label(caption, font: ShellFont.ui(11), color: ShellPalette.inkTertiary)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        valueField.alignment = .center
        captionField.alignment = .center
        if let captionWidth {
            captionField.usesSingleLineMode = false
            captionField.cell?.wraps = true
            captionField.lineBreakMode = .byWordWrapping
            captionField.maximumNumberOfLines = 2
            captionField.preferredMaxLayoutWidth = captionWidth
        }

        let stack = NSStackView(views: [valueField, captionField])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 1
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func apply(_ value: Int) { valueField.stringValue = "\(value)" }
    func apply(_ value: String) { valueField.stringValue = value }
}

/// One line of the git tab's commit list: hash, subject, age.
final class HoverCommitRowView: NSView {
    private let hashField = ShellFont.label(font: ShellFont.mono(11), color: ShellPalette.blue)
    private let subjectField = ShellFont.label(font: ShellFont.ui(12), color: ShellPalette.inkSecondary)
    private let ageField = ShellFont.label(font: ShellFont.ui(10), color: ShellPalette.inkTertiary)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        // The hash and the age are fixed facts; the subject is the one thing
        // long enough to need truncating, so it is the one that gives way.
        for field in [hashField, ageField] {
            field.setContentHuggingPriority(.required, for: .horizontal)
            field.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        subjectField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        ageField.alignment = .right

        let stack = NSStackView(views: [hashField, subjectField, NSView(), ageField])
        stack.orientation = .horizontal
        stack.alignment = .firstBaseline
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func apply(_ row: HoverCommitRow) {
        hashField.stringValue = row.hash
        subjectField.stringValue = row.subject
        ageField.stringValue = row.age
        setAccessibilityLabel("\(row.hash) \(row.subject), \(row.age) ago")
    }
}

/// The card's other tab: the repository the second KPI tile counts, in full.
///
/// Three numbers, the last three commits, and the one action a card of this
/// kind can honestly offer — open the review panel on what is not committed
/// yet.
final class HoverGitPanelView: NSView {
    static let maxCommits = 3

    private let changedStat = HoverGitStatView(caption: "changed", color: ShellPalette.amber)
    private let stagedStat = HoverGitStatView(caption: "staged", color: ShellPalette.green)
    private let committedStat = HoverGitStatView(caption: "committed today", color: ShellPalette.accent)
    private let caption = ShellFont.label(
        "RECENT COMMITS",
        font: ShellFont.ui(10, .semibold),
        color: ShellPalette.inkTertiary,
        tracking: 0.9
    )
    /// `↑2 ↓0` against the tracking branch, where the table's own count sits on
    /// the other tab — the same corner answering the same kind of question.
    private let trackingField = ShellFont.label(font: ShellFont.ui(10), color: ShellPalette.inkTertiary)
    private let commitViews = (0..<maxCommits).map { _ in HoverCommitRowView() }
    private let commits = NSStackView()
    private let rule = NSView()
    private let pendingField = ShellFont.label(font: ShellFont.ui(11.5), color: ShellPalette.amber)
    private let reviewButton = PaneApprovalButton(
        title: "Review",
        isPrimary: true,
        tint: ShellPalette.accent
    )

    /// What the button does. Unset — nothing can handle it — and there is no
    /// button: a card does not offer an action that goes nowhere.
    var onReview: (() -> Void)? {
        didSet {
            reviewButton.onClick = onReview
            reviewButton.isHidden = onReview == nil
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        reviewButton.isHidden = true

        let stats = NSStackView(views: [
            changedStat, hoverDivider(), stagedStat, hoverDivider(), committedStat,
        ])
        stats.orientation = .horizontal
        stats.alignment = .centerY
        stats.distribution = .fill
        stats.spacing = 10
        stagedStat.widthAnchor.constraint(equalTo: changedStat.widthAnchor).isActive = true
        committedStat.widthAnchor.constraint(equalTo: changedStat.widthAnchor).isActive = true

        trackingField.alignment = .right
        let header = NSStackView(views: [caption, NSView(), trackingField])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 6

        commits.orientation = .vertical
        commits.alignment = .leading
        commits.spacing = 7
        for view in commitViews { commits.addArrangedSubview(view) }

        rule.wantsLayer = true
        rule.layer?.backgroundColor = ShellPalette.hairlineStrong.cgColor
        rule.translatesAutoresizingMaskIntoConstraints = false

        let footer = NSStackView(views: [pendingField, NSView(), reviewButton])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 8

        let stack = NSStackView(views: [stats, header, commits, rule, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 7
        stack.setCustomSpacing(12, after: stats)
        stack.setCustomSpacing(9, after: commits)
        stack.setCustomSpacing(9, after: rule)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 11),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            rule.heightAnchor.constraint(equalToConstant: 1),
        ] + [stats, header, commits, rule, footer].map {
            $0.widthAnchor.constraint(equalTo: stack.widthAnchor)
        } + commitViews.map { $0.widthAnchor.constraint(equalTo: commits.widthAnchor) })
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    /// For tests: how many commits the list is actually showing.
    var visibleCommitCount: Int { commitViews.filter { !$0.isHidden }.count }

    func apply(_ dashboard: SessionDashboard) {
        let git = dashboard.git ?? GitDiffStat()
        changedStat.apply(git.files)
        stagedStat.apply(git.staged)
        committedStat.apply(git.committedToday)
        trackingField.stringValue = "↑\(git.ahead)  ↓\(git.behind)"

        for (index, view) in commitViews.enumerated() {
            let row = index < dashboard.commits.count ? dashboard.commits[index] : nil
            if let row { view.apply(row) }
            view.isHidden = row == nil
        }
        let empty = dashboard.commits.isEmpty
        caption.isHidden = empty
        commits.isHidden = empty

        pendingField.stringValue = git.files == 1
            ? "1 file awaiting commit"
            : "\(git.files) files awaiting commit"
    }

}

final class HoverDashboardView: NSView {
    private let panesBar = HoverPillBarView()
    private let diffBar = HoverDiffBarView()
    private let panesTile: HoverKPITileView
    private let gitTile: HoverKPITileView
    /// The git tile's own trio, sized to share a row three-up rather than the
    /// 21pt the wider git-tab body affords its own copy of the same idea.
    private let filesStat = HoverGitStatView(
        caption: "files changed", color: ShellPalette.amber, size: 14, captionWidth: 52
    )
    private let addedStat = HoverGitStatView(
        caption: "lines added", color: ShellPalette.green, size: 14, captionWidth: 52
    )
    private let removedStat = HoverGitStatView(
        caption: "lines removed", color: ShellPalette.red, size: 14, captionWidth: 52
    )
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
    private let gitPanel = HoverGitPanelView()
    /// Everything under the tiles: the working table, or the git panel — the
    /// part of the card a tab switch actually turns. A sibling of `tiles` in
    /// `stack`, not a child of it, so nothing about swapping its content ever
    /// touches the tiles above.
    private let page = NSStackView()

    /// The two tiles are the card's tabs, and what is under them is whichever
    /// one the pointer is on. Terminals to begin with — the card is opened from
    /// a session row, and the fleet is what that row is about.
    enum Tab { case terminals, git }
    private(set) var tab: Tab = .terminals

    /// Wired by the controller, and only when the window can act on it.
    var onReview: (() -> Void)? {
        get { gitPanel.onReview }
        set { gitPanel.onReview = newValue }
    }

    override init(frame frameRect: NSRect) {
        // The tile's own trio — files changed, lines added, lines removed —
        // three peers in a row with a hairline between each, the bar that
        // draws their ratio underneath. `.fillEqually` on just the three
        // numbers is what actually guarantees each one its third of the row:
        // `.fill` sizes every arranged view to its own content first and only
        // hands out leftover space after, which is how a two-line caption
        // this tight on room ends up narrower than the room it had. The
        // hairlines sit outside that arrangement, centred in the gaps.
        let stats = NSStackView(views: [filesStat, addedStat, removedStat])
        stats.orientation = .horizontal
        stats.distribution = .fillEqually
        stats.spacing = 8
        let filesGap = hoverDivider(height: 36)
        let addedGap = hoverDivider(height: 36)
        stats.addSubview(filesGap)
        stats.addSubview(addedGap)
        NSLayoutConstraint.activate([
            filesGap.centerXAnchor.constraint(equalTo: filesStat.trailingAnchor, constant: 4),
            filesGap.centerYAnchor.constraint(equalTo: stats.centerYAnchor),
            addedGap.centerXAnchor.constraint(equalTo: addedStat.trailingAnchor, constant: 4),
            addedGap.centerYAnchor.constraint(equalTo: stats.centerYAnchor),
        ])
        let gitAccessory = NSStackView(views: [stats, diffBar])
        gitAccessory.orientation = .vertical
        gitAccessory.alignment = .leading
        gitAccessory.spacing = 6

        panesTile = HoverKPITileView(caption: "Terminals", accessory: panesBar)
        // No title, no headline: three labelled numbers already say what this
        // tile is, and "Files changed" above them would just repeat the first.
        gitTile = HoverKPITileView(
            caption: "Files changed",
            accessory: gitAccessory,
            showsHeadline: false,
            showsCaption: false
        )
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

        page.orientation = .vertical
        page.alignment = .leading
        page.spacing = 6
        for view in [tableHeader, rows, gitPanel] { page.addArrangedSubview(view) }

        let stack = NSStackView(views: [tiles, page])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.setCustomSpacing(11, after: tiles)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        // Which tile the pointer is on is which tab is showing. Selecting on
        // the way in only: there is no "off the tiles" state, because leaving
        // them for the table below must not throw the tab away.
        panesTile.onHover = { [weak self] in self?.select(.terminals) }
        gitTile.onHover = { [weak self] in self?.select(.git) }
        panesTile.setSelected(true)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            tiles.widthAnchor.constraint(equalTo: stack.widthAnchor),
            page.widthAnchor.constraint(equalTo: stack.widthAnchor),
            tableHeader.widthAnchor.constraint(equalTo: page.widthAnchor),
            rows.widthAnchor.constraint(equalTo: page.widthAnchor),
            gitPanel.widthAnchor.constraint(equalTo: page.widthAnchor),
            stats.widthAnchor.constraint(equalTo: gitAccessory.widthAnchor),
            diffBar.widthAnchor.constraint(equalTo: gitAccessory.widthAnchor),
        ] + rowViews.map { $0.widthAnchor.constraint(equalTo: rows.widthAnchor) })
    }

    /// Fired right after a tab switch changes what `page` shows, so the
    /// panel can resize to fit it in the same beat as the fade below rather
    /// than waiting on whichever quarter-second tick lands next — a resize
    /// that arrives late reads as the whole card catching up, tiles included,
    /// since the tiles sit inside the same window being resized.
    var onTabSwitch: (() -> Void)?

    /// Switches tab. This used to hand `page`'s own layer a `CATransition`
    /// push — technically scoped to just that layer, but a real Liquid Glass
    /// card samples and refracts its *whole* surface live, so an explicit
    /// layer transition anywhere inside it made the entire card visibly
    /// recomposite, tiles included, not just the part actually changing. A
    /// plain alpha fade is what `setHidden` already uses for a row within
    /// the same tab, with no such flicker — reusing it here, through the
    /// same `animated: true` path, is what makes this tab switch trustworthy
    /// rather than novel.
    func select(_ next: Tab) {
        guard tab != next, !(next == .git && gitTile.isHidden) else { return }
        let goingToGit = next == .git
        tab = next
        panesTile.setSelected(!goingToGit)
        gitTile.setSelected(goingToGit)
        guard let dashboard else { return }
        syncPage(dashboard, animated: true)
        onTabSwitch?()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    /// For tests: which rows the table is actually showing.
    var visibleRowCount: Int { rowViews.filter { !$0.isHidden }.count }
    /// For tests: the git tab, when it is the one showing.
    var visibleGitPanel: HoverGitPanelView? { gitPanel.isHidden ? nil : gitPanel }

    /// The last dashboard drawn, so a tab switch can redraw without waiting
    /// for the next tick to hand one over.
    private var dashboard: SessionDashboard?

    func apply(_ dashboard: SessionDashboard, animated: Bool) {
        self.dashboard = dashboard
        panesTile.apply(
            value: "\(dashboard.working)",
            label: dashboard.mix.isEmpty ? "working" : "working · \(dashboard.mix)",
            hint: "of \(dashboard.capacity) max"
        )
        panesBar.apply(pills: dashboard.pills, capacity: dashboard.capacity)

        if let git = dashboard.git {
            gitTile.isHidden = false
            filesStat.apply(git.files)
            addedStat.apply("+\(git.added)")
            // A real minus sign, not a hyphen: it sits beside a `+` at the same
            // optical weight, which a hyphen does not.
            removedStat.apply("\u{2212}\(git.removed)")
            diffBar.apply(added: git.added, removed: git.removed)
        } else {
            gitTile.isHidden = true
            // A clean tree has no tile, and a tab with no handle is a trap.
            if tab == .git { select(.terminals) }
        }

        let count = dashboard.rows.count
        tableCount.stringValue = count == 1 ? "1 agent" : "\(count) agents"
        for (index, view) in rowViews.enumerated() {
            if index < count { view.apply(dashboard.rows[index]) }
            let hidden = index >= count
            guard view.isHidden != hidden else { continue }
            setHidden(view, hidden, animated: animated)
        }

        gitPanel.apply(dashboard)
        syncPage(dashboard, animated: animated)
    }

    /// Which half of `page` is showing: the table, when there is one and the
    /// tab is on it; the git panel, when the tab is on that; otherwise
    /// neither. Called on every tick, where `animated` only fades a row that
    /// actually gained or lost content, and from `select`, where the tab
    /// itself just changed and the whole swap fades.
    private func syncPage(_ dashboard: SessionDashboard, animated: Bool) {
        let showsTable = !dashboard.rows.isEmpty && tab == .terminals
        setHidden(tableHeader, !showsTable, animated: animated)
        setHidden(rows, !showsTable, animated: animated)
        setHidden(gitPanel, tab != .git, animated: animated)
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
    ///
    /// `translatesAutoresizingMaskIntoConstraints` is on so `HoverCardShellView`
    /// can fill its host the old-fashioned way — which means AppKit is also
    /// holding a `.required` constraint pinning this view's height to
    /// whatever it was last measured at. Asking `fittingSize` "how tall do
    /// you want to be" while still pinned to yesterday's answer is a
    /// contradiction the moment the dashboard grows: the engine cannot
    /// satisfy both, breaks a stack spacing constraint to cope, and on a bad
    /// day produces NaN geometry instead (crash: "Invalid view geometry: y
    /// is NaN"). Lifting the pin for the one measurement that exists to
    /// answer it, then restoring it, removes the contradiction rather than
    /// surviving it.
    ///
    /// ponytail (2026-08-26): `layoutSubtreeIfNeeded()` was removed from here
    /// for one build, suspecting it as the reentrant trigger of the
    /// "Invalid view geometry: y is NaN" crash inside `NSGlassEffectView.layout()`
    /// — it wasn't: the crash recurred anyway via a second, unrelated path
    /// (an active `NSAnimationContext.runAnimationGroup` elsewhere), and
    /// removing it silently broke this card's actual content instead:
    /// `fittingSize` alone computes the *ideal* size without applying it back
    /// through the stack view's constraints, so every descendant stayed
    /// zero-framed (confirmed live: `_subtreeDescription` showed the whole
    /// content tree at `f=(0,0,0,0)`) while this view's own frame looked
    /// fine. Restored now that `CommandPaletteController.glassEnabled` is
    /// `false` — `NSGlassEffectView.layout()` (the actual crash site) no
    /// longer runs at all, so the forced relayout this call performs is back
    /// to being ordinary, safe AppKit usage.
    var cardSize: NSSize {
        translatesAutoresizingMaskIntoConstraints = false
        layoutSubtreeIfNeeded()
        let height = max(fittingSize.height, 44)
        frame.size = NSSize(width: currentWidth, height: height)
        translatesAutoresizingMaskIntoConstraints = true
        return frame.size
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

        if #available(macOS 26.0, *), CommandPaletteController.glassEnabled {
            // Framed, not the parameterless initializer: `NSGlassEffectView`
            // defaults to `.zero` like any other view, and — since nothing
            // here ever turns off `translatesAutoresizingMaskIntoConstraints`
            // — a `.zero` frame is a `.required` `height == 0` constraint
            // AppKit holds until the first real `card.frame = …` in
            // `layout()`. `contentView = body` pins `body`'s edges to this
            // view's with constraints of its own regardless, so that
            // `.required` zero was reaching every stack and text field
            // inside `body` before this view was ever placed — "Unable to
            // simultaneously satisfy constraints", and on a bad day NaN
            // geometry instead (crash: "Invalid view geometry: y is NaN").
            // Seeding the same starting size the pre-26 fallback already
            // uses below removes the contradiction instead of surviving it.
            let glass = NSGlassEffectView(
                frame: NSRect(origin: .zero, size: NSSize(width: HoverCardBodyView.width, height: 120))
            )
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

    /// The floor `layout()` holds `card`'s size to. Set by `cardSize`, which
    /// the controller always calls right before starting an animated
    /// resize — but the animation itself then drives `card`'s size (and,
    /// through `NSGlassEffectView.contentView`'s own `.required` pin,
    /// `body`'s) through every intermediate value between the old frame and
    /// the new one, once per tick, not just the two endpoints. Any tick that
    /// lands smaller than `body`'s real content needs is the same
    /// contradiction `HoverCardBodyView.cardSize`'s fix removes for a single
    /// synchronous measurement — except this one recurs live, inside
    /// `+[NSAnimationManager performAnimations:]`, at 60–120 times a second,
    /// which is where a broken stack constraint stops being the recovery
    /// and NaN geometry starts being the crash (EXC_BREAKPOINT, "Invalid
    /// view geometry: y is NaN" — the bug this fixes). `layout()` never
    /// lets `card` answer a tick with less than this, whatever `bounds`
    /// says: a card bigger than `bounds` for a few frames of a 120–200ms
    /// transition reads as nothing; one that traps does not.
    private var minimumCardSize = NSSize(width: HoverCardBodyView.width, height: 120)

    override func layout() {
        super.layout()
        host.frame = bounds
        wrapper.frame = bounds
        card.frame = NSRect(
            x: Self.lane,
            y: 0,
            width: max(max(0, bounds.width - Self.lane), minimumCardSize.width),
            height: max(bounds.height, minimumCardSize.height)
        )
        dropBox.frame = dropFrame(centerY: dropCenterY)
    }

    /// `body`'s natural size, asked before this view's own frame has any
    /// reason to already be the right shape — the controller calls this to
    /// *decide* that shape, and every call also refreshes the floor
    /// `layout()` holds `card` to for whatever animation follows.
    ///
    /// On macOS 26, `NSGlassEffectView.contentView` pins `body`'s edges to
    /// `card`'s with its own `.required` constraints, permanently — so
    /// measuring while `card` is still sized for the *previous* card fights
    /// the new content the same way `body`'s own stale mask constraint used
    /// to (`HoverCardBodyView.cardSize`'s fix does not reach this one: the
    /// pin belongs to `card`, not to `body`). Widening `card` first, the way
    /// that fix widens `body`, gives the measurement room instead of a fight.
    var cardSize: NSSize {
        let previous = card.frame
        card.frame.size.height = 10_000
        let size = body.cardSize
        card.frame = previous
        minimumCardSize = size
        return size
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
/// It takes the mouse, because the card is a dashboard now and its two KPI
/// tiles are tabs: the pointer has to be able to reach them. So leaving the
/// row no longer closes it — the pointer is given `closeGrace` to arrive on
/// the card, and only when it is on neither does the card fade. Hovering
/// another row, or a click anywhere else, still closes it at once: the grace
/// is for a pointer on its way to the card, not for one that has moved on.
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
    /// What the git tab's Review button does. Unset — the window has nothing
    /// to show — and the card does not draw the button at all.
    var onReview: ((Target) -> Void)?

    /// Barely a delay at all — enough to keep a pointer crossing the list from
    /// firing a card per row, and no more. Anything longer reads as the card
    /// deciding whether to come.
    static let openDelay: TimeInterval = 0.12
    static let tickInterval: TimeInterval = 0.1
    /// How long the pointer may be on neither the row nor the card before the
    /// card goes — one second, enough to cross the gap between them without
    /// hurrying. Hovering a different row does not wait on this at all: that
    /// is `hover` calling `present()` straight away, below.
    static let closeGrace: TimeInterval = 1
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
    /// When the pointer left both the row and the card, and `nil` while it is
    /// on one of them. The grace runs from here.
    private var leftAt: TimeInterval?
    private var clickMonitor: Any?
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
        panel.ignoresMouseEvents = false
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.transient, .ignoresCycle]
        // Always on top: a child window alone only outranks its own parent,
        // and the card has to clear whatever else the app has floating —
        // same level `CommandPaletteController` uses for the same reason.
        panel.level = .floating
        panel.contentView = shell
        // A tab switch changes `page`'s height; the panel has to catch up in
        // the same beat as the fade, not on whichever tick lands next — a
        // resize arriving up to a tenth of a second late reads as the whole
        // card catching up around the fade rather than growing with it.
        shell.body.dashboardView.onTabSwitch = { [weak self] in self?.resizeToFitContent() }
    }

    deinit {
        openTimer?.invalidate()
        tickTimer?.invalidate()
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
    }

    /// The pointer entered a row, or left one (`nil`).
    func hover(_ next: Target?, in parent: NSWindow?) {
        self.parent = parent
        guard let next else {
            openTimer?.invalidate()
            openTimer = nil
            // An open card is not dismissed here any more: the pointer may be
            // on its way *onto* it, and the row it came from reports that as
            // having left. The tick, which can see where the pointer actually
            // is, decides — see `closeGrace`.
            if !isOpen { dismiss() }
            return
        }
        guard next != target || !isOpen else { return }
        // A different row: that is the pointer having moved on, not a pointer
        // in transit, and the old card goes now rather than in three seconds.
        leftAt = nil
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

    /// `fade` is longer on the way out of the grace than on the way off a row:
    /// a card that timed out should look like it faded, and one the pointer
    /// walked away from should already be gone.
    func dismiss(fade: TimeInterval = 0.09) {
        openTimer?.invalidate()
        openTimer = nil
        tickTimer?.invalidate()
        tickTimer = nil
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        leftAt = nil
        target = nil
        guard panel.isVisible else { return }
        let panel = panel
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = ShellMotion.reduced ? 0 : fade
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
        if let onReview, case .session = target {
            // Clicking it is a decision: the card has done its job and gets
            // out of the way of whatever it just opened.
            body.dashboardView.onReview = { [weak self] in
                self?.dismiss()
                onReview(target)
            }
        } else {
            body.dashboardView.onReview = nil
        }
        let size = Self.panelSize(card: shell.cardSize)
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
        // A click anywhere but on the card ends it now — the pointer is doing
        // something else, and no grace applies to that. Local only: a click in
        // another app takes the whole window's attention, and the card goes
        // with the window.
        if clickMonitor == nil {
            clickMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
            ) { [weak self] event in
                guard let self, self.isOpen, event.window !== self.panel else { return event }
                self.dismiss()
                return event
            }
        }
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
        // sends one, and the card would be stranded on screen. The card counts
        // as well as the row now — resting on it is what the tabs are for.
        let pointer = NSEvent.mouseLocation
        if row.contains(pointer) || panel.frame.contains(pointer) {
            leftAt = nil
        } else {
            let now = Date().timeIntervalSince1970
            let since = leftAt ?? now
            leftAt = since
            if now - since >= Self.closeGrace {
                dismiss(fade: 0.35)
                return
            }
        }
        body.apply(model)
        resizeToFitContent()
    }

    /// Resizes (and repositions) the panel to whatever `shell` currently
    /// wants to be. Shared by the periodic tick — where a pane started or
    /// stopped working and the table gained or lost a row — and by a tab
    /// switch's `onTabSwitch`, which needs this in the same beat as its own
    /// fade rather than on whichever tick lands next. A move with no resize
    /// is just the row scrolling under the card, and animating that lags.
    private func resizeToFitContent() {
        guard let target, let parent, let row = rowFrame?(target) else { return }
        let frame = Self.frame(size: Self.panelSize(card: shell.cardSize), row: row, container: parent.frame)
        guard !frame.equalTo(panel.frame) else { return }
        if ShellMotion.reduced || frame.size.equalTo(panel.frame.size) {
            panel.setFrame(frame, display: true)
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 0.85, 0.25, 1)
                panel.animator().setFrame(frame, display: true)
            }
        }
        // The row moves under the card as the sidebar reloads; the drop keeps
        // pointing at it.
        let centerY = row.midY - frame.minY
        if abs(centerY - shell.dropCenterY) > 0.5 { shell.pointDrop(at: centerY, animated: true) }
    }
}
