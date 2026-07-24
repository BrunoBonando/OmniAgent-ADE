//! Gitignore-aware directory walk (Task 2.1). Pure filesystem -> paths; no
//! DB access here so it stays trivially testable and reusable by both
//! `ingest_project` and `discover_projects`.

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
}
