//! Per-session code review: what's uncommitted in one session's repo, the
//! diff behind each changed file, and committing the lot.
//!
//! Founder ask, 2026-07-26 (verbatim): *"For each session, have a top right
//! menu with three things: Code Review Panel info (number of changes within
//! files that are uncommited) and if clicked, it should show a code review
//! panel for that session like this: [screenshot] as a new column, dedicated
//! on the right"* — followed by *"Make sure that the code panel is for
//! session, okay?"*. Reference screenshot:
//! `docs/reference/warp-code-review-panel.png`.
//!
//! **Per session** is the load-bearing word and it's why every function here
//! takes a `repo_path`: the panel is scoped to the cwd of the pane it was
//! opened from, never to some app-global "current repo". Nothing in this
//! module holds state between calls.
//!
//! ## Why this crate and not `src-tauri/src/commands.rs`
//!
//! [`crate::gitmine`] already shells out to `git log --numstat` from this
//! crate (no libgit2 dependency, per PLAN.md) and [`crate::fileops`] already
//! owns the "real mutations against the user's real files, with the safety
//! model and the `Result<_, String>` user-facing errors" pattern that
//! `commands.rs` thin-wraps. This module is both of those things at once, so
//! it belongs beside them. `commands::git_branch` is the counter-precedent —
//! but that's a twelve-line read-only lookup with no logic worth isolating,
//! whereas the porcelain/numstat/unified-diff parsing below is exactly the
//! kind of pure function this codebase tests independently of Tauri.
//!
//! ## Never a destructive git operation
//!
//! [`commit`] runs `git add -A` + `git commit -m` and nothing else: no
//! `--amend`, no `--force`, no `--no-verify` (the user's own hooks are part
//! of their repo and are respected), and **no `push`** — nothing here talks
//! to a network. [`revert_file`] is the one genuinely destructive operation
//! and is deliberately asymmetric: a file git has never seen goes to the
//! macOS Trash via [`crate::fileops::delete_to_trash`] (recoverable) rather
//! than `git clean` (not recoverable), and only a file whose contents are
//! already safe in a commit is restored with `git checkout HEAD --`. The
//! frontend must additionally never wire it to a bare one-click.
//!
//! ## The two `-z` formats, which do not agree with each other
//!
//! Both parsers below were written against real `git` output (probed, not
//! recalled), and the ordering trap is real:
//!
//! - `git status --porcelain -z` emits `XY <new>\0<old>\0` for a rename —
//!   **new path first**.
//! - `git diff --numstat -z` emits `<add>\t<del>\t\0<old>\0<new>\0` for a
//!   rename — an *empty* third field, then **old path first**.
//!
//! `-z` is used rather than the default output precisely because the default
//! C-quotes any path with a space or a non-ASCII byte (`"ünïcødé — file.txt"`
//! comes back backslash-escaped); with `-z` the bytes are raw and
//! NUL-separated, so filenames with spaces and unicode need no unquoting at
//! all.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};

/// Hard cap on how many changed files [`status`] will describe in one call.
/// The reference screenshot shows a real repo with 158 changed files; a
/// generated/vendored tree can be far worse, and the panel must not stall
/// the UI counting lines in twenty thousand files. Past this the list is
/// truncated and `truncated` is set — `file_count` still reports the true
/// total, so the header never lies about how many changes there are.
pub const MAX_FILES: usize = 2000;

/// Hard cap on emitted lines for a single file's diff ([`file_diff`]).
/// Expanding one 200k-line generated file inline would jank the panel for no
/// benefit; past this the diff is cut and `truncated` is set so the UI can
/// say so out loud instead of silently showing a partial diff.
pub const MAX_DIFF_LINES: usize = 4000;

/// How many bytes of an untracked file to sniff for a NUL byte before
/// calling it binary — the same "does it look like text" heuristic git
/// itself uses (`buffer_is_binary` checks the first 8000 bytes).
const BINARY_SNIFF_BYTES: usize = 8000;

// --------------------------------------------------------------- wire types

/// What happened to one file, as git itself classifies it. `Untracked` is
/// kept distinct from `Added` on purpose: both are "a file with no committed
/// version", but only `Added` has been `git add`ed, and [`revert_file`]
/// has to unstage one and not the other.
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize)]
#[serde(rename_all = "lowercase")]
pub enum ChangeStatus {
    Modified,
    Added,
    Deleted,
    Renamed,
    Untracked,
}

/// One changed file in the working tree.
#[derive(Debug, Clone, PartialEq, serde::Serialize)]
pub struct ChangedFile {
    /// Repo-relative, POSIX separators — the id every other function here
    /// takes back.
    pub path: String,
    pub status: ChangeStatus,
    /// Only set for [`ChangeStatus::Renamed`]: where the file came from.
    pub old_path: Option<String>,
    /// `None` for a binary file — deliberately absent rather than `0`, so
    /// the UI can render "binary" instead of a truthful-looking `+0 -0`.
    pub added: Option<u32>,
    pub removed: Option<u32>,
    pub binary: bool,
}

/// Everything the panel header and the pane-menu badge need for one repo.
#[derive(Debug, Clone, PartialEq, serde::Serialize)]
pub struct ReviewStatus {
    /// `git rev-parse --show-toplevel` — the repo the session's cwd is
    /// inside, which is not necessarily the cwd itself.
    pub repo_root: String,
    /// `None` on a detached HEAD or a repo with no commits yet.
    pub branch: Option<String>,
    pub detached: bool,
    /// Empty when the repo has no commits yet — [`commit`] still works.
    pub has_head: bool,
    pub files: Vec<ChangedFile>,
    /// The true total, even when `files` was truncated at [`MAX_FILES`].
    pub file_count: usize,
    /// Aggregate added/removed across text files only; binary files
    /// contribute nothing rather than a fake zero.
    pub added: u32,
    pub removed: u32,
    /// How many of `file_count` are binary — lets the header disclose that
    /// the aggregate doesn't cover everything.
    pub binary_count: usize,
    pub truncated: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize)]
#[serde(rename_all = "lowercase")]
pub enum DiffLineKind {
    Context,
    Added,
    Removed,
}

/// One rendered diff line, carrying both gutters so the frontend never has
/// to re-derive line numbers by counting.
#[derive(Debug, Clone, PartialEq, serde::Serialize)]
pub struct DiffLine {
    pub kind: DiffLineKind,
    /// `None` on an added line (it has no old-side number).
    pub old_line: Option<u32>,
    /// `None` on a removed line.
    pub new_line: Option<u32>,
    /// The line's content, already stripped of its leading `+`/`-`/space.
    pub text: String,
}

#[derive(Debug, Clone, PartialEq, serde::Serialize)]
pub struct DiffHunk {
    /// The raw `@@ -a,b +c,d @@ trailing` header, verbatim.
    pub header: String,
    pub lines: Vec<DiffLine>,
}

#[derive(Debug, Clone, PartialEq, serde::Serialize)]
pub struct FileDiff {
    pub path: String,
    /// `true` for a binary file — `hunks` is then empty by definition, not
    /// by omission.
    pub binary: bool,
    pub hunks: Vec<DiffHunk>,
    /// `true` when the diff was cut at [`MAX_DIFF_LINES`].
    pub truncated: bool,
    pub line_count: usize,
}

#[derive(Debug, Clone, PartialEq, serde::Serialize)]
pub struct CommitResult {
    pub sha: String,
    pub short_sha: String,
    pub files_committed: usize,
}

/// Which of [`revert_file`]'s two very different outcomes happened — the
/// frontend words its confirmation differently for each, because one is
/// recoverable from the Trash and the other is not recoverable at all.
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize)]
#[serde(rename_all = "snake_case")]
pub enum RevertOutcome {
    /// The file's committed contents were restored over the working copy.
    RestoredFromHead,
    /// The file had no committed version, so it went to the macOS Trash.
    MovedToTrash,
}

// ------------------------------------------------------------- git plumbing

/// Runs `git -C <root> <args>`, mapping both "git isn't installed" and "git
/// ran and failed" onto one clean `Err(String)` carrying git's own stderr —
/// which is almost always already the best available message for the user.
fn git(root: &Path, args: &[&str]) -> Result<Output, String> {
    let output = Command::new("git")
        .arg("-C")
        .arg(root)
        .args(args)
        .output()
        .map_err(|e| format!("couldn't run git: {e}"))?;
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
        return Err(if stderr.is_empty() {
            format!("git {} failed", args.first().copied().unwrap_or("command"))
        } else {
            stderr
        });
    }
    Ok(output)
}

/// Resolves the repo `path` sits inside, or a clean error. This is the
/// not-a-git-repo / path-doesn't-exist gate every public function starts
/// with, so no later step has to re-check either.
fn repo_root(path: &str) -> Result<PathBuf, String> {
    let p = Path::new(path);
    if !p.exists() {
        return Err(format!("{path} doesn't exist"));
    }
    let output = Command::new("git")
        .arg("-C")
        .arg(p)
        .args(["rev-parse", "--show-toplevel"])
        .output()
        .map_err(|e| format!("couldn't run git: {e}"))?;
    if !output.status.success() {
        return Err(format!("{path} isn't inside a git repository"));
    }
    let root = String::from_utf8_lossy(&output.stdout).trim().to_string();
    if root.is_empty() {
        return Err(format!("{path} isn't inside a git repository"));
    }
    Ok(PathBuf::from(root))
}

/// Rejects anything that isn't a plain repo-relative path — an absolute
/// path, or one that climbs out with `..`. The frontend only ever sends
/// paths that came back from [`status`], so this is a belt-and-braces guard
/// on the two commands that actually touch files, in the same spirit as
/// [`crate::fileops`]'s containment checks.
fn checked_relative(path: &str) -> Result<&str, String> {
    if path.is_empty() {
        return Err("no file path given".to_string());
    }
    let p = Path::new(path);
    if p.is_absolute() {
        return Err(format!("{path} must be a repo-relative path"));
    }
    if p.components()
        .any(|c| matches!(c, std::path::Component::ParentDir))
    {
        return Err(format!("{path} must not climb outside the repository"));
    }
    Ok(path)
}

fn has_head(root: &Path) -> bool {
    git(root, &["rev-parse", "--verify", "--quiet", "HEAD"]).is_ok()
}

/// `(branch, detached)`. A detached HEAD reports `branch: None` rather than
/// the literal string `"HEAD"` git hands back, which would render as a
/// branch named HEAD in the panel header.
fn branch_of(root: &Path) -> (Option<String>, bool) {
    let Ok(out) = git(root, &["rev-parse", "--abbrev-ref", "HEAD"]) else {
        return (None, false); // no commits yet
    };
    let name = String::from_utf8_lossy(&out.stdout).trim().to_string();
    if name.is_empty() {
        (None, false)
    } else if name == "HEAD" {
        (None, true)
    } else {
        (Some(name), false)
    }
}

// ------------------------------------------------------------ pure parsers

/// Splits `git`'s `-z` output into its NUL-separated fields, dropping the
/// empty tail the final separator produces.
fn nul_fields(text: &str) -> Vec<&str> {
    text.split('\0').filter(|f| !f.is_empty()).collect()
}

/// Parses `git status --porcelain -z --untracked-files=all` into
/// `(path, status, old_path)` triples, in git's own order.
///
/// Entry shape is `XY <path>` — two status columns, one space, then the raw
/// path (no quoting under `-z`). A rename entry is followed by a *second*
/// NUL field holding the old path; see this module's doc for why that field
/// order is the opposite of numstat's.
pub fn parse_porcelain_z(text: &str) -> Vec<(String, ChangeStatus, Option<String>)> {
    let fields = nul_fields(text);
    let mut out = Vec::new();
    let mut i = 0;
    while i < fields.len() {
        let entry = fields[i];
        i += 1;
        // "XY path" — need at least the two status chars, a space, and a
        // one-character path.
        if entry.len() < 4 {
            continue;
        }
        let code = &entry[..2];
        let path = &entry[3..];
        let (status, old_path) = match code.as_bytes() {
            b"??" => (ChangeStatus::Untracked, None),
            [b'R', _] | [_, b'R'] => {
                // The very next field is where this file came from.
                let old = fields.get(i).map(|s| s.to_string());
                if old.is_some() {
                    i += 1;
                }
                (ChangeStatus::Renamed, old)
            }
            [b'D', _] | [_, b'D'] => (ChangeStatus::Deleted, None),
            [b'A', _] | [_, b'A'] => (ChangeStatus::Added, None),
            _ => (ChangeStatus::Modified, None),
        };
        out.push((path.to_string(), status, old_path));
    }
    out
}

/// Parses `git diff --numstat -z` into `path -> (added, removed)`, where
/// `None` means git reported `-` for both columns, i.e. a binary file.
///
/// Records are `<add>\t<del>\t<path>`, except a rename, which has an *empty*
/// third field and is followed by two more fields: old path, then new path.
/// The map is keyed by the new path, which is what `status` reports.
pub fn parse_numstat_z(text: &str) -> HashMap<String, Option<(u32, u32)>> {
    let fields = nul_fields(text);
    let mut out = HashMap::new();
    let mut i = 0;
    while i < fields.len() {
        let record = fields[i];
        i += 1;
        let mut parts = record.splitn(3, '\t');
        let (Some(add), Some(del), Some(path)) = (parts.next(), parts.next(), parts.next()) else {
            continue;
        };
        let counts = match (add.parse::<u32>(), del.parse::<u32>()) {
            (Ok(a), Ok(d)) => Some((a, d)),
            _ => None, // git prints "-\t-" for binary
        };
        let key = if path.is_empty() {
            // Rename: consume <old>, <new> and key by <new>.
            let _old = fields.get(i);
            let new = fields.get(i + 1);
            i += 2;
            match new {
                Some(n) => n.to_string(),
                None => continue,
            }
        } else {
            path.to_string()
        };
        out.insert(key, counts);
    }
    out
}

/// Parses one file's unified diff into hunks with both line-number gutters
/// resolved, stopping once `max_lines` lines have been emitted.
///
/// Pure and free of any `git` dependency on purpose — it's fed real `git
/// diff` output in production and hand-written diff text in tests, which is
/// how the line-number arithmetic and the `\ No newline at end of file`
/// marker get covered without constructing a repo for each case.
///
/// Returns `(hunks, truncated)`.
pub fn parse_unified_diff(text: &str, max_lines: usize) -> (Vec<DiffHunk>, bool) {
    let mut hunks: Vec<DiffHunk> = Vec::new();
    let mut emitted = 0usize;
    let mut old_no = 0u32;
    let mut new_no = 0u32;
    let mut truncated = false;

    for line in text.lines() {
        if line.starts_with("@@") {
            let Some((old_start, new_start)) = parse_hunk_header(line) else {
                continue;
            };
            old_no = old_start;
            new_no = new_start;
            hunks.push(DiffHunk {
                header: line.to_string(),
                lines: Vec::new(),
            });
            continue;
        }
        let Some(hunk) = hunks.last_mut() else {
            continue; // still in the ---/+++/index preamble
        };
        // "\ No newline at end of file" annotates the previous line; it is
        // not itself a diff line and must not consume a line number.
        if line.starts_with('\\') {
            continue;
        }
        if emitted >= max_lines {
            truncated = true;
            break;
        }
        let (kind, text) = match line.as_bytes().first() {
            Some(b'+') => (DiffLineKind::Added, &line[1..]),
            Some(b'-') => (DiffLineKind::Removed, &line[1..]),
            Some(b' ') => (DiffLineKind::Context, &line[1..]),
            // A totally empty line inside a hunk is a context line whose
            // single leading space git trimmed away.
            None => (DiffLineKind::Context, ""),
            _ => continue, // any other trailing metadata
        };
        let (old_line, new_line) = match kind {
            DiffLineKind::Added => {
                let n = new_no;
                new_no += 1;
                (None, Some(n))
            }
            DiffLineKind::Removed => {
                let o = old_no;
                old_no += 1;
                (Some(o), None)
            }
            DiffLineKind::Context => {
                let (o, n) = (old_no, new_no);
                old_no += 1;
                new_no += 1;
                (Some(o), Some(n))
            }
        };
        hunk.lines.push(DiffLine {
            kind,
            old_line,
            new_line,
            text: text.to_string(),
        });
        emitted += 1;
    }
    (hunks, truncated)
}

/// `@@ -12,7 +12,9 @@ optional trailing context` -> `(12, 12)`.
fn parse_hunk_header(line: &str) -> Option<(u32, u32)> {
    let body = line.strip_prefix("@@")?.split("@@").next()?;
    let mut old = None;
    let mut new = None;
    for token in body.split_whitespace() {
        let (sign, rest) = token.split_at(1);
        let start: u32 = rest.split(',').next()?.parse().ok()?;
        match sign {
            "-" => old = Some(start),
            "+" => new = Some(start),
            _ => {}
        }
    }
    Some((old?, new?))
}

/// `true` when `bytes` looks binary by git's own rule: a NUL in the first
/// [`BINARY_SNIFF_BYTES`].
fn looks_binary(bytes: &[u8]) -> bool {
    bytes.iter().take(BINARY_SNIFF_BYTES).any(|&b| b == 0)
}

/// Counts the lines an untracked file would contribute as additions, or
/// `None` if it's binary. Matches git's own notion of a line: a trailing
/// newline does not start a new one, and an empty file is `0` (which is
/// exactly the plain grey `0` badge the reference screenshot shows for the
/// empty `.log` files).
fn untracked_added_lines(abs: &Path) -> Option<u32> {
    let bytes = std::fs::read(abs).ok()?;
    if looks_binary(&bytes) {
        return None;
    }
    if bytes.is_empty() {
        return Some(0);
    }
    let newlines = bytes.iter().filter(|&&b| b == b'\n').count();
    let unterminated = if bytes.last() == Some(&b'\n') { 0 } else { 1 };
    Some((newlines + unterminated) as u32)
}

// ---------------------------------------------------------------- commands

/// Everything uncommitted in the repo `repo_path` sits inside: the branch,
/// every changed file with its per-file line counts, and the aggregate.
///
/// Untracked files are included (the reference panel counts them — its "158"
/// is a working tree full of untracked logs) but carry
/// [`ChangeStatus::Untracked`] so the UI can mark them apart. Their line
/// counts come from reading the file, since `git diff` by definition has
/// nothing to say about a file it has never seen.
pub fn status(repo_path: &str) -> Result<ReviewStatus, String> {
    let root = repo_root(repo_path)?;
    let (branch, detached) = branch_of(&root);
    let head = has_head(&root);

    let porcelain = git(
        &root,
        &["status", "--porcelain", "-z", "--untracked-files=all"],
    )?;
    let entries = parse_porcelain_z(&String::from_utf8_lossy(&porcelain.stdout));

    // Line counts for everything git already tracks. Against HEAD when there
    // is one (this catches staged *and* unstaged work in one pass); against
    // the empty tree via --cached when the repo has no commits yet.
    let numstat_args: &[&str] = if head {
        &["diff", "HEAD", "--numstat", "-z"]
    } else {
        &["diff", "--cached", "--numstat", "-z"]
    };
    let numstat_out = git(&root, numstat_args)?;
    let counts = parse_numstat_z(&String::from_utf8_lossy(&numstat_out.stdout));

    let file_count = entries.len();
    let truncated = file_count > MAX_FILES;

    let mut files = Vec::with_capacity(file_count.min(MAX_FILES));
    let (mut total_added, mut total_removed, mut binary_count) = (0u32, 0u32, 0usize);

    for (path, change, old_path) in entries.into_iter().take(MAX_FILES) {
        let (added, removed, binary) = if change == ChangeStatus::Untracked {
            match untracked_added_lines(&root.join(&path)) {
                Some(n) => (Some(n), Some(0), false),
                None => (None, None, true),
            }
        } else {
            match counts.get(&path) {
                Some(Some((a, d))) => (Some(*a), Some(*d), false),
                Some(None) => (None, None, true),
                // Tracked but absent from the numstat — e.g. a staged mode
                // change with no content change. Honest zeroes, not binary.
                None => (Some(0), Some(0), false),
            }
        };
        if binary {
            binary_count += 1;
        }
        total_added += added.unwrap_or(0);
        total_removed += removed.unwrap_or(0);
        files.push(ChangedFile {
            path,
            status: change,
            old_path,
            added,
            removed,
            binary,
        });
    }

    Ok(ReviewStatus {
        repo_root: root.to_string_lossy().to_string(),
        branch,
        detached,
        has_head: head,
        files,
        file_count,
        added: total_added,
        removed: total_removed,
        binary_count,
        truncated,
    })
}

/// The structured diff for one changed file, ready to render with line
/// numbers and added/removed classification.
///
/// An untracked file is diffed against `/dev/null` with `--no-index`, which
/// renders it as an all-additions diff — the same thing the reference
/// screenshot shows when a new log file's row is expanded.
pub fn file_diff(repo_path: &str, path: &str) -> Result<FileDiff, String> {
    let root = repo_root(repo_path)?;
    let rel = checked_relative(path)?;
    let abs = root.join(rel);

    let is_untracked = git(&root, &["ls-files", "--error-unmatch", "--", rel]).is_err();

    let text = if is_untracked {
        if !abs.exists() {
            return Err(format!("{rel} no longer exists"));
        }
        // --no-index exits 1 whenever the two inputs differ, which for a new
        // file is always — so success is 0 or 1 here, and only anything else
        // is a real failure.
        let output = Command::new("git")
            .arg("-C")
            .arg(&root)
            .args(["diff", "--no-color", "--no-index", "--", "/dev/null", rel])
            .output()
            .map_err(|e| format!("couldn't run git: {e}"))?;
        match output.status.code() {
            Some(0) | Some(1) => String::from_utf8_lossy(&output.stdout).to_string(),
            _ => {
                let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
                return Err(if stderr.is_empty() {
                    format!("couldn't diff {rel}")
                } else {
                    stderr
                });
            }
        }
    } else {
        let args: Vec<&str> = if has_head(&root) {
            vec!["diff", "--no-color", "HEAD", "--", rel]
        } else {
            vec!["diff", "--no-color", "--cached", "--", rel]
        };
        let out = git(&root, &args)?;
        String::from_utf8_lossy(&out.stdout).to_string()
    };

    // git never emits hunks for a binary file — it says so in one line
    // instead. Reporting that honestly beats an empty diff that looks like
    // "no changes".
    if text.contains("\nBinary files ")
        || text.starts_with("Binary files ")
        || text.contains("GIT binary patch")
    {
        return Ok(FileDiff {
            path: rel.to_string(),
            binary: true,
            hunks: Vec::new(),
            truncated: false,
            line_count: 0,
        });
    }

    let (hunks, truncated) = parse_unified_diff(&text, MAX_DIFF_LINES);
    let line_count = hunks.iter().map(|h| h.lines.len()).sum();
    Ok(FileDiff {
        path: rel.to_string(),
        binary: false,
        hunks,
        truncated,
        line_count,
    })
}

/// Stages every uncommitted change in the repo and commits it with
/// `message`.
///
/// Deliberately all-or-nothing, matching the reference panel's single
/// "Commit" button and the set of files the panel is showing: `git add -A`
/// stages exactly what [`status`] lists (both honour `.gitignore`), so what
/// you reviewed is what you commit. No `--amend`, no `--force`, no
/// `--no-verify` — the repo's own hooks run, because they're part of the
/// user's repo, not ours to skip. Nothing here pushes.
pub fn commit(repo_path: &str, message: &str) -> Result<CommitResult, String> {
    let root = repo_root(repo_path)?;
    if message.trim().is_empty() {
        return Err("a commit needs a message".to_string());
    }

    let pending = status(repo_path)?;
    if pending.file_count == 0 {
        return Err("nothing to commit — the working tree is clean".to_string());
    }

    git(&root, &["add", "-A", "--", "."])?;
    git(&root, &["commit", "-m", message])?;

    let sha = String::from_utf8_lossy(&git(&root, &["rev-parse", "HEAD"])?.stdout)
        .trim()
        .to_string();
    let short_sha = sha[..7.min(sha.len())].to_string();
    Ok(CommitResult {
        sha,
        short_sha,
        files_committed: pending.file_count,
    })
}

/// Throws away one file's uncommitted changes.
///
/// **This destroys work.** The frontend must confirm it explicitly and must
/// never put it behind a bare one-click on a row. Two paths, and the
/// difference matters to the user:
///
/// - A file with no committed version ([`ChangeStatus::Untracked`] or
///   [`ChangeStatus::Added`]) goes to the macOS Trash via
///   [`crate::fileops::delete_to_trash`], never `git clean` — same "there is
///   no permanent delete in this app" rule the file tree already follows, so
///   a mistaken discard is recoverable from the Trash.
/// - Anything else is restored with `git checkout HEAD --`, which is safe in
///   the sense that the restored content is what's already committed — but
///   the edits it overwrites are gone for good.
///
/// A rename is refused outright rather than half-undone: putting the file
/// back means restoring the old path *and* removing the new one, and getting
/// that subtly wrong on the user's real repo is worse than saying no.
pub fn revert_file(repo_path: &str, path: &str) -> Result<RevertOutcome, String> {
    let root = repo_root(repo_path)?;
    let rel = checked_relative(path)?;

    let current = status(repo_path)?;
    let Some(entry) = current.files.iter().find(|f| f.path == rel) else {
        return Err(format!("{rel} has no uncommitted changes"));
    };

    match entry.status {
        ChangeStatus::Renamed => Err(format!(
            "{rel} was renamed from {} — undo a rename with git directly, this panel won't guess at it",
            entry.old_path.as_deref().unwrap_or("another path")
        )),
        ChangeStatus::Untracked => {
            crate::fileops::delete_to_trash(&root, &root.join(rel))?;
            Ok(RevertOutcome::MovedToTrash)
        }
        ChangeStatus::Added => {
            // Unstage first, so the Trash move doesn't leave git holding an
            // index entry for a file that isn't there any more.
            git(&root, &["rm", "--cached", "--", rel])?;
            crate::fileops::delete_to_trash(&root, &root.join(rel))?;
            Ok(RevertOutcome::MovedToTrash)
        }
        ChangeStatus::Modified | ChangeStatus::Deleted => {
            if !has_head(&root) {
                return Err(format!("{rel} can't be restored — this repo has no commits yet"));
            }
            git(&root, &["checkout", "HEAD", "--", rel])?;
            Ok(RevertOutcome::RestoredFromHead)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use tempfile::{tempdir, TempDir};

    /// A real git repo in a tempdir with a real baseline commit. Every
    /// status/diff/commit test below runs against actual `git`, not a
    /// recorded fixture — the whole point is that these parsers agree with
    /// the git binary the user actually has.
    fn repo() -> TempDir {
        let dir = tempdir().unwrap();
        run(dir.path(), &["init", "-q", "-b", "main"]);
        run(dir.path(), &["config", "user.email", "test@example.com"]);
        run(dir.path(), &["config", "user.name", "Test"]);
        run(dir.path(), &["config", "commit.gpgsign", "false"]);
        dir
    }

    fn run(dir: &Path, args: &[&str]) {
        let out = Command::new("git")
            .arg("-C")
            .arg(dir)
            .args(args)
            .output()
            .unwrap();
        assert!(
            out.status.success(),
            "git {args:?} failed: {}",
            String::from_utf8_lossy(&out.stderr)
        );
    }

    fn write(dir: &Path, rel: &str, contents: &str) {
        let p = dir.join(rel);
        if let Some(parent) = p.parent() {
            fs::create_dir_all(parent).unwrap();
        }
        fs::write(p, contents).unwrap();
    }

    fn baseline(dir: &Path) {
        write(
            dir,
            "src/main.rs",
            "fn main() {\n    println!(\"hi\");\n}\n",
        );
        write(dir, "README.md", "# Project\n\nHello.\n");
        write(dir, "doomed.txt", "delete me\n");
        write(dir, "movable.txt", "move me\n");
        run(dir, &["add", "-A"]);
        run(dir, &["commit", "-q", "-m", "baseline"]);
    }

    fn path_of(dir: &TempDir) -> String {
        dir.path().to_string_lossy().to_string()
    }

    fn find<'a>(s: &'a ReviewStatus, path: &str) -> &'a ChangedFile {
        s.files.iter().find(|f| f.path == path).unwrap_or_else(|| {
            panic!(
                "{path} not in {:?}",
                s.files.iter().map(|f| &f.path).collect::<Vec<_>>()
            )
        })
    }

    // ------------------------------------------------------- guard rails

    #[test]
    fn status_rejects_a_directory_that_is_not_a_git_repo() {
        let dir = tempdir().unwrap();
        let err = status(&dir.path().to_string_lossy()).unwrap_err();
        assert!(err.contains("isn't inside a git repository"), "{err}");
    }

    #[test]
    fn status_rejects_a_path_that_does_not_exist() {
        let err = status("/no/such/path/omniagent-ade-gitreview").unwrap_err();
        assert!(err.contains("doesn't exist"), "{err}");
    }

    #[test]
    fn status_of_a_clean_repo_is_empty_but_still_reports_the_branch() {
        let dir = repo();
        baseline(dir.path());
        let s = status(&path_of(&dir)).unwrap();
        assert_eq!(s.file_count, 0);
        assert!(s.files.is_empty());
        assert_eq!(s.added, 0);
        assert_eq!(s.removed, 0);
        assert_eq!(s.branch.as_deref(), Some("main"));
        assert!(s.has_head);
        assert!(!s.detached);
        assert!(!s.truncated);
    }

    #[test]
    fn status_works_in_a_subdirectory_and_reports_the_repo_root() {
        let dir = repo();
        baseline(dir.path());
        write(dir.path(), "src/main.rs", "fn main() {}\n");
        let s = status(&dir.path().join("src").to_string_lossy()).unwrap();
        // Paths stay repo-relative even though we asked from src/.
        assert_eq!(find(&s, "src/main.rs").status, ChangeStatus::Modified);
        assert!(
            fs::canonicalize(&s.repo_root).unwrap() == fs::canonicalize(dir.path()).unwrap(),
            "{} vs {}",
            s.repo_root,
            dir.path().display()
        );
    }

    #[test]
    fn status_handles_a_repo_with_no_commits_yet() {
        let dir = repo();
        write(dir.path(), "first.txt", "hello\n");
        let s = status(&path_of(&dir)).unwrap();
        assert!(!s.has_head);
        assert_eq!(s.file_count, 1);
        assert_eq!(find(&s, "first.txt").status, ChangeStatus::Untracked);
    }

    // ------------------------------------------------ the five status kinds

    #[test]
    fn status_classifies_every_change_kind_with_real_line_counts() {
        let dir = repo();
        baseline(dir.path());

        // modified: +1 line
        write(
            dir.path(),
            "src/main.rs",
            "fn main() {\n    println!(\"hi\");\n    let x = 1;\n}\n",
        );
        // deleted
        run(dir.path(), &["rm", "-q", "doomed.txt"]);
        // renamed
        run(dir.path(), &["mv", "movable.txt", "moved.txt"]);
        // staged-added
        write(dir.path(), "staged.txt", "one\ntwo\n");
        run(dir.path(), &["add", "staged.txt"]);
        // untracked
        write(dir.path(), "loose.txt", "a\nb\nc\n");

        let s = status(&path_of(&dir)).unwrap();
        assert_eq!(s.file_count, 5, "{:?}", s.files);

        let m = find(&s, "src/main.rs");
        assert_eq!(m.status, ChangeStatus::Modified);
        assert_eq!((m.added, m.removed), (Some(1), Some(0)));

        let d = find(&s, "doomed.txt");
        assert_eq!(d.status, ChangeStatus::Deleted);
        assert_eq!((d.added, d.removed), (Some(0), Some(1)));

        let r = find(&s, "moved.txt");
        assert_eq!(r.status, ChangeStatus::Renamed);
        assert_eq!(r.old_path.as_deref(), Some("movable.txt"));

        let a = find(&s, "staged.txt");
        assert_eq!(a.status, ChangeStatus::Added);
        assert_eq!((a.added, a.removed), (Some(2), Some(0)));

        let u = find(&s, "loose.txt");
        assert_eq!(u.status, ChangeStatus::Untracked);
        assert_eq!((u.added, u.removed), (Some(3), Some(0)));
    }

    /// The aggregate in the panel header must equal what `git diff
    /// --numstat` really reports, summed — not a number we invented.
    #[test]
    fn aggregate_totals_match_git_numstat_summed() {
        let dir = repo();
        baseline(dir.path());
        write(
            dir.path(),
            "src/main.rs",
            "fn main() {\n    let a = 1;\n    let b = 2;\n}\n",
        );
        write(dir.path(), "README.md", "# Project\n");

        let s = status(&path_of(&dir)).unwrap();

        let raw = Command::new("git")
            .arg("-C")
            .arg(dir.path())
            .args(["diff", "HEAD", "--numstat"])
            .output()
            .unwrap();
        let (mut ga, mut gr) = (0u32, 0u32);
        for line in String::from_utf8_lossy(&raw.stdout).lines() {
            let mut p = line.split('\t');
            ga += p.next().unwrap().parse::<u32>().unwrap();
            gr += p.next().unwrap().parse::<u32>().unwrap();
        }
        assert_eq!(
            (s.added, s.removed),
            (ga, gr),
            "aggregate disagrees with git"
        );
    }

    // ------------------------------------------------------- awkward names

    #[test]
    fn status_handles_spaces_and_unicode_in_filenames() {
        let dir = repo();
        baseline(dir.path());
        write(dir.path(), "with space.txt", "x\ny\n");
        write(dir.path(), "ünïcødé — file.txt", "é\nü\n");
        write(dir.path(), "nested dir/☕ coffee.md", "# ☕\n");

        let s = status(&path_of(&dir)).unwrap();
        assert_eq!(find(&s, "with space.txt").added, Some(2));
        assert_eq!(find(&s, "ünïcødé — file.txt").added, Some(2));
        assert_eq!(find(&s, "nested dir/☕ coffee.md").added, Some(1));
    }

    #[test]
    fn file_diff_handles_a_unicode_filename() {
        let dir = repo();
        baseline(dir.path());
        write(dir.path(), "ünïcødé — file.txt", "é\nü\n");
        let d = file_diff(&path_of(&dir), "ünïcødé — file.txt").unwrap();
        assert!(!d.binary);
        assert_eq!(d.line_count, 2);
        assert!(d.hunks[0]
            .lines
            .iter()
            .all(|l| l.kind == DiffLineKind::Added));
    }

    // ------------------------------------------------------------- binary

    #[test]
    fn binary_files_report_no_line_counts_rather_than_a_fake_zero() {
        let dir = repo();
        fs::write(dir.path().join("blob.bin"), [0u8, 1, 2, 3, 0, 255]).unwrap();
        run(dir.path(), &["add", "-A"]);
        run(dir.path(), &["commit", "-q", "-m", "baseline with binary"]);
        fs::write(dir.path().join("blob.bin"), [0u8, 9, 9, 9, 0, 1, 2]).unwrap();
        fs::write(dir.path().join("fresh.bin"), [0u8, 0, 0, 7]).unwrap();

        let s = status(&path_of(&dir)).unwrap();

        let tracked = find(&s, "blob.bin");
        assert!(tracked.binary);
        assert_eq!(
            tracked.added, None,
            "a binary file must not claim 0 added lines"
        );
        assert_eq!(tracked.removed, None);

        let untracked = find(&s, "fresh.bin");
        assert!(untracked.binary);
        assert_eq!(untracked.added, None);

        assert_eq!(s.binary_count, 2);
        assert_eq!((s.added, s.removed), (0, 0));
    }

    #[test]
    fn file_diff_of_a_binary_file_says_binary_instead_of_showing_nothing() {
        let dir = repo();
        fs::write(dir.path().join("blob.bin"), [0u8, 1, 2, 3]).unwrap();
        run(dir.path(), &["add", "-A"]);
        run(dir.path(), &["commit", "-q", "-m", "b"]);
        fs::write(dir.path().join("blob.bin"), [0u8, 4, 5, 6, 7]).unwrap();

        let d = file_diff(&path_of(&dir), "blob.bin").unwrap();
        assert!(d.binary);
        assert!(d.hunks.is_empty());
    }

    #[test]
    fn an_empty_untracked_file_counts_zero_lines_and_is_not_binary() {
        let dir = repo();
        baseline(dir.path());
        write(dir.path(), "empty.log", "");
        let s = status(&path_of(&dir)).unwrap();
        let e = find(&s, "empty.log");
        assert!(!e.binary);
        assert_eq!(e.added, Some(0));
    }

    #[test]
    fn an_untracked_file_without_a_trailing_newline_still_counts_its_last_line() {
        let dir = repo();
        baseline(dir.path());
        write(dir.path(), "no-newline.txt", "one\ntwo");
        let s = status(&path_of(&dir)).unwrap();
        assert_eq!(find(&s, "no-newline.txt").added, Some(2));
    }

    // --------------------------------------------------------- file diffs

    #[test]
    fn file_diff_of_a_modified_file_carries_both_line_number_gutters() {
        let dir = repo();
        baseline(dir.path());
        write(
            dir.path(),
            "src/main.rs",
            "fn main() {\n    println!(\"bye\");\n}\n",
        );

        let d = file_diff(&path_of(&dir), "src/main.rs").unwrap();
        assert!(!d.binary);
        assert_eq!(d.hunks.len(), 1);

        let removed: Vec<&DiffLine> = d.hunks[0]
            .lines
            .iter()
            .filter(|l| l.kind == DiffLineKind::Removed)
            .collect();
        let added: Vec<&DiffLine> = d.hunks[0]
            .lines
            .iter()
            .filter(|l| l.kind == DiffLineKind::Added)
            .collect();
        assert_eq!(removed.len(), 1);
        assert_eq!(added.len(), 1);
        assert!(removed[0].text.contains("hi"));
        assert!(added[0].text.contains("bye"));
        // The changed line is line 2 on both sides.
        assert_eq!(removed[0].old_line, Some(2));
        assert_eq!(removed[0].new_line, None);
        assert_eq!(added[0].new_line, Some(2));
        assert_eq!(added[0].old_line, None);
        // Context lines carry both.
        let ctx = d.hunks[0]
            .lines
            .iter()
            .find(|l| l.kind == DiffLineKind::Context)
            .unwrap();
        assert!(ctx.old_line.is_some() && ctx.new_line.is_some());
    }

    #[test]
    fn file_diff_of_an_untracked_file_is_all_additions_from_line_one() {
        let dir = repo();
        baseline(dir.path());
        write(dir.path(), "notes.md", "alpha\nbeta\ngamma\n");

        let d = file_diff(&path_of(&dir), "notes.md").unwrap();
        assert!(!d.binary);
        assert_eq!(d.line_count, 3);
        let lines = &d.hunks[0].lines;
        assert!(lines.iter().all(|l| l.kind == DiffLineKind::Added));
        assert_eq!(lines[0].new_line, Some(1));
        assert_eq!(lines[0].text, "alpha");
        assert_eq!(lines[2].new_line, Some(3));
    }

    #[test]
    fn file_diff_rejects_a_path_that_climbs_out_of_the_repo() {
        let dir = repo();
        baseline(dir.path());
        let err = file_diff(&path_of(&dir), "../../etc/passwd").unwrap_err();
        assert!(err.contains("climb outside"), "{err}");
    }

    #[test]
    fn file_diff_rejects_an_absolute_path() {
        let dir = repo();
        baseline(dir.path());
        let err = file_diff(&path_of(&dir), "/etc/passwd").unwrap_err();
        assert!(err.contains("repo-relative"), "{err}");
    }

    #[test]
    fn file_diff_reports_a_clean_error_for_a_vanished_untracked_file() {
        let dir = repo();
        baseline(dir.path());
        let err = file_diff(&path_of(&dir), "never-existed.txt").unwrap_err();
        assert!(err.contains("no longer exists"), "{err}");
    }

    /// A file far bigger than the cap must come back cut and *say* it was
    /// cut, rather than handing the UI 200k lines to lay out.
    #[test]
    fn a_huge_diff_is_capped_and_reports_that_it_was_truncated() {
        let dir = repo();
        baseline(dir.path());
        let big: String = (0..MAX_DIFF_LINES + 500)
            .map(|i| format!("line {i}\n"))
            .collect();
        write(dir.path(), "huge.txt", &big);

        let d = file_diff(&path_of(&dir), "huge.txt").unwrap();
        assert!(
            d.truncated,
            "a {}-line file must report truncation",
            MAX_DIFF_LINES + 500
        );
        assert_eq!(d.line_count, MAX_DIFF_LINES);
    }

    // ------------------------------------------------------------- commit

    #[test]
    fn commit_creates_a_real_commit_containing_every_listed_change() {
        let dir = repo();
        baseline(dir.path());
        write(
            dir.path(),
            "src/main.rs",
            "fn main() {\n    let changed = true;\n}\n",
        );
        write(dir.path(), "brand new.txt", "fresh\n");

        let before = String::from_utf8_lossy(
            &Command::new("git")
                .arg("-C")
                .arg(dir.path())
                .args(["rev-parse", "HEAD"])
                .output()
                .unwrap()
                .stdout,
        )
        .trim()
        .to_string();

        let result = commit(&path_of(&dir), "test: real commit from the review panel").unwrap();

        assert_ne!(result.sha, before, "HEAD must have moved");
        assert_eq!(result.short_sha.len(), 7);
        assert_eq!(result.files_committed, 2);

        // The working tree is genuinely clean afterwards.
        assert_eq!(status(&path_of(&dir)).unwrap().file_count, 0);

        // The message and the files really landed.
        let show = Command::new("git")
            .arg("-C")
            .arg(dir.path())
            .args(["show", "--stat", "--format=%s", "HEAD"])
            .output()
            .unwrap();
        let text = String::from_utf8_lossy(&show.stdout);
        assert!(
            text.contains("test: real commit from the review panel"),
            "{text}"
        );
        assert!(text.contains("brand new.txt"), "{text}");
        assert!(text.contains("src/main.rs"), "{text}");
    }

    #[test]
    fn commit_works_on_a_repo_with_no_commits_yet() {
        let dir = repo();
        write(dir.path(), "first.txt", "hello\n");
        let result = commit(&path_of(&dir), "chore: first commit").unwrap();
        assert!(!result.sha.is_empty());
        assert_eq!(status(&path_of(&dir)).unwrap().file_count, 0);
    }

    #[test]
    fn commit_refuses_an_empty_message() {
        let dir = repo();
        baseline(dir.path());
        write(dir.path(), "x.txt", "x\n");
        let err = commit(&path_of(&dir), "   ").unwrap_err();
        assert!(err.contains("needs a message"), "{err}");
        // Nothing was staged or committed by the failed attempt.
        assert_eq!(status(&path_of(&dir)).unwrap().file_count, 1);
    }

    #[test]
    fn commit_refuses_a_clean_working_tree() {
        let dir = repo();
        baseline(dir.path());
        let err = commit(&path_of(&dir), "nothing here").unwrap_err();
        assert!(err.contains("nothing to commit"), "{err}");
    }

    #[test]
    fn commit_rejects_a_directory_that_is_not_a_git_repo() {
        let dir = tempdir().unwrap();
        let err = commit(&dir.path().to_string_lossy(), "msg").unwrap_err();
        assert!(err.contains("isn't inside a git repository"), "{err}");
    }

    // ------------------------------------------------------------- revert

    #[test]
    fn revert_restores_a_modified_file_from_head() {
        let dir = repo();
        baseline(dir.path());
        let original = fs::read_to_string(dir.path().join("src/main.rs")).unwrap();
        write(dir.path(), "src/main.rs", "fn main() { /* wrecked */ }\n");

        let outcome = revert_file(&path_of(&dir), "src/main.rs").unwrap();
        assert_eq!(outcome, RevertOutcome::RestoredFromHead);
        assert_eq!(
            fs::read_to_string(dir.path().join("src/main.rs")).unwrap(),
            original
        );
        assert_eq!(status(&path_of(&dir)).unwrap().file_count, 0);
    }

    #[test]
    fn revert_brings_back_a_deleted_file() {
        let dir = repo();
        baseline(dir.path());
        run(dir.path(), &["rm", "-q", "doomed.txt"]);
        assert!(!dir.path().join("doomed.txt").exists());

        let outcome = revert_file(&path_of(&dir), "doomed.txt").unwrap();
        assert_eq!(outcome, RevertOutcome::RestoredFromHead);
        assert!(dir.path().join("doomed.txt").exists());
    }

    #[test]
    fn revert_refuses_a_rename_rather_than_half_undoing_it() {
        let dir = repo();
        baseline(dir.path());
        run(dir.path(), &["mv", "movable.txt", "moved.txt"]);
        let err = revert_file(&path_of(&dir), "moved.txt").unwrap_err();
        assert!(err.contains("renamed from movable.txt"), "{err}");
        // Nothing was touched.
        assert!(dir.path().join("moved.txt").exists());
    }

    #[test]
    fn revert_refuses_a_file_with_no_uncommitted_changes() {
        let dir = repo();
        baseline(dir.path());
        let err = revert_file(&path_of(&dir), "README.md").unwrap_err();
        assert!(err.contains("no uncommitted changes"), "{err}");
    }

    #[test]
    fn revert_rejects_a_path_that_climbs_out_of_the_repo() {
        let dir = repo();
        baseline(dir.path());
        let err = revert_file(&path_of(&dir), "../escape.txt").unwrap_err();
        assert!(err.contains("climb outside"), "{err}");
    }

    // ------------------------------------------------------ pure  parsers

    #[test]
    fn porcelain_parser_reads_a_rename_with_the_new_path_first() {
        // Real shape, probed from git: "R  <new>\0<old>\0".
        let text = "R  renamed.txt\0torename.txt\0 M plain.txt\0?? loose.txt\0";
        let parsed = parse_porcelain_z(text);
        assert_eq!(
            parsed,
            vec![
                (
                    "renamed.txt".to_string(),
                    ChangeStatus::Renamed,
                    Some("torename.txt".to_string())
                ),
                ("plain.txt".to_string(), ChangeStatus::Modified, None),
                ("loose.txt".to_string(), ChangeStatus::Untracked, None),
            ]
        );
    }

    #[test]
    fn numstat_parser_reads_a_rename_with_the_old_path_first() {
        // Real shape, probed from git: "<a>\t<d>\t\0<old>\0<new>\0" — the
        // opposite field order from porcelain, which is the whole trap.
        let text = "1\t0\tplain.txt\0-\t-\tblob.bin\x000\t0\t\0torename.txt\0renamed.txt\0";
        let parsed = parse_numstat_z(text);
        assert_eq!(parsed.get("plain.txt"), Some(&Some((1, 0))));
        assert_eq!(
            parsed.get("blob.bin"),
            Some(&None),
            "binary must parse as None, not (0,0)"
        );
        assert_eq!(parsed.get("renamed.txt"), Some(&Some((0, 0))));
        assert!(
            !parsed.contains_key("torename.txt"),
            "keyed by the new path only"
        );
    }

    #[test]
    fn unified_diff_parser_numbers_lines_across_multiple_hunks() {
        let text = "\
diff --git a/f.txt b/f.txt
index 111..222 100644
--- a/f.txt
+++ b/f.txt
@@ -1,3 +1,4 @@
 one
-two
+TWO
+two-and-a-half
 three
@@ -20,2 +21,2 @@ fn context()
-twenty
+TWENTY
 twentyone
";
        let (hunks, truncated) = parse_unified_diff(text, 1000);
        assert!(!truncated);
        assert_eq!(hunks.len(), 2);

        let h1 = &hunks[0];
        assert!(h1.header.starts_with("@@ -1,3 +1,4 @@"));
        assert_eq!(h1.lines.len(), 5);
        // " one" — context at old 1 / new 1
        assert_eq!(
            (h1.lines[0].kind, h1.lines[0].old_line, h1.lines[0].new_line),
            (DiffLineKind::Context, Some(1), Some(1))
        );
        assert_eq!(
            (h1.lines[1].kind, h1.lines[1].old_line, h1.lines[1].new_line),
            (DiffLineKind::Removed, Some(2), None)
        );
        assert_eq!(
            (h1.lines[2].kind, h1.lines[2].old_line, h1.lines[2].new_line),
            (DiffLineKind::Added, None, Some(2))
        );
        assert_eq!(
            (h1.lines[3].kind, h1.lines[3].old_line, h1.lines[3].new_line),
            (DiffLineKind::Added, None, Some(3))
        );
        // context after one removal + two additions: old 3, new 4
        assert_eq!(
            (h1.lines[4].kind, h1.lines[4].old_line, h1.lines[4].new_line),
            (DiffLineKind::Context, Some(3), Some(4))
        );
        assert_eq!(h1.lines[2].text, "TWO");

        // Second hunk restarts from its own header, with the trailing
        // function context kept verbatim in the header.
        let h2 = &hunks[1];
        assert!(h2.header.contains("fn context()"));
        assert_eq!(h2.lines[0].old_line, Some(20));
        assert_eq!(h2.lines[1].new_line, Some(21));
    }

    #[test]
    fn unified_diff_parser_ignores_the_no_newline_marker() {
        let text = "@@ -1,2 +1,2 @@\n one\n-two\n\\ No newline at end of file\n+two\n";
        let (hunks, _) = parse_unified_diff(text, 100);
        assert_eq!(
            hunks[0].lines.len(),
            3,
            "the \\ marker must not become a line"
        );
        assert_eq!(hunks[0].lines[2].kind, DiffLineKind::Added);
        assert_eq!(hunks[0].lines[2].new_line, Some(2));
    }

    #[test]
    fn unified_diff_parser_treats_a_blank_line_in_a_hunk_as_context() {
        let text = "@@ -1,3 +1,3 @@\n one\n\n+added\n";
        let (hunks, _) = parse_unified_diff(text, 100);
        assert_eq!(hunks[0].lines[1].kind, DiffLineKind::Context);
        assert_eq!(hunks[0].lines[1].text, "");
    }

    #[test]
    fn unified_diff_parser_stops_at_the_cap() {
        let body: String = (0..50).map(|i| format!("+line {i}\n")).collect();
        let text = format!("@@ -0,0 +1,50 @@\n{body}");
        let (hunks, truncated) = parse_unified_diff(&text, 10);
        assert!(truncated);
        assert_eq!(hunks[0].lines.len(), 10);
    }

    #[test]
    fn unified_diff_parser_returns_nothing_for_an_empty_diff() {
        let (hunks, truncated) = parse_unified_diff("", 100);
        assert!(hunks.is_empty());
        assert!(!truncated);
    }

    #[test]
    fn hunk_header_parser_handles_single_line_ranges() {
        // The numbers parsed are the hunk's START lines, never its counts:
        // "@@ -1,3 +1,4 @@" means "old side starts at 1 and runs 3 lines,
        // new side starts at 1 and runs 4". Both starts are 1.
        assert_eq!(parse_hunk_header("@@ -1,3 +1,4 @@ trailing"), Some((1, 1)));
        assert_eq!(parse_hunk_header("@@ -12,7 +40,9 @@"), Some((12, 40)));
        // git omits the count entirely when it's 1: "@@ -5 +7,2 @@".
        assert_eq!(parse_hunk_header("@@ -5 +7,2 @@"), Some((5, 7)));
        assert_eq!(parse_hunk_header("not a header"), None);
    }

    #[test]
    fn binary_sniffing_matches_gits_nul_byte_rule() {
        assert!(looks_binary(&[b'a', 0, b'b']));
        assert!(!looks_binary(b"plain text\n"));
        assert!(!looks_binary(&[]));
    }
}
