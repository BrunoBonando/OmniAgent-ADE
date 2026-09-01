import AppKit

// The Settings destination (2026-08-27), in the Apple TV idiom: a floating
// rounded panel of sections at the top-left of the content area — inset from
// every edge, on plain glass so the app's grey-to-black ground shows through
// — with "Settings" in the title strip above it, the way the Desk names its
// session, and the picked section's content in a centred column beside it.
// The screens come one by one: Accounts has one (who is signed in, whether
// GitHub is connected, and the button that changes each); every other
// section still says "Under development".
//
// The panel is one object in two roles (2026-08-28): the sidebar gear
// *offers* it beside itself, tip on the gear, as the menu; a pick slides it
// up to *dock* under the title as the page's sidebar; the gear again brings
// it back down to pick anew. `WorkspaceWindowController` owns it and places
// it — it floats over the content area, not inside this page — so the same
// glass travels between the two places instead of a popup standing in for
// it. ⌘, and the palette open the page on whatever section it was last on.

/// The Settings page's sections, in the design's order. `startsGroup` marks
/// the gaps in the list: General…Accessibility, Customize/Model providers,
/// Experimental.
enum SettingsSection: String, CaseIterable {
    case general
    case accounts
    case sessions
    case themes
    case accessibility
    case customize
    case modelProviders
    case experimental

    var title: String {
        switch self {
        case .general: return "General"
        case .accounts: return "Accounts"
        case .sessions: return "Sessions"
        case .themes: return "Themes"
        case .accessibility: return "Accessibility"
        case .customize: return "Customize"
        case .modelProviders: return "Model providers"
        case .experimental: return "Experimental"
        }
    }

    /// SF Symbols approximating the design's set.
    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .accounts: return "person.2"
        case .sessions: return "arrow.triangle.branch"
        case .themes: return "paintpalette"
        case .accessibility: return "accessibility"
        case .customize: return "square.grid.2x2"
        case .modelProviders: return "cpu"
        case .experimental: return "flask"
        }
    }

    var startsGroup: Bool { self == .customize || self == .experimental }
}

/// The floating panel of sections: a search row over the left menu's nav
/// rows, on a rounded sheet of untinted glass, hugging its rows rather than
/// the window's height. The picked row wears the app's accent — the blue the
/// left menu's gradient is made of — solidly enough to read as "you are
/// here"; offered off the page it wears none, since nothing is.
///
/// The tip it wears on the gear is the session hover card's drop, as that
/// card actually draws it: a dark rounded square turned 45°, half tucked
/// under the card, so the half that shows is a point. (The hover card's
/// glass-on-glass merge is behind `CommandPaletteController.glassEnabled`,
/// which is off — and a rotated `NSGlassEffectView` inside a layout engine
/// trips AppKit's `_nsis_frameInEngine` assertion, so it stays off here
/// too.) Like the hover card's shell, this view keeps a `lane` on its left
/// for the drop, and the card sits at `x = lane`. Placed by frame (its
/// owner slides it about), sized `frameWidth` × `contentHeight`.
final class SettingsSidebarView: NSView, NSTextFieldDelegate {
    /// The card's width.
    static let width: CGFloat = 220
    static let cornerRadius: CGFloat = 16
    // The drop, in the hover card's own numbers.
    static let dropSize: CGFloat = 13
    static let dropCorner: CGFloat = 2
    static var tipSpan: CGFloat { dropSize * 2.squareRoot() }
    static let neck: CGFloat = 4
    static var lane: CGFloat { tipSpan + neck + 1 }
    /// The whole view: the lane and the card.
    static var frameWidth: CGFloat { lane + width }

    private(set) var rows: [SidebarNavRowView] = []
    let search = NSTextField()
    var onSelect: ((SettingsSection) -> Void)?
    /// Filtering changed which rows show, and so the height the owner
    /// should place this at.
    var onHeightChange: (() -> Void)?

    private let body = NSView()
    /// `body.fittingSize.height`, measured when the rows change and never
    /// inside `layout()`: `fittingSize` runs a temporary layout engine, and
    /// asking for one from within the real pass trips AppKit's
    /// `_nsis_frameInEngine` assertion (SIGABRT) — the hover card caches
    /// `minimumCardSize` for the same reason.
    private var measuredHeight: CGFloat = 120
    private let card: NSView
    private let dropBox = NSView()
    private let drop = NSView()

    override init(frame frameRect: NSRect) {
        let seed = NSSize(width: Self.width, height: 120)
        // The body is never a glass view's `contentView`: those pins are
        // `.required` constraints inside an ancestor's layout engine, and
        // with this view frame-placed inside a constraint-managed container
        // they trip the same assertion. The body sits *over* the card as a
        // frame-placed sibling instead.
        body.frame = NSRect(origin: .zero, size: seed)
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: NSRect(origin: .zero, size: seed))
            glass.cornerRadius = Self.cornerRadius
            glass.style = .regular
            glass.tintColor = nil
            card = glass
        } else {
            let plain = NSView(frame: NSRect(origin: .zero, size: seed))
            plain.wantsLayer = true
            plain.layer?.cornerRadius = Self.cornerRadius
            plain.layer?.cornerCurve = .continuous
            plain.layer?.backgroundColor = ShellPalette.cardFill.cgColor
            plain.layer?.borderWidth = 1
            plain.layer?.borderColor = ShellPalette.hairlineStrong.cgColor
            card = plain
        }
        super.init(frame: frameRect)
        wantsLayer = true

        // The search row: a bare field, no bezel, no focus ring — part of
        // the panel, not a control sitting in it. Return picks the first
        // row showing.
        search.isBordered = false
        search.isBezeled = false
        search.drawsBackground = false
        search.focusRingType = .none
        search.font = ShellFont.ui(13)
        search.textColor = ShellPalette.ink
        search.placeholderAttributedString = NSAttributedString(
            string: "Search settings…",
            attributes: [.foregroundColor: ShellPalette.inkMuted, .font: ShellFont.ui(13)]
        )
        search.delegate = self
        search.target = self
        search.action = #selector(pickFirstVisible)
        search.translatesAutoresizingMaskIntoConstraints = false
        let rule = ShellSeparator()

        rows = SettingsSection.allCases.map { section in
            let row = SidebarNavRowView(
                title: section.title,
                symbol: section.symbol,
                selectedFill: ShellPalette.accentFill
            )
            row.onPress = { [weak self] in self?.onSelect?(section) }
            return row
        }
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 10, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        for (index, section) in SettingsSection.allCases.enumerated() {
            rows[index].widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20).isActive = true
            if section.startsGroup, index > 0 { stack.setCustomSpacing(18, after: rows[index - 1]) }
        }
        body.addSubview(search)
        body.addSubview(rule)
        body.addSubview(stack)
        NSLayoutConstraint.activate([
            search.topAnchor.constraint(equalTo: body.topAnchor, constant: 12),
            search.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: 18),
            search.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -18),
            rule.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 12),
            rule.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            stack.topAnchor.constraint(equalTo: rule.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: body.bottomAnchor),
        ])

        drop.wantsLayer = true
        drop.layer?.cornerRadius = Self.dropCorner
        drop.layer?.backgroundColor = NSColor(srgbRed: 0.12, green: 0.13, blue: 0.20, alpha: 0.92).cgColor
        addSubview(dropBox)
        // Above the drop, covering its inner half; the rows over the card.
        addSubview(card)
        addSubview(body)
        dropBox.addSubview(drop)
        drop.frame = NSRect(
            x: (Self.tipSpan - Self.dropSize) / 2,
            y: (Self.tipSpan - Self.dropSize) / 2,
            width: Self.dropSize,
            height: Self.dropSize
        )
        drop.frameCenterRotation = 45
        dropBox.frame = NSRect(x: 0, y: 0, width: Self.tipSpan, height: Self.tipSpan)
        dropBox.isHidden = true

        // The card can never be shorter than its rows: its content pins are
        // `.required`, and an animated frame passes through every height
        // between two places — a card smaller than its content for one tick
        // is the contradiction that ends in NaN geometry and a crash (the
        // hover card's `minimumCardSize`, for the same reason).
        remeasure()
        card.frame.size = NSSize(width: Self.width, height: contentHeight)
        frame.size = NSSize(width: Self.frameWidth, height: contentHeight)
    }

    private func remeasure() {
        measuredHeight = body.fittingSize.height
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func layout() {
        super.layout()
        card.frame = NSRect(
            x: Self.lane,
            y: 0,
            width: max(bounds.width - Self.lane, Self.width),
            height: max(bounds.height, contentHeight)
        )
        body.frame = card.frame
    }

    /// The height the rows on show need.
    var contentHeight: CGFloat { measuredHeight }

    /// Puts the drop's centre at `y` in this view's coordinates, in the
    /// lane, kept off the rounded corners.
    func pointTip(at y: CGFloat) {
        let half = Self.tipSpan / 2
        let clamped = min(max(y, Self.cornerRadius + half), bounds.height - Self.cornerRadius - half)
        dropBox.frame.origin = NSPoint(x: 0, y: clamped - half)
    }

    var isTipVisible: Bool {
        get { !dropBox.isHidden }
        set { dropBox.isHidden = !newValue }
    }

    /// Where the drop points, in this view's coordinates — for the tests.
    var tipCenterYForTesting: CGFloat { dropBox.frame.midY }

    /// `nil` lights no row: offered off the page, nothing is "here".
    func apply(selected: SettingsSection?) {
        for (row, section) in zip(rows, SettingsSection.allCases) {
            row.apply(selected: section == selected)
        }
    }

    func focusSearch() {
        window?.makeFirstResponder(search)
    }

    func clearSearch() {
        search.stringValue = ""
        for row in rows { row.isHidden = false }
        remeasure()
    }

    func controlTextDidChange(_ obj: Notification) {
        let query = search.stringValue.trimmingCharacters(in: .whitespaces)
        for (row, section) in zip(rows, SettingsSection.allCases) {
            row.isHidden = !query.isEmpty && !section.title.localizedCaseInsensitiveContains(query)
        }
        remeasure()
        onHeightChange?()
    }

    /// Test seam: the same path a keystroke takes.
    func setQueryForTesting(_ query: String) {
        search.stringValue = query
        controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
    }

    var visibleTitlesForTesting: [String] { rows.filter { !$0.isHidden }.map(\.titleText) }

    @objc private func pickFirstVisible() {
        guard let index = rows.firstIndex(where: { !$0.isHidden }) else { return }
        onSelect?(SettingsSection.allCases[index])
    }
}

/// The Settings page's content: the picked section's name and body in
/// Home's centred 880pt column, clear of the docked panel on the left —
/// from the top, though, not from a share of the height. Transparent, like
/// Home: `PaneGroundView` behind it is the ground. The panel itself and the
/// "Settings" title above it are the controller's — see `settingsPanel` and
/// `refreshTitle`.
final class SettingsSurfaceView: NSView {
    /// The room the docked panel takes on the left: the title's 12pt inset,
    /// the panel, and a gutter.
    static let panelRoom = 12 + SettingsSidebarView.width + 16

    /// The picked section's name, heading its content.
    let titleField = ShellFont.label(font: ShellFont.ui(22, .semibold), color: ShellPalette.ink)
    let subtitleField = ShellFont.label(
        "Under development",
        font: ShellFont.ui(13),
        color: ShellPalette.inkMuted
    )
    /// Accounts, and only Accounts: who is signed in, and the one button
    /// that changes it — with the GitHub pair below it. The first section
    /// with a screen instead of a promise — the rest keep `subtitleField`.
    let accountField = ShellFont.label(font: ShellFont.ui(13), color: ShellPalette.inkMuted)
    let accountButton = NSButton(title: "", target: nil, action: nil)
    /// The GitHub connection, under the account it belongs to: which handle
    /// is linked, and the one button that links or unlinks it.
    let githubField = ShellFont.label(font: ShellFont.ui(13), color: ShellPalette.inkMuted)
    let githubButton = NSButton(title: "", target: nil, action: nil)
    /// The destructive third button, under both. Shown only on Accounts and
    /// only while signed in — there is no account to delete otherwise, and
    /// the spotlight's row obeys the same rule.
    let deleteAccountButton = NSButton(title: "Delete account…", target: nil, action: nil)
    /// What the block currently says about the account — the one reading of
    /// it, so the label and the button can never disagree, and so the
    /// spotlight's row (which offers "Log out" or "Sign in with Apple…" off
    /// exactly this) says what the page says. See `applyAccount`.
    private(set) var accountSignedIn = false
    /// The same, for the GitHub pair: the spotlight offers "Disconnect
    /// GitHub" or "Connect GitHub…" off this one reading.
    private(set) var accountGitHubConnected = false
    /// The linked handle, without the `@` — `""` when not connected. Home's
    /// branch dropdown reads this to show who is actually connected instead
    /// of repeating the account bool as bare text.
    private(set) var githubLogin = ""
    /// The account block's buttons, as one press each. `onLogOut` and
    /// `onDisconnectGitHub` are the destructive halves; all four are the
    /// controller's to perform — this view knows nothing about auth.
    var onSignIn: (() -> Void)?
    var onLogOut: (() -> Void)?
    var onConnectGitHub: (() -> Void)?
    var onDisconnectGitHub: (() -> Void)?
    var onDeleteAccount: (() -> Void)?
    /// General's update block: which version is running, what the updater is
    /// doing, and the one button that advances it. General rather than a
    /// section of its own -- it is where macOS apps put this, and a whole
    /// section for three controls is a menu entry nobody needs.
    let updateVersionField = ShellFont.label(font: ShellFont.ui(13), color: ShellPalette.inkSecondary)
    let updateStatusField = ShellFont.label(font: ShellFont.ui(13), color: ShellPalette.inkMuted)
    let updateButton = NSButton(title: "Check for Updates", target: nil, action: nil)
    /// The three things the button can mean, by state. The view dispatches so
    /// the caller does not have to re-derive what is on screen.
    var onCheckForUpdates: (() -> Void)?
    var onDownloadUpdate: (() -> Void)?
    var onRestartUpdate: (() -> Void)?
    private(set) var updateState: UpdateState = .idle

    /// The section on screen. Sticks for as long as the app lives, like
    /// Home's own picks.
    private(set) var section: SettingsSection = .general

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        accountButton.bezelStyle = .rounded
        accountButton.controlSize = .regular
        accountButton.font = ShellFont.ui(13)
        accountButton.target = self
        accountButton.action = #selector(accountButtonPressed)
        accountButton.translatesAutoresizingMaskIntoConstraints = false
        githubButton.bezelStyle = .rounded
        githubButton.controlSize = .regular
        githubButton.font = ShellFont.ui(13)
        githubButton.target = self
        githubButton.action = #selector(githubButtonPressed)
        githubButton.translatesAutoresizingMaskIntoConstraints = false
        deleteAccountButton.bezelStyle = .rounded
        deleteAccountButton.controlSize = .regular
        deleteAccountButton.font = ShellFont.ui(13)
        deleteAccountButton.target = self
        deleteAccountButton.action = #selector(deleteAccountPressed)
        deleteAccountButton.translatesAutoresizingMaskIntoConstraints = false
        applyAccount(email: nil, signedIn: false)

        updateButton.bezelStyle = .rounded
        updateButton.controlSize = .regular
        updateButton.font = ShellFont.ui(13)
        updateButton.target = self
        updateButton.action = #selector(updateButtonPressed)
        updateButton.translatesAutoresizingMaskIntoConstraints = false
        let running = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        updateVersionField.stringValue = "OmniAgent \(running ?? "")"
        applyUpdateState(.idle)

        let column = NSStackView(views: [
            titleField, subtitleField, accountField, accountButton, githubField, githubButton,
            deleteAccountButton, updateVersionField, updateStatusField, updateButton,
        ])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 6
        column.setCustomSpacing(14, after: accountField)
        // A gap between the two blocks, so the GitHub line reads as a fact
        // about the account above it rather than a second caption on it.
        column.setCustomSpacing(22, after: accountButton)
        column.setCustomSpacing(14, after: githubField)
        // Its own gap again: deleting the account is not a third line of the
        // GitHub block.
        column.setCustomSpacing(22, after: githubButton)
        column.setCustomSpacing(14, after: updateStatusField)
        column.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(column)

        let scroll = ShellScrollView(
            documentView: content,
            topFade: ShellScrollView.pageFade,
            topInset: WorkspaceTitleBarView.height
        )
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.panelRoom),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),

            // Past the fade band, so the heading is whole at rest.
            column.topAnchor.constraint(
                equalTo: content.topAnchor,
                constant: ShellScrollView.pageFade - WorkspaceTitleBarView.height + 8
            ),
            column.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -36),
            column.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            column.leadingAnchor.constraint(greaterThanOrEqualTo: content.leadingAnchor, constant: 24),
        ])
        let width = column.widthAnchor.constraint(equalToConstant: 880)
        width.priority = .defaultHigh
        width.isActive = true

        select(.general)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func select(_ section: SettingsSection) {
        self.section = section
        titleField.stringValue = section.title
        // Accounts has a screen; everything else still says so.
        let isAccounts = section == .accounts
        subtitleField.isHidden = isAccounts
        accountField.isHidden = !isAccounts
        accountButton.isHidden = !isAccounts
        githubField.isHidden = !isAccounts
        githubButton.isHidden = !isAccounts
        deleteAccountButton.isHidden = !(isAccounts && accountSignedIn)
        // General has a screen too now: the update block. Which means General
        // no longer says "Under development" either.
        let isGeneral = section == .general
        subtitleField.isHidden = isAccounts || isGeneral
        updateVersionField.isHidden = !isGeneral
        updateStatusField.isHidden = !isGeneral
        updateButton.isHidden = !isGeneral
    }

    /// The update story, on the Settings page. Same states as the sidebar
    /// widget, spelled out because there is room here to spell them out.
    func applyUpdateState(_ state: UpdateState) {
        updateState = state
        let status: String
        let title: String
        switch state {
        case .idle:
            status = "OmniAgent checks for updates automatically, once a day."
            title = "Check for Updates"
        case .checking:
            status = "Checking…"
            title = "Checking…"
        case let .available(version):
            status = "Version \(version) is available."
            title = "Download Update"
        case let .updating(fraction):
            status = fraction.map { "Updating… \(Int($0 * 100))%" } ?? "Updating…"
            title = "Updating…"
        case let .readyToRestart(version):
            let named = version.isEmpty ? "An update" : "Version \(version)"
            status = "\(named) is ready. Restarting ends any running terminal sessions."
            title = "Restart to Update"
        case let .failed(message):
            status = "Update failed — \(message)"
            title = "Try Again"
        }
        updateStatusField.stringValue = status
        updateButton.title = title
        // Nothing to press while work is in flight; the label already says so.
        switch state {
        case .checking, .updating: updateButton.isEnabled = false
        default: updateButton.isEnabled = true
        }
    }

    @objc private func updateButtonPressed() {
        switch updateState {
        case .available: onDownloadUpdate?()
        case .readyToRestart: onRestartUpdate?()
        case .idle, .failed: onCheckForUpdates?()
        case .checking, .updating: break
        }
    }

    /// The account as the page shows it, handed in by the controller — this
    /// view never reads settings itself.
    ///
    /// **Signed in is `signedIn` alone; the address is only what it is
    /// called.** The controller seeds this from the `UserDefaults` mirror
    /// the launch gate is decided by, which is current and synchronous but
    /// carries no email, and only then fills the address in from the
    /// `auth_account_email` row a daemon round trip later. Deriving
    /// signed-in from the address too would make that first moment read
    /// "Not signed in" to a signed-in user — and taking the "Sign in…" it
    /// offered would end in a local sign-out with the server session never
    /// revoked. So a signed-in account with no address yet (and the
    /// fake-login era's row, which never had one — see
    /// `AuthGate.describeAuthSummary`) says plain "Signed in".
    ///
    /// **The GitHub line is shown whether or not the account is signed in**,
    /// and offers Connect either way — the same one row the spotlight offers,
    /// in the same two states. Hiding it while signed out would make the
    /// spotlight and the page disagree, and the honest answer to pressing
    /// Connect with no session ("sign in first", from
    /// `AuthGateViewModel.signInFirstMessage`) is more use than a row that
    /// silently is not there.
    func applyAccount(email: String?, signedIn: Bool, githubLogin: String? = nil) {
        let address = (email ?? "").trimmingCharacters(in: .whitespaces)
        accountSignedIn = signedIn
        accountField.stringValue = switch (signedIn, address.isEmpty) {
        case (false, _): "Not signed in"
        case (true, true): "Signed in"
        case (true, false): "Signed in as \(address)"
        }
        accountButton.title = signedIn ? "Log out" : "Sign in…"

        let login = (githubLogin ?? "").trimmingCharacters(in: .whitespaces)
        accountGitHubConnected = !login.isEmpty
        self.githubLogin = login
        githubField.stringValue = login.isEmpty ? "GitHub: not connected" : "GitHub: @\(login)"
        githubButton.title = login.isEmpty ? "Connect GitHub…" : "Disconnect"
        deleteAccountButton.isHidden = !(section == .accounts && signedIn)
    }

    @objc private func accountButtonPressed() {
        if accountSignedIn { onLogOut?() } else { onSignIn?() }
    }

    @objc private func githubButtonPressed() {
        if accountGitHubConnected { onDisconnectGitHub?() } else { onConnectGitHub?() }
    }

    @objc private func deleteAccountPressed() { onDeleteAccount?() }
}
