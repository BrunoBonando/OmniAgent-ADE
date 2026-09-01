#!/usr/bin/env bash
# Publishes a built DMG to dl.omni-agent.ai as a Sparkle release: signs it with
# the EdDSA key, regenerates the appcast, uploads both, and then *asks the
# public URL* whether the new feed is actually being served.
#
# That last step is the whole reason this is a script and not two curls.
# Cloudflare caches `appcast.xml`, and an overwritten file can keep serving the
# old copy from the edge for a while -- during which the release exists, is
# downloadable, and is invisible to every app checking for it. Sparkle's own
# no-cache request policy defeats only the *client's* URL cache, not the edge.
#
# Usage:
#   ./scripts/publish-release.sh                     # newest DMG in target/native-macos-dist
#   ./scripts/publish-release.sh path/to/Foo.dmg     # a specific one
#
# Environment:
#   OMNIAGENT_DL_AUTH   user:password for the LAN upload host (required)
#   OMNIAGENT_DL        upload base URL (default http://10.1.2.37)
set -euo pipefail

DL="${OMNIAGENT_DL:-http://10.1.2.37}"
PUBLIC="https://dl.omni-agent.ai/releases"

if [ -z "${OMNIAGENT_DL_AUTH:-}" ]; then
  cat >&2 <<EOF
$0: OMNIAGENT_DL_AUTH is not set.

  export OMNIAGENT_DL_AUTH='admin:<password>'

The upload host ($DL) is LAN-only -- the router forwards just 443 to the public
edge, so this will not work off the network. The password is deliberately not
in this repo: everything under dl.omni-agent.ai is world-readable.
EOF
  exit 2
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dist="$ROOT_DIR/target/native-macos-dist"

# Sparkle's tools. The SPM artifact bundle carries them too, but that lives in
# derived data and is deleted by any clean, so a stable copy wins.
tools="$HOME/.local/share/sparkle/bin"
if [ ! -x "$tools/generate_appcast" ]; then
  echo "$0: Sparkle's tools are not at $tools." >&2
  echo "    Download Sparkle-<version>.tar.xz from github.com/sparkle-project/Sparkle/releases" >&2
  echo "    and copy its bin/ to $tools." >&2
  exit 1
fi

dmg="${1:-}"
if [ -z "$dmg" ]; then
  # Newest by mtime, not by name: the version sorts as a string, and 1.7.9
  # sorts after 1.7.10.
  dmg="$(ls -t "$dist"/OmniAgent_*_universal.dmg 2>/dev/null | head -1 || true)"
fi
[ -n "$dmg" ] && [ -f "$dmg" ] || { echo "$0: no DMG to publish (looked in $dist)." >&2; exit 1; }

# The version Sparkle will compare against is the one inside the app, not the
# one in the filename -- read it from the horse's mouth.
mnt="$(mktemp -d)"
hdiutil attach "$dmg" -nobrowse -readonly -mountpoint "$mnt" >/dev/null
version="$(defaults read "$mnt/OmniAgent.app/Contents/Info" CFBundleVersion)"
hdiutil detach "$mnt" -quiet
rmdir "$mnt" 2>/dev/null || true
echo "$0: publishing OmniAgent $version ($(basename "$dmg"))"

# generate_appcast builds the feed from every archive in the directory it is
# given, so give it a directory holding exactly the release being published.
# The alternative -- pointing it at target/native-macos-dist -- would sweep up
# every stale local build, including the pre-semver date-scheme ones.
staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT
cp "$dmg" "$staging/"

echo "$0: signing and generating the appcast..." >&2
# The private EdDSA key lives in the login keychain, and only `generate_keys`
# is in that item's ACL -- it is the binary that created it. `generate_appcast`
# is a different binary, so asking it to read the keychain directly raises a
# permission dialog, which is an infinite hang for anything without a person
# in front of it (a background job, a locked screen, CI).
#
# So the tool that is allowed to read the key exports it, and it is piped
# straight into the one that needs it. `--ed-key-file -` reads standard input,
# so the private key never touches the disk -- no second copy to protect, and
# nothing left behind if this script dies halfway.
# `-x` insists on a real file (it will not write to /dev/stdout), so the key
# goes to a 0700 directory of its own and is shredded the moment it has been
# used -- and again by the trap, so a crash in between leaves nothing.
keydir="$(mktemp -d)"
chmod 700 "$keydir"
trap 'rm -rf "$staging"; rm -Pf "$keydir"/* 2>/dev/null; rm -rf "$keydir"' EXIT
( umask 077; "$tools/generate_keys" -x "$keydir/ed" >/dev/null 2>&1 )
[ -s "$keydir/ed" ] || {
  echo "$0: could not read the signing key from the keychain." >&2
  echo "    Run './scripts/publish-release.sh' once from a terminal on the" >&2
  echo "    desktop and click \"Always Allow\" if macOS asks for permission." >&2
  exit 1
}
"$tools/generate_appcast" --ed-key-file "$keydir/ed" \
  --download-url-prefix "$PUBLIC/" "$staging"
rm -Pf "$keydir/ed"

[ -f "$staging/appcast.xml" ] || {
  echo "$0: no appcast was generated -- the DMG was NOT uploaded." >&2
  exit 1
}

echo "$0: uploading..." >&2
# The DMG first, the appcast last. A feed that points at a file which has not
# finished uploading is a broken update for everyone who checks in between.
curl -sf -u "$OMNIAGENT_DL_AUTH" -T "$dmg" "$DL/releases/$(basename "$dmg")"
curl -sf -u "$OMNIAGENT_DL_AUTH" -T "$staging/appcast.xml" "$DL/releases/appcast.xml"

echo "$0: asking the public URL what it serves..." >&2
# `sparkle:version` is an element, not an attribute -- the only attribute
# carrying the word "version" is on <enclosure>, which is a different thing.
served="$(curl -s "$PUBLIC/appcast.xml" \
  | sed -n 's|.*<sparkle:version>\([^<]*\)</sparkle:version>.*|\1|p' | head -1)"
if [ "$served" = "$version" ]; then
  echo "$0: live -- $PUBLIC/appcast.xml offers $version." >&2
else
  cat >&2 <<EOF
$0: WARNING -- the edge is serving version "${served:-<nothing>}", not $version.

The upload succeeded; Cloudflare is caching the old appcast. Until it expires,
no app will see this release. Fix it once, permanently, with a Cloudflare Cache
Rule that bypasses cache for the URI path /releases/appcast.xml -- the DMGs
should stay cached (that is what keeps the home uplink sane), only the feed
must not be.
EOF
  exit 1
fi
