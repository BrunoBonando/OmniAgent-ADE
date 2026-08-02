import AppKit
import SwiftUI

/// The Settings screen's I/O and derived state — one view model behind the
/// five sections `SettingsView` renders (Account/Notifications/Review/
/// Panels/About), each reading/writing through `SettingsStore` so every
/// control uses the exact key strings the web app shares the same
/// `brain.db` row with.
final class SettingsViewModel: ObservableObject {
    @Published private(set) var authSummary = "Loading…"
    @Published private(set) var authSignedIn = false
    @Published private(set) var notificationEntries: [NotificationEntry] = []
    @Published private(set) var reviewMemoryEnabled = false
    @Published var fileTreeWidthText = ""
    @Published var codeReviewWidthText = ""
    @Published private(set) var rebuildInProgress = false
    @Published var rebuildError: String?
    @Published var rebuildConfirming = false

    let versionLine: String?
    let notifier: SessionNotifier

    private let settings: SettingsStore
    private let authGate: AuthGateCoordinator
    private let brainAdmin: BrainAdminClient
    /// Installed by `SettingsWindowController` — "Sign in" re-runs the same
    /// gate flow `AuthGateWindowController` shows at launch, rather than a
    /// second sign-in implementation living in this screen.
    var presentAuthGate: (() -> Void)?

    init(
        settings: SettingsStore,
        authGate: AuthGateCoordinator,
        brainAdmin: BrainAdminClient,
        notifier: SessionNotifier,
        version: String?
    ) {
        self.settings = settings
        self.authGate = authGate
        self.brainAdmin = brainAdmin
        self.notifier = notifier
        versionLine = version.map { "v\($0) — dogfood build" }
        refreshAccount()
        refreshReview()
        refreshPanels()
        refreshNotifications()
    }

    // MARK: - Account

    func refreshAccount() {
        settings.get(SettingsKey.authSignedIn) { [weak self] result in
            self?.authSignedIn = AuthGate.resolveSignedIn(try? result.get())
        }
        authGate.summary { [weak self] summary in self?.authSummary = summary }
    }

    func signOut() {
        authGate.reset { [weak self] in self?.refreshAccount() }
    }

    func signIn() {
        presentAuthGate?()
    }

    // MARK: - Notifications

    func refreshNotifications() {
        notificationEntries = notifier.entries
    }

    func markAllNotificationsRead() {
        notifier.markAllRead()
        refreshNotifications()
    }

    func clearAllNotifications() {
        notifier.clear()
        refreshNotifications()
    }

    // MARK: - Review

    func refreshReview() {
        settings.getBool(SettingsKey.reviewMemory, default: false) { [weak self] value in
            self?.reviewMemoryEnabled = value
        }
    }

    func setReviewMemory(_ enabled: Bool) {
        reviewMemoryEnabled = enabled
        settings.setBool(SettingsKey.reviewMemory, enabled)
    }

    // MARK: - Panels

    func refreshPanels() {
        settings.get(SettingsKey.fileTreeWidth) { [weak self] result in
            self?.fileTreeWidthText = (try? result.get()) ?? ""
        }
        settings.get(SettingsKey.codeReviewWidth) { [weak self] result in
            self?.codeReviewWidthText = (try? result.get()) ?? ""
        }
    }

    func commitFileTreeWidth() {
        settings.set(SettingsKey.fileTreeWidth, fileTreeWidthText)
    }

    func commitCodeReviewWidth() {
        settings.set(SettingsKey.codeReviewWidth, codeReviewWidthText)
    }

    // MARK: - About

    func rebuildBrain() {
        rebuildInProgress = true
        rebuildError = nil
        brainAdmin.rebuildBrain { [weak self] result in
            guard let self else { return }
            rebuildInProgress = false
            switch result {
            case .success: rebuildConfirming = false
            case let .failure(error): rebuildError = error.localizedDescription
            }
        }
    }
}

/// The Settings screen: `NSHostingController`-hosted, reachable from the
/// OmniAgent application menu's "Settings…" (⌘,) — see
/// `AppDelegate.ApplicationMenus`. Five sections plus the Usage readout,
/// each a thin tab over `SettingsViewModel`.
struct SettingsView: View {
    @ObservedObject var model: SettingsViewModel
    @ObservedObject var usage: UsageViewModel

    var body: some View {
        TabView {
            AccountSettingsTab(model: model)
                .tabItem { Label("Account", systemImage: "person.crop.circle") }
            NotificationsSettingsTab(model: model)
                .tabItem { Label("Notifications", systemImage: "bell") }
            ReviewSettingsTab(model: model)
                .tabItem { Label("Review", systemImage: "checkmark.seal") }
            PanelsSettingsTab(model: model)
                .tabItem { Label("Panels", systemImage: "sidebar.right") }
            UsageView(model: usage)
                .tabItem { Label("Usage", systemImage: "chart.bar") }
            AboutSettingsTab(model: model)
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 520, height: 440)
    }
}

private struct SettingsTabBackground<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 16, content: { content })
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .foregroundStyle(OmniAgentPalette.textPrimary)
            .background(OmniAgentPalette.background)
    }
}

/// Account — sign in/out and the captured persona, mirroring
/// `accountBadgeState.ts`'s honest-placeholder convention: this is a dev-mode
/// fake identity, and the copy says so.
private struct AccountSettingsTab: View {
    @ObservedObject var model: SettingsViewModel

    var body: some View {
        SettingsTabBackground {
            Text("Account").font(.title3.bold())
            Text(model.authSummary).foregroundStyle(OmniAgentPalette.textSecondary)
            Button(model.authSignedIn ? "Log out" : "Sign in") {
                model.authSignedIn ? model.signOut() : model.signIn()
            }
        }
    }
}

/// Notifications — the feed Task 6b-1 built, plus clear/mark-read.
private struct NotificationsSettingsTab: View {
    @ObservedObject var model: SettingsViewModel

    var body: some View {
        SettingsTabBackground {
            HStack {
                Text("Notifications").font(.title3.bold())
                Spacer()
                Button("Mark all read") { model.markAllNotificationsRead() }
                    .disabled(model.notificationEntries.allSatisfy(\.read))
                Button("Clear all") { model.clearAllNotifications() }
                    .disabled(model.notificationEntries.isEmpty)
            }
            if model.notificationEntries.isEmpty {
                Text("Nothing yet. Sessions notify here when they finish, need approval, or fail.")
                    .foregroundStyle(OmniAgentPalette.textSecondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(model.notificationEntries, id: \.id) { entry in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.title).font(.callout).fontWeight(entry.read ? .regular : .semibold)
                                Text("\(entry.projectLabel) — \(NotificationFeed.subtitle(for: entry.status))")
                                    .font(.caption)
                                    .foregroundStyle(OmniAgentPalette.textSecondary)
                            }
                        }
                    }
                }
            }
        }
    }
}

/// Review — the `review_memory` toggle.
private struct ReviewSettingsTab: View {
    @ObservedObject var model: SettingsViewModel

    var body: some View {
        SettingsTabBackground {
            Text("Review").font(.title3.bold())
            Toggle(
                "Review before committing new session summaries",
                isOn: Binding(get: { model.reviewMemoryEnabled }, set: { model.setReviewMemory($0) })
            )
            .toggleStyle(.checkbox)
            Text(
                model.reviewMemoryEnabled
                    ? "New session summaries wait for approval before they show up in search or briefings."
                    : "Auto-commit is on (default) — new session summaries land immediately."
            )
            .font(.caption)
            .foregroundStyle(OmniAgentPalette.textSecondary)
        }
    }
}

/// Panels — the file tree and code review panel widths, shared with the web
/// build's own resizable panels.
private struct PanelsSettingsTab: View {
    @ObservedObject var model: SettingsViewModel

    var body: some View {
        SettingsTabBackground {
            Text("Panels").font(.title3.bold())
            LabeledContent("File tree width") {
                TextField("px", text: $model.fileTreeWidthText)
                    .frame(width: 80)
                    .onSubmit { model.commitFileTreeWidth() }
            }
            LabeledContent("Code review panel width") {
                TextField("px", text: $model.codeReviewWidthText)
                    .frame(width: 80)
                    .onSubmit { model.commitCodeReviewWidth() }
            }
        }
    }
}

/// About — bundle version, tagline, and the now-unblocked "Rebuild brain".
private struct AboutSettingsTab: View {
    @ObservedObject var model: SettingsViewModel

    var body: some View {
        SettingsTabBackground {
            Text("OmniAgent ADE").font(.title3.bold())
            Text("The knowledge graph is the operating system.")
                .font(.subheadline)
                .foregroundStyle(OmniAgentPalette.textSecondary)
            if let versionLine = model.versionLine {
                Text(versionLine).font(.caption)
            }
            Divider()
            Text(
                "Something look wrong with the graph? Rebuilding deletes the derived database and "
                    + "re-ingests every known project root from scratch. Markdown memory notes are never touched."
            )
            .font(.caption)
            .foregroundStyle(OmniAgentPalette.textSecondary)
            if let rebuildError = model.rebuildError {
                Text("Rebuild failed: \(rebuildError)").font(.caption).foregroundStyle(.red)
            }
            if model.rebuildConfirming {
                HStack {
                    Text("Delete the graph and re-ingest everything?")
                    Button(model.rebuildInProgress ? "Rebuilding…" : "Yes, rebuild") { model.rebuildBrain() }
                        .disabled(model.rebuildInProgress)
                    Button("Cancel") { model.rebuildConfirming = false }
                        .disabled(model.rebuildInProgress)
                }
            } else {
                Button("Rebuild brain…") { model.rebuildConfirming = true }
            }
        }
    }
}

/// Hosts `SettingsView` in a standalone window (not a sheet — Settings is a
/// destination you visit, not a gate blocking the workspace).
final class SettingsWindowController: NSWindowController {
    private let settings: SettingsStore
    private let authGate: AuthGateCoordinator
    private let authGateWindow: AuthGateWindowController
    private let brainAdmin: BrainAdminClient & BrainSearchClient
    private let notifier: SessionNotifier

    init(
        settings: SettingsStore,
        authGate: AuthGateCoordinator,
        authGateWindow: AuthGateWindowController,
        brainAdmin: BrainAdminClient & BrainSearchClient,
        notifier: SessionNotifier
    ) {
        self.settings = settings
        self.authGate = authGate
        self.authGateWindow = authGateWindow
        self.brainAdmin = brainAdmin
        self.notifier = notifier
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 440),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    /// Rebuilt from scratch on every open, same reasoning as
    /// `CommandPaletteController.present`: a stale settings screen showing
    /// last-launch's auth/notification state would be a lie. `usageRecorder`
    /// is read at call time rather than stored, so the Usage tab always
    /// shows whatever has been recorded up to the moment Settings opens.
    func present(over parentWindow: NSWindow?, usageRecorder: UsageAnalyticsRecorder) {
        let model = SettingsViewModel(
            settings: settings,
            authGate: authGate,
            brainAdmin: brainAdmin,
            notifier: notifier,
            version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        )
        model.presentAuthGate = { [weak self] in
            self?.authGateWindow.present(over: self?.window)
        }
        let usage = UsageViewModel(store: usageRecorder.store, projectDirectory: brainAdmin)
        window?.contentViewController = NSHostingController(rootView: SettingsView(model: model, usage: usage))
        showWindow(nil)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }
}
