import AppKit
import SwiftUI

/// FirstRun's stateful shell: dispatches `OnboardingAction`s against the
/// pure reducer, drives `IngestionClient`'s start/poll/biggest-project
/// calls, and republishes for SwiftUI — the same "coordinator does I/O,
/// reducer stays pure" split `AuthGateCoordinator`/`AuthGateViewModel` use.
///
/// Polling is on an injectable interval (a real `Timer` by default) so a
/// test can drive `poll()` directly instead of racing a real clock — the
/// same seam `WorkspaceWindowController.directoryChooser` gives `newSession`.
final class FirstRunViewModel: ObservableObject {
    @Published private(set) var state = OnboardingReducer.initial
    @Published var pickError: String?
    @Published var isPicking = false
    @Published private(set) var biggestProject: BrainProjectSummary?

    private let ingestion: IngestionClient
    private let pollInterval: TimeInterval
    private var pollTimer: Timer?

    /// `nil` means "ask with an `NSOpenPanel`" (set by `FirstRunWindowController`);
    /// a test substitutes an answer so `pickFolder()` runs without a modal.
    var folderChooser: ((@escaping (String?) -> Void) -> Void)?

    init(ingestion: IngestionClient, pollInterval: TimeInterval = 2) {
        self.ingestion = ingestion
        self.pollInterval = pollInterval
    }

    deinit {
        pollTimer?.invalidate()
    }

    func pickFolder() {
        folderChooser?({ [weak self] path in
            guard let self, let path, !path.isEmpty else { return }
            self.startIngesting(at: path)
        })
    }

    /// The ingest half of `pickFolder()`, without the panel — so the
    /// "pick -> ingesting -> polling" sequence is testable without a modal.
    func startIngesting(at path: String) {
        pickError = nil
        isPicking = true
        ingestion.startIngest(path: path) { [weak self] result in
            guard let self else { return }
            isPicking = false
            switch result {
            case .success:
                state = OnboardingReducer.reduce(state, .rootPicked)
                startPolling()
            case let .failure(error):
                pickError = error.localizedDescription
            }
        }
    }

    func startPolling() {
        pollTimer?.invalidate()
        poll()
        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    /// One `ingestionStatus` round-trip, folded through the reducer. Public
    /// so a test can call it directly instead of waiting on the timer.
    func poll() {
        ingestion.ingestionStatus { [weak self] result in
            guard let self, case let .success(status) = result else { return }
            state = OnboardingReducer.reduce(state, .statusPolled(status: status))
            if state.phase == .done {
                pollTimer?.invalidate()
                pollTimer = nil
                fetchBiggestProjectIfNeeded()
            }
        }
    }

    private func fetchBiggestProjectIfNeeded() {
        guard let status = state.status, status.projectsTotal > 0 else { return }
        ingestion.biggestProject { [weak self] result in
            guard let self, case let .success(project) = result else { return }
            biggestProject = project
        }
    }

    func retry() {
        pollTimer?.invalidate()
        pollTimer = nil
        biggestProject = nil
        pickError = nil
        state = OnboardingReducer.reduce(state, .retry)
    }
}

/// A SwiftUI port of `FirstRun.tsx`'s three phases: a folder-picker modal, a
/// small progress HUD while ingesting, and a completion readout offering the
/// biggest project's first terminal.
struct FirstRunContentView: View {
    @ObservedObject var model: FirstRunViewModel
    let onOpenTerminal: (BrainProjectSummary) -> Void
    let onDismiss: () -> Void

    var body: some View {
        Group {
            switch model.state.phase {
            case .pick: pickScreen
            case .ingesting: ingestingScreen
            case .done: doneScreen
            }
        }
        .frame(width: 420)
        .padding(28)
        .background(OmniAgentPalette.background)
        .foregroundStyle(OmniAgentPalette.textPrimary)
    }

    private var pickScreen: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("> initialize brain_")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(OmniAgentPalette.accent)
            Text("Where do your projects live?")
                .font(.title2.bold())
            Text(
                "Point OmniAgent at a folder. Everything inside it gets walked, parsed, and linked "
                    + "into your local knowledge graph, automatically — nothing leaves this machine."
            )
            .font(.subheadline)
            .foregroundStyle(OmniAgentPalette.textSecondary)

            if let pickError = model.pickError {
                Text("Couldn't start ingestion: \(pickError)")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Button(model.isPicking ? "Choosing…" : "Browse for a folder…") { model.pickFolder() }
                .keyboardShortcut(.defaultAction)
                .disabled(model.isPicking)
            Button("Skip for now") { onDismiss() }
        }
    }

    private var ingestingScreen: some View {
        let status = model.state.status
        let projectsPct: Double = {
            guard let status, status.projectsTotal > 0 else { return 0 }
            return min(1.0, Double(status.projectsDone) / Double(status.projectsTotal))
        }()
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Ingesting").font(.headline)
                if let current = status?.currentProject, !current.isEmpty {
                    Text(current).font(.caption).foregroundStyle(OmniAgentPalette.textSecondary)
                }
            }
            ProgressView(value: projectsPct).tint(OmniAgentPalette.accent)
            Text("\(status?.projectsDone ?? 0)/\(status.map { String($0.projectsTotal) } ?? "…") projects")
                .font(.caption)
            Text("\((status?.totalNodes ?? 0).formatted()) nodes")
                .font(.caption)
                .foregroundStyle(OmniAgentPalette.textSecondary)
        }
    }

    private var doneScreen: some View {
        let status = model.state.status
        let foundNothing = (status?.projectsTotal ?? 0) == 0
        return VStack(alignment: .leading, spacing: 12) {
            if foundNothing {
                Text("No projects found in that folder.")
                Button("Try a different folder") { model.retry() }
            } else {
                Text(
                    "Brain online — \(status?.projectsDone ?? 0) project\((status?.projectsDone ?? 0) == 1 ? "" : "s"), "
                        + "\((status?.totalNodes ?? 0).formatted()) nodes"
                )
                .font(.headline)
                if let biggest = model.biggestProject {
                    Button("Open terminal in \(biggest.label)") { onOpenTerminal(biggest) }
                        .keyboardShortcut(.defaultAction)
                }
            }
            Button("Dismiss") { onDismiss() }
        }
    }
}

/// Hosts `FirstRunContentView` in a sheet on the workspace window, and turns
/// its two AppKit-only needs (the `NSOpenPanel`, dismissal) into plain
/// callbacks the SwiftUI content never has to know about.
final class FirstRunWindowController {
    let model: FirstRunViewModel
    private var sheetWindow: NSWindow?

    init(ingestion: IngestionClient) {
        model = FirstRunViewModel(ingestion: ingestion)
    }

    /// `SessionConnection.rootsList` empty = true first run, mirroring
    /// `App.tsx`'s `needsOnboarding`. Fails open on a read error, same
    /// posture as the auth gate's own boot check.
    static func needsPresenting(ingestion: IngestionClient, completion: @escaping (Bool) -> Void) {
        ingestion.rootsList { result in
            switch result {
            case let .success(roots): completion(roots.isEmpty)
            case .failure: completion(false)
            }
        }
    }

    func present(over window: NSWindow?, onOpenTerminal: @escaping (BrainProjectSummary) -> Void) {
        model.folderChooser = { [weak self] completion in
            self?.chooseFolder(over: window, completion: completion)
        }
        let content = FirstRunContentView(
            model: model,
            onOpenTerminal: { [weak self] project in
                self?.dismiss()
                onOpenTerminal(project)
            },
            onDismiss: { [weak self] in self?.dismiss() }
        )
        let hosting = NSHostingController(rootView: content)
        let sheet = NSWindow(contentViewController: hosting)
        sheet.styleMask = [.titled, .fullSizeContentView]
        sheet.titlebarAppearsTransparent = true
        sheet.titleVisibility = .hidden
        sheet.isReleasedWhenClosed = false
        sheetWindow = sheet
        if let window {
            window.beginSheet(sheet)
        } else {
            sheet.center()
            sheet.makeKeyAndOrderFront(nil)
        }
    }

    private func chooseFolder(over window: NSWindow?, completion: @escaping (String?) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Where do your projects live?"
        panel.prompt = "Choose"
        guard let window else {
            completion(panel.runModal() == .OK ? panel.url?.path : nil)
            return
        }
        panel.beginSheetModal(for: window) { response in
            completion(response == .OK ? panel.url?.path : nil)
        }
    }

    private func dismiss() {
        guard let sheet = sheetWindow else { return }
        if let parent = sheet.sheetParent {
            parent.endSheet(sheet)
        } else {
            sheet.orderOut(nil)
        }
        sheetWindow = nil
    }
}
