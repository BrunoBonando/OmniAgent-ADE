import AppKit
import WebKit

/// A browser pane's content: a WKWebView under a slim URL/nav bar. The
/// PTY-shaped half of `PaneContentView` is deliberately a no-op — WebKit
/// lays itself out and manages its own occlusion/process suspension.
final class BrowserPaneView: NSView, PaneContentView {
    static let toolbarHeight: CGFloat = 34
    /// One pool for every browser pane, so N panes share renderer processes
    /// instead of each paying for their own.
    static let sharedProcessPool = WKProcessPool()

    let webView: WKWebView
    let urlField = NSTextField()
    private let backButton = NSButton()
    private let forwardButton = NSButton()
    private let reloadButton = NSButton()

    var onTitleChange: ((String) -> Void)?
    /// Fires on every committed navigation — what keeps the descriptor's
    /// `browserURL` (and through it the persisted last URL) current.
    var onURLChange: ((String) -> Void)?

    // MARK: - PaneContentView
    var isSelected = false
    var suspendsDrawing = false
    weak var resizeCoalescer: PaneResizeCoalescer?
    var primaryResponderView: NSView { webView }
    func focus() {
        // A blank browser is one you are about to type an address into.
        window?.makeFirstResponder(webView.url == nil ? urlField : webView)
    }
    func scheduleResize() {}
    func flushResize() {}

    private var observations: [NSKeyValueObservation] = []

    init(initialURL: String) {
        let configuration = WKWebViewConfiguration()
        configuration.processPool = Self.sharedProcessPool
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = PaneContainerView.paneBackgroundColor.cgColor
        if #available(macOS 13.3, *) { webView.isInspectable = WebInspectorPolicy.isEnabled() }
        webView.navigationDelegate = self
        webView.uiDelegate = self

        configureButton(backButton, symbol: "chevron.left", action: #selector(goBack))
        configureButton(forwardButton, symbol: "chevron.right", action: #selector(goForward))
        configureButton(reloadButton, symbol: "arrow.clockwise", action: #selector(reload))
        urlField.placeholderString = "Search or enter address"
        urlField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        urlField.bezelStyle = .roundedBezel
        urlField.target = self
        urlField.action = #selector(commitURL)
        for view in [backButton, forwardButton, reloadButton, urlField, webView] as [NSView] {
            addSubview(view)
        }

        observations = [
            webView.observe(\.title) { [weak self] webView, _ in
                self?.onTitleChange?(webView.title ?? "")
            },
            webView.observe(\.url) { [weak self] webView, _ in
                guard let self, let url = webView.url else { return }
                urlField.stringValue = url.absoluteString
                onURLChange?(url.absoluteString)
            },
            webView.observe(\.canGoBack) { [weak self] webView, _ in
                self?.backButton.isEnabled = webView.canGoBack
            },
            webView.observe(\.canGoForward) { [weak self] webView, _ in
                self?.forwardButton.isEnabled = webView.canGoForward
            },
        ]
        backButton.isEnabled = false
        forwardButton.isEnabled = false

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Browser pane")

        if let url = Self.destination(for: initialURL) {
            urlField.stringValue = url.absoluteString
            load(url)
        }
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
        let inset: CGFloat = 6
        let buttonWidth: CGFloat = 26
        var x = inset
        for button in [backButton, forwardButton, reloadButton] {
            button.frame = NSRect(x: x, y: (Self.toolbarHeight - 22) / 2, width: buttonWidth, height: 22)
            x += buttonWidth + 2
        }
        urlField.frame = NSRect(
            x: x + 4,
            y: (Self.toolbarHeight - 22) / 2,
            width: max(0, bounds.width - x - 4 - inset),
            height: 22
        )
        webView.frame = NSRect(
            x: 0,
            y: Self.toolbarHeight,
            width: bounds.width,
            height: max(0, bounds.height - Self.toolbarHeight)
        )
    }

    private func configureButton(_ button: NSButton, symbol: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.bezelStyle = .accessoryBarAction
        button.isBordered = false
        button.target = self
        button.action = action
    }

    /// One door for every load. A `file://` URL cannot go through `URLRequest`:
    /// WebKit refuses to read it without an explicit read-access grant and
    /// fails silently, which is why typing a path did nothing. Local files take
    /// `loadFileURL`, scoped to the file's own folder so its siblings (an
    /// image's stylesheet, a page's assets) resolve.
    func load(_ url: URL) {
        if url.isFileURL {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            webView.load(URLRequest(url: url))
        }
    }

    @objc private func goBack() { webView.goBack() }
    @objc private func goForward() { webView.goForward() }
    @objc private func reload() { webView.reload() }

    @objc private func commitURL() {
        guard let url = Self.destination(for: urlField.stringValue) else { return }
        load(url)
        window?.makeFirstResponder(webView)
    }

    /// What typing in the URL bar means: a real URL loads, an absolute or
    /// tilde path is a local file, a hostname gets https:// (http:// for
    /// localhost/loopback), anything else is a search.
    static func destination(for input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") {
            return URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath)
        }
        if let url = URL(string: trimmed),
           let scheme = url.scheme?.lowercased(),
           ["http", "https", "file"].contains(scheme) {
            return url
        }
        let lowered = trimmed.lowercased()
        if lowered.hasPrefix("localhost") || lowered.hasPrefix("127.0.0.1") {
            return URL(string: "http://\(trimmed)")
        }
        if !trimmed.contains(" "), trimmed.contains(".") {
            return URL(string: "https://\(trimmed)")
        }
        var components = URLComponents(string: "https://www.google.com/search")!
        components.queryItems = [URLQueryItem(name: "q", value: trimmed)]
        return components.url
    }

    /// Pure so it is testable without touching the real ~/Downloads.
    static func downloadDestination(
        suggestedFilename: String,
        in directory: URL,
        fileExists: (String) -> Bool
    ) -> URL {
        var target = directory.appendingPathComponent(suggestedFilename)
        let base = (suggestedFilename as NSString).deletingPathExtension
        let ext = (suggestedFilename as NSString).pathExtension
        var counter = 1
        while fileExists(target.path) {
            let name = ext.isEmpty ? "\(base)-\(counter)" : "\(base)-\(counter).\(ext)"
            target = directory.appendingPathComponent(name)
            counter += 1
        }
        return target
    }
}

extension BrowserPaneView: WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .download)
    }

    func webView(
        _ webView: WKWebView,
        navigationResponse: WKNavigationResponse,
        didBecome download: WKDownload
    ) {
        download.delegate = self
    }

    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping (URL?) -> Void
    ) {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        completionHandler(Self.downloadDestination(
            suggestedFilename: suggestedFilename,
            in: downloads,
            fileExists: FileManager.default.fileExists(atPath:)
        ))
    }

    /// target=_blank / window.open land in this same pane — one page per
    /// pane, split panes for more. ponytail: no tab strip until asked for.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = navigationAction.request.url {
            load(url)
        }
        return nil
    }
}
