# Native macOS benchmark harness

No benchmark results are committed. On a packaged app, run:

```sh
python3 scripts/native-macos-pty-harness.py benchmark /Applications/OmniAgent.app \
  --output benchmarks/native-macos/local-results.json
```

The harness records one, four, and eight terminals with continuous output, resize storms, input-to-snapshot latency, daemon CPU, and hidden-output RSS growth. `reference-machine.schema.json` defines the machine metadata embedded in each result file.

## Attached in-process benchmarks

Two XCTest `measure` cases run inside `./macos/build.sh test`:

- `WorkspaceWindowControllerTests.testFrameDecodeFeedAndRendererDrawRequestMicrobenchmark` — frame decode plus terminal feed plus a renderer draw request, one pane.
- `PaneWorkspaceViewTests.testEightPaneDividerAndRendererDrawBenchmark` — an eight-pane workspace: divider drags, the coalesced resize flush, and a renderer draw request per pane.

They exist to catch a regression in the layout/draw path on whatever machine runs the suite. **They are not benchmark results and must never be quoted as any.** There is no PTY behind their panes (the socket never connects), no daemon, and no window compositing on a headless test host, so they say nothing about throughput, input-to-glyph latency, CPU under continuous output, or memory with hidden output.

The gate for those numbers is still the harness above, run against a packaged app on reference hardware, with the machine metadata recorded. No result file is committed until that run happens.
