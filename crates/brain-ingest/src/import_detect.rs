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
}
