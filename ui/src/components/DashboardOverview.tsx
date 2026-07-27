import { useMemo } from "react";
import type { ProjectInfo, TabInfo } from "../state/sessions";
import { groupTabsBySession } from "../state/sessionGroups";
import { deriveUsageInsights, type UsageAnalyticsStore } from "../state/usageAnalytics";
import Icon from "./Icon";

interface DashboardOverviewProps {
  hidden: boolean;
  project: ProjectInfo | null;
  tabs: TabInfo[];
  activeTabId: string | null;
  analytics: UsageAnalyticsStore;
  onOpenTerminals: () => void;
  onOpenBoard: () => void;
  onOpenFiles: () => void;
  onOpenSession: (tabId: string) => void;
}

function compact(value: number): string {
  return new Intl.NumberFormat(undefined, { notation: "compact", maximumFractionDigits: 1 }).format(value);
}

function formatHour(hour: number): string {
  const suffix = hour < 12 ? "AM" : "PM";
  const display = hour % 12 === 0 ? 12 : hour % 12;
  return `${display}${suffix}`;
}

function linePath(values: number[], width: number, height: number): string {
  if (values.length === 0) return "";
  const max = Math.max(...values, 1);
  const xStep = values.length > 1 ? width / (values.length - 1) : width;
  return values
    .map((v, i) => {
      const x = i * xStep;
      const y = height - (v / max) * height;
      return `${i === 0 ? "M" : "L"}${x.toFixed(2)},${y.toFixed(2)}`;
    })
    .join(" ");
}

export default function DashboardOverview({
  hidden,
  project,
  tabs,
  activeTabId,
  analytics,
  onOpenTerminals,
  onOpenBoard,
  onOpenFiles,
  onOpenSession,
}: DashboardOverviewProps) {
  const inProject = useMemo(
    () => (project ? tabs.filter((tab) => tab.project === project.id) : []),
    [project, tabs],
  );
  const sessions = useMemo(
    () =>
      project
        ? groupTabsBySession(inProject, activeTabId).find((group) => group.project === project.id)?.sessions ?? []
        : [],
    [project, inProject, activeTabId],
  );
  const summary = useMemo(
    () => ({ sessions: sessions.length, terminals: inProject.length, agents: new Set(inProject.map((tab) => tab.engine)).size }),
    [sessions.length, inProject],
  );
  const usage = useMemo(
    () => deriveUsageInsights(analytics, project?.id ?? null),
    [analytics, project],
  );
  const activitySeries = useMemo(() => usage.daily.map((d) => d.activeHours), [usage.daily]);
  const activityPath = useMemo(() => linePath(activitySeries, 100, 36), [activitySeries]);
  const maxHourly = useMemo(() => Math.max(...usage.hourlyActiveHours, 0.0001), [usage.hourlyActiveHours]);

  return (
    <section className="dashboard-surface dashboard-overview" style={{ display: hidden ? "none" : "flex" }}>
      <header className="dashboard-surface-header">
        <div>
          <h2>Dashboard</h2>
          <p>{project ? `${project.label} · ${project.path ?? project.id}` : "Select a workspace to open its dashboard"}</p>
        </div>
      </header>

      {!project ? (
        <div className="dashboard-empty">Select a workspace to open dashboard insights.</div>
      ) : (
        <>
          <div className="dashboard-kpis">
            <article>
              <span>Live sessions</span>
              <strong>{summary.sessions}</strong>
            </article>
            <article>
              <span>Total tokens</span>
              <strong>{compact(usage.totals.tokenCount)}</strong>
            </article>
            <article>
              <span>Avg sessions/day</span>
              <strong>{usage.avgSessionsPerDay.toFixed(1)}</strong>
            </article>
          </div>

          <div className="dashboard-insights-grid">
            <article className="dashboard-insight-card">
              <header>
                <strong>Work rhythm</strong>
                <small>Last 14 days</small>
              </header>
              <div className="dashboard-line-chart">
                <svg viewBox="0 0 100 36" preserveAspectRatio="none">
                  <path d={activityPath} />
                </svg>
              </div>
              <div className="dashboard-insight-stats">
                <span>{usage.avgActiveHoursPerDay.toFixed(2)}h/day active</span>
                <span>{compact(usage.totals.commandsSubmitted)} prompts submitted</span>
              </div>
            </article>

            <article className="dashboard-insight-card">
              <header>
                <strong>Best focus hour</strong>
                <small>{usage.bestHour === null ? "No data yet" : `${formatHour(usage.bestHour)} peak`}</small>
              </header>
              <div className="dashboard-hour-bars">
                {usage.hourlyActiveHours.map((value, hour) => (
                  <span
                    key={hour}
                    className="dashboard-hour-bar"
                    style={{ height: `${Math.max(8, (value / maxHourly) * 100)}%` }}
                    title={`${formatHour(hour)} · ${value.toFixed(2)}h`}
                  />
                ))}
              </div>
              <div className="dashboard-hour-labels">
                <span>12A</span>
                <span>6A</span>
                <span>12P</span>
                <span>6P</span>
                <span>11P</span>
              </div>
            </article>
          </div>

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

          <section className="dashboard-sessions">
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
        </>
      )}
    </section>
  );
}
