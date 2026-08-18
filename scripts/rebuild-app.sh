#!/usr/bin/env bash
# Builds the NATIVE macOS app (macos/OmniAgent.xcodeproj), signs it, optionally
# notarizes it, packages it as a DMG, and installs it to /Applications. The
# legacy Tauri app is deliberately no longer built here (standing decision,
# 2026-08-03): the native app is the only artifact Bruno builds and runs
# day-to-day. The Tauri hot path's code stays in-tree until scripts/cutover.sh's
# gate opens -- build it manually with
# `cd src-tauri && ../ui/node_modules/.bin/tauri build` if ever needed.
#
# Order matters here and is not obvious:
#
#   build -> sign app -> notarize+staple app -> DMG -> sign+notarize+staple DMG
#
# The DMG has to be built *after* the app is stapled, or it ships an app with
# no ticket in it; and the DMG then needs its own signature and its own
# notarization, because Gatekeeper assesses the disk image separately from
# what is inside it.
#
# Usage:
#   ./scripts/rebuild-app.sh                 # notarize when credentials exist
#   ./scripts/rebuild-app.sh --no-notarize   # skip the two Apple round-trips
#   ./scripts/rebuild-app.sh --keep-daemon   # leave the running PTY daemon up
#
# The PTY daemon is restarted along with the app. It is a binary inside the
# bundle being replaced, so leaving it running means the install silently keeps
# the old one -- see the comment above the install step. This ends live
# terminal sessions; --keep-daemon opts out.
set -euo pipefail

notarize=auto
keep_daemon=no
for arg in "$@"; do
  case "$arg" in
    --no-notarize) notarize=no ;;
    --keep-daemon) keep_daemon=yes ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    *) echo "$0: unknown option: $arg" >&2; exit 2 ;;
  esac
done

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# Notarization is two round-trips to Apple, a few minutes each, and it buys
# nothing for a local install: an app copied into place with `ditto` carries no
# quarantine flag, so Gatekeeper never evaluates it. It matters the moment the
# DMG goes to someone else. Hence: on when credentials exist, and one flag away
# when the fast loop is what is wanted.
if [ "$notarize" = auto ]; then
  if [ -n "${OMNIAGENT_NOTARY_PROFILE:-}" ]; then
    notarize=yes
  else
    notarize=no
    echo "note: OMNIAGENT_NOTARY_PROFILE is unset -- building signed but NOT notarized." >&2
    echo "      The app installs and runs fine locally; a DMG handed to someone else would be blocked." >&2
  fi
fi

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
  notarize=no
fi

if [ "$notarize" = yes ]; then
  ./macos/dist.sh notarize "$app"
fi

dist="$ROOT_DIR/target/native-macos-dist"
mkdir -p "$dist"
dmg="$dist/OmniAgent_${version}_universal.dmg"
# Non-fatal: the DMG is for handing to other people, and its Finder-scripted
# layout step times out often enough (AppleEvent -1712) that letting it abort
# the run would leave the app built but not installed -- which is the part that
# actually matters here.
rm -f "$dmg"
if ./macos/make-dmg.sh "$app" "$dmg"; then
  if [ "$notarize" = yes ]; then
    # Signs the image, submits it, staples it, and asks Gatekeeper.
    ./macos/dist.sh notarize "$dmg"
  fi
else
  echo "warning: DMG packaging failed; continuing to install the app itself." >&2
  dmg="(not built)"
fi

# Quit a running copy first: replacing the bundle underneath a live process
# leaves it running from an unlinked inode, so the app on screen is no longer
# the app on disk.
#
# The PTY daemon goes with it. It outlives the app by design -- that is what
# keeps terminal sessions alive -- and this script used to leave it alone for
# exactly that reason. But it is a *binary in the bundle being replaced*, so
# leaving it up means every install silently keeps running the old daemon:
# every daemon-side change (agent status detection, the session cap) looked
# like it had shipped and had not, and the surviving process kept running from
# an unlinked inode. Bruno's call, and the right one -- a reinstall you have to
# remember to finish by hand is not an install.
#
# Terminal sessions do not survive this. --keep-daemon opts out for a rebuild
# that changes nothing daemon-side and would rather not interrupt a running
# agent.
was_running=no
if pgrep -f "/Applications/OmniAgent.app/Contents/MacOS/OmniAgent$" >/dev/null 2>&1; then
  was_running=yes
  echo "Quitting the running OmniAgent..."
  osascript -e 'quit app "OmniAgent"' >/dev/null 2>&1 || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    pgrep -f "/Applications/OmniAgent.app/Contents/MacOS/OmniAgent$" >/dev/null 2>&1 || break
    sleep 1
  done
fi

if [ "$keep_daemon" = yes ]; then
  echo "Leaving the running PTY daemon alone (--keep-daemon)."
else
  daemon_pattern="/Applications/OmniAgent.app/Contents/MacOS/omniagent-pty-daemon$"
  if pgrep -f "$daemon_pattern" >/dev/null 2>&1; then
    echo "Stopping the PTY daemon so the new one is the one that runs..."
    pkill -f "$daemon_pattern" || true
    for _ in 1 2 3 4 5; do
      pgrep -f "$daemon_pattern" >/dev/null 2>&1 || break
      sleep 1
    done
  elif pgrep -a -f "$daemon_pattern" >/dev/null 2>&1; then
    # -a is the difference between seeing it and not: pgrep/pkill exclude their
    # own ancestors, and the daemon *is* this shell's ancestor whenever the
    # rebuild is run from a terminal pane inside OmniAgent -- which is the
    # normal case. So the stop above was a silent no-op exactly there, and
    # every such install kept the old daemon: the bug this block exists to
    # prevent, reintroduced by the tool used to check for it.
    #
    # Killing it from here is not the fix: it would hang up this script's own
    # PTY mid-install. Say so instead of pretending.
    echo "PTY daemon NOT restarted: it is this shell's own parent (rebuild started"
    echo "  from a pane inside OmniAgent). Daemon-side changes are not live."
    echo "  To finish: quit OmniAgent, then from an outside Terminal run"
    echo "  pkill -f omniagent-pty-daemon && open -a OmniAgent"
  fi
fi

rm -rf /Applications/OmniAgent.app
ditto "$app" /Applications/OmniAgent.app

# Put it back exactly if it was up. Only when this script is what closed it --
# a rebuild started with the app already shut should leave it shut.
if [ "$was_running" = yes ]; then
  echo "Relaunching OmniAgent..."
  open -a /Applications/OmniAgent.app
fi

echo "Installed OmniAgent $version (native) -> /Applications/OmniAgent.app"
echo "DMG: $dmg"
if [ "$notarize" = yes ]; then
  echo "Notarized: app and DMG stapled and accepted by Gatekeeper."
else
  echo "Notarized: no (signed only)."
fi
