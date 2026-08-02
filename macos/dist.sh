#!/bin/sh
# Distribution steps for the built OmniAgent.app: hardened-runtime signing,
# notarization/stapling, and Gatekeeper/install smoke verification.
# Sibling to macos/build.sh, same shell style and subcommand dispatch.
# Build the app first (./macos/build.sh universal for a distributable
# artifact), then run these against the resulting .app path.
set -eu

action=${1:-}
case "$action" in
  sign|notarize|verify) ;;
  *)
    echo "usage: $0 sign|notarize|verify <path-to-OmniAgent.app>" >&2
    exit 2
    ;;
esac

app=${2:-}
[ -n "$app" ] || { echo "usage: $0 $action <path-to-OmniAgent.app>" >&2; exit 2; }
[ -d "$app" ] || { echo "$0: no such app bundle: $app" >&2; exit 1; }

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
entitlements="$root/macos/OmniAgent/OmniAgent.entitlements"
daemon="$app/Contents/MacOS/omniagent-pty-daemon"

# --- sign: hardened-runtime codesign, app + embedded daemon, same identity ---

sign() {
  identity=${OMNIAGENT_CODESIGN_IDENTITY:-}
  if [ -z "$identity" ]; then
    cat >&2 <<EOF
$0 sign: OMNIAGENT_CODESIGN_IDENTITY is not set.

Signing needs a Developer ID Application (or Apple Development, for local
testing) identity from your keychain. Find one with:

  security find-identity -v -p codesigning

Then set OMNIAGENT_CODESIGN_IDENTITY to either its name (e.g.
"Developer ID Application: Your Name (TEAMID)") or its SHA-1 hash, and
re-run this command.
EOF
    exit 1
  fi

  if ! security find-identity -v -p codesigning | grep -qF "$identity"; then
    cat >&2 <<EOF
$0 sign: no codesigning identity matching "$identity" was found in the
keychain. Run 'security find-identity -v -p codesigning' to see what is
actually available and correct OMNIAGENT_CODESIGN_IDENTITY.
EOF
    exit 1
  fi

  [ -f "$entitlements" ] || { echo "$0 sign: missing entitlements file: $entitlements" >&2; exit 1; }
  plutil -lint "$entitlements" >/dev/null

  if [ -f "$daemon" ]; then
    echo "$0 sign: signing embedded daemon ($daemon)..." >&2
    codesign --force --options runtime --timestamp --sign "$identity" "$daemon"
  else
    echo "$0 sign: warning: no daemon binary embedded at $daemon (nothing to sign there)" >&2
  fi

  echo "$0 sign: signing app bundle ($app)..." >&2
  codesign --force --options runtime --timestamp \
    --entitlements "$entitlements" --sign "$identity" "$app"

  echo "$0 sign: verifying signature..." >&2
  codesign --verify --deep --strict --verbose=2 "$app"
  echo "$0 sign: done." >&2
}

# --- notarize: submit the signed, zipped app; staple the ticket on success ---

notarize() {
  profile=${OMNIAGENT_NOTARY_PROFILE:-}
  if [ -z "$profile" ]; then
    cat >&2 <<EOF
$0 notarize: OMNIAGENT_NOTARY_PROFILE is not set.

Notarization needs a notarytool credential profile stored in your
keychain. Create one once with:

  xcrun notarytool store-credentials <profile-name> \\
    --apple-id <your-apple-id> --team-id <TEAMID> --password <app-specific-password>

Then set OMNIAGENT_NOTARY_PROFILE=<profile-name> and re-run this command.
EOF
    exit 1
  fi

  if ! xcrun notarytool history --keychain-profile "$profile" >/dev/null 2>&1; then
    cat >&2 <<EOF
$0 notarize: no stored credential profile named "$profile" was found (or it
is invalid). Create/recreate it with:

  xcrun notarytool store-credentials $profile \\
    --apple-id <your-apple-id> --team-id <TEAMID> --password <app-specific-password>
EOF
    exit 1
  fi

  zip="${app%.app}.zip"
  echo "$0 notarize: zipping $app -> $zip..." >&2
  ditto -c -k --keepParent "$app" "$zip"

  echo "$0 notarize: submitting to Apple notary service..." >&2
  xcrun notarytool submit "$zip" --keychain-profile "$profile" --wait

  echo "$0 notarize: stapling ticket to $app..." >&2
  xcrun stapler staple "$app"
  echo "$0 notarize: done." >&2
}

# --- verify: bundle-structure check, Gatekeeper assessment, packaged smoke ---

verify() {
  status=0

  echo "$0 verify: bundle structure --------------------------------------" >&2
  find "$app/Contents/MacOS" "$app/Contents/Library/LaunchAgents" -maxdepth 1 2>&1 || true
  if [ ! -x "$daemon" ]; then
    echo "$0 verify: FAIL missing executable daemon at $daemon" >&2
    status=1
  fi
  plist_count=$(find "$app/Contents/Library/LaunchAgents" -name '*.plist' 2>/dev/null | wc -l | tr -d ' ')
  if [ "$plist_count" -lt 1 ]; then
    echo "$0 verify: FAIL no LaunchAgent plist found under $app/Contents/Library/LaunchAgents" >&2
    status=1
  fi

  echo "$0 verify: Gatekeeper assessment --------------------------------" >&2
  if spctl --assess --type execute --verbose=2 "$app"; then
    echo "$0 verify: Gatekeeper accepts the app." >&2
  else
    echo "$0 verify: Gatekeeper rejected the app (expected until it is both signed and notarized -- see 'dist.sh sign'/'dist.sh notarize')." >&2
    status=1
  fi

  echo "$0 verify: packaged PTY smoke -----------------------------------" >&2
  if ! python3 "$root/scripts/native-macos-pty-harness.py" smoke "$app"; then
    cat >&2 <<EOF
$0 verify: FAIL packaged PTY smoke

Known pre-existing issue, not a Task 6d/distribution defect: this harness
(scripts/native-macos-pty-harness.py, added in Task 1) still speaks Task
1's original per-request JSON-over-a-newline protocol. Task 2 replaced the
daemon's wire protocol with the persistent 16-byte-envelope framing
(crates/omniagent-pty-daemon/src/server.rs's MessageKind-based Hello/
HelloAck handshake) and the harness was never updated for that rewrite, so
it fails to get a response from ANY current daemon build, packaged or not
-- see the Task 6d report for how this was confirmed against the
unmodified, pre-Task-6d harness too.
EOF
    status=1
  fi

  return $status
}

$action
