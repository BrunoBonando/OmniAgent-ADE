#!/usr/bin/env python3
"""Tests for scripts/cutover.sh's decision logic (scripts/cutover_lib.py).

Mirrors scripts/test_native_macos_pty_harness.py's shape: plain functions,
plain asserts, no test framework dependency, run directly:

    python3 scripts/test_cutover.py

Two layers:
  - unit tests against cutover_lib's functions directly (gate/record/status
    decision logic -- the part the brief requires TDD coverage for), and
  - CLI (subprocess) tests against scripts/cutover.sh itself, including one
    full end-to-end run of the automated removal machinery against a
    disposable scratch git repo (never against this actual repo -- the real
    gate stays closed the whole time, see test_real_repo_gate_is_closed).

OMNIAGENT_CUTOVER_ROOT / OMNIAGENT_CUTOVER_LOG let every scratch-repo test
point the script at a temp directory instead of touching the real repo.
"""

import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CUTOVER_SH = ROOT / "scripts" / "cutover.sh"

sys.path.insert(0, str(ROOT / "scripts"))
import cutover_lib  # noqa: E402


# ---------------------------------------------------------------------------
# Unit tests: gate/record/status decision logic
# ---------------------------------------------------------------------------


def test_missing_log_is_zero_cycles_and_gate_closed():
    with tempfile.TemporaryDirectory() as tmp:
        log = Path(tmp) / "nonexistent.jsonl"
        cycles = cutover_lib.load_cycles(log)
        assert cycles == [], cycles
        assert cutover_lib.gate_open(cycles) is False


def test_one_cycle_gate_still_closed():
    with tempfile.TemporaryDirectory() as tmp:
        log = Path(tmp) / "log.jsonl"
        cutover_lib.record_cycle(log, "2026.1.1+001", "tester", "first RC")
        cycles = cutover_lib.load_cycles(log)
        assert len(cycles) == 1, cycles
        assert cutover_lib.gate_open(cycles) is False


def test_two_cycles_gate_open():
    with tempfile.TemporaryDirectory() as tmp:
        log = Path(tmp) / "log.jsonl"
        cutover_lib.record_cycle(log, "2026.1.1+001", "tester", "first RC")
        cutover_lib.record_cycle(log, "2026.1.8+001", "tester", "second RC")
        cycles = cutover_lib.load_cycles(log)
        assert len(cycles) == 2, cycles
        assert cutover_lib.gate_open(cycles) is True


def test_three_cycles_still_open_not_a_boundary_bug():
    with tempfile.TemporaryDirectory() as tmp:
        log = Path(tmp) / "log.jsonl"
        for i in range(3):
            cutover_lib.record_cycle(log, f"2026.1.{i + 1}+001", "tester", "")
        cycles = cutover_lib.load_cycles(log)
        assert len(cycles) == 3
        assert cutover_lib.gate_open(cycles) is True


def test_record_is_append_only_prior_lines_untouched():
    with tempfile.TemporaryDirectory() as tmp:
        log = Path(tmp) / "log.jsonl"
        cutover_lib.record_cycle(log, "v1", "a", "first")
        first_line = log.read_text().splitlines()[0]
        cutover_lib.record_cycle(log, "v2", "b", "second")
        lines = log.read_text().splitlines()
        assert len(lines) == 2
        assert lines[0] == first_line, "recording a 2nd cycle must not rewrite the 1st"
        assert json.loads(lines[1])["version"] == "v2"


def test_record_rejects_empty_version():
    with tempfile.TemporaryDirectory() as tmp:
        log = Path(tmp) / "log.jsonl"
        try:
            cutover_lib.record_cycle(log, "   ", "a", "")
        except ValueError:
            pass
        else:
            raise AssertionError("record_cycle must reject an empty/whitespace version")
        assert not log.exists() or cutover_lib.load_cycles(log) == []


def test_status_text_reports_count_and_gate_state():
    with tempfile.TemporaryDirectory() as tmp:
        log = Path(tmp) / "log.jsonl"
        closed_text = cutover_lib.format_status(cutover_lib.load_cycles(log), log)
        assert "0/2" in closed_text
        assert "GATE: CLOSED" in closed_text

        cutover_lib.record_cycle(log, "v1", "a", "")
        cutover_lib.record_cycle(log, "v2", "b", "")
        open_text = cutover_lib.format_status(cutover_lib.load_cycles(log), log)
        assert "2/2" in open_text
        assert "GATE: OPEN" in open_text


def test_malformed_log_line_raises_not_silently_undercounts():
    with tempfile.TemporaryDirectory() as tmp:
        log = Path(tmp) / "log.jsonl"
        log.write_text("not json\n")
        try:
            cutover_lib.load_cycles(log)
        except ValueError:
            pass
        else:
            raise AssertionError("a corrupt log line must raise, not be silently skipped")


# ---------------------------------------------------------------------------
# CLI (subprocess) tests
# ---------------------------------------------------------------------------


def _run(args, env_extra):
    env = dict(os.environ)
    env.update(env_extra)
    return subprocess.run(
        ["sh", str(CUTOVER_SH)] + args,
        capture_output=True,
        text=True,
        timeout=30,
        env=env,
    )


def test_cli_status_zero_cycles_closed():
    with tempfile.TemporaryDirectory() as tmp:
        log = Path(tmp) / "log.jsonl"
        result = _run(["status"], {"OMNIAGENT_CUTOVER_LOG": str(log)})
        assert result.returncode == 0, result.stderr
        assert "0/2" in result.stdout
        assert "GATE: CLOSED" in result.stdout
        assert "refuses" in result.stdout.lower()


def test_cli_record_then_status_shows_one_cycle():
    with tempfile.TemporaryDirectory() as tmp:
        log = Path(tmp) / "log.jsonl"
        rec = _run(
            ["record", "--version", "9.9.9", "--by", "test-harness", "--note", "smoke"],
            {"OMNIAGENT_CUTOVER_LOG": str(log)},
        )
        assert rec.returncode == 0, rec.stderr
        assert log.exists()
        lines = log.read_text().splitlines()
        assert len(lines) == 1
        entry = json.loads(lines[0])
        assert entry["version"] == "9.9.9"
        assert entry["recorded_by"] == "test-harness"

        status = _run(["status"], {"OMNIAGENT_CUTOVER_LOG": str(log)})
        assert "1/2" in status.stdout
        assert "GATE: CLOSED" in status.stdout


def test_cli_cutover_refuses_when_gate_closed_and_touches_nothing():
    with tempfile.TemporaryDirectory() as tmp:
        log = Path(tmp) / "log.jsonl"
        scratch_root = Path(tmp) / "scratch-root"
        scratch_root.mkdir()
        sentinel = scratch_root / "ui" / "package.json"
        sentinel.parent.mkdir(parents=True)
        sentinel.write_text('{"dependencies": {"@xterm/xterm": "^6.0.0"}}\n')

        result = _run(
            ["cutover"],
            {
                "OMNIAGENT_CUTOVER_LOG": str(log),
                "OMNIAGENT_CUTOVER_ROOT": str(scratch_root),
            },
        )
        assert result.returncode == 1, result.stdout + result.stderr
        assert "REFUSING" in result.stderr
        assert "0/2" in result.stderr
        # nothing destructive happened: the sentinel file is untouched
        assert "@xterm/xterm" in sentinel.read_text()


def test_cli_cutover_yes_also_refuses_when_gate_closed():
    """--yes must not bypass the gate -- it only skips the dry-run
    preview once the gate is already open."""
    with tempfile.TemporaryDirectory() as tmp:
        log = Path(tmp) / "log.jsonl"
        result = _run(["cutover", "--yes"], {"OMNIAGENT_CUTOVER_LOG": str(log)})
        assert result.returncode == 1, result.stdout + result.stderr
        assert "REFUSING" in result.stderr


def _build_scratch_repo(tmp: Path) -> Path:
    """A disposable git repo shaped enough like the real one for
    perform_cutover to run against for real, proving the mechanism (not the
    refusal) actually works end-to-end without ever touching this repo."""
    root = tmp / "scratch-repo"
    for rel in cutover_lib.WHOLE_FILES_TO_REMOVE:
        p = root / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(f"// placeholder for {rel}\n")

    (root / "ui" / "package.json").write_text(
        json.dumps(
            {
                "dependencies": {
                    "@xterm/xterm": "^6.0.0",
                    "@xterm/addon-fit": "^0.11.0",
                    "@xterm/addon-webgl": "^0.19.0",
                    "react-mosaic-component": "^7.0.0",
                    "react": "^18.0.0",
                },
                "devDependencies": {},
            },
            indent=2,
        )
        + "\n"
    )

    lib_rs = root / "src-tauri" / "src" / "lib.rs"
    lib_rs.parent.mkdir(parents=True, exist_ok=True)
    invoke_lines = "".join(cutover_lib.INVOKE_HANDLER_LINES_TO_REMOVE)
    lib_rs.write_text(
        "fn run() {\n"
        "    tauri::Builder::default()\n"
        "        .setup(|app| {\n"
        "            let brain = 1;\n"
        f"{cutover_lib.LIB_RS_BLOCK_START}\n"
        "            // ... sink wiring omitted in this fixture ...\n"
        f"{cutover_lib.LIB_RS_BLOCK_END}"
        "            Ok(())\n"
        "        })\n"
        "        .invoke_handler(tauri::generate_handler![\n"
        "            greet,\n"
        f"{invoke_lines}"
        "            other_command,\n"
        "        ]);\n"
        "}\n"
    )

    commands_mod = root / "src-tauri" / "src" / "commands" / "mod.rs"
    commands_mod.parent.mkdir(parents=True, exist_ok=True)
    body = ""
    for name in cutover_lib.COMMANDS_MOD_FUNCTIONS_TO_REMOVE:
        body += (
            "/// doc comment\n"
            "#[tauri::command]\n"
            f"pub fn {name}(id: String) -> Result<(), String> {{\n"
            "    Ok(())\n"
            "}\n\n"
        )
    body += (
        "#[tauri::command]\n"
        "pub fn unrelated_command() -> Result<(), String> {\n"
        "    Ok(())\n"
        "}\n"
    )
    commands_mod.write_text(body)

    # a dependent example the *fixed* WHOLE_FILES_TO_REMOVE list does not
    # know about -- proves discovery, not a hardcoded list, finds it.
    discovered = root / "src-tauri" / "examples" / "manual_new_thing_verify.rs"
    discovered.parent.mkdir(parents=True, exist_ok=True)
    discovered.write_text("use crate::sessions::SessionManager;\nfn main() {}\n")

    # excluded-from-auto-delete file: depends on sessions:: but must NOT be
    # deleted automatically (entangled with a retained feature).
    feedback_test = root / "src-tauri" / "tests" / "feedback_test.rs"
    feedback_test.parent.mkdir(parents=True, exist_ok=True)
    feedback_test.write_text("use omniagent_ade_lib::sessions::SessionManager;\n")

    # an unrelated example that must survive untouched.
    unrelated = root / "src-tauri" / "examples" / "manual_fileops_verify.rs"
    unrelated.parent.mkdir(parents=True, exist_ok=True)
    unrelated.write_text("fn main() {}\n")

    subprocess.run(["git", "init", "--quiet", str(root)], check=True)
    subprocess.run(["git", "-C", str(root), "add", "-A"], check=True)
    subprocess.run(
        ["git", "-C", str(root), "-c", "user.email=t@example.com", "-c", "user.name=t",
         "commit", "--quiet", "-m", "scratch fixture"],
        check=True,
    )
    return root


def test_perform_cutover_dry_run_previews_without_touching_files():
    with tempfile.TemporaryDirectory() as tmp:
        root = _build_scratch_repo(Path(tmp))
        before = (root / "ui" / "package.json").read_text()
        actions = cutover_lib.perform_cutover(root, dry_run=True)
        assert any("dry-run" in a for a in actions)
        assert (root / "ui" / "package.json").read_text() == before
        for rel in cutover_lib.WHOLE_FILES_TO_REMOVE:
            assert (root / rel).exists(), f"dry run must not delete {rel}"


def test_perform_cutover_discovers_undeclared_dependent_and_skips_excluded():
    with tempfile.TemporaryDirectory() as tmp:
        root = _build_scratch_repo(Path(tmp))
        discovered = cutover_lib._discover_dependent_examples_and_tests(root)
        assert "src-tauri/examples/manual_new_thing_verify.rs" in discovered
        assert "src-tauri/tests/feedback_test.rs" not in discovered
        assert "src-tauri/examples/manual_fileops_verify.rs" not in discovered


def test_perform_cutover_executes_for_real_against_scratch_repo():
    with tempfile.TemporaryDirectory() as tmp:
        root = _build_scratch_repo(Path(tmp))
        actions = cutover_lib.perform_cutover(root, dry_run=False)
        assert any("removed" in a for a in actions)

        for rel in cutover_lib.WHOLE_FILES_TO_REMOVE:
            assert not (root / rel).exists(), f"{rel} should have been removed"
        assert not (root / "src-tauri/examples/manual_new_thing_verify.rs").exists()
        # excluded/unrelated files must survive
        assert (root / "src-tauri/tests/feedback_test.rs").exists()
        assert (root / "src-tauri/examples/manual_fileops_verify.rs").exists()

        pkg = json.loads((root / "ui" / "package.json").read_text())
        for dep in cutover_lib.NPM_DEPS_TO_REMOVE:
            assert dep not in pkg.get("dependencies", {})
        assert "react" in pkg["dependencies"], "unrelated deps must survive"

        lib_rs_text = (root / "src-tauri" / "src" / "lib.rs").read_text()
        assert cutover_lib.LIB_RS_BLOCK_START not in lib_rs_text
        assert "commands::session_create," not in lib_rs_text
        assert "greet," in lib_rs_text
        assert "other_command," in lib_rs_text

        commands_text = (root / "src-tauri" / "src" / "commands" / "mod.rs").read_text()
        for name in cutover_lib.COMMANDS_MOD_FUNCTIONS_TO_REMOVE:
            assert f"pub fn {name}(" not in commands_text
        assert "pub fn unrelated_command(" in commands_text


def test_perform_cutover_aborts_on_missing_expected_file():
    with tempfile.TemporaryDirectory() as tmp:
        root = _build_scratch_repo(Path(tmp))
        (root / "src-tauri" / "src" / "sessions.rs").unlink()
        try:
            cutover_lib.perform_cutover(root, dry_run=False)
        except cutover_lib.CutoverAbort:
            pass
        else:
            raise AssertionError("must abort when an expected file is already missing")
        # nothing else should have been touched by an aborted run
        pkg = json.loads((root / "ui" / "package.json").read_text())
        assert "@xterm/xterm" in pkg["dependencies"]


def test_lib_rs_removal_aborts_when_anchor_has_drifted():
    with tempfile.TemporaryDirectory() as tmp:
        root = _build_scratch_repo(Path(tmp))
        lib_rs = root / "src-tauri" / "src" / "lib.rs"
        lib_rs.write_text("fn run() {\n    // no session wiring block here anymore\n}\n")
        try:
            cutover_lib._remove_lib_rs_block(lib_rs)
        except cutover_lib.CutoverAbort:
            pass
        else:
            raise AssertionError("must abort when the anchor text has drifted")


def test_commands_mod_removal_aborts_when_function_missing():
    with tempfile.TemporaryDirectory() as tmp:
        root = _build_scratch_repo(Path(tmp))
        commands_mod = root / "src-tauri" / "src" / "commands" / "mod.rs"
        commands_mod.write_text("#[tauri::command]\npub fn something_else() {}\n")
        try:
            cutover_lib._remove_commands_mod_functions(commands_mod)
        except cutover_lib.CutoverAbort:
            pass
        else:
            raise AssertionError("must abort when an expected function is missing")


def test_cli_cutover_yes_end_to_end_through_the_shell_wrapper():
    with tempfile.TemporaryDirectory() as tmp:
        root = _build_scratch_repo(Path(tmp))
        log = Path(tmp) / "log.jsonl"
        cutover_lib.record_cycle(log, "v1", "a", "")
        cutover_lib.record_cycle(log, "v2", "b", "")

        result = _run(
            ["cutover", "--yes"],
            {"OMNIAGENT_CUTOVER_LOG": str(log), "OMNIAGENT_CUTOVER_ROOT": str(root)},
        )
        assert result.returncode == 0, result.stdout + result.stderr
        assert not (root / "src-tauri" / "src" / "sessions.rs").exists()


def test_real_repo_gate_is_closed():
    """The load-bearing check: against THIS repo's real, default log path
    (not a scratch dir), the gate must report closed right now -- Task 7
    built the mechanism, it did not record any cycles."""
    result = _run(["status"], {})
    assert result.returncode == 0, result.stderr
    assert "0/2" in result.stdout, result.stdout
    assert "GATE: CLOSED" in result.stdout, result.stdout

    cutover_result = _run(["cutover"], {})
    assert cutover_result.returncode == 1, cutover_result.stdout + cutover_result.stderr
    assert "REFUSING" in cutover_result.stderr


def main() -> None:
    tests = [obj for name, obj in sorted(globals().items()) if name.startswith("test_")]
    for t in tests:
        t()
        print(f"ok  {t.__name__}")
    print(f"\n{len(tests)} cutover tests passed")


if __name__ == "__main__":
    main()
