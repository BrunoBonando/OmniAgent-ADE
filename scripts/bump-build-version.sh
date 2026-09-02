#!/usr/bin/env bash
# Bumps the native app's sequential MAJOR.MINOR.PATCH version in
# macos/OmniAgent.xcodeproj. MARKETING_VERSION and CURRENT_PROJECT_VERSION
# are always set to the same value -- a plain X.Y.Z is already a legal
# CFBundleShortVersionString *and* CFBundleVersion, so there's no need to
# split them the way the old date-based scheme (YYYY.M.D+NNN) did.
#
# Default: patch += 1 (a deploy).            1.6.234 -> 1.6.235
# --minor: minor += 1, patch resets to 1.     1.6.234 -> 1.7.1
# --major: major += 1, minor+patch reset.     1.6.234 -> 2.0.1
#
# Applied to every app-target build configuration that carries the keys
# (Debug/Release/Preview); the test target and project-level configs
# deliberately do not carry a user-visible version.
set -euo pipefail

bump="patch"
XCODE_PROJECT=""
for arg in "$@"; do
  case "$arg" in
    --major) bump="major" ;;
    --minor) bump="minor" ;;
    *) XCODE_PROJECT="$arg" ;;
  esac
done

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
XCODE_PROJECT="${XCODE_PROJECT:-$ROOT_DIR/macos/OmniAgent.xcodeproj/project.pbxproj}"

python3 - "$XCODE_PROJECT" "$bump" <<'PY'
import re
import sys
from pathlib import Path

xcode_project = Path(sys.argv[1])
bump = sys.argv[2]
EXPECTED_XCODE_CONFIGS = 3

text = xcode_project.read_text()
marketing = re.findall(r"^\s*MARKETING_VERSION = ([^;]*);", text, re.MULTILINE)
current = re.findall(r"^\s*CURRENT_PROJECT_VERSION = ([^;]*);", text, re.MULTILINE)
if len(marketing) != EXPECTED_XCODE_CONFIGS or len(current) != EXPECTED_XCODE_CONFIGS:
    raise SystemExit(
        f"bump-build-version.sh: expected {EXPECTED_XCODE_CONFIGS} MARKETING_VERSION/"
        f"CURRENT_PROJECT_VERSION lines in {xcode_project}, found {len(marketing)}/{len(current)}"
        " -- did a build configuration get added or removed?"
    )

# Both keys must already be the same X.Y.Z triple -- that's how the new
# scheme is told apart from the old date-based one (where CURRENT_PROJECT_VERSION
# was a bare daily counter like "2", not a dotted triple). Anything else means
# this is the first bump under the new scheme: seed at 1.0.0.
triple = r"(\d+)\.(\d+)\.(\d+)"
mkt_match = re.fullmatch(triple, marketing[0].strip())
cur_match = re.fullmatch(triple, current[0].strip())
if mkt_match and cur_match and mkt_match.groups() == cur_match.groups():
    major, minor, patch = (int(g) for g in mkt_match.groups())
else:
    major, minor, patch = 1, 0, 0

if bump == "major":
    major, minor, patch = major + 1, 0, 1
elif bump == "minor":
    minor, patch = minor + 1, 1
else:
    patch += 1

version = f"{major}.{minor}.{patch}"
for key in ("MARKETING_VERSION", "CURRENT_PROJECT_VERSION"):
    text = re.sub(rf"^(\s*{key} = )[^;]*;", lambda m: f"{m.group(1)}{version};", text, flags=re.MULTILINE)
xcode_project.write_text(text)
print(version)
PY
