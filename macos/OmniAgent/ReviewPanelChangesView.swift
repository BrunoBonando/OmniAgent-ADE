import AppKit

// The review panel's Changes tab — the 2026-08-20 redesign's §5: the
// workspace's working-tree diff, strictly read-only. The changed-file list is
// one `GitStatus.load` for the session's workspace; a row's hunks are one
// `GitFileContent.unifiedDiff`, rendered through the Monaco bridge with the
// editor's own changes-overview machinery (`showChanges`/`appendFileDiff`),
// so the two surfaces cannot drift into reading git differently. No staging,
// no commit UI, nothing writable: a clean tree shows the centred empty state
// and that is the whole story.

/// The bridge surface the tab draws on. `EditorWebView` already speaks it;
/// tests hand in a spy so the exact payloads can be asserted without booting
/// WebKit.
protocol ReviewPanelDiffRenderer: AnyObject {
    func showChanges(files: [(path: String, badge: String)])
    func appendFileDiff(path: String, text: String)
}

extension EditorWebView: ReviewPanelDiffRenderer {}

/// The tab's whole content: a slim controls bar (change count, refresh), and
/// below it either the embedded Monaco overview or the empty state. Reports
/// row activations up; which editor pane they land in — like everything
/// routed — is `WorkspaceWindowController`'s business, exactly like
/// `ReviewPanelFilesView`'s clicks.
final class ReviewPanelChangesView: NSView {
    static let controlsHeight: CGFloat = 30

    /// A row's "open file" was clicked — routed to the editor flows, never
    /// opened here: the panel is a review surface.
    var onOpenFileRequest: ((URL) -> Void)?
    /// A row was double-clicked: the file's side-by-side diff, in an editor
    /// pane.
    var onOpenDiffRequest: ((URL) -> Void)?

    private(set) var rootURL: URL?
    /// The last loaded status. Kept whole (`WorkspaceFilesTreeView`'s
    /// reasoning): repo-relative path math must go through `GitStatus`.
    private(set) var currentStatus: GitStatus?
    /// Created on the first non-empty status, not in `init`: a WKWebView
    /// costs a WebKit content process, and a clean tree never needs one.
    private(set) var webHost: EditorWebView?

    /// Test seam: stands in for the Monaco host so the list and diff
    /// payloads are assertable. When set, no web view is ever built.
    var rendererForTesting: ReviewPanelDiffRenderer?

    let refreshButton = ReviewPanelIconButton(symbol: "arrow.clockwise", label: "Refresh changes")
    let summaryField = ShellFont.label(
        font: ShellFont.ui(12, .medium),
        color: ShellPalette.inkSecondary
    )

    // The empty state — the spec's centred plus-minus glyph and two lines.
    let emptyStateView = NSStackView()
    let emptyGlyph = NSImageView()
    let emptyTitleField = ShellFont.label(
        "No changes to compare",
        font: ShellFont.ui(13, .medium),
        color: ShellPalette.inkSecondary
    )
    let emptySubtitleField = ShellFont.label(
        "Make changes in this workspace to see them here",
        font: ShellFont.ui(12),
        color: ShellPalette.inkMuted
    )

    private let controlsBar = NSView()
    private let contentContainer = NSView()
    /// Ties an async load's answer to the refresh (and root) that asked for
    /// it, so a stale status can never land over a newer one.
    private var loadGeneration = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = ShellPalette.content.cgColor

        let barHairline = NSView()
        barHairline.wantsLayer = true
        barHairline.layer?.backgroundColor = ShellPalette.hairline.cgColor
        barHairline.translatesAutoresizingMaskIntoConstraints = false

        controlsBar.addSubview(summaryField)
        controlsBar.addSubview(refreshButton)
        controlsBar.addSubview(barHairline)
        NSLayoutConstraint.activate([
            summaryField.leadingAnchor.constraint(equalTo: controlsBar.leadingAnchor, constant: 10),
            summaryField.centerYAnchor.constraint(equalTo: controlsBar.centerYAnchor),
            summaryField.trailingAnchor.constraint(
                lessThanOrEqualTo: refreshButton.leadingAnchor, constant: -8
            ),

            refreshButton.trailingAnchor.constraint(equalTo: controlsBar.trailingAnchor, constant: -8),
            refreshButton.centerYAnchor.constraint(equalTo: controlsBar.centerYAnchor),

            barHairline.leadingAnchor.constraint(equalTo: controlsBar.leadingAnchor),
            barHairline.trailingAnchor.constraint(equalTo: controlsBar.trailingAnchor),
            barHairline.bottomAnchor.constraint(equalTo: controlsBar.bottomAnchor),
            barHairline.heightAnchor.constraint(equalToConstant: 1),
        ])

        emptyGlyph.image = NSImage(
            systemSymbolName: "plus.forwardslash.minus",
            accessibilityDescription: "No changes"
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

        for view in [controlsBar, contentContainer] { addSubview(view) }
        refreshButton.onPress = { [weak self] in self?.refresh() }
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
        contentContainer.frame = NSRect(
            x: 0,
            y: Self.controlsHeight,
            width: bounds.width,
            height: max(0, bounds.height - Self.controlsHeight)
        )
        webHost?.frame = contentContainer.bounds
    }

    // MARK: - Loading

    /// Points the tab at a workspace without loading anything — `refresh`
    /// is the load, and the controller calls the two together on every tab
    /// activation.
    func setRoot(_ url: URL?) {
        guard rootURL != url else { return }
        rootURL = url
        // A stale status must not keep answering path math for the old
        // workspace, and an in-flight load for it must not land here.
        currentStatus = nil
        loadGeneration += 1
    }

    /// One `git status` for the stored root, off the main thread — the tab's
    /// only load, shared by activation and the refresh button. `completion`
    /// is a test seam: it fires when the answer has been applied (or refused
    /// as stale).
    func refresh(_ completion: (() -> Void)? = nil) {
        loadGeneration += 1
        let generation = loadGeneration
        guard let root = rootURL else {
            apply(status: nil)
            completion?()
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let status = GitStatus.repoRoot(for: root).flatMap { GitStatus.load(repoRoot: $0) }
            DispatchQueue.main.async { [weak self] in
                if let self, self.loadGeneration == generation {
                    self.apply(status: status)
                }
                completion?()
            }
        }
    }

    /// Renders one status: the sorted list with the FILES tree's own badge
    /// letters (`GitBadge.letter`, one mapping for every surface), or the
    /// empty state when there is nothing to compare — which a workspace
    /// outside any repository also is, truthfully.
    private func apply(status: GitStatus?) {
        currentStatus = status
        let files = (status?.badges ?? [:])
            .sorted { $0.key < $1.key }
            .map { (path: $0.key, badge: $0.value.letter) }
        guard !files.isEmpty else {
            summaryField.stringValue = status == nil ? "" : "No changes"
            emptyStateView.isHidden = false
            webHost?.isHidden = true
            return
        }
        summaryField.stringValue = files.count == 1
            ? "1 changed file"
            : "\(files.count) changed files"
        emptyStateView.isHidden = true
        if rendererForTesting == nil { ensureWebHost().isHidden = false }
        renderer?.showChanges(files: files)
    }

    // MARK: - The bridge

    private var renderer: ReviewPanelDiffRenderer? { rendererForTesting ?? webHost }

    /// A row opened and asked for its hunks: one `git diff`, and only then —
    /// the editor pane's rule, kept: a thousand-file working tree must not
    /// cost a thousand subprocesses to draw a list nobody has read yet.
    func handleFileDiffRequest(_ relative: String) {
        guard let root = currentStatus?.root else { return }
        let url = root.appendingPathComponent(relative)
        GitFileContent.unifiedDiff(of: url) { [weak self] text in
            self?.renderer?.appendFileDiff(
                path: relative,
                text: EditorPaneView.hunkText(text, for: url)
            )
        }
    }

    /// A row's "open file" click or double-click — routed up, so a file (or
    /// a diff) already open in an editor pane is focused instead of
    /// duplicated: the no-duplicates rule is the workspace's, not this tab's.
    func handleChangesOpen(_ relative: String, asDiff: Bool) {
        guard let root = currentStatus?.root else { return }
        let url = root.appendingPathComponent(relative)
        (asDiff ? onOpenDiffRequest : onOpenFileRequest)?(url)
    }

    private func ensureWebHost() -> EditorWebView {
        if let webHost { return webHost }
        let host = EditorWebView()
        host.autoresizingMask = [.width, .height]
        host.onRequestFileDiff = { [weak self] relative in
            self?.handleFileDiffRequest(relative)
        }
        host.onChangesOpen = { [weak self] relative, asDiff in
            self?.handleChangesOpen(relative, asDiff: asDiff)
        }
        contentContainer.addSubview(host)
        host.frame = contentContainer.bounds
        webHost = host
        return host
    }
}
