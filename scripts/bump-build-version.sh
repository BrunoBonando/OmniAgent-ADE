#!/usr/bin/env bash
# Bumps the native app's date-based build version (YYYY.M.D+NNN) in
# macos/OmniAgent.xcodeproj. The version is split across two keys because
# `2026.8.3+001` is not a legal CFBundleShortVersionString (Apple: one to
# three period-separated integers): the date triple is MARKETING_VERSION and
# the same-day counter is CURRENT_PROJECT_VERSION. SettingsView.swift's
# `NativeAppVersion.current()` recombines them into the full string for the
# About tab. Applied to every app-target build configuration that carries the
# keys (Debug/Release/Preview); the test target and project-level configs
# deliberately do not carry a user-visible version.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
XCODE_PROJECT="${1:-$ROOT_DIR/macos/OmniAgent.xcodeproj/project.pbxproj}"

python3 - "$XCODE_PROJECT" <<'PY'
import datetime
import re
import sys
from pathlib import Path

xcode_project = Path(sys.argv[1])
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

today = datetime.date.today()
prefix = f"{today.year}.{today.month}.{today.day}"
patch = int(current[0]) + 1 if marketing[0].strip() == prefix else 1

for key, value in (("MARKETING_VERSION", prefix), ("CURRENT_PROJECT_VERSION", str(patch))):
    text = re.sub(rf"^(\s*{key} = )[^;]*;", lambda m: f"{m.group(1)}{value};", text, flags=re.MULTILINE)
xcode_project.write_text(text)
print(f"{prefix}+{patch:03d}")
PY
