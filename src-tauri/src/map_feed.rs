//! Task 6.1 (PLAN.md Phase 6): the `map_graph` Tauri command — a
//! level-of-detail (LOD) graph feed for the brain map pane. Task 6.2 (the
//! interactive WebGL pane) is built on top of this module's output; this
//! file owns the entire collapse/expand/filter/cap contract so Task 6.2
//! never has to re-derive it.
//!
//! [`map_graph`] is a thin `#[tauri::command]` wrapper — same
//! lock-then-delegate pattern as `commands::brain_query` — around
//! [`build_map_graph`], the plain, Store-only function that does the real
//! work and is what the tests below exercise directly.

use std::collections::{HashMap, HashSet};

use brain_core::{EdgeKind, Node, NodeKind, Store};
use serde::Serialize;
use tauri::State;

use crate::commands::BrainState;

/// Hard cap on visible nodes in one `map_graph` response (PLAN.md Task 6.1:
/// "cap payload at 3 000 visible nodes ... hard cap now, virtualize later
/// if users outgrow it"). `ponytail:` no virtualization/streaming — a flat
/// cap plus deterministic truncation is the whole mechanism until real
/// usage on Bruno's brain proves it isn't enough.
pub const MAX_VISIBLE_NODES: usize = 3000;

/// Size assigned to every non-`community` node: each represents exactly
/// one graph entity, unlike a community hub which stands in for its member
/// count. Named so the `1` in [`build_map_graph`] reads as "one
/// represented entity" rather than a magic default.
const SINGLE_ENTITY_SIZE: u32 = 1;

/// One node as the brain map renders it: either a real graph node or a
/// collapsed community's hub. Field names match PLAN.md Task 6.1's
/// contract verbatim — Task 6.2 depends on this exact shape over Tauri's
/// IPC (`camelCase` is NOT applied; these serialize as-is: `id`, `kind`,
/// `label`, `project`, `size`).
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct MapNode {
    pub id: String,
    pub kind: String,
    pub label: String,
    pub project: String,
    pub size: u32,
}

/// One edge as the brain map renders it, after any collapse-time
/// re-routing and same-pair aggregation. Field names match PLAN.md Task
/// 6.1's contract verbatim (`src`, `dst`, `kind`, `weight`).
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct MapLink {
    pub src: String,
    pub dst: String,
    pub kind: String,
    pub weight: f32,
}

/// The full `map_graph` response payload.
#[derive(Debug, Clone, Default, PartialEq, Serialize)]
pub struct MapGraph {
    pub nodes: Vec<MapNode>,
    pub links: Vec<MapLink>,
}

/// The wire convention for `NodeKind` used by this module's `kind` field
/// and by the `filter` argument: lowercase snake_case (`"code_entity"`,
/// not `"CodeEntity"`) — the same strings `brain_core::store`'s (private)
/// `NodeKind::as_str` produces and `mcp_server::tools::kind_str` mirrors.
/// Duplicated locally rather than exposed from `brain_core`, matching
/// `mcp-server`'s own precedent: each consumer's serialized shape is its
/// own contract to keep stable, independent of storage internals.
fn kind_str(kind: NodeKind) -> &'static str {
    match kind {
        NodeKind::Project => "project",
        NodeKind::File => "file",
        NodeKind::CodeEntity => "code_entity",
        NodeKind::Doc => "doc",
        NodeKind::Memory => "memory",
        NodeKind::Decision => "decision",
        NodeKind::Session => "session",
        NodeKind::Community => "community",
    }
}

fn edge_kind_str(kind: EdgeKind) -> &'static str {
    match kind {
        EdgeKind::Contains => "contains",
        EdgeKind::Imports => "imports",
        EdgeKind::References => "references",
        EdgeKind::LinksTo => "links_to",
        EdgeKind::MemberOf => "member_of",
        EdgeKind::Touched => "touched",
    }
}

/// The `map_graph` Tauri command. `project: None` is the whole-brain view
/// (every ingested project); `Some(p)` scopes to one project. `expanded`
/// lists community node ids to show expanded; `filter` lists `NodeKind`
/// wire-strings to include (empty = everything). See [`build_map_graph`]
/// for the full LOD contract this wraps.
#[tauri::command]
pub fn map_graph(
    project: Option<String>,
    expanded: Vec<String>,
    filter: Vec<String>,
    brain: State<'_, BrainState>,
) -> Result<MapGraph, String> {
    let store = brain.store.lock().map_err(|e| e.to_string())?;
    build_map_graph(&store, project.as_deref(), &expanded, &filter).map_err(|e| e.to_string())
}

/// Builds the level-of-detail graph payload for the brain map. Pure
/// `Store` in, `MapGraph` out — no Tauri involved — so it's directly
/// unit-testable.
///
/// ## Level of detail (the actual engineering point of this task)
///
/// Every `File`/`CodeEntity`/`Doc` node that belongs to a `Community` (via
/// a `MemberOf` edge — `member -> community`, per `brain-ingest::community`)
/// is either:
/// - **collapsed** (its community id is not in `expanded`): the member
///   itself is omitted from `nodes`; any edge that touched it is
///   re-routed to the community's hub node instead of being dropped, so
///   cross-community structure survives the collapse. The hub is emitted
///   once, `kind: "community"`, `size` = its true member count.
/// - **expanded** (its community id is in `expanded`): the real member is
///   emitted instead, and the hub itself is omitted entirely — no
///   orphaned hub node sitting alongside its own members.
///
/// Nodes with no community membership (every `Project` node today, plus
/// any singleton the label-propagation pass didn't group into a
/// multi-member community) are always emitted as themselves.
///
/// Multiple raw edges that resolve to the same `(src, dst, kind)` triple
/// after collapsing — e.g. several member-to-member edges between the
/// same two now-collapsed communities — merge into one `MapLink` with
/// summed weight; otherwise collapsing would trade one hairball of raw
/// edges for a hairball of duplicate hub-to-hub edges, defeating the
/// point. `MemberOf` edges themselves never appear in `links`: once
/// resolved they're either a self-loop (a member and its own collapsed
/// hub resolve to the same id) or dangling (a member's hub was just
/// omitted because it's expanded) — both dropped by the same general
/// same-endpoint / missing-endpoint rules applied to every edge kind.
///
/// ## Filter
///
/// `filter` is a list of `NodeKind` wire-strings (see [`kind_str`]).
/// Applied to the *resolved* (post-collapse) node kind, so filtering to
/// `["memory"]` while a memory node's community is collapsed hides it
/// behind the community hub like everything else in that community —
/// matching what the map actually renders, not the raw graph underneath.
/// A filter that excludes `"community"` also removes hub nodes, by the
/// same literal rule. Empty `filter` = no filtering.
///
/// ## Cap
///
/// After filtering, [`truncate_by_size`] enforces [`MAX_VISIBLE_NODES`]
/// deterministically; `links` are then re-filtered to only those whose
/// both endpoints survived filtering and truncation.
pub fn build_map_graph(
    store: &Store,
    project: Option<&str>,
    expanded: &[String],
    filter: &[String],
) -> anyhow::Result<MapGraph> {
    let (raw_nodes, raw_edges) = match project {
        Some(p) => (store.nodes_for_project(p)?, store.edges_for_project(p)?),
        None => (store.all_nodes()?, store.all_edges()?),
    };

    let expanded_set: HashSet<&str> = expanded.iter().map(|s| s.as_str()).collect();
    let node_by_id: HashMap<&str, &Node> = raw_nodes.iter().map(|n| (n.id.as_str(), n)).collect();

    // member id -> the community hub id it belongs to, for every member
    // whose community node is actually present in this view (project-
    // scoped queries only ever see communities of that same project, so
    // this is always true in practice, but the None-check keeps the logic
    // correct even against a hand-built graph missing the hub node).
    let mut member_to_hub: HashMap<&str, &str> = HashMap::new();
    // community hub id -> true member count, computed before any kind
    // filter or cap so `size` always means "real member count" per the
    // contract, not "members that survived filtering".
    let mut hub_size: HashMap<&str, u32> = HashMap::new();
    for e in &raw_edges {
        if e.kind != EdgeKind::MemberOf {
            continue;
        }
        if let Some(hub) = node_by_id.get(e.dst.as_str()) {
            if hub.kind == NodeKind::Community {
                member_to_hub.insert(e.src.as_str(), e.dst.as_str());
                *hub_size.entry(e.dst.as_str()).or_insert(0) += 1;
            }
        }
    }

    // Resolve every raw node id to the id it appears as in this view (its
    // own id, or its collapsed hub's id) and, separately, the ids that
    // actually get emitted as MapNodes (community hubs are emitted from
    // this same loop, not derived from member_to_hub, so a community with
    // zero surviving members in this scope still shows up as an empty
    // hub rather than vanishing).
    let mut resolved: HashMap<&str, &str> = HashMap::new();
    let mut emit_ids: Vec<&str> = Vec::new();

    for n in &raw_nodes {
        if n.kind == NodeKind::Community {
            if expanded_set.contains(n.id.as_str()) {
                continue; // expanded: omit the hub, members appear below
            }
            resolved.insert(n.id.as_str(), n.id.as_str());
            emit_ids.push(n.id.as_str());
            continue;
        }
        match member_to_hub.get(n.id.as_str()) {
            Some(&hub_id) if !expanded_set.contains(hub_id) => {
                resolved.insert(n.id.as_str(), hub_id); // collapsed into its hub
            }
            _ => {
                // No community, or its community is expanded: show as itself.
                resolved.insert(n.id.as_str(), n.id.as_str());
                emit_ids.push(n.id.as_str());
            }
        }
    }

    let mut nodes: Vec<MapNode> = emit_ids
        .into_iter()
        .map(|id| {
            let n = node_by_id[id];
            let size = if n.kind == NodeKind::Community {
                *hub_size.get(id).unwrap_or(&0)
            } else {
                SINGLE_ENTITY_SIZE
            };
            MapNode {
                id: n.id.clone(),
                kind: kind_str(n.kind).to_string(),
                label: n.label.clone(),
                project: n.project.clone(),
                size,
            }
        })
        .collect();

    let filter_set: HashSet<&str> = filter.iter().map(|s| s.as_str()).collect();
    if !filter_set.is_empty() {
        nodes.retain(|n| filter_set.contains(n.kind.as_str()));
    }

    nodes = truncate_by_size(nodes, MAX_VISIBLE_NODES);
    nodes.sort_by(|a, b| a.id.cmp(&b.id));

    let visible: HashSet<&str> = nodes.iter().map(|n| n.id.as_str()).collect();

    // Re-route + aggregate: every raw edge maps through `resolved` to its
    // view-level endpoints; same-endpoint (collapsed self-loop / dangling
    // expanded-hub reference) and endpoints that didn't survive
    // filter/cap are dropped; everything else merges by (src, dst, kind).
    let mut link_weight: HashMap<(&str, &str, &'static str), f32> = HashMap::new();
    for e in &raw_edges {
        let (Some(&s), Some(&d)) = (resolved.get(e.src.as_str()), resolved.get(e.dst.as_str()))
        else {
            continue;
        };
        if s == d {
            continue;
        }
        if !visible.contains(s) || !visible.contains(d) {
            continue;
        }
        let key = (s, d, edge_kind_str(e.kind));
        *link_weight.entry(key).or_insert(0.0) += e.weight;
    }

    let mut links: Vec<MapLink> = link_weight
        .into_iter()
        .map(|((src, dst, kind), weight)| MapLink {
            src: src.to_string(),
            dst: dst.to_string(),
            kind: kind.to_string(),
            weight,
        })
        .collect();
    links.sort_by(|a, b| {
        a.src
            .cmp(&b.src)
            .then_with(|| a.dst.cmp(&b.dst))
            .then_with(|| a.kind.cmp(&b.kind))
    });

    Ok(MapGraph { nodes, links })
}

/// One graph neighbor of a node-detail lookup: the typed edge plus a flat
/// projection of the neighboring node (id/kind/label/project — no
/// path/summary, since the detail panel only needs enough to render a
/// clickable backlink row and re-fetch full detail on demand).
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct MapNodeBacklink {
    pub edge_kind: String,
    pub id: String,
    pub kind: String,
    pub label: String,
    pub project: String,
}

/// The full record behind Task 6.2's detail panel — everything
/// [`MapNode`] deliberately omits (`path`, `summary`) plus its graph
/// neighbors. A *new* command rather than a change to [`MapNode`]/
/// [`MapGraph`]: Task 6.1's wire contract is frozen, and the map canvas
/// itself never needs `path`/`summary` for the thousands of nodes it
/// renders every frame — only the one node a user actually clicks.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct MapNodeDetail {
    pub id: String,
    pub kind: String,
    pub label: String,
    pub project: String,
    pub path: Option<String>,
    pub summary: Option<String>,
    pub backlinks: Vec<MapNodeBacklink>,
}

/// Cap on backlinks returned per detail lookup — mirrors `mcp_server::tools`'
/// own `RELATED_LIMIT` (25): a detail panel is a human-scannable list, not a
/// full adjacency dump.
const DETAIL_BACKLINKS_LIMIT: usize = 25;

/// The `map_node_detail` Tauri command backing Task 6.2's detail panel:
/// looks up one node by id and its graph neighbors. `Ok(None)` (not an
/// error) when the id doesn't exist — e.g. a stale click after the brain
/// re-ingested — so the UI can show "not found" instead of an error toast.
#[tauri::command]
pub fn map_node_detail(
    id: String,
    brain: State<'_, BrainState>,
) -> Result<Option<MapNodeDetail>, String> {
    let store = brain.store.lock().map_err(|e| e.to_string())?;
    build_map_node_detail(&store, &id).map_err(|e| e.to_string())
}

/// Pure `Store` in, `Option<MapNodeDetail>` out — same split as
/// [`build_map_graph`], for the same reason (directly unit-testable, no
/// Tauri involved).
pub fn build_map_node_detail(store: &Store, id: &str) -> anyhow::Result<Option<MapNodeDetail>> {
    let Some(node) = store.get_node(id)? else {
        return Ok(None);
    };
    let neighbors = store.neighbors(id, DETAIL_BACKLINKS_LIMIT)?;
    let backlinks = neighbors
        .into_iter()
        .map(|(edge, n)| MapNodeBacklink {
            edge_kind: edge_kind_str(edge.kind).to_string(),
            id: n.id,
            kind: kind_str(n.kind).to_string(),
            label: n.label,
            project: n.project,
        })
        .collect();
    Ok(Some(MapNodeDetail {
        id: node.id,
        kind: kind_str(node.kind).to_string(),
        label: node.label,
        project: node.project,
        path: node.path,
        summary: node.summary,
        backlinks,
    }))
}

/// Deterministically truncates `nodes` to at most `limit` entries: highest
/// `size` first (community hubs represent the most collapsed information,
/// so they carry the most signal per visible node — plain nodes are all
/// tied at [`SINGLE_ENTITY_SIZE`], so among those this degrades to the
/// "simplest: sorted by id" option PLAN.md names), ties broken by `id` so
/// two calls over the same input always agree. PLAN.md Task 6.1's own
/// wording: "truncate deterministically ... do not silently return fewer
/// than what a naive slice would give inconsistently across calls." Pure
/// and `Store`-free so it's directly unit-testable at cap scale without a
/// real >3000-node ingest.
pub fn truncate_by_size(mut nodes: Vec<MapNode>, limit: usize) -> Vec<MapNode> {
    if nodes.len() <= limit {
        return nodes;
    }
    nodes.sort_by(|a, b| b.size.cmp(&a.size).then_with(|| a.id.cmp(&b.id)));
    nodes.truncate(limit);
    nodes
}

#[cfg(test)]
mod tests {
    use super::*;
    use brain_core::{now_ts, Edge, Origin};
    use std::path::PathBuf;
    use tempfile::tempdir;

    fn fixture_root() -> PathBuf {
        PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .unwrap() // repo root
            .join("fixtures/sample-project")
    }

    fn ingested_fixture_store() -> Store {
        let store = Store::open_in_memory().unwrap();
        brain_ingest::ingest_project(&store, &fixture_root(), "sample-project").unwrap();
        store
    }

    // --- PLAN.md Task 6.1's exact asks, against the real ingested fixture ---

    #[test]
    fn collapsed_view_returns_community_hubs_and_no_raw_code_entity_leaves() {
        let store = ingested_fixture_store();

        let graph = build_map_graph(&store, Some("sample-project"), &[], &[]).unwrap();

        assert!(
            graph
                .nodes
                .iter()
                .all(|n| n.kind != "code_entity" && n.kind != "file" && n.kind != "doc"),
            "collapsed view must hide every raw leaf, got {:?}",
            graph.nodes
        );
        let hubs: Vec<&MapNode> = graph
            .nodes
            .iter()
            .filter(|n| n.kind == "community")
            .collect();
        assert_eq!(hubs.len(), 3, "{:?}", graph.nodes);
        assert!(
            graph
                .nodes
                .iter()
                .any(|n| n.kind == "project" && n.id == "sample-project"),
            "{:?}",
            graph.nodes
        );
        // Fixture's known shape (see crates/brain-ingest's own ingest_test.rs):
        // community:0 = {README.md, docs/notes.md}, community:1 =
        // {helpers.py, helpers.py#parse_config, main.py, main.py#fetch_data},
        // community:2 = {src/auth.ts, src/auth.ts#login, src/util.ts,
        // src/util.ts#hashPassword}.
        let sizes: HashMap<&str, u32> = graph
            .nodes
            .iter()
            .filter(|n| n.kind == "community")
            .map(|n| (n.id.as_str(), n.size))
            .collect();
        assert_eq!(sizes["sample-project:community:0"], 2);
        assert_eq!(sizes["sample-project:community:1"], 4);
        assert_eq!(sizes["sample-project:community:2"], 4);
    }

    #[test]
    fn expanding_a_community_shows_members_and_removes_its_hub() {
        let store = ingested_fixture_store();

        let graph = build_map_graph(
            &store,
            Some("sample-project"),
            &["sample-project:community:1".to_string()],
            &[],
        )
        .unwrap();

        assert!(
            !graph
                .nodes
                .iter()
                .any(|n| n.id == "sample-project:community:1"),
            "expanded hub must be gone: {:?}",
            graph.nodes
        );
        // The other two communities stay collapsed.
        assert!(graph
            .nodes
            .iter()
            .any(|n| n.id == "sample-project:community:0"));
        assert!(graph
            .nodes
            .iter()
            .any(|n| n.id == "sample-project:community:2"));

        for expected_member in [
            "sample-project:helpers.py",
            "sample-project:helpers.py#parse_config",
            "sample-project:main.py",
            "sample-project:main.py#fetch_data",
        ] {
            assert!(
                graph.nodes.iter().any(|n| n.id == expected_member),
                "missing expanded member {expected_member} in {:?}",
                graph.nodes
            );
        }

        // Real edges between expanded members must survive as links, not
        // just the nodes.
        assert!(
            graph
                .links
                .iter()
                .any(|l| l.src == "sample-project:helpers.py"
                    && l.dst == "sample-project:helpers.py#parse_config"
                    && l.kind == "contains"),
            "{:?}",
            graph.links
        );
        assert!(
            graph.links.iter().any(|l| l.src == "sample-project:main.py"
                && l.dst == "sample-project:helpers.py"
                && l.kind == "imports"),
            "{:?}",
            graph.links
        );
    }

    #[test]
    fn filter_by_memory_kind_excludes_code_nodes() {
        let store = ingested_fixture_store();
        // The raw fixture has no Memory nodes (no Phase 4/7 enrichment run
        // here) — seed one directly so the filter mechanism has something
        // to prove itself against, per PLAN.md Task 6.1's own guidance.
        store
            .upsert_node(&Node {
                id: "sample-project:memory:note-1".to_string(),
                kind: NodeKind::Memory,
                project: "sample-project".to_string(),
                label: "Session: added auth".to_string(),
                path: None,
                summary: None,
                origin: Origin::MachineSummary,
                updated: now_ts(),
            })
            .unwrap();

        let graph =
            build_map_graph(&store, Some("sample-project"), &[], &["memory".to_string()]).unwrap();

        assert_eq!(graph.nodes.len(), 1, "{:?}", graph.nodes);
        assert_eq!(graph.nodes[0].id, "sample-project:memory:note-1");
        assert_eq!(graph.nodes[0].kind, "memory");
        assert!(graph.nodes.iter().all(|n| n.kind != "code_entity"));
        // Its endpoints didn't survive the filter, so no links reference it.
        assert!(graph.links.is_empty());
    }

    #[test]
    fn empty_filter_shows_everything_no_filtering() {
        let store = ingested_fixture_store();
        let unfiltered = build_map_graph(&store, Some("sample-project"), &[], &[]).unwrap();
        let explicitly_all = build_map_graph(
            &store,
            Some("sample-project"),
            &[],
            &["project".to_string(), "community".to_string()],
        )
        .unwrap();
        assert_eq!(unfiltered.nodes.len(), explicitly_all.nodes.len());
    }

    // --- The re-route-to-hub mechanism, isolated from the fixture's own
    // (edge-isolated) community shape, since none of its raw edges happen
    // to cross a community boundary. Built directly against a Store so the
    // cross-community case is exercised precisely. ---

    #[test]
    fn cross_community_edges_reroute_to_hubs_and_aggregate_instead_of_dropping() {
        let store = Store::open_in_memory().unwrap();
        let node = |id: &str, kind: NodeKind, label: &str| Node {
            id: id.to_string(),
            kind,
            project: "px".to_string(),
            label: label.to_string(),
            path: None,
            summary: None,
            origin: Origin::Extracted,
            updated: now_ts(),
        };

        for id in ["px:m1", "px:m2", "px:m3", "px:m4"] {
            store.upsert_node(&node(id, NodeKind::File, id)).unwrap();
        }
        store
            .upsert_node(&node("px:community:0", NodeKind::Community, "Community 0"))
            .unwrap();
        store
            .upsert_node(&node("px:community:1", NodeKind::Community, "Community 1"))
            .unwrap();
        for (member, hub) in [
            ("px:m1", "px:community:0"),
            ("px:m2", "px:community:0"),
            ("px:m3", "px:community:1"),
            ("px:m4", "px:community:1"),
        ] {
            store
                .upsert_edge(&Edge {
                    src: member.to_string(),
                    dst: hub.to_string(),
                    kind: EdgeKind::MemberOf,
                    weight: 1.0,
                })
                .unwrap();
        }
        // Two cross-community edges, same kind, same resolved (hub, hub)
        // pair once collapsed — must merge into one aggregated link, not
        // be dropped and not appear twice.
        store
            .upsert_edge(&Edge {
                src: "px:m1".to_string(),
                dst: "px:m3".to_string(),
                kind: EdgeKind::Imports,
                weight: 1.0,
            })
            .unwrap();
        store
            .upsert_edge(&Edge {
                src: "px:m2".to_string(),
                dst: "px:m4".to_string(),
                kind: EdgeKind::Imports,
                weight: 1.0,
            })
            .unwrap();
        // An intra-community edge, which must collapse to a dropped
        // self-loop rather than surviving as a link.
        store
            .upsert_edge(&Edge {
                src: "px:m1".to_string(),
                dst: "px:m2".to_string(),
                kind: EdgeKind::References,
                weight: 5.0,
            })
            .unwrap();

        let graph = build_map_graph(&store, Some("px"), &[], &[]).unwrap();

        assert_eq!(graph.nodes.len(), 2, "{:?}", graph.nodes);
        assert!(graph.nodes.iter().all(|n| n.kind == "community"));

        assert_eq!(graph.links.len(), 1, "{:?}", graph.links);
        let link = &graph.links[0];
        assert_eq!(link.src, "px:community:0");
        assert_eq!(link.dst, "px:community:1");
        assert_eq!(link.kind, "imports");
        assert_eq!(link.weight, 2.0, "the two m1->m3 / m2->m4 edges must sum");
    }

    #[test]
    fn whole_brain_view_spans_multiple_projects() {
        let store = Store::open_in_memory().unwrap();
        let node = |id: &str, project: &str| Node {
            id: id.to_string(),
            kind: NodeKind::File,
            project: project.to_string(),
            label: id.to_string(),
            path: None,
            summary: None,
            origin: Origin::Extracted,
            updated: now_ts(),
        };
        store.upsert_node(&node("p1:a.ts", "p1")).unwrap();
        store.upsert_node(&node("p2:b.ts", "p2")).unwrap();

        let scoped = build_map_graph(&store, Some("p1"), &[], &[]).unwrap();
        assert_eq!(scoped.nodes.len(), 1);

        let whole_brain = build_map_graph(&store, None, &[], &[]).unwrap();
        assert_eq!(whole_brain.nodes.len(), 2);
        assert!(whole_brain.nodes.iter().any(|n| n.project == "p1"));
        assert!(whole_brain.nodes.iter().any(|n| n.project == "p2"));
    }

    // --- The 3000-node cap: a pure unit test against the truncation
    // helper, per PLAN.md Task 6.1's own guidance ("you likely can't
    // easily produce >3000 real nodes in a fast test"). ---

    fn synthetic_node(id: &str, size: u32) -> MapNode {
        MapNode {
            id: id.to_string(),
            kind: "file".to_string(),
            label: id.to_string(),
            project: "p".to_string(),
            size,
        }
    }

    #[test]
    fn truncate_by_size_is_a_noop_under_the_limit() {
        let nodes = vec![synthetic_node("a", 1), synthetic_node("b", 1)];
        let result = truncate_by_size(nodes.clone(), 10);
        assert_eq!(result.len(), 2);
    }

    #[test]
    fn truncate_by_size_keeps_highest_size_first() {
        let nodes = vec![
            synthetic_node("low", 1),
            synthetic_node("high", 100),
            synthetic_node("mid", 10),
        ];
        let result = truncate_by_size(nodes, 2);
        let ids: Vec<&str> = result.iter().map(|n| n.id.as_str()).collect();
        assert_eq!(ids, vec!["high", "mid"]);
    }

    #[test]
    fn truncate_by_size_breaks_ties_by_id_and_is_deterministic() {
        let nodes: Vec<MapNode> = vec![
            synthetic_node("z", 1),
            synthetic_node("a", 1),
            synthetic_node("m", 1),
        ];
        let first = truncate_by_size(nodes.clone(), 2);
        let second = truncate_by_size(nodes, 2);
        assert_eq!(first, second, "truncation must be deterministic");
        let ids: Vec<&str> = first.iter().map(|n| n.id.as_str()).collect();
        assert_eq!(ids, vec!["a", "m"], "ties break by ascending id");
    }

    #[test]
    fn truncate_by_size_enforces_the_real_map_graph_cap() {
        let nodes: Vec<MapNode> = (0..MAX_VISIBLE_NODES + 500)
            .map(|i| synthetic_node(&format!("n{i:05}"), 1))
            .collect();
        let result = truncate_by_size(nodes, MAX_VISIBLE_NODES);
        assert_eq!(result.len(), MAX_VISIBLE_NODES);
    }

    #[test]
    fn tempdir_smoke_ingest_still_matches_the_in_memory_fixture() {
        // Sanity check that on-disk Store::open behaves the same as
        // Store::open_in_memory for this module's purposes (both the
        // ingest tests above and manual verification use disk-backed
        // stores), following the same tempdir pattern brain-ingest's own
        // tests use.
        let dir = tempdir().unwrap();
        let store = Store::open(dir.path()).unwrap();
        brain_ingest::ingest_project(&store, &fixture_root(), "sample-project").unwrap();
        let graph = build_map_graph(&store, Some("sample-project"), &[], &[]).unwrap();
        assert_eq!(
            graph.nodes.iter().filter(|n| n.kind == "community").count(),
            3
        );
    }

    // --- Task 6.2's `map_node_detail` command, backing the detail panel ---

    #[test]
    fn node_detail_returns_none_for_unknown_id() {
        let store = ingested_fixture_store();
        let detail = build_map_node_detail(&store, "sample-project:does-not-exist").unwrap();
        assert!(detail.is_none());
    }

    #[test]
    fn node_detail_returns_path_and_summary_the_map_graph_response_omits() {
        let store = ingested_fixture_store();
        store
            .upsert_node(&Node {
                summary: Some("Handles login.".to_string()),
                ..store
                    .get_node("sample-project:src/auth.ts")
                    .unwrap()
                    .expect("fixture has src/auth.ts")
            })
            .unwrap();

        let detail = build_map_node_detail(&store, "sample-project:src/auth.ts")
            .unwrap()
            .expect("node exists");

        assert_eq!(detail.id, "sample-project:src/auth.ts");
        assert_eq!(detail.kind, "file");
        assert_eq!(detail.project, "sample-project");
        assert_eq!(detail.path.as_deref(), Some("src/auth.ts"));
        assert_eq!(detail.summary.as_deref(), Some("Handles login."));
    }

    #[test]
    fn node_detail_includes_typed_backlinks() {
        let store = ingested_fixture_store();

        let detail = build_map_node_detail(&store, "sample-project:src/auth.ts")
            .unwrap()
            .expect("node exists");

        assert!(
            detail.backlinks.iter().any(|b| b.edge_kind == "contains"
                && b.id == "sample-project:src/auth.ts#login"
                && b.kind == "code_entity"),
            "{:?}",
            detail.backlinks
        );
        assert!(
            detail
                .backlinks
                .iter()
                .any(|b| b.edge_kind == "imports" && b.id == "sample-project:src/util.ts"),
            "{:?}",
            detail.backlinks
        );
    }
}
