import AppKit

/// What the user chose in the "save before closing?" prompt.
enum EditorSaveDecision { case save, discard, cancel }

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

    /// Per-open-file bookkeeping, keyed by absolute path.
    private var encodings: [String: String.Encoding] = [:]
    private var modificationDates: [String: Date] = [:]
    /// Paths that currently have a live Monaco model. Also the "did this file
    /// read successfully?" answer — a file we could not read never lands here,
    /// so `showActiveContent` shows the message instead of an empty editor.
    private(set) var loadedPaths: Set<String> = []
    /// Debounced dirty-buffer snapshots from the bridge — crash insurance
    /// (Task 15 replays them on renderer death).
    private(set) var dirtySnapshots: [String: String] = [:]

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
    func focus() { window?.makeFirstResponder(primaryResponderView) }
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
            guard let self, let tab = model.activeTab, tab.kind == .file else { return }
            onOpenDiffRequest?(URL(fileURLWithPath: tab.path))
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
            GitFileContent.unifiedDiff(of: root.appendingPathComponent(relative)) { [weak self] text in
                self?.webHost.appendFileDiff(
                    path: relative,
                    text: text?.isEmpty == false ? (text ?? "") : "No textual changes."
                )
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
        // onCrash wired in Task 15.
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
    private func loadFileTab(_ url: URL, classified: EditorFileClass) {
        guard case let .text(readOnly) = classified else { return }
        guard !loadedPaths.contains(url.path) else { return }
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
        GitFileContent.headVersion(of: url) { [weak self] result in
            guard let self,
                  model.activeTab?.path == url.path,
                  model.activeTab?.kind == .diff
            else { return }
            switch result {
            case let .success(original):
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
        if model.activeTab?.kind == .changes { renderChanges() }
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
                setContentVisibility(web: true, media: false, empty: false)
                return
            }
            let url = URL(fileURLWithPath: tab.path)
            let classified = EditorFileClass.classify(url: url)
            if case .text = classified {
                loadFileTab(url, classified: classified)
                if loadedPaths.contains(tab.path) {
                    webHost.showModel(path: tab.path)
                } else {
                    webHost.showMessage("Could not read \(url.lastPathComponent)")
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
            // Re-rendered on focus for the diff tab's reason: the list is a
            // snapshot, and the pane has usually been away while the working
            // tree moved.
            renderChanges()
        }
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

    var hasDirtyTabs: Bool { model.tabs.contains(where: \.isDirty) }

    /// Saves every dirty file tab, one after another — the writes are async
    /// (Monaco answers `requestContent` on a callback), so they are chained
    /// rather than looped. Stops at the first failure.
    func saveAllDirty(completion: @escaping (Bool) -> Void) {
        saveSerially(model.tabs.filter { $0.isDirty && $0.kind == .file }.map(\.path), completion: completion)
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

    func requestCloseTab(at index: Int) {
        guard model.tabs.indices.contains(index) else { return }
        let tab = model.tabs[index]
        guard tab.isDirty else {
            performClose(at: index)
            return
        }
        confirmSave((tab.path as NSString).lastPathComponent) { [weak self] decision in
            guard let self else { return }
            switch decision {
            case .cancel: break
            case .discard: performClose(at: index)
            case .save:
                save(at: index) { saved in
                    if saved { self.performClose(at: self.model.index(of: tab.path, kind: tab.kind) ?? index) }
                }
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
    }

    /// Resolves every dirty tab with a prompt and closes it. `false` means the
    /// user cancelled (or a save failed) and the close/quit must stop — the
    /// pane is left exactly as far along as the walk got.
    func closeAllTabsAfterConfirmation(completion: @escaping (Bool) -> Void) {
        drainDirtyTabs(completion: completion)
    }

    private func drainDirtyTabs(completion: @escaping (Bool) -> Void) {
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
                performClose(at: index, notifyLastClosed: false)
                drainDirtyTabs(completion: completion)
            case .save:
                save(at: index) { [weak self] saved in
                    guard saved, let self else {
                        completion(false)
                        return
                    }
                    performClose(at: model.index(of: tab.path, kind: tab.kind) ?? index, notifyLastClosed: false)
                    drainDirtyTabs(completion: completion)
                }
            }
        }
    }

    // MARK: - Sync

    private func syncAll() { sync(publish: true) }

    private func sync(publish: Bool) {
        strip.render(model: model, diffAvailable: activeFileHasChanges())
        onTitleChange?(model.activeTab.map(EditorTabStripView.title(for:)) ?? "Editor")
        guard publish else { return }
        onStateChange?(persistedTabs, model.activeIndex)
    }

    /// Chrome only — `changedPaths` moving is not a tab mutation, so it must
    /// not republish the persisted row.
    private func syncChrome() {
        strip.render(model: model, diffAvailable: activeFileHasChanges())
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

    private static func defaultConfirmSave(_ name: String, _ decide: @escaping (EditorSaveDecision) -> Void) {
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
