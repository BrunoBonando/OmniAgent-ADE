import AppKit

// The review panel's Files tab — the 2026-08-20 redesign's §5. The workspace
// file tree (migrated here from the old sliding sidebar, where nothing mounts
// it any more) sits beside an embedded single-file Monaco view; a slim
// controls bar carries the gear popover (Show hidden files, File tree
// position Left/Right) and the hide-tree toggle. The two gear preferences and
// the open file persist per session in the `review_panel_native` row; the
// hide-tree toggle is deliberately transient.

// MARK: - File row

/// One row of the Finder-like tree.
final class WorkspaceFileRowView: ShellRowView {
    let node: WorkspaceFileNode

    /// Pressing the git badge asks for the file's diff instead of opening it.
    /// `nil` on every row that has no badge to press — a clean file's whole
    /// width stays "open this file".
    var onBadgePress: (() -> Void)?

    private let chevron: ShellGlyphView?
    private let badgeField: NSTextField
    private var isSelected: Bool
    /// Set on a mouse-down that landed on the badge, so the *release* decides
    /// — a press that starts on the badge and ends elsewhere does nothing, the
    /// way every other control on the platform behaves.
    private var badgePressArmed = false

    init(node: WorkspaceFileNode, depth: Int, expanded: Bool, selected: Bool) {
        self.node = node
        isSelected = selected
        chevron = node.isDirectory
            ? ShellGlyphView(.chevronRight, color: ShellPalette.chevron, size: 15, lineWidth: 1.6)
            : nil
        badgeField = ShellFont.label(
            WorkspaceFileRowView.badgeText(node),
            font: ShellFont.mono(node.isDirectory ? 11.5 : 12, .semibold),
            color: WorkspaceFileRowView.badgeColor(node)
        )
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous
        hoverEnabled = false
        chevron?.rotated = expanded

        // The design indents 13pt for the first level and 21pt after it, which
        // is what keeps a file's icon aligned under its folder's name rather
        // than under its folder's chevron.
        let indent: CGFloat = depth == 0 ? 8 : 8 + 13 + CGFloat(depth - 1) * 21

        let icon = ShellGlyphView(
            node.isDirectory ? .folder : .file,
            color: node.isDirectory ? ShellPalette.folderGlyph : ShellPalette.fileGlyph,
            size: node.isDirectory ? 20 : 19,
            lineWidth: 1.1
        )
        icon.alphaValue = node.isDirectory ? (depth <= 1 ? 0.85 : 0.7) : 1

        let name = ShellFont.label(
            node.name,
            font: ShellFont.ui(14.5, node.isDirectory ? .medium : .regular),
            color: WorkspaceFileRowView.nameColor(node: node, depth: depth, selected: selected)
        )

        let badge = badgeField

        var leading: NSLayoutXAxisAnchor = leadingAnchor
        var offset = indent
        if let chevron {
            addSubview(chevron)
            NSLayoutConstraint.activate([
                chevron.leadingAnchor.constraint(equalTo: leadingAnchor, constant: indent),
                chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
            leading = chevron.trailingAnchor
            offset = 5
        } else {
            // The design reserves the chevron's width on leaf rows so names
            // still line up in a column.
            offset = indent + 9
        }

        for view in [icon, name, badge] { addSubview(view) }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leading, constant: offset),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),

            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 5),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
            name.trailingAnchor.constraint(equalTo: badge.leadingAnchor, constant: -5),

            badge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),

            heightAnchor.constraint(equalToConstant: ShellMetrics.fileRowHeight),
        ])
        badge.setContentCompressionResistancePriority(.required, for: .horizontal)
        badge.setContentHuggingPriority(.required, for: .horizontal)
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        refreshBackground()
        setAccessibilityLabel(node.name)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func setExpanded(_ expanded: Bool) { chevron?.rotated = expanded }

    /// The badge is a small target, so it is grown by 6 pt on every side —
    /// enough to hit reliably, still far from the name.
    private func isBadgePoint(_ point: NSPoint) -> Bool {
        guard onBadgePress != nil, !badgeField.isHidden, !badgeField.stringValue.isEmpty else { return false }
        return badgeField.frame.insetBy(dx: -6, dy: -6).contains(point)
    }

    override func mouseDown(with event: NSEvent) {
        if isBadgePoint(convert(event.locationInWindow, from: nil)) {
            badgePressArmed = true
            return
        }
        super.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        guard badgePressArmed else {
            super.mouseUp(with: event)
            return
        }
        badgePressArmed = false
        guard isBadgePoint(convert(event.locationInWindow, from: nil)) else { return }
        onBadgePress?()
    }

    override func refreshBackground() {
        let fill: NSColor
        if isSelected {
            fill = ShellPalette.rowSelected
        } else if isHovered {
            fill = ShellPalette.hoverFile
        } else {
            fill = .clear
        }
        layer?.backgroundColor = fill.cgColor
    }

    private static func nameColor(node: WorkspaceFileNode, depth: Int, selected: Bool) -> NSColor {
        if selected { return ShellPalette.inkFile }
        if node.isDirectory { return depth == 0 ? ShellPalette.inkFolder : ShellPalette.inkSecondary }
        return node.gitBadge == nil ? ShellPalette.inkTertiary : ShellPalette.inkSecondary
    }

    static func badgeText(_ node: WorkspaceFileNode) -> String {
        if node.isDirectory { return node.changedCount == 0 ? "" : "\(node.changedCount)" }
        return node.gitBadge?.letter ?? ""
    }

    static func badgeColor(_ node: WorkspaceFileNode) -> NSColor {
        if node.isDirectory { return ShellPalette.green }
        switch node.gitBadge {
        case .modified, .renamed: return ShellPalette.amber
        case .added, .untracked: return ShellPalette.green
        case .deleted, .conflicted: return ShellPalette.red
        case nil: return .clear
        }
    }
}

// MARK: - Files tree

/// The FILES section: header with the diff counts, a filter field, and a
/// lazily expanded tree with git state on the right.
final class WorkspaceFilesTreeView: NSView {
    /// `(url, pinned)` — VS Code's rule: a single click previews, a double
    /// click pins.
    var onOpenFile: ((URL, Bool) -> Void)?
    /// A git badge was clicked: show that file's diff against HEAD.
    var onOpenDiff: ((URL) -> Void)?
    /// The header's +N −M counts were clicked: show the repo-wide overview.
    var onOpenAllChanges: (() -> Void)?
    /// Every `git status` this tree loads, so the editor panes render the same
    /// snapshot the badges were drawn from rather than running git again.
    var onStatusChanged: ((GitStatus?) -> Void)?

    /// Lifts the leading-dot rule (the gear's "Show hidden files"). A plain
    /// flag with no side effects: callers re-`setRoot` to make it take.
    var showsHiddenFiles = false

    /// The context menu's name prompt, a seam so tests can answer without a
    /// modal. `nil` from the closure is a cancel.
    var promptForName: (String, @escaping (String?) -> Void) -> Void =
        WorkspaceFilesTreeView.defaultPromptForName

    private let diffField = ShellFont.label(font: ShellFont.mono(12, .semibold), color: ShellPalette.green)
    /// Held so it can be disabled outside a repository — see
    /// `updateDiffHeaderAvailability`.
    private lazy var diffHeaderRecognizer = NSClickGestureRecognizer(
        target: self,
        action: #selector(diffHeaderPressed)
    )
    private let filterField = NSTextField()
    private let rows = NSStackView()
    private var root: URL?
    /// The last `git status`. Kept whole rather than reduced to its badge map
    /// so path math goes through `GitStatus`, which resolves the `/var` vs
    /// `/private/var` symlink case a string prefix silently gets wrong.
    private var gitStatus: GitStatus?
    private var expanded: Set<URL> = []
    private(set) var selected: URL?
    /// Children already listed, so re-rendering a collapse does not re-hit the
    /// filesystem for every level.
    private var children: [URL: [WorkspaceFileNode]] = [:]
    /// The rows run their own mouse handling, so `NSEvent.clickCount` never
    /// reaches `activate(_:)`; this stands in for it.
    private var doublePress = DoublePressDetector()

    var rootForTesting: URL? { root }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        let header = ShellFont.label(
            "FILES",
            font: ShellFont.ui(12, .semibold),
            color: ShellPalette.inkMuted,
            tracking: 1.2
        )

        filterField.font = ShellFont.ui(14)
        filterField.textColor = ShellPalette.inkSecondary
        filterField.placeholderString = "Filter files…"
        filterField.isBordered = false
        filterField.drawsBackground = false
        filterField.focusRingType = .none
        filterField.translatesAutoresizingMaskIntoConstraints = false
        filterField.target = self
        filterField.action = #selector(filterChanged)

        let fieldBox = NSView()
        fieldBox.wantsLayer = true
        fieldBox.layer?.backgroundColor = ShellPalette.fieldFill.cgColor
        fieldBox.layer?.cornerRadius = 6
        fieldBox.layer?.cornerCurve = .continuous
        fieldBox.layer?.borderWidth = 1
        fieldBox.layer?.borderColor = ShellPalette.hairline.cgColor
        fieldBox.translatesAutoresizingMaskIntoConstraints = false
        let magnifier = ShellGlyphView(.magnifier, color: ShellPalette.chevronSoft, size: 18, lineWidth: 1.3)
        magnifier.alphaValue = 0.45
        fieldBox.addSubview(magnifier)
        fieldBox.addSubview(filterField)

        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 0
        rows.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 8, right: 6)
        rows.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.contentView = ShellFlippedClipView()
        scroll.documentView = rows
        scroll.translatesAutoresizingMaskIntoConstraints = false

        for view in [header, diffField, fieldBox, scroll] { addSubview(view) }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),

            diffField.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            diffField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),

            fieldBox.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 5),
            fieldBox.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            fieldBox.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            fieldBox.heightAnchor.constraint(equalToConstant: 24),

            magnifier.leadingAnchor.constraint(equalTo: fieldBox.leadingAnchor, constant: 8),
            magnifier.centerYAnchor.constraint(equalTo: fieldBox.centerYAnchor),

            filterField.leadingAnchor.constraint(equalTo: magnifier.trailingAnchor, constant: 6),
            filterField.trailingAnchor.constraint(equalTo: fieldBox.trailingAnchor, constant: -8),
            filterField.centerYAnchor.constraint(equalTo: fieldBox.centerYAnchor),

            scroll.topAnchor.constraint(equalTo: fieldBox.bottomAnchor, constant: 7),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),

            rows.widthAnchor.constraint(equalTo: scroll.widthAnchor),
            rows.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
        ])
        setDiff(added: 0, removed: 0)

        // The counts are the button for the repo-wide overview — a gesture
        // recognizer rather than a button, because the design's header is a
        // two-colour attributed string and an NSButton cannot wear one
        // without a custom cell.
        diffField.addGestureRecognizer(diffHeaderRecognizer)
        diffField.setAccessibilityLabel("Show all changes")
        // Inert until a `git status` actually lands: outside a repository
        // there is no overview to show, and a click that opens a tab saying
        // so is worse than a header that simply is not a button.
        updateDiffHeaderAvailability()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    @objc private func filterChanged() { render() }

    @objc private func diffHeaderPressed() { onOpenAllChanges?() }

    /// Programmatic filtering, for callers and tests without a field editor.
    func setFilter(_ text: String) {
        filterField.stringValue = text
        render()
    }

    /// The counts are a button only where there is a repository behind them.
    private func updateDiffHeaderAvailability() {
        let inRepository = gitStatus != nil
        diffHeaderRecognizer.isEnabled = inRepository
        diffField.setAccessibilityElement(inRepository)
        diffField.setAccessibilityRole(inRepository ? .button : .staticText)
    }

    func setDiff(added: Int, removed: Int) {
        let font = ShellFont.mono(12, .semibold)
        let string = NSMutableAttributedString(
            string: "+\(added)",
            attributes: [.font: font, .foregroundColor: ShellPalette.green]
        )
        string.append(NSAttributedString(
            string: "−\(removed)",
            attributes: [.font: font, .foregroundColor: ShellPalette.red]
        ))
        diffField.attributedStringValue = string
    }

    /// Point the tree at a workspace. Listing, `git status` and the diff totals
    /// all happen off the main thread — a cold `git status` on a large repo is
    /// tens of milliseconds and must never land on a keystroke.
    func setRoot(_ url: URL?) {
        root = url
        gitStatus = nil
        expanded = []
        children = [:]
        selected = nil
        setDiff(added: 0, removed: 0)
        updateDiffHeaderAvailability()
        render()
        // The reset is reported too: a pane must not keep rendering the last
        // workspace's changes while this one's status is still loading.
        onStatusChanged?(nil)
        guard let url else { return }

        let hidden = showsHiddenFiles
        DispatchQueue.global(qos: .userInitiated).async {
            let listing = WorkspaceFiles.children(of: url, includingHidden: hidden)
            let repo = GitStatus.repoRoot(for: url)
            let status = repo.flatMap { GitStatus.load(repoRoot: $0) }
            let totals = repo.flatMap { WorkspaceFilesTreeView.diffTotals(repoRoot: $0) } ?? (0, 0)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.root == url else { return }
                self.children[url] = listing
                self.gitStatus = status
                self.setDiff(added: totals.added, removed: totals.removed)
                self.updateDiffHeaderAvailability()
                self.render()
                self.onStatusChanged?(status)
            }
        }
    }

    /// `git status --porcelain` says *which* files changed but not by how much,
    /// and the design's header prints lines. One extra `--shortstat` is cheaper
    /// than parsing a full diff, and it covers staged and unstaged together.
    static func diffTotals(repoRoot: URL) -> (added: Int, removed: Int)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", repoRoot.path, "diff", "--shortstat", "HEAD"]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8)
        else { return nil }

        func number(before keyword: String) -> Int {
            guard let range = text.range(of: keyword) else { return 0 }
            let head = text[text.startIndex..<range.lowerBound]
            let digits = head.reversed().drop(while: { $0 == " " }).prefix(while: \.isNumber)
            return Int(String(digits.reversed())) ?? 0
        }
        return (number(before: "insertion"), number(before: "deletion"))
    }

    // MARK: - New file / New folder

    /// The directory a right-click at `point` (in this view's coordinates)
    /// targets: a directory row is itself the target, a file row targets the
    /// directory that holds it, and the space below the rows targets the root.
    func contextDirectory(at point: NSPoint) -> URL? {
        guard let root else { return nil }
        for case let row as WorkspaceFileRowView in rows.arrangedSubviews {
            let frame = rows.convert(row.frame, to: self)
            guard frame.contains(point) else { continue }
            return row.node.isDirectory ? row.node.url : row.node.url.deletingLastPathComponent()
        }
        return root
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let directory = contextDirectory(at: convert(event.locationInWindow, from: nil)) else {
            return super.menu(for: event)
        }
        return makeContextMenu(for: directory)
    }

    func makeContextMenu(for directory: URL) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(ShellMenuItem("New File…") { [weak self] in
            self?.promptAndCreate(isDirectory: false, in: directory)
        })
        menu.addItem(ShellMenuItem("New Folder…") { [weak self] in
            self?.promptAndCreate(isDirectory: true, in: directory)
        })
        return menu
    }

    private func promptAndCreate(isDirectory: Bool, in directory: URL) {
        promptForName(isDirectory ? "New Folder" : "New File") { [weak self] name in
            guard let name else { return }
            self?.createEntry(named: name, isDirectory: isDirectory, in: directory)
        }
    }

    /// Creates the entry on disk and selects its node. A name that already
    /// exists just selects it — the user's intent ("I want this to exist,
    /// selected") is already satisfied, and clobbering would be worse.
    func createEntry(named name: String, isDirectory: Bool, in directory: URL) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/") else { return }
        let target = directory.appendingPathComponent(trimmed).standardizedFileURL
        if !FileManager.default.fileExists(atPath: target.path) {
            if isDirectory {
                guard (try? FileManager.default.createDirectory(
                    at: target, withIntermediateDirectories: false
                )) != nil else { return }
            } else {
                guard FileManager.default.createFile(atPath: target.path, contents: Data()) else {
                    return
                }
            }
        }
        selected = target
        // A collapsed target directory opens so the selection is on screen.
        if directory != root { expanded.insert(directory) }
        // The cached level predates the new inode; re-list it.
        let expectedRoot = root
        WorkspaceFiles.list(directory, includingHidden: showsHiddenFiles) { [weak self] listing in
            guard let self, self.root == expectedRoot else { return }
            self.children[directory] = listing
            self.render()
        }
        render()
    }

    /// The fallback when nothing stubs the prompt: a small modal ask.
    static func defaultPromptForName(_ title: String, _ completion: @escaping (String?) -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.placeholderString = "Name"
        alert.accessoryView = field
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        completion(alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil)
    }

    // MARK: - Rendering

    private func render() {
        for view in rows.arrangedSubviews {
            rows.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        guard let root else { return }
        let needle = filterField.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        appendRows(of: root, depth: 0, filter: needle)
    }

    private func appendRows(of directory: URL, depth: Int, filter: String) {
        let listing = children[directory] ?? []
        for node in listing {
            let matches = filter.isEmpty || node.name.lowercased().contains(filter)
            let isOpen = expanded.contains(node.url)
            // A filtered-out directory still shows when something under it
            // matches, otherwise the match would be unreachable.
            if !matches && !node.isDirectory { continue }

            let annotated = annotate(node)
            let row = WorkspaceFileRowView(
                node: annotated,
                depth: depth,
                expanded: isOpen,
                selected: node.url == selected
            )
            row.onPress = { [weak self] in self?.activate(node) }
            // Only a changed file has a badge, and only a badge is clickable:
            // a directory's count is an aggregate with no single diff behind
            // it, and a clean file has nothing to show.
            if !node.isDirectory, annotated.gitBadge != nil {
                row.onBadgePress = { [weak self] in self?.onOpenDiff?(node.url) }
            }
            rows.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rows.widthAnchor, constant: -12).isActive = true

            if node.isDirectory && isOpen {
                appendRows(of: node.url, depth: depth + 1, filter: filter)
            }
        }
    }

    /// Git state is looked up at render time from the porcelain map, so one
    /// `git status` annotates every level without re-walking.
    private func annotate(_ node: WorkspaceFileNode) -> WorkspaceFileNode {
        guard let gitStatus else { return node }
        var copy = node
        if node.isDirectory {
            copy.changedCount = gitStatus.relativePath(for: node.url)
                .map(gitStatus.changedCount(under:)) ?? 0
        } else {
            copy.gitBadge = gitStatus.badge(for: node.url)
        }
        return copy
    }

    private func activate(_ node: WorkspaceFileNode) {
        guard node.isDirectory else {
            selected = node.url
            // `systemUptime` rather than wall clock: monotonic, so a clock
            // adjustment between two clicks cannot invent or swallow a double.
            let pinned = doublePress.register(node.url.path, at: ProcessInfo.processInfo.systemUptime)
            onOpenFile?(node.url, pinned)
            render()
            return
        }
        if expanded.contains(node.url) {
            expanded.remove(node.url)
            render()
            return
        }
        expanded.insert(node.url)
        guard children[node.url] == nil else {
            render()
            return
        }
        // Expanding is the only thing that touches the disk after the first
        // load, and a cold directory on a network volume can block.
        WorkspaceFiles.list(node.url, includingHidden: showsHiddenFiles) { [weak self] listing in
            guard let self, self.expanded.contains(node.url) else { return }
            self.children[node.url] = listing
            self.render()
        }
        render()
    }
}

// MARK: - The Files tab

/// The tab's whole content: controls bar, tree column, single-file Monaco
/// viewer. Reports preference and open-file changes up; which session they
/// belong to — and everything persisted — is `WorkspaceWindowController`'s
/// business, exactly like `ReviewPanelView`'s tabs.
final class ReviewPanelFilesView: NSView {
    enum TreePosition: String {
        case left
        case right
    }

    static let controlsHeight: CGFloat = 30
    static let treeWidth: CGFloat = 232

    let tree = WorkspaceFilesTreeView(frame: .zero)
    let gearButton = ReviewPanelIconButton(symbol: "gearshape", label: "File tree settings")
    let hideTreeButton = ReviewPanelIconButton(symbol: "sidebar.left", label: "Hide file tree")
    let viewerContainer = NSView()

    /// A user preference changed by hand (hidden files, tree position) —
    /// never fired by `apply`, which is the restore path.
    var onPreferencesChanged: (() -> Void)?
    /// The open file changed by a click — same restore rule.
    var onOpenFileChanged: ((String?) -> Void)?
    var onOpenDiff: ((URL) -> Void)?
    var onOpenAllChanges: (() -> Void)?

    private(set) var treePosition: TreePosition = .left
    private(set) var isTreeHidden = false
    private(set) var currentOpenFilePath: String?
    private(set) var rootURL: URL?
    /// Created on the first open, not in `init`: a WKWebView costs a WebKit
    /// content process, and most sessions never open a file here.
    private(set) var webHost: EditorWebView?

    var showsHiddenFiles: Bool { tree.showsHiddenFiles }

    private let controlsBar = NSView()
    private let fileNameField = ShellFont.label(
        font: ShellFont.ui(12, .medium),
        color: ShellPalette.inkSecondary
    )
    private let treeDivider = NSView()
    private let emptyField = ShellFont.label(
        "Click a file to open it here",
        font: ShellFont.ui(13),
        color: ShellPalette.inkMuted
    )
    private var settingsPopover: NSPopover?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // No ground of its own: the panel behind it is the glass sheet, and an
        // opaque fill here would be a slab sitting on top of it.

        let barHairline = NSView()
        barHairline.wantsLayer = true
        barHairline.layer?.backgroundColor = ShellPalette.hairline.cgColor
        barHairline.translatesAutoresizingMaskIntoConstraints = false

        fileNameField.lineBreakMode = .byTruncatingMiddle
        fileNameField.maximumNumberOfLines = 1

        controlsBar.addSubview(fileNameField)
        controlsBar.addSubview(gearButton)
        controlsBar.addSubview(hideTreeButton)
        controlsBar.addSubview(barHairline)
        NSLayoutConstraint.activate([
            fileNameField.leadingAnchor.constraint(equalTo: controlsBar.leadingAnchor, constant: 10),
            fileNameField.centerYAnchor.constraint(equalTo: controlsBar.centerYAnchor),
            fileNameField.trailingAnchor.constraint(
                lessThanOrEqualTo: gearButton.leadingAnchor, constant: -8
            ),

            hideTreeButton.trailingAnchor.constraint(equalTo: controlsBar.trailingAnchor, constant: -8),
            hideTreeButton.centerYAnchor.constraint(equalTo: controlsBar.centerYAnchor),
            gearButton.trailingAnchor.constraint(equalTo: hideTreeButton.leadingAnchor, constant: -4),
            gearButton.centerYAnchor.constraint(equalTo: controlsBar.centerYAnchor),

            barHairline.leadingAnchor.constraint(equalTo: controlsBar.leadingAnchor),
            barHairline.trailingAnchor.constraint(equalTo: controlsBar.trailingAnchor),
            barHairline.bottomAnchor.constraint(equalTo: controlsBar.bottomAnchor),
            barHairline.heightAnchor.constraint(equalToConstant: 1),
        ])

        treeDivider.wantsLayer = true
        treeDivider.layer?.backgroundColor = ShellPalette.hairline.cgColor

        emptyField.translatesAutoresizingMaskIntoConstraints = false
        viewerContainer.addSubview(emptyField)
        NSLayoutConstraint.activate([
            emptyField.centerXAnchor.constraint(equalTo: viewerContainer.centerXAnchor),
            emptyField.centerYAnchor.constraint(equalTo: viewerContainer.centerYAnchor),
        ])

        for view in [controlsBar, tree, treeDivider, viewerContainer] { addSubview(view) }

        gearButton.onPress = { [weak self] in self?.presentSettingsPopover() }
        hideTreeButton.onPress = { [weak self] in
            guard let self else { return }
            setTreeHidden(!isTreeHidden)
        }
        tree.onOpenFile = { [weak self] url, _ in self?.openFile(url, notify: true) }
        tree.onOpenDiff = { [weak self] url in self?.onOpenDiff?(url) }
        tree.onOpenAllChanges = { [weak self] in self?.onOpenAllChanges?() }
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
        controlsBar.frame = NSRect(x: 0, y: 0, width: bounds.width, height: Self.controlsHeight)
        let top = Self.controlsHeight
        let height = max(0, bounds.height - top)
        tree.isHidden = isTreeHidden
        treeDivider.isHidden = isTreeHidden
        guard !isTreeHidden else {
            viewerContainer.frame = NSRect(x: 0, y: top, width: bounds.width, height: height)
            layoutViewerContent()
            return
        }
        let treeWidth = min(Self.treeWidth, floor(bounds.width * 0.5))
        let viewerWidth = max(0, bounds.width - treeWidth - 1)
        switch treePosition {
        case .left:
            tree.frame = NSRect(x: 0, y: top, width: treeWidth, height: height)
            treeDivider.frame = NSRect(x: treeWidth, y: top, width: 1, height: height)
            viewerContainer.frame = NSRect(x: treeWidth + 1, y: top, width: viewerWidth, height: height)
        case .right:
            viewerContainer.frame = NSRect(x: 0, y: top, width: viewerWidth, height: height)
            treeDivider.frame = NSRect(x: viewerWidth, y: top, width: 1, height: height)
            tree.frame = NSRect(x: viewerWidth + 1, y: top, width: treeWidth, height: height)
        }
        layoutViewerContent()
    }

    private func layoutViewerContent() {
        webHost?.frame = viewerContainer.bounds
    }

    // MARK: - Restore

    /// Puts one session's persisted Files state on screen. Silent — a
    /// restore is not an edit, so nothing here fires the change callbacks.
    func apply(root: URL?, openFile: String?, treePosition rawPosition: String?, showHidden: Bool?) {
        let position = TreePosition(rawValue: rawPosition ?? "") ?? .left
        if position != treePosition {
            treePosition = position
            needsLayout = true
        }
        let hidden = showHidden ?? false
        if rootURL != root || hidden != tree.showsHiddenFiles {
            rootURL = root
            tree.showsHiddenFiles = hidden
            tree.setRoot(root)
        }
        if let openFile, FileManager.default.fileExists(atPath: openFile) {
            self.openFile(URL(fileURLWithPath: openFile), notify: false)
        } else {
            clearOpenFile(notify: false)
        }
        applyLayout()
    }

    // MARK: - Preferences

    func setShowsHiddenFiles(_ flag: Bool) {
        guard tree.showsHiddenFiles != flag else { return }
        tree.showsHiddenFiles = flag
        tree.setRoot(rootURL)
        onPreferencesChanged?()
    }

    func setTreePosition(_ position: TreePosition) {
        guard treePosition != position else { return }
        treePosition = position
        needsLayout = true
        applyLayout()
        onPreferencesChanged?()
    }

    /// Deliberately transient — the row persists position and hidden files,
    /// not this.
    func setTreeHidden(_ hidden: Bool) {
        guard isTreeHidden != hidden else { return }
        isTreeHidden = hidden
        hideTreeButton.setSymbol(
            "sidebar.left",
            label: hidden ? "Show file tree" : "Hide file tree"
        )
        needsLayout = true
        applyLayout()
    }

    private func presentSettingsPopover() {
        let content = ReviewPanelFilesSettingsView(showsHidden: showsHiddenFiles, position: treePosition)
        content.onShowHiddenChanged = { [weak self] flag in self?.setShowsHiddenFiles(flag) }
        content.onPositionChanged = { [weak self] position in self?.setTreePosition(position) }
        let controller = NSViewController()
        controller.view = content
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = controller
        settingsPopover = popover
        popover.show(relativeTo: gearButton.bounds, of: gearButton, preferredEdge: .maxY)
    }

    // MARK: - The embedded Monaco viewer

    /// One file at a time, read-only: the panel is a review surface with no
    /// tab strip and no save pipeline, so an editable buffer here would be a
    /// place to silently lose work. Editing stays in the editor panes.
    private func openFile(_ url: URL, notify: Bool) {
        let path = url.path
        guard currentOpenFilePath != path else { return }
        let host = ensureWebHost()
        if let previous = currentOpenFilePath { host.closeModel(path: previous) }
        fileNameField.stringValue = url.lastPathComponent
        emptyField.isHidden = true
        host.isHidden = false

        let opened: Bool
        if let refusal = refusalMessage(for: url) {
            host.showMessage(refusal)
            opened = false
        } else if let text = readText(url) {
            host.openModel(path: path, content: text, readOnly: true)
            opened = true
        } else {
            host.showMessage("Could not read \(url.lastPathComponent)")
            opened = false
        }
        currentOpenFilePath = opened ? path : nil
        if notify { onOpenFileChanged?(currentOpenFilePath) }
    }

    private func clearOpenFile(notify: Bool) {
        let hadFile = currentOpenFilePath != nil
        if let previous = currentOpenFilePath { webHost?.closeModel(path: previous) }
        currentOpenFilePath = nil
        fileNameField.stringValue = ""
        webHost?.isHidden = true
        emptyField.isHidden = false
        if notify, hadFile { onOpenFileChanged?(nil) }
    }

    private func ensureWebHost() -> EditorWebView {
        if let webHost { return webHost }
        let host = EditorWebView()
        host.autoresizingMask = [.width, .height]
        viewerContainer.addSubview(host)
        host.frame = viewerContainer.bounds
        webHost = host
        return host
    }

    /// `EditorPaneView`'s read rules, minus the bookkeeping a read-only
    /// single-file viewer does not need: text via UTF-8 then latin-1, a
    /// message for what cannot be shown, a hard size ceiling because the
    /// content crosses the bridge as one JS literal on the main thread.
    private func refusalMessage(for url: URL) -> String? {
        let classified = EditorFileClass.classify(url: url)
        guard case .text = classified else {
            return "\(url.lastPathComponent) can't be previewed here"
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int ?? 0
        guard size <= EditorFileClass.maxReadableBytes else {
            let megabytes = EditorFileClass.maxReadableBytes / (1024 * 1024)
            return "\(url.lastPathComponent) is too large to open (over \(megabytes) MB)."
        }
        return nil
    }

    private func readText(_ url: URL) -> String? {
        if let text = try? String(contentsOf: url, encoding: .utf8) { return text }
        // Not valid UTF-8, but the classifier already ruled out binary:
        // latin-1 maps every byte, so this succeeds for real text.
        return try? String(contentsOf: url, encoding: .isoLatin1)
    }
}

// MARK: - Gear popover content

/// The gear popover's two preferences. A plain AppKit form: this is a
/// low-frequency surface, and the popover inherits the system appearance.
final class ReviewPanelFilesSettingsView: NSView {
    let hiddenCheckbox: NSButton
    let positionControl: NSSegmentedControl

    var onShowHiddenChanged: ((Bool) -> Void)?
    var onPositionChanged: ((ReviewPanelFilesView.TreePosition) -> Void)?

    init(showsHidden: Bool, position: ReviewPanelFilesView.TreePosition) {
        hiddenCheckbox = NSButton(checkboxWithTitle: "Show hidden files", target: nil, action: nil)
        positionControl = NSSegmentedControl(
            labels: ["Left", "Right"],
            trackingMode: .selectOne,
            target: nil,
            action: nil
        )
        super.init(frame: .zero)
        hiddenCheckbox.state = showsHidden ? .on : .off
        hiddenCheckbox.target = self
        hiddenCheckbox.action = #selector(hiddenToggled)
        positionControl.selectedSegment = position == .left ? 0 : 1
        positionControl.target = self
        positionControl.action = #selector(positionPicked)

        let positionLabel = NSTextField(labelWithString: "File tree position")
        positionLabel.font = NSFont.systemFont(ofSize: 12)

        let stack = NSStackView(views: [hiddenCheckbox, positionLabel, positionControl])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(12, after: hiddenCheckbox)
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    @objc func hiddenToggled() { onShowHiddenChanged?(hiddenCheckbox.state == .on) }

    @objc func positionPicked() {
        onPositionChanged?(positionControl.selectedSegment == 0 ? .left : .right)
    }
}
