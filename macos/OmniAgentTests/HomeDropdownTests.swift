import XCTest
@testable import OmniAgent

/// The Home dropdown's content view, exercised directly — the popover
/// around it is AppKit's, and needs a key window this host never gets.
final class HomeDropdownTests: XCTestCase {
    private func makeView(
        _ sections: [HomeDropdown.Section],
        extra: ((String) -> [HomeDropdown.Row])? = nil
    ) -> HomeDropdownView {
        let view = HomeDropdownView(searchPlaceholder: "Search…") {}
        view.sections = sections
        view.extraRows = extra
        return view
    }

    /// Typing narrows the rows to titles containing the query, case
    /// blind; clearing it brings every row back.
    func testTypingFiltersRowsByTitleAndClearingRestoresThem() {
        let view = makeView([
            HomeDropdown.Section(rows: [
                HomeDropdown.Row(title: "main") {},
                HomeDropdown.Row(title: "codex/native-macos-migration") {},
                HomeDropdown.Row(title: "worktree-real-login") {},
            ]),
        ])
        XCTAssertEqual(view.visibleTitlesForTesting.count, 3)

        view.setQueryForTesting("NATIVE")
        XCTAssertEqual(view.visibleTitlesForTesting, ["codex/native-macos-migration"])

        view.setQueryForTesting("")
        XCTAssertEqual(view.visibleTitlesForTesting.count, 3)
    }

    /// The query-dependent rows (the branch picker's "Create ‘x’ from main")
    /// appear only while something is typed, and rebuild on every change —
    /// so the offered name always matches what is in the field.
    func testExtraRowsFollowTheQueryAndVanishWhenItIsCleared() {
        let view = makeView(
            [HomeDropdown.Section(rows: [HomeDropdown.Row(title: "main") {}])],
            extra: { query in
                query == "main" ? [] : [HomeDropdown.Row(title: "Create “\(query)” from main") {}]
            }
        )
        XCTAssertEqual(view.visibleTitlesForTesting, ["main"])

        view.setQueryForTesting("feature-x")
        XCTAssertEqual(view.visibleTitlesForTesting, ["Create “feature-x” from main"])

        view.setQueryForTesting("feature-xy")
        XCTAssertEqual(view.visibleTitlesForTesting, ["Create “feature-xy” from main"], "one create row, never a stale one beside it")

        // An exact match is a pick, not a creation.
        view.setQueryForTesting("main")
        XCTAssertEqual(view.visibleTitlesForTesting, ["main"])

        view.setQueryForTesting("")
        XCTAssertEqual(view.visibleTitlesForTesting, ["main"])
    }

    /// A pick runs the row's action and then closes the popover — in that
    /// order, so the caller's state is updated before anything tears down.
    func testPressingARowFiresItsActionThenDismisses() {
        var log: [String] = []
        let view = HomeDropdownView(searchPlaceholder: "Search…") { log.append("dismiss") }
        view.sections = [HomeDropdown.Section(rows: [HomeDropdown.Row(title: "opus") { log.append("pick") }])]
        view.setQueryForTesting("op")
        view.pressFirstVisibleForTesting()
        XCTAssertEqual(log, ["pick", "dismiss"])
    }
}
