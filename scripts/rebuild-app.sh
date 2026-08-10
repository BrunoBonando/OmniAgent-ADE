#!/usr/bin/env bash
# Builds the NATIVE macOS app (macos/OmniAgent.xcodeproj), packages it as a
# DMG, and installs it to /Applications. The legacy Tauri app is deliberately
# no longer built here (standing decision, 2026-08-03): the native app is the
# only artifact Bruno builds and runs day-to-day. The Tauri hot path's code
# stays in-tree until scripts/cutover.sh's gate opens -- build it manually
# with `cd src-tauri && ../ui/node_modules/.bin/tauri build` if ever needed.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

version="$(./scripts/bump-build-version.sh)"
./macos/build.sh universal

app="$ROOT_DIR/macos/.build/Build/Products/Release/OmniAgent.app"
dist="$ROOT_DIR/target/native-macos-dist"
mkdir -p "$dist"
dmg="$dist/OmniAgent_${version}_universal.dmg"
./macos/make-dmg.sh "$app" "$dmg"

rm -rf /Applications/OmniAgent.app
ditto "$app" /Applications/OmniAgent.app

echo "Installed OmniAgent $version (native) -> /Applications/OmniAgent.app"
echo "DMG: $dmg"
