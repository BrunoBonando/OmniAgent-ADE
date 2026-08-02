import XCTest
@testable import OmniAgent

final class UsageViewModelTests: XCTestCase {
    func testInsightsReflectTheSnapshotStoreForTheSelectedProject() {
        var store = UsageAnalyticsStore()
        UsageAnalytics.recordSessionOpened(&store, projectId: "alpha", at: 1_000)
        UsageAnalytics.recordSessionOpened(&store, projectId: "beta", at: 1_000)
        let client = FakeBrainAdminClient()

        let model = UsageViewModel(store: store, projectDirectory: client, clock: { 2_000 })

        XCTAssertEqual(model.insights.totals.sessionsOpened, 2, "defaults to the global __all__ bucket")

        model.selectedProject = "alpha"
        XCTAssertEqual(model.insights.totals.sessionsOpened, 1)
    }

    func testProjectsArePopulatedFromTheDirectoryOnInit() {
        let client = FakeBrainAdminClient()
        client.listProjectsResult = .success([
            BrainProjectSummary(id: "alpha", label: "Alpha", path: "/a"),
            BrainProjectSummary(id: "beta", label: "Beta", path: "/b"),
        ])

        let model = UsageViewModel(store: UsageAnalyticsStore(), projectDirectory: client)

        XCTAssertEqual(model.projects.map(\.id), ["alpha", "beta"])
    }
}
