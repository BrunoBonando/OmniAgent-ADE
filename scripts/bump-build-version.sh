#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TAURI_CONF="$ROOT_DIR/src-tauri/tauri.conf.json"
UI_PACKAGE="$ROOT_DIR/ui/package.json"

python3 - "$TAURI_CONF" "$UI_PACKAGE" <<'PY'
import datetime
import json
import re
import sys
from pathlib import Path

tauri_conf = Path(sys.argv[1])
ui_package = Path(sys.argv[2])

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

print(next_version)
PY
