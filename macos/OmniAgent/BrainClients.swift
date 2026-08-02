import Foundation

/// The project-directory + per-project brain administration surface — what
/// the inspector, the session outline's project-label fix, and the settings
/// screen's "Rebuild brain" all need. `SessionConnection` already has every
/// one of these methods (Task 6a/6a-2); this protocol only narrows them into
/// one injectable seam so those three screens are testable without a socket,
/// the same seam shape `SettingsClient` gives `SettingsStore`.
protocol BrainAdminClient: AnyObject {
    func listProjects(completion: @escaping (Result<[BrainProjectSummary], Error>) -> Void)
    func getContext(project: String, completion: @escaping (Result<BrainContext, Error>) -> Void)
    func staleness(completion: @escaping (Result<[ProjectStaleness], Error>) -> Void)
    func pausedProjects(completion: @escaping (Result<[String], Error>) -> Void)
    func setPaused(project: String, paused: Bool, completion: ((Result<Void, Error>) -> Void)?)
    func reingestProject(project: String, completion: ((Result<Void, Error>) -> Void)?)
    func renameProject(id: String, newLabel: String, completion: ((Result<Void, Error>) -> Void)?)
    func rebuildBrain(completion: ((Result<Void, Error>) -> Void)?)
}

extension SessionConnection: BrainAdminClient {}

/// FirstRun's project-root picker -> ingest -> poll -> biggest-project
/// surface, narrowed the same way.
protocol IngestionClient: AnyObject {
    func startIngest(path: String, completion: ((Result<Void, Error>) -> Void)?)
    func ingestionStatus(completion: @escaping (Result<IngestionStatus, Error>) -> Void)
    func biggestProject(completion: @escaping (Result<BrainProjectSummary?, Error>) -> Void)
    /// Every project root ever picked — empty means true first run, the
    /// native mirror of `App.tsx`'s `needsOnboarding` check.
    func rootsList(completion: @escaping (Result<[String], Error>) -> Void)
}

extension SessionConnection: IngestionClient {}

/// The command palette's brain-search row.
protocol BrainSearchClient: AnyObject {
    func search(query: String, scope: String?, completion: @escaping (Result<[BrainNodeView], Error>) -> Void)
}

extension SessionConnection: BrainSearchClient {}
