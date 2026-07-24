// Task 6.1 named this hook in its own description; Task 6.2 is the first to
// actually need it. Wraps `map_graph`, transforms the wire shape into
// force-graph's `graphData` shape, and merges each new fetch into the
// previous one so nodes that persist across an expand/collapse/filter click
// keep their live simulation position instead of jumping (see
// `graphTransform.ts`'s `mergeGraphData` doc for why that matters).
import { useEffect, useRef, useState } from "react";
import { mapGraph } from "../lib/tauri";
import { mergeGraphData, transformMapGraph, type GraphData } from "./graphTransform";

const EMPTY: GraphData = { nodes: [], links: [] };

export interface UseGraphDataResult {
  data: GraphData;
  loading: boolean;
  error: string | null;
}

export function useGraphData(
  project: string | null,
  expanded: string[],
  filter: string[],
): UseGraphDataResult {
  const [data, setData] = useState<GraphData>(EMPTY);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const dataRef = useRef<GraphData>(EMPTY);

  // Stable dependency keys — `expanded`/`filter` are typically re-created
  // arrays on every render of the parent even when their contents didn't
  // change, and this hook does a real IPC round trip + a fresh force-sim
  // digest on every fetch, so re-running on referential churn alone would
  // be wasteful and would also fight `mergeGraphData`'s whole point.
  const expandedKey = expanded.slice().sort().join(",");
  const filterKey = filter.slice().sort().join(",");

  useEffect(() => {
    let cancelled = false;
    setLoading(true);
    mapGraph(project, expanded, filter)
      .then((wire) => {
        if (cancelled) return;
        const merged = mergeGraphData(dataRef.current, transformMapGraph(wire));
        dataRef.current = merged;
        setData(merged);
        setError(null);
        // Real-IPC-data-flow proof for manual verification (Task 6.2's own
        // gate: "log the actual node/link counts your useGraphData hook
        // receives from a real map_graph call and confirm they match Task
        // 6.1's reported real numbers").
        console.info(
          `[omniagent-ade] map_graph(project=${project ?? "*"}, expanded=${expanded.length}, filter=${filter.length}) -> ${wire.nodes.length} nodes, ${wire.links.length} links`,
        );
      })
      .catch((err) => {
        if (cancelled) return;
        console.error("map_graph failed", err);
        setError(String(err));
      })
      .finally(() => {
        if (!cancelled) setLoading(false);
      });
    return () => {
      cancelled = true;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [project, expandedKey, filterKey]);

  return { data, loading, error };
}
