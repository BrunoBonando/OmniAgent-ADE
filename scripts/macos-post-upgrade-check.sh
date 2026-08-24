#!/bin/sh
set -eu

full=0
if [ "${1:-}" = "--full" ]; then
  full=1
elif [ "${1:-}" != "" ]; then
  echo "usage: $0 [--full]" >&2
  exit 2
fi

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

echo "== active developer dir =="
xcode-select -p

echo
echo "== xcode version =="
xcodebuild -version

echo
echo "== macOS SDK =="
xcrun --sdk macosx --show-sdk-version

major=$(xcodebuild -version | awk '/^Xcode / { split($2, parts, "."); print parts[1]; exit }')
if [ -n "${major:-}" ] && [ "$major" -ge 27 ]; then
  echo
  echo "== metal toolchain component =="
  component_json=$(xcodebuild -showComponent MetalToolchain -json 2>/dev/null || true)
  status=$(printf "%s" "$component_json" | python3 -c 'import json,sys
raw=sys.stdin.read().strip()
if not raw:
    print("unknown")
else:
    try:
        print(json.loads(raw).get("status", "unknown"))
    except Exception:
        print("unknown")
')
  if [ "$status" != "installed" ]; then
    echo "MetalToolchain status: $status" >&2
    echo "Install with: xcodebuild -downloadComponent MetalToolchain" >&2
    exit 1
  fi
  echo "MetalToolchain: installed"
fi

echo
echo "== native macOS test/build =="
./macos/build.sh test
./macos/build.sh build

if [ "$full" -eq 1 ]; then
  echo
  echo "== rust workspace build/tests =="
  cargo build --workspace
  cargo test --workspace
fi

echo
echo "Post-upgrade checks passed."
