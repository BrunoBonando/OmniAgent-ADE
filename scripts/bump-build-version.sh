#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TAURI_CONF="$ROOT_DIR/src-tauri/tauri.conf.json"
UI_PACKAGE="$ROOT_DIR/ui/package.json"
TAURI_CARGO_TOML="$ROOT_DIR/src-tauri/Cargo.toml"

python3 - "$TAURI_CONF" "$UI_PACKAGE" "$TAURI_CARGO_TOML" <<'PY'
import datetime
import json
import re
import sys
from pathlib import Path

tauri_conf = Path(sys.argv[1])
ui_package = Path(sys.argv[2])
tauri_cargo_toml = Path(sys.argv[3])

today = datetime.date.today()
prefix = f"{today.year}.{today.month}.{today.day}"
pattern = re.compile(r"^(\d{4})\.(\d{1,2})\.(\d{1,2})(?:\+(\d{3}))?$")

conf = json.loads(tauri_conf.read_text())
current = str(conf.get("version", "")).strip()
match = pattern.match(current)
if match and f"{int(match.group(1))}.{int(match.group(2))}.{int(match.group(3))}" == prefix:
    patch = int(match.group(4) or "0") + 1
else:
    patch = 1

next_version = f"{prefix}+{patch:03d}"
conf["version"] = next_version
tauri_conf.write_text(json.dumps(conf, indent=2) + "\n")

ui = json.loads(ui_package.read_text())
ui["version"] = next_version
ui_package.write_text(json.dumps(ui, indent=2) + "\n")

# src-tauri/Cargo.toml's own [package] version must stay in lockstep with
# tauri.conf.json's -- src-tauri/src/lib.rs's
# the_titles_version_is_the_one_tauri_conf_json_declares test asserts
# exactly this (env!("CARGO_PKG_VERSION") vs. tauri.conf.json's declared
# version), and it previously drifted because this script only touched
# tauri.conf.json/ui/package.json (found while verifying Task 7 of
# docs/plans/native-macos-migration.md). A plain regex substitution (not a
# TOML parser) to avoid adding a dependency for one field, anchored on the
# `[package]` table's own `version = "..."` line so it can't touch an
# unrelated dependency's `version = "..."` entry elsewhere in the file.
cargo_toml_text = tauri_cargo_toml.read_text()
package_table_pattern = re.compile(r"(\[package\]\n(?:[^\n]*\n)*?version = )\"[^\"]*\"")
new_cargo_toml_text, n = package_table_pattern.subn(
    lambda m: f'{m.group(1)}"{next_version}"', cargo_toml_text, count=1
)
if n != 1:
    raise SystemExit(
        f"bump-build-version.sh: could not find [package]'s version line in {tauri_cargo_toml}"
    )
tauri_cargo_toml.write_text(new_cargo_toml_text)

print(next_version)
PY
