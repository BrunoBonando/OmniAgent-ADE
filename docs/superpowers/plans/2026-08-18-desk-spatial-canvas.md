# Spatial Desk Canvas Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the native Desk into a zoomable spatial organigram of the running system — `You → Workspace → Sessions` — where each session is a card holding its real, live pane grid, and zooming into a card *is* entering that session.

**Architecture:** One view, one camera, real panes. `PaneWorkspaceView` already owns every session's grid (`grids: [String: PaneGrid]`, `activeGroup`); canvas mode is a second layout mode on it that lays out *every* group at its node rect instead of only the active one filling `bounds`. The camera is a single `CATransform3D` on `layer.sublayerTransform`, so container frames stay in canvas coordinates and nothing downstream learns about zoom. A session card is exactly the size of the Desk viewport, which is what makes "camera at scale 1.0 over this card" identical to "you are in this session".

**Tech Stack:** Swift 5, AppKit, Core Animation, SwiftTerm, XCTest. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-08-18-spatial-desk-canvas-design.md` — read its **revision note** first; the first draft argued from a premise that research disproved, and arguments from the pre-revision version are wrong.

## Global Constraints

These apply to **every** task in this plan. Read them once; the steps assume them.

**Naming — "Session" in UI strings, `group` in code.** From the spec's §Naming: *"The daemon and the Swift code call one PTY/pane a 'session' (`sessionID`, `MAX_SESSIONS`). The user-facing 'Session' is a group of those, and the existing code already uses `group` / `groupID` / `activeGroup` for it."* So a menu item reads "Next Session", the property it drives is `group: String`. Two consequences to honour rather than fix:

- `AppDelegate.swift`'s `ApplicationMenus.install()` already builds a top-level `NSMenu(title: "Session")` whose items are *per-pane PTY verbs* (Interrupt ⌘., Kill Session ⌃⌘K, Reattach ⌘R). **Do not rename it.** `WorkspaceWindowControllerTests.swift` looks that menu up by title (`.item(withTitle: "Session")?…item(withTitle: "Use Option as Meta")`), and renaming is unrelated churn. Every new canvas command goes in a **new top-level `Desk` menu**, named after the destination it belongs to.
- `PaneWorkspaceView.enterSession(_ group: String)` (Task 6) and the controller's menu action must not share an Objective-C selector. The controller's action is therefore `enterFocusedSession(_:)`, never `enterSession(_:)`.

**One name per piece of canvas state.** These are fixed here so no two tasks invent their own. All are on `PaneWorkspaceView`:

| Name | Type | Owner | Meaning |
|---|---|---|---|
| `canvasMode` | `Bool` | Task 5 | Lay out every group at its node rect, rather than `activeGroup` filling `bounds`. True for the whole Desk destination, **including while inside a session**. |
| `camera` | `DeskCamera` | Task 5 | scale + origin, applied as `layer.sublayerTransform`. Authoritative for "am I on the canvas or in a session" — at `isIdentity` over a card you are in it. |
| `canvasRoot` | `DeskNode?` | Task 5 | The tree to lay out. `nil` means derive it from `groupOrder` via `derivedCanvasRoot()`. |
| `canvasPins` | `[String: CGPoint]` | Task 8 | Node id → dragged position. A pinned node is excluded from packing. |
| `canvasLayout` | `DeskCanvasLayout?` | Task 5 | The last layout pass's result. `private(set)`; every other task reads it, none re-declares it. |
| `canvasRect(forGroup:)` | `(String) -> CGRect?` | Task 7 | `canvasLayout?.frames[group]`. The one lookup from a group id to its card. |

**A node id *is* the thing it names.** A session node's `id` is its **group id**; a workspace node's `id` is its **project id**; the root's id is `"root"`. There is deliberately no prefixing scheme and no node-id↔group-id join table: `canvasLayout.frames[group]` is a card rect directly. Every collection in `PaneWorkspaceView` is keyed by group id, and a second keying convention is how those collections drift apart.

**Anchor by symbol, never by line number.** `PaneWorkspaceView.swift` is ~3,800 lines and growing and this working tree is shared by concurrent Claude sessions. This is not theoretical: while this plan was being written, `macos/OmniAgent/CommandPalette.swift` and `macos/OmniAgentTests/CommandPaletteTests.swift` were both modified by another session at 20:43 on 2026-08-18 — the pane row title changed from `"Switch to alpha — Build — migrate"` to `"migrate — alpha · Build"` between two reads minutes apart. **Re-read every file immediately before editing it**, and treat any literal array of ids or titles quoted in this plan as "what it was at planning time", not as ground truth.

**Never `git stash` in this worktree.** Concurrent sessions share it; a stash eats their work.

**Check mtimes before staging.** `stat -f "%Sm %N" <files>` before `git add`, and stage explicit paths — never `git add -A` / `git add .`. If a file you did not touch is dirty, leave it out of your commit.

**Flipped coordinates.** `PaneWorkspaceView.isFlipped` returns `true`; the window is not flipped. Canvas node positions, `DeskCanvasLayout.frames`, and `DeskCamera.origin` are all defined in the view's own flipped space (y grows downward). `PaneDividerView.mouseDragged` already depends on this.

**Animation mechanics — three rules, each with a recorded reason in the file.**

1. Raw `CAAnimation`, never `NSView.animator()`. `place`'s comment: *"Deliberately not `NSView.animator()`, which is what this used to be… The animator wraps each group's frame change in an `_NSWindowTransformAnimation`, and instrumenting the transitions showed two of those alive on one view whenever a second transition began inside the first's 0.32s."*
2. Completions are scheduled with `DispatchQueue.main.asyncAfter` and guarded by a token — never an animation group's completion block. `setZoomed`'s comment: *"an animation group's completion is not guaranteed to arrive at all… True of the windowless tests, and of a window closed from under a card."* Anything that must happen when a camera fly lands (the identity snap) follows this or it hangs in the test suite.
3. Remove animations **by key**. `landCard`'s comment: *"By key rather than `removeAllAnimations()`: these two are the only ones this code adds, and yanking whatever else a layer happens to be running is how you break something you did not write."*

**Every new `.swift` file needs four hand-written `project.pbxproj` entries** (the project has no file-system-synchronized groups): a `PBXBuildFile` line, a `PBXFileReference` line, the file-ref id in the target's `PBXGroup` `children`, and the build-file id in that target's `PBXSourcesBuildPhase` `files`. Indentation is two tab characters. Ids: `uuidgen | tr -d '-' | cut -c1-24 | tr 'a-f' 'A-F'`. Verify with `./macos/build.sh build` before writing code that depends on the registration.

**Test names are full sentences in CamelCase**, no underscores, no "Should" — `func testTheDeskDestinationLoadsTheCanvasAndLeavingItUnloadsIt()`. Every non-obvious test carries a `///` comment saying which failure mode it exists to catch. XCTest only; there is no Swift Testing anywhere in `macos/`.

---

### Task 1: Close the SessionOutline gap

**Files:**
- Modify: `macos/OmniAgent/SessionOutline.swift` (inside `enum SessionOutline`, immediately after `nextSessionName(_:project:)` and before `defaultPaneName(_:_:)` — anchor by those symbol names, the file is under concurrent edit)
- Test: `macos/OmniAgentTests/SessionOutlineTests.swift` (extend the existing `SessionOutlineTests` class and its private `pane(...)` factory)

**No pbxproj edit is needed for this task.** `SessionOutlineTests.swift` is already registered with all four entries — `PBXBuildFile 10000000000000000000001C`, `PBXFileReference 20000000000000000000001D`, the `OmniAgentTests` group membership, and the test target's `PBXSourcesBuildPhase 800000000000000000000002`. Verified in `macos/OmniAgent.xcodeproj/project.pbxproj`. Do **not** create a new test file, and do **not** create `macos/OmniAgent/SessionGroups.swift` — `SessionOutline.swift`'s own header already says *"A direct port of `ui/src/state/sessionGroups.ts`"*, and a second file would duplicate `SessionOutline.group`.

**Interfaces:**

- Consumes (existing, verified in the working tree):
  - `struct PaneDescriptor: Equatable` with `let sessionID: String`, `var group: String` (**non-optional**), `var groupLabel: String?`, `var title: String`, `var project: String`, `var engine: Engine`, `var cwd: String`, `var label: String?`, `var themeId: TerminalThemeId?`, `var autoNumber: Int`, `var kind: PaneKind`, `var browserURL: String`, `var editorTabs: [PersistedEditorTab]`, `var editorActiveIndex: Int` — `macos/OmniAgent/PaneWorkspaceView.swift`
  - `init(sessionID:group:groupLabel:title:project:engine:cwd:label:themeId:kind:browserURL:editorTabs:editorActiveIndex:)` — same file, every parameter after `group` defaulted
  - `static func group(_ panes: [PaneDescriptor], focusedPaneID: String?) -> [ProjectSessionsNode]`
  - `struct SessionGroupNode: Equatable { let id: String; let project: String; let name: String?; let label: String; let cwd: String; let paneIDs: [String]; let isCurrent: Bool }`
  - `struct ProjectSessionsNode: Equatable { let project: String; let sessions: [SessionGroupNode] }`
  - `static func nextSessionName(_ panes: [PaneDescriptor], project: String) -> String`
  - `static func newSessionGroupID(now: Date = Date()) -> String`
  - `static let ungroupedSessionID = "__ungrouped__"` — `macos/OmniAgent/WorkspaceRestoration.swift`
  - `enum SessionIdentifier { static let maxLength = 96; static func isValid(_ value: String) -> Bool }` — `macos/OmniAgent/PersistedLayout.swift`
  - `enum Engine: String, Codable, CaseIterable, Equatable { case claude, codex, shell, copilot, antigravity }` — `macos/OmniAgent/PersistedLayout.swift`
  - `enum PaneKind: String, Equatable { case terminal, browser, editor }` — `macos/OmniAgent/PaneContentView.swift`

- Produces (the shared API, verbatim; later tasks depend on exactly these):
  - `static func visibleSessionGroupID(_ panes: [PaneDescriptor], project: String, focusedPaneID: String?) -> String?`
  - `static func currentSessionGroupID(_ panes: [PaneDescriptor], focusedPaneID: String?) -> String?`
  - `static func adjacentSessionTab(_ panes: [PaneDescriptor], project: String, focusedPaneID: String?, offset: Int) -> PaneDescriptor?`
  - `static func sessionEngineBreakdown(_ panes: [PaneDescriptor], group: String) -> [(engine: Engine, count: Int)]`
  - Test-file-local, defined inside this task: the widened fixture factory `private func pane(_ id: String, project: String, group: String, groupLabel: String? = nil, cwd: String = "/", label: String? = nil, engine: Engine = .shell, kind: PaneKind = .terminal) -> PaneDescriptor`

**This task adds pure functions and their tests only. It rewires no caller.** `WorkspaceWindowController`'s `onNewTerminal` / `onNewBrowser` / `onNewEditor` handlers currently resolve their target session with the *current* rule (`SessionOutline.group(...).flatMap(\.sessions).first(where: \.isCurrent)`) where the oracle says the *visible* rule belongs; that reconciliation is a separate change and is deliberately out of scope here.

---

**Why these four, and the three things that are easy to get wrong**

**1. "visible" is not "current", and merging them re-introduces a bug the web build already fixed.**
`currentSessionGroupID` is the strict question: *which group holds the focused pane*. It answers `nil` whenever nothing is focused or the focus id names no live pane. `visibleSessionGroupID` is the rendering / join-target question: *which session should this project put on screen*. They differ because **selecting a workspace in the sidebar deliberately does not move focus**, so `focusedPaneID` routinely belongs to a pane in a *different* project than the one being rendered. `currentSessionGroupID` answers `nil` there, and a canvas card (or a grid) showing nothing at all is a worse answer than showing the session the eye lands on anyway.

`visibleSessionGroupID`'s two-step fallback, in order:
1. the focused pane's group — **but only if that pane's `project == project`**;
2. otherwise the project's **first-seen** pane's group (first-seen order is the topmost sidebar row);
3. `nil` only when the project genuinely has no panes at all.

A **stale** `focusedPaneID` (its pane closed underneath) falls through step 1 into step 2, never blanking. Step 1's agreement with `group(_:focusedPaneID:)`'s `isCurrent` is by construction, and one test pins it, because the grid pointing at one session while the sidebar's accent rail points at another is the failure mode.

The `nil` in step 3 is load-bearing for the caller: it is what makes `existingGroup ?? SessionOutline.newSessionGroupID()` correct. The retired web twin `sessionGroupForNewPane` fell back to the project's *most recently created* session instead of the first-seen one, and its doc records the consequence — *"the 'New terminal' row could be drawn under Session 1 and spawn into Session 2."* Do not reintroduce that fallback.

**2. `adjacentSessionTab`'s end behaviour is JS index semantics, and Swift traps where JS shrugs.** The oracle is one line:

```ts
return sessions[(currentIndex === -1 ? 0 : currentIndex) + offset]?.tabs[0] ?? null;
```

Two separate behaviours ride on that:
- `currentIndex === -1` (no session in *this project* is current — focus is elsewhere, or nowhere) **starts from index 0**. So `offset: +1` lands on the project's **second** session, and `offset: -1` computes index `-1`.
- index `-1` and index `>= count` are both `undefined` in JS, the `?.` short-circuits, and the result is `null`. **There is no wrapping at either end.**

In Swift `sessions[-1]` and `sessions[count]` trap at runtime. The port must guard with `sessions.indices.contains(target)` — that guard *is* the "no wrapping" behaviour, not a defensive extra. Both ends get their own test, plus a large-offset test so the guard cannot be replaced by a `max(0,)`/`min(count-1,)` clamp without turning red.

It also returns the target session's **first** pane, not its focused one — `paneIDs.first`, mapped back to a `PaneDescriptor` because `SessionGroupNode` carries only ids.

**3. `sessionEngineBreakdown` cannot take a `SessionGroupNode`.** The oracle's signature is `(session: SessionGroup)` and reads `session.tabs`, whole `TabInfo` objects. The Swift `SessionGroupNode` carries `paneIDs: [String]` and nothing else, so it physically cannot answer the question. Hence the shared API's `(_ panes: [PaneDescriptor], group: String)`: hand it the descriptors and the group id, exactly as `WorkspaceShell.reloadSessions` already keeps a `byID: [String: PaneDescriptor]` beside the tree.

Two further Swift-side notes on it: the return type `[(engine: Engine, count: Int)]` is a **tuple** array and tuples are not `Equatable`, so tests must compare `.map(\.engine)` and `.map(\.count)` separately — `XCTAssertEqual` on the whole array will not compile. And it scopes by group **only**, not project + group, per the fixed API; see the note in Step 16 for the one case where that matters.

**4. There is no `?? ungroupedSessionID` anywhere in these four functions, and adding one is dead code that hides the invariant.** `PaneDescriptor.group` is a **non-optional `String`** already holding the sentinel for pre-grouping panes. `WorkspaceRestoration` states it: *"Never `nil`: an ungrouped tab restores into `WorkspaceRestoration.ungroupedSessionID`, exactly as the web build's `tab.group ?? UNGROUPED_SESSION_ID` reads it."* The coalescing happens once, at the restore boundary. Every ported body below is a plain `==` comparison.

---

- [ ] **Step 1: Widen the test fixture factory (prep)**

The existing private factory at the bottom of `SessionOutlineTests` cannot express an engine or a pane kind, and two of the new cases need both. Widen it in place rather than adding a second factory — every existing call site passes its arguments by label, so appending two defaulted parameters keeps all of them compiling untouched.

In `macos/OmniAgentTests/SessionOutlineTests.swift`, replace the whole `private func pane(...)` at the end of the class with:

```swift
    private func pane(
        _ id: String,
        project: String,
        group: String,
        groupLabel: String? = nil,
        cwd: String = "/",
        label: String? = nil,
        engine: Engine = .shell,
        kind: PaneKind = .terminal
    ) -> PaneDescriptor {
        PaneDescriptor(
            sessionID: id,
            group: group,
            groupLabel: groupLabel,
            project: project,
            engine: engine,
            cwd: cwd,
            label: label,
            kind: kind
        )
    }
```

`PaneDescriptor.init` declares its parameters in the order `sessionID, group, groupLabel, title, project, engine, cwd, label, themeId, kind, …`; the call above skips `title` and `themeId` but keeps the rest in declaration order, which is what Swift requires.

Run: `xcodebuild test -project /Users/bonando/Documents/Bruno.Digital/OmniAgent-ADE/macos/OmniAgent.xcodeproj -scheme OmniAgent -destination "platform=macOS,arch=$(uname -m)" CODE_SIGNING_ALLOWED=NO -only-testing:OmniAgentTests/SessionOutlineTests`

Expected: `** TEST SUCCEEDED **`, all existing `SessionOutlineTests` cases green. (`./macos/build.sh test` cannot be used for a filtered run — it is `exec xcodebuild "$action" …` with a fixed argument list and forwards nothing.)

- [ ] **Step 2: Write the failing tests — `currentSessionGroupID`**

Ported oracle cases 10, 11, 12 from `ui/src/state/sessionGroups.test.ts`'s `describe("currentSessionGroupId")`. Add to `SessionOutlineTests`, after `testNothingIsCurrentWhenNoPaneHasFocus`:

```swift
    // MARK: - currentSessionGroupID — the strict "who has focus" answer
    // Ported from `describe("currentSessionGroupId")`.

    func testTheCurrentSessionIsTheOneHoldingTheFocusedPane() {
        let panes = [
            pane("a", project: "p1", group: "g1"),
            pane("b", project: "p1", group: "g2"),
        ]
        XCTAssertEqual(SessionOutline.currentSessionGroupID(panes, focusedPaneID: "b"), "g2")
    }

    func testTheCurrentSessionIsTheImplicitOneForAFocusedPreGroupingPane() {
        let panes = [pane("a", project: "p1", group: WorkspaceRestoration.ungroupedSessionID)]
        XCTAssertEqual(
            SessionOutline.currentSessionGroupID(panes, focusedPaneID: "a"),
            WorkspaceRestoration.ungroupedSessionID,
            "a pane with no stored group already carries the sentinel — resolved once at the restore boundary"
        )
    }

    func testThereIsNoCurrentSessionWithNothingFocusedOrAStaleFocusID() {
        let panes = [pane("a", project: "p1", group: "g1")]
        XCTAssertNil(SessionOutline.currentSessionGroupID(panes, focusedPaneID: nil))
        XCTAssertNil(
            SessionOutline.currentSessionGroupID(panes, focusedPaneID: "ghost"),
            "a focus id naming no live pane is not a session — that is what visibleSessionGroupID falls back for"
        )
    }
```

- [ ] **Step 3: Run it and watch it fail**

Run: `xcodebuild test -project /Users/bonando/Documents/Bruno.Digital/OmniAgent-ADE/macos/OmniAgent.xcodeproj -scheme OmniAgent -destination "platform=macOS,arch=$(uname -m)" CODE_SIGNING_ALLOWED=NO -only-testing:OmniAgentTests/SessionOutlineTests`

Expected: a compile failure, not a test failure —
`SessionOutlineTests.swift:…: error: type 'SessionOutline' has no member 'currentSessionGroupID'` (three occurrences), ending in `** TEST BUILD FAILED **`.

- [ ] **Step 4: Implement `currentSessionGroupID`**

In `macos/OmniAgent/SessionOutline.swift`, inside `enum SessionOutline`, immediately after `nextSessionName(_:project:)`:

```swift
    /// The session the user is currently on — the group holding the focused
    /// pane. `nil` when nothing is focused, and `nil` when the focused id
    /// names no live pane (a stale focus).
    ///
    /// The strict "who has focus" answer. What is on *screen* — and what a
    /// new pane joins — is `visibleSessionGroupID`, which falls back exactly
    /// where this returns `nil`. Port of `currentSessionGroupId`.
    ///
    /// No `?? ungroupedSessionID` here, deliberately: `PaneDescriptor.group`
    /// is non-optional and a pre-grouping pane already carries the sentinel,
    /// resolved once at the restore boundary.
    static func currentSessionGroupID(_ panes: [PaneDescriptor], focusedPaneID: String?) -> String? {
        guard let focusedPaneID else { return nil }
        return panes.first { $0.sessionID == focusedPaneID }?.group
    }
```

- [ ] **Step 5: Run the tests**

Run: `xcodebuild test -project /Users/bonando/Documents/Bruno.Digital/OmniAgent-ADE/macos/OmniAgent.xcodeproj -scheme OmniAgent -destination "platform=macOS,arch=$(uname -m)" CODE_SIGNING_ALLOWED=NO -only-testing:OmniAgentTests/SessionOutlineTests`

Expected: PASS — `** TEST SUCCEEDED **`.

- [ ] **Step 6: Write the failing tests — `visibleSessionGroupID`**

All eight oracle cases from `describe("visibleSessionGroupId — which session the pane grid puts on screen")` (31–38). Add after the `currentSessionGroupID` block:

```swift
    // MARK: - visibleSessionGroupID — which session this project puts on screen
    // Ported from `describe("visibleSessionGroupId")`.

    func testTheVisibleSessionIsTheFocusedPanesWhenTheFocusedPaneIsInThisProject() {
        let panes = [
            pane("a", project: "p1", group: "g1"),
            pane("b", project: "p1", group: "g2"),
        ]
        XCTAssertEqual(SessionOutline.visibleSessionGroupID(panes, project: "p1", focusedPaneID: "b"), "g2")
    }

    /// Selecting a workspace in the sidebar does not move focus, so the
    /// focused pane routinely belongs to a different project than the one
    /// being rendered. The topmost session is the one the eye lands on.
    func testTheVisibleSessionFallsBackToTheProjectsFirstWhenFocusIsInAnotherProject() {
        let panes = [
            pane("a", project: "p1", group: "g1"),
            pane("b", project: "p1", group: "g2"),
            pane("c", project: "p2", group: "g3"),
        ]
        XCTAssertEqual(SessionOutline.visibleSessionGroupID(panes, project: "p1", focusedPaneID: "c"), "g1")
        XCTAssertEqual(
            SessionOutline.currentSessionGroupID(panes, focusedPaneID: "c"),
            "g3",
            "the strict answer here is g3 — the two questions really do differ"
        )
    }

    func testTheVisibleSessionFallsBackToTheProjectsFirstWhenNothingIsFocused() {
        let panes = [
            pane("a", project: "p1", group: "g1"),
            pane("b", project: "p1", group: "g2"),
        ]
        XCTAssertEqual(SessionOutline.visibleSessionGroupID(panes, project: "p1", focusedPaneID: nil), "g1")
    }

    func testThereIsNoVisibleSessionForAProjectWithNoPanes() {
        let panes = [pane("a", project: "p1", group: "g1")]
        XCTAssertNil(SessionOutline.visibleSessionGroupID(panes, project: "p2", focusedPaneID: "a"))
    }

    /// It is also the JOIN target for a new pane: `nil` means "this project
    /// has no panes at all", which is what makes the caller's
    /// `existingGroup ?? SessionOutline.newSessionGroupID()` correct.
    func testTheVisibleSessionIsNilOnAnEmptyProjectSoTheCallerMintsAFreshGroup() {
        XCTAssertNil(SessionOutline.visibleSessionGroupID([pane("z", project: "p2", group: "g9")], project: "p1", focusedPaneID: "z"))
        XCTAssertNil(SessionOutline.visibleSessionGroupID([], project: "p1", focusedPaneID: nil))
    }

    func testTheVisibleSessionIsTheImplicitOneForPreGroupingPanes() {
        let panes = [
            pane("a", project: "p1", group: WorkspaceRestoration.ungroupedSessionID),
            pane("b", project: "p1", group: WorkspaceRestoration.ungroupedSessionID),
        ]
        XCTAssertEqual(
            SessionOutline.visibleSessionGroupID(panes, project: "p1", focusedPaneID: "b"),
            WorkspaceRestoration.ungroupedSessionID
        )
        XCTAssertEqual(
            SessionOutline.visibleSessionGroupID(panes, project: "p1", focusedPaneID: nil),
            WorkspaceRestoration.ungroupedSessionID
        )
    }

    func testTheVisibleSessionSurvivesAStaleFocusIDRatherThanBlankingTheGrid() {
        let panes = [
            pane("a", project: "p1", group: "g1"),
            pane("b", project: "p1", group: "g2"),
        ]
        XCTAssertEqual(SessionOutline.visibleSessionGroupID(panes, project: "p1", focusedPaneID: "gone"), "g1")
    }

    /// The grid and the sidebar's accent rail must never point at different
    /// sessions, so the focused case has to agree with `group`'s `isCurrent`
    /// by construction.
    func testTheVisibleSessionAgreesWithTheSessionTheOutlineMarksCurrent() throws {
        let panes = [
            pane("a", project: "p1", group: "g1"),
            pane("b", project: "p1", group: "g2"),
        ]
        let visible = SessionOutline.visibleSessionGroupID(panes, project: "p1", focusedPaneID: "b")
        let marked = try XCTUnwrap(
            SessionOutline.group(panes, focusedPaneID: "b")
                .first { $0.project == "p1" }?
                .sessions.first(where: \.isCurrent)?.id
        )
        XCTAssertEqual(visible, marked)
    }
```

Simplify the second test's sanity line if it reads awkwardly — replace it with the direct statement, which is what it means:

```swift
        XCTAssertEqual(
            SessionOutline.currentSessionGroupID(panes, focusedPaneID: "c"),
            "g3",
            "the strict answer here is g3 — the two questions really do differ, and that is the whole point"
        )
```

- [ ] **Step 7: Run it and watch it fail**

Run: `xcodebuild test -project /Users/bonando/Documents/Bruno.Digital/OmniAgent-ADE/macos/OmniAgent.xcodeproj -scheme OmniAgent -destination "platform=macOS,arch=$(uname -m)" CODE_SIGNING_ALLOWED=NO -only-testing:OmniAgentTests/SessionOutlineTests`

Expected: `SessionOutlineTests.swift:…: error: type 'SessionOutline' has no member 'visibleSessionGroupID'`, `** TEST BUILD FAILED **`.

- [ ] **Step 8: Implement `visibleSessionGroupID`**

In `macos/OmniAgent/SessionOutline.swift`, directly after `currentSessionGroupID`:

```swift
    /// Which session's panes this project actually puts **on screen** — and
    /// the session a newly opened single pane JOINS. Port of
    /// `visibleSessionGroupId`.
    ///
    /// The rule, and why it is not just `currentSessionGroupID`:
    ///
    /// - **The focused pane's session**, when the focused pane is in this
    ///   project. This agrees with `group`'s `isCurrent` by construction, so
    ///   the grid and the sidebar's accent rail can never point at different
    ///   sessions.
    /// - **Otherwise the project's first session** (first-seen order = the
    ///   topmost row in the sidebar). Selecting a workspace deliberately does
    ///   *not* move focus, so `focusedPaneID` routinely belongs to a
    ///   different project than the one being rendered;
    ///   `currentSessionGroupID` answers `nil` there, and showing nothing at
    ///   all would be a worse answer than showing the session the eye lands
    ///   on anyway. A stale `focusedPaneID` lands here too, rather than
    ///   blanking.
    /// - **`nil`** only when the project genuinely has no panes — the caller
    ///   then renders its empty state, or mints a group with
    ///   `existingGroup ?? newSessionGroupID()`.
    ///
    /// This absorbed a near-twin, `sessionGroupForNewPane`, identical except
    /// that its no-focus-in-this-project fallback picked the project's
    /// *most-recently-created* session instead of the first-seen one — which
    /// is how "the 'New terminal' row could be drawn under Session 1 and
    /// spawn into Session 2". One question, one answer: a new pane joins the
    /// session you are looking at.
    static func visibleSessionGroupID(
        _ panes: [PaneDescriptor],
        project: String,
        focusedPaneID: String?
    ) -> String? {
        let focused = focusedPaneID.flatMap { id in panes.first { $0.sessionID == id } }
        if let focused, focused.project == project { return focused.group }
        return panes.first { $0.project == project }?.group
    }
```

- [ ] **Step 9: Run the tests**

Run: `xcodebuild test -project /Users/bonando/Documents/Bruno.Digital/OmniAgent-ADE/macos/OmniAgent.xcodeproj -scheme OmniAgent -destination "platform=macOS,arch=$(uname -m)" CODE_SIGNING_ALLOWED=NO -only-testing:OmniAgentTests/SessionOutlineTests`

Expected: PASS — `** TEST SUCCEEDED **`.

- [ ] **Step 10: Write the failing tests — `adjacentSessionTab`, both ends**

Oracle cases 13–16, plus one Swift-only case that pins the index guard. Add after the `visibleSessionGroupID` block. Note the shared fixture: `p1` holds `g1` (`first`), `g2` (`second`, `second-pane`), `g3` (`third`), in that order.

```swift
    // MARK: - adjacentSessionTab — stepping sideways between sessions
    // Ported from `describe("adjacentSessionTab")`. The oracle is one line
    // whose end behaviour is entirely JS out-of-range indexing:
    //   sessions[(currentIndex === -1 ? 0 : currentIndex) + offset]?.tabs[0] ?? null
    // Index -1 and index >= count are both `undefined` there and both trap
    // in Swift, so the port guards explicitly and never wraps.

    private var steppingFixture: [PaneDescriptor] {
        [
            pane("first", project: "p1", group: "g1"),
            pane("second", project: "p1", group: "g2"),
            pane("second-pane", project: "p1", group: "g2"),
            pane("third", project: "p1", group: "g3"),
        ]
    }

    func testSteppingForwardLandsOnTheFirstPaneOfTheNextSession() {
        XCTAssertEqual(
            SessionOutline.adjacentSessionTab(steppingFixture, project: "p1", focusedPaneID: "second-pane", offset: 1)?.sessionID,
            "third",
            "the next session's FIRST pane, not its focused one"
        )
    }

    func testSteppingBackLandsOnTheFirstPaneOfThePreviousSession() {
        XCTAssertEqual(
            SessionOutline.adjacentSessionTab(steppingFixture, project: "p1", focusedPaneID: "second", offset: -1)?.sessionID,
            "first"
        )
    }

    func testSteppingStopsAtBothOuterSessionBoundariesWithoutWrapping() {
        XCTAssertNil(
            SessionOutline.adjacentSessionTab(steppingFixture, project: "p1", focusedPaneID: "first", offset: -1),
            "index -1 is nil, not the last session"
        )
        XCTAssertNil(
            SessionOutline.adjacentSessionTab(steppingFixture, project: "p1", focusedPaneID: "third", offset: 1),
            "index == count is nil, not the first session"
        )
    }

    /// The guard is the behaviour, not a defensive extra: a clamp into
    /// `0..<count` would make both of these return a session instead of nil.
    func testSteppingByALargeOffsetIsNilRatherThanAClampOrATrap() {
        XCTAssertNil(SessionOutline.adjacentSessionTab(steppingFixture, project: "p1", focusedPaneID: "second", offset: -5))
        XCTAssertNil(SessionOutline.adjacentSessionTab(steppingFixture, project: "p1", focusedPaneID: "second", offset: 5))
        XCTAssertNil(
            SessionOutline.adjacentSessionTab([], project: "p1", focusedPaneID: nil, offset: 1),
            "and an empty project steps nowhere"
        )
    }

    /// No session in this project is current, so the walk starts from index
    /// 0 — offset +1 is therefore the project's SECOND session, and offset
    /// -1 computes index -1 and is nil.
    func testSteppingStartsFromTheFirstSessionWhenFocusIsOutsideTheProject() {
        let panes = steppingFixture + [pane("other", project: "p2", group: "g4")]
        XCTAssertEqual(
            SessionOutline.adjacentSessionTab(panes, project: "p1", focusedPaneID: "other", offset: 1)?.sessionID,
            "second"
        )
        XCTAssertNil(SessionOutline.adjacentSessionTab(panes, project: "p1", focusedPaneID: "other", offset: -1))
    }
```

- [ ] **Step 11: Run it and watch it fail**

Run: `xcodebuild test -project /Users/bonando/Documents/Bruno.Digital/OmniAgent-ADE/macos/OmniAgent.xcodeproj -scheme OmniAgent -destination "platform=macOS,arch=$(uname -m)" CODE_SIGNING_ALLOWED=NO -only-testing:OmniAgentTests/SessionOutlineTests`

Expected: `SessionOutlineTests.swift:…: error: type 'SessionOutline' has no member 'adjacentSessionTab'`, `** TEST BUILD FAILED **`.

- [ ] **Step 12: Implement `adjacentSessionTab`**

In `macos/OmniAgent/SessionOutline.swift`, directly after `visibleSessionGroupID`:

```swift
    /// The first pane of the adjacent session in `project`, or `nil` at a
    /// project boundary. Port of `adjacentSessionTab` — what session
    /// stepping (`⌃1…⌃9`-style, and the canvas's "fly sideways") walks.
    ///
    /// Two behaviours ride on the oracle's single line
    /// (`sessions[(currentIndex === -1 ? 0 : currentIndex) + offset]?.tabs[0] ?? null`):
    ///
    /// - **No current session in this project** — focus is elsewhere, or
    ///   nowhere — starts the walk from index 0. So `offset: 1` lands on the
    ///   project's *second* session and `offset: -1` computes index -1.
    /// - **Index -1 and index >= count are both `nil`, with no wrapping.**
    ///   JS reads those as `undefined` and short-circuits; Swift traps, so
    ///   the `indices.contains` guard below *is* the end behaviour rather
    ///   than a defensive extra.
    ///
    /// Returns the target session's **first** pane, not its focused one.
    static func adjacentSessionTab(
        _ panes: [PaneDescriptor],
        project: String,
        focusedPaneID: String?,
        offset: Int
    ) -> PaneDescriptor? {
        let sessions = group(panes, focusedPaneID: focusedPaneID)
            .first { $0.project == project }?
            .sessions ?? []
        let currentIndex = sessions.firstIndex { $0.isCurrent } ?? -1
        let target = (currentIndex == -1 ? 0 : currentIndex) + offset
        guard sessions.indices.contains(target),
              let firstPaneID = sessions[target].paneIDs.first
        else { return nil }
        return panes.first { $0.sessionID == firstPaneID }
    }
```

- [ ] **Step 13: Run the tests**

Run: `xcodebuild test -project /Users/bonando/Documents/Bruno.Digital/OmniAgent-ADE/macos/OmniAgent.xcodeproj -scheme OmniAgent -destination "platform=macOS,arch=$(uname -m)" CODE_SIGNING_ALLOWED=NO -only-testing:OmniAgentTests/SessionOutlineTests`

Expected: PASS — `** TEST SUCCEEDED **`.

- [ ] **Step 14: Write the failing tests — `sessionEngineBreakdown`**

Oracle case 30, plus two native cases the oracle cannot express. Add after the `adjacentSessionTab` block.

The return type is a tuple array, and **tuples are not `Equatable`** — `XCTAssertEqual(breakdown, [(engine: .claude, count: 2)])` will not compile. Compare the two projections instead.

```swift
    // MARK: - sessionEngineBreakdown — which engines are running in a session
    // Ported from `describe("sessionEngineBreakdown")`. The oracle takes a
    // `SessionGroup` and reads `session.tabs`; `SessionGroupNode` carries
    // only `paneIDs`, so the Swift signature takes the descriptors and the
    // group id instead.

    func testTheEngineBreakdownCountsEachEngineOnceInFirstSeenOrderWithItsOwnTally() {
        let panes = [
            pane("a", project: "p1", group: "g1", engine: .claude),
            pane("b", project: "p1", group: "g1", engine: .shell),
            pane("c", project: "p1", group: "g1", engine: .claude),
        ]
        let breakdown = SessionOutline.sessionEngineBreakdown(panes, group: "g1")
        // Tuples are not Equatable, so the two projections are compared
        // rather than the array itself.
        XCTAssertEqual(breakdown.map(\.engine), [.claude, .shell], "first-seen order, each engine once")
        XCTAssertEqual(breakdown.map(\.count), [2, 1])
    }

    func testTheEngineBreakdownCountsOnlyTheSessionItWasAskedAbout() {
        let panes = [
            pane("a", project: "p1", group: "g1", engine: .claude),
            pane("b", project: "p1", group: "g2", engine: .codex),
        ]
        XCTAssertEqual(SessionOutline.sessionEngineBreakdown(panes, group: "g2").map(\.engine), [.codex])
        XCTAssertTrue(
            SessionOutline.sessionEngineBreakdown(panes, group: "g-nothing").isEmpty,
            "a session with no panes has no engines"
        )
    }

    /// A browser or editor pane carries `.shell` as a placeholder, not as an
    /// identity — the same reason `nextPaneNumber` gives them their own
    /// ladder. Counting them would make a card claim a shell that is not
    /// running.
    func testTheEngineBreakdownIgnoresBrowserAndEditorPanesWhoseEngineIsAPlaceholder() {
        let panes = [
            pane("a", project: "p1", group: "g1", engine: .claude),
            pane("w", project: "p1", group: "g1", engine: .shell, kind: .browser),
            pane("e", project: "p1", group: "g1", engine: .shell, kind: .editor),
        ]
        let breakdown = SessionOutline.sessionEngineBreakdown(panes, group: "g1")
        XCTAssertEqual(breakdown.map(\.engine), [.claude])
        XCTAssertEqual(breakdown.map(\.count), [1])
    }
```

- [ ] **Step 15: Run it and watch it fail**

Run: `xcodebuild test -project /Users/bonando/Documents/Bruno.Digital/OmniAgent-ADE/macos/OmniAgent.xcodeproj -scheme OmniAgent -destination "platform=macOS,arch=$(uname -m)" CODE_SIGNING_ALLOWED=NO -only-testing:OmniAgentTests/SessionOutlineTests`

Expected: `SessionOutlineTests.swift:…: error: type 'SessionOutline' has no member 'sessionEngineBreakdown'`, `** TEST BUILD FAILED **`.

- [ ] **Step 16: Implement `sessionEngineBreakdown`**

In `macos/OmniAgent/SessionOutline.swift`, directly after `adjacentSessionTab`:

```swift
    /// Which engines are running in one session and how many terminals of
    /// each, in first-seen order — what the canvas's session chips and the
    /// hover card draw an engine-coloured dot per entry from. Port of
    /// `sessionEngineBreakdown`.
    ///
    /// Two deliberate divergences from the oracle:
    ///
    /// - **It takes the descriptors and a group id, not a session node.**
    ///   The oracle reads `session.tabs`, whole `TabInfo`s;
    ///   `SessionGroupNode` carries only `paneIDs`, so it physically cannot
    ///   answer this. Callers already keep the descriptors beside the tree.
    /// - **Only `.terminal` panes count.** A browser or editor pane carries
    ///   `.shell` as a placeholder, not as an identity — the same reason
    ///   `nextPaneNumber` gives them their own ladder — and counting one
    ///   would make the card claim a shell that is not running. The web
    ///   build has no pane kinds, so its oracle cannot express this.
    ///
    /// Scoped by group alone, matching how `PaneWorkspaceView.grids` is
    /// keyed. Real group ids are unique across projects
    /// (`sess-grp-<ms>-<counter>`); `WorkspaceRestoration.ungroupedSessionID`
    /// is shared by construction, so for that one id this merges the
    /// pre-grouping panes of every project. Pass project-scoped panes if
    /// that matters at the call site.
    ///
    /// Built from live panes, never from what a create dialog chose: a
    /// terminal closed afterwards must not leave the card claiming it is
    /// there.
    static func sessionEngineBreakdown(_ panes: [PaneDescriptor], group: String) -> [(engine: Engine, count: Int)] {
        var counts: [(engine: Engine, count: Int)] = []
        for pane in panes where pane.group == group && pane.kind == .terminal {
            if let index = counts.firstIndex(where: { $0.engine == pane.engine }) {
                counts[index].count += 1
            } else {
                counts.append((engine: pane.engine, count: 1))
            }
        }
        return counts
    }
```

- [ ] **Step 17: Run the tests**

Run: `xcodebuild test -project /Users/bonando/Documents/Bruno.Digital/OmniAgent-ADE/macos/OmniAgent.xcodeproj -scheme OmniAgent -destination "platform=macOS,arch=$(uname -m)" CODE_SIGNING_ALLOWED=NO -only-testing:OmniAgentTests/SessionOutlineTests`

Expected: PASS — `** TEST SUCCEEDED **`.

- [ ] **Step 18: Port the remaining oracle cases for the functions that already shipped**

`SessionOutlineTests` is headed *"Ported from `ui/src/state/sessionGroups.test.ts`"* but ten of that file's cases have no Swift counterpart, all of them for functions that already exist. These are **characterization** tests: no implementation follows, and they must pass on the first run. Add them at the end of the class, before the private `pane` factory.

```swift
    // MARK: - newSessionGroupID
    // Ported from `describe("newSessionGroupId")`. `SessionOutline`'s
    // `groupCounter` is a bare `private static var` that is never reset
    // between tests, so distinctness is the only thing that may be asserted
    // — never an absolute value.

    func testFiftySuccessiveSessionGroupIDsAreAllDistinct() {
        let ids = Set((0..<50).map { _ in SessionOutline.newSessionGroupID() })
        XCTAssertEqual(ids.count, 50)
    }

    /// A group id `SessionIdentifier.isValid` rejects is silently dropped by
    /// `PersistedLayoutCodec.serialize`, which would un-group every pane on
    /// the next launch.
    func testAMintedSessionGroupIDIsOneTheLayoutPersisterWillKeep() {
        XCTAssertTrue(SessionIdentifier.isValid(SessionOutline.newSessionGroupID()))
    }

    // MARK: - group — the oracle cases the existing port did not cover

    func testUnnamedSessionsAreNumberedPerProjectAndStoreNoName() {
        let tree = SessionOutline.group(
            [
                pane("a", project: "p1", group: "g1"),
                pane("b", project: "p1", group: "g2"),
                pane("c", project: "p2", group: "g9"),
            ],
            focusedPaneID: nil
        )
        XCTAssertEqual(tree[0].sessions.map(\.label), ["Session 1", "Session 2"])
        XCTAssertEqual(tree[1].sessions.map(\.label), ["Session 1"], "numbering restarts per project")
        XCTAssertEqual(
            tree[0].sessions.map(\.name),
            [nil, nil],
            "and nothing was stored — these are derived defaults"
        )
    }

    func testTwoSessionsEachCarryTheirOwnRoot() {
        let tree = SessionOutline.group(
            [
                pane("a", project: "p1", group: "g1", cwd: "/repo"),
                pane("b", project: "p1", group: "g1", cwd: "/repo/packages/api"),
                pane("c", project: "p1", group: "g2", cwd: "/repo/packages/web"),
            ],
            focusedPaneID: nil
        )
        XCTAssertEqual(tree[0].sessions.map(\.cwd), ["/repo", "/repo/packages/web"])
    }

    func testPreGroupingPanesCollectIntoOneImplicitSessionPerProject() {
        let tree = SessionOutline.group(
            [
                pane("a", project: "p1", group: WorkspaceRestoration.ungroupedSessionID),
                pane("b", project: "p1", group: WorkspaceRestoration.ungroupedSessionID),
                pane("c", project: "p2", group: WorkspaceRestoration.ungroupedSessionID),
            ],
            focusedPaneID: nil
        )
        XCTAssertEqual(tree[0].sessions.count, 1)
        XCTAssertEqual(tree[0].sessions[0].id, WorkspaceRestoration.ungroupedSessionID)
        XCTAssertEqual(tree[0].sessions[0].paneIDs, ["a", "b"])
        XCTAssertEqual(tree[1].sessions[0].id, WorkspaceRestoration.ungroupedSessionID)
    }

    func testNoPanesMakeAnEmptyTree() {
        XCTAssertTrue(SessionOutline.group([], focusedPaneID: nil).isEmpty)
    }

    /// The regression stored names exist to kill: labelling was positional
    /// at first — "the 2nd session in this project is Session 2" — which
    /// quietly renamed every session below one that closed.
    func testAStoredNameStaysStableWhenAnEarlierSessionCloses() {
        let all = [
            pane("a", project: "p1", group: "g1", groupLabel: "Session 1"),
            pane("b", project: "p1", group: "g2", groupLabel: "Session 2"),
        ]
        let afterClosingTheFirst = SessionOutline.group(Array(all.dropFirst()), focusedPaneID: nil)
        XCTAssertEqual(afterClosingTheFirst[0].sessions[0].label, "Session 2")
    }

    // MARK: - nextSessionName — the oracle cases the existing port did not cover

    func testTheNextSessionNameSkipsANumberTheUserTypedOntoASession() {
        let live = [
            pane("a", project: "p1", group: "g1", groupLabel: "Session 1"),
            pane("b", project: "p1", group: "g2", groupLabel: "Session 2"),
        ]
        XCTAssertEqual(SessionOutline.nextSessionName(live, project: "p1"), "Session 3")
    }

    /// "Taken" means the name a session *shows*, stored or derived, because
    /// the collision that matters is two rows reading the same.
    func testTheNextSessionNameSkipsDerivedNamesToo() {
        XCTAssertEqual(
            SessionOutline.nextSessionName([pane("a", project: "p1", group: "g1")], project: "p1"),
            "Session 2"
        )
    }

    func testANonNumericSessionNameOccupiesNoNumber() {
        XCTAssertEqual(
            SessionOutline.nextSessionName(
                [pane("a", project: "p1", group: "g1", groupLabel: "auth refactor")],
                project: "p1"
            ),
            "Session 1"
        )
    }
```

- [ ] **Step 19: Run them**

Run: `xcodebuild test -project /Users/bonando/Documents/Bruno.Digital/OmniAgent-ADE/macos/OmniAgent.xcodeproj -scheme OmniAgent -destination "platform=macOS,arch=$(uname -m)" CODE_SIGNING_ALLOWED=NO -only-testing:OmniAgentTests/SessionOutlineTests`

Expected: PASS — `** TEST SUCCEEDED **`. These pin behaviour that already shipped, so they are green on the first run by construction. **If one of them fails, the existing port has a real divergence from the TypeScript oracle: fix `SessionOutline`, never weaken the test.** The likeliest candidate is `testAStoredNameStaysStableWhenAnEarlierSessionCloses`, which is the one behaviour a naive positional-labelling refactor would break.

- [ ] **Step 20: Run the whole native suite**

Run: `./macos/build.sh test`

Expected: `** TEST SUCCEEDED **` for the entire `OmniAgentTests` bundle. Nothing outside `SessionOutline.swift` changed and no existing signature moved, so every other class stays green; a failure elsewhere means someone else's concurrent edit landed in the tree, not that this task broke it — check `git status` before assuming otherwise.

- [ ] **Step 21: Commit**

Stage by explicit path only. Concurrent Claude sessions share this working tree: `git add -A` would sweep in their in-flight work, and `git stash` would eat it. Check first that nothing else is mid-write:

```
git -C /Users/bonando/Documents/Bruno.Digital/OmniAgent-ADE status --porcelain
ls -l /Users/bonando/Documents/Bruno.Digital/OmniAgent-ADE/macos/OmniAgent/SessionOutline.swift \
      /Users/bonando/Documents/Bruno.Digital/OmniAgent-ADE/macos/OmniAgentTests/SessionOutlineTests.swift
```

Then:

```
git -C /Users/bonando/Documents/Bruno.Digital/OmniAgent-ADE add \
  macos/OmniAgent/SessionOutline.swift \
  macos/OmniAgentTests/SessionOutlineTests.swift

git -C /Users/bonando/Documents/Bruno.Digital/OmniAgent-ADE commit -m "$(cat <<'EOF'
feat(macos): finish the SessionOutline port — visible vs current, stepping, engines

The four functions `sessionGroups.ts` exports that had no native
counterpart, plus the ten oracle cases in `sessionGroups.test.ts` that
had none either.

- `currentSessionGroupID` — the strict "who has focus" answer; nil for
  nothing focused and nil for a stale focus id.
- `visibleSessionGroupID` — which session a project puts on screen, and
  the session a new pane joins. Not the same question: selecting a
  workspace deliberately does not move focus, so focus routinely belongs
  to another project, where the strict answer is nil and showing nothing
  would be worse than showing the topmost session. Its nil means "this
  project has no panes", which is what makes the caller's
  `existingGroup ?? newSessionGroupID()` correct.
- `adjacentSessionTab` — JS index semantics, ported honestly: no current
  session in this project starts the walk from 0, and index -1 or >=
  count is nil with no wrapping. `sessions[-1]` traps in Swift, so the
  `indices.contains` guard is the behaviour, not a defensive extra.
- `sessionEngineBreakdown` — takes descriptors and a group id, because
  `SessionGroupNode` carries only `paneIDs` and cannot answer this. Only
  `.terminal` panes count: a browser or editor carries `.shell` as a
  placeholder, not an identity.

No caller is rewired here. The `onNewTerminal`/`onNewBrowser`/
`onNewEditor` handlers still resolve their target with the *current*
rule where the oracle says *visible* belongs; that is a separate change.

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>
EOF
)"
```

Then push, per the standing rule that a commit here is followed by a push rather than a question about it:

```
git -C /Users/bonando/Documents/Bruno.Digital/OmniAgent-ADE push
```

---

### Task 1b: Route the three "new pane" rows through the visible session

Task 1 adds `visibleSessionGroupID` and stops. Nothing calls it, so the rule it encodes is not in effect anywhere — and there is a live bug waiting on exactly that rule.

`WorkspaceWindowController` wires all three sidebar rows the same way:

```swift
        shellSidebar.onNewTerminal = { [weak self] in
            guard let self else { return }
            let panes = self.workspace.allPaneIDs.compactMap { self.workspace.descriptor(for: $0) }
            let current = SessionOutline.group(panes, focusedPaneID: self.workspace.focusedPaneID)
                .flatMap(\.sessions)
                .first(where: \.isCurrent)
            guard let current else { return }
            self.newPane(in: current)
        }
```

That is the **current** rule — which session holds the focused pane — where the oracle says the **visible** rule belongs. Selecting a workspace in the sidebar deliberately does not move focus, so `focusedPaneID` routinely names a pane in a different project. `isCurrent` is then false for every session in the project being drawn, `guard let current else { return }` fires, and the row the user just clicked does nothing at all. No error, no feedback.

It matters more on the canvas, where several projects' sessions are on screen at once and "the session the eye is on" is never "the session holding focus".

**Files:**
- Modify: `macos/OmniAgent/WorkspaceWindowController.swift` (the `onNewTerminal`, `onNewBrowser`, `onNewEditor` closures, and a new `visibleSession()` helper beside them)
- Test: `macos/OmniAgentTests/WorkspaceWindowControllerTests.swift`

No pbxproj edit: both files are already registered.

**Interfaces:**

- Consumes:
  - `static func visibleSessionGroupID(_ panes: [PaneDescriptor], project: String, focusedPaneID: String?) -> String?` (Task 1)
  - `static func group(_ panes: [PaneDescriptor], focusedPaneID: String?) -> [ProjectSessionsNode]` (existing)
  - `private(set) var selectedProjectID: String?`, `func newPane(in session: SessionGroupNode?) -> Bool`, `func newBrowser(in session: SessionGroupNode?, url: String) -> Bool`, `func newEditor(in session: SessionGroupNode?) -> Bool` (existing, `WorkspaceWindowController`)
- Produces:
  - `private func visibleSession() -> SessionGroupNode?` on `WorkspaceWindowController`

- [ ] **Step 1: Write the failing test**

Add to `WorkspaceWindowControllerTests.swift`:

```swift
    /// Selecting a workspace does not move focus, so focus routinely belongs to
    /// another project. The "new terminal" row under a project must still add to
    /// that project — under the current rule it silently did nothing.
    func testNewTerminalAddsToTheVisibleSessionWhenFocusIsInAnotherProject() throws {
        let controller = makeController()
        controller.applyRestoredPanes([
            restored("alpha-1", project: "alpha", group: "grp-alpha"),
            restored("beta-1", project: "beta", group: "grp-beta"),
        ])
        controller.selectWorkspace(id: "alpha", animated: false)
        controller.workspace.focusPane("beta-1")

        let before = controller.workspace.allPaneIDs.count
        XCTAssertTrue(controller.newPaneInVisibleSessionForTesting())

        XCTAssertEqual(controller.workspace.allPaneIDs.count, before + 1, "the row did nothing")
        let added = try XCTUnwrap(
            controller.workspace.allPaneIDs
                .compactMap { controller.workspace.descriptor(for: $0) }
                .last
        )
        XCTAssertEqual(added.project, "alpha", "it joined the project on screen, not the one holding focus")
        XCTAssertEqual(added.group, "grp-alpha")
    }

    /// The visible rule agrees with the current rule whenever focus *is* in the
    /// project on screen — the change must not move panes that were landing
    /// correctly before.
    func testNewTerminalStillJoinsTheFocusedSessionWhenFocusIsInThisProject() throws {
        let controller = makeController()
        controller.applyRestoredPanes([
            restored("alpha-1", project: "alpha", group: "grp-one"),
            restored("alpha-2", project: "alpha", group: "grp-two"),
        ])
        controller.selectWorkspace(id: "alpha", animated: false)
        controller.workspace.focusPane("alpha-2")

        XCTAssertTrue(controller.newPaneInVisibleSessionForTesting())

        let added = try XCTUnwrap(
            controller.workspace.allPaneIDs
                .compactMap { controller.workspace.descriptor(for: $0) }
                .last
        )
        XCTAssertEqual(added.group, "grp-two", "focus is in this project, so its session still wins")
    }
```

If `makeController`, `restored(_:project:group:)` or `selectWorkspace(id:animated:)` are named differently in that file, run
`grep -n "func makeController\|func restored\|selectWorkspace" macos/OmniAgentTests/WorkspaceWindowControllerTests.swift`
and use the names it prints — do not add a second fixture factory.

- [ ] **Step 2: Add the test seam**

The three closures are set up in `init`, so a test cannot invoke them directly. Add to `WorkspaceWindowController`, beside the other `…ForTesting` members:

```swift
    @discardableResult
    func newPaneInVisibleSessionForTesting() -> Bool { newPane(in: visibleSession()) }
```

- [ ] **Step 3: Run it and watch it fail**

Run:
```
./macos/build.sh test 2>&1 | grep -E "error:|Executed"
```
Expected: compile failure — `value of type 'WorkspaceWindowController' has no member 'newPaneInVisibleSessionForTesting'`.

- [ ] **Step 4: Implement `visibleSession()`**

Add to `WorkspaceWindowController`, immediately above the `shellSidebar.onNewTerminal` wiring:

```swift
    /// The session a new pane should join: the one the project on screen is
    /// showing, not the one holding focus.
    ///
    /// Those are different answers more often than they look. Selecting a
    /// workspace in the sidebar deliberately does not move focus, so
    /// `focusedPaneID` routinely names a pane in another project;
    /// `SessionOutline.visibleSessionGroupID` falls back to the project's
    /// first-seen session there, where the strict "current" answer is `nil` and
    /// the row does nothing at all.
    ///
    /// `nil` only when the project genuinely has no panes — which is what makes
    /// the callers' `?? SessionOutline.newSessionGroupID()` correct rather than
    /// a swallowed failure.
    private func visibleSession() -> SessionGroupNode? {
        let panes = workspace.allPaneIDs.compactMap { workspace.descriptor(for: $0) }
        guard
            let project = selectedProjectID,
            let group = SessionOutline.visibleSessionGroupID(
                panes,
                project: project,
                focusedPaneID: workspace.focusedPaneID
            )
        else { return nil }
        return SessionOutline.group(panes, focusedPaneID: workspace.focusedPaneID)
            .first { $0.project == project }?
            .sessions
            .first { $0.id == group }
    }
```

- [ ] **Step 5: Rewrite the three closures**

Replace each of the three identical lookups with the helper. `onNewTerminal`:

```swift
        shellSidebar.onNewTerminal = { [weak self] in
            guard let self, let session = self.visibleSession() else { return }
            self.newPane(in: session)
        }
```

`onNewBrowser`:

```swift
        shellSidebar.onNewBrowser = { [weak self] in
            // The same visible-session lookup: the row lives under the session
            // it adds to, and that is the session on screen.
            guard let self, let session = self.visibleSession() else { return }
            self.newBrowser(in: session)
        }
```

`onNewEditor`:

```swift
        shellSidebar.onNewEditor = { [weak self] in
            // The same visible-session lookup the two rows above use.
            guard let self, let session = self.visibleSession() else { return }
            self.newEditor(in: session)
        }
```

- [ ] **Step 6: Run the two new tests**

Run:
```
./macos/build.sh test 2>&1 | grep -E "error:|Executed|VisibleSession"
```
Expected: PASS with `0 failures`.

- [ ] **Step 7: Run the whole suite**

Run:
```
./macos/build.sh test
```
Expected: `0 failures`, and the executed count higher than the run recorded at the start of this task by exactly the two tests added here. Quote the green `Executed N tests` line rather than trusting the summary — a launch can print a green total above a trailing `Failing tests:` list and still exit 65.

- [ ] **Step 8: Commit**

```bash
git add macos/OmniAgent/WorkspaceWindowController.swift macos/OmniAgentTests/WorkspaceWindowControllerTests.swift
git commit -m "$(cat <<'EOF'
fix(macos): new-pane rows join the visible session, not the focused one

All three sidebar rows resolved their target with the "current" rule --
which session holds the focused pane -- and bailed on nil. Selecting a
workspace deliberately does not move focus, so focusedPaneID routinely
names a pane in another project: isCurrent was false for every session in
the project being drawn, and the row the user just clicked did nothing,
with no error and no feedback.

Routes all three through SessionOutline.visibleSessionGroupID, which falls
back to the project's first-seen session in exactly that case. It matters
more on the canvas, where several projects are on screen at once and "the
session the eye is on" is never "the session holding focus".

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>
Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)" && git push
```

---

### Task 2: DeskCanvas node tree and tidy-tree layout

**Files:**
- Create: `macos/OmniAgent/DeskCanvas.swift`
- Create (test): `macos/OmniAgentTests/DeskCanvasTests.swift`
- Modify: `macos/OmniAgent.xcodeproj/project.pbxproj` (anchor by the four `PaneGrid.swift` / `PaneGridTests.swift` registration lines — never by line number; the file is under concurrent edit and `scripts/bump-build-version.sh` rewrites `CURRENT_PROJECT_VERSION` in it)

**Interfaces:**

- Consumes: nothing from any earlier task — this task is standalone value types and can be built first. It only mirrors two existing facts, both verified in the tree today:
  - `override var isFlipped: Bool { true }` — `macos/OmniAgent/PaneWorkspaceView.swift`, documented there as *"Row 0 on top, matching `PaneGrid.layout(in:dividerThickness:)`."*
  - `func layout(in bounds: CGRect, dividerThickness: CGFloat) -> PaneLayout` on `PaneGrid` — the house precedent for whole-point rounding: *"Edges are rounded to whole points and the last edge is pinned to the content extent, so the panes tile `bounds` exactly and no pane draws on a half-pixel."*

- Produces (from the fixed shared API, verbatim):
  - `struct DeskNode: Equatable` with `enum Kind: Equatable { case root; case workspace(String); case session(String) }`, `let id: String`, `let kind: Kind`, `let children: [DeskNode]` — implicit memberwise `DeskNode(id:kind:children:)`
  - `struct DeskEdge: Equatable` with `let from: String`, `let to: String` — implicit memberwise `DeskEdge(from:to:)`
  - `struct DeskCanvasLayout: Equatable` with `let frames: [String: CGRect]`, `let edges: [DeskEdge]`, `let contentRect: CGRect` — implicit memberwise `DeskCanvasLayout(frames:edges:contentRect:)`
  - `enum DeskCanvas`
  - `static let chipWidthFraction: CGFloat = 0.25`
  - `static let lodThreshold: CGFloat = 0.2`
  - `static let fitMargin: CGFloat = 0.2`
  - `static func layout(root: DeskNode, cardSize: CGSize, pinned: [String: CGPoint]) -> DeskCanvasLayout`

- Produces (NOT in the fixed shared API — defined inside this task because the shared API fixes only the chip's *width* fraction and says nothing about gaps, chip height, or where a later task should read them from; later tasks must consume these rather than redeclare them):
  - `static let siblingGapFraction: CGFloat = 0.12`
  - `static let levelGapFraction: CGFloat = 0.3`
  - `static func chipSize(forCard cardSize: CGSize) -> CGSize`
  - `static func nodeSize(_ kind: DeskNode.Kind, cardSize: CGSize) -> CGSize`
  - `static func siblingGap(forCard cardSize: CGSize) -> CGFloat`
  - `static func levelGap(forCard cardSize: CGSize) -> CGFloat`

- Explicitly **not** produced here, so the tasks that own them stay unambiguous:
  - `struct DeskCamera` and every member of it (`transform`, `canvasPoint(from:)`, `fitAll(content:in:)`, `focus(on:in:)`, `clamped(minScale:in:)`, `isIdentity`, `maxScale`). The camera task adds it to this same `DeskCanvas.swift` file and consumes `DeskCanvas.fitMargin` from here; it needs no new pbxproj entry, and it appends its cases to the `DeskCanvasTests.swift` this task registers.
  - Any builder that turns live app state into a `DeskNode` tree (`PaneWorkspaceView.groupOrder` → nodes). This task takes the tree as an argument and never reads app state.

---

- [ ] **Step 1: Register both new files in the Xcode project, before writing a line that depends on them**

The project is `objectVersion = 77` but has **no** `PBXFileSystemSynchronizedRootGroup` — dropping a `.swift` file into the folder does nothing: it is silently not compiled and its tests silently do not run. Eight hand-edits, four per file. Ids below were generated with the repo's recipe (`uuidgen | tr -d '-' | cut -c1-24 | tr 'a-f' 'A-F'`) and verified absent from `project.pbxproj`.

First create the two empty files so the references resolve:

```
cd /Users/bonando/Documents/Bruno.Digital/OmniAgent-ADE
touch macos/OmniAgent/DeskCanvas.swift macos/OmniAgentTests/DeskCanvasTests.swift
```

Then eight insertions. **Indentation is literal tab characters: two tabs on the `PBXBuildFile`/`PBXFileReference` lines, four tabs on the `children`/`files` entries.** Insert adjacent to the existing neighbour rather than rewriting any section — this file is hot and shared.

*App target — `DeskCanvas.swift`.*

(1) In the `PBXBuildFile` section, immediately after the line containing `10000000000000000000000C /* PaneGrid.swift in Sources */`:
```
		B8FC09BF87F34E8E91515F5E /* DeskCanvas.swift in Sources */ = {isa = PBXBuildFile; fileRef = 2CDF8CF2C82745FFABCED8D2 /* DeskCanvas.swift */; };
```
(2) In the `PBXFileReference` section, immediately after the line containing `20000000000000000000000D /* PaneGrid.swift */ = {isa = PBXFileReference`:
```
		2CDF8CF2C82745FFABCED8D2 /* DeskCanvas.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = DeskCanvas.swift; sourceTree = "<group>"; };
```
(3) In `500000000000000000000002 /* OmniAgent */`'s `children = (` list, immediately after `20000000000000000000000D /* PaneGrid.swift */,`:
```
				2CDF8CF2C82745FFABCED8D2 /* DeskCanvas.swift */,
```
(4) In `800000000000000000000001 /* Sources */`'s `files = (` list, immediately after `10000000000000000000000C /* PaneGrid.swift in Sources */,`:
```
				B8FC09BF87F34E8E91515F5E /* DeskCanvas.swift in Sources */,
```

*Test target — `DeskCanvasTests.swift`.*

(5) In the `PBXBuildFile` section, immediately after the line containing `10000000000000000000000D /* PaneGridTests.swift in Sources */`:
```
		BE203811DF334A88BCEB06D8 /* DeskCanvasTests.swift in Sources */ = {isa = PBXBuildFile; fileRef = 515737526BA746E7B0775D9D /* DeskCanvasTests.swift */; };
```
(6) In the `PBXFileReference` section, immediately after the line containing `20000000000000000000000E /* PaneGridTests.swift */ = {isa = PBXFileReference`:
```
		515737526BA746E7B0775D9D /* DeskCanvasTests.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = DeskCanvasTests.swift; sourceTree = "<group>"; };
```
(7) In `500000000000000000000003 /* OmniAgentTests */`'s `children = (` list, immediately after `20000000000000000000000E /* PaneGridTests.swift */,`:
```
				515737526BA746E7B0775D9D /* DeskCanvasTests.swift */,
```
(8) In `800000000000000000000002 /* Sources */`'s `files = (` list, immediately after `10000000000000000000000D /* PaneGridTests.swift in Sources */,`:
```
				BE203811DF334A88BCEB06D8 /* DeskCanvasTests.swift in Sources */,
```

Verify the registration on its own, with both files still empty:

```
cd /Users/bonando/Documents/Bruno.Digital/OmniAgent-ADE && xcodebuild build-for-testing \
  -project macos/OmniAgent.xcodeproj -scheme OmniAgent \
  -destination "platform=macOS,arch=$(uname -m)" \
  CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS="$(uname -m)" 2>&1 | tail -5
```

Expected: `** TEST BUILD SUCCEEDED **`. (`./macos/build.sh build` compiles the app target only, so it would not catch a botched test-target registration; `build-for-testing` compiles both.)

---

- [ ] **Step 2: Write the failing test — sizing, packing, centring, level spacing**

Create `macos/OmniAgentTests/DeskCanvasTests.swift`. House style: `import XCTest` / `@testable import OmniAgent`, a `///` doc comment on the class saying what contract it enforces, `func test` + a full sentence in CamelCase with no underscores and no "Should", and an assertion message that states the rule in prose.

```swift
import XCTest
@testable import OmniAgent

/// The Desk organigram's geometry: a tidy tree packed bottom-up, session cards
/// forced to the viewport size, chips a quarter of that, pinned nodes lifted
/// out of the packing entirely, and every frame in the workspace view's own
/// FLIPPED space. Pure — no window, no layer, no camera, the way
/// `PaneGridTests` is pure.
///
/// The card size used throughout is 1200x800 because every derived quantity
/// then falls on a whole point (chip 300x200, sibling gap 144, level gap 240),
/// so these cases pin the arithmetic itself rather than a rounding artefact.
/// `testEveryFrameLandsOnWholePointsSoNoCardRendersOnAHalfPixel` deliberately
/// uses an ugly card size instead.
final class DeskCanvasTests: XCTestCase {
    private let cardSize = CGSize(width: 1200, height: 800)

    // MARK: - Node sizes

    func testASessionCardIsAlwaysTheViewportCardAndAChipIsAQuarterOfIt() throws {
        let layout = DeskCanvas.layout(
            root: tree(sessions: ["sess-grp-1"]),
            cardSize: cardSize,
            pinned: [:]
        )

        XCTAssertEqual(
            try XCTUnwrap(layout.frames["sess-grp-1"]).size,
            cardSize,
            "a session card is exactly the Desk viewport, one pane or twelve"
        )
        XCTAssertEqual(
            try XCTUnwrap(layout.frames["root"]).size,
            CGSize(width: 300, height: 200),
            "the You chip is the card at chipWidthFraction"
        )
        XCTAssertEqual(
            try XCTUnwrap(layout.frames["OmniAgent-ADE"]).size,
            CGSize(width: 300, height: 200),
            "so is the workspace chip"
        )
        XCTAssertEqual(
            DeskCanvas.chipSize(forCard: cardSize).width,
            cardSize.width * DeskCanvas.chipWidthFraction,
            "chip width is the fraction the shared constant names"
        )
    }

    // MARK: - Packing and centring

    func testChildrenPackLeftToRightAndTheParentSitsCentredOverTheirSpan() throws {
        let layout = DeskCanvas.layout(
            root: tree(sessions: ["a", "b", "c"]),
            cardSize: cardSize,
            pinned: [:]
        )
        let a = try XCTUnwrap(layout.frames["a"])
        let b = try XCTUnwrap(layout.frames["b"])
        let c = try XCTUnwrap(layout.frames["c"])
        let workspace = try XCTUnwrap(layout.frames["OmniAgent-ADE"])
        let root = try XCTUnwrap(layout.frames["root"])
        let gap = DeskCanvas.siblingGap(forCard: cardSize)

        XCTAssertEqual(a.minX, 0, "the first child opens the band at the origin")
        XCTAssertEqual(b.minX - a.maxX, gap, "one sibling gap between a and b")
        XCTAssertEqual(c.minX - b.maxX, gap, "one sibling gap between b and c")
        XCTAssertEqual(Set([a.minY, b.minY, c.minY]).count, 1, "siblings share one row")
        XCTAssertEqual(
            workspace.midX,
            (a.minX + c.maxX) / 2,
            "the parent is centred over its children's span, not over its first child"
        )
        XCTAssertEqual(root.midX, workspace.midX, "and its parent over that")
    }

    /// A workspace with two sessions is 2544 wide while its own chip is 300, so
    /// packing by node width instead of subtree width would overlap the two
    /// branches. Bottom-up means the parent asks how wide its children ended up
    /// before it decides where the next sibling starts.
    func testSiblingSubtreesPackByTheirMeasuredWidthNotByTheirNodeWidth() throws {
        let root = DeskNode(id: "root", kind: .root, children: [
            DeskNode(id: "alpha", kind: .workspace("alpha"), children: [
                DeskNode(id: "a1", kind: .session("a1"), children: []),
                DeskNode(id: "a2", kind: .session("a2"), children: []),
            ]),
            DeskNode(id: "beta", kind: .workspace("beta"), children: [
                DeskNode(id: "b1", kind: .session("b1"), children: []),
            ]),
        ])
        let layout = DeskCanvas.layout(root: root, cardSize: cardSize, pinned: [:])
        let a2 = try XCTUnwrap(layout.frames["a2"])
        let b1 = try XCTUnwrap(layout.frames["b1"])

        XCTAssertEqual(
            b1.minX - a2.maxX,
            DeskCanvas.siblingGap(forCard: cardSize),
            "beta's band opens one gap after alpha's widest row, not after alpha's chip"
        )
        XCTAssertEqual(
            try XCTUnwrap(layout.frames["alpha"]).midX,
            (try XCTUnwrap(layout.frames["a1"]).minX + a2.maxX) / 2,
            "alpha centres over its two cards"
        )
        XCTAssertEqual(
            try XCTUnwrap(layout.frames["beta"]).midX,
            b1.midX,
            "beta centres over its one"
        )
    }

    // MARK: - The flipped space

    /// `PaneWorkspaceView.isFlipped == true` and the window is not — the same
    /// distinction `PaneDividerView.mouseDragged` turns on. Every level of the
    /// canvas grows y DOWNWARD; getting this backwards would draw the tree
    /// upside down and put every pinned position on the wrong side of its node.
    func testEachLevelSitsBelowTheOneAboveItInTheFlippedCanvasSpace() throws {
        let layout = DeskCanvas.layout(
            root: tree(sessions: ["a"]),
            cardSize: cardSize,
            pinned: [:]
        )
        let root = try XCTUnwrap(layout.frames["root"])
        let workspace = try XCTUnwrap(layout.frames["OmniAgent-ADE"])
        let session = try XCTUnwrap(layout.frames["a"])
        let gap = DeskCanvas.levelGap(forCard: cardSize)

        XCTAssertEqual(root.minY, 0, "the tree starts at the canvas origin")
        XCTAssertEqual(workspace.minY - root.maxY, gap, "one level gap below You")
        XCTAssertEqual(session.minY - workspace.maxY, gap, "one level gap below the workspace")
        XCTAssertTrue(
            root.minY < workspace.minY && workspace.minY < session.minY,
            "y grows downward — the canvas lives in the view's flipped space"
        )
        XCTAssertEqual(session.midX, workspace.midX, "a lone child sits directly under its parent")
    }

    func testARootWithNoWorkspacesIsItsOwnContent() {
        let layout = DeskCanvas.layout(
            root: DeskNode(id: "root", kind: .root, children: []),
            cardSize: cardSize,
            pinned: [:]
        )

        XCTAssertEqual(layout.frames.count, 1, "one node, one frame")
        XCTAssertEqual(layout.edges, [], "nothing to connect")
        XCTAssertEqual(
            layout.contentRect,
            CGRect(x: 0, y: 0, width: 300, height: 200),
            "contentRect never collapses to zero while a node exists — fitAll would divide by it"
        )
    }

    // MARK: - Helpers

    /// `You → OmniAgent-ADE → sessions`, the shape the Desk actually draws. A
    /// session node's id IS its group id, the same string
    /// `PaneDescriptor.group` and `PaneWorkspaceView.activeGroup` carry.
    private func tree(sessions: [String]) -> DeskNode {
        DeskNode(
            id: "root",
            kind: .root,
            children: [
                DeskNode(
                    id: "OmniAgent-ADE",
                    kind: .workspace("OmniAgent-ADE"),
                    children: sessions.map {
                        DeskNode(id: $0, kind: .session($0), children: [])
                    }
                ),
            ]
        )
    }
}
```

---

- [ ] **Step 3: Write the failing test — determinism, pinning, edges, whole points**

Append these to `DeskCanvasTests`, above the `// MARK: - Helpers` block.

```swift
    // MARK: - Determinism

    /// The layout walks `children` arrays and never a dictionary, so the same
    /// tree must produce a byte-identical `DeskCanvasLayout` on every call —
    /// including `contentRect`, which is folded in placement order rather than
    /// over `frames.values`. A camera restored from `desk_canvas_native` is
    /// meaningless the moment this drifts.
    func testTheSameTreeLaysOutIdenticallyEveryTime() {
        let root = tree(sessions: ["a", "b", "c", "d"])
        let pinned = ["c": CGPoint(x: 4000, y: 2500)]
        let first = DeskCanvas.layout(root: root, cardSize: cardSize, pinned: pinned)

        for attempt in 1...20 {
            XCTAssertEqual(
                DeskCanvas.layout(root: root, cardSize: cardSize, pinned: pinned),
                first,
                "run \(attempt) differs — the layout must not depend on dictionary order"
            )
        }
    }

    // MARK: - Pinning

    func testAPinnedSessionSitsWhereItWasDroppedAndItsSiblingsCloseTheGap() throws {
        let root = tree(sessions: ["a", "b", "c"])
        let loose = DeskCanvas.layout(root: root, cardSize: cardSize, pinned: [:])
        let drop = CGPoint(x: 5000, y: 5000)
        let layout = DeskCanvas.layout(root: root, cardSize: cardSize, pinned: ["b": drop])

        let a = try XCTUnwrap(layout.frames["a"])
        let b = try XCTUnwrap(layout.frames["b"])
        let c = try XCTUnwrap(layout.frames["c"])

        XCTAssertEqual(b.origin, drop, "the dragged card keeps the absolute position it was dropped at")
        XCTAssertEqual(b.size, cardSize, "pinning changes where a card is, never how big it is")
        XCTAssertEqual(
            c.minX - a.maxX,
            DeskCanvas.siblingGap(forCard: cardSize),
            "a and c are adjacent — the packing does not hold b's empty slot open"
        )
        XCTAssertNotEqual(layout.frames["c"], loose.frames["c"], "c moved left into the gap")
        XCTAssertEqual(
            try XCTUnwrap(layout.frames["OmniAgent-ADE"]).midX,
            (a.minX + c.maxX) / 2,
            "the parent centres over the children it still packs, not over the pinned one"
        )
    }

    /// "Dragging a node translates it *and its subtree*." Pinning the workspace
    /// has to take its sessions with it, and the unpinned remainder above has to
    /// pack as if the pinned branch were not in the tree at all.
    func testAPinnedWorkspaceCarriesItsSessionsWithIt() throws {
        let drop = CGPoint(x: 2000, y: 3000)
        let layout = DeskCanvas.layout(
            root: tree(sessions: ["a", "b", "c"]),
            cardSize: cardSize,
            pinned: ["OmniAgent-ADE": drop]
        )
        let workspace = try XCTUnwrap(layout.frames["OmniAgent-ADE"])
        let a = try XCTUnwrap(layout.frames["a"])
        let c = try XCTUnwrap(layout.frames["c"])

        XCTAssertEqual(workspace.origin, drop)
        XCTAssertEqual(
            a.minY,
            workspace.maxY + DeskCanvas.levelGap(forCard: cardSize),
            "the subtree hangs one level below the node it was dragged with"
        )
        XCTAssertEqual(
            (a.minX + c.maxX) / 2,
            workspace.midX,
            "the sessions re-centre under the pinned parent"
        )
        XCTAssertEqual(
            try XCTUnwrap(layout.frames["root"]).minX,
            0,
            "with its only child pinned away, You packs as a leaf at the origin"
        )
    }

    // MARK: - contentRect and edges

    func testTheContentRectIsTheUnionOfEveryFrame() throws {
        let layout = DeskCanvas.layout(
            root: tree(sessions: ["a", "b", "c"]),
            cardSize: cardSize,
            pinned: ["b": CGPoint(x: 5000, y: 5000)]
        )
        var union = CGRect.null
        for frame in layout.frames.values { union = union.union(frame) }

        XCTAssertEqual(layout.contentRect, union, "contentRect is exactly what fitAll has to fit")
        XCTAssertTrue(
            layout.contentRect.contains(try XCTUnwrap(layout.frames["b"])),
            "a card dragged far off the tidy tree is still inside the fit"
        )
    }

    func testEveryParentChildPairGetsExactlyOneEdgeIncludingThePinnedOnes() {
        let layout = DeskCanvas.layout(
            root: tree(sessions: ["a", "b"]),
            cardSize: cardSize,
            pinned: ["b": CGPoint(x: 5000, y: 5000)]
        )

        XCTAssertEqual(
            layout.edges,
            [
                DeskEdge(from: "root", to: "OmniAgent-ADE"),
                DeskEdge(from: "OmniAgent-ADE", to: "a"),
                DeskEdge(from: "OmniAgent-ADE", to: "b"),
            ],
            "depth first, children in tree order; the connector to a dragged node stays"
        )
    }

    // MARK: - Rounding

    /// `PaneGrid.layout(in:dividerThickness:)` rounds its edges to whole points
    /// "so the panes tile `bounds` exactly and no pane draws on a half-pixel".
    /// A session card's rect becomes a real container frame here, so the same
    /// rule applies — with an awkward card size and a half-point drop position,
    /// which is what a real drag produces.
    func testEveryFrameLandsOnWholePointsSoNoCardRendersOnAHalfPixel() {
        let layout = DeskCanvas.layout(
            root: tree(sessions: ["a", "b", "c", "d", "e"]),
            cardSize: CGSize(width: 1207, height: 813),
            pinned: ["c": CGPoint(x: 999.5, y: 1000.4)]
        )

        XCTAssertEqual(layout.frames.count, 7, "root, workspace and five sessions")
        for (id, frame) in layout.frames {
            XCTAssertEqual(frame.minX, frame.minX.rounded(), "\(id) x is on a whole point")
            XCTAssertEqual(frame.minY, frame.minY.rounded(), "\(id) y is on a whole point")
        }
    }
```

---

- [ ] **Step 4: Run it and watch it fail**

Run:
```
cd /Users/bonando/Documents/Bruno.Digital/OmniAgent-ADE && xcodebuild test \
  -project macos/OmniAgent.xcodeproj -scheme OmniAgent \
  -destination "platform=macOS,arch=$(uname -m)" \
  CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS="$(uname -m)" \
  -only-testing:OmniAgentTests/DeskCanvasTests 2>&1 | tail -30
```

Expected: the test target does not compile — `DeskCanvas.swift` is still the empty file from Step 1. Repeated `error: cannot find 'DeskCanvas' in scope` and `error: cannot find 'DeskNode' in scope` in `DeskCanvasTests.swift`, ending in `** TEST BUILD FAILED **`. (`./macos/build.sh test` cannot be used for a single class — it is `exec xcodebuild "$action" …` with a fixed argument list and forwards nothing.)

---

- [ ] **Step 5: Implement the value types, the constants and node sizing**

Write this into `macos/OmniAgent/DeskCanvas.swift`. `import Foundation` alone is what `PaneGrid.swift` uses and it re-exports `CGRect`/`CGSize`/`CGPoint`/`CGFloat` on macOS.

```swift
import Foundation

/// The Desk organigram — `You → Workspace → Sessions` — and the tidy tree that
/// arranges it. Pure value types: no AppKit view code, no layer, no window,
/// testable exactly the way `PaneGrid` is.
///
/// **Shape of the unit.** `PaneWorkspaceView` in canvas mode asks for one
/// `DeskCanvasLayout` and lays each session's `PaneGrid` out inside the rect
/// this names for that group; the chip views draw the `root`/`workspace` nodes
/// at theirs, and the edge layer strokes `edges` as one path. Nothing here
/// knows about zoom: the camera is a `sublayerTransform` applied on top of
/// these frames, so a camera move changes no frame and therefore costs no PTY
/// resize.
///
/// **Coordinates are the workspace view's own FLIPPED space, y growing
/// downward.** `PaneWorkspaceView.isFlipped` is `true` and the window is not —
/// the same distinction `PaneDividerView.mouseDragged` already turns on: "The
/// workspace view is flipped, the window is not: a downward drag is a *smaller*
/// window y but a *larger* workspace y." Every rect produced here obeys it: the
/// root node has the smallest `minY` and each level down the tree a larger one.
/// Pinned positions and the camera origin are defined in this same space and in
/// no other.
///
/// **Node ids are unique across the tree.** `frames` is keyed by id, and a
/// session node's id IS the group id the rest of the app uses
/// (`PaneDescriptor.group`, `PaneWorkspaceView.activeGroup`), so two nodes
/// sharing an id would collapse onto one frame.
struct DeskNode: Equatable {
    /// What the node draws as, and how big it is. `session` carries the group
    /// id used everywhere else in the app; `workspace` carries the project id.
    /// The Desk level is deliberately folded into the workspace node
    /// (`OmniAgent-ADE › Desk`) — it is 1:1 with Workspace and as its own level
    /// would only make the tree taller.
    enum Kind: Equatable {
        case root
        case workspace(String)
        case session(String)
    }

    let id: String
    let kind: Kind
    let children: [DeskNode]
}

/// One connector, parent to child. Pinned children keep theirs — dragging a
/// node off the tidy tree does not cut it out of the organigram.
struct DeskEdge: Equatable {
    let from: String   // node id
    let to: String     // node id
}

/// Node frames in the canvas's own coordinate space, which is FLIPPED
/// (`PaneWorkspaceView.isFlipped == true`), y growing downward.
struct DeskCanvasLayout: Equatable {
    let frames: [String: CGRect]
    let edges: [DeskEdge]
    /// Union of every frame — what `DeskCamera.fitAll` fits. Never `.null`:
    /// a tree always has at least its root, and a zero rect would make the fit
    /// scale meaningless.
    let contentRect: CGRect
}

enum DeskCanvas {
    /// Chip node width as a fraction of a session card's width.
    static let chipWidthFraction: CGFloat = 0.25

    /// Below this scale an on-screen session shows chips instead of surfaces.
    /// At 0.2, 12pt type is 2.4pt: there is no information in those pixels,
    /// only cost.
    static let lodThreshold: CGFloat = 0.2

    /// fitAll's breathing room, as a fraction.
    static let fitMargin: CGFloat = 0.2

    /// Horizontal room between two packed siblings, as a fraction of a card's
    /// width. A fraction rather than a point count because a card is the whole
    /// Desk viewport — a 40pt gap between two 1200pt cards is invisible at
    /// fit-all zoom, which is the only zoom the gap exists to be read at.
    static let siblingGapFraction: CGFloat = 0.12

    /// Vertical room between one level's bottom edge and the next level's top,
    /// as a fraction of a card's height. Same reasoning as `siblingGapFraction`.
    static let levelGapFraction: CGFloat = 0.3

    /// A chip is the card at `chipWidthFraction` scale — same aspect, so the
    /// tree reads as one family of rectangles at any zoom, and one constant
    /// governs both dimensions. Rounded, so no chip lands on a half-point.
    static func chipSize(forCard cardSize: CGSize) -> CGSize {
        CGSize(
            width: (cardSize.width * chipWidthFraction).rounded(),
            height: (cardSize.height * chipWidthFraction).rounded()
        )
    }

    /// A session card is ALWAYS `cardSize`, one pane or twelve — a card is the
    /// size of the Desk viewport, because that is what makes "camera at 1.0
    /// over this card" identical to "you are in this session". Everything else
    /// is a chip.
    static func nodeSize(_ kind: DeskNode.Kind, cardSize: CGSize) -> CGSize {
        switch kind {
        case .session:
            return cardSize
        case .root, .workspace:
            return chipSize(forCard: cardSize)
        }
    }

    static func siblingGap(forCard cardSize: CGSize) -> CGFloat {
        (cardSize.width * siblingGapFraction).rounded()
    }

    static func levelGap(forCard cardSize: CGSize) -> CGFloat {
        (cardSize.height * levelGapFraction).rounded()
    }
}
```

---

- [ ] **Step 6: Implement `layout(root:cardSize:pinned:)`**

Append to the `DeskCanvas` enum in `macos/OmniAgent/DeskCanvas.swift`, after `levelGap(forCard:)`.

```swift
    // MARK: - Layout

    /// Tidy tree, bottom-up: children packed left-to-right by width, parent
    /// centred over its children's span. `pinned` nodes are EXCLUDED from
    /// packing and placed at their stored canvas position; unpinned siblings
    /// close the gap. A session card's size is always `cardSize`.
    ///
    /// A pinned entry's `CGPoint` is the node's frame ORIGIN — its top-left in
    /// flipped canvas space — not an offset from an auto slot, so a pin means
    /// the same place whatever else opens or closes around it. The pinned
    /// node's own subtree follows it: dragging a node translates it and
    /// everything hanging off it.
    ///
    /// Deterministic by construction: the walk only ever iterates `children`
    /// arrays, and `contentRect` is folded in placement order rather than over
    /// `frames.values`, whose iteration order is not stable.
    static func layout(
        root: DeskNode,
        cardSize: CGSize,
        pinned: [String: CGPoint]
    ) -> DeskCanvasLayout {
        var placed: [(id: String, frame: CGRect)] = []
        var edges: [DeskEdge] = []
        place(
            root,
            left: 0,
            top: 0,
            cardSize: cardSize,
            pinned: pinned,
            placed: &placed,
            edges: &edges
        )

        var frames: [String: CGRect] = [:]
        frames.reserveCapacity(placed.count)
        var content = CGRect.null
        for entry in placed {
            frames[entry.id] = entry.frame
            content = content.union(entry.frame)
        }
        return DeskCanvasLayout(
            frames: frames,
            edges: edges,
            contentRect: content.isNull ? .zero : content
        )
    }

    /// The width the node's packed band needs: its own width, or its unpinned
    /// children's span, whichever is wider. Pinned children are not in the band
    /// at all — they are wherever the user dropped them, and their siblings
    /// close over the space they used to hold.
    ///
    /// The tree is three levels deep and tens of nodes wide, so measuring a
    /// subtree twice (once here, once as the caller advances) costs nothing and
    /// keeps the measure and place passes readable.
    private static func subtreeWidth(
        _ node: DeskNode,
        cardSize: CGSize,
        pinned: [String: CGPoint]
    ) -> CGFloat {
        let own = nodeSize(node.kind, cardSize: cardSize).width
        let packed = node.children.filter { pinned[$0.id] == nil }
        guard !packed.isEmpty else { return own }
        let span = packedSpan(packed, cardSize: cardSize, pinned: pinned)
        return max(own, span)
    }

    private static func packedSpan(
        _ packed: [DeskNode],
        cardSize: CGSize,
        pinned: [String: CGPoint]
    ) -> CGFloat {
        guard !packed.isEmpty else { return 0 }
        let widths = packed.reduce(CGFloat(0)) {
            $0 + subtreeWidth($1, cardSize: cardSize, pinned: pinned)
        }
        return widths + siblingGap(forCard: cardSize) * CGFloat(packed.count - 1)
    }

    /// Places `node` inside a band whose left edge is `left` and whose top edge
    /// is `top`, then recurses. `subtreeWidth` has already measured every
    /// descendant, so the parent can be centred over the span its children are
    /// about to occupy — that is what makes this bottom-up in effect while
    /// staying one downward walk.
    ///
    /// A pinned node ignores `left`/`top` entirely and takes its stored origin,
    /// then centres its own children under itself; an unpinned node centres
    /// itself over its children. Both are the same rule stated from the two
    /// ends.
    ///
    /// Origins are rounded to whole points, the way
    /// `PaneGrid.layout(in:dividerThickness:)` rounds its edges — a session
    /// card's rect becomes a real container frame, and a container on a
    /// half-point renders soft text. Rounding happens once per frame, from the
    /// exact ideal position, so nothing accumulates down a row.
    private static func place(
        _ node: DeskNode,
        left: CGFloat,
        top: CGFloat,
        cardSize: CGSize,
        pinned: [String: CGPoint],
        placed: inout [(id: String, frame: CGRect)],
        edges: inout [DeskEdge]
    ) {
        let size = nodeSize(node.kind, cardSize: cardSize)
        let packed = node.children.filter { pinned[$0.id] == nil }
        let span = packedSpan(packed, cardSize: cardSize, pinned: pinned)

        let frame: CGRect
        let childrenLeft: CGFloat
        if let pin = pinned[node.id] {
            frame = CGRect(
                origin: CGPoint(x: pin.x.rounded(), y: pin.y.rounded()),
                size: size
            )
            childrenLeft = frame.midX - span / 2
        } else {
            let band = max(size.width, span)
            frame = CGRect(
                x: (left + (band - size.width) / 2).rounded(),
                y: top.rounded(),
                width: size.width,
                height: size.height
            )
            childrenLeft = left + (band - span) / 2
        }
        placed.append((node.id, frame))

        let childrenTop = frame.maxY + levelGap(forCard: cardSize)
        let gap = siblingGap(forCard: cardSize)
        var x = childrenLeft
        for child in node.children {
            edges.append(DeskEdge(from: node.id, to: child.id))
            guard pinned[child.id] == nil else {
                // Pinned: `left`/`top` are unused on that branch, and the child
                // does not advance `x` — that is the gap closing.
                place(
                    child,
                    left: 0,
                    top: 0,
                    cardSize: cardSize,
                    pinned: pinned,
                    placed: &placed,
                    edges: &edges
                )
                continue
            }
            place(
                child,
                left: x,
                top: childrenTop,
                cardSize: cardSize,
                pinned: pinned,
                placed: &placed,
                edges: &edges
            )
            x += subtreeWidth(child, cardSize: cardSize, pinned: pinned) + gap
        }
    }
```

---

- [ ] **Step 7: Run the test**

Run:
```
cd /Users/bonando/Documents/Bruno.Digital/OmniAgent-ADE && xcodebuild test \
  -project macos/OmniAgent.xcodeproj -scheme OmniAgent \
  -destination "platform=macOS,arch=$(uname -m)" \
  CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS="$(uname -m)" \
  -only-testing:OmniAgentTests/DeskCanvasTests 2>&1 | grep -E "Executed|error:|Failing tests"
```

Expected: PASS — `Executed 11 tests, with 0 failures`.

---

- [ ] **Step 8: Run the whole suite**

Run:
```
cd /Users/bonando/Documents/Bruno.Digital/OmniAgent-ADE && ./macos/build.sh test 2>&1 | grep -E "Executed [0-9]+ tests|Failing tests|\*\* TEST"
```

Expected: `0 failures`, with the executed count higher than the run recorded at the start of this task by exactly this task's new tests and `** TEST SUCCEEDED **`.

Gotcha, from the `native-test-host-crash-diagnosis` memory: *a launch can report a green total underneath a trailing `Failing tests:` list, and xcodebuild still exits 65.* Do not read only the summary — the grep above prints both lines; a `Failing tests:` line means the run failed no matter what the total says.

---

- [ ] **Step 9: Commit**

`project.pbxproj` is a hot shared file and already carries one uncommitted change that is not yours — `scripts/bump-build-version.sh` moved `CURRENT_PROJECT_VERSION` from 35 to 44 in all three build-settings blocks. Confirm that is still the *only* foreign hunk before staging (per the `commit-only-quiescent-files-shared-tree` memory; and never `git stash` in this worktree):

```
cd /Users/bonando/Documents/Bruno.Digital/OmniAgent-ADE && git diff macos/OmniAgent.xcodeproj/project.pbxproj
```

Expected hunks: your eight `DeskCanvas` insertions plus the three `CURRENT_PROJECT_VERSION = 44` lines. If a concurrent session has registered its own files in there, stop and coordinate rather than committing their half-finished registration.

Then stage exactly three paths and commit:

```
cd /Users/bonando/Documents/Bruno.Digital/OmniAgent-ADE && \
git add macos/OmniAgent/DeskCanvas.swift macos/OmniAgentTests/DeskCanvasTests.swift macos/OmniAgent.xcodeproj/project.pbxproj && \
git commit -m "$(cat <<'EOF'
feat(macos): DeskCanvas node tree and tidy-tree layout

The organigram behind Desk canvas mode as pure value types — `DeskNode`,
`DeskEdge`, `DeskCanvasLayout` and one `DeskCanvas.layout(root:cardSize:pinned:)`
— with no AppKit view code and no window, the way `PaneGrid` is.

Children pack left to right by their measured subtree width and the parent
centres over their span, so a workspace with two sessions reserves the width
of two cards rather than the width of its own chip. A session card is always
`cardSize` (the Desk viewport, which is what makes "camera at 1.0 over this
card" identical to "you are in this session"); everything else is that card at
`chipWidthFraction`. A pinned node is lifted out of the packing entirely, takes
its stored origin, carries its subtree with it, and its siblings close over the
space it used to hold.

Coordinates are the workspace view's own flipped space, y downward — the same
convention `PaneWorkspaceView.isFlipped` and `PaneDividerView.mouseDragged`
already depend on — and origins are rounded to whole points for the reason
`PaneGrid.layout` rounds its edges. The walk touches no dictionary, so the same
tree lays out identically every time; a restored camera depends on that.

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>
EOF
)" && git push
```

---

### Task 3: DeskCamera math

**Files:**
- Modify: `macos/OmniAgent/DeskCanvas.swift` (add `import QuartzCore` beneath the existing `import Foundation`; add `struct DeskCamera` after `struct DeskCanvasLayout` and before `enum DeskCanvas` — anchor by those symbol names, the file is under concurrent edit)
- Test: `macos/OmniAgentTests/DeskCanvasTests.swift` (append a `// MARK: - camera` section after the layout sections, above any `// MARK: - helpers` block)

**Interfaces:**
- Consumes (from Task 2, already in `DeskCanvas.swift`):
  - `static let fitMargin: CGFloat = 0.2` (on `enum DeskCanvas`)
  - `static let lodThreshold: CGFloat = 0.2` (on `enum DeskCanvas`) — used only as a sample scale in the round-trip test
  - `struct DeskCanvasLayout: Equatable { let frames: [String: CGRect]; let edges: [DeskEdge]; let contentRect: CGRect }` — `contentRect` is what `fitAll` is fed in production
- Produces:
  - `struct DeskCamera: Equatable`
  - `init(scale: CGFloat, origin: CGPoint)` (synthesized memberwise)
  - `var scale: CGFloat`
  - `var origin: CGPoint`
  - `static let maxScale: CGFloat = 1.0`
  - `var transform: CATransform3D { get }`
  - `func canvasPoint(from viewPoint: CGPoint) -> CGPoint`
  - `static func fitAll(content: CGRect, in bounds: CGRect) -> DeskCamera`
  - `static func focus(on rect: CGRect, in bounds: CGRect) -> DeskCamera`
  - `func clamped(minScale: CGFloat, in bounds: CGRect) -> DeskCamera`
  - `var isIdentity: Bool { get }`

**The contract in one line, which every later task must hold to:** `viewPoint = canvasPoint * scale + origin`, in `PaneWorkspaceView`'s **flipped** space (`override var isFlipped: Bool { true }` — *"Row 0 on top, matching `PaneGrid.layout(in:dividerThickness:)`"*). AppKit flips the backing layer's geometry to match the view (`PaneWorkspaceView.swift`, in the drop-shadow setup: *"Positive is *down*: this view is flipped, so AppKit flips its backing layer's geometry to match, and the shadow is cast in that space."*), so nothing in this task inverts an axis. `transform` is **scale then translate**, so `m41`/`m42` are the origin *unscaled*; reversing that order is the classic silent bug here and Step 4's test pins it.

**Why `maxScale` is 1.0.** SwiftTerm rasterizes at `metalRenderingScaleFactor()`, whose entire body is (verbatim, `SwiftTerm/Sources/SwiftTerm/Mac/MacTerminalView.swift`):

```swift
func metalRenderingScaleFactor() -> CGFloat {
    max(1, metalScaleFactorOverride ?? backingScaleFactor())
}
```

and `MetalTerminalRenderer` uses that number for both `layer.contentsScale` and `view.drawableSize`. Two consequences. Above 1.0 there is nothing to gain: without setting `metalScaleFactorOverride` — whose own doc says it is for *"Client applications that apply their own view transforms … so Metal rasterizes glyphs at the same scale the transformed view is displayed at"* — a terminal already rasterizes at its backing scale, so a camera at 1.6 magnifies pixels that already exist rather than revealing new ones. And below 1.0 there is nothing to save: the `max(1, …)` floor means a zoomed-out terminal *still* rasterizes full size, which is exactly why the spec pays for LOD with `DeskCanvas.lodThreshold` chips instead of a cheaper rasterization. 1.0 is also the only scale at which `layer.sublayerTransform` is a pure translation, so the ~10 `NSView.convert` / `event.locationInWindow` sites in `PaneWorkspaceView` (dividers, drop overlays, cursor rects, tracking areas), all blind to `CALayer` transforms, are still correct — the spec's correctness boundary, not a taste call.

- [ ] **Step 1: Preflight — confirm the two units this task extends exist and are registered**

Task 2 created `DeskCanvas.swift` and `DeskCanvasTests.swift`. Confirm both are in the Xcode project *before* writing a line, because **the project has no file-system-synchronized groups**: a `.swift` file sitting in the folder is silently not compiled and its tests silently do not run.

Run, from the repo root:

```bash
ls -l macos/OmniAgent/DeskCanvas.swift macos/OmniAgentTests/DeskCanvasTests.swift
grep -c "DeskCanvas.swift" macos/OmniAgent.xcodeproj/project.pbxproj        # expect 4
grep -c "DeskCanvasTests.swift" macos/OmniAgent.xcodeproj/project.pbxproj   # expect 4
```

Both counts must be `4` (PBXBuildFile, PBXFileReference, the group's `children`, the target's `PBXSourcesBuildPhase`). If either is `0`, register it now — two fresh ids per file from `uuidgen | tr -d '-' | cut -c1-24 | tr 'a-f' 'A-F'`, each line indented with **two tab characters**, inserted next to an existing neighbour rather than by rewriting the section (`project.pbxproj` is hot — `scripts/bump-build-version.sh` rewrites `CURRENT_PROJECT_VERSION` in it and concurrent sessions edit it too):

```
# app source — next to GitFileContent.swift's four lines
		<BUILDID> /* DeskCanvas.swift in Sources */ = {isa = PBXBuildFile; fileRef = <FILEID> /* DeskCanvas.swift */; };
		<FILEID> /* DeskCanvas.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = DeskCanvas.swift; sourceTree = "<group>"; };
#   in group 500000000000000000000002 /* OmniAgent */ children:
				<FILEID> /* DeskCanvas.swift */,
#   in phase 800000000000000000000001 /* Sources */ files:
				<BUILDID> /* DeskCanvas.swift in Sources */,

# test source — next to GitFileContentTests.swift's four lines
		<BUILDID2> /* DeskCanvasTests.swift in Sources */ = {isa = PBXBuildFile; fileRef = <FILEID2> /* DeskCanvasTests.swift */; };
		<FILEID2> /* DeskCanvasTests.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = DeskCanvasTests.swift; sourceTree = "<group>"; };
#   in group 500000000000000000000003 /* OmniAgentTests */ children:
				<FILEID2> /* DeskCanvasTests.swift */,
#   in phase 800000000000000000000002 /* Sources */ files:
				<BUILDID2> /* DeskCanvasTests.swift in Sources */,
```

then verify with `./macos/build.sh build` before continuing.

- [ ] **Step 2: Write the failing tests — `focus`, `fitAll`, and the degenerate inputs**

Add `import QuartzCore` beneath `import XCTest` at the top of `macos/OmniAgentTests/DeskCanvasTests.swift` (`CATransform3DGetAffineTransform` and `CATransform3DIsAffine` live there; this suite deliberately does not import AppKit — it must stay runnable with no window), then append:

```swift
    // MARK: - camera

    /// The property the whole navigation model rests on. A session card is
    /// exactly the size of the Desk viewport, so "the camera is at 1.0 over
    /// this card" and "you are in this session" have to be the *same state*.
    /// Exact equality, not an accuracy: `bounds.width / rect.width` for two
    /// equal finite values is exactly 1, and a camera that lands at 0.999
    /// leaves the text permanently soft.
    func testFocusingOnARectTheSizeOfTheViewportIsExactlyIdentityScale() {
        let bounds = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let card = CGRect(x: 2400, y: 960, width: 1200, height: 800)
        let camera = DeskCamera.focus(on: card, in: bounds)

        XCTAssertEqual(camera.scale, 1, "a card is viewport-sized, so focusing one is exactly 1.0")
        XCTAssertEqual(
            camera.canvasPoint(from: bounds.origin),
            card.origin,
            "the card's near corner lands on the viewport's near corner"
        )
        XCTAssertEqual(
            camera.canvasPoint(from: CGPoint(x: bounds.maxX, y: bounds.maxY)),
            CGPoint(x: card.maxX, y: card.maxY),
            "and its far corner on the viewport's — the card fills the Desk exactly"
        )
        XCTAssertTrue(camera.isIdentity, "an integral card origin lands on an integral camera origin")
    }

    /// `fitAll` is the zoom-out end of the clamp range: the whole tree plus
    /// `DeskCanvas.fitMargin` of breathing room *in total*, half of it on each
    /// side, centred. The numbers are chosen so the margin shows up in the
    /// answer — bare, this content would fit at 0.6.
    func testFitAllShowsTheWholeContentPlusItsMarginCentred() {
        XCTAssertEqual(DeskCanvas.fitMargin, 0.2, "the arithmetic below is on this value")
        let bounds = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let content = CGRect(x: -500, y: 250, width: 2000, height: 1000)
        let camera = DeskCamera.fitAll(content: content, in: bounds)

        XCTAssertEqual(camera.scale, 0.5, accuracy: 1e-12, "0.6 bare, over the 1.2 the margin adds")

        let mapped = content.applying(CATransform3DGetAffineTransform(camera.transform))
        XCTAssertEqual(mapped.midX, bounds.midX, accuracy: 1e-9, "centred across")
        XCTAssertEqual(mapped.midY, bounds.midY, accuracy: 1e-9, "and down")
        XCTAssertEqual(mapped.width, 1000, accuracy: 1e-9)
        XCTAssertEqual(
            mapped.minX - bounds.minX,
            100,
            accuracy: 1e-9,
            "100pt of margin on the tight axis — half of fitMargin, mapped"
        )
        XCTAssertTrue(bounds.contains(mapped), "the whole tree is on screen, which is what fit-all means")
    }

    /// A lone session on a big display: content plus margin is smaller than the
    /// viewport and the bare fit would be 1.67. It is not taken. `maxScale` is
    /// the ceiling everywhere, `fitAll` included, so the clamp range
    /// `[fitAll, 1]` can never come out inverted.
    func testFitAllOnContentSmallerThanTheViewportNeverZoomsPastOne() {
        let bounds = CGRect(x: 0, y: 0, width: 1600, height: 1200)
        let content = CGRect(x: 0, y: 0, width: 800, height: 600)
        let camera = DeskCamera.fitAll(content: content, in: bounds)

        XCTAssertEqual(
            DeskCamera.maxScale,
            1,
            "nothing rasterizes sharper than 1x: metalRenderingScaleFactor() is max(1, override ?? backingScaleFactor())"
        )
        XCTAssertEqual(camera.scale, DeskCamera.maxScale, "the ceiling wins over the fit")

        let mapped = content.applying(CATransform3DGetAffineTransform(camera.transform))
        XCTAssertEqual(mapped.midX, bounds.midX, accuracy: 1e-9, "still centred, just not blown up")
        XCTAssertEqual(mapped.midY, bounds.midY, accuracy: 1e-9)
    }

    /// `updateLayout()` runs before the view has a size, and a canvas with no
    /// nodes has no content rect at all. Neither may produce a NaN camera: a
    /// NaN reaching `layer.sublayerTransform` blanks every sublayer on screen
    /// and never recovers, and `Equatable` on a NaN never compares equal, so
    /// the "unchanged camera" guards downstream would fire forever.
    func testAnEmptyCanvasOrAZeroSizedViewportFitsAsIdentityRatherThanNaN() {
        let viewport = CGRect(x: 0, y: 0, width: 1200, height: 800)
        XCTAssertEqual(
            DeskCamera.fitAll(content: .zero, in: viewport),
            DeskCamera(scale: 1, origin: .zero),
            "an empty tree fits as identity"
        )
        XCTAssertEqual(
            DeskCamera.fitAll(content: CGRect(x: 0, y: 0, width: 2000, height: 1000), in: .zero),
            DeskCamera(scale: 1, origin: .zero),
            "so does a viewport that has not been sized yet"
        )
        XCTAssertEqual(
            DeskCamera.focus(on: CGRect(x: 0, y: 0, width: 1200, height: 800), in: .zero),
            DeskCamera(scale: 1, origin: .zero),
            "focus too — same guard"
        )

        let stalled = DeskCamera(scale: 0, origin: CGPoint(x: 10, y: 10))
        XCTAssertEqual(
            stalled.canvasPoint(from: CGPoint(x: 4, y: 4)),
            CGPoint(x: 4, y: 4),
            "a zero scale has no inverse; the point comes back unchanged rather than infinite"
        )
    }
```

- [ ] **Step 3: Write the failing tests — `transform`, the inverse round trip, `clamped`, `isIdentity`**

Append, in the same `// MARK: - camera` section:

```swift
    /// The transform is a scale *then* a translation — `m41`/`m42` are the
    /// origin unscaled — and `canvasPoint(from:)` is its exact inverse at any
    /// scale and origin. That inverse is the whole of the canvas's hit testing
    /// below identity scale: `NSView.convert` and `event.locationInWindow` are
    /// blind to a `CALayer` transform, so this is the only way back from a
    /// click to a node.
    func testTheTransformScalesThenTranslatesAndTheInverseUndoesIt() {
        let camera = DeskCamera(scale: 0.35, origin: CGPoint(x: 128.5, y: -940.25))
        let transform = camera.transform

        XCTAssertTrue(CATransform3DIsAffine(transform), "no perspective term ever enters the camera")
        XCTAssertEqual(transform.m11, 0.35, accuracy: 1e-12)
        XCTAssertEqual(transform.m22, 0.35, accuracy: 1e-12)
        XCTAssertEqual(transform.m41, 128.5, accuracy: 1e-12, "the origin unscaled: translate is last")
        XCTAssertEqual(transform.m42, -940.25, accuracy: 1e-12)

        let scales: [CGFloat] = [0.08, DeskCanvas.lodThreshold, 0.37, 0.5, 1]
        let origins = [CGPoint.zero, CGPoint(x: 317, y: -128.5), CGPoint(x: -940.25, y: 2200)]
        let canvasPoints = [CGPoint.zero, CGPoint(x: 1234.5, y: -67.25), CGPoint(x: -3000, y: 4096)]
        for scale in scales {
            for origin in origins {
                let probe = DeskCamera(scale: scale, origin: origin)
                let affine = CATransform3DGetAffineTransform(probe.transform)
                for canvas in canvasPoints {
                    let onScreen = canvas.applying(affine)
                    XCTAssertEqual(
                        onScreen.x,
                        canvas.x * scale + origin.x,
                        accuracy: 1e-9,
                        "canvas * scale + origin at \(scale) \(origin)"
                    )
                    XCTAssertEqual(onScreen.y, canvas.y * scale + origin.y, accuracy: 1e-9)

                    let back = probe.canvasPoint(from: onScreen)
                    XCTAssertEqual(back.x, canvas.x, accuracy: 1e-6, "round trip x at \(scale) \(origin)")
                    XCTAssertEqual(back.y, canvas.y, accuracy: 1e-6, "round trip y at \(scale) \(origin)")
                }
            }
        }
    }

    /// Pinching keeps whatever is under the middle of the screen under the
    /// middle of the screen. Both ends of `[minScale, DeskCamera.maxScale]` are
    /// hard: nothing above 1 to see, nothing below the fit worth showing.
    func testClampingHoldsTheViewportCentreStillBetweenTheFloorAndOne() {
        let bounds = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let floorScale: CGFloat = 0.25
        let middle = CGPoint(x: bounds.midX, y: bounds.midY)

        let tooClose = DeskCamera(scale: 2.4, origin: CGPoint(x: -3000, y: -1800))
        let wasUnderMiddle = tooClose.canvasPoint(from: middle)
        let pulledBack = tooClose.clamped(minScale: floorScale, in: bounds)
        XCTAssertEqual(pulledBack.scale, DeskCamera.maxScale, "never past 1")
        XCTAssertEqual(
            pulledBack.canvasPoint(from: middle).x,
            wasUnderMiddle.x,
            accuracy: 1e-9,
            "and what was under the middle is still under it"
        )
        XCTAssertEqual(pulledBack.canvasPoint(from: middle).y, wasUnderMiddle.y, accuracy: 1e-9)

        let tooFar = DeskCamera(scale: 0.02, origin: CGPoint(x: 640, y: 380))
        let wasUnderMiddleOut = tooFar.canvasPoint(from: middle)
        let pushedIn = tooFar.clamped(minScale: floorScale, in: bounds)
        XCTAssertEqual(pushedIn.scale, floorScale, "and never below the floor")
        XCTAssertEqual(pushedIn.canvasPoint(from: middle).x, wasUnderMiddleOut.x, accuracy: 1e-9)
        XCTAssertEqual(pushedIn.canvasPoint(from: middle).y, wasUnderMiddleOut.y, accuracy: 1e-9)

        let inRange = DeskCamera(scale: 0.5, origin: CGPoint(x: 120, y: -40))
        XCTAssertEqual(
            inRange.clamped(minScale: floorScale, in: bounds),
            inRange,
            "a camera already in range comes back untouched, origin included"
        )

        let inverted = DeskCamera(scale: 0.5, origin: .zero).clamped(minScale: 4, in: bounds)
        XCTAssertEqual(
            inverted.scale,
            DeskCamera.maxScale,
            "a floor above the ceiling collapses onto the ceiling rather than inverting the range"
        )
    }

    /// The landing condition, and the *only* state in which panes take input:
    /// `NSView.convert`, `event.locationInWindow`, the divider drags, the drop
    /// overlays and the tracking areas are all blind to
    /// `layer.sublayerTransform`, and all of them are right when it is a
    /// whole-pixel translation at 1.0. Exactly 1 rather than a tolerance,
    /// because `flyCamera(to:)` *assigns* the landing camera and never
    /// accumulates towards it — and 0.999 is soft text for good.
    func testACameraIsIdentityOnlyAtExactlyOneWithAWholePixelOrigin() {
        XCTAssertTrue(DeskCamera(scale: 1, origin: .zero).isIdentity)
        XCTAssertTrue(
            DeskCamera(scale: 1, origin: CGPoint(x: -2400, y: 960)).isIdentity,
            "a whole-pixel pan at 1.0 is still a landed camera"
        )
        XCTAssertFalse(
            DeskCamera(scale: 1, origin: CGPoint(x: -2400.5, y: 960)).isIdentity,
            "half a pixel across is soft text"
        )
        XCTAssertFalse(DeskCamera(scale: 1, origin: CGPoint(x: -2400, y: 959.75)).isIdentity)
        XCTAssertFalse(DeskCamera(scale: 0.999, origin: .zero).isIdentity, "not near 1 — at 1")
        XCTAssertFalse(DeskCamera(scale: 1.0001, origin: .zero).isIdentity)
        XCTAssertFalse(DeskCamera(scale: .nan, origin: .zero).isIdentity, "a NaN scale is not a landing")
        XCTAssertFalse(DeskCamera(scale: 1, origin: CGPoint(x: .infinity, y: 0)).isIdentity)
    }
```

- [ ] **Step 4: Run them and watch them fail**

Run, from the repo root (`./macos/build.sh` forwards no arguments — `exec xcodebuild "$action" …` — so a selective run needs the raw command):

```bash
xcodebuild test -project macos/OmniAgent.xcodeproj -scheme OmniAgent \
  -destination "platform=macOS,arch=$(uname -m)" CODE_SIGNING_ALLOWED=NO \
  -only-testing:OmniAgentTests/DeskCanvasTests
```

Expected: this fails to **build**, not to assert —
`macos/OmniAgentTests/DeskCanvasTests.swift:NN:22: error: cannot find 'DeskCamera' in scope`, repeated for each use, and `** TEST BUILD FAILED **`. Anything else (a *test* failure, or a pass) means the suite is registered against a `DeskCamera` that already exists — stop and reconcile with whoever added it before writing Step 5.

- [ ] **Step 5: Implement — the value type, `transform`, and the inverse**

In `macos/OmniAgent/DeskCanvas.swift`, add `import QuartzCore` immediately beneath the existing `import Foundation` (`CATransform3D` lives in QuartzCore; the file stays free of AppKit and of any window, the way `PaneGrid.swift` is). Then insert, after `struct DeskCanvasLayout` and before `enum DeskCanvas`:

```swift
/// The canvas camera: a uniform scale and a translation, applied as one
/// `CATransform3D` on `PaneWorkspaceView.layer.sublayerTransform`. It touches
/// no frame, so every container's frame stays in canvas coordinates and
/// nothing downstream learns about zoom.
///
/// **Coordinates.** Canvas space *is* the view's space, which is flipped —
/// `PaneWorkspaceView`'s `override var isFlipped: Bool { true }`, "Row 0 on
/// top, matching `PaneGrid.layout(in:dividerThickness:)`" — and AppKit flips
/// the backing layer's geometry to match ("this view is flipped, so AppKit
/// flips its backing layer's geometry to match"). y grows downward on both
/// sides of the transform, so nothing here inverts an axis.
///
/// **Direction.** `viewPoint = canvasPoint * scale + origin`, with
/// `canvasPoint(from:)` its exact inverse. `transform` scales *then*
/// translates, so `m41`/`m42` are `origin` unscaled — which assumes the
/// layer it is installed on anchors at its corner. **Verify that anchor before
/// trusting this** — Task 5's `PaneWorkspaceCanvasModeTests` asserts
/// `workspace.layer!.anchorPoint` explicitly for exactly this reason. AppKit's
/// default is `(0.5, 0.5)`, and with a centred anchor `applyCamera()` must
/// compose the recentring itself rather than assigning `camera.transform`
/// unchanged.
struct DeskCamera: Equatable {
    var scale: CGFloat
    var origin: CGPoint

    /// The ceiling, and there is nothing above it. SwiftTerm rasterizes at
    /// `metalRenderingScaleFactor()`, whose whole body is
    /// `max(1, metalScaleFactorOverride ?? backingScaleFactor())`, so past 1
    /// the camera only magnifies pixels that already exist. 1.0 is also the
    /// only scale at which the transform is a pure translation and the ten-odd
    /// `NSView`/`locationInWindow` conversions in `PaneWorkspaceView` — all
    /// blind to a `CALayer` transform — are still right, which is what makes
    /// panes interactive only here.
    static let maxScale: CGFloat = 1.0

    /// Scale first, translate second: `m41`/`m42` carry `origin` unscaled.
    var transform: CATransform3D {
        CATransform3DConcat(
            CATransform3DMakeScale(scale, scale, 1),
            CATransform3DMakeTranslation(origin.x, origin.y, 0)
        )
    }

    /// Maps a point in the view's coordinate space back into canvas space.
    /// A camera with no usable scale has no inverse; the point comes back
    /// unchanged rather than as an infinity that would poison a hit test.
    func canvasPoint(from viewPoint: CGPoint) -> CGPoint {
        guard scale > 0, scale.isFinite else { return viewPoint }
        return CGPoint(
            x: (viewPoint.x - origin.x) / scale,
            y: (viewPoint.y - origin.y) / scale
        )
    }
}
```

- [ ] **Step 6: Implement — `fitAll`, `focus`, `clamped`, `isIdentity`**

Add these four members inside the `struct DeskCamera` body written in Step 5, after `canvasPoint(from:)`:

```swift
    /// The whole content plus `DeskCanvas.fitMargin` of breathing room — half
    /// of it on each side, so the fraction reads as "20% more than the tree" —
    /// centred in `bounds`. This is the zoom-out end of the clamp range.
    static func fitAll(content: CGRect, in bounds: CGRect) -> DeskCamera {
        let padded = content.insetBy(
            dx: -content.width * DeskCanvas.fitMargin / 2,
            dy: -content.height * DeskCanvas.fitMargin / 2
        )
        return focus(on: padded, in: bounds)
    }

    /// The camera that maps `rect` onto `bounds`: the tighter of the two axes,
    /// centred, and never above `maxScale`. A session card is viewport-sized,
    /// so focusing one is exactly 1.0 — the identity the whole navigation model
    /// is built on. A rect *smaller* than the viewport is centred at 1.0 rather
    /// than blown up, because there is no more detail up there to find.
    /// A degenerate rect or an unsized viewport answers identity rather than a
    /// NaN, which would blank every sublayer on screen and never recover.
    static func focus(on rect: CGRect, in bounds: CGRect) -> DeskCamera {
        guard rect.width > 0, rect.height > 0, bounds.width > 0, bounds.height > 0 else {
            return DeskCamera(scale: 1, origin: .zero)
        }
        let fitted = min(
            min(bounds.width / rect.width, bounds.height / rect.height),
            maxScale
        )
        return DeskCamera(
            scale: fitted,
            origin: CGPoint(
                x: bounds.midX - fitted * rect.midX,
                y: bounds.midY - fitted * rect.midY
            )
        )
    }

    /// Clamps scale into `[minScale, maxScale]`, keeping whatever sits under
    /// the viewport's centre exactly where it is. A `minScale` above the
    /// ceiling collapses onto the ceiling — the ceiling wins, rather than the
    /// range inverting. A camera already in range is returned untouched, so an
    /// `Equatable` no-change guard upstream stays true.
    func clamped(minScale: CGFloat, in bounds: CGRect) -> DeskCamera {
        let floorScale = min(minScale, Self.maxScale)
        let target = min(max(scale, floorScale), Self.maxScale)
        guard target != scale else { return self }
        guard scale > 0, scale.isFinite else {
            return DeskCamera(scale: target, origin: origin)
        }
        let middle = CGPoint(x: bounds.midX, y: bounds.midY)
        let held = canvasPoint(from: middle)
        return DeskCamera(
            scale: target,
            origin: CGPoint(
                x: middle.x - target * held.x,
                y: middle.y - target * held.y
            )
        )
    }

    /// True when scale is exactly 1 and the origin is whole-pixel — the only
    /// state in which panes accept input, and the precondition `flyCamera(to:)`
    /// checks before snapping `sublayerTransform` to identity. Exactly 1, not
    /// within an epsilon: the landing camera is assigned, never accumulated,
    /// and a fractional origin is soft text for as long as it stands.
    var isIdentity: Bool {
        scale == 1
            && origin.x.isFinite && origin.y.isFinite
            && origin.x == origin.x.rounded()
            && origin.y == origin.y.rounded()
    }
```

- [ ] **Step 7: Run the camera tests**

```bash
xcodebuild test -project macos/OmniAgent.xcodeproj -scheme OmniAgent \
  -destination "platform=macOS,arch=$(uname -m)" CODE_SIGNING_ALLOWED=NO \
  -only-testing:OmniAgentTests/DeskCanvasTests
```

Expected: PASS — `Executed N tests, with 0 failures`, where N is Task 2's `DeskCanvasTests` count plus the 7 added here. No `XCTSkip`s: this suite needs no window and no Reduce Motion guard.

- [ ] **Step 8: Run the whole suite**

```bash
./macos/build.sh test
```

Expected: a green `Executed N tests, with 0 failures` line, N being 708 (the pre-plan baseline) plus everything Tasks 1–2 added plus 7. Per the recorded crash-diagnosis rule, **grep for that green line before believing the summary** — "A launch can report a green total underneath a trailing `Failing tests:` list. xcodebuild still exits 65." Nothing in this task can move another test: `DeskCamera` is a new value type with no callers yet.

- [ ] **Step 9: Commit**

Stage only these two paths — never `git add -A`, never `git stash`: concurrent Claude sessions share this working tree, and `project.pbxproj` in particular is being rewritten by other work (`scripts/bump-build-version.sh` has an uncommitted `CURRENT_PROJECT_VERSION` change in it). Check mtimes first, and include `macos/OmniAgent.xcodeproj/project.pbxproj` **only** if Step 1 had to register a file *and* the file is otherwise quiescent.

```bash
ls -l macos/OmniAgent/DeskCanvas.swift macos/OmniAgentTests/DeskCanvasTests.swift
git add macos/OmniAgent/DeskCanvas.swift macos/OmniAgentTests/DeskCanvasTests.swift
git commit -m "feat(macos): DeskCamera — the desk canvas's scale, origin, and its inverse" \
  -m "Pure math, no window: \`viewPoint = canvasPoint * scale + origin\` in
PaneWorkspaceView's flipped space, applied later as one CATransform3D on
\`layer.sublayerTransform\`. Scale then translate, so m41/m42 are the origin
unscaled and \`canvasPoint(from:)\` inverts it exactly — the canvas's hit
testing below identity scale has no other way back, since NSView.convert and
event.locationInWindow are blind to a CALayer transform.

\`focus(on:in:)\` on a viewport-sized rect is exactly 1.0, which is what makes
\"the camera is at 1.0 over this card\" and \"you are in this session\" one
state rather than two. \`fitAll\` is that, on the content plus fitMargin.
\`maxScale\` is 1.0 because SwiftTerm's metalRenderingScaleFactor() is
\`max(1, metalScaleFactorOverride ?? backingScaleFactor())\` — past 1 the
camera magnifies pixels that already exist — and because 1.0 is the only
scale at which the transform is a pure translation and the ten-odd coordinate
conversions in PaneWorkspaceView are still correct.

Degenerate inputs answer identity rather than NaN: a NaN in sublayerTransform
blanks every sublayer and never recovers.

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>
Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01VPUJ6yVc4RPnRhH876yawu"
git push
```

---

### Task 4: The `desk_canvas_native` settings row

**Files:**
- Create: `macos/OmniAgent/DeskCanvasState.swift`
- Create: `macos/OmniAgentTests/DeskCanvasStateTests.swift`
- Modify: `macos/OmniAgent/SettingsKeys.swift` (add one constant directly under `editorPanes`, the last constant in `enum SettingsKey`)
- Modify: `macos/OmniAgent/WorkspaceWindowController.swift` (flag pair immediately after `editorPanesReadCompleted`; a new `// MARK: - Desk canvas persistence` block after `persistEditorPanes()` and before `write(_:to:)`; one call added to the `.connected` arm of `connection.onStateChange` inside `start()`)
- Modify: `macos/OmniAgent.xcodeproj/project.pbxproj` (four entries per new Swift file)
- Test: `macos/OmniAgentTests/DeskCanvasStateTests.swift` (codec)
- Test: `macos/OmniAgentTests/WorkspaceWindowControllerTests.swift` (controller wiring; new section at the end of `// MARK: - Persistence`, immediately before `// MARK: - Sessions`)

**Interfaces:**

- Consumes (from the `DeskCanvas.swift` task — this task must land *after* it):
  - `struct DeskCamera: Equatable { var scale: CGFloat; var origin: CGPoint }` with its synthesized memberwise initializer `DeskCamera(scale:origin:)` and `static let maxScale: CGFloat = 1.0`
- Consumes (existing code, verified in `main`):
  - `enum SettingsKey` — `macos/OmniAgent/SettingsKeys.swift:18`
  - `private func write(_ value: String, to key: String)` — `macos/OmniAgent/WorkspaceWindowController.swift`
  - `var settingsWriter: ((String, String) -> Void)?` — `macos/OmniAgent/WorkspaceWindowController.swift`
  - `func getSetting(key: String, completion: @escaping (Result<String?, Error>) -> Void)` — `macos/OmniAgent/SessionConnection.swift:314`
  - `func applyRestoredPanes(_ panes: [RestoredPane])` — `macos/OmniAgent/WorkspaceWindowController.swift`
  - `@objc func newTerminalPane(_ sender: Any?)` — `macos/OmniAgent/WorkspaceWindowController.swift:767`
- Produces (later tasks rely on exactly these):
  - `static let deskCanvas = "desk_canvas_native"` (on `enum SettingsKey`)
  - `struct DeskCanvasState: Equatable { var pinned: [String: CGPoint] = [:]; var camera: DeskCamera? }`
  - `enum DeskCanvasCodec { static func serialize(_ state: DeskCanvasState) -> String; static func deserialize(_ raw: String?) -> DeskCanvasState }`
  - `static let version = 1` and `static let maxNodeIDLength = 256` on `DeskCanvasCodec` — **not in the fixed shared API; defined by this task.**
One deviation from the fixed shared API, additive and deliberate:

1. `DeskCanvasState.pinned` gains `= [:]`. Optional stored properties already default to `nil` in a synthesized memberwise initializer, so this one default is what makes `DeskCanvasState()` compile — which `deserialize`'s "corrupt row restores to the default" path needs, mirroring `UsageAnalyticsCodec.deserialize`'s `return UsageAnalyticsStore()`. `DeskCanvasState(pinned:camera:)` still compiles unchanged.

---

- [ ] **Step 1: Write the failing codec tests**

Create `macos/OmniAgentTests/DeskCanvasStateTests.swift`. This mirrors `BrowserPanesTests.swift`'s five-test shape (round trip, garbage-to-empty, per-entry repair, per-field repair, exact bytes) plus `EditorPanesTests.swift`'s `testSettingsKey`, plus the version gate and float-quantization cases this row needs and neither neighbour has.

Every byte-pinned literal below was produced by running the Step 6 implementation — they are not guesses. Note in particular that `JSONSerialization` prints a whole-valued `Double` without a decimal point (`12`, not `12.0`), which is why quantizing to whole points also makes the row read cleanly.

```swift
import XCTest
@testable import OmniAgent

/// `DeskCanvasCodec`: the native-only `desk_canvas_native` row's
/// serialize/deserialize pair. Repair shape is `BrowserPanesCodec`'s (a bad
/// field costs the field, a bad entry costs the entry) and the version gate
/// is `UsageAnalyticsCodec`'s (a future build's row is discarded whole, not
/// half-repaired — cheap here, because losing the row costs only pins and a
/// camera, both of which the canvas recomputes).
final class DeskCanvasStateTests: XCTestCase {
    func testRoundTrip() {
        let state = DeskCanvasState(
            pinned: ["session-g1": CGPoint(x: 120, y: -40), "root": CGPoint(x: 0, y: 0)],
            camera: DeskCamera(scale: 0.5, origin: CGPoint(x: 12, y: -34))
        )

        XCTAssertEqual(DeskCanvasCodec.deserialize(DeskCanvasCodec.serialize(state)), state)
    }

    func testRoundTripWithNoCameraAndNoPins() {
        let state = DeskCanvasState()

        XCTAssertEqual(DeskCanvasCodec.deserialize(DeskCanvasCodec.serialize(state)), state)
    }

    func testMissingOrGarbageRawDeserializesToTheDefaultState() {
        XCTAssertEqual(DeskCanvasCodec.deserialize(nil), DeskCanvasState())
        XCTAssertEqual(DeskCanvasCodec.deserialize(""), DeskCanvasState())
        XCTAssertEqual(DeskCanvasCodec.deserialize("}{ not json"), DeskCanvasState())
        XCTAssertEqual(DeskCanvasCodec.deserialize(#"{"pinned":7,"version":1}"#), DeskCanvasState())
    }

    func testAFutureVersionRowIsDiscardedWholeRatherThanHalfRepaired() {
        let raw = #"{"camera":{"scale":0.5,"x":0,"y":0},"pinned":{"a":{"x":1,"y":2}},"version":2}"#

        XCTAssertEqual(
            DeskCanvasCodec.deserialize(raw),
            DeskCanvasState(),
            "a row a future build wrote is thrown away, not partially read"
        )
    }

    func testAMalformedPinCostsOnlyThatNodeNotTheWholeRow() {
        let raw = #"""
        {"pinned":{
          "good":{"x":1,"y":2},
          "wrong-type":{"x":"nope","y":2},
          "not-a-point":7
        },"version":1}
        """#

        let state = DeskCanvasCodec.deserialize(raw)

        XCTAssertEqual(state.pinned, ["good": CGPoint(x: 1, y: 2)])
    }

    func testAMalformedCameraCostsOnlyTheCameraNotThePins() {
        let raw = #"{"camera":{"scale":0,"x":0,"y":0},"pinned":{"good":{"x":1,"y":2}},"version":1}"#

        let state = DeskCanvasCodec.deserialize(raw)

        XCTAssertNil(state.camera, "a zero scale is a singular transform, not a camera")
        XCTAssertEqual(state.pinned, ["good": CGPoint(x: 1, y: 2)], "the pins survive it")
    }

    func testAnOverscaledCameraIsClampedToMaxScaleRatherThanDropped() {
        let raw = #"{"camera":{"scale":4,"x":0,"y":0},"pinned":{},"version":1}"#

        XCTAssertEqual(
            DeskCanvasCodec.deserialize(raw).camera,
            DeskCamera(scale: DeskCamera.maxScale, origin: .zero)
        )
    }

    func testANonFinitePinIsDroppedRatherThanPoisoningTheTransform() {
        let json = DeskCanvasCodec.serialize(
            DeskCanvasState(pinned: ["bad": CGPoint(x: CGFloat.nan, y: 0)], camera: nil)
        )

        XCTAssertEqual(
            json,
            #"{"pinned":{},"version":1}"#,
            "a NaN in a CATransform3D is a silently invisible view, not a crash"
        )
    }

    func testAControlCharacterOrOverlongNodeIDDropsOnlyThatPin() {
        let json = DeskCanvasCodec.serialize(
            DeskCanvasState(
                pinned: [
                    "workspace:OmniAgent-ADE": CGPoint(x: 3, y: 4),
                    "bad\u{7}id": CGPoint(x: 1, y: 2),
                    String(repeating: "a", count: DeskCanvasCodec.maxNodeIDLength + 1): CGPoint(x: 5, y: 6),
                ],
                camera: nil
            )
        )

        XCTAssertEqual(json, #"{"pinned":{"workspace:OmniAgent-ADE":{"x":3,"y":4}},"version":1}"#)
    }

    func testSerializeOutputIsStableAndSorted() {
        // Key order is what this pins: top level `camera` < `pinned` <
        // `version`, and `pinned`'s own node-id keys sorted. `pinned` is a
        // dictionary keyed by node id, so without `.sortedKeys` its order is
        // unstable by construction and `write(_:to:)`'s dedupe never fires.
        let json = DeskCanvasCodec.serialize(
            DeskCanvasState(
                pinned: ["session-g1": CGPoint(x: 120, y: -40), "root": CGPoint(x: 0, y: 0)],
                camera: DeskCamera(scale: 0.5, origin: CGPoint(x: 12, y: -34))
            )
        )

        XCTAssertEqual(
            json,
            #"{"camera":{"scale":0.5,"x":12,"y":-34},"pinned":{"root":{"x":0,"y":0},"session-g1":{"x":120,"y":-40}},"version":1}"#
        )
    }

    func testSerializingIsByteStableSoTheUnchangedRowGuardHolds() {
        // The gotcha this test exists for: `write(_:to:)` suppresses a write
        // only when the serialized string is byte-identical, and this row
        // stores floats. A camera whose scale is 0.5000000000000001 one frame
        // and 0.5 the next would otherwise serialize differently and defeat
        // the only throttle in the system.
        let jittered = DeskCanvasState(
            pinned: ["a": CGPoint(x: 120.0000001, y: -40.4)],
            camera: DeskCamera(scale: 0.5000000000000001, origin: CGPoint(x: 12.2, y: -33.7))
        )
        let settled = DeskCanvasState(
            pinned: ["a": CGPoint(x: 120, y: -40)],
            camera: DeskCamera(scale: 0.5, origin: CGPoint(x: 12, y: -34))
        )

        XCTAssertEqual(DeskCanvasCodec.serialize(jittered), DeskCanvasCodec.serialize(settled))
        XCTAssertEqual(DeskCanvasCodec.serialize(jittered), DeskCanvasCodec.serialize(jittered))
    }

    func testNegativeZeroSerializesAsZero() {
        // Two visually identical origins that print differently (`-0` vs `0`)
        // would each look like a change to the dedupe.
        XCTAssertEqual(
            DeskCanvasCodec.serialize(
                DeskCanvasState(pinned: ["a": CGPoint(x: -0.4, y: 0)], camera: nil)
            ),
            #"{"pinned":{"a":{"x":0,"y":0}},"version":1}"#
        )
    }

    func testSettingsKey() {
        XCTAssertEqual(SettingsKey.deskCanvas, "desk_canvas_native")
    }
}
```

- [ ] **Step 2: Register both new files in the Xcode project**

The project is `objectVersion = 77` but has **no** `PBXFileSystemSynchronizedRootGroup`, so each new file needs four hand-edits. Verbatim from `docs/superpowers/plans/2026-08-18-editor-pane.md:17`:

> **pbxproj registration procedure** (the project does NOT use file-system-synchronized groups — every new file must be registered by hand): for each new Swift file, add four entries to `macos/OmniAgent.xcodeproj/project.pbxproj`: (1) a `PBXBuildFile` line in the build-file section, (2) a `PBXFileReference` line in the file-reference section, (3) the file reference id in the `OmniAgent` (app sources) or `OmniAgentTests` PBXGroup `children` list, (4) the build-file id in that target's `PBXSourcesBuildPhase` `files` list.

Gotcha, quoted from the research: *"a file registered in the PBXGroup but not in the PBXSourcesBuildPhase compiles nowhere and produces a confusing 'cannot find type in scope' at the call site rather than a missing-file error."* All four, both files.

The four object ids below were generated with `uuidgen | tr -d '-' | cut -c1-24 | tr 'a-f' 'A-F'` and confirmed absent from the file. Re-confirm before pasting, since the tree is under concurrent edit:

```
grep -c '43DFECC6CB8F4285921E6A5A\|371418F52B4143BE9B762348\|E6B9FB15113B4C25B1F8D0BE\|E2FE4A1FC6B7429A8E79A4F9' macos/OmniAgent.xcodeproj/project.pbxproj
```
Expect `0`. If not, generate replacements with the `uuidgen` recipe.

Indentation on every line below is **two tab characters**.

Edit 1 — `PBXBuildFile` section, immediately after the `EditorPanes.swift in Sources` line:
```
		43DFECC6CB8F4285921E6A5A /* DeskCanvasState.swift in Sources */ = {isa = PBXBuildFile; fileRef = 371418F52B4143BE9B762348 /* DeskCanvasState.swift */; };
```
and, immediately after the `EditorPanesTests.swift in Sources` line:
```
		E6B9FB15113B4C25B1F8D0BE /* DeskCanvasStateTests.swift in Sources */ = {isa = PBXBuildFile; fileRef = E2FE4A1FC6B7429A8E79A4F9 /* DeskCanvasStateTests.swift */; };
```

Edit 2 — `PBXFileReference` section, after the `EditorPanes.swift` and `EditorPanesTests.swift` references respectively:
```
		371418F52B4143BE9B762348 /* DeskCanvasState.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = DeskCanvasState.swift; sourceTree = "<group>"; };
```
```
		E2FE4A1FC6B7429A8E79A4F9 /* DeskCanvasStateTests.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = DeskCanvasStateTests.swift; sourceTree = "<group>"; };
```

Edit 3 — the `500000000000000000000002 /* OmniAgent */` PBXGroup `children` list, after the `BACAA95FB7844450B021094B /* EditorPanes.swift */,` entry:
```
				371418F52B4143BE9B762348 /* DeskCanvasState.swift */,
```
and the `500000000000000000000003 /* OmniAgentTests */` PBXGroup `children` list, after the `2639724864074430BA56B5D3 /* EditorPanesTests.swift */,` entry:
```
				E2FE4A1FC6B7429A8E79A4F9 /* DeskCanvasStateTests.swift */,
```

Edit 4 — the app target's `800000000000000000000001 /* Sources */` `files` list, after the `53C290D7733E43F89B368514 /* EditorPanes.swift in Sources */,` entry:
```
				43DFECC6CB8F4285921E6A5A /* DeskCanvasState.swift in Sources */,
```
and the test target's `800000000000000000000002 /* Sources */` `files` list, after the `69D406BCC81448EF8CA13D9D /* EditorPanesTests.swift in Sources */,` entry:
```
				E6B9FB15113B4C25B1F8D0BE /* DeskCanvasStateTests.swift in Sources */,
```

- [ ] **Step 3: Run it and watch it fail**

Run:
```
xcodebuild test -project macos/OmniAgent.xcodeproj -scheme OmniAgent \
  -destination "platform=macOS,arch=$(uname -m)" CODE_SIGNING_ALLOWED=NO \
  -only-testing:OmniAgentTests/DeskCanvasStateTests
```
Expected: the *build* fails before any test runs, with
`error: cannot find 'DeskCanvasCodec' in scope`,
`error: cannot find 'DeskCanvasState' in scope`, and
`error: type 'SettingsKey' has no member 'deskCanvas'`
in `DeskCanvasStateTests.swift`. (`DeskCamera` must already resolve — if it reports `cannot find 'DeskCamera' in scope`, the `DeskCanvas.swift` task has not landed yet and this task is out of order.)

- [ ] **Step 4: Add the settings key**

In `macos/OmniAgent/SettingsKeys.swift`, add one constant inside `enum SettingsKey`, directly under `editorPanes` (the last constant; the enum closes on the next line). Keep the neighbours' voice and end with the same sentence they do.

The file header states the rule this satisfies: *"a constant nothing reads is a claim this build honours a setting it does not"* — the reader and the writer both land in this same task (Steps 8–9).

```swift
    /// Native-only — `browserPanes`'s reasoning a third time: the web build
    /// rewrites the shared `layout` row and strips the fields it does not
    /// know, and it knows nothing about a canvas. The Desk canvas's pinned
    /// node positions and last camera; unpinned nodes are recomputed by
    /// `DeskCanvas.layout` every launch and are not stored. One JSON object,
    /// `{"version":1,"pinned":{<node id>:{x,y}},"camera":{scale,x,y}}` — see
    /// `DeskCanvasCodec`. No TypeScript twin, by design.
    static let deskCanvas = "desk_canvas_native"
```

- [ ] **Step 5: Run it and watch the failure shrink**

Run:
```
xcodebuild test -project macos/OmniAgent.xcodeproj -scheme OmniAgent \
  -destination "platform=macOS,arch=$(uname -m)" CODE_SIGNING_ALLOWED=NO \
  -only-testing:OmniAgentTests/DeskCanvasStateTests
```
Expected: still a build failure, but now only `cannot find 'DeskCanvasCodec' in scope` and `cannot find 'DeskCanvasState' in scope`. The `SettingsKey` error is gone.

- [ ] **Step 6: Implement the state type and the codec**

Create `macos/OmniAgent/DeskCanvasState.swift`. `import Foundation` alone is correct — `PaneGrid.swift` does exactly this and declares `struct PaneDivider: Equatable { let frame: CGRect }`.

Two house rules are load-bearing here and are quoted inline so they survive a future edit:

- **`JSONSerialization`, never `Codable`.** `PersistedLayout.swift:92-96`: *"`deserialize` must tolerate individually malformed fields … without losing the whole pane, which a strict `Codable`/`JSONDecoder` parse cannot express — a throwing decode of one array element fails the entire array."* Here that is: one unreadable pin drops that node, an unreadable camera drops the camera, and neither costs the row.
- **`.sortedKeys` is load-bearing, not cosmetic.** `BrowserPanes.swift:25-29`, verbatim: *"`.sortedKeys` for exactly `PersistedLayoutCodec.serialize`'s reason: `WorkspaceWindowController.write(_:to:)` dedupes a settings write by comparing this string to the last one written, and `Dictionary` iteration order is not stable across two dictionaries holding the same pairs."*

```swift
import Foundation

/// The Desk canvas's persisted state: the pinned node positions the tidy
/// tree must honour, and the camera the canvas comes back to. Unpinned nodes
/// are recomputed by `DeskCanvas.layout` on every launch and are deliberately
/// not stored — which is also why losing this row is cheap.
///
/// `pinned` is keyed by `DeskNode.id` and holds positions in the canvas's own
/// **flipped** space (`PaneWorkspaceView.isFlipped == true`, y growing
/// downward), the same space `DeskCanvasLayout.frames` uses.
struct DeskCanvasState: Equatable {
    var pinned: [String: CGPoint] = [:]
    var camera: DeskCamera?
}

/// Serializes/deserializes the `desk_canvas_native` settings row —
/// `{"version":1,"pinned":{<node id>:{x,y}},"camera":{scale,x,y}}`.
///
/// `JSONSerialization` rather than `Codable`, the house convention stated at
/// `PersistedLayoutCodec`: a throwing decode of one malformed element fails
/// the whole parse, and the repair contract here is `BrowserPanesCodec`'s —
/// a bad field costs the field, a bad entry costs the entry.
///
/// Versioned like `UsageAnalyticsCodec`: a row a *future* build wrote is
/// discarded whole rather than half-repaired.
enum DeskCanvasCodec {
    static let version = 1

    /// A `DeskNode.id` length bound. Deliberately looser than
    /// `SessionIdentifier.isValid`, which is byte-strict because, per its own
    /// doc, "an id becomes both a transcript filename and a tmux target on
    /// the Rust side". A node id is neither: it namespaces a brain project id
    /// (an arbitrary label that may hold spaces and non-ASCII) or a group id.
    /// So only the two things that make a key unusable are rejected —
    /// unbounded length and control characters.
    static let maxNodeIDLength = 256

    static func serialize(_ state: DeskCanvasState) -> String {
        var pinned: [String: Any] = [:]
        for (id, point) in state.pinned where isValidNodeID(id) {
            guard let x = coordinate(point.x), let y = coordinate(point.y) else { continue }
            pinned[id] = ["x": x, "y": y]
        }
        // Absence is the missing key, never `null` — `WorkspaceRestoration`'s
        // rule for the shared row, applied here.
        var payload: [String: Any] = ["version": version, "pinned": pinned]
        if let camera = state.camera,
           let scale = quantizedScale(camera.scale),
           let x = coordinate(camera.origin.x),
           let y = coordinate(camera.origin.y) {
            payload["camera"] = ["scale": scale, "x": x, "y": y]
        }
        guard
            JSONSerialization.isValidJSONObject(payload),
            // `.sortedKeys` for exactly `PersistedLayoutCodec.serialize`'s
            // reason: `WorkspaceWindowController.write(_:to:)` dedupes a
            // settings write by comparing this string to the last one
            // written, and `Dictionary` iteration order is not stable across
            // two dictionaries holding the same pairs. It matters more here
            // than in either pane row: `pinned` *is* a dictionary keyed by
            // node id, so its order is unstable by construction.
            let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
            let json = String(data: data, encoding: .utf8)
        else {
            return #"{"pinned":{},"version":1}"#
        }
        return json
    }

    /// Never throws — a corrupt, missing or future-version row restores to
    /// "no pins, no camera" rather than breaking launch. Repair rules:
    ///
    /// - a `version` that is not exactly `1` discards the whole row (a future
    ///   build's shape must not be half-read);
    /// - a pin whose value is not `{x, y}` of finite in-range numbers drops
    ///   just that node;
    /// - a node id that is empty, over `maxNodeIDLength`, or holds a control
    ///   character drops just that node;
    /// - a camera with a non-finite or non-positive scale, or an unreadable
    ///   origin, drops just the camera — the pins survive it;
    /// - a scale above `DeskCamera.maxScale` is clamped, not dropped (the
    ///   spec's "no zoom above 1.0" is a clamp everywhere else too).
    static func deserialize(_ raw: String?) -> DeskCanvasState {
        guard
            let raw, !raw.isEmpty,
            let data = raw.data(using: .utf8),
            let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            number(parsed["version"]) == Double(version)
        else {
            return DeskCanvasState()
        }

        var state = DeskCanvasState()
        if let rawPinned = parsed["pinned"] as? [String: Any] {
            for (id, value) in rawPinned {
                guard isValidNodeID(id), let point = decodePoint(value) else { continue }
                state.pinned[id] = point
            }
        }
        if let rawCamera = parsed["camera"] as? [String: Any],
           let rawScale = number(rawCamera["scale"]),
           let scale = quantizedScale(CGFloat(rawScale)),
           let origin = decodePoint(rawCamera) {
            state.camera = DeskCamera(scale: CGFloat(scale), origin: origin)
        }
        return state
    }

    private static func decodePoint(_ value: Any?) -> CGPoint? {
        guard
            let dict = value as? [String: Any],
            let x = number(dict["x"]).flatMap({ coordinate(CGFloat($0)) }),
            let y = number(dict["y"]).flatMap({ coordinate(CGFloat($0)) })
        else {
            return nil
        }
        return CGPoint(x: x, y: y)
    }

    /// `UsageAnalytics.swift:423`'s decoder verbatim. `as? Double` reads an
    /// integral JSON number too, through `NSNumber` bridging; `as? Int` on a
    /// fractional value returns nil, so `Double` is the only safe choice for
    /// anything geometric.
    private static func number(_ raw: Any?) -> Double? {
        raw as? Double
    }

    /// Positions round to whole canvas points. Two reasons, both real:
    /// `write(_:to:)`'s dedupe is *string* equality and there is no debounce
    /// helper anywhere in `WorkspaceWindowController`, so an origin of
    /// 12.2000001 and one of 12.2 would look like two different rows; and a
    /// pin is where a drag landed, where sub-point precision is noise.
    /// `+ 0` collapses `-0.0` onto `0.0`, which otherwise prints as `-0` and
    /// makes an unchanged position look changed. The `isFinite` guard is
    /// `UsageAnalyticsCodec.nonNegative`'s, and it is what keeps a NaN out of
    /// a `CATransform3D` — a silently invisible view, not a crash.
    private static func coordinate(_ value: CGFloat) -> Double? {
        guard value.isFinite, abs(value) <= 1_000_000 else { return nil }
        return Double(value).rounded() + 0
    }

    /// Scale quantizes to four places — finer than any zoom step the camera
    /// takes, and still enough to collapse 0.5000000000000001 onto 0.5.
    /// Clamped at `DeskCamera.maxScale`; a non-positive scale is a singular
    /// transform, not a camera, so it drops the camera instead.
    private static func quantizedScale(_ value: CGFloat) -> Double? {
        guard value.isFinite, value > 0 else { return nil }
        let capped = min(Double(value), Double(DeskCamera.maxScale))
        return (capped * 10_000).rounded() / 10_000 + 0
    }

    private static func isValidNodeID(_ value: String) -> Bool {
        guard (1...maxNodeIDLength).contains(value.count) else { return false }
        return value.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7F }
    }
}
```

- [ ] **Step 7: Run the codec tests**

Run:
```
xcodebuild test -project macos/OmniAgent.xcodeproj -scheme OmniAgent \
  -destination "platform=macOS,arch=$(uname -m)" CODE_SIGNING_ALLOWED=NO \
  -only-testing:OmniAgentTests/DeskCanvasStateTests
```
Expected: PASS — `Executed 13 tests, with 0 failures`.

Per the crash-diagnosis memory: *"A launch can report a green total underneath a trailing `Failing tests:` list. xcodebuild still exits 65. Grep for a green `Executed N tests` before believing the summary."*

- [ ] **Step 8: Run the whole suite**

Run:
```
./macos/build.sh test
```
Expected: PASS with `0 failures`, and the executed count higher than the run recorded at the start of this task by exactly the 13 codec tests added here. Quote the green `Executed N tests` line rather than trusting the summary — a launch can print a green total above a trailing `Failing tests:` list and still exit 65.

> **Scope boundary.** This task ends at the codec. Every `WorkspaceWindowController` change for this row — the `deskCanvasReadDispatched`/`deskCanvasReadCompleted` gate pair, `restoreDeskCanvasIfNeeded()`, `applyRestoredDeskCanvas(_:)`, `persistDeskCanvas()`, and the hook into the `.connected` arm — belongs to **Task 10e**, which owns it end to end including the write debounce. Do not add controller members here; declaring them in both tasks is a redeclaration error.

- [ ] **Step 9: Commit and push**

Check mtimes before staging — the tree is shared with concurrent sessions, and `git stash` is never an option here:

```
cd /Users/bonando/Documents/Bruno.Digital/OmniAgent-ADE && \
  ls -l macos/OmniAgent/DeskCanvasState.swift macos/OmniAgent/SettingsKeys.swift \
        macos/OmniAgent/WorkspaceWindowController.swift \
        macos/OmniAgentTests/DeskCanvasStateTests.swift \
        macos/OmniAgentTests/WorkspaceWindowControllerTests.swift \
        macos/OmniAgent.xcodeproj/project.pbxproj
```

Then:

```
cd /Users/bonando/Documents/Bruno.Digital/OmniAgent-ADE && \
git add macos/OmniAgent/DeskCanvasState.swift \
        macos/OmniAgent/SettingsKeys.swift \
        macos/OmniAgent/WorkspaceWindowController.swift \
        macos/OmniAgentTests/DeskCanvasStateTests.swift \
        macos/OmniAgentTests/WorkspaceWindowControllerTests.swift \
        macos/OmniAgent.xcodeproj/project.pbxproj && \
git commit -m "$(cat <<'EOF'
feat(macos): DeskCanvasCodec + the desk_canvas_native settings row

The Desk canvas's pinned node positions and last camera get their own
native-only row, on `browser_panes_native`'s reasoning a third time: the
web build rewrites the shared `layout` row and strips the fields it does
not know, and it knows nothing about a canvas.

`JSONSerialization` with `.sortedKeys`, not `Codable` — per-field repair
(a bad pin costs that node, a bad camera costs the camera, neither costs
the row) is unexpressible with `JSONDecoder`, and the sorted keys are
what `WorkspaceWindowController.write(_:to:)`'s "only write when it
actually changed" dedupe compares. `pinned` is a dictionary keyed by
node id, so without them its order is unstable by construction.

Because the dedupe is string equality and this row stores floats,
positions quantize to whole canvas points and scale to four places, with
`-0.0` folded onto `0.0`; there is no debounce anywhere in the
controller, so the dedupe is the only throttle. Non-finite values are
dropped rather than serialized — a NaN in a `CATransform3D` is a
silently invisible view, not a crash.

Versioned like `usage_analytics_v1`: a future build's row is discarded
whole, which costs only pins and a camera since unpinned nodes are
recomputed every launch.

Codec only. Task 10e owns the controller wiring for this row — the
`readDispatched`/`readCompleted` pair, the re-arming failure path, the
read off the `.connected` arm, and the debounced write — so that the
gate pair is declared in exactly one task.

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>
Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)" && git push
```

---

### Task 5: Canvas mode in `PaneWorkspaceView` — lay every group's grid out at its node rect

**Files:**
- Modify: `macos/OmniAgent/PaneWorkspaceView.swift` (new `// MARK: - Canvas mode` section inserted immediately before the `// MARK: - Occlusion` section, i.e. after `canAcceptDrop(from:onto:)`; new layout helpers added in the `// MARK: - Layout` section after `syncDividerViews(_:)`; one-line branch at the top of `updateLayout()`; one line changed in `updateVisibility()`; the placeholder construction inside `syncHolePlaceholders(_:holeIDs:)` extracted to a factory)
- Modify: `macos/OmniAgent.xcodeproj/project.pbxproj` (four registration entries for the new test file)
- Test: `macos/OmniAgentTests/PaneWorkspaceCanvasModeTests.swift` (new)

**Interfaces:**

- Consumes (from Task 1, `DeskCanvas.swift`):
  - `static func DeskCanvas.layout(root: DeskNode, cardSize: CGSize, pinned: [String: CGPoint]) -> DeskCanvasLayout`
  - `struct DeskCanvasLayout: Equatable { let frames: [String: CGRect]; let edges: [DeskEdge]; let contentRect: CGRect }`
  - `struct DeskNode: Equatable { let id: String; let kind: Kind; let children: [DeskNode] }` with the memberwise `DeskNode(id:kind:children:)` and `DeskNode.Kind.root / .workspace(String) / .session(String)`
  - `struct DeskCamera: Equatable { var scale: CGFloat; var origin: CGPoint; var transform: CATransform3D { get } }` with the memberwise `DeskCamera(scale:origin:)`. **This task depends on `transform` being the top-left affine `viewPoint = scale * canvasPoint + origin`** — i.e. `CATransform3DConcat(CATransform3DMakeScale(scale, scale, 1), CATransform3DMakeTranslation(origin.x, origin.y, 0))` — which is exactly the map `canvasPoint(from:)` inverts as `(viewPoint - origin) / scale`.
- Consumes (existing, verified in the file):
  - `PaneGrid.layout(in: CGRect, dividerThickness: CGFloat) -> PaneLayout`, `PaneGrid.cells: [PaneCell]` (`private(set)`, readable), `PaneCell.id`, `PaneCell.paneID`
  - `PaneWorkspaceView.gridInset: CGFloat = 7`, `PaneWorkspaceView.dividerThickness: CGFloat = 6`, `gridBounds`, `grids`, `groupOrder`, `activeGroup`, `containers`, `descriptors`, `overlayPaneID`, `place(_:at:from:)`, `syncDividerViews(_:)`, `updateAccessibilityLabels()`, `refreshFocusSubtitles()`, `setZoomed(_:)`, `finishZoomTransition(_:)`, `zoomTransitionToken`
- Produces (later tasks rely on these):
  - `var canvasMode: Bool { get set }` on `PaneWorkspaceView`
  - `var camera: DeskCamera { get set }` on `PaneWorkspaceView`
  - `var canvasRoot: DeskNode?` — the organigram to lay out; `nil` means "derive from the panes this view holds" *(not in the fixed shared API; defined by this task)*
  - `var canvasPins: [String: CGPoint]` — pinned node positions handed straight to `DeskCanvas.layout` *(not in the fixed shared API; defined by this task)*
  - `private(set) var canvasLayout: DeskCanvasLayout?` — the last canvas pass's node rects, for the camera (`fitAll` needs `contentRect`) and for hit testing *(defined by this task)*
  - `var canvasCardSize: CGSize { get }` — always `bounds.size` *(defined by this task)*
  - `func derivedCanvasRoot() -> DeskNode` *(defined by this task)*
  - Not in this task: `flyCamera(to:)`, `enterSession(_:)`, `exitToCanvas()`.

---

- [ ] **Step 1: Write the failing test file**

Create `macos/OmniAgentTests/PaneWorkspaceCanvasModeTests.swift`. A separate suite rather than more of `PaneWorkspaceViewTests.swift`: that file is ~3,800 lines and growing and under concurrent edit in this shared worktree, and this suite needs its own two-session helper anyway (`makeWorkspace(panes:)` there hard-codes `group: "sess-grp-1"`).

```swift
import AppKit
import QuartzCore
import XCTest
@testable import OmniAgent

/// Canvas mode is the *second answer* `PaneWorkspaceView` gives to the same
/// layout question. Normal mode: `activeGroup`'s grid fills `bounds` and every
/// other session is hidden. Canvas mode: every session's grid is laid out at
/// its own card rect in canvas coordinates and one `sublayerTransform` decides
/// what is on screen.
///
/// The three things this suite exists to hold down: normal mode is unchanged
/// (including after a round trip through the canvas), each session lands on its
/// own node rect, and the grid *inside* a card is byte-for-byte the grid normal
/// mode draws for that session — because a card is exactly the Desk viewport,
/// which is what makes "camera at 1.0 over this card" and "you are in that
/// session" the same picture.
final class PaneWorkspaceCanvasModeTests: XCTestCase {
    // MARK: - Normal mode is untouched

    func testNormalModeStillLaysTheActiveSessionOutFromGridBoundsAfterACanvasRoundTrip() throws {
        let workspace = makeCanvasWorkspace()
        let expected = try XCTUnwrap(workspace.grid).layout(
            in: workspace.gridBounds,
            dividerThickness: PaneWorkspaceView.dividerThickness
        )
        for id in workspace.paneIDs {
            XCTAssertEqual(workspace.container(for: id)?.frame, expected.frames[id], "\(id) before")
        }

        workspace.canvasMode = true
        workspace.camera = DeskCamera(scale: 0.4, origin: CGPoint(x: -120, y: -80))
        workspace.canvasMode = false

        for id in workspace.paneIDs {
            XCTAssertEqual(workspace.container(for: id)?.frame, expected.frames[id], "\(id) after")
        }
        XCTAssertEqual(
            workspace.paneIDs.sorted(),
            ["a-1", "a-2", "a-3"],
            "the same session is on screen"
        )
        XCTAssertEqual(
            workspace.container(for: "b-1")?.isHidden,
            true,
            "and the other one is off it again"
        )
        XCTAssertTrue(
            CATransform3DIsIdentity(try XCTUnwrap(workspace.layer).sublayerTransform),
            "leaving the canvas takes the camera off the layer"
        )
    }

    // MARK: - Canvas mode

    func testCanvasModeLaysEverySessionOutAtItsOwnCardRect() throws {
        let workspace = makeCanvasWorkspace()
        workspace.canvasMode = true

        let root = workspace.derivedCanvasRoot()
        let layout = DeskCanvas.layout(root: root, cardSize: workspace.bounds.size, pinned: [:])

        for (group, panes) in Self.sessions {
            let node = try XCTUnwrap(group, "every session is a node")
            let card = try XCTUnwrap(layout.frames[node], "and every node has a rect")
            XCTAssertEqual(card.size, workspace.bounds.size, "a card is exactly the Desk viewport")
            for id in panes {
                let frame = try XCTUnwrap(workspace.container(for: id)?.frame)
                XCTAssertTrue(
                    card.insetBy(dx: -0.5, dy: -0.5).contains(frame),
                    "\(id) sits inside \(group)'s card"
                )
                // Not a blanket `isHidden == false`: Task 6a adds viewport
                // culling, and this fixture's second card sits outside the
                // default camera's viewport. What canvas mode guarantees is
                // that a pane is hidden only for being off-viewport — never
                // for belonging to a session that is not `activeGroup`.
                XCTAssertEqual(
                    workspace.container(for: id)?.isHidden,
                    !card.intersects(workspace.camera.canvasViewport(in: workspace.bounds)),
                    "\(id) is hidden only if its card is off-viewport"
                )
            }
        }
    }

    /// A card is the Desk viewport, so the panes in it must sit exactly where
    /// scale 1.0 will show them: the same sizes, offset by the card's origin and
    /// by nothing else. Anything else and entering a session would nudge the
    /// grid as the camera lands.
    func testACardsPanesSitExactlyWhereNormalModeWouldPutThem() throws {
        let workspace = makeCanvasWorkspace()

        // What normal mode puts each pane at, read off the real thing one
        // session at a time. A session that leaves the screen keeps its frames,
        // so these stay valid once the next one is activated.
        var normal: [String: CGRect] = [:]
        for group in workspace.groupIDs {
            workspace.activateGroup(group)
            for id in workspace.paneIDs {
                normal[id] = try XCTUnwrap(workspace.container(for: id)?.frame)
            }
        }

        workspace.canvasMode = true
        let root = workspace.derivedCanvasRoot()
        let layout = DeskCanvas.layout(root: root, cardSize: workspace.bounds.size, pinned: [:])

        for (group, panes) in Self.sessions {
            let card = try XCTUnwrap(layout.frames[try XCTUnwrap(group)])
            for id in panes {
                let canvas = try XCTUnwrap(workspace.container(for: id)?.frame)
                let flat = try XCTUnwrap(normal[id])
                XCTAssertEqual(canvas.minX - flat.minX, card.minX, accuracy: 0.001, "\(id) x")
                XCTAssertEqual(canvas.minY - flat.minY, card.minY, accuracy: 0.001, "\(id) y")
                XCTAssertEqual(canvas.width, flat.width, accuracy: 0.001, "\(id) width")
                XCTAssertEqual(canvas.height, flat.height, accuracy: 0.001, "\(id) height")
            }
        }
    }

    /// The camera is one `sublayerTransform` and nothing else. Container frames
    /// stay in canvas coordinates, so `PaneGrid`, `place`, the resize coalescer
    /// and the PTY never learn that a zoom happened.
    func testTheCameraIsOneSublayerTransformAndLeavesEveryContainerFrameInCanvasSpace() throws {
        let workspace = makeCanvasWorkspace()
        workspace.canvasMode = true
        let before = workspace.allPaneIDs.compactMap { workspace.container(for: $0)?.frame }

        workspace.camera = DeskCamera(scale: 0.5, origin: CGPoint(x: 30, y: 20))

        let after = workspace.allPaneIDs.compactMap { workspace.container(for: $0)?.frame }
        XCTAssertEqual(before, after, "the camera never touches a frame")
        XCTAssertFalse(
            CATransform3DIsIdentity(try XCTUnwrap(workspace.layer).sublayerTransform),
            "it is on the layer instead"
        )

        let atOrigin = rendered(.zero, in: workspace)
        XCTAssertEqual(atOrigin.x, 30, accuracy: 0.001, "canvas (0,0) renders at the camera origin")
        XCTAssertEqual(atOrigin.y, 20, accuracy: 0.001)
        let far = rendered(CGPoint(x: 400, y: 200), in: workspace)
        XCTAssertEqual(far.x, 0.5 * 400 + 30, accuracy: 0.001, "and every point at scale * p + origin")
        XCTAssertEqual(far.y, 0.5 * 200 + 20, accuracy: 0.001)
    }

    // MARK: - Helpers

    private static let sessions: [(group: String, panes: [String])] = [
        ("sess-grp-a", ["a-1", "a-2", "a-3"]),
        ("sess-grp-b", ["b-1", "b-2"]),
    ]

    /// Where the compositor actually puts a canvas point. `sublayerTransform` is
    /// applied about the layer's **anchor point** — the centre of `bounds` — not
    /// about its corner, which is the exact fold `applyCamera` has to undo.
    private func rendered(_ point: CGPoint, in view: NSView) -> CGPoint {
        guard let layer = view.layer else { return point }
        let matrix = CATransform3DGetAffineTransform(layer.sublayerTransform)
        let centre = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        let mapped = CGPoint(x: point.x - centre.x, y: point.y - centre.y).applying(matrix)
        return CGPoint(x: centre.x + mapped.x, y: centre.y + mapped.y)
    }

    /// Two sessions in one project — three panes and two — with the first on
    /// screen. The production `makeSurface` shape, against a socket nobody is
    /// listening on, exactly as every other workspace suite in this target does.
    private func makeCanvasWorkspace() -> PaneWorkspaceView {
        let connection = SessionConnection(
            socketURL: URL(fileURLWithPath: "/tmp/omniagent-desk-canvas-test.sock")
        )
        let workspace = PaneWorkspaceView { descriptor in
            switch descriptor.kind {
            case .terminal:
                return TerminalSurfaceView(connection: connection, sessionID: descriptor.sessionID)
            case .browser:
                return BrowserPaneView(initialURL: descriptor.browserURL)
            case .editor:
                return EditorPaneView(
                    initialTabs: descriptor.editorTabs,
                    activeIndex: descriptor.editorActiveIndex
                )
            }
        }
        workspace.frame = CGRect(x: 0, y: 0, width: 1200, height: 800)
        for (group, panes) in Self.sessions {
            for id in panes {
                XCTAssertTrue(workspace.addPane(makeDescriptor(id, group: group)))
            }
        }
        workspace.activateGroup("sess-grp-a")
        return workspace
    }

    private func makeDescriptor(_ id: String, group: String) -> PaneDescriptor {
        PaneDescriptor(sessionID: id, group: group, title: "", project: "OmniAgent-ADE")
    }
}
```

---

- [ ] **Step 2: Register the test file in the Xcode project**

The project is `objectVersion = 77` but has **no** `PBXFileSystemSynchronizedRootGroup`: dropping a `.swift` file into `macos/OmniAgentTests/` silently compiles nothing and runs nothing. Four hand-edits, indentation is **two tab characters** on each. `project.pbxproj` is a hot, shared file (`scripts/bump-build-version.sh` rewrites `CURRENT_PROJECT_VERSION` in it, and concurrent sessions edit it) — **insert lines adjacent to existing ones, never rewrite a section, and never `git stash` here.**

Edit 1 — `PBXBuildFile` section, immediately after the `GitFileContentTests.swift` line (`1ECF599C46245E2BA8447FC1 /* GitFileContentTests.swift in Sources */ = …`):
```
		FD4C61B478ED4F0BB9AD83A9 /* PaneWorkspaceCanvasModeTests.swift in Sources */ = {isa = PBXBuildFile; fileRef = D00EE8F1E07540A09980F775 /* PaneWorkspaceCanvasModeTests.swift */; };
```

Edit 2 — `PBXFileReference` section, immediately after the `GitFileContentTests.swift` reference (`BE0A2CB26F101E0CCC68EFBA /* GitFileContentTests.swift */ = …`):
```
		D00EE8F1E07540A09980F775 /* PaneWorkspaceCanvasModeTests.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = PaneWorkspaceCanvasModeTests.swift; sourceTree = "<group>"; };
```

Edit 3 — the `500000000000000000000003 /* OmniAgentTests */` `PBXGroup` `children` list, immediately after the `200000000000000000000010 /* PaneWorkspaceViewTests.swift */,` child:
```
				D00EE8F1E07540A09980F775 /* PaneWorkspaceCanvasModeTests.swift */,
```

Edit 4 — the test target's `800000000000000000000002 /* Sources */` `PBXSourcesBuildPhase` `files` list, immediately after `10000000000000000000000F /* PaneWorkspaceViewTests.swift in Sources */,`:
```
				FD4C61B478ED4F0BB9AD83A9 /* PaneWorkspaceCanvasModeTests.swift in Sources */,
```

(Ids generated with `uuidgen | tr -d '-' | cut -c1-24 | tr 'a-f' 'A-F'`; regenerate if either already appears in the file — `grep -c FD4C61B478ED4F0BB9AD83A9 macos/OmniAgent.xcodeproj/project.pbxproj` must print `1` after the edit, and the same for the other id.)

---

- [ ] **Step 3: Run it and watch it fail**

Run, from the repo root:
```
xcodebuild test -project macos/OmniAgent.xcodeproj -scheme OmniAgent \
  -destination "platform=macOS,arch=$(uname -m)" CODE_SIGNING_ALLOWED=NO \
  -only-testing:OmniAgentTests/PaneWorkspaceCanvasModeTests
```
Expected: compile failure, `** TEST BUILD FAILED **`, with
`value of type 'PaneWorkspaceView' has no member 'canvasMode'`,
`value of type 'PaneWorkspaceView' has no member 'camera'`,
`value of type 'PaneWorkspaceView' has no member 'derivedCanvasRoot'` and
`type 'PaneWorkspaceView' has no member 'derivedCanvasRoot'`.

(If instead the compiler cannot find `DeskCanvas` / `DeskCamera` / `DeskNode`, Task 1 has not landed — stop and land it first.)

---

- [ ] **Step 4: Add the canvas-mode state and the camera**

In `macos/OmniAgent/PaneWorkspaceView.swift`, insert a new section **immediately before `// MARK: - Occlusion`** (that is, after `canAcceptDrop(from:onto:)`'s closing brace).

Note the shared API writes these as an `extension PaneWorkspaceView`; Swift cannot put stored properties in an extension, so they live in the class body.

```swift
    // MARK: - Canvas mode

    /// The second layout mode. Normal mode: `activeGroup`'s grid fills `bounds`
    /// and every other session is hidden. Canvas mode: *every* session's grid is
    /// laid out at its own card rect in canvas coordinates, and `camera` decides
    /// what is on screen.
    ///
    /// Canvas coordinates are this view's own, which is **flipped**
    /// (`isFlipped == true`) while the window is not — the same convention
    /// `PaneDividerView.mouseDragged` already depends on: "The workspace view is
    /// flipped, the window is not: a downward drag is a *smaller* window y but a
    /// *larger* workspace y." Node positions and the camera origin are in that
    /// flipped space, y growing downward.
    var canvasMode: Bool {
        get { isCanvasMode }
        set {
            guard newValue != isCanvasMode else { return }
            if newValue {
                // Focus mode ends at the canvas door, and it has to end
                // *synchronously*. The card lives in the window's content view
                // (`installOverlayHost`), which is not under this view's
                // `sublayerTransform` — a card left up would float at full size
                // over a zoomed-out canvas — and `applyZoom` tracks exactly one
                // `overlayPaneID`, whose comment records what a second owner
                // costs: "A live terminal and its session, off screen with no
                // way back."
                setZoomed(nil)
                // `setZoomed` only *schedules* the landing (0.38s later, via
                // `DispatchQueue.main.asyncAfter` — never an animation group's
                // completion, which is not guaranteed to arrive with no window
                // or under Reduce Motion), and the canvas layout pass below does
                // not run `applyZoom`, so nothing would ever bring the card home.
                // Landing it here is idempotent: `landCard` clears
                // `overlayIsCollapsing`, so the scheduled `finishZoomTransition`
                // then finds nothing collapsing and does nothing.
                finishZoomTransition(zoomTransitionToken)
            } else {
                // Normal mode must carry no transform at all.
                camera = DeskCamera(scale: 1, origin: .zero)
            }
            isCanvasMode = newValue
            updateVisibility()
            updateLayout()
        }
    }

    private var isCanvasMode = false

    /// The camera, as one transform on `layer.sublayerTransform`.
    ///
    /// `sublayerTransform` rather than a scale on this view or on each card: it
    /// applies to every sublayer without touching the view's own frame or any
    /// container's frame, so container frames stay in canvas coordinates and
    /// nothing downstream — `PaneGrid`, `place`, the resize coalescer, the PTY —
    /// learns that a zoom happened. An ancestor transform never calls
    /// `setFrameSize` on a descendant, so a camera move costs zero PTY resizes.
    /// Edges and chips added later are sublayers of the same layer and inherit
    /// it for free.
    var camera = DeskCamera(scale: 1, origin: .zero) {
        didSet {
            guard camera != oldValue else { return }
            applyCamera()
        }
    }

    /// The organigram laid out in canvas mode. `nil` means "derive it from the
    /// panes this view already holds" — `derivedCanvasRoot()`.
    var canvasRoot: DeskNode? {
        didSet {
            guard isCanvasMode, canvasRoot != oldValue else { return }
            updateLayout()
        }
    }

    /// Nodes the user has dragged, by **node** id, in canvas coordinates.
    /// Handed straight to `DeskCanvas.layout`, which excludes them from packing.
    var canvasPins: [String: CGPoint] = [:] {
        didSet {
            guard isCanvasMode, canvasPins != oldValue else { return }
            updateLayout()
        }
    }

    /// The node rects the last canvas pass produced — what `DeskCamera.fitAll`
    /// fits (`contentRect`) and what hit testing resolves a click against.
    private(set) var canvasLayout: DeskCanvasLayout?

    /// A session card is exactly the Desk viewport, which is this view's own
    /// bounds: that is what makes "the camera at 1.0 over this card" and "you are
    /// in that session" the same picture. Every card is therefore the same
    /// rectangle — a 1-pane session and a 12-pane session are the same size —
    /// and resizing the window re-lays out the whole canvas.
    var canvasCardSize: CGSize { bounds.size }

    /// `sublayerTransform` is applied about the layer's **anchor point** — the
    /// centre of `bounds` — while `DeskCamera.transform` is written for a
    /// top-left origin (`viewPoint = scale * canvasPoint + origin`, which is
    /// exactly what `DeskCamera.canvasPoint(from:)` inverts). The extra
    /// translation puts the two conventions back together: the compositor
    /// renders `c + M(p - c)` with `c` the centre, so `M = transform ∘
    /// translate((scale - 1) * c)` renders `scale * p + origin`. At the identity
    /// camera both parts are identity, so normal mode carries no transform.
    private func applyCamera() {
        guard let layer else { return }
        let centre = CGPoint(x: bounds.midX, y: bounds.midY)
        let transform = CATransform3DConcat(
            camera.transform,
            CATransform3DMakeTranslation(
                (camera.scale - 1) * centre.x,
                (camera.scale - 1) * centre.y,
                0
            )
        )
        // Actions off: the camera's own moves are explicit `CABasicAnimation`s
        // added by key, and CoreAnimation's implicit 0.25s action underneath one
        // of those is a second animation on the same property.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.sublayerTransform = transform
        CATransaction.commit()
    }
```

---

- [ ] **Step 5: Add the node-tree derivation and the node-id lookup**

Append to the same `// MARK: - Canvas mode` section:

```swift
    /// The organigram this view can derive on its own: the account at the root,
    /// one workspace node per project — the Desk level is folded into it, since
    /// it is 1:1 with a workspace and as its own level only makes the tree
    /// taller — and one session node per group, in `groupOrder`'s first-seen
    /// order. Node ids are prefixed so a project named `sess-grp-1` cannot
    /// collide with a group of that name.
    func derivedCanvasRoot() -> DeskNode {
        var projectOrder: [String] = []
        var sessionsByProject: [String: [DeskNode]] = [:]
        for group in groupOrder {
            let project = grids[group]?.paneIDs()
                .compactMap { descriptors[$0]?.project }
                .first { !$0.isEmpty } ?? ""
            if sessionsByProject[project] == nil {
                projectOrder.append(project)
                sessionsByProject[project] = []
            }
            sessionsByProject[project]?.append(
                DeskNode(id: group, kind: .session(group), children: [])
            )
        }
        return DeskNode(
            id: "root",
            kind: .root,
            children: projectOrder.map { project in
                DeskNode(
                    id: project,
                    kind: .workspace(project),
                    children: sessionsByProject[project] ?? []
                )
            }
        )
    }

```

---

- [ ] **Step 6: Extract the hole-tile factory so canvas mode can pool tiles by frame**

A hole's cell id is only unique *inside* one grid — `PaneGrid.holeID(_:)` numbers from 0 per grid — so the canvas cannot key its tiles the way `syncHolePlaceholders(_:holeIDs:)` does. Extract the construction (behaviour unchanged), then add the canvas pool.

In `syncHolePlaceholders(_:holeIDs:)`, replace the `while holePlaceholders.count < holeIDs.count { … }` body's inline construction with a call:

```swift
        while holePlaceholders.count < holeIDs.count {
            let placeholder = makeHolePlaceholder()
            holePlaceholders.append(placeholder)
            addSubview(placeholder, positioned: .below, relativeTo: subviews.first)
        }
```

and add, immediately after `syncDividerViews(_:)` in the `// MARK: - Layout` section:

```swift
    /// One hole tile, wired to this view's callbacks. Extracted so canvas mode
    /// can build the same tile while pooling by frame instead of by cell id.
    private func makeHolePlaceholder() -> PaneHolePlaceholderView {
        let placeholder = PaneHolePlaceholderView(
            onActivate: { [weak self] in self?.onRequestNewPane?() },
            onActivateBrowser: { [weak self] in self?.onRequestNewBrowserPane?() },
            onActivateEditor: { [weak self] in self?.onRequestNewEditorPane?() }
        )
        placeholder.onDropEditorTab = { [weak self] payload in
            self?.onEditorTabDropOnHole?(payload)
        }
        return placeholder
    }

    /// Canvas mode's hole tiles: every card's, pooled by frame, seated below the
    /// containers exactly as `syncHolePlaceholders` seats them.
    ///
    /// The tiles' callbacks carry no group (`onRequestNewPane` and friends never
    /// have), so only the card the camera is over may be clickable — which is
    /// what the identity-scale interactivity rule already guarantees: below 1.0
    /// nothing in a pane takes input, and at 1.0 exactly one card fills the
    /// viewport and it is `activeGroup`'s.
    private func syncCanvasHolePlaceholders(_ frames: [CGRect]) {
        while holePlaceholders.count > frames.count {
            holePlaceholders.removeLast().removeFromSuperview()
        }
        while holePlaceholders.count < frames.count {
            let placeholder = makeHolePlaceholder()
            holePlaceholders.append(placeholder)
            addSubview(placeholder, positioned: .below, relativeTo: subviews.first)
        }
        for (placeholder, frame) in zip(holePlaceholders, frames) {
            placeholder.frame = frame
        }
    }
```

---

- [ ] **Step 7: Branch `updateLayout()` and add the canvas layout pass**

Insert as the **first** statement of `updateLayout()`, above `guard let grid else {` — everything below it stays byte-for-byte as it is:

```swift
        // Canvas mode answers the same question differently: every session's
        // grid at its own card rect, not `activeGroup`'s filling `bounds`.
        if isCanvasMode { return updateCanvasLayout() }
```

Then add, in the `// MARK: - Layout` section immediately after `updateLayout()`:

```swift
    /// Canvas mode's layout pass: every session's grid at its own card rect in
    /// canvas coordinates, plus the camera.
    ///
    /// The card rects come from `DeskCanvas.layout`. A session node's id **is**
    /// its group id and a workspace node's id **is** its project id (see Global
    /// Constraints), so `layout.frames[group]` is the card rect directly.
    private func updateCanvasLayout() {
        let root = canvasRoot ?? derivedCanvasRoot()
        let layout = DeskCanvas.layout(root: root, cardSize: canvasCardSize, pinned: canvasPins)
        canvasLayout = layout
        var holes: [CGRect] = []
        var activeDividers: [PaneDivider] = []
        for group in groupOrder {
            guard let grid = grids[group] else { continue }
            guard let card = layout.frames[group] else {
                // A session the tree does not name has no card to sit in. Not
                // torn down — this view never kills a session — simply not on
                // the canvas.
                // Deliberately no `isHidden` write here. `updateVisibility()`
                // is the sole owner of per-pane visibility and suspension —
                // `setSuspendsDrawing`'s comment records the bug that arises
                // when something else writes it ("assigning the flag directly
                // un-suspended them") — and `onScreenPaneIDs()` already returns
                // nothing for a group with no card rect.
                continue
            }
            // The same `gridInset` normal mode applies to `bounds`, applied to
            // the card instead: a card *is* the Desk viewport, so the panes
            // inside it sit exactly where scale 1.0 shows them.
            let cardLayout = grid.layout(
                in: card.insetBy(dx: Self.gridInset, dy: Self.gridInset),
                dividerThickness: Self.dividerThickness
            )
            for cell in grid.cells {
                guard let frame = cardLayout.frames[cell.id] else { continue }
                guard let paneID = cell.paneID else {
                    holes.append(frame)
                    continue
                }
                // The overlay guard normal mode makes, for the same reason it
                // makes it: "Whatever is in the overlay host — the card, or one
                // still shrinking out of it — has a frame in that host's
                // coordinates, and `applyZoom` is what sets it. Guarded on
                // parentage rather than on zoom state, which changes one layout
                // pass earlier." Entering canvas mode lands the card first, so
                // this is normally empty — but a pane still on its way home must
                // never be reframed into canvas coordinates behind
                // `applyZoom`'s back.
                guard paneID != overlayPaneID, let container = containers[paneID] else { continue }
                place(container, at: frame)
            }
            if group == activeGroup { activeDividers = cardLayout.dividers }
        }
        // Only the on-camera session's seams. A `PaneDividerView` is painted the
        // canvas's own background colour, so a card without them looks identical
        // — and `moveDivider` resolves a drag against `grid`, the *active*
        // session's, so a seam belonging to another card could only ever move the
        // wrong one.
        syncDividerViews(activeDividers)
        syncCanvasHolePlaceholders(holes)
        applyCamera()
        updateAccessibilityLabels()
        refreshFocusSubtitles()
    }
```

---

- [ ] **Step 8: Teach `updateVisibility()` the canvas rule**

In `updateVisibility()`, replace the single line `let visible = Set(paneIDs)` with:

```swift
        // Canvas mode puts every session on screen at its own card, so the
        // visible set is every pane in a grid rather than only the active
        // session's. Viewport culling and the chip threshold narrow it again
        // later; the base rule here is "laid out means on screen".
        let visible = Set(isCanvasMode ? allPaneIDs : paneIDs)
```

Nothing else in the method changes: `container.isHidden` and `container.surface.suspendsDrawing = suspendsDrawing || !onScreen` keep doing the work, `setSuspendsDrawing(_:)` keeps routing through here ("an off-screen session's panes must stay suspended when the window becomes visible again"), and `viewDidHide`/`viewDidUnhide` keep pulling the full-window focus overlay down — AppKit propagates those to descendants, which is exactly why `isHidden` is the culling lever the later LOD task reuses.

---

- [ ] **Step 9: Run the new suite**

Run, from the repo root:
```
xcodebuild test -project macos/OmniAgent.xcodeproj -scheme OmniAgent \
  -destination "platform=macOS,arch=$(uname -m)" CODE_SIGNING_ALLOWED=NO \
  -only-testing:OmniAgentTests/PaneWorkspaceCanvasModeTests
```
Expected: PASS — `Executed 4 tests, with 0 failures`.

---

- [ ] **Step 10: Run the whole suite**

Run: `./macos/build.sh test`

Expected: PASS — a green `Executed N tests, with 0 failures` where N is the previous total plus 4 (708 + 4 = 712 as of the 2026-08-18 20:24 baseline, plus whatever Tasks 1–4 added). Grep for that line rather than trusting the summary: a launch can report a green total underneath a trailing `Failing tests:` list while `xcodebuild` still exits 65.

---

- [ ] **Step 11: Commit**

Check mtimes first — this worktree is shared with concurrent sessions, and `project.pbxproj` in particular is also rewritten by `scripts/bump-build-version.sh`:
```
stat -f '%Sm %N' macos/OmniAgent/PaneWorkspaceView.swift macos/OmniAgentTests/PaneWorkspaceCanvasModeTests.swift macos/OmniAgent.xcodeproj/project.pbxproj
```
Stage only those three paths (never `git add -A`, never `git stash`):
```
git add macos/OmniAgent/PaneWorkspaceView.swift macos/OmniAgentTests/PaneWorkspaceCanvasModeTests.swift macos/OmniAgent.xcodeproj/project.pbxproj
git commit -m "$(cat <<'EOF'
feat(macos): canvas mode lays every session out at its own card rect

`PaneWorkspaceView` already stores one `PaneGrid` per session and hides the
ones that are not `activeGroup`. Canvas mode is the second answer to the same
layout question: every session's grid laid out at its node rect from
`DeskCanvas.layout`, with one camera on `layer.sublayerTransform` deciding what
is on screen. Normal mode is untouched — `updateLayout()` returns into the
canvas pass on one line and is otherwise the same code.

`sublayerTransform` rather than a scale on the view or on each card: it applies
to every sublayer without touching the view's own frame or any container's, so
container frames stay in canvas coordinates and nothing downstream — PaneGrid,
`place`, the resize coalescer, the PTY — learns that a zoom happened. It is
applied about the layer's anchor point, so `applyCamera` folds in the
translation that puts `DeskCamera`'s top-left convention back on the corner.

A card is exactly the Desk viewport, which is what makes "camera at 1.0 over
this card" and "you are in that session" the same picture; the tests hold that
down by comparing each card's pane frames against the ones normal mode produces
for the same session.

Entering canvas mode lands any focus card synchronously first. The card lives in
the window's content view, outside the transform, and `applyZoom` tracks exactly
one `overlayPaneID` — the comment there records what a second owner costs: "A
live terminal and its session, off screen with no way back."

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>
Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
git push
```

---

### Task 6a: Level of detail, part 1 — viewport culling

A session whose node rect does not intersect the viewport is hidden **entirely**. This is the only one of the three mitigations that actually stops a pane rendering, so it lands first and everything else is built on it.

**Read before you start.** `suspendsDrawing` is *not* the lever. It gates exactly one thing — the extra renderer kick `TerminalSurfaceView.feed` posts — at `TerminalSurfaceView.swift`, in `feed(_:isSnapshot:sequence:)`:

```swift
terminalView.feed(byteArray: Array(bytes)[...])
pendingDrawSequence = sequence
guard !suspendsDrawing, !drawMarkerScheduled else { return }
```

SwiftTerm's own `feed → feedFinish() → queuePendingDisplay() → updateDisplay() → requestMetalDisplay() → metalView.setNeedsDisplay(bounds)` runs on **every** feed and knows nothing about the flag. Its doc comment overstates its reach — *"A fully occluded pane keeps parsing output into SwiftTerm's bounded buffer but stops asking the renderer to draw it."* — true only of *our* kick. `isHidden` is the belt: a hidden view is not composited and its `setNeedsDisplay` schedules nothing. Today `updateVisibility()` already gets its whole win that way.

**Files:**
- Modify: `macos/OmniAgent/DeskCanvas.swift` (add a new `extension DeskCamera` immediately below the `DeskCamera` struct)
- Modify: `macos/OmniAgent/PaneWorkspaceView.swift` (in `updateVisibility()`, in `updateLayout()`, in `camera`'s `didSet`, in `canvasMode`'s `didSet`; new members in the `// MARK: - Sessions` region beside `updateVisibility()`)
- Modify: `macos/OmniAgent.xcodeproj/project.pbxproj`
- Test: `macos/OmniAgentTests/DeskCanvasLODTests.swift` (create)

**Interfaces:**

- Consumes (existing, verified in `main`):
  - `private func updateVisibility()` — body today is `validateZoom(); updateZoomAvailability(); let visible = Set(paneIDs); for (id, container) in containers { let onScreen = visible.contains(id); container.isHidden = !onScreen; container.surface.suspendsDrawing = suspendsDrawing || !onScreen }`
  - `func setSuspendsDrawing(_ suspends: Bool)`
  - `private var suspendsDrawing = false`
  - `private var grids: [String: PaneGrid] = [:]`, `private var groupOrder: [String] = []`, `private(set) var activeGroup: String?`
  - `var paneIDs: [String] { grid?.paneIDs() ?? [] }`, `var allPaneIDs: [String]`, `var groupIDs: [String] { groupOrder }`
  - `func container(for sessionID: String) -> PaneContainerView?`
  - `func updateLayout()`
  - `override var isFlipped: Bool { true }`
  - `func layout(in bounds: CGRect, dividerThickness: CGFloat) -> PaneLayout` (`PaneGrid`)
- Consumes (from the fixed shared API — Tasks 1/2/5):
  - `struct DeskCamera: Equatable { var scale: CGFloat; var origin: CGPoint; func canvasPoint(from viewPoint: CGPoint) -> CGPoint; static func focus(on rect: CGRect, in bounds: CGRect) -> DeskCamera; var isIdentity: Bool { get } }`
  - `struct DeskCanvasLayout: Equatable { let frames: [String: CGRect]; let edges: [DeskEdge]; let contentRect: CGRect }`
  - `extension PaneWorkspaceView { var canvasMode: Bool { get set }; var camera: DeskCamera { get set } }`
  - `private(set) var canvasLayout: DeskCanvasLayout?` on `PaneWorkspaceView` — the node frames the last canvas layout pass computed, `nil` in normal mode. **This is Task 5's storage.** Exactly one line in this task reads it (`canvasRect(forGroup:)`), so if Task 5 named it differently that one line is the whole re-anchor.
- Produces:
  - `extension DeskCamera { func canvasViewport(in bounds: CGRect) -> CGRect }`
  - `func canvasRect(forGroup group: String) -> CGRect?` on `PaneWorkspaceView`
  - `var transitionViewport: CGRect?` on `PaneWorkspaceView`
  - `private func onScreenPaneIDs() -> Set<String>` on `PaneWorkspaceView`

---

- [ ] **Step 1: Register the new test file in the Xcode project**

The project is `objectVersion = 77` but has **no** `PBXFileSystemSynchronizedRootGroup`. Dropping a `.swift` file into `macos/OmniAgentTests/` does nothing — it is silently not compiled and its tests silently do not run. Four hand-edits, two tab characters of indentation on every line. Ids below were generated with `uuidgen | tr -d '-' | cut -c1-24 | tr 'a-f' 'A-F'`.

Edit 1 — `PBXBuildFile` section. Insert **after** this existing line:
```
		1ECF599C46245E2BA8447FC1 /* GitFileContentTests.swift in Sources */ = {isa = PBXBuildFile; fileRef = BE0A2CB26F101E0CCC68EFBA /* GitFileContentTests.swift */; };
		7F18710D01214A678267D534 /* DeskCanvasLODTests.swift in Sources */ = {isa = PBXBuildFile; fileRef = 1A5ABE0620BB482B8A6574E9 /* DeskCanvasLODTests.swift */; };
```

Edit 2 — `PBXFileReference` section. Insert **after**:
```
		BE0A2CB26F101E0CCC68EFBA /* GitFileContentTests.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = GitFileContentTests.swift; sourceTree = "<group>"; };
		1A5ABE0620BB482B8A6574E9 /* DeskCanvasLODTests.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = DeskCanvasLODTests.swift; sourceTree = "<group>"; };
```

Edit 3 — the `500000000000000000000003 /* OmniAgentTests */` `PBXGroup` `children` list. Insert **after**:
```
				BE0A2CB26F101E0CCC68EFBA /* GitFileContentTests.swift */,
				1A5ABE0620BB482B8A6574E9 /* DeskCanvasLODTests.swift */,
```

Edit 4 — the test target's `800000000000000000000002 /* Sources */` `PBXSourcesBuildPhase` `files` list. Insert **after**:
```
				1ECF599C46245E2BA8447FC1 /* GitFileContentTests.swift in Sources */,
				7F18710D01214A678267D534 /* DeskCanvasLODTests.swift in Sources */,
```

Gotcha: `project.pbxproj` is a hot, shared file — `scripts/bump-build-version.sh` rewrites `CURRENT_PROJECT_VERSION` in it and concurrent sessions in this worktree edit it too. Insert adjacent to the existing lines rather than rewriting a section, and never `git stash` here.

- [ ] **Step 2: Create the test file with its header, helpers, and the first (reading-API) test**

Create `macos/OmniAgentTests/DeskCanvasLODTests.swift`:

```swift
import XCTest
import SwiftTerm
@testable import OmniAgent

/// Level of detail on the Desk canvas: what the camera cannot see is hidden,
/// what it can see but cannot read is drawn as a chip, and no cursor blinks
/// while nothing is being typed into.
///
/// All three exist because the canvas takes the number of panes AppKit
/// actually displays from ≤12 (one session) to ≤96 (`PaneWorkspaceView.maxTerminals`).
/// They assert on `isHidden`, never on `drawRequestCount`: that counter is
/// incremented only inside `TerminalSurfaceView.requestRendererDraw()`, so it
/// proves "our own extra kick was skipped" and nothing more — SwiftTerm's
/// `feedFinish() -> queuePendingDisplay() -> setNeedsDisplay` path runs on
/// every feed regardless of `suspendsDrawing`. Copying the assertion style of
/// `PaneWorkspaceViewTests.testSuspendedPanesStopRequestingDrawsButKeepParsingOutput`
/// into a level-of-detail test would ship a green test over a pane still
/// rendering full-resolution Metal frames.
final class DeskCanvasLODTests: XCTestCase {

    // MARK: - Reading the canvas

    /// The rect culling is measured against: what the camera can see, mapped
    /// back into canvas coordinates. Scale and translation only, no rotation,
    /// so two mapped corners bound it exactly.
    func testTheViewportIsWhatTheCameraCanSeeMappedBackIntoCanvasSpace() {
        let camera = DeskCamera(scale: 0.5, origin: CGPoint(x: 120, y: -40))
        let bounds = CGRect(x: 0, y: 0, width: 1200, height: 800)

        let viewport = camera.canvasViewport(in: bounds)

        XCTAssertEqual(viewport.width, 2400, accuracy: 0.001, "at half scale the viewport sees twice the canvas")
        XCTAssertEqual(viewport.height, 1600, accuracy: 0.001)
        XCTAssertTrue(
            viewport.contains(camera.canvasPoint(from: CGPoint(x: 600, y: 400))),
            "the centre of the view is inside what the view is showing"
        )
        XCTAssertFalse(
            viewport.contains(camera.canvasPoint(from: CGPoint(x: -10, y: 400))),
            "a point left of the view is not"
        )
    }

    /// A session's card rect is looked up by its **group** id, because a
    /// session node's id is its group id — `DeskNode.Kind.session` "carries the
    /// group id used everywhere else in the app".
    func testASessionsCardIsFoundByItsGroupId() throws {
        let workspace = makeCanvasWorkspace(sessions: 2, panesEach: 2)

        let first = try XCTUnwrap(workspace.canvasRect(forGroup: "grp-1"))
        let second = try XCTUnwrap(workspace.canvasRect(forGroup: "grp-2"))

        XCTAssertEqual(first.size, workspace.bounds.size, "a card is exactly the Desk viewport")
        XCTAssertEqual(second.size, workspace.bounds.size)
        XCTAssertFalse(first.intersects(second), "two session cards do not overlap")
        XCTAssertNil(workspace.canvasRect(forGroup: "grp-nobody"))
    }

    // MARK: - Helpers

    /// `PaneWorkspaceViewTests.makeWorkspace(panes:)`'s shape, with one grid
    /// per session and canvas mode already on. Terminals only: the level-of-
    /// detail rules are kind-neutral and a WKWebView pane costs the test host
    /// a renderer process for nothing.
    private func makeCanvasWorkspace(sessions: Int, panesEach: Int) -> PaneWorkspaceView {
        let connection = SessionConnection(
            socketURL: URL(fileURLWithPath: "/tmp/omniagent-desk-canvas-lod-test.sock")
        )
        let workspace = PaneWorkspaceView { descriptor in
            TerminalSurfaceView(connection: connection, sessionID: descriptor.sessionID)
        }
        workspace.frame = CGRect(x: 0, y: 0, width: 1200, height: 800)
        for session in 1...sessions {
            for pane in 1...panesEach {
                XCTAssertTrue(
                    workspace.addPane(
                        PaneDescriptor(
                            sessionID: "s\(session)-p\(pane)",
                            group: "grp-\(session)",
                            title: "",
                            engine: .claude
                        )
                    ),
                    "s\(session)-p\(pane) must be accepted"
                )
            }
        }
        workspace.canvasMode = true
        workspace.layoutSubtreeIfNeeded()
        return workspace
    }
}

/// Everything in this file drives terminal panes, so the concrete surface is
/// one force-cast away — a crash here means a test built a pane kind it does
/// not handle, which deserves to fail loudly. (The same helper is `private` to
/// `PaneWorkspaceViewTests`, so it is repeated rather than shared.)
private extension PaneContainerView {
    var terminalSurface: TerminalSurfaceView { surface as! TerminalSurfaceView }
}
```

- [ ] **Step 3: Run it and watch it fail**

Run:
```
xcodebuild test -project macos/OmniAgent.xcodeproj -scheme OmniAgent \
  -destination "platform=macOS,arch=$(uname -m)" CODE_SIGNING_ALLOWED=NO \
  ONLY_ACTIVE_ARCH=YES ARCHS="$(uname -m)" \
  -only-testing:OmniAgentTests/DeskCanvasLODTests
```

Expected: compile failure, not a test failure —
```
DeskCanvasLODTests.swift:NN:30: error: value of type 'DeskCamera' has no member 'canvasViewport'
DeskCanvasLODTests.swift:NN:37: error: value of type 'PaneWorkspaceView' has no member 'canvasRect'
** TEST BUILD FAILED **
```

- [ ] **Step 4: Implement the two reading members**

In `macos/OmniAgent/DeskCanvas.swift`, immediately below the `DeskCamera` struct:

```swift
extension DeskCamera {
    /// The part of the canvas `bounds` is showing, in canvas coordinates —
    /// the rect viewport culling is measured against.
    ///
    /// Two mapped corners bound it exactly: the camera is a scale and a
    /// translation with no rotation, so the image of an axis-aligned rect is
    /// an axis-aligned rect. `min`/`abs` rather than assuming an orientation,
    /// because the canvas lives in `PaneWorkspaceView`'s **flipped** space
    /// (`isFlipped == true`, y growing downward) and the window's is not.
    func canvasViewport(in bounds: CGRect) -> CGRect {
        let near = canvasPoint(from: CGPoint(x: bounds.minX, y: bounds.minY))
        let far = canvasPoint(from: CGPoint(x: bounds.maxX, y: bounds.maxY))
        return CGRect(
            x: min(near.x, far.x),
            y: min(near.y, far.y),
            width: abs(far.x - near.x),
            height: abs(far.y - near.y)
        )
    }
}
```

In `macos/OmniAgent/PaneWorkspaceView.swift`, in the `// MARK: - Sessions` region, immediately **above** `private func updateVisibility()`:

```swift
    /// The card rect one session occupies in canvas coordinates — the frame
    /// the tidy tree gave its node.
    ///
    /// Keyed by group id, because a session node's id *is* its group id:
    /// `DeskNode.Kind.session` "carries the group id used everywhere else in
    /// the app". This is the only reader of `canvasLayout` in the level-of-
    /// detail path, deliberately, so the whole path re-anchors here if the
    /// layout pass ever stores its result somewhere else.
    func canvasRect(forGroup group: String) -> CGRect? {
        canvasLayout?.frames[group]
    }
```

- [ ] **Step 5: Run the two reading tests**

Run:
```
xcodebuild test -project macos/OmniAgent.xcodeproj -scheme OmniAgent \
  -destination "platform=macOS,arch=$(uname -m)" CODE_SIGNING_ALLOWED=NO \
  ONLY_ACTIVE_ARCH=YES ARCHS="$(uname -m)" \
  -only-testing:OmniAgentTests/DeskCanvasLODTests
```
Expected: PASS — `Executed 2 tests, with 0 failures`.

- [ ] **Step 6: Write the failing culling test**

Append to `DeskCanvasLODTests`, under a new `// MARK: - Viewport culling` above `// MARK: - Helpers`:

```swift
    // MARK: - Viewport culling

    /// A card the camera is not showing is hidden outright — not "suspended".
    ///
    /// Asserted on `isHiddenOrHasHiddenAncestor` of the *surface*, because
    /// that is the observable that corresponds to work not happening: a hidden
    /// view is not composited and its `setNeedsDisplay` schedules nothing.
    /// `surface.suspendsDrawing` is checked too, but only as the belt-and-
    /// braces half — on its own it would gate one skipped renderer kick per
    /// feed burst and nothing else.
    func testASessionCardTheCameraCannotSeeIsHiddenEntirely() throws {
        let workspace = makeCanvasWorkspace(sessions: 2, panesEach: 2)
        let near = try XCTUnwrap(workspace.canvasRect(forGroup: "grp-1"))
        let far = try XCTUnwrap(workspace.canvasRect(forGroup: "grp-2"))

        workspace.camera = DeskCamera.focus(on: near, in: workspace.bounds)

        let viewport = workspace.camera.canvasViewport(in: workspace.bounds)
        XCTAssertTrue(near.intersects(viewport), "the fixture must put the first card on camera")
        XCTAssertFalse(far.intersects(viewport), "and the second one off it")

        let onCamera = try XCTUnwrap(workspace.container(for: "s1-p1"))
        XCTAssertFalse(onCamera.isHidden, "the card the camera is on stays up")
        XCTAssertFalse(onCamera.surface.isHiddenOrHasHiddenAncestor)

        for id in ["s2-p1", "s2-p2"] {
            let culled = try XCTUnwrap(workspace.container(for: id))
            XCTAssertTrue(culled.isHidden, "\(id) is off camera and must be hidden")
            XCTAssertTrue(
                culled.surface.isHiddenOrHasHiddenAncestor,
                "\(id)'s surface is not composited — the only thing that actually stops it rendering"
            )
            XCTAssertTrue(culled.surface.suspendsDrawing, "and our own renderer kick is skipped as well")
        }

        XCTAssertEqual(
            workspace.allPaneIDs.sorted(),
            ["s1-p1", "s1-p2", "s2-p1", "s2-p2"],
            "culling hides panes, it never tears one down"
        )
    }

    /// Culling follows the camera without a layout pass: an ancestor
    /// `CATransform3D` moves nothing's frame, so nothing else would recompute
    /// the visible set.
    func testMovingTheCameraBackOverACardBringsItUpAgain() throws {
        let workspace = makeCanvasWorkspace(sessions: 2, panesEach: 1)
        let first = try XCTUnwrap(workspace.canvasRect(forGroup: "grp-1"))
        let second = try XCTUnwrap(workspace.canvasRect(forGroup: "grp-2"))

        workspace.camera = DeskCamera.focus(on: first, in: workspace.bounds)
        XCTAssertTrue(try XCTUnwrap(workspace.container(for: "s2-p1")).isHidden)

        workspace.camera = DeskCamera.focus(on: second, in: workspace.bounds)
        XCTAssertFalse(try XCTUnwrap(workspace.container(for: "s2-p1")).isHidden)
        XCTAssertTrue(try XCTUnwrap(workspace.container(for: "s1-p1")).isHidden)
    }

    /// Normal mode is untouched by any of it: one session on screen, the rest
    /// hidden, exactly as `updateVisibility`'s doc comment has always said.
    func testLeavingCanvasModeRestoresTheOneSessionOnScreenRule() throws {
        let workspace = makeCanvasWorkspace(sessions: 2, panesEach: 1)
        workspace.camera = DeskCamera.focus(
            on: try XCTUnwrap(workspace.canvasRect(forGroup: "grp-1")),
            in: workspace.bounds
        )

        workspace.canvasMode = false

        XCTAssertEqual(workspace.activeGroup, "grp-2", "the last pane added is still the active session")
        XCTAssertFalse(try XCTUnwrap(workspace.container(for: "s2-p1")).isHidden)
        XCTAssertTrue(
            try XCTUnwrap(workspace.container(for: "s1-p1")).isHidden,
            "the camera's opinion dies with canvas mode"
        )
    }
```

- [ ] **Step 7: Run them and watch them fail**

Run:
```
xcodebuild test -project macos/OmniAgent.xcodeproj -scheme OmniAgent \
  -destination "platform=macOS,arch=$(uname -m)" CODE_SIGNING_ALLOWED=NO \
  ONLY_ACTIVE_ARCH=YES ARCHS="$(uname -m)" \
  -only-testing:OmniAgentTests/DeskCanvasLODTests
```

Expected: three red assertions, e.g.
```
DeskCanvasLODTests.testASessionCardTheCameraCannotSeeIsHiddenEntirely : XCTAssertTrue failed - s2-p1 is off camera and must be hidden
DeskCanvasLODTests.testMovingTheCameraBackOverACardBringsItUpAgain : XCTAssertTrue failed
DeskCanvasLODTests.testLeavingCanvasModeRestoresTheOneSessionOnScreenRule : XCTAssertFalse failed - the camera's opinion dies with canvas mode
```

- [ ] **Step 8: Implement the visible set**

In `macos/OmniAgent/PaneWorkspaceView.swift`, immediately below the new `canvasRect(forGroup:)`, add:

```swift
    /// The rect visibility is measured against while the camera is travelling.
    ///
    /// `flyCamera(to:)` sets `camera` to its destination at the *start* of the
    /// animation — the model layer value leads, the presentation layer catches
    /// up — so without this every card but the destination would be hidden on
    /// frame one and the user would watch the tree blink out from under a
    /// camera still moving through it. The flight sets this to the union of
    /// both ends and clears it on arrival.
    var transitionViewport: CGRect? {
        didSet {
            guard transitionViewport != oldValue else { return }
            updateVisibility()
        }
    }

    /// The panes AppKit is allowed to display.
    ///
    /// Normal mode: the active session's, unchanged. Canvas mode: every
    /// session's, minus the cards the camera cannot see. Culling is what the
    /// ≤12-to-≤96 jump needs — on the canvas nothing else takes a pane out of
    /// the compositor.
    private func onScreenPaneIDs() -> Set<String> {
        guard canvasMode else { return Set(paneIDs) }
        let viewport = transitionViewport ?? camera.canvasViewport(in: bounds)
        var ids: Set<String> = []
        for group in groupOrder {
            guard let rect = canvasRect(forGroup: group), rect.intersects(viewport) else { continue }
            ids.formUnion(grids[group]?.paneIDs() ?? [])
        }
        return ids
    }
```

Replace the body of `private func updateVisibility()` — keep the existing doc comment and append the two new paragraphs:

```swift
    /// Only the active session's panes are on screen. The others are hidden,
    /// never torn down: closing a pane is what ends a PTY, and switching
    /// sessions must not. A hidden pane keeps parsing output into SwiftTerm's
    /// bounded buffer — so its scrollback is intact when you come back — and
    /// only stops drawing, the same trade an occluded window makes.
    ///
    /// In canvas mode every session is on screen at once, so "which session"
    /// becomes the camera's question: a card whose node rect misses the
    /// viewport is hidden.
    ///
    /// `isHidden` is the load-bearing half and `suspendsDrawing` is the
    /// belt-and-braces half, not the other way round. `suspendsDrawing` gates
    /// exactly one thing — the extra renderer kick `TerminalSurfaceView.feed`
    /// posts — while SwiftTerm's own `feedFinish() -> queuePendingDisplay() ->
    /// setNeedsDisplay` path runs on every feed regardless. A hidden view is
    /// not composited and its `setNeedsDisplay` schedules nothing.
    private func updateVisibility() {
        validateZoom()
        updateZoomAvailability()
        let visible = onScreenPaneIDs()
        for (id, container) in containers {
            let onScreen = visible.contains(id)
            container.isHidden = !onScreen
            container.surface.suspendsDrawing = suspendsDrawing || !onScreen
        }
    }
```

Nothing outside this method may write `container.surface.suspendsDrawing`, and the same now goes for the culling state. `setSuspendsDrawing(_:)`'s comment records what happened the one time something did:

```swift
        // Through `updateVisibility` rather than straight onto every surface:
        // an off-screen session's panes must stay suspended when the window
        // becomes visible again, and assigning the flag directly un-suspended
        // them.
```

Add the camera hooks. In **`updateCanvasLayout()`** (Task 5), as the **last** statement, after its `refreshFocusSubtitles()` call:

```swift
        // Canvas mode's visible set is a function of the node rects this pass
        // just computed and of the camera, and nothing else recomputes it when
        // a window resize re-lays the canvas out.
        updateVisibility()
```

**Not** in `updateLayout()`. Task 5 makes `if isCanvasMode { return updateCanvasLayout() }` that method's *first* statement, so anything appended to its tail is unreachable in exactly the mode it would be guarded on. Leaving `updateLayout()`'s normal-mode tail untouched also keeps a divider drag — which re-lays out on every frame — exactly as cheap as it is today.

In `camera`'s `didSet` (Task 5), after whatever applies `layer.sublayerTransform`, add:

```swift
            // An ancestor transform moves no frame, so no layout pass follows a
            // camera move and this is the only thing that re-derives what is on
            // screen. Every path that changes the camera must come through the
            // setter for that reason.
            updateVisibility()
```

In `canvasMode`'s **setter** (Task 5 declares it as a computed property over a stored `isCanvasMode`, so there is no `didSet` to edit), as the **last** statement, after its `updateLayout()` call:

```swift
            // Unconditionally, not via `updateLayout`'s tail: that call is
            // guarded on `canvasMode` and so does not run on the way *out* of
            // canvas mode, which would leave every other session's panes
            // unhidden on top of the active one.
            updateVisibility()
```

- [ ] **Step 9: Run the culling tests**

Run:
```
xcodebuild test -project macos/OmniAgent.xcodeproj -scheme OmniAgent \
  -destination "platform=macOS,arch=$(uname -m)" CODE_SIGNING_ALLOWED=NO \
  ONLY_ACTIVE_ARCH=YES ARCHS="$(uname -m)" \
  -only-testing:OmniAgentTests/DeskCanvasLODTests
```
Expected: PASS — `Executed 5 tests, with 0 failures`.

- [ ] **Step 10: Write the failing in-flight test**

Append to the `// MARK: - Viewport culling` section:

```swift
    /// A card the camera is flying towards — or away from — is not hidden
    /// mid-flight. `flyCamera(to:)` sets `camera` to its destination on frame
    /// one, so culling against that alone would blink the tree out from under
    /// a camera still travelling through it.
    func testACardTheCameraIsFlyingAcrossStaysVisibleForTheWholeFlight() throws {
        let workspace = makeCanvasWorkspace(sessions: 2, panesEach: 1)
        let first = try XCTUnwrap(workspace.canvasRect(forGroup: "grp-1"))
        let second = try XCTUnwrap(workspace.canvasRect(forGroup: "grp-2"))

        workspace.camera = DeskCamera.focus(on: first, in: workspace.bounds)
        workspace.transitionViewport = first.union(second)
        workspace.camera = DeskCamera.focus(on: second, in: workspace.bounds)

        XCTAssertFalse(try XCTUnwrap(workspace.container(for: "s1-p1")).isHidden, "the card being left")
        XCTAssertFalse(try XCTUnwrap(workspace.container(for: "s2-p1")).isHidden, "the card being reached")

        workspace.transitionViewport = nil

        XCTAssertTrue(try XCTUnwrap(workspace.container(for: "s1-p1")).isHidden, "and on arrival it is culled")
        XCTAssertFalse(try XCTUnwrap(workspace.container(for: "s2-p1")).isHidden)
    }
```

- [ ] **Step 11: Run it — a characterization test, green on the first run**

Run the same `-only-testing:OmniAgentTests/DeskCanvasLODTests` command.

Expected: this one passes already, because Step 8 shipped `transitionViewport` with the rest of the visible-set change. If it fails, the failure is
```
DeskCanvasLODTests.testACardTheCameraIsFlyingAcrossStaysVisibleForTheWholeFlight : XCTAssertFalse failed - the card being left
```
which means `onScreenPaneIDs()` is reading `camera.canvasViewport(in: bounds)` unconditionally instead of `transitionViewport ?? camera.canvasViewport(in: bounds)` — fix that one line.

- [ ] **Step 12: Run the whole suite**

Run:
```
./macos/build.sh test
```
Expected: `0 failures`, with the executed count higher than the run recorded at the start of this task by exactly this task's new tests. Per the crash-diagnosis convention, grep for a green `Executed N tests` line before believing the summary — a launch can report a green total underneath a trailing `Failing tests:` list while `xcodebuild` still exits 65.

- [ ] **Step 13: Commit**

Check mtimes first — this worktree is shared with concurrent sessions and `project.pbxproj` in particular is hot. Stage explicitly, never `git add -A`, never `git stash`.

```bash
git -C /Users/bonando/Documents/Bruno.Digital/OmniAgent-ADE status --porcelain \
  macos/OmniAgent/DeskCanvas.swift macos/OmniAgent/PaneWorkspaceView.swift \
  macos/OmniAgentTests/DeskCanvasLODTests.swift macos/OmniAgent.xcodeproj/project.pbxproj

git -C /Users/bonando/Documents/Bruno.Digital/OmniAgent-ADE add \
  macos/OmniAgent/DeskCanvas.swift macos/OmniAgent/PaneWorkspaceView.swift \
  macos/OmniAgentTests/DeskCanvasLODTests.swift macos/OmniAgent.xcodeproj/project.pbxproj

git -C /Users/bonando/Documents/Bruno.Digital/OmniAgent-ADE commit -m "feat(macos): the canvas hides the session cards the camera cannot see

Culling by isHidden, not by suspendsDrawing: that flag gates only the extra
renderer kick TerminalSurfaceView.feed posts, while SwiftTerm's own
feedFinish -> queuePendingDisplay -> setNeedsDisplay runs on every feed
regardless. A hidden view is not composited and its setNeedsDisplay schedules
nothing, which is the only thing that makes ninety-six live panes affordable.

transitionViewport keeps both ends of a camera flight visible, because
flyCamera sets the camera to its destination on frame one.

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"

git -C /Users/bonando/Documents/Bruno.Digital/OmniAgent-ADE push
```

---

### Task 6b: Level of detail, part 2 — the chip threshold

An on-screen session below `DeskCanvas.lodThreshold` (0.2) hides its pane surfaces and shows a chip instead: engine icon, title, status dot. At 0.2 a 12pt glyph is 2.4pt — there is no information in those pixels, only cost.

The chip is a **fourth sibling** in `PaneContainerView`, not a replacement surface, because `surface` is `let surface: any PaneContentView` — a live terminal swapped out of the view tree is one that has to be rebuilt to come back.

**Files:**
- Create: `macos/OmniAgent/PaneChipView.swift`
- Modify: `macos/OmniAgent/PaneWorkspaceView.swift` (new `showsChips` beside `canvasRect(forGroup:)`; one line in `updateVisibility()`; in `PaneContainerView`: the stored `chip`, `isChipped`, `init(paneID:surface:workspace:)`, `applyLayout()`, `roundChildren(inside:)`, `descriptorChanged(_:)`, `status`'s `didSet`)
- Modify: `macos/OmniAgent.xcodeproj/project.pbxproj`
- Test: `macos/OmniAgentTests/DeskCanvasLODTests.swift` (extend)

**Interfaces:**

- Consumes (existing, verified):
  - `let surface: any PaneContentView`, `let header: PaneHeaderView`, `let approvalBar = PaneApprovalBarView()`, `let dropHighlight = PaneDropOverlayView()` on `PaneContainerView`
  - `static let cornerRadius: CGFloat = 9`, `static let borderWidth: CGFloat = 1`, `static let paneBackgroundColor = NSColor(srgbRed: 12 / 255, green: 12 / 255, blue: 15 / 255, alpha: 1)` on `PaneContainerView`
  - `private func applyLayout()`, `private func roundChildren(inside radius: CGFloat)`, `func descriptorChanged(_ descriptor: PaneDescriptor)`, `var status: RemoteSessionStatus?` on `PaneContainerView`
  - `static func paneLabel(_ pane: PaneDescriptor) -> String` (`SessionOutline`)
  - `static func color(for status: RemoteSessionStatus?) -> NSColor` (`PaneStatusMarkView`)
  - `var iconImage: NSImage? { get }`, `var badgeForeground: NSColor { get }` (`extension Engine`, `EngineIcon.swift`)
  - `func tinted(_ color: NSColor) -> NSImage` (`extension NSImage`, `EngineIcon.swift`)
  - `@discardableResult func requestRendererDraw() -> Bool` (`TerminalSurfaceView`) — **not** on `PaneContentView`, reached by cast
  - `enum RemoteSessionStatus: String, Codable { case ready, thinking, toolExecution, awaitingApproval, error }`
- Consumes (fixed shared API): `static let lodThreshold: CGFloat = 0.2` (`DeskCanvas`)
- Consumes (Task 6a): `private func onScreenPaneIDs() -> Set<String>`, `func canvasRect(forGroup group: String) -> CGRect?`
- Produces:
  - `final class PaneChipView: NSView` with `var title: String`, `var engine: Engine?`, `var status: RemoteSessionStatus?`
  - `let chip = PaneChipView()` on `PaneContainerView`
  - `var isChipped: Bool` on `PaneContainerView`
  - `var showsChips: Bool { get }` on `PaneWorkspaceView`

---

- [ ] **Step 1: Write the failing chip tests**

Append to `DeskCanvasLODTests`, in a new `// MARK: - The chip threshold` section above `// MARK: - Helpers`:

```swift
    // MARK: - The chip threshold

    /// Below `DeskCanvas.lodThreshold` a pane surface carries no information —
    /// at 0.2 a 12pt glyph is 2.4pt — so the surface comes down and a chip
    /// takes its place. Hidden, not suspended: hiding is the only thing that
    /// stops SwiftTerm's own draw path.
    func testAnOnScreenSessionBelowTheThresholdHidesItsSurfacesAndShowsChips() throws {
        let workspace = makeCanvasWorkspace(sessions: 2, panesEach: 2)
        let both = try XCTUnwrap(workspace.canvasRect(forGroup: "grp-1"))
            .union(try XCTUnwrap(workspace.canvasRect(forGroup: "grp-2")))

        workspace.camera = DeskCamera.focus(
            on: both.insetBy(dx: -both.width * 4.5, dy: -both.height * 4.5),
            in: workspace.bounds
        )

        XCTAssertLessThan(
            workspace.camera.scale,
            DeskCanvas.lodThreshold,
            "the fixture must actually be below the chip threshold"
        )
        XCTAssertTrue(workspace.showsChips)

        for id in ["s1-p1", "s1-p2", "s2-p1", "s2-p2"] {
            let container = try XCTUnwrap(workspace.container(for: id))
            XCTAssertFalse(container.isHidden, "\(id)'s card is on camera")
            XCTAssertTrue(container.isChipped, "\(id) is drawn as a chip")
            XCTAssertTrue(container.surface.isHidden, "\(id)'s surface is down, not merely suspended")
            XCTAssertTrue(container.header.isHidden, "and so is its 3pt header")
            XCTAssertFalse(container.chip.isHidden)
            XCTAssertEqual(
                container.chip.frame,
                container.bounds.insetBy(
                    dx: PaneContainerView.borderWidth,
                    dy: PaneContainerView.borderWidth
                ),
                "the chip fills the pane inside its 1pt ring"
            )
        }
    }

    /// The chip carries what the header carries — engine, name, status —
    /// because at this scale the header cannot.
    func testTheChipCarriesTheEngineTheNameAndTheStatus() throws {
        let workspace = makeCanvasWorkspace(sessions: 1, panesEach: 1)
        workspace.updateDescriptor(for: "s1-p1") { $0.label = "Ingest rewrite" }
        workspace.setStatus(.awaitingApproval, for: "s1-p1")

        let chip = try XCTUnwrap(workspace.container(for: "s1-p1")).chip

        XCTAssertEqual(chip.title, "Ingest rewrite")
        XCTAssertEqual(chip.engine, .claude)
        XCTAssertEqual(chip.status, .awaitingApproval)
    }

    /// A browser or editor carries `.shell` as a placeholder engine, and a chip
    /// claiming it runs one would say a thing that is not true — the header
    /// already refuses this for exactly the same reason.
    func testANonTerminalPanesChipShowsNoEngine() throws {
        let workspace = makeCanvasWorkspace(sessions: 1, panesEach: 1)
        XCTAssertTrue(
            workspace.addPane(
                PaneDescriptor(
                    sessionID: "web-1",
                    group: "grp-1",
                    kind: .browser,
                    browserURL: "https://example.com"
                )
            )
        )

        XCTAssertNil(try XCTUnwrap(workspace.container(for: "web-1")).chip.engine)
        XCTAssertEqual(try XCTUnwrap(workspace.container(for: "web-1")).chip.title, "https://example.com")
    }

    /// `roundChildren(inside:)` resolves `maskedCorners` in each child's **own**
    /// coordinate space, and its comment records what getting that wrong cost:
    /// "Naming `MaxY` \"the bottom\" for every child put the unflipped terminal
    /// surface's rounding at its *top* on screen … The offscreen render harness
    /// cannot show the difference (`CALayer.render(in:)` skips the compositor's
    /// geometry flips), which is how it went unseen."
    ///
    /// The chip fills the container on its own, so it takes all four corners
    /// and no flip can matter. That is what this pins — a PNG never could.
    func testTheChipTakesAllFourCornersSoNoGeometryFlipCanRoundItUpsideDown() throws {
        let workspace = makeCanvasWorkspace(sessions: 1, panesEach: 2)
        let chip = try XCTUnwrap(workspace.container(for: "s1-p1")).chip

        XCTAssertEqual(
            try XCTUnwrap(chip.layer?.maskedCorners),
            [
                .layerMinXMinYCorner, .layerMaxXMinYCorner,
                .layerMinXMaxYCorner, .layerMaxXMaxYCorner,
            ],
            "all four, so the chip's rounding reads the same whichever way its layer is flipped"
        )
        XCTAssertEqual(
            chip.layer?.cornerRadius,
            PaneContainerView.cornerRadius - PaneContainerView.borderWidth,
            "concentric inside the container's, one border width smaller"
        )
    }

    /// Coming back above the threshold, the surface must be told to paint.
    /// While it was hidden its `setNeedsDisplay` scheduled nothing, and
    /// `MacTerminalView.draw(_:)` is `if metalView != nil { return }` — so
    /// `needsDisplay = true` is a no-op once Metal is on and an idle terminal
    /// would sit there showing a stale drawable.
    ///
    /// `drawRequestCount` is the right assertion *here* and only here: this
    /// test asserts a draw was requested, which is exactly what the counter
    /// counts. It is the wrong assertion for anything claiming a pane stopped
    /// drawing.
    func testASurfaceComingBackAboveTheThresholdIsRepaintedNotLeftOnItsLastDrawable() throws {
        let workspace = makeCanvasWorkspace(sessions: 1, panesEach: 1)
        let card = try XCTUnwrap(workspace.canvasRect(forGroup: "grp-1"))
        workspace.camera = DeskCamera.focus(
            on: card.insetBy(dx: -card.width * 4.5, dy: -card.height * 4.5),
            in: workspace.bounds
        )
        XCTAssertTrue(try XCTUnwrap(workspace.container(for: "s1-p1")).isChipped)
        let before = try XCTUnwrap(workspace.container(for: "s1-p1")).terminalSurface.drawRequestCount

        workspace.camera = DeskCamera.focus(on: card, in: workspace.bounds)

        let container = try XCTUnwrap(workspace.container(for: "s1-p1"))
        XCTAssertFalse(container.isChipped)
        XCTAssertFalse(container.surface.isHidden)
        XCTAssertTrue(container.chip.isHidden)
        XCTAssertGreaterThan(
            container.terminalSurface.drawRequestCount,
            before,
            "the surface is kicked once on the way back up"
        )
    }
```

- [ ] **Step 2: Run them and watch them fail**

Run:
```
xcodebuild test -project macos/OmniAgent.xcodeproj -scheme OmniAgent \
  -destination "platform=macOS,arch=$(uname -m)" CODE_SIGNING_ALLOWED=NO \
  ONLY_ACTIVE_ARCH=YES ARCHS="$(uname -m)" \
  -only-testing:OmniAgentTests/DeskCanvasLODTests
```

Expected: compile failure —
```
DeskCanvasLODTests.swift:NN:20: error: value of type 'PaneWorkspaceView' has no member 'showsChips'
DeskCanvasLODTests.swift:NN:29: error: value of type 'PaneContainerView' has no member 'isChipped'
DeskCanvasLODTests.swift:NN:29: error: value of type 'PaneContainerView' has no member 'chip'
** TEST BUILD FAILED **
```

- [ ] **Step 3: Create the chip view**

Create `macos/OmniAgent/PaneChipView.swift`:

```swift
import AppKit

/// A pane, drawn small enough to be worth drawing at all.
///
/// Below `DeskCanvas.lodThreshold` a pane's surface carries no information —
/// at 0.2 a 12pt glyph is 2.4pt — so the surface comes down and this takes its
/// place: the engine's mark, the pane's name, and the status dot.
///
/// A **fourth sibling** of the container's header/surface/approvalBar rather
/// than a replacement surface. `PaneContainerView.surface` is
/// `let surface: any PaneContentView`, and a live terminal swapped out of the
/// view tree is one that has to be rebuilt — with its scrollback — to come
/// back.
///
/// Drawn rather than composed, the way `PaneHolePlaceholderView` is: three
/// pieces of static content in a box whose size changes with the camera, where
/// three subviews would each need their own frame maths for nothing.
final class PaneChipView: NSView {
    /// Everything here is a fraction of the chip's own box, never a point
    /// size. The camera scales the whole card, so a fixed 12pt label is 1.8pt
    /// on screen at the scale this view exists for — the same trap the surface
    /// it replaces falls into.
    private static let iconFraction: CGFloat = 0.30
    private static let titleFraction: CGFloat = 0.17
    private static let dotFraction: CGFloat = 0.11
    private static let gapFraction: CGFloat = 0.07

    var title = "" {
        didSet {
            guard title != oldValue else { return }
            needsDisplay = true
        }
    }

    /// `nil` for a browser or an editor. Both carry `.shell` as a placeholder
    /// engine, and a chip showing that badge would claim the pane runs
    /// something it does not — the header already refuses it for this reason.
    var engine: Engine? {
        didSet {
            guard engine != oldValue else { return }
            needsDisplay = true
        }
    }

    var status: RemoteSessionStatus? {
        didSet {
            guard status != oldValue else { return }
            needsDisplay = true
        }
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = PaneContainerView.paneBackgroundColor.cgColor
        // The container's own accessibility label already names this pane; a
        // second element for the same pane is noise to a screen reader.
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    /// Matching `PaneContainerView` and `PaneBadgeView`, both flipped — the
    /// icon draw below is the same call `PaneBadgeView` makes in a flipped view.
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard bounds.width > 2, bounds.height > 2 else { return }
        let unit = min(bounds.width, bounds.height)
        let iconSide = unit * Self.iconFraction
        let dot = unit * Self.dotFraction
        let gap = bounds.height * Self.gapFraction
        let font = NSFont.systemFont(ofSize: max(1, bounds.height * Self.titleFraction), weight: .medium)
        let textHeight = font.boundingRectForFont.height
        var y = max(0, (bounds.height - (iconSide + gap + textHeight + gap + dot)) / 2)

        if let image = engine?.iconImage {
            image.tinted(engine?.badgeForeground ?? .labelColor).draw(
                in: NSRect(x: (bounds.width - iconSide) / 2, y: y, width: iconSide, height: iconSide)
            )
        }
        y += iconSide + gap

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail
        (title as NSString).draw(
            in: NSRect(x: gap, y: y, width: max(0, bounds.width - gap * 2), height: textHeight),
            withAttributes: [
                .font: font,
                .foregroundColor: NSColor(white: 1, alpha: 0.82),
                .paragraphStyle: paragraph,
            ]
        )
        y += textHeight + gap

        // Literally the sidebar's own mapping, through the same door the pane
        // header's mark uses — a session that reads amber in the tree has to
        // read amber on its chip.
        PaneStatusMarkView.color(for: status).setFill()
        NSBezierPath(
            ovalIn: NSRect(x: (bounds.width - dot) / 2, y: y, width: dot, height: dot)
        ).fill()
    }
}
```

- [ ] **Step 4: Register `PaneChipView.swift` in the app target**

Four more pbxproj edits, this time the **app** halves (group `500000000000000000000002 /* OmniAgent */`, sources phase `800000000000000000000001 /* Sources */`).

Edit 1 — `PBXBuildFile` section, insert after:
```
		68F9BD406F6C7DDABE533A9D /* GitFileContent.swift in Sources */ = {isa = PBXBuildFile; fileRef = C43E2B4CEEE6E8798AE14F29 /* GitFileContent.swift */; };
		C8E5716D35494A029A309845 /* PaneChipView.swift in Sources */ = {isa = PBXBuildFile; fileRef = 405D7DD97ED24F13AEC1C23B /* PaneChipView.swift */; };
```

Edit 2 — `PBXFileReference` section, insert after:
```
		C43E2B4CEEE6E8798AE14F29 /* GitFileContent.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = GitFileContent.swift; sourceTree = "<group>"; };
		405D7DD97ED24F13AEC1C23B /* PaneChipView.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = PaneChipView.swift; sourceTree = "<group>"; };
```

Edit 3 — the `OmniAgent` group's `children`, insert after:
```
				C43E2B4CEEE6E8798AE14F29 /* GitFileContent.swift */,
				405D7DD97ED24F13AEC1C23B /* PaneChipView.swift */,
```

Edit 4 — the app target's `Sources` phase `files`, insert after:
```
				68F9BD406F6C7DDABE533A9D /* GitFileContent.swift in Sources */,
				C8E5716D35494A029A309845 /* PaneChipView.swift in Sources */,
```

- [ ] **Step 5: Verify the registration compiles before building anything on it**

Run:
```
./macos/build.sh build
```
Expected: `** BUILD SUCCEEDED **`. If `PaneChipView.swift` were unregistered the app would build without it and the next step would fail with `cannot find 'PaneChipView' in scope` — which is why this check comes before the code that depends on it.

- [ ] **Step 6: Add the chip as `PaneContainerView`'s fourth child**

All four edits are in `macos/OmniAgent/PaneWorkspaceView.swift`, inside `final class PaneContainerView`.

(a) Beside `let dropHighlight = PaneDropOverlayView()`, add:

```swift
    /// The level-of-detail stand-in — see `PaneChipView`. A sibling of
    /// `header`/`surface`/`approvalBar`, because `surface` is `let`.
    let chip = PaneChipView()

    /// Whether this pane is drawn as a chip instead of as itself.
    ///
    /// The surface is **hidden**, not merely suspended: `suspendsDrawing`
    /// gates only the extra renderer kick `TerminalSurfaceView.feed` posts,
    /// while SwiftTerm keeps calling `setNeedsDisplay` on every feed. A hidden
    /// view is not composited and its `setNeedsDisplay` schedules nothing.
    ///
    /// The header goes down with it. It carries the same three facts the chip
    /// does — mark, engine, name — and at the scale a chip exists for it is
    /// three points tall: two labels for one pane, one of them unreadable.
    /// The approval bar needs no such treatment; the chip is opaque, fills the
    /// pane and is stacked above it.
    ///
    /// Written only by `PaneWorkspaceView.updateVisibility()`, which is the
    /// sole owner of per-pane visibility. Anything that assigns this from
    /// elsewhere is overwritten by that method's next call — the same trap
    /// `setSuspendsDrawing`'s comment already records for `suspendsDrawing`.
    var isChipped = false {
        didSet {
            guard isChipped != oldValue else { return }
            chip.isHidden = !isChipped
            surface.isHidden = isChipped
            header.isHidden = isChipped
            // Directly, not through `needsLayout`: a chip that arrives one
            // layout pass later is a blank pane for a frame, and the windowless
            // test host never turns a run loop to deliver that pass at all.
            applyLayout()
        }
    }
```

(b) In `init(paneID:surface:workspace:)`, immediately after `addSubview(approvalBar)` and **before** the `addSubview(dropHighlight, positioned: .above, relativeTo: nil)` line (the drop tint must stay top-most):

```swift
        chip.isHidden = true
        addSubview(chip)
```

(c) In `applyLayout()`, after the `approvalBar.frame = …` assignment and before `dropHighlight.frame = bounds`:

```swift
        // The whole pane inside its 1pt ring: the chip replaces the header and
        // the surface together, so it takes the box both of them shared.
        // Framed on every pass, hidden or not, so it is right the instant it
        // is shown.
        chip.frame = CGRect(x: inset, y: inset, width: width, height: max(0, bounds.height - inset * 2))
```

(d) In `roundChildren(inside:)`, add `chip.wantsLayer = true` beside the existing two, and a fourth entry to the loop. Its comment is a live trap for exactly this edit:

> `maskedCorners` is resolved in each child's **own** coordinate space — AppKit manages the backing layers' geometry flips to preserve every view's own convention, so this container being flipped says nothing about which literal pair a child needs. Naming `MaxY` "the bottom" for every child put the unflipped terminal surface's rounding at its *top* on screen … The offscreen render harness cannot show the difference (`CALayer.render(in:)` skips the compositor's geometry flips), which is how it went unseen.

```swift
        let inner = max(0, radius - Self.borderWidth)
        header.wantsLayer = true
        surface.wantsLayer = true
        chip.wantsLayer = true
        // The screen-bottom corner pair belongs to whichever child sits on the
        // bottom edge — the approval bar takes it over while it is showing.
        func screenBottom(of child: NSView) -> CACornerMask {
            child.isFlipped
                ? [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
                : [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        }
        func screenTop(of child: NSView) -> CACornerMask {
            child.isFlipped
                ? [.layerMinXMinYCorner, .layerMaxXMinYCorner]
                : [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        }
        for (child, corners) in [
            (header as NSView, screenTop(of: header)),
            (surface as NSView, approvalBar.isHidden ? screenBottom(of: surface) : []),
            (approvalBar as NSView, screenBottom(of: approvalBar)),
            // The chip is the only child on both edges at once, so it takes
            // both pairs — which is also why the flip cannot bite here, and why
            // it is written as the union of the two helpers rather than as a
            // four-corner literal the next author would have to re-derive.
            (chip as NSView, screenTop(of: chip).union(screenBottom(of: chip))),
        ] {
            child.layer?.cornerRadius = inner
            child.layer?.cornerCurve = .continuous
            child.layer?.maskedCorners = corners
            child.layer?.masksToBounds = true
        }
```

(e) In `descriptorChanged(_ descriptor: PaneDescriptor)`, after the existing `header.engine = …` line:

```swift
        // The chip says the same three things the header says, from the same
        // two expressions, so the two can never disagree about a pane.
        chip.title = header.title
        chip.engine = header.engine
```

and in `status`'s `didSet`, after `header.status = status`:

```swift
            chip.status = status
```

- [ ] **Step 7: Add the threshold to the workspace**

In `macos/OmniAgent/PaneWorkspaceView.swift`, beside `canvasRect(forGroup:)`:

```swift
    /// Whether the camera is far enough out that pane surfaces carry no
    /// information: at `DeskCanvas.lodThreshold` 12pt type is 2.4pt. Below it
    /// the surfaces come down and chips take their place.
    ///
    /// Not a compromise on live miniatures — there is nothing in those pixels,
    /// only cost. SwiftTerm has no lever for it either: `metalScaleFactorOverride`
    /// looks like one and is clamped by `max(1, …)`, so a shrunken terminal
    /// still rasterizes at full backing scale.
    var showsChips: Bool {
        canvasMode && camera.scale < DeskCanvas.lodThreshold
    }
```

and in `updateVisibility()`, hoist the flag once and assign it per container:

```swift
        let visible = onScreenPaneIDs()
        let chips = showsChips
        for (id, container) in containers {
            let onScreen = visible.contains(id)
            container.isHidden = !onScreen
            container.surface.suspendsDrawing = suspendsDrawing || !onScreen
            container.isChipped = onScreen && chips
        }
```

- [ ] **Step 8: Run the chip tests**

Run:
```
xcodebuild test -project macos/OmniAgent.xcodeproj -scheme OmniAgent \
  -destination "platform=macOS,arch=$(uname -m)" CODE_SIGNING_ALLOWED=NO \
  ONLY_ACTIVE_ARCH=YES ARCHS="$(uname -m)" \
  -only-testing:OmniAgentTests/DeskCanvasLODTests
```

Expected: ten of eleven pass; the repaint test is still red —
```
DeskCanvasLODTests.testASurfaceComingBackAboveTheThresholdIsRepaintedNotLeftOnItsLastDrawable : XCTAssertGreaterThan failed: ("1") is not greater than ("1") - the surface is kicked once on the way back up
```

- [ ] **Step 9: Kick the surface on the way back up**

In `isChipped`'s `didSet` in `PaneContainerView`, after `applyLayout()`:

```swift
            // Un-hiding is not a repaint. While the surface was down its own
            // `setNeedsDisplay` scheduled nothing, and `MacTerminalView.draw(_:)`
            // opens with `if metalView != nil { return }` — so the CG-path nudge
            // `suspendsDrawing`'s didSet does is a no-op once Metal is on, and an
            // idle terminal would come back showing a stale drawable until its
            // next byte arrives. `requestRendererDraw()` is the primitive that
            // actually paints; it is not on `PaneContentView`, hence the cast —
            // the same one `approvalBar.onChoose` makes.
            if !isChipped { (surface as? TerminalSurfaceView)?.requestRendererDraw() }
```

- [ ] **Step 10: Run the chip tests again**

Run the same `-only-testing:OmniAgentTests/DeskCanvasLODTests` command.
Expected: PASS — `Executed 11 tests, with 0 failures`.

- [ ] **Step 11: Run the whole suite**

Run:
```
./macos/build.sh test
```
Expected: `0 failures`, with the executed count higher than the run recorded at the start of this task by exactly this task's new tests. Pay attention to `PaneWorkspaceViewTests` — `applyLayout` and `roundChildren` are shared with focus mode, and `testPanesAndHolesTileTheWorkspaceBoundsExactly` and the approval-bar geometry tests are the ones a bad chip frame would take down.

- [ ] **Step 12: Commit**

```bash
git -C /Users/bonando/Documents/Bruno.Digital/OmniAgent-ADE status --porcelain \
  macos/OmniAgent/PaneChipView.swift macos/OmniAgent/PaneWorkspaceView.swift \
  macos/OmniAgentTests/DeskCanvasLODTests.swift macos/OmniAgent.xcodeproj/project.pbxproj

git -C /Users/bonando/Documents/Bruno.Digital/OmniAgent-ADE add \
  macos/OmniAgent/PaneChipView.swift macos/OmniAgent/PaneWorkspaceView.swift \
  macos/OmniAgentTests/DeskCanvasLODTests.swift macos/OmniAgent.xcodeproj/project.pbxproj

git -C /Users/bonando/Documents/Bruno.Digital/OmniAgent-ADE commit -m "feat(macos): panes the camera cannot read are drawn as chips

Below DeskCanvas.lodThreshold a pane surface is 2.4pt type: no information,
only cost. The surface and the header come down and PaneChipView takes their
place -- engine mark, name, status dot, all sized as fractions of the chip's
own box so the camera cannot shrink them out of legibility.

A fourth sibling in PaneContainerView, not a replacement surface: surface is
let. Threaded through applyLayout and roundChildren, where the chip takes all
four corners so the maskedCorners flip the offscreen harness cannot see cannot
apply to it.

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"

git -C /Users/bonando/Documents/Bruno.Digital/OmniAgent-ADE push
```

---

### Task 6c: Level of detail, part 3 — blink suppression

One selected pane is one 0.7s repeating `Timer` calling `setNeedsDisplay` on the Metal view, driven by the cursor **style** alone and immune to every flag. `TerminalSurfaceView.isSelected`'s `didSet` swapping in `steadyTwin(of:)` is the only thing that stops it — its own comment says so:

> its blink timer runs off the cursor *style* alone, so every open pane sat there flashing an outline at you — and, under Metal, woke a frame each to do it.

Today selection is welded to the focus ring: `PaneContainerView.isFocused`'s `didSet` does `surface.isSelected = isFocused`. On the canvas those two must come apart — the ring still says which pane you will land on, while nothing blinks until the camera has actually landed on that pane's session at identity scale, which is the only state in which a pane accepts input at all (spec §4).

**Files:**
- Modify: `macos/OmniAgent/PaneWorkspaceView.swift` (`PaneContainerView.isFocused`, new `PaneContainerView.isSelected`; new `selectablePaneID` / `updateSelection()` beside `updateVisibility()`; `updateFocusRings()`; `updateVisibility()`)
- Test: `macos/OmniAgentTests/DeskCanvasLODTests.swift` (extend)

**Interfaces:**

- Consumes (existing, verified):
  - `var isFocused = false { didSet { guard isFocused != oldValue else { return }; header.isFocused = isFocused; surface.isSelected = isFocused; updateChrome() } }` (`PaneContainerView`)
  - `private func updateFocusRings()` — body today is `for (id, container) in containers { container.isFocused = id == focusedPaneID }`
  - `func focusPane(_ sessionID: String)`, `func adoptFocus(from responder: NSResponder?)`, `private(set) var focusedPaneID: String?`
  - `var isSelected: Bool { get set }` (`PaneContentView`), `var isSelected = false { didSet { … wash.isHidden = isSelected; applyCursorBlink() } }` (`TerminalSurfaceView`)
  - `var sessionKiller: ((String) -> Void)?`, `var workspaceView: PaneWorkspaceView { workspace }`, `convenience init(connection: SessionConnection, sessionID: String)` (`WorkspaceWindowController`)
- Consumes (fixed shared API): `var isIdentity: Bool { get }` (`DeskCamera`)
- Produces:
  - `var isSelected: Bool` on `PaneContainerView`
  - `private var selectablePaneID: String? { get }` on `PaneWorkspaceView`
  - `private func updateSelection()` on `PaneWorkspaceView`

---

- [ ] **Step 1: Write the failing blink tests**

Append to `DeskCanvasLODTests`, in a new `// MARK: - Blink suppression` section above `// MARK: - Helpers`:

```swift
    // MARK: - Blink suppression

    /// Nothing blinks while the camera is out on the canvas. A blinking cursor
    /// is a 0.7s `Timer` forcing a full-resolution Metal frame, and at canvas
    /// scale the caret it is drawing is two points tall.
    ///
    /// The focus *ring* is untouched: which pane you will land on is still
    /// worth showing.
    func testNoCursorBlinksWhileTheCameraIsOutOnTheCanvas() throws {
        let workspace = makeCanvasWorkspace(sessions: 2, panesEach: 1)
        workspace.focusPane("s1-p1")
        let card = try XCTUnwrap(workspace.canvasRect(forGroup: "grp-1"))

        workspace.camera = DeskCamera.focus(
            on: card.insetBy(dx: -card.width * 4.5, dy: -card.height * 4.5),
            in: workspace.bounds
        )

        XCTAssertFalse(workspace.camera.isIdentity, "the fixture must be off identity")
        let focused = try XCTUnwrap(workspace.container(for: "s1-p1"))
        XCTAssertEqual(workspace.focusedPaneID, "s1-p1", "focus is remembered, only the blink is off")
        XCTAssertTrue(focused.isFocused, "and the ring still says which pane it is")
        XCTAssertFalse(focused.isSelected)
        XCTAssertFalse(focused.terminalSurface.isSelected)
        XCTAssertEqual(
            focused.terminalSurface.terminalView.terminal.options.cursorStyle,
            .steadyBlock,
            "the style is swapped for its steady twin, which is what stops the timer"
        )
    }

    /// It comes back the moment the camera lands, and only then: at identity
    /// scale the transform *is* identity, every coordinate conversion in this
    /// file is correct again, and the pane is being typed into.
    func testTheFocusedPaneBlinksAgainOnceTheCameraHasLandedAtIdentity() throws {
        let workspace = makeCanvasWorkspace(sessions: 2, panesEach: 1)
        workspace.focusPane("s1-p1")
        let card = try XCTUnwrap(workspace.canvasRect(forGroup: "grp-1"))
        workspace.camera = DeskCamera.focus(
            on: card.insetBy(dx: -card.width * 4.5, dy: -card.height * 4.5),
            in: workspace.bounds
        )
        XCTAssertFalse(try XCTUnwrap(workspace.container(for: "s1-p1")).isSelected)

        // Identity by construction — `isIdentity` is "scale exactly 1 and an
        // integral origin", which this is wherever the tidy tree put the cards.
        workspace.camera = DeskCamera(scale: 1, origin: .zero)

        XCTAssertTrue(workspace.camera.isIdentity)
        let focused = try XCTUnwrap(workspace.container(for: "s1-p1"))
        XCTAssertTrue(focused.isSelected)
        XCTAssertTrue(focused.terminalSurface.isSelected)
        XCTAssertEqual(focused.terminalSurface.terminalView.terminal.options.cursorStyle, .blinkBlock)
    }

    /// And only the session the camera is on. `adoptFocus` is the click path,
    /// and it sets `focusedPaneID` without touching `activeGroup` — so a pane
    /// in a session the camera is not on can hold focus, and must not blink at
    /// full resolution behind the one you are looking at.
    func testASessionTheCameraIsNotOnNeverBlinksEvenAtIdentity() throws {
        let workspace = makeCanvasWorkspace(sessions: 2, panesEach: 1)
        workspace.camera = DeskCamera(scale: 1, origin: .zero)
        XCTAssertEqual(workspace.activeGroup, "grp-2", "the last pane added owns the active session")

        let foreign = try XCTUnwrap(workspace.container(for: "s1-p1"))
        workspace.adoptFocus(from: foreign.surface)

        XCTAssertEqual(workspace.focusedPaneID, "s1-p1")
        XCTAssertEqual(workspace.activeGroup, "grp-2", "adoptFocus does not switch sessions")
        XCTAssertFalse(foreign.isSelected, "a session the camera is not on holds no blink")
        XCTAssertEqual(foreign.terminalSurface.terminalView.terminal.options.cursorStyle, .steadyBlock)
        XCTAssertFalse(try XCTUnwrap(workspace.container(for: "s2-p1")).isSelected, "and neither does any other")
    }

    /// Normal mode is exactly what it was: the focused pane blinks, everything
    /// else holds a steady cursor of the same shape.
    func testNormalModeStillGivesTheFocusedPaneItsBlink() throws {
        let workspace = makeCanvasWorkspace(sessions: 2, panesEach: 2)
        workspace.canvasMode = false

        workspace.focusPane("s1-p2")

        let focused = try XCTUnwrap(workspace.container(for: "s1-p2"))
        XCTAssertTrue(focused.isSelected)
        XCTAssertEqual(focused.terminalSurface.terminalView.terminal.options.cursorStyle, .blinkBlock)
        XCTAssertEqual(
            try XCTUnwrap(workspace.container(for: "s1-p1")).terminalSurface
                .terminalView.terminal.options.cursorStyle,
            .steadyBlock
        )
    }
```

- [ ] **Step 2: Run them and watch them fail**

Run:
```
xcodebuild test -project macos/OmniAgent.xcodeproj -scheme OmniAgent \
  -destination "platform=macOS,arch=$(uname -m)" CODE_SIGNING_ALLOWED=NO \
  ONLY_ACTIVE_ARCH=YES ARCHS="$(uname -m)" \
  -only-testing:OmniAgentTests/DeskCanvasLODTests
```

Expected: compile failure —
```
DeskCanvasLODTests.swift:NN:29: error: value of type 'PaneContainerView' has no member 'isSelected'
** TEST BUILD FAILED **
```

- [ ] **Step 3: Split selection out of the focus ring**

In `macos/OmniAgent/PaneWorkspaceView.swift`, in `final class PaneContainerView`, replace `isFocused` and add `isSelected` beside it:

```swift
    var isFocused = false {
        didSet {
            guard isFocused != oldValue else { return }
            header.isFocused = isFocused
            updateChrome()
        }
    }

    /// Whether this is the pane the cursor blinks in.
    ///
    /// Split out of `isFocused` for the canvas. A blinking cursor is a 0.7s
    /// repeating `Timer` that calls `setNeedsDisplay` on the Metal view; below
    /// identity scale nothing is being typed into and that frame draws a caret
    /// nobody can see. `PaneWorkspaceView.selectablePaneID` answers "which
    /// pane, if any", and in normal mode its answer is the focused pane — so
    /// the two move together exactly as they did when this was one line inside
    /// `isFocused`'s `didSet`.
    var isSelected = false {
        didSet {
            guard isSelected != oldValue else { return }
            // The cursor is part of "which pane am I typing into": only this
            // one blinks (see `TerminalSurfaceView.isSelected`).
            surface.isSelected = isSelected
        }
    }
```

- [ ] **Step 4: Decide who may blink**

In `macos/OmniAgent/PaneWorkspaceView.swift`, immediately below `updateVisibility()`:

```swift
    /// The one pane whose cursor may blink, and the only one wearing the
    /// selected treatment.
    ///
    /// A blinking cursor is a 0.7s repeating `Timer` forcing a
    /// full-resolution Metal frame, driven by the cursor *style* alone and
    /// immune to `suspendsDrawing`; `TerminalSurfaceView.isSelected`'s `didSet`
    /// swapping in `steadyTwin(of:)` is the only thing that stops it.
    ///
    /// Normal mode: the focused pane, exactly as before. Canvas mode: nobody,
    /// unless the camera has landed at identity on the focused pane's own
    /// session — which is precisely the state in which a pane accepts input at
    /// all, since every coordinate conversion in this file is blind to the
    /// camera's layer transform below it.
    private var selectablePaneID: String? {
        guard canvasMode else { return focusedPaneID }
        guard
            let focusedPaneID,
            descriptors[focusedPaneID]?.group == activeGroup,
            camera.isIdentity
        else { return nil }
        return focusedPaneID
    }

    /// One writer for selection, the way `updateVisibility` is the one writer
    /// for `isHidden`/`suspendsDrawing`. Reached from both the focus pass and
    /// the visibility pass, because either the focused pane or the camera can
    /// change the answer and neither implies the other.
    private func updateSelection() {
        let selected = selectablePaneID
        for (id, container) in containers {
            container.isSelected = id == selected
        }
    }
```

Call it from both passes. At the end of `updateFocusRings()`:

```swift
    private func updateFocusRings() {
        for (id, container) in containers {
            container.isFocused = id == focusedPaneID
        }
        updateSelection()
    }
```

and as the last statement of `updateVisibility()`, after the container loop:

```swift
        // The camera decides who may blink as much as it decides who is on
        // screen, and a camera move runs this pass and no other.
        updateSelection()
```

- [ ] **Step 5: Run the blink tests**

Run:
```
xcodebuild test -project macos/OmniAgent.xcodeproj -scheme OmniAgent \
  -destination "platform=macOS,arch=$(uname -m)" CODE_SIGNING_ALLOWED=NO \
  ONLY_ACTIVE_ARCH=YES ARCHS="$(uname -m)" \
  -only-testing:OmniAgentTests/DeskCanvasLODTests
```
Expected: PASS — `Executed 15 tests, with 0 failures`.

- [ ] **Step 6: Pin the lifecycle invariant**

Level of detail is a rendering decision and must never become a lifecycle one. `PaneWorkspaceView` has no kill path of its own — `onRequestClosePane`'s comment: *"Closing a pane ends its PTY, which only the window controller may do — this view never kills a session itself."* — and the controller funnels every kill through `killSession(_:)` so `sessionKiller` sees them all. Append to `DeskCanvasLODTests`, at the end of the blink section:

```swift
    // MARK: - Lifecycle

    /// Culling, chipping and deselecting are all rendering decisions. None of
    /// them may reach the daemon: `PaneWorkspaceView` "never kills a session
    /// itself", and `WorkspaceWindowController.killSession` is the one funnel
    /// `sessionKiller` watches.
    ///
    /// A guard, not a driver — it is expected to pass the first time it runs.
    /// It exists so a later change that reaps "invisible" panes fails here
    /// instead of in someone's terminal.
    func testLevelOfDetailNeverKillsASession() throws {
        let controller = WorkspaceWindowController(
            connection: SessionConnection(
                socketURL: URL(fileURLWithPath: "/tmp/omniagent-desk-canvas-lod-test.sock")
            ),
            sessionID: "native-terminal"
        )
        defer { controller.close() }
        controller.showWindow(nil)
        var killed: [String] = []
        controller.sessionKiller = { killed.append($0) }

        let workspace = controller.workspaceView
        XCTAssertTrue(workspace.addPane(PaneDescriptor(sessionID: "far-1", group: "grp-far")))
        let before = workspace.allPaneIDs.sorted()

        // Activate the group *before* canvas mode, so the focused pane is
        // already in the active session. Task 7 makes a cross-session
        // `focusPane` in canvas mode a camera flight — focus does not move
        // until the flight lands — and a test that focuses across sessions and
        // asserts immediately would race it.
        workspace.activateGroup("grp-far")
        workspace.canvasMode = true
        workspace.layoutSubtreeIfNeeded()
        let card = try XCTUnwrap(workspace.canvasRect(forGroup: "grp-far"))
        // On camera at identity, then culled, then chipped, then back out.
        workspace.camera = DeskCamera.focus(on: card, in: workspace.bounds)
        workspace.camera = DeskCamera.focus(
            on: try XCTUnwrap(workspace.canvasRect(forGroup: try XCTUnwrap(workspace.groupIDs.first))),
            in: workspace.bounds
        )
        workspace.camera = DeskCamera.focus(
            on: card.insetBy(dx: -card.width * 9, dy: -card.height * 9),
            in: workspace.bounds
        )
        workspace.canvasMode = false

        XCTAssertEqual(killed, [], "level of detail is a rendering decision, never a lifecycle one")
        XCTAssertEqual(workspace.allPaneIDs.sorted(), before, "and nothing was torn down")
    }
```

- [ ] **Step 7: Run it**

Run:
```
xcodebuild test -project macos/OmniAgent.xcodeproj -scheme OmniAgent \
  -destination "platform=macOS,arch=$(uname -m)" CODE_SIGNING_ALLOWED=NO \
  ONLY_ACTIVE_ARCH=YES ARCHS="$(uname -m)" \
  -only-testing:OmniAgentTests/DeskCanvasLODTests
```
Expected: PASS — `Executed 16 tests, with 0 failures`. A failure here is not a flake: `killed` being non-empty means something in the canvas path is reaching `WorkspaceWindowController.killSession`, and the reaper in `applyRestoredPanes`' orphan sweep (which measures `owned: Set(workspace.allPaneIDs)`) is the first place to look.

- [ ] **Step 8: Run the whole suite**

Run:
```
./macos/build.sh test
```
Expected: `0 failures`, with the executed count higher than the run recorded at the start of this task by exactly this task's new tests. The three existing tests this change could plausibly break, all in `PaneWorkspaceViewTests`, are `testOnlyTheSelectedPaneBlinksItsCursor`, `testDeselectDoesNotClobberACursorStyleTheProgramChose` and `testOnlyTheSelectedPaneIsUnwashed` — all three construct a workspace with `canvasMode == false`, where `selectablePaneID` returns `focusedPaneID` and behaviour is byte-for-byte what it was.

- [ ] **Step 9: Commit**

```bash
git -C /Users/bonando/Documents/Bruno.Digital/OmniAgent-ADE status --porcelain \
  macos/OmniAgent/PaneWorkspaceView.swift macos/OmniAgentTests/DeskCanvasLODTests.swift

git -C /Users/bonando/Documents/Bruno.Digital/OmniAgent-ADE add \
  macos/OmniAgent/PaneWorkspaceView.swift macos/OmniAgentTests/DeskCanvasLODTests.swift

git -C /Users/bonando/Documents/Bruno.Digital/OmniAgent-ADE commit -m "feat(macos): nothing blinks while the camera is out on the canvas

A blinking cursor is a 0.7s Timer forcing a full-resolution Metal frame,
driven by the cursor style alone and immune to every drawing flag --
TerminalSurfaceView.isSelected's didSet is the only thing that stops it.

Selection is therefore split out of PaneContainerView.isFocused: the ring
still says which pane you will land on, while only the camera's own session,
landed at identity, holds the blink. In normal mode selectablePaneID returns
the focused pane, so nothing about the grid changes.

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"

git -C /Users/bonando/Documents/Bruno.Digital/OmniAgent-ADE push
```

---

### Task 7: The camera flight, and every way into and out of a session

**Files:**
- Modify: `macos/OmniAgent/PaneWorkspaceView.swift` (one new `// MARK: - Desk canvas camera` block inserted **after `updateVisibility()`**, inside the `PaneWorkspaceView` class body; plus a one-line edit in `updateLayout()` and a branch in `focusPane(_:)`)
- Create: `macos/OmniAgentTests/DeskCameraFlightTests.swift`
- Modify: `macos/OmniAgent.xcodeproj/project.pbxproj` (register the new test file)
- Test: `macos/OmniAgentTests/DeskCameraFlightTests.swift`

**Interfaces:**

Consumes (from earlier tasks, verbatim):
- `struct DeskCamera: Equatable { var scale: CGFloat; var origin: CGPoint; static let maxScale: CGFloat; var transform: CATransform3D { get }; func canvasPoint(from viewPoint: CGPoint) -> CGPoint; static func fitAll(content: CGRect, in bounds: CGRect) -> DeskCamera; static func focus(on rect: CGRect, in bounds: CGRect) -> DeskCamera; func clamped(minScale: CGFloat, in bounds: CGRect) -> DeskCamera; var isIdentity: Bool { get } }`
- `struct DeskCanvasLayout: Equatable { let frames: [String: CGRect]; let edges: [DeskEdge]; let contentRect: CGRect }`
- `var canvasMode: Bool { get set }` and `var camera: DeskCamera { get set }` on `PaneWorkspaceView`

Consumes (existing, verified in `macos/OmniAgent/PaneWorkspaceView.swift`):
- `static let zoomTransitionDuration: TimeInterval = 0.38`
- `static let zoomTimingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)`
- `private var grids: [String: PaneGrid]`, `private(set) var activeGroup: String?`, `var paneIDs: [String]`, `var groupIDs: [String]`, `var allPaneIDs: [String]`, `private(set) var focusedPaneID: String?`
- `@discardableResult func activateGroup(_ group: String) -> Bool`
- `private func updateVisibility()`, `func updateLayout()`, `private func carryCardToFocusedPane()`
- `func focusPane(_ sessionID: String)`
- `let resizeCoalescer = PaneResizeCoalescer()` (`private(set) var flushCount: Int`, `var hasPending: Bool`), `func terminalSurface(for sessionID: String) -> TerminalSurfaceView?` (`private(set) var resizeSendCount: Int`)
- `func contains(_ id: String) -> Bool` on `PaneGrid`

Produces:
- `func flyCamera(to target: DeskCamera)`
- `func enterSession(_ group: String)`
- `func exitToCanvas()`
- `func canvasRect(forGroup group: String) -> CGRect?`
- `func setDeskCanvasLayout(_ layout: DeskCanvasLayout)`
- `private(set) var canvasLayout: DeskCanvasLayout?`
- `static let cameraFlightKey = "sublayerTransform"`
- Behaviour change: `focusPane(_:)` flies instead of swapping `activeGroup` **when `canvasMode` is true**; unchanged otherwise.

---

- [ ] **Step 1: Create the test file with the three flight-mechanics tests**

Create `macos/OmniAgentTests/DeskCameraFlightTests.swift`:

```swift
import AppKit
import XCTest
@testable import OmniAgent

/// The canvas has exactly one operation: move the camera so a rect maps onto
/// the viewport. A click on a card, a double-click, a session shortcut and a
/// zoom past identity (`pinchCanvas`, Task 8) all resolve to it, and so does the way back
/// out. This file pins the operation itself — the animation's mechanics, the
/// exactness of the landing, and the two things a camera move must *not* do:
/// swap the grid underneath the user, or cost a PTY resize.
final class DeskCameraFlightTests: XCTestCase {
    // MARK: - The flight

    /// The completion is scheduled with `DispatchQueue.main.asyncAfter` and
    /// guarded by a token, never handed to an animation's delegate, because with
    /// no window or under Reduce Motion "an animation group's completion is not
    /// guaranteed to arrive at all" (`setZoomed`). Here there is no window at
    /// all: the landing has to be synchronous or it never happens, and a camera
    /// stranded between two sessions leaves no pane accepting input.
    func testAFlightWithNoWindowLandsTheSessionTheInstantItIsAsked() throws {
        let workspace = makeWorkspace(groups: 2, panesPerGroup: 2)
        XCTAssertNil(workspace.window, "the point of this test")
        workspace.canvasMode = true
        let layer = try XCTUnwrap(workspace.layer)
        // A decoy under another key. `finishCameraFlight` removes its own
        // animation by key and leaves everything else alone — `landCard`'s rule:
        // "yanking whatever else a layer happens to be running is how you break
        // something you did not write."
        let decoy = CABasicAnimation(keyPath: "opacity")
        decoy.fromValue = 1.0
        decoy.toValue = 1.0
        decoy.duration = 60
        layer.add(decoy, forKey: "test-decoy")

        workspace.enterSession("sess-grp-2")

        XCTAssertFalse(workspace.canvasMode, "landed, with nothing to wait for")
        XCTAssertEqual(workspace.activeGroup, "sess-grp-2")
        XCTAssertEqual(workspace.camera, DeskCamera(scale: 1, origin: .zero))
        XCTAssertTrue(workspace.camera.isIdentity, "identity is what landing means")
        XCTAssertTrue(
            CATransform3DIsIdentity(layer.sublayerTransform),
            "snapped on arrival, or the text stays permanently soft"
        )
        XCTAssertNil(layer.animation(forKey: PaneWorkspaceView.cameraFlightKey))
        XCTAssertNotNil(
            layer.animation(forKey: "test-decoy"),
            "removed by key, never with removeAllAnimations()"
        )
    }

    /// One system with the pane zoom: the same 0.38s and the same front-loaded
    /// curve, so entering a session and zooming a pane read as the same gesture
    /// at two scales. A raw `CABasicAnimation` rather than `NSView.animator()`,
    /// for the reason `place` records — the animator wraps each frame change in
    /// an `_NSWindowTransformAnimation`, and two of those were seen alive on one
    /// view when a second transition began inside the first's.
    func testTheFlightAnimatesThisViewsSublayerTransformWithTheZoomsDurationAndCurve() throws {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            throw XCTSkip("under Reduce Motion the camera lands instantly")
        }
        let (workspace, window) = makeAttachedWorkspace(groups: 2, panesPerGroup: 1)
        defer { window.close() }
        workspace.canvasMode = true
        let layer = try XCTUnwrap(workspace.layer)
        let content = try XCTUnwrap(workspace.canvasLayout?.contentRect)
        let before = layer.sublayerTransform

        workspace.flyCamera(to: DeskCamera.fitAll(content: content, in: workspace.bounds))

        let flight = try XCTUnwrap(
            layer.animation(forKey: PaneWorkspaceView.cameraFlightKey) as? CABasicAnimation
        )
        XCTAssertEqual(flight.keyPath, "sublayerTransform", "the camera is a transform, not a frame")
        XCTAssertEqual(flight.duration, PaneWorkspaceView.zoomTransitionDuration)
        XCTAssertEqual(flight.timingFunction, PaneWorkspaceView.zoomTimingFunction)
        let from = try XCTUnwrap((flight.fromValue as? NSValue)?.caTransform3DValue)
        XCTAssertTrue(
            CATransform3DEqualToTransform(from, before),
            "from where the eye is, not from the model it already left"
        )
        XCTAssertTrue(
            CATransform3DEqualToTransform(layer.sublayerTransform, workspace.camera.transform),
            "the model value lands immediately — `place`'s discipline"
        )
        XCTAssertNil(layer.animation(forKey: "position"), "the camera moves nothing's frame")
    }

    /// Two flights inside one duration. Both completions arrive; without the
    /// token the *entry*'s completion lands session 2 partway through the exit
    /// that followed it, and the user is dropped into a session they just flew
    /// away from. The same failure `zoomTransitionToken` exists for.
    func testAnEntrysCompletionCannotLandTheSessionTheExitFlewAwayFrom() throws {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            throw XCTSkip("under Reduce Motion both flights land instantly")
        }
        let (workspace, window) = makeAttachedWorkspace(groups: 2, panesPerGroup: 1)
        defer { window.close() }
        workspace.canvasMode = true
        let content = try XCTUnwrap(workspace.canvasLayout?.contentRect)

        let entered = Date()
        workspace.enterSession("sess-grp-2")
        RunLoop.current.run(
            until: entered.addingTimeInterval(PaneWorkspaceView.zoomTransitionDuration / 2)
        )
        XCTAssertLessThan(
            Date().timeIntervalSince(entered),
            PaneWorkspaceView.zoomTransitionDuration,
            "the entry's completion has to still be pending, or this proves nothing"
        )

        workspace.exitToCanvas()
        RunLoop.current.run(
            until: Date().addingTimeInterval(PaneWorkspaceView.zoomTransitionDuration + 0.2)
        )

        XCTAssertTrue(workspace.canvasMode, "the leftover completion did not land session 2")
        XCTAssertEqual(workspace.activeGroup, "sess-grp-1")
        XCTAssertEqual(
            workspace.camera,
            DeskCamera.fitAll(content: content, in: workspace.bounds)
        )
    }

    // MARK: - Helpers

    /// Panes are added one at a time, exactly as ⌘T does, across `groups`
    /// sessions. `addPane` makes the last-added pane's session active, so this
    /// ends by activating the first — every test here starts in session 1.
    private func makeWorkspace(groups: Int, panesPerGroup: Int) -> PaneWorkspaceView {
        let connection = SessionConnection(
            socketURL: URL(fileURLWithPath: "/tmp/omniagent-desk-camera-test.sock")
        )
        let workspace = PaneWorkspaceView { descriptor in
            TerminalSurfaceView(connection: connection, sessionID: descriptor.sessionID)
        }
        workspace.frame = CGRect(x: 0, y: 0, width: 1200, height: 800)
        for group in 1...groups {
            for pane in 1...panesPerGroup {
                XCTAssertTrue(workspace.addPane(PaneDescriptor(
                    sessionID: "sess-\(group)-pane-\(pane)",
                    group: "sess-grp-\(group)"
                )))
            }
        }
        workspace.activateGroup("sess-grp-1")
        return workspace
    }

    private func makeAttachedWorkspace(
        groups: Int,
        panesPerGroup: Int
    ) -> (PaneWorkspaceView, NSWindow) {
        let workspace = makeWorkspace(groups: groups, panesPerGroup: panesPerGroup)
        let window = WorkspaceWindow(
            contentRect: CGRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        // `NSWindow` defaults to releasing itself when closed and every helper
        // here closes its window in a `defer` while ARC still holds this
        // reference — an over-release that frees the window early, leaving
        // CoreAnimation's window-scoped registrations dangling for the next
        // autorelease-pool drain to dereference. See `PaneWorkspaceViewTests`.
        window.isReleasedWhenClosed = false
        window.contentView = workspace
        window.onFirstResponderChange = { [weak workspace] in workspace?.adoptFocus(from: $0) }
        window.makeKeyAndOrderFront(nil)
        return (workspace, window)
    }

    /// Where the canvas pass actually drew a session's card. Read back rather
    /// than assumed, so these tests pin the camera's behaviour and not the tidy
    /// tree's arithmetic.
    private func card(_ workspace: PaneWorkspaceView, _ group: String) throws -> CGRect {
        try XCTUnwrap(
            workspace.canvasRect(forGroup: group),
            "the canvas pass must place a card per session — none for \(group)"
        )
    }

    /// Canvas → view, the exact inverse of `DeskCamera.canvasPoint(from:)`
    /// without assuming which order the camera composes its scale and its
    /// translation: the transform itself is affine, so ask it.
    private func viewPoint(_ camera: DeskCamera, _ canvasPoint: CGPoint) -> CGPoint {
        canvasPoint.applying(CATransform3DGetAffineTransform(camera.transform))
    }
}
```

- [ ] **Step 2: Register the test file in the Xcode project**

The project has **no** file-system-synchronized groups — a `.swift` file dropped into `macos/OmniAgentTests/` is silently not compiled and its tests silently do not run. Four hand-edits to `macos/OmniAgent.xcodeproj/project.pbxproj`. Ids below were generated with `uuidgen | tr -d '-' | cut -c1-24 | tr 'a-f' 'A-F'` and verified absent from the file; regenerate if `grep` says otherwise. Indentation is **two tab characters** on every line.

Edit 1 — `PBXBuildFile` section, directly after the `GitFileContentTests.swift in Sources` line:
```
		9221AD3E21244586840226C8 /* DeskCameraFlightTests.swift in Sources */ = {isa = PBXBuildFile; fileRef = 928CD3A8DE8E4A35B612FD89 /* DeskCameraFlightTests.swift */; };
```

Edit 2 — `PBXFileReference` section, directly after the `GitFileContentTests.swift` file reference:
```
		928CD3A8DE8E4A35B612FD89 /* DeskCameraFlightTests.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = DeskCameraFlightTests.swift; sourceTree = "<group>"; };
```

Edit 3 — in group `500000000000000000000003 /* OmniAgentTests */`, directly after the `BE0A2CB26F101E0CCC68EFBA /* GitFileContentTests.swift */,` child:
```
				928CD3A8DE8E4A35B612FD89 /* DeskCameraFlightTests.swift */,
```

Edit 4 — in the test target's sources phase `800000000000000000000002 /* Sources */`, directly after the `1ECF599C46245E2BA8447FC1 /* GitFileContentTests.swift in Sources */,` entry:
```
				9221AD3E21244586840226C8 /* DeskCameraFlightTests.swift in Sources */,
```

Gotcha: `project.pbxproj` is a hot, shared file — `scripts/bump-build-version.sh` rewrites `CURRENT_PROJECT_VERSION` in it and concurrent sessions edit it too. Insert lines adjacent to existing ones; never rewrite a section.

- [ ] **Step 3: Run it and watch it fail**

Run:
```
xcodebuild build -project macos/OmniAgent.xcodeproj -scheme OmniAgent \
  -destination "platform=macOS,arch=$(uname -m)" CODE_SIGNING_ALLOWED=NO
```
Expected: compile errors in `DeskCameraFlightTests.swift` —
`value of type 'PaneWorkspaceView' has no member 'enterSession'`,
`… no member 'flyCamera'`, `… no member 'canvasRect'`, `… no member 'canvasLayout'`,
`type 'PaneWorkspaceView' has no member 'cameraFlightKey'`.

- [ ] **Step 4: Add the camera block to `PaneWorkspaceView`**

In `macos/OmniAgent/PaneWorkspaceView.swift`, insert one contiguous section **immediately after `updateVisibility()`** (the end of the `// MARK: - Sessions` section) and before `// MARK: - Lifecycle`. It goes in the class body, not an extension — `canvasLayout` and the tokens are stored properties, which an extension cannot hold.

```swift
    // MARK: - Desk canvas camera

    /// The animation's key on this view's layer, named after the property it
    /// animates the way `zoomLayer` keys by `animation.keyPath`.
    static let cameraFlightKey = "sublayerTransform"


    /// Which flight is current. Same discipline as `zoomTransitionToken`: a
    /// completion does nothing unless the number it was given is still this one,
    /// or an entry's completion lands a session the exit that followed it has
    /// already flown away from.
    private var cameraFlightToken = 0

    /// The session this flight is an entry into, or `nil` for a flight that is
    /// only a move — `fitAll`, a pan, a free zoom. Read once, on arrival.
    private var pendingSessionEntry: String?

    /// The pane a focus request is waiting on the flight for. `focusPane` cannot
    /// focus across the canvas — the pane it wants is not on screen until the
    /// camera gets there — so it names the pane and the landing does the rest.
    private var pendingFocusPaneID: String?

    /// Where the next flight begins when the presentation layer cannot answer.
    /// Exactly `place`'s `start:` parameter and for exactly its reason: "a pane
    /// that has just been reparented, whose presented position is still the one
    /// it had in the view it left." Here it is a camera re-seated by a mode
    /// change — the content moved into canvas coordinates this turn, and the
    /// transform still presented belongs to the layout before it.
    private var cameraFlightStart: DeskCamera?

    /// The canvas layout the cards are actually drawn at, handed over by the
    /// canvas layout pass. Read rather than recomputed: asking `DeskCanvas
    /// .layout` again with a different `pinned` snapshot is how a flight ends up
    /// aimed at a patch of empty canvas.
    private(set) var canvasLayout: DeskCanvasLayout?

    func setDeskCanvasLayout(_ layout: DeskCanvasLayout) {
        canvasLayout = layout
    }

    /// Where one session's card is on the canvas, as the pass that drew it
    /// placed it.
    func canvasRect(forGroup group: String) -> CGRect? {
        canvasLayout?.frames[group]
    }

    /// What `fitAll` fits. `bounds` until the first canvas pass has run, so a
    /// fit asked for before there is a canvas is a stationary camera rather than
    /// a jump to nowhere.
    private var canvasContentRect: CGRect { canvasLayout?.contentRect ?? bounds }

    /// Which session's card a canvas point falls in. A session node's id **is**
    /// its group id — the same string `PaneDescriptor.group` and `activeGroup`
    /// carry — so this is a lookup rather than a walk of the tree, and the
    /// `grids` check is what keeps the root and workspace nodes out of it.
    private func sessionCard(containing point: CGPoint) -> String? {
        canvasLayout?.frames
            .first { grids[$0.key] != nil && $0.value.contains(point) }?
            .key
    }

    /// The canvas's one animation, and the operation every way into and out of a
    /// session resolves to: move the camera so a rect maps onto the viewport.
    ///
    /// The model value lands immediately and the *layer* is animated into it
    /// from where it is presented — `place`'s discipline, for `place`'s reason:
    /// everything downstream (hit testing, `canvasRect`, the next gesture) reads
    /// the model, and only the eye reads the interpolation.
    ///
    /// A raw `CABasicAnimation`, never `NSView.animator()`, and `place` records
    /// why: "The animator wraps each group's frame change in an
    /// `_NSWindowTransformAnimation`, and instrumenting the transitions showed
    /// two of those alive on one view whenever a second transition began inside
    /// the first's 0.32s."
    func flyCamera(to target: DeskCamera) {
        // Before anything else, so a flight still in flight — animated or the
        // instant Reduce Motion kind — can no longer land on this one's behalf.
        cameraFlightToken += 1
        let token = cameraFlightToken
        // Read before the model moves: once `camera` is assigned the layer is
        // already at the destination, and the presented value is the only record
        // of where the eye currently is.
        let from = cameraFlightStart?.transform
            ?? layer?.presentation()?.sublayerTransform
            ?? layer?.sublayerTransform
            ?? CATransform3DIdentity
        cameraFlightStart = nil
        // Both ends of the flight stay on screen for its duration. `camera`'s
        // setter re-derives the visible set, and it is assigned to the
        // *destination* on frame one — so without this the card being left is
        // hidden while the eye is still looking straight at it.
        transitionViewport = camera.canvasViewport(in: bounds)
            .union(target.canvasViewport(in: bounds))
        camera = target
        // Reduced motion still flies, it just lands instantly — and so does a
        // flight in a view with no window, where, as `setZoomed` puts it, "an
        // animation group's completion is not guaranteed to arrive at all.
        // Sequencing the landing behind one that never comes would strand the
        // transition half-done": here, a camera parked between two sessions with
        // no pane accepting input.
        guard window != nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            finishCameraFlight(token)
            return
        }
        let flight = CABasicAnimation(keyPath: Self.cameraFlightKey)
        flight.fromValue = NSValue(caTransform3D: from)
        flight.toValue = NSValue(caTransform3D: target.transform)
        // The zoom's own duration and curve, so canvas zoom and pane focus zoom
        // read as one system rather than as two animations that happen to be
        // near each other.
        flight.duration = Self.zoomTransitionDuration
        flight.timingFunction = Self.zoomTimingFunction
        layer?.add(flight, forKey: Self.cameraFlightKey)
        // Scheduled rather than handed to the animation's delegate, for the same
        // reason `setZoomed` schedules `finishZoomTransition`. A stale timer is
        // harmless: `finishCameraFlight` refuses any token but the current one.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.zoomTransitionDuration) {
            [weak self] in
            self?.finishCameraFlight(token)
        }
    }

    /// The end of one flight's 0.38s, gated on the token so it only ever acts
    /// for the flight it was created by.
    private func finishCameraFlight(_ token: Int) {
        guard token == cameraFlightToken else { return }
        // By key rather than `removeAllAnimations()`, following `landCard`:
        // "these two are the only ones this code adds, and yanking whatever else
        // a layer happens to be running is how you break something you did not
        // write." This view's layer is the shell's too.
        layer?.removeAnimation(forKey: Self.cameraFlightKey)
        // The flight is over, so the union of its two ends stops being the
        // visible set and the camera's own viewport takes over again.
        transitionViewport = nil
        // Gated on the pending entry rather than on `camera.isIdentity`: the two
        // mean the same thing while the tidy tree places cards at integral
        // origins, and if it ever does not, a flight that refused to land would
        // strand the camera mid-air with nothing accepting input. The snap below
        // fixes the fraction either way.
        guard let group = pendingSessionEntry else { return }
        pendingSessionEntry = nil
        landSession(group)
    }

    /// The end of an entry: the camera has arrived over one card at scale 1, and
    /// the view goes back to the single-session layout it has always had. The
    /// two are the same pixels — a card is exactly the viewport — so this is a
    /// change of bookkeeping, not a cut.
    ///
    /// It is also the only way `sublayerTransform` becomes a true identity. A
    /// card at canvas x=1600 leaves the camera's origin at -1600, and every
    /// `event.locationInWindow` conversion in this file — the dividers, the hole
    /// tiles, the header buttons, the editor-tab drop zones — is blind to that
    /// translation. Panes accept input at identity and nowhere else.
    private func landSession(_ group: String) {
        guard grids[group] != nil else { return }
        activeGroup = group
        // `canvasMode` deliberately stays true. Being *in* a session is the
        // camera at identity over that card, not a different layout mode: the
        // card is the size of the viewport, so at identity the pane grid fills
        // `bounds` exactly as normal mode would lay it out. Keeping the mode on
        // is what lets a pinch-out get back to the canvas (the gesture handlers
        // all guard on `canvasMode`), and what lets a trip to Dashboard and back
        // return you to the session you were in rather than to the canvas.
        camera = DeskCamera(scale: 1, origin: .zero)
        // Explicitly, with actions off, so the snap is a snap: a residual scale
        // of 1.0000001 left behind by the interpolation is what makes the text
        // permanently soft.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.sublayerTransform = CATransform3DIdentity
        CATransaction.commit()
        updateVisibility()
        updateLayout()
        let requested = pendingFocusPaneID.flatMap {
            grids[group]?.contains($0) == true ? $0 : nil
        }
        pendingFocusPaneID = nil
        if let target = requested ?? paneIDs.first { focusPane(target) }
        // Or the blink is left behind: "a focus-moving path that skips this
        // helper leaves the blink behind the blur on a pane nobody can see, and
        // reads as a cursor bug rather than a focus-mode one." Called from here
        // rather than from `focusPane(_:)`, which `setZoomed` calls itself and
        // would re-enter.
        carryCardToFocusedPane()
    }

    /// One of the four ways in — a click on a card, a double-click, a session
    /// shortcut, or a zoom that reaches identity over one card — and all four
    /// are this: fly the camera so that card's rect maps onto the viewport, then
    /// land.
    func enterSession(_ group: String) {
        guard grids[group] != nil else { return }
        guard canvasMode else {
            // Off the canvas the instant switch is still the right answer, and
            // it is the one every existing caller and test expects.
            activateGroup(group)
            return
        }
        guard
            bounds.width > 0, bounds.height > 0,
            let card = canvasRect(forGroup: group)
        else { return }
        pendingSessionEntry = group
        flyCamera(to: DeskCamera.focus(on: card, in: bounds))
    }

    /// The way out — ⌘0, Esc, or a pinch that went the other way — and the same
    /// operation as the way in, aimed at `fitAll` instead of at one card.
    func exitToCanvas() {
        pendingSessionEntry = nil
        pendingFocusPaneID = nil
        guard bounds.width > 0, bounds.height > 0 else { return }
        if !canvasMode {
            // Join the canvas *where the session already is*, so the mode change
            // shows nothing: `canvasMode` lays every group out at its node rect,
            // and this camera puts the one that was filling `bounds` back
            // exactly where it was. Both happen in this turn, before CA commits,
            // so no frame is ever drawn with the layout changed and the camera
            // not — and the flight is told to start here rather than from the
            // presented transform, which still belongs to the old layout.
            if let group = activeGroup, let card = canvasRect(forGroup: group) {
                let seat = DeskCamera.focus(on: card, in: bounds)
                camera = seat
                cameraFlightStart = seat
            }
        }
        flyCamera(to: DeskCamera.fitAll(content: canvasContentRect, in: bounds))
    }

```

- [ ] **Step 5: Hand the canvas layout to the camera**

In `updateLayout()`, inside the canvas-mode branch the canvas-mode task added, pass the `DeskCanvasLayout` that pass just placed the cards from to `setDeskCanvasLayout(_:)` — one added line, before the cards are placed:

```swift
    func updateLayout() {
        if canvasMode {
            let canvas = DeskCanvas.layout(root: canvasRoot, cardSize: bounds.size, pinned: canvasPins)
            setDeskCanvasLayout(canvas)   // <- added by Task 7
            layoutCanvasCards(canvas)
            return
        }
        guard let grid else {
```
Task 5 already stores the layout in `private(set) var canvasLayout: DeskCanvasLayout?`, so this task does **not** re-declare it. Delete `setDeskCanvasLayout(_:)` from the Step 4 block above and point `canvasRect(forGroup:)` and `canvasContentRect` at Task 5's property:

```swift
    func canvasRect(forGroup group: String) -> CGRect? { canvasLayout?.frames[group] }
    var canvasContentRect: CGRect { canvasLayout?.contentRect ?? bounds }
```

No edit to `updateLayout()` is needed here — Task 5's `updateCanvasLayout()` already assigns `canvasLayout` on every pass.

- [ ] **Step 6: Run the three flight tests**

Run:
```
xcodebuild test -project macos/OmniAgent.xcodeproj -scheme OmniAgent \
  -destination "platform=macOS,arch=$(uname -m)" CODE_SIGNING_ALLOWED=NO \
  -only-testing:OmniAgentTests/DeskCameraFlightTests
```
Expected: PASS — `Executed 3 tests, with 0 failures`.

- [ ] **Step 7: Write the failing entry/exit tests**

Append to `DeskCameraFlightTests.swift`, before `// MARK: - Helpers`:

```swift
    // MARK: - In and out

    /// Entering is aiming: the camera that maps that card's rect onto the
    /// viewport. Because §4 forces a card to be exactly the Desk viewport, that
    /// camera is identity-scaled — which is what makes "the camera arrived" and
    /// "you are in the session" the same fact.
    func testEnteringASessionAimsTheCameraAtThatSessionsCard() throws {
        let (workspace, window) = makeAttachedWorkspace(groups: 2, panesPerGroup: 1)
        defer { window.close() }
        workspace.canvasMode = true
        let card2 = try card(workspace, "sess-grp-2")

        workspace.enterSession("sess-grp-2")

        XCTAssertEqual(workspace.camera, DeskCamera.focus(on: card2, in: workspace.bounds))
        XCTAssertEqual(workspace.camera.scale, 1, accuracy: 0.0001, "a card is the viewport")
        XCTAssertTrue(
            workspace.camera.isIdentity,
            "and the layout places cards at integral origins, or nothing may accept input here"
        )
        XCTAssertTrue(workspace.canvasMode, "still flying — the landing is 0.38s away")
        XCTAssertEqual(workspace.activeGroup, "sess-grp-1", "and the grid has not changed yet")
    }

    /// Off the canvas the rule is the old one. Every existing caller of
    /// `activateGroup` — the sidebar, the palette, restore — reaches this and
    /// must still get an instant switch and no camera at all.
    func testEnteringASessionOffTheCanvasIsStillTheInstantSwitch() {
        let workspace = makeWorkspace(groups: 2, panesPerGroup: 1)
        XCTAssertFalse(workspace.canvasMode)

        workspace.enterSession("sess-grp-2")

        XCTAssertEqual(workspace.activeGroup, "sess-grp-2")
        XCTAssertTrue(workspace.paneIDs.contains("sess-2-pane-1"))
        XCTAssertEqual(workspace.camera, DeskCamera(scale: 1, origin: .zero), "no flight off the canvas")
    }

    /// Leaving joins the canvas *where the session already is*: the layout mode
    /// changes and the camera is re-seated on that card in the same turn, so the
    /// flight starts from the pixels that were on screen. Read off the
    /// animation's `fromValue`, because the presentation layer at that instant
    /// still holds the transform of the layout that was just replaced — the one
    /// case `place`'s `start:` parameter exists for.
    func testLeavingASessionJoinsTheCanvasWhereItWasBeforeFlyingToFitAll() throws {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            throw XCTSkip("under Reduce Motion the camera lands instantly, with no fromValue to read")
        }
        let (workspace, window) = makeAttachedWorkspace(groups: 2, panesPerGroup: 1)
        defer { window.close() }
        XCTAssertFalse(workspace.canvasMode)
        let layer = try XCTUnwrap(workspace.layer)

        workspace.exitToCanvas()

        XCTAssertTrue(workspace.canvasMode)
        let card1 = try card(workspace, "sess-grp-1")
        let content = try XCTUnwrap(workspace.canvasLayout?.contentRect)
        let flight = try XCTUnwrap(
            layer.animation(forKey: PaneWorkspaceView.cameraFlightKey) as? CABasicAnimation
        )
        let from = try XCTUnwrap((flight.fromValue as? NSValue)?.caTransform3DValue)
        XCTAssertTrue(
            CATransform3DEqualToTransform(
                from,
                DeskCamera.focus(on: card1, in: workspace.bounds).transform
            ),
            "the canvas opens on the session you were in, so the mode change shows nothing"
        )
        XCTAssertEqual(
            workspace.camera,
            DeskCamera.fitAll(content: content, in: workspace.bounds),
            "and flies to the whole tree"
        )
    }
```

- [ ] **Step 8: Run them**

Run:
```
xcodebuild test -project macos/OmniAgent.xcodeproj -scheme OmniAgent \
  -destination "platform=macOS,arch=$(uname -m)" CODE_SIGNING_ALLOWED=NO \
  -only-testing:OmniAgentTests/DeskCameraFlightTests
```
Expected: PASS — `Executed 6 tests, with 0 failures`. If `testLeavingASessionJoinsTheCanvasWhereItWasBeforeFlyingToFitAll` fails with a nil `canvasRect`, Step 5's `setDeskCanvasLayout(_:)` call is missing or in the wrong branch.

- [ ] **Step 9: Write the failing focus tests**

Append to `DeskCameraFlightTests.swift`, before `// MARK: - Helpers`:

```swift
    // MARK: - Focus

    /// `focusPane`'s comment today: "Focusing a pane in another session brings
    /// that session to the screen. This is the single rule that makes the
    /// sidebar work." On the canvas that rule becomes *fly there* — swapping
    /// `activeGroup` underneath the user would replace what they are looking at
    /// with a session that is drawn somewhere else entirely.
    func testFocusingAPaneInAnotherSessionFliesInsteadOfSwappingTheGridUnderneath() throws {
        let (workspace, window) = makeAttachedWorkspace(groups: 2, panesPerGroup: 2)
        defer { window.close() }
        workspace.canvasMode = true
        let card2 = try card(workspace, "sess-grp-2")
        XCTAssertEqual(workspace.activeGroup, "sess-grp-1")

        workspace.focusPane("sess-2-pane-1")

        XCTAssertEqual(workspace.activeGroup, "sess-grp-1", "the grid did not change underneath")
        XCTAssertTrue(workspace.canvasMode)
        XCTAssertEqual(
            workspace.camera,
            DeskCamera.focus(on: card2, in: workspace.bounds),
            "aimed at session 2's card"
        )
        XCTAssertNotEqual(workspace.focusedPaneID, "sess-2-pane-1", "focus waits for the landing")
    }

    /// And the request is not lost on the way: the pane the caller asked for is
    /// the pane that has focus when the camera arrives, not merely the session's
    /// first. Works with or without Reduce Motion — the loop exits on the first
    /// pass when the landing was instant.
    func testTheLandingFocusesTheVeryPaneTheFlightWasAskedFor() throws {
        let (workspace, window) = makeAttachedWorkspace(groups: 2, panesPerGroup: 2)
        defer { window.close() }
        workspace.canvasMode = true

        workspace.focusPane("sess-2-pane-2")
        let deadline = Date().addingTimeInterval(3)
        while workspace.canvasMode, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }

        XCTAssertFalse(workspace.canvasMode, "the flight landed")
        XCTAssertEqual(workspace.activeGroup, "sess-grp-2")
        XCTAssertEqual(workspace.focusedPaneID, "sess-2-pane-2")
        XCTAssertTrue(workspace.camera.isIdentity)
        let layer = try XCTUnwrap(workspace.layer)
        XCTAssertTrue(CATransform3DIsIdentity(layer.sublayerTransform))
    }
```

- [ ] **Step 10: Make `focusPane` fly on the canvas**

In `focusPane(_ sessionID: String)`, keep the existing comment verbatim and add the canvas branch above the swap:

```swift
        // Focusing a pane in another session brings that session to the
        // screen. This is the single rule that makes the sidebar work: its
        // session rows and pane rows both already call through here, so
        // selecting either one switches sessions without a second code path.
        if activeGroup != group {
            // On the canvas the session is flown to rather than swapped in
            // underneath the user. The switch still happens — `landSession`
            // does it when the camera arrives — so every caller still ends up
            // with `sessionID` focused, one camera move later.
            if canvasMode {
                pendingFocusPaneID = sessionID
                enterSession(group)
                return
            }
            activeGroup = group
            updateVisibility()
            updateLayout()
        }
```

- [ ] **Step 11: Run the focus tests and the whole existing pane suite**

Run:
```
xcodebuild test -project macos/OmniAgent.xcodeproj -scheme OmniAgent \
  -destination "platform=macOS,arch=$(uname -m)" CODE_SIGNING_ALLOWED=NO \
  -only-testing:OmniAgentTests/DeskCameraFlightTests \
  -only-testing:OmniAgentTests/PaneWorkspaceViewTests
```
Expected: PASS — `Executed 85 tests, with 0 failures` (8 new + `PaneWorkspaceViewTests`' 77). `canvasMode` is false in every existing test, so the new branch must be inert there.

- [ ] **Step 12: Write the failing gesture tests**

Append to `DeskCameraFlightTests.swift`, before `// MARK: - Helpers`:

```swift
    // MARK: - The gestures are one operation

    /// The spec's whole navigation rule in one test. A click on a card and a
    /// double-click both call `enterSession`; a session shortcut reaches
    /// `focusPane`; a pinch reaches `pinchCanvas` (Task 8). All three aim the camera at
    /// exactly the same rect, so there is one operation and no second code path
    /// to drift.
    func testEveryWayIntoASessionResolvesToTheSameCamera() throws {
        let (workspace, window) = makeAttachedWorkspace(groups: 2, panesPerGroup: 2)
        defer { window.close() }
        workspace.canvasMode = true
        let card2 = try card(workspace, "sess-grp-2")
        let expected = DeskCamera.focus(on: card2, in: workspace.bounds)

        workspace.enterSession("sess-grp-2")
        let byClick = workspace.camera

        workspace.exitToCanvas()
        workspace.focusPane("sess-2-pane-1")
        let byShortcut = workspace.camera

        workspace.exitToCanvas()
        let cursor = viewPoint(workspace.camera, CGPoint(x: card2.midX, y: card2.midY))
        XCTAssertEqual(
            workspace.camera.canvasPoint(from: cursor).x,
            card2.midX,
            accuracy: 0.5,
            "the helper's inverse agrees with the camera's own"
        )
        // The pinch funnel lives in Task 8 (`pinchCanvas`); this task pins only
        // that the rect it must land on is the same one the other two reach.
        workspace.enterSession("sess-grp-2")
        let byZoom = workspace.camera

        XCTAssertEqual(byClick, expected, "the click")
        XCTAssertEqual(byShortcut, expected, "the session shortcut")
        XCTAssertEqual(byZoom, expected, "the zoom past the threshold, which hands off to enterSession")
    }
```

- [ ] **Step 13: Run them**

Run:
```
xcodebuild test -project macos/OmniAgent.xcodeproj -scheme OmniAgent \
  -destination "platform=macOS,arch=$(uname -m)" CODE_SIGNING_ALLOWED=NO \
  -only-testing:OmniAgentTests/DeskCameraFlightTests
```
Expected: PASS, and the run reports `0 failures`. Record the executed count; the next task asserts it grew.

- [ ] **Step 14: Write the failing cost and invariant tests**

Append to `DeskCameraFlightTests.swift`, before `// MARK: - Helpers`:

```swift
    // MARK: - What a camera move must not cost

    /// An ancestor's `sublayerTransform` does not call `setFrameSize` on
    /// descendants, so `TerminalSurfaceView.sizeChanged(source:newCols:newRows:)`
    /// never fires and no `resize` is scheduled. That is the whole reason the
    /// camera is a transform rather than N reframes: panning and zooming a
    /// canvas of up to 96 live terminals must be free of PTY traffic. Asserted
    /// rather than assumed.
    func testACameraMoveCostsNoPTYResizes() throws {
        let workspace = makeWorkspace(groups: 2, panesPerGroup: 3)
        workspace.canvasMode = true
        let content = try XCTUnwrap(workspace.canvasLayout?.contentRect)
        workspace.camera = DeskCamera.fitAll(content: content, in: workspace.bounds)
        // Everything the mode change itself scheduled, sent and settled first.
        workspace.resizeCoalescer.flush()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        workspace.resizeCoalescer.flush()
        let flushes = workspace.resizeCoalescer.flushCount
        let sends = workspace.allPaneIDs.reduce(into: [String: Int]()) {
            $0[$1] = workspace.terminalSurface(for: $1)?.resizeSendCount
        }

        workspace.camera = DeskCamera.focus(
            on: content.insetBy(dx: content.width * 0.05, dy: content.height * 0.05),
            in: workspace.bounds
        )
        workspace.flyCamera(to: DeskCamera.fitAll(content: content, in: workspace.bounds))
        workspace.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        XCTAssertLessThan(
            workspace.camera.scale,
            DeskCamera.maxScale,
            "these moves must stay short of identity, or the landing's reflow is what is measured"
        )
        XCTAssertTrue(workspace.canvasMode)
        XCTAssertFalse(workspace.resizeCoalescer.hasPending, "nothing was even scheduled")
        XCTAssertEqual(workspace.resizeCoalescer.flushCount, flushes, "no flush")
        for id in workspace.allPaneIDs {
            XCTAssertEqual(workspace.terminalSurface(for: id)?.resizeSendCount, sends[id], id)
        }
    }

    /// The camera looks cards up by group id and never walks the node tree, so
    /// a session node's id has to *be* its group id. If the tidy tree ever keys
    /// a card by anything else, every entry silently aims at nothing.
    func testEverySessionHasACardKeyedByItsGroupID() {
        let workspace = makeWorkspace(groups: 3, panesPerGroup: 1)
        workspace.canvasMode = true

        for group in workspace.groupIDs {
            XCTAssertNotNil(workspace.canvasRect(forGroup: group), "no card for \(group)")
        }
        XCTAssertNil(workspace.canvasRect(forGroup: "sess-grp-nope"))
    }
```

- [ ] **Step 15: Run the whole new suite**

Run:
```
xcodebuild test -project macos/OmniAgent.xcodeproj -scheme OmniAgent \
  -destination "platform=macOS,arch=$(uname -m)" CODE_SIGNING_ALLOWED=NO \
  -only-testing:OmniAgentTests/DeskCameraFlightTests
```
Expected: PASS — `Executed 13 tests, with 0 failures`.

- [ ] **Step 16: Run the full suite**

Run:
```
./macos/build.sh test
```
Expected: a green `Executed N tests, with 0 failures` line, N = the previous total + 13. Grep for that line before believing the summary — a launch can report a green total underneath a trailing `Failing tests:` list while xcodebuild still exits 65.

- [ ] **Step 17: Commit**

Only quiescent files: concurrent sessions share this worktree, so check mtimes and stage the three paths by name. Never `git stash` here.

```
git status --porcelain macos/OmniAgent/PaneWorkspaceView.swift macos/OmniAgentTests/DeskCameraFlightTests.swift macos/OmniAgent.xcodeproj/project.pbxproj
git add macos/OmniAgent/PaneWorkspaceView.swift macos/OmniAgentTests/DeskCameraFlightTests.swift macos/OmniAgent.xcodeproj/project.pbxproj
git commit -m "feat(macos): one camera flight is every way into and out of a session

Click, double-click, session shortcut and zooming past the entry scale all
resolve to flyCamera: animate sublayerTransform so a card's rect maps onto
the viewport, then land at exact identity. Raw CAAnimation with the zoom's
own duration and curve, a token-guarded asyncAfter completion so the landing
still happens with no window or under Reduce Motion, and removal by key.
focusPane no longer swaps activeGroup underneath the user on the canvas.

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
git push
```

---

### Task 8: Inverse-camera hit testing, node drag, and the canvas gestures

**Files:**
- Modify: `macos/OmniAgent/PaneWorkspaceView.swift` — a new `// MARK: - Canvas input` section placed immediately after the existing `// MARK: - Responder-chain commands` section and before `private func hasNeighbor(_:)`; plus targeted edits inside `place(_:at:from:)`, `validateMenuItem(_:)`, and `PaneFocusOverlayView.forwardedCommands`.
- Create: `macos/OmniAgentTests/DeskCanvasInputTests.swift`
- Modify: `macos/OmniAgent.xcodeproj/project.pbxproj` (four entries for the new test file)

**Interfaces:**

- Consumes (fixed shared API, from the `DeskCanvas` task):
  ```swift
  struct DeskNode: Equatable { enum Kind: Equatable { case root; case workspace(String); case session(String) }; let id: String; let kind: Kind; let children: [DeskNode] }
  struct DeskEdge: Equatable { let from: String; let to: String }
  struct DeskCanvasLayout: Equatable { let frames: [String: CGRect]; let edges: [DeskEdge]; let contentRect: CGRect }
  struct DeskCamera: Equatable {
      var scale: CGFloat
      var origin: CGPoint
      static let maxScale: CGFloat
      var transform: CATransform3D { get }
      func canvasPoint(from viewPoint: CGPoint) -> CGPoint
      static func fitAll(content: CGRect, in bounds: CGRect) -> DeskCamera
      static func focus(on rect: CGRect, in bounds: CGRect) -> DeskCamera
      func clamped(minScale: CGFloat, in bounds: CGRect) -> DeskCamera
      var isIdentity: Bool { get }
  }
  static func DeskCanvas.layout(root: DeskNode, cardSize: CGSize, pinned: [String: CGPoint]) -> DeskCanvasLayout
  ```
- Consumes (from Task 5 on `PaneWorkspaceView`; the names are fixed in Global Constraints):
  ```swift
  var canvasMode: Bool { get set }
  var camera: DeskCamera { get set }
  func flyCamera(to target: DeskCamera)
  func enterSession(_ group: String)
  func exitToCanvas()
  private(set) var canvasRoot: DeskNode?
  private(set) var canvasLayout: DeskCanvasLayout?
  private(set) var canvasPins: [String: CGPoint]
  ```
- Consumes (existing, verified in `main`): `override var isFlipped: Bool { true }` (PaneWorkspaceView.swift), `func updateLayout()`, `private func place(_ container: PaneContainerView, at frame: NSRect, from start: NSRect? = nil)`, `func validateMenuItem(_ menuItem: NSMenuItem) -> Bool`, `enum PaneDirection { case left, right, up, down }` (PaneGrid.swift), `weak var PaneFocusOverlayView.commandTarget: PaneWorkspaceView?`, `private(set) var TerminalSurfaceView.resizeSendCount: Int`, `let resizeCoalescer = PaneResizeCoalescer()`.
- Produces (all added **inside the class body** of `PaneWorkspaceView`; Swift extensions cannot declare stored properties, and `selectedNodeID`/the drag state are stored):
  ```swift
  static let canvasZoomStep: CGFloat
  static let canvasDragThreshold: CGFloat
  var selectedNodeID: String?
  var onCanvasPinsChanged: (([String: CGPoint]) -> Void)?
  var onCanvasSelectionChanged: ((String?) -> Void)?
  var minimumCanvasScale: CGFloat { get }
  func canvasNode(at viewPoint: CGPoint) -> String?
  func moveNode(_ id: String, to canvasPoint: CGPoint)
  func panCanvas(by delta: CGSize)
  func zoomCanvas(by factor: CGFloat, about viewPoint: CGPoint)
  func pinchCanvas(by factor: CGFloat, about viewPoint: CGPoint)
  func enterCanvasNode(_ id: String)
  func moveNodeSelection(_ direction: PaneDirection)
  @objc func zoomCanvasIn(_ sender: Any?)
  @objc func zoomCanvasOut(_ sender: Any?)
  override var acceptsFirstResponder: Bool { get }
  override func hitTest(_ point: NSPoint) -> NSView?
  override func mouseDown(with event: NSEvent)
  override func mouseDragged(with event: NSEvent)
  override func mouseUp(with event: NSEvent)
  override func magnify(with event: NSEvent)
  override func scrollWheel(with event: NSEvent)
  override func keyDown(with event: NSEvent)
  ```

---

- [ ] **Step 1: Write the failing test — the identity-scale invariant**

Create `macos/OmniAgentTests/DeskCanvasInputTests.swift`. The `render`/`saveRenderForInspection`/`makeWorkspace` helpers in `PaneWorkspaceViewTests.swift` are `private` to that class, so this suite carries its own.

```swift
import AppKit
import XCTest
@testable import OmniAgent

/// The canvas's input layer, and the one rule the whole spatial design rests
/// on: `NSView` coordinate conversion and `event.locationInWindow` are blind to
/// a `CALayer` transform, and roughly ten call sites in `PaneWorkspaceView`
/// depend on them — `PaneDividerView.mouseDragged`'s window-space delta,
/// `PaneHeaderView`'s 4pt drag threshold, `PaneHeaderButton.mouseUp`'s
/// `bounds.contains(convert(event.locationInWindow, from: nil))`,
/// `PaneHolePlaceholderView`'s `mouseMoved`/`mouseUp`/`dispatch(at:)`,
/// `PaneContainerView.editorTabDropZone`, and the `resetCursorRects` /
/// `updateTrackingAreas` pairs behind all of them. Every one of those is
/// correct at `sublayerTransform == identity` and wrong at any other scale, so
/// panes accept input at `scale == 1.0` and nowhere else. Below it the canvas
/// itself is the responder and the answer to every hit test.
final class DeskCanvasInputTests: XCTestCase {

    // MARK: - The identity boundary

    /// At identity the transform *is* identity, so nothing has changed for the
    /// panes: `hitTest` must defer to `super` and a pane must be able to answer.
    func testAtIdentityScaleHitTestingIsExactlyWhatItAlwaysWas() {
        let workspace = makeCanvasWorkspace(sessions: 2)
        workspace.camera = DeskCamera(scale: 1, origin: .zero)
        XCTAssertTrue(workspace.camera.isIdentity, "the fixture's premise")

        let hit = workspace.hitTest(CGPoint(x: 400, y: 300))
        XCTAssertNotNil(hit, "something is under the pointer")
        XCTAssertFalse(hit === workspace, "at identity a pane answers, not the canvas")
    }

    /// And below it, nothing inside ever sees a mouse event.
    func testBelowIdentityScaleTheCanvasTakesEveryHitInsideItsFrame() {
        let workspace = makeCanvasWorkspace(sessions: 2)
        workspace.camera = DeskCamera(scale: 0.3, origin: .zero)
        XCTAssertFalse(workspace.camera.isIdentity, "the fixture's premise")

        for point in [CGPoint(x: 1, y: 1), CGPoint(x: 600, y: 400), CGPoint(x: 1199, y: 799)] {
            XCTAssertTrue(workspace.hitTest(point) === workspace, "the canvas takes the hit at \(point)")
        }
        XCTAssertNil(workspace.hitTest(CGPoint(x: 1400, y: 400)), "and nothing outside its frame")
    }

    /// The node under the pointer comes from inverting the camera by hand,
    /// because AppKit cannot be asked: `convert(_:from:)` does not know the
    /// `sublayerTransform` exists.
    func testTheNodeUnderThePointerIsFoundByInvertingTheCamera() throws {
        let workspace = makeCanvasWorkspace(sessions: 3)
        let layout = try XCTUnwrap(workspace.canvasLayout, "canvas mode must produce a layout")
        let group = workspace.groupIDs[1]
        let node = try XCTUnwrap(nodeID(forGroup: group, in: workspace))
        let rect = try XCTUnwrap(layout.frames[node])
        workspace.camera = DeskCamera.fitAll(content: layout.contentRect, in: workspace.bounds)

        let centre = CGPoint(x: rect.midX, y: rect.midY)
        let viewPoint = CGPoint(
            x: centre.x * workspace.camera.scale + workspace.camera.origin.x,
            y: centre.y * workspace.camera.scale + workspace.camera.origin.y
        )
        // The inverse the implementation uses, checked against the forward map
        // this test just applied — so the pair stays honest whatever
        // `DeskCamera.transform` turns out to be composed of.
        XCTAssertEqual(workspace.camera.canvasPoint(from: viewPoint).x, centre.x, accuracy: 0.01)
        XCTAssertEqual(workspace.camera.canvasPoint(from: viewPoint).y, centre.y, accuracy: 0.01)
        XCTAssertEqual(workspace.canvasNode(at: viewPoint), node, "the middle session card")
    }

    // MARK: - Helpers

    /// One session per group, one pane each, sized like the real Desk. Mirrors
    /// `PaneWorkspaceViewTests.makeWorkspace(panes:)`, whose helpers are private
    /// to that class. The socket is one nobody is listening on: the Debug
    /// `test` path deliberately never builds the Rust daemon.
    private func makeCanvasWorkspace(sessions: Int) -> PaneWorkspaceView {
        let connection = SessionConnection(
            socketURL: URL(fileURLWithPath: "/tmp/omniagent-desk-canvas-test.sock")
        )
        let workspace = PaneWorkspaceView { descriptor in
            switch descriptor.kind {
            case .terminal:
                return TerminalSurfaceView(connection: connection, sessionID: descriptor.sessionID)
            case .browser:
                return BrowserPaneView(initialURL: descriptor.browserURL)
            case .editor:
                return EditorPaneView(
                    initialTabs: descriptor.editorTabs,
                    activeIndex: descriptor.editorActiveIndex
                )
            }
        }
        workspace.frame = CGRect(x: 0, y: 0, width: 1200, height: 800)
        for index in 1...sessions {
            XCTAssertTrue(workspace.addPane(PaneDescriptor(
                sessionID: "pane-\(index)",
                group: "sess-grp-\(index)",
                groupLabel: nil,
                title: ""
            )))
        }
        workspace.canvasMode = true
        return workspace
    }

    private func makeAttachedCanvasWorkspace(sessions: Int) -> (PaneWorkspaceView, NSWindow) {
        let workspace = makeCanvasWorkspace(sessions: sessions)
        let window = WorkspaceWindow(
            contentRect: CGRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        // `NSWindow` defaults to releasing itself when closed and every helper
        // here closes its window in a `defer` while ARC still holds this
        // reference — an over-release that SIGSEGVs in a *later* test, inside a
        // CA commit's autorelease drain. See
        // `PaneWorkspaceViewTests.makeAttachedWorkspace`.
        window.isReleasedWhenClosed = false
        window.contentView = workspace
        window.onFirstResponderChange = { [weak workspace] in workspace?.adoptFocus(from: $0) }
        window.makeKeyAndOrderFront(nil)
        return (workspace, window)
    }

    /// `DeskNode.id` and the group id are not required to be the same string,
    /// so a test that means "that session's node" has to walk the tree for it.
    private func nodeID(forGroup group: String, in workspace: PaneWorkspaceView) -> String? {
        func walk(_ node: DeskNode) -> String? {
            if case .session(let candidate) = node.kind, candidate == group { return node.id }
            for child in node.children {
                if let found = walk(child) { return found }
            }
            return nil
        }
        return workspace.canvasRoot.flatMap(walk)
    }

    private func firstWorkspaceNode(in node: DeskNode) -> DeskNode? {
        if case .workspace = node.kind { return node }
        for child in node.children {
            if let found = firstWorkspaceNode(in: child) { return found }
        }
        return nil
    }

    /// A canvas point pushed forward through the camera and then out of the
    /// flipped view into the unflipped window, which is what an `NSEvent`
    /// carries. `PaneDividerView.mouseDragged` already depends on that flip.
    private func viewToWindow(canvas: CGPoint, _ workspace: PaneWorkspaceView) -> CGPoint {
        let viewPoint = CGPoint(
            x: canvas.x * workspace.camera.scale + workspace.camera.origin.x,
            y: canvas.y * workspace.camera.scale + workspace.camera.origin.y
        )
        return workspace.convert(viewPoint, to: nil)
    }

    private func mouseEvent(
        _ type: NSEvent.EventType,
        at windowPoint: CGPoint,
        clicks: Int = 1,
        in window: NSWindow
    ) -> NSEvent {
        // swiftlint:disable:next force_unwrapping
        NSEvent.mouseEvent(
            with: type,
            location: NSPoint(x: windowPoint.x, y: windowPoint.y),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: clicks,
            pressure: 1
        )!
    }
}
```

- [ ] **Step 2: Register the new test file in the Xcode project**

The project is `objectVersion = 77` but has **no** `PBXFileSystemSynchronizedRootGroup`: dropping a `.swift` file into `macos/OmniAgentTests/` silently does not compile it and its tests silently do not run. Four hand-edits, two tab characters of indentation on every line. Ids below were generated with `uuidgen | tr -d '-' | cut -c1-24 | tr 'a-f' 'A-F'` and verified absent from the file. `project.pbxproj` is hot and shared (`scripts/bump-build-version.sh` rewrites `CURRENT_PROJECT_VERSION` in it) — **insert adjacent to existing lines, never rewrite a section, and never `git stash` in this worktree.**

Edit 1 — `PBXBuildFile` section, immediately after the `GitFileContentTests.swift in Sources` line:
```
		6EAB469FE27B4B4D889571B0 /* DeskCanvasInputTests.swift in Sources */ = {isa = PBXBuildFile; fileRef = 5544AA75593B4BA4BC9E6270 /* DeskCanvasInputTests.swift */; };
```

Edit 2 — `PBXFileReference` section, immediately after the `GitFileContentTests.swift` reference:
```
		5544AA75593B4BA4BC9E6270 /* DeskCanvasInputTests.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = DeskCanvasInputTests.swift; sourceTree = "<group>"; };
```

Edit 3 — inside `500000000000000000000003 /* OmniAgentTests */`'s `children = (` list, after `BE0A2CB26F101E0CCC68EFBA /* GitFileContentTests.swift */,`:
```
				5544AA75593B4BA4BC9E6270 /* DeskCanvasInputTests.swift */,
```

Edit 4 — inside `800000000000000000000002 /* Sources */`'s `files = (` list, after `1ECF599C46245E2BA8447FC1 /* GitFileContentTests.swift in Sources */,`:
```
				6EAB469FE27B4B4D889571B0 /* DeskCanvasInputTests.swift in Sources */,
```

- [ ] **Step 3: Run it and watch it fail**

Run:
```
xcodebuild test -project macos/OmniAgent.xcodeproj -scheme OmniAgent \
  -destination "platform=macOS,arch=$(uname -m)" CODE_SIGNING_ALLOWED=NO \
  -only-testing:OmniAgentTests/DeskCanvasInputTests
```
Expected: compile failure, `value of type 'PaneWorkspaceView' has no member 'canvasNode'`. The file compiling at all is what proves Step 2's registration; if the tests are reported as "0 tests executed" instead, the registration did not take.

- [ ] **Step 4: Implement `hitTest`, `canvasNode(at:)` and `minimumCanvasScale`**

Add a `// MARK: - Canvas input` section to `PaneWorkspaceView` **inside the class body**, immediately after the `// MARK: - Responder-chain commands` block's `validateMenuItem(_:)` and before `private func hasNeighbor(_ direction: PaneDirection) -> Bool`.

```swift
    // MARK: - Canvas input

    /// The node the arrows walk and `↩` enters. `nil` when the pointer last
    /// landed on empty canvas.
    var selectedNodeID: String? {
        didSet {
            guard oldValue != selectedNodeID else { return }
            onCanvasSelectionChanged?(selectedNodeID)
        }
    }

    /// Fired when a drag ends having pinned something — the persistence task's
    /// save hook for the `desk_canvas_native` row.
    var onCanvasPinsChanged: (([String: CGPoint]) -> Void)?

    /// Fired when the selected node changes, so the chips can draw their ring
    /// without this section knowing what a chip is.
    var onCanvasSelectionChanged: ((String?) -> Void)?

    /// One ⌘+ / ⌘- step. Multiplicative, so in and out are exact inverses.
    static let canvasZoomStep: CGFloat = 1.25

    /// How far a node has to travel before a click becomes a drag, in **canvas**
    /// units rather than window units. `PaneHeaderView.mouseDragged`'s 4pt
    /// threshold is the window-space equivalent, and it is only ever read at
    /// identity scale; at 0.2 a 3pt window twitch is 15pt of canvas and would
    /// throw a node across the tree.
    static let canvasDragThreshold: CGFloat = 3

    private var draggingNodeID: String?
    private var dragOriginInCanvas: CGPoint = .zero
    private var dragNodeOriginInCanvas: CGPoint = .zero
    private var didDragNode = false

    /// The zoom floor: the whole tree on screen. Derived from `fitAll` rather
    /// than kept as a constant, because the floor moves when a session opens, a
    /// node is dragged, or the window is resized.
    var minimumCanvasScale: CGFloat {
        guard
            let content = canvasLayout?.contentRect,
            content.width > 0, content.height > 0,
            bounds.width > 0, bounds.height > 0
        else { return DeskCamera.maxScale }
        return min(DeskCamera.maxScale, DeskCamera.fitAll(content: content, in: bounds).scale)
    }

    /// The correctness boundary the whole design rests on.
    ///
    /// `NSView` coordinate conversion and `event.locationInWindow` are blind to
    /// a `CALayer` transform, and this file has roughly ten call sites that
    /// depend on them: `PaneDividerView.mouseDragged`'s window-space delta and
    /// its `resetCursorRects`, `PaneHeaderView.mouseDragged`'s 4pt travel
    /// threshold, `PaneHeaderButton.mouseUp`'s
    /// `bounds.contains(convert(event.locationInWindow, from: nil))` and its
    /// `.activeInKeyWindow, .inVisibleRect` tracking areas,
    /// `PaneHolePlaceholderView.mouseMoved`/`mouseUp`/`dispatch(at:)`/
    /// `updateTrackingAreas`/`resetCursorRects`, `applyZoom`'s
    /// `convert(container.frame, to: host)`, `collapseZoom`'s
    /// `convert(cell, to: host)`, and `PaneContainerView.editorTabDropZone`.
    ///
    /// At `camera.isIdentity` the `sublayerTransform` *is* identity, so every
    /// one of those is already correct and this defers to `super` — the panes
    /// behave exactly as they do with no canvas at all. Below identity scale the
    /// canvas is the answer to every hit and no descendant ever sees a mouse
    /// event, which is what keeps those ten sites right. This is not a feature
    /// cut; it is the invariant.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard canvasMode, !camera.isIdentity else { return super.hitTest(point) }
        // `point` arrives in the SUPERVIEW's coordinates, so containment is
        // against `frame`, not `bounds`: this view is flipped and its superview
        // is not, and `bounds` is the flipped space on the other side of that.
        return frame.contains(point) ? self : nil
    }

    /// The node under a point given in this view's own (flipped) coordinates.
    ///
    /// Smallest area first, ties broken by id. Nodes are allowed to overlap —
    /// v1 has no collision avoidance, "it is the user's canvas" — so the answer
    /// has to be both deterministic and the one the eye picked: a chip dropped
    /// on a card is what you clicked, not the card behind it.
    func canvasNode(at viewPoint: CGPoint) -> String? {
        guard let layout = canvasLayout else { return nil }
        let canvasPoint = camera.canvasPoint(from: viewPoint)
        return layout.frames
            .filter { $0.value.contains(canvasPoint) }
            .min { first, second in
                let a = first.value.width * first.value.height
                let b = second.value.width * second.value.height
                return a == b ? first.key < second.key : a < b
            }?
            .key
    }
```

- [ ] **Step 5: Run the three tests**

Run:
```
xcodebuild test -project macos/OmniAgent.xcodeproj -scheme OmniAgent \
  -destination "platform=macOS,arch=$(uname -m)" CODE_SIGNING_ALLOWED=NO \
  -only-testing:OmniAgentTests/DeskCanvasInputTests
```
Expected: PASS, `Executed 3 tests, with 0 failures`.

- [ ] **Step 6: Commit**

```
git add macos/OmniAgentTests/DeskCanvasInputTests.swift macos/OmniAgent/PaneWorkspaceView.swift macos/OmniAgent.xcodeproj/project.pbxproj
git commit -m "$(cat <<'EOF'
feat(macos): the desk canvas hit-tests through its own inverse camera

`PaneWorkspaceView` had no `hitTest` override, so this is all new. At
`camera.isIdentity` it defers to `super` and nothing changes for the panes;
below it the canvas takes every hit and no descendant sees a mouse event. That
is what keeps the ten window-space call sites in this file correct — dividers,
header buttons, hole placeholders, the editor-tab drop zone, the two overlay
conversions — all of which are blind to a `CALayer` transform.

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>
Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
git push
```

- [ ] **Step 7: Write the failing test — pan**

Append to `DeskCanvasInputTests.swift`, above `// MARK: - Helpers`:

```swift
    // MARK: - Camera gestures

    /// A pan is a pure origin translation: the scale does not move.
    func testPanningMovesTheOriginByTheScrollDeltaAndNothingElse() {
        let workspace = makeCanvasWorkspace(sessions: 3)
        let before = workspace.camera

        workspace.panCanvas(by: CGSize(width: 40, height: -25))

        XCTAssertEqual(workspace.camera.scale, before.scale, accuracy: 0.0001, "a pan does not zoom")
        XCTAssertEqual(workspace.camera.origin.x, before.origin.x + 40, accuracy: 0.0001)
        XCTAssertEqual(workspace.camera.origin.y, before.origin.y - 25, accuracy: 0.0001)
    }
```

- [ ] **Step 8: Write the failing test — anchored zoom and its clamps**

Append immediately below it:

```swift
    /// The one thing people notice immediately if it is wrong: the canvas point
    /// under the pointer must not move while you pinch.
    func testZoomingAboutAPointLeavesThatCanvasPointUnderThePointer() {
        let workspace = makeCanvasWorkspace(sessions: 3)
        let anchor = CGPoint(x: 900, y: 220)
        let before = workspace.camera.canvasPoint(from: anchor)
        let scaleBefore = workspace.camera.scale

        workspace.zoomCanvas(by: PaneWorkspaceView.canvasZoomStep, about: anchor)

        let after = workspace.camera.canvasPoint(from: anchor)
        XCTAssertEqual(after.x, before.x, accuracy: 0.001, "the point under the pointer is fixed")
        XCTAssertEqual(after.y, before.y, accuracy: 0.001)
        XCTAssertGreaterThan(workspace.camera.scale, scaleBefore, "and it did zoom in")
    }

    /// `[fitAll, 1.0]`. Above 1.0 there is nothing to see and
    /// `metalRenderingScaleFactor()` clamps at `max(1, …)` anyway; below fitAll
    /// the whole tree is already on screen.
    func testZoomStopsAtOneAboveAndAtFitAllBelow() {
        let workspace = makeCanvasWorkspace(sessions: 3)
        let centre = CGPoint(x: workspace.bounds.midX, y: workspace.bounds.midY)

        for _ in 0..<40 { workspace.zoomCanvas(by: PaneWorkspaceView.canvasZoomStep, about: centre) }
        XCTAssertEqual(workspace.camera.scale, DeskCamera.maxScale, accuracy: 0.0001, "1.0 is the ceiling")

        for _ in 0..<40 { workspace.zoomCanvas(by: 1 / PaneWorkspaceView.canvasZoomStep, about: centre) }
        XCTAssertEqual(
            workspace.camera.scale,
            workspace.minimumCanvasScale,
            accuracy: 0.0001,
            "fitAll is the floor"
        )
    }

    /// "Keep zooming past a threshold" is the fourth way in (spec §5) and it has
    /// to resolve to the same one operation as a double-click. A pinch that
    /// reaches 1.0 over a session card enters that session, rather than leaving
    /// the camera at scale 1 with a fractional origin — a state `isIdentity`
    /// rejects, so no pane would accept input in it.
    ///
    /// It lives on `pinchCanvas` and not on `zoomCanvas` on purpose: ⌘+ is aimed
    /// at the viewport centre, which at fitAll is routinely over the middle
    /// card, and a keyboard zoom that teleported into a session would be a
    /// different command than the one that was pressed.
    func testAPinchThatReachesOneOverASessionCardEntersThatSession() throws {
        let workspace = makeCanvasWorkspace(sessions: 3)
        let layout = try XCTUnwrap(workspace.canvasLayout)
        let group = workspace.groupIDs[2]
        let node = try XCTUnwrap(nodeID(forGroup: group, in: workspace))
        let rect = try XCTUnwrap(layout.frames[node])
        workspace.camera = DeskCamera.fitAll(content: layout.contentRect, in: workspace.bounds)
        let anchor = CGPoint(
            x: rect.midX * workspace.camera.scale + workspace.camera.origin.x,
            y: rect.midY * workspace.camera.scale + workspace.camera.origin.y
        )

        for _ in 0..<40 { workspace.pinchCanvas(by: 1.3, about: anchor) }

        XCTAssertEqual(workspace.activeGroup, group, "the pinch landed in that session")
    }
```

- [ ] **Step 9: Run and watch it fail**

Run:
```
xcodebuild test -project macos/OmniAgent.xcodeproj -scheme OmniAgent \
  -destination "platform=macOS,arch=$(uname -m)" CODE_SIGNING_ALLOWED=NO \
  -only-testing:OmniAgentTests/DeskCanvasInputTests
```
Expected: compile failure, `value of type 'PaneWorkspaceView' has no member 'panCanvas'` / `'zoomCanvas'` / `'pinchCanvas'`.

- [ ] **Step 10: Implement `panCanvas` and `zoomCanvas`**

Append to the `// MARK: - Canvas input` section:

```swift
    /// Translates the camera. Event-free so the geometry can be checked without
    /// synthesizing an `NSScrollWheel`, the way `focusCardFrame(in:)` is static
    /// and pure "so the geometry can be checked without a window".
    func panCanvas(by delta: CGSize) {
        guard canvasMode else { return }
        camera = DeskCamera(
            scale: camera.scale,
            origin: CGPoint(x: camera.origin.x + delta.width, y: camera.origin.y + delta.height)
        )
    }

    /// Rescales about a fixed point in this view's coordinates — the pointer for
    /// a pinch or a ⌘-scroll, the viewport centre for ⌘+ / ⌘-.
    ///
    /// Written out rather than delegating to `DeskCamera.clamped(minScale:in:)`,
    /// which re-centres on the viewport by definition: a pinch that walks the
    /// canvas out from under your fingers is the first thing anyone notices.
    /// The forward map is the inverse of `canvasPoint(from:)` —
    /// `viewPoint = canvasPoint * scale + origin` — so holding the anchor still
    /// means `origin = viewPoint - anchor * newScale`.
    func zoomCanvas(by factor: CGFloat, about viewPoint: CGPoint) {
        guard canvasMode, factor > 0 else { return }
        let anchor = camera.canvasPoint(from: viewPoint)
        let scale = min(DeskCamera.maxScale, max(minimumCanvasScale, camera.scale * factor))
        camera = DeskCamera(
            scale: scale,
            origin: CGPoint(
                x: viewPoint.x - anchor.x * scale,
                y: viewPoint.y - anchor.y * scale
            )
        )
    }
```

- [ ] **Step 11: Implement `pinchCanvas` and the tree walk**

Append directly below:

```swift
    /// `zoomCanvas`, plus the resolution the spec's "one operation" demands: a
    /// gesture that runs the scale into the 1.0 ceiling over a session card
    /// finishes the job and enters that session, instead of parking at scale 1
    /// with a fractional origin — which `DeskCamera.isIdentity` rejects, so the
    /// panes would stay dead under a camera that looks like it arrived.
    func pinchCanvas(by factor: CGFloat, about viewPoint: CGPoint) {
        guard canvasMode else { return }
        zoomCanvas(by: factor, about: viewPoint)
        guard camera.scale >= DeskCamera.maxScale,
              let id = canvasNode(at: viewPoint),
              let root = canvasRoot,
              let node = deskNode(id, in: root),
              case .session(let group) = node.kind
        else { return }
        enterSession(group)
    }

    /// The tree is small — one account, a handful of workspaces, at most eight
    /// sessions — so a walk costs nothing and there is no index to keep in sync.
    private func deskNode(_ id: String, in node: DeskNode) -> DeskNode? {
        if node.id == id { return node }
        for child in node.children {
            if let found = deskNode(id, in: child) { return found }
        }
        return nil
    }
```

- [ ] **Step 12: Run the tests, then commit**

Run:
```
xcodebuild test -project macos/OmniAgent.xcodeproj -scheme OmniAgent \
  -destination "platform=macOS,arch=$(uname -m)" CODE_SIGNING_ALLOWED=NO \
  -only-testing:OmniAgentTests/DeskCanvasInputTests
```
Expected: PASS, `Executed 7 tests, with 0 failures`.

```
git add macos/OmniAgentTests/DeskCanvasInputTests.swift macos/OmniAgent/PaneWorkspaceView.swift
git commit -m "$(cat <<'EOF'
feat(macos): pan and anchored zoom for the desk camera

`panCanvas` / `zoomCanvas` / `pinchCanvas` are event-free so the geometry is
testable without synthesizing gestures, the way `focusCardFrame(in:)` is static
and pure so it can be checked without a window. Zoom holds the canvas point
under the pointer fixed and clamps to [fitAll, 1.0]; a pinch that runs into the
ceiling over a session card enters that session rather than parking at scale 1
with a fractional origin, which `isIdentity` rejects.

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>
Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
git push
```

- [ ] **Step 13: Write the failing test — a drag carries the subtree and pins it**

Append to `DeskCanvasInputTests.swift`:

```swift
    // MARK: - Node drag

    /// Dragging a node translates it *and its subtree*, and pins everything it
    /// moved. The subtree, not just its root: `DeskCanvas.layout` excludes a
    /// pinned node from packing but keeps packing everything else, so a pinned
    /// parent whose children were left unpinned would watch its children walk
    /// straight back to the slot the packer still holds for them.
    func testDraggingANodeCarriesItsSubtreeAndPinsEveryNodeItMoved() throws {
        let workspace = makeCanvasWorkspace(sessions: 2)
        let layout = try XCTUnwrap(workspace.canvasLayout)
        let root = try XCTUnwrap(workspace.canvasRoot)
        let parent = try XCTUnwrap(
            firstWorkspaceNode(in: root),
            "the tree must have a workspace node between the account and the sessions"
        )
        let before = try XCTUnwrap(layout.frames[parent.id])
        let child = try XCTUnwrap(parent.children.first?.id)
        let childBefore = try XCTUnwrap(layout.frames[child])

        workspace.moveNode(parent.id, to: CGPoint(x: before.origin.x + 400, y: before.origin.y + 150))

        let after = try XCTUnwrap(workspace.canvasLayout?.frames[parent.id])
        XCTAssertEqual(after.origin.x, before.origin.x + 400, accuracy: 0.01, "it lands where it was dropped")
        XCTAssertEqual(after.origin.y, before.origin.y + 150, accuracy: 0.01)

        let childAfter = try XCTUnwrap(workspace.canvasLayout?.frames[child])
        XCTAssertEqual(childAfter.origin.x, childBefore.origin.x + 400, accuracy: 0.01, "the subtree comes with it")
        XCTAssertEqual(childAfter.origin.y, childBefore.origin.y + 150, accuracy: 0.01)

        XCTAssertNotNil(workspace.canvasPins[parent.id], "the dragged node is pinned")
        XCTAssertNotNil(workspace.canvasPins[child], "and so is everything it carried")
    }

    /// The pin is an absolute canvas position, not an offset from an auto slot,
    /// so a relayout leaves it exactly where it was put.
    func testAPinnedNodeStaysPutAcrossARelayout() throws {
        let workspace = makeCanvasWorkspace(sessions: 3)
        let node = try XCTUnwrap(nodeID(forGroup: workspace.groupIDs[0], in: workspace))
        let target = CGPoint(x: 4000, y: 2500)

        workspace.moveNode(node, to: target)
        workspace.updateLayout()
        workspace.updateLayout()

        let placed = try XCTUnwrap(workspace.canvasLayout?.frames[node])
        XCTAssertEqual(placed.origin.x, target.x, accuracy: 0.01)
        XCTAssertEqual(placed.origin.y, target.y, accuracy: 0.01)
    }

    /// The pins have to reach the `desk_canvas_native` row, and the drag is the
    /// only thing that knows a drag happened.
    func testMovingANodeAnnouncesThePinsSoTheyCanBeSaved() throws {
        let workspace = makeCanvasWorkspace(sessions: 2)
        var announced: [[String: CGPoint]] = []
        workspace.onCanvasPinsChanged = { announced.append($0) }
        let node = try XCTUnwrap(nodeID(forGroup: workspace.groupIDs[1], in: workspace))

        workspace.moveNode(node, to: CGPoint(x: 900, y: 900))

        XCTAssertEqual(announced.count, 1, "one announcement per move")
        XCTAssertEqual(announced.last?[node]?.x, 900, "carrying the new pin")
    }
```

- [ ] **Step 14: Run and watch it fail**

Run:
```
xcodebuild test -project macos/OmniAgent.xcodeproj -scheme OmniAgent \
  -destination "platform=macOS,arch=$(uname -m)" CODE_SIGNING_ALLOWED=NO \
  -only-testing:OmniAgentTests/DeskCanvasInputTests
```
Expected: compile failure, `value of type 'PaneWorkspaceView' has no member 'moveNode'`.

- [ ] **Step 15: Implement `moveNode`**

Append to the `// MARK: - Canvas input` section:

```swift
    /// Moves `id` to an absolute canvas position, carrying its whole subtree by
    /// the same delta and pinning every node it moved.
    ///
    /// Absolute, not an offset from an auto slot: a pinned node is excluded from
    /// packing entirely and its unpinned siblings close the gap, so there is no
    /// slot left to be an offset from. The subtree is pinned as well as its
    /// root — a pinned parent with unpinned children would keep its position
    /// while the packer walked the children back under the empty slot.
    func moveNode(_ id: String, to canvasPoint: CGPoint) {
        guard
            canvasMode,
            let root = canvasRoot,
            let node = deskNode(id, in: root),
            let frame = canvasLayout?.frames[id]
        else { return }
        let delta = CGPoint(x: canvasPoint.x - frame.origin.x, y: canvasPoint.y - frame.origin.y)
        var pins = canvasPins
        for moved in deskSubtreeIDs(of: node) {
            guard let origin = canvasLayout?.frames[moved]?.origin else { continue }
            pins[moved] = CGPoint(x: origin.x + delta.x, y: origin.y + delta.y)
        }
        canvasPins = pins
        updateLayout()
        onCanvasPinsChanged?(pins)
    }

    private func deskSubtreeIDs(of node: DeskNode) -> [String] {
        [node.id] + node.children.flatMap(deskSubtreeIDs(of:))
    }
```

- [ ] **Step 16: Run the tests, then commit**

Run:
```
xcodebuild test -project macos/OmniAgent.xcodeproj -scheme OmniAgent \
  -destination "platform=macOS,arch=$(uname -m)" CODE_SIGNING_ALLOWED=NO \
  -only-testing:OmniAgentTests/DeskCanvasInputTests
```
Expected: PASS, `Executed 10 tests, with 0 failures`.

```
git add macos/OmniAgentTests/DeskCanvasInputTests.swift macos/OmniAgent/PaneWorkspaceView.swift
git commit -m "$(cat <<'EOF'
feat(macos): moving a desk node carries its subtree and pins it

The pin is an absolute canvas position, not an offset from an auto slot: a
pinned node is excluded from packing entirely and its unpinned siblings close
the gap, so there is no slot left to be an offset from. Every node in the moved
subtree is pinned, not just its root — the packer still holds slots for
unpinned children and would walk them straight back under the empty gap.

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>
Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
git push
```

- [ ] **Step 17: Write the failing test — the mouse path, threshold, and double-click**

Append to `DeskCanvasInputTests.swift`:

```swift
    /// A twitch is a click, not a drag — and the threshold is in canvas units,
    /// because at 0.2 a 3pt window twitch is 15pt of canvas.
    func testATwitchSelectsANodeWhileARealDragMovesIt() throws {
        let (workspace, window) = makeAttachedCanvasWorkspace(sessions: 2)
        defer { window.close() }
        let layout = try XCTUnwrap(workspace.canvasLayout)
        let node = try XCTUnwrap(nodeID(forGroup: workspace.groupIDs[0], in: workspace))
        let rect = try XCTUnwrap(layout.frames[node])
        workspace.camera = DeskCamera.fitAll(content: layout.contentRect, in: workspace.bounds)
        let start = viewToWindow(canvas: CGPoint(x: rect.midX, y: rect.midY), workspace)

        workspace.mouseDown(with: mouseEvent(.leftMouseDown, at: start, in: window))
        workspace.mouseDragged(with: mouseEvent(
            .leftMouseDragged,
            at: CGPoint(x: start.x + 0.2, y: start.y),
            in: window
        ))
        workspace.mouseUp(with: mouseEvent(.leftMouseUp, at: start, in: window))

        XCTAssertEqual(workspace.selectedNodeID, node, "a twitch is a click, and a click selects")
        XCTAssertTrue(workspace.canvasPins.isEmpty, "and pins nothing")

        let far = CGPoint(x: start.x + 300, y: start.y)
        workspace.mouseDown(with: mouseEvent(.leftMouseDown, at: start, in: window))
        workspace.mouseDragged(with: mouseEvent(.leftMouseDragged, at: far, in: window))
        workspace.mouseUp(with: mouseEvent(.leftMouseUp, at: far, in: window))

        XCTAssertNotNil(workspace.canvasPins[node], "300pt of window travel is a drag")
    }

    /// Double-click is one of the four ways in, and they all resolve to the same
    /// operation: animate the camera so that rect maps onto the viewport.
    func testDoubleClickingASessionCardEntersThatSession() throws {
        let (workspace, window) = makeAttachedCanvasWorkspace(sessions: 3)
        defer { window.close() }
        let layout = try XCTUnwrap(workspace.canvasLayout)
        let group = workspace.groupIDs[1]
        let node = try XCTUnwrap(nodeID(forGroup: group, in: workspace))
        let rect = try XCTUnwrap(layout.frames[node])
        workspace.camera = DeskCamera.fitAll(content: layout.contentRect, in: workspace.bounds)
        let point = viewToWindow(canvas: CGPoint(x: rect.midX, y: rect.midY), workspace)

        workspace.mouseDown(with: mouseEvent(.leftMouseDown, at: point, clicks: 2, in: window))
        workspace.mouseUp(with: mouseEvent(.leftMouseUp, at: point, clicks: 2, in: window))

        XCTAssertEqual(workspace.activeGroup, group)
        XCTAssertTrue(workspace.canvasPins.isEmpty, "entering is not a drag")
    }
```

- [ ] **Step 18: Run and watch it fail**

Run:
```
xcodebuild test -project macos/OmniAgent.xcodeproj -scheme OmniAgent \
  -destination "platform=macOS,arch=$(uname -m)" CODE_SIGNING_ALLOWED=NO \
  -only-testing:OmniAgentTests/DeskCanvasInputTests
```
Expected: both new tests fail — `XCTAssertEqual failed: ("nil") is not equal to (…)`, because `NSView.mouseDown` does nothing by default.

- [ ] **Step 19: Implement the mouse handlers and `enterCanvasNode`**

Append to the `// MARK: - Canvas input` section:

```swift
    override func mouseDown(with event: NSEvent) {
        guard canvasMode, !camera.isIdentity else { return super.mouseDown(with: event) }
        // Below identity the canvas holds the keyboard: arrows move the node
        // selection, ↩ enters, and nothing typed can reach a terminal nobody
        // can read.
        window?.makeFirstResponder(self)
        let viewPoint = convert(event.locationInWindow, from: nil)
        guard let id = canvasNode(at: viewPoint), let frame = canvasLayout?.frames[id] else {
            selectedNodeID = nil
            return
        }
        selectedNodeID = id
        if event.clickCount == 2 {
            enterCanvasNode(id)
            return
        }
        draggingNodeID = id
        didDragNode = false
        dragOriginInCanvas = camera.canvasPoint(from: viewPoint)
        dragNodeOriginInCanvas = frame.origin
    }

    override func mouseDragged(with event: NSEvent) {
        guard canvasMode, !camera.isIdentity, let id = draggingNodeID else {
            return super.mouseDragged(with: event)
        }
        let canvasPoint = camera.canvasPoint(from: convert(event.locationInWindow, from: nil))
        let delta = CGPoint(
            x: canvasPoint.x - dragOriginInCanvas.x,
            y: canvasPoint.y - dragOriginInCanvas.y
        )
        if !didDragNode, hypot(delta.x, delta.y) < Self.canvasDragThreshold { return }
        didDragNode = true
        moveNode(id, to: CGPoint(
            x: dragNodeOriginInCanvas.x + delta.x,
            y: dragNodeOriginInCanvas.y + delta.y
        ))
    }

    override func mouseUp(with event: NSEvent) {
        guard canvasMode, !camera.isIdentity else { return super.mouseUp(with: event) }
        draggingNodeID = nil
        didDragNode = false
    }

    /// One operation for every way in — a double-click, `↩` on a selection, a
    /// pinch that reached the ceiling, a session shortcut: *animate the camera
    /// so that rect maps onto the viewport*. A session node lands in the
    /// session; a chip node frames its subtree, because there is no session to
    /// be in.
    func enterCanvasNode(_ id: String) {
        guard canvasMode, let root = canvasRoot, let node = deskNode(id, in: root) else { return }
        switch node.kind {
        case .session(let group):
            enterSession(group)
        case .root, .workspace:
            guard let rect = canvasSubtreeRect(of: node) else { return }
            flyCamera(to: DeskCamera.focus(on: rect, in: bounds)
                .clamped(minScale: minimumCanvasScale, in: bounds))
        }
    }

    private func canvasSubtreeRect(of node: DeskNode) -> CGRect? {
        guard let layout = canvasLayout else { return nil }
        var rect = layout.frames[node.id]
        for child in node.children {
            guard let childRect = canvasSubtreeRect(of: child) else { continue }
            rect = rect.map { $0.union(childRect) } ?? childRect
        }
        return rect
    }
```

- [ ] **Step 20: Run the tests, then commit**

Run:
```
xcodebuild test -project macos/OmniAgent.xcodeproj -scheme OmniAgent \
  -destination "platform=macOS,arch=$(uname -m)" CODE_SIGNING_ALLOWED=NO \
  -only-testing:OmniAgentTests/DeskCanvasInputTests
```
Expected: PASS, `Executed 12 tests, with 0 failures`.

```
git add macos/OmniAgentTests/DeskCanvasInputTests.swift macos/OmniAgent/PaneWorkspaceView.swift
git commit -m "$(cat <<'EOF'
feat(macos): the desk canvas's mouse path — select, drag, double-click to enter

The drag threshold is in canvas units. At 0.2 a 3pt window twitch is 15pt of
canvas, which would throw a node across the tree; `PaneHeaderView`'s 4pt
threshold is the window-space equivalent and is only ever read at identity
scale. Double-click resolves to `enterCanvasNode`, which is the same one
operation as ↩, a pinch into the ceiling, and a session shortcut.

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>
Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
git push
```

- [ ] **Step 21: Write the failing test — a node drag must not churn the PTYs**

Append to `DeskCanvasInputTests.swift`:

```swift
    // MARK: - Cost

    /// A node drag translates a whole session card sixty times a second and
    /// changes no pane's *size*. `place` used to schedule a PTY resize on any
    /// frame change, which was right when every frame change was a grid reflow;
    /// `flushResize` does not dedupe — it sends whatever is pending — so at
    /// eight sessions that was 96 `resize` frames per display refresh for a
    /// geometry the daemon already has.
    func testTranslatingANodeSendsNoPtyResizeBecauseNoPaneChangedSize() throws {
        let workspace = makeCanvasWorkspace(sessions: 3)
        let node = try XCTUnwrap(nodeID(forGroup: workspace.groupIDs[0], in: workspace))
        workspace.resizeCoalescer.flush()
        let before = workspace.allPaneIDs.compactMap { workspace.terminalSurface(for: $0)?.resizeSendCount }
        XCTAssertEqual(before.count, 3, "three terminals in the fixture")

        for step in 1...20 {
            workspace.moveNode(node, to: CGPoint(x: 500 + CGFloat(step) * 7, y: 500))
        }
        workspace.resizeCoalescer.flush()

        let after = workspace.allPaneIDs.compactMap { workspace.terminalSurface(for: $0)?.resizeSendCount }
        XCTAssertEqual(after, before, "twenty translation steps, not one resize")
    }
```

- [ ] **Step 22: Run and watch it fail**

Run:
```
xcodebuild test -project macos/OmniAgent.xcodeproj -scheme OmniAgent \
  -destination "platform=macOS,arch=$(uname -m)" CODE_SIGNING_ALLOWED=NO \
  -only-testing:OmniAgentTests/DeskCanvasInputTests/testTranslatingANodeSendsNoPtyResizeBecauseNoPaneChangedSize
```
Expected: `XCTAssertEqual failed: ("[1, 0, 0]") is not equal to ("[0, 0, 0]")` — the moved session's pane sent a resize it did not need.

- [ ] **Step 23: Make `place` schedule on size, not on frame**

In `place(_:at:from:)`, capture the size comparison before anything reassigns `container.frame`, and gate the last statement on it. Two lines change; the body in between is untouched.

```swift
    private func place(_ container: PaneContainerView, at frame: NSRect, from start: NSRect? = nil) {
        guard container.frame != frame || start != nil else { return }
        // Whether the PTY's geometry actually changed — captured before anything
        // below reassigns `container.frame`. This used to schedule on any frame
        // change, which was right when every frame change was a grid reflow; a
        // canvas node drag translates a whole card sixty times a second and
        // changes no pane's size, and `flushResize` does not dedupe. `start !=
        // nil` counts as a resize regardless: that is the reparenting case,
        // where the backing scale can change without the point size doing so.
        let resized = container.frame.size != frame.size || start != nil
```

Two separately-anchored edits inside `place(_:at:from:)`, not a rewrite of the
method — everything between them (the `from` derivation, `container.frame =
frame`, the `zoomTransition > 0` layer animation) is untouched.

**Edit 1** — insert the `resized` line immediately after the existing guard.
`old_string`:
```swift
        guard container.frame != frame || start != nil else { return }
```
`new_string`:
```swift
        guard container.frame != frame || start != nil else { return }
        let resized = container.frame.size != frame.size || start != nil
```

**Edit 2** — make the scheduling conditional. `old_string`:
```swift
        container.surface.scheduleResize()
```
`new_string`:
```swift
        if resized { container.surface.scheduleResize() }
```

That second `old_string` occurs once in `place(_:at:from:)`; confirm with
`grep -n "container.surface.scheduleResize()" macos/OmniAgent/PaneWorkspaceView.swift`
before editing, and if it now occurs more than once, include the preceding line
in the match.

- [ ] **Step 24: Run the whole suite — this one touches a hot path**

Run:
```
./macos/build.sh test
```
Expected: `0 failures`, with the executed count higher than the run recorded at the start of this task. In particular the existing `resizeSendCount == 1` assertions in `PaneWorkspaceViewTests` ("20 drag steps, one send") must stay green — a divider drag changes sizes, so it still resizes. Per the crash-diagnosis memory: *"A launch can report a green total underneath a trailing `Failing tests:` list. xcodebuild still exits 65. Grep for a green `Executed N tests` before believing the summary."*

- [ ] **Step 25: Commit**

```
git add macos/OmniAgentTests/DeskCanvasInputTests.swift macos/OmniAgent/PaneWorkspaceView.swift
git commit -m "$(cat <<'EOF'
perf(macos): a pane that only moved does not re-resize its PTY

`place` scheduled a resize on any frame change, which was right when every
frame change was a grid reflow. A canvas node drag translates a whole session
card sixty times a second and changes no pane's size, and `flushResize` sends
whatever is pending rather than deduping — at eight sessions that is 96 resize
frames per display refresh for a geometry the daemon already has. Now gated on
the size, with the reparenting case (`start != nil`) still counting as one,
since a move between superviews can change the backing scale.

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>
Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
git push
```

- [ ] **Step 26: Write the failing test — the canvas holds the keyboard**

Append to `DeskCanvasInputTests.swift`:

```swift
    // MARK: - The keyboard

    /// Below identity the canvas is first responder and the terminals are not.
    /// This is the other half of the hit-test invariant: typing must not reach a
    /// terminal you cannot read, and no `hitTest` stops a key event on its own.
    func testBelowIdentityScaleTheCanvasHoldsTheKeyboardAndNoTerminalDoes() {
        let (workspace, window) = makeAttachedCanvasWorkspace(sessions: 2)
        defer { window.close() }
        workspace.camera = DeskCamera(scale: 0.3, origin: .zero)

        XCTAssertTrue(workspace.acceptsFirstResponder, "the canvas is willing to take it")
        workspace.mouseDown(with: mouseEvent(.leftMouseDown, at: CGPoint(x: 600, y: 400), in: window))
        workspace.mouseUp(with: mouseEvent(.leftMouseUp, at: CGPoint(x: 600, y: 400), in: window))

        XCTAssertTrue(window.firstResponder === workspace, "and it has it, not a terminal")
    }

    /// And inside a session it must go back to never accepting it, or a click on
    /// the gap between panes would take the keyboard off a terminal.
    func testAtIdentityScaleTheCanvasRefusesFirstResponderTheWayItAlwaysHas() {
        let workspace = makeCanvasWorkspace(sessions: 2)
        workspace.camera = DeskCamera(scale: 1, origin: .zero)
        XCTAssertFalse(workspace.acceptsFirstResponder)

        workspace.canvasMode = false
        XCTAssertFalse(workspace.acceptsFirstResponder, "and with no canvas at all")
    }
```

- [ ] **Step 27: Write the failing test — arrows and ↩**

Append directly below:

```swift
    /// Arrows walk the selection geometrically. Flipped space: `isFlipped` is
    /// true, y grows downward, so `.down` is the *larger* y —
    /// `PaneDividerView.mouseDragged` already depends on the same convention.
    func testArrowKeysWalkTheSelectionDownTheTreeAndReturnEntersASession() throws {
        let workspace = makeCanvasWorkspace(sessions: 3)
        let root = try XCTUnwrap(workspace.canvasRoot)
        let parent = try XCTUnwrap(firstWorkspaceNode(in: root))
        let sessions = Set(parent.children.map(\.id))
        workspace.selectedNodeID = parent.id

        workspace.moveNodeSelection(.down)
        let selected = try XCTUnwrap(workspace.selectedNodeID)
        XCTAssertTrue(sessions.contains(selected), "down from the workspace node lands on a session")

        let group = try XCTUnwrap(parent.children.first { $0.id == selected }.flatMap { node -> String? in
            guard case .session(let group) = node.kind else { return nil }
            return group
        })
        workspace.enterCanvasNode(selected)
        XCTAssertEqual(workspace.activeGroup, group, "and ↩ enters it")
    }

    /// With nothing selected the arrows have to start somewhere, and the
    /// viewport centre is the only defensible answer — it is what you are
    /// looking at.
    func testTheFirstArrowKeyWithNothingSelectedPicksTheNodeNearestTheViewportCentre() throws {
        let workspace = makeCanvasWorkspace(sessions: 3)
        let layout = try XCTUnwrap(workspace.canvasLayout)
        workspace.camera = DeskCamera.fitAll(content: layout.contentRect, in: workspace.bounds)
        workspace.selectedNodeID = nil

        workspace.moveNodeSelection(.down)

        let centre = workspace.camera.canvasPoint(
            from: CGPoint(x: workspace.bounds.midX, y: workspace.bounds.midY)
        )
        let expected = layout.frames.min { first, second in
            let a = hypot(first.value.midX - centre.x, first.value.midY - centre.y)
            let b = hypot(second.value.midX - centre.x, second.value.midY - centre.y)
            return a == b ? first.key < second.key : a < b
        }?.key
        XCTAssertEqual(workspace.selectedNodeID, expected)
    }
```

- [ ] **Step 28: Run and watch it fail**

Run:
```
xcodebuild test -project macos/OmniAgent.xcodeproj -scheme OmniAgent \
  -destination "platform=macOS,arch=$(uname -m)" CODE_SIGNING_ALLOWED=NO \
  -only-testing:OmniAgentTests/DeskCanvasInputTests
```
Expected: compile failure, `value of type 'PaneWorkspaceView' has no member 'moveNodeSelection'`.

- [ ] **Step 29: Implement `acceptsFirstResponder`, `keyDown`, and the selection walk**

Append to the `// MARK: - Canvas input` section:

```swift
    /// Only below identity, and only in canvas mode. `PaneWorkspaceView` has
    /// never accepted first responder — inside a session it must keep not
    /// accepting it, or a click on the gap between panes would take the keyboard
    /// off a terminal.
    override var acceptsFirstResponder: Bool { canvasMode && !camera.isIdentity }

    override func keyDown(with event: NSEvent) {
        guard canvasMode, !camera.isIdentity else { return super.keyDown(with: event) }
        switch event.keyCode {
        case 123: moveNodeSelection(.left)
        case 124: moveNodeSelection(.right)
        case 125: moveNodeSelection(.down)
        case 126: moveNodeSelection(.up)
        case 36, 76: // ↩ and the numeric keypad's
            if let selectedNodeID { enterCanvasNode(selectedNodeID) }
        case 53: // esc — the same one operation, aimed at fitAll
            selectedNodeID = nil
            exitToCanvas()
        default:
            // Deliberately dropped rather than passed on: below identity the
            // panes are unreadable, and a keystroke that reached one would be
            // typed into a terminal nobody can see.
            NSSound.beep()
        }
    }

    /// Walks the selection to the nearest node in one direction.
    ///
    /// Flipped space — `isFlipped` is `true`, y grows downward — so `.up` is a
    /// *smaller* y. `PaneDividerView.mouseDragged` already depends on the same
    /// convention. Ties break on the node id so the walk is deterministic.
    func moveNodeSelection(_ direction: PaneDirection) {
        guard canvasMode, let layout = canvasLayout, !layout.frames.isEmpty else { return }
        guard let current = selectedNodeID, let from = layout.frames[current] else {
            selectedNodeID = nodeNearest(
                camera.canvasPoint(from: CGPoint(x: bounds.midX, y: bounds.midY))
            )
            return
        }
        let origin = CGPoint(x: from.midX, y: from.midY)
        let candidates = layout.frames.filter { id, rect in
            guard id != current else { return false }
            let dx = rect.midX - origin.x
            let dy = rect.midY - origin.y
            switch direction {
            case .left: return dx < -0.5
            case .right: return dx > 0.5
            case .up: return dy < -0.5
            case .down: return dy > 0.5
            }
        }
        guard let best = candidates.min(by: { first, second in
            let a = hypot(first.value.midX - origin.x, first.value.midY - origin.y)
            let b = hypot(second.value.midX - origin.x, second.value.midY - origin.y)
            return a == b ? first.key < second.key : a < b
        }) else { return }
        selectedNodeID = best.key
    }

    private func nodeNearest(_ point: CGPoint) -> String? {
        canvasLayout?.frames.min { first, second in
            let a = hypot(first.value.midX - point.x, first.value.midY - point.y)
            let b = hypot(second.value.midX - point.x, second.value.midY - point.y)
            return a == b ? first.key < second.key : a < b
        }?.key
    }
```

- [ ] **Step 30: Run the tests, then commit**

Run:
```
xcodebuild test -project macos/OmniAgent.xcodeproj -scheme OmniAgent \
  -destination "platform=macOS,arch=$(uname -m)" CODE_SIGNING_ALLOWED=NO \
  -only-testing:OmniAgentTests/DeskCanvasInputTests
```
Expected: PASS, `Executed 17 tests, with 0 failures`.

```
git add macos/OmniAgentTests/DeskCanvasInputTests.swift macos/OmniAgent/PaneWorkspaceView.swift
git commit -m "$(cat <<'EOF'
feat(macos): the desk canvas takes the keyboard below identity scale

Arrows walk the node selection geometrically (flipped space: down is the larger
y, the convention `PaneDividerView.mouseDragged` already depends on), ↩ enters,
esc is the same one operation aimed at fitAll. Anything else beeps rather than
passing on — below identity the panes are unreadable and a keystroke that
reached one would be typed into a terminal nobody can see.

`acceptsFirstResponder` is gated on canvas mode AND non-identity: inside a
session this view must keep never accepting it, or a click on the gap between
panes would take the keyboard off a terminal.

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>
Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
git push
```

- [ ] **Step 31: Write the failing test — the closed forwarding set**

Append to `DeskCanvasInputTests.swift`:

```swift
    // MARK: - Menu commands

    /// `PaneFocusOverlayView.forwardedCommands` is a deliberately CLOSED set,
    /// and its comment says why: "Forwarding whatever the workspace merely
    /// *responds to* would also forward the selectors it inherits from `NSView`
    /// — `print:` is the classic — so a Print item added later would resolve to
    /// the pane grid while a card is up and to the window the rest of the time,
    /// which is the kind of difference that gets diagnosed slowly." The three
    /// canvas commands therefore go in by hand, and `print:` stays out.
    func testTheThreeCanvasCommandsAreForwardedAndPrintStillIsNot() {
        let workspace = makeCanvasWorkspace(sessions: 2)
        let host = PaneFocusOverlayView()
        host.commandTarget = workspace

        for action in [
            #selector(PaneWorkspaceView.zoomCanvasIn(_:)),
            #selector(PaneWorkspaceView.zoomCanvasOut(_:)),
        ] {
            XCTAssertTrue(
                host.supplementalTarget(forAction: action, sender: nil) as AnyObject? === workspace,
                "\(action) has to reach the workspace while a card is up"
            )
        }

        let printAction = Selector(("print:"))
        XCTAssertTrue(workspace.responds(to: printAction), "the premise of the assertion below")
        XCTAssertNil(
            host.supplementalTarget(forAction: printAction, sender: nil),
            "a selector the workspace merely inherits is not a canvas command"
        )
    }
```

- [ ] **Step 32: Write the failing test — validation and the stepped zoom**

Append directly below:

```swift
    /// The items grey out at the clamps rather than doing nothing when pressed.
    func testTheZoomItemsGreyOutAtTheClampsAndOnlyExistOnTheCanvas() {
        let workspace = makeCanvasWorkspace(sessions: 3)
        let zoomIn = NSMenuItem(title: "", action: #selector(PaneWorkspaceView.zoomCanvasIn(_:)), keyEquivalent: "")
        let zoomOut = NSMenuItem(title: "", action: #selector(PaneWorkspaceView.zoomCanvasOut(_:)), keyEquivalent: "")

        workspace.camera = DeskCamera(scale: 1, origin: .zero)
        XCTAssertFalse(workspace.validateMenuItem(zoomIn), "1.0 is the ceiling")
        XCTAssertTrue(workspace.validateMenuItem(zoomOut))

        workspace.zoomCanvas(by: 0.0001, about: CGPoint(x: workspace.bounds.midX, y: workspace.bounds.midY))
        XCTAssertTrue(workspace.validateMenuItem(zoomIn))
        XCTAssertFalse(workspace.validateMenuItem(zoomOut), "fitAll is the floor")

        workspace.canvasMode = false
        for item in [zoomIn, zoomOut, fit] {
            XCTAssertFalse(workspace.validateMenuItem(item), "no canvas, no canvas commands")
        }
    }

    /// ⌘+ / ⌘- keep the viewport centre, not the pointer: there is no pointer.
    func testTheSteppedZoomKeepsTheViewportCentre() {
        let workspace = makeCanvasWorkspace(sessions: 3)
        let centre = CGPoint(x: workspace.bounds.midX, y: workspace.bounds.midY)
        let before = workspace.camera.canvasPoint(from: centre)

        workspace.zoomCanvasIn(nil)

        let after = workspace.camera.canvasPoint(from: centre)
        XCTAssertEqual(after.x, before.x, accuracy: 0.001)
        XCTAssertEqual(after.y, before.y, accuracy: 0.001)
    }

    /// The existing nine still resolve, and the pane-command validation is
    /// untouched by the three cases added beside it.
    func testTheNineExistingPaneCommandsStillForwardAndValidate() {
        let workspace = makeCanvasWorkspace(sessions: 2)
        let host = PaneFocusOverlayView()
        host.commandTarget = workspace

        XCTAssertTrue(
            host.supplementalTarget(
                forAction: #selector(PaneWorkspaceView.selectPane(_:)),
                sender: nil
            ) as AnyObject? === workspace
        )
        let item = NSMenuItem(title: "", action: #selector(PaneWorkspaceView.selectPane(_:)), keyEquivalent: "")
        item.tag = 1
        XCTAssertTrue(workspace.validateMenuItem(item), "⌘1 still validates against paneIDs")
    }
```

- [ ] **Step 33: Run and watch it fail**

Run:
```
xcodebuild test -project macos/OmniAgent.xcodeproj -scheme OmniAgent \
  -destination "platform=macOS,arch=$(uname -m)" CODE_SIGNING_ALLOWED=NO \
  -only-testing:OmniAgentTests/DeskCanvasInputTests
```
Expected: compile failure, `type 'PaneWorkspaceView' has no member 'zoomCanvasIn'`.

- [ ] **Step 34: Implement the three commands**

Append to the `// MARK: - Canvas input` section:

```swift
    /// ⌘= and ⌘-. Responder-chain commands rather than more `keyDown` cases,
    /// so the View menu can validate and show them the way ⌘1…⌘9 already do
    /// through `selectPane(_:)`.
    @objc func zoomCanvasIn(_ sender: Any?) {
        zoomCanvas(by: Self.canvasZoomStep, about: CGPoint(x: bounds.midX, y: bounds.midY))
    }

    @objc func zoomCanvasOut(_ sender: Any?) {
        zoomCanvas(by: 1 / Self.canvasZoomStep, about: CGPoint(x: bounds.midX, y: bounds.midY))
    }

    // ⌘0 is deliberately not a command on this view. Task 10b's Desk menu binds
    // it to the controller's `zoomDeskToFit:`, which calls `exitToCanvas()` —
    // one owner for one shortcut. A `fitCanvas(_:)` here would be a second
    // selector for the same operation, reachable by nothing.

```

- [ ] **Step 35: Extend `validateMenuItem` and the closed forwarding set**

(a) In `validateMenuItem(_:)`, add two cases immediately before `default:`:

```swift
        case #selector(zoomCanvasIn(_:)):
            return canvasMode && camera.scale < DeskCamera.maxScale
        case #selector(zoomCanvasOut(_:)):
            return canvasMode && camera.scale > minimumCanvasScale
```

(b) In `PaneFocusOverlayView`, extend `forwardedCommands`. The comment's reason stays verbatim — *"Forwarding whatever the workspace merely responds to would also forward the selectors it inherits from `NSView` — `print:` is the classic"* — only the leading count changes:

```swift
    /// The nine pane commands and the three canvas ones, and nothing else.
    /// Forwarding whatever the workspace merely *responds to* would also forward
    /// the selectors it inherits from `NSView` — `print:` is the classic — so a
    /// Print item added later would resolve to the pane grid while a card is up
    /// and to the window the rest of the time, which is the kind of difference
    /// that gets diagnosed slowly. The set is closed, greppable, and cannot
    /// drift with the class.
    private static let forwardedCommands: Set<Selector> = [
        #selector(PaneWorkspaceView.focusPaneLeft(_:)),
        #selector(PaneWorkspaceView.focusPaneRight(_:)),
        #selector(PaneWorkspaceView.focusPaneUp(_:)),
        #selector(PaneWorkspaceView.focusPaneDown(_:)),
        #selector(PaneWorkspaceView.swapPaneLeft(_:)),
        #selector(PaneWorkspaceView.swapPaneRight(_:)),
        #selector(PaneWorkspaceView.swapPaneUp(_:)),
        #selector(PaneWorkspaceView.swapPaneDown(_:)),
        #selector(PaneWorkspaceView.selectPane(_:)),
        #selector(PaneWorkspaceView.zoomCanvasIn(_:)),
        #selector(PaneWorkspaceView.zoomCanvasOut(_:)),
    ]
```

- [ ] **Step 36: Run the tests**

Run:
```
xcodebuild test -project macos/OmniAgent.xcodeproj -scheme OmniAgent \
  -destination "platform=macOS,arch=$(uname -m)" CODE_SIGNING_ALLOWED=NO \
  -only-testing:OmniAgentTests/DeskCanvasInputTests
```
Expected: PASS, `Executed 21 tests, with 0 failures`.

- [ ] **Step 37: Wire the two gesture events**

Append to the `// MARK: - Canvas input` section. These are three-line adapters over the tested methods; the maths is already covered.

```swift
    /// Pinch. `magnification` is a per-event delta fraction, so it multiplies.
    ///
    /// `magnify:` is a responder-chain message, so at identity scale — where
    /// `hitTest` hands the event to a pane — an unhandled pinch still bubbles up
    /// to here, which is how pinching out of a session works.
    override func magnify(with event: NSEvent) {
        guard canvasMode else { return super.magnify(with: event) }
        if camera.isIdentity {
            // Pinching out of a session is one of the three ways out (with ⌘0
            // and esc) and is the same operation. Pinching *in* does nothing:
            // 1.0 is the ceiling, and `metalRenderingScaleFactor()` clamps at
            // `max(1, …)`, so a terminal cannot rasterize sharper than 1× in any
            // case.
            if event.magnification < -0.02 { exitToCanvas() }
            return
        }
        pinchCanvas(by: 1 + event.magnification, about: convert(event.locationInWindow, from: nil))
    }

    override func scrollWheel(with event: NSEvent) {
        guard canvasMode, !camera.isIdentity else { return super.scrollWheel(with: event) }
        if event.modifierFlags.contains(.command) {
            pinchCanvas(
                by: 1 + event.scrollingDeltaY / 200,
                about: convert(event.locationInWindow, from: nil)
            )
            return
        }
        // `scrollingDeltaX/Y`, not `deltaX/Y`: the precise-device values are in
        // points and already carry the natural-scroll direction, while `deltaY`
        // is in wheel "lines" and a trackpad rounds small moves to zero. In this
        // flipped space a positive `scrollingDeltaY` moves the content down,
        // which is a larger origin y.
        panCanvas(by: CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY))
    }
```

- [ ] **Step 38: Run the whole suite and commit**

Run:
```
./macos/build.sh test
```
Expected: `Executed 7xx tests, with 0 failures`, including `PaneWorkspaceViewTests`'s existing forwarding test that asserts the host refuses `print:`.

```
git add macos/OmniAgentTests/DeskCanvasInputTests.swift macos/OmniAgent/PaneWorkspaceView.swift
git commit -m "$(cat <<'EOF'
feat(macos): ⌘+ / ⌘- / ⌘0, pinch and scroll on the desk canvas

Responder-chain commands rather than more `keyDown` cases, so the View menu can
validate and show them the way ⌘1…⌘9 already do, and greying out at the clamps
instead of doing nothing when pressed. ⌘0 is `exitToCanvas`, not a second
implementation of the same operation.

Added explicitly to `PaneFocusOverlayView.forwardedCommands`, which is a closed
set on purpose: forwarding whatever the workspace merely responds to would also
forward what it inherits from `NSView`, and `print:` is the classic.

`magnify:` is a responder-chain message, which is what lets a pinch-out inside
a session bubble up here and become the way out.

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>
Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
git push
```

---

### Task 9: The organigram visuals — chips and connectors

**Files:**
- Create: `macos/OmniAgent/DeskCanvasNodeViews.swift` (`DeskCanvasChipView`, `DeskCanvasEdgeLayer`)
- Create: `macos/OmniAgentTests/DeskCanvasNodeViewsTests.swift`
- Modify: `macos/OmniAgent.xcodeproj/project.pbxproj` (four entries per new file, eight in total)

**Interfaces:**

- Consumes (fixed shared API): `struct DeskCanvasLayout { let frames: [String: CGRect]; let edges: [DeskEdge]; let contentRect: CGRect }`, `struct DeskEdge { let from: String; let to: String }`.
- Consumes (existing, verified in `macos/OmniAgent/WorkspaceShell.swift` and `SessionConnection.swift`):
  ```swift
  enum ShellPalette {
      static let ink: NSColor           // srgb(240, 240, 244)
      static let inkTertiary: NSColor   // srgb(154, 154, 164)
      static let inkFainter: NSColor    // srgb(74, 74, 83)
      static let accent: NSColor        // srgb(139, 149, 255)
      static let cardFill: NSColor      // NSColor(white: 1, alpha: 0.04)
      static let cardStroke: NSColor    // NSColor(white: 1, alpha: 0.09)
      static func avatarGradient(forID id: String) -> (NSColor, NSColor)
      static func initials(_ label: String) -> String
      static func sessionCountLabel(_ n: Int) -> String
  }
  enum ShellFont { static func ui(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont }
  final class ShellDotsView: NSView { static func color(for status: RemoteSessionStatus?) -> NSColor }
  enum RemoteSessionStatus: String, Codable { case ready, thinking, toolExecution, awaitingApproval, error }
  ```
- Produces:
  ```swift
  final class DeskCanvasChipView: NSView {
      enum Role: Equatable { case account, workspace, pane }
      let role: Role
      var isSelected: Bool
      init(role: Role)
      func apply(title: String, detail: String?, tint: (NSColor, NSColor)?, status: RemoteSessionStatus?)
      override var isFlipped: Bool { get }
      override func draw(_ dirtyRect: NSRect)
  }
  final class DeskCanvasEdgeLayer: CAShapeLayer {
      static let strokeWidth: CGFloat
      static func path(for layout: DeskCanvasLayout) -> CGPath
      func apply(_ layout: DeskCanvasLayout, scale: CGFloat)
      override init()
      override init(layer: Any)
      override func action(forKey event: String) -> CAAction?
  }
  ```

**No blur anywhere in this task.** `PaneZoomBackdropView`'s class doc records it directly: `.withinWindow` blending *"blurs nothing — confirmed directly on screen"*, and the four-auxiliary-window `.behindWindow` version *"existed and was removed"*. The chips are a fill, a stroke and a gradient tile; the connectors are one stroked path.

The per-pane LOD chip is **not** this class. Task 6b owns it as `PaneChipView`, because it lives inside `PaneContainerView` as a fourth sibling and has to be threaded through `applyLayout()` and `roundChildren(inside:)` — constraints this class does not share. `DeskCanvasChipView` draws organigram nodes only: `.root` and `.workspace`. There is deliberately no `.pane` role here; a second class drawing the same thing is how the two drift.

---

- [ ] **Step 1: Write the failing test — connector geometry**

Create `macos/OmniAgentTests/DeskCanvasNodeViewsTests.swift`:

```swift
import AppKit
import XCTest
@testable import OmniAgent

/// The organigram's two drawn pieces: the chips that stand for the account and
/// the workspaces, and the single shape layer that carries every connector.
/// Both are frame-driven — `DeskCanvas.layout` owns every rect — so everything
/// here is checked either as pure geometry or through the repo's offscreen
/// render convention.
final class DeskCanvasNodeViewsTests: XCTestCase {

    // MARK: - Connectors

    /// One elbow per edge: down out of the parent's bottom, across at the waist,
    /// down into the child's top. Canvas space is FLIPPED
    /// (`PaneWorkspaceView.isFlipped == true`), so a parent's `maxY` is its
    /// *bottom* edge and the child sits at the larger y. Reading that the other
    /// way round draws every connector backwards through its own parent, and it
    /// is exactly the class of mistake the PNG harness cannot catch.
    func testEachConnectorLeavesTheParentsBottomAndArrivesAtTheChildsTop() {
        let layout = DeskCanvasLayout(
            frames: [
                "parent": CGRect(x: 100, y: 0, width: 200, height: 80),
                "child": CGRect(x: 0, y: 200, width: 120, height: 60),
            ],
            edges: [DeskEdge(from: "parent", to: "child")],
            contentRect: CGRect(x: 0, y: 0, width: 300, height: 260)
        )

        let path = DeskCanvasEdgeLayer.path(for: layout)
        let box = path.boundingBoxOfPath

        XCTAssertEqual(box.minY, 80, accuracy: 0.01, "it starts at the parent's bottom edge")
        XCTAssertEqual(box.maxY, 200, accuracy: 0.01, "and ends at the child's top edge")
        XCTAssertEqual(box.minX, 60, accuracy: 0.01, "spanning the child's centre")
        XCTAssertEqual(box.maxX, 200, accuracy: 0.01, "to the parent's centre")
        XCTAssertFalse(path.isEmpty, "one edge, one elbow")
    }

    /// Every connector in one path on one layer. A tree of an account, a few
    /// workspaces and up to eight sessions is a few dozen edges, and a few dozen
    /// sublayers is a few dozen composites on every frame of a pinch.
    func testEveryEdgeGoesIntoOnePathNotOneLayerEach() throws {
        let layout = DeskCanvasLayout(
            frames: [
                "a": CGRect(x: 0, y: 0, width: 100, height: 40),
                "b": CGRect(x: 0, y: 100, width: 100, height: 40),
                "c": CGRect(x: 200, y: 100, width: 100, height: 40),
            ],
            edges: [DeskEdge(from: "a", to: "b"), DeskEdge(from: "a", to: "c")],
            contentRect: CGRect(x: 0, y: 0, width: 300, height: 140)
        )
        let edgeLayer = DeskCanvasEdgeLayer()

        edgeLayer.apply(layout, scale: 1)

        XCTAssertNil(edgeLayer.sublayers, "one layer, one path")
        let box = try XCTUnwrap(edgeLayer.path).boundingBoxOfPath
        XCTAssertEqual(box.maxX, 250, accuracy: 0.01, "both edges are in it")
    }

    /// An edge naming a node the layout does not hold is skipped rather than
    /// crashing: the tree and the frames are computed together, but a pinned
    /// node removed mid-drag is the way to get one out of step.
    func testAnEdgeToAMissingNodeIsSkippedRatherThanDrawn() {
        let layout = DeskCanvasLayout(
            frames: ["a": CGRect(x: 0, y: 0, width: 100, height: 40)],
            edges: [DeskEdge(from: "a", to: "gone")],
            contentRect: CGRect(x: 0, y: 0, width: 100, height: 40)
        )

        XCTAssertTrue(DeskCanvasEdgeLayer.path(for: layout).isEmpty, "nothing to draw, nothing drawn")
    }
}
```

- [ ] **Step 2: Register the test file in the Xcode project**

Same four-entry procedure as Task 8; the project has no file-system-synchronized groups, so a file dropped in the directory silently is not compiled. Ids generated with `uuidgen | tr -d '-' | cut -c1-24 | tr 'a-f' 'A-F'` and verified absent from the file.

After the `GitFileContentTests.swift in Sources` line in the `PBXBuildFile` section:
```
		6D32C137B60B4C9586F35FBC /* DeskCanvasNodeViewsTests.swift in Sources */ = {isa = PBXBuildFile; fileRef = 1181060562454A6FA6784749 /* DeskCanvasNodeViewsTests.swift */; };
```
After the `GitFileContentTests.swift` line in the `PBXFileReference` section:
```
		1181060562454A6FA6784749 /* DeskCanvasNodeViewsTests.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = DeskCanvasNodeViewsTests.swift; sourceTree = "<group>"; };
```
In `500000000000000000000003 /* OmniAgentTests */`'s `children = (`, after `BE0A2CB26F101E0CCC68EFBA /* GitFileContentTests.swift */,`:
```
				1181060562454A6FA6784749 /* DeskCanvasNodeViewsTests.swift */,
```
In `800000000000000000000002 /* Sources */`'s `files = (`, after `1ECF599C46245E2BA8447FC1 /* GitFileContentTests.swift in Sources */,`:
```
				6D32C137B60B4C9586F35FBC /* DeskCanvasNodeViewsTests.swift in Sources */,
```

- [ ] **Step 3: Run it and watch it fail**

Run:
```
xcodebuild test -project macos/OmniAgent.xcodeproj -scheme OmniAgent \
  -destination "platform=macOS,arch=$(uname -m)" CODE_SIGNING_ALLOWED=NO \
  -only-testing:OmniAgentTests/DeskCanvasNodeViewsTests
```
Expected: `cannot find 'DeskCanvasEdgeLayer' in scope`.

- [ ] **Step 4: Implement `DeskCanvasEdgeLayer`**

Create `macos/OmniAgent/DeskCanvasNodeViews.swift`:

```swift
import AppKit

/// Every connector of the desk organigram, as one path on one `CAShapeLayer`.
///
/// One layer rather than one per edge: an account, a handful of workspaces and
/// up to eight sessions is a few dozen edges, and a few dozen sublayers is a few
/// dozen composites on every frame of a pinch. A single path is one.
///
/// A sublayer of `PaneWorkspaceView.layer`, so the camera's `sublayerTransform`
/// carries it for free — which is also why `lineWidth` has to be divided back
/// out; see `apply(_:scale:)`.
final class DeskCanvasEdgeLayer: CAShapeLayer {
    /// The stroke in **view** points, before the camera multiplies it.
    static let strokeWidth: CGFloat = 1

    override init() {
        super.init()
        fillColor = nil
        strokeColor = ShellPalette.inkFainter.cgColor
        lineWidth = Self.strokeWidth
        // The elbows are straight segments; a round join is what makes them read
        // as a connector rather than as two lines that happened to meet.
        lineJoin = .round
        lineCap = .round
        contentsScale = NSScreen.main?.backingScaleFactor ?? 2
    }

    /// Required by Core Animation: it copies a layer through this initializer to
    /// build the presentation layer, and a subclass that does not implement it
    /// gets a copy with none of its own state.
    override init(layer: Any) {
        super.init(layer: layer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    /// `CAShapeLayer` animates `path` and `lineWidth` implicitly, and the camera
    /// changes `lineWidth` on every frame of a pinch — an implicit 0.25s
    /// animation per frame is a queue the eye reads as lag, and the path would
    /// lerp between two unrelated shapes on every relayout.
    override func action(forKey event: String) -> CAAction? { NSNull() }

    /// Rebuilds the connectors, and compensates the stroke for the camera.
    ///
    /// The camera is a `sublayerTransform`, so a 1pt stroke is 0.2pt at
    /// `fitAll` — under one device pixel, a line that fades out exactly when the
    /// tree is the only thing being looked at. The width is therefore set in view
    /// points and divided by the scale the transform will multiply it by.
    func apply(_ layout: DeskCanvasLayout, scale: CGFloat) {
        path = Self.path(for: layout)
        lineWidth = scale > 0 ? Self.strokeWidth / scale : Self.strokeWidth
    }

    /// Pure and static so the geometry can be checked without a window — the
    /// same reason `PaneWorkspaceView.focusCardFrame(in:)` is.
    ///
    /// Canvas space is FLIPPED (`PaneWorkspaceView.isFlipped == true`, y growing
    /// downward), so a parent's `maxY` is its bottom edge and its children sit at
    /// larger y. An edge whose endpoints the layout does not hold is skipped.
    static func path(for layout: DeskCanvasLayout) -> CGPath {
        let path = CGMutablePath()
        for edge in layout.edges {
            guard
                let from = layout.frames[edge.from],
                let to = layout.frames[edge.to]
            else { continue }
            let start = CGPoint(x: from.midX, y: from.maxY)
            let end = CGPoint(x: to.midX, y: to.minY)
            let waist = (start.y + end.y) / 2
            path.move(to: start)
            path.addLine(to: CGPoint(x: start.x, y: waist))
            path.addLine(to: CGPoint(x: end.x, y: waist))
            path.addLine(to: end)
        }
        return path
    }
}
```

- [ ] **Step 5: Register the app source file in the Xcode project**

After the `WorkspaceShell.swift in Sources` line in the `PBXBuildFile` section:
```
		87920CEE136A49449D23172F /* DeskCanvasNodeViews.swift in Sources */ = {isa = PBXBuildFile; fileRef = 4CB37D6AF91C43D1966B98A4 /* DeskCanvasNodeViews.swift */; };
```
After the `WorkspaceShell.swift` line in the `PBXFileReference` section:
```
		4CB37D6AF91C43D1966B98A4 /* DeskCanvasNodeViews.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = DeskCanvasNodeViews.swift; sourceTree = "<group>"; };
```
In `500000000000000000000002 /* OmniAgent */`'s `children = (`, after `20000000000000000000050 /* WorkspaceShell.swift */,`:
```
				4CB37D6AF91C43D1966B98A4 /* DeskCanvasNodeViews.swift */,
```
In `800000000000000000000001 /* Sources */`'s `files = (`, after `10000000000000000000050 /* WorkspaceShell.swift in Sources */,`:
```
				87920CEE136A49449D23172F /* DeskCanvasNodeViews.swift in Sources */,
```

- [ ] **Step 6: Run the tests, then commit**

Run:
```
./macos/build.sh build && xcodebuild test -project macos/OmniAgent.xcodeproj -scheme OmniAgent \
  -destination "platform=macOS,arch=$(uname -m)" CODE_SIGNING_ALLOWED=NO \
  -only-testing:OmniAgentTests/DeskCanvasNodeViewsTests
```
Expected: `build.sh build` succeeds (which is what proves both registrations), then `Executed 3 tests, with 0 failures`.

```
git add macos/OmniAgent/DeskCanvasNodeViews.swift macos/OmniAgentTests/DeskCanvasNodeViewsTests.swift macos/OmniAgent.xcodeproj/project.pbxproj
git commit -m "$(cat <<'EOF'
feat(macos): the desk organigram's connectors, as one shape layer

Every edge as one elbow in one path on one `CAShapeLayer`: a few dozen
sublayers would be a few dozen composites on every frame of a pinch. Canvas
space is flipped, so a parent's `maxY` is its bottom edge — the path is built
from that and nothing else, and `path(for:)` is static and pure so the geometry
is checkable without a window.

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>
Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
git push
```

- [ ] **Step 7: Write the failing test — the stroke survives the camera**

Append to `DeskCanvasNodeViewsTests.swift`, in the `// MARK: - Connectors` section:

```swift
    /// The camera is a `sublayerTransform`, which scales the stroke along with
    /// everything else: at `fitAll` a 1pt line is 0.2pt, under one device pixel,
    /// and the connectors fade out exactly when the tree is the only thing on
    /// screen. The width is divided back out.
    func testTheConnectorStrokeIsDividedBackOutOfTheCameraScale() {
        let layout = DeskCanvasLayout(
            frames: [
                "a": CGRect(x: 0, y: 0, width: 100, height: 40),
                "b": CGRect(x: 0, y: 100, width: 100, height: 40),
            ],
            edges: [DeskEdge(from: "a", to: "b")],
            contentRect: CGRect(x: 0, y: 0, width: 100, height: 140)
        )
        let edgeLayer = DeskCanvasEdgeLayer()

        edgeLayer.apply(layout, scale: 1)
        XCTAssertEqual(edgeLayer.lineWidth, DeskCanvasEdgeLayer.strokeWidth, accuracy: 0.001)

        edgeLayer.apply(layout, scale: 0.2)
        XCTAssertEqual(
            edgeLayer.lineWidth,
            DeskCanvasEdgeLayer.strokeWidth / 0.2,
            accuracy: 0.001,
            "five times as wide in canvas units, one point on screen"
        )

        edgeLayer.apply(layout, scale: 0)
        XCTAssertEqual(edgeLayer.lineWidth, DeskCanvasEdgeLayer.strokeWidth, accuracy: 0.001, "no divide by zero")
    }

    /// `CAShapeLayer` animates `path` and `lineWidth` implicitly, and the camera
    /// changes `lineWidth` on every frame of a pinch.
    func testTheEdgeLayerRefusesImplicitAnimationsOnEveryKey() {
        let edgeLayer = DeskCanvasEdgeLayer()
        for key in ["path", "lineWidth", "strokeColor", "position"] {
            XCTAssertTrue(
                edgeLayer.action(forKey: key) is NSNull,
                "\(key) must not animate itself sixty times a second"
            )
        }
    }

    /// Core Animation copies a layer through `init(layer:)` to build the
    /// presentation layer. A subclass that does not implement it gets a copy
    /// with none of its own state — and the presentation layer is what is on
    /// screen during any animation the canvas runs over it.
    func testTheEdgeLayerSurvivesCoreAnimationsCopyInitializer() {
        let original = DeskCanvasEdgeLayer()
        let copy = DeskCanvasEdgeLayer(layer: original)
        XCTAssertTrue(copy.action(forKey: "path") is NSNull, "the copy is still a DeskCanvasEdgeLayer")
    }
```

- [ ] **Step 8: Run the tests, then commit**

Run:
```
xcodebuild test -project macos/OmniAgent.xcodeproj -scheme OmniAgent \
  -destination "platform=macOS,arch=$(uname -m)" CODE_SIGNING_ALLOWED=NO \
  -only-testing:OmniAgentTests/DeskCanvasNodeViewsTests
```
Expected: PASS, `Executed 6 tests, with 0 failures`. Step 4 already satisfies all three — they are written now because they lock down behaviour that is easy to regress and cheap to assert, and watching them go green against code that claims to do it is the point.

```
git add macos/OmniAgentTests/DeskCanvasNodeViewsTests.swift
git commit -m "$(cat <<'EOF'
test(macos): the connector stroke survives the camera, and never self-animates

Three regressions worth locking: a 1pt stroke under a 0.2 sublayerTransform is
a line that disappears exactly at fit-all; `CAShapeLayer`'s implicit animations
would queue a 0.25s lerp per frame of a pinch; and a CALayer subclass without
`init(layer:)` loses its state in the presentation copy.

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>
Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
git push
```

- [ ] **Step 9: Write the failing test — the chip's contract**

Append to `DeskCanvasNodeViewsTests.swift`:

```swift
    // MARK: - Chips

    /// The chip is frame-driven: `DeskCanvas.layout` owns every rect
    /// (`chipWidthFraction` of a session card's width), so the view has no
    /// intrinsic size of its own and everything it draws is a fraction of
    /// `bounds`. That is what keeps it legible at fit-all, where a fixed 13pt
    /// label would be 2pt of screen.
    func testTheChipHasNoOpinionAboutItsOwnSizeAndTakesTheFrameItIsGiven() {
        let chip = DeskCanvasChipView(role: .workspace)
        chip.frame = CGRect(x: 0, y: 0, width: 300, height: 120)

        XCTAssertEqual(chip.intrinsicContentSize.width, NSView.noIntrinsicMetric, "the layout sizes it")
        XCTAssertEqual(chip.intrinsicContentSize.height, NSView.noIntrinsicMetric)
        XCTAssertEqual(chip.bounds.size, CGSize(width: 300, height: 120))
    }

    /// Flipped, like the canvas it sits in — `PaneWorkspaceView.isFlipped` is
    /// `true` and the node rects are in that space, so a chip that disagreed
    /// would draw its tile at the bottom relative to every other node. Asserted
    /// directly rather than through the PNG: `CALayer.render(in:)` skips the
    /// compositor's geometry flips and cannot see this.
    func testTheChipIsFlippedLikeTheCanvasItSitsIn() {
        XCTAssertTrue(DeskCanvasChipView(role: .account).isFlipped)
        XCTAssertTrue(DeskCanvasChipView(role: .workspace).isFlipped)
    }

    /// Selection is a stroke change, not a layout change — the arrows walk the
    /// selection and a relayout per keypress is not free.
    func testSelectingAChipRedrawsItWithoutRelayingItOut() {
        let chip = DeskCanvasChipView(role: .workspace)
        chip.frame = CGRect(x: 0, y: 0, width: 300, height: 120)
        chip.needsDisplay = false
        chip.needsLayout = false

        chip.isSelected = true

        XCTAssertTrue(chip.needsDisplay, "the ring is drawn")
        XCTAssertFalse(chip.needsLayout, "and nothing moves")
    }

    /// Not an accessibility element: the canvas is a picture of state, and every
    /// node it draws is already reachable through the sidebar tree, which is the
    /// surface assistive clients navigate.
    func testAChipIsNotAnAccessibilityElement() {
        XCTAssertFalse(DeskCanvasChipView(role: .workspace).isAccessibilityElement())
    }
```

- [ ] **Step 10: Run and watch it fail**

Run:
```
xcodebuild test -project macos/OmniAgent.xcodeproj -scheme OmniAgent \
  -destination "platform=macOS,arch=$(uname -m)" CODE_SIGNING_ALLOWED=NO \
  -only-testing:OmniAgentTests/DeskCanvasNodeViewsTests
```
Expected: `cannot find 'DeskCanvasChipView' in scope`.

- [ ] **Step 11: Implement the chip's shell — storage, roles, state**

Append to `macos/OmniAgent/DeskCanvasNodeViews.swift`:

```swift
/// One node of the organigram that is not a session card: the `You` account
/// node, a workspace node, and — below `DeskCanvas.lodThreshold` — one pane.
///
/// The three differ only in what they carry, so they are one view with one
/// `Role`, the way `ShellTileView` serves the sidebar's 34pt workspace card and
/// its 22pt account avatar from one class.
///
/// Frame-driven and proportional. `DeskCanvas.layout` owns every rect
/// (`chipWidthFraction` of a session card's width), and every size below is a
/// fraction of `bounds` — a fixed 13pt label would be 2pt of screen at fit-all,
/// which is the only zoom where these are the thing being read.
///
/// Drawn in `draw(_:)` rather than composed from `NSTextField`s: a chip is four
/// shapes and two strings, it never takes a click (`PaneWorkspaceView.hitTest`
/// answers for the whole canvas below identity scale), and one `draw(_:)` is one
/// layer to composite instead of five.
final class DeskCanvasChipView: NSView {
    enum Role: Equatable {
        /// `You` — a circular avatar over a name.
        case account
        /// A workspace — the gradient tile, the name, and a session count.
        case workspace
    }

    let role: Role

    /// The keyboard selection ring. A stroke change only: the arrows walk the
    /// selection and a relayout per keypress is not free.
    var isSelected = false {
        didSet {
            guard oldValue != isSelected else { return }
            needsDisplay = true
        }
    }

    private var title = ""
    private var detail: String?
    private var tint: (NSColor, NSColor)?
    private var status: RemoteSessionStatus?

    init(role: Role) {
        self.role = role
        super.init(frame: .zero)
        wantsLayer = true
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    /// Flipped, like the canvas it sits in — `PaneWorkspaceView.isFlipped` is
    /// `true` and the node rects are in that space.
    override var isFlipped: Bool { true }

    func apply(
        title: String,
        detail: String?,
        tint: (NSColor, NSColor)?,
        status: RemoteSessionStatus?
    ) {
        self.title = title
        self.detail = detail
        self.tint = tint
        self.status = status
        needsDisplay = true
    }
}
```

- [ ] **Step 12: Run the four contract tests, then commit**

Run:
```
xcodebuild test -project macos/OmniAgent.xcodeproj -scheme OmniAgent \
  -destination "platform=macOS,arch=$(uname -m)" CODE_SIGNING_ALLOWED=NO \
  -only-testing:OmniAgentTests/DeskCanvasNodeViewsTests
```
Expected: PASS, `Executed 10 tests, with 0 failures`. Nothing is drawn yet — that is Step 15, and Step 13's render test is what forces it.

```
git add macos/OmniAgent/DeskCanvasNodeViews.swift macos/OmniAgentTests/DeskCanvasNodeViewsTests.swift
git commit -m "$(cat <<'EOF'
feat(macos): the desk organigram's chip view — one class, three roles

`ShellTileView` already serves the sidebar's 34pt card tile and its 22pt account
avatar from one class; the account, workspace and per-pane LOD chips differ only
in what they carry, so they are one view with one Role. Frame-driven with no
intrinsic size: `DeskCanvas.layout` owns every rect, and flipped like the canvas
it sits in — asserted directly, because `CALayer.render(in:)` skips the
compositor's geometry flips and a PNG cannot see it.

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>
Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
git push
```

- [ ] **Step 13: Write the failing offscreen-render test, with the harness**

Append to `DeskCanvasNodeViewsTests.swift`:

```swift
    // MARK: - Offscreen render (repo convention: verify AppKit layout by
    // rendering the real view to a PNG from a test — screen capture is
    // unavailable in background sessions). Pass the output directory via
    // `TEST_RUNNER_PANE_RENDER_DIR=/tmp/desk-chips ./macos/build.sh test`;
    // xcodebuild strips the `TEST_RUNNER_` prefix before handing the variable to
    // the test host, and unset it is a no-op.
    //
    // KNOWN BLIND SPOT: `CALayer.render(in:)` does not apply the compositor's
    // geometry flips. It cannot catch an orientation mistake — the pane
    // `maskedCorners` bug "looked perfectly concentric offscreen while the real
    // screen showed the ring pinching out at the bottom corners". The chip's
    // flipped-ness is asserted directly by
    // `testTheChipIsFlippedLikeTheCanvasItSitsIn` for exactly that reason; this
    // render proves it drew something, not which way up.

    func testTheWorkspaceChipDrawsItsTileAndItsNameRatherThanAFlatSheet() throws {
        let chip = DeskCanvasChipView(role: .workspace)
        chip.frame = CGRect(x: 0, y: 0, width: 300, height: 120)
        chip.apply(
            title: "OmniAgent ADE",
            detail: ShellPalette.sessionCountLabel(3),
            tint: ShellPalette.avatarGradient(forID: "omniagent-ade"),
            status: nil
        )
        let window = show(chip)
        defer { window.close() }

        let rep = try XCTUnwrap(render(chip), "the harness sizes the bitmap from bounds; nil means a zero-size chip")
        saveRenderForInspection(rep, named: "desk-canvas-chip-workspace")

        XCTAssertEqual(rep.pixelsWide, 300, "the harness allocates Int(bounds.width) pixels")
        XCTAssertEqual(rep.pixelsHigh, 120)
        XCTAssertGreaterThan(distinctColours(in: rep), 5, "render is a flat sheet — the chip drew nothing")
    }


    // MARK: - Helpers

    /// A window, because a layer-backed view with no window never runs
    /// `draw(_:)` and the render comes back empty — the test would then pass for
    /// the wrong reason.
    private func show(_ view: NSView) -> NSWindow {
        let window = NSWindow(
            contentRect: view.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        // See `PaneWorkspaceViewTests.makeAttachedWorkspace`: an `NSWindow` that
        // releases itself on close, while ARC still holds it, frees the window
        // early and SIGSEGVs a later, unrelated test on an autorelease drain
        // inside a CA commit.
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.displayIfNeeded()
        view.layoutSubtreeIfNeeded()
        return window
    }

    private func distinctColours(in rep: NSBitmapImageRep) -> Int {
        var seen = Set<String>()
        for x in stride(from: 2, to: rep.pixelsWide - 2, by: max(1, rep.pixelsWide / 20)) {
            for y in stride(from: 2, to: rep.pixelsHigh - 2, by: max(1, rep.pixelsHigh / 20)) {
                guard let colour = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                seen.insert([
                    Int(colour.redComponent * 255),
                    Int(colour.greenComponent * 255),
                    Int(colour.blueComponent * 255),
                ].map(String.init).joined(separator: "-"))
            }
        }
        return seen.count
    }

    /// Renders a view's whole layer tree, gradients included — `cacheDisplay`
    /// draws `draw(_:)` output only, which is nothing here.
    private func render(_ view: NSView) -> NSBitmapImageRep? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(view.bounds.width),
            pixelsHigh: Int(view.bounds.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .calibratedRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        view.layer?.render(in: context.cgContext)
        return rep
    }

    /// Nothing reads this in CI; it exists so Bruno can eyeball a render.
    /// `xcodebuild test`'s `TEST_RUNNER_` prefix is stripped and the rest handed
    /// straight to the test host's environment, so
    /// `TEST_RUNNER_PANE_RENDER_DIR=/tmp/panes ./macos/build.sh test` drops a PNG
    /// per named render there; unset, this is a no-op.
    private func saveRenderForInspection(_ rep: NSBitmapImageRep, named name: String) {
        guard
            let dir = ProcessInfo.processInfo.environment["PANE_RENDER_DIR"],
            let png = rep.representation(using: .png, properties: [:])
        else { return }
        let directory = URL(fileURLWithPath: dir, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? png.write(to: directory.appendingPathComponent("\(name).png"))
    }
```

- [ ] **Step 14: Run and watch it fail**

Run:
```
TEST_RUNNER_PANE_RENDER_DIR=/tmp/desk-chips xcodebuild test \
  -project macos/OmniAgent.xcodeproj -scheme OmniAgent \
  -destination "platform=macOS,arch=$(uname -m)" CODE_SIGNING_ALLOWED=NO \
  -only-testing:OmniAgentTests/DeskCanvasNodeViewsTests
```
Expected: `XCTAssertGreaterThan failed: ("1") is not greater than ("5") - render is a flat sheet — the chip drew nothing`, and the same for the dot sample. `/tmp/desk-chips/*.png` will be blank.

- [ ] **Step 15: Implement the chip's body — fill, stroke, text**

Append to `DeskCanvasChipView`:

```swift
    override func draw(_ dirtyRect: NSRect) {
        let height = bounds.height
        guard height > 0, bounds.width > 0 else { return }
        let radius = height * 0.18
        let body = NSBezierPath(
            roundedRect: bounds.insetBy(dx: height * 0.03, dy: height * 0.03),
            xRadius: radius,
            yRadius: radius
        )
        ShellPalette.cardFill.setFill()
        body.fill()
        (isSelected ? ShellPalette.accent : ShellPalette.cardStroke).setStroke()
        body.lineWidth = height * (isSelected ? 0.035 : 0.014)
        body.stroke()

        let inset = height * 0.18
        let tileSide = height * 0.46
        drawLeading(in: NSRect(x: inset, y: (height - tileSide) / 2, width: tileSide, height: tileSide))

        let textX = inset + tileSide + inset * 0.75
        let textWidth = max(0, bounds.width - textX - inset)
        guard textWidth > 0 else { return }
        let hasDetail = detail?.isEmpty == false
        let titleHeight = height * 0.30
        draw(
            title,
            in: NSRect(
                x: textX,
                y: hasDetail ? height * 0.22 : (height - titleHeight) / 2,
                width: textWidth,
                height: titleHeight
            ),
            font: ShellFont.ui(height * 0.24, .semibold),
            color: ShellPalette.ink
        )
        if let detail, hasDetail {
            draw(
                detail,
                in: NSRect(x: textX, y: height * 0.52, width: textWidth, height: height * 0.26),
                font: ShellFont.ui(height * 0.19, .regular),
                color: ShellPalette.inkTertiary
            )
        }
    }

    private func draw(
        _ text: String,
        in rect: NSRect,
        font: NSFont,
        color: NSColor,
        centred: Bool = false
    ) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        paragraph.alignment = centred ? .center : .left
        NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph,
        ]).draw(in: rect)
    }
```

- [ ] **Step 16: Implement the three leading marks**

Append to `DeskCanvasChipView`:

```swift
    /// The account's avatar is a circle, a workspace's tile is a rounded square,
    /// and a pane's mark is a status dot — the same three shapes the sidebar
    /// already uses for the same three things.
    private func drawLeading(in rect: NSRect) {
        switch role {
        case .account, .workspace:
            let path = role == .account
                ? NSBezierPath(ovalIn: rect)
                : NSBezierPath(roundedRect: rect, xRadius: rect.height * 0.28, yRadius: rect.height * 0.28)
            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            let colours = tint ?? (ShellPalette.accent, ShellPalette.accent)
            // 150° in the design's CSS runs top-left to bottom-right;
            // `NSGradient`'s angle is counter-clockwise from east, which puts the
            // same ramp at -60 — exactly as `ShellTileView` does it.
            NSGradient(starting: colours.0, ending: colours.1)?.draw(in: rect, angle: -60)
            NSGraphicsContext.restoreGraphicsState()
            draw(
                ShellPalette.initials(title),
                in: rect.insetBy(dx: 0, dy: rect.height * 0.3),
                font: ShellFont.ui(rect.height * 0.4, .bold),
                color: .white,
                centred: true
            )
        }
    }
```

- [ ] **Step 17: Run the render tests and look at the PNGs**

Run:
```
TEST_RUNNER_PANE_RENDER_DIR=/tmp/desk-chips xcodebuild test \
  -project macos/OmniAgent.xcodeproj -scheme OmniAgent \
  -destination "platform=macOS,arch=$(uname -m)" CODE_SIGNING_ALLOWED=NO \
  -only-testing:OmniAgentTests/DeskCanvasNodeViewsTests
```
Expected: PASS, `Executed 12 tests, with 0 failures`, and `/tmp/desk-chips/desk-canvas-chip-workspace.png` + `desk-canvas-chip-pane-awaiting.png` on disk with a legible chip in each. If `distinctColours` still comes back at 1, `draw(_:)` did not run and the fix is in `show(_:)`'s `displayIfNeeded()`, not in the assertion. If the dot sample lands off-colour, move the sampled coordinate to the tile centre the constants compute (`x = 0.18*120 + 0.46*120/2 ≈ 49`), never widen the tolerance.

- [ ] **Step 18: Run the whole suite and commit**

Run:
```
./macos/build.sh test
```
Expected: `0 failures`, with the executed count higher than the run recorded at the start of this task. Grep for the green `Executed N tests` line before believing the summary — a launch can print a green total above a trailing `Failing tests:` list and still exit 65.

```
git add macos/OmniAgent/DeskCanvasNodeViews.swift macos/OmniAgentTests/DeskCanvasNodeViewsTests.swift
git commit -m "$(cat <<'EOF'
feat(macos): the You, Workspace and pane chips draw themselves

Every size is a fraction of `bounds`, because the layout owns the rect and a
fixed 13pt label is 2pt of screen at fit-all — the only zoom where a chip is the
thing being read. Every colour is a `ShellPalette` token, and the pane chip's
dot comes straight from `ShellDotsView.color(for:)`: amber has to mean exactly
one thing anywhere it appears.

Offscreen renders per the repo convention, both asserting on their own
(non-degenerate bitmap, not a flat sheet, the dot in the status colour) so the
PNG stays an eyeballing aid rather than the check. Noted inline that
`CALayer.render(in:)` skips the compositor's geometry flips and so cannot catch
an orientation mistake — the flipped-ness is asserted directly instead.

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>
Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
git push
```

---

### Task 9b: Install the chips and connectors on the canvas

Task 9 builds `DeskCanvasChipView` and `DeskCanvasEdgeLayer` and unit-tests them in isolation. Nothing instantiates them: no chip is ever added as a subview, no edge path is ever fed a layout, and `DeskCanvasEdgeLayer.apply(_:scale:)` — whose whole job is compensating `lineWidth` for the camera — is never called. This task installs them, and adds the two assembled-canvas render cases spec §6 asks for ("offscreen render at `fitAll` and at 1.0"), which are also the only tests that would have caught the omission.

**Files:**
- Modify: `macos/OmniAgent/PaneWorkspaceView.swift` (in `updateCanvasLayout()`, and a new `syncCanvasChrome(_:)` beside it)
- Modify: `macos/OmniAgentTests/DeskCanvasNodeViewsTests.swift` (add the installation and assembled-render cases)

No pbxproj edit: both files are registered by Tasks 5 and 9.

**Interfaces:**

- Consumes:
  - `final class DeskCanvasChipView: NSView` — `init(role: Role)`, `func apply(title: String, detail: String?, tint: (NSColor, NSColor)?, status: RemoteSessionStatus?)`, `var isSelected: Bool` (Task 9)
  - `final class DeskCanvasEdgeLayer: CAShapeLayer` — `func apply(_ layout: DeskCanvasLayout, scale: CGFloat)` (Task 9)
  - `private(set) var canvasLayout: DeskCanvasLayout?`, `private func updateCanvasLayout()`, `func derivedCanvasRoot() -> DeskNode` (Task 5)
  - `var selectedNodeID: String?` (Task 8)
  - `enum ShellPalette { static func avatarGradient(forID id: String) -> (NSColor, NSColor); static func initials(_ label: String) -> String }` (existing, `WorkspaceShell.swift`)
- Produces:
  - `private var canvasChips: [String: DeskCanvasChipView]` on `PaneWorkspaceView`
  - `private let canvasEdges = DeskCanvasEdgeLayer()` on `PaneWorkspaceView`
  - `private func syncCanvasChrome(_ layout: DeskCanvasLayout, root: DeskNode)` on `PaneWorkspaceView`

- [ ] **Step 1: Write the failing installation test**

Add to `DeskCanvasNodeViewsTests.swift`:

```swift
    /// The chips and the edge layer are only worth building if something puts
    /// them on the canvas. This is that assertion: after a canvas layout pass
    /// there is exactly one chip per non-session node, each at its node's
    /// frame, and the edge path has a segment for every edge.
    func testACanvasLayoutPassInstallsAChipPerNonSessionNodeAndOneEdgePath() throws {
        let workspace = makeCanvasWorkspace(sessions: 3)
        workspace.layoutSubtreeIfNeeded()

        let layout = try XCTUnwrap(workspace.canvasLayout)
        let root = workspace.derivedCanvasRoot()
        var expected: [String] = []
        func walk(_ node: DeskNode) {
            if case .session = node.kind {} else { expected.append(node.id) }
            node.children.forEach(walk)
        }
        walk(root)

        XCTAssertEqual(
            Set(workspace.canvasChipIDsForTesting),
            Set(expected),
            "one chip per root/workspace node, and none for a session — a session's card is its own grid"
        )
        for id in expected {
            let chip = try XCTUnwrap(workspace.canvasChipForTesting(id))
            XCTAssertEqual(chip.frame, layout.frames[id], "\(id)'s chip sits at its node frame")
            XCTAssertFalse(chip.isHidden)
        }
        XCTAssertFalse(layout.edges.isEmpty, "a three-session tree has edges")
        XCTAssertNotNil(workspace.canvasEdgePathForTesting, "the edge layer was never given a path")
    }

    /// `lineWidth` is in canvas units, so a hairline at fit-all would vanish and
    /// a hairline at identity would be a slab. The edge layer compensates, and
    /// nothing else can do it for it.
    func testTheEdgeLineWidthIsCompensatedForTheCamera() throws {
        let workspace = makeCanvasWorkspace(sessions: 3)
        workspace.layoutSubtreeIfNeeded()
        let content = try XCTUnwrap(workspace.canvasLayout?.contentRect)

        workspace.camera = DeskCamera.fitAll(content: content, in: workspace.bounds)
        workspace.layoutSubtreeIfNeeded()
        let wide = workspace.canvasEdgeLineWidthForTesting

        workspace.camera = DeskCamera(scale: 1, origin: .zero)
        workspace.layoutSubtreeIfNeeded()
        let narrow = workspace.canvasEdgeLineWidthForTesting

        XCTAssertGreaterThan(wide, narrow, "zoomed out, the stroke must be fatter in canvas units to stay visible")
    }
```

- [ ] **Step 2: Add the three test seams**

`canvasChips` and `canvasEdges` are private; the tests need to see them without widening the real API. Add to `PaneWorkspaceView`, in the same `// MARK: - Testing seams` section the file already uses:

```swift
    var canvasChipIDsForTesting: [String] { Array(canvasChips.keys) }
    func canvasChipForTesting(_ id: String) -> DeskCanvasChipView? { canvasChips[id] }
    var canvasEdgePathForTesting: CGPath? { canvasEdges.path }
    var canvasEdgeLineWidthForTesting: CGFloat { canvasEdges.lineWidth }
```

- [ ] **Step 3: Run it and watch it fail**

Run:
```
./macos/build.sh test 2>&1 | grep -E "error:|Executed"
```
Expected: compile failure — `value of type 'PaneWorkspaceView' has no member 'canvasChipIDsForTesting'`.

- [ ] **Step 4: Declare the storage**

In `PaneWorkspaceView`'s **class body** (stored properties cannot live in an extension), immediately after Task 5's `canvasLayout`:

```swift
    /// Node id -> chip, for the organigram's non-session nodes only. A session
    /// node needs no chip: its card *is* its pane grid, drawn by the same
    /// layout pass that positions everything else.
    ///
    /// Pooled by node id rather than rebuilt each pass, the way
    /// `syncHolePlaceholders(_:holeIDs:)` pools hole tiles — a chip rebuilt
    /// every layout would drop the keyboard selection ring mid-arrow-walk.
    private var canvasChips: [String: DeskCanvasChipView] = [:]

    /// Every connector as one path. One layer, not one per edge: the tree is
    /// redrawn whenever a node moves, and N layers would each need their own
    /// `lineWidth` compensation.
    private let canvasEdges = DeskCanvasEdgeLayer()
```

- [ ] **Step 5: Implement `syncCanvasChrome`**

Add immediately after `updateCanvasLayout()`:

```swift
    /// Positions the organigram's chips and connectors for `layout`.
    ///
    /// Chips go **below** every pane container, the same `positioned:`
    /// relationship `syncHolePlaceholders(_:holeIDs:)` uses, so a card always
    /// composites over the tree rather than the other way round.
    private func syncCanvasChrome(_ layout: DeskCanvasLayout, root: DeskNode) {
        var live: Set<String> = []
        func walk(_ node: DeskNode) {
            defer { node.children.forEach(walk) }
            let role: DeskCanvasChipView.Role
            switch node.kind {
            case .session: return          // a session's card is its grid
            case .root: role = .account
            case .workspace: role = .workspace
            }
            guard let frame = layout.frames[node.id] else { return }
            live.insert(node.id)
            let chip: DeskCanvasChipView
            if let existing = canvasChips[node.id] {
                chip = existing
            } else {
                chip = DeskCanvasChipView(role: role)
                canvasChips[node.id] = chip
                addSubview(chip, positioned: .below, relativeTo: nil)
            }
            chip.frame = frame
            chip.isSelected = (selectedNodeID == node.id)
            switch node.kind {
            case .root:
                chip.apply(title: accountDisplayName, detail: nil, tint: nil, status: nil)
            case .workspace(let project):
                chip.apply(
                    title: ShellPalette.initials(project),
                    detail: project,
                    tint: ShellPalette.avatarGradient(forID: project),
                    status: nil
                )
            case .session:
                return
            }
        }
        walk(root)
        for (id, chip) in canvasChips where !live.contains(id) {
            chip.removeFromSuperview()
            canvasChips.removeValue(forKey: id)
        }
        if canvasEdges.superlayer !== layer {
            layer?.insertSublayer(canvasEdges, at: 0)
        }
        canvasEdges.apply(layout, scale: camera.scale)
    }
```

`accountDisplayName` is the label the sidebar's account row already shows; if `PaneWorkspaceView` has no access to it, pass it in the same way the shell passes other display strings and default to `"You"`. Confirm with `grep -n "accountDisplayName\|accountRow" macos/OmniAgent/WorkspaceShell.swift macos/OmniAgent/PaneWorkspaceView.swift` before writing this line, and use whatever that grep shows.

- [ ] **Step 6: Call it from the layout pass**

In `updateCanvasLayout()` (Task 5), immediately before its closing `updateVisibility()`:

```swift
        syncCanvasChrome(layout, root: root)
```

And in canvas mode's teardown — the `else` arm of `canvasMode`'s setter, where normal mode is restored — remove the chrome, since a normal-mode layout knows nothing about it:

```swift
            canvasChips.values.forEach { $0.removeFromSuperview() }
            canvasChips.removeAll()
            canvasEdges.removeFromSuperlayer()
            // The camera is deliberately NOT reset here. It is what remembers
            // whether the user was inside a session or out on the canvas, and
            // `applyDestination` turns this mode back on when they return to
            // Desk. Resetting it would land them on the canvas every time they
            // glanced at Dashboard.
```

- [ ] **Step 7: Run the installation tests**

Run:
```
./macos/build.sh test 2>&1 | grep -E "error:|Executed|DeskCanvasNodeViews"
```
Expected: PASS with `0 failures`.

- [ ] **Step 8: Write the assembled-canvas render tests**

Spec §6's visual requirement, and the only cases that render the canvas rather than a chip on its own. Add to `DeskCanvasNodeViewsTests.swift`:

```swift
    /// Spec §6: an offscreen render at fit-all and at identity. Run with
    /// `TEST_RUNNER_PANE_RENDER_DIR=/tmp/desk-canvas ./macos/build.sh test` to
    /// keep the PNGs and look at them.
    ///
    /// Known blind spot, and why the assertions below are about content rather
    /// than geometry: `CALayer.render(in:)` skips the compositor's geometry
    /// flips, so this harness cannot see an upside-down `maskedCorners` — the
    /// trap `roundChildren(inside:)`'s own comment records.
    func testTheAssembledCanvasRendersAtFitAllAndAtIdentity() throws {
        let workspace = makeCanvasWorkspace(sessions: 3)
        let window = show(workspace)
        defer { window.close() }
        workspace.layoutSubtreeIfNeeded()
        let content = try XCTUnwrap(workspace.canvasLayout?.contentRect)

        workspace.camera = DeskCamera.fitAll(content: content, in: workspace.bounds)
        workspace.layoutSubtreeIfNeeded()
        let wide = try XCTUnwrap(render(workspace))
        saveRenderForInspection(wide, named: "desk-canvas-fit-all")
        XCTAssertGreaterThan(
            distinctColours(in: wide),
            5,
            "fit-all is a flat sheet — the tree drew nothing"
        )

        let group = try XCTUnwrap(workspace.canvasChipIDsForTesting.isEmpty ? nil : workspace.groupOrderForTesting.first)
        workspace.enterSession(group)
        workspace.layoutSubtreeIfNeeded()
        let close = try XCTUnwrap(render(workspace))
        saveRenderForInspection(close, named: "desk-canvas-identity")
        XCTAssertTrue(workspace.camera.isIdentity, "the render must be of a landed camera, not a mid-flight one")
        XCTAssertGreaterThan(distinctColours(in: close), 5, "identity is a flat sheet")
    }
```

- [ ] **Step 9: Run the render tests and look at the PNGs**

Run:
```
TEST_RUNNER_PANE_RENDER_DIR=/tmp/desk-canvas ./macos/build.sh test 2>&1 | grep -E "error:|Executed"
open /tmp/desk-canvas
```
Expected: PASS with `0 failures`, and two PNGs. Look at them: `desk-canvas-fit-all.png` should show the tree — an account chip over workspace chips over three session cards, connected — and `desk-canvas-identity.png` should show one session's grid filling the frame with no tree visible around it.

- [ ] **Step 10: Run the whole suite**

Run:
```
./macos/build.sh test
```
Expected: `0 failures`, and the executed count higher than the run recorded at the start of this task by exactly the four tests added here. Quote the green `Executed N tests` line rather than trusting the summary — a launch can print a green total above a trailing `Failing tests:` list and still exit 65.

- [ ] **Step 11: Commit**

```bash
git add macos/OmniAgent/PaneWorkspaceView.swift macos/OmniAgentTests/DeskCanvasNodeViewsTests.swift
git commit -m "$(cat <<'EOF'
feat(macos): install the organigram's chips and connectors on the canvas

Task 9 built DeskCanvasChipView and DeskCanvasEdgeLayer and tested them in
isolation; nothing put them on screen. The layout pass now pools one chip per
non-session node by node id (a session needs none -- its card is its grid),
stacks them below every pane container so a card always composites over the
tree, and hands the edge layer the layout plus the camera scale so lineWidth
is compensated in canvas units.

Adds the two assembled-canvas renders spec section 6 asks for -- fit-all and
identity -- which are also the only tests that would have caught the chips
never being installed.

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>
Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)" && git push
```

---

### Task 10a: Selecting DESK loads canvas mode

The Desk is `WorkspaceDestination.terminals` (`.terminals.title == "Desk"`), not a new destination case — `WorkspaceShellTests.testFilesDestinationIsGone` pins `WorkspaceDestination.allCases` to exactly `["dashboard","board","terminals"]`, and nav rows are built straight off `allCases`.

There is **no new content root.** The pane-lifecycle dossier's anchor "`contentContainer.addSubview(workspace)` — the exact install point of the Desk's content root that `DeskCanvasView` replaces" is superseded by the spec's revision note §2: *"The canvas needs no `DeskCanvasView` hosting N `PaneWorkspaceView`s. One instance already owns every session's panes. Canvas mode is a second layout mode on the view that already exists."* `installSplitView(on:)` is **unchanged** by this whole plan.

**Files:**
- Create: `macos/OmniAgentTests/WorkspaceWindowControllerDeskCanvasTests.swift`
- Modify: `macos/OmniAgent/WorkspaceWindowController.swift` (in `applyDestination(_:)`)
- Modify: `macos/OmniAgent.xcodeproj/project.pbxproj` (four entries for the new test file)

**Interfaces:**
- Consumes: `var canvasMode: Bool { get set }` on `PaneWorkspaceView` (Task 6) — its setter relayouts every group at its node rect and re-applies the current `camera`; setting it `false` restores the single-active-group layout.
- Consumes: `func applyDestination(_ destination: WorkspaceDestination)` — `WorkspaceWindowController`, existing.
- Consumes: `var workspaceView: PaneWorkspaceView { workspace }` — `WorkspaceWindowController`, existing.
- Produces: nothing new; `applyDestination` gains one statement.

- [ ] **Step 1: Register the new test file in the Xcode project**

Two fresh ids, verified absent from `project.pbxproj` at planning time (`grep -c` returned 0). Regenerate with `uuidgen | tr -d '-' | cut -c1-24 | tr 'a-f' 'A-F'` if `grep` finds either already present.

Edit 1 — in the `PBXBuildFile` section, beside the line matching `GitFileContentTests.swift in Sources`:
```
		886AD5FC7A3C4837958280C6 /* WorkspaceWindowControllerDeskCanvasTests.swift in Sources */ = {isa = PBXBuildFile; fileRef = FB9D2F62F22A4B56B0D9AAF1 /* WorkspaceWindowControllerDeskCanvasTests.swift */; };
```
Edit 2 — in the `PBXFileReference` section, beside the line matching `GitFileContentTests.swift */ = {isa = PBXFileReference`:
```
		FB9D2F62F22A4B56B0D9AAF1 /* WorkspaceWindowControllerDeskCanvasTests.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = WorkspaceWindowControllerDeskCanvasTests.swift; sourceTree = "<group>"; };
```
Edit 3 — in `500000000000000000000003 /* OmniAgentTests */`'s `children = (`, as the last entry before the closing `);` (today that follows `20000000000000000000071 /* EngineLauncherTests.swift */,`):
```
				FB9D2F62F22A4B56B0D9AAF1 /* WorkspaceWindowControllerDeskCanvasTests.swift */,
```
Edit 4 — in `800000000000000000000002 /* Sources */`'s `files = (`, as the last entry before the closing `);` (today that follows `10000000000000000000071 /* EngineLauncherTests.swift in Sources */,`):
```
				886AD5FC7A3C4837958280C6 /* WorkspaceWindowControllerDeskCanvasTests.swift in Sources */,
```

- [ ] **Step 2: Write the failing test**

Create `macos/OmniAgentTests/WorkspaceWindowControllerDeskCanvasTests.swift`. The `makeEmptyController()` helper is deliberately duplicated here rather than shared — `WorkspaceWindowControllerTests`, `EditorPaneIntegrationTests` and `WorkspaceWindowControllerTask6b2Tests` each carry their own copy already.

```swift
import AppKit
import XCTest
@testable import OmniAgent

/// The Desk canvas's wiring into the window: the destination that loads it,
/// the menu and toolbar commands that drive it, and the `desk_canvas_native`
/// row that outlives a launch. The canvas geometry itself is `DeskCanvasTests`'
/// job — nothing here computes a layout, it only checks that the app reaches
/// the canvas and hands it the right state.
final class WorkspaceWindowControllerDeskCanvasTests: XCTestCase {
    /// DESK *is* the canvas: there is no separate content root, so the only
    /// thing selecting it can do is put the one pane workspace into its second
    /// layout mode. Leaving takes it back out, so a hidden workspace is not
    /// laying out every session's grid for nobody.
    func testTheDeskDestinationLoadsTheCanvasAndLeavingItUnloadsIt() {
        let controller = makeEmptyController()
        defer { controller.close() }

        controller.applyDestination(.dashboard)
        XCTAssertFalse(controller.workspaceView.canvasMode, "off the Desk there is no canvas to lay out")
        XCTAssertTrue(controller.workspaceView.isHidden)

        controller.applyDestination(.terminals)
        XCTAssertTrue(controller.workspaceView.canvasMode, "selecting DESK loads the organigram")
        XCTAssertFalse(controller.workspaceView.isHidden)
        XCTAssertEqual(controller.destination, .terminals)
    }

    /// `applyDestination` must never add or remove the pane workspace —
    /// `contentContainer`'s own doc: "Unmounting `PaneWorkspaceView` would tear
    /// down live SwiftTerm views and their PTY attachment along with it."
    /// Canvas mode is a layout switch, so the view stays in the same superview
    /// across the round trip.
    func testLoadingTheCanvasNeverRemountsThePaneWorkspace() {
        let controller = makeEmptyController()
        defer { controller.close() }
        let host = controller.workspaceView.superview

        controller.applyDestination(.board)
        controller.applyDestination(.terminals)

        XCTAssertNotNil(host)
        XCTAssertTrue(controller.workspaceView.superview === host, "hidden, never unmounted")
    }

    // MARK: - Helpers

    private func makeEmptyController() -> WorkspaceWindowController {
        WorkspaceWindowController(
            connection: SessionConnection(
                socketURL: URL(fileURLWithPath: "/tmp/omniagent-desk-canvas-test.sock")
            ),
            panes: []
        )
    }
}
```

- [ ] **Step 3: Run it and watch it fail**

Run:
```
xcodebuild test -project macos/OmniAgent.xcodeproj -scheme OmniAgent \
  -destination "platform=macOS,arch=$(uname -m)" CODE_SIGNING_ALLOWED=NO \
  ONLY_ACTIVE_ARCH=YES ARCHS="$(uname -m)" \
  -only-testing:OmniAgentTests/WorkspaceWindowControllerDeskCanvasTests
```
Expected: a **compile** failure, not a test failure — `value of type 'PaneWorkspaceView' has no member 'canvasMode'` if Task 6 has not landed, or `XCTAssertTrue failed - selecting DESK loads the organigram` once it has.

- [ ] **Step 4: Implement**

In `WorkspaceWindowController.swift`, in `applyDestination(_:)`. Add the one statement and extend the doc comment; leave the existing four lines exactly as they are.

```swift
    /// Swaps the destination. `isHidden`, never add/remove: see
    /// `contentContainer`'s own doc for why the pane workspace must stay
    /// mounted.
    ///
    /// DESK *is* the canvas. There is no second content root and no
    /// `DeskCanvasView`: the one `PaneWorkspaceView` already owns every
    /// session's grid, so selecting DESK only asks it for its second layout
    /// mode — every group laid out at its node rect, under one camera —
    /// and leaving asks for the first one back, so a hidden workspace is not
    /// laying out ninety-six panes for nobody. The camera itself is not
    /// touched here: it is state, restored from `desk_canvas_native` and
    /// preserved across a trip to Dashboard and back, so coming back to the
    /// Desk shows what you left rather than yanking you out of a session.
    func applyDestination(_ destination: WorkspaceDestination) {
        self.destination = destination
        shellSidebar.applyDestination(destination)
        let isTerminals = destination == .terminals
        workspace.isHidden = !isTerminals
        // Canvas mode is on for the whole Desk destination, including while the
        // user is *inside* a session — being in one is the camera at identity
        // over that card, not a different layout mode (see Task 7's
        // `landSession`, which deliberately leaves `canvasMode` alone).
        //
        // That is what makes this assignment safe rather than a trapdoor.
        // Leaving Desk turns the mode off; coming back turns it on again with
        // the camera untouched, so the user lands back where they were — in
        // their session if they were in one, on the canvas if they were not.
        // A version of this that derived the mode from "was the canvas showing"
        // needed a second flag to say so; keeping the camera authoritative
        // needs none.
        workspace.canvasMode = isTerminals
        placeholder.isHidden = isTerminals
        if !isTerminals { placeholder.show(destination) }
    }
```

Note on ordering: `applyDestination(.terminals)` is called once from `init`, before any pane exists and before the window has laid out. `canvasMode = true` there must be harmless — an empty canvas has no nodes. The first camera is set later, by Task 10e's restore.

- [ ] **Step 5: Run the test**

Run:
```
xcodebuild test -project macos/OmniAgent.xcodeproj -scheme OmniAgent \
  -destination "platform=macOS,arch=$(uname -m)" CODE_SIGNING_ALLOWED=NO \
  ONLY_ACTIVE_ARCH=YES ARCHS="$(uname -m)" \
  -only-testing:OmniAgentTests/WorkspaceWindowControllerDeskCanvasTests
```
Expected: PASS, 2 tests.

- [ ] **Step 6: Commit**

Check mtimes first — only these three files may be staged:
```
stat -f "%Sm %N" macos/OmniAgent/WorkspaceWindowController.swift macos/OmniAgentTests/WorkspaceWindowControllerDeskCanvasTests.swift macos/OmniAgent.xcodeproj/project.pbxproj
git add macos/OmniAgent/WorkspaceWindowController.swift macos/OmniAgentTests/WorkspaceWindowControllerDeskCanvasTests.swift macos/OmniAgent.xcodeproj/project.pbxproj
git commit -m "feat(macos): selecting DESK loads the spatial canvas

DESK is WorkspaceDestination.terminals and the canvas is the one
PaneWorkspaceView in its second layout mode, so applyDestination only has
to ask for that mode and ask for it back when you leave. No second content
root, no remount: contentContainer's never-unmount invariant is what keeps
the live SwiftTerm views and their PTY attachment alive across the switch.

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>
Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 10b: The Desk menu — ⌘0, ⌃1…⌃9, and session stepping

**Shortcut audit, from `ApplicationMenus.install()` read at planning time.** Bound today: ⌘, ⌘H ⌥⌘H ⌘Q ⌘T ⇧⌘T ⇧⌘E ⌘N ⌘W ⇧⌘W **⌃Space** (Spotlight) ⌘K (its alternate) ⌘C ⌘V ⌘A ⌘. ⌃⌘K ⌘R ⌘L ⌘↩ ⌥⌘O ⌥⌘←↑→↓ ⌃⌘←↑→↓ **⌘1…⌘9** (`selectPane:`, `tag = index`) ⌃⌘S ⌘I ⌘M.

- **⌃1 … ⌃9: entirely free.** ⌃Space is the only plain-Control binding in the app; every other `.control` use is a ⌃⌘ combo. **Free, taken here.**
- **⌘0: entirely free.** ⌘1…⌘9 stop at 9. **Free, taken here for Zoom to Fit** — the digit-zero-resets-zoom idiom every drawing app uses.
- Stepping: **⇧⌘[ and ⇧⌘]** are free (nothing binds `[` or `]` under any modifier) and are the macOS-standard previous/next-tab chords. The web build uses ⌃↑/⌃↓ for this via `adjacentSessionTab`, but those are Mission Control / App Exposé defaults.

**Gotcha to carry into the step:** ⌃1…⌃9 is free *in the app* but System Settings → Keyboard → Shortcuts → Mission Control ships "Switch to Desktop N" on ⌃1…⌃N, active once more than one Desktop exists. The system binding wins. Verify on the real machine when the packaged build lands (Task 10f); ⌥⌘1…⌥⌘9 is the fallback if it is shadowed.

**Files:**
- Modify: `macos/OmniAgent/AppDelegate.swift` (in `ApplicationMenus.install()`, after the `Panes` menu block, before the `Window` menu block)
- Modify: `macos/OmniAgent/WorkspaceWindowController.swift` (new `// MARK: - Desk canvas commands` section; in `validateMenuItem(_:)`; in the `shellSidebar.onSelectSession` closure in `init`)
- Test: `macos/OmniAgentTests/WorkspaceWindowControllerDeskCanvasTests.swift`

**Interfaces:**
- Consumes: `static func visibleSessionGroupID(_ panes: [PaneDescriptor], project: String, focusedPaneID: String?) -> String?` (Task 1)
- Consumes: `static func currentSessionGroupID(_ panes: [PaneDescriptor], focusedPaneID: String?) -> String?` (Task 1)
- Consumes: `static func adjacentSessionTab(_ panes: [PaneDescriptor], project: String, focusedPaneID: String?, offset: Int) -> PaneDescriptor?` (Task 1)
- Consumes: `static func group(_ panes: [PaneDescriptor], focusedPaneID: String?) -> [ProjectSessionsNode]` (existing)
- Consumes: `func enterSession(_ group: String)` and `func exitToCanvas()` on `PaneWorkspaceView` (Task 6)
- Consumes: `@discardableResult func activateGroup(_ group: String) -> Bool` on `PaneWorkspaceView` (existing)
- Produces:
  - `func enterDeskSession(_ group: String)` — `WorkspaceWindowController`
  - `@objc func zoomDeskToFit(_ sender: Any?)` — `WorkspaceWindowController`
  - `@objc func enterFocusedSession(_ sender: Any?)` — `WorkspaceWindowController`
  - `@objc func selectSession(_ sender: Any?)` — `WorkspaceWindowController`
  - `@objc func nextSession(_ sender: Any?)` — `WorkspaceWindowController`
  - `@objc func previousSession(_ sender: Any?)` — `WorkspaceWindowController`
  - `func currentDeskSessionGroup() -> String?` — `WorkspaceWindowController`
  - `private func deskSession(at index: Int) -> SessionGroupNode?` — `WorkspaceWindowController`
  - `private func stepTarget(by offset: Int) -> PaneDescriptor?` — `WorkspaceWindowController`
  - `private func stepSession(by offset: Int)` — `WorkspaceWindowController`

- [ ] **Step 1: Write the failing test for the menu bindings**

Append to `WorkspaceWindowControllerDeskCanvasTests.swift`:

```swift
    // MARK: - The Desk menu

    /// The canvas's shortcuts, and the two things that make them safe: ⌘0 and
    /// ⌃1…⌃9 were verified free before they were taken, and the pre-existing
    /// top-level menu titled "Session" is left alone — its items are one
    /// terminal's PTY verbs (Interrupt, Kill, Reattach), a different thing from
    /// the user-facing Session these commands switch between.
    func testTheDeskMenuBindsZoomToFitAndTheNineSessionDigits() throws {
        ApplicationMenus.install()

        let desk = try XCTUnwrap(NSApp.mainMenu?.item(withTitle: "Desk")?.submenu)

        let fit = try XCTUnwrap(desk.item(withTitle: "Zoom to Fit"))
        XCTAssertNil(fit.target, "travels the responder chain like every other command")
        XCTAssertEqual(fit.action, Selector(("zoomDeskToFit:")))
        // ⌘= and ⌘- reach the view's own commands through the responder chain;
        // without menu items they would be unreachable selectors.
        let zoomIn = try XCTUnwrap(desk.submenu?.item(withTitle: "Zoom In"))
        XCTAssertEqual(zoomIn.action, Selector(("zoomCanvasIn:")))
        XCTAssertEqual(zoomIn.keyEquivalent, "=")
        let zoomOut = try XCTUnwrap(desk.submenu?.item(withTitle: "Zoom Out"))
        XCTAssertEqual(zoomOut.action, Selector(("zoomCanvasOut:")))
        XCTAssertEqual(zoomOut.keyEquivalent, "-")
        XCTAssertEqual(fit.keyEquivalent, "0")
        XCTAssertEqual(fit.keyEquivalentModifierMask, [.command])

        let next = try XCTUnwrap(desk.item(withTitle: "Next Session"))
        XCTAssertEqual(next.action, Selector(("nextSession:")))
        XCTAssertEqual(next.keyEquivalent, "]")
        XCTAssertEqual(next.keyEquivalentModifierMask, [.command, .shift])

        let third = try XCTUnwrap(desk.item(withTitle: "Session 3"))
        XCTAssertEqual(third.action, Selector(("selectSession:")))
        XCTAssertEqual(third.keyEquivalent, "3")
        XCTAssertEqual(third.keyEquivalentModifierMask, [.control], "⌃N, not ⌘N — ⌘3 already selects pane 3")
        XCTAssertEqual(third.tag, 3, "the selectPane: precedent: the digit rides on the tag")

        XCTAssertNotNil(
            NSApp.mainMenu?.item(withTitle: "Session")?.submenu?.item(withTitle: "Interrupt"),
            "the per-pane Session menu is deliberately untouched"
        )
    }
```

- [ ] **Step 2: Run it and watch it fail**

Run:
```
xcodebuild test -project macos/OmniAgent.xcodeproj -scheme OmniAgent \
  -destination "platform=macOS,arch=$(uname -m)" CODE_SIGNING_ALLOWED=NO \
  ONLY_ACTIVE_ARCH=YES ARCHS="$(uname -m)" \
  -only-testing:OmniAgentTests/WorkspaceWindowControllerDeskCanvasTests/testTheDeskMenuBindsZoomToFitAndTheNineSessionDigits
```
Expected: `XCTUnwrap failed: expected non-nil value of type 'NSMenu'` on the `item(withTitle: "Desk")` line.

- [ ] **Step 3: Add the Desk menu**

In `AppDelegate.swift`, inside `ApplicationMenus.install()`, immediately after the `Panes` menu's `for index in 1...PaneGrid.maxPanes { … }` loop and before `let window = NSMenu(title: "Window")`:

```swift
        // The Desk destination's own commands — the spatial canvas, not one
        // terminal. A separate menu from "Session" above, which is deliberately
        // left as it is: its items (Interrupt, Kill Session, Reattach) are one
        // PTY's verbs, and the user-facing Session these commands move between
        // is a *group* of those. Renaming that menu would be churn in an
        // unrelated place; naming this one after the destination it belongs to
        // keeps the two apart where the user looks for them.
        let desk = NSMenu(title: "Desk")
        main.addItem(withSubmenu: desk)
        // ⌘0, the reset-the-zoom digit every canvas app uses. Free here: ⌘1…⌘9
        // are pane selection and stop at nine.
        desk.addItem(item("Zoom In", Selector(("zoomCanvasIn:")), "="))
        desk.addItem(item("Zoom Out", Selector(("zoomCanvasOut:")), "-"))
        desk.addItem(item("Zoom to Fit", Selector(("zoomDeskToFit:")), "0"))
        desk.addItem(item("Enter Session", Selector(("enterFocusedSession:"))))
        desk.addItem(.separator())
        // ⇧⌘[ / ⇧⌘], the system's own previous/next-tab chords, both unbound
        // here. The web build steps sessions with ⌃↑/⌃↓, which collide with
        // Mission Control and App Exposé.
        desk.addItem(item("Previous Session", Selector(("previousSession:")), "[", [.command, .shift]))
        desk.addItem(item("Next Session", Selector(("nextSession:")), "]", [.command, .shift]))
        desk.addItem(.separator())
        // ⌃1…⌃9, the `selectPane:` loop's shape with Control instead of
        // Command: no plain-Control chord but ⌃Space (Spotlight) is bound
        // anywhere in this app. macOS ships "Switch to Desktop N" on the same
        // chords once a second Desktop exists, and the system binding wins —
        // ⌥⌘1…⌥⌘9 is the fallback if that ever bites.
        for index in 1...9 {
            let selection = item("Session \(index)", Selector(("selectSession:")), "\(index)", [.control])
            selection.tag = index
            desk.addItem(selection)
        }
```

- [ ] **Step 4: Run the menu test**

Run:
```
xcodebuild test -project macos/OmniAgent.xcodeproj -scheme OmniAgent \
  -destination "platform=macOS,arch=$(uname -m)" CODE_SIGNING_ALLOWED=NO \
  ONLY_ACTIVE_ARCH=YES ARCHS="$(uname -m)" \
  -only-testing:OmniAgentTests/WorkspaceWindowControllerDeskCanvasTests/testTheDeskMenuBindsZoomToFitAndTheNineSessionDigits
```
Expected: PASS.

- [ ] **Step 5: Write the failing test for the actions**

Append to the same test file:

```swift
    // MARK: - Entering and stepping between sessions

    /// One entry path, four callers. The sidebar row, ⌃N, ⇧⌘], the toolbar
    /// button and the palette row all land in `enterDeskSession`, so the
    /// canvas-mode rule ("fly the camera there") and the normal-mode rule
    /// ("activate that grid") are decided in exactly one place. The sidebar's
    /// old body called `workspace.focusPane(first)` directly; the spec's §5
    /// forbids that in canvas mode — "focusPane must not swap the grid
    /// underneath the user".
    func testSteppingSessionsStopsAtBothEndsRatherThanWrapping() {
        let controller = makeEmptyController()
        defer { controller.close() }
        controller.sessionEnsurer = { _ in }
        controller.applyRestoredPanes(
            WorkspaceRestoration.plan(
                fromLayout: PersistedLayoutCodec.serialize([
                    PersistedTab(project: "alpha", engine: .shell, cwd: "/a", id: "sess-a", group: "grp-1"),
                    PersistedTab(project: "alpha", engine: .shell, cwd: "/a", id: "sess-b", group: "grp-2"),
                ])
            )
        )
        controller.selectWorkspace(id: "alpha", animated: false)
        controller.workspaceView.focusPane("sess-a")

        controller.nextSession(nil)
        XCTAssertEqual(controller.currentDeskSessionGroup(), "grp-2")

        // JS index semantics, ported: index >= count yields null, it does not
        // wrap. `sessions[-1]` would trap in Swift, so the guard is explicit.
        controller.nextSession(nil)
        XCTAssertEqual(controller.currentDeskSessionGroup(), "grp-2", "the last session is the end, not a wrap")

        controller.previousSession(nil)
        XCTAssertEqual(controller.currentDeskSessionGroup(), "grp-1")
        controller.previousSession(nil)
        XCTAssertEqual(controller.currentDeskSessionGroup(), "grp-1", "and the first is the other end")
    }

    /// ⌃3 with two sessions open must do nothing rather than reach past the
    /// end — the menu item exists for nine, the workspace rarely has nine.
    func testASessionDigitPastTheEndDoesNothing() {
        let controller = makeEmptyController()
        defer { controller.close() }
        controller.sessionEnsurer = { _ in }
        controller.applyRestoredPanes(
            WorkspaceRestoration.plan(
                fromLayout: PersistedLayoutCodec.serialize([
                    PersistedTab(project: "alpha", engine: .shell, cwd: "/a", id: "sess-a", group: "grp-1"),
                    PersistedTab(project: "alpha", engine: .shell, cwd: "/a", id: "sess-b", group: "grp-2"),
                ])
            )
        )
        controller.selectWorkspace(id: "alpha", animated: false)
        controller.workspaceView.focusPane("sess-a")

        let third = NSMenuItem(title: "Session 3", action: Selector(("selectSession:")), keyEquivalent: "3")
        third.tag = 3
        controller.selectSession(third)

        XCTAssertEqual(controller.currentDeskSessionGroup(), "grp-1", "nothing to reach, nothing moved")
        XCTAssertFalse(controller.validateMenuItem(third), "and the item says so")

        let first = NSMenuItem(title: "Session 1", action: Selector(("selectSession:")), keyEquivalent: "1")
        first.tag = 1
        XCTAssertTrue(controller.validateMenuItem(first))
    }
```

- [ ] **Step 6: Run it and watch it fail**

Run:
```
xcodebuild test -project macos/OmniAgent.xcodeproj -scheme OmniAgent \
  -destination "platform=macOS,arch=$(uname -m)" CODE_SIGNING_ALLOWED=NO \
  ONLY_ACTIVE_ARCH=YES ARCHS="$(uname -m)" \
  -only-testing:OmniAgentTests/WorkspaceWindowControllerDeskCanvasTests
```
Expected: compile failure — `value of type 'WorkspaceWindowController' has no member 'nextSession'`.

- [ ] **Step 7: Implement the commands**

In `WorkspaceWindowController.swift`, add a new section immediately **after** the `// MARK: - Command palette` section's `run(_:)` method (so the canvas commands sit beside the one place a palette row becomes a workspace command):

```swift
    // MARK: - Desk canvas commands

    /// The one way into a session, whichever surface asked.
    ///
    /// Below identity scale the canvas is what you are looking at, so entering
    /// is a camera flight and `PaneWorkspaceView.enterSession` owns the
    /// landing — including `carryCardToFocusedPane()`, without which the
    /// blinking cursor is left behind on a pane nobody can see. Off the Desk
    /// (or with the canvas not loaded) the old instant swap is still exactly
    /// right, so `activateGroup` stays the other arm rather than being
    /// replaced by it. Four callers — the sidebar row, ⌃1…⌃9, ⇧⌘[ / ⇧⌘], the
    /// toolbar button and the palette row — and one rule, so the surfaces can
    /// never drift apart the way `run(_:)`'s doc warns about.
    func enterDeskSession(_ group: String) {
        if workspace.canvasMode {
            workspace.enterSession(group)
        } else {
            workspace.activateGroup(group)
        }
        // The sidebar's current-session highlight is derived from the focused
        // pane, which the line above has just moved.
        reloadOutline()
    }

    /// Which session the Desk is about right now.
    ///
    /// Deliberately the *visible* session of the selected project first, and
    /// only then the one holding focus: selecting a workspace does not move
    /// focus, so focus routinely belongs to another project entirely, and
    /// "which session should this project show" is a different question from
    /// "which session has the cursor in it".
    func currentDeskSessionGroup() -> String? {
        let panes = workspace.allPaneIDs.compactMap { workspace.descriptor(for: $0) }
        if let project = selectedProjectID,
           let visible = SessionOutline.visibleSessionGroupID(
               panes,
               project: project,
               focusedPaneID: workspace.focusedPaneID
           ) {
            return visible
        }
        return SessionOutline.currentSessionGroupID(panes, focusedPaneID: workspace.focusedPaneID)
    }

    /// ⌘0 — the whole tree plus its margin, centred. The same operation
    /// exiting a session performs, aimed at `fitAll` rather than at a card.
    @objc func zoomDeskToFit(_ sender: Any?) {
        guard destination == .terminals else { return }
        workspace.exitToCanvas()
    }

    /// Enter whichever session the Desk is currently about. Named
    /// `enterFocusedSession:` rather than `enterSession:` on purpose: the
    /// latter selector would be ambiguous with
    /// `PaneWorkspaceView.enterSession(_:)` if that ever became `@objc`, and a
    /// responder chain that handed an `NSMenuItem` to a method expecting a
    /// group id crashes rather than misbehaving.
    @objc func enterFocusedSession(_ sender: Any?) {
        guard let group = currentDeskSessionGroup() else { return }
        enterDeskSession(group)
    }

    /// ⌃1…⌃9. The `selectPane:` precedent exactly — the digit rides on the
    /// menu item's tag — but scoped to the sessions of the *selected project*,
    /// because that is what the sidebar is showing rows for.
    @objc func selectSession(_ sender: Any?) {
        guard let index = (sender as? NSMenuItem)?.tag, index >= 1,
              let node = deskSession(at: index) else { return }
        enterDeskSession(node.id)
    }

    @objc func nextSession(_ sender: Any?) { stepSession(by: 1) }

    @objc func previousSession(_ sender: Any?) { stepSession(by: -1) }

    /// What `stepSession` would land on — split out so `validateMenuItem` greys
    /// the item out on exactly the condition the command refuses on.
    ///
    /// `adjacentSessionTab` answers with a *pane*, the web build's own shape,
    /// and both ends stop rather than wrap: index -1 and index >= count are
    /// both "nothing there", which is why nothing here is a modulo.
    private func stepTarget(by offset: Int) -> PaneDescriptor? {
        guard let project = selectedProjectID else { return nil }
        let panes = workspace.allPaneIDs.compactMap { workspace.descriptor(for: $0) }
        return SessionOutline.adjacentSessionTab(
            panes,
            project: project,
            focusedPaneID: workspace.focusedPaneID,
            offset: offset
        )
    }

    /// ⇧⌘] / ⇧⌘[.
    private func stepSession(by offset: Int) {
        guard let target = stepTarget(by: offset) else { return }
        enterDeskSession(target.group)
    }

    /// The 1-based Nth session of the selected project, or nil past the end.
    private func deskSession(at index: Int) -> SessionGroupNode? {
        guard let project = selectedProjectID else { return nil }
        let panes = workspace.allPaneIDs.compactMap { workspace.descriptor(for: $0) }
        let sessions = SessionOutline.group(panes, focusedPaneID: workspace.focusedPaneID)
            .first { $0.project == project }?
            .sessions ?? []
        guard sessions.indices.contains(index - 1) else { return nil }
        return sessions[index - 1]
    }
```

- [ ] **Step 8: Add the enablement arms**

In `validateMenuItem(_:)`, before the `default:` arm. `validateToolbarItem` synthesizes a probe `NSMenuItem` and calls straight into here, so this is the *only* enablement rule the toolbar buttons in Task 10c will need.

```swift
        case #selector(zoomDeskToFit(_:)):
            // The canvas only exists on the Desk.
            return destination == .terminals
        case #selector(enterFocusedSession(_:)):
            return destination == .terminals && currentDeskSessionGroup() != nil
        case #selector(nextSession(_:)):
            return destination == .terminals && stepTarget(by: 1) != nil
        case #selector(previousSession(_:)):
            return destination == .terminals && stepTarget(by: -1) != nil
        case #selector(selectSession(_:)):
            // Nine menu items, rarely nine sessions: the ones past the end are
            // greyed out rather than silently doing nothing.
            return destination == .terminals && deskSession(at: menuItem.tag) != nil
```

- [ ] **Step 9: Route the sidebar through the same path**

In `init`, in the `shellSidebar.onSelectSession` closure — today the only "switch to session" implementation in the app, and it must not become the second one:

```swift
        shellSidebar.onSelectSession = { [weak self] session in
            // The one entry path. This used to call `workspace.focusPane(first)`
            // directly, which in canvas mode would swap the grid out from under
            // a camera pointed somewhere else.
            self?.enterDeskSession(session.id)
        }
```

Note the pane-lifecycle dossier's gotcha: `groupOrder`/`groupIDs` only contain groups that have a grid, and `focusPane` hard-guards on the pane existing — so a session with no panes is not enterable. `SessionOutline.group` derives sessions from panes, so `deskSession(at:)` can never produce one either. Nothing to guard beyond what is here.

- [ ] **Step 10: Run the tests**

Run:
```
xcodebuild test -project macos/OmniAgent.xcodeproj -scheme OmniAgent \
  -destination "platform=macOS,arch=$(uname -m)" CODE_SIGNING_ALLOWED=NO \
  ONLY_ACTIVE_ARCH=YES ARCHS="$(uname -m)" \
  -only-testing:OmniAgentTests/WorkspaceWindowControllerDeskCanvasTests
```
Expected: PASS, 5 tests.

- [ ] **Step 11: Check `forwardedCommands` — and leave it closed**

Run:
```
grep -n "forwardedCommands" -A 14 macos/OmniAgent/PaneWorkspaceView.swift
```
Expected: the nine `#selector(PaneWorkspaceView.…)` entries, unchanged. **No edit.** The spec says *"`PaneFocusOverlayView.forwardedCommands` is a deliberately closed set of nine selectors. Any canvas command must be added to it explicitly"* — that set forwards to `commandTarget`, a `PaneWorkspaceView`, and exists because *"`PaneWorkspaceView` is not on [the responder chain]"* while a focus card is up. Every command added in this task is implemented on `WorkspaceWindowController`, which AppKit places in the chain after the window, so it is reachable with a card up already. The set's own comment is the reason not to widen it speculatively: *"Forwarding whatever the workspace merely responds to would also forward the selectors it inherits from `NSView` — `print:` is the classic."* If a later task moves any of these five actions onto `PaneWorkspaceView`, that task adds the selector here.

- [ ] **Step 12: Commit**

```
stat -f "%Sm %N" macos/OmniAgent/AppDelegate.swift macos/OmniAgent/WorkspaceWindowController.swift macos/OmniAgentTests/WorkspaceWindowControllerDeskCanvasTests.swift
git add macos/OmniAgent/AppDelegate.swift macos/OmniAgent/WorkspaceWindowController.swift macos/OmniAgentTests/WorkspaceWindowControllerDeskCanvasTests.swift
git commit -m "feat(macos): a Desk menu — zoom to fit on Cmd-0, sessions on Ctrl-1..9

Ctrl-Space is the only plain-Control chord this app binds and Cmd-1..9 stop
at nine, so Ctrl-1..9 and Cmd-0 were both free. Stepping is Shift-Cmd-[ and
Shift-Cmd-] through SessionOutline.adjacentSessionTab, which stops at both
ends rather than wrapping — JS index semantics ported, with the explicit
guard Swift needs because sessions[-1] traps.

Every surface now enters a session through one method: canvas mode flies the
camera, normal mode activates the grid, and the sidebar row no longer calls
focusPane behind the camera's back. The pre-existing top-level Session menu is
left alone — its items are one PTY's verbs, a different thing entirely.

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>
Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 10c: Toolbar items for Zoom to Fit and Enter Session

Follow the registration pattern exactly: an identifier constant in `enum ToolbarItem`, a slot in `toolbarDefaultItemIdentifiers`, an arm in `toolbar(_:itemForItemIdentifier:willBeInsertedIntoToolbar:)` built by the private `item(_:_:_:_:)` factory. `toolbarAllowedItemIdentifiers` is derived and needs nothing. Enablement comes free — `validateToolbarItem` builds a probe `NSMenuItem` and calls `validateMenuItem`, whose arms Task 10b added.

Both items are plain bordered push buttons, which matters: `WorkspaceWindowControllerTests` loops every non-`NS` default identifier and asserts `XCTAssertNil(item.target)`, `XCTAssertNotNil(item.action)`, `XCTAssertNotNil(item.image)`. An `NSMenuToolbarItem` session popup would fail that loop; these two do not.

**Files:**
- Modify: `macos/OmniAgent/WorkspaceToolbar.swift` (in `enum ToolbarItem`, `installToolbar(on:)`, `toolbarDefaultItemIdentifiers(_:)`, `toolbar(_:itemForItemIdentifier:willBeInsertedIntoToolbar:)`)
- Test: `macos/OmniAgentTests/WorkspaceWindowControllerTests.swift` (in `testTheToolbarCarriesOnlyCommandsThatAlsoExistElsewhereAndTargetsTheResponderChain`)

**Interfaces:**
- Consumes: `@objc func zoomDeskToFit(_ sender: Any?)`, `@objc func enterFocusedSession(_ sender: Any?)` (Task 10b)
- Produces:
  - `static let zoomToFit = NSToolbarItem.Identifier("digital.bruno.omniagent.toolbar.zoom-to-fit")`
  - `static let enterSession = NSToolbarItem.Identifier("digital.bruno.omniagent.toolbar.enter-session")`

- [ ] **Step 1: Write the failing test**

In `macos/OmniAgentTests/WorkspaceWindowControllerTests.swift`, in `testTheToolbarCarriesOnlyCommandsThatAlsoExistElsewhereAndTargetsTheResponderChain`, replace the expected identifier array. **Re-read the method first** — the file is under concurrent edit.

```swift
        XCTAssertEqual(
            identifiers,
            [
                WorkspaceWindowController.ToolbarItem.sidebar,
                .sidebarTrackingSeparator,
                WorkspaceWindowController.ToolbarItem.newPane,
                WorkspaceWindowController.ToolbarItem.newBrowser,
                WorkspaceWindowController.ToolbarItem.newEditor,
                WorkspaceWindowController.ToolbarItem.closePane,
                .flexibleSpace,
                WorkspaceWindowController.ToolbarItem.zoomToFit,
                WorkspaceWindowController.ToolbarItem.enterSession,
                WorkspaceWindowController.ToolbarItem.palette,
            ]
        )
```

- [ ] **Step 2: Run it and watch it fail**

Run:
```
xcodebuild test -project macos/OmniAgent.xcodeproj -scheme OmniAgent \
  -destination "platform=macOS,arch=$(uname -m)" CODE_SIGNING_ALLOWED=NO \
  ONLY_ACTIVE_ARCH=YES ARCHS="$(uname -m)" \
  -only-testing:OmniAgentTests/WorkspaceWindowControllerTests/testTheToolbarCarriesOnlyCommandsThatAlsoExistElsewhereAndTargetsTheResponderChain
```
Expected: compile failure — `type 'WorkspaceWindowController.ToolbarItem' has no member 'zoomToFit'`.

- [ ] **Step 3: Implement**

In `WorkspaceToolbar.swift`, in `enum ToolbarItem`, after `closePane`:
```swift
        static let zoomToFit = NSToolbarItem.Identifier("digital.bruno.omniagent.toolbar.zoom-to-fit")
        static let enterSession = NSToolbarItem.Identifier("digital.bruno.omniagent.toolbar.enter-session")
```

In `toolbarDefaultItemIdentifiers(_:)`, between `.flexibleSpace` and `ToolbarItem.palette`:
```swift
            ToolbarItem.zoomToFit,
            ToolbarItem.enterSession,
```

In `toolbar(_:itemForItemIdentifier:willBeInsertedIntoToolbar:)`, before the `case ToolbarItem.palette:` arm:
```swift
        case ToolbarItem.zoomToFit:
            return item(identifier, "Zoom to Fit", "arrow.down.right.and.arrow.up.left", #selector(zoomDeskToFit(_:)))
        case ToolbarItem.enterSession:
            return item(identifier, "Enter Session", "arrow.up.left.and.arrow.down.right", #selector(enterFocusedSession(_:)))
```

Update the type's header comment, which counts the items:
```swift
/// The window's toolbar. Six items, each one a command that already exists
/// somewhere else (a menu item, a palette row) — a toolbar button that is the
/// only way to reach something would be a fifth place for the same behaviour
/// to drift.
```

- [ ] **Step 4: Bump the toolbar's autosave identity**

`installToolbar(on:)` sets `allowsUserCustomization = true` and `autosavesConfiguration = true`. Once a user's configuration has been saved under a toolbar identifier, **a newly added default identifier does not appear in their toolbar** — the two new buttons would ship invisible on every existing install, including Bruno's. Bumping the identifier resets the saved configuration back to the defaults, which is the intent.

```swift
    func installToolbar(on window: NSWindow) {
        // `.canvas` rather than the bare identifier this used to carry:
        // `autosavesConfiguration` means AppKit remembers the item set under
        // this name, and an already-saved configuration silently swallows any
        // *newly added* default item. Adding Zoom to Fit and Enter Session
        // under the old name would have shipped two buttons nobody could see.
        // Bumping resets the saved layout to the defaults, which is what is
        // wanted; it costs anyone who had dragged their own arrangement.
        let toolbar = NSToolbar(identifier: "digital.bruno.omniagent.workspace.canvas")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        window.toolbar = toolbar
        window.toolbarStyle = .unified
    }
```

- [ ] **Step 5: Run the test**

Run:
```
xcodebuild test -project macos/OmniAgent.xcodeproj -scheme OmniAgent \
  -destination "platform=macOS,arch=$(uname -m)" CODE_SIGNING_ALLOWED=NO \
  ONLY_ACTIVE_ARCH=YES ARCHS="$(uname -m)" \
  -only-testing:OmniAgentTests/WorkspaceWindowControllerTests
```
Expected: PASS — including the loop asserting every new item has `target == nil`, a non-nil `action` and a non-nil `image`, and `testTheToolbarSharesTheMenusEnablementRuleRatherThanAddingASecondOne`.

- [ ] **Step 6: Commit**

```
stat -f "%Sm %N" macos/OmniAgent/WorkspaceToolbar.swift macos/OmniAgentTests/WorkspaceWindowControllerTests.swift
git add macos/OmniAgent/WorkspaceToolbar.swift macos/OmniAgentTests/WorkspaceWindowControllerTests.swift
git commit -m "feat(macos): Zoom to Fit and Enter Session on the toolbar

Two plain bordered buttons through the existing item() factory, so they
target nil and travel the responder chain, and validateToolbarItem's probe
picks up the validateMenuItem arms the Desk menu already added — one
enablement rule, not a second one.

The toolbar identifier is bumped with them: autosavesConfiguration means an
already-saved configuration swallows newly added default items, so under the
old name both buttons would have shipped invisible on every existing install.

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>
Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 10d: Palette rows for Zoom to fit and Enter session

Registering a palette command is four edits and no closures: a `PaletteAction` case, rows appended in `CommandPaletteModel.build`, an arm in `WorkspaceWindowController.run(_:)`, and — already done in Task 10b — a matching menu item.

**Section ordering is load-bearing.** `PaletteSection`'s doc: *"rows are emitted in section order, so a section is just a run of consecutive rows and nothing has to sort or re-index after filtering"*, and `testRowsComeOutInSectionOrderSoAGroupIsJustARunOfRows` asserts exactly that. The per-session rows are `.terminals`, so they must be emitted **immediately before** `commands += paneRows[.terminal] ?? []` — appending them after the editor rows would split the `.terminals` run in two.

**Files:**
- Modify: `macos/OmniAgent/CommandPalette.swift` (in `enum PaletteAction`; in `CommandPaletteModel.build`)
- Modify: `macos/OmniAgent/WorkspaceWindowController.swift` (in `run(_:)`)
- Test: `macos/OmniAgentTests/CommandPaletteTests.swift`

**Interfaces:**
- Consumes: `func enterDeskSession(_ group: String)`, `@objc func zoomDeskToFit(_ sender: Any?)` (Task 10b)
- Consumes: `static func group(_ panes: [PaneDescriptor], focusedPaneID: String?) -> [ProjectSessionsNode]`, `static func projectLabel(_ project: String, labels: [String: String] = [:]) -> String` (existing)
- Produces:
  - `case zoomDeskToFit` on `PaletteAction`
  - `case enterSession(group: String)` on `PaletteAction`

- [ ] **Step 1: Write the failing test**

Append to `macos/OmniAgentTests/CommandPaletteTests.swift`, under `// MARK: - the list`:

```swift
    /// The canvas's two rows. "Enter" is per session and lives in the
    /// Terminals section beside the panes it contains — emitted before the
    /// pane rows so the section stays one consecutive run, which is the only
    /// thing the table's heading logic relies on.
    func testTheCanvasOffersOneEnterRowPerSessionAndOneZoomToFit() throws {
        let commands = CommandPaletteModel.build(
            panes: [
                pane("a", project: "alpha", group: "g1", groupLabel: "Build"),
                pane("b", project: "alpha", group: "g2"),
                pane("c", project: "beta", group: "g3"),
            ],
            paneOrder: ["a", "b", "c"],
            focusedPaneID: nil,
            unreadNotifications: 0
        )

        let enters = commands.filter { if case .enterSession = $0.action { return true } else { return false } }
        XCTAssertEqual(enters.map(\.id), ["enter:g1", "enter:g2", "enter:g3"])
        XCTAssertEqual(enters.map(\.title), [
            "Enter Build — alpha",
            "Enter Session 2 — alpha",
            "Enter Session 1 — beta",
        ])
        XCTAssertEqual(enters.map(\.detail), ["⌃1", "⌃2", "⌃1"], "the digit is per project, like ⌃1…⌃9 is")
        XCTAssertEqual(enters.map(\.section), [.terminals, .terminals, .terminals])
        XCTAssertEqual(enters.first?.action, .enterSession(group: "g1"))

        let fit = try XCTUnwrap(commands.first { $0.id == "zoom-to-fit" })
        XCTAssertEqual(fit.detail, "⌘0")
        XCTAssertEqual(fit.action, .zoomDeskToFit)
        XCTAssertEqual(fit.section, .actions)
    }
```

- [ ] **Step 2: Run it and watch it fail**

Run:
```
xcodebuild test -project macos/OmniAgent.xcodeproj -scheme OmniAgent \
  -destination "platform=macOS,arch=$(uname -m)" CODE_SIGNING_ALLOWED=NO \
  ONLY_ACTIVE_ARCH=YES ARCHS="$(uname -m)" \
  -only-testing:OmniAgentTests/CommandPaletteTests/testTheCanvasOffersOneEnterRowPerSessionAndOneZoomToFit
```
Expected: compile failure — `type 'PaletteAction' has no member 'enterSession'`.

- [ ] **Step 3: Add the actions**

In `CommandPalette.swift`, in `enum PaletteAction`, after `case newSession`:

```swift
    /// Fly the Desk's camera onto one session's card. The palette twin of
    /// ⌃1…⌃9 and of the sidebar's session row — all three land in
    /// `WorkspaceWindowController.enterDeskSession`.
    case enterSession(group: String)
    /// ⌘0 — the whole organigram, centred.
    case zoomDeskToFit
```

- [ ] **Step 4: Emit the rows**

In `CommandPaletteModel.build`, immediately **before** `commands += paneRows[.terminal] ?? []`:

```swift
        // One row per session, before the pane rows and in the same section:
        // a section is a run of consecutive rows, so these cannot be appended
        // after the browser and editor rows without splitting Terminals in two.
        for project in tree {
            for (index, session) in project.sessions.enumerated() {
                commands.append(
                    PaletteCommand(
                        id: "enter:\(session.id)",
                        title: "Enter \(session.label) — \(SessionOutline.projectLabel(project.project, labels: projectLabels))",
                        // Hand-typed, like every other key hint in this file:
                        // nothing links a row to the NSMenuItem that defines
                        // its chord. ⌃1…⌃9 is per project, and there is no
                        // single keystroke past nine.
                        detail: index < 9 ? "⌃\(index + 1)" : nil,
                        action: .enterSession(group: session.id),
                        keywords: session.cwd,
                        section: .terminals
                    )
                )
            }
        }
```

and immediately **before** the existing `toggle-sidebar` append:

```swift
        commands.append(
            PaletteCommand(id: "zoom-to-fit", title: "Zoom to fit", detail: "⌘0", action: .zoomDeskToFit)
        )
```

- [ ] **Step 5: Add the run arms**

In `WorkspaceWindowController.run(_:)` — the switch is exhaustive, so this is required to compile — beside `case .newSession:`:

```swift
        case let .enterSession(group):
            enterDeskSession(group)
        case .zoomDeskToFit:
            zoomDeskToFit(nil)
```

- [ ] **Step 6: Update the four assertions that pin exact row lists**

**Re-read each one before editing** — `CommandPaletteTests.swift` was modified by a concurrent session at 20:43 on 2026-08-18 and these arrays may already differ from what is written here.

In `testFocusedPaneCommandsAppearOnlyWhenSomethingIsFocused`:
```swift
        XCTAssertEqual(
            unfocused.map(\.id),
            ["enter:g1", "focus:a", "new-pane", "new-browser", "new-editor", "new-session", "zoom-to-fit", "toggle-sidebar"]
        )
```
```swift
        XCTAssertEqual(
            focused.map(\.id),
            [
                "enter:g1", "focus:a", "new-pane", "new-browser", "new-editor", "new-session",
                "close-pane", "interrupt", "reattach", "zoom-to-fit", "toggle-sidebar",
            ]
        )
```
In `testAnEmptyWorkspaceStillOffersTheCommandsThatDoNotNeedAPane` (no panes, so no session rows):
```swift
            ["new-pane", "new-browser", "new-editor", "new-session", "zoom-to-fit", "toggle-sidebar"]
```
In `testRowsComeOutInSectionOrderSoAGroupIsJustARunOfRows`:
```swift
        XCTAssertEqual(
            model.matches.filter { $0.section == .terminals }.map(\.id),
            ["enter:g1", "enter:g2", "focus:t1", "focus:t2"]
        )
```
The `runs` assertion in that same test — `[.terminals, .browsers, .files, .actions]` — must stay unchanged. If it fails, the session rows were emitted in the wrong place.

- [ ] **Step 7: Run the tests**

Run:
```
xcodebuild test -project macos/OmniAgent.xcodeproj -scheme OmniAgent \
  -destination "platform=macOS,arch=$(uname -m)" CODE_SIGNING_ALLOWED=NO \
  ONLY_ACTIVE_ARCH=YES ARCHS="$(uname -m)" \
  -only-testing:OmniAgentTests/CommandPaletteTests
```
Expected: PASS, whole suite.

- [ ] **Step 8: Commit**

```
stat -f "%Sm %N" macos/OmniAgent/CommandPalette.swift macos/OmniAgent/WorkspaceWindowController.swift macos/OmniAgentTests/CommandPaletteTests.swift
git add macos/OmniAgent/CommandPalette.swift macos/OmniAgent/WorkspaceWindowController.swift macos/OmniAgentTests/CommandPaletteTests.swift
git commit -m "feat(macos): palette rows for entering a session and zooming to fit

One Enter row per session, emitted from the same SessionOutline tree the
pane rows come from and immediately before them, so the Terminals section
stays one consecutive run — the only thing the table's heading logic relies
on. Zoom to fit joins the actions beside Toggle sidebar.

Both run through the same methods the Desk menu items and the toolbar
buttons call, so the four surfaces cannot drift.

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>
Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 10e: `desk_canvas_native` — read on connect, write on change

Its own settings row, following the `browser_panes_native` / `editor_panes_native` recipe exactly: two flags, a one-shot dispatched gate that re-arms on failure, and a **completed** gate that alone opens writes. `SettingsKeys.swift`'s existing doc says why a separate row rather than a field on `layout`: *"the web codec drops unknown-engine tabs and strips unknown fields on rewrite."*

The gotcha to honour, from `write(_:to:)`'s own comment: *"a shell that repaints its OSC title on every prompt would otherwise write an identical `layout` row several times a second, against the database the web app is also reading."* Write suppression compares values, and a moving camera produces a different value every frame — so suppression cannot help here and the write must be debounced instead.

**Files:**
- Modify: `macos/OmniAgent/PaneWorkspaceView.swift` (in the class body, beside the `camera` property Task 6 added — stored properties cannot live in an extension)
- Modify: `macos/OmniAgent/WorkspaceWindowController.swift` (state declarations beside `editorPanesReadDispatched`; in `init` beside the other `workspace.on…` wiring; in `applyRestoredPanes`; a new persistence section beside `persistEditorPanes`)
- Modify: `macos/OmniAgent/SettingsKeys.swift` (only if Task 4 did not add the key — see Step 1)
- Test: `macos/OmniAgentTests/WorkspaceWindowControllerDeskCanvasTests.swift`

**Interfaces:**
- Consumes: `struct DeskCanvasState: Equatable { var pinned: [String: CGPoint]; var camera: DeskCamera? }` (Task 4)
- Consumes: `static func serialize(_ state: DeskCanvasState) -> String` / `static func deserialize(_ json: String) -> DeskCanvasState` on `DeskCanvasCodec` (Task 4)
- Consumes: `struct DeskCamera` with `var scale: CGFloat`, `var origin: CGPoint`, `var isIdentity: Bool` (Task 4)
- Consumes: `static let deskCanvas = "desk_canvas_native"` on `SettingsKey` (Task 4 — see Step 1)
- Consumes: `var camera: DeskCamera { get set }`, `func exitToCanvas()` on `PaneWorkspaceView` (Task 6)
- Consumes: `private func write(_ value: String, to key: String)`, `var settingsWriter: ((String, String) -> Void)?` (existing)
- Produces:
  - `var canvasPins: [String: CGPoint]` — `PaneWorkspaceView` (stored, `didSet` relayouts and raises `onDeskCanvasChanged`)
  - `var onDeskCanvasChanged: (() -> Void)?` — `PaneWorkspaceView`
  - `func applyRestoredDeskCanvas(_ state: DeskCanvasState)` — `WorkspaceWindowController`
  - `private func restoreDeskCanvasIfNeeded()` — `WorkspaceWindowController`
  - `private func persistDeskCanvas()` — `WorkspaceWindowController`
  - `private var deskCanvasReadDispatched = false`, `private var deskCanvasReadCompleted = false`, `private var deskCanvasWriteToken = 0` — `WorkspaceWindowController`
  - `private static let deskCanvasWriteDelay: TimeInterval = 0.25` — `WorkspaceWindowController`

- [ ] **Step 1: Confirm the settings key exists**

Run:
```
grep -n "deskCanvas\|desk_canvas_native" macos/OmniAgent/SettingsKeys.swift
```
Expected: `static let deskCanvas = "desk_canvas_native"`, added by Task 4 alongside `DeskCanvasCodec`. If it prints nothing, add it as the last member of `enum SettingsKey`, immediately after `editorPanes`:

```swift
    /// Native-only — `browserPanes`'s reasoning applied to the Desk canvas:
    /// the web build has no canvas and its codec strips fields it does not
    /// know on the next `layout` rewrite. One JSON object,
    /// `{"pinned":{"<node id>":{"x":…,"y":…}},"camera":{"scale":…,"origin":…}}`
    /// — see `DeskCanvasCodec`. Unpinned nodes are recomputed every launch and
    /// are deliberately not stored. No TypeScript twin, by design.
    static let deskCanvas = "desk_canvas_native"
```

- [ ] **Step 2: Write the failing test**

Append to `WorkspaceWindowControllerDeskCanvasTests.swift`:

```swift
    // MARK: - desk_canvas_native

    /// The write gate is the *completed* flag, not the dispatched one. The read
    /// is asynchronous, and a node dragged while it is in flight would
    /// otherwise persist an empty pinned map over a row nothing has read yet —
    /// the exact reasoning `layoutReadCompleted`'s doc records for the shared
    /// layout row.
    func testTheCanvasRowIsNotWrittenBeforeItHasBeenRead() {
        let controller = makeEmptyController()
        defer { controller.close() }
        var writes: [(String, String)] = []
        controller.settingsWriter = { writes.append(($0, $1)) }

        controller.workspaceView.canvasPins["grp-1"] = CGPoint(x: 40, y: 60)
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))

        XCTAssertTrue(
            writes.filter { $0.0 == SettingsKey.deskCanvas }.isEmpty,
            "the row has not been read, so nothing may be written over it"
        )
    }

    /// Restore hands the view its pinned nodes and its camera, and from then on
    /// a change writes the row back. Debounced: a camera in flight changes
    /// every frame, so `write`'s unchanged-value suppression cannot help and
    /// only a settle can.
    func testPinningANodeWritesTheCanvasRowOnceTheRowHasBeenRead() throws {
        let controller = makeEmptyController()
        defer { controller.close() }
        var writes: [(String, String)] = []
        controller.settingsWriter = { writes.append(($0, $1)) }

        controller.applyRestoredDeskCanvas(
            DeskCanvasState(
                pinned: ["grp-1": CGPoint(x: 10, y: 20)],
                camera: DeskCamera(scale: 0.5, origin: CGPoint(x: 5, y: 7))
            )
        )
        XCTAssertEqual(controller.workspaceView.canvasPins["grp-1"], CGPoint(x: 10, y: 20))
        XCTAssertEqual(controller.workspaceView.camera.scale, 0.5, accuracy: 0.0001)

        controller.workspaceView.canvasPins["grp-2"] = CGPoint(x: 80, y: 90)
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))

        let row = try XCTUnwrap(writes.last { $0.0 == SettingsKey.deskCanvas })
        let stored = DeskCanvasCodec.deserialize(row.1)
        XCTAssertEqual(stored.pinned["grp-1"], CGPoint(x: 10, y: 20))
        XCTAssertEqual(stored.pinned["grp-2"], CGPoint(x: 80, y: 90))
    }

    /// Five changes in a row are one write, not five. A drag and a camera
    /// flight both produce a stream of them against a database the web app is
    /// also reading.
    func testAStreamOfCanvasChangesCoalescesIntoOneWrite() throws {
        let controller = makeEmptyController()
        defer { controller.close() }
        var writes: [(String, String)] = []
        controller.settingsWriter = { writes.append(($0, $1)) }
        controller.applyRestoredDeskCanvas(DeskCanvasState(pinned: [:], camera: nil))

        for step in 1...5 {
            controller.workspaceView.canvasPins["grp-1"] = CGPoint(x: CGFloat(step) * 10, y: 0)
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))

        let rows = writes.filter { $0.0 == SettingsKey.deskCanvas }
        XCTAssertEqual(rows.count, 1)
        let stored = DeskCanvasCodec.deserialize(try XCTUnwrap(rows.last).1)
        XCTAssertEqual(stored.pinned["grp-1"], CGPoint(x: 50, y: 0), "the last position, once")
    }

    /// A row that could not be *read* is not an empty row. The read re-arms for
    /// the next reconnect and the write gate stays shut, so a transient daemon
    /// error at launch cannot erase where the user put their nodes.
    func testAFailedCanvasReadReArmsWithoutOpeningTheWriteGate() {
        let controller = makeEmptyController()
        defer { controller.close() }
        var writes: [(String, String)] = []
        controller.settingsWriter = { writes.append(($0, $1)) }

        controller.workspaceView.canvasPins["grp-1"] = CGPoint(x: 1, y: 2)
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))

        XCTAssertTrue(writes.filter { $0.0 == SettingsKey.deskCanvas }.isEmpty)
    }
```

- [ ] **Step 3: Run it and watch it fail**

Run:
```
xcodebuild test -project macos/OmniAgent.xcodeproj -scheme OmniAgent \
  -destination "platform=macOS,arch=$(uname -m)" CODE_SIGNING_ALLOWED=NO \
  ONLY_ACTIVE_ARCH=YES ARCHS="$(uname -m)" \
  -only-testing:OmniAgentTests/WorkspaceWindowControllerDeskCanvasTests
```
Expected: compile failure — `value of type 'PaneWorkspaceView' has no member 'canvasPins'` and `value of type 'WorkspaceWindowController' has no member 'applyRestoredDeskCanvas'`.

- [ ] **Step 4: Add the view's two hooks**

Task 8 already declares `canvasPins` (Global Constraints fixes the name), so this step adds only the `onDeskCanvasChanged` callback and hangs it off that property's existing `didSet`. In `PaneWorkspaceView`'s **class body** (not an extension — stored properties cannot live in one), immediately after the `camera` property Task 6 added:

```swift
    /// Node id -> position in the canvas's own flipped coordinate space, for
    /// every node the user has dragged.
    ///
    /// A pinned node is excluded from the tidy tree's packing and placed here
    /// instead; the unpinned remainder closes the gap around it. Absolute, not
    /// an offset from an auto slot, so a node stays where it was put even when
    /// its siblings come and go. Unpinned nodes are recomputed every launch and
    /// are deliberately not stored anywhere.
    var canvasPins: [String: CGPoint] = [:] {
        didSet {
            guard canvasPins != oldValue else { return }
            if canvasMode { updateLayout() }
            onDeskCanvasChanged?()
        }
    }

    /// Raised when the canvas's persistable state settles — a drag released, a
    /// camera flight landed. Deliberately not per frame: the controller writes
    /// a settings row from this, against the database the web app also reads.
    var onDeskCanvasChanged: (() -> Void)?
```

Whatever Task 6/9 does at the end of a camera flight and Task 8 at the end of a drag must call `onDeskCanvasChanged?()` — on settle, never per frame.

- [ ] **Step 5: Add the controller's gates and wiring**

In `WorkspaceWindowController.swift`, beside `editorPanesReadDispatched` / `editorPanesReadCompleted`:

```swift
    /// The `desk_canvas_native` row's two flags — the browser and editor pairs
    /// above, for the third native-only row. Separate again for the same
    /// reason: the web build rewrites the shared `layout` row and drops fields
    /// it does not know about, and it knows nothing about a canvas.
    private var deskCanvasReadDispatched = false
    private var deskCanvasReadCompleted = false
    /// Coalesces a burst of canvas changes into one write — see
    /// `persistDeskCanvas`.
    private var deskCanvasWriteToken = 0
```

In `init`, beside the other `workspace.on…` assignments (next to `workspace.onPanesChanged`):

```swift
        workspace.onDeskCanvasChanged = { [weak self] in self?.persistDeskCanvas() }
```

In `applyRestoredPanes`, on the line after `restoreEditorPanesIfNeeded()`:

```swift
        restoreDeskCanvasIfNeeded()
```

A sibling of the browser and editor reads rather than chained behind them, deliberately: each of the three is independently gated and independently re-armed, so a browser read that fails must not take the canvas down with it.

- [ ] **Step 6: Add restore and persist**

In `WorkspaceWindowController.swift`, after `persistEditorPanes()`:

```swift
    // MARK: - Desk canvas persistence

    /// Reads the native-only `desk_canvas_native` row once, alongside the
    /// browser and editor rows — `restoreBrowserPanesIfNeeded`'s shape and its
    /// reasons: a row that could not be read is not an empty one, so the write
    /// gate stays shut and the read re-arms for the next reconnect.
    private func restoreDeskCanvasIfNeeded() {
        guard !deskCanvasReadDispatched else { return }
        deskCanvasReadDispatched = true
        connection.getSetting(key: SettingsKey.deskCanvas) { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(raw):
                // The codec takes a non-optional String, unlike its browser and
                // editor siblings; an absent row is an empty document, which
                // `deserialize` answers with an empty state.
                applyRestoredDeskCanvas(DeskCanvasCodec.deserialize(raw ?? ""))
            case .failure:
                deskCanvasReadDispatched = false
            }
        }
    }

    /// Hands the canvas its pinned nodes and the camera it was left at. Split
    /// out from the read so a state can be applied in a test without a socket,
    /// exactly as `applyRestoredBrowserPanes` is.
    ///
    /// A first launch has no stored camera, and that is what makes DESK open on
    /// the whole organigram: `exitToCanvas` is `fitAll`. Afterwards the camera
    /// is restored as it was, including an identity camera parked over one
    /// session's card — which is simply "you were inside that session", the
    /// same state the canvas is in after entering one.
    func applyRestoredDeskCanvas(_ state: DeskCanvasState) {
        deskCanvasReadCompleted = true
        workspace.canvasPins = state.pinned
        if let camera = state.camera {
            workspace.camera = camera
        } else {
            workspace.exitToCanvas()
        }
    }

    /// A burst of canvas changes is one write.
    ///
    /// `write(_:to:)` suppresses an unchanged value, which is what protects the
    /// `layout` row from a shell repainting its OSC title — but a camera in
    /// flight produces a *different* value every frame, so suppression cannot
    /// help here and only a settle can. Scheduled with `asyncAfter` behind a
    /// token, the same shape `finishZoomTransition` uses and for the same
    /// reason: a stale timer is harmless because it refuses any token but the
    /// current one.
    private static let deskCanvasWriteDelay: TimeInterval = 0.25

    private func persistDeskCanvas() {
        guard deskCanvasReadCompleted else { return }
        deskCanvasWriteToken += 1
        let token = deskCanvasWriteToken
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.deskCanvasWriteDelay) { [weak self] in
            guard let self, token == deskCanvasWriteToken else { return }
            write(
                DeskCanvasCodec.serialize(
                    DeskCanvasState(pinned: workspace.canvasPins, camera: workspace.camera)
                ),
                to: SettingsKey.deskCanvas
            )
        }
    }
```

- [ ] **Step 7: Run the tests**

Run:
```
xcodebuild test -project macos/OmniAgent.xcodeproj -scheme OmniAgent \
  -destination "platform=macOS,arch=$(uname -m)" CODE_SIGNING_ALLOWED=NO \
  ONLY_ACTIVE_ARCH=YES ARCHS="$(uname -m)" \
  -only-testing:OmniAgentTests/WorkspaceWindowControllerDeskCanvasTests
```
Expected: PASS, 9 tests.

- [ ] **Step 8: Commit**

```
stat -f "%Sm %N" macos/OmniAgent/PaneWorkspaceView.swift macos/OmniAgent/WorkspaceWindowController.swift macos/OmniAgent/SettingsKeys.swift macos/OmniAgentTests/WorkspaceWindowControllerDeskCanvasTests.swift
git add macos/OmniAgent/PaneWorkspaceView.swift macos/OmniAgent/WorkspaceWindowController.swift macos/OmniAgentTests/WorkspaceWindowControllerDeskCanvasTests.swift
git commit -m "feat(macos): the canvas remembers its pinned nodes and its camera

desk_canvas_native, its own row for browser_panes_native's reason: the web
codec strips fields it does not know on the next layout rewrite, and it knows
nothing about a canvas. Same two flags as every other native row, with the
*completed* one as the write gate — a node dragged while the read is in
flight must not persist an empty map over a row nothing has read yet.

Writes are debounced rather than value-suppressed: a camera in flight changes
every frame, so write()'s unchanged-value guard cannot help. asyncAfter behind
a token, the shape finishZoomTransition already uses.

No stored camera is what makes the first DESK selection open on the whole
organigram — exitToCanvas is fitAll.

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>
Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 10f: Whole suite, then a packaged build and install

The standing repository rule: *"changes that affect releases should end with a packaged app build."* The test run is evidence, not the deliverable — the app is.

**Files:** none. This task only runs things.

**Interfaces:**
- Consumes: everything Tasks 1–10e produced.
- Produces: nothing.

- [ ] **Step 1: Run the whole native suite**

Run:
```
./macos/build.sh test
```
Expected: `** TEST SUCCEEDED **`. The baseline at planning time was **708 passed / 0 failed / 0 skipped** (2026-08-18 20:24, 59 s). This plan's tasks add to that; the number to check is that failures are zero and that the count went **up**, not that it hit a specific value — other sessions are landing tests in this tree concurrently.

If a failure is in a suite none of these tasks touched, check `git status` and file mtimes before assuming it is yours.

- [ ] **Step 2: Read back the exact counts**

Run:
```
xcrun xcresulttool get test-results summary --path \
  "$(ls -td ~/Library/Developer/Xcode/DerivedData/OmniAgent-*/Logs/Test/*.xcresult | head -1)"
```
Expected: `"failedTests" : 0`, `"result" : "Passed"`. Record `passedTests`.

- [ ] **Step 3: Build, sign, package and install the real app**

Run:
```
./scripts/rebuild-app.sh --no-notarize
```
Expected: the pipeline runs in its documented order — build → sign app → DMG → sign DMG → install to `/Applications` — and ends with the app installed.

Three things to know before running it:

1. **It stops the PTY daemon with the app, by design, and that ends every live terminal session.** From the script's own header: *"The PTY daemon is restarted along with the app. It is a binary inside the bundle being replaced, so leaving it running means the install silently keeps the old one… This ends live terminal sessions; `--keep-daemon` opts out."* Do not pass `--keep-daemon` here: Task 10e changed nothing daemon-side, but the app is what changed and a stale daemon has bitten this repo before. Save anything running in a terminal pane first.
2. **`--no-notarize` is the fast local loop and is correct here.** Notarization is two multi-minute round trips to Apple and buys nothing for a `ditto` install, which carries no quarantine flag. Drop the flag (and set `OMNIAGENT_NOTARY_PROFILE`) only when the DMG is going to someone else.
3. **One rebuild at a time.** The script takes a `macos/.build/rebuild.lock` directory because two concurrent `xcodebuild`s writing the same Release product corrupted a `codesign` on 2026-08-18 and put an unsigned app into `/Applications`. If it refuses with "another rebuild is already running", wait — do not `rmdir` the lock unless nothing is actually building.

- [ ] **Step 4: Verify the shortcuts against the real machine**

Launch `/Applications/OmniAgent.app` and check, by hand:

- The **Desk** menu exists in the menu bar, separate from **Session**, and its items are enabled while the Desk destination is selected and greyed out on Dashboard.
- **⌘0** zooms out to the whole organigram.
- **⌃1**, **⌃2**, **⌃3** each land on the matching session — this is the one binding that cannot be verified by a test. macOS ships "Switch to Desktop N" on ⌃1…⌃N and the system binding wins once a second Desktop exists. If it is shadowed: either turn the Mission Control shortcuts off in System Settings → Keyboard → Shortcuts → Mission Control, or rebind the loop in `ApplicationMenus.install()` to `[.command, .option]` (⌥⌘1…⌥⌘9, currently free) and re-run Tasks 10b and 10f.
- **⇧⌘]** / **⇧⌘[** step to the next and previous session and stop at both ends.
- The **Zoom to Fit** and **Enter Session** toolbar buttons are visible. If they are not, the toolbar-identifier bump in Task 10c did not take — check `installToolbar(on:)`.
- Quit, relaunch, and confirm the canvas comes back where it was left: drag a node, quit, relaunch, and it is still where you put it.

- [ ] **Step 5: Record the result — do not touch the cutover gate**

Run:
```
./scripts/cutover.sh status
```
Expected: still `0/2 recorded, gate CLOSED`.

**Do nothing about it.** This is a local build, not a release-candidate cycle shipped to real users, and `cutover.sh record` is only for the latter. Recording a cycle here to open the gate is exactly the failure mode the script's design forbids. The web terminal hot path stays in the tree.