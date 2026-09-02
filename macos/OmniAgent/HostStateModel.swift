import Foundation

/// The viewer's read of `HostState` (2026-09-01 remote environment sharing
/// spec §4, Task 26): the payload `HostStatePublisher` builds on the host,
/// parsed back out here so the sidebar's gauges, the Claude limits card and
/// engine availability can answer for the machine actually being driven
/// instead of this one.
///
/// **A missing key keeps the last value rather than blanking** — the same
/// rule `ClaudeUsageLimits.merged(onto:)` already follows, for the same
/// reason: a momentarily absent field (a tick that only carries `metrics`,
/// an engine the host has not re-scanned since the last publish) must not
/// read as a broken gauge. Every `apply` therefore merges field by field
/// onto whatever this already held, never replacing the object wholesale —
/// which is also why every reading here is `nil` until the first `HostState`
/// lands, rather than defaulting to some local guess.
final class HostStateModel {
    struct Metrics: Equatable {
        var cpu: Double?
        var mem: Double?
        var gpu: Double?
    }

    struct HostInfo: Equatable {
        var name: String?
        var os: String?
        var appVersion: String?
    }

    private(set) var metrics: Metrics?
    private(set) var limits: ClaudeUsageLimits?
    /// Keyed by the wire name (`"claude"`, `"codex"`, `"antigravity"` —
    /// `Engine.rawValue`), so `EnginePickerModel` reads it directly rather
    /// than translating a second time. An engine the host has never
    /// mentioned simply has no entry — `HostStatePublisher.Engines` only
    /// ever carries these three, so `.shell`/`.copilot` never appear here.
    private(set) var engineAvailability: [String: Bool] = [:]
    private(set) var host: HostInfo?

    /// Whether at least one `HostState` push has ever been applied — what
    /// the connect ceremony's "Loading environment…" step waits on (spec §6,
    /// the carried item from Task 24/25): the environment the user sees when
    /// the glass lifts must be complete, not layout-and-sessions-only.
    private(set) var hasReceivedAny = false

    init() {}

    /// Parses one `HostState` payload and merges it onto whatever this
    /// already held. Malformed JSON is dropped silently, the same rule every
    /// other push in this app follows (`SessionConnection.handle(_:)`'s
    /// `try?` decodes) — a daemon this build cannot fully understand must
    /// leave the last good reading in place, not blank the card.
    func apply(_ json: String) {
        apply(Data(json.utf8))
    }

    func apply(_ data: Data) {
        guard let wire = try? Self.decoder.decode(Wire.self, from: data) else { return }
        hasReceivedAny = true
        if let incoming = wire.metrics {
            metrics = Metrics(
                cpu: incoming.cpu ?? metrics?.cpu,
                mem: incoming.mem ?? metrics?.mem,
                gpu: incoming.gpu ?? metrics?.gpu
            )
        }
        if let incoming = wire.limits {
            // `ClaudeUsageLimits` already knows how to lay a fresh reading
            // over a previous one window by window — reused rather than a
            // second copy of the same merge rule.
            limits = incoming.merged(onto: limits)
        }
        if let incoming = wire.engines {
            for (name, availability) in incoming {
                engineAvailability[name] = availability.available
            }
        }
        if let incoming = wire.host {
            host = HostInfo(
                name: incoming.name ?? host?.name,
                os: incoming.os ?? host?.os,
                appVersion: incoming.appVersion ?? host?.appVersion
            )
        }
    }

    /// Back to knowing nothing — `WorkspaceWindowController` calls this on
    /// every `connectRemote(to:)`, so a fresh takeover of a *different*
    /// machine never shows the previous host's readings even for one frame.
    func reset() {
        metrics = nil
        limits = nil
        engineAvailability = [:]
        host = nil
        hasReceivedAny = false
    }

    private struct Wire: Decodable {
        var metrics: WireMetrics?
        var limits: ClaudeUsageLimits?
        var engines: [String: WireEngine]?
        var host: WireHost?
    }

    private struct WireMetrics: Decodable {
        var cpu: Double?
        var mem: Double?
        var gpu: Double?
    }

    private struct WireEngine: Decodable {
        var available: Bool
    }

    private struct WireHost: Decodable {
        var name: String?
        var os: String?
        var appVersion: String?
    }

    private static let decoder = JSONDecoder()
}
