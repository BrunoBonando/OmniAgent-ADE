//! Gitignore-aware directory walk (Task 2.1). Pure filesystem -> paths; no
//! DB access here so it stays trivially testable and reusable by both
//! `ingest_project` and `discover_projects`. Also home to [`list_dir`]
//! (file tree panel, founder feedback: "nice to have a folder/file
//! navigation on the right panel"), which reuses the same `ignore`-crate
//! walker and [`SKIP_DIRS`] list but for a single, lazy directory level
//! instead of a full recursive walk — see that function's own doc comment.

use ignore::WalkBuilder;
use std::path::{Path, PathBuf};

/// Directories we always skip, regardless of what .gitignore says (matches
/// PLAN.md Task 2.1's explicit skip list).
const SKIP_DIRS: &[&str] = &["node_modules", "target", ".git"];

/// Files bigger than this are treated as generated/binary and skipped.
const MAX_FILE_BYTES: u64 = 1_000_000;

/// Walks `root`, gitignore-aware, returning absolute paths to every file
/// worth considering for ingestion (skips build/vendor dirs and anything
/// over `MAX_FILE_BYTES`). Sorted for determinism.
///
/// Note: `require_git(false)` so `.gitignore` is honored even when `root`
/// isn't (yet) inside an actual git repository — otherwise the `ignore`
/// crate silently stops applying `.gitignore` rules outside a real repo.
pub fn walk_files(root: &Path) -> Vec<PathBuf> {
    let mut out = Vec::new();
    let walker = WalkBuilder::new(root).require_git(false).build();
    for entry in walker.filter_map(Result::ok) {
        let Some(file_type) = entry.file_type() else {
            continue;
        };
        if !file_type.is_file() {
            continue;
        }
        let path = entry.path();
        let in_skip_dir = path.components().any(|c| {
            c.as_os_str()
                .to_str()
                .map(|s| SKIP_DIRS.contains(&s))
                .unwrap_or(false)
        });
        if in_skip_dir {
            continue;
        }
        if let Ok(meta) = entry.metadata() {
            if meta.len() > MAX_FILE_BYTES {
                continue;
            }
        }
        out.push(path.to_path_buf());
    }
    out.sort();
    out
}

/// One entry in a single directory level, as returned by [`list_dir`] — the
/// file tree panel's wire shape (`src-tauri/src/commands.rs::list_dir`
/// serializes this straight to the frontend's `DirEntry` type).
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
pub struct DirEntry {
    pub name: String,
    pub path: String,
    pub is_dir: bool,
}

/// Lists exactly one level of `dir`'s children — the file tree panel's
/// lazy, expand-on-click listing (as opposed to [`walk_files`]'s full
/// recursive walk for ingestion). Gitignore-aware via the same `ignore`
/// crate walker `walk_files` uses (`require_git(false)` so `.gitignore` is
/// honored even when `dir` isn't itself a git repo root), capped to
/// `max_depth(Some(1))` so expanding one folder never pays for the whole
/// subtree, and skips the same always-skip [`SKIP_DIRS`] regardless of
/// `.gitignore` content. Dotfiles (`.git` included) are skipped too, via
/// the `ignore` crate's own default `hidden(true)` behavior.
///
/// Sorted directories-first, then alphabetically case-insensitive within
/// each group — the convention every OS file browser uses, so it reads as
/// "expected" rather than surprising.
///
/// Returns `Err` (rather than panicking or silently returning an empty
/// list) for a path that doesn't exist, isn't a directory, or can't be
/// read for permission reasons — `std::fs::read_dir` is used purely as an
/// up-front access check, since the `ignore` crate's own walker silently
/// drops per-entry errors instead of surfacing them.
pub fn list_dir(dir: &Path) -> Result<Vec<DirEntry>, String> {
    std::fs::read_dir(dir).map_err(|e| format!("can't read {}: {e}", dir.display()))?;

    let walker = WalkBuilder::new(dir)
        .require_git(false)
        .max_depth(Some(1))
        .build();
    let mut out = Vec::new();
    for entry in walker.filter_map(Result::ok) {
        if entry.path() == dir {
            continue; // the walker yields the root itself at depth 0
        }
        let Some(file_type) = entry.file_type() else {
            continue; // e.g. a broken symlink — nothing sensible to show
        };
        let name = entry.file_name().to_string_lossy().into_owned();
        if SKIP_DIRS.contains(&name.as_str()) {
            continue;
        }
        out.push(DirEntry {
            name,
            path: entry.path().to_string_lossy().into_owned(),
            is_dir: file_type.is_dir(),
        });
    }

    out.sort_by(|a, b| match (a.is_dir, b.is_dir) {
        (true, false) => std::cmp::Ordering::Less,
        (false, true) => std::cmp::Ordering::Greater,
        _ => a.name.to_lowercase().cmp(&b.name.to_lowercase()),
    });
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use tempfile::tempdir;

    #[test]
    fn skips_git_node_modules_target_and_respects_gitignore() {
        let dir = tempdir().unwrap();
        fs::create_dir_all(dir.path().join("node_modules/pkg")).unwrap();
        fs::write(dir.path().join("node_modules/pkg/index.js"), "x").unwrap();
        fs::create_dir_all(dir.path().join("target/debug")).unwrap();
        fs::write(dir.path().join("target/debug/out"), "x").unwrap();
        fs::create_dir_all(dir.path().join(".git")).unwrap();
        fs::write(dir.path().join(".git/HEAD"), "x").unwrap();
        fs::write(dir.path().join("keep.ts"), "export const x = 1;").unwrap();
        fs::write(dir.path().join(".gitignore"), "ignored.ts\n").unwrap();
        fs::write(dir.path().join("ignored.ts"), "export const y = 1;").unwrap();

        let files = walk_files(dir.path());
        let names: Vec<String> = files
            .iter()
            .map(|p| {
                p.strip_prefix(dir.path())
                    .unwrap()
                    .to_string_lossy()
                    .into_owned()
            })
            .collect();

        assert!(names.contains(&"keep.ts".to_string()), "{names:?}");
        assert!(!names.iter().any(|n| n.contains("node_modules")));
        assert!(!names.iter().any(|n| n.starts_with("target/")));
        assert!(!names.iter().any(|n| n.contains(".git/")));
        assert!(!names.contains(&"ignored.ts".to_string()), "{names:?}");
    }

    #[test]
    fn skips_files_over_the_size_cap() {
        let dir = tempdir().unwrap();
        let big = vec![b'a'; (MAX_FILE_BYTES + 1) as usize];
        fs::write(dir.path().join("big.ts"), &big).unwrap();
        fs::write(dir.path().join("small.ts"), b"export const x = 1;").unwrap();

        let files = walk_files(dir.path());
        let names: Vec<String> = files
            .iter()
            .map(|p| p.file_name().unwrap().to_string_lossy().into_owned())
            .collect();
        assert!(names.contains(&"small.ts".to_string()));
        assert!(!names.contains(&"big.ts".to_string()));
    }

    #[test]
    fn result_is_sorted() {
        let dir = tempdir().unwrap();
        fs::write(dir.path().join("z.ts"), "x").unwrap();
        fs::write(dir.path().join("a.ts"), "x").unwrap();
        let files = walk_files(dir.path());
        let mut sorted = files.clone();
        sorted.sort();
        assert_eq!(files, sorted);
    }

    // ---------------------------------------------------------------- list_dir

    #[test]
    fn lists_one_level_directories_first_then_alphabetical() {
        let dir = tempdir().unwrap();
        fs::create_dir_all(dir.path().join("src")).unwrap();
        fs::write(dir.path().join("src/nested.ts"), "x").unwrap(); // must not appear — one level only
        fs::create_dir_all(dir.path().join("docs")).unwrap();
        fs::write(dir.path().join("README.md"), "x").unwrap();
        fs::write(dir.path().join("main.py"), "x").unwrap();

        let entries = list_dir(dir.path()).unwrap();
        let names: Vec<&str> = entries.iter().map(|e| e.name.as_str()).collect();

        // dirs first (alphabetical among themselves), then files (alphabetical,
        // case-insensitive) — README.md sorts after main.py under that rule.
        assert_eq!(names, vec!["docs", "src", "main.py", "README.md"]);
        assert!(entries.iter().find(|e| e.name == "docs").unwrap().is_dir);
        assert!(!entries.iter().find(|e| e.name == "main.py").unwrap().is_dir);
        // one level only — src/nested.ts must not leak into this listing.
        assert!(!names.contains(&"nested.ts"));

        let docs_entry = entries.iter().find(|e| e.name == "docs").unwrap();
        assert_eq!(docs_entry.path, dir.path().join("docs").to_string_lossy());
    }

    #[test]
    fn respects_gitignore_and_skips_dotfiles_and_always_skip_dirs() {
        let dir = tempdir().unwrap();
        fs::write(dir.path().join(".gitignore"), "build/\nignored.log\n").unwrap();
        fs::create_dir_all(dir.path().join("build")).unwrap();
        fs::write(dir.path().join("build/out.js"), "x").unwrap();
        fs::write(dir.path().join("ignored.log"), "x").unwrap();
        fs::create_dir_all(dir.path().join("node_modules")).unwrap();
        fs::create_dir_all(dir.path().join(".git")).unwrap();
        fs::create_dir_all(dir.path().join(".hidden-dir")).unwrap();
        fs::write(dir.path().join(".env"), "SECRET=1").unwrap();
        fs::write(dir.path().join("kept.ts"), "x").unwrap();

        let entries = list_dir(dir.path()).unwrap();
        let names: Vec<&str> = entries.iter().map(|e| e.name.as_str()).collect();

        assert_eq!(names, vec!["kept.ts"], "{names:?}");
    }

    #[test]
    fn errors_gracefully_for_a_path_that_does_not_exist() {
        let err = list_dir(Path::new("/no/such/path/omniagent-ade-list-dir-test")).unwrap_err();
        assert!(!err.is_empty());
    }

    #[test]
    fn errors_gracefully_for_a_path_that_is_a_file_not_a_directory() {
        let dir = tempdir().unwrap();
        let file = dir.path().join("not-a-dir.txt");
        fs::write(&file, "x").unwrap();
        let err = list_dir(&file).unwrap_err();
        assert!(!err.is_empty());
    }

    #[test]
    fn against_the_golden_fixture_lists_real_dirs_and_files_with_no_dot_git() {
        let fixture = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .unwrap()
            .parent()
            .unwrap()
            .join("fixtures/sample-project");
        let entries = list_dir(&fixture).unwrap();
        let names: Vec<&str> = entries.iter().map(|e| e.name.as_str()).collect();

        assert_eq!(
            names,
            vec!["docs", "src", "helpers.py", "main.py", "README.md"],
            "{names:?}"
        );
        assert!(!names.contains(&".git"), "{names:?}");
    }
}
