// Right-side LENS/legend sidebar (g-brain reference: a stacked LENS +
// LEGEND panel). Combined into one component because they're the same
// list, twice — the Lens's checkboxes and the Legend's swatches both walk
// `NODE_KINDS`, so keeping them separate would mean two places that could
// drift out of sync with the palette.
//
// Semantics, worth stating plainly: `map_graph`'s `filter` param is an
// ALLOW-list (`map_feed.rs`: "empty filter = no filtering"). So the Lens
// starts fully unchecked (= show everything); checking one or more kinds
// narrows the view to *only* those. This is the honest mapping onto the
// backend's actual contract rather than faking a hide-list on top of it.
import { NODE_KINDS, type NodeKindWire } from "./graphState";
import { colorForKind, isHubKind, labelForKind } from "./palette";

interface LensProps {
  filter: NodeKindWire[];
  onToggleKind: (kind: NodeKindWire) => void;
  onClearFilter: () => void;
  counts: Partial<Record<string, number>>;
}

export default function Lens({ filter, onToggleKind, onClearFilter, counts }: LensProps) {
  const filtering = filter.length > 0;

  return (
    <aside className="map-lens" aria-label="Lens and legend">
      <div className="map-lens-section">
        <div className="map-lens-heading">
          <span>LENS</span>
          {filtering && (
            <button className="map-lens-clear" onClick={onClearFilter}>
              show all
            </button>
          )}
        </div>
        <p className="map-lens-hint">
          {filtering ? "Showing only checked kinds." : "Showing everything — check a kind to narrow."}
        </p>
        <ul className="map-lens-list">
          {NODE_KINDS.map((kind) => {
            const active = filter.includes(kind);
            const count = counts[kind] ?? 0;
            return (
              <li key={kind}>
                <label className={`map-lens-row${active ? " is-active" : ""}`}>
                  <input
                    type="checkbox"
                    checked={active}
                    onChange={() => onToggleKind(kind)}
                    aria-label={`Show only ${labelForKind(kind)} nodes`}
                  />
                  <span
                    className={`map-lens-swatch${isHubKind(kind) ? " is-hub" : ""}`}
                    style={{ background: colorForKind(kind) }}
                    aria-hidden
                  />
                  <span className="map-lens-label">{labelForKind(kind)}</span>
                  <span className="map-lens-count">{count}</span>
                </label>
              </li>
            );
          })}
        </ul>
      </div>

      <div className="map-lens-section">
        <div className="map-lens-heading">
          <span>LEGEND</span>
        </div>
        <ul className="map-legend-list">
          {NODE_KINDS.map((kind) => (
            <li key={kind} className="map-legend-row">
              <span
                className={`map-lens-swatch${isHubKind(kind) ? " is-hub" : ""}`}
                style={{ background: colorForKind(kind) }}
                aria-hidden
              />
              <span>{labelForKind(kind)}</span>
              {isHubKind(kind) && <span className="map-legend-hub-note">hub</span>}
            </li>
          ))}
        </ul>
      </div>
    </aside>
  );
}
