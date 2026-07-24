//! Git co-change mining (Task 2.2): shells out to `git log --numstat` (no
//! libgit2 dependency, per PLAN.md) and bumps a `References` edge weight
//! between every pair of files touched in the same commit. Non-git roots
//! (or systems without `git`) are skipped silently — this is a bonus signal,
//! not a requirement.

use anyhow::Result;
use brain_core::{Edge, EdgeKind, Store};
use std::collections::{HashMap, HashSet};
use std::path::Path;
use std::process::Command;

const MAX_WEIGHT: u32 = 10;

/// A `git log --numstat --format=%H` commit-hash line: exactly 40 (SHA-1) or
/// 64 (SHA-256) lowercase hex chars, nothing else on the line.
fn is_commit_hash_line(line: &str) -> bool {
    matches!(line.len(), 40 | 64) && line.chars().all(|c| c.is_ascii_hexdigit())
}

fn flush_commit(files: &mut Vec<String>, counts: &mut HashMap<(String, String), u32>) {
    for i in 0..files.len() {
        for j in (i + 1)..files.len() {
            let (a, b) = if files[i] < files[j] {
                (files[i].clone(), files[j].clone())
            } else {
                (files[j].clone(), files[i].clone())
            };
            *counts.entry((a, b)).or_insert(0) += 1;
        }
    }
    files.clear();
}

/// Counts co-changes across `git log --numstat` for `root`, restricted to
/// `file_ids` (the `"<project>:<rel>"` ids of files we actually walked —
/// paths git remembers from deleted/renamed history are dropped, not
/// guessed). Returns the number of `References` edges written.
pub fn mine(
    store: &Store,
    root: &Path,
    project: &str,
    file_ids: &HashSet<String>,
) -> Result<usize> {
    let output = Command::new("git")
        .arg("-C")
        .arg(root)
        .arg("log")
        .arg("--numstat")
        .arg("--format=%H")
        .output();

    let output = match output {
        Ok(o) if o.status.success() => o,
        _ => return Ok(0), // not a git repo, or git isn't installed: skip silently
    };
    let text = String::from_utf8_lossy(&output.stdout);

    let mut pair_counts: HashMap<(String, String), u32> = HashMap::new();
    let mut current_files: Vec<String> = Vec::new();

    for line in text.lines() {
        if line.is_empty() {
            continue;
        }
        if is_commit_hash_line(line) {
            flush_commit(&mut current_files, &mut pair_counts);
            continue;
        }
        // numstat line: "<added>\t<deleted>\t<path>"
        if let Some(path) = line.splitn(3, '\t').nth(2) {
            let rel = path.trim().replace('\\', "/");
            let id = format!("{project}:{rel}");
            if file_ids.contains(&id) {
                current_files.push(id);
            }
        }
    }
    flush_commit(&mut current_files, &mut pair_counts);

    let mut edges = 0;
    for ((a, b), count) in pair_counts {
        store.upsert_edge(&Edge {
            src: a,
            dst: b,
            kind: EdgeKind::References,
            weight: count.min(MAX_WEIGHT) as f32,
        })?;
        edges += 1;
    }
    Ok(edges)
}

#[cfg(test)]
mod tests {
    use super::*;
    use brain_core::{NodeKind, Origin};
    use std::fs;
    use tempfile::tempdir;

    fn init_repo_with_cochange(dir: &Path) {
        let run = |args: &[&str]| {
            assert!(Command::new("git")
                .arg("-C")
                .arg(dir)
                .args(args)
                .status()
                .unwrap()
                .success());
        };
        run(&["init", "-q"]);
        run(&["config", "user.email", "test@example.com"]);
        run(&["config", "user.name", "Test"]);
        fs::write(dir.join("a.ts"), "export const a = 1;\n").unwrap();
        fs::write(dir.join("b.ts"), "export const b = 2;\n").unwrap();
        run(&["add", "a.ts", "b.ts"]);
        run(&["commit", "-q", "-m", "co-change a and b"]);
    }

    #[test]
    fn mines_cochange_weight_between_files_touched_together() {
        let dir = tempdir().unwrap();
        init_repo_with_cochange(dir.path());

        let store = Store::open_in_memory().unwrap();
        let mut file_ids = HashSet::new();
        file_ids.insert("p1:a.ts".to_string());
        file_ids.insert("p1:b.ts".to_string());
        // neighbors() needs the endpoint nodes to exist to join against.
        for id in &file_ids {
            store
                .upsert_node(&brain_core::Node {
                    id: id.clone(),
                    kind: NodeKind::File,
                    project: "p1".to_string(),
                    label: id.clone(),
                    path: None,
                    summary: None,
                    origin: Origin::Extracted,
                    updated: 0,
                })
                .unwrap();
        }

        let edges = mine(&store, dir.path(), "p1", &file_ids).unwrap();
        assert_eq!(edges, 1);

        let neighbors = store.neighbors("p1:a.ts", 10).unwrap();
        assert!(neighbors
            .iter()
            .any(|(e, n)| e.kind == EdgeKind::References && n.id == "p1:b.ts" && e.weight >= 1.0));
    }

    #[test]
    fn non_git_root_is_skipped_silently() {
        let dir = tempdir().unwrap();
        let store = Store::open_in_memory().unwrap();
        let edges = mine(&store, dir.path(), "p1", &HashSet::new()).unwrap();
        assert_eq!(edges, 0);
    }

    #[test]
    fn detects_commit_hash_lines_correctly() {
        assert!(is_commit_hash_line(&"a".repeat(40)));
        assert!(is_commit_hash_line(&"f".repeat(64)));
        assert!(!is_commit_hash_line("12\t0\tsrc/auth.ts"));
        assert!(!is_commit_hash_line(""));
    }
}
