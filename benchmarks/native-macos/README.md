# Native macOS benchmark harness

No benchmark results are committed. On a packaged app, run:

```sh
python3 scripts/native-macos-pty-harness.py benchmark /Applications/OmniAgent.app \
  --output benchmarks/native-macos/local-results.json
```

The harness records one, four, and eight terminals with continuous output, resize storms, input-to-snapshot latency, daemon CPU, and hidden-output RSS growth. `reference-machine.schema.json` defines the machine metadata embedded in each result file.
