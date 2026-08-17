import XCTest
@testable import OmniAgent

/// `BrowserPanesCodec`: the native-only `browser_panes_native` row's
/// serialize/deserialize pair, mirroring `PersistedLayoutCodec`'s per-entry
/// repair shape (a bad field costs the field, a bad entry costs the entry).
final class BrowserPanesTests: XCTestCase {
    func testRoundTrip() {
        let panes = [
            PersistedBrowserPane(url: "https://example.com", group: "g1", groupLabel: "Session 1"),
            PersistedBrowserPane(url: "https://other.com", group: nil, groupLabel: nil),
        ]

        let raw = BrowserPanesCodec.serialize(panes)

        XCTAssertEqual(BrowserPanesCodec.deserialize(raw), panes)
    }

    func testMissingOrGarbageRawDeserializesToEmpty() {
        XCTAssertEqual(BrowserPanesCodec.deserialize(nil), [])
        XCTAssertEqual(BrowserPanesCodec.deserialize(""), [])
        XCTAssertEqual(BrowserPanesCodec.deserialize("}{ not json"), [])
        XCTAssertEqual(BrowserPanesCodec.deserialize(#"{"panes":[]}"#), [])
    }

    func testANonStringURLDropsOnlyThatEntryWhileItsSiblingsSurvive() {
        let raw = #"""
        {"panes":[
          {"url":"https://a"},
          {"url":42},
          {"url":"https://c"}
        ]}
        """#

        let panes = BrowserPanesCodec.deserialize(raw)

        XCTAssertEqual(panes.map(\.url), ["https://a", "https://c"])
    }

    func testAnInvalidGroupCostsOnlyTheFieldNotTheWholeEntry() {
        let raw = #"{"panes":[{"url":"https://a","group":"not a valid id!"}]}"#

        let panes = BrowserPanesCodec.deserialize(raw)

        XCTAssertEqual(panes.count, 1)
        XCTAssertEqual(panes.first?.url, "https://a")
        XCTAssertNil(panes.first?.group, "the pane survives, just ungrouped")
    }

    func testSerializeOutputIsStableAndSorted() {
        // `JSONSerialization` escapes `/` as `\/`, exactly what
        // `PersistedLayoutCodec.serialize` also produces — key order
        // (`group` before `url`) is what this test is actually pinning.
        let json = BrowserPanesCodec.serialize([
            PersistedBrowserPane(url: "https://a", group: "g1", groupLabel: nil),
        ])

        XCTAssertEqual(json, #"{"panes":[{"group":"g1","url":"https:\/\/a"}]}"#)
    }
}
