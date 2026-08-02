#!/bin/sh
# Stages the omniagent-pty-daemon binary and both LaunchAgent plists that
# macos/OmniAgent.xcodeproj's "Embed PTY Daemon" / "Embed LaunchAgent
# Plists" Copy Files build phases embed into the app bundle at
# Contents/MacOS/omniagent-pty-daemon and Contents/Library/LaunchAgents/.
# Task 6d addendum: Task 6c built DaemonBinaryLocator/DaemonLaunchAgentPlist
# expecting these to exist; this script (invoked from macos/build.sh before
# every xcodebuild call) is what actually produces them.
#
# Usage: macos/embed-daemon.sh <arch> [arch...]
#   arch is "arm64" or "x86_64" (uname -m spelling, matching build.sh).
#   One arch: builds a single-slice binary (fast local dev/test loop).
#   Two arches: builds both and lipo -create's them into one universal
#   binary (macos/build.sh's "universal" subcommand).
set -eu

[ $# -ge 1 ] || { echo "usage: $0 <arch> [arch...]" >&2; exit 2; }

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
stage="$root/target/native-macos-embed"
mkdir -p "$stage"

# --- 1. Build the daemon binary for each requested arch, then combine. ---

slice_paths=""
for arch in "$@"; do
  case "$arch" in
    arm64) triple=aarch64-apple-darwin ;;
    x86_64) triple=x86_64-apple-darwin ;;
    *) echo "embed-daemon.sh: unsupported arch '$arch' (expected arm64 or x86_64)" >&2; exit 2 ;;
  esac

  if ! rustup target list --installed 2>/dev/null | grep -qx "$triple"; then
    echo "embed-daemon.sh: Rust target '$triple' is not installed." >&2
    echo "  Install it with: rustup target add $triple" >&2
    exit 1
  fi

  echo "embed-daemon.sh: building omniagent-pty-daemon for $arch ($triple)..." >&2
  ( cd "$root" && cargo build --release --target "$triple" -p omniagent-pty-daemon --bin omniagent-pty-daemon )
  slice_paths="$slice_paths $root/target/$triple/release/omniagent-pty-daemon"
done

daemon_out="$stage/omniagent-pty-daemon"
# shellcheck disable=SC2086 # slice_paths is an intentionally word-split list of paths
if [ "$#" -eq 1 ]; then
  cp -f $slice_paths "$daemon_out"
else
  lipo -create -output "$daemon_out" $slice_paths
fi
chmod 755 "$daemon_out"

# --- 2. Generate both channel's LaunchAgent plists. ---
#
# Mirrors DaemonLaunchAgentPlist.build / DaemonPaths.resolve
# (macos/OmniAgent/DaemonPersistence.swift) — see that file's doc comments
# for the production-data-reuse and preview-separation requirements this
# pins down. Two deliberate divergences from a literal port of
# DaemonLaunchAgentPlist.build, both documented here because there is no
# Swift call site to point to instead (this script *is* the "small
# standalone script that mirrors its logic" the Task 6d brief names):
#
#  1. The production plist omits EnvironmentVariables entirely. The
#     daemon's own built-in defaults (crates/omniagent-pty-daemon/src/main.rs,
#     falling back to $HOME/.omniagent-ade/omniagent-pty.sock; and
#     brain_core::Store::default_data_dir(), $HOME/Library/Application
#     Support/OmniAgent-ADE) are byte-identical to DaemonPaths' production
#     defaults. Baking this *build machine's* $HOME into the plist would
#     be redundant at best and wrong at worst (if the built .app is ever
#     copied to a different account without rebuilding, a baked-in path
#     would override the daemon's own correct per-user default with the
#     wrong user's home directory). Omitting the keys lets the daemon
#     compute the right path itself from its own runtime environment,
#     exactly as it already does when launched with no env override.
#  2. The preview plist *does* bake in this build machine's $HOME, because
#     preview's socket/data-dir paths differ from the daemon's built-in
#     defaults and a static launchd plist has no portable way to reference
#     "the invoking user's home directory" other than a literal path
#     resolved at packaging time. This is correct for this task's actual
#     deployment model (build and run on the same developer Mac) and is
#     called out explicitly in the Task 6d report as a known limitation
#     for true multi-account distribution of a preview build.

home="$HOME"
prod_label="digital.bruno.omniagent.pty-daemon"
preview_label="digital.bruno.omniagent.preview.pty-daemon"

write_plist() {
  # write_plist <path> <label> <environment-variables-fragment-or-empty>
  path=$1
  label=$2
  env_fragment=$3
  cat > "$path" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$label</string>
	<key>ProgramArguments</key>
	<array>
		<string>Contents/MacOS/omniagent-pty-daemon</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
	<key>ProcessType</key>
	<string>Interactive</string>
$env_fragment
</dict>
</plist>
PLIST
  chmod 644 "$path"
  plutil -lint "$path" >/dev/null
}

write_plist "$stage/$prod_label.plist" "$prod_label" ""

preview_env_fragment=$(cat <<ENVXML
	<key>EnvironmentVariables</key>
	<dict>
		<key>OMNIAGENT_PTY_SOCKET</key>
		<string>$home/.omniagent-ade/preview/omniagent-pty.sock</string>
		<key>OMNIAGENT_ADE_DATA_DIR</key>
		<string>$home/Library/Application Support/OmniAgent-ADE-Preview</string>
	</dict>
ENVXML
)
write_plist "$stage/$preview_label.plist" "$preview_label" "$preview_env_fragment"

echo "embed-daemon.sh: staged $daemon_out and both LaunchAgent plists in $stage" >&2
