//! `brain-ingest`: walks a project, parses its code, links docs, mines git
//! co-change history, and groups the result into communities — writing it
//! all into the shared `brain-core::Store`. Phase 2 of PLAN.md (the CLI +
//! watcher are added on top of this in Task 2.3).

pub mod code;
pub mod community;
pub mod docs;
pub mod gitmine;
mod paths;
pub mod walk;

use anyhow::Result;
use brain_core::{now_ts, Node, NodeKind, Origin, Store};
use paths::rel_posix;
use std::collections::HashSet;
use std::path::Path;

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
