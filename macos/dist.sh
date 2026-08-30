#!/bin/sh
# Distribution steps for the built OmniAgent.app: hardened-runtime signing,
# notarization/stapling, and Gatekeeper/install smoke verification.
# Sibling to macos/build.sh, same shell style and subcommand dispatch.
# Build the app first (./macos/build.sh universal for a distributable
# artifact), then run these against the resulting .app path.
set -eu

# Subcommands:
#   sign        hardened-runtime codesign of the embedded daemon + the bundle
#   notarize    submit to Apple, wait, staple
#   verify      bundle structure + Gatekeeper assessment  <- the release gate
#   verify-smoke  the packaged PTY smoke check, KNOWN BROKEN, opt-in only
#   preflight   store-readiness gate: signature/entitlement/bundle-metadata
#               checks App Review and notarization look at. Add --mas to
#               also fail the MAS-only gaps (app sandbox, sandboxed socket
#               path, MAS build lane), which otherwise only report.
#
# Why `verify-smoke` is a separate subcommand and not part of `verify`
# (final whole-branch review, Important #3): the smoke check shells out to
# scripts/native-macos-pty-harness.py, which still speaks Task 1's original
# per-request JSON-over-a-newline protocol. Task 2 replaced the daemon's wire
# format with the persistent 16-byte-envelope framing and the harness was
# never updated, so it cannot get a response out of ANY current daemon build,
# packaged or not (independently confirmed against the unmodified harness in
# both the Task 6d and Task 7 reports). While it was wired into `verify`,
# `verify` could never exit 0 -- which trains everyone to ignore the exit
# code of the one command that is supposed to be the release gate, and
# quietly voids the bundle-structure and Gatekeeper checks it also performs.
# Rewriting the harness onto the current protocol is a real piece of work
# that both prior tasks deliberately deferred; splitting it out here is not
# that fix, it is what makes `verify`'s exit code mean something again in the
# meantime. Run `verify-smoke` explicitly if you are working on the harness.
action=${1:-}
case "$action" in
  sign|notarize|verify|verify-smoke|preflight) ;;
  *)
    echo "usage: $0 sign|verify|verify-smoke|preflight <path-to-OmniAgent.app>" >&2
    echo "       $0 preflight <path-to-OmniAgent.app> [--mas]" >&2
    echo "       $0 notarize <path-to-OmniAgent.app|path-to.dmg>" >&2
    echo "  (verify-smoke is a known-broken harness check, opt-in only -- see this script's comments)" >&2
    exit 2
    ;;
esac

app=${2:-}
[ -n "$app" ] || { echo "usage: $0 $action <path>" >&2; exit 2; }
# `notarize` is the one subcommand that also takes a disk image; everything
# else operates on the bundle itself.
case "$action:$app" in
  notarize:*.dmg)
    [ -f "$app" ] || { echo "$0: no such disk image: $app" >&2; exit 1; }
    ;;
  *)
    [ -d "$app" ] || { echo "$0: no such app bundle: $app" >&2; exit 1; }
    ;;
esac

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
entitlements="$root/macos/OmniAgent/OmniAgent.entitlements"
daemon="$app/Contents/MacOS/omniagent-pty-daemon"

# --- sign: hardened-runtime codesign, app + embedded daemon, same identity ---

# The identity to sign with when OMNIAGENT_CODESIGN_IDENTITY is not set: the
# keychain's Developer ID Application certificate, when there is exactly one.
#
# This fallback exists because an unsigned build is not just unshippable, it is
# hostile to daily use. macOS keys folder-access (TCC) grants -- Documents,
# Desktop, Downloads -- to an app's code-signing identity. An ad-hoc or
# linker-signed bundle has no stable one, so its identity is effectively its
# cdhash, which changes on every single build: every rebuild looks like a
# brand-new app and macOS asks for folder access all over again. A real
# Developer ID gives the bundle a designated requirement that survives
# rebuilds, so the grant is given once and kept.
#
# Exactly one, deliberately: with several Developer IDs in the keychain there is
# no obviously right answer, and silently picking the first would sign releases
# with whichever certificate happened to sort first.
default_identity() {
  found=$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -F "Developer ID Application" \
    | sed -n 's/.*"\(.*\)".*/\1/p' \
    | sort -u)
  [ -n "$found" ] || return 1
  [ "$(printf '%s\n' "$found" | wc -l | tr -d ' ')" = "1" ] || return 1
  printf '%s\n' "$found"
}

sign() {
  identity=${OMNIAGENT_CODESIGN_IDENTITY:-}
  if [ -z "$identity" ]; then
    identity=$(default_identity || true)
    [ -n "$identity" ] && echo "$0 sign: using keychain identity \"$identity\"." >&2
  fi
  if [ -z "$identity" ]; then
    cat >&2 <<EOF
$0 sign: OMNIAGENT_CODESIGN_IDENTITY is not set, and the keychain does not
hold exactly one "Developer ID Application" identity to fall back on.

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

  # Hard failure, not a warning (final whole-branch review, Important #3).
  # An OmniAgent.app with no embedded daemon is not a shippable artifact --
  # the app has no PTY backend at all -- and signing one produces a
  # convincingly signed, notarizable, completely non-functional bundle. This
  # used to only warn, on the theory that `verify`'s bundle-structure check
  # was the backstop; that backstop lived inside a subcommand whose exit code
  # could never be 0 (see the header comment). Same fail-clearly posture this
  # function already takes for a missing signing identity or entitlements
  # file.
  if [ ! -f "$daemon" ]; then
    cat >&2 <<EOF
$0 sign: no daemon binary embedded at
  $daemon

The app bundle has no PTY backend, so signing it would produce a validly
signed but non-functional artifact. Build a distributable bundle first:

  ./macos/build.sh universal

(which runs macos/embed-daemon.sh and the Xcode "Embed PTY Daemon and
LaunchAgent Plists" phase). Note that Debug builds deliberately skip the
embed step -- sign a Release or Preview build.
EOF
    exit 1
  fi

  echo "$0 sign: signing embedded daemon ($daemon)..." >&2
  codesign --force --options runtime --timestamp --sign "$identity" "$daemon"

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

  case "$app" in
    *.dmg)
      # A disk image must be SIGNED as well as notarized, and this is the step
      # that is easy to miss: `stapler staple` reports "The staple and validate
      # action worked!" on an *unsigned* .dmg, and notarization accepts it too,
      # because both are judging the app inside. Only `spctl -a -t open`
      # notices, as "source=no usable signature" -- i.e. the artifact looks
      # finished by every check you are likely to run, and still trips
      # Gatekeeper on the machine you sent it to. So sign first, always.
      identity=${OMNIAGENT_CODESIGN_IDENTITY:-}
      [ -n "$identity" ] || identity=$(default_identity || true)
      if [ -z "$identity" ]; then
        echo "$0 notarize: no signing identity for the disk image (set OMNIAGENT_CODESIGN_IDENTITY)." >&2
        exit 1
      fi
      echo "$0 notarize: signing disk image ($app)..." >&2
      codesign --force --timestamp --sign "$identity" "$app"
      submission=$app
      ;;
    *)
      submission="${app%.app}.zip"
      echo "$0 notarize: zipping $app -> $submission..." >&2
      ditto -c -k --keepParent "$app" "$submission"
      ;;
  esac

  echo "$0 notarize: submitting to Apple notary service..." >&2
  xcrun notarytool submit "$submission" --keychain-profile "$profile" --wait

  echo "$0 notarize: stapling ticket to $app..." >&2
  xcrun stapler staple "$app"

  # Prove it rather than trust it. `stapler` succeeding is not evidence that
  # Gatekeeper will accept the artifact -- see the disk-image note above.
  echo "$0 notarize: asking Gatekeeper..." >&2
  case "$app" in
    *.dmg) spctl -a -vv -t open --context context:primary-signature "$app" ;;
    *) spctl -a -vv "$app" ;;
  esac
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

  if [ "$status" -eq 0 ]; then
    echo "$0 verify: OK (bundle structure + Gatekeeper)." >&2
  fi
  echo "$0 verify: note: the packaged PTY smoke check is NOT part of this gate -- run '$0 verify-smoke $app' for it (known broken, see this script's header)." >&2
  return $status
}

# --- preflight: what App Review / notarisation looks at before anything runs ---
# Developer-ID facts fail the run. The "MAS gate" section only reports (the
# sandbox is absent by decision -- docs/appstore-rejection-risks.html) unless
# `--mas` is given, which turns those lines into failures too.
#
# Called via `preflight "$@"` from the dispatch case below (not bare, unlike
# sign/notarize/verify) specifically so $3 here is the script's own third
# argument -- a bare call clears a function's positional parameters even
# though $app etc. remain visible as ordinary globals.
preflight() {
  want_mas=0; [ "${3:-}" = "--mas" ] && want_mas=1
  status=0
  fail() { echo "$0 preflight: FAIL $*" >&2; status=1; }
  mas()  { if [ "$want_mas" = 1 ]; then fail "[MAS] $*"; else echo "$0 preflight: MAS-GATE $*" >&2; fi; }
  info="$app/Contents/Info.plist"

  echo "$0 preflight: signatures ------------------------------------------" >&2
  app_team=$(codesign -dv "$app" 2>&1 | sed -n 's/^TeamIdentifier=//p')
  daemon_team=$(codesign -dv "$daemon" 2>&1 | sed -n 's/^TeamIdentifier=//p')
  [ -n "$app_team" ] || fail "app is not signed with a Team ID"
  [ "$app_team" = "$daemon_team" ] || fail "daemon Team ID ($daemon_team) != app Team ID ($app_team)"
  codesign -dv "$daemon" 2>&1 | grep -q 'flags=.*runtime' || fail "daemon lacks hardened runtime"

  echo "$0 preflight: entitlements ----------------------------------------" >&2
  ents=$(codesign -d --entitlements :- "$app" 2>/dev/null || true)
  echo "$ents" | grep -q 'get-task-allow' && fail "com.apple.security.get-task-allow present (debug entitlement)"
  echo "$ents" | grep -q 'com.apple.security.app-sandbox' || mas "App Sandbox entitlement absent"

  echo "$0 preflight: bundle metadata -------------------------------------" >&2
  [ -f "$app/Contents/Resources/PrivacyInfo.xcprivacy" ] || fail "PrivacyInfo.xcprivacy missing"
  for key in LSApplicationCategoryType NSHumanReadableCopyright ITSAppUsesNonExemptEncryption \
             NSDocumentsFolderUsageDescription NSDesktopFolderUsageDescription NSDownloadsFolderUsageDescription; do
    /usr/libexec/PlistBuddy -c "Print :$key" "$info" >/dev/null 2>&1 || fail "Info.plist lacks $key"
  done
  plist=$(find "$app/Contents/Library/LaunchAgents" -name '*.plist' | head -1)
  [ -n "$plist" ] || fail "no LaunchAgent plist"
  [ -n "$plist" ] && { /usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$plist" | grep -q '^Contents/MacOS/' \
    || fail "LaunchAgent Program is not bundle-relative"; }
  [ -f "$app/Contents/Resources/Legal/privacy-policy.html" ] || fail "bundled privacy policy missing (Task B1)"
  [ -f "$app/Contents/Resources/Legal/third-party-notices.html" ] || fail "bundled third-party notices missing (Task B1)"

  echo "$0 preflight: MAS gate (informational unless --mas) -----------------" >&2
  mas "socket path ~/.omniagent-ade is outside any sandbox container (D1)"
  mas "no Mac App Store build configuration / archive lane (D1)"

  [ "$status" = 0 ] && echo "$0 preflight: OK" >&2
  return $status
}

# --- verify-smoke: the packaged PTY smoke check, opt-in and known broken ---

verify_smoke() {
  echo "$0 verify-smoke: packaged PTY smoke ------------------------------" >&2
  if python3 "$root/scripts/native-macos-pty-harness.py" smoke "$app"; then
    echo "$0 verify-smoke: OK." >&2
    return 0
  fi
  cat >&2 <<EOF
$0 verify-smoke: FAIL packaged PTY smoke

EXPECTED until the harness is rewritten. Known pre-existing issue, not a
distribution defect: this harness (scripts/native-macos-pty-harness.py,
added in Task 1) still speaks Task 1's original per-request
JSON-over-a-newline protocol. Task 2 replaced the daemon's wire protocol
with the persistent 16-byte-envelope framing
(crates/omniagent-pty-daemon/src/server.rs's MessageKind-based Hello/
HelloAck handshake) and the harness was never updated for that rewrite, so
it fails to get a response from ANY current daemon build, packaged or not
-- confirmed against the unmodified, pre-Task-6d harness in both the Task
6d and Task 7 reports.

This is why the check is not part of '$0 verify': a permanently red gate is
a gate nobody reads. Fixing it means porting the harness onto the current
framing, which is its own piece of work.
EOF
  return 1
}

case "$action" in
  verify-smoke) verify_smoke ;;
  preflight) preflight "$@" ;;
  *) $action ;;
esac
