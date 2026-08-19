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
    /// `42 tool runs · 18m active`.
    var totals: String?
    /// The live output line. `nil` for anything that is not a terminal.
    var tail: String?

    /// How much of the output line the card shows. The ask was the beginning
    /// of the line and an ellipsis, not the line.
    static let tailLimit = 38
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
                tail: tail.flatMap { snippet($0) }
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

    /// `42 tool runs · 18m active`. Deliberately not tokens: nothing in the
    /// native app counts them (`UsageAnalytics.recordTokens` is ported but
    /// never called, and its buckets are per project), and a number the app
    /// cannot actually know is worse than no number.
    static func totalsLine(_ activity: PaneActivity?, now: Double) -> String? {
        guard let activity else { return nil }
        var parts: [String] = []
        if activity.toolRuns > 0 { parts.append(count(activity.toolRuns, "tool run")) }
        let active = activity.activeMs(now: now)
        if active >= 1000 { parts.append("\(coarseDuration(active)) active") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
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

    /// The same span with the seconds dropped — for totals, where a ticking
    /// second on a number nobody is timing is just noise.
    static func coarseDuration(_ ms: Double) -> String {
        let total = Int(max(0, ms) / 1000)
        if total >= 3600 { return String(format: "%dh %02dm", total / 3600, (total % 3600) / 60) }
        if total >= 60 { return "\(total / 60)m" }
        return "\(total)s"
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

    /// Off under Reduce Motion and in tests: the text lands whole.
    var animates = true

    private var goal = ""
    private var shown = ""
    private var timer: Timer?
    private var caretTimer: Timer?
    private let caret = CALayer()

    init(font: NSFont, color: NSColor) {
        super.init(frame: .zero)
        isEditable = false
        isBordered = false
        isSelectable = false
        drawsBackground = false
        usesSingleLineMode = true
        cell?.wraps = false
        cell?.truncatesLastVisibleLine = true
        lineBreakMode = .byTruncatingTail
        self.font = font
        textColor = color
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
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
        render()
        startTyping()
    }

    /// Drops what is on screen without animating — used when the card swaps to
    /// a different row, where continuing to type would splice two panes'
    /// output into one sentence.
    func reset() {
        stop()
        goal = ""
        shown = ""
        caret.opacity = 0
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
        guard let font else { return }
        let width = (shown as NSString).size(withAttributes: [.font: font]).width
        let height = ceil(font.ascender - font.descender)
        // Never past the right edge: a truncated line has nowhere left to put
        // a caret, and one sitting outside the card would look like a bug.
        let x = min(width + 2, max(0, bounds.width - 2))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        caret.frame = NSRect(x: x, y: (bounds.height - height) / 2, width: 1.5, height: height)
        CATransaction.commit()
    }
}

// MARK: - The card's body

/// A small filled circle in the status colour, glowing and pulsing exactly the
/// way the sidebar row's own mark does.
final class HoverStatusDot: NSView {
    private var color: NSColor = ShellPalette.idle

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 7, height: 7))
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        layer?.cornerRadius = 3.5
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 7),
            heightAnchor.constraint(equalToConstant: 7),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func apply(color: NSColor, pulses: Bool) {
        self.color = color
        layer?.backgroundColor = color.cgColor
        layer?.shadowColor = color.cgColor
        layer?.shadowOpacity = 0.55
        layer?.shadowRadius = 4
        layer?.shadowOffset = .zero
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

    let dot = HoverStatusDot()
    let statusField = ShellFont.label(font: ShellFont.ui(11.5, .semibold), color: ShellPalette.inkSecondary)
    let titleField = ShellFont.label(font: ShellFont.ui(15, .semibold), color: ShellPalette.ink)
    let metaField = ShellFont.label(font: ShellFont.ui(11.5), color: ShellPalette.inkMuted)
    let timingField = ShellFont.label(font: ShellFont.ui(11.5), color: ShellPalette.inkTertiary)
    let totalsField = ShellFont.label(font: ShellFont.ui(11.5), color: ShellPalette.inkFaint)
    let tailField = TypingTextField(font: ShellFont.mono(11.5), color: ShellPalette.inkSecondary)
    let engineIcon = NSImageView()
    private let rule = NSView()
    private let stack = NSStackView()

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 120))
        wantsLayer = true

        engineIcon.translatesAutoresizingMaskIntoConstraints = false
        engineIcon.imageScaling = .scaleProportionallyUpOrDown

        let header = NSStackView(views: [dot, statusField, NSView(), engineIcon])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 6
        header.translatesAutoresizingMaskIntoConstraints = false

        rule.wantsLayer = true
        rule.layer?.backgroundColor = ShellPalette.hairlineStrong.cgColor
        rule.translatesAutoresizingMaskIntoConstraints = false

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.translatesAutoresizingMaskIntoConstraints = false
        for view in [header, titleField, metaField, timingField, totalsField, rule, tailField] {
            stack.addArrangedSubview(view)
        }
        stack.setCustomSpacing(9, after: header)
        stack.setCustomSpacing(9, after: totalsField)
        stack.setCustomSpacing(8, after: rule)
        addSubview(stack)

        let content = Self.width - Self.inset * 2
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
            titleField.widthAnchor.constraint(equalToConstant: content),
            metaField.widthAnchor.constraint(equalToConstant: content),
            timingField.widthAnchor.constraint(equalToConstant: content),
            totalsField.widthAnchor.constraint(equalToConstant: content),
            tailField.widthAnchor.constraint(equalToConstant: content),
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

        dot.apply(color: model.accent, pulses: model.pulses)
        statusField.stringValue = model.status.uppercased()
        statusField.textColor = model.accent
        titleField.stringValue = model.title

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

        if let tail = model.tail {
            rule.isHidden = false
            tailField.isHidden = false
            // A different row is a different sentence: continuing the type
            // would splice two panes' output together.
            if !sameRow { tailField.reset() }
            tailField.setLine(tail)
        } else {
            rule.isHidden = true
            tailField.isHidden = true
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

    /// Long enough that running the pointer down the list does not strobe
    /// cards, short enough to feel like it was already there.
    static let openDelay: TimeInterval = 0.35
    static let tickInterval: TimeInterval = 0.1
    /// Between the row's right edge and the card.
    static let gap: CGFloat = 12
    static let cornerRadius: CGFloat = 16
    /// How far the card slides in, and back out.
    static let slide: CGFloat = 6

    private(set) var target: Target?
    private let body = HoverCardBodyView()
    private let panel: NSPanel
    private let tint = CAGradientLayer()
    private var openTimer: Timer?
    private var tickTimer: Timer?
    private weak var parent: NSWindow?

    var isOpen: Bool { panel.isVisible }
    /// For tests: what the card is currently showing.
    var shownModel: HoverCardModel? { body.model }

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: HoverCardBodyView.width, height: 120),
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

        // The palette's treatment: the system material, with a slight navy
        // gradient over it — a flat wash reads as paint, a gradient as glass.
        body.wantsLayer = true
        tint.colors = [
            NSColor(srgbRed: 0.09, green: 0.10, blue: 0.16, alpha: 0.55).cgColor,
            NSColor(srgbRed: 0.05, green: 0.05, blue: 0.09, alpha: 0.42).cgColor,
        ]
        tint.startPoint = CGPoint(x: 0.1, y: 1)
        tint.endPoint = CGPoint(x: 0.9, y: 0)
        tint.cornerRadius = Self.cornerRadius
        tint.frame = body.bounds
        tint.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        body.layer?.insertSublayer(tint, at: 0)
        body.autoresizingMask = [.width, .height]

        let glass = CommandPaletteController.glassHost(
            body,
            size: NSSize(width: HoverCardBodyView.width, height: 120),
            cornerRadius: Self.cornerRadius
        )
        panel.contentView = glass
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

    /// Where the card goes: top-aligned with its row, just off the sidebar's
    /// edge, and always fully inside the window.
    static func frame(size: NSSize, row: NSRect, container: NSRect) -> NSRect {
        var origin = NSPoint(x: row.maxX + gap, y: row.maxY + 6 - size.height)
        origin.x = min(origin.x, container.maxX - size.width - 8)
        origin.x = max(origin.x, container.minX + 8)
        origin.y = min(origin.y, container.maxY - size.height - 8)
        origin.y = max(origin.y, container.minY + 8)
        return NSRect(origin: origin, size: size)
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
        let size = body.cardSize
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
        let frame = Self.frame(size: body.cardSize, row: row, container: parent.frame)
        if !frame.equalTo(panel.frame) { panel.setFrame(frame, display: true) }
    }
}
