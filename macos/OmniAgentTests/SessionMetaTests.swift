import XCTest

@testable import OmniAgent

/// `SessionMetaCodec`: the native-only `session_meta_native` row's
/// serialize/deserialize pair (EditorPanesCodec's repair shape — a bad field
/// costs the field, a bad entry costs the entry), the prune that drops
/// entries for vanished groups, and `SessionMeta.arrange` — the Project-mode
/// ordering that puts pinned sessions first and nests children under their
/// parent at depth 1.
final class SessionMetaTests: XCTestCase {
    // MARK: - Codec

    func testRoundTrip() {
        let meta: [String: SessionMeta] = [
            "g-1": SessionMeta(pinned: true),
            "g-2": SessionMeta(pinned: false, parent: "g-1"),
            "g-3": SessionMeta(
                pinned: true,
                parent: "g-1",
                branch: SessionBranch(
                    repositoryRoot: "/repo",
                    branch: "feature/a",
                    worktreePath: "/repo/.omniagent/worktrees/feature-a",
                    sourceRef: "main",
                    sourceCommit: "abc123",
                    engine: .claude,
                    model: "opus"
                )
            ),
        ]
        XCTAssertEqual(SessionMetaCodec.deserialize(SessionMetaCodec.serialize(meta)), meta)
    }

    /// `.sortedKeys` — the write-dedupe in `WorkspaceWindowController.write`
    /// compares strings, so the same map must serialize to the same string.
    func testSerializeIsDeterministic() {
        let meta: [String: SessionMeta] = [
            "g-a": SessionMeta(pinned: true),
            "g-b": SessionMeta(pinned: false, parent: "g-a"),
        ]
        XCTAssertEqual(SessionMetaCodec.serialize(meta), SessionMetaCodec.serialize(meta))
    }

    func testCorruptRowRestoresEmpty() {
        XCTAssertEqual(SessionMetaCodec.deserialize(nil), [:])
        XCTAssertEqual(SessionMetaCodec.deserialize(""), [:])
        XCTAssertEqual(SessionMetaCodec.deserialize("not json"), [:])
        XCTAssertEqual(SessionMetaCodec.deserialize(#"{"sessions": 3}"#), [:])
        XCTAssertEqual(SessionMetaCodec.deserialize(#"[1,2]"#), [:])
    }

    /// A parent this build cannot trust costs the parent, not the session; a
    /// non-bool `pinned` reads as unpinned; an entry with nothing left is
    /// dropped rather than stored as a claim about the session.
    func testFieldRepairRules() {
        let raw = """
        {"sessions":{
            "g-keeps-both":{"pinned":true,"parent":"g-parent"},
            "g-bad-parent":{"pinned":true,"parent":"no spaces allowed"},
            "g-self-parent":{"pinned":true,"parent":"g-self-parent"},
            "g-nothing-left":{"pinned":false,"parent":"also invalid!"},
            "g-not-a-dict":7,
            "invalid key!":{"pinned":true}
        }}
        """
        let meta = SessionMetaCodec.deserialize(raw)
        XCTAssertEqual(meta["g-keeps-both"], SessionMeta(pinned: true, parent: "g-parent"))
        XCTAssertEqual(meta["g-bad-parent"], SessionMeta(pinned: true))
        XCTAssertEqual(meta["g-self-parent"], SessionMeta(pinned: true))
        XCTAssertNil(meta["g-nothing-left"])
        XCTAssertNil(meta["g-not-a-dict"])
        XCTAssertEqual(meta.count, 3)
    }

    /// Serialization never stores an empty entry either — unpinning an
    /// un-nested session removes it from the row.
    func testSerializeDropsEmptyEntries() {
        let meta = ["g-1": SessionMeta(pinned: false, parent: nil)]
        XCTAssertEqual(SessionMetaCodec.deserialize(SessionMetaCodec.serialize(meta)), [:])
    }

    func testBranchMetadataRepairRules() {
        let raw = """
        {"sessions":{
            "g-branch":{"branch":{
                "repositoryRoot":"/repo",
                "branch":"feat/x",
                "worktreePath":"/repo/.omniagent/worktrees/feat-x",
                "sourceRef":"main",
                "sourceCommit":"abc",
                "engine":"codex",
                "model":"gpt"
            }},
            "g-bad-engine":{"branch":{
                "repositoryRoot":"/repo",
                "branch":"feat/y",
                "worktreePath":"/repo/.omniagent/worktrees/feat-y",
                "engine":"unknown"
            }},
            "g-empty-branch":{"branch":{"repositoryRoot":"","branch":"","worktreePath":""}}
        }}
        """

        let meta = SessionMetaCodec.deserialize(raw)

        XCTAssertEqual(
            meta["g-branch"]?.branch,
            SessionBranch(
                repositoryRoot: "/repo",
                branch: "feat/x",
                worktreePath: "/repo/.omniagent/worktrees/feat-x",
                sourceRef: "main",
                sourceCommit: "abc",
                engine: .codex,
                model: "gpt"
            )
        )
        XCTAssertEqual(meta["g-bad-engine"]?.branch?.engine, nil)
        XCTAssertNil(meta["g-empty-branch"])
    }

    func testSettingsKey() {
        XCTAssertEqual(SettingsKey.sessionMeta, "session_meta_native")
    }

    // MARK: - Prune

    /// An entry keyed by a group no live pane carries is dropped, and a
    /// parent pointing at one is cleared — with an entry left empty by that
    /// clearing dropped too.
    func testPrunedDropsVanishedGroupsAndDanglingParents() {
        let meta: [String: SessionMeta] = [
            "g-live": SessionMeta(pinned: true, parent: "g-gone"),
            "g-gone": SessionMeta(pinned: true),
            "g-only-dangling": SessionMeta(pinned: false, parent: "g-gone"),
        ]
        XCTAssertEqual(
            SessionMeta.pruned(meta, live: ["g-live", "g-only-dangling"]),
            ["g-live": SessionMeta(pinned: true)]
        )
    }

    // MARK: - Arrange

    private func node(_ id: String) -> SessionGroupNode {
        SessionGroupNode(
            id: id,
            project: "p",
            name: nil,
            label: id,
            cwd: "/tmp",
            paneIDs: [],
            isCurrent: false
        )
    }

    /// Pinned sessions sort first, stably on both sides of the split.
    func testArrangePutsPinnedSessionsFirstKeepingOrderWithinEachHalf() {
        let sessions = ["g-1", "g-2", "g-3", "g-4"].map(node)
        let arranged = SessionMeta.arrange(
            sessions,
            meta: [
                "g-2": SessionMeta(pinned: true),
                "g-4": SessionMeta(pinned: true),
            ]
        )
        XCTAssertEqual(arranged.map(\.session.id), ["g-2", "g-4", "g-1", "g-3"])
        XCTAssertEqual(arranged.map(\.nested), [false, false, false, false])
    }

    /// A nested session renders directly under its parent, marked nested.
    func testArrangeNestsChildrenUnderTheirParent() {
        let sessions = ["g-1", "g-2", "g-3"].map(node)
        let arranged = SessionMeta.arrange(
            sessions,
            meta: ["g-3": SessionMeta(pinned: false, parent: "g-1")]
        )
        XCTAssertEqual(arranged.map(\.session.id), ["g-1", "g-3", "g-2"])
        XCTAssertEqual(arranged.map(\.nested), [false, true, false])
    }

    /// A parent that is not in this list (deleted, or another workspace)
    /// costs the indent, not the session.
    func testArrangeRendersAnOrphanTopLevel() {
        let arranged = SessionMeta.arrange(
            [node("g-1")],
            meta: ["g-1": SessionMeta(pinned: false, parent: "g-gone")]
        )
        XCTAssertEqual(arranged.map(\.session.id), ["g-1"])
        XCTAssertEqual(arranged.map(\.nested), [false])
    }

    /// Depth 1 only: a chain deeper than one level flattens under its
    /// top-level ancestor rather than stepping further right.
    func testArrangeFlattensDeeperChainsToDepthOne() {
        let sessions = ["g-root", "g-child", "g-grandchild"].map(node)
        let arranged = SessionMeta.arrange(
            sessions,
            meta: [
                "g-child": SessionMeta(pinned: false, parent: "g-root"),
                "g-grandchild": SessionMeta(pinned: false, parent: "g-child"),
            ]
        )
        XCTAssertEqual(arranged.map(\.session.id), ["g-root", "g-child", "g-grandchild"])
        XCTAssertEqual(arranged.map(\.nested), [false, true, true])
    }

    /// A parent cycle in a corrupt row must not make its members vanish.
    func testArrangeSurvivesAParentCycle() {
        let sessions = ["g-a", "g-b"].map(node)
        let arranged = SessionMeta.arrange(
            sessions,
            meta: [
                "g-a": SessionMeta(pinned: false, parent: "g-b"),
                "g-b": SessionMeta(pinned: false, parent: "g-a"),
            ]
        )
        XCTAssertEqual(Set(arranged.map(\.session.id)), ["g-a", "g-b"])
    }
}
