import AppKit
import WebKit

/// The Monaco host: one WKWebView per editor pane, running the bundled
/// `Resources/monaco/editor.html`. This class is the whole bridge — typed
/// commands down via `evaluateJavaScript`, typed events up via one
/// `WKScriptMessageHandler`. Swift owns all file I/O; the page never sees a
/// URL outside its own bundle folder, and is loaded with `loadFileURL` from
/// the app bundle — never over http, never from a remote origin.
final class EditorWebView: NSView, WKScriptMessageHandler, WKNavigationDelegate {
    /// The JS→Swift message handler name. `bridge.js` posts to
    /// `window.webkit.messageHandlers.editor`.
    static let messageHandlerName = "editor"

    /// One pool for every editor pane, so N panes share renderer processes
    /// instead of each paying for its own copy of Monaco's ~4 MB of script.
    /// Mirrors `BrowserPaneView.sharedProcessPool`.
    static let sharedProcessPool = WKProcessPool()

    let webView: WKWebView
    private(set) var isReady = false
    /// Commands issued before Monaco's `ready` land here and replay in order.
    private var queued: [String] = []
    /// A page that never reaches `ready` must not turn the queue into an
    /// unbounded retainer of whole file contents. Far above any real pre-ready
    /// burst (a pane opens a handful of models), so eviction means something
    /// is wrong, not that a normal workload is being trimmed.
    static let maxQueuedCharacters = 8 * 1024 * 1024
    private var queuedCharacters = 0
    private let contentController: WKUserContentController
    private let messageProxy: MessageProxy

    var onReady: (() -> Void)?
    var onDirtyChanged: ((String, Bool) -> Void)?
    var onSnapshot: ((String, String) -> Void)?
    var onSaveRequested: ((String) -> Void)?
    var onChangesOpen: ((String, Bool) -> Void)?
    var onRequestFileDiff: ((String) -> Void)?
    var onCrash: (() -> Void)?

    override init(frame frameRect: NSRect) {
        // The handler must be registered *before* the web view exists:
        // `WKWebView.configuration` is `@NSCopying`, so a handler added to the
        // configuration afterwards is easy to add to the wrong copy. Registering
        // a proxy that holds its owner weakly also breaks the classic
        // WKUserContentController → handler → view retain cycle.
        let proxy = MessageProxy()
        let controller = WKUserContentController()
        controller.add(proxy, name: Self.messageHandlerName)
        messageProxy = proxy
        contentController = controller

        let configuration = WKWebViewConfiguration()
        configuration.processPool = Self.sharedProcessPool
        configuration.userContentController = controller
        webView = WKWebView(frame: .zero, configuration: configuration)

        super.init(frame: frameRect)
        messageProxy.owner = self

        wantsLayer = true
        layer?.backgroundColor = PaneContainerView.paneBackgroundColor.cgColor
        webView.isInspectable = true
        webView.navigationDelegate = self
        // The page paints #0c0c0f itself; this is what WebKit paints *under* it,
        // so there is no white flash between attach and first paint. (The public
        // macOS 12+ replacement for the old `drawsBackground` KVC hack.)
        webView.underPageBackgroundColor = PaneContainerView.paneBackgroundColor
        addSubview(webView)
        webView.frame = bounds
        loadPage()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    deinit {
        contentController.removeScriptMessageHandler(forName: Self.messageHandlerName)
    }

    override var isFlipped: Bool { true }
    override func layout() {
        super.layout()
        webView.frame = bounds
    }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        webView.frame = bounds
    }

    private func loadPage() {
        guard
            let page = Bundle.main.url(forResource: "editor", withExtension: "html", subdirectory: "monaco"),
            let folder = Bundle.main.url(forResource: "monaco", withExtension: nil)
        else {
            assertionFailure("monaco assets missing from the bundle")
            return
        }
        webView.loadFileURL(page, allowingReadAccessTo: folder)
    }

    // MARK: - Commands (Swift -> JS)

    /// One JSON-escaped JS string literal. Foundation only encodes top-level
    /// arrays/objects portably, so wrap-and-strip.
    static func jsLiteral(_ value: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [value])) ?? Data("[\"\"]".utf8)
        let array = String(data: data, encoding: .utf8) ?? "[\"\"]"
        return String(array.dropFirst().dropLast())
    }

    private func run(_ script: String) {
        guard isReady else {
            queued.append(script)
            queuedCharacters += script.count
            // Evict oldest first: these are per-path state setters, so the most
            // recent commands describe the state the owner actually wants.
            while queuedCharacters > Self.maxQueuedCharacters, !queued.isEmpty {
                queuedCharacters -= queued.removeFirst().count
            }
            return
        }
        webView.evaluateJavaScript(script)
    }

    private func dropQueue() {
        queued = []
        queuedCharacters = 0
    }

    func openModel(path: String, content: String, readOnly: Bool) {
        run("window.omniagent.openModel(\(Self.jsLiteral(path)), \(Self.jsLiteral(content)), \(readOnly))")
    }
    func setContent(path: String, content: String) {
        run("window.omniagent.setContent(\(Self.jsLiteral(path)), \(Self.jsLiteral(content)))")
    }
    func showModel(path: String) { run("window.omniagent.showModel(\(Self.jsLiteral(path)))") }
    /// `versionId` is the model version whose text was actually written to
    /// disk. The page refuses to rebase a buffer that has moved on since, so a
    /// keystroke typed inside the `requestContent` -> write round trip stays
    /// dirty instead of being silently marked saved. `nil` rebases
    /// unconditionally, for callers with no write to race.
    func markSaved(path: String, versionId: Int? = nil) {
        run("window.omniagent.markSaved(\(Self.jsLiteral(path)), \(versionId.map(String.init) ?? "null"))")
    }
    func closeModel(path: String) { run("window.omniagent.closeModel(\(Self.jsLiteral(path)))") }
    func showDiff(path: String, original: String, modified: String) {
        run("window.omniagent.showDiff(\(Self.jsLiteral(path)), \(Self.jsLiteral(original)), \(Self.jsLiteral(modified)))")
    }
    func showChanges(files: [(path: String, badge: String)]) {
        let payload = files.map { ["path": $0.path, "badge": $0.badge] }
        let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("[]".utf8)
        run("window.omniagent.showChanges(\(String(data: data, encoding: .utf8) ?? "[]"))")
    }
    func appendFileDiff(path: String, text: String) {
        run("window.omniagent.appendFileDiff(\(Self.jsLiteral(path)), \(Self.jsLiteral(text)))")
    }
    func showMessage(_ text: String) { run("window.omniagent.showMessage(\(Self.jsLiteral(text)))") }

    /// Drives `model.setValue` *without* rebasing the saved version, i.e. what
    /// typing in the editor looks like from the outside. `setContent` above
    /// deliberately does rebase, so it cannot stand in for a keystroke in tests.
    func setContentForTesting(path: String, content: String) {
        run("window.omniagent.typeForTesting(\(Self.jsLiteral(path)), \(Self.jsLiteral(content)))")
    }

    /// The buffer *and* the model version it was taken at — the two have to
    /// travel together, or `markSaved` cannot tell a saved buffer from one
    /// that was edited while the save was in flight.
    func requestContent(path: String, completion: @escaping (String?, Int?) -> Void) {
        guard isReady else {
            completion(nil, nil)
            return
        }
        webView.evaluateJavaScript("window.omniagent.getContent(\(Self.jsLiteral(path)))") { value, _ in
            guard let payload = value as? [String: Any] else {
                completion(nil, nil)
                return
            }
            completion(payload["content"] as? String, payload["versionId"] as? Int)
        }
    }

    // MARK: - Events (JS -> Swift)

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "ready":
            isReady = true
            let replay = queued
            dropQueue()
            for script in replay { webView.evaluateJavaScript(script) }
            onReady?()
        case "dirtyChanged":
            if let path = body["path"] as? String, let dirty = body["dirty"] as? Bool {
                onDirtyChanged?(path, dirty)
            }
        case "contentSnapshot":
            if let path = body["path"] as? String, let content = body["content"] as? String {
                onSnapshot?(path, content)
            }
        case "saveRequested":
            if let path = body["path"] as? String { onSaveRequested?(path) }
        case "changesOpen":
            if let path = body["path"] as? String {
                onChangesOpen?(path, (body["target"] as? String) != "file")
            }
        case "requestFileDiff":
            if let path = body["path"] as? String { onRequestFileDiff?(path) }
        default:
            break
        }
    }

    /// WebKit's renderer died. Reload the page; the owner re-opens models
    /// (with its crash snapshots) when `onReady` fires again.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        isReady = false
        dropQueue()
        onCrash?()
        loadPage()
    }

    /// The page could not load at all. Nothing will ever replay, so let go of
    /// the queued content rather than retain it for the life of the pane.
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        dropQueue()
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        dropQueue()
    }

    /// Holds its owner weakly so the content controller cannot pin the view
    /// alive; see the note in `init`.
    private final class MessageProxy: NSObject, WKScriptMessageHandler {
        weak var owner: EditorWebView?
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            owner?.userContentController(controller, didReceive: message)
        }
    }
}
