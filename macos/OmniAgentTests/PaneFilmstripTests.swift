import XCTest
@testable import OmniAgent

/// The overflow layout's geometry, on its own: the hero column, the rail that
/// holds a card for *every* pane, and the scroll the rail exists to provide.
final class PaneFilmstripTests: XCTestCase {
    private let bounds = CGRect(x: 10, y: 20, width: 1200, height: 800)
    /// Short enough that a rail of eight cards cannot fit in it.
    private let shortBounds = CGRect(x: 10, y: 20, width: 1200, height: 300)

    private func layout(
        _ ids: [String],
        selected: String,
        heroCount: Int = 1,
        scroll: CGFloat = 0,
        in rect: CGRect? = nil
    ) -> PaneFilmstrip.Layout {
        PaneFilmstrip.layout(
            ids: ids,
            selected: selected,
            heroCount: heroCount,
            in: rect ?? bounds,
            railWidth: 196,
            itemHeight: 62,
            gap: 6,
            scroll: scroll
        )
    }

    private var ids: [String] { (1...8).map { "pane-\($0)" } }

    func testTheHeroTakesEverythingTheRailDoesNot() {
        let result = layout(ids, selected: "pane-3")
        XCTAssertEqual(result.heroIDs, ["pane-3"])
        XCTAssertEqual(
            result.hero.first?.frame,
            CGRect(x: 10 + 196 + 6, y: 20, width: 1200 - 202, height: 800)
        )
        XCTAssertEqual(result.railBounds, CGRect(x: 10, y: 20, width: 196, height: 800))
    }

    /// Every pane has a card, the one on screen included — it is marked, not
    /// removed, so the strip never shuffles under the pointer.
    func testTheRailHoldsEveryPaneInPaneOrderAtAFixedHeight() {
        let result = layout(ids, selected: "pane-3")
        XCTAssertEqual(result.rail.map(\.id), ids)
        XCTAssertEqual(result.rail.first?.frame.minY, bounds.minY)
        for item in result.rail {
            XCTAssertEqual(item.frame.width, 196)
            XCTAssertEqual(item.frame.height, 62, "fixed, whatever the window is doing")
            XCTAssertEqual(item.frame.minX, bounds.minX)
        }
        for (above, below) in zip(result.rail, result.rail.dropFirst()) {
            XCTAssertEqual(below.frame.minY - above.frame.maxY, 6, accuracy: 0.001)
        }
        // The rail's cards do not grow when the window does.
        let taller = layout(ids, selected: "pane-3", in: bounds.insetBy(dx: 0, dy: -400))
        XCTAssertEqual(taller.rail.first?.frame.height, 62)
    }

    /// Room for more than one at a usable height means more than one, and they
    /// tile the hero column exactly.
    func testATallHeroColumnShowsSeveralPanes() {
        let result = layout(ids, selected: "pane-2", heroCount: 3)
        XCTAssertEqual(result.heroIDs, ["pane-2", "pane-3", "pane-4"])
        let frames = result.hero.map(\.frame)
        XCTAssertEqual(frames.first?.minY, bounds.minY)
        XCTAssertEqual(frames.last?.maxY, bounds.maxY, "the last row is pinned to the floor")
        for (above, below) in zip(frames, frames.dropFirst()) {
            XCTAssertEqual(below.minY - above.maxY, 6, accuracy: 1)
            XCTAssertEqual(below.height, above.height, accuracy: 1, "equal rows")
            XCTAssertEqual(below.minX, above.minX)
        }
    }

    /// Selecting near the end shows the last `heroCount` rather than a short
    /// column: what was asked for is always on screen, and so is a full column.
    func testTheHeroWindowShiftsBackAtTheEndOfTheList() {
        let result = layout(ids, selected: "pane-8", heroCount: 3)
        XCTAssertEqual(result.heroIDs, ["pane-6", "pane-7", "pane-8"])
        XCTAssertEqual(layout(ids, selected: "pane-1", heroCount: 3).heroIDs.first, "pane-1")
    }

    func testAskingForMoreRowsThanThereArePanesShowsThePanesThereAre() {
        let result = layout(["pane-1", "pane-2"], selected: "pane-1", heroCount: 5)
        XCTAssertEqual(result.heroIDs, ["pane-1", "pane-2"])
        XCTAssertEqual(result.hero.last?.frame.maxY, bounds.maxY)
    }

    func testTheRailScrollsAndClampsAtBothEnds() {
        let result = layout(ids, selected: "pane-3", in: shortBounds)
        XCTAssertGreaterThan(result.maxScroll, 0, "eight cards do not fit in 300pt")

        let scrolled = layout(ids, selected: "pane-3", scroll: 120, in: shortBounds)
        XCTAssertEqual(scrolled.scroll, 120)
        XCTAssertEqual(
            scrolled.rail.first?.frame.minY,
            (result.rail.first?.frame.minY ?? 0) - 120,
            "the whole rail moves by the offset"
        )

        XCTAssertEqual(
            layout(ids, selected: "pane-3", scroll: -50, in: shortBounds).scroll,
            0,
            "no scrolling past the top"
        )
        let end = layout(ids, selected: "pane-3", scroll: 9_999, in: shortBounds)
        XCTAssertEqual(end.scroll, result.maxScroll, "nor past the last card")
        XCTAssertEqual(
            end.rail.last?.frame.maxY ?? 0,
            shortBounds.maxY,
            accuracy: 0.001,
            "scrolled to the end, the last card sits on the rail's floor"
        )
    }

    func testAShortRailDoesNotScroll() {
        let result = layout(["pane-1", "pane-2"], selected: "pane-1")
        XCTAssertEqual(result.rail.count, 2)
        XCTAssertEqual(result.maxScroll, 0)
        XCTAssertEqual(layout(["pane-1", "pane-2"], selected: "pane-1", scroll: 400).scroll, 0)
    }

    /// What a focus command that walked past the visible end asks for.
    func testScrollToShowBringsACardBackIntoTheRail() throws {
        let result = layout(ids, selected: "pane-1", in: shortBounds)
        XCTAssertNil(result.scrollToShow("pane-1"), "already in view")
        let offset = try XCTUnwrap(result.scrollToShow("pane-8"))
        let scrolled = layout(ids, selected: "pane-8", scroll: offset, in: shortBounds)
        let last = try XCTUnwrap(scrolled.rail.last)
        XCTAssertEqual(last.frame.maxY, shortBounds.maxY, accuracy: 0.001)
        XCTAssertNil(scrolled.scrollToShow("pane-8"), "and now it is in view")
    }

    func testAClickFindsTheCardUnderIt() throws {
        let result = layout(ids, selected: "pane-3")
        let second = try XCTUnwrap(result.rail.first { $0.id == "pane-2" })
        XCTAssertEqual(result.railPane(at: CGPoint(x: 100, y: second.frame.midY)), "pane-2")
        let hero = try XCTUnwrap(result.hero.first)
        XCTAssertNil(
            result.railPane(at: CGPoint(x: hero.frame.midX, y: hero.frame.midY)),
            "the pane on screen is not a card"
        )
        XCTAssertEqual(
            result.railPane(at: CGPoint(x: 100, y: result.rail[2].frame.midY)),
            "pane-3",
            "and the selected pane still has one"
        )
    }

    /// A card scrolled out of the rail is only clickable where it is actually
    /// drawn — a scroll view's clip, without a scroll view.
    func testACardScrolledPastTheRailIsNotClickableThere() throws {
        let result = layout(ids, selected: "pane-3", scroll: 200, in: shortBounds)
        let first = result.rail[0]
        XCTAssertLessThan(first.frame.maxY, shortBounds.minY, "scrolled clean off the top")
        XCTAssertNil(
            result.railPane(at: CGPoint(x: 100, y: first.frame.midY)),
            "its frame is still up there and still means nothing"
        )
        // The first card still fully inside the rail answers where it is drawn.
        // Asked at the rail's very top edge the answer may be nothing at all —
        // a scrolled rail can have a gap there, and a gap is not a card.
        let visible = try XCTUnwrap(result.rail.first { $0.frame.minY >= shortBounds.minY })
        XCTAssertEqual(result.railPane(at: CGPoint(x: 100, y: visible.frame.midY)), visible.id)
    }
}
