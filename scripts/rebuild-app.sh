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

# Sign with a real identity whenever one is available. macOS keys folder-access
# (TCC) grants to the code-signing identity, and an ad-hoc bundle's identity is
# its cdhash -- which changes on every build, so an unsigned rebuild makes macOS
# ask for access to Documents all over again, every time. Signing is
# best-effort: a machine with no Developer ID still gets a working app out of
# this script, just a forgetful one.
if ./macos/dist.sh sign "$app"; then
  echo "Signed $app"
else
  echo "warning: could not sign $app -- macOS will ask for folder access again after this build." >&2
fi

dist="$ROOT_DIR/target/native-macos-dist"
mkdir -p "$dist"
dmg="$dist/OmniAgent_${version}_universal.dmg"
# Non-fatal: the DMG is for handing to other people, and its Finder-scripted
# layout step times out often enough (AppleEvent -1712) that letting it abort
# the run would leave the app built but not installed -- which is the part that
# actually matters here.
if ! ./macos/make-dmg.sh "$app" "$dmg"; then
  echo "warning: DMG packaging failed; continuing to install the app itself." >&2
  dmg="(not built)"
fi

rm -rf /Applications/OmniAgent.app
ditto "$app" /Applications/OmniAgent.app

echo "Installed OmniAgent $version (native) -> /Applications/OmniAgent.app"
echo "DMG: $dmg"
