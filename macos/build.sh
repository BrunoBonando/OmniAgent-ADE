#!/bin/sh
set -eu

action=${1:-test}
case "$action" in
  test|build) ;;
  *) echo "usage: $0 [test|build]" >&2; exit 2 ;;
esac

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
arch=$(uname -m)
exec xcodebuild "$action" \
  -project "$root/macos/OmniAgent.xcodeproj" \
  -scheme OmniAgent \
  -destination "platform=macOS,arch=$arch" \
  CODE_SIGNING_ALLOWED=NO \
  ONLY_ACTIVE_ARCH=YES \
  ARCHS="$arch"
