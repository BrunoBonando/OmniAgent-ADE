# Task 4 — The `desk_canvas_native` settings row

Branch: `worktree-desk-canvas`. Commit: see below.

## What was built

**`macos/OmniAgent/DeskCanvasState.swift`** (new, registered in the app target):

- `struct DeskCanvasState: Equatable { var pinned: [String: CGPoint] = [:]; var camera: DeskCamera? }`.
  The `= [:]` default is the one additive deviation the plan sanctions — it is what makes
  `DeskCanvasState()` compile, which `deserialize`'s "corrupt row restores to the default" path
  needs. `DeskCanvasState(pinned:camera:)` still compiles unchanged.
- `enum DeskCanvasCodec` with `static let version = 1`, `static let maxNodeIDLength = 256`,
  `serialize(_:) -> String` and `deserialize(_:) -> DeskCanvasState`, plus four private helpers
  (`decodePoint`, `number`, `coordinate`, `quantizedScale`, `isValidNodeID`).

Wire format, byte-pinned by tests:
`{"camera":{"scale":0.5,"x":12,"y":-34},"pinned":{"root":{"x":0,"y":0},"session-g1":{"x":120,"y":-40}},"version":1}`

Repair contract, exactly as the plan specifies:

- `version != 1` → the whole row is discarded (a future build's shape is never half-read).
- A pin whose value is not `{x, y}` of finite in-range numbers → that node only.
- A node id that is empty, longer than `maxNodeIDLength`, or holds a control character → that node only.
- A camera with a non-finite or non-positive scale, or an unreadable origin → the camera only; pins survive.
- A scale above `DeskCamera.maxScale` → clamped, not dropped.
- Missing/empty/garbage raw → `DeskCanvasState()`.

Quantization is load-bearing, not cosmetic: `write(_:to:)`'s dedupe is *string* equality and this
row stores floats, so positions round to whole canvas points and scale to four places, with `-0.0`
folded onto `0.0` (`+ 0`). `.sortedKeys` matters more here than in either pane row because `pinned`
is a dictionary keyed by node id and its order is unstable by construction.

**`macos/OmniAgent/SettingsKeys.swift`**: one constant added directly under `editorPanes` —
`static let deskCanvas = "desk_canvas_native"`, with the neighbours' doc-comment voice.

**`macos/OmniAgentTests/DeskCanvasStateTests.swift`** (new, registered in the test target):
13 tests, verbatim from the plan — round trip, empty round trip, garbage-to-default, the version
gate, per-pin repair, per-camera repair, over-scale clamp, NaN drop, control-character/overlong id
drop, byte-exact sorted output, jitter stability, negative-zero, and `testSettingsKey`.

**`macos/OmniAgent.xcodeproj/project.pbxproj`**: eight hand-written entries (four per new file) —
`PBXBuildFile`, `PBXFileReference`, the group `children` id, and the target `Sources` `files` id.
The four object ids the plan pre-generated were re-confirmed absent before pasting and are the ones
used: `43DFECC6CB8F4285921E6A5A` / `371418F52B4143BE9B762348` (`DeskCanvasState.swift`) and
`E6B9FB15113B4C25B1F8D0BE` / `E2FE4A1FC6B7429A8E79A4F9` (`DeskCanvasStateTests.swift`).

## Deviations

- **None in the code.** The implementation is the plan's Step 6 body verbatim, and the tests are the
  Step 1 body verbatim.
- Process only: Step 3's "watch it fail" was run with an `import Foundation`-only stub at
  `macos/OmniAgent/DeskCanvasState.swift` so the registered build input existed. The failure was the
  predicted one — `cannot find 'DeskCanvasCodec' in scope`, `cannot find 'DeskCanvasState' in scope`,
  `type 'SettingsKey' has no member 'deskCanvas'`, and **no** `DeskCamera` error, confirming Task 3
  had landed and the order was right.
- Step 9's `git push` was deliberately not run (this branch is not pushed by task agents), and the
  commit was made in the worktree at `.claude/worktrees/desk-canvas`, not in the shared main tree.
- `WorkspaceWindowController.swift` and `WorkspaceWindowControllerTests.swift` are listed in this
  task's **Files** header but were **not touched**, per the task's own Step 8 scope boundary. They
  belong to Task 10e.

## Verification

- `xcodebuild -only-testing:OmniAgentTests/DeskCanvasStateTests` → `Executed 13 tests, with 0 failures`.
- `caffeinate -disu ./macos/build.sh test` → `Executed 887 tests, with 0 failures (0 unexpected)`,
  `** TEST SUCCEEDED **`. Task 3's report recorded 874; 874 + 13 = 887, exactly the tests added here.
  No pre-existing failures to report — the suite is fully green on this branch.

## What the next task needs to know

- **Task 10e owns every controller member for this row** — `deskCanvasReadDispatched` /
  `deskCanvasReadCompleted`, `restoreDeskCanvasIfNeeded()`, `applyRestoredDeskCanvas(_:)`,
  `persistDeskCanvas()`, and the hook into the `.connected` arm of `connection.onStateChange`. None
  of them exist yet; declaring them here as well would have been a redeclaration error.
- **There is no debounce.** `write(_:to:)`'s string-equality dedupe is the only throttle, which is
  precisely why the codec quantizes. A caller that serializes on every drag frame will still hit the
  settings writer once per *whole-point* change, not once per pixel of mouse movement — but it will
  hit it. If 10e wants fewer writes than that, the debounce is 10e's to add.
- `DeskCanvasCodec.serialize` never emits a `null` camera key: absence is the missing key. A reader
  must treat "no `camera`" as "no stored camera", not as an error.
- `maxNodeIDLength` is 256 and control characters are rejected, but **spaces and non-ASCII are
  allowed** — a workspace node id is a brain project id, which may legitimately hold both. Do not
  route node ids through `SessionIdentifier.isValid`.
- The camera clamp on read is only against `DeskCamera.maxScale` (the ceiling). There is no floor
  here, because the floor is `fitAll`, which depends on a layout that does not exist at read time.
  Whoever installs the restored camera must run it through `DeskCamera.clamped(minScale:in:)` after
  the first real layout — and note Task 3's warning that `fitAll` on an empty layout answers 1.0.

## Left undone

Nothing in this task's scope.
