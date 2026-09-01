import AppKit
import SwiftUI

// The Insights page — the 2026-09-01 flow-layout design's §6
// (`docs/superpowers/specs/2026-09-01-flow-layout-design.md`): the app's own
// numbers, wearing the page frame every destination wears (`PageShellView`).
//
// Neither tab invents data. **Usage** is three KPI cards over the SwiftUI
// `UsageView` the Settings window already shows — the same
// `UsageAnalytics.deriveUsageInsights` numbers, hosted `embedded` so it
// drops its own totals grid (the cards say those) and its own ground (the
// card behind it is the ground). **Activity** is the review panel's
// `ReviewPanelInsightsView`, unchanged, widened from the one session the
// panel reviews to every session in the window
// (`WorkspaceWindowController.syncPageInsights`).

/// The page's two faces. `Int`-raw so `PageShellView`'s index-based tab strip
/// and the spotlight's rows can both name one without a mapping table of
/// their own.
enum InsightsTab: Int, CaseIterable {
    case usage
    case activity

    var title: String {
        switch self {
        case .usage: return "Usage"
        case .activity: return "Activity"
        }
    }
}

// MARK: - KPI card

/// One headline number: a display numeral over an all-caps caption, in the
/// Home screen's card language.
///
/// The tile *holds* a `HomeCardView` rather than being one because that class
/// is `final`. The card fills the tile exactly, so the row's `fillEqually`
/// still measures real cards and nothing about the drawn result differs.
final class InsightsKPICardView: NSView {
    /// The drawn card — `ShellPalette.cardFill` on `cardStroke`, radius 12.
    /// No `onPress`: a number is scenery, so it never wears the hover pair.
    let card = HomeCardView()
    let valueField: NSTextField
    let labelField: NSTextField

    init(label: String) {
        valueField = ShellFont.label(
            InsightsSurfaceView.placeholderValue,
            font: ShellFont.ui(34, .semibold),
            color: ShellPalette.ink
        )
        labelField = ShellFont.label(
            label,
            font: ShellFont.ui(11, .medium),
            color: ShellPalette.inkTertiary,
            tracking: 0.8
        )
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)
        card.addSubview(valueField)
        card.addSubview(labelField)
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: leadingAnchor),
            card.trailingAnchor.constraint(equalTo: trailingAnchor),
            card.topAnchor.constraint(equalTo: topAnchor),
            card.bottomAnchor.constraint(equalTo: bottomAnchor),

            valueField.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
            valueField.trailingAnchor.constraint(lessThanOrEqualTo: card.trailingAnchor, constant: -18),
            valueField.topAnchor.constraint(equalTo: card.topAnchor, constant: 18),

            labelField.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
            labelField.trailingAnchor.constraint(lessThanOrEqualTo: card.trailingAnchor, constant: -18),
            labelField.topAnchor.constraint(equalTo: valueField.bottomAnchor, constant: 6),
            labelField.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -18),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    /// The numeral, already formatted. The caption goes with it into the
    /// accessibility label — a bare number read aloud says nothing.
    func setValue(_ text: String) {
        valueField.stringValue = text
        setAccessibilityLabel("\(labelField.stringValue): \(text)")
    }
}

// MARK: - The page

/// `PageShellView(title: "Insights", tabs: ["Usage", "Activity"])` over two
/// bodies, of which exactly one is on screen. The view holds no clock, reads
/// no store and asks the daemon nothing: everything it draws arrives through
/// `applyInsights`, `applyUsage` and `activity.apply` from the controller.
final class InsightsSurfaceView: NSView {
    /// What a card shows before any data has been applied — an em dash, not
    /// a zero: "no numbers yet" and "zero sessions" are different facts.
    static let placeholderValue = "—"
    /// The charts card's height. The hosted `UsageView` scrolls inside it,
    /// so this is how much of the page the charts are given, not how tall
    /// they are.
    static let usageCardHeight: CGFloat = 360
    /// The Activity tape's height. `ReviewPanelInsightsView` lays itself out
    /// top-down in manual frames and has no intrinsic size, so the page has
    /// to state one: room for the header, ~15 lanes, the axis and the
    /// time-by-status bars. Past that it clips, exactly as the review panel's
    /// own copy does when a session has more panes than the panel is tall.
    static let activityHeight: CGFloat = 520

    /// The page frame — title, tab strip, hairline, scrolling body.
    let shell: PageShellView
    private(set) var selectedTab: InsightsTab = .usage
    /// Fires for a *programmatic* pick as well as a press — unlike
    /// `PageShellView.select(tab:)`, deliberately: every route to Activity
    /// (the strip, a spotlight row, the page being shown) has to be able to
    /// feed the timeline, and the controller has one hook for all of them.
    var onSelectTab: ((InsightsTab) -> Void)?

    /// Sessions, tokens, active hours — in that order, which is the order
    /// `applyInsights` fills them in.
    let kpiCards: [InsightsKPICardView]
    /// The Usage tab's body: the KPI row and the charts card under it.
    let usageBody = NSView()
    /// The full-width card hosting the SwiftUI `UsageView`.
    let usageCard = HomeCardView()
    /// The Activity tab's body — the review panel's own timeline view, fed
    /// across every session by `WorkspaceWindowController.syncPageInsights`.
    let activity = ReviewPanelInsightsView()

    private var usageHost: NSView?
    private var usageBodyBottom: NSLayoutConstraint?
    private var activityBottom: NSLayoutConstraint?
    /// Grouped thousands, no fraction: the counts are `Double` only because
    /// the store's JSON oracle has no integers. Grouped in the *viewer's*
    /// locale — a Mac set to German reads "8.783" here the way its other
    /// apps write it — which is why the locale is an argument: a test has to
    /// be able to assert one exact grouping.
    private let countFormatter: NumberFormatter

    init(locale: Locale = .current) {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        countFormatter = formatter
        let cards = [
            InsightsKPICardView(label: "SESSIONS"),
            InsightsKPICardView(label: "TOKENS"),
            InsightsKPICardView(label: "ACTIVE HOURS"),
        ]
        kpiCards = cards
        // The scrolling document, holding both bodies — owned by the shell's
        // scroll view from here on, so it is a local rather than a property.
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        shell = PageShellView(
            title: "Insights",
            tabs: InsightsTab.allCases.map(\.title),
            body: container
        )
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        addSubview(shell)
        NSLayoutConstraint.activate([
            shell.leadingAnchor.constraint(equalTo: leadingAnchor),
            shell.trailingAnchor.constraint(equalTo: trailingAnchor),
            shell.topAnchor.constraint(equalTo: topAnchor),
            shell.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        let row = NSStackView(views: cards)
        row.orientation = .horizontal
        row.distribution = .fillEqually
        row.spacing = 16
        row.translatesAutoresizingMaskIntoConstraints = false
        usageBody.translatesAutoresizingMaskIntoConstraints = false
        // The hosted charts run the card's full width; clipping is what
        // keeps them inside its rounded corners.
        usageCard.layer?.masksToBounds = true
        usageBody.addSubview(row)
        usageBody.addSubview(usageCard)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: usageBody.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: usageBody.trailingAnchor),
            row.topAnchor.constraint(equalTo: usageBody.topAnchor),

            usageCard.leadingAnchor.constraint(equalTo: usageBody.leadingAnchor),
            usageCard.trailingAnchor.constraint(equalTo: usageBody.trailingAnchor),
            usageCard.topAnchor.constraint(equalTo: row.bottomAnchor, constant: 24),
            usageCard.heightAnchor.constraint(equalToConstant: Self.usageCardHeight),
            usageCard.bottomAnchor.constraint(equalTo: usageBody.bottomAnchor),
        ])

        activity.translatesAutoresizingMaskIntoConstraints = false
        for view in [usageBody, activity] as [NSView] {
            container.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                view.topAnchor.constraint(equalTo: container.topAnchor),
            ])
        }
        activity.heightAnchor.constraint(equalToConstant: Self.activityHeight).isActive = true
        usageBodyBottom = usageBody.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        activityBottom = activity.bottomAnchor.constraint(equalTo: container.bottomAnchor)

        shell.onSelectTab = { [weak self] index in
            guard let tab = InsightsTab(rawValue: index) else { return }
            self?.select(tab)
        }
        select(.usage)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    // MARK: - Tabs

    /// Puts one tab on screen: the strip's underline, the two bodies'
    /// visibility, and which of them sizes the scrolling document.
    func select(_ tab: InsightsTab) {
        selectedTab = tab
        shell.select(tab: tab.rawValue)
        usageBody.isHidden = tab != .usage
        activity.isHidden = tab != .activity
        // Only the body on screen may size the document: two live bottom
        // constraints would ask the container to be two heights at once.
        usageBodyBottom?.isActive = tab == .usage
        activityBottom?.isActive = tab == .activity
        onSelectTab?(tab)
    }

    // MARK: - Applying data

    /// The KPI row, from the same insights the charts below it are derived
    /// from. Active hours is the run's total — the daily average times the
    /// days it was averaged over — which is what "active hours" means on a
    /// page with no date range picker.
    func applyInsights(_ insights: UsageInsights) {
        kpiCards[0].setValue(count(insights.totals.sessionsOpened))
        kpiCards[1].setValue(count(insights.totals.tokenCount))
        kpiCards[2].setValue(
            String(format: "%.1f", insights.avgActiveHoursPerDay * Double(insights.trackedDays))
        )
    }

    /// The charts card's content, from a `UsageViewModel` rebuilt every time
    /// the page is shown — `SettingsWindowController.present`'s own contract:
    /// a snapshot as of opening, never a live feed. The previous host goes
    /// with it, since an `NSHostingView` retains its model.
    func applyUsage(model: UsageViewModel) {
        usageHost?.removeFromSuperview()
        let host = NSHostingView(rootView: UsageView(model: model, embedded: true))
        host.translatesAutoresizingMaskIntoConstraints = false
        usageCard.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: usageCard.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: usageCard.trailingAnchor),
            host.topAnchor.constraint(equalTo: usageCard.topAnchor),
            host.bottomAnchor.constraint(equalTo: usageCard.bottomAnchor),
        ])
        usageHost = host
    }

    private func count(_ value: Double) -> String {
        countFormatter.string(from: NSNumber(value: value)) ?? Self.placeholderValue
    }
}
