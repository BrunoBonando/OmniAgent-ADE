import XCTest

@testable import OmniAgent

/// `HostStatePublisher` — the host side of `HostState` (2026-09-01 remote
/// environment sharing spec §4, Task 22): the gauges, the Claude usage
/// limits, and engine availability the app computes in-process, published to
/// the lease holder over `PublishHostState`. `HostStateSources` is the seam
/// that keeps these tests off the kernel, `/usage`, and a real `PATH` search
/// — `FixtureHostStateSources`/`SpyHostStateSources` below stand in for it.
final class HostStatePublisherTests: XCTestCase {
    /// `start()` registers with the real `HostMetricsSource.shared` — see
    /// its own doc — so every test here that calls `start()` cleans up after
    /// itself, the same discipline `NavigationSidebarTests`'s cadence tests
    /// use for the same singleton.
    override func tearDown() {
        HostMetricsSource.shared.resetForTesting()
        super.tearDown()
    }

    func testPayloadCarriesEverythingAViewerCannotComputeItself() throws {
        let json = try JSONSerialization.jsonObject(
            with: HostStatePublisher(sources: .fixture())
                .payload()
        ) as! [String: Any]

        XCTAssertNotNil((json["metrics"] as? [String: Any])?["cpu"])
        XCTAssertNotNil((json["metrics"] as? [String: Any])?["gpu"])
        XCTAssertNotNil((json["limits"] as? [String: Any])?["weekPercent"])
        XCTAssertEqual(
            ((json["engines"] as? [String: Any])?["claude"] as? [String: Any])?["available"] as? Bool,
            true
        )
        XCTAssertEqual((json["host"] as? [String: Any])?["name"] as? String, "Test Mac")
    }

    func testNothingIsComputedWhileNobodyIsConnected() {
        let sources = SpyHostStateSources()
        let publisher = HostStatePublisher(sources: sources)
        publisher.stop()
        XCTAssertEqual(sources.metricsReads, 0)
    }

    /// `HostMetricsSource`'s timer fires no sooner than a real second away
    /// (`RunLoop.main`, `timeInterval: 1`), so a `start()` immediately
    /// followed by `stop()` cannot have been ticked even once by the time
    /// this function returns — deterministic, not a race against real time.
    /// This is the other half of "nothing runs when nobody is connected":
    /// the fast path, where a viewer connects and disconnects between two
    /// lines of this test, must publish nothing either.
    func testStartingThenStoppingBeforeAnyTickPublishesNothing() {
        let sources = SpyHostStateSources()
        let publisher = HostStatePublisher(sources: sources)
        var published: [Data] = []
        publisher.publish = { published.append($0) }

        publisher.start()
        publisher.stop()

        XCTAssertEqual(sources.metricsReads, 0)
        XCTAssertTrue(published.isEmpty)
    }

    /// `start()`/`stop()` are each idempotent — `syncTakeoverPanel` never has
    /// to track whether it already called one.
    func testStartAndStopAreIdempotent() {
        let publisher = HostStatePublisher(sources: SpyHostStateSources())
        publisher.start()
        publisher.start()
        publisher.stop()
        publisher.stop()
        // No crash, and no HostMetricsSource observer left dangling — the
        // second `stop()` finding nothing to unregister is exactly the point.
    }

    /// The wire shape, key by key (spec §4) — a later task (the viewer's
    /// `HostState` consumer) is written against this exact structure, so a
    /// non-nil check alone is not enough here.
    func testPayloadMatchesTheSpecShapeExactly() throws {
        let json = try JSONSerialization.jsonObject(
            with: HostStatePublisher(sources: .fixture()).payload()
        ) as! [String: Any]

        XCTAssertEqual(keySet(json), ["metrics", "limits", "engines", "host"])
        XCTAssertEqual(keySet(json["metrics"] as? [String: Any]), ["cpu", "mem", "gpu"])
        XCTAssertEqual(
            keySet(json["limits"] as? [String: Any]),
            ["sessionPercent", "sessionResets", "weekPercent", "weekResets", "modelName", "modelPercent"]
        )

        let engines = json["engines"] as? [String: Any]
        XCTAssertEqual(keySet(engines), ["claude", "codex", "antigravity"])
        for engine in ["claude", "codex", "antigravity"] {
            XCTAssertEqual(keySet(engines?[engine] as? [String: Any]), ["available"])
        }

        XCTAssertEqual(keySet(json["host"] as? [String: Any]), ["name", "os", "appVersion"])
    }

    // MARK: - Caching (fix round 1, IMPORTANT 2)
    //
    // `tick()` is not `private` specifically so these can drive it directly
    // rather than waiting out `HostMetricsSource`'s real 1-second timer, or
    // — for the slow-refresh test — a real minute of them.

    /// `start()` refreshes `engines`/`hostInfo` exactly once, explicitly —
    /// a viewer that has just taken the lease is told the truth right away —
    /// and then not again on every metrics tick. The metrics tick must carry
    /// metrics: `metricsReads` grows one-for-one with `tick()`, `enginesReads`/
    /// `hostInfoReads` do not move at all across ten of them.
    func testEnginesAndHostAreCachedNotReReadEveryTick() {
        let sources = SpyHostStateSources()
        let publisher = HostStatePublisher(sources: sources)
        var published: [Data] = []
        publisher.publish = { published.append($0) }

        publisher.start()
        XCTAssertEqual(sources.enginesReads, 1)
        XCTAssertEqual(sources.hostInfoReads, 1)
        XCTAssertEqual(sources.metricsReads, 0, "start() itself must not read metrics")

        for _ in 0..<10 { publisher.tick() }

        XCTAssertEqual(published.count, 10)
        XCTAssertEqual(sources.metricsReads, 10)
        XCTAssertEqual(sources.enginesReads, 1, "engines must not be re-read on every metrics tick")
        XCTAssertEqual(sources.hostInfoReads, 1, "host info must not be re-read on every metrics tick")

        publisher.stop()
    }

    /// The other half of "on change": with no real change signal for
    /// installed engines, a long tick-counted interval stands in for one.
    /// One full `HostStatePublisher.slowRefreshEveryTicks` worth of ticks
    /// must refresh the cache exactly once more — not before, and not
    /// silently never.
    func testEnginesAndHostRefreshAfterOneSlowInterval() {
        let sources = SpyHostStateSources()
        let publisher = HostStatePublisher(sources: sources)
        publisher.start()
        XCTAssertEqual(sources.enginesReads, 1)

        for _ in 0..<(HostStatePublisher.slowRefreshEveryTicks - 1) { publisher.tick() }
        XCTAssertEqual(sources.enginesReads, 1, "not yet — one tick short of a full interval")

        publisher.tick()
        XCTAssertEqual(sources.enginesReads, 2, "a full slow-refresh interval elapsed while running")
        XCTAssertEqual(sources.hostInfoReads, 2)

        publisher.stop()
    }

    /// `payload()` called on its own, before `start()` ever has been, still
    /// reads `engines`/`hostInfo` live — the cache exists to spare a
    /// *running* publisher repeated work, not to make a standalone call
    /// answer with nothing.
    func testPayloadWithoutStartReadsEnginesAndHostLiveEveryTime() {
        let sources = SpyHostStateSources()
        let publisher = HostStatePublisher(sources: sources)

        _ = publisher.payload()
        _ = publisher.payload()

        XCTAssertEqual(sources.enginesReads, 2)
        XCTAssertEqual(sources.hostInfoReads, 2)
    }
}

/// `[String: Any].keys` (or `nil`, for a field this test is also checking is
/// the right *type*) as a `Set` — `Dictionary.Keys` has no `?? []` of its
/// own, since it is not array-literal-expressible.
private func keySet(_ dict: [String: Any]?) -> Set<String> {
    Set((dict ?? [:]).keys)
}

// MARK: - Test doubles

extension HostStateSources where Self == FixtureHostStateSources {
    /// Every field populated with a plausible reading — the shape-only test
    /// above just needs *something* at each key, not a particular value.
    static func fixture() -> FixtureHostStateSources { FixtureHostStateSources() }
}

struct FixtureHostStateSources: HostStateSources {
    func metrics() -> HostStatePublisher.Metrics {
        HostStatePublisher.Metrics(cpu: 0.34, mem: 0.61, gpu: 0.12)
    }

    func limits() -> ClaudeUsageLimits {
        ClaudeUsageLimits(
            sessionPercent: 41, sessionResets: "4h 12m",
            weekPercent: 63, weekResets: "2d 19h",
            modelName: "Opus 5", modelPercent: 22
        )
    }

    func engines() -> HostStatePublisher.Engines {
        HostStatePublisher.Engines(
            claude: .init(available: true),
            codex: .init(available: false),
            antigravity: .init(available: true)
        )
    }

    func hostInfo() -> HostStatePublisher.HostInfo {
        HostStatePublisher.HostInfo(name: "Test Mac", os: "macOS 27.0", appVersion: "1.7.22")
    }
}

/// Counts reads rather than answering them meaningfully — what
/// `testNothingIsComputedWhileNobodyIsConnected`,
/// `testStartingThenStoppingBeforeAnyTickPublishesNothing`, and the caching
/// tests (fix round 1, IMPORTANT 2) need to observe: not just *that*
/// `HostStatePublisher` reads each field, but *how often*.
final class SpyHostStateSources: HostStateSources {
    private(set) var metricsReads = 0
    private(set) var enginesReads = 0
    private(set) var hostInfoReads = 0

    func metrics() -> HostStatePublisher.Metrics {
        metricsReads += 1
        return HostStatePublisher.Metrics(cpu: nil, mem: nil, gpu: nil)
    }

    func limits() -> ClaudeUsageLimits { .empty }

    func engines() -> HostStatePublisher.Engines {
        enginesReads += 1
        return HostStatePublisher.Engines(
            claude: .init(available: false),
            codex: .init(available: false),
            antigravity: .init(available: false)
        )
    }

    func hostInfo() -> HostStatePublisher.HostInfo {
        hostInfoReads += 1
        return HostStatePublisher.HostInfo(name: "Spy Mac", os: "macOS", appVersion: "0")
    }
}
