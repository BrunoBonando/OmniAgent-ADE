import Foundation

/// Everything the host app knows about itself that a viewer's own machine
/// cannot (2026-09-01 remote environment sharing spec §4, Task 22): the
/// gauges (`HostMetricsSource`, `NavigationSidebar.swift`), the Claude usage
/// limits (`ClaudeUsageLimits`, from `/usage`), and which engines are
/// installed (`EngineLauncher`). A viewer's app reading its *own* disk for
/// any of these would answer for the wrong machine — this protocol is the
/// seam that lets `HostStatePublisher` be tested against fixed values
/// (`HostStatePublisherTests`'s `.fixture()`/`SpyHostStateSources`) instead
/// of the kernel, `/usage`, and a real `PATH` search.
protocol HostStateSources {
    /// CPU/memory/GPU fractions, 0...1, `nil` where unavailable — the exact
    /// reading `HostMetricsSource.shared.latest` holds, never a second call
    /// into `MachineStats`. See `HostMetricsSource`'s own doc for why two
    /// independent samplers would corrupt each other's baseline.
    func metrics() -> HostStatePublisher.Metrics

    /// Claude's rate-limit windows. Already-cached, already "on change": the
    /// app-wide `ClaudeUsageLimitsPoller` owns the `/usage` cadence, and this
    /// is a read of whatever it last landed — never a fetch of its own.
    func limits() -> ClaudeUsageLimits

    /// Which engines are on this machine's `PATH` right now.
    func engines() -> HostStatePublisher.Engines

    /// This machine's own identity.
    func hostInfo() -> HostStatePublisher.HostInfo
}

/// The live [`HostStateSources`] — every field read from the real machine,
/// `HostStatePublisher`'s production dependency (`WorkspaceWindowController`
/// constructs it once, alongside the daemon connection).
struct LiveHostStateSources: HostStateSources {
    func metrics() -> HostStatePublisher.Metrics {
        let snapshot = HostMetricsSource.shared.latest
        return HostStatePublisher.Metrics(cpu: snapshot.cpu, mem: snapshot.memory, gpu: snapshot.gpu)
    }

    func limits() -> ClaudeUsageLimits {
        ClaudeUsageLimitsPoller.shared.latest ?? .empty
    }

    func engines() -> HostStatePublisher.Engines {
        HostStatePublisher.Engines(
            claude: .init(available: EngineLauncher.isInstalled(.claude)),
            codex: .init(available: EngineLauncher.isInstalled(.codex)),
            antigravity: .init(available: EngineLauncher.isInstalled(.antigravity))
        )
    }

    func hostInfo() -> HostStatePublisher.HostInfo {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let appVersion =
            Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return HostStatePublisher.HostInfo(
            name: Host.current().localizedName ?? "Mac",
            os: "macOS \(version.majorVersion).\(version.minorVersion)",
            appVersion: appVersion ?? "?"
        )
    }
}

/// Publishes `HostState`'s payload (spec §4) to whichever remote connection
/// currently holds the lease — the machine driving this one, and the one and
/// only reader `PublishHostState` ever reaches
/// (`crates/omniagent-pty-daemon/src/connections.rs`'s `host_state_updates`).
///
/// **Runs only while `start()` has been called and `stop()` has not.**
/// `WorkspaceWindowController.syncTakeoverPanel()` is the one caller of
/// either: `start()` the moment `remoteSharing.liveConnection` goes from
/// `nil` to a real connection, `stop()` the moment it goes back — the same
/// transition that puts up and takes down the takeover panel. A machine with
/// no viewer calls neither, so nothing here ever runs for it.
/// `WorkspaceWindowController.deinit` also calls `stop()` — the abnormal
/// path a window torn down mid-share would otherwise leave running.
///
/// **One tick, not two — but the tick carries only `metrics` (fix round 1,
/// IMPORTANT 2).** `start()` registers with `HostMetricsSource` at 1 Hz
/// (`Self.metricsInterval`, shared with the sidebar's dial, never
/// duplicated — see its doc) rather than owning a second timer. Every time
/// that fires, `metrics()` and `limits()` are read fresh — both are cheap,
/// cached reads of state something else already polls on its own schedule
/// (`HostMetricsSource.shared.latest`, `ClaudeUsageLimitsPoller.shared
/// .latest`) — but `engines()`/`hostInfo()` are **not**: `EngineLauncher
/// .isInstalled` loops the whole `PATH` calling `isExecutableFile` for each
/// of three engines, and only the `PATH` *string* is cached, not that stat.
/// Running that once a second for the life of a share was fix round 1's
/// finding, and this is the fix — `cachedEngines`/`cachedHostInfo` are read
/// by `payload()` on every tick, but only *written* by `refreshSlowFields()`,
/// which runs at two moments: an explicit refresh the instant `start()` is
/// called (so a viewer that has just connected sees real values, not
/// whatever `.fixture()`-shaped default an unread cache would fall back to),
/// and again every `Self.slowRefreshEveryTicks` ticks after that — a much
/// longer interval, chosen because installing or removing a CLI is a rare,
/// manual act, not something a viewer needs to see land within one
/// heartbeat.
final class HostStatePublisher {
    struct Metrics: Encodable {
        var cpu: Double?
        var mem: Double?
        var gpu: Double?
    }

    struct EngineAvailability: Encodable {
        var available: Bool
    }

    struct Engines: Encodable {
        var claude: EngineAvailability
        var codex: EngineAvailability
        var antigravity: EngineAvailability
    }

    struct HostInfo: Encodable {
        var name: String
        var os: String
        var appVersion: String
    }

    private struct Payload: Encodable {
        var metrics: Metrics
        var limits: ClaudeUsageLimits
        var engines: Engines
        var host: HostInfo
    }

    /// `HostMetricsSource`'s own 1 Hz cadence — the publisher's interval,
    /// registered explicitly (fix round 1, IMPORTANT 1) rather than assumed,
    /// so it cannot silently drift from what spec §4 actually asks for.
    private static let metricsInterval: TimeInterval = 1

    /// How many metrics ticks pass between `engines()`/`hostInfo()`
    /// refreshes while running — one minute at `metricsInterval`. See the
    /// class doc's "fix round 1, IMPORTANT 2" paragraph for why this is a
    /// tick count rather than a second timer, and why a minute is the chosen
    /// trade-off.
    static let slowRefreshEveryTicks = 60

    private let sources: HostStateSources
    /// Readable so the window can be asked whether this Mac is publishing —
    /// `ConnectionSwapTests` pins that it is not, for the whole of a takeover:
    /// a machine driving another machine is not a host and has nothing to say
    /// about itself to anyone.
    private(set) var isRunning = false
    private var ticksSinceSlowRefresh = 0

    /// `engines()`/`hostInfo()` as of the last `refreshSlowFields()` —
    /// `nil` until that has run at least once, which `payload()` falls back
    /// on so it stays correct (if not cache-fast) when called without
    /// `start()` ever having run.
    private var cachedEngines: Engines?
    private var cachedHostInfo: HostInfo?

    /// How this reaches the daemon. Assigned once by
    /// `WorkspaceWindowController` to `connection.publishHostState(_:)`;
    /// `nil` in a test that only wants to check `payload()`'s shape or
    /// `sources`'s own read count — a publisher nobody has wired to a
    /// connection has nowhere to send and must not crash for lack of one.
    var publish: ((Data) -> Void)?

    init(sources: HostStateSources) {
        self.sources = sources
    }

    /// The exact JSON in spec §4 — a snapshot built right now, independent
    /// of whether `start()` has ever been called: `metrics()`/`limits()` are
    /// always read live (both cheap), `engines()`/`hostInfo()` come from the
    /// cache when `refreshSlowFields()` has populated one and are read live
    /// otherwise — so a standalone `payload()` call before `start()` is
    /// correct, just not cache-fast, and every call while running reads the
    /// same cache `tick()` does. `JSONEncoder` cannot fail on `Payload`'s
    /// all-`Double`/`String`/`Bool` shape, so a caller gets `Data` rather
    /// than a `throws` it can never usefully recover from; `??` only guards
    /// the type system's own promise, never a real failure this has been
    /// observed to hit.
    func payload() -> Data {
        let payload = Payload(
            metrics: sources.metrics(),
            limits: sources.limits(),
            engines: cachedEngines ?? sources.engines(),
            host: cachedHostInfo ?? sources.hostInfo()
        )
        return (try? Self.encoder.encode(payload)) ?? Data("{}".utf8)
    }

    /// Starts publishing — a no-op if already running, so a caller does not
    /// have to track whether it already called this. Refreshes
    /// `engines`/`hostInfo` once, immediately, before registering: a viewer
    /// that has just taken the lease is told what is actually installed on
    /// this machine right now, not a stale cache from the share before.
    func start() {
        guard !isRunning else { return }
        isRunning = true
        refreshSlowFields()
        HostMetricsSource.shared.addObserver(self, interval: Self.metricsInterval) { [weak self] _ in
            self?.tick()
        }
    }

    /// Stops publishing — a no-op if not running. Safe to call before
    /// `start()` ever has been, and safe to call from `deinit`.
    func stop() {
        guard isRunning else { return }
        isRunning = false
        HostMetricsSource.shared.removeObserver(self)
    }

    /// One `HostMetricsSource` sample: publishes the current `payload()`,
    /// and every `Self.slowRefreshEveryTicks`th call also refreshes the slow
    /// fields first. Not `private` — `HostStatePublisherTests` calls this
    /// directly to pin the caching behaviour without waiting out real
    /// 1-second (or one-minute) timer ticks, the same reason
    /// `SidebarSystemStatsView.apply` is public rather than reachable only
    /// through its own timer.
    func tick() {
        ticksSinceSlowRefresh += 1
        if ticksSinceSlowRefresh >= Self.slowRefreshEveryTicks {
            refreshSlowFields()
        }
        publish?(payload())
    }

    private func refreshSlowFields() {
        cachedEngines = sources.engines()
        cachedHostInfo = sources.hostInfo()
        ticksSinceSlowRefresh = 0
    }

    private static let encoder = JSONEncoder()
}
