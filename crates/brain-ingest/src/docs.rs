//! Docs linking (Task 2.2): reclassifies markdown files from the generic
//! `File` kind (set by `lib.rs`'s walk pass) to the more specific `Doc` kind,
//! and turns relative markdown links into `LinksTo` edges.

use crate::paths::{normalize_join, parent_dir, rel_posix};
use anyhow::Result;
use brain_core::{now_ts, Edge, EdgeKind, Node, NodeKind, Origin, Store};
use once_cell::sync::Lazy;
use regex::Regex;
use std::path::{Path, PathBuf};

static MD_LINK: Lazy<Regex> = Lazy::new(|| Regex::new(r"\[[^\]]*\]\(([^)]+)\)").unwrap());

fn is_markdown(rel: &str) -> bool {
    rel.ends_with(".md") || rel.ends_with(".mdx")
}

/// Reclassifies every markdown file in `files` to `NodeKind::Doc` (same id as
/// the `File` node lib.rs already wrote, so this just upgrades it) and links
/// relative markdown references to other files actually walked. Returns the
/// number of `LinksTo` edges created.
pub fn extract(store: &Store, root: &Path, project: &str, files: &[PathBuf]) -> Result<usize> {
    let known: std::collections::HashSet<String> =
        files.iter().filter_map(|f| rel_posix(root, f)).collect();
    let mut edges = 0;

    for file in files {
        let Some(rel) = rel_posix(root, file) else {
            continue;
        };
        if !is_markdown(&rel) {
            continue;
        }
        let Ok(content) = std::fs::read_to_string(file) else {
            continue;
        };
        let doc_id = format!("{project}:{rel}");

        store.upsert_node(&Node {
            id: doc_id.clone(),
            kind: NodeKind::Doc,
            project: project.to_string(),
            label: rel.clone(),
            path: Some(rel.clone()),
            summary: None,
            origin: Origin::Extracted,
            updated: now_ts(),
        })?;

        let dir = parent_dir(&rel);
        for cap in MD_LINK.captures_iter(&content) {
            let target = &cap[1];
            if target.starts_with("http://")
                || target.starts_with("https://")
                || target.starts_with('#')
            {
                continue;
            }
            let target_path = target.split('#').next().unwrap_or(target);
            let resolved = normalize_join(&dir, target_path);
            if !known.contains(&resolved) {
                continue; // don't guess broken links
            }
            store.upsert_edge(&Edge {
                src: doc_id.clone(),
                dst: format!("{project}:{resolved}"),
                kind: EdgeKind::LinksTo,
                weight: 1.0,
            })?;
            edges += 1;
        }
    }

    Ok(edges)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use tempfile::tempdir;

    #[test]
    fn links_readme_to_relative_doc_and_drops_broken_links() {
        let dir = tempdir().unwrap();
        fs::write(
            dir.path().join("README.md"),
            "# Title\nSee [notes](docs/notes.md) and [missing](docs/missing.md).\n",
        )
        .unwrap();
        fs::create_dir_all(dir.path().join("docs")).unwrap();
        fs::write(dir.path().join("docs/notes.md"), "# Notes\n").unwrap();

        let store = Store::open_in_memory().unwrap();
        let files = crate::walk::walk_files(dir.path());
        let edges = extract(&store, dir.path(), "p1", &files).unwrap();
        assert_eq!(edges, 1);

        let neighbors = store.neighbors("p1:README.md", 10).unwrap();
        assert!(neighbors
            .iter()
            .any(|(e, n)| e.kind == EdgeKind::LinksTo && n.id == "p1:docs/notes.md"));

        let readme = store.get_node("p1:README.md").unwrap().unwrap();
        assert_eq!(readme.kind, NodeKind::Doc);
    }
}
