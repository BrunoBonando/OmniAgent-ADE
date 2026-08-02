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
Task 6a: fix round 2/5 (1 addressed, 0 open; also fixed manual_black_pane_verify.rs found in the same sweep; commits 3a0c165..9e6a9c2)
Task 6a: minor (deferred): DaemonSessions::default_for_data_dir is inert/misleadingly named — sets socket path, not the data_dir override field; zero call sites today (src-tauri/src/daemon.rs:209-211)
Task 6a: complete (commits eeb7af4..9e6a9c2, review clean after 2 fix rounds, 9 minors deferred to final review)
Task 6a-2: briefed (ingestion/roots daemon routing) — see task-6a-2-brief.md, dispatch after Task 6b-1 lands to avoid concurrent daemon-protocol edits
Task 6b split: 6b-1 (AppKit surface: sidebar/palette/toolbar/notifications/restoration) delivered; 6b-2 (SwiftUI settings/onboarding/usage/inspectors) deferred, blocked on Task 6a-2
Task 6b-1: implemented (commits cda3ac2..c823e20). Review: spec ❌ (missing session-group creation; 2 documented/accepted deviations: onAttention via NSApp.requestUserAttention not UNUserNotificationCenter, palette drops brain-search pending 6a-2), 4 Important, ~11 Minor.
Task 6b-1: minor (deferred): Escape doesn't leave rename edit chrome (SessionOutlineView.swift:277)
Task 6b-1: minor (deferred): ported-but-unwired API (markAllRead, relativeTime, nextSessionName) — settle once session-group creation lands
Task 6b-1: minor (deferred): project id leaks into persisted notification's human-facing label (WorkspaceWindowController.swift:412-414, SessionNotifier.swift:112)
Task 6b-1: minor (deferred): redundant write-back of just-read layout/notifications on every launch (lastPersisted not seeded from the read value)
Task 6b-1: minor (deferred): toggleSidebar: menu item likely handled by NSSplitViewController before reaching the controller's method, test can't distinguish (WorkspaceWindowController.swift:368)
Task 6b-1: minor (deferred): connection widened to non-private with no cross-file consumer (WorkspaceWindowController.swift:35)
Task 6b-1: minor (deferred): lastStatus not cleared on closePane unlike sibling dicts
Task 6b-1: minor (deferred): UserNotificationDelivery() sets itself as UNUserNotificationCenter delegate in init, second controller would steal it
Task 6b-1: minor (deferred): WorkspaceWindowController.swift is 622 lines, settings-write pair (write/persistLayout/persistNotifications/lastPersisted) is an extractable collaborator
Task 6b-1: minor (deferred): palette action test covers 4/7 PaletteAction cases; recordNotification wiring untested
Task 6b-1: minor (deferred): Dictionary(uniqueKeysWithValues:) traps on duplicate session ids in CommandPaletteModel.build/SessionOutlineView.reload
Task 6b-1: fix round 1/5 (5 addressed — missing session-group creation + 4 Important — 0 open; commits c823e20..478930d)
Task 6b-1: minor (deferred): full 8-pane saved layout silently loses its last pane if a ⌘T races the restore read (WorkspaceWindowController.swift:439-451)
Task 6b-1: minor (deferred): a failed layout read disarms reconnect re-attach for panes created during the outage, and the window title sticks on the error (WorkspaceWindowController.swift:399-402,428-429)
Task 6b-1: minor (deferred): editingEnded triggers reloadData synchronously from controlTextDidEndEditing, an AppKit hazard; should dispatch async (SessionOutlineView.swift:113-117)
Task 6b-1: minor (deferred): beginRename() latches isRenaming=true unconditionally even if no field editor opens, no escape (SessionOutlineView.swift:365-373)
Task 6b-1: minor (deferred): fix report's "matches web build's cap semantics" claim for gating newSession on the 8-pane cap is inaccurate — web cap is per-session with new-session as the explicit escape hatch; native closes that hatch (defensible on native grounds, just mis-justified)
Task 6b-1: minor (deferred): rename tests never open a real field editor (no window), controlTextDidEndEditing path untested; one new-session test still uses paneIDs.last fill-order assumption instead of pane(inGroup:)
Task 6b-1: complete (commits cda3ac2..478930d, review clean after 1 fix round, 7 additional minors + prior 11 deferred to final review)
Task 6a-2: INTERRUPTED mid-implementation (user stopped the session for a computer restart, not a task failure) — commits bac1ecd..21f3257:
  8eb7461 feat(brain-ingest): extract roots.rs's ingestion orchestration into a Tauri-independent module
  25ba266 refactor(tauri): delegate roots.rs commands to the extracted brain-ingest module
  bf46bf5 feat(daemon): add protocol message kinds for the roots/ingestion surface and brain search
  21f3257 wip(daemon): dispatch handlers for roots/ingestion message kinds (compiles clean, UNTESTED — no cargo test run yet, no new tests written, no Swift client methods)
  Not reviewed. No task-6a-2-report.md written yet.
  Resume by re-reading task-6a-2-brief.md and these 4 commits, then: run `cargo test -p omniagent-pty-daemon` and `cargo test -p omniagent-ade` for regressions first, add tests for every new message kind (malformed/oversized payload rejection + round-trip, matching Task 6a's pattern), add the Swift SessionConnection client methods, then dispatch the task reviewer as usual.
Task 6a-2: resumed in a Linux sandbox (no Xcode/Swift toolchain available — see gap below), regression baselines re-run clean (roots.rs's 22 pre-existing tests unaffected; two unrelated pre-existing failures noted in the report), six new server_protocol.rs tests added covering all twelve message kinds (round-trip + malformed payload), twelve Swift SessionConnection client methods + matching XCTest cases added mirroring Task 6a's pattern. See task-6a-2-report.md for the full routing table and delegation list.
Task 6a-2: ⚠️ NOT reviewed, NOT code-complete by this plan's own bar — `./macos/build.sh test`/`build` could not be run (no Swift toolchain in this environment: `swift`/`swiftc`/`xcodebuild` all absent, and `SessionConnection.swift` imports the Apple-only `Darwin` module so no Linux Swift toolchain could compile it either). The Swift additions (SessionProtocol.swift, SessionConnection.swift, SessionConnectionTests.swift) are hand-verified against the Rust wire shapes and Task 6a's established pattern but UNCOMPILED. Resume on a real Mac by running `./macos/build.sh test` first — fix whatever it surfaces — before dispatching the task reviewer or starting Task 6b-2.
Task 6a-2: resumed on a real Mac — `./macos/build.sh test` surfaced 5 compile errors in SessionConnectionTests.swift (`XCTAssertNoThrow(try result.get())` inside a non-throwing completion closure), fixed by switching to `if case .failure` + `XCTFail` (commit 581aeab); full suite then passed (SessionConnectionTests 17/17; one unrelated pre-existing flake in WorkspaceWindowControllerTests confirmed non-reproducing in isolation); `./macos/build.sh build` succeeded; report updated (commit be92c78).
Task 6a-2: review 1 — spec ✅ with 1 Important gap; no compiler warnings (cargo build -p omniagent-pty-daemon -p brain-ingest -p omniagent-ade clean). Important: RootsRebuild's running-check + rebuild + background-reingest-kickoff sequence is duplicated near-verbatim between src-tauri/src/roots.rs:220-240 and crates/omniagent-pty-daemon/src/server.rs:611-632 instead of sharing one brain_ingest::roots function, violating the brief's "without duplicating logic" requirement.
Task 6a-2: minor (deferred): no test exercises "reject a concurrent rebuild" at any level (brain_ingest::roots::rebuild has no running-check itself) — add once the duplication fix lands a shared function to test against.
Task 6a-2: minor (deferred): TDD not strictly followed for daemon dispatch commits bf46bf5/21f3257 (tests landed after, in 1010de6) — transparently self-documented by the implementer as a session-interruption artifact; resulting coverage is thorough.
Task 6a-2: review 1's Important finding fixed — added `brain_ingest::roots::rebuild_and_reingest` (running-check + store lock/rebuild/swap + background-reingest-kickoff in one function, mirroring `start_ingest`'s shape); `src-tauri/src/roots.rs::roots_rebuild` and the daemon's `MessageKind::RootsRebuild` arm now both call only that function. `cargo test -p brain-ingest`/`-p omniagent-pty-daemon`/`-p omniagent-ade --lib` and `./macos/build.sh build` all re-run clean (pre-existing baseline flakes confirmed via `git stash` diffing, not caused by this fix). See task-6a-2-report.md's fix addendum for the full command output.
Task 6a-2: fix round 1/5 (1 addressed, 0 open; commits be92c78..c53deee) — re-review confirmed ADDRESSED at crates/brain-ingest/src/roots.rs:678-696, src-tauri/src/roots.rs:223-224, crates/omniagent-pty-daemon/src/server.rs:613; no new Critical/Important breakage.
Task 6a-2: complete (commits bac1ecd..c53deee, review clean after 1 fix round, 2 minors deferred to final review)
Task 6b-2: implemented (commit d64a6b0, 32 files/3863 insertions) — SettingsStore, 6-tab SwiftUI settings screen (Account/Notifications/Review/Panels/About incl. Rebuild brain), usage analytics (faithful port of usageAnalytics.ts + recorder + readout), per-project Inspector (getContext/staleness/pausedProjects), AuthGate, FirstRun (project picker → startIngest → poll → biggestProject), palette brain-search row, plus the 6b-1 project-label fix via a shared projectLabels cache. 274 tests passing (one confirmed-pre-existing unrelated flake). Review: spec ✅, 0 Critical/Important, 3 Minor.
Task 6b-2: minor (deferred): single squashed commit for a ~3.9k-line diff makes TDD RED→GREEN unverifiable from git history alone (report-only evidence) — note for final whole-branch review.
Task 6b-2: minor (deferred): InspectorViewModel.load() fires three independent daemon round-trips (getContext/staleness/pausedProjects) with no combined query (InspectorView.swift:1322-1343) — candidate for a combined message kind if inspector load latency ever matters.
Task 6b-2: minor (deferred): SettingsView.swift (363 lines) bundles view model + 5 tab views + window controller in one file, consistent with this diff's own house style (AuthGateView.swift/FirstRunView.swift do the same) but larger than most single-responsibility files elsewhere in the codebase.
Task 6b-2: complete (commits a91836f..d64a6b0, review clean, 3 minors deferred to final review)
