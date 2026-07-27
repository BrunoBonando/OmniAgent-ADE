import type { SessionStatus } from "./sessionStatus";

export const USAGE_ANALYTICS_SETTING_KEY = "usage_analytics_v1";
export const GLOBAL_USAGE_PROJECT = "__all__";

export interface UsageBucket {
  sessionsOpened: number;
  terminalsOpened: number;
  commandsSubmitted: number;
  inputChars: number;
  outputChars: number;
  tokenCount: number;
  activeMs: number;
  readyMs: number;
  thinkingMs: number;
  toolExecutionMs: number;
  awaitingApprovalMs: number;
  errorMs: number;
}

export interface UsageProjectAnalytics {
  totals: UsageBucket;
  days: Record<string, UsageBucket>;
  hourActivityMs: number[];
  updatedAt: number;
}

export interface UsageAnalyticsStore {
  version: 1;
  projects: Record<string, UsageProjectAnalytics>;
}

export interface DailyUsagePoint {
  day: string;
  activeHours: number;
  tokens: number;
  sessions: number;
  commands: number;
}

export interface UsageInsights {
  totals: UsageBucket;
  trackedDays: number;
  avgSessionsPerDay: number;
  avgTokensPerDay: number;
  avgActiveHoursPerDay: number;
  bestHour: number | null;
  hourlyActiveHours: number[];
  daily: DailyUsagePoint[];
}

function emptyBucket(): UsageBucket {
  return {
    sessionsOpened: 0,
    terminalsOpened: 0,
    commandsSubmitted: 0,
    inputChars: 0,
    outputChars: 0,
    tokenCount: 0,
    activeMs: 0,
    readyMs: 0,
    thinkingMs: 0,
    toolExecutionMs: 0,
    awaitingApprovalMs: 0,
    errorMs: 0,
  };
}

function emptyProjectAnalytics(now = Date.now()): UsageProjectAnalytics {
  return {
    totals: emptyBucket(),
    days: {},
    hourActivityMs: Array.from({ length: 24 }, () => 0),
    updatedAt: now,
  };
}

function toDayKey(ts: number): string {
  const d = new Date(ts);
  const y = d.getFullYear();
  const m = String(d.getMonth() + 1).padStart(2, "0");
  const day = String(d.getDate()).padStart(2, "0");
  return `${y}-${m}-${day}`;
}

function addNumber(target: UsageBucket, key: keyof UsageBucket, amount: number): void {
  if (!Number.isFinite(amount) || amount <= 0) return;
  target[key] += amount;
}

function projectBucket(store: UsageAnalyticsStore, projectId: string, ts: number): UsageProjectAnalytics {
  const existing = store.projects[projectId];
  if (existing) return existing;
  const created = emptyProjectAnalytics(ts);
  store.projects[projectId] = created;
  return created;
}

function dayBucket(project: UsageProjectAnalytics, ts: number): UsageBucket {
  const key = toDayKey(ts);
  const existing = project.days[key];
  if (existing) return existing;
  const created = emptyBucket();
  project.days[key] = created;
  return created;
}

function withGlobalProjects(projectId: string): string[] {
  return projectId === GLOBAL_USAGE_PROJECT ? [GLOBAL_USAGE_PROJECT] : [projectId, GLOBAL_USAGE_PROJECT];
}

function touch(store: UsageAnalyticsStore, projectId: string, ts: number): UsageProjectAnalytics[] {
  const keys = withGlobalProjects(projectId);
  const touched = keys.map((id) => projectBucket(store, id, ts));
  for (const project of touched) project.updatedAt = ts;
  return touched;
}

function addMetric(store: UsageAnalyticsStore, projectId: string, ts: number, key: keyof UsageBucket, amount: number): void {
  if (!Number.isFinite(amount) || amount <= 0) return;
  for (const project of touch(store, projectId, ts)) {
    addNumber(project.totals, key, amount);
    addNumber(dayBucket(project, ts), key, amount);
  }
}

function addStatusMetric(bucket: UsageBucket, status: SessionStatus, amountMs: number): void {
  if (amountMs <= 0) return;
  switch (status) {
    case "ready":
      bucket.readyMs += amountMs;
      break;
    case "thinking":
      bucket.thinkingMs += amountMs;
      bucket.activeMs += amountMs;
      break;
    case "tool_execution":
      bucket.toolExecutionMs += amountMs;
      bucket.activeMs += amountMs;
      break;
    case "awaiting_approval":
      bucket.awaitingApprovalMs += amountMs;
      bucket.activeMs += amountMs;
      break;
    case "error":
      bucket.errorMs += amountMs;
      bucket.activeMs += amountMs;
      break;
  }
}

function nextHourBoundary(ts: number): number {
  const d = new Date(ts);
  d.setMinutes(0, 0, 0);
  d.setHours(d.getHours() + 1);
  return d.getTime();
}

export function createUsageAnalyticsStore(): UsageAnalyticsStore {
  return { version: 1, projects: {} };
}

export function parseUsageAnalyticsStore(raw: string | null): UsageAnalyticsStore {
  if (!raw) return createUsageAnalyticsStore();
  try {
    const parsed = JSON.parse(raw) as Partial<UsageAnalyticsStore>;
    if (parsed.version !== 1 || !parsed.projects || typeof parsed.projects !== "object") {
      return createUsageAnalyticsStore();
    }
    const store = createUsageAnalyticsStore();
    for (const [projectId, projectRaw] of Object.entries(parsed.projects)) {
      if (!projectRaw || typeof projectRaw !== "object") continue;
      const safe = emptyProjectAnalytics(
        typeof projectRaw.updatedAt === "number" ? projectRaw.updatedAt : Date.now(),
      );
      const totals = projectRaw.totals;
      if (totals && typeof totals === "object") {
        const totalsRecord = totals as Partial<Record<keyof UsageBucket, unknown>>;
        for (const key of Object.keys(safe.totals) as Array<keyof UsageBucket>) {
          const value = totalsRecord[key];
          if (typeof value === "number" && Number.isFinite(value) && value >= 0) safe.totals[key] = value;
        }
      }
      const days = projectRaw.days;
      if (days && typeof days === "object") {
        for (const [day, bucketRaw] of Object.entries(days as Record<string, unknown>)) {
          if (!/^\d{4}-\d{2}-\d{2}$/.test(day) || !bucketRaw || typeof bucketRaw !== "object") continue;
          const bucket = emptyBucket();
          for (const key of Object.keys(bucket) as Array<keyof UsageBucket>) {
            const value = (bucketRaw as Record<string, unknown>)[key];
            if (typeof value === "number" && Number.isFinite(value) && value >= 0) bucket[key] = value;
          }
          safe.days[day] = bucket;
        }
      }
      const hours = projectRaw.hourActivityMs;
      if (Array.isArray(hours)) {
        for (let i = 0; i < 24; i++) {
          const value = hours[i];
          if (typeof value === "number" && Number.isFinite(value) && value >= 0) safe.hourActivityMs[i] = value;
        }
      }
      store.projects[projectId] = safe;
    }
    return store;
  } catch {
    return createUsageAnalyticsStore();
  }
}

export function cloneUsageAnalyticsStore(store: UsageAnalyticsStore): UsageAnalyticsStore {
  return JSON.parse(JSON.stringify(store)) as UsageAnalyticsStore;
}

export function recordSessionOpened(store: UsageAnalyticsStore, projectId: string, at = Date.now()): void {
  addMetric(store, projectId, at, "sessionsOpened", 1);
}

export function recordTerminalOpened(store: UsageAnalyticsStore, projectId: string, at = Date.now()): void {
  addMetric(store, projectId, at, "terminalsOpened", 1);
}

export function recordInput(store: UsageAnalyticsStore, projectId: string, chars: number, commands: number, at = Date.now()): void {
  addMetric(store, projectId, at, "inputChars", chars);
  addMetric(store, projectId, at, "commandsSubmitted", commands);
}

export function recordOutput(store: UsageAnalyticsStore, projectId: string, chars: number, at = Date.now()): void {
  addMetric(store, projectId, at, "outputChars", chars);
}

export function recordTokens(store: UsageAnalyticsStore, projectId: string, tokens: number, at = Date.now()): void {
  addMetric(store, projectId, at, "tokenCount", tokens);
}

export function recordStatusDuration(
  store: UsageAnalyticsStore,
  projectId: string,
  status: SessionStatus,
  fromTs: number,
  toTs: number,
): void {
  if (!Number.isFinite(fromTs) || !Number.isFinite(toTs) || toTs <= fromTs) return;

  let cursor = fromTs;
  while (cursor < toTs) {
    const chunkEnd = Math.min(toTs, nextHourBoundary(cursor));
    const chunkMs = chunkEnd - cursor;
    for (const project of touch(store, projectId, cursor)) {
      addStatusMetric(project.totals, status, chunkMs);
      addStatusMetric(dayBucket(project, cursor), status, chunkMs);
      if (status !== "ready") {
        const hour = new Date(cursor).getHours();
        project.hourActivityMs[hour] += chunkMs;
      }
    }
    cursor = chunkEnd;
  }
}

export function parseTokenEstimateMax(text: string): number | null {
  if (!text) return null;
  const regexes = [
    /(?:↓|down)\s*([0-9][0-9,]*)\s*tokens?/gi,
    /tokens?\s*[:=]\s*([0-9][0-9,]*)/gi,
    /\b([0-9][0-9,]*)\s*tokens?\b/gi,
  ];
  let max: number | null = null;
  for (const regex of regexes) {
    for (const match of text.matchAll(regex)) {
      const parsed = Number((match[1] ?? "").replace(/,/g, ""));
      if (!Number.isFinite(parsed) || parsed <= 0) continue;
      if (max === null || parsed > max) max = parsed;
    }
  }
  return max;
}

function daySequence(now: number, days: number): string[] {
  const out: string[] = [];
  const start = new Date(now);
  start.setHours(0, 0, 0, 0);
  start.setDate(start.getDate() - (days - 1));
  for (let i = 0; i < days; i++) {
    const d = new Date(start);
    d.setDate(start.getDate() + i);
    out.push(toDayKey(d.getTime()));
  }
  return out;
}

export function deriveUsageInsights(
  store: UsageAnalyticsStore,
  projectId: string | null,
  now = Date.now(),
  rangeDays = 14,
): UsageInsights {
  const project = store.projects[projectId ?? GLOBAL_USAGE_PROJECT] ?? emptyProjectAnalytics(now);
  const days = daySequence(now, Math.max(1, rangeDays));
  const daily = days.map((day) => {
    const bucket = project.days[day] ?? emptyBucket();
    return {
      day,
      activeHours: bucket.activeMs / 3_600_000,
      tokens: bucket.tokenCount,
      sessions: bucket.sessionsOpened,
      commands: bucket.commandsSubmitted,
    };
  });
  const trackedDays = Math.max(1, Object.keys(project.days).length);
  const totals = project.totals;
  const hourlyActiveHours = project.hourActivityMs.map((ms) => ms / 3_600_000);
  let bestHour: number | null = null;
  let bestHourValue = 0;
  for (let i = 0; i < hourlyActiveHours.length; i++) {
    if (hourlyActiveHours[i] > bestHourValue) {
      bestHourValue = hourlyActiveHours[i];
      bestHour = i;
    }
  }

  return {
    totals,
    trackedDays,
    avgSessionsPerDay: totals.sessionsOpened / trackedDays,
    avgTokensPerDay: totals.tokenCount / trackedDays,
    avgActiveHoursPerDay: totals.activeMs / 3_600_000 / trackedDays,
    bestHour,
    hourlyActiveHours,
    daily,
  };
}
