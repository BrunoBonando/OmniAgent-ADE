import AppKit

/// What the user chose in the "save before closing?" prompt.
enum EditorSaveDecision { case save, discard, cancel }

/// What the page said about a buffer *after* a save was written to disk.
/// `.clean` is the only answer that makes it safe to destroy the buffer —
/// close the tab, or drag it to a pane that will re-read the file from disk.
/// `.stillDirty` means a keystroke landed inside the write and the
/// version-scoped `markSaved` correctly refused it: ask again.
/// `.failed` means the bytes never reached disk (the error is already on
/// screen) and whatever bulk walk asked must stop.
enum EditorSaveAcknowledgement { case clean, stillDirty, failed }

/// An editor pane's content: a native tab strip over a swap container that
/// shows either the Monaco web surface (file/diff/changes tabs) or a native
/// media view (image/PDF). The PTY half of `PaneContentView` is a no-op,
/// exactly like `BrowserPaneView`. All disk I/O lives here, on the Swift
/// side; Monaco only ever sees strings.
final class EditorPaneView: NSView, PaneContentView {
    let strip = EditorTabStripView()
    let webHost = EditorWebView()
    let mediaHost = MediaTabView()
    private let emptyField = NSTextField(labelWithString: "No file open — click a file in FILES")

    private(set) var model = EditorPaneModel()

    var onTitleChange: ((String) -> Void)?
    var onStateChange: (([PersistedEditorTab], Int) -> Void)?
    var onLastTabClosed: (() -> Void)?
    var onOpenDiffRequest: ((URL) -> Void)?
    /// The Changes overview's "open file" — routed up for the same reason the
    /// diff request is: which pane a file lands in is the controller's rule.
    var onOpenFileRequest: ((URL) -> Void)?
    /// A tab was dropped in this pane's strip, with the index the indicator
    /// showed. Routed up: a drop can prompt about unsaved work and can move a
    /// tab out of another pane, neither of which this view may decide.
    var onTabDroppedInStrip: ((EditorTabDragPayload, Int) -> Void)?

    /// The workspace pane id this view is mounted under, injected by the
    /// controller's wiring. Only the drag payload needs it — a tab in flight
    /// is "pane X's tab N", and nothing else here knows X.
    var paneID: String = ""

    var workspaceRoot: URL?
    var changedPaths: Set<String> = [] { didSet { syncChrome() } }
    /// The workspace's last `git status`, pushed in by the controller. The
    /// Changes tab is a rendering of exactly this — the pane never runs
    /// `git status` itself, so it can never disagree with the FILES tree.
    private(set) var gitStatus: GitStatus?

    var confirmSave: ((String, @escaping (EditorSaveDecision) -> Void) -> Void) = EditorPaneView.defaultConfirmSave
    var presentError: ((String) -> Void) = { message in
        let alert = NSAlert()
        alert.messageText = "Could not save"
        alert.informativeText = message
        alert.runModal()
    }
    /// The other alert seam: an open file changed on disk *while the buffer
    /// was dirty*. `takeDisk == false` is "Keep Mine".
    var confirmConflict: ((String, @escaping (_ takeDisk: Bool) -> Void) -> Void) =
        EditorPaneView.defaultConfirmConflict

    /// Per-open-file bookkeeping, keyed by absolute path.
    private var encodings: [String: String.Encoding] = [:]
    private var modificationDates: [String: Date] = [:]
    /// Paths that currently have a live Monaco model. Also the "did this file
    /// read successfully?" answer — a file we could not read never lands here,
    /// so `showActiveContent` shows the message instead of an empty editor.
    private(set) var loadedPaths: Set<String> = []
    /// Paths Monaco holds read-only because of their size. They wear a banner
    /// (spec §7) — an editor that silently swallows keystrokes reads as broken.
    private var readOnlyPaths: Set<String> = []
    /// Debounced dirty-buffer snapshots from the bridge — crash insurance,
    /// replayed by `restoreAfterRendererCrash` when the page comes back.
    private(set) var dirtySnapshots: [String: String] = [:]
    /// Open files that have vanished from disk. The buffer is kept (it is the
    /// only copy left, and saving recreates the file); only the tab title
    /// changes, so this is chrome and never republishes the persisted row.
    private(set) var deletedPaths: Set<String> = []
    /// Set when the renderer dies, cleared by the `onReady` that follows it.
    /// `onReady` fires again after *every* crash, so it is a "the web view is
    /// (re)born" signal rather than a one-shot — and only a rebirth needs the
    /// models put back.
    private var needsModelRestore = false
    /// A conflict alert is on screen. Stops `checkExternalChanges` stacking a
    /// second one behind it.
    private var conflictPromptInFlight = false

    // MARK: - PaneContentView

    var isSelected = false
    var suspendsDrawing = false
    weak var resizeCoalescer: PaneResizeCoalescer?
    /// Never points at a hidden surface: a *binary* `.file` tab is rendered by
    /// `mediaHost`, not Monaco, so it focuses the media view like `.media` does.
    /// `mediaHost.isHidden` is the same answer `showActiveContent` just
    /// computed, without a second trip to the filesystem.
    var primaryResponderView: NSView {
        switch model.activeTab?.kind {
        case .media: return mediaHost.preferredResponder
        case .none: return self
        default: return mediaHost.isHidden ? webHost.webView : mediaHost.preferredResponder
        }
    }
    /// Focus is the spec's moment for noticing the world moved: an agent (or
    /// a `git checkout`) rewrites files while the pane is not looking, and
    /// this is when the user comes back to look.
    func focus() {
        checkExternalChanges()
        window?.makeFirstResponder(primaryResponderView)
    }
    func scheduleResize() {}
    func flushResize() {}

    init(initialTabs: [PersistedEditorTab], activeIndex: Int) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = PaneContainerView.paneBackgroundColor.cgColor

        emptyField.font = ShellFont.ui(13)
        emptyField.textColor = ShellPalette.inkMuted
        emptyField.alignment = .center
        emptyField.lineBreakMode = .byTruncatingTail
        emptyField.maximumNumberOfLines = 1

        for view in [strip, webHost, mediaHost, emptyField] as [NSView] { addSubview(view) }
        setContentVisibility(web: false, media: false, empty: true)

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Editor pane")

        wireStrip()
        wireBridge()
        restore(initialTabs: initialTabs, activeIndex: activeIndex)
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
        strip.frame = NSRect(x: 0, y: 0, width: bounds.width, height: EditorTabStripView.height)
        let content = NSRect(
            x: 0,
            y: EditorTabStripView.height,
            width: bounds.width,
            height: max(0, bounds.height - EditorTabStripView.height)
        )
        webHost.frame = content
        mediaHost.frame = content
        let size = emptyField.intrinsicContentSize
        emptyField.frame = NSRect(
            x: content.minX + (content.width - size.width) / 2,
            y: content.minY + (content.height - size.height) / 2,
            width: min(size.width, content.width),
            height: size.height
        )
    }

    /// Restores a persisted row. Tabs whose file has vanished since the last
    /// launch are dropped (`.changes` has no file and always survives), and
    /// the active index is clamped into whatever is left.
    private func restore(initialTabs: [PersistedEditorTab], activeIndex: Int) {
        let surviving: [EditorTab] = initialTabs.compactMap { persisted in
            // The codec already drops unknown kinds; belt and braces here.
            guard let kind = EditorTabKind(rawValue: persisted.kind) else { return nil }
            guard kind == .changes || FileManager.default.fileExists(atPath: persisted.path) else { return nil }
            return EditorTab(path: persisted.path, kind: kind, isPinned: persisted.pinned)
        }
        for (index, tab) in surviving.enumerated() { model.insert(tab, at: index) }
        model.activate(min(max(0, activeIndex), max(0, surviving.count - 1)))
        // No publish: the restore *is* what the persisted row already says.
        sync(publish: false)
        showActiveContent()
    }

    private func wireStrip() {
        strip.onSelect = { [weak self] index in self?.activateTab(index) }
        strip.onPin = { [weak self] index in
            guard let self else { return }
            model.pin(at: index)
            syncAll()
        }
        strip.onClose = { [weak self] index in self?.requestCloseTab(at: index) }
        strip.onSave = { [weak self] in self?.saveActiveTab() }
        strip.onDiffToggle = { [weak self] in
            guard let self, let tab = model.activeTab else { return }
            switch tab.kind {
            case .file:
                onOpenDiffRequest?(URL(fileURLWithPath: tab.path))
            case .diff:
                // The return leg. Without it the ± is a one-way door: the
                // affordance vanished on the diff tab, so there was no way
                // back to the file except finding its tab by hand.
                onOpenFileRequest?(URL(fileURLWithPath: tab.path))
            default:
                break
            }
        }
        strip.onBeginDrag = { [weak self] index, event in self?.beginTabDrag(index: index, event: event) }
        strip.onTabDrop = { [weak self] payload, index in
            self?.onTabDroppedInStrip?(payload, index)
        }
    }

    // MARK: - Tab drag and drop

    /// The pasteboard item for dragging tab `index`, and the pin that comes
    /// with it: dragging a tab pins it, exactly as double-clicking or editing
    /// it does (spec §4). Nothing else changes — the tab stays in this pane's
    /// model until a drop actually commits, so a cancelled drag leaves the
    /// strip as it was.
    func makeTabDragItem(at index: Int) -> NSPasteboardItem? {
        guard model.tabs.indices.contains(index),
              let string = EditorTabDragPayload(paneID: paneID, index: index).pasteboardString()
        else { return nil }
        model.pin(at: index)
        syncAll()
        let item = NSPasteboardItem()
        item.setString(string, forType: PaneWorkspaceView.editorTabDragType)
        return item
    }

    private func beginTabDrag(index: Int, event: NSEvent) {
        guard let item = makeTabDragItem(at: index) else { return }
        let dragItem = NSDraggingItem(pasteboardWriter: item)
        // The tab's own rectangle, so the drag image starts where the tab is
        // rather than at the pane's origin. `itemFrames` is recomputed by the
        // `syncAll` above, so it already reflects the pin's italic-to-roman
        // width change.
        let frame = strip.itemFrames.indices.contains(index) ? strip.itemFrames[index] : .zero
        dragItem.setDraggingFrame(strip.convert(frame, to: self), contents: nil)
        beginDraggingSession(with: [dragItem], event: event, source: self)
    }

    /// Lifts a tab out for a move into another pane, releasing everything it
    /// owned here — its Monaco model above all, since the destination opens
    /// its own from disk. Fires `onLastTabClosed` when the pane empties, so a
    /// pane whose final tab is dragged away closes exactly as one whose final
    /// tab is closed does.
    ///
    /// The buffer does **not** travel: each pane owns its own web view, and
    /// v1 resolves a dirty tab (save or discard) before the move — see the
    /// controller's `deliverAfterSavePrompt`.
    @discardableResult
    func removeTabForTransfer(at index: Int) -> EditorTab? {
        guard let removed = model.close(at: index) else { return nil }
        discardResources(for: removed)
        syncAll()
        showActiveContent()
        if model.tabs.isEmpty { onLastTabClosed?() }
        return removed
    }

    /// A tab arriving from another pane. It lands clean — its content is
    /// whatever is on disk, which is what this pane's Monaco will read — and
    /// `showActiveContent` gives every kind (file, media, diff, changes) the
    /// same first render it gets on any other activation.
    func receiveTransferredTab(_ tab: EditorTab, at index: Int) {
        var arrived = tab
        arrived.isDirty = false
        model.insert(arrived, at: index)
        syncAll()
        showActiveContent()
    }

    /// A reorder inside this strip. `destination` is an index in the array
    /// *after* the tab is lifted out — the caller converts the indicator's
    /// index, which is measured with the tab still in place.
    func moveTab(from source: Int, to destination: Int) {
        model.move(from: source, to: destination)
        syncAll()
    }

    private func wireBridge() {
        webHost.onDirtyChanged = { [weak self] path, dirty in
            guard let self, let index = model.index(of: path, kind: .file) else { return }
            model.setDirty(dirty, at: index)
            if !dirty { dirtySnapshots.removeValue(forKey: path) }
            syncAll()
        }
        webHost.onSnapshot = { [weak self] path, content in
            self?.dirtySnapshots[path] = content
        }
        webHost.onSaveRequested = { [weak self] path in
            guard let self, let index = model.index(of: path, kind: .file) else { return }
            save(at: index) { _ in }
        }
        // One `git diff` per row, and only when the row is opened: a
        // thousand-file working tree would otherwise cost a thousand
        // subprocesses to draw a list nobody has read yet.
        webHost.onRequestFileDiff = { [weak self] relative in
            guard let self, let root = gitStatus?.root else { return }
            let url = root.appendingPathComponent(relative)
            GitFileContent.unifiedDiff(of: url) { [weak self] text in
                self?.webHost.appendFileDiff(path: relative, text: EditorPaneView.hunkText(text, for: url))
            }
        }
        // Routed up rather than opened here, so a file (or a diff) already
        // open somewhere else is focused instead of duplicated — the
        // no-duplicates rule is the whole workspace's, not this pane's.
        webHost.onChangesOpen = { [weak self] relative, asDiff in
            guard let self, let root = gitStatus?.root else { return }
            let url = root.appendingPathComponent(relative)
            if asDiff {
                onOpenDiffRequest?(url)
            } else {
                onOpenFileRequest?(url)
            }
        }
        // The renderer died: `EditorWebView` has already dropped its queue and
        // is reloading the page. Nothing can be sent until it answers `ready`,
        // so all this does is remember why the next `ready` is arriving.
        webHost.onCrash = { [weak self] in self?.needsModelRestore = true }
        webHost.onReady = { [weak self] in
            guard let self, needsModelRestore else { return }
            needsModelRestore = false
            restoreAfterRendererCrash()
        }
    }

    /// The page was rebuilt from scratch, so every Monaco model it held is
    /// gone. Re-open the ones this pane had loaded — dirty buffers from their
    /// last ~2 s snapshot (spec §7: unsaved edits survive a renderer death),
    /// clean ones from disk — and re-show the active tab.
    ///
    /// Only `loadedPaths` are restored, which keeps the pane's laziness
    /// intact: a restored-session tab Monaco never saw stays unloaded until
    /// it is activated, exactly as before the crash. `.diff` and `.changes`
    /// tabs need nothing replayed — `showActiveContent` refetches them.
    func restoreAfterRendererCrash() {
        for tab in model.tabs where tab.kind == .file && loadedPaths.contains(tab.path) {
            let url = URL(fileURLWithPath: tab.path)
            // The snapshot is the **only** copy of an unsaved edit once the
            // renderer is gone, so it is restored whatever the file has since
            // become — deleted, grown past the size cap, or turned binary.
            // Classification decides `readOnly`, and decides whether to
            // restore at all only when there is nothing unsaved at stake.
            let snapshot = tab.isDirty ? dirtySnapshots[tab.path] : nil
            var readOnly = false
            if case let .text(classified) = EditorFileClass.classify(url: url) {
                // `classify` opens the file itself and answers `.binary` for
                // anything it cannot read, so this arm also means "still
                // there, still editable text".
                readOnly = classified
            } else if snapshot == nil {
                // Nothing unsaved to protect, and nothing editable to show.
                // Forget the model so the tab re-derives itself on activation
                // (media placeholder, "too large", "(deleted)") rather than
                // leaving a blank surface behind a Monaco model that no longer
                // exists — and drop the dirty flag with it. It is not
                // protecting anything: the renderer took the buffer with it
                // and there is no snapshot, so a "Save" prompt could only ask
                // `getContent` for a model that is gone and fail.
                loadedPaths.remove(tab.path)
                if !FileManager.default.fileExists(atPath: tab.path) { deletedPaths.insert(tab.path) }
                if let index = model.index(of: tab.path, kind: .file) { model.setDirty(false, at: index) }
                continue
            }
            let encoding = encodings[tab.path] ?? .utf8
            let disk = (try? String(contentsOf: url, encoding: encoding)) ?? ""
            // Open at the *disk* text first so the page's saved version is the
            // file's, then put the unsaved edit back on top of it. Opening
            // straight at the snapshot would make the page call that edit
            // saved, and a later close would discard it without asking.
            //
            // `show: false` because `openModel` otherwise shows each model as
            // it lands: n-1 wasted editor swaps and a focus steal, all undone
            // by the `showActiveContent()` below.
            webHost.openModel(path: tab.path, content: disk, readOnly: readOnly, show: false)
            if let snapshot { webHost.restoreUnsaved(path: tab.path, content: snapshot) }
        }
        syncAll()
        showActiveContent()
    }

    // MARK: - External changes

    /// Spec §2. A file that moved on disk under a **clean** buffer is reloaded
    /// silently; under a **dirty** one the user is asked (keep mine / take
    /// disk). A file that is *gone* keeps its buffer and is marked in the
    /// strip — the buffer is the only copy left, and saving recreates it.
    ///
    /// The recorded mtime advances *before* the prompt, so one disk change
    /// asks exactly once however many times focus comes back.
    func checkExternalChanges() {
        // One conflict alert at a time. Focus changes freely while a modal is
        // up (the alert takes key, the pane can be re-focused behind it), and
        // without this a second disk change stacks a nested alert on the
        // first. Nothing is lost by returning early: the recorded mtimes are
        // only advanced past this point, so every unresolved change is still
        // pending on the next focus.
        guard !conflictPromptInFlight else { return }
        var markedChanged = false
        for tab in model.tabs where tab.kind == .file {
            let path = tab.path
            guard let recorded = modificationDates[path] else { continue }
            guard FileManager.default.fileExists(atPath: path) else {
                markedChanged = deletedPaths.insert(path).inserted || markedChanged
                continue
            }
            markedChanged = deletedPaths.remove(path) != nil || markedChanged
            let current = modificationDate(of: URL(fileURLWithPath: path)) ?? recorded
            guard current > recorded else { continue }
            // Nothing can be decided while the page is down: its buffers are
            // not there to be asked about, and a crash restore is about to
            // re-apply them. The recorded date is deliberately left alone so
            // this is re-checked as soon as the bridge is back.
            guard webHost.isReady else { continue }
            modificationDates[path] = current
            resolveExternalChange(path, previouslyRecorded: recorded)
        }
        // Chrome only: a title gaining or losing " (deleted)" is not a tab
        // mutation and must not rewrite the persisted row.
        if markedChanged { syncChrome() }
    }

    /// Clean buffer -> silent reload; dirty buffer -> ask.
    ///
    /// "Dirty" is asked of the **page**, not of `model.tabs[…].isDirty`. That
    /// flag is only ever written by the *posted* `dirtyChanged`, and a posted
    /// message is not ordered against anything: a keystroke whose message has
    /// not arrived yet reads as clean, and the reload below would then rebase
    /// over it and lose the edit with no prompt. `requestIsClean` is an
    /// `evaluateJavaScript` reply, which is ordered — the same reason the
    /// close path asks it rather than trusting `save`'s `true`.
    private func resolveExternalChange(_ path: String, previouslyRecorded: Date?) {
        webHost.requestIsClean(path: path) { [weak self] clean in
            guard let self else { return }
            guard clean else {
                // One pass can find two changed dirty files, and the entry
                // guard cannot help: both resolves were dispatched before
                // either alert went up. Put the recorded date back so this
                // change is noticed again on the next focus rather than
                // stacking a nested alert inside the first one's `runModal`.
                guard !conflictPromptInFlight else {
                    modificationDates[path] = previouslyRecorded
                    return
                }
                conflictPromptInFlight = true
                confirmConflict((path as NSString).lastPathComponent) { [weak self] takeDisk in
                    guard let self else { return }
                    conflictPromptInFlight = false
                    guard takeDisk else { return }
                    reloadFromDisk(path)
                }
                return
            }
            reloadFromDisk(path)
        }
    }

    /// Replaces a buffer with what is on disk. Clearing dirty (and with it the
    /// crash snapshot) is deliberately left to the bridge: `setContent`
    /// rebases the page's saved version and posts `dirtyChanged(false)`, and
    /// `wireBridge` drops the snapshot there. Doing it here as well would let
    /// Swift call a buffer clean that the page had not actually rebased.
    private func reloadFromDisk(_ path: String) {
        guard loadedPaths.contains(path) else { return }
        let encoding = encodings[path] ?? .utf8
        guard let content = try? String(contentsOfFile: path, encoding: encoding) else { return }
        webHost.setContent(path: path, content: content)
    }

    /// The fallback when a pane ask has nowhere to appear; see
    /// `WorkspaceWindowController.wireEditorPane`.
    static func defaultConfirmConflict(_ name: String, _ decide: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = "\(name) changed on disk"
        alert.informativeText =
            "You have unsaved edits, and the file was modified outside the editor (probably by an agent)."
        alert.addButton(withTitle: "Keep Mine")
        alert.addButton(withTitle: "Take Disk")
        decide(alert.runModal() == .alertSecondButtonReturn)
    }

    // MARK: - Opening

    func openFile(_ url: URL, pinned: Bool) {
        let classified = EditorFileClass.classify(url: url)
        let kind = classified.tabKind
        let hadTab = model.index(of: url.path, kind: kind) != nil
        // A preview open recycles the existing preview tab in place, which
        // evicts whatever was in it — the evicted file's Monaco model and
        // bookkeeping have to go with it or they leak for the life of the
        // pane. Only the model knows which tab it reused, so it reports it;
        // re-deriving that here would be the same rule written twice.
        // Known, deliberately not fixed here: the recycle predicate
        // (`!isPinned && !isDirty`) reads a dirty flag that lags the page by a
        // message hop, so a buffer typed into microseconds ago can still be
        // evicted as "a clean preview". `reconcileDirtyFlags` would close it —
        // but only by making `openFile` asynchronous, and its synchronous
        // publish is a documented contract (Task 10 §7) that the sidebar,
        // palette and drop paths and their tests all rely on. The window is
        // one message hop, and the same hop pins the tab (spec §4) and so
        // closes it; widening `openFile` to an async contract for it is a
        // change of its own, not a line in this one.
        let opened = model.openReportingEviction(path: url.path, kind: kind, asPreview: !pinned)
        if let evicted = opened.evicted { discardResources(for: evicted) }
        if !hadTab, kind == .file { loadFileTab(url, classified: classified) }
        syncAll()
        showActiveContent()
    }

    /// Reads `url` off disk and hands Monaco a string — the only place a file
    /// tab's text enters the editor. Idempotent: a path that already has a
    /// live model is left alone, so re-activating a tab never clobbers the
    /// buffer with what is on disk.
    /// Why a text file cannot be opened at all, or `nil` if it can.
    ///
    /// `EditorFileClass.maxEditableBytes` only decides *read-only*; the whole
    /// file is still read here on the main thread and JSON-escaped into one JS
    /// string literal, so without a hard ceiling a 500 MB log freezes the app.
    /// `loadDiffContent` has refused on size since Task 12's review; this is
    /// the same refusal on the path that actually opens files.
    private func refusalMessage(for url: URL) -> String? {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int ?? 0
        guard size > EditorFileClass.maxReadableBytes else { return nil }
        let megabytes = EditorFileClass.maxReadableBytes / (1024 * 1024)
        return "\(url.lastPathComponent) is too large to open (over \(megabytes) MB)."
    }

    private func loadFileTab(_ url: URL, classified: EditorFileClass) {
        guard case let .text(readOnly) = classified else { return }
        guard !loadedPaths.contains(url.path) else { return }
        guard refusalMessage(for: url) == nil else { return }
        var encoding = String.Encoding.utf8
        var text: String? = try? String(contentsOf: url, encoding: .utf8)
        if text == nil {
            // Not valid UTF-8, but `EditorFileClass` already ruled out binary:
            // latin-1 maps every byte, so this always succeeds for real text.
            text = try? String(contentsOf: url, encoding: .isoLatin1)
            if text != nil { encoding = .isoLatin1 }
        }
        guard let text else {
            webHost.showMessage("Could not read \(url.lastPathComponent)")
            return
        }
        encodings[url.path] = encoding
        modificationDates[url.path] = modificationDate(of: url)
        loadedPaths.insert(url.path)
        if readOnly { readOnlyPaths.insert(url.path) } else { readOnlyPaths.remove(url.path) }
        webHost.openModel(path: url.path, content: text, readOnly: readOnly)
    }

    private func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    /// `url`'s working tree against its HEAD version, in Monaco's side-by-side
    /// diff editor. Always pinned: asking for a diff is never accidental.
    ///
    /// The content is fetched by `showActiveContent`, which is also what runs
    /// when the tab is focused again — one path, so a diff tab always shows
    /// what git says *now* rather than what it said when the tab was opened.
    func openDiff(_ url: URL) {
        model.open(path: url.path, kind: .diff, asPreview: false)
        syncAll()
        showActiveContent()
    }

    /// Both sides of the diff. The HEAD side is a subprocess and answers on
    /// the main thread; by then the user may well have moved to another tab,
    /// so the answer is dropped unless it is still the one on screen.
    ///
    /// The working-tree side is read here rather than taken from Monaco: a
    /// diff tab is a view of the *file*, and the file's own editor tab may
    /// not even be open. A file that vanished reads as empty, which is
    /// exactly the right left-side-only rendering for a deletion.
    private func loadDiffContent(_ url: URL) {
        // The same classifier the file tabs use, for the same two reasons —
        // and both bite harder here. Monaco only ever sees strings, so a
        // binary decoded latin-1 against a HEAD side full of U+FFFD is noise
        // rather than a diff; and this read is on the **main thread** with the
        // whole file in memory, so the size cap is what stops a changed 200 MB
        // asset from stalling the UI and then becoming a vast JS literal.
        //
        // A file that is *gone* is deliberately not classified: it cannot be,
        // and its diff — the whole left-hand side, nothing on the right — is
        // exactly what a deletion should look like.
        if FileManager.default.fileExists(atPath: url.path) {
            switch EditorFileClass.classify(url: url) {
            case .text(readOnly: false):
                break
            case .text(readOnly: true):
                webHost.showMessage(
                    "\(url.lastPathComponent) is too large to diff (over \(EditorFileClass.maxEditableBytes / (1024 * 1024)) MB)."
                )
                return
            case .image, .pdf, .binary:
                webHost.showMessage("Binary file — no textual diff.")
                return
            }
        }
        GitFileContent.headVersion(of: url) { [weak self] result in
            guard let self,
                  model.activeTab?.path == url.path,
                  model.activeTab?.kind == .diff
            else { return }
            switch result {
            case let .success(original):
                // The working side is capped above; HEAD's is not, and a file
                // that has since been truncated can still have a huge blob
                // behind it.
                guard original.utf8.count <= EditorFileClass.maxEditableBytes else {
                    webHost.showMessage("\(url.lastPathComponent) is too large to diff.")
                    return
                }
                let modified = (try? String(contentsOf: url, encoding: .utf8))
                    ?? (try? String(contentsOf: url, encoding: .isoLatin1))
                    ?? ""
                webHost.showDiff(path: url.path, original: original, modified: modified)
            case .failure:
                webHost.showMessage(
                    "Could not load the diff for \(url.lastPathComponent) — is this file in a git repository?"
                )
            }
        }
    }

    /// What one row of the overview shows once its diff comes back. The stat
    /// costs one syscall and happens only for the row the user actually
    /// opened — never for the whole list.
    static func hunkText(_ text: String?, for url: URL) -> String {
        if let text, !text.isEmpty { return text }
        // A non-nil empty answer really is "git had nothing to print": a
        // mode-only change, or a file whose staged and working copies match.
        if text != nil { return "No textual changes." }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            // `--untracked-files=normal` collapses a new folder into one
            // `dir/` record, and git cannot diff a directory at all.
            return "New folder — open a file inside it to see its diff."
        }
        return "Could not load this file's diff."
    }

    /// The repo-wide overview: every changed file, hunks expanding on demand.
    /// At most one per pane — the tab is keyed `("", .changes)`, so a second
    /// request focuses the tab that is already there.
    func openChanges() {
        model.open(path: "", kind: .changes, asPreview: false)
        syncAll()
        showActiveContent()
    }

    /// The workspace's `git status` changed (or a pane was just created and is
    /// being seeded). Updates the ± toggle's `changedPaths` *and* re-renders an
    /// open overview, which are the two things the status feeds.
    func setGitStatus(_ status: GitStatus?) {
        gitStatus = status
        changedPaths = Set(
            status.map { snapshot in
                snapshot.badges.keys.map { snapshot.root.appendingPathComponent($0).path }
            } ?? []
        )
        switch model.activeTab?.kind {
        case .changes:
            renderChanges()
        case .diff:
            // Spec §3: a diff tab shows what git says *now*. The status moving
            // is exactly the event that makes an open one stale, and until
            // this it only refreshed when the tab was re-activated.
            if let tab = model.activeTab { loadDiffContent(URL(fileURLWithPath: tab.path)) }
        default:
            break
        }
    }

    /// Files sorted by path, each with the FILES tree's own badge letter
    /// (`GitBadge.letter`, so the two surfaces read one mapping). The hunks
    /// are *not* fetched here — the page asks for them per row, as they open.
    private func renderChanges() {
        guard let status = gitStatus else {
            webHost.showMessage("Not a git repository — nothing to show.")
            return
        }
        webHost.showChanges(
            files: status.badges
                .sorted { $0.key < $1.key }
                .map { (path: $0.key, badge: $0.value.letter) }
        )
    }

    private func activateTab(_ index: Int) {
        // Same reason as `focus()`: switching to a tab is looking at it again.
        checkExternalChanges()
        model.activate(index)
        syncAll()
        // `showActiveContent` loads a restored tab's model on first sight.
        showActiveContent()
    }

    /// Routes the active tab to exactly one surface. Whether a `.file` tab is
    /// text or binary is re-derived here (one stat plus an 8 KB read) rather
    /// than cached in a parallel dictionary that could drift from disk.
    private func showActiveContent() {
        guard let tab = model.activeTab else {
            setContentVisibility(web: false, media: false, empty: true)
            return
        }
        switch tab.kind {
        case .file:
            // A file already open in Monaco stays in Monaco. Re-classifying it
            // here would let a file deleted or rewritten under the user (branch
            // switch, `git checkout`) flip a *dirty* buffer to the binary
            // placeholder: the edits would survive in the model but become
            // invisible, which reads as data loss.
            if loadedPaths.contains(tab.path) {
                webHost.showModel(path: tab.path)
                showBannerForActiveFile(tab.path)
                setContentVisibility(web: true, media: false, empty: false)
                return
            }
            let url = URL(fileURLWithPath: tab.path)
            let classified = EditorFileClass.classify(url: url)
            if case .text = classified {
                if let refusal = refusalMessage(for: url) {
                    webHost.showMessage(refusal)
                } else {
                    loadFileTab(url, classified: classified)
                    if loadedPaths.contains(tab.path) {
                        webHost.showModel(path: tab.path)
                        showBannerForActiveFile(tab.path)
                    } else {
                        webHost.showMessage("Could not read \(url.lastPathComponent)")
                    }
                }
                setContentVisibility(web: true, media: false, empty: false)
            } else {
                mediaHost.show(url: url, kind: .binary)
                setContentVisibility(web: false, media: true, empty: false)
            }
        case .media:
            let url = URL(fileURLWithPath: tab.path)
            mediaHost.show(url: url, kind: EditorFileClass.classify(url: url))
            setContentVisibility(web: false, media: true, empty: false)
        case .diff:
            setContentVisibility(web: true, media: false, empty: false)
            // Re-queried on every activation, not cached: the working tree
            // moves under a diff tab constantly (an edit, a stage, a branch
            // switch), and a stale diff is worse than a slow one.
            loadDiffContent(URL(fileURLWithPath: tab.path))
        case .changes:
            setContentVisibility(web: true, media: false, empty: false)
            // Redraws the status the pane is *holding* — it does not re-ask
            // git. Only the sidebar runs `git status`, and it pushes the
            // result in through `setGitStatus`, which re-renders too. This
            // call is what puts the list back after the web view showed
            // something else (another tab, a message, a renderer crash).
            renderChanges()
        }
    }

    private func showBannerForActiveFile(_ path: String) {
        let editable = EditorFileClass.maxEditableBytes / (1024 * 1024)
        webHost.showBanner(
            readOnlyPaths.contains(path) ? "Read-only — this file is over \(editable) MB." : ""
        )
    }

    private func setContentVisibility(web: Bool, media: Bool, empty: Bool) {
        webHost.isHidden = !web
        mediaHost.isHidden = !media
        emptyField.isHidden = !empty
    }

    // MARK: - Saving

    func saveActiveTab() { saveActiveTab { _ in } }

    func saveActiveTab(completion: @escaping (Bool) -> Void) {
        guard let tab = model.activeTab, tab.kind == .file else {
            completion(false)
            return
        }
        guard let index = model.index(of: tab.path, kind: .file) else {
            completion(false)
            return
        }
        save(at: index, completion: completion)
    }

    /// The one write path. Monaco is asked for the buffer, Swift writes it —
    /// atomically, in the encoding the file was read in. A failed write leaves
    /// the tab dirty and says so; it never silently drops the edit.
    ///
    /// The round trip to Monaco is asynchronous, so two things can change
    /// under it and both are guarded: the tab can be closed (a "Don't Save"
    /// close racing the save must not resurrect the discarded edit on disk),
    /// and the buffer can be typed into (`markSaved` is version-scoped, so a
    /// keystroke that landed after the snapshot stays dirty instead of being
    /// marked clean and later discarded without a prompt).
    /// Internal, not private: the controller's drop broker saves a dirty tab
    /// at a known index before letting it travel to another pane.
    func save(at index: Int, completion: @escaping (Bool) -> Void) {
        guard model.tabs.indices.contains(index), model.tabs[index].kind == .file else {
            completion(false)
            return
        }
        let path = model.tabs[index].path
        let url = URL(fileURLWithPath: path)
        webHost.requestContent(path: path) { [weak self] content, versionId in
            guard let self else {
                completion(false)
                return
            }
            guard model.index(of: path, kind: .file) != nil else {
                completion(false)
                return
            }
            guard let content else {
                presentError("\(url.lastPathComponent) could not be read back from the editor.")
                completion(false)
                return
            }
            do {
                try content.write(to: url, atomically: true, encoding: encodings[path] ?? .utf8)
            } catch {
                presentError("\(url.lastPathComponent): \(error.localizedDescription)")
                completion(false)
                return
            }
            modificationDates[path] = modificationDate(of: url)
            // The write recreated a file that had vanished, so the strip's
            // " (deleted)" mark is no longer true.
            if deletedPaths.remove(path) != nil { syncChrome() }
            // Version-scoped: the page leaves the tab dirty (and re-posts
            // nothing) when the buffer has moved past `versionId`.
            webHost.markSaved(path: path, versionId: versionId)
            // Dirty state (and with it the crash snapshot) is now the bridge's
            // to clear: it posts `dirtyChanged(false)` only when it actually
            // rebased, and `wireBridge` drops the snapshot there. Clearing it
            // eagerly here would re-open the very hole the version guard shuts.
            completion(true)
        }
    }

    /// Swift's copy of "is this buffer dirty". **Only meaningful straight
    /// after `reconcileDirtyFlags`** — see its doc comment. Every gate that
    /// decides whether to prompt reconciles first.
    var hasDirtyTabs: Bool { model.tabs.contains(where: \.isDirty) }

    /// Whether this pane holds any Monaco buffer at all. Cheap and always
    /// true-or-safe: a pane with no loaded buffer cannot be hiding unsaved
    /// work, so the close and quit paths can skip the asynchronous reconcile
    /// entirely for it.
    var hasLoadedBuffers: Bool { !loadedPaths.isEmpty }

    /// Brings `model.tabs[…].isDirty` into line with what the page actually
    /// holds, then answers.
    ///
    /// The flags are written **only** by the posted `dirtyChanged`, and a
    /// posted message is not ordered against anything — so a keystroke typed
    /// a moment ago can still read as clean. Every gate that decides whether
    /// to prompt about unsaved work (`requestCloseTab`, `drainDirtyTabs`, the
    /// controller's drop broker) therefore runs through here first: reading
    /// the flag without reconciling is how a buffer gets closed, or dragged
    /// away, with no prompt at all.
    ///
    /// `requestIsClean` is an `evaluateJavaScript` reply, which *is* ordered.
    /// Only loaded `.file` paths are asked — nothing else can be dirty — so a
    /// pane of media/diff/changes tabs costs nothing.
    func reconcileDirtyFlags(completion: @escaping () -> Void) {
        let paths = model.tabs
            .filter { $0.kind == .file && loadedPaths.contains($0.path) }
            .map(\.path)
        reconcile(paths, completion: completion)
    }

    private func reconcile(_ paths: [String], completion: @escaping () -> Void) {
        guard let path = paths.first else {
            completion()
            return
        }
        let rest = Array(paths.dropFirst())
        reconcileDirty(path: path) { [weak self] _ in
            guard let self else {
                completion()
                return
            }
            reconcile(rest, completion: completion)
        }
    }

    /// One path, answering the reconciled flag. A path Monaco never received
    /// cannot be dirty, and answers synchronously.
    private func reconcileDirty(path: String, completion: @escaping (Bool) -> Void) {
        guard loadedPaths.contains(path) else {
            completion(false)
            return
        }
        // With no live page, Swift's flag *is* the authority rather than a
        // lagging copy of one: nothing can have typed into a buffer that does
        // not exist yet, and after a renderer death the flag (plus
        // `dirtySnapshots`) is what carries the unsaved work. Asking anyway
        // would take `requestIsClean`'s deliberately conservative "not ready
        // means not clean" and turn it into a save prompt for a buffer nobody
        // has touched — every close and every drag in a pane's first seconds.
        guard webHost.isReady else {
            completion(model.index(of: path, kind: .file).map { model.tabs[$0].isDirty } ?? false)
            return
        }
        webHost.requestIsClean(path: path) { [weak self] clean in
            guard let self else {
                completion(!clean)
                return
            }
            if let index = model.index(of: path, kind: .file), model.tabs[index].isDirty != !clean {
                // `setDirty(true)` also *pins* the tab (spec §4: editing the
                // buffer pins it), which is a change to the persisted row —
                // so this publishes rather than only re-rendering the strip.
                model.setDirty(!clean, at: index)
                syncAll()
            }
            completion(!clean)
        }
    }

    /// Saves every dirty file tab, one after another — the writes are async
    /// (Monaco answers `requestContent` on a callback), so they are chained
    /// rather than looped. Stops at the first failure.
    /// Reconciles first for the same reason every other gate does: the filter
    /// below reads the dirty flags, and a keystroke whose `dirtyChanged` post
    /// has not landed would be silently left out of a Save All.
    func saveAllDirty(completion: @escaping (Bool) -> Void) {
        reconcileDirtyFlags { [weak self] in
            guard let self else {
                completion(false)
                return
            }
            saveSerially(model.tabs.filter { $0.isDirty && $0.kind == .file }.map(\.path), completion: completion)
        }
    }

    private func saveSerially(_ paths: [String], completion: @escaping (Bool) -> Void) {
        guard let path = paths.first else {
            completion(true)
            return
        }
        let rest = Array(paths.dropFirst())
        guard let index = model.index(of: path, kind: .file) else {
            saveSerially(rest, completion: completion)
            return
        }
        save(at: index) { [weak self] saved in
            guard saved, let self else {
                completion(false)
                return
            }
            saveSerially(rest, completion: completion)
        }
    }

    // MARK: - Closing

    /// Asynchronous **only when there is a buffer to ask about**: a media,
    /// diff, changes or never-loaded tab closes on the spot, exactly as
    /// before. A loaded `.file` tab costs one `evaluateJavaScript` round trip
    /// before it closes, because the alternative is reading a flag that lags
    /// a keystroke and closing over it with no prompt at all.
    func requestCloseTab(at index: Int) {
        guard model.tabs.indices.contains(index) else { return }
        let tab = model.tabs[index]
        guard tab.kind == .file, loadedPaths.contains(tab.path) else {
            // Nothing Monaco holds: a media, diff, changes or never-loaded
            // tab has no buffer that could be dirty.
            performClose(at: index)
            return
        }
        reconcileDirty(path: tab.path) { [weak self] dirty in
            guard let self else { return }
            // The round trip handed control back to the run loop; re-resolve.
            guard let index = model.index(of: tab.path, kind: tab.kind) else { return }
            guard dirty else {
                performClose(at: index)
                return
            }
            promptThenCloseTab(tab: tab, index: index)
        }
    }

    private func promptThenCloseTab(tab: EditorTab, index: Int) {
        confirmSave((tab.path as NSString).lastPathComponent) { [weak self] decision in
            guard let self else { return }
            switch decision {
            case .cancel: break
            case .discard:
                // By identity, and with **no fallback to the captured index**:
                // the reconcile round trip and the prompt both hand control
                // back to the run loop, and if the asked-about tab went away
                // in that window the captured slot now holds somebody else's
                // tab. Closing that one would dispose its Monaco model and
                // lose *its* unsaved edits, with no prompt at all. A tab that
                // is already gone needs no closing.
                guard let index = model.index(of: tab.path, kind: tab.kind) else { return }
                performClose(at: index)
            case .save:
                saveThenCloseIfClean(tab: tab, index: index) { [weak self] clean in
                    // Not clean means a keystroke landed inside the write and
                    // was correctly refused by the version-scoped `markSaved`.
                    // The decision the user made was about the *old* content;
                    // ask again rather than closing over the new edit.
                    guard let self, !clean else { return }
                    if let again = model.index(of: tab.path, kind: tab.kind) { requestCloseTab(at: again) }
                }
            }
        }
    }

    /// Saves tab `index` and reports what the **page** then says about the
    /// buffer — which is not the question `save`'s own `true` answers.
    ///
    /// This is the load-bearing distinction Task 15 exists to close.
    /// `save`'s `completion(true)` means "the bytes reached disk", **not**
    /// "the buffer is clean" — and the modal `confirmSave` alert does not
    /// protect the gap, because `NSAlert.runModal()` returns *before* the
    /// asynchronous `requestContent -> write -> markSaved` round trip even
    /// begins. A keystroke landing in that window is refused by the
    /// version-scoped `markSaved`, and would then be thrown away by any
    /// caller that destroys the buffer on `true` alone — a close, or a drag
    /// to another pane, which disposes the Monaco model just as finally.
    ///
    /// Internal: the controller's drop broker is the third caller, and it has
    /// exactly the same reason to wait for the acknowledgement.
    func saveAndConfirmClean(at index: Int, completion: @escaping (EditorSaveAcknowledgement) -> Void) {
        // An index that no longer exists reports `.failed` along with a write
        // that did not land. Both callers treat it the same way and must:
        // there is nothing to write and nothing to close, so the only correct
        // move either way is to stop and change nothing.
        guard model.tabs.indices.contains(index) else {
            completion(.failed)
            return
        }
        let path = model.tabs[index].path
        save(at: index) { [weak self] saved in
            guard let self, saved else {
                completion(.failed)
                return
            }
            // Ordered behind the `markSaved` the write just issued, which a
            // posted `dirtyChanged` message is not — so this is the only
            // decidable answer to "did the page accept the save?".
            webHost.requestIsClean(path: path) { clean in
                completion(clean ? .clean : .stillDirty)
            }
        }
    }

    /// Saves a tab, waits for the acknowledgement above, and closes it only if
    /// the buffer really did go clean.
    ///
    /// `completion` reports whether the tab was closed. A failed *write* never
    /// reaches it: that keeps `false` meaning exactly one thing at each call
    /// site — "still dirty, ask again" — while a write that cannot land stops
    /// the walk through `onFailure`.
    private func saveThenCloseIfClean(
        tab: EditorTab,
        index: Int,
        notifyLastClosed: Bool = true,
        onFailure: @escaping () -> Void = {},
        completion: @escaping (Bool) -> Void
    ) {
        saveAndConfirmClean(at: index) { [weak self] acknowledgement in
            guard let self else {
                onFailure()
                return
            }
            switch acknowledgement {
            case .failed:
                onFailure()
            case .stillDirty:
                completion(false)
            case .clean:
                // Identity only — never the captured index. If the tab went
                // away during the save, the slot it held now belongs to
                // another tab whose buffer would be disposed unprompted.
                //
                // A vanished tab still reports `true`: it is *resolved*, and
                // the bulk walk above must go on completing or the close or
                // quit waiting on it would never finish (the liveness hazard
                // round 3 fixed). That is why this cannot simply `return`,
                // the way the single-tab discard above can.
                if let index = model.index(of: tab.path, kind: tab.kind) {
                    performClose(at: index, notifyLastClosed: notifyLastClosed)
                }
                completion(true)
            }
        }
    }

    /// `notifyLastClosed: false` is the bulk-drain path: its caller is already
    /// tearing the pane down and closes it itself, so the "last tab went, close
    /// the pane" reflex would fire a second, redundant close underneath it.
    /// Passed per call rather than held as a flag — a `confirmSave` seam that
    /// never calls its `decide` callback would strand a flag `true` forever and
    /// silently break every later close.
    private func performClose(at index: Int, notifyLastClosed: Bool = true) {
        guard let closed = model.close(at: index) else { return }
        discardResources(for: closed)
        syncAll()
        showActiveContent()
        if model.tabs.isEmpty, notifyLastClosed { onLastTabClosed?() }
    }

    /// Releases everything a tab owned: its Monaco model and the three
    /// path-keyed dictionaries. Called from close *and* from preview-tab
    /// recycling, which evicts a tab without ever calling close.
    private func discardResources(for tab: EditorTab) {
        guard tab.kind == .file else { return }
        if loadedPaths.remove(tab.path) != nil { webHost.closeModel(path: tab.path) }
        encodings.removeValue(forKey: tab.path)
        modificationDates.removeValue(forKey: tab.path)
        dirtySnapshots.removeValue(forKey: tab.path)
        deletedPaths.remove(tab.path)
        readOnlyPaths.remove(tab.path)
    }

    /// Resolves every dirty tab with a prompt and closes it. `false` means the
    /// user cancelled (or a save failed) and the close/quit must stop — the
    /// pane is left exactly as far along as the walk got.
    func closeAllTabsAfterConfirmation(completion: @escaping (Bool) -> Void) {
        drainDirtyTabs(completion: completion)
    }

    /// Each pass reconciles before it scans: "nothing is dirty" is the answer
    /// that lets a pane, a window or the whole app go away, so it may not be
    /// read off a flag that lags a keystroke.
    private func drainDirtyTabs(completion: @escaping (Bool) -> Void) {
        reconcileDirtyFlags { [weak self] in
            guard let self else {
                completion(false)
                return
            }
            drainReconciledDirtyTabs(completion: completion)
        }
    }

    private func drainReconciledDirtyTabs(completion: @escaping (Bool) -> Void) {
        guard let index = model.tabs.firstIndex(where: \.isDirty) else {
            completion(true)
            return
        }
        let tab = model.tabs[index]
        confirmSave((tab.path as NSString).lastPathComponent) { [weak self] decision in
            guard let self else {
                completion(false)
                return
            }
            switch decision {
            case .cancel:
                completion(false)
            case .discard:
                // Identity only, and the walk continues either way: a tab that
                // vanished during the prompt is already resolved, but the
                // drain still has to run to completion or the close or quit
                // waiting on it hangs.
                if let index = model.index(of: tab.path, kind: tab.kind) {
                    performClose(at: index, notifyLastClosed: false)
                }
                drainDirtyTabs(completion: completion)
            case .save:
                saveThenCloseIfClean(
                    tab: tab,
                    index: index,
                    notifyLastClosed: false,
                    // A write that could not land is not "resolved": it stops
                    // the walk, exactly as it did before.
                    onFailure: { completion(false) }
                ) { [weak self] _ in
                    // Closed or not, the next step is the same: drain what is
                    // still dirty. A tab that stayed dirty because a keystroke
                    // landed inside the write is simply asked about again.
                    self?.drainDirtyTabs(completion: completion)
                }
            }
        }
    }

    // MARK: - Sync

    private func syncAll() { sync(publish: true) }

    private func sync(publish: Bool) {
        strip.render(model: model, diffAvailable: activeFileHasChanges(), deletedPaths: deletedPaths)
        onTitleChange?(model.activeTab.map(EditorTabStripView.title(for:)) ?? "Editor")
        guard publish else { return }
        onStateChange?(persistedTabs, model.activeIndex)
    }

    /// Chrome only — neither `changedPaths` nor `deletedPaths` moving is a tab
    /// mutation, so neither may republish the persisted row.
    private func syncChrome() {
        strip.render(model: model, diffAvailable: activeFileHasChanges(), deletedPaths: deletedPaths)
    }

    private var persistedTabs: [PersistedEditorTab] {
        model.tabs.map { PersistedEditorTab(path: $0.path, kind: $0.kind.rawValue, pinned: $0.isPinned) }
    }

    private func activeFileHasChanges() -> Bool {
        guard let tab = model.activeTab, tab.kind == .file else { return false }
        return changedPaths.contains(tab.path)
    }

    // MARK: - Test hooks

    /// Mutates the model the way the strip's callbacks would, then re-syncs —
    /// the only supported way for a test to fabricate tab state.
    func modelForTesting(_ mutate: (inout EditorPaneModel) -> Void) {
        mutate(&model)
        syncAll()
    }

    /// Stands in for the bridge's debounced `contentSnapshot`, which takes two
    /// real seconds to arrive.
    func injectSnapshotForTesting(path: String, content: String) {
        dirtySnapshots[path] = content
    }

    /// Kills the renderer through the *production* seam — the delegate
    /// callback WebKit itself calls — so the test drives the real crash path
    /// (queue dropped, page reloaded, `onCrash` then `onReady`) rather than a
    /// second implementation of it.
    func simulateRendererCrashForTesting() {
        webHost.webViewWebContentProcessDidTerminate(webHost.webView)
    }

    /// The fallback when a pane ask has nowhere to appear; see
    /// `WorkspaceWindowController.wireEditorPane`.
    static func defaultConfirmSave(_ name: String, _ decide: @escaping (EditorSaveDecision) -> Void) {
        let alert = NSAlert()
        alert.messageText = "Save changes to \(name)?"
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: decide(.save)
        case .alertSecondButtonReturn: decide(.discard)
        default: decide(.cancel)
        }
    }
}

/// A tab only ever *moves*, and only inside this app — copying one would mean
/// two panes editing one file through two Monaco models. `PaneContainerView`'s
/// pane drag says exactly the same thing for the same reason.
extension EditorPaneView: NSDraggingSource {
    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }
}
