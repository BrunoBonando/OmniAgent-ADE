# Task 2 — DeskCanvas node tree and tidy-tree layout

Branch: `worktree-desk-canvas`. Worktree: `.claude/worktrees/desk-canvas`.

## What was built

`macos/OmniAgent/DeskCanvas.swift` (new, 275 lines) — pure value types, `import Foundation` only,
no AppKit view code, no window, testable the way `PaneGrid` is:

- `struct DeskNode: Equatable` — `enum Kind: Equatable { case root; case workspace(String); case session(String) }`,
  `let id: String`, `let kind: Kind`, `let children: [DeskNode]`, implicit memberwise init.
- `struct DeskEdge: Equatable` — `let from: String`, `let to: String` (node ids).
- `struct DeskCanvasLayout: Equatable` — `let frames: [String: CGRect]`, `let edges: [DeskEdge]`, `let contentRect: CGRect`.
- `enum DeskCanvas` with:
  - `static let chipWidthFraction: CGFloat = 0.25`
  - `static let lodThreshold: CGFloat = 0.2`
  - `static let fitMargin: CGFloat = 0.2`
  - `static let siblingGapFraction: CGFloat = 0.12`
  - `static let levelGapFraction: CGFloat = 0.3`
  - `static func chipSize(forCard:) -> CGSize`
  - `static func nodeSize(_ kind: DeskNode.Kind, cardSize:) -> CGSize`
  - `static func siblingGap(forCard:) -> CGFloat`
  - `static func levelGap(forCard:) -> CGFloat`
  - `static func layout(root:cardSize:pinned:) -> DeskCanvasLayout`
  - `private static func subtreeWidth(_:cardSize:pinned:)`, `private static func packedSpan(_:cardSize:pinned:)`,
    `private static func place(_:left:top:cardSize:pinned:placed:edges:)`

`macos/OmniAgentTests/DeskCanvasTests.swift` (new, 311 lines) — 11 tests, all green:
node sizing, left-to-right packing with parent centring, subtree-width packing (not node-width),
flipped-space level ordering, the empty-root content rect, 20-run determinism, pinned session
(siblings close the gap, parent re-centres over what it still packs), pinned workspace (subtree
follows, `root` packs as a leaf at the origin), `contentRect` as the union of every frame,
one edge per parent/child pair including pinned children, and whole-point origins under an
awkward card size (1207x813) with a half-point drop.

`macos/OmniAgent.xcodeproj/project.pbxproj` — the eight hand-written entries (four per file:
`PBXBuildFile`, `PBXFileReference`, target `PBXGroup` children, target `PBXSourcesBuildPhase` files),
tab-indented, inserted adjacent to the `PaneGrid.swift` / `PaneGridTests.swift` neighbours. Ids used
were the ones the plan generated and they were verified absent from the file first:
`B8FC09BF87F34E8E91515F5E`, `2CDF8CF2C82745FFABCED8D2`, `BE203811DF334A88BCEB06D8`, `515737526BA746E7B0775D9D`.
Registration was verified with `xcodebuild build-for-testing` while both files were still empty
(`** TEST BUILD SUCCEEDED **`), before any code depended on it.

## Deviations from the plan

None of substance. Two procedural differences:

1. The plan's shell snippets `cd` to the main repo path; every command was run in the worktree instead.
2. The plan's Step 9 commit command ends with `git push`. Per the task brief, nothing was pushed.

One expectation in the plan did not match reality and needed no action: Step 9 predicted the
`project.pbxproj` diff would also carry three foreign `CURRENT_PROJECT_VERSION = 44` lines from
`scripts/bump-build-version.sh`. This worktree was clean, so the diff is exactly the eight
`DeskCanvas` insertions and nothing else.

## What the next tasks need to know

- **The camera is NOT here.** `DeskCamera` and its members (`transform`, `canvasPoint(from:)`,
  `fitAll(content:in:)`, `focus(on:in:)`, `clamped(minScale:in:)`, `isIdentity`, `maxScale`) are
  Task 3's, appended to this same `DeskCanvas.swift`. **No new pbxproj entry is needed for that** —
  the file is already registered — and Task 3's cases append to the `DeskCanvasTests.swift` this
  task registered. Consume `DeskCanvas.fitMargin` from here; do not redeclare it.
- **Nothing here reads app state.** `layout(root:cardSize:pinned:)` takes the tree as an argument.
  The `PaneWorkspaceView.groupOrder → DeskNode` builder (`derivedCanvasRoot()`) belongs to Task 5.
- **Gap/chip constants live here.** Task 9 (chips) and anything needing spacing must read
  `DeskCanvas.chipSize(forCard:)`, `siblingGap(forCard:)`, `levelGap(forCard:)`,
  `DeskCanvas.lodThreshold` — do not hardcode 0.25 / 0.12 / 0.3 / 0.2 anywhere else.
- **A pinned entry's `CGPoint` is the node's frame ORIGIN** (top-left, flipped space), not an offset
  from an auto slot. Task 8's drag must store the dropped origin, and it may store a half-point value
  — `layout` rounds it.
- **Sizes are never rounded away from the card.** A session frame's `size` is always exactly the
  `cardSize` passed in; only origins are rounded. Task 5 can compare `canvasLayout.frames[group]!.size`
  against the viewport size safely.
- **`contentRect` is never `.null`** — it is `.zero` only if the tree somehow placed nothing, which
  cannot happen since the root is always placed. `fitAll` can divide by it.
- **Determinism is load-bearing and tested to 20 runs.** The walk touches no dictionary: `frames` is
  built from an ordered `placed` array and `contentRect` is folded in placement order. If a later task
  edits `place`/`layout`, do not start iterating `frames` to compute anything the layout returns.
- **Edge order** is depth-first, children in tree order, and pinned children keep their edge.

## Verification

- `xcodebuild build-for-testing` with both files empty: `** TEST BUILD SUCCEEDED **` (registration proven).
- `-only-testing:OmniAgentTests/DeskCanvasTests` before implementing: `cannot find 'DeskCanvas' in scope`,
  `** TEST BUILD FAILED **` (the test genuinely failed first).
- `-only-testing:OmniAgentTests/DeskCanvasTests` after: `Executed 11 tests, with 0 failures`.
- `caffeinate -disu ./macos/build.sh test`: **`Executed 867 tests, with 0 failures (0 unexpected)`**,
  no `Failing tests:` line, `** TEST SUCCEEDED **`.
- `./macos/build.sh build`: `** BUILD SUCCEEDED **`.

## Left undone / blockers

None. Every step of Task 2 is implemented, the suite is green, and no pre-existing failures were
observed in this worktree.
