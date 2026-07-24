//! `brain-ingest`: walks a project, parses its code, links docs, mines git
//! co-change history, and groups the result into communities — writing it
//! all into the shared `brain-core::Store`. Phase 2 of PLAN.md; the `brain`
//! CLI (`src/bin/brain.rs`) and the fs watcher (`watch.rs`) sit on top of
//! this crate's public API.

pub mod code;
pub mod community;
pub mod docs;
pub mod gitmine;
mod paths;
pub mod walk;
pub mod watch;

use anyhow::Result;
use brain_core::{now_ts, Node, NodeKind, Origin, Store};
use paths::rel_posix;
use std::collections::HashSet;
use std::path::{Path, PathBuf};

/// Counts of what a single `ingest_project` run produced.
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq, serde::Serialize)]
pub struct IngestStats {
    pub files: usize,
    pub entities: usize,
    pub edges: usize,
    pub communities: usize,
}

/// Ingests one project rooted at `root` under project id `name`: walks its
/// files, parses code entities + imports, links docs, mines git co-change
/// history, and groups the result into communities. Idempotent — re-running
/// on an unchanged tree produces the same nodes/edges (extracted data for
/// this project is cleared first via `delete_project_extracted`, so stale
/// entries from deleted/renamed files don't linger) and, since every pass is
/// deterministic over the same on-disk state, the same community layout.
pub fn ingest_project(store: &Store, root: &Path, name: &str) -> Result<IngestStats> {
    store.delete_project_extracted(name)?;

    store.upsert_node(&Node {
        id: name.to_string(),
        kind: NodeKind::Project,
        project: name.to_string(),
        label: name.to_string(),
        path: Some(root.to_string_lossy().to_string()),
        summary: None,
        origin: Origin::Extracted,
        updated: now_ts(),
    })?;

    let files = walk::walk_files(root);
    let mut stats = IngestStats::default();
    let mut file_ids: HashSet<String> = HashSet::new();

    for file in &files {
        let Some(rel) = rel_posix(root, file) else {
            continue;
        };
        let id = format!("{name}:{rel}");
        store.upsert_node(&Node {
            id: id.clone(),
            kind: NodeKind::File,
            project: name.to_string(),
            label: rel.clone(),
            path: Some(rel),
            summary: None,
            origin: Origin::Extracted,
            updated: now_ts(),
        })?;
        file_ids.insert(id);
        stats.files += 1;
    }

    let code_stats = code::extract(store, root, name, &files)?;
    stats.entities += code_stats.entities;
    stats.edges += code_stats.edges;

    stats.edges += docs::extract(store, root, name, &files)?;
    stats.edges += gitmine::mine(store, root, name, &file_ids)?;
    stats.communities = community::detect(store, name)?;

    Ok(stats)
}

/// Finds every immediate subdirectory of `root` that looks like a project:
/// has a `.git` directory, or has at least 3 recognized source files. Used
/// by `brain ingest <root>` and the watcher to enumerate roots. Directories
/// starting with `.` are skipped. Sorted by name for determinism.
pub fn discover_projects(root: &Path) -> Vec<(String, PathBuf)> {
    let mut out = Vec::new();
    let Ok(entries) = std::fs::read_dir(root) else {
        return out;
    };
    let mut dirs: Vec<PathBuf> = entries
        .filter_map(|e| e.ok())
        .map(|e| e.path())
        .filter(|p| p.is_dir())
        .collect();
    dirs.sort();

    for dir in dirs {
        let Some(name) = dir.file_name().and_then(|n| n.to_str()) else {
            continue;
        };
        if name.starts_with('.') {
            continue;
        }
        let has_git = dir.join(".git").exists();
        let source_count = walk::walk_files(&dir)
            .iter()
            .filter(|f| {
                rel_posix(&dir, f)
                    .map(|rel| code::Lang::from_ext(&rel).is_some())
                    .unwrap_or(false)
            })
            .count();
        if has_git || source_count >= 3 {
            out.push((name.to_string(), dir));
        }
    }
    out
}

#[cfg(test)]
mod discover_tests {
    use super::*;
    use std::fs;
    use tempfile::tempdir;

    #[test]
    fn finds_dirs_with_git_or_enough_source_files() {
        let root = tempdir().unwrap();

        // has .git -> counts even with 0 source files
        fs::create_dir_all(root.path().join("has-git/.git")).unwrap();

        // 3 source files, no .git -> counts
        let enough = root.path().join("enough-sources");
        fs::create_dir_all(&enough).unwrap();
        fs::write(enough.join("a.ts"), "export const a = 1;").unwrap();
        fs::write(enough.join("b.ts"), "export const b = 1;").unwrap();
        fs::write(enough.join("c.ts"), "export const c = 1;").unwrap();

        // 2 source files, no .git -> doesn't count
        let not_enough = root.path().join("not-enough");
        fs::create_dir_all(&not_enough).unwrap();
        fs::write(not_enough.join("a.ts"), "export const a = 1;").unwrap();
        fs::write(not_enough.join("b.ts"), "export const b = 1;").unwrap();

        // dotfile dir is always skipped regardless of contents
        fs::create_dir_all(root.path().join(".hidden/.git")).unwrap();

        let found = discover_projects(root.path());
        let names: Vec<&String> = found.iter().map(|(n, _)| n).collect();

        assert!(names.contains(&&"has-git".to_string()), "{names:?}");
        assert!(names.contains(&&"enough-sources".to_string()), "{names:?}");
        assert!(!names.contains(&&"not-enough".to_string()), "{names:?}");
        assert!(!names.contains(&&".hidden".to_string()), "{names:?}");
    }
}
