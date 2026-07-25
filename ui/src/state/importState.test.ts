import { describe, expect, it } from "vitest";
import {
  canProceedToCandidates,
  checkedCount,
  checkedPaths,
  checkedToolIds,
  importFailureBanner,
  importReducer,
  initialImportState,
  mergeCandidates,
  rowsByTool,
  selectableTools,
  summarizeImportResults,
  toBatchResult,
  toolGroupState,
  type ImportRow,
  type ImportRowResult,
  type ImportState,
} from "./importState";
import type { DetectedTool, ImportCandidate } from "../lib/tauri";
import type { ProjectInfo } from "./sessions";

const CLAUDE_CODE: DetectedTool = { id: "claude-code", name: "Claude Code", detected: true, candidate_count: 16 };
const VSCODE: DetectedTool = { id: "vscode", name: "VS Code", detected: true, candidate_count: 17 };
const CURSOR: DetectedTool = { id: "cursor", name: "Cursor", detected: false, candidate_count: 0 };
const TOOLS = [CLAUDE_CODE, VSCODE, CURSOR];

describe("importReducer — tools phase", () => {
  it("starts in the tools phase with nothing loaded yet", () => {
    expect(initialImportState).toEqual({
      phase: "tools",
      tools: null,
      selectedTools: {},
      rows: [],
      checked: {},
      results: [],
      error: null,
    });
  });

  it("tools_loaded checks every detected tool by default, leaves undetected ones unchecked", () => {
    const next = importReducer(initialImportState, { type: "tools_loaded", tools: TOOLS });
    expect(next.tools).toEqual(TOOLS);
    expect(next.selectedTools).toEqual({ "claude-code": true, vscode: true, cursor: false });
  });

  it("tools_load_failed sets tools to [] and records the error", () => {
    const next = importReducer(initialImportState, { type: "tools_load_failed", error: "boom" });
    expect(next.tools).toEqual([]);
    expect(next.error).toBe("boom");
  });

  it("tool_toggled flips a detected tool's checked state", () => {
    const loaded = importReducer(initialImportState, { type: "tools_loaded", tools: TOOLS });
    const next = importReducer(loaded, { type: "tool_toggled", id: "claude-code" });
    expect(next.selectedTools["claude-code"]).toBe(false);
  });

  it("tool_toggled is a no-op for an undetected tool", () => {
    const loaded = importReducer(initialImportState, { type: "tools_loaded", tools: TOOLS });
    const next = importReducer(loaded, { type: "tool_toggled", id: "cursor" });
    expect(next).toBe(loaded); // unchanged reference — genuinely a no-op
  });

  it("tool_toggled is a no-op for an unknown id", () => {
    const loaded = importReducer(initialImportState, { type: "tools_loaded", tools: TOOLS });
    const next = importReducer(loaded, { type: "tool_toggled", id: "not-a-tool" });
    expect(next).toBe(loaded);
  });
});

describe("selectableTools / checkedToolIds / canProceedToCandidates", () => {
  it("selectableTools filters to only detected tools", () => {
    expect(selectableTools(TOOLS)).toEqual([CLAUDE_CODE, VSCODE]);
  });

  it("selectableTools handles null (still loading)", () => {
    expect(selectableTools(null)).toEqual([]);
  });

  it("checkedToolIds reflects selectedTools, detected tools only", () => {
    const state: ImportState = {
      ...initialImportState,
      tools: TOOLS,
      selectedTools: { "claude-code": true, vscode: false, cursor: false },
    };
    expect(checkedToolIds(state)).toEqual(["claude-code"]);
  });

  it("canProceedToCandidates is false with nothing checked, true with >=1", () => {
    const none: ImportState = { ...initialImportState, tools: TOOLS, selectedTools: {} };
    expect(canProceedToCandidates(none)).toBe(false);
    const one: ImportState = { ...initialImportState, tools: TOOLS, selectedTools: { vscode: true } };
    expect(canProceedToCandidates(one)).toBe(true);
  });
});

describe("mergeCandidates", () => {
  const claudeCandidates: ImportCandidate[] = [
    { path: "/Users/bruno/code/alpha", suggested_name: "alpha" },
    { path: "/Users/bruno/code/beta", suggested_name: "beta" },
  ];
  const vscodeCandidates: ImportCandidate[] = [
    { path: "/Users/bruno/code/beta", suggested_name: "beta" }, // same path as claude's — dedup target
    { path: "/Users/bruno/code/gamma", suggested_name: "gamma" },
  ];

  it("merges candidates from multiple tools in tool order", () => {
    const rows = mergeCandidates(
      [CLAUDE_CODE, VSCODE],
      { "claude-code": claudeCandidates, vscode: vscodeCandidates },
      [],
    );
    expect(rows.map((r) => r.path)).toEqual([
      "/Users/bruno/code/alpha",
      "/Users/bruno/code/beta",
      "/Users/bruno/code/gamma",
    ]);
  });

  it("dedupes a path reported by two tools, keeping the FIRST tool's row (tool order)", () => {
    const rows = mergeCandidates(
      [CLAUDE_CODE, VSCODE],
      { "claude-code": claudeCandidates, vscode: vscodeCandidates },
      [],
    );
    const beta = rows.find((r) => r.path === "/Users/bruno/code/beta");
    expect(beta?.sourceTool).toBe("claude-code");
    expect(rows).toHaveLength(3); // not 4 — beta only appears once
  });

  it("dedupes a path with/without a trailing slash as the same folder", () => {
    const rows = mergeCandidates(
      [CLAUDE_CODE, VSCODE],
      {
        "claude-code": [{ path: "/Users/bruno/code/alpha/", suggested_name: "alpha" }],
        vscode: [{ path: "/Users/bruno/code/alpha", suggested_name: "alpha" }],
      },
      [],
    );
    expect(rows).toHaveLength(1);
  });

  it("marks a candidate matching an existing project's path as alreadyAdded, without dropping it", () => {
    const existing: ProjectInfo[] = [{ id: "beta", label: "beta", path: "/Users/bruno/code/beta" }];
    const rows = mergeCandidates(
      [CLAUDE_CODE, VSCODE],
      { "claude-code": claudeCandidates, vscode: vscodeCandidates },
      existing,
    );
    const beta = rows.find((r) => r.path === "/Users/bruno/code/beta");
    expect(beta?.alreadyAdded).toBe(true);
    const alpha = rows.find((r) => r.path === "/Users/bruno/code/alpha");
    expect(alpha?.alreadyAdded).toBe(false);
  });

  it("matches an existing project by id when its path is null", () => {
    const existing: ProjectInfo[] = [{ id: "/Users/bruno/code/gamma", label: "gamma", path: null }];
    const rows = mergeCandidates([VSCODE], { vscode: vscodeCandidates }, existing);
    const gamma = rows.find((r) => r.path === "/Users/bruno/code/gamma");
    expect(gamma?.alreadyAdded).toBe(true);
  });

  it("an unselected tool contributes nothing (only checked tools are ever passed in)", () => {
    const rows = mergeCandidates([CLAUDE_CODE], { "claude-code": claudeCandidates, vscode: vscodeCandidates }, []);
    expect(rows.map((r) => r.path)).toEqual(["/Users/bruno/code/alpha", "/Users/bruno/code/beta"]);
  });
});

describe("importReducer — candidates phase", () => {
  const ROWS: ImportRow[] = [
    { path: "/a", suggestedName: "a", sourceTool: "claude-code", alreadyAdded: false },
    { path: "/b", suggestedName: "b", sourceTool: "claude-code", alreadyAdded: true },
    { path: "/c", suggestedName: "c", sourceTool: "vscode", alreadyAdded: false },
  ];

  it("candidates_requested moves to the candidates phase", () => {
    const next = importReducer(initialImportState, { type: "candidates_requested" });
    expect(next.phase).toBe("candidates");
  });

  it("candidates_loaded checks every row by default EXCEPT already-added ones", () => {
    const next = importReducer(initialImportState, { type: "candidates_loaded", rows: ROWS });
    expect(next.rows).toEqual(ROWS);
    expect(next.checked).toEqual({ "/a": true, "/b": false, "/c": true });
  });

  it("candidates_load_failed records the error without clearing existing rows", () => {
    const loaded = importReducer(initialImportState, { type: "candidates_loaded", rows: ROWS });
    const next = importReducer(loaded, { type: "candidates_load_failed", error: "disk error" });
    expect(next.rows).toEqual(ROWS);
    expect(next.error).toBe("disk error");
  });

  it("back_to_tools clears rows/checked and returns to the tools phase", () => {
    const loaded = importReducer(
      { ...initialImportState, phase: "candidates" },
      { type: "candidates_loaded", rows: ROWS },
    );
    const next = importReducer(loaded, { type: "back_to_tools" });
    expect(next).toEqual({ ...loaded, phase: "tools", rows: [], checked: {}, error: null });
  });

  it("candidate_toggled flips a selectable row", () => {
    const loaded = importReducer(initialImportState, { type: "candidates_loaded", rows: ROWS });
    const next = importReducer(loaded, { type: "candidate_toggled", path: "/a" });
    expect(next.checked["/a"]).toBe(false);
  });

  it("candidate_toggled is a no-op for an already-added row", () => {
    const loaded = importReducer(initialImportState, { type: "candidates_loaded", rows: ROWS });
    const next = importReducer(loaded, { type: "candidate_toggled", path: "/b" });
    expect(next).toBe(loaded);
  });

  it("candidate_toggled is a no-op for an unknown path", () => {
    const loaded = importReducer(initialImportState, { type: "candidates_loaded", rows: ROWS });
    const next = importReducer(loaded, { type: "candidate_toggled", path: "/nope" });
    expect(next).toBe(loaded);
  });

  it("tool_group_set(false) unchecks every selectable row for that tool only", () => {
    const loaded = importReducer(initialImportState, { type: "candidates_loaded", rows: ROWS });
    const next = importReducer(loaded, { type: "tool_group_set", tool: "claude-code", checked: false });
    expect(next.checked).toEqual({ "/a": false, "/b": false, "/c": true });
  });

  it("tool_group_set(true) checks every selectable row for that tool, leaves already-added alone", () => {
    const loaded = importReducer(initialImportState, { type: "candidates_loaded", rows: ROWS });
    const uncheckedFirst = importReducer(loaded, { type: "tool_group_set", tool: "claude-code", checked: false });
    const next = importReducer(uncheckedFirst, { type: "tool_group_set", tool: "claude-code", checked: true });
    expect(next.checked).toEqual({ "/a": true, "/b": false, "/c": true });
  });
});

describe("checkedPaths / checkedCount", () => {
  const ROWS: ImportRow[] = [
    { path: "/a", suggestedName: "a", sourceTool: "claude-code", alreadyAdded: false },
    { path: "/b", suggestedName: "b", sourceTool: "claude-code", alreadyAdded: true },
    { path: "/c", suggestedName: "c", sourceTool: "vscode", alreadyAdded: false },
  ];

  it("counts only checked, non-already-added rows, in row order", () => {
    const state: ImportState = { ...initialImportState, rows: ROWS, checked: { "/a": true, "/b": true, "/c": true } };
    // "/b" is alreadyAdded — even if `checked` somehow had it true, it must never count.
    expect(checkedPaths(state)).toEqual(["/a", "/c"]);
    expect(checkedCount(state)).toBe(2);
  });

  it("is zero when nothing is checked", () => {
    const state: ImportState = { ...initialImportState, rows: ROWS, checked: {} };
    expect(checkedCount(state)).toBe(0);
  });
});

describe("rowsByTool", () => {
  it("groups rows by sourceTool, preserving first-seen tool order", () => {
    const rows: ImportRow[] = [
      { path: "/a", suggestedName: "a", sourceTool: "vscode", alreadyAdded: false },
      { path: "/b", suggestedName: "b", sourceTool: "claude-code", alreadyAdded: false },
      { path: "/c", suggestedName: "c", sourceTool: "vscode", alreadyAdded: false },
    ];
    const grouped = rowsByTool(rows);
    expect(grouped.map((g) => g.tool)).toEqual(["vscode", "claude-code"]);
    expect(grouped[0].rows.map((r) => r.path)).toEqual(["/a", "/c"]);
    expect(grouped[1].rows.map((r) => r.path)).toEqual(["/b"]);
  });

  it("empty input yields an empty grouping", () => {
    expect(rowsByTool([])).toEqual([]);
  });
});

describe("toolGroupState", () => {
  const ROWS: ImportRow[] = [
    { path: "/a", suggestedName: "a", sourceTool: "claude-code", alreadyAdded: false },
    { path: "/b", suggestedName: "b", sourceTool: "claude-code", alreadyAdded: false },
    { path: "/c", suggestedName: "c", sourceTool: "claude-code", alreadyAdded: true },
  ];

  it("returns 'all' when every selectable row in the group is checked", () => {
    expect(toolGroupState(ROWS, { "/a": true, "/b": true }, "claude-code")).toBe("all");
  });

  it("returns 'none' when nothing in the group is checked", () => {
    expect(toolGroupState(ROWS, { "/a": false, "/b": false }, "claude-code")).toBe("none");
  });

  it("returns 'some' for a mixed group", () => {
    expect(toolGroupState(ROWS, { "/a": true, "/b": false }, "claude-code")).toBe("some");
  });

  it("returns 'none' for a group with only already-added rows", () => {
    const onlyAdded: ImportRow[] = [{ path: "/z", suggestedName: "z", sourceTool: "vscode", alreadyAdded: true }];
    expect(toolGroupState(onlyAdded, {}, "vscode")).toBe("none");
  });

  it("ignores already-added rows when computing 'all'", () => {
    // /c is alreadyAdded and can never be checked, but that must not stop
    // /a+/b (both checked) from reading as "all".
    expect(toolGroupState(ROWS, { "/a": true, "/b": true, "/c": false }, "claude-code")).toBe("all");
  });
});

describe("summarizeImportResults", () => {
  const ok = (path: string): ImportRowResult => ({
    path,
    suggestedName: path,
    success: true,
    project: { id: path, label: path, path },
  });
  const fail = (path: string): ImportRowResult => ({ path, suggestedName: path, success: false, error: "boom" });

  it("all succeeded", () => {
    expect(summarizeImportResults([ok("/a"), ok("/b")])).toEqual({
      createdCount: 2,
      failedCount: 0,
      message: "Imported 2 projects.",
    });
  });

  it("singular phrasing for exactly one success", () => {
    expect(summarizeImportResults([ok("/a")]).message).toBe("Imported 1 project.");
  });

  it("all failed", () => {
    expect(summarizeImportResults([fail("/a"), fail("/b")])).toEqual({
      createdCount: 0,
      failedCount: 2,
      message: "Couldn't import 2 projects.",
    });
  });

  it("mixed success/failure", () => {
    expect(summarizeImportResults([ok("/a"), fail("/b"), ok("/c")])).toEqual({
      createdCount: 2,
      failedCount: 1,
      message: "Imported 2 of 3 projects — 1 failed.",
    });
  });

  it("empty results", () => {
    expect(summarizeImportResults([])).toEqual({ createdCount: 0, failedCount: 0, message: "Imported 0 projects." });
  });
});

describe("toBatchResult", () => {
  it("splits results into created projects and failures", () => {
    const projectA: ProjectInfo = { id: "a", label: "a", path: "/a" };
    const results: ImportRowResult[] = [
      { path: "/a", suggestedName: "a", success: true, project: projectA },
      { path: "/b", suggestedName: "b", success: false, error: "already added" },
    ];
    expect(toBatchResult(results)).toEqual({
      created: [projectA],
      failed: [{ path: "/b", suggestedName: "b", success: false, error: "already added" }],
    });
  });

  it("treats a success with no project as a failure rather than dropping it", () => {
    const results: ImportRowResult[] = [{ path: "/a", suggestedName: "a", success: true }];
    const batch = toBatchResult(results);
    expect(batch.created).toEqual([]);
    expect(batch.failed).toEqual([{ path: "/a", suggestedName: "a", success: false, error: "no project returned" }]);
  });
});

describe("importFailureBanner", () => {
  it("returns null when nothing failed", () => {
    const projectA: ProjectInfo = { id: "a", label: "a", path: "/a" };
    expect(importFailureBanner({ created: [projectA], failed: [] })).toBeNull();
  });

  it("names the failures when some succeeded too", () => {
    const projectA: ProjectInfo = { id: "a", label: "a", path: "/a" };
    const banner = importFailureBanner({
      created: [projectA],
      failed: [{ path: "/b", suggestedName: "beta", success: false, error: "x" }],
    });
    expect(banner).toBe("Imported 1 project, but couldn't import beta.");
  });

  it("names the failures when everything failed", () => {
    const banner = importFailureBanner({
      created: [],
      failed: [
        { path: "/b", suggestedName: "beta", success: false, error: "x" },
        { path: "/g", suggestedName: "gamma", success: false, error: "y" },
      ],
    });
    expect(banner).toBe("Couldn't import beta, gamma.");
  });
});
