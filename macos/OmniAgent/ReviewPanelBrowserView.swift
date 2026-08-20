import AppKit
import WebKit

// The review panel's Browser tab — the 2026-08-20 redesign's §5: a WKWebView
// under a URL field with back/forward/reload, for glancing at the dev server
// the session's agent just started without leaving the panel. The tab reads
// the session's terminals (their recent visible output, unwrapped) for
// `localhost:PORT` / `127.0.0.1:PORT` and offers
// every port it finds as a one-click chip on the URL field. Normalization is
// `BrowserPaneView.destination` — one rule for both browser surfaces — and
// the web view rides `BrowserPaneView.sharedProcessPool` for the same
// renderer-sharing reason. The terminal read is `unwrappedTailLines`, so an
// address wrapped across the rows of a narrow pane still reads whole.

/// Where navigations land. The real one wraps the WKWebView; tests hand in a
/// spy so every navigation is assertable without a WebKit content process —
/// `ReviewPanelDiffRenderer`'s pattern, for the browser.
protocol ReviewPanelBrowserNavigator: AnyObject {
    func load(_ url: URL)
    func goBack()
    func goForward()
    func reload()
}

/// One suggested dev-server port: a small chip that reads as the address a
/// click will load.
final class ReviewPanelPortChipView: ShellRowView {
    let port: Int
    let title: String

    init(port: Int) {
        self.port = port
        title = "localhost:\(port)"
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        layer?.borderColor = ShellPalette.hairline.cgColor
        translatesAutoresizingMaskIntoConstraints = false
        let label = ShellFont.label(
            title,
            font: ShellFont.mono(11, .medium),
            color: ShellPalette.inkSecondary
        )
        addSubview(label)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 20),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityLabel("Open \(title)")
        refreshBackground()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func refreshBackground() {
        layer?.backgroundColor = (isHovered ? ShellPalette.hoverSoft : ShellPalette.fieldFill).cgColor
    }
}

/// The tab's whole content: a nav bar (back/forward/reload, the URL field),
/// a suggestions row that appears when the session's terminals mention a
/// local port, and the web view. The WKWebView is built on the first real
/// navigation, not in `init` — `ReviewPanelChangesView.webHost`'s reasoning:
/// a WebKit content process is not paid for a tab that only ever shows its
/// empty state (and in tests, never at all).
final class ReviewPanelBrowserView: NSView {
    static let navBarHeight: CGFloat = 34
    static let suggestionsHeight: CGFloat = 28

    let backButton = ReviewPanelIconButton(symbol: "chevron.left", label: "Back")
    let forwardButton = ReviewPanelIconButton(symbol: "chevron.right", label: "Forward")
    let reloadButton = ReviewPanelIconButton(symbol: "arrow.clockwise", label: "Reload")
    let urlField = NSTextField()

    private(set) var webView: WKWebView?
    /// Test seam: stands in for the web view. When set, no WKWebView is ever
    /// built — `rendererForTesting`'s contract.
    var navigatorForTesting: ReviewPanelBrowserNavigator?

    private(set) var suggestedPorts: [Int] = []
    private(set) var suggestionChips: [ReviewPanelPortChipView] = []

    // The empty state — what the tab says before anything has been loaded.
    let emptyStateView = NSStackView()
    let emptyGlyph = NSImageView()
    let emptyTitleField = ShellFont.label(
        "No page loaded",
        font: ShellFont.ui(13, .medium),
        color: ShellPalette.inkSecondary
    )
    let emptySubtitleField = ShellFont.label(
        "Enter an address or pick a detected port",
        font: ShellFont.ui(12),
        color: ShellPalette.inkMuted
    )

    private let navBar = NSView()
    private let suggestionsBar = NSView()
    private let suggestionsStack = NSStackView()
    private let contentContainer = NSView()
    private var observations: [NSKeyValueObservation] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = ShellPalette.content.cgColor

        backButton.onPress = { [weak self] in self?.currentNavigator?.goBack() }
        forwardButton.onPress = { [weak self] in self?.currentNavigator?.goForward() }
        reloadButton.onPress = { [weak self] in self?.currentNavigator?.reload() }

        let fieldBox = NSView()
        fieldBox.wantsLayer = true
        fieldBox.layer?.backgroundColor = ShellPalette.fieldFill.cgColor
        fieldBox.layer?.cornerRadius = 5
        fieldBox.layer?.cornerCurve = .continuous
        fieldBox.layer?.borderWidth = 1
        fieldBox.layer?.borderColor = ShellPalette.hairline.cgColor
        fieldBox.translatesAutoresizingMaskIntoConstraints = false

        urlField.placeholderString = "Search or enter address"
        urlField.font = ShellFont.mono(12)
        urlField.textColor = ShellPalette.inkSecondary
        urlField.isBordered = false
        urlField.drawsBackground = false
        urlField.focusRingType = .none
        urlField.translatesAutoresizingMaskIntoConstraints = false
        urlField.target = self
        urlField.action = #selector(commitURL)
        fieldBox.addSubview(urlField)

        let barHairline = NSView()
        barHairline.wantsLayer = true
        barHairline.layer?.backgroundColor = ShellPalette.hairline.cgColor
        barHairline.translatesAutoresizingMaskIntoConstraints = false

        for view in [backButton, forwardButton, reloadButton, fieldBox, barHairline] as [NSView] {
            navBar.addSubview(view)
        }
        NSLayoutConstraint.activate([
            backButton.leadingAnchor.constraint(equalTo: navBar.leadingAnchor, constant: 8),
            backButton.centerYAnchor.constraint(equalTo: navBar.centerYAnchor),
            forwardButton.leadingAnchor.constraint(equalTo: backButton.trailingAnchor, constant: 2),
            forwardButton.centerYAnchor.constraint(equalTo: navBar.centerYAnchor),
            reloadButton.leadingAnchor.constraint(equalTo: forwardButton.trailingAnchor, constant: 2),
            reloadButton.centerYAnchor.constraint(equalTo: navBar.centerYAnchor),

            fieldBox.leadingAnchor.constraint(equalTo: reloadButton.trailingAnchor, constant: 8),
            fieldBox.trailingAnchor.constraint(equalTo: navBar.trailingAnchor, constant: -8),
            fieldBox.centerYAnchor.constraint(equalTo: navBar.centerYAnchor),
            fieldBox.heightAnchor.constraint(equalToConstant: 22),
            urlField.leadingAnchor.constraint(equalTo: fieldBox.leadingAnchor, constant: 8),
            urlField.trailingAnchor.constraint(equalTo: fieldBox.trailingAnchor, constant: -8),
            urlField.centerYAnchor.constraint(equalTo: fieldBox.centerYAnchor),

            barHairline.leadingAnchor.constraint(equalTo: navBar.leadingAnchor),
            barHairline.trailingAnchor.constraint(equalTo: navBar.trailingAnchor),
            barHairline.bottomAnchor.constraint(equalTo: navBar.bottomAnchor),
            barHairline.heightAnchor.constraint(equalToConstant: 1),
        ])

        suggestionsStack.orientation = .horizontal
        suggestionsStack.alignment = .centerY
        suggestionsStack.spacing = 6
        suggestionsStack.translatesAutoresizingMaskIntoConstraints = false
        suggestionsBar.addSubview(suggestionsStack)
        NSLayoutConstraint.activate([
            suggestionsStack.leadingAnchor.constraint(equalTo: suggestionsBar.leadingAnchor, constant: 10),
            suggestionsStack.trailingAnchor.constraint(
                lessThanOrEqualTo: suggestionsBar.trailingAnchor, constant: -10
            ),
            suggestionsStack.centerYAnchor.constraint(equalTo: suggestionsBar.centerYAnchor),
        ])

        emptyGlyph.image = NSImage(
            systemSymbolName: "globe",
            accessibilityDescription: "No page loaded"
        )?.withSymbolConfiguration(.init(pointSize: 26, weight: .medium))
        emptyGlyph.contentTintColor = ShellPalette.inkFainter

        emptyStateView.orientation = .vertical
        emptyStateView.alignment = .centerX
        emptyStateView.spacing = 4
        emptyStateView.setViews([emptyGlyph, emptyTitleField, emptySubtitleField], in: .center)
        emptyStateView.setCustomSpacing(10, after: emptyGlyph)
        emptyStateView.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(emptyStateView)
        NSLayoutConstraint.activate([
            emptyStateView.centerXAnchor.constraint(equalTo: contentContainer.centerXAnchor),
            emptyStateView.centerYAnchor.constraint(equalTo: contentContainer.centerYAnchor),
        ])

        for view in [navBar, suggestionsBar, contentContainer] { addSubview(view) }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Browser tab")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        applyLayout()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        applyLayout()
    }

    private func applyLayout() {
        navBar.frame = NSRect(x: 0, y: 0, width: bounds.width, height: Self.navBarHeight)
        let suggestions = suggestedPorts.isEmpty ? 0 : Self.suggestionsHeight
        suggestionsBar.frame = NSRect(
            x: 0, y: Self.navBarHeight, width: bounds.width, height: suggestions
        )
        suggestionsBar.isHidden = suggestedPorts.isEmpty
        contentContainer.frame = NSRect(
            x: 0,
            y: Self.navBarHeight + suggestions,
            width: bounds.width,
            height: max(0, bounds.height - Self.navBarHeight - suggestions)
        )
        webView?.frame = contentContainer.bounds
    }

    // MARK: - Normalization

    /// The browser pane's rule, reused verbatim: bare local hosts get
    /// http://, bare domains https://, real URLs pass through, anything else
    /// is a search. One door means the two browser surfaces cannot drift.
    static func destination(for input: String) -> URL? {
        BrowserPaneView.destination(for: input)
    }

    // MARK: - Port detection

    /// The dev-server shapes the spec names — `localhost:PORT` and
    /// `127.0.0.1:PORT` — pulled out of terminal lines. Most recent first
    /// (the server still talking is the one the user wants), each port once,
    /// and only ports a TCP socket could actually wear. The lookbehind keeps
    /// `mylocalhost:3000` out; the lookahead keeps `localhost:300000` from
    /// matching as 30000-and-change.
    static func detectPorts(in lines: [String]) -> [Int] {
        guard let regex = try? NSRegularExpression(
            pattern: #"(?<![\w.])(?:localhost|127\.0\.0\.1):(\d{1,5})(?!\d)"#,
            options: [.caseInsensitive]
        ) else { return [] }
        var ports: [Int] = []
        var seen: Set<Int> = []
        for line in lines.reversed() {
            let range = NSRange(line.startIndex..., in: line)
            for match in regex.matches(in: line, range: range) {
                guard
                    let portRange = Range(match.range(at: 1), in: line),
                    let port = Int(line[portRange]),
                    (1...65535).contains(port),
                    seen.insert(port).inserted
                else { continue }
                ports.append(port)
            }
        }
        return ports
    }

    /// Rescans: terminal lines in, chips out. What the controller calls with
    /// the session's `visibleTailLines` on every tab activation.
    func updatePortSuggestions(fromTerminalLines lines: [String]) {
        setSuggestedPorts(Self.detectPorts(in: lines))
    }

    /// Rebuilds the chip row. An empty set clears it — a server that has
    /// exited must not keep being advertised.
    func setSuggestedPorts(_ ports: [Int]) {
        guard suggestedPorts != ports else { return }
        suggestedPorts = ports
        for view in suggestionsStack.arrangedSubviews { view.removeFromSuperview() }
        suggestionChips = ports.map { port in
            let chip = ReviewPanelPortChipView(port: port)
            chip.onPress = { [weak self] in self?.navigate(to: chip.title) }
            return chip
        }
        for chip in suggestionChips { suggestionsStack.addArrangedSubview(chip) }
        needsLayout = true
        applyLayout()
    }

    // MARK: - Navigation

    /// One door for every navigation: normalize, mirror into the field, hand
    /// to the navigator. The empty state stands down on the first real load.
    func navigate(to input: String) {
        guard let url = Self.destination(for: input) else { return }
        urlField.stringValue = url.absoluteString
        emptyStateView.isHidden = true
        ensureNavigator().load(url)
    }

    @objc private func commitURL() {
        navigate(to: urlField.stringValue)
        if let webView { window?.makeFirstResponder(webView) }
    }

    /// The navigator to route a button through — nil while no page has ever
    /// loaded, so a stray back-press does not conjure a WebKit process.
    private var currentNavigator: ReviewPanelBrowserNavigator? {
        navigatorForTesting ?? webNavigator
    }

    /// The navigator a navigation goes through, built if need be.
    private func ensureNavigator() -> ReviewPanelBrowserNavigator {
        if let navigatorForTesting { return navigatorForTesting }
        if let webNavigator { return webNavigator }
        let configuration = WKWebViewConfiguration()
        configuration.processPool = BrowserPaneView.sharedProcessPool
        let web = WKWebView(frame: contentContainer.bounds, configuration: configuration)
        web.autoresizingMask = [.width, .height]
        if #available(macOS 13.3, *) { web.isInspectable = true }
        contentContainer.addSubview(web)
        observations = [
            web.observe(\.url) { [weak self] web, _ in
                guard let self, let url = web.url else { return }
                urlField.stringValue = url.absoluteString
            },
        ]
        webView = web
        let navigator = WebKitNavigator(webView: web)
        webNavigator = navigator
        applyLayout()
        return navigator
    }

    private var webNavigator: WebKitNavigator?

    /// The real navigator: the same load rule as `BrowserPaneView.load` —
    /// a `file://` URL must go through `loadFileURL` with a read-access
    /// grant, or WebKit refuses it silently.
    private final class WebKitNavigator: ReviewPanelBrowserNavigator {
        let webView: WKWebView
        init(webView: WKWebView) { self.webView = webView }
        func load(_ url: URL) {
            if url.isFileURL {
                webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
            } else {
                webView.load(URLRequest(url: url))
            }
        }
        func goBack() { webView.goBack() }
        func goForward() { webView.goForward() }
        func reload() { webView.reload() }
    }
}
