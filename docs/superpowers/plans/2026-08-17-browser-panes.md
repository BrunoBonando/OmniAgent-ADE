# Browser Panes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user add a browser (WKWebView) or a terminal to any pane of the native macOS pane grid, plus (milestone 2) a console pane that mirrors and drives a browser pane from a different pane.

**Architecture:** Cut a `PaneContentView` protocol seam at `PaneContainerView.surface` (currently hard-typed `TerminalSurfaceView`), add a `kind` discriminator to `PaneDescriptor`/`RestoredPane`, branch `WorkspaceWindowController`'s four session-lifecycle choke points on kind, and persist browser panes' last URLs in a **native-only** settings row (never the shared `"layout"` row). `PaneGrid` stays kind-blind (fixture-pinned to the TypeScript oracle).

**Tech Stack:** Swift / AppKit / WebKit (WKWebView), XCTest. Build/test: `./macos/build.sh test` (Xcode only, no Rust needed).

**Spec:** `docs/superpowers/specs/2026-08-17-browser-panes-design.md`

## Global Constraints

- All work in `macos/` only. **No `ui/` changes, no daemon-protocol changes, no MCP changes.**
- `PaneGrid`/`PaneCell`/`PaneGridShape` must not learn about pane kinds (fixture parity with `fixtures/native-macos-compat/pane-grid.json`).
- Browser is a pane **kind**, never a new `Engine` case.
- The shared `"layout"` settings row must remain byte-identical whether or not browser panes exist (web codec drops unknown-engine tabs / strips unknown fields).
- Browser panes never reach `ensureSession`/`createSession`/`connection.kill` (a browser id reaching `createSession` silently spawns a login shell).
- Browser panes do NOT count against `PaneWorkspaceView.maxTerminals` (64, the PTY budget); only the 8-per-session grid geometry bounds them.
- New source files must be registered in `macos/OmniAgent.xcodeproj/project.pbxproj` by hand (the project uses explicit `PBXFileReference`/`PBXBuildFile` entries with hand-rolled hex IDs like `20000000000000000000050` — copy the pattern, pick unused IDs, add to the group's `children` and the right target's Sources phase; app files go in the OmniAgent target, test files in OmniAgentTests).
- Every commit: conventional message + trailers:
  `Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>`
  `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`
  `Claude-Session: https://claude.ai/code/session_01GBL2GzAComVkVNuSewWtN5`
- **Push after every commit** (`git push`). Never `git stash` (shared working tree with concurrent sessions).
- Run the full suite (`./macos/build.sh test`) before every commit; commit only green.

---

### Task 1: The seam — `PaneContentView` protocol, kind on the descriptor, suite green

Purely mechanical retype. **No behavior change, no browser code.** The existing test suite is the test; it must pass unmodified in behavior (only types/callsites updated).

**Files:**
- Create: `macos/OmniAgent/PaneContentView.swift`
- Modify: `macos/OmniAgent/PaneWorkspaceView.swift` (PaneDescriptor ~18-74, makeSurface 172/185, surface accessors 247-251, addPane 259-304, reclaimFirstResponder 723-727, PaneContainerView 1335-1424, roundChildren 1549-1562)
- Modify: `macos/OmniAgent/TerminalSurfaceView.swift` (conformance)
- Modify: `macos/OmniAgent/WorkspaceRestoration.swift` (RestoredPane fields)
- Modify: `macos/OmniAgent/WorkspaceWindowController.swift` (factory 213-215, initialFirstResponder 295-296, run(_:) 940-943, onTerminalData 487, reportSessionFailure 1421, addPane title wiring 1284-1298)
- Modify: `macos/OmniAgentTests/PaneWorkspaceViewTests.swift` (makeWorkspace 1546-1557 and every `container.surface.terminalView` deref), `macos/OmniAgentTests/WorkspaceWindowControllerTests.swift`, `macos/OmniAgentTests/WorkspaceRestorationTests.swift` (RestoredPane constructor call sites — defaults should make most compile unchanged)

**Interfaces (later tasks rely on these exact names):**

```swift
// PaneContentView.swift
enum PaneKind: String, Equatable {
    case terminal
    case browser
}

/// The container's real contract with its content — what PaneContainerView,
/// the resize coalescer and the focus machinery actually call. A terminal
/// implements all of it; a browser no-ops the PTY-shaped half.
protocol PaneContentView: NSView {
    var isSelected: Bool { get set }
    var suspendsDrawing: Bool { get set }
    var resizeCoalescer: PaneResizeCoalescer? { get set }
    /// The view keyboard focus should land on — what
    /// `window.initialFirstResponder` and `focus()` aim at.
    var primaryResponderView: NSView { get }
    func focus()
    func scheduleResize()
    func flushResize()
}
```

- `PaneDescriptor` gains `var kind: PaneKind` and `var browserURL: String` — appended to the explicit init as `kind: PaneKind = .terminal, browserURL: String = ""` so every existing call site compiles unchanged. `init(_ pane: RestoredPane)` passes both through.
- `RestoredPane` gains `let kind: PaneKind` / `let browserURL: String` plus an explicit init with the same defaults (the struct currently relies on the implicit memberwise init — write the explicit one now, all fields, defaults on the two new ones).
- `PaneWorkspaceView.init(makeSurface: @escaping (PaneDescriptor) -> any PaneContentView)` — the factory takes the full descriptor now.
- `PaneWorkspaceView.surface(for:) -> (any PaneContentView)?` (same name, widened type) plus a new convenience:
  ```swift
  func terminalSurface(for sessionID: String) -> TerminalSurfaceView? {
      containers[sessionID]?.surface as? TerminalSurfaceView
  }
  ```
- `PaneContainerView.surface` becomes `let surface: any PaneContentView` (init param too).

**Steps:**

- [ ] **Step 1: Create `PaneContentView.swift`** with the code above. Register it in `project.pbxproj` (OmniAgent target).

- [ ] **Step 2: Conform `TerminalSurfaceView`** — it already has every member except:

```swift
extension TerminalSurfaceView: PaneContentView {
    var primaryResponderView: NSView { terminalView }
}
```

(`resizeCoalescer` is `weak var` — that satisfies the protocol's `{ get set }`.)

- [ ] **Step 3: Retype `PaneWorkspaceView`**:
  - `private let makeSurface: (PaneDescriptor) -> any PaneContentView`; init signature to match.
  - `addPane`: `surface: makeSurface(descriptor)` instead of `makeSurface(descriptor.sessionID)`.
  - `reclaimFirstResponder` — replace the identity check with a descendant check (WKWebView's actual responder is an internal `WKContentView`, so identity can never work for it; the descendant check is also correct for the terminal, whose `terminalView` is a descendant of the surface):

```swift
private func reclaimFirstResponder(_ container: PaneContainerView) {
    guard let window, focusedPaneID == container.paneID else { return }
    if let view = window.firstResponder as? NSView, view.isDescendant(of: container.surface) {
        return
    }
    container.surface.focus()
}
```

  - `PaneContainerView.surface`/init param → `any PaneContentView`. In `roundChildren` the tuple array now needs an explicit upcast: `for (child, corners) in [(header as NSView, CACornerMask([...])), (surface as NSView, CACornerMask([...]))]`.
  - Everything else (`scheduleResize`, `flushResize`, `suspendsDrawing`, `isSelected`, `focus`) already compiles against the protocol.

- [ ] **Step 4: Add kind/browserURL to `PaneDescriptor` and `RestoredPane`** exactly as in Interfaces.

- [ ] **Step 5: Update `WorkspaceWindowController`**:
  - Factory (init):

```swift
workspace = PaneWorkspaceView { descriptor in
    TerminalSurfaceView(connection: connection, sessionID: descriptor.sessionID)
}
```

  - `initialFirstResponder`: `workspace.focusedPaneID.flatMap { workspace.surface(for: $0)?.primaryResponderView }`
  - `onTerminalData`, `reportSessionFailure`, `run(_:)`'s `.interruptFocusedPane`/`.reattachFocusedPane`, and `addPane`'s `onTitleChange`/`onDirectoryChange` wiring: use `workspace.terminalSurface(for:)` (they need the concrete type).

- [ ] **Step 6: Update tests mechanically.** `makeWorkspace`'s factory closure becomes `{ descriptor in TerminalSurfaceView(connection: connection, sessionID: descriptor.sessionID) }`. Every `container.surface.terminalView` / `surface(for:)!.terminalView` becomes `terminalSurface(for:)` or `(container.surface as? TerminalSurfaceView)?.terminalView` — add a tiny test helper if it reads better. No assertion changes.

- [ ] **Step 7: Run `./macos/build.sh test`** — entire suite green.

- [ ] **Step 8: Commit + push**: `refactor(macos): pane content behind a PaneContentView protocol seam`

---

### Task 2: Lifecycle guards — non-terminal panes never touch the daemon

**Files:**
- Modify: `macos/OmniAgent/PaneWorkspaceView.swift` (addPane guard 263-269, new `terminalPaneCount`)
- Modify: `macos/OmniAgent/WorkspaceWindowController.swift` (addPane 1253-1301, ensureSession loops 799 + 844, closePane 744-756, reapOrphanedSessions 879, validateMenuItem 758-767, preflights 613-615/655/677/689; fix the stale "caps at 8" comment at ~857 — `MAX_SESSIONS` is 64)
- Modify: `macos/OmniAgent/CommandPalette.swift` (interrupt/reattach rows 101-117)
- Test: `macos/OmniAgentTests/WorkspaceWindowControllerTests.swift`, `macos/OmniAgentTests/PaneWorkspaceViewTests.swift`, `macos/OmniAgentTests/CommandPaletteTests.swift`

**Interfaces:**
- Produces: `PaneWorkspaceView.terminalPaneCount: Int`; controller test seams `var sessionEnsurer: ((String) -> Void)?` and `var sessionKiller: ((String) -> Void)?` (nil in production, same pattern as the existing `settingsWriter`).

**Steps:**

- [ ] **Step 1: Write failing tests** (WorkspaceWindowControllerTests — construct the controller the way existing tests there do, with a dead-socket `SessionConnection`):

```swift
func testBrowserPanesNeverEnsureOrKillDaemonSessions() {
    let controller = makeController() // existing helper pattern in this file
    var ensured: [String] = []
    var killed: [String] = []
    controller.sessionEnsurer = { ensured.append($0) }
    controller.sessionKiller = { killed.append($0) }

    controller.applyRestoredPanes([
        RestoredPane(
            sessionID: "term-1", reattaches: true, project: "p", engine: .shell,
            cwd: "/tmp", label: nil, themeId: nil, group: "g1", groupLabel: nil
        ),
    ])
    controller.workspaceView.addPane(
        PaneDescriptor(sessionID: "web-1", group: "g1", kind: .browser, browserURL: "https://example.com")
    )
    // A later restore pass (reconnect path) must skip the browser pane.
    controller.applyRestoredPanes([])
    XCTAssertFalse(ensured.contains("web-1"))
    XCTAssertTrue(ensured.contains("term-1"))

    controller.workspaceView.focusPane("web-1")
    controller.closePane(nil)
    XCTAssertEqual(killed, [], "closing a browser pane must not kill anything")

    controller.workspaceView.focusPane("term-1")
    controller.closePane(nil)
    XCTAssertEqual(killed, ["term-1"])
}
```

(PaneWorkspaceViewTests):

```swift
func testBrowserPanesDoNotCountAgainstTheTerminalCap() {
    let workspace = makeWorkspace(panes: 2)
    XCTAssertEqual(workspace.terminalPaneCount, 2)
    XCTAssertTrue(workspace.addPane(
        PaneDescriptor(sessionID: "web-1", group: "session-1", kind: .browser)
    ))
    XCTAssertEqual(workspace.terminalPaneCount, 2, "a browser consumes no PTY budget")
    XCTAssertEqual(workspace.allPaneIDs.count, 3)
}
```

(CommandPaletteTests): with a focused **browser** pane, `build(...)` contains the close-pane row but **not** interrupt/reattach rows; with a focused terminal it contains all three.

- [ ] **Step 2: Run** `./macos/build.sh test` — new tests FAIL (missing members / wrong behavior).

- [ ] **Step 3: Implement**:
  - `PaneWorkspaceView`:

```swift
/// The panes that actually hold a PTY — what `maxTerminals` is measured
/// against. Browser panes cost WebKit memory, not daemon slots.
var terminalPaneCount: Int {
    allPaneIDs.filter { descriptors[$0]?.kind == .terminal }.count
}
```

  and in `addPane`'s guard replace `allPaneIDs.count < Self.maxTerminals` with `descriptor.kind != .terminal || terminalPaneCount < Self.maxTerminals`.
  - Controller seams + kill helper:

```swift
/// Test seams, `settingsWriter`'s pattern: nil means the real daemon call.
var sessionEnsurer: ((String) -> Void)?
var sessionKiller: ((String) -> Void)?

private func killSession(_ id: String) {
    if let sessionKiller { sessionKiller(id) } else { connection.kill(sessionID: id) }
}
```

  At the top of `ensureSession`: `if let sessionEnsurer { sessionEnsurer(sessionID); return }`. `closePane` and `reapOrphanedSessions` route kills through `killSession(_:)`.
  - Both restore loops become: `for id in workspace.allPaneIDs where workspace.descriptor(for: id)?.kind == .terminal { ensureSession(id) }`
  - `closePane`: only `killSession(focused)` when `workspace.descriptor(for: focused)?.kind == .terminal` (the status-dictionary cleanup stays unconditional).
  - Controller `addPane`: wrap the terminal-only work in `if descriptor.kind == .terminal { ... }` — conversation claim, `usageRecorder.recordPaneOpened`, `onTitleChange`/`onDirectoryChange` wiring, and `if startSession { ensureSession(sessionID) }`. (Browser-side wiring arrives in Task 4.)
  - Preflights (`newPane` guard, `newSession`, `openWorkspaceFolder`, `startSession`, `validateMenuItem`'s `newTerminalPane`/`newSession` arms): replace `workspace.allPaneIDs.count < PaneWorkspaceView.maxTerminals` with `workspace.terminalPaneCount < PaneWorkspaceView.maxTerminals`.
  - `CommandPaletteModel.build`: append the interrupt/reattach rows only when `byID[focusedPaneID]?.kind == .terminal` (close-pane row stays for every kind).
  - Fix the stale "(8, in ...session.rs)" comment at ~857 to say 64.

- [ ] **Step 4: Run** `./macos/build.sh test` — all green.

- [ ] **Step 5: Commit + push**: `feat(macos): non-terminal pane kinds bypass daemon session lifecycle`

---

### Task 3: `BrowserPaneView`

**Files:**
- Create: `macos/OmniAgent/BrowserPaneView.swift` (register in pbxproj, OmniAgent target)
- Test: create `macos/OmniAgentTests/BrowserPaneViewTests.swift` (register, OmniAgentTests target)

**Interfaces:**
- Produces: `BrowserPaneView: NSView, PaneContentView` with `init(initialURL: String)`, `var onTitleChange: ((String) -> Void)?`, `var onURLChange: ((String) -> Void)?`, `let webView: WKWebView`, `static func destination(for input: String) -> URL?`, `static func downloadDestination(suggestedFilename: String, in directory: URL, fileExists: (String) -> Bool) -> URL`.

**Steps:**

- [ ] **Step 1: Write failing tests**:

```swift
final class BrowserPaneViewTests: XCTestCase {
    func testDestinationNormalizesInput() {
        XCTAssertEqual(BrowserPaneView.destination(for: "https://example.com")?.absoluteString, "https://example.com")
        XCTAssertEqual(BrowserPaneView.destination(for: "example.com")?.absoluteString, "https://example.com")
        XCTAssertEqual(BrowserPaneView.destination(for: "localhost:5173")?.absoluteString, "http://localhost:5173")
        XCTAssertEqual(BrowserPaneView.destination(for: "127.0.0.1:8080")?.absoluteString, "http://127.0.0.1:8080")
        XCTAssertEqual(
            BrowserPaneView.destination(for: "swift wkwebview")?.absoluteString,
            "https://www.google.com/search?q=swift%20wkwebview"
        )
        XCTAssertNil(BrowserPaneView.destination(for: "   "))
    }

    func testDownloadDestinationAvoidsOverwriting() {
        let dir = URL(fileURLWithPath: "/tmp/dl")
        var existing: Set<String> = [dir.appendingPathComponent("a.zip").path]
        let first = BrowserPaneView.downloadDestination(
            suggestedFilename: "a.zip", in: dir, fileExists: { existing.contains($0) }
        )
        XCTAssertEqual(first.lastPathComponent, "a-1.zip")
        existing.insert(first.path)
        XCTAssertEqual(
            BrowserPaneView.downloadDestination(
                suggestedFilename: "a.zip", in: dir, fileExists: { existing.contains($0) }
            ).lastPathComponent,
            "a-2.zip"
        )
    }

    func testConformsToPaneContentViewWithNoOpResizePipeline() {
        let view = BrowserPaneView(initialURL: "")
        XCTAssertTrue((view as Any) is any PaneContentView)
        XCTAssertIdentical(view.primaryResponderView, view.webView)
        view.scheduleResize()
        view.flushResize()
        view.suspendsDrawing = true
        view.isSelected = true // all no-ops; must not crash
    }

    func testTitlePublishingReachesTheHook() {
        let view = BrowserPaneView(initialURL: "")
        let published = expectation(description: "title")
        view.onTitleChange = { title in
            if title == "Hello Pane" { published.fulfill() }
        }
        view.webView.loadHTMLString("<title>Hello Pane</title><p>hi</p>", baseURL: nil)
        wait(for: [published], timeout: 10)
    }
}
```

- [ ] **Step 2: Run** — FAIL (type doesn't exist).

- [ ] **Step 3: Implement `BrowserPaneView.swift`**:

```swift
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
        if #available(macOS 13.3, *) { webView.isInspectable = true }
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
            webView.load(URLRequest(url: url))
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

    @objc private func goBack() { webView.goBack() }
    @objc private func goForward() { webView.goForward() }
    @objc private func reload() { webView.reload() }

    @objc private func commitURL() {
        guard let url = Self.destination(for: urlField.stringValue) else { return }
        webView.load(URLRequest(url: url))
        window?.makeFirstResponder(webView)
    }

    /// What typing in the URL bar means: a real URL loads, a hostname gets
    /// https:// (http:// for localhost/loopback), anything else is a search.
    static func destination(for input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
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
            webView.load(URLRequest(url: url))
        }
        return nil
    }
}
```

(The default `WKWebsiteDataStore.default()` is persistent and shared — cookies/logins stick across panes and relaunches with no configuration, which is the spec's shared-store behavior.)

- [ ] **Step 4: Run** `./macos/build.sh test` — green (the async title test may need the standard run-loop expectation; keep timeout ≥ 10s).

- [ ] **Step 5: Commit + push**: `feat(macos): BrowserPaneView — WKWebView pane content with URL bar and nav`

---

### Task 4: Wire browsers in — factory, ⇧⌘T everywhere, kind-aware chrome

**Files:**
- Modify: `macos/OmniAgent/WorkspaceWindowController.swift` (factory, addPane browser wiring, `newBrowserPane`, validateMenuItem, run(_:), sidebar callback)
- Modify: `macos/OmniAgent/AppDelegate.swift` (File menu ~112)
- Modify: `macos/OmniAgent/WorkspaceToolbar.swift` (fifth item)
- Modify: `macos/OmniAgent/CommandPalette.swift` (action + rows)
- Modify: `macos/OmniAgent/PaneWorkspaceView.swift` (hole tile, `onRequestNewBrowserPane`, container chrome, accessibility)
- Modify: `macos/OmniAgent/SessionOutline.swift` (naming)
- Modify: `macos/OmniAgent/WorkspaceShell.swift` (row icon, add-row)
- Test: `macos/OmniAgentTests/CommandPaletteTests.swift`, `macos/OmniAgentTests/SessionOutlineTests.swift`, `macos/OmniAgentTests/PaneWorkspaceViewTests.swift`, `macos/OmniAgentTests/WorkspaceWindowControllerTests.swift`

**Interfaces:**
- Produces: `WorkspaceWindowController.newBrowserPane(_:)` (`@objc`), `newBrowser(in: SessionGroupNode?) -> Bool`, `PaneWorkspaceView.onRequestNewBrowserPane: (() -> Void)?`, `PaneWorkspaceView.browserPane(for:) -> BrowserPaneView?`, `PaletteAction.newBrowserPane`, `SessionOutline.defaultPaneName(_ pane: PaneDescriptor) -> String`, `SessionOutline.nextPaneNumber(_:group:engine:kind:)` (kind defaulting `.terminal`), `WorkspaceSidebarView.onNewBrowser: (() -> Void)?`.

**Steps:**

- [ ] **Step 1: Failing tests first**:
  - SessionOutlineTests: `defaultPaneName` for a browser descriptor is `"Browser 1"`; label ladder for a browser pane: user label → page title → `browserURL` → `"Browser N"`; `nextPaneNumber` numbers browsers independently of shells in the same group; `isGeneratedPaneName("Browser 2")` is true.
  - CommandPaletteTests: `build` contains a `new-browser` row titled `"New browser pane"` with detail `"⇧⌘T"`; a browser pane's switch-to row detail is `"browser"` not an engine name.
  - PaneWorkspaceViewTests: adding a browser descriptor makes the container's accessibility label read `"Browser pane N of M"`; the hole placeholder invokes `onRequestNewBrowserPane` when its browser affordance is activated and `onRequestNewPane` otherwise.
  - WorkspaceWindowControllerTests: `newBrowser(in: nil)` adds a pane with `kind == .browser` into the focused pane's group, does not call `sessionEnsurer`, and is refused when that session already has `PaneGrid.maxPanes` panes.

- [ ] **Step 2: Run — FAIL.**

- [ ] **Step 3: Implement**:
  - **Factory** (controller init):

```swift
workspace = PaneWorkspaceView { descriptor in
    switch descriptor.kind {
    case .terminal:
        return TerminalSurfaceView(connection: connection, sessionID: descriptor.sessionID)
    case .browser:
        return BrowserPaneView(initialURL: descriptor.browserURL)
    }
}
```

  - **`PaneWorkspaceView.browserPane(for:)`**: `containers[sessionID]?.surface as? BrowserPaneView`.
  - **Controller `addPane` browser branch** (the `else` of Task 2's terminal branch):

```swift
} else if let browser = workspace.browserPane(for: sessionID) {
    browser.onTitleChange = { [weak self] title in
        guard let self else { return }
        workspace.updateDescriptor(for: sessionID) { $0.title = title }
        if workspace.focusedPaneID == sessionID { refreshTitle() }
    }
    browser.onURLChange = { [weak self] url in
        self?.workspace.updateDescriptor(for: sessionID) { $0.browserURL = url }
    }
}
```

  (`updateDescriptor` already fires `onPanesChanged`, which Task 5 uses for persistence.)
  - **`newBrowserPane` / `newBrowser(in:)`** — mirrors `newPane(in:)` minus everything PTY:

```swift
/// ⇧⌘T — a browser pane in the focused pane's session. No PTY, no engine,
/// no cwd; only the grid geometry can refuse it.
@objc func newBrowserPane(_ sender: Any?) {
    newBrowser(in: nil)
}

@discardableResult
func newBrowser(in session: SessionGroupNode?) -> Bool {
    let sibling = session.map { seed in
        seed.paneIDs.first.flatMap { workspace.descriptor(for: $0) }
    } ?? workspace.focusedPaneID.flatMap { workspace.descriptor(for: $0) }
    let template = WorkspaceRestoration.bootstrapPane()
    let group = session?.id ?? sibling?.group ?? template.group
    guard workspace.paneCount(inGroup: group) < PaneGrid.maxPanes else { return false }
    return addPane(
        RestoredPane(
            sessionID: template.sessionID,
            reattaches: false,
            project: sibling?.project ?? session?.project ?? "",
            engine: .shell,
            cwd: "",
            label: nil,
            themeId: nil,
            group: group,
            groupLabel: sibling?.groupLabel ?? session?.name,
            kind: .browser,
            browserURL: ""
        ),
        startSession: false
    )
}
```

  - **validateMenuItem** arm: `case #selector(newBrowserPane(_:)): return workspace.paneIDs.count < PaneGrid.maxPanes`.
  - **Menu** (AppDelegate, after New Terminal Pane): `file.addItem(item("New Browser Pane", Selector(("newBrowserPane:")), "t", [.command, .shift]))`.
  - **Toolbar**: new identifier `ToolbarItem.newBrowser = NSToolbarItem.Identifier("digital.bruno.omniagent.toolbar.new-browser")`, default identifiers gain it right after `newPane`, item case returns `item(identifier, "New Browser", "globe", #selector(newBrowserPane(_:)))`. Enablement is free via the synthetic-menu-item probe.
  - **Palette**: `case newBrowserPane` in `PaletteAction`; in `build` after the `new-pane` row: `PaletteCommand(id: "new-browser", title: "New browser pane", detail: "⇧⌘T", action: .newBrowserPane)`; switch-to row detail becomes `pane.kind == .browser ? "browser" : pane.engine.rawValue`; controller `run(_:)` gains `case .newBrowserPane: newBrowserPane(nil)`.
  - **Hole tile**: `PaneHolePlaceholderView` gains a second closure `onActivateBrowser`; it draws `"+ New terminal"` centered and a fainter, smaller `"+ New browser"` line below it, records both text rects during `draw(_:)`, and `mouseUp` dispatches on which rect contains the click (anywhere else = terminal, the primary affordance). Accessibility keeps the single "Add terminal" press; browser stays reachable via menu/palette/toolbar for assistive users. `PaneWorkspaceView` grows `var onRequestNewBrowserPane: (() -> Void)?` and passes both closures in `syncHolePlaceholders`; controller wires it to `newBrowserPane(nil)`.
  - **Sidebar**: parameterize `NewTerminalRowView`'s init with `(title: String, shortcut: String)` (defaults `"New terminal"`/`"⌘T"`), add an `onNewBrowser` callback on `WorkspaceSidebarView` plumbed like `onNewTerminal`, and render a second add-row (`"New browser"`, `"⇧⌘T"`) under the current session next to the existing one, same cap condition. Controller wires it to `newBrowser(in: current)` using the same current-session lookup `onNewTerminal` uses. `TerminalRowView` shows a globe for browser panes: `pane.kind == .browser` → `NSImageView` with `NSImage(systemSymbolName: "globe", accessibilityDescription: "Browser")`, `contentTintColor = ShellPalette.inkTertiary`, instead of `engineIcon(for:)`.
  - **SessionOutline**: add

```swift
static func defaultPaneName(_ pane: PaneDescriptor) -> String {
    pane.kind == .browser ? "Browser \(pane.autoNumber)" : defaultPaneName(pane.engine, pane.autoNumber)
}
```

  `paneLabel` ladder for browsers: label → title → non-empty `browserURL` → `defaultPaneName(pane)`. `nextPaneNumber` gains `kind: PaneKind = .terminal` and filters `$0.kind == kind && (kind == .browser || $0.engine == engine)`; controller `addPane` passes `kind: descriptor.kind`. `isGeneratedPaneName` also recognizes `"Browser N"`.
  - **Container chrome** (`PaneContainerView.descriptorChanged`): `header.engine = descriptor.kind == .browser ? nil : descriptor.engine` (nil already hides the badge); skip `updateBranch` for browsers. `subtitleProvider` word: `"browser"` instead of `"terminal"` for browser panes. `updateAccessibilityLabel`: noun per kind (`"browser pane N of M"`). Workspace group label and header-button labels move to kind-neutral wording (`"Zoom this pane"`, `"Close this pane"`, `"Workspace panes"`) — update the one test that pins `"Zoom this terminal"`.

- [ ] **Step 4: Run** `./macos/build.sh test` — green.

- [ ] **Step 5: Commit + push**: `feat(macos): browser panes — ⇧⌘T, toolbar, palette, sidebar and hole-tile entry points`

---

### Task 5: Last-URL persistence (native-only row)

**Files:**
- Create: `macos/OmniAgent/BrowserPanes.swift` (register in pbxproj)
- Modify: `macos/OmniAgent/SettingsKeys.swift`, `macos/OmniAgent/WorkspaceRestoration.swift` (persistedTabs), `macos/OmniAgent/WorkspaceWindowController.swift` (restore/persist)
- Test: create `macos/OmniAgentTests/BrowserPanesTests.swift` (register); modify `macos/OmniAgentTests/WorkspaceRestorationTests.swift`, `macos/OmniAgentTests/WorkspaceWindowControllerTests.swift`

**Interfaces:**
- Produces: `PersistedBrowserPane { var url: String; var group: String?; var groupLabel: String? }`, `BrowserPanesCodec.serialize/deserialize`, `SettingsKey.browserPanes == "browser_panes_native"`, `WorkspaceWindowController.applyRestoredBrowserPanes(_:)`.

**Steps:**

- [ ] **Step 1: Failing tests**:
  - BrowserPanesTests: round-trip; `deserialize(nil)`/garbage → `[]`; an entry with a non-string `url` is dropped while its siblings survive; an invalid `group` costs only the field; serialize output is stable/sorted (`{"panes":[{"group":"g1","url":"https://a"}]}` ordering).
  - WorkspaceRestorationTests: `persistedTabs` **excludes** browser-kind descriptors — with a mixed list, the serialized `"layout"` value is byte-identical to serializing the terminals alone (this is the shared-row regression test the spec demands).
  - WorkspaceWindowControllerTests: `applyRestoredBrowserPanes([PersistedBrowserPane(url: "https://x", group: "g1", groupLabel: nil)])` adds one browser pane in `g1` with `browserURL == "https://x"` and never calls `sessionEnsurer`; with a recording `settingsWriter`, adding/closing a browser pane writes `SettingsKey.browserPanes` and never changes the `SettingsKey.layout` value.

- [ ] **Step 2: Run — FAIL.**

- [ ] **Step 3: Implement**:
  - `BrowserPanes.swift`: mirror `PersistedLayoutCodec`'s structure exactly — `JSONSerialization`, `.sortedKeys` (the write-dedup in `write(_:to:)` compares strings), per-entry repair (`url` must be a `String` and non-empty or the entry drops; `group` invalid per `SessionIdentifier.isValid` drops the field; `groupLabel` trims like the layout codec).
  - `SettingsKey`:

```swift
/// Native-only — deliberately NOT shared with the web build. Browser panes
/// must stay out of the shared `layout` row: the web codec drops
/// unknown-engine tabs and strips unknown fields on rewrite, so a browser
/// tab persisted there would be destroyed by the next web-side save. One
/// JSON object, `{"panes":[{url, group?, groupLabel?}]}` — see
/// `BrowserPanesCodec`. No TypeScript twin, by design.
static let browserPanes = "browser_panes_native"
```

  - `WorkspaceRestoration.persistedTabs`: `guard pane.kind == .terminal, !pane.project.isEmpty else { return nil }`.
  - Controller — same one-shot/re-arm/write-gate shape as notifications:

```swift
private var browserPanesReadDispatched = false
private var browserPanesReadCompleted = false

private func restoreBrowserPanesIfNeeded() {
    guard !browserPanesReadDispatched else { return }
    browserPanesReadDispatched = true
    connection.getSetting(key: SettingsKey.browserPanes) { [weak self] result in
        guard let self else { return }
        switch result {
        case let .success(raw):
            applyRestoredBrowserPanes(BrowserPanesCodec.deserialize(raw))
        case .failure:
            browserPanesReadDispatched = false
        }
    }
}

func applyRestoredBrowserPanes(_ panes: [PersistedBrowserPane]) {
    browserPanesReadCompleted = true
    for pane in panes where workspace.paneCount(inGroup: pane.group ?? WorkspaceRestoration.ungroupedSessionID) < PaneGrid.maxPanes {
        addPane(
            RestoredPane(
                sessionID: UUID().uuidString,
                reattaches: false,
                project: "",
                engine: .shell,
                cwd: "",
                label: nil,
                themeId: nil,
                group: pane.group ?? WorkspaceRestoration.ungroupedSessionID,
                groupLabel: pane.groupLabel,
                kind: .browser,
                browserURL: pane.url
            ),
            startSession: false
        )
    }
}

private func persistBrowserPanes() {
    guard browserPanesReadCompleted else { return }
    let panes = workspace.allPaneIDs
        .compactMap { workspace.descriptor(for: $0) }
        .filter { $0.kind == .browser }
        .map {
            PersistedBrowserPane(
                url: $0.browserURL,
                group: $0.group == WorkspaceRestoration.ungroupedSessionID ? nil : $0.group,
                groupLabel: $0.groupLabel
            )
        }
    write(BrowserPanesCodec.serialize(panes), to: SettingsKey.browserPanes)
}
```

  Call `restoreBrowserPanesIfNeeded()` at the end of `applyRestoredPanes` (terminals restore first, so grid fill order favors them), and `persistBrowserPanes()` next to `persistLayout()` inside the `onPanesChanged` closure. Note `browserURL` updates already flow through `updateDescriptor` → `onPanesChanged` (Task 4), so navigating persists the new URL with zero extra plumbing.

- [ ] **Step 4: Run** `./macos/build.sh test` — green.

- [ ] **Step 5: Commit + push**: `feat(macos): browser panes restore their last URL from a native-only settings row`

---

### Task 6: Milestone-1 verification — offscreen render, packaged build

**Files:**
- Modify: `macos/OmniAgentTests/PaneWorkspaceViewTests.swift` (or the file the existing offscreen-render convention lives in — find it with `grep -rn "cacheDisplay\|bitmapImageRep" macos/OmniAgentTests/`)

**Steps:**

- [ ] **Step 1: Offscreen layout verification** (memory: verify AppKit layout by offscreen render). Add a test that builds a mixed grid (2 terminals + 1 browser in one session), lays it out at 1200×800 in a `WorkspaceWindow` (use `makeAttachedWorkspace`'s pattern), renders to a bitmap, and asserts structural facts: the browser container's frame matches its grid cell, `BrowserPaneView.webView.frame.minY == BrowserPaneView.toolbarHeight`, url field width > 0, and the render itself is non-empty. Follow the existing render-to-PNG convention for optionally writing the PNG out (TEST_RUNNER_-prefixed env var) so Bruno can eyeball it.
- [ ] **Step 2: Manual-path checks in the same test file**: focus a browser pane then `restoreFocus()` — first responder ends up inside the browser container; zoom a browser pane and back — identity survives (reuse the existing identity-survival test pattern with a mixed grid).
- [ ] **Step 3: Run the full suite**: `./macos/build.sh test` — green.
- [ ] **Step 4: Packaged build** (packaging rule + native-app-only memory): `./scripts/bump-build-version.sh` then `./scripts/rebuild-app.sh --no-notarize`. This quits the running app, restarts the PTY daemon (standing decision — don't ask), and installs to /Applications.
- [ ] **Step 5: Commit + push**: `test(macos): offscreen render + focus/zoom coverage for mixed terminal/browser grids`

---

### Task 7: Console capture + JS eval in `BrowserPaneView` (milestone 2)

**Files:**
- Modify: `macos/OmniAgent/BrowserPaneView.swift`
- Test: `macos/OmniAgentTests/BrowserPaneViewTests.swift`

**Interfaces:**
- Produces: `BrowserPaneView.onConsoleMessage: ((_ level: String, _ message: String) -> Void)?`, `BrowserPaneView.evaluateForConsole(_ js: String, completion: @escaping (String) -> Void)`.

**Steps:**

- [ ] **Step 1: Failing tests** (async, `loadHTMLString` + expectations, timeout ≥ 10s):

```swift
func testConsoleMessagesReachTheHook() {
    let view = BrowserPaneView(initialURL: "")
    let logged = expectation(description: "console")
    view.onConsoleMessage = { level, message in
        if level == "log", message == "hello 42" { logged.fulfill() }
    }
    view.webView.loadHTMLString("<script>console.log('hello', 42)</script>", baseURL: nil)
    wait(for: [logged], timeout: 10)
}

func testEvaluateForConsoleReturnsResultsAndErrors() {
    let view = BrowserPaneView(initialURL: "")
    let loaded = expectation(description: "loaded")
    view.onTitleChange = { if $0 == "t" { loaded.fulfill() } }
    view.webView.loadHTMLString("<title>t</title>", baseURL: nil)
    wait(for: [loaded], timeout: 10)

    let evaluated = expectation(description: "eval")
    view.evaluateForConsole("1 + 2") { output in
        XCTAssertEqual(output, "3")
        evaluated.fulfill()
    }
    let failed = expectation(description: "error")
    view.evaluateForConsole("nope(") { output in
        XCTAssertTrue(output.hasPrefix("⚠︎"))
        failed.fulfill()
    }
    wait(for: [evaluated, failed], timeout: 10)
}
```

- [ ] **Step 2: Run — FAIL.**

- [ ] **Step 3: Implement**: a `WKUserScript` (`.atDocumentStart`, `forMainFrameOnly: false`) that wraps `console.log/info/warn/error/debug`, `window.onerror` and `unhandledrejection` and posts `{level, message}` to a `"omniConsole"` message handler (guard against double-hooking with a `window.__omniConsoleHooked` flag; stringify object args via `JSON.stringify` with a `String(a)` fallback). The handler is a small `NSObject, WKScriptMessageHandler` class holding `weak var owner: BrowserPaneView?` (the content controller retains the handler; the weak back-reference avoids the cycle). `evaluateForConsole` wraps `webView.evaluateJavaScript`: error → `"⚠︎ \(error.localizedDescription)"`, nil result → `"undefined"`, else `String(describing: result)`.

- [ ] **Step 4: Run — green. Step 5: Commit + push**: `feat(macos): browser panes capture console output and evaluate JS`

---

### Task 8: Console pane kind (milestone 2)

**Files:**
- Create: `macos/OmniAgent/ConsolePaneView.swift` (register in pbxproj)
- Modify: `macos/OmniAgent/PaneContentView.swift` (add `case console`), `macos/OmniAgent/WorkspaceWindowController.swift` (factory case, wiring, `newConsolePane`, validateMenuItem, run(_:)), `macos/OmniAgent/AppDelegate.swift` (menu item, no key equivalent), `macos/OmniAgent/CommandPalette.swift` (`case newConsolePane` + row), `macos/OmniAgent/SessionOutline.swift` (`"Console N"` in `defaultPaneName(_ pane:)` / `isGeneratedPaneName`), `macos/OmniAgent/WorkspaceShell.swift` (row icon: `"terminal"` SF symbol? use `"chevron.left.slash.chevron.right"` for console)
- Test: create `macos/OmniAgentTests/ConsolePaneViewTests.swift`; modify controller/palette/outline tests

**Interfaces:**

```swift
final class ConsolePaneView: NSView, PaneContentView {
    struct Target: Equatable {
        let id: String
        let title: String
    }
    /// Supplied by the window controller: the open browser panes, freshest
    /// focus first, re-asked every time the picker opens.
    var availableTargets: (() -> [Target])?
    /// (js, targetID, print) — routed to that browser's evaluateForConsole.
    var evaluate: ((String, String, @escaping (String) -> Void) -> Void)?
    /// Tells the controller to route the chosen browser's console output
    /// here (nil unbinds).
    var onBindTarget: ((String?) -> Void)?
    private(set) var boundTargetID: String?
    func bind(to target: Target?)
    func append(level: String, message: String)
    func noteTargetClosed()
}
```

**Steps:**

- [ ] **Step 1: Failing tests**: `ConsolePaneView` conforms to `PaneContentView` (no-op resize pipeline, `primaryResponderView` is the REPL input field); `bind(to:)` sets `boundTargetID` and fires `onBindTarget`; `append` adds a line to the log text; `noteTargetClosed` clears `boundTargetID` and appends a "browser pane closed" line; submitting the input calls `evaluate` with the bound id and appends both the `> js` echo and the printed result. Controller test: `newConsolePane(nil)` with no browser pane open is refused by `validateMenuItem` but binds automatically to the most recently focused browser when one exists; closing that browser calls the console's `noteTargetClosed`. SessionOutline: `"Console 1"` naming.

- [ ] **Step 2: Run — FAIL.**

- [ ] **Step 3: Implement**:
  - `PaneKind` gains `case console`. (Persistence needs no change: `persistedTabs` keeps only `.terminal`, `persistBrowserPanes` keeps only `.browser` — consoles are session-only by spec.)
  - `ConsolePaneView`: top bar (28pt) with an `NSPopUpButton` rebuilt from `availableTargets` on menu open + the bound target's title; middle: read-only monospaced `NSTextView` in an `NSScrollView` (log lines `[level] message`, error/warn tinted); bottom: `NSTextField` REPL (`target/action` on Enter → echo `"> \(js)"`, call `evaluate`, print result, clear field). `focus()` targets the input field.
  - Controller: factory `case .console: return ConsolePaneView()`; in `addPane`'s non-terminal branch, when `workspace.consolePane(for: sessionID)` (new accessor, same as `browserPane(for:)`) exists, wire `availableTargets` (browser descriptors, most-recently-focused first — track `private var lastFocusedBrowserID: String?` updated in the existing `onFocusedPaneChanged` closure), `evaluate` (via `workspace.browserPane(for: targetID)?.evaluateForConsole`), and `onBindTarget` → set that browser's `onConsoleMessage` to `[weak console] in console?.append(level:message:)` (clearing any previous binding; last console bound to a browser wins — `// ponytail: single listener per browser, multicast when someone actually wants two consoles on one page`). Auto-bind on creation to `lastFocusedBrowserID`. In `closePane`, when the closing pane is a browser, call `noteTargetClosed()` on any console bound to it.
  - `newConsolePane(_:)`: clone of `newBrowser(in:)` with `kind: .console`; `validateMenuItem` arm requires an open browser pane (`workspace.allPaneIDs.contains { workspace.descriptor(for: $0)?.kind == .browser }`) and grid room. Menu item "New Console Pane" (no shortcut) after New Browser Pane; palette row `new-console` / "New console pane"; `run(_:)` arm.
  - `SessionOutline.defaultPaneName(_ pane:)`: `"Console \(n)"` for `.console`; row icon in sidebar.

- [ ] **Step 4: Run — green. Step 5: Commit + push**: `feat(macos): console panes — cross-pane JS console/REPL bound to a browser pane`

---

### Task 9: Final verification and ship

- [ ] **Step 1:** Full suite: `./macos/build.sh test` — green. Also `cargo test --workspace` untouched-check is NOT needed (no Rust changes) — skip it.
- [ ] **Step 2:** `git log --oneline main..` sanity: every task committed and pushed; working tree clean.
- [ ] **Step 3:** `./scripts/bump-build-version.sh` (date-based rule) then `./scripts/rebuild-app.sh --no-notarize` — packaged native app in /Applications, daemon restarted.
- [ ] **Step 4:** Report: what shipped, how to try it (⇧⌘T for a browser, right-click → Inspect Element for the real inspector, New Console Pane for the cross-pane console), and any deviations from this plan.
