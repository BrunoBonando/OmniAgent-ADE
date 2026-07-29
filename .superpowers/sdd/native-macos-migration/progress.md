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
