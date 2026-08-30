#!/bin/sh
# Package a built OmniAgent.app as the styled drag-to-install DMG the Tauri
# bundler used to produce: navy background with the DRAG TO INSTALL arrow
# (macos/dmg/), app icon at (172,205), Applications at (528,205), 700x400
# window, 128pt icons, volume icon. Finder does the .DS_Store styling, so this
# needs a GUI session with Automation permission for Finder.
set -eu

app=${1:-}
out=${2:-}
if [ -z "$app" ] || [ -z "$out" ]; then
  echo "usage: $0 <path-to-OmniAgent.app> <output.dmg>" >&2
  exit 2
fi

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
bg_dir="$root/macos/dmg"
volname="OmniAgent"

# A leftover mounted OmniAgent volume makes the fresh one mount as
# "OmniAgent 1" and every path below misses -- detach leftovers first.
for stale in "/Volumes/$volname" "/Volumes/$volname "*; do
  [ -d "$stale" ] && hdiutil detach "$stale" || true
done

staging=$(mktemp -d)
rw_dmg=$(mktemp -u).dmg
device=""
trap 'hdiutil detach "$device" -force >/dev/null 2>&1 || true; rm -rf "$staging" "$rw_dmg"' EXIT

ditto "$app" "$staging/OmniAgent.app"
ln -s /Applications "$staging/Applications"
mkdir "$staging/.background"
# 1x + 2x combined into one tiff so the background stays crisp on retina
tiffutil -cathidpicheck "$bg_dir/dmg-background.png" "$bg_dir/dmg-background@2x.png" \
  -out "$staging/.background/background.tiff"

# HFS+ so the custom-volume-icon attribute sticks
hdiutil create -volname "$volname" -srcfolder "$staging" -ov -fs HFS+ \
  -format UDRW "$rw_dmg" >/dev/null

attach_out=$(hdiutil attach -readwrite -noverify -noautoopen "$rw_dmg")
device=$(printf '%s\n' "$attach_out" | awk '/\/Volumes\// {print $1; exit}')
vol=$(printf '%s\n' "$attach_out" | sed -n 's|.*\(/Volumes/.*\)|\1|p' | head -1)
if [ "$vol" != "/Volumes/$volname" ]; then
  echo "error: volume mounted at '$vol', expected /Volumes/$volname" >&2
  exit 1
fi

# ponytail: no custom volume icon -- this macOS release strips
# .VolumeIcon.icns from converted images (verified: survives neither
# srcfolder nor live-volume copy). Revisit if Apple restores the behavior.

osascript <<EOF
tell application "Finder"
  tell disk "$volname"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {400, 140, 1100, 540}
    set viewOptions to the icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 128
    set background picture of viewOptions to file ".background:background.tiff"
    set position of item "OmniAgent.app" of container window to {172, 205}
    set position of item "Applications" of container window to {528, 205}
    close
    open
    update without registering applications
    delay 2
    close
  end tell
end tell
EOF

sync
hdiutil detach "$device" >/dev/null
mkdir -p "$(dirname "$out")"
rm -f "$out"
hdiutil convert "$rw_dmg" -format UDZO -o "$out" >/dev/null
echo "Styled DMG: $out"
