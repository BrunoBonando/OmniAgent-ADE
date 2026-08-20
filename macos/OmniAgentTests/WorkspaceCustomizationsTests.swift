import AppKit
import XCTest

@testable import OmniAgent

/// `WorkspaceCustomizationsCodec`: the native-only
/// `workspace_customizations_native` row's serialize/deserialize pair,
/// mirroring `EditorPanesCodec`'s repair shape (a bad field costs the field,
/// a bad entry costs the entry), plus the closed-workspaces row's tiny codec
/// — whose shape is the web build's (`ui/src/state/closedWorkspaces.ts`), a
/// bare JSON array of ids.
final class WorkspaceCustomizationsTests: XCTestCase {
    func testRoundTrip() {
        let map: [String: WorkspaceCustomization] = [
            "/Users/b/Code/alpha": WorkspaceCustomization(displayName: "Alpha Prime", color: .blue),
            "/Users/b/Code/beta": WorkspaceCustomization(displayName: nil, color: .gold),
            "/Users/b/Code/gamma": WorkspaceCustomization(displayName: "Γ", color: nil),
        ]
        XCTAssertEqual(
            WorkspaceCustomizationsCodec.deserialize(WorkspaceCustomizationsCodec.serialize(map)),
            map
        )
    }

    /// `.sortedKeys` — the write-dedupe in `WorkspaceWindowController.write`
    /// compares strings, so the same map must serialize to the same string.
    func testSerializeIsDeterministic() {
        let map: [String: WorkspaceCustomization] = [
            "/a": WorkspaceCustomization(displayName: "A", color: .red),
            "/b": WorkspaceCustomization(displayName: "B", color: .green),
        ]
        XCTAssertEqual(
            WorkspaceCustomizationsCodec.serialize(map),
            WorkspaceCustomizationsCodec.serialize(map)
        )
    }

    func testCorruptRowRestoresEmpty() {
        XCTAssertEqual(WorkspaceCustomizationsCodec.deserialize(nil), [:])
        XCTAssertEqual(WorkspaceCustomizationsCodec.deserialize(""), [:])
        XCTAssertEqual(WorkspaceCustomizationsCodec.deserialize("not json"), [:])
        XCTAssertEqual(WorkspaceCustomizationsCodec.deserialize(#"{"workspaces": 3}"#), [:])
        XCTAssertEqual(WorkspaceCustomizationsCodec.deserialize(#"[1,2]"#), [:])
    }

    /// A colour from a future build costs the colour, not the workspace; a
    /// blank name costs the name; an entry with nothing left is dropped
    /// rather than stored as a claim that the workspace was customized.
    func testFieldRepairRules() {
        let raw = """
        {"workspaces":{
            "/keeps-both":{"name":"Kept","color":"pink"},
            "/martian-color":{"name":"Named","color":"chartreuse"},
            "/blank-name":{"name":"   ","color":"gray"},
            "/nothing-left":{"name":"","color":"martian"},
            "/not-a-dict":7
        }}
        """
        let map = WorkspaceCustomizationsCodec.deserialize(raw)
        XCTAssertEqual(map["/keeps-both"], WorkspaceCustomization(displayName: "Kept", color: .pink))
        XCTAssertEqual(map["/martian-color"], WorkspaceCustomization(displayName: "Named", color: nil))
        XCTAssertEqual(map["/blank-name"], WorkspaceCustomization(displayName: nil, color: .gray))
        XCTAssertNil(map["/nothing-left"])
        XCTAssertNil(map["/not-a-dict"])
    }

    /// Serialization never stores an empty customization either — removing a
    /// workspace's name and colour removes the row entry.
    func testSerializeDropsEmptyCustomizations() {
        let map = ["/empty": WorkspaceCustomization(displayName: nil, color: nil)]
        XCTAssertEqual(
            WorkspaceCustomizationsCodec.deserialize(WorkspaceCustomizationsCodec.serialize(map)),
            [:]
        )
    }

    func testSettingsKey() {
        XCTAssertEqual(SettingsKey.workspaceCustomizations, "workspace_customizations_native")
    }

    /// The spec's eight swatches, in the dialog's order.
    func testTheEightColors() {
        XCTAssertEqual(
            WorkspaceColor.allCases.map(\.rawValue),
            ["gray", "green", "blue", "purple", "pink", "red", "orange", "gold"]
        )
    }

    // MARK: - Closed workspaces (the web build's row, shape-for-shape)

    func testClosedWorkspacesRoundTrip() {
        let ids: Set<String> = ["proj-a", "proj-b"]
        XCTAssertEqual(
            ClosedWorkspacesCodec.deserialize(ClosedWorkspacesCodec.serialize(ids)),
            ids
        )
    }

    /// The exact bytes the web build writes for one id — the row is shared,
    /// so the shape is a contract, not a choice.
    func testClosedWorkspacesShapeMatchesTheWebBuild() {
        XCTAssertEqual(ClosedWorkspacesCodec.serialize(["only"]), #"["only"]"#)
        XCTAssertEqual(ClosedWorkspacesCodec.deserialize(#"["a","b"]"#), ["a", "b"])
    }

    /// A corrupt row means "nothing is closed" — showing more than asked for
    /// rather than hiding work, the web codec's own rule.
    func testClosedWorkspacesCorruptRowRestoresEmpty() {
        XCTAssertEqual(ClosedWorkspacesCodec.deserialize(nil), [])
        XCTAssertEqual(ClosedWorkspacesCodec.deserialize(""), [])
        XCTAssertEqual(ClosedWorkspacesCodec.deserialize("{}"), [])
        XCTAssertEqual(ClosedWorkspacesCodec.deserialize(#"["ok", 3, {"no":1}]"#), ["ok"])
    }
}
