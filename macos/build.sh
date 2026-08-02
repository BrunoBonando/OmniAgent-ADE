#!/bin/sh
set -eu

action=${1:-test}
case "$action" in
  test|build|universal) ;;
  *) echo "usage: $0 [test|build|universal]" >&2; exit 2 ;;
esac

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
arch=$(uname -m)

# `build`/`test` build the Debug configuration (the scheme's default for
# both), and the OmniAgent target's "Embed PTY Daemon + LaunchAgent Plists
# (non-Debug)" Run Script build phase (Task 6d) skips itself entirely for
# Debug -- so plain `./macos/build.sh build`/`test` never touches Rust,
# preserving the Xcode-only workflow every earlier Task 6 sub-task relied
# on. `universal` builds Release, which that phase does NOT skip, so it
# needs the daemon binary + plists staged first.
if [ "$action" = "universal" ]; then
  "$root/macos/embed-daemon.sh" arm64 x86_64
  exec xcodebuild build \
    -project "$root/macos/OmniAgent.xcodeproj" \
    -scheme OmniAgent \
    -configuration Release \
    -derivedDataPath "$root/macos/.build" \
    -destination "generic/platform=macOS" \
    CODE_SIGNING_ALLOWED=NO \
    ONLY_ACTIVE_ARCH=NO \
    ARCHS="arm64 x86_64"
fi

exec xcodebuild "$action" \
  -project "$root/macos/OmniAgent.xcodeproj" \
  -scheme OmniAgent \
  -destination "platform=macOS,arch=$arch" \
  CODE_SIGNING_ALLOWED=NO \
  ONLY_ACTIVE_ARCH=YES \
  ARCHS="$arch"
