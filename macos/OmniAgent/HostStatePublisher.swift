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
///
/// **One tick, not two.** `metrics()` is 1 Hz because that is
/// `HostMetricsSource`'s own cadence (shared with the sidebar's dial, never
/// duplicated — see its doc), and `start()` piggybacks on that same timer
/// rather than owning a second one: every time `HostMetricsSource` samples,
/// this publishes the *whole* payload, `limits`/`engines`/`host` read fresh
/// from whatever their own sources already have cached. That is what "metrics
/// at 1 Hz, everything else on change" means in practice — the *limits*
/// poller's `/usage` cadence and the *engine* probe's `PATH` search each stay
/// exactly as expensive (or as rare) as they already are on their own; this
/// class adds no polling of its own for either.
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

    private let sources: HostStateSources
    private var isRunning = false

    /// How this reaches the daemon. Assigned once by
    /// `WorkspaceWindowController` to `connection.publishHostState(_:)`;
    /// `nil` in a test that only wants to check `payload()`'s shape or
    /// `sources`'s own read count — a publisher nobody has wired to a
    /// connection has nowhere to send and must not crash for lack of one.
    var publish: ((Data) -> Void)?

    init(sources: HostStateSources) {
        self.sources = sources
    }

    /// The exact JSON in spec §4 — a snapshot built from `sources` right now,
    /// independent of whether `start()` has ever been called. `JSONEncoder`
    /// cannot fail on `Payload`'s all-`Double`/`String`/`Bool` shape, so a
    /// caller gets `Data` rather than a `throws` it can never usefully
    /// recover from; `??` only guards the type system's own promise, never a
    /// real failure this has been observed to hit.
    func payload() -> Data {
        let payload = Payload(
            metrics: sources.metrics(),
            limits: sources.limits(),
            engines: sources.engines(),
            host: sources.hostInfo()
        )
        return (try? Self.encoder.encode(payload)) ?? Data("{}".utf8)
    }

    /// Starts publishing — a no-op if already running, so a caller does not
    /// have to track whether it already called this.
    func start() {
        guard !isRunning else { return }
        isRunning = true
        HostMetricsSource.shared.addObserver(self) { [weak self] _ in
            guard let self else { return }
            self.publish?(self.payload())
        }
    }

    /// Stops publishing — a no-op if not running. Safe to call before
    /// `start()` ever has been.
    func stop() {
        guard isRunning else { return }
        isRunning = false
        HostMetricsSource.shared.removeObserver(self)
    }

    private static let encoder = JSONEncoder()
}
