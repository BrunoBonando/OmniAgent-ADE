#!/bin/sh
set -euo pipefail

echo "Installing local git hooks (setting core.hooksPath to .githooks)"

git config core.hooksPath .githooks

echo "Done. To undo: git config --unset core.hooksPath"
