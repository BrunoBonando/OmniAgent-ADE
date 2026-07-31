# SDD ledger — plan: docs/plans/native-macos-migration.md

Baseline:
- Branch: codex/native-macos-migration
- Start: ffc9c68cd5c24243f7cf683bcaf42d605aca6306
- Rust workspace baseline initially blocked because the committed Tauri resource requires a release `omniagent-mcp` build.
- UI baseline: 77 files passed, 1,178 tests passed, 8 skipped.
- Rust baseline after building the required release MCP binary: all suites reached `brain-ingest`; one pre-existing failure remained at `ingest_fixture_mines_git_cochange_between_auth_and_util` because the ignored nested fixture repository is absent.

Task 1: fix round 1/5 (1 addressed, 0 open; commits 67bfb72..2114631)
Task 1: complete (commits 121d16f..2114631, review clean)
Task 2: fix round 1/5 (2 addressed, 0 open; commits 69926fc..fbfc93e)
Task 2: complete (commits 2114631..fbfc93e, review clean)
Task 3: fix round 1/5 (5 addressed, 3 open; commits 3133e61..2ff9291)
Task 3: fix round 2/5 (3 addressed, 0 open; commits 2ff9291..5ac1567)
Task 3: complete (commits fbfc93e..5ac1567, review clean)
Task 4: fix round 1/5 (3 addressed, 0 open; commits 790a7d1..ecaccd2)
Task 4: fix round 2/5 (2 addressed, 0 open; commits ecaccd2..9607b73)
Task 4: fix round 3/5 (3 addressed, 0 open; commits 9607b73..a0e388f)
Task 4: code complete (commits 5ac1567..a0e388f, review clean)
Task 4 external gate: signed-installed-app Instruments p95 and terminal/input fidelity matrix remain unrun and block release acceptance.
Task 5: implemented (commits caaf9fb..a89990f) — PaneGrid.swift port of paneGrid.ts, PaneWorkspaceView.swift, N-session WorkspaceWindowController, tests. Review: spec ✅, 2 Important, 8 Minor.
Task 5: ⚠️ resolved by controller — PersistedTab/layout/SessionInfo/SessionStatus preservation not verifiable from diff because no persistence exists in the native client yet (Task 6's job, routes through Rust service per plan Task 6); not a Task 5 gap.
Task 5: minor (deferred): closePane leaves blank view + leaks hole placeholders on nil grid (PaneWorkspaceView.swift:307-311)
Task 5: minor (deferred): "Add terminal" hole missing from accessibilityChildren() (PaneWorkspaceView.swift:424)
Task 5: minor (deferred): currentDivider(matching:) is dead indirection, comment is wrong (PaneWorkspaceView.swift:371-375)
Task 5: minor (deferred): display-link half of resize coalescing untested (attached-window path) (PaneWorkspaceViewTests.swift)
Task 5: minor (deferred): occlusion observer/display link torn down only in viewDidMoveToWindow, no deinit (PaneWorkspaceView.swift:390-397)
Task 5: minor (deferred): PaneWorkspaceView.swift is 812 lines/7 types, split PaneContainerView/PaneHeaderView/PaneDividerView/PaneHolePlaceholderView into PaneViews.swift (PaneWorkspaceView.swift:479-812)
Task 5: minor (deferred): two test names over-promise what they assert (PaneWorkspaceViewTests.swift testPanesAndHolesTileTheWorkspaceBoundsExactly, testEveryPaneIsBothADragSourceAndADropDestination)
Task 5: minor (deferred): StubDraggingInfo uses a shared process-global NSPasteboard; Fixture enum name too generic (PaneWorkspaceViewTests.swift, PaneGridTests.swift)
Task 5: fix round 1/5 (2 addressed, 0 open; commits a89990f..3162243)
Task 5: complete (commits caaf9fb..3162243, review clean, 8 minors deferred to final review)
Task 6: split into 6a (daemon/Swift settings+brain routing), 6b (native UI surface), 6c (persistence service), 6d (distribution) — see task-6[a-d]-brief.md
Task 6a: implemented (commits eeb7af4..2400811) — new BrainListProjects/BrainGetContext message kinds, PersistedLayoutCodec. Review: spec ❌ (1 Important), 8 Minor.
Task 6a: minor (deferred): data_dir plumbing inert until a mutation tool is wired, will be wrong when it is (server.rs:48,197-201,231,253,256,278,428)
Task 6a: minor (deferred): near-duplicate dispatch blocks for the two new brain kinds (server.rs:352-397)
Task 6a: minor (deferred): tool_context() helper is a two-field literal behind a function, inline it (server.rs:428-430)
Task 6a: minor (deferred): ToolError variants flattened to a generic Error frame (server.rs:359,383)
Task 6a: minor (deferred): BrainListProjects accepts any JSON value as payload, empty payload closes connection instead of being treated as no-args (server.rs:353)
Task 6a: minor (deferred): dead Layout struct and unused CaseIterable conformances in PersistedLayout.swift:7,17,84-86
Task 6a: minor (deferred): no shared fixture guarding Swift/TS layout codec drift, unlike pane-grid.json's convention (PersistedLayoutTests.swift)
Task 6a: minor (deferred): SessionConnection new client methods untested against .error/non-.response frames (SessionConnection.swift:287-352)
Task 6a: fix round 1/5 (1 addressed, 0 open on original finding; re-review found 1 new Important regression: sessions.rs:4821-4822 missed the .with_data_dir ripple, would spawn real daemon against production brain.db; commits 2400811..3a0c165)
