//! Manual, run-by-hand proof that `map_feed::build_map_graph`'s LOD
//! collapse actually shrinks the payload on Bruno's real brain (PLAN.md
//! Task 6.1's "Manual verification" step) — NOT part of `cargo test`
//! (opens the real ~10k-node `/tmp/ade-test/brain.db`).
//!
//! Prints: raw node/edge counts straight from the DB, the whole-brain
//! collapsed `map_graph` counts (project: None, expanded: [], filter: []),
//! then expands one real community id and shows its members appearing.
//!
//! Run:
//! ```sh
//! OMNIAGENT_ADE_DATA_DIR=/tmp/ade-test cargo run -p omniagent-ade --example manual_map_verify
//! ```

use std::path::PathBuf;

use brain_core::Store;
use omniagent_ade_lib::map_feed::build_map_graph;

fn main() {
    let data_dir = PathBuf::from(
        std::env::var("OMNIAGENT_ADE_DATA_DIR").unwrap_or_else(|_| "/tmp/ade-test".to_string()),
    );
    println!("== manual map_graph verify ==");
    println!("data_dir: {}", data_dir.display());

    let store = Store::open(&data_dir).expect("open real brain.db");

    let raw_nodes = store.all_nodes().expect("all_nodes");
    let raw_edges = store.all_edges().expect("all_edges");
    println!(
        "\n-- raw DB --\n  nodes: {}\n  edges: {}",
        raw_nodes.len(),
        raw_edges.len()
    );

    let mut raw_kind_counts: std::collections::BTreeMap<&str, usize> = Default::default();
    for n in &raw_nodes {
        *raw_kind_counts
            .entry(match n.kind {
                brain_core::NodeKind::Project => "project",
                brain_core::NodeKind::File => "file",
                brain_core::NodeKind::CodeEntity => "code_entity",
                brain_core::NodeKind::Doc => "doc",
                brain_core::NodeKind::Memory => "memory",
                brain_core::NodeKind::Decision => "decision",
                brain_core::NodeKind::Session => "session",
                brain_core::NodeKind::Community => "community",
            })
            .or_insert(0) += 1;
    }
    println!("  by kind: {raw_kind_counts:?}");

    let collapsed = build_map_graph(&store, None, &[], &[]).expect("whole-brain collapsed view");
    println!(
        "\n-- collapsed whole-brain map_graph (project: None, expanded: [], filter: []) --\n  nodes: {}\n  links: {}",
        collapsed.nodes.len(),
        collapsed.links.len()
    );
    let mut collapsed_kind_counts: std::collections::BTreeMap<&str, usize> = Default::default();
    for n in &collapsed.nodes {
        *collapsed_kind_counts.entry(n.kind.as_str()).or_insert(0) += 1;
    }
    println!("  by kind: {collapsed_kind_counts:?}");
    println!(
        "  reduction: {} raw nodes -> {} visible nodes ({:.1}% of raw); {} raw edges -> {} links ({:.2}% of raw)",
        raw_nodes.len(),
        collapsed.nodes.len(),
        100.0 * collapsed.nodes.len() as f64 / raw_nodes.len() as f64,
        raw_edges.len(),
        collapsed.links.len(),
        100.0 * collapsed.links.len() as f64 / raw_edges.len() as f64,
    );

    // Pick one real community hub from the collapsed view and expand it.
    let Some(sample_hub) = collapsed.nodes.iter().find(|n| n.kind == "community") else {
        println!("\n(no community nodes found — skipping expand demo)");
        return;
    };
    println!(
        "\n-- expanding one real community: {} (label {:?}, collapsed size {}) --",
        sample_hub.id, sample_hub.label, sample_hub.size
    );
    let expanded = build_map_graph(&store, None, std::slice::from_ref(&sample_hub.id), &[])
        .expect("expanded view");
    let hub_still_present = expanded.nodes.iter().any(|n| n.id == sample_hub.id);
    println!(
        "  hub still present after expand: {hub_still_present} (expect false)\n  total nodes now: {}\n  total links now: {}",
        expanded.nodes.len(),
        expanded.links.len()
    );
    let example_members: Vec<&str> = expanded
        .nodes
        .iter()
        .filter(|n| n.project == sample_hub.project && n.kind != "community")
        .take(5)
        .map(|n| n.id.as_str())
        .collect();
    println!("  sample real member ids now visible: {example_members:?}");
}
