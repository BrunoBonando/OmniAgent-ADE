#!/usr/bin/env python3
"""Decision logic + destructive-removal logic behind ``scripts/cutover.sh``.

Task 7 (Phase 7 cutover, ``docs/plans/native-macos-migration.md``) requires a
release-gated cutover script that refuses to delete the web terminal hot path
(xterm.js, React Mosaic, the Tauri-side terminal events/commands and its
duplicate daemon-protocol client, proxy-PTY remnants, and the frontend
terminal buffer) until **two real release-candidate cycles** have been
recorded. This module is that gate, plus the (currently unreachable, because
the gate stays shut) removal logic for when it eventually opens.

Importable so ``scripts/test_cutover.py`` can unit-test the decision logic
directly (cycle counting, gate open/closed, record/status formatting)
without shelling out for every case, following the same pattern as
``scripts/native-macos-pty-harness.py`` / ``scripts/test_native_macos_pty_harness.py``.

## Why "record" is a separate, manual step

A release-candidate "cycle" means: a build was actually shipped to real
users/testers running the native app under production-adjacent conditions,
for a real evaluation window -- not "I ran ``macos/build.sh universal``
locally". This script has no way to verify that a recorded cycle was real;
that trust boundary is a human's, not code's. Recording is therefore **not**
wired into ``scripts/bump-build-version.sh`` or ``scripts/rebuild-app.sh`` --
either of those can run any number of times a day, and auto-recording a
cycle on every local build/version-bump would make the two-cycle
requirement trivially satisfiable by running a build script twice, which
defeats the entire point of the gate. A human runs ``cutover.sh record``
by hand, after a real RC has actually gone out and been evaluated.

## Why the removal list is discovered, not just hardcoded

Some of what bullet 2 removes is unambiguous today (four npm packages, two
whole Rust modules). But by the time the gate is actually open -- after two
real release cycles, i.e. not this session, not soon -- the codebase will
have moved on, and a snapshot-in-time file list silently goes stale (new
example files added, files renamed, etc). So the parts of `perform_cutover`
that touch a *set* of files (the ``src-tauri/examples`` and
``src-tauri/tests`` files that depend on the modules being removed) rescan
the tree at cutover time via the same dependency signal a human would use,
rather than trusting a list written back in 2026. Anything the scan can't
resolve with confidence is left for the printed manual-follow-up checklist
instead of being guessed at destructively.
"""

from __future__ import annotations

import argparse
import datetime
import json
import re
import subprocess
import sys
from pathlib import Path
from typing import Optional

REQUIRED_CYCLES = 2
DEFAULT_LOG_RELPATH = "scripts/cutover-rc-log.jsonl"

# ---------------------------------------------------------------------------
# Gate decision logic (the part with real behavior to unit-test)
# ---------------------------------------------------------------------------


def load_cycles(log_path: Path) -> list[dict]:
    """Reads the append-only JSONL cycle log. Missing file == zero cycles."""
    if not log_path.exists():
        return []
    cycles = []
    for lineno, raw in enumerate(log_path.read_text().splitlines(), start=1):
        line = raw.strip()
        if not line:
            continue
        try:
            cycles.append(json.loads(line))
        except json.JSONDecodeError as e:
            raise ValueError(f"{log_path}:{lineno}: not valid JSON: {e}") from e
    return cycles


def gate_open(cycles: list[dict]) -> bool:
    """The entire gate: at least REQUIRED_CYCLES recorded cycles."""
    return len(cycles) >= REQUIRED_CYCLES


def record_cycle(
    log_path: Path, version: str, recorded_by: str, note: str
) -> dict:
    """Appends one cycle record. Append-only: never rewrites prior lines."""
    if not version.strip():
        raise ValueError("version must not be empty")
    entry = {
        "date": datetime.datetime.now(datetime.timezone.utc).strftime(
            "%Y-%m-%dT%H:%M:%SZ"
        ),
        "version": version,
        "recorded_by": recorded_by,
        "note": note,
    }
    log_path.parent.mkdir(parents=True, exist_ok=True)
    with log_path.open("a") as f:
        f.write(json.dumps(entry, sort_keys=True) + "\n")
    return entry


def default_by() -> str:
    try:
        out = subprocess.run(
            ["git", "config", "user.name"],
            capture_output=True,
            text=True,
            timeout=5,
        )
        name = out.stdout.strip()
        if out.returncode == 0 and name:
            return name
    except Exception:
        pass
    import getpass

    return getpass.getuser()


def default_version(root: Path) -> Optional[str]:
    conf = root / "src-tauri" / "tauri.conf.json"
    try:
        data = json.loads(conf.read_text())
        v = data.get("version")
        return str(v) if v else None
    except Exception:
        return None


# ---------------------------------------------------------------------------
# The checklist: what bullet 2 removes and what it retains
# ---------------------------------------------------------------------------

REMOVE_ITEMS = [
    "ui/package.json: @xterm/xterm, @xterm/addon-fit, @xterm/addon-webgl, "
    "react-mosaic-component dependencies",
    "ui/src/components/Terminal.tsx (xterm.js terminal surface + its "
    "in-memory scrollback/output buffer)",
    "ui/src/components/Workspace.tsx and its tests (Workspace.visibility."
    "test.tsx, Workspace.initialLayout.test.tsx, Workspace.mountStability."
    "test.tsx) -- the react-mosaic-component pane grid",
    "ui/src/components/PaneHeader.tsx + PaneHeader.test.tsx",
    "ui/src/components/PaneMenu.tsx + PaneMenu.test.tsx",
    "ui/src/state/paneGrid.ts + paneGrid.test.ts (web pane-layout model; "
    "PaneGrid.swift in the native app is the ported, retained equivalent)",
    "ui/src/lib/terminalThemes.ts + terminalThemes.test.ts",
    "src-tauri/src/sessions.rs -- the Tauri-side session/PTY compatibility "
    "adapter (a *duplicate* client of the daemon protocol; the daemon "
    "itself, and the native app's own SessionConnection.swift client, are "
    "not touched)",
    "src-tauri/src/daemon.rs -- the Tauri-side daemon-protocol client "
    "(same duplicate-client rationale)",
    "src-tauri/src/lib.rs: the session-output/session-attention/"
    "session-status Tauri event emission and SessionManager app.manage() "
    "wiring in run()'s setup() closure",
    "src-tauri/src/commands/mod.rs: the session_create/session_write/"
    "session_resize/session_kill/session_status/session_has_working_tasks/"
    "session_stop_working_tasks #[tauri::command] wrappers, and their "
    "entries in lib.rs's invoke_handler![...] list",
    "src-tauri/tests/{session_test.rs, session_persistence_test.rs, "
    "daemon_client_protocol.rs, native_macos_compatibility_test.rs}",
    "fixtures/native-macos-compat/{rust-session-models.json, "
    "status-end-events.json, persisted-layout.json, pane-grid.json} -- "
    "compatibility fixtures for the tests just listed",
    "src-tauri/examples/manual_*.rs files that depend on sessions::/"
    "daemon:: (discovered at cutover time by dependency scan, not a fixed "
    "list -- currently: manual_attention_verify.rs, "
    "manual_black_pane_verify.rs, manual_claude_verify.rs, "
    "manual_color_verify.rs, manual_daemon_persistence_verify.rs, "
    "manual_multi_pane_conversation_verify.rs, "
    "manual_path_resolution_verify.rs, manual_status_verify.rs)",
]

MANUAL_FOLLOWUP_ITEMS = [
    "ui/src/App.tsx: drop the <Workspace> import/render and the terminal-"
    "session tab-creation wiring it drives; KEEP the broader project/"
    "workspace-tab bookkeeping (openWorkspaces/closedWorkspaces etc) other "
    "surfaces (Sidebar, BrainMap) still use -- entangled enough with "
    "non-terminal concerns that this needs a human pass, not a blind regex",
    "ui/src/App.css: drop the xterm/mosaic-specific rules (grep -n "
    "'xterm\\|mosaic' ui/src/App.css)",
    "ui/src/state/keyboardShortcuts.ts: drop the mosaic-grid-specific "
    "shortcut/comment (grep -n mosaic ui/src/state/keyboardShortcuts.ts)",
    "src-tauri/src/feedback.rs: drop on_session_end() and its two private "
    "helpers (read_transcript_tail, git_diff_stat); KEEP pending_notes_list/"
    "approve/discard, which are an unrelated brain-review feature that "
    "happens to live in the same file",
    "src-tauri/tests/feedback_test.rs: drop/rewrite the session-end-"
    "triggers-feedback test(s) that construct a real SessionManager; keep "
    "any pending-notes-only tests",
    "src-tauri/Cargo.toml: after the above, check whether `portable-pty` "
    "is still referenced anywhere under src-tauri/src or src-tauri/"
    "examples; if not, remove that dependency line. Do NOT touch "
    "crates/omniagent-pty-daemon's own portable-pty dependency -- the "
    "daemon remains the sole real PTY owner",
    "Re-run this brief's full verification pass (cargo build/test/clippy, "
    "npm --prefix ui run test, ./macos/build.sh test/build, cargo test -p "
    "omniagent-pty-daemon, packaging smoke) after the above, before "
    "committing the cutover",
]

RETAIN_ITEMS = [
    "The Tauri rollback artifact: a signed/notarized build of the last "
    "pre-cutover Tauri release, archived for one release cycle as a "
    "rollback option, per the plan text",
    "Every other Tauri command/UI surface not listed above (brain, roots/"
    "ingestion, settings, file-tree, code-review) -- unrelated to the "
    "terminal hot path, and keeps working through this same Tauri app for "
    "that one retained release",
    "crates/omniagent-pty-daemon in full -- it is the real PTY owner both "
    "the (soon-removed) Tauri client and the native macOS app talk to; "
    "this cutover removes the Tauri side's *duplicate* client of it, not "
    "the daemon",
    "The native macOS app (macos/) -- becomes production, unaffected",
]


def format_checklist() -> str:
    lines = ["Removes (bullet 2, automated where safe):"]
    lines += [f"  - {item}" for item in REMOVE_ITEMS]
    lines.append("")
    lines.append("Requires a manual follow-up pass (entangled, not automated):")
    lines += [f"  - {item}" for item in MANUAL_FOLLOWUP_ITEMS]
    lines.append("")
    lines.append("Retains:")
    lines += [f"  - {item}" for item in RETAIN_ITEMS]
    return "\n".join(lines)


def format_status(cycles: list[dict], log_path: Path) -> str:
    lines = [f"cutover.sh status: log = {log_path}"]
    lines.append(f"  {len(cycles)}/{REQUIRED_CYCLES} release-candidate cycles recorded")
    for i, c in enumerate(cycles, start=1):
        note = f" -- {c.get('note')}" if c.get("note") else ""
        lines.append(
            f"    {i}. {c.get('date', '?')}  version={c.get('version', '?')}"
            f"  by={c.get('recorded_by', '?')}{note}"
        )
    if gate_open(cycles):
        lines.append(
            f"  GATE: OPEN ({len(cycles)}/{REQUIRED_CYCLES}) -- "
            "`cutover.sh cutover --yes` will perform the removal."
        )
    else:
        missing = REQUIRED_CYCLES - len(cycles)
        lines.append(
            f"  GATE: CLOSED ({len(cycles)}/{REQUIRED_CYCLES} recorded, "
            f"{missing} more needed) -- `cutover.sh cutover` refuses."
        )
    lines.append("")
    lines.append(format_checklist())
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# The removal logic itself -- real code, reachable only when the gate is
# open. It has never run against this repo (0/2 cycles recorded), by design.
# ---------------------------------------------------------------------------


class CutoverAbort(RuntimeError):
    """Raised when a precondition the removal logic depends on doesn't hold
    -- i.e. the codebase has drifted since this script was written. Aborts
    loudly rather than silently doing the wrong thing to a file it no
    longer understands."""


NPM_DEPS_TO_REMOVE = [
    "@xterm/xterm",
    "@xterm/addon-fit",
    "@xterm/addon-webgl",
    "react-mosaic-component",
]

WHOLE_FILES_TO_REMOVE = [
    "ui/src/components/Terminal.tsx",
    "ui/src/components/Workspace.tsx",
    "ui/src/components/Workspace.visibility.test.tsx",
    "ui/src/components/Workspace.initialLayout.test.tsx",
    "ui/src/components/Workspace.mountStability.test.tsx",
    "ui/src/components/PaneHeader.tsx",
    "ui/src/components/PaneHeader.test.tsx",
    "ui/src/components/PaneMenu.tsx",
    "ui/src/components/PaneMenu.test.tsx",
    "ui/src/state/paneGrid.ts",
    "ui/src/state/paneGrid.test.ts",
    "ui/src/lib/terminalThemes.ts",
    "ui/src/lib/terminalThemes.test.ts",
    "src-tauri/src/sessions.rs",
    "src-tauri/src/daemon.rs",
    "src-tauri/tests/session_test.rs",
    "src-tauri/tests/session_persistence_test.rs",
    "src-tauri/tests/daemon_client_protocol.rs",
    "src-tauri/tests/native_macos_compatibility_test.rs",
    "fixtures/native-macos-compat/rust-session-models.json",
    "fixtures/native-macos-compat/status-end-events.json",
    "fixtures/native-macos-compat/persisted-layout.json",
    "fixtures/native-macos-compat/pane-grid.json",
]

# Rust import paths whose presence in an examples/ file marks it as a
# dependent of the modules being removed -- used to *discover* the
# manual_*_verify.rs files to delete rather than trusting a fixed list.
RUST_DEPENDENT_MARKERS = (
    "omniagent_ade_lib::sessions",
    "omniagent_ade_lib::daemon",
    "crate::sessions",
    "crate::daemon",
)

# Known to be entangled with a *retained* concern (feedback.rs's
# pending_notes_* commands) -- excluded from the automatic dependency scan
# and left on the manual-follow-up checklist instead of being deleted
# whole, so cutover doesn't remove pending_notes_* along with it.
RUST_DEPENDENT_EXCLUDE_FROM_AUTO_DELETE = {"src-tauri/tests/feedback_test.rs"}

LIB_RS_BLOCK_START = "            let output_handle = handle.clone();"
LIB_RS_BLOCK_END = (
    "                    .with_status_sink(status_sink),\n            );\n"
)

COMMANDS_MOD_FUNCTIONS_TO_REMOVE = [
    "session_create",
    "session_status",
    "session_has_working_tasks",
    "session_stop_working_tasks",
    "session_write",
    "session_resize",
    "session_kill",
]

INVOKE_HANDLER_LINES_TO_REMOVE = [
    f"            commands::{name},\n" for name in COMMANDS_MOD_FUNCTIONS_TO_REMOVE
]


def _remove_npm_deps(ui_package_json: Path) -> list[str]:
    data = json.loads(ui_package_json.read_text())
    removed = []
    for section in ("dependencies", "devDependencies"):
        deps = data.get(section, {})
        for dep in NPM_DEPS_TO_REMOVE:
            if dep in deps:
                del deps[dep]
                removed.append(f"{section}.{dep}")
    ui_package_json.write_text(json.dumps(data, indent=2) + "\n")
    return removed


def _discover_dependent_examples_and_tests(root: Path) -> list[str]:
    """Greps src-tauri/examples and src-tauri/tests for anything that still
    imports the modules WHOLE_FILES_TO_REMOVE deletes (sessions/daemon),
    beyond the whole-file list itself. This is what makes the removal list
    resilient to drift instead of a stale 2026 snapshot."""
    found = []
    for sub in ("src-tauri/examples", "src-tauri/tests"):
        d = root / sub
        if not d.is_dir():
            continue
        for f in sorted(d.glob("*.rs")):
            rel = f.relative_to(root).as_posix()
            if rel in WHOLE_FILES_TO_REMOVE:
                continue
            if rel in RUST_DEPENDENT_EXCLUDE_FROM_AUTO_DELETE:
                continue
            text = f.read_text()
            if any(marker in text for marker in RUST_DEPENDENT_MARKERS):
                found.append(rel)
    return found


def _remove_lib_rs_block(lib_rs: Path) -> None:
    text = lib_rs.read_text()
    start = text.find(LIB_RS_BLOCK_START)
    if start == -1:
        raise CutoverAbort(
            f"{lib_rs}: session-wiring block start marker not found -- "
            "the file has drifted since this script was written; update "
            "cutover_lib.py's LIB_RS_BLOCK_START/END by hand before "
            "retrying"
        )
    end_marker_pos = text.find(LIB_RS_BLOCK_END, start)
    if end_marker_pos == -1:
        raise CutoverAbort(
            f"{lib_rs}: session-wiring block end marker not found -- "
            "same drift concern as the start marker"
        )
    end = end_marker_pos + len(LIB_RS_BLOCK_END)
    new_text = text[:start] + text[end:]
    lib_rs.write_text(new_text)

    for line in INVOKE_HANDLER_LINES_TO_REMOVE:
        if line not in new_text:
            raise CutoverAbort(
                f"{lib_rs}: expected invoke_handler entry {line!r} not "
                "found -- the handler list has drifted since this script "
                "was written"
            )
    new_text = new_text
    for line in INVOKE_HANDLER_LINES_TO_REMOVE:
        new_text = new_text.replace(line, "", 1)
    lib_rs.write_text(new_text)


def _remove_commands_mod_functions(commands_mod: Path) -> list[str]:
    text = commands_mod.read_text()
    removed = []
    for name in COMMANDS_MOD_FUNCTIONS_TO_REMOVE:
        # Doc comments (contiguous `///` lines) directly above
        # `#[tauri::command]\npub fn NAME(...) -> ... { ... }`, up to the
        # function's own closing brace at column 0 (safe under rustfmt:
        # every nested block is indented, only the item's own `}` sits at
        # column 0).
        pattern = re.compile(
            r"(?:^///[^\n]*\n)*"
            r"^#\[tauri::command\]\n"
            r"pub fn " + re.escape(name) + r"\b.*?\n\}\n",
            re.MULTILINE | re.DOTALL,
        )
        new_text, n = pattern.subn("", text, count=1)
        if n == 0:
            raise CutoverAbort(
                f"{commands_mod}: function {name!r} not found in the "
                "expected #[tauri::command] shape -- drifted since this "
                "script was written"
            )
        text = new_text
        removed.append(name)
    commands_mod.write_text(text)
    return removed


def perform_cutover(root: Path, dry_run: bool) -> list[str]:
    """The real (gate-only-reachable) removal. Returns a log of actions
    taken (or, in dry-run mode, that would be taken)."""
    actions = []

    dependent_examples = _discover_dependent_examples_and_tests(root)
    all_whole_files = list(WHOLE_FILES_TO_REMOVE) + dependent_examples

    missing = [f for f in all_whole_files if not (root / f).exists()]
    if missing and not dry_run:
        raise CutoverAbort(
            "expected files are missing (already removed, or renamed since "
            f"this script was written): {missing}"
        )

    if dry_run:
        actions.append(f"[dry-run] would remove {len(all_whole_files)} files:")
        actions += [f"  [dry-run]   git rm -f {f}" for f in all_whole_files]
        actions.append(
            f"[dry-run] would prune npm deps: {', '.join(NPM_DEPS_TO_REMOVE)}"
        )
        actions.append("[dry-run] would excise the session-wiring block in src-tauri/src/lib.rs")
        actions.append(
            "[dry-run] would remove "
            f"{', '.join(COMMANDS_MOD_FUNCTIONS_TO_REMOVE)} from "
            "src-tauri/src/commands/mod.rs"
        )
        actions.append("")
        actions.append("Manual follow-up still required after the above (see checklist):")
        actions += [f"  - {item}" for item in MANUAL_FOLLOWUP_ITEMS]
        return actions

    for f in all_whole_files:
        subprocess.run(["git", "-C", str(root), "rm", "-f", "--quiet", f], check=True)
        actions.append(f"removed {f}")

    removed_deps = _remove_npm_deps(root / "ui" / "package.json")
    actions.append(f"pruned npm deps: {removed_deps}")

    _remove_lib_rs_block(root / "src-tauri" / "src" / "lib.rs")
    actions.append("excised session-wiring block from src-tauri/src/lib.rs")

    removed_fns = _remove_commands_mod_functions(
        root / "src-tauri" / "src" / "commands" / "mod.rs"
    )
    actions.append(f"removed commands: {removed_fns}")

    actions.append("")
    actions.append("Manual follow-up still required (see checklist):")
    actions += [f"  - {item}" for item in MANUAL_FOLLOWUP_ITEMS]
    return actions


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def _root_from_here() -> Path:
    return Path(__file__).resolve().parent.parent


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="cutover.sh",
        description=(
            "Release-gated cutover for the web terminal hot path "
            "(Task 7, native macOS migration). Refuses the destructive "
            f"removal until {REQUIRED_CYCLES} real release-candidate "
            "cycles are recorded."
        ),
    )
    sub = p.add_subparsers(dest="command", required=True)

    rec = sub.add_parser("record", help="record one completed RC cycle")
    rec.add_argument("--version", help="version of the shipped RC (default: current tauri.conf.json version)")
    rec.add_argument("--by", help="who/what is recording this (default: git user.name)")
    rec.add_argument("--note", default="", help="free-text note (e.g. what was validated)")

    sub.add_parser("status", help="show recorded cycles, gate state, and the removal checklist")

    cut = sub.add_parser("cutover", help="perform the removal, only if the gate is open")
    cut.add_argument(
        "--yes",
        action="store_true",
        help="actually execute (without this, an open gate only prints a dry-run preview)",
    )

    sub.add_parser("help", help="show usage and the removal/retention checklist")
    return p


def main(argv: Optional[list[str]] = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)

    root = _root_from_here()
    import os

    root = Path(os.environ.get("OMNIAGENT_CUTOVER_ROOT", str(root)))
    log_path = Path(
        os.environ.get("OMNIAGENT_CUTOVER_LOG", str(root / DEFAULT_LOG_RELPATH))
    )

    if args.command == "help":
        parser.print_help()
        print()
        print(format_checklist())
        return 0

    if args.command == "status":
        print(format_status(load_cycles(log_path), log_path))
        return 0

    if args.command == "record":
        version = args.version or default_version(root)
        if not version:
            print(
                "cutover.sh record: --version not given and could not be "
                "inferred from src-tauri/tauri.conf.json -- pass --version explicitly",
                file=sys.stderr,
            )
            return 2
        by = args.by or default_by()
        entry = record_cycle(log_path, version, by, args.note)
        cycles = load_cycles(log_path)
        print(f"cutover.sh record: recorded cycle {len(cycles)}: {entry}")
        print(format_status(cycles, log_path))
        return 0

    if args.command == "cutover":
        cycles = load_cycles(log_path)
        if not gate_open(cycles):
            missing = REQUIRED_CYCLES - len(cycles)
            print(
                f"cutover.sh cutover: REFUSING -- {len(cycles)}/{REQUIRED_CYCLES} "
                f"release-candidate cycles recorded, {missing} more needed. "
                "Nothing was touched. Run `cutover.sh record` after a real "
                "RC cycle, or `cutover.sh status` to see what's recorded.",
                file=sys.stderr,
            )
            return 1

        try:
            actions = perform_cutover(root, dry_run=not args.yes)
        except CutoverAbort as e:
            print(f"cutover.sh cutover: ABORTED -- {e}", file=sys.stderr)
            return 1

        print("\n".join(actions))
        if not args.yes:
            print(
                "\ncutover.sh cutover: gate is OPEN. This was a dry run "
                "(no files touched) -- pass --yes to execute for real.",
            )
        return 0

    parser.print_usage(sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
