import XCTest
@testable import OmniAgent

final class CommandPaletteTests: XCTestCase {
    // MARK: - the list

    func testEveryLivePaneIsSwitchableNamedByProjectSessionAndPane() {
        let commands = CommandPaletteModel.build(
            panes: [
                pane("a", project: "alpha", group: "g1", groupLabel: "Build", label: "migrate"),
                pane("b", project: "beta", group: "g2"),
            ],
            paneOrder: ["a", "b"],
            focusedPaneID: "a",
            unreadNotifications: 0
        )

        let switches = commands.filter { if case .focusPane = $0.action { return true } else { return false } }
        XCTAssertEqual(switches.map(\.title), [
            "Switch to alpha — Build — migrate",
            "Switch to beta — Session 1 — shell",
        ])
        XCTAssertEqual(switches.map(\.detail), ["shell", "shell"])
    }

    func testFocusedPaneCommandsAppearOnlyWhenSomethingIsFocused() {
        let unfocused = CommandPaletteModel.build(
            panes: [pane("a", project: "alpha", group: "g1")],
            paneOrder: ["a"],
            focusedPaneID: nil,
            unreadNotifications: 0
        )
        XCTAssertEqual(unfocused.map(\.id), ["focus:a", "new-pane", "new-session", "toggle-sidebar"])

        let focused = CommandPaletteModel.build(
            panes: [pane("a", project: "alpha", group: "g1")],
            paneOrder: ["a"],
            focusedPaneID: "a",
            unreadNotifications: 0
        )
        XCTAssertEqual(
            focused.map(\.id),
            ["focus:a", "new-pane", "new-session", "close-pane", "interrupt", "reattach", "toggle-sidebar"]
        )
        XCTAssertEqual(focused.first { $0.id == "close-pane" }?.action, .closePane(sessionID: "a"))
    }

    func testTheNewSessionRowNamesTheSessionItWouldCreate() {
        let named = CommandPaletteModel.build(
            panes: [pane("a", project: "alpha", group: "g1", groupLabel: "Session 1")],
            paneOrder: ["a"],
            focusedPaneID: nil,
            unreadNotifications: 0,
            nextSessionName: "Session 2"
        ).first { $0.id == "new-session" }
        XCTAssertEqual(named?.title, "New session — Session 2")
        XCTAssertEqual(named?.detail, "⌘N")
        XCTAssertEqual(named?.action, .newSession)

        let unnamed = CommandPaletteModel.build(
            panes: [], paneOrder: [], focusedPaneID: nil, unreadNotifications: 0
        ).first { $0.id == "new-session" }
        XCTAssertEqual(unnamed?.title, "New session", "no name to offer, no dangling dash")
    }

    func testTheClearNotificationsRowExistsOnlyWhenThereIsSomethingToClear() {
        XCTAssertNil(
            CommandPaletteModel.build(panes: [], paneOrder: [], focusedPaneID: nil, unreadNotifications: 0)
                .first { $0.id == "clear-notifications" }
        )
        let row = CommandPaletteModel.build(panes: [], paneOrder: [], focusedPaneID: nil, unreadNotifications: 3)
            .first { $0.id == "clear-notifications" }
        XCTAssertEqual(row?.detail, "3 unread")
        XCTAssertEqual(row?.action, .clearNotifications)
    }

    func testAnEmptyWorkspaceStillOffersTheCommandsThatDoNotNeedAPane() {
        XCTAssertEqual(
            CommandPaletteModel.build(panes: [], paneOrder: [], focusedPaneID: nil, unreadNotifications: 0)
                .map(\.id),
            ["new-pane", "new-session", "toggle-sidebar"]
        )
    }

    // MARK: - filtering and selection

    func testFilteringIsACaseInsensitiveSubstringThatPreservesOrder() {
        var model = CommandPaletteModel(commands: sample)

        model.update(query: "PANE")

        XCTAssertEqual(model.matches.map(\.id), ["focus:a", "new-pane", "close-pane"])
    }

    func testAnEmptyOrWhitespaceQueryShowsEverything() {
        var model = CommandPaletteModel(commands: sample)
        model.update(query: "   ")
        XCTAssertEqual(model.matches.count, sample.count)
    }

    func testTypingReturnsTheHighlightToTheTop() {
        var model = CommandPaletteModel(commands: sample)
        model.moveSelection(by: 2)
        XCTAssertEqual(model.selectedIndex, 2)

        model.update(query: "new")

        XCTAssertEqual(model.selectedIndex, 0)
        XCTAssertEqual(model.selected?.id, "new-pane")
    }

    func testSelectionClampsRatherThanWrapping() {
        var model = CommandPaletteModel(commands: sample)

        model.moveSelection(by: -1)
        XCTAssertEqual(model.selectedIndex, 0, "up at the top stays at the top")

        model.moveSelection(by: 99)
        XCTAssertEqual(model.selectedIndex, sample.count - 1, "down at the bottom stays at the bottom")
    }

    func testAQueryThatMatchesNothingSelectsNothingRatherThanTheWrongRow() {
        var model = CommandPaletteModel(commands: sample)
        model.update(query: "zzzz")

        XCTAssertTrue(model.matches.isEmpty)
        XCTAssertNil(model.selected)
        model.moveSelection(by: 1)
        XCTAssertNil(model.selected)
    }

    func testResetClearsTheQueryAndTheHighlightAlongWithTheList() {
        var model = CommandPaletteModel(commands: sample)
        model.update(query: "new")
        model.moveSelection(by: 1)

        model.reset(commands: [sample[0]])

        XCTAssertEqual(model.query, "")
        XCTAssertEqual(model.selectedIndex, 0)
        XCTAssertEqual(model.matches.map(\.id), ["focus:a"])
    }

    // MARK: - the panel

    func testThePanelRunsTheHighlightedRowAndClosesFirst() {
        let controller = CommandPaletteController()
        var ran: [PaletteAction] = []
        var openWhenRun: [Bool] = []
        controller.onRun = { action in
            ran.append(action)
            openWhenRun.append(controller.window?.isVisible == true)
        }
        controller.present(commands: sample, over: nil)

        controller.runSelected()

        XCTAssertEqual(ran, [.focusPane(sessionID: "a")])
        XCTAssertEqual(openWhenRun, [false], "the action lands with focus already back in the workspace")
    }

    func testThePanelIsRebuiltFromScratchOnEveryOpen() {
        let controller = CommandPaletteController()
        controller.present(commands: sample, over: nil)
        controller.moveSelection(by: 2)
        XCTAssertEqual(controller.model.selectedIndex, 2)

        controller.present(commands: [sample[1]], over: nil)

        XCTAssertEqual(controller.model.matches.map(\.id), ["new-pane"])
        XCTAssertEqual(controller.model.selectedIndex, 0)
        controller.dismiss()
    }

    // MARK: - fixtures

    private let sample: [PaletteCommand] = [
        PaletteCommand(id: "focus:a", title: "Switch to alpha — Session 1 — pane", detail: "shell", action: .focusPane(sessionID: "a")),
        PaletteCommand(id: "new-pane", title: "New terminal pane", detail: "⌘T", action: .newPane),
        PaletteCommand(id: "close-pane", title: "Close pane shell", detail: "⌘W", action: .closePane(sessionID: "a")),
        PaletteCommand(id: "toggle-sidebar", title: "Toggle sidebar", detail: "⌃⌘S", action: .toggleSidebar),
    ]

    private func pane(
        _ id: String,
        project: String,
        group: String,
        groupLabel: String? = nil,
        label: String? = nil
    ) -> PaneDescriptor {
        PaneDescriptor(
            sessionID: id,
            group: group,
            groupLabel: groupLabel,
            project: project,
            engine: .shell,
            cwd: "/",
            label: label
        )
    }
}
