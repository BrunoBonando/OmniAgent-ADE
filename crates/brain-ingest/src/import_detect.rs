//! Detects other dev tools already installed on this machine and extracts
//! their known project-list history as *candidates* — Part A of the
//! founder ask (Bruno, 2026-07-25, verbatim): "detect other dev tools
//! already installed on the user's machine and offer to import their known
//! project lists, so a new OmniAgent user doesn't have to manually '+ Add
//! Project' one folder at a time."
//!
//! **Read-only, local-only** (DESIGN.md principle 1: local-first, no
//! network calls ever). This module never writes anything and never calls
//! `roots::add_project` itself — it only detects and lists. Turning a
//! selected [`ImportCandidate`] into a real OmniAgent project is the next
//! (frontend) task's job, built on top of [`list_candidates`] below.
//!
//! ## Supported tools ([`Tool`])
//! - [`Tool::ClaudeCode`] — `~/.claude/projects/`: one directory per
//!   project the CLI has ever been run in, with the real path encoded into
//!   the directory name (see [`decode_dash_encoded_dir`]'s doc comment for
//!   how — and why that's genuinely ambiguous, not just a `-` -> `/` swap).
//! - [`Tool::VsCode`] — `~/Library/Application Support/Code/User/
//!   globalStorage/state.vscdb`, a real SQLite database; see
//!   [`vscode_family_candidates`]'s doc comment for which `ItemTable` key(s)
//!   are read on this machine and why.
//! - [`Tool::Cursor`] — same VS-Code-fork architecture, same code path, at
//!   its own app-support path. **Unverified**: Cursor isn't installed on
//!   the machine this was built against, so this integration is
//!   implemented by analogy only and has never been exercised against a
//!   real Cursor install — see [`cursor_state_db_path`]'s doc comment.
//!
//! ## Failure model
//! Every function here degrades to "not detected" / "zero candidates" on
//! any error — a missing file, a corrupt or permission-denied SQLite
//! database, malformed JSON, an unreadable directory. Never panics, never
//! lets one tool's bad data abort the sweep over the others: every
//! `#[tauri::command]` built on this module (`commands.rs`) calls exactly
//! one tool per invocation, and every helper below is `Result`/`Option`
//! all the way down — no `.unwrap()`/`.expect()` on anything derived from
//! disk or database content.
//!
//! Every returned candidate path is independently verified to exist as a
//! real directory on disk at detection time (`Path::is_dir()`) — a stale
//! history entry pointing at a deleted folder is silently filtered out,
//! never surfaced as a broken import option.

use std::path::{Path, PathBuf};

// --------------------------------------------------------------- wire types

/// One dev tool this module knows how to detect — `commands::
/// detect_importable_tools`'s per-tool summary.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
pub struct DetectedTool {
    /// Stable machine id — what the frontend passes back to
    /// [`list_candidates`] (`"claude-code"` | `"vscode"` | `"cursor"`).
    pub id: String,
    /// Human-readable label for the import picker.
    pub name: String,
    /// Whether this tool's data was found on this machine at all (its
    /// directory/file exists). `candidate_count` is always `0` when this
    /// is `false` — no point opening a database that isn't there.
    pub detected: bool,
    /// How many real, filesystem-verified candidate projects were found.
    pub candidate_count: usize,
}

/// One importable project a detected tool knows about — `commands::
/// list_import_candidates`'s per-project entry. Read-only: nothing about
/// this struct causes anything to be imported; that's the next task.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
pub struct ImportCandidate {
    /// Absolute path, already verified to exist as a real directory.
    pub path: String,
    /// A reasonable derived display name — the folder's own basename.
    pub suggested_name: String,
}

fn to_candidate(path: PathBuf) -> Option<ImportCandidate> {
    let suggested_name = path.file_name()?.to_str()?.to_string();
    Some(ImportCandidate {
        path: path.to_string_lossy().into_owned(),
        suggested_name,
    })
}

// -------------------------------------------------------------------- Tool
//
// Three concrete cases, plain enum + match — not a plugin architecture.
// Adding a 4th tool later means one more variant and one more `match` arm
// in `is_present`/`candidates_for`/`id`/`display_name`, nothing more.

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Tool {
    ClaudeCode,
    VsCode,
    Cursor,
}

impl Tool {
    pub const ALL: [Tool; 3] = [Tool::ClaudeCode, Tool::VsCode, Tool::Cursor];

    pub fn id(self) -> &'static str {
        match self {
            Tool::ClaudeCode => "claude-code",
            Tool::VsCode => "vscode",
            Tool::Cursor => "cursor",
        }
    }

    pub fn display_name(self) -> &'static str {
        match self {
            Tool::ClaudeCode => "Claude Code",
            Tool::VsCode => "VS Code",
            Tool::Cursor => "Cursor",
        }
    }

    fn from_id(id: &str) -> Option<Tool> {
        Tool::ALL.into_iter().find(|t| t.id() == id)
    }
}

// ------------------------------------------------------- Claude Code paths

fn claude_code_projects_dir(home: &Path) -> PathBuf {
    home.join(".claude/projects")
}

// -------------------------------------------------- Claude Code path decode

/// Decodes one `~/.claude/projects/<encoded>` directory name back into the
/// real absolute project path it was derived from — verified against the
/// real filesystem at every step, never a guess.
///
/// ## Why this isn't a simple `replace('-', '/')`
/// Claude Code's directory-naming scheme replaces `/` in the real path with
/// `-`, but it also replaces at least `.` the same way (confirmed on this
/// machine: `/Users/bonando/Documents/Bruno.Digital/BrunoDigital-Backend`
/// encodes to `-Users-bonando-Documents-Bruno-Digital-BrunoDigital-Backend`
/// — both the path separators *and* the dot in `Bruno.Digital` became `-`,
/// and the project's own already-hyphenated name `BrunoDigital-Backend`
/// keeps its dash too). So the encoding is **lossy**: a bare
/// `s.replace('-', '/')` cannot tell a real path separator apart from a
/// literal `-` or `.` that happened to live inside a folder name — on this
/// exact machine it resolves to `/Users/bonando/Documents/Bruno/Digital/
/// BrunoDigital/Backend`, which does not exist, so naive decoding alone
/// finds almost nothing real (empirically: 5 of 48 real entries on this
/// machine, all trivial ancestors like `/Users/bonando`, not one actual
/// project).
///
/// Rather than guess which character a given `-` "really" was (the kind of
/// heuristic this is deliberately avoiding), this walks the token stream
/// left to right and, at each path level, tries every way of grouping the
/// next 1..=N tokens back into one name — joined with a literal `-`, or
/// with a literal `.` — accepting a grouping only when
/// `current.join(name).is_dir()` is true on the REAL filesystem. Longest
/// grouping is tried first (greedy) but the search backtracks: if a long
/// match's descendants never bottom out in a real directory, shorter
/// groupings at that same level are tried before giving up. The real
/// filesystem is the oracle at every step, not a character-class guess —
/// this is "verify against the real filesystem" taken to its natural
/// conclusion, not a clever re-derivation of the encoding rule.
///
/// This also transparently recovers `.dotfile`-style segments from a
/// doubled dash (`--` decodes token-wise to `["", "name"]`, and `["",
/// "name"].join(".")` is exactly `.name`) — which is what makes Claude
/// Code's own `.claude/worktrees/<branch>` layout decode correctly with no
/// special-casing (see [`collapse_worktree`]).
///
/// Returns `None` — never partial output — when `encoded` doesn't start
/// with `-` (every real entry does: it stands for the path's leading `/`),
/// or when no full reconstruction bottoms out in a real, existing
/// directory. A search budget bounds the worst case so a pathological
/// directory name (thousands of dashes) can't make this hang; hitting the
/// budget is treated exactly like "no decode found."
pub fn decode_dash_encoded_dir(encoded: &str) -> Option<PathBuf> {
    let rest = encoded.strip_prefix('-')?;
    let tokens: Vec<&str> = rest.split('-').collect();
    let mut budget: u32 = 50_000;
    backtrack_path(Path::new("/"), &tokens, &mut budget)
}

fn backtrack_path(current: &Path, tokens: &[&str], budget: &mut u32) -> Option<PathBuf> {
    if tokens.is_empty() {
        return if current.is_dir() {
            Some(current.to_path_buf())
        } else {
            None
        };
    }
    let n = tokens.len();
    for take in (1..=n).rev() {
        let joiners: &[&str] = if take == 1 { &["-"] } else { &["-", "."] };
        for joiner in joiners {
            if *budget == 0 {
                return None;
            }
            *budget -= 1;
            let name = tokens[..take].join(joiner);
            let candidate = current.join(&name);
            if candidate.is_dir() {
                if let Some(found) = backtrack_path(&candidate, &tokens[take..], budget) {
                    return Some(found);
                }
            }
        }
    }
    None
}

/// If `path` contains a `.claude/worktrees/<branch>` component sequence
/// anywhere in it, collapses back to the ancestor directory that directly
/// contains `.claude` — the parent repo. Claude Code worktree checkouts
/// (Bruno's own founder note, matching this repo's own `CLAUDE.md`
/// convention: "background sessions get pushed into a git worktree... e.g.
/// `..._BrunoBonando-Website--claude-worktrees-bd-blurb-trim`") are noise
/// for project-import purposes — the parent repo already represents the
/// project, and offering one candidate per worktree branch would flood the
/// picker with the same repo N times. Leaves `path` untouched when no such
/// sequence is present.
fn collapse_worktree(path: &Path) -> PathBuf {
    let components: Vec<std::path::Component> = path.components().collect();
    for (i, c) in components.iter().enumerate() {
        if c.as_os_str() == ".claude" && components.get(i + 1).map(|n| n.as_os_str()) == Some(std::ffi::OsStr::new("worktrees"))
        {
            return components[..i].iter().collect();
        }
    }
    path.to_path_buf()
}

/// Every real, filesystem-verified, worktree-deduped Claude Code project
/// candidate under `home/.claude/projects`. Degrades to an empty `Vec` (not
/// an error) if that directory is missing or unreadable — matches the
/// module's overall failure model.
fn claude_code_candidates(home: &Path) -> Vec<ImportCandidate> {
    let projects_dir = claude_code_projects_dir(home);
    let Ok(entries) = std::fs::read_dir(&projects_dir) else {
        return Vec::new();
    };

    let mut seen: std::collections::HashSet<PathBuf> = std::collections::HashSet::new();
    let mut out: Vec<PathBuf> = Vec::new();

    for entry in entries.filter_map(Result::ok) {
        let Ok(file_type) = entry.file_type() else {
            continue;
        };
        if !file_type.is_dir() {
            continue;
        }
        let name = entry.file_name();
        let Some(name) = name.to_str() else {
            continue;
        };
        let Some(decoded) = decode_dash_encoded_dir(name) else {
            continue;
        };
        let collapsed = collapse_worktree(&decoded);
        // Degenerate: `decode_dash_encoded_dir` bottoming out at the
        // filesystem root itself (`/`) has no usable basename and is never
        // a sane "project" candidate — skip rather than surface it.
        if collapsed.file_name().is_none() {
            continue;
        }
        if seen.insert(collapsed.clone()) {
            out.push(collapsed);
        }
    }

    out.sort();
    out.into_iter().filter_map(to_candidate).collect()
}

// -------------------------------------------------------- VS Code / Cursor
//
// Both are the same VS-Code-fork architecture: a `state.vscdb` SQLite file
// with a plain `key TEXT, value BLOB` `ItemTable`, `value` holding a JSON
// string. Cursor's own install isn't on this machine (see the module doc's
// "unverified" note); everything below was written and tested against VS
// Code's real database, then reused verbatim for Cursor at its own
// app-support path.

/// `ItemTable` keys read for "recent folders", and why.
///
/// [`RECENTLY_OPENED_KEY`] (`history.recentlyOpenedPathsList`) is VS Code's
/// actual "recent folders you can reopen" list — the semantically correct
/// source. It is tried first. But on the real machine this was built
/// against (VS Code 1.130.0), that key is **absent** from `ItemTable`
/// entirely (confirmed: a full dump of all 212 keys in the real
/// `state.vscdb` has no key containing "recent" or "opened" at all — only
/// `workbench.editor.languageDetectionOpenedLanguages.global`, which is
/// unrelated). Rather than depend on a key that may simply not exist for a
/// given install/profile, [`TERMINAL_DIRS_KEY`]
/// (`terminal.history.entries.dirs`) is also read and unioned in: it *is*
/// present and populated on this machine with ~20 real project-root paths
/// (confirmed via direct `sqlite3` inspection — `/Users/bonando/Documents/
/// Bruno.Digital/OmniAgent`, `.../BrunoDigital-Website`, `.../My-Brain`,
/// ...). It's technically "directories used in the integrated terminal",
/// not "recently opened folders/workspaces" — a distinction the founder's
/// own brief for this task calls out — but for a developer who works from
/// integrated terminals it correlates strongly with real project roots,
/// and it's the only one of the two that's actually populated here. Both
/// are read and their real, existing-directory results unioned (deduped by
/// resolved path) rather than picking just one, so this works whether a
/// given VS Code install/version has one, the other, both, or (gracefully)
/// neither.
const RECENTLY_OPENED_KEY: &str = "history.recentlyOpenedPathsList";
const TERMINAL_DIRS_KEY: &str = "terminal.history.entries.dirs";

fn vscode_state_db_path(home: &Path) -> PathBuf {
    home.join("Library/Application Support/Code/User/globalStorage/state.vscdb")
}

/// Cursor's app-support path, by analogy with VS Code's own (same Electron/
/// VS-Code-fork convention: `~/Library/Application Support/<App>/User/
/// globalStorage/state.vscdb`). **Unverified** — Cursor is not installed on
/// the machine this was built against, so this exact path has never been
/// checked against a real Cursor install. If Cursor's actual convention
/// differs, [`Tool::Cursor`] simply degrades to "not detected" (a missing
/// file is exactly the same code path as every other absent-tool case,
/// per the module's failure model) rather than doing anything wrong.
fn cursor_state_db_path(home: &Path) -> PathBuf {
    home.join("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
}

/// Reads one `ItemTable` row's `value` as a UTF-8 string. `value`'s
/// *declared* column type is `BLOB`, but SQLite's `BLOB` affinity means "no
/// type coercion at all" — the value keeps whatever storage class it was
/// written with. Confirmed against the real `state.vscdb` on this machine
/// (`sqlite3 ... "SELECT typeof(value) FROM ItemTable WHERE key=...`) that
/// VS Code actually stores these as `TEXT`, not `BLOB`. Reading via
/// `row.get_ref` and handling *both* `Text` and `Blob` storage classes
/// (rather than asking `rusqlite` for a `Vec<u8>` or `String` column
/// directly, either of which errors on a type it didn't expect) means this
/// works regardless of which storage class a given row actually has, and
/// degrades to `None` — never panics or propagates — for a missing key,
/// a `NULL`/numeric value, or any other query error.
fn read_item_table_value(conn: &rusqlite::Connection, key: &str) -> Option<String> {
    conn.query_row("SELECT value FROM ItemTable WHERE key = ?1", [key], |row| {
        let bytes = match row.get_ref(0)? {
            rusqlite::types::ValueRef::Text(b) => Some(b.to_vec()),
            rusqlite::types::ValueRef::Blob(b) => Some(b.to_vec()),
            _ => None,
        };
        Ok(bytes)
    })
    .ok()
    .flatten()
    .map(|bytes| String::from_utf8_lossy(&bytes).into_owned())
}

/// Extracts folder paths from [`RECENTLY_OPENED_KEY`]'s JSON shape:
/// `{"entries":[{"folderUri":"file:///..."},{"workspace":{"configPath":
/// "file:///....code-workspace"}},{"fileUri":"file:///..."}], ...}`. Only
/// `folderUri` entries are real project-root folders — `workspace` entries
/// point at a `.code-workspace` *file*, and `fileUri` entries are
/// individual files someone opened, neither of which is "a project
/// folder", so both are deliberately skipped here rather than guessed at.
fn extract_recently_opened(json: &serde_json::Value) -> Vec<PathBuf> {
    let mut out = Vec::new();
    if let Some(entries) = json.get("entries").and_then(|v| v.as_array()) {
        for entry in entries {
            if let Some(uri) = entry.get("folderUri").and_then(|v| v.as_str()) {
                if let Some(p) = file_uri_to_path(uri) {
                    out.push(p);
                }
            }
        }
    }
    out
}

/// Extracts directories from [`TERMINAL_DIRS_KEY`]'s JSON shape:
/// `{"entries":[{"key":"/abs/path","value":{}}, ...]}` — plain absolute
/// paths, no URI decoding needed.
fn extract_terminal_dirs(json: &serde_json::Value) -> Vec<PathBuf> {
    let mut out = Vec::new();
    if let Some(entries) = json.get("entries").and_then(|v| v.as_array()) {
        for entry in entries {
            if let Some(path_str) = entry.get("key").and_then(|v| v.as_str()) {
                out.push(PathBuf::from(path_str));
            }
        }
    }
    out
}

/// Strips a `file://` scheme and percent-decodes the rest — VS Code
/// percent-encodes spaces and other special characters in these URIs (e.g.
/// `file:///Users/x/My%20Project`). Returns `None` for anything not
/// actually a `file://` URI rather than guessing.
fn file_uri_to_path(uri: &str) -> Option<PathBuf> {
    let rest = uri.strip_prefix("file://")?;
    Some(PathBuf::from(percent_decode(rest)))
}

/// Minimal `%XX` percent-decoder — just enough for VS Code's own file URIs
/// (always ASCII hex escapes), not a general URI/URL library. Any `%` not
/// followed by two valid hex digits is left as a literal `%` rather than
/// erroring, since a slightly-malformed escape shouldn't take out the
/// whole path.
fn percent_decode(s: &str) -> String {
    let bytes = s.as_bytes();
    let mut out: Vec<u8> = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 3 <= bytes.len() {
            if let Ok(byte) = u8::from_str_radix(&s[i + 1..i + 3], 16) {
                out.push(byte);
                i += 3;
                continue;
            }
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// Every real, existing-directory candidate from a VS-Code-family
/// `state.vscdb` at `db_path` — shared by both [`Tool::VsCode`] and
/// [`Tool::Cursor`] (same schema, same code path). Degrades to an empty
/// `Vec` for a missing file, a file that isn't a valid SQLite database
/// (corrupt, or actually something else entirely), a permission error, a
/// missing `ItemTable`, or a JSON value that fails to parse — any one of
/// these failing never stops the other source key from still being tried.
fn vscode_family_candidates(db_path: &Path) -> Vec<ImportCandidate> {
    let Ok(conn) = rusqlite::Connection::open_with_flags(db_path, rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY) else {
        return Vec::new();
    };

    let mut seen: std::collections::HashSet<PathBuf> = std::collections::HashSet::new();
    let mut out: Vec<PathBuf> = Vec::new();

    let sources: [(&str, fn(&serde_json::Value) -> Vec<PathBuf>); 2] =
        [(RECENTLY_OPENED_KEY, extract_recently_opened), (TERMINAL_DIRS_KEY, extract_terminal_dirs)];

    for (key, extract) in sources {
        let Some(raw) = read_item_table_value(&conn, key) else {
            continue;
        };
        let Ok(json) = serde_json::from_str::<serde_json::Value>(&raw) else {
            continue; // malformed JSON for this key — skip it, try the next source
        };
        for path in extract(&json) {
            if path.is_dir() && seen.insert(path.clone()) {
                out.push(path);
            }
        }
    }

    out.sort();
    out.into_iter().filter_map(to_candidate).collect()
}

// ----------------------------------------------------------- Tool dispatch

fn is_present(tool: Tool, home: &Path) -> bool {
    match tool {
        Tool::ClaudeCode => claude_code_projects_dir(home).is_dir(),
        Tool::VsCode => vscode_state_db_path(home).is_file(),
        Tool::Cursor => cursor_state_db_path(home).is_file(),
    }
}

fn candidates_for(tool: Tool, home: &Path) -> Vec<ImportCandidate> {
    match tool {
        Tool::ClaudeCode => claude_code_candidates(home),
        Tool::VsCode => vscode_family_candidates(&vscode_state_db_path(home)),
        Tool::Cursor => vscode_family_candidates(&cursor_state_db_path(home)),
    }
}

// ------------------------------------------------------------- public API

fn real_home_dir() -> PathBuf {
    PathBuf::from(std::env::var("HOME").unwrap_or_else(|_| "/tmp".to_string()))
}

fn detect_tools_impl(home: &Path) -> Vec<DetectedTool> {
    Tool::ALL
        .into_iter()
        .map(|tool| {
            let detected = is_present(tool, home);
            let candidate_count = if detected { candidates_for(tool, home).len() } else { 0 };
            DetectedTool {
                id: tool.id().to_string(),
                name: tool.display_name().to_string(),
                detected,
                candidate_count,
            }
        })
        .collect()
}

fn list_candidates_impl(home: &Path, tool_id: &str) -> Result<Vec<ImportCandidate>, String> {
    let tool = Tool::from_id(tool_id).ok_or_else(|| format!("unknown import-detect tool id: {tool_id:?}"))?;
    if !is_present(tool, home) {
        return Ok(Vec::new());
    }
    Ok(candidates_for(tool, home))
}

/// Every dev tool this module knows how to detect, with whether it was
/// found on this machine and how many real candidate projects it has.
/// Thin wrapper over [`detect_tools_impl`] using the real `$HOME` — same
/// "pure impl + thin real-home wrapper" split as [`list_candidates`]/
/// [`list_candidates_impl`], so the real logic is directly unit-testable
/// against a synthetic `home` without touching the caller's actual machine.
pub fn detect_tools() -> Vec<DetectedTool> {
    detect_tools_impl(&real_home_dir())
}

/// Every real, filesystem-verified import candidate for `tool_id`
/// (`"claude-code"` | `"vscode"` | `"cursor"`). `Err` only for an unknown
/// id (a frontend/contract bug); an unknown-but-valid tool id that simply
/// isn't detected on this machine returns `Ok(vec![])`, never an error —
/// "not installed" and "installed but nothing found" are both empty
/// results, not failures.
pub fn list_candidates(tool_id: &str) -> Result<Vec<ImportCandidate>, String> {
    list_candidates_impl(&real_home_dir(), tool_id)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use tempfile::tempdir;

    // -------------------------------------------------- decode_dash_encoded_dir

    /// Builds `<root>/<rel>` on real disk (all intermediate dirs too) and
    /// returns it — the fixture builder every decode test below shares.
    fn make_real_dir(root: &Path, rel: &str) -> PathBuf {
        let full = root.join(rel);
        fs::create_dir_all(&full).unwrap();
        full
    }

    /// Dash-encodes a real absolute path exactly the way Claude Code does
    /// on this machine (confirmed empirically against this real
    /// `~/.claude/projects`): every `/` AND every `.` becomes `-`. Test
    /// fixtures build real nested tempdirs, encode their real path with
    /// this, and then assert `decode_dash_encoded_dir` recovers the
    /// original path — proving the round trip against real disk, not a
    /// mocked filesystem.
    fn encode_like_claude_code(path: &Path) -> String {
        path.to_str().unwrap().replace('.', "-").replace('/', "-")
    }

    #[test]
    fn decodes_a_simple_path_with_no_internal_dashes_or_dots() {
        let root = tempdir().unwrap();
        let project = make_real_dir(root.path(), "workspace/plainproject");
        let encoded = encode_like_claude_code(&project);

        let decoded = decode_dash_encoded_dir(&encoded).unwrap();
        assert_eq!(decoded, project);
    }

    #[test]
    fn decodes_a_path_whose_own_folder_name_contains_a_literal_dash() {
        let root = tempdir().unwrap();
        // "BrunoDigital-Backend"-style: the folder's OWN name has a dash
        // in it, so the encoded form has one MORE dash at that position
        // than there are real path separators — this is exactly the
        // ambiguity the module doc describes.
        let project = make_real_dir(root.path(), "workspace/My-Project-Name");
        let encoded = encode_like_claude_code(&project);

        let decoded = decode_dash_encoded_dir(&encoded).unwrap();
        assert_eq!(decoded, project);
    }

    #[test]
    fn decodes_a_path_whose_parent_folder_name_contains_a_literal_dot() {
        let root = tempdir().unwrap();
        // Mirrors the real "Bruno.Digital" case on this machine.
        let project = make_real_dir(root.path(), "Bruno.Digital/SomeApp");
        let encoded = encode_like_claude_code(&project);

        let decoded = decode_dash_encoded_dir(&encoded).unwrap();
        assert_eq!(decoded, project);
    }

    #[test]
    fn decodes_a_path_mixing_a_dotted_parent_and_a_dashed_project_name() {
        let root = tempdir().unwrap();
        // The exact real case this machine's Claude Code data has:
        // .../Bruno.Digital/BrunoDigital-Backend
        let project = make_real_dir(root.path(), "Bruno.Digital/BrunoDigital-Backend");
        let encoded = encode_like_claude_code(&project);

        let decoded = decode_dash_encoded_dir(&encoded).unwrap();
        assert_eq!(decoded, project);
    }

    #[test]
    fn returns_none_for_a_path_that_does_not_resolve_to_any_real_directory() {
        let root = tempdir().unwrap();
        // Never created on disk.
        let fake = root.path().join("workspace/ghost-project");
        let encoded = encode_like_claude_code(&fake);

        assert!(decode_dash_encoded_dir(&encoded).is_none());
    }

    #[test]
    fn returns_none_for_an_encoded_name_missing_the_leading_dash() {
        assert!(decode_dash_encoded_dir("Users-bonando-tmp").is_none());
    }

    #[test]
    fn a_pathological_all_dash_name_terminates_quickly_without_a_match() {
        // Defends the search-budget cap: many dashes, none of which
        // resolve to anything real, must not hang.
        let encoded = format!("-{}", "x-".repeat(200));
        let started = std::time::Instant::now();
        let result = decode_dash_encoded_dir(&encoded);
        assert!(result.is_none());
        assert!(started.elapsed() < std::time::Duration::from_secs(2), "{:?}", started.elapsed());
    }

    // -------------------------------------------------------- collapse_worktree

    #[test]
    fn collapse_worktree_truncates_at_the_dot_claude_worktrees_component() {
        let path = PathBuf::from("/Users/x/Documents/Repo/.claude/worktrees/some-branch");
        let collapsed = collapse_worktree(&path);
        assert_eq!(collapsed, PathBuf::from("/Users/x/Documents/Repo"));
    }

    #[test]
    fn collapse_worktree_leaves_a_normal_path_untouched() {
        let path = PathBuf::from("/Users/x/Documents/Repo");
        assert_eq!(collapse_worktree(&path), path);
    }

    #[test]
    fn decode_then_collapse_resolves_a_real_worktree_dir_to_its_parent_repo() {
        let root = tempdir().unwrap();
        let repo = make_real_dir(root.path(), "Documents/Bruno.Digital/SomeApp-Website");
        let worktree = make_real_dir(&repo, ".claude/worktrees/bd-blurb-trim");

        let encoded = encode_like_claude_code(&worktree);
        let decoded = decode_dash_encoded_dir(&encoded).unwrap();
        assert_eq!(decoded, worktree, "decode itself must resolve the FULL real worktree path");

        let collapsed = collapse_worktree(&decoded);
        assert_eq!(collapsed, repo, "collapsing must land on the parent repo, not the worktree");
    }

    // ------------------------------------------------------- claude_code_candidates

    #[test]
    fn claude_code_candidates_decodes_dedupes_worktrees_and_skips_stale_entries() {
        let home = tempdir().unwrap();
        let projects_dir = claude_code_projects_dir(home.path());
        fs::create_dir_all(&projects_dir).unwrap();

        // Two real, distinct projects.
        let repo_a = make_real_dir(home.path(), "Documents/Bruno.Digital/RepoA");
        let repo_b = make_real_dir(home.path(), "Documents/Bruno.Digital/RepoB-Two");
        // Two worktrees of RepoA — must collapse+dedupe to ONE candidate.
        let wt1 = make_real_dir(&repo_a, ".claude/worktrees/branch-one");
        let wt2 = make_real_dir(&repo_a, ".claude/worktrees/branch-two");

        for real in [&repo_a, &repo_b, &wt1, &wt2] {
            let encoded = encode_like_claude_code(real);
            fs::create_dir_all(projects_dir.join(&encoded)).unwrap();
        }
        // A stale entry: encodes a path that was never created on disk —
        // must be silently filtered, never surfaced.
        let ghost = home.path().join("Documents/Bruno.Digital/DeletedProject");
        let ghost_encoded = encode_like_claude_code(&ghost);
        fs::create_dir_all(projects_dir.join(&ghost_encoded)).unwrap();

        let candidates = claude_code_candidates(home.path());
        let paths: Vec<&str> = candidates.iter().map(|c| c.path.as_str()).collect();

        assert_eq!(candidates.len(), 2, "{paths:?}");
        assert!(paths.contains(&repo_a.to_str().unwrap()), "{paths:?}");
        assert!(paths.contains(&repo_b.to_str().unwrap()), "{paths:?}");
        assert!(!paths.iter().any(|p| p.contains("worktrees")), "{paths:?}");
        assert!(!paths.iter().any(|p| p.contains("DeletedProject")), "{paths:?}");

        let names: Vec<&str> = candidates.iter().map(|c| c.suggested_name.as_str()).collect();
        assert!(names.contains(&"RepoA"), "{names:?}");
        assert!(names.contains(&"RepoB-Two"), "{names:?}");
    }

    #[test]
    fn claude_code_candidates_is_empty_when_the_projects_dir_does_not_exist() {
        let home = tempdir().unwrap();
        assert!(claude_code_candidates(home.path()).is_empty());
    }

    // --------------------------------------------------------- VS Code / Cursor

    /// Builds a real, temporary `state.vscdb`-shaped SQLite file: the same
    /// `ItemTable (key TEXT, value BLOB)` schema real VS Code uses
    /// (confirmed via `sqlite3 state.vscdb ".schema ItemTable"` against the
    /// real file on this machine), with whatever `(key, value)` rows the
    /// caller supplies. A real file on real disk, opened with the real
    /// `rusqlite` — not a mock — per the task's own instruction to test
    /// the SQLite parsing "against a real database file."
    fn build_fake_state_db(path: &Path, rows: &[(&str, &str)]) {
        let conn = rusqlite::Connection::open(path).unwrap();
        conn.execute("CREATE TABLE ItemTable (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB)", [])
            .unwrap();
        for (key, value) in rows {
            conn.execute("INSERT INTO ItemTable (key, value) VALUES (?1, ?2)", rusqlite::params![key, value])
                .unwrap();
        }
    }

    #[test]
    fn vscode_family_candidates_reads_both_keys_unions_and_filters_stale_entries() {
        let dir = tempdir().unwrap();
        let real_folder = make_real_dir(dir.path(), "Documents/RealProject");
        let real_terminal_dir = make_real_dir(dir.path(), "Documents/TerminalProject");
        let stale_folder = dir.path().join("Documents/DeletedProject"); // never created

        let recently_opened = serde_json::json!({
            "entries": [
                { "folderUri": format!("file://{}", real_folder.display()) },
                { "folderUri": format!("file://{}", stale_folder.display()) },
                { "fileUri": format!("file://{}", dir.path().join("Documents/notes.txt").display()) },
                { "workspace": { "configPath": "file:///tmp/whatever.code-workspace" } },
            ]
        })
        .to_string();
        let terminal_dirs = serde_json::json!({
            "entries": [
                { "key": real_terminal_dir.to_str().unwrap(), "value": {} },
                { "key": "/no/such/stale/terminal/dir", "value": {} },
            ]
        })
        .to_string();

        let db_path = dir.path().join("state.vscdb");
        build_fake_state_db(&db_path, &[(RECENTLY_OPENED_KEY, &recently_opened), (TERMINAL_DIRS_KEY, &terminal_dirs)]);

        let candidates = vscode_family_candidates(&db_path);
        let paths: Vec<&str> = candidates.iter().map(|c| c.path.as_str()).collect();

        assert_eq!(candidates.len(), 2, "{paths:?}");
        assert!(paths.contains(&real_folder.to_str().unwrap()), "{paths:?}");
        assert!(paths.contains(&real_terminal_dir.to_str().unwrap()), "{paths:?}");
        assert!(!paths.iter().any(|p| p.contains("DeletedProject")), "{paths:?}");
        assert!(!paths.iter().any(|p| p.contains("stale")), "{paths:?}");
        assert!(!paths.iter().any(|p| p.contains("notes.txt")), "fileUri entries must be skipped, {paths:?}");
    }

    #[test]
    fn vscode_family_candidates_decodes_a_percent_encoded_space_in_a_folder_uri() {
        let dir = tempdir().unwrap();
        let real_folder = make_real_dir(dir.path(), "Documents/My Project");
        let uri = format!("file://{}", real_folder.display()).replace(' ', "%20");

        let recently_opened = serde_json::json!({ "entries": [ { "folderUri": uri } ] }).to_string();
        let db_path = dir.path().join("state.vscdb");
        build_fake_state_db(&db_path, &[(RECENTLY_OPENED_KEY, &recently_opened)]);

        let candidates = vscode_family_candidates(&db_path);
        assert_eq!(candidates.len(), 1);
        assert_eq!(candidates[0].path, real_folder.to_str().unwrap());
        assert_eq!(candidates[0].suggested_name, "My Project");
    }

    /// Task requirement: "one malformed/unparseable value to prove it's
    /// skipped gracefully rather than erroring the whole read." Corrupts
    /// ONE key's JSON; the other key's real, valid data must still surface.
    #[test]
    fn vscode_family_candidates_skips_malformed_json_for_one_key_but_still_reads_the_other() {
        let dir = tempdir().unwrap();
        let real_terminal_dir = make_real_dir(dir.path(), "Documents/StillWorks");

        let terminal_dirs = serde_json::json!({
            "entries": [ { "key": real_terminal_dir.to_str().unwrap(), "value": {} } ]
        })
        .to_string();

        let db_path = dir.path().join("state.vscdb");
        build_fake_state_db(
            &db_path,
            &[
                (RECENTLY_OPENED_KEY, "{ this is not valid json at all {{{"),
                (TERMINAL_DIRS_KEY, &terminal_dirs),
            ],
        );

        let candidates = vscode_family_candidates(&db_path);
        assert_eq!(candidates.len(), 1, "{candidates:?}");
        assert_eq!(candidates[0].path, real_terminal_dir.to_str().unwrap());
    }

    #[test]
    fn vscode_family_candidates_is_empty_for_a_missing_db_file() {
        let dir = tempdir().unwrap();
        let missing = dir.path().join("does-not-exist.vscdb");
        assert!(vscode_family_candidates(&missing).is_empty());
    }

    #[test]
    fn vscode_family_candidates_is_empty_for_a_file_that_is_not_a_valid_sqlite_database() {
        let dir = tempdir().unwrap();
        let corrupt = dir.path().join("corrupt.vscdb");
        fs::write(&corrupt, b"not a sqlite database, just garbage bytes").unwrap();
        // A malformed-but-openable file: rusqlite may open the connection
        // lazily and only fail on the first real query — either way this
        // must degrade to empty, never panic or propagate.
        assert!(vscode_family_candidates(&corrupt).is_empty());
    }

    #[test]
    fn vscode_family_candidates_is_empty_when_neither_known_key_is_present() {
        let dir = tempdir().unwrap();
        let db_path = dir.path().join("state.vscdb");
        build_fake_state_db(&db_path, &[("some.unrelated.key", "\"whatever\"")]);
        assert!(vscode_family_candidates(&db_path).is_empty());
    }

    // ------------------------------------------------------- Tool dispatch / paths

    #[test]
    fn vscode_and_cursor_state_db_paths_follow_the_vs_code_fork_convention() {
        let home = Path::new("/Users/x");
        assert_eq!(
            vscode_state_db_path(home),
            Path::new("/Users/x/Library/Application Support/Code/User/globalStorage/state.vscdb")
        );
        assert_eq!(
            cursor_state_db_path(home),
            Path::new("/Users/x/Library/Application Support/Cursor/User/globalStorage/state.vscdb")
        );
    }

    /// Cursor is unverified against a real install (see the module doc),
    /// but the shared `vscode_family_candidates` code path it dispatches
    /// to is mechanically the same one VS Code's own tests above exercise
    /// against a real SQLite file — this proves the WIRING (right path,
    /// right dispatch) is correct even though no real Cursor install was
    /// available to test end to end.
    #[test]
    fn cursor_dispatches_through_the_same_vscode_family_code_path_at_its_own_path() {
        let home_dir = tempdir().unwrap();
        let cursor_db = cursor_state_db_path(home_dir.path());
        fs::create_dir_all(cursor_db.parent().unwrap()).unwrap();
        let real_folder = make_real_dir(home_dir.path(), "Documents/CursorProject");
        let recently_opened = serde_json::json!({
            "entries": [ { "folderUri": format!("file://{}", real_folder.display()) } ]
        })
        .to_string();
        build_fake_state_db(&cursor_db, &[(RECENTLY_OPENED_KEY, &recently_opened)]);

        assert!(is_present(Tool::Cursor, home_dir.path()));
        let candidates = candidates_for(Tool::Cursor, home_dir.path());
        assert_eq!(candidates.len(), 1);
        assert_eq!(candidates[0].path, real_folder.to_str().unwrap());
    }

    #[test]
    fn tool_from_id_round_trips_every_known_tool_and_rejects_unknown_ids() {
        for tool in Tool::ALL {
            assert_eq!(Tool::from_id(tool.id()), Some(tool));
        }
        assert_eq!(Tool::from_id("not-a-real-tool"), None);
    }

    // --------------------------------------------------------------- public API

    #[test]
    fn detect_tools_impl_reports_detected_and_candidate_counts_per_tool() {
        let home = tempdir().unwrap();
        // Claude Code: present, one real project.
        let projects_dir = claude_code_projects_dir(home.path());
        fs::create_dir_all(&projects_dir).unwrap();
        let project = make_real_dir(home.path(), "Documents/OnlyProject");
        let encoded = encode_like_claude_code(&project);
        fs::create_dir_all(projects_dir.join(encoded)).unwrap();

        // VS Code: present, one real candidate.
        let vscode_db = vscode_state_db_path(home.path());
        fs::create_dir_all(vscode_db.parent().unwrap()).unwrap();
        let terminal_dirs = serde_json::json!({
            "entries": [ { "key": project.to_str().unwrap(), "value": {} } ]
        })
        .to_string();
        build_fake_state_db(&vscode_db, &[(TERMINAL_DIRS_KEY, &terminal_dirs)]);

        // Cursor: absent entirely.

        let tools = detect_tools_impl(home.path());
        let get = |id: &str| tools.iter().find(|t| t.id == id).unwrap().clone();

        assert!(get("claude-code").detected);
        assert_eq!(get("claude-code").candidate_count, 1);
        assert!(get("vscode").detected);
        assert_eq!(get("vscode").candidate_count, 1);
        assert!(!get("cursor").detected);
        assert_eq!(get("cursor").candidate_count, 0);
    }

    #[test]
    fn list_candidates_impl_returns_err_for_an_unknown_tool_id() {
        let home = tempdir().unwrap();
        let err = list_candidates_impl(home.path(), "totally-made-up").unwrap_err();
        assert!(err.contains("totally-made-up"), "{err}");
    }

    #[test]
    fn list_candidates_impl_returns_an_empty_ok_for_a_known_but_undetected_tool() {
        let home = tempdir().unwrap();
        let result = list_candidates_impl(home.path(), "cursor").unwrap();
        assert!(result.is_empty());
    }

    #[test]
    fn list_candidates_impl_returns_real_candidates_for_a_detected_tool() {
        let home = tempdir().unwrap();
        let projects_dir = claude_code_projects_dir(home.path());
        fs::create_dir_all(&projects_dir).unwrap();
        let project = make_real_dir(home.path(), "Documents/RealOne");
        let encoded = encode_like_claude_code(&project);
        fs::create_dir_all(projects_dir.join(encoded)).unwrap();

        let result = list_candidates_impl(home.path(), "claude-code").unwrap();
        assert_eq!(result.len(), 1);
        assert_eq!(result[0].path, project.to_str().unwrap());
        assert_eq!(result[0].suggested_name, "RealOne");
    }
}
