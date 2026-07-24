// The brain map pane (Task 6.2) — DESIGN.md's "flagship pane" / PLAN.md's
// "money screenshot". Orchestrates: `useGraphData` (the live IPC feed),
// `graphState`'s reducer (layout/filter/expand/search/fullscreen/selection),
// `RadialLayout`/`HierarchyLayout` (pure positioning math), `Lens` (filter +
// legend chrome), and `DetailPanel` (node actions) around a
// `react-force-graph-2d` canvas.
//
// Search-to-focus: client-side, over the currently *loaded* node set
// (label substring match) rather than a `brain_query` server search. A
// server hit can name a node that's presently collapsed inside a community
// hub — making that useful would mean resolving its ancestor chain and
// auto-expanding, which is real scope beyond this task. Client-side search
// is the honest, simpler primitive: it finds what's on screen (or tells you
// to expand first), and reuses zero extra IPC round trips.
//
// Fullscreen: an in-pane CSS overlay (`position: fixed; inset: 0`), not the
// browser Fullscreen API — more reliable inside a Tauri WebView, no
// permission prompt, and matches the g-brain reference's own "Fullscreen"
// button (which reads as "give the graph the whole window," not an OS-level
// fullscreen mode).
import { useCallback, useEffect, useMemo, useReducer, useRef, useState } from "react";
import ForceGraph2D, { type ForceGraphMethods, type NodeObject } from "react-force-graph-2d";
import { initialMapUiState, mapUiReducer, type NodeKindWire } from "./graphState";
import { useGraphData } from "./useGraphData";
import { applyRadialPositions, clearPins } from "./RadialLayout";
import { dagLevelDistanceFor, hierarchyLinks } from "./HierarchyLayout";
import { colorForKind, isHubKind } from "./palette";
import { shouldShowNodeLabel } from "./labelVisibility";
import Lens from "./Lens";
import DetailPanel from "./DetailPanel";
import type { GraphLink, GraphNode } from "./graphTransform";
import type { ProjectInfo } from "../state/sessions";
import { enrichQueuePendingCount } from "../lib/tauri";

/** Task 8.1's degradation badge: how often to poll the enrichment backlog
 * count. Independent of (and much lighter than) `livePollMs` — this runs at
 * a fixed, low cadence the whole time the map is mounted, not just during
 * onboarding, since a stale-summary backlog can build up any time the
 * user's `claude` CLI is offline. */
const ENRICH_BACKLOG_POLL_MS = 8000;

const RADIAL_RING_RADIUS = 320;
const DOUBLE_CLICK_MS = 350;
const BASE_NODE_RADIUS = 3;
const HUB_RADIUS_MULT = 2.4;
const LEAF_RADIUS_MULT = 1.15;
const MAX_NODE_RADIUS = 28;

function nodeRadius(node: GraphNode): number {
  const magnitude = Math.sqrt(Math.max(1, node.size));
  const mult = isHubKind(node.kind) ? HUB_RADIUS_MULT : LEAF_RADIUS_MULT;
  return Math.min(MAX_NODE_RADIUS, BASE_NODE_RADIUS + magnitude * mult);
}

interface BrainMapProps {
  projects: ProjectInfo[];
  onOpenTerminal: (project: ProjectInfo) => void;
  /** Kept mounted at all times by `App.tsx` (same reason `Terminal.tsx` stays
   * mounted across tab switches) so camera position, expand/filter state,
   * and the force simulation survive toggling back to the workspace view;
   * visibility is CSS-only. */
  hidden: boolean;
  /** Task 8.1: set by `App.tsx` to ~2s while onboarding/rebuild ingestion is
   * running, so the map's own `useGraphData` re-fetches and visibly grows
   * in near-real-time — "the map pane growing live IS the onboarding"
   * (DESIGN.md 4). `undefined` the rest of the time (no polling overhead). */
  livePollMs?: number;
}

export default function BrainMap({ projects, onOpenTerminal, hidden, livePollMs }: BrainMapProps) {
  const [ui, dispatch] = useReducer(mapUiReducer, initialMapUiState);
  const { data, loading, error } = useGraphData(null, ui.expanded, ui.filter, livePollMs);
  const [enrichBacklog, setEnrichBacklog] = useState(0);

  // Degradation surface: the enrichment queue backlog badge (Task 8.1).
  // Runs on its own fixed cadence regardless of `hidden` — cheap (a single
  // COUNT query) and the badge should already read correctly the instant
  // the user switches back into this view, not a poll-cycle later.
  useEffect(() => {
    let cancelled = false;
    const tick = () => {
      enrichQueuePendingCount()
        .then((n) => {
          if (!cancelled) setEnrichBacklog(n);
        })
        .catch((err) => console.error("enrich_queue_pending_count failed", err));
    };
    tick();
    const interval = window.setInterval(tick, ENRICH_BACKLOG_POLL_MS);
    return () => {
      cancelled = true;
      window.clearInterval(interval);
    };
  }, []);

  const containerRef = useRef<HTMLDivElement | null>(null);
  const fgRef = useRef<ForceGraphMethods<GraphNode, GraphLink> | undefined>(undefined);
  const lastBackgroundClickRef = useRef<number>(0);
  // The currently-hovered node id (Bruno's zoom/hover-gated labels ask —
  // see `labelVisibility.ts`). A ref, not `useState`: `paintNode` runs on
  // react-force-graph-2d's own render loop, not React's, so it can read
  // `.current` directly every frame without needing a React re-render on
  // every hover change (mousemove-driven hover transitions are frequent
  // enough that re-rendering the whole pane — Lens, stats, topbar — on each
  // one would be exactly the kind of unnecessary per-frame-adjacent work
  // this task also asked to check for).
  const hoveredNodeIdRef = useRef<string | null>(null);
  const [size, setSize] = useState({ width: 0, height: 0 });
  const [searchInput, setSearchInput] = useState("");
  const [searchMiss, setSearchMiss] = useState(false);

  // ---- size the canvas to its container --------------------------------
  useEffect(() => {
    const el = containerRef.current;
    if (!el) return;
    const measure = () => setSize({ width: el.clientWidth, height: el.clientHeight });
    measure();
    const observer = new ResizeObserver(measure);
    observer.observe(el);
    return () => observer.disconnect();
  }, [ui.fullscreen]);

  // Re-measure (and resume) whenever this pane stops being hidden — it may
  // have been laid out at 0x0 while `display: none`.
  useEffect(() => {
    if (hidden) {
      fgRef.current?.pauseAnimation();
      return;
    }
    fgRef.current?.resumeAnimation();
    const el = containerRef.current;
    if (el) requestAnimationFrame(() => setSize({ width: el.clientWidth, height: el.clientHeight }));
  }, [hidden]);

  // ---- radial pinning vs hierarchy dag ----------------------------------
  // Project nodes (the top-level category tier — see RadialLayout.ts's own
  // doc) are pinned to the ring in Radial mode; every other node free-floats
  // under the normal force simulation. Switching to Hierarchy clears any
  // leftover pins so `dagMode` isn't fighting them.
  useEffect(() => {
    if (ui.layout === "radial") {
      const hubIds = data.nodes.filter((n) => n.kind === "project").map((n) => n.id);
      applyRadialPositions(data.nodes, hubIds, RADIAL_RING_RADIUS);
    } else {
      clearPins(data.nodes);
    }
    fgRef.current?.d3ReheatSimulation();
  }, [ui.layout, data.nodes]);

  const renderLinks = useMemo(
    () => (ui.layout === "hierarchy" ? hierarchyLinks(data.links) : data.links),
    [ui.layout, data.links],
  );
  const graphData = useMemo(() => ({ nodes: data.nodes, links: renderLinks }), [data.nodes, renderLinks]);

  const dagLevelDistance = useMemo(() => dagLevelDistanceFor(data.nodes.length), [data.nodes.length]);

  // ---- stats (Task 6.2's minimum: nodes/links; plus what's free to derive
  // from data already in hand — no extra IPC call) -----------------------
  const stats = useMemo(() => {
    const projectSet = new Set(data.nodes.map((n) => n.project));
    const kindCounts: Partial<Record<string, number>> = {};
    for (const n of data.nodes) kindCounts[n.kind] = (kindCounts[n.kind] ?? 0) + 1;
    return {
      nodes: data.nodes.length,
      links: data.links.length,
      projects: projectSet.size,
      expanded: ui.expanded.length,
      kindCounts,
    };
  }, [data.nodes, data.links, ui.expanded.length]);

  // ---- interaction -------------------------------------------------------
  const handleNodeClick = useCallback(
    (node: NodeObject<GraphNode>) => {
      if (node.kind === "community") {
        dispatch({ type: "community/expand", id: node.id });
      } else {
        dispatch({ type: "node/select", id: node.id });
      }
    },
    [],
  );

  const handleBackgroundClick = useCallback(() => {
    const now = Date.now();
    const isDoubleClick = now - lastBackgroundClickRef.current < DOUBLE_CLICK_MS;
    lastBackgroundClickRef.current = isDoubleClick ? 0 : now;
    if (isDoubleClick) {
      dispatch({ type: "community/collapseAll" });
    }
  }, []);

  const runSearch = useCallback(() => {
    const q = searchInput.trim().toLowerCase();
    if (!q) return;
    const hit = data.nodes.find((n) => n.label.toLowerCase().includes(q));
    if (!hit) {
      setSearchMiss(true);
      return;
    }
    setSearchMiss(false);
    dispatch({ type: "node/select", id: hit.id });
    const fg = fgRef.current;
    if (fg && typeof hit.x === "number" && typeof hit.y === "number") {
      fg.centerAt(hit.x, hit.y, 600);
      fg.zoom(4, 700);
    }
  }, [searchInput, data.nodes]);

  // ---- canvas paint --------------------------------------------------
  // Post-ship feedback (Bruno, 2026-07-24): "extremely smooth... not the
  // text, only show texts if you zoom enough... or when you hover... also
  // very important to not focus too much on this functionality — the main
  // focus is an ADE" — this dropped the earlier per-node radial-gradient
  // glow entirely (it was a `createRadialGradient` + extra `fill()`
  // allocated on *every* node on *every* frame — real GC/rasterization cost
  // at the "tens of thousands of nodes" scale DESIGN.md targets, and,
  // checked against the g-brain reference screenshots, not actually what
  // the reference does: individual nodes there are flat dots, no halo). The
  // flat dot + hub ring stroke is both cheaper and the more faithful, less
  // "shouty" match to the reference — the map is a supporting pane, not the
  // product.
  const paintNode = useCallback((node: NodeObject<GraphNode>, ctx: CanvasRenderingContext2D, globalScale: number) => {
    const r = nodeRadius(node);
    const color = colorForKind(node.kind);
    const x = node.x ?? 0;
    const y = node.y ?? 0;

    ctx.fillStyle = color;
    ctx.beginPath();
    ctx.arc(x, y, r, 0, 2 * Math.PI, false);
    ctx.fill();

    // Hub kinds (project / community) get an outer ring — the secondary,
    // non-color encoding `palette.ts` documents (see its module doc for
    // why: the 8-hue categorical palette only clears CVD-separation on
    // *adjacent* pairs, not all-pairs, and a force layout puts any two
    // kinds beside each other).
    if (isHubKind(node.kind)) {
      ctx.strokeStyle = color;
      ctx.lineWidth = 1.5 / globalScale;
      ctx.beginPath();
      ctx.arc(x, y, r + 3, 0, 2 * Math.PI, false);
      ctx.stroke();
    }

    // Labels: gated by `shouldShowNodeLabel` (labelVisibility.ts) — bare
    // dot until zoomed in, hovered, or a hub landmark; the ALWAYS-draw-the-
    // glyph / SOMETIMES-draw-the-text split this task asked for.
    const showLabel = shouldShowNodeLabel({
      kind: node.kind,
      globalScale,
      isHovered: hoveredNodeIdRef.current === node.id,
    });
    if (showLabel) {
      const fontSize = Math.max(3, 11 / globalScale);
      ctx.font = `${fontSize}px "JetBrains Mono", monospace`;
      ctx.textAlign = "center";
      ctx.textBaseline = "top";
      ctx.fillStyle = "#c9d3de";
      ctx.fillText(node.label, x, y + r + 2);
    }
  }, []);

  const handleNodeHover = useCallback((node: NodeObject<GraphNode> | null) => {
    hoveredNodeIdRef.current = node ? String(node.id) : null;
    // react-force-graph-2d's `autoPauseRedraw` (on by default, and left on
    // — see the `hidden`-driven pause/resume effect below for why an
    // always-repainting loop is the wrong tradeoff for "extremely smooth")
    // skips the canvas repaint whenever the sim is idle and the camera
    // isn't moving — exactly the common case a user hovers in, on an
    // already-settled graph. `nodeCanvasObject` reading `hoveredNodeIdRef`
    // isn't part of the library's own "does this need a redraw"
    // bookkeeping, so — verified directly against the library's source and
    // empirically against a live instance — a hover-triggered label change
    // otherwise sits invisible until something else (a pan/zoom, a live
    // simulation tick) happens to force a repaint. `zoom()` (get) ->
    // `zoom(get)` (set) is a same-value round trip through the one public
    // API that unconditionally flips the library's internal redraw flag as
    // a side effect, without visibly moving the camera or (like
    // `d3ReheatSimulation` would) un-settling every node's position just to
    // reveal a label.
    const fg = fgRef.current;
    const currentZoom = fg?.zoom();
    if (fg && typeof currentZoom === "number") fg.zoom(currentZoom);
  }, []);

  const paintNodePointerArea = useCallback(
    (node: NodeObject<GraphNode>, color: string, ctx: CanvasRenderingContext2D) => {
      ctx.fillStyle = color;
      ctx.beginPath();
      ctx.arc(node.x ?? 0, node.y ?? 0, nodeRadius(node) + 2, 0, 2 * Math.PI, false);
      ctx.fill();
    },
    [],
  );

  const nodeLabelAccessor = useCallback(
    (node: NodeObject<GraphNode>) => `${node.kind}: ${node.label}`,
    [],
  );

  const linkColorAccessor = useCallback((link: GraphLink) => {
    const alpha = Math.min(0.85, 0.25 + Math.log2(1 + link.weight) * 0.15);
    return `rgba(102, 116, 138, ${alpha})`; // --ink-dim, weight-modulated
  }, []);

  const linkWidthAccessor = useCallback((link: GraphLink) => Math.min(2.5, 0.6 + Math.log2(1 + link.weight) * 0.4), []);

  const isEmpty = !loading && !error && data.nodes.length === 0;

  return (
    <div
      ref={containerRef}
      className={`brain-map${ui.fullscreen ? " is-fullscreen" : ""}`}
      style={{ display: hidden ? "none" : "grid" }}
    >
      <div className="brain-map-topbar">
        <div className="brain-map-layout-toggle" role="tablist" aria-label="Map layout">
          <button
            className={ui.layout === "radial" ? "is-active" : ""}
            role="tab"
            aria-selected={ui.layout === "radial"}
            onClick={() => dispatch({ type: "layout/set", layout: "radial" })}
          >
            Radial
          </button>
          <button
            className={ui.layout === "hierarchy" ? "is-active" : ""}
            role="tab"
            aria-selected={ui.layout === "hierarchy"}
            onClick={() => dispatch({ type: "layout/set", layout: "hierarchy" })}
          >
            Hierarchy
          </button>
        </div>

        <div className="brain-map-search">
          <input
            placeholder="Find a node…"
            value={searchInput}
            onChange={(e) => {
              setSearchInput(e.currentTarget.value);
              setSearchMiss(false);
            }}
            onKeyDown={(e) => {
              if (e.key === "Enter") runSearch();
            }}
          />
          {searchMiss && <span className="brain-map-search-miss">no match in the loaded view</span>}
        </div>

        {enrichBacklog > 0 && (
          <span
            className="brain-map-enrich-badge"
            title={`${enrichBacklog} enrichment job${enrichBacklog === 1 ? "" : "s"} waiting for your claude CLI (offline, or just busy) — the graph works lexically in the meantime`}
          >
            enrichment queued ({enrichBacklog})
          </span>
        )}

        <button
          className="brain-map-fullscreen"
          onClick={() => dispatch({ type: "fullscreen/toggle" })}
        >
          {ui.fullscreen ? "Exit fullscreen" : "Fullscreen"}
        </button>
      </div>

      <div className="brain-map-canvas-wrap">
        {size.width > 0 && size.height > 0 && (
          <ForceGraph2D
            ref={fgRef}
            width={size.width}
            height={size.height}
            graphData={graphData}
            backgroundColor="#0a0d12"
            nodeRelSize={1}
            nodeCanvasObject={paintNode}
            nodePointerAreaPaint={paintNodePointerArea}
            nodeLabel={nodeLabelAccessor}
            linkColor={linkColorAccessor}
            linkWidth={linkWidthAccessor}
            dagMode={ui.layout === "hierarchy" ? "radialout" : undefined}
            dagLevelDistance={ui.layout === "hierarchy" ? dagLevelDistance : null}
            onDagError={(loopIds) => console.warn("brain map: dag cycle detected, skipping dag layout for", loopIds)}
            onNodeClick={handleNodeClick}
            onNodeHover={handleNodeHover}
            onBackgroundClick={handleBackgroundClick}
            cooldownTime={8000}
            warmupTicks={ui.layout === "radial" ? 60 : 0}
          />
        )}

        {loading && data.nodes.length === 0 && <div className="brain-map-status">Loading the brain…</div>}
        {error && <div className="brain-map-status is-error">Couldn't load the map: {error}</div>}
        {isEmpty && (
          <div className="brain-map-status">
            {ui.filter.length > 0
              ? "Nothing matches the current lens filter."
              : "Nothing ingested yet — run `brain ingest <folder>`, then relaunch."}
          </div>
        )}

        {ui.selectedNodeId && (
          <DetailPanel
            nodeId={ui.selectedNodeId}
            projects={projects}
            onClose={() => dispatch({ type: "node/select", id: null })}
            onSelectNode={(id) => dispatch({ type: "node/select", id })}
            onOpenTerminal={onOpenTerminal}
          />
        )}
      </div>

      <Lens
        filter={ui.filter}
        onToggleKind={(kind: NodeKindWire) => dispatch({ type: "filter/toggle", kind })}
        onClearFilter={() => dispatch({ type: "filter/clear" })}
        counts={stats.kindCounts}
      />

      <div className="brain-map-stats">
        <div className="brain-map-stat">
          <span className="brain-map-stat-value">{stats.nodes}</span>
          <span className="brain-map-stat-label">nodes</span>
        </div>
        <div className="brain-map-stat">
          <span className="brain-map-stat-value">{stats.links}</span>
          <span className="brain-map-stat-label">links</span>
        </div>
        <div className="brain-map-stat">
          <span className="brain-map-stat-value">{stats.projects}</span>
          <span className="brain-map-stat-label">projects</span>
        </div>
        <div className="brain-map-stat">
          <span className="brain-map-stat-value">{stats.expanded}</span>
          <span className="brain-map-stat-label">expanded</span>
        </div>
      </div>
    </div>
  );
}
