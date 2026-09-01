import SwiftUI

/// Feeds `UsageView` from a point-in-time snapshot of the recorder's store
/// (the Settings window is rebuilt fresh every time it opens — see
/// `SettingsWindowController` — so "point in time" is "as of opening the
/// window", the same freshness contract `CommandPaletteController.present`
/// already uses for its own list) plus the project picker's options.
final class UsageViewModel: ObservableObject {
    @Published var selectedProject: String?
    @Published private(set) var projects: [BrainProjectSummary] = []

    private let store: UsageAnalyticsStore
    private let clock: () -> Double

    init(
        store: UsageAnalyticsStore,
        projectDirectory: BrainAdminClient,
        clock: @escaping () -> Double = { Date().timeIntervalSince1970 * 1000 }
    ) {
        self.store = store
        self.clock = clock
        projectDirectory.listProjects { [weak self] result in
            guard let self, case let .success(list) = result else { return }
            projects = list
        }
    }

    var insights: UsageInsights {
        UsageAnalytics.deriveUsageInsights(store, projectId: selectedProject, now: clock())
    }
}

/// `DashboardOverview.tsx`'s numbers — daily/hourly activity and totals —
/// as a plain SwiftUI readout rather than that component's full dashboard
/// (working-now list, tokens-by-agent, git status, …): this is
/// client-computed analytics, not the workspace's primary view, so it stays
/// a compact summary a settings-adjacent window can host.
struct UsageView: View {
    @ObservedObject var model: UsageViewModel
    /// Hosted inside another surface rather than owning a window — the
    /// Insights page's charts card (spec §6). It drops two things the page
    /// already provides: the totals grid, whose numbers are the page's KPI
    /// cards right above this view, and the opaque ground, which inside a
    /// card reads as a slab sitting on it. The text colour stays: it is the
    /// same dark language either way.
    var embedded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                projectPicker
                if !embedded { totalsRow }
                dailyChart
                hourlyChart
            }
            .padding(20)
        }
        .background { if !embedded { OmniAgentPalette.background } }
        .foregroundStyle(OmniAgentPalette.textPrimary)
    }

    private var projectPicker: some View {
        Picker("Project", selection: $model.selectedProject) {
            Text("All projects").tag(String?.none)
            ForEach(model.projects, id: \.id) { project in
                Text(project.label).tag(String?.some(project.id))
            }
        }
        .pickerStyle(.menu)
        .frame(maxWidth: 260)
    }

    private var totalsRow: some View {
        let insights = model.insights
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 12)], spacing: 12) {
            statTile("Sessions", value: formatted(insights.totals.sessionsOpened))
            statTile("Terminals", value: formatted(insights.totals.terminalsOpened))
            statTile("Commands", value: formatted(insights.totals.commandsSubmitted))
            statTile("Tokens", value: formatted(insights.totals.tokenCount))
            statTile("Active hours", value: String(format: "%.1f", insights.avgActiveHoursPerDay * Double(insights.trackedDays)))
            statTile("Avg sessions/day", value: String(format: "%.1f", insights.avgSessionsPerDay))
        }
    }

    private func statTile(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(.caption2)
                .foregroundStyle(OmniAgentPalette.textSecondary)
            Text(value)
                .font(.title3.monospacedDigit())
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(OmniAgentPalette.panel)
        .cornerRadius(8)
    }

    private var dailyChart: some View {
        let daily = model.insights.daily
        let maxHours = max(daily.map(\.activeHours).max() ?? 0, 0.01)
        return VStack(alignment: .leading, spacing: 6) {
            Text("ACTIVE HOURS — LAST \(daily.count) DAYS")
                .font(.caption2)
                .foregroundStyle(OmniAgentPalette.textSecondary)
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(daily, id: \.day) { point in
                    VStack(spacing: 2) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(OmniAgentPalette.accent)
                            .frame(height: max(2, CGFloat(point.activeHours / maxHours) * 60))
                        Text(String(point.day.suffix(2)))
                            .font(.system(size: 8))
                            .foregroundStyle(OmniAgentPalette.textSecondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 76)
        }
    }

    private var hourlyChart: some View {
        let hours = model.insights.hourlyActiveHours
        let maxHours = max(hours.max() ?? 0, 0.01)
        let bestHour = model.insights.bestHour
        return VStack(alignment: .leading, spacing: 6) {
            Text("ACTIVITY BY HOUR OF DAY")
                .font(.caption2)
                .foregroundStyle(OmniAgentPalette.textSecondary)
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(Array(hours.enumerated()), id: \.offset) { hour, value in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(hour == bestHour ? OmniAgentPalette.accent : OmniAgentPalette.accent.opacity(0.45))
                        .frame(height: max(2, CGFloat(value / maxHours) * 44))
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 48)
            if let bestHour {
                Text("Busiest around \(bestHour):00")
                    .font(.caption2)
                    .foregroundStyle(OmniAgentPalette.textSecondary)
            }
        }
    }

    private func formatted(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0)))
    }
}
