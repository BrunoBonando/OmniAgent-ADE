import AppKit
import XCTest

@testable import OmniAgent

/// The shell's shared building blocks: the sessions tree the sidebar mounts,
/// its rows and badges, and the files tree (headed for the review panel). The
/// flat sidebar column itself is `NavigationSidebarTests`' subject.
final class WorkspaceShellTests: XCTestCase {
    override func setUp() {
        super.setUp()
        // A collapsed workspace left behind by an earlier run would fold the
        // rows these tests assert on.
        UserDefaults.standard.removeObject(forKey: WorkspacesTreeView.collapsedDefaultsKey)
    }

    private func makeSidebar() -> NavigationSidebarView {
        let sidebar = NavigationSidebarView()
        sidebar.frame = NSRect(x: 0, y: 0, width: ShellMetrics.sidebarWidth, height: 700)
        sidebar.layoutSubtreeIfNeeded()
        return sidebar
    }

    private func pane(
        _ id: String,
        group: String,
        project: String = "p1",
        engine: Engine = .claude,
        title: String = "term"
    ) -> PaneDescriptor {
        PaneDescriptor(
            sessionID: id,
            group: group,
            groupLabel: group,
            title: title,
            project: project,
            engine: engine,
            cwd: "/tmp"
        )
    }

    // MARK: - Destinations

    func testHomeIsTheDefaultDestination() {
        XCTAssertEqual(makeSidebar().destination, .home)
    }

    /// The workspaces tree stays on screen for every destination — the sidebar
    /// always shows at least the workspace list.
    func testTheWorkspacesTreeStaysVisibleAcrossDestinations() {
        let sidebar = makeSidebar()
        for destination in WorkspaceDestination.allCases {
            sidebar.applyDestination(destination)
            XCTAssertFalse(sidebar.workspacesTree.isHiddenOrHasHiddenAncestor)
        }
    }

    /// The 2026-08-20 redesign's three destinations, and no more: Home, To Do
    /// List and the Desk. Dashboard, Board and the `.files` dead end are gone,
    /// and the palette's rows are built straight off `allCases`.
    func testTheDestinationsAreTheRedesigns() {
        XCTAssertEqual(
            WorkspaceDestination.allCases.map(\.rawValue),
            ["home", "todo", "terminals", "settings"]
        )
    }

    /// A page's scroll view fades its top edge over the asked-for points,
    /// whatever height it is laid out at — a sidebar region's does not.
    func testAPageScrollViewFadesItsTopEdge() {
        let page = ShellScrollView(documentView: NSView(), topFade: 28)
        page.frame = NSRect(x: 0, y: 0, width: 300, height: 700)
        page.layoutSubtreeIfNeeded()
        XCTAssertEqual(page.topFadeForTesting, 28, accuracy: 0.01)
        page.frame = NSRect(x: 0, y: 0, width: 300, height: 350)
        page.layoutSubtreeIfNeeded()
        XCTAssertEqual(page.topFadeForTesting, 28, accuracy: 0.01)
        XCTAssertEqual(ShellScrollView(documentView: NSView()).topFadeForTesting, 0)
    }

    /// Paths read the way the design writes them — `~` for home, an em dash
    /// for nothing (the hover card leans on this).
    func testShellPathAbbreviatesTheHomeDirectory() {
        let home = NSHomeDirectory()
        XCTAssertEqual(ShellPath.abbreviate("\(home)/Code/api"), "~/Code/api")
        XCTAssertEqual(ShellPath.abbreviate(nil), "—")
    }

    // MARK: - Workspace identity

    /// The tile colour has to survive a relaunch without being persisted, so
    /// the hash must be stable and in range.
    func testTheAvatarGradientIsStableAndInRange() {
        let first = ShellPalette.avatarGradient(forID: "omniagent-ade")
        let second = ShellPalette.avatarGradient(forID: "omniagent-ade")
        XCTAssertEqual(first.0, second.0)
        XCTAssertEqual(first.1, second.1)
        XCTAssertTrue(ShellPalette.avatarGradients.contains { $0.0 == first.0 && $0.1 == first.1 })
    }

    /// A long id used to overflow-trap before the hash was made wrapping.
    func testTheAvatarGradientSurvivesALongID() {
        let long = String(repeating: "workspace-", count: 64)
        XCTAssertTrue(
            ShellPalette.avatarGradients.contains {
                let picked = ShellPalette.avatarGradient(forID: long)
                return $0.0 == picked.0 && $0.1 == picked.1
            }
        )
    }

    func testInitialsTakeTwoWordsThenTwoLetters() {
        XCTAssertEqual(ShellPalette.initials("OmniAgent ADE"), "OA")
        XCTAssertEqual(ShellPalette.initials("voice"), "VO")
        XCTAssertEqual(ShellPalette.initials("bruno-studio"), "BS")
    }

    func testSessionCountLabelReadsAsProse() {
        XCTAssertEqual(ShellPalette.sessionCountLabel(0), "no sessions")
        XCTAssertEqual(ShellPalette.sessionCountLabel(1), "1 session")
        XCTAssertEqual(ShellPalette.sessionCountLabel(4), "4 sessions")
    }

    // MARK: - Workspaces tree

    /// The 2026-08-20 redesign: the tree lists EVERY workspace with its
    /// sessions inline underneath — never scoped to the open one.
    func testTheTreeListsEveryWorkspaceWithItsSessionsInline() {
        let sidebar = makeSidebar()
        sidebar.reloadWorkspaces(
            workspaces: [
                BrainProjectSummary(id: "p1", label: "Alpha", path: nil),
                BrainProjectSummary(id: "p2", label: "Beta", path: nil),
            ],
            panes: [pane("a", group: "s1", project: "p1"), pane("b", group: "s2", project: "p2")],
            focusedPaneID: "a",
            statuses: [:],
            projectLabels: [:]
        )
        let tree = sidebar.workspacesTree
        XCTAssertEqual(tree.renderedWorkspaceIDs, ["p1", "p2"])
        XCTAssertEqual(tree.renderedSessionIDs, ["s1", "s2"])
        XCTAssertEqual(
            tree.descendants(WorkspaceRowView.self).map(\.workspaceID),
            ["p1", "p2"]
        )
    }

    /// A folder opened directly — panes carrying a project the brain has not
    /// listed — still gets its workspace row.
    func testAPaneOnlyWorkspaceStillGetsARow() {
        let sidebar = makeSidebar()
        sidebar.reloadWorkspaces(
            workspaces: [BrainProjectSummary(id: "p1", label: "Alpha", path: nil)],
            panes: [pane("a", group: "s9", project: "p9")],
            focusedPaneID: nil,
            statuses: [:],
            projectLabels: [:]
        )
        XCTAssertEqual(sidebar.workspacesTree.renderedWorkspaceIDs, ["p1", "p9"])
    }

    /// Sessions are the tree's leaves now: pane rows are gone from the
    /// sidebar entirely, as are the per-session add-pane rows. ⌘T / ⇧⌘T /
    /// ⇧⌘E, the hole tile and the palette add panes.
    func testTheTreeDrawsSessionsAsLeavesNeverPaneRows() {
        let sidebar = makeSidebar()
        sidebar.reloadWorkspaces(
            workspaces: [],
            panes: (1..<PaneGrid.maxPanes).map { pane("t\($0)", group: "s1") },
            focusedPaneID: "t1",
            statuses: [:],
            projectLabels: [:]
        )
        let rows = sidebar.workspacesTree.descendants(ShellRowView.self)
        XCTAssertEqual(rows.filter { $0 is SessionRowView }.count, 1, "many panes, one session row")
        XCTAssertTrue(
            rows.allSatisfy { $0 is SessionRowView || $0 is WorkspaceRowView },
            "workspace and session rows are the whole tree"
        )
    }

    /// A workspace with nothing running says so, dimly, instead of showing a
    /// bare header.
    func testAWorkspaceWithNoSessionsShowsADimEmptyRow() throws {
        let sidebar = makeSidebar()
        sidebar.reloadWorkspaces(
            workspaces: [BrainProjectSummary(id: "p1", label: "Alpha", path: nil)],
            panes: [],
            focusedPaneID: nil,
            statuses: [:],
            projectLabels: [:]
        )
        let empty = try XCTUnwrap(sidebar.workspacesTree.descendant(WorkspaceEmptyRowView.self))
        XCTAssertEqual(empty.title, "No sessions yet")
    }

    /// The disclosure fold survives a rebuild *and* a relaunch — the tree is
    /// thrown away and re-made on every status event, so an unpersisted fold
    /// would pop back open within seconds.
    func testCollapsingAWorkspacePersistsAcrossTreeRebuilds() throws {
        let suite = "workspaces-tree-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let tree = WorkspacesTreeView(defaults: defaults)
        tree.frame = NSRect(x: 0, y: 0, width: ShellMetrics.sidebarWidth, height: 500)
        let entries = [WorkspaceTreeEntry(id: "p1", label: "Alpha", sessions: [sessionNode(label: "s")])]
        tree.reload(entries: entries, focusedPaneID: nil, statuses: [:])
        XCTAssertEqual(tree.renderedSessionIDs, ["s1"])
        let row = try XCTUnwrap(tree.descendant(WorkspaceRowView.self))
        XCTAssertTrue(row.isExpanded)

        row.onPress?()

        XCTAssertEqual(tree.renderedSessionIDs, [], "collapsed: the sessions leave the tree")
        XCTAssertFalse(try XCTUnwrap(tree.descendant(WorkspaceRowView.self)).isExpanded)

        // A fresh tree over the same defaults — a relaunch — keeps the fold.
        let rebuilt = WorkspacesTreeView(defaults: defaults)
        rebuilt.reload(entries: entries, focusedPaneID: nil, statuses: [:])
        XCTAssertEqual(rebuilt.renderedSessionIDs, [])
    }

    /// The folder icon tells the fold state at a glance: open while expanded.
    func testTheFolderIconShowsTheOpenVariantWhileExpanded() {
        XCTAssertEqual(WorkspaceRowView(id: "p1", label: "A", expanded: true).folderGlyph.glyph, .folderOpen)
        XCTAssertEqual(WorkspaceRowView(id: "p1", label: "A", expanded: false).folderGlyph.glyph, .folder)
    }

    /// The session row aggregates its blocked terminals minus the focused one
    /// — selected counts as seen, and with pane rows gone the session row is
    /// the only place the count can live.
    func testASessionRowCountsItsUnseenAsks() throws {
        let sidebar = makeSidebar()
        let panes = (1...3).map { pane("t\($0)", group: "s1") }
        let statuses: [String: RemoteSessionStatus] = [
            "t1": .awaitingApproval, "t2": .awaitingApproval, "t3": .awaitingApproval,
        ]
        sidebar.reloadWorkspaces(
            workspaces: [], panes: panes, focusedPaneID: "t1", statuses: statuses, projectLabels: [:]
        )
        let row = try XCTUnwrap(sidebar.workspacesTree.descendant(SessionRowView.self))
        XCTAssertEqual(row.awaitingBadge?.count, 2, "three asks, one focused")
    }

    func testTheSessionRowShowsTheWaitingCountOnlyWhileSomethingWaits() {
        let row = SessionRowView(
            session: sessionNode(label: "s"),
            statuses: [.awaitingApproval],
            awaitingCount: 2
        )
        XCTAssertEqual(row.awaitingBadge?.count, 2)
        let quiet = SessionRowView(
            session: sessionNode(label: "s"),
            statuses: [.ready],
            awaitingCount: 0
        )
        XCTAssertNil(quiet.awaitingBadge)
    }

    /// The badge's width is a literal computed from its digit count, not
    /// Auto Layout measuring `label.widthAnchor` — see `ShellAwaitingBadgeView`
    /// (2026-08-24). This locks in the two sizes the design covers and
    /// guards against the width absorbing slack from elsewhere in the row.
    func testTheAwaitingBadgeStaysTightRegardlessOfRowWidth() {
        let row = SessionRowView(
            session: sessionNode(label: "Main One"),
            statuses: [.ready, .ready, .awaitingApproval],
            awaitingCount: 1
        )
        row.frame = NSRect(x: 0, y: 0, width: 600, height: 32)
        row.layoutSubtreeIfNeeded()
        XCTAssertEqual(row.awaitingBadge?.frame.width, 17)

        let doubleDigit = SessionRowView(
            session: sessionNode(label: "Main Two"),
            statuses: [.ready],
            awaitingCount: 12
        )
        doubleDigit.frame = NSRect(x: 0, y: 0, width: 600, height: 32)
        doubleDigit.layoutSubtreeIfNeeded()
        XCTAssertEqual(doubleDigit.awaitingBadge?.frame.width, 24)
    }

    func testStatusDotColoursFollowTheDesign() {
        XCTAssertEqual(ShellDotsView.color(for: .thinking), ShellPalette.blue)
        // Running a tool is the agent *working*, not the agent needing you:
        // it reads blue with the rest of the working family, so amber means
        // exactly one thing anywhere it appears — waiting on your input.
        XCTAssertEqual(ShellDotsView.color(for: .toolExecution), ShellPalette.blue)
        XCTAssertEqual(ShellDotsView.color(for: .awaitingApproval), ShellPalette.amber)
        XCTAssertEqual(ShellDotsView.color(for: .ready), ShellPalette.green)
        XCTAssertEqual(ShellDotsView.color(for: .error), ShellPalette.red)
        XCTAssertEqual(ShellDotsView.color(for: nil), ShellPalette.idle)
    }

    /// Only a working agent breathes; a finished one would be noise. Running a
    /// tool is working, so its dot breathes with thinking's.
    func testOnlyTheWorkingStatusesPulse() {
        XCTAssertTrue(ShellDotsView.pulses(.thinking))
        XCTAssertTrue(ShellDotsView.pulses(.toolExecution))
        XCTAssertFalse(ShellDotsView.pulses(.ready))
        XCTAssertFalse(ShellDotsView.pulses(nil))
    }

    // MARK: - Rename

    /// Renaming used to live on `SessionOutlineView`; it has to keep working
    /// now that the design's own rows replaced it.
    func testCommittingARenameReportsTheNewName() {
        let row = SessionRowView(
            session: sessionNode(label: "old"),
            statuses: []
        )
        var reported: String?
        row.onRename = { reported = $0 }
        row.beginRenaming()
        row.renameField.stringValue = "new name"
        row.commitRenameForTesting()
        XCTAssertEqual(reported, "new name")
    }

    /// An empty name is a cancel, not a request to erase the label.
    func testAnEmptyRenameIsIgnored() {
        let row = SessionRowView(
            session: sessionNode(label: "old"),
            statuses: []
        )
        var reported: String?
        row.onRename = { reported = $0 }
        row.beginRenaming()
        row.renameField.stringValue = "   "
        row.commitRenameForTesting()
        XCTAssertNil(reported)
    }

    private func sessionNode(label: String) -> SessionGroupNode {
        SessionGroupNode(
            id: "s1",
            project: "p1",
            name: label,
            label: label,
            cwd: "/tmp",
            paneIDs: ["t1"],
            isCurrent: true
        )
    }

    // MARK: - Where a terminal starts

    /// A pane already inside the workspace keeps exactly where it is.
    func testAPaneInsideTheWorkspaceKeepsItsDirectory() {
        XCTAssertTrue(WorkspaceWindowController.isInside("/w/api/macos", "/w/api"))
        XCTAssertTrue(WorkspaceWindowController.isInside("/w/api", "/w/api"))
        XCTAssertTrue(WorkspaceWindowController.isInside("/w/api/", "/w/api"))
    }

    /// A stale home directory from an older layout is not "in the workspace",
    /// and neither is a sibling folder with a shared prefix.
    func testAStaleOrSiblingDirectoryIsNotInsideTheWorkspace() {
        XCTAssertFalse(WorkspaceWindowController.isInside("/Users/me", "/w/api"))
        XCTAssertFalse(WorkspaceWindowController.isInside("/w/api-old", "/w/api"))
        XCTAssertFalse(WorkspaceWindowController.isInside("", "/w/api"))
    }

    // MARK: - Files tree rows

    func testFileBadgesMatchTheDesignsLetters() {
        XCTAssertEqual(WorkspaceFileRowView.badgeText(file(badge: .modified)), "M")
        XCTAssertEqual(WorkspaceFileRowView.badgeText(file(badge: .added)), "A")
        XCTAssertEqual(WorkspaceFileRowView.badgeText(file(badge: .deleted)), "D")
        XCTAssertEqual(WorkspaceFileRowView.badgeText(file(badge: nil)), "")
    }

    /// A directory prints how many changed files are under it, and prints
    /// nothing at all when the answer is zero.
    func testDirectoryBadgeCountsChangesBeneathIt() {
        var directory = WorkspaceFileNode(
            name: "src",
            url: URL(fileURLWithPath: "/tmp/src"),
            isDirectory: true
        )
        directory.changedCount = 3
        XCTAssertEqual(WorkspaceFileRowView.badgeText(directory), "3")
        directory.changedCount = 0
        XCTAssertEqual(WorkspaceFileRowView.badgeText(directory), "")
    }

    // MARK: - Opening files (Task 11)

    /// VS Code's rule, from the tree's side: one click previews, a second
    /// click on the same row within the system double-click interval pins.
    func testSingleClickPreviewsAndDoubleClickPins() throws {
        let tree = WorkspaceFilesTreeView(frame: NSRect(x: 0, y: 0, width: 280, height: 400))
        var opened: [(URL, Bool)] = []
        tree.onOpenFile = { url, pinned in opened.append((url, pinned)) }
        let directory = try makeTempDirectory(containing: "a.swift")
        tree.setRoot(directory)

        try pressFileRow(named: "a.swift", in: tree)
        try pressFileRow(named: "a.swift", in: tree)

        XCTAssertEqual(opened.map(\.0.lastPathComponent), ["a.swift", "a.swift"])
        XCTAssertEqual(opened.map(\.1), [false, true], "preview, then pinned")
    }

    /// A click on a *different* row is a fresh single click, never the second
    /// half of a double — otherwise walking a list with the mouse would pin
    /// every other file.
    func testClickingADifferentRowIsAlwaysASingleClick() throws {
        let tree = WorkspaceFilesTreeView(frame: NSRect(x: 0, y: 0, width: 280, height: 400))
        var opened: [(URL, Bool)] = []
        tree.onOpenFile = { url, pinned in opened.append((url, pinned)) }
        let directory = try makeTempDirectory(containing: "a.swift", "b.swift")
        tree.setRoot(directory)

        try pressFileRow(named: "a.swift", in: tree)
        try pressFileRow(named: "b.swift", in: tree)

        XCTAssertEqual(opened.map(\.0.lastPathComponent), ["a.swift", "b.swift"])
        XCTAssertEqual(opened.map(\.1), [false, false])
    }

    // MARK: - Opening diffs (Task 12)

    /// The git badge is its own hit target: clicking the "M" asks for the
    /// diff, clicking anywhere else in the row still opens the file.
    func testTheGitBadgeIsItsOwnClickTarget() throws {
        let row = WorkspaceFileRowView(node: file(badge: .modified), depth: 0, expanded: false, selected: false)
        var presses = 0
        var badgePresses = 0
        row.onPress = { presses += 1 }
        row.onBadgePress = { badgePresses += 1 }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 60),
            styleMask: [.borderless],
            backing: .buffered,
            defer: true
        )
        window.contentView?.addSubview(row)
        row.frame = NSRect(x: 0, y: 0, width: 280, height: ShellMetrics.fileRowHeight)
        row.layoutSubtreeIfNeeded()
        let badge = try XCTUnwrap(row.descendants(NSTextField.self).first { $0.stringValue == "M" })

        click(row, at: NSPoint(x: badge.frame.midX, y: badge.frame.midY), in: window)

        XCTAssertEqual(badgePresses, 1, "the badge answered")
        XCTAssertEqual(presses, 0, "and the row did not")

        click(row, at: NSPoint(x: 40, y: row.bounds.midY), in: window)

        XCTAssertEqual(presses, 1, "the rest of the row still opens the file")
        XCTAssertEqual(badgePresses, 1)
    }

    /// Only a *changed* file has a badge to click, so only a changed file
    /// carries the callback — an unbadged row must keep its whole width as
    /// "open this file".
    func testOnlyChangedFileRowsCarryABadgePress() throws {
        let tree = WorkspaceFilesTreeView(frame: NSRect(x: 0, y: 0, width: 280, height: 400))
        var diffed: [URL] = []
        tree.onOpenDiff = { diffed.append($0) }
        let directory = try makeTempGitRepository(changed: "a.swift", clean: "b.swift")
        tree.setRoot(directory)

        let changed = try awaitFileRow(named: "a.swift", in: tree) { $0.node.gitBadge != nil }
        let clean = try awaitFileRow(named: "b.swift", in: tree) { _ in true }
        XCTAssertNil(clean.onBadgePress, "a clean row has no badge and no diff to offer")
        try XCTUnwrap(changed.onBadgePress)()

        XCTAssertEqual(diffed.map(\.lastPathComponent), ["a.swift"])
    }

    /// Task 13: the header's +N −M counts are the button for the repo-wide
    /// overview.
    func testTheDiffHeaderOpensAllChangesOnlyInsideARepository() throws {
        let tree = WorkspaceFilesTreeView(frame: NSRect(x: 0, y: 0, width: 280, height: 400))
        var opened = 0
        tree.onOpenAllChanges = { opened += 1 }

        let recognizers = tree.descendants(NSTextField.self).flatMap(\.gestureRecognizers)
        XCTAssertEqual(recognizers.count, 1, "exactly one header label is clickable")
        let recognizer = try XCTUnwrap(recognizers.first)
        XCTAssertFalse(
            recognizer.isEnabled,
            "with no repository the counts are inert — absent, not a click that lands on a message"
        )

        tree.setRoot(try makeTempGitRepository(changed: "a.swift", clean: "b.swift"))
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline, !recognizer.isEnabled {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertTrue(recognizer.isEnabled, "once a status lands the counts are the button")
        NSApp.sendAction(try XCTUnwrap(recognizer.action), to: recognizer.target, from: recognizer)

        XCTAssertEqual(opened, 1)
    }

    /// The pane surfaces need the same `git status` the tree drew its badges
    /// from, so the tree reports every load — including the `nil` that means
    /// "no workspace, no repository".
    func testTheTreeReportsItsGitStatus() throws {
        let tree = WorkspaceFilesTreeView(frame: NSRect(x: 0, y: 0, width: 280, height: 400))
        var reported: [GitStatus?] = []
        tree.onStatusChanged = { reported.append($0) }
        let directory = try makeTempGitRepository(changed: "a.swift", clean: "b.swift")

        tree.setRoot(directory)

        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline, reported.compactMap({ $0 }).isEmpty {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertNil(reported.first ?? nil, "the reset lands first, so a stale status never lingers")
        let status = try XCTUnwrap(reported.compactMap { $0 }.first)
        XCTAssertEqual(status.badges["a.swift"], .untracked)
    }

    /// A real click, at a point in the row rather than through its closure.
    private func click(_ view: NSView, at point: NSPoint, in window: NSWindow) {
        let inWindow = view.convert(point, to: nil)
        func event(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.mouseEvent(
                with: type,
                location: inWindow,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            )
        }
        guard let down = event(.leftMouseDown), let up = event(.leftMouseUp) else {
            return XCTFail("could not synthesize a click")
        }
        view.mouseDown(with: down)
        view.mouseUp(with: up)
    }

    /// A throwaway repository, so the badges under test come from real `git`
    /// rather than this repo's own working tree (which other sessions move).
    private func makeTempGitRepository(changed: String, clean: String) throws -> URL {
        let directory = try makeTempDirectory()
        func git(_ arguments: String...) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["git", "-C", directory.path] + arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { throw XCTSkip("git is not available on PATH") }
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw XCTSkip("git is not usable here") }
        }
        try git("init", "-q")
        try git("config", "user.email", "t@t")
        try git("config", "user.name", "t")
        try "x".write(to: directory.appendingPathComponent(clean), atomically: true, encoding: .utf8)
        try git("add", ".")
        try git("commit", "-qm", "initial")
        try "x".write(to: directory.appendingPathComponent(changed), atomically: true, encoding: .utf8)
        return directory
    }

    /// The tree loads its listing *and* its `git status` off the main thread,
    /// so a row worth asserting on may not exist yet.
    private func awaitFileRow(
        named name: String,
        in tree: WorkspaceFilesTreeView,
        until predicate: (WorkspaceFileRowView) -> Bool
    ) throws -> WorkspaceFileRowView {
        let deadline = Date().addingTimeInterval(20)
        repeat {
            if let row = tree.descendants(WorkspaceFileRowView.self).first(where: { $0.node.name == name }),
               predicate(row) {
                return row
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        } while Date() < deadline
        throw XCTSkip("the FILES row for \(name) never arrived")
    }

    /// Presses the row for `name`, re-finding it each time: activating a row
    /// re-renders the tree, so the previous row object is already detached.
    private func pressFileRow(named name: String, in tree: WorkspaceFilesTreeView) throws {
        let deadline = Date().addingTimeInterval(10)
        var row: WorkspaceFileRowView?
        repeat {
            row = tree.descendants(WorkspaceFileRowView.self).first { $0.node.name == name }
            if row != nil { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        } while Date() < deadline
        try XCTUnwrap(XCTUnwrap(row).onPress)()
    }

    private func makeTempDirectory(containing names: String...) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("files-tree-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        for name in names {
            try "x".write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        return directory
    }

    private func file(badge: GitBadge?) -> WorkspaceFileNode {
        var node = WorkspaceFileNode(
            name: "token.service.ts",
            url: URL(fileURLWithPath: "/tmp/token.service.ts"),
            isDirectory: false
        )
        node.gitBadge = badge
        return node
    }
}

private extension NSView {
    /// Depth-first search for the tree tests — the rows live in a private
    /// stack, and walking the view tree is how a test sees what a user sees.
    func descendant<View: NSView>(_ type: View.Type) -> View? {
        for subview in subviews {
            if let match = subview as? View { return match }
            if let match = subview.descendant(type) { return match }
        }
        return nil
    }

    /// Every match, in tree order — the rows are siblings, so `descendant`'s
    /// first hit is not enough to pick one out by name.
    func descendants<View: NSView>(_ type: View.Type) -> [View] {
        var found: [View] = []
        for subview in subviews {
            if let match = subview as? View { found.append(match) }
            found += subview.descendants(type)
        }
        return found
    }
}
