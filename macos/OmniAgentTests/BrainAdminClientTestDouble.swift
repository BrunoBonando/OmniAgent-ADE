import Foundation
@testable import OmniAgent

/// An in-memory `BrainAdminClient` + `BrainSearchClient` — no daemon, shared
/// by every test (Usage, Inspector, palette search, the outline's project-
/// label fix) that needs a fake project directory/brain-admin surface,
/// mirroring `FakeSettingsClient`'s role for `SettingsClient`.
final class FakeBrainAdminClient: BrainAdminClient, BrainSearchClient {
    var listProjectsResult: Result<[BrainProjectSummary], Error> = .success([])
    var getContextResults: [String: Result<BrainContext, Error>] = [:]
    var stalenessResult: Result<[ProjectStaleness], Error> = .success([])
    var pausedProjectsResult: Result<[String], Error> = .success([])
    var searchResult: Result<[BrainNodeView], Error> = .success([])
    var rebuildResult: Result<Void, Error> = .success(())
    var setPausedResult: Result<Void, Error> = .success(())

    private(set) var setPausedCalls: [(project: String, paused: Bool)] = []
    private(set) var reingestCalls: [String] = []
    private(set) var renameCalls: [(id: String, newLabel: String)] = []
    private(set) var rebuildCallCount = 0
    private(set) var searchCalls: [(query: String, scope: String?)] = []

    func listProjects(completion: @escaping (Result<[BrainProjectSummary], Error>) -> Void) {
        completion(listProjectsResult)
    }

    func getContext(project: String, completion: @escaping (Result<BrainContext, Error>) -> Void) {
        completion(getContextResults[project] ?? .success(BrainContext(summary: "", recentDecisions: [], relatedProjects: [], memoryNotes: [])))
    }

    func staleness(completion: @escaping (Result<[ProjectStaleness], Error>) -> Void) {
        completion(stalenessResult)
    }

    func pausedProjects(completion: @escaping (Result<[String], Error>) -> Void) {
        completion(pausedProjectsResult)
    }

    func setPaused(project: String, paused: Bool, completion: ((Result<Void, Error>) -> Void)?) {
        setPausedCalls.append((project, paused))
        completion?(setPausedResult)
    }

    func reingestProject(project: String, completion: ((Result<Void, Error>) -> Void)?) {
        reingestCalls.append(project)
        completion?(.success(()))
    }

    func renameProject(id: String, newLabel: String, completion: ((Result<Void, Error>) -> Void)?) {
        renameCalls.append((id, newLabel))
        completion?(.success(()))
    }

    func rebuildBrain(completion: ((Result<Void, Error>) -> Void)?) {
        rebuildCallCount += 1
        completion?(rebuildResult)
    }

    func search(query: String, scope: String?, completion: @escaping (Result<[BrainNodeView], Error>) -> Void) {
        searchCalls.append((query, scope))
        completion(searchResult)
    }
}
