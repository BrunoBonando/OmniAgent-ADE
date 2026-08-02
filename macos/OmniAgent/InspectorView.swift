import AppKit
import SwiftUI

/// The inspector's data: one project's brain-context briefing
/// (`getContext`) plus `ProjectMenu`'s per-project controls — pause,
/// re-check, rename — now unblocked by Task 6a-2's roots routing.
final class InspectorViewModel: ObservableObject {
    let project: String
    @Published private(set) var projectLabel: String
    @Published private(set) var context: BrainContext?
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?
    @Published private(set) var isPaused = false
    @Published private(set) var staleness: ProjectStaleness?
    @Published private(set) var isBusy = false

    private let client: BrainAdminClient
    /// Raised after a successful rename, so whatever else shows this
    /// project's label (the session outline, the palette) can refresh
    /// without a second "get project info" path.
    var onRenamed: ((String, String) -> Void)?

    init(project: String, label: String, client: BrainAdminClient) {
        self.project = project
        projectLabel = label
        self.client = client
    }

    func load() {
        guard !project.isEmpty else { return }
        isLoading = true
        errorMessage = nil
        client.getContext(project: project) { [weak self] result in
            guard let self else { return }
            isLoading = false
            switch result {
            case let .success(context): self.context = context
            case let .failure(error): errorMessage = error.localizedDescription
            }
        }
        client.staleness { [weak self] result in
            guard let self, case let .success(all) = result else { return }
            let project = self.project
            staleness = all.first { $0.project == project }
        }
        client.pausedProjects { [weak self] result in
            guard let self, case let .success(paused) = result else { return }
            isPaused = paused.contains(project)
        }
    }

    /// Optimistic, reverted on failure — the same shape `ReviewPanel.tsx`'s
    /// `toggleReviewMode` uses.
    func togglePause() {
        let next = !isPaused
        isPaused = next
        client.setPaused(project: project, paused: next) { [weak self] result in
            if case .failure = result { self?.isPaused = !next }
        }
    }

    func reingest() {
        isBusy = true
        errorMessage = nil
        client.reingestProject(project: project) { [weak self] result in
            guard let self else { return }
            isBusy = false
            switch result {
            case .success: load()
            case let .failure(error): errorMessage = error.localizedDescription
            }
        }
    }

    /// A no-op for an empty or unchanged name — the same guard
    /// `ProjectMenu.tsx`'s `commitRename` applies before ever calling
    /// `rename_project`.
    func rename(to newLabel: String) {
        let trimmed = newLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != projectLabel else { return }
        client.renameProject(id: project, newLabel: trimmed) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                projectLabel = trimmed
                onRenamed?(project, trimmed)
            case let .failure(error):
                errorMessage = error.localizedDescription
            }
        }
    }
}

/// A per-project brain-context panel over `listProjects`/`getContext`, plus
/// `ProjectMenu`'s pause/re-check/rename controls — the SwiftUI port of
/// `ProjectMenu.tsx` and the read-only half of `AboutPanel`'s briefing idea,
/// scoped to whichever project the focused pane belongs to.
struct InspectorView: View {
    @ObservedObject var model: InspectorViewModel
    @State private var renameDraft = ""
    @State private var isRenaming = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if let staleness = model.staleness, staleness.stale {
                    Label("Stale — hasn't been re-ingested recently", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                controls
                if model.isLoading {
                    ProgressView().controlSize(.small)
                } else if let errorMessage = model.errorMessage {
                    Text(errorMessage).font(.caption).foregroundStyle(.red)
                } else if let context = model.context {
                    contextBody(context)
                }
            }
            .padding(20)
        }
        .frame(minWidth: 320, minHeight: 360)
        .background(OmniAgentPalette.background)
        .foregroundStyle(OmniAgentPalette.textPrimary)
        .onAppear { model.load() }
    }

    private var header: some View {
        Group {
            if isRenaming {
                TextField("Project name", text: $renameDraft, onCommit: commitRename)
                    .textFieldStyle(.roundedBorder)
                    .onExitCommand { isRenaming = false }
            } else {
                Text(model.projectLabel)
                    .font(.title2.bold())
                    .onTapGesture(count: 2) {
                        renameDraft = model.projectLabel
                        isRenaming = true
                    }
            }
        }
    }

    private func commitRename() {
        isRenaming = false
        model.rename(to: renameDraft)
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Toggle("Pause ingestion", isOn: Binding(get: { model.isPaused }, set: { _ in model.togglePause() }))
                .toggleStyle(.checkbox)
            Button(model.isBusy ? "Re-checking…" : "Re-check now") { model.reingest() }
                .disabled(model.isBusy)
        }
        .font(.callout)
    }

    private func contextBody(_ context: BrainContext) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if !context.summary.isEmpty {
                Text(context.summary).font(.body)
            }
            nodeSection("Recent decisions", context.recentDecisions)
            nodeSection("Memory notes", context.memoryNotes)
            projectSection("Related projects", context.relatedProjects)
        }
    }

    private func nodeSection(_ title: String, _ nodes: [BrainNodeView]) -> some View {
        Group {
            if !nodes.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title.uppercased()).font(.caption2).foregroundStyle(OmniAgentPalette.textSecondary)
                    ForEach(nodes, id: \.id) { node in
                        Text(node.label).font(.callout)
                    }
                }
            }
        }
    }

    private func projectSection(_ title: String, _ projects: [BrainProjectSummary]) -> some View {
        Group {
            if !projects.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title.uppercased()).font(.caption2).foregroundStyle(OmniAgentPalette.textSecondary)
                    ForEach(projects, id: \.id) { project in
                        Text(project.label).font(.callout)
                    }
                }
            }
        }
    }
}

/// Hosts `InspectorView` in a floating `NSPanel`, rebuilt for whichever
/// project the focused pane belongs to every time it is asked to show one —
/// the same "never stale, rebuilt from the live workspace" contract
/// `CommandPaletteController.present` already keeps.
final class InspectorWindowController: NSWindowController {
    private let client: BrainAdminClient
    private var currentProject: String?

    init(client: BrainAdminClient) {
        self.client = client
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 480),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "Inspector"
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.isReleasedWhenClosed = false
        super.init(window: panel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    /// Shows the panel scoped to `project`/`label`. `onRenamed` is
    /// re-installed on every call so it always reports through the caller's
    /// current callback.
    func show(project: String, label: String, over parent: NSWindow?, onRenamed: @escaping (String, String) -> Void) {
        currentProject = project
        let model = InspectorViewModel(project: project, label: label, client: client)
        model.onRenamed = onRenamed
        window?.contentViewController = NSHostingController(rootView: InspectorView(model: model))
        window?.title = "Inspector — \(label)"
        showWindow(nil)
        if let parent {
            window?.setFrameOrigin(NSPoint(x: parent.frame.maxX - 380, y: parent.frame.maxY - 500))
        }
        window?.makeKeyAndOrderFront(nil)
    }

    /// The project the panel is currently scoped to, if it is open —
    /// `WorkspaceWindowController` reads this to decide whether a focus
    /// change should refresh what is already on screen.
    var projectIfVisible: String? {
        window?.isVisible == true ? currentProject : nil
    }
}
