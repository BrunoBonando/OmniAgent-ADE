#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

./scripts/bump-build-version.sh

cd src-tauri
../ui/node_modules/.bin/tauri build --bundles app,dmg
