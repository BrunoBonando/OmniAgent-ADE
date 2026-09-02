import AppKit

// The host's takeover panel (2026-09-01 remote environment sharing spec §7):
// what the person sitting at this Mac sees for exactly as long as somebody
// else is driving it.
//
// The promise the whole feature rests on is that a takeover is never quiet.
// So this is a screen-covering sheet of glass above the workspace window,
// with **no dismiss and no minimize** — while someone is connected, the panel
// is the app. ⌘Q still quits, and quitting ends sharing (the last local
// connection goes, the daemon's control channel closes after its grace, and
// the viewer drops).
//
// The workspace window stays *visible* behind it, dimmed rather than hidden:
// the host watches their own terminals update while somebody else types into
// them, which is the difference between "a stranger is on my Mac" and
// "I can see exactly what is being done".

/// What the panel needs from the daemon connection, and nothing else — the
/// `SettingsClient` seam's shape, for the same reason: a kick is a write to
/// another Mac's connection and no test may send one down a live socket.
protocol RemoteViewerDisconnecting: AnyObject {
    func disconnectViewer(
        viewerID: String,
        block: Bool,
        completion: ((Result<Void, Error>) -> Void)?
    )
}

extension SessionConnection: RemoteViewerDisconnecting {}

/// One machine driving this Mac, as the host's panel shows it.
///
/// **Two kinds of fact, deliberately not merged.** `machineName` and the app
/// and OS inside `client` are what the connecting side says about itself;
/// `accountEmail`, `ip` and `country` are what the relay and Cloudflare
/// asserted about the connection (spec §9), which nobody on the far end can
/// choose. The panel marks the second kind and leaves the first unmarked — a
/// trust panel that cannot tell them apart is worse than no panel — so the
/// distinction has to survive into this type rather than being flattened
/// into six strings.
///
/// Every asserted field is optional because the relay sends what it knows and
/// invents nothing ("City is omitted, not faked"). A `nil` is a row the panel
/// leaves out entirely, never a row drawn blank.
struct RemoteConnectionInfo: Equatable {
    /// The viewer id the daemon keys its roster and its blocklist on —
    /// self-reported, but stable across launches, and what `Terminate` and
    /// `Block` name. Not shown; the machine name is what a human reads.
    let viewerID: String
    /// Self-reported, from the viewer's `Hello`.
    let machineName: String
    /// Relay-asserted: the account the viewer's JWT is signed in as.
    let accountEmail: String?
    /// Relay-asserted: `CF-Connecting-IP` at Cloudflare's edge.
    let ip: String?
    /// Relay-asserted: `CF-IPCountry`, same.
    let country: String?
    /// The viewer app's user agent as the relay saw it —
    /// `"OmniAgent/1.7.22 macOS 27.0"`. Relayed, but chosen by the client,
    /// so what it carries is shown **unmarked**.
    let client: String?
    /// When the daemon accepted the connection — its own observation, not
    /// anybody's claim.
    let since: Date
    /// Whether the viewer has attached to a session yet. The one honest
    /// signal available for the header's state line: the daemon witnesses the
    /// `Attach`, and until one arrives the far end is still loading the
    /// environment (the viewer's own ceremony step 4).
    let isAttached: Bool

    /// The roster row the daemon pushes, as the panel needs it. `since`
    /// falls back to *now* rather than to a wrong date: an unparseable
    /// timestamp is a daemon/app skew, and "just now" is the least wrong
    /// thing to say about a connection that certainly exists.
    init(viewer: RemoteViewer) {
        viewerID = viewer.viewerID
        machineName = viewer.machineName
        accountEmail = Self.trimmedOrNil(viewer.accountEmail)
        ip = Self.trimmedOrNil(viewer.ip)
        country = Self.trimmedOrNil(viewer.country)
        client = Self.trimmedOrNil(viewer.client)
        since = Self.rfc3339.date(from: viewer.since) ?? Date()
        isAttached = !viewer.sessions.isEmpty
    }

    init(
        viewerID: String,
        machineName: String,
        accountEmail: String?,
        ip: String?,
        country: String?,
        client: String?,
        since: Date,
        isAttached: Bool
    ) {
        self.viewerID = viewerID
        self.machineName = machineName
        self.accountEmail = accountEmail
        self.ip = ip
        self.country = country
        self.client = client
        self.since = since
        self.isAttached = isAttached
    }

    /// `""` is not a value. A relay that sent an empty string said nothing,
    /// and the panel must omit that row rather than draw an empty one.
    private static func trimmedOrNil(_ raw: String?) -> String? {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static let rfc3339: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}

/// The panel: a borderless, screen-covering window and the glass inside it.
///
/// Not an `NSWindowController` and not a sheet. A sheet hangs off the
/// workspace window and can be dismissed; this cannot be dismissed at all,
/// and it has to sit *above* the window it dims rather than inside it, so
/// terminals keep drawing behind the glass.
@MainActor
final class RemoteTakeoverPanel {
    /// The rows of the identity grid, in the order they are drawn.
    ///
    /// `CaseIterable` so the grid is built off the list rather than off six
    /// hand-written call sites — a seventh fact appears by being added here.
    enum RowKind: CaseIterable {
        case machineName
        case account
        case ip
        case country
        case appVersion
        case os
        case since

        /// The left column.
        var label: String {
            switch self {
            case .machineName: return "Machine"
            case .account: return "Account"
            case .ip: return "IP address"
            case .country: return "Country"
            case .appVersion: return "App"
            case .os: return "OS"
            case .since: return "Connected"
            }
        }

        /// Whether the relay asserted this field — the *only* thing the
        /// verified glyph means.
        ///
        /// `account`, `ip` and `country` are the three the far end cannot
        /// choose: a JWT the relay verified, and two headers Cloudflare sets
        /// at the edge. `machineName` comes out of the viewer's own `Hello`;
        /// `appVersion`/`os` come out of a user agent the client wrote, which
        /// the relay passed on without checking. `since` is the daemon's own
        /// observation — truer than any of them, and still not a relay
        /// assertion, so it wears nothing either.
        var isRelayAsserted: Bool {
            switch self {
            case .account, .ip, .country: return true
            case .machineName, .appVersion, .os, .since: return false
            }
        }
    }

    /// One rendered row. Only rows with a value exist at all.
    struct Row: Equatable {
        let kind: RowKind
        let value: String
        var label: String { kind.label }
        var isVerified: Bool { kind.isRelayAsserted }
    }

    /// The header's two states (spec §7). Not a progress animation: the
    /// second one is reached when the far end actually attaches to a session.
    enum State: Equatable {
        case settingUp
        case connected

        var line: String {
            switch self {
            case .settingUp: return "Setting up connection…"
            case .connected: return "Connected"
            }
        }
    }

    let window: NSWindow
    let view: RemoteTakeoverPanelView
    /// This connection's daemon-witnessed activity (spec §8, Task 19/20) —
    /// owned here rather than by whoever presents the panel, so it resets
    /// naturally with every new connection: a fresh `RemoteTakeoverPanel` is
    /// built per connection (`WorkspaceWindowController.syncTakeoverPanel`),
    /// and a fresh log with it.
    let activityLog = RemoteActivityLog()
    private(set) var info: RemoteConnectionInfo
    /// `nil` in a test that only inspects the layout. A kick with no
    /// connection is a no-op, never a crash.
    private weak var connection: RemoteViewerDisconnecting?
    /// A failed Terminate/Block, for anyone who wants to know beyond the
    /// panel itself.
    ///
    /// **The panel is what reports the failure**, in its own red line — see
    /// `disconnect(block:)`. It cannot be the house glass ask card, which
    /// `presentWindowAsk` mounts on the workspace window's content view,
    /// *behind* this window. So this is an extra hook and not the mechanism;
    /// production leaves it unset, and nothing is swallowed when it is.
    var onActionFailed: ((Error) -> Void)?
    /// A Block that landed. The daemon writes `remote_control_blocked`
    /// itself, so the app's copy of that row is stale until it re-reads.
    var onBlocked: (() -> Void)?

    init(info: RemoteConnectionInfo, connection: RemoteViewerDisconnecting?) {
        self.info = info
        self.connection = connection
        view = RemoteTakeoverPanelView()
        window = RemoteTakeoverWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        // Everything here is one half of "no dismiss and no minimize".
        // `.borderless` is what removes `.closable`/`.miniaturizable` — there
        // is no button to press — and the rest stops the window from being
        // dragged aside, hidden behind the workspace, or released out from
        // under its owner.
        window.isMovable = false
        window.isMovableByWindowBackground = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        // Above the workspace window and every panel in it, below nothing the
        // user needs: the takeover is the app while it is up.
        window.level = .modalPanel
        window.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.setAccessibilityLabel("Remote takeover")
        view.onTerminate = { [weak self] in self?.terminate() }
        view.onBlock = { [weak self] in self?.block() }
        view.apply(state: state, machineName: info.machineName, rows: rows, info: info)
    }

    /// Every row that has a value, in `RowKind.allCases` order. A row whose
    /// value is `nil` is not in the list at all — the panel never draws a
    /// labelled blank, which would read as "the relay says this is empty"
    /// rather than "nobody said".
    var rows: [Row] {
        RowKind.allCases.compactMap { kind in
            value(for: kind).map { Row(kind: kind, value: $0) }
        }
    }

    /// One row, or `nil` when there is nothing to say.
    func row(for kind: RowKind) -> Row? {
        value(for: kind).map { Row(kind: kind, value: $0) }
    }

    var state: State { info.isAttached ? .connected : .settingUp }

    /// Sizes the panel to `host`'s screen and puts it up. The host window is
    /// deliberately left exactly where it is — visible, dimmed through the
    /// glass — rather than hidden or ordered out.
    func present(over host: NSWindow?) {
        let frame = host?.screen?.frame ?? NSScreen.main?.frame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        window.setFrame(frame, display: true)
        view.frame = NSRect(origin: .zero, size: frame.size)
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func dismiss() {
        // The spotlight parents its scrim to whichever window it opened over
        // (`WorkspaceWindowController.paletteParentWindow`), and a child
        // window is ordered out with its parent. Letting go first means a
        // palette that outlives the panel comes back on the workspace window
        // rather than disappearing with this one.
        for child in window.childWindows ?? [] {
            window.removeChildWindow(child)
        }
        window.orderOut(nil)
    }

    /// A newer roster for the same machine — the state line advancing, or an
    /// asserted field the relay filled in a moment later.
    func apply(_ info: RemoteConnectionInfo) {
        guard info != self.info else { return }
        self.info = info
        view.apply(state: state, machineName: info.machineName, rows: rows, info: info)
    }

    /// One `RemoteActivity` push's worth of rows (Task 19/20, spec §8) —
    /// appended to `activityLog` and handed straight to the table view as
    /// only the new rows (fix round 1, IMPORTANT 3: the view appends, it
    /// does not rebuild from the whole accumulated log every time), which
    /// holds scroll position steady unless it was already at the bottom and
    /// leaves every already-expanded row exactly as it was.
    func appendActivity(_ entries: [RemoteActivityLog.Entry]) {
        activityLog.append(entries)
        view.appendActivity(entries)
    }

    // MARK: - The two verbs (spec §7)

    /// **Terminate** — drop this connection and leave sharing on. The machine
    /// may dial straight back; that is the difference from `block()`, and the
    /// footer copy says so.
    ///
    /// The panel is *not* torn down here. It goes when the daemon's roster
    /// says the connection is gone, which is the only thing that makes it
    /// true — closing on the click would tell the host "they are off your
    /// Mac" while a failed kick left them on it.
    func terminate() {
        disconnect(block: false)
    }

    /// **Block** — the same kick, plus the viewer id appended to the daemon's
    /// `remote_control_blocked` row, so the next `Hello` from that machine is
    /// refused until someone unblocks it in Settings › Remote. The daemon
    /// writes that row (it has to hold with the app closed); the app only
    /// ever removes from it.
    func block() {
        disconnect(block: true)
    }

    private func disconnect(block: Bool) {
        connection?.disconnectViewer(viewerID: info.viewerID, block: block) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                if block { onBlocked?() }
            case let .failure(error):
                // Said on the panel itself, whether or not anyone else is
                // listening: a security surface must never let "nothing
                // happened" look like "done".
                view.showFailure(
                    "Could not \(block ? "block" : "disconnect") "
                        + "\(info.machineName): \(error.localizedDescription)"
                )
                onActionFailed?(error)
            }
        }
    }

    // MARK: - Values

    private func value(for kind: RowKind) -> String? {
        switch kind {
        case .machineName:
            return info.machineName.isEmpty ? nil : info.machineName
        case .account:
            return info.accountEmail
        case .ip:
            return info.ip
        case .country:
            return info.country.map(Self.countryName)
        case .appVersion:
            return Self.appVersion(fromUserAgent: info.client)
        case .os:
            return Self.operatingSystem(fromUserAgent: info.client)
        case .since:
            return Self.time.string(from: info.since)
        }
    }

    /// "DE" → "Germany", and any code this machine has no name for stays the
    /// code. Never a blank.
    static func countryName(_ code: String) -> String {
        let region = code.uppercased()
        guard let name = Locale.current.localizedString(forRegionCode: region) else { return region }
        return "\(name) (\(region))"
    }

    /// `"OmniAgent/1.7.22 macOS 27.0"` → `"OmniAgent 1.7.22"`.
    ///
    /// A user agent is a shape, not a contract, so this refuses to guess: the
    /// first token must look like `name/version` or there is no app row.
    /// Everything after the first space is the OS.
    static func appVersion(fromUserAgent raw: String?) -> String? {
        guard let raw else { return nil }
        let head = raw.split(separator: " ", maxSplits: 1).first.map(String.init) ?? raw
        let parts = head.split(separator: "/", maxSplits: 1)
        guard parts.count == 2, !parts[1].isEmpty else { return nil }
        return "\(parts[0]) \(parts[1])"
    }

    static func operatingSystem(fromUserAgent raw: String?) -> String? {
        guard let raw else { return nil }
        let parts = raw.split(separator: " ", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        let tail = parts[1].trimmingCharacters(in: .whitespaces)
        return tail.isEmpty ? nil : tail
    }

    private static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()
}

/// A borderless window still has to take the keyboard, or the two buttons on
/// it cannot be reached by anything but the mouse.
final class RemoteTakeoverWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// The glass, laid out by hand.
///
/// Frames, not constraints, throughout — `PaneAskOverlayView`'s construction
/// exactly, and for its reasons: a glass view pinned inside a layout engine
/// (an `NSGlassEffectView.contentView`, or anything asking `fittingSize`
/// mid-pass) trips AppKit's `_nsis_frameInEngine` assertion, and this view is
/// nothing but glass.
final class RemoteTakeoverPanelView: NSView {
    var onTerminate: (() -> Void)?
    var onBlock: (() -> Void)?

    static let cardWidth: CGFloat = 520
    private static let padding: CGFloat = 28
    private static let rowHeight: CGFloat = 24
    private static let labelColumn: CGFloat = 118
    private static let glyphSize: CGFloat = 12
    private static let buttonHeight: CGFloat = 26
    private static let cardRadius: CGFloat = 20
    /// The room the activity table fills (spec §7, §8, Task 20).
    static let activityRoom: CGFloat = 150

    /// Where the activity table goes, in this view's coordinates.
    private(set) var activityFrame: NSRect = .zero
    /// The table itself (Task 20) — a plain subview positioned by `.frame`
    /// like every other view here, never pinned by Auto Layout: this view is
    /// nothing but glass, and Auto Layout pinned inside one has already
    /// caused `_nsis_frameInEngine` aborts elsewhere in this app. Its own
    /// internal content is free to use Auto Layout, since it is not itself a
    /// descendant of the glass.
    private let activityView = RemoteActivityTableView(frame: .zero)

    private let scrim: NSView?
    private let scrimTint = NSView()
    private let scrimTintLayer = CAGradientLayer()
    private let cardGlass: NSView?
    private let cardTint = NSView()
    private let cardTintLayer = CAGradientLayer()

    private let stateLabel = ShellFont.label(font: ShellFont.ui(12, .semibold), color: ShellPalette.accentBright)
    private let machineLabel = ShellFont.label(font: ShellFont.ui(24, .semibold), color: ShellPalette.ink)
    private let explanationLabel: NSTextField
    private let blockCaption: NSTextField
    /// A Terminate or Block the daemon refused. It belongs *here* and not in
    /// the window's usual glass ask card: that card mounts on the workspace
    /// window's content view, which this panel covers, so the host would
    /// never see it. Empty most of the time, and it takes no room when it is.
    private let failureLabel: NSTextField
    /// Built fresh whenever the rows change — a row that lost its value must
    /// leave no view behind, which is the whole point of omitting it.
    private var rowViews: [(label: NSTextField, value: NSTextField, glyph: NSImageView?)] = []
    let terminateButton = PaneApprovalButton(
        title: "Terminate",
        isPrimary: false,
        tint: PaneAskOverlayView.accent
    )
    let blockButton = PaneApprovalButton(title: "Block", isPrimary: true, tint: ShellPalette.red)
    /// The card's rectangle in this view's coordinates, measured by the last
    /// `layout()`. Not private: layout here is verified by rendering the view
    /// and asking where things landed, never by eye.
    private(set) var cardFrame: NSRect = .zero

    /// Spotlight's navy, as `PaneAskOverlayView` wears it — the same wash, so
    /// the takeover reads as this app's own modal rather than a new species
    /// of window.
    private static let navyTint = [
        NSColor(srgbRed: 0.11, green: 0.16, blue: 0.38, alpha: 0.40).cgColor,
        NSColor(srgbRed: 0.05, green: 0.08, blue: 0.22, alpha: 0.14).cgColor,
    ]
    /// The dim over everything else. Deliberately translucent: the host is
    /// meant to watch their terminals through it.
    private static let scrimWash = [
        NSColor(srgbRed: 0.04, green: 0.05, blue: 0.12, alpha: 0.62).cgColor,
        NSColor(srgbRed: 0.02, green: 0.02, blue: 0.06, alpha: 0.78).cgColor,
    ]

    override init(frame frameRect: NSRect) {
        explanationLabel = Self.wrapping(
            "Someone signed in to your account is using this Mac. You can watch what they do "
                + "behind this panel.",
            font: ShellFont.ui(13),
            color: ShellPalette.inkSecondary
        )
        blockCaption = Self.wrapping("", font: ShellFont.ui(11.5), color: ShellPalette.inkTertiary)
        failureLabel = Self.wrapping("", font: ShellFont.ui(12, .medium), color: ShellPalette.red)
        scrim = WorkspaceGlass.sheet()
        cardGlass = WorkspaceGlass.sheet(cornerRadius: Self.cardRadius)
        super.init(frame: frameRect)
        wantsLayer = true
        scrimTint.wantsLayer = true
        scrimTintLayer.colors = Self.scrimWash
        scrimTintLayer.startPoint = CGPoint(x: 0.5, y: 1)
        scrimTintLayer.endPoint = CGPoint(x: 0.5, y: 0)
        scrimTint.layer?.addSublayer(scrimTintLayer)
        cardTint.wantsLayer = true
        cardTintLayer.colors = Self.navyTint
        cardTintLayer.startPoint = CGPoint(x: 0.5, y: 1)
        cardTintLayer.endPoint = CGPoint(x: 0.5, y: 0)
        cardTint.layer?.addSublayer(cardTintLayer)
        cardTint.layer?.cornerRadius = Self.cardRadius
        cardTint.layer?.cornerCurve = .continuous
        cardTint.layer?.masksToBounds = true
        cardTint.layer?.borderWidth = 1
        cardTint.layer?.borderColor = NSColor(white: 1, alpha: 0.16).cgColor
        for view in [scrim, scrimTint, cardGlass, cardTint].compactMap({ $0 }) {
            addSubview(view)
        }
        for view in [stateLabel, machineLabel, explanationLabel, blockCaption, failureLabel] {
            view.translatesAutoresizingMaskIntoConstraints = true
            addSubview(view)
        }
        terminateButton.onClick = { [weak self] in self?.onTerminate?() }
        blockButton.onClick = { [weak self] in self?.onBlock?() }
        addSubview(terminateButton)
        addSubview(blockButton)
        activityView.translatesAutoresizingMaskIntoConstraints = true
        addSubview(activityView)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Remote takeover")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    /// Manual layout only runs when something asks for it, and a frame change
    /// alone does not — the panel is resized to a screen exactly once, so
    /// without this the card would sit wherever the seed frame put it.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    func apply(
        state: RemoteTakeoverPanel.State,
        machineName: String,
        rows: [RemoteTakeoverPanel.Row],
        info: RemoteConnectionInfo
    ) {
        failureLabel.stringValue = ""
        stateLabel.stringValue = state.line.uppercased()
        machineLabel.stringValue = machineName.isEmpty ? "Another Mac" : machineName
        blockCaption.stringValue = "Block: \(machineName.isEmpty ? "that machine" : machineName) "
            + "will not be able to connect again until you unblock it in Settings › Remote."
        for row in rowViews {
            row.label.removeFromSuperview()
            row.value.removeFromSuperview()
            row.glyph?.removeFromSuperview()
        }
        rowViews = rows.map { row in
            let label = ShellFont.label(row.label, font: ShellFont.ui(12), color: ShellPalette.inkMuted)
            let value = ShellFont.label(row.value, font: ShellFont.ui(13), color: ShellPalette.ink)
            label.translatesAutoresizingMaskIntoConstraints = true
            value.translatesAutoresizingMaskIntoConstraints = true
            addSubview(label)
            addSubview(value)
            var glyph: NSImageView?
            if row.isVerified {
                let view = NSImageView()
                view.image = NSImage(
                    systemSymbolName: "checkmark.seal.fill",
                    accessibilityDescription: "Verified by the relay"
                )
                view.contentTintColor = ShellPalette.accentBright
                view.imageScaling = .scaleProportionallyUpOrDown
                view.toolTip = "Verified by the relay"
                addSubview(view)
                glyph = view
            }
            return (label, value, glyph)
        }
        needsLayout = true
        needsDisplay = true
    }

    /// What the panel says when a kick did not land. Cleared on the next
    /// `apply` — a stale "could not disconnect" over a connection that has
    /// since gone is its own kind of lie.
    func showFailure(_ message: String) {
        failureLabel.stringValue = message
        needsLayout = true
    }

    /// Hands new activity rows to the table (Task 20; append-only since fix
    /// round 1). Not gated on `needsLayout`: the table appends its own rows
    /// and manages its own scroll position, independent of this view's
    /// outer geometry pass.
    func appendActivity(_ entries: [RemoteActivityLog.Entry]) {
        activityView.append(entries)
    }

    override func layout() {
        super.layout()
        let full = bounds
        scrim?.frame = full
        scrimTint.frame = full
        scrimTintLayer.frame = scrimTint.bounds

        let width = min(Self.cardWidth, max(320, full.width - 80))
        let inner = width - Self.padding * 2
        let stateHeight: CGFloat = 15
        let machineHeight: CGFloat = 30
        let explanationHeight = Self.height(of: explanationLabel, width: inner)
        let gridHeight = CGFloat(rowViews.count) * Self.rowHeight
        let captionHeight = Self.height(of: blockCaption, width: inner)
        let failureHeight = Self.height(of: failureLabel, width: inner)
        let height = Self.padding + stateHeight + 6 + machineHeight + 10 + explanationHeight
            + 20 + gridHeight + Self.activityRoom + captionHeight + failureHeight + 10
            + Self.buttonHeight + Self.padding
        cardFrame = NSRect(
            x: (full.width - width).rounded() / 2,
            y: (full.height - height).rounded() / 2,
            width: width,
            height: height
        )
        cardGlass?.frame = cardFrame
        cardTint.frame = cardFrame
        cardTintLayer.frame = cardTint.bounds

        // Top-down inside the card, in a bottom-left coordinate space.
        var y = cardFrame.maxY - Self.padding - stateHeight
        let left = cardFrame.minX + Self.padding
        stateLabel.frame = NSRect(x: left, y: y, width: inner, height: stateHeight)
        y -= 6 + machineHeight
        machineLabel.frame = NSRect(x: left, y: y, width: inner, height: machineHeight)
        y -= 10 + explanationHeight
        explanationLabel.frame = NSRect(x: left, y: y, width: inner, height: explanationHeight)
        y -= 20
        for row in rowViews {
            y -= Self.rowHeight
            row.label.frame = NSRect(x: left, y: y, width: Self.labelColumn, height: Self.rowHeight)
            let valueX = left + Self.labelColumn
            let glyphRoom = row.glyph == nil ? 0 : Self.glyphSize + 6
            let valueWidth = inner - Self.labelColumn - glyphRoom
            row.value.frame = NSRect(x: valueX, y: y, width: valueWidth, height: Self.rowHeight)
            if let glyph = row.glyph {
                let textWidth = min(
                    valueWidth,
                    ceil((row.value.stringValue as NSString)
                        .size(withAttributes: [.font: row.value.font ?? ShellFont.ui(13)]).width)
                )
                glyph.frame = NSRect(
                    x: valueX + textWidth + 6,
                    y: y + (Self.rowHeight - Self.glyphSize) / 2,
                    width: Self.glyphSize,
                    height: Self.glyphSize
                )
            }
        }
        activityFrame = NSRect(x: left, y: y - Self.activityRoom, width: inner, height: Self.activityRoom)
        activityView.frame = activityFrame
        y -= Self.activityRoom + captionHeight
        blockCaption.frame = NSRect(x: left, y: y, width: inner, height: captionHeight)
        y -= failureHeight
        failureLabel.frame = NSRect(x: left, y: y, width: inner, height: failureHeight)
        y -= 10 + Self.buttonHeight
        let blockWidth = blockButton.intrinsicContentSize.width
        let terminateWidth = terminateButton.intrinsicContentSize.width
        blockButton.frame = NSRect(
            x: cardFrame.maxX - Self.padding - blockWidth,
            y: y,
            width: blockWidth,
            height: Self.buttonHeight
        )
        terminateButton.frame = NSRect(
            x: blockButton.frame.minX - 10 - terminateWidth,
            y: y,
            width: terminateWidth,
            height: Self.buttonHeight
        )
    }

    /// The flat stand-in below macOS 26, where there is no glass to ask for:
    /// an honest translucent fill rather than a pretend blur. Above 26 the
    /// glass views cover this entirely.
    override func draw(_ dirtyRect: NSRect) {
        guard scrim == nil else { return }
        NSColor(srgbRed: 0.03, green: 0.04, blue: 0.10, alpha: 0.86).setFill()
        dirtyRect.fill()
        NSColor(srgbRed: 0.09, green: 0.12, blue: 0.28, alpha: 0.96).setFill()
        NSBezierPath(roundedRect: cardFrame, xRadius: Self.cardRadius, yRadius: Self.cardRadius).fill()
    }

    /// The click that lands on the glass rather than on a control is
    /// swallowed here. There is nothing behind this panel to click, and Esc
    /// is not handled at all — the panel has no dismiss (spec §7).
    override func mouseDown(with event: NSEvent) {}

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Everything inside the panel is the panel's: no click reaches the
        // workspace window underneath it while somebody is connected.
        let hit = super.hitTest(point)
        return hit ?? (bounds.contains(convert(point, from: superview)) ? self : nil)
    }

    private static func wrapping(_ text: String, font: NSFont, color: NSColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = font
        field.textColor = color
        field.lineBreakMode = .byWordWrapping
        field.maximumNumberOfLines = 0
        field.isSelectable = false
        return field
    }

    private static func height(of field: NSTextField, width: CGFloat) -> CGFloat {
        guard !field.stringValue.isEmpty else { return 0 }
        let size = field.cell?.cellSize(forBounds: NSRect(
            x: 0, y: 0, width: width, height: .greatestFiniteMagnitude
        ))
        return ceil(size?.height ?? 16)
    }
}

// MARK: - The activity table (Task 20, spec §8)

/// The activity table's row data — a lightweight, renderless model so
/// `isExpandable` can be pinned by a test without instantiating any view at
/// all. A row with no `detail` cannot expand: spec §8 says "clicking a
/// session is one line and no detail", so a disclosure chevron on one would
/// promise something the row cannot make good on, and it must not respond to
/// clicks either.
struct RemoteActivityTable: Equatable {
    let entries: [RemoteActivityLog.Entry]

    var count: Int { entries.count }

    func isExpandable(at index: Int) -> Bool {
        entries[index].detail != nil
    }

    func timeText(at index: Int) -> String {
        Self.timeText(for: entries[index].ts)
    }

    /// The same formatting, off a bare `Date` — for a caller (the live
    /// table, fix round 1) that appends one row at a time rather than
    /// holding a whole `RemoteActivityTable` to index into.
    static func timeText(for date: Date) -> String {
        time.string(from: date)
    }

    /// An SF Symbol for `kind` (spec §8: "symbol for kind"). A kind this
    /// build does not recognise — a daemon ahead of the app — still draws
    /// something, rather than nothing at all.
    static func symbolName(for kind: String) -> String {
        switch kind {
        case "connected": return "arrow.down.left.circle.fill"
        case "disconnected": return "arrow.up.right.circle"
        case "attach": return "rectangle.on.rectangle"
        case "create_session": return "plus.rectangle.on.rectangle"
        case "input": return "character.cursor.ibeam"
        case "interrupt": return "hand.raised"
        case "kill": return "xmark.circle"
        case "set_setting": return "gearshape"
        case "roots": return "folder"
        case "list_directory": return "folder.badge.questionmark"
        case "brain_search", "brain_list_projects": return "magnifyingglass"
        case "brain_get_context": return "text.book.closed"
        case "resize": return "arrow.up.left.and.arrow.down.right"
        // Fix round 1, IMPORTANT 2: the synthetic "N rows not shown" marker
        // (`RemoteActivityLog.Entry.init(gapCount:)`).
        case "gap": return "ellipsis.circle"
        default: return "circle"
        }
    }

    private static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }()
}

/// One row of the activity table: time, a symbol for `kind`, and the summary
/// — expanding, on click, into a monospaced detail block, but only when it
/// has one (spec §8). `PaneAppWorkGroupView`'s own shape (`PaneAppMessageRow.swift`):
/// the detail is built up front and merely hidden, and a click toggles it —
/// adapted here for a row that may have **no** detail at all, in which case
/// there is nothing to reveal and no chevron promising there is, and no
/// gesture recognizer to respond to a click in the first place.
final class RemoteActivityRowView: NSView {
    private(set) var isExpanded = false
    private let isExpandable: Bool
    private let chevron: NSTextField?
    private let detailLabel: NSTextField?
    private let header: NSStackView
    private var cursorTracking: NSTrackingArea?

    init(entry: RemoteActivityLog.Entry, timeText: String, symbolName: String) {
        isExpandable = entry.detail != nil

        let time = ShellFont.label(timeText, font: ShellFont.ui(11), color: ShellPalette.inkFaint)
        time.setContentHuggingPriority(.required, for: .horizontal)
        time.setContentCompressionResistancePriority(.required, for: .horizontal)

        let symbol = NSImageView(
            image: NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) ?? NSImage()
        )
        symbol.contentTintColor = ShellPalette.inkTertiary
        symbol.setContentHuggingPriority(.required, for: .horizontal)
        symbol.translatesAutoresizingMaskIntoConstraints = false
        symbol.widthAnchor.constraint(equalToConstant: 14).isActive = true
        symbol.heightAnchor.constraint(equalToConstant: 14).isActive = true

        let summary = ShellFont.label(entry.summary, font: ShellFont.ui(12), color: ShellPalette.ink)
        summary.lineBreakMode = .byTruncatingTail
        summary.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        var headerViews: [NSView] = [time, symbol, summary]
        if isExpandable {
            let chevronField = ShellFont.label("⌄", font: ShellFont.ui(10), color: ShellPalette.inkFaint)
            chevron = chevronField
            headerViews.append(chevronField)
        } else {
            chevron = nil
        }
        header = NSStackView(views: headerViews)

        if let detail = entry.detail {
            let label = ShellFont.label(detail, font: ShellFont.mono(11), color: ShellPalette.inkTerminal)
            label.lineBreakMode = .byWordWrapping
            label.maximumNumberOfLines = 0
            label.isSelectable = true
            detailLabel = label
        } else {
            detailLabel = nil
        }

        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        header.orientation = .horizontal
        header.alignment = .firstBaseline
        header.spacing = 6
        header.translatesAutoresizingMaskIntoConstraints = false

        let body = NSStackView()
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 4
        body.translatesAutoresizingMaskIntoConstraints = false
        body.addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        if let detailLabel {
            detailLabel.isHidden = true
            body.addArrangedSubview(detailLabel)
            detailLabel.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        }

        addSubview(body)
        NSLayoutConstraint.activate([
            body.topAnchor.constraint(equalTo: topAnchor),
            body.leadingAnchor.constraint(equalTo: leadingAnchor),
            body.trailingAnchor.constraint(equalTo: trailingAnchor),
            body.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        if isExpandable {
            setAccessibilityElement(true)
            setAccessibilityRole(.disclosureTriangle)
            setAccessibilityLabel(entry.summary)
            setAccessibilityExpanded(false)
            let click = NSClickGestureRecognizer(target: self, action: #selector(handleClick))
            header.addGestureRecognizer(click)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    /// The pointing hand over the header, and only when there is something to
    /// click — `PaneAppWorkGroupView`'s own reasoning: a cursor rect is
    /// cached by the window and does not follow a view a stack view moves, so
    /// this tracks the live frame on every layout pass instead.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard isExpandable else { return }
        if let cursorTracking { removeTrackingArea(cursorTracking) }
        let area = NSTrackingArea(
            rect: convert(header.bounds, from: header),
            options: [.cursorUpdate, .activeInKeyWindow],
            owner: self
        )
        addTrackingArea(area)
        cursorTracking = area
    }

    override func cursorUpdate(with event: NSEvent) {
        guard isExpandable else { return }
        NSCursor.pointingHand.set()
    }

    @objc private func handleClick() { toggle() }

    /// Internal rather than private so a test can drive expansion without
    /// synthesising a click — `PaneAppWorkGroupView.toggle()`'s own reasoning.
    /// A no-op on a row with nothing to expand: the gesture recognizer that
    /// would call this is never even attached to one, but this guard is what
    /// makes "does not respond to clicks" true of the method itself, not only
    /// of whatever happens to invoke it.
    func toggle() {
        guard isExpandable, let detailLabel, let chevron else { return }
        isExpanded.toggle()
        detailLabel.isHidden = !isExpanded
        chevron.stringValue = isExpanded ? "⌃" : "⌄"
        setAccessibilityExpanded(isExpanded)
    }
}

/// The activity table itself (spec §8, Task 20): a scrolling, top-to-bottom
/// list of `RemoteActivityRowView`s, newest row at the bottom, auto-scrolling
/// only while it is already scrolled to the bottom — a host who has scrolled
/// up to read something is never yanked back down by the next row.
///
/// `ShellScrollView`'s flipped clip view (`WorkspaceShell.swift`) and
/// `isScrolledToBottom`/`scrollToBottom`'s shape are
/// `PaneAppView.swift`'s own — the identical problem (a stack of appended
/// rows, scrolled to the newest only when the reader was already there) with
/// no reason to solve it twice.
final class RemoteActivityTableView: NSView {
    private let stack = NSStackView()
    private let scroll: ShellScrollView
    private let emptyLabel = ShellFont.label(
        "No activity yet.", font: ShellFont.ui(12), color: ShellPalette.inkFaint
    )
    /// How many rows have been appended — readable so a test can pin
    /// "appended, not rebuilt" without reaching into `stack`. Not the same
    /// thing as `RemoteActivityTable.count`: this view no longer holds one.
    private(set) var rowCount = 0

    override init(frame frameRect: NSRect) {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll = ShellScrollView(documentView: stack)
        super.init(frame: frameRect)

        scroll.translatesAutoresizingMaskIntoConstraints = true
        scroll.autoresizingMask = [.width, .height]
        addSubview(scroll)

        emptyLabel.translatesAutoresizingMaskIntoConstraints = true
        addSubview(emptyLabel)

        setAccessibilityElement(true)
        setAccessibilityRole(.list)
        setAccessibilityLabel("Remote activity")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func layout() {
        super.layout()
        scroll.frame = bounds
        emptyLabel.frame = NSRect(x: 0, y: (bounds.height - 16) / 2, width: bounds.width, height: 16)
    }

    /// Appends `entries` as new rows — **never** rebuilds the rows already
    /// standing (fix round 1, IMPORTANT 3). The old `apply(_:)` took the
    /// live log's *whole* accumulated array on every single push and
    /// rebuilt every row from scratch: O(n²) over an unbounded live history,
    /// and a host who had expanded a row to read its detail watched it
    /// collapse the instant the next row arrived, because that row view was
    /// destroyed and a fresh, collapsed one put in its place — the same
    /// "do not disturb the reader" intent the scroll rule below already
    /// honours, just not extended to expansion state. Appending only the
    /// new rows costs O(1) amortised per push and leaves every existing
    /// `RemoteActivityRowView` — and whatever it has toggled to — untouched.
    func append(_ entries: [RemoteActivityLog.Entry]) {
        guard !entries.isEmpty else { return }
        let wasAtBottom = isScrolledToBottom
        for entry in entries {
            let row = RemoteActivityRowView(
                entry: entry,
                timeText: RemoteActivityTable.timeText(for: entry.ts),
                symbolName: RemoteActivityTable.symbolName(for: entry.kind)
            )
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        rowCount += entries.count
        emptyLabel.isHidden = rowCount > 0
        layoutSubtreeIfNeeded()
        if wasAtBottom {
            scrollToBottom()
        }
    }

    /// `PaneAppView.isScrolledToBottom`'s formula, without a bottom inset:
    /// this table has none.
    private var isScrolledToBottom: Bool {
        let clip = scroll.contentView
        let range = max(0, stack.frame.height - clip.bounds.height)
        return clip.bounds.origin.y >= range - 2
    }

    /// `PaneAppView.scrollToBottom`'s formula.
    private func scrollToBottom() {
        let clip = scroll.contentView
        let range = max(0, stack.frame.height - clip.bounds.height)
        clip.scroll(to: NSPoint(x: 0, y: range))
        scroll.reflectScrolledClipView(clip)
    }
}
