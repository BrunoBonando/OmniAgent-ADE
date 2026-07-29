import { describe, expect, it } from "vitest";
import layoutFixture from "../../../fixtures/native-macos-compat/persisted-layout.json";
import paneFixture from "../../../fixtures/native-macos-compat/pane-grid.json";
import { LAYOUT_SETTING_KEY, deserializeLayout } from "./sessions";
import { buildGrid, gridShape, isPaneHole, paneIds, syncPaneTree } from "./paneGrid";
import type { PaneTree } from "./paneGrid";

function leaves(tree: PaneTree | null): string[] {
  if (tree === null) return [];
  if (typeof tree === "string") return [tree];
  return tree.children.flatMap(leaves);
}

describe("native macOS compatibility fixtures", () => {
  it("preserves and repairs the persisted layout setting", () => {
    expect(LAYOUT_SETTING_KEY).toBe(layoutFixture.setting_key);
    expect(deserializeLayout(JSON.stringify(layoutFixture.layout))).toEqual(layoutFixture.layout.tabs);
    expect(deserializeLayout(JSON.stringify(layoutFixture.corrupt_layout))).toEqual(layoutFixture.repaired_layout.tabs);
  });

  it("preserves approved pane shapes and repairs a hole when a pane is added", () => {
    for (const shape of paneFixture.shapes) {
      expect(gridShape(shape.count)).toEqual({ cols: shape.cols, rows: shape.rows });
      const tree = buildGrid(shape.pane_ids);
      expect(paneIds(tree)).toEqual(shape.pane_ids);
      expect(leaves(tree).filter(isPaneHole)).toHaveLength(shape.holes);
    }

    const repaired = syncPaneTree(buildGrid(paneFixture.hole_repair.existing_ids), paneFixture.hole_repair.desired_ids);
    expect(paneIds(repaired)).toEqual(paneFixture.hole_repair.expected_pane_ids);
    expect(leaves(repaired).filter(isPaneHole)).toHaveLength(paneFixture.hole_repair.holes);
  });
});
