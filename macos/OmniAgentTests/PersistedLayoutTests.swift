import XCTest
@testable import OmniAgent

/// Ports `ui/src/state/sessions.test.ts`'s "layout serialize/deserialize
/// round trip" / grouping describe blocks fixture-for-fixture — the native
/// `PersistedLayoutCodec` must repair a corrupt/legacy layout exactly like
/// the web build's `deserializeLayout`, since both read/write the same
/// `"layout"` settings row.
final class PersistedLayoutTests: XCTestCase {
    private func tab(
        _ id: String,
        _ project: String,
        _ engine: Engine = .claude
    ) -> PersistedTab {
        PersistedTab(project: project, engine: engine, cwd: "/tmp/\(project)", id: id)
    }

    func testRoundTripsTabsKeepingIdsSoTheyCanBeReplayedAsRestoreId() {
        let tabs = [tab("sess-1", "p1", .codex), tab("sess-2", "p2", .shell)]
        let restored = PersistedLayoutCodec.deserialize(PersistedLayoutCodec.serialize(tabs))
        XCTAssertEqual(
            restored,
            [
                PersistedTab(project: "p1", engine: .codex, cwd: "/tmp/p1", id: "sess-1"),
                PersistedTab(project: "p2", engine: .shell, cwd: "/tmp/p2", id: "sess-2"),
            ]
        )
    }

    func testRestoresALegacyLayoutWithNoIdField() {
        let legacy = #"{"tabs":[{"project":"p1","engine":"claude","cwd":"/tmp/p1","label":"old"}]}"#
        XCTAssertEqual(
            PersistedLayoutCodec.deserialize(legacy),
            [PersistedTab(project: "p1", engine: .claude, cwd: "/tmp/p1", label: "old")]
        )
    }

    func testDropsAnIdTheBackendWouldRejectRatherThanTheWholeTab() {
        let raw = """
        {"tabs":[
            {"id":"has spaces","project":"p1","engine":"claude","cwd":"/tmp/p1"},
            {"id":"slash/es","project":"p2","engine":"claude","cwd":"/tmp/p2"},
            {"id":"\(String(repeating: "x", count: 97))","project":"p3","engine":"claude","cwd":"/tmp/p3"},
            {"id":"","project":"p4","engine":"claude","cwd":"/tmp/p4"},
            {"id":7,"project":"p5","engine":"claude","cwd":"/tmp/p5"}
        ]}
        """
        let restored = PersistedLayoutCodec.deserialize(raw)
        XCTAssertEqual(restored.count, 5)
        for tab in restored {
            XCTAssertNil(tab.id)
        }
    }

    func testKeepsOnlyTheFirstOfTwoTabsPersistedWithTheSameId() {
        let raw = """
        {"tabs":[
            {"id":"sess-dup","project":"p1","engine":"claude","cwd":"/tmp/p1"},
            {"id":"sess-dup","project":"p2","engine":"claude","cwd":"/tmp/p2"}
        ]}
        """
        let restored = PersistedLayoutCodec.deserialize(raw)
        XCTAssertEqual(restored.count, 2)
        XCTAssertEqual(restored[0].id, "sess-dup")
        XCTAssertNil(restored[1].id)
    }

    func testDeserializingNilOrGarbageNeverThrowsAndReturnsEmpty() {
        XCTAssertEqual(PersistedLayoutCodec.deserialize(nil), [])
        XCTAssertEqual(PersistedLayoutCodec.deserialize(""), [])
        XCTAssertEqual(PersistedLayoutCodec.deserialize("not json"), [])
        XCTAssertEqual(PersistedLayoutCodec.deserialize("{}"), [])
        XCTAssertEqual(
            PersistedLayoutCodec.deserialize(#"{"tabs":[{"project":"p1"}]}"#),
            []
        )
    }

    func testFiltersOutIndividuallyMalformedTabEntriesButKeepsTheValidOnes() {
        let raw = """
        {"tabs":[
            {"project":"p1","engine":"claude","cwd":"/tmp/p1"},
            {"project":"p2","engine":"not-real","cwd":"/tmp/p2"}
        ]}
        """
        XCTAssertEqual(
            PersistedLayoutCodec.deserialize(raw),
            [PersistedTab(project: "p1", engine: .claude, cwd: "/tmp/p1")]
        )
    }

    func testRoundTripsARenamedTabsCustomLabel() {
        var renamed = tab("sess-1", "p1", .codex)
        renamed.label = "backend fix"
        let restored = PersistedLayoutCodec.deserialize(PersistedLayoutCodec.serialize([renamed]))
        XCTAssertEqual(
            restored,
            [PersistedTab(project: "p1", engine: .codex, cwd: "/tmp/p1", id: "sess-1", label: "backend fix")]
        )
    }

    func testOmitsTheLabelKeyEntirelyForUnrenamedTabs() {
        let json = PersistedLayoutCodec.serialize([tab("a", "p1")])
        XCTAssertFalse(json.contains("label"))
        XCTAssertEqual(
            PersistedLayoutCodec.deserialize(json),
            [PersistedTab(project: "p1", engine: .claude, cwd: "/tmp/p1", id: "a")]
        )
    }

    func testRoundTripsAPerPaneTerminalThemeOverride() {
        var themed = tab("sess-1", "p1", .codex)
        themed.themeId = .matrix
        XCTAssertEqual(
            PersistedLayoutCodec.deserialize(PersistedLayoutCodec.serialize([themed])),
            [
                PersistedTab(
                    project: "p1",
                    engine: .codex,
                    cwd: "/tmp/p1",
                    id: "sess-1",
                    themeId: .matrix
                ),
            ]
        )
    }

    func testOmitsTheThemeIdKeyEntirelyWhenATabHasNoOverride() {
        let json = PersistedLayoutCodec.serialize([tab("a", "p1")])
        XCTAssertFalse(json.contains("themeId"))
    }

    func testDropsAGarbageThemeIdRatherThanRestoringIt() {
        let raw = #"{"tabs":[{"project":"p1","engine":"claude","cwd":"/tmp/p1","themeId":"not-a-real-theme"}]}"#
        XCTAssertEqual(
            PersistedLayoutCodec.deserialize(raw),
            [PersistedTab(project: "p1", engine: .claude, cwd: "/tmp/p1")]
        )
    }

    // MARK: - Session grouping (group / groupLabel)

    func testRoundTripsAGroupAndItsSessionName() {
        var a = tab("sess-1", "p1")
        a.group = "sess-grp-1"
        a.groupLabel = "auth refactor"
        var b = tab("sess-2", "p1")
        b.group = "sess-grp-1"
        b.groupLabel = "auth refactor"

        XCTAssertEqual(
            PersistedLayoutCodec.deserialize(PersistedLayoutCodec.serialize([a, b])),
            [
                PersistedTab(
                    project: "p1",
                    engine: .claude,
                    cwd: "/tmp/p1",
                    id: "sess-1",
                    group: "sess-grp-1",
                    groupLabel: "auth refactor"
                ),
                PersistedTab(
                    project: "p1",
                    engine: .claude,
                    cwd: "/tmp/p1",
                    id: "sess-2",
                    group: "sess-grp-1",
                    groupLabel: "auth refactor"
                ),
            ]
        )
    }

    func testPersistsTheDefaultSessionNameToo() {
        var withGroup = tab("sess-1", "p1")
        withGroup.group = "sess-grp-1"
        withGroup.groupLabel = "Session 2"
        let json = PersistedLayoutCodec.serialize([withGroup])
        XCTAssertTrue(json.contains("Session 2"))
    }

    func testOmitsGroupLabelEntirelyForASessionThatHasNeverBeenNamed() {
        var withGroup = tab("a", "p1")
        withGroup.group = "sess-grp-1"
        let json = PersistedLayoutCodec.serialize([withGroup])
        XCTAssertFalse(json.contains("groupLabel"))
    }

    func testDropsAGarbageSessionNameRatherThanTheWholePane() {
        let raw = """
        {"tabs":[
            {"project":"p1","engine":"claude","cwd":"/tmp/p1","groupLabel":7},
            {"project":"p2","engine":"claude","cwd":"/tmp/p2","groupLabel":"   "}
        ]}
        """
        let restored = PersistedLayoutCodec.deserialize(raw)
        XCTAssertEqual(restored.count, 2)
        for tab in restored {
            XCTAssertNil(tab.groupLabel)
        }
    }

    func testKeepsASessionNameOnAPaneWhoseGroupIdWasRejected() {
        let raw = #"{"tabs":[{"project":"p1","engine":"claude","cwd":"/tmp/p1","group":"bad group","groupLabel":"old work"}]}"#
        XCTAssertEqual(
            PersistedLayoutCodec.deserialize(raw),
            [PersistedTab(project: "p1", engine: .claude, cwd: "/tmp/p1", groupLabel: "old work")]
        )
    }

    // MARK: - SessionIdentifier

    func testSessionIdentifierAcceptsTheAllowedCharsetWithinLength() {
        XCTAssertTrue(SessionIdentifier.isValid("sess-1_ABC"))
        XCTAssertTrue(SessionIdentifier.isValid(String(repeating: "x", count: 96)))
    }

    func testSessionIdentifierRejectsEmptyTooLongOrOutOfCharsetValues() {
        XCTAssertFalse(SessionIdentifier.isValid(""))
        XCTAssertFalse(SessionIdentifier.isValid(String(repeating: "x", count: 97)))
        XCTAssertFalse(SessionIdentifier.isValid("has spaces"))
        XCTAssertFalse(SessionIdentifier.isValid("slash/es"))
        XCTAssertFalse(SessionIdentifier.isValid("café"))
    }
}
