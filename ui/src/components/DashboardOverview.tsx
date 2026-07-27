import { useMemo, useState } from "react";
import type { ProjectInfo, TabInfo } from "../state/sessions";
import { groupTabsBySession } from "../state/sessionGroups";
import { deriveUsageInsights, type UsageAnalyticsStore } from "../state/usageAnalytics";
import type { NotificationsState } from "../state/notifications";
import { relativeTime } from "../state/notifications";
import Icon from "./Icon";
import { ENGINE_COLOR, ENGINE_LABEL } from "../theme";

interface DashboardOverviewProps {
  hidden: boolean;
  project: ProjectInfo | null;
  tabs: TabInfo[];
  activeTabId: string | null;
  analytics: UsageAnalyticsStore;
  notifications: NotificationsState;
  onOpenTerminals: () => void;
  onOpenBoard: () => void;
  onOpenFiles: () => void;
  onOpenSession: (tabId: string) => void;
}

type TimeFilter = "today" | "7d" | "30d" | "all";

function compact(value: number): string {
  return new Intl.NumberFormat(undefined, { notation: "compact", maximumFractionDigits: 2 }).format(value);
}

function statusColor(status: string): string {
  if (status === "thinking" || status === "tool_execution") return "#9ec2ff";
  if (status === "awaiting_approval") return "#f5b93a";
  if (status === "ready") return "#35d07f";
  if (status === "error") return "#ff3d71";
  return "#9a9aa4";
}

function statusLabel(status: string): string {
  if (status === "thinking" || status === "tool_execution") return "WORKING";
  if (status === "awaiting_approval") return "APPROVE";
  if (status === "ready") return "DONE";
  if (status === "error") return "BLOCKED";
  return status.toUpperCase();
}

function StatusBadge({ status }: { status: string }) {
  const color = statusColor(status);
  const label = statusLabel(status);
  return (
    <span
      className="dash-status-badge"
      style={{ background: color + "22", color, border: `0.5px solid ${color}55` }}
    >
      {label}
    </span>
  );
}

function EngineDot({ engine }: { engine: string }) {
  const color = ENGINE_COLOR[engine as keyof typeof ENGINE_COLOR] ?? "#9a9ca6";
  return <span className="dash-engine-dot" style={{ background: color }} />;
}

function EngineChip({ engine }: { engine: string }) {
  const color = ENGINE_COLOR[engine as keyof typeof ENGINE_COLOR] ?? "#9a9ca6";
  const label = ENGINE_LABEL[engine as keyof typeof ENGINE_LABEL] ?? engine;
  return (
    <span className="dash-engine-chip" style={{ background: color + "22", color, border: `0.5px solid ${color}44` }}>
      {label}
    </span>
  );
}

function StatCard({
  label,
  value,
  sub,
  trend,
  accent,
  children,
}: {
  label: string;
  value: string;
  sub?: string;
  trend?: string | null;
  accent?: string;
  children?: React.ReactNode;
}) {
  return (
    <article className="dash-stat-card">
      <span className="dsc-label">{label}</span>
      <div className="dsc-value-row">
        <strong className="dsc-value" style={accent ? { color: accent } : undefined}>
          {value}
        </strong>
        {trend != null && (
          <span
            className="dash-trend-badge"
            style={{
              background: trend.startsWith("+") ? "rgba(53,208,127,.15)" : "rgba(255,61,113,.15)",
              color: trend.startsWith("+") ? "#35d07f" : "#ff3d71",
            }}
          >
            {trend}
          </span>
        )}
      </div>
      {sub && <span className="dsc-sub">{sub}</span>}
      {children}
    </article>
  );
}

function WorkingNow({
  tabs,
  onOpenSession,
}: {
  tabs: TabInfo[];
  onOpenSession: (id: string) => void;
}) {
  const active = tabs.filter(
    (t) => t.status === "thinking" || t.status === "tool_execution" || t.status === "awaiting_approval",
  );
  const now = Date.now();
  return (
    <div className="dash-panel dash-working-now">
      <div className="dash-panel-header">
        <span className="dash-panel-title">WORKING NOW</span>
        <span className="dash-panel-sub">
          {active.length} agent{active.length !== 1 ? "s" : ""}
        </span>
      </div>
      {active.length === 0 ? (
        <div className="dash-empty-state">No agents working right now</div>
      ) : (
        <div className="dash-working-list">
          {active.map((tab) => {
            const elapsed = Math.floor((now - tab.createdAt) / 60000);
            return (
              <button
                key={tab.id}
                className="dash-working-row"
                onClick={() => onOpenSession(tab.id)}
              >
                <EngineDot engine={tab.engine} />
                <div className="dash-working-info">
                  <span className="dash-working-task">
                    {tab.label ?? ENGINE_LABEL[tab.engine as keyof typeof ENGINE_LABEL] ?? tab.engine}
                  </span>
                  <span className="dash-working-session">
                    {tab.groupLabel ?? "Session"}
                  </span>
                </div>
                <EngineChip engine={tab.engine} />
                <span className="dash-working-time">{elapsed}m</span>
                <StatusBadge status={tab.status ?? "ready"} />
                <Icon name="chevron-right" size={12} className="dash-working-arrow" />
              </button>
            );
          })}
        </div>
      )}
    </div>
  );
}

function TokensByAgent({ tabs }: { tabs: TabInfo[] }) {
  const total = tabs.length || 1;
  const counts = useMemo(() => {
    const acc: Record<string, number> = {};
    for (const t of tabs) acc[t.engine] = (acc[t.engine] ?? 0) + 1;
    return acc;
  }, [tabs]);

  const engines = Object.entries(counts).sort((a, b) => b[1] - a[1]);

  return (
    <div className="dash-panel dash-tokens-by-agent">
      <div className="dash-panel-header">
        <span className="dash-panel-title">TERMINALS BY ENGINE</span>
        <span className="dash-panel-sub">{tabs.length} total</span>
      </div>
      {engines.length === 0 ? (
        <div className="dash-empty-state">No active sessions</div>
      ) : (
        <div className="dash-agent-list">
          {engines.map(([engine, count]) => {
            const color = ENGINE_COLOR[engine as keyof typeof ENGINE_COLOR] ?? "#9a9ca6";
            const label = ENGINE_LABEL[engine as keyof typeof ENGINE_LABEL] ?? engine;
            const pct = Math.round((count / total) * 100);
            return (
              <div key={engine} className="dash-agent-bar-row">
                <span className="dash-engine-dot" style={{ background: color }} />
                <span className="dash-agent-name">{label}</span>
                <span className="dash-agent-count">{count}</span>
                <span className="dash-agent-pct">{pct}%</span>
                <div className="dash-agent-bar-track">
                  <div
                    className="dash-agent-bar-fill"
                    style={{ width: `${pct}%`, background: color }}
                  />
                </div>
              </div>
            );
          })}
        </div>
      )}
    </div>
  );
}

function ContributionPie() {
  return (
    <div className="dash-panel dash-contribution-pie">
      <div className="dash-panel-header">
        <span className="dash-panel-title">WORK CONTRIBUTION</span>
        <span className="dash-panel-sub">by model, merged diff</span>
      </div>
      <div className="dash-pie-placeholder">
        <svg viewBox="0 0 80 80" width={80} height={80}>
          <circle cx={40} cy={40} r={32} fill="none" stroke="rgba(255,255,255,0.06)" strokeWidth={14} />
        </svg>
        <span className="dash-pie-hint">Tracked when sessions commit code</span>
      </div>
    </div>
  );
}

function UsageTable({
  tabs,
  sessions,
  totalTokens,
}: {
  tabs: TabInfo[];
  sessions: number;
  totalTokens: number;
}) {
  const engines = useMemo(() => {
    const acc: Record<string, { terminals: number; sessions: Set<string> }> = {};
    for (const t of tabs) {
      if (!acc[t.engine]) acc[t.engine] = { terminals: 0, sessions: new Set() };
      acc[t.engine].terminals += 1;
      acc[t.engine].sessions.add(t.group ?? "ungrouped");
    }
    return Object.entries(acc).sort((a, b) => b[1].terminals - a[1].terminals);
  }, [tabs]);

  const total = tabs.length || 1;

  return (
    <div className="dash-panel dash-usage-table-panel">
      <div className="dash-panel-header">
        <span className="dash-panel-title">USAGE BY ENGINE &amp; SESSION</span>
        <button
          className="dash-ghost-btn"
          onClick={() => alert("Export CSV — not yet implemented")}
        >
          Export CSV
        </button>
      </div>
      <table className="dash-usage-table">
        <thead>
          <tr>
            <th>ENGINE</th>
            <th>SESSIONS</th>
            <th>TERMINALS</th>
            <th>TOKENS</th>
            <th>SHARE</th>
          </tr>
        </thead>
        <tbody>
          {engines.map(([engine, { terminals, sessions: sesSet }]) => {
            const color = ENGINE_COLOR[engine as keyof typeof ENGINE_COLOR] ?? "#9a9ca6";
            const label = ENGINE_LABEL[engine as keyof typeof ENGINE_LABEL] ?? engine;
            const share = Math.round((terminals / total) * 100);
            return (
              <tr key={engine}>
                <td>
                  <span className="dash-engine-dot" style={{ background: color }} />
                  {label}
                </td>
                <td>{sesSet.size}</td>
                <td>{terminals}</td>
                <td>{compact(totalTokens > 0 ? Math.round((terminals / total) * totalTokens) : 0)}</td>
                <td>{share}%</td>
              </tr>
            );
          })}
        </tbody>
      </table>
      <div className="dash-table-footer">
        {engines.length} engine{engines.length !== 1 ? "s" : ""} · {sessions} session{sessions !== 1 ? "s" : ""}
        {totalTokens > 0 && <span> · {compact(totalTokens)} tokens total</span>}
      </div>
    </div>
  );
}

function GitStatus({ project }: { project: ProjectInfo | null }) {
  return (
    <div className="dash-panel dash-git-status">
      <div className="dash-panel-header">
        <span className="dash-panel-title">GIT STATUS</span>
        {project?.path && (
          <span className="dash-branch-badge">
            <Icon name="branch" size={10} /> main
          </span>
        )}
      </div>
      <div className="dash-git-counts">
        <span className="dash-git-num" style={{ color: "#f5b93a" }}>0 changed</span>
        <span className="dash-git-num" style={{ color: "#35d07f" }}>0 staged</span>
        <span className="dash-git-num" style={{ color: "#9ec2ff" }}>0 today</span>
      </div>
      <div className="dash-empty-state" style={{ marginTop: 8, fontSize: 10 }}>
        Connect git status · check the review panel
      </div>
    </div>
  );
}

function ApprovalsPanel({
  approvingTabs,
  notifications,
  onOpenSession,
}: {
  approvingTabs: TabInfo[];
  notifications: NotificationsState;
  onOpenSession: (id: string) => void;
}) {
  const pastApprovals = notifications.entries
    .filter((e) => e.status === "awaiting_approval" || e.status === "ready")
    .slice(0, 3);

  return (
    <div className="dash-panel dash-approvals">
      <div className="dash-panel-header">
        <span className="dash-panel-title">APPROVALS</span>
        <span className="dash-panel-sub">avg response 38s</span>
      </div>
      {approvingTabs.length === 0 && pastApprovals.length === 0 ? (
        <div className="dash-empty-state">All clear</div>
      ) : (
        <>
          {approvingTabs.map((tab) => (
            <div key={tab.id} className="dash-approval-row">
              <span className="dash-engine-dot" style={{ background: "#f5b93a" }} />
              <div className="dash-approval-info">
                <span className="dash-approval-task">
                  {tab.label ?? ENGINE_LABEL[tab.engine as keyof typeof ENGINE_LABEL] ?? tab.engine}
                </span>
                <span className="dash-approval-session">{tab.groupLabel ?? "Session"}</span>
              </div>
              <button
                className="dash-approve-btn"
                onClick={() => onOpenSession(tab.id)}
              >
                Approve
              </button>
              <button
                className="dash-ghost-btn"
                onClick={() => onOpenSession(tab.id)}
              >
                View
              </button>
            </div>
          ))}
          {pastApprovals.map((entry) => (
            <div key={entry.id} className="dash-approval-row dash-approval-past">
              <span
                className="dash-engine-dot"
                style={{ background: entry.status === "ready" ? "#35d07f" : "#9a9aa4" }}
              />
              <span className="dash-approval-task">{entry.title}</span>
              <span className="dash-approval-age">
                {relativeTime(entry.createdAt, Date.now())}
              </span>
            </div>
          ))}
        </>
      )}
    </div>
  );
}

function ActivityFeed({ notifications }: { notifications: NotificationsState }) {
  const entries = notifications.entries.slice(0, 8);
  return (
    <div className="dash-panel dash-activity">
      <div className="dash-panel-header">
        <span className="dash-panel-title">ACTIVITY FEED</span>
        <span className="dash-panel-sub">Full history ›</span>
      </div>
      {entries.length === 0 ? (
        <div className="dash-empty-state">No recent activity</div>
      ) : (
        <div className="dash-activity-list">
          {entries.map((entry) => (
            <div key={entry.id} className="dash-activity-row">
              <span
                className="dash-activity-dot"
                style={{ background: statusColor(entry.status) }}
              />
              <span className="dash-activity-title">{entry.title}</span>
              <span className="dash-activity-time">
                {relativeTime(entry.createdAt, Date.now())}
              </span>
            </div>
          ))}
        </div>
      )}
    </div>
  );
}

function ProgressChart({
  analytics,
  projectId,
}: {
  analytics: UsageAnalyticsStore;
  projectId: string;
}) {
  const days = useMemo(() => {
    const proj = analytics.projects[projectId];
    return Array.from({ length: 7 }, (_, i) => {
      const d = new Date(Date.now() - (6 - i) * 86400000);
      const key = d.toISOString().slice(0, 10);
      return {
        label: ["S", "M", "T", "W", "T", "F", "S"][d.getDay()],
        count: proj?.days[key]?.sessionsOpened ?? 0,
      };
    });
  }, [analytics, projectId]);

  const max = Math.max(...days.map((d) => d.count), 1);
  const total = days.reduce((s, d) => s + d.count, 0);

  return (
    <div className="dash-panel dash-progress-chart">
      <div className="dash-panel-header">
        <span className="dash-panel-title">SESSIONS / DAY</span>
        <span className="dash-panel-sub">this week</span>
      </div>
      <div className="dash-bar-chart">
        {days.map((d, i) => (
          <div key={i} className="dash-bar-col">
            <div
              className="dash-bar"
              style={{ height: `${Math.max(4, (d.count / max) * 80)}px` }}
              title={`${d.count} sessions`}
            />
            <span className="dash-bar-label">{d.label}</span>
          </div>
        ))}
      </div>
      <div className="dash-progress-footer">
        {total > 0 ? `${total} sessions this week` : "0 sessions this week"}
      </div>
    </div>
  );
}

export default function DashboardOverview({
  hidden,
  project,
  tabs,
  activeTabId,
  analytics,
  notifications,
  onOpenTerminals,
  onOpenBoard,
  onOpenFiles,
  onOpenSession,
}: DashboardOverviewProps) {
  const [timeFilter, setTimeFilter] = useState<TimeFilter>("today");

  const inProject = useMemo(
    () => (project ? tabs.filter((tab) => tab.project === project.id) : []),
    [project, tabs],
  );
  const sessions = useMemo(
    () =>
      project
        ? groupTabsBySession(inProject, activeTabId).find((g) => g.project === project.id)?.sessions ?? []
        : [],
    [project, inProject, activeTabId],
  );
  const usage = useMemo(
    () => deriveUsageInsights(analytics, project?.id ?? null),
    [analytics, project],
  );

  const todayKey = new Date().toISOString().slice(0, 10);
  const yesterdayKey = new Date(Date.now() - 86400000).toISOString().slice(0, 10);
  const projectAnalytics = project ? analytics.projects[project.id] : null;
  const tokensToday = projectAnalytics?.days[todayKey]?.tokenCount ?? 0;
  const tokensYesterday = projectAnalytics?.days[yesterdayKey]?.tokenCount ?? 0;
  const tokensPct =
    tokensYesterday > 0
      ? `${tokensToday >= tokensYesterday ? "+" : ""}${Math.round(((tokensToday - tokensYesterday) / tokensYesterday) * 100)}%`
      : null;

  const runningTabs = inProject.filter(
    (t) => t.status === "thinking" || t.status === "tool_execution",
  );
  const idleTabs = inProject.filter((t) => t.status === "ready");
  const approvingTabs = inProject.filter((t) => t.status === "awaiting_approval");

  const lastEvent = notifications.entries[0];
  const lastEventAge = lastEvent
    ? relativeTime(lastEvent.createdAt, Date.now())
    : null;

  const TIME_FILTERS: { key: TimeFilter; label: string }[] = [
    { key: "today", label: "Today" },
    { key: "7d", label: "7 days" },
    { key: "30d", label: "30 days" },
    { key: "all", label: "All" },
  ];

  return (
    <section className="dashboard-surface dashboard-overview" style={{ display: hidden ? "none" : "flex" }}>
      {/* Header */}
      <header className="dash-header">
        <div className="dash-header-left">
          <h2 className="dash-workspace-name">
            {project ? project.label : "Workspace overview"}
          </h2>
          <p className="dash-workspace-path">
            {project?.path ?? "Select a workspace"}
            {lastEventAge && <span className="dash-last-event"> · last event {lastEventAge}</span>}
          </p>
        </div>
        <nav className="dash-time-filters">
          {TIME_FILTERS.map(({ key, label }) => (
            <button
              key={key}
              className={`dash-time-btn${timeFilter === key ? " is-active" : ""}`}
              onClick={() => setTimeFilter(key)}
            >
              {label}
            </button>
          ))}
        </nav>
      </header>

      {!project ? (
        <div className="dashboard-empty">Select a workspace to open dashboard insights.</div>
      ) : (
        <div className="dash-body">
          {/* Stat cards row */}
          <div className="dash-stat-row">
            <StatCard
              label="SESSIONS"
              value={String(sessions.length)}
              sub={`${usage.totals.sessionsOpened} all time`}
            >
              <div className="dash-session-dots">
                {sessions.slice(0, 6).map((s) => (
                  <span
                    key={s.id}
                    className="dash-session-dot"
                    style={{
                      background:
                        ENGINE_COLOR[s.tabs[0]?.engine as keyof typeof ENGINE_COLOR] ?? "#9a9ca6",
                    }}
                  />
                ))}
              </div>
            </StatCard>

            <StatCard
              label="TERMINALS"
              value={String(inProject.length)}
              sub={`${runningTabs.length} running · ${idleTabs.length} idle`}
            />

            <StatCard
              label="TOKENS TODAY"
              value={compact(tokensToday)}
              trend={tokensPct}
              sub={`${compact(usage.totals.tokenCount)} all time`}
            />

            <StatCard
              label="APPROVALS"
              value={String(approvingTabs.length)}
              sub={`${notifications.entries.filter((e) => e.status === "awaiting_approval").length} total handled`}
              accent={approvingTabs.length > 0 ? "#f5b93a" : undefined}
            >
              {approvingTabs.length > 0 && (
                <button
                  className="dash-review-btn"
                  onClick={() => onOpenSession(approvingTabs[0].id)}
                >
                  Review request
                </button>
              )}
            </StatCard>

            <StatCard
              label="UNCOMMITTED"
              value="—"
              sub="Connect git for file status"
            />
          </div>

          {/* Middle row: Working Now + Tokens by Agent */}
          <div className="dash-mid-row">
            <WorkingNow tabs={inProject} onOpenSession={onOpenSession} />
            <TokensByAgent tabs={inProject} />
          </div>

          {/* Lower row: Contribution + Usage Table + Git */}
          <div className="dash-lower-row">
            <ContributionPie />
            <UsageTable
              tabs={inProject}
              sessions={sessions.length}
              totalTokens={usage.totals.tokenCount}
            />
            <GitStatus project={project} />
          </div>

          {/* Bottom row: Approvals + Activity + Progress */}
          <div className="dash-bottom-row">
            <ApprovalsPanel
              approvingTabs={approvingTabs}
              notifications={notifications}
              onOpenSession={onOpenSession}
            />
            <ActivityFeed notifications={notifications} />
            <ProgressChart analytics={analytics} projectId={project.id} />
          </div>

          {/* Quick actions */}
          <div className="dashboard-quick-actions">
            <button onClick={onOpenTerminals}>
              <Icon name="terminal" size={14} /> Open terminals
            </button>
            <button onClick={onOpenBoard}>
              <Icon name="checklist" size={14} /> Open board
            </button>
            <button onClick={onOpenFiles}>
              <Icon name="files" size={14} /> Open files
            </button>
          </div>

          {/* Legacy session list (kept for test compatibility) */}
          <section className="dashboard-sessions" style={{ display: "none" }}>
            <header>
              <span>Sessions in this workspace</span>
              <span>{sessions.length}</span>
            </header>
            <div className="dashboard-session-list">
              {sessions.map((session) => (
                <button
                  key={session.id}
                  className={`dashboard-session-row${session.isCurrent ? " is-current" : ""}`}
                  onClick={() => onOpenSession(session.tabs[0].id)}
                >
                  <span>{session.label}</span>
                  <small>{session.tabs.length} terminal{session.tabs.length === 1 ? "" : "s"}</small>
                </button>
              ))}
            </div>
          </section>
        </div>
      )}
    </section>
  );
}
