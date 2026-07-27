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

function formatRam(bytes: number | null): string {
  return bytes === null ? "—" : `${(bytes / 1024 ** 3).toFixed(1).replace(/\.0$/, "")}G`;
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
  const computer = `CPU ${cpuPercent === null ? "—" : `${cpuPercent}%`} · RAM ${formatRam(ramUsedBytes)} / ${formatRam(ramTotalBytes)}`;

  return (
    <footer className="system-status-bar" aria-label="System status">
      <span className="system-status-item is-live"><i aria-hidden="true" />{liveSessionCount} sessions live</span>
      <span className="system-status-item">{brain}</span>
      <span className="system-status-spacer" />
      <span className="system-status-item">{computer}</span>
      <span className="system-status-item is-mcp"><i aria-hidden="true" />{mcpWired ? "MCP wired" : "MCP unavailable"}</span>
      <span className="system-status-shortcut">⌘K</span>
    </footer>
  );
}
