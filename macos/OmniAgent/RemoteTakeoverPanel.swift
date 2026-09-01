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
    private(set) var info: RemoteConnectionInfo
    /// `nil` in a test that only inspects the layout. A kick with no
    /// connection is a no-op, never a crash.
    private weak var connection: RemoteViewerDisconnecting?
    /// A failed Terminate/Block — surfaced by the owner in the house glass
    /// card, never swallowed: this is a security surface, and "nothing
    /// happened" must not look like "done".
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
        window.orderOut(nil)
    }

    /// A newer roster for the same machine — the state line advancing, or an
    /// asserted field the relay filled in a moment later.
    func apply(_ info: RemoteConnectionInfo) {
        guard info != self.info else { return }
        self.info = info
        view.apply(state: state, machineName: info.machineName, rows: rows, info: info)
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
    /// The room Phase 4's activity table drops into (spec §7, §8). Left
    /// **empty**, not filled with a placeholder: an empty region is honest
    /// about a table that does not exist yet, and a stub would have to be
    /// deleted rather than filled.
    static let activityRoom: CGFloat = 150

    /// Where the activity table goes, in this view's coordinates. Published
    /// so Task 20 has somewhere to put it without re-deriving the geometry.
    private(set) var activityFrame: NSRect = .zero

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
