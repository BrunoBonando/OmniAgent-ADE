#!/bin/sh
# Release-gated cutover for the web terminal hot path (Task 7, Phase 7 of
# docs/plans/native-macos-migration.md). Sibling to macos/build.sh and
# macos/dist.sh: same shell style and subcommand dispatch, real logic
# delegated to a plain, unit-testable module (scripts/cutover_lib.py),
# mirroring how scripts/native-macos-pty-harness.py backs its own tests.
#
# Usage:
#   scripts/cutover.sh record [--version V] [--by NAME] [--note TEXT]
#   scripts/cutover.sh status
#   scripts/cutover.sh cutover [--yes]
#   scripts/cutover.sh help
#
# The destructive removal (`cutover --yes`) only runs once
# scripts/cutover-rc-log.jsonl has 2 recorded release-candidate cycles.
# Before that, `cutover` refuses with a non-zero exit and does nothing.
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
exec python3 "$root/scripts/cutover_lib.py" "$@"
