import XCTest
@testable import OmniAgent

/// The overflow layout's geometry, on its own: hero, rail, and the scroll the
/// rail exists to provide.
final class PaneFilmstripTests: XCTestCase {
    private let bounds = CGRect(x: 10, y: 20, width: 1200, height: 800)

    private func layout(
        _ ids: [String],
        hero: String,
        scroll: CGFloat = 0
    ) -> PaneFilmstrip.Layout {
        PaneFilmstrip.layout(
            ids: ids,
            hero: hero,
            in: bounds,
            railWidth: 196,
            gap: 6,
            scroll: scroll
        )
    }

    private var ids: [String] { (1...8).map { "pane-\($0)" } }

    func testTheHeroTakesEverythingTheRailDoesNot() {
        let result = layout(ids, hero: "pane-3")
        XCTAssertEqual(result.hero, CGRect(x: 10 + 196 + 6, y: 20, width: 1200 - 202, height: 800))
        XCTAssertEqual(result.railBounds, CGRect(x: 10, y: 20, width: 196, height: 800))
        XCTAssertEqual(result.hero.maxX, bounds.maxX, "the two tile the bounds exactly")
    }

    func testTheRailHoldsEveryPaneButTheHeroInPaneOrder() {
        let result = layout(ids, hero: "pane-3")
        XCTAssertEqual(result.rail.map(\.id), ["pane-1", "pane-2", "pane-4", "pane-5", "pane-6", "pane-7", "pane-8"])
        XCTAssertEqual(result.rail.first?.frame.minY, bounds.minY)
        // Each chip is the hero's shape at the rail's width.
        let hero = result.hero
        let expectedHeight = (196 * hero.height / hero.width).rounded()
        for item in result.rail {
            XCTAssertEqual(item.frame.width, 196)
            XCTAssertEqual(item.frame.height, expectedHeight)
            XCTAssertEqual(item.frame.minX, bounds.minX)
        }
        // Stacked with the same gap the grid's seams use, and no overlap.
        for (above, below) in zip(result.rail, result.rail.dropFirst()) {
            XCTAssertEqual(below.frame.minY - above.frame.maxY, 6, accuracy: 0.001)
        }
    }

    func testTheRailScrollsAndClampsAtBothEnds() {
        let result = layout(ids, hero: "pane-3")
        XCTAssertGreaterThan(result.maxScroll, 0, "seven chips do not fit in 800pt")

        let scrolled = layout(ids, hero: "pane-3", scroll: 120)
        XCTAssertEqual(scrolled.scroll, 120)
        XCTAssertEqual(
            scrolled.rail.first?.frame.minY,
            (result.rail.first?.frame.minY ?? 0) - 120,
            "the whole rail moves by the offset"
        )

        XCTAssertEqual(layout(ids, hero: "pane-3", scroll: -50).scroll, 0, "no scrolling past the top")
        XCTAssertEqual(
            layout(ids, hero: "pane-3", scroll: 9_999).scroll,
            result.maxScroll,
            "nor past the last chip"
        )
        let end = layout(ids, hero: "pane-3", scroll: 9_999)
        XCTAssertEqual(
            end.rail.last?.frame.maxY ?? 0,
            bounds.maxY,
            accuracy: 0.001,
            "scrolled to the end, the last chip sits on the rail's floor"
        )
    }

    func testAShortRailDoesNotScroll() {
        let result = layout(["pane-1", "pane-2"], hero: "pane-1")
        XCTAssertEqual(result.rail.count, 1)
        XCTAssertEqual(result.maxScroll, 0)
        XCTAssertEqual(layout(["pane-1", "pane-2"], hero: "pane-1", scroll: 400).scroll, 0)
    }

    func testAClickFindsTheChipUnderIt() {
        let result = layout(ids, hero: "pane-3")
        let second = try? XCTUnwrap(result.rail[1])
        XCTAssertEqual(result.railPane(at: CGPoint(x: 100, y: (second?.frame.midY ?? 0))), "pane-2")
        XCTAssertNil(
            result.railPane(at: CGPoint(x: result.hero.midX, y: result.hero.midY)),
            "the hero is not a chip"
        )
        XCTAssertNil(
            result.railPane(at: CGPoint(x: 100, y: bounds.maxY + 40)),
            "nor is anything outside the rail"
        )
    }

    /// A chip scrolled half out of the rail is only clickable where it is
    /// actually drawn — a scroll view's clip, without a scroll view.
    func testAChipScrolledPastTheRailIsNotClickableThere() {
        let result = layout(ids, hero: "pane-3", scroll: 200)
        let first = result.rail[0]
        XCTAssertLessThan(first.frame.maxY, bounds.minY, "scrolled clean off the top")
        XCTAssertNil(
            result.railPane(at: CGPoint(x: 100, y: first.frame.midY)),
            "its frame is still up there and still means nothing"
        )
        // What is actually against the rail's top edge now answers instead.
        let visible = try? XCTUnwrap(result.rail.first { $0.frame.maxY > bounds.minY })
        XCTAssertEqual(result.railPane(at: CGPoint(x: 100, y: bounds.minY + 2)), visible?.id)
    }
}
