import { describe, expect, it } from "vitest";
import { LEAF_LABEL_ZOOM_THRESHOLD, shouldShowNodeLabel } from "./labelVisibility";

describe("shouldShowNodeLabel — leaf kinds (e.g. file/code_entity/doc/memory/decision/session)", () => {
  it("hides the label when zoomed out and not hovered", () => {
    expect(shouldShowNodeLabel({ kind: "file", globalScale: 1, isHovered: false })).toBe(false);
  });

  it("hides the label right at the threshold (strictly greater-than, not >=)", () => {
    expect(
      shouldShowNodeLabel({ kind: "code_entity", globalScale: LEAF_LABEL_ZOOM_THRESHOLD, isHovered: false }),
    ).toBe(false);
  });

  it("shows the label once zoomed in past the threshold", () => {
    expect(
      shouldShowNodeLabel({
        kind: "code_entity",
        globalScale: LEAF_LABEL_ZOOM_THRESHOLD + 0.01,
        isHovered: false,
      }),
    ).toBe(true);
  });

  it("shows the label while hovered, regardless of zoom", () => {
    expect(shouldShowNodeLabel({ kind: "doc", globalScale: 0.2, isHovered: true })).toBe(true);
  });

  it("hides the label when zoomed out and un-hovered even for every leaf kind", () => {
    for (const kind of ["file", "code_entity", "doc", "memory", "decision", "session"]) {
      expect(shouldShowNodeLabel({ kind, globalScale: 1, isHovered: false })).toBe(false);
    }
  });
});

describe("shouldShowNodeLabel — hub kinds (project/community)", () => {
  it("always shows the label, zoomed all the way out", () => {
    expect(shouldShowNodeLabel({ kind: "project", globalScale: 0.1, isHovered: false })).toBe(true);
    expect(shouldShowNodeLabel({ kind: "community", globalScale: 0.1, isHovered: false })).toBe(true);
  });

  it("still shows the label zoomed in and/or hovered (no behavior change)", () => {
    expect(shouldShowNodeLabel({ kind: "project", globalScale: 5, isHovered: true })).toBe(true);
  });
});

describe("shouldShowNodeLabel — an unrecognized kind", () => {
  it("falls back to the leaf-kind rule rather than throwing", () => {
    expect(shouldShowNodeLabel({ kind: "some_future_kind", globalScale: 1, isHovered: false })).toBe(false);
    expect(
      shouldShowNodeLabel({ kind: "some_future_kind", globalScale: LEAF_LABEL_ZOOM_THRESHOLD + 1, isHovered: false }),
    ).toBe(true);
  });
});
