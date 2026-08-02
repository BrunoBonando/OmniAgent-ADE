#!/bin/sh
set -eu

action=${1:-test}
case "$action" in
  test|build|universal) ;;
  *) echo "usage: $0 [test|build|universal]" >&2; exit 2 ;;
esac

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
arch=$(uname -m)

# The OmniAgent target's "Embed PTY Daemon" / "Embed LaunchAgent Plists"
# Copy Files build phases (Task 6d addendum) reference fixed paths under
# target/native-macos-embed/; xcodebuild fails outright if those inputs are
# missing, so every action below stages them first. `build`/`test` only
# need this machine's own arch (fast local loop); `universal` needs both.
if [ "$action" = "universal" ]; then
  "$root/macos/embed-daemon.sh" arm64 x86_64
else
  "$root/macos/embed-daemon.sh" "$arch"
fi

if [ "$action" = "universal" ]; then
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
