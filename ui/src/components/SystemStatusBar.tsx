export interface SystemStats {
  cpuPercent: number | null;
  ramUsedBytes: number | null;
  ramTotalBytes: number | null;
  mcpWired: boolean;
}

interface SystemStatusBarProps extends SystemStats {
  liveSessionCount: number;
  brainNodeCount: number | null;
  brainQueueCount: number | null;
}

function usageColor(pct: number | null): string {
  if (pct === null) return "";
  if (pct > 75) return " is-usage-critical";
  if (pct > 50) return " is-usage-warn";
  if (pct > 25) return " is-usage-ok";
  return " is-usage-low";
}

function fmtPct(pct: number | null): string {
  return pct === null ? "—" : `${pct}%`;
}

export default function SystemStatusBar({
  liveSessionCount,
  brainNodeCount,
  brainQueueCount,
  cpuPercent,
  ramUsedBytes,
  ramTotalBytes,
  mcpWired,
}: SystemStatusBarProps) {
  const brain = brainNodeCount === null ? "brain — nodes · queue —" : `brain ${brainNodeCount.toLocaleString()} nodes · queue ${brainQueueCount ?? "—"}`;
  const ramPct = ramUsedBytes !== null && ramTotalBytes !== null && ramTotalBytes > 0
    ? Math.round((ramUsedBytes / ramTotalBytes) * 100)
    : null;

  return (
    <footer className="system-status-bar" aria-label="System status">
      <span className="system-status-item is-live"><i aria-hidden="true" />{liveSessionCount} sessions live</span>
      <span className="system-status-item">{brain}</span>
      <span className="system-status-spacer" />
      <span className={`system-status-item${usageColor(cpuPercent)}`}>CPU {fmtPct(cpuPercent)}</span>
      <span className="system-status-item" aria-hidden="true">·</span>
      <span className={`system-status-item${usageColor(ramPct)}`}>RAM {fmtPct(ramPct)}</span>
      <span className="system-status-item is-mcp"><i aria-hidden="true" />{mcpWired ? "MCP wired" : "MCP unavailable"}</span>
      <span className="system-status-shortcut">⌘K</span>
    </footer>
  );
}
