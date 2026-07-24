//! Community detection (Task 2.2): label propagation over the project's
//! File/CodeEntity/Doc subgraph. ponytail: hand-rolled (~60 lines) rather
//! than pulling in a graph library — upgrade to Leiden only if map
//! legibility demands it (PLAN.md's own guidance).
//!
//! Deterministic by construction: node visit order is sorted ids, and ties
//! in the propagation step break on the lexicographically smallest label —
//! so re-running detection over an unchanged graph always reproduces the
//! same groups (and thus the same Community node ids).

use anyhow::Result;
use brain_core::{now_ts, Edge, Node, NodeKind, Origin, Store};
use std::collections::HashMap;

const MAX_ITERATIONS: usize = 20;

/// Runs label propagation over `project`'s File/CodeEntity/Doc nodes and
/// their edges, writing one `Community` node + `MemberOf` edges per group of
/// 2+ members. Returns the number of communities written.
pub fn detect(store: &Store, project: &str) -> Result<usize> {
    let nodes = store.nodes_for_project(project)?;
    let edges = store.edges_for_project(project)?;

    let mut ids: Vec<String> = nodes
        .iter()
        .filter(|n| {
            matches!(
                n.kind,
                NodeKind::File | NodeKind::CodeEntity | NodeKind::Doc
            )
        })
        .map(|n| n.id.clone())
        .collect();
    ids.sort();
    if ids.is_empty() {
        return Ok(0);
    }

    let groups = propagate_labels(&ids, &edges);

    let mut sorted_labels: Vec<&String> = groups.keys().collect();
    sorted_labels.sort();

    let mut count = 0;
    for (idx, label) in sorted_labels.into_iter().enumerate() {
        let members = &groups[label];
        if members.len() < 2 {
            continue;
        }
        let community_id = format!("{project}:community:{idx}");
        store.upsert_node(&Node {
            id: community_id.clone(),
            kind: NodeKind::Community,
            project: project.to_string(),
            label: format!("Community {idx}"),
            path: None,
            summary: None,
            origin: Origin::Extracted,
            updated: now_ts(),
        })?;
        for member in members {
            store.upsert_edge(&Edge {
                src: member.clone(),
                dst: community_id.clone(),
                kind: brain_core::EdgeKind::MemberOf,
                weight: 1.0,
            })?;
        }
        count += 1;
    }
    Ok(count)
}

/// Label propagation over an explicit id list + edge list (kept separate
/// from `detect` so it's directly unit-testable without touching a Store).
/// Returns `{final_label -> members}`.
fn propagate_labels(ids: &[String], edges: &[Edge]) -> HashMap<String, Vec<String>> {
    let id_set: std::collections::HashSet<&str> = ids.iter().map(|s| s.as_str()).collect();
    let mut adjacency: HashMap<&str, Vec<&str>> = HashMap::new();
    for e in edges {
        if id_set.contains(e.src.as_str()) && id_set.contains(e.dst.as_str()) {
            adjacency
                .entry(e.src.as_str())
                .or_default()
                .push(e.dst.as_str());
            adjacency
                .entry(e.dst.as_str())
                .or_default()
                .push(e.src.as_str());
        }
    }

    let mut label: HashMap<&str, String> = ids.iter().map(|id| (id.as_str(), id.clone())).collect();

    for _ in 0..MAX_ITERATIONS {
        let mut changed = false;
        for id in ids {
            let Some(neighbors) = adjacency.get(id.as_str()) else {
                continue;
            };
            if neighbors.is_empty() {
                continue;
            }
            let mut counts: HashMap<&str, usize> = HashMap::new();
            for n in neighbors {
                let l = label.get(n).expect("every id has a label");
                *counts.entry(l.as_str()).or_insert(0) += 1;
            }
            let mut ranked: Vec<(&str, usize)> = counts.into_iter().collect();
            // highest count first; tie -> lexicographically smallest label first
            ranked.sort_by(|a, b| b.1.cmp(&a.1).then_with(|| a.0.cmp(b.0)));
            if let Some((best, _)) = ranked.first() {
                if label.get(id.as_str()).map(|s| s.as_str()) != Some(*best) {
                    label.insert(id.as_str(), best.to_string());
                    changed = true;
                }
            }
        }
        if !changed {
            break;
        }
    }

    let mut groups: HashMap<String, Vec<String>> = HashMap::new();
    for id in ids {
        let l = label
            .get(id.as_str())
            .expect("every id has a label")
            .clone();
        groups.entry(l).or_default().push(id.clone());
    }
    groups
}

#[cfg(test)]
mod tests {
    use super::*;
    use brain_core::EdgeKind;

    fn edge(src: &str, dst: &str) -> Edge {
        Edge {
            src: src.to_string(),
            dst: dst.to_string(),
            kind: EdgeKind::Imports,
            weight: 1.0,
        }
    }

    #[test]
    fn connected_component_converges_to_one_label() {
        let ids = vec![
            "a".to_string(),
            "b".to_string(),
            "c".to_string(),
            "d".to_string(),
        ];
        let edges = vec![edge("a", "b"), edge("b", "c"), edge("c", "d")];
        let groups = propagate_labels(&ids, &edges);
        assert_eq!(groups.len(), 1, "{groups:?}");
        let (_, members) = groups.iter().next().unwrap();
        let mut sorted = members.clone();
        sorted.sort();
        assert_eq!(sorted, vec!["a", "b", "c", "d"]);
    }

    #[test]
    fn disconnected_components_stay_separate() {
        let ids = vec![
            "a".to_string(),
            "b".to_string(),
            "x".to_string(),
            "y".to_string(),
        ];
        let edges = vec![edge("a", "b"), edge("x", "y")];
        let groups = propagate_labels(&ids, &edges);
        assert_eq!(groups.len(), 2, "{groups:?}");
    }

    #[test]
    fn isolated_node_stays_its_own_singleton_label() {
        let ids = vec!["a".to_string(), "b".to_string(), "lonely".to_string()];
        let edges = vec![edge("a", "b")];
        let groups = propagate_labels(&ids, &edges);
        assert!(groups.contains_key("lonely"));
        assert_eq!(groups["lonely"], vec!["lonely".to_string()]);
    }

    #[test]
    fn deterministic_across_repeated_runs() {
        let ids = vec![
            "a".to_string(),
            "b".to_string(),
            "c".to_string(),
            "d".to_string(),
            "e".to_string(),
        ];
        let edges = vec![edge("a", "b"), edge("b", "c"), edge("d", "e")];
        let first = propagate_labels(&ids, &edges);
        let second = propagate_labels(&ids, &edges);
        let mut first_sorted: Vec<_> = first.into_iter().collect();
        let mut second_sorted: Vec<_> = second.into_iter().collect();
        first_sorted.sort();
        second_sorted.sort();
        assert_eq!(first_sorted, second_sorted);
    }
}
