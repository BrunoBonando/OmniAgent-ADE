import AppKit
import XCTest
@testable import OmniAgent

/// The viewer's read of `HostState` (2026-09-01 remote environment sharing
/// spec §4, Task 26): `HostStateModel` parses the payload, and the sidebar's
/// gauges, the Claude limits card and every engine picker read from it while
/// `isDrivingRemote` — from their existing local sources otherwise. A viewer
/// reading its own disk answers about the wrong machine, and an engine the
/// host does not have must show as unavailable even when it is installed
/// locally, with a reason naming the host.
final class HostStateConsumerTests: XCTestCase {
    func testGaugesAndLimitsFollowTheHostWhileDriving() {
        let model = HostStateModel()
        model.apply(#"{"metrics":{"cpu":0.9,"mem":0.5,"gpu":0.2},"limits":{"weekPercent":63},"engines":{"codex":{"available":false}}}"#)

        XCTAssertEqual(model.metrics?.cpu, 0.9)
        XCTAssertEqual(model.limits?.weekPercent, 63)
        XCTAssertEqual(model.engineAvailability["codex"], false)
    }

    func testAnEngineMissingOnTheHostIsShownUnavailableEvenIfInstalledLocally() {
        let picker = EnginePickerModel(hostState: .fixture(engines: ["codex": false]), isDrivingRemote: true)
        XCTAssertFalse(picker.isAvailable(.codex))
        XCTAssertEqual(picker.unavailableReason(.codex), "Not installed on Mac Studio")
    }

    /// The rule `HostStateModel` is built around, pinned directly:
    /// `ClaudeUsageLimits.merged(onto:)` already keeps a window's previous
    /// reading when a fresh one omits it, and this is the same promise one
    /// level up — a payload that only mentions `metrics` must not blank the
    /// limits or the engines a previous payload already established.
    func testAMissingKeyKeepsTheLastValueRatherThanBlanking() {
        let model = HostStateModel()
        model.apply(#"""
        {"metrics":{"cpu":0.4,"mem":0.3,"gpu":0.1},
         "limits":{"sessionPercent":10,"weekPercent":20},
         "engines":{"claude":{"available":true},"codex":{"available":false}},
         "host":{"name":"Mac Studio","os":"macOS 27.0","appVersion":"1.7.22"}}
        """#)

        // A tick that carries only metrics — `HostStatePublisher`'s own
        // 1 Hz cadence, where `engines`/`host` are cached and not re-sent
        // every second.
        model.apply(#"{"metrics":{"cpu":0.55,"mem":null,"gpu":null}}"#)

        XCTAssertEqual(model.metrics?.cpu, 0.55, "the field that was sent updates")
        XCTAssertEqual(model.metrics?.mem, 0.3, "a null field keeps the previous reading")
        XCTAssertEqual(model.metrics?.gpu, 0.1)
        XCTAssertEqual(model.limits?.sessionPercent, 10, "limits absent from this tick are untouched")
        XCTAssertEqual(model.limits?.weekPercent, 20)
        XCTAssertEqual(model.engineAvailability["claude"], true, "engines absent from this tick are untouched")
        XCTAssertEqual(model.engineAvailability["codex"], false)
        XCTAssertEqual(model.host?.name, "Mac Studio", "host info absent from this tick is untouched")
    }

    /// Reset is what keeps a *second* takeover of a different machine from
    /// showing the first host's readings for even one frame.
    func testResetForgetsEverything() {
        let model = HostStateModel()
        model.apply(#"{"metrics":{"cpu":0.5},"limits":{"weekPercent":10},"engines":{"claude":{"available":true}},"host":{"name":"Mac Studio"}}"#)
        XCTAssertTrue(model.hasReceivedAny)

        model.reset()

        XCTAssertNil(model.metrics)
        XCTAssertNil(model.limits)
        XCTAssertTrue(model.engineAvailability.isEmpty)
        XCTAssertNil(model.host)
        XCTAssertFalse(model.hasReceivedAny)
    }

    /// An engine the host was never asked about (`HostStatePublisher.Engines`
    /// only ever carries claude/codex/antigravity) has no host reading to
    /// contradict the local one, so the picker falls back to it rather than
    /// blocking an engine on missing information.
    func testAnEngineTheHostNeverMentionedFallsBackToTheLocalAnswer() {
        let picker = EnginePickerModel(
            hostState: .fixture(engines: ["codex": false]),
            isDrivingRemote: true,
            localAvailability: { _ in true }
        )
        XCTAssertTrue(picker.isAvailable(.shell), "no host reading for shell — fall back to local")
        XCTAssertNil(picker.unavailableReason(.shell))
    }

    /// Not driving at all: the picker never consults `hostState`, even when
    /// one happens to be set (a window that just ended a takeover, say).
    func testNotDrivingAlwaysReadsLocal() {
        let picker = EnginePickerModel(
            hostState: .fixture(engines: ["claude": false]),
            isDrivingRemote: false,
            localAvailability: { _ in true }
        )
        XCTAssertTrue(picker.isAvailable(.claude))
        XCTAssertNil(picker.unavailableReason(.claude))
    }

    // MARK: - The sidebar cards read the host while driving

    func testTheGaugesReadTheHostWhileDrivingAndTheLocalMachineOtherwise() {
        let stats = SidebarSystemStatsView()
        stats.apply(cpu: 0.2, memory: 0.3, gpu: 0.4, animated: false)

        let host = HostStateModel()
        host.apply(#"{"metrics":{"cpu":0.9,"mem":0.8,"gpu":0.7}}"#)

        // Not driving: a `HostState` push is recorded but not shown.
        stats.applyHostState(host, animated: false)
        XCTAssertEqual(stats.cpuGauge.fraction, 0.2, "still this machine's own reading")

        // Driving: the same push is now shown.
        stats.isDrivingRemote = true
        XCTAssertEqual(stats.cpuGauge.fraction, 0.9, "flipping the flag re-applies the last push")

        // Driving ends: the host's stale reading does not linger — this
        // machine's own kernel snapshot resumes immediately rather than
        // waiting out `sampleInterval`'s next tick. The exact figure comes
        // from the real, unmocked `HostMetricsSource.shared` (no injection
        // seam exists, nor should this test add one just to read a number
        // back), so what is pinned here is that the *host's* number is
        // gone, not what specific local one replaced it.
        stats.isDrivingRemote = false
        XCTAssertNotEqual(stats.cpuGauge.fraction, 0.9, "the host's reading must not linger")
    }

    func testTheLimitsCardReadsTheHostWhileDrivingAndTheLocalMachineOtherwise() {
        let card = SidebarClaudeLimitsView()
        card.apply(ClaudeUsageLimits(
            sessionPercent: 5, sessionResets: nil, weekPercent: 5, weekResets: nil,
            modelName: nil, modelPercent: nil
        ), animated: false)

        let host = HostStateModel()
        host.apply(#"{"limits":{"sessionPercent":91,"weekPercent":63}}"#)

        card.applyHostState(host, animated: false)
        XCTAssertEqual(card.sessionColumn.readout, "5%", "not driving — the local card is untouched")

        card.isDrivingRemote = true
        XCTAssertEqual(card.sessionColumn.readout, "91%", "driving — the host's reading shows")
        XCTAssertEqual(card.weekColumn.readout, "63%")

        // Ending the takeover reads `ClaudeUsageLimitsPoller.shared` — the
        // real, unmocked app-wide singleton, with no injection seam and none
        // added here just to read a number back — so what is pinned is that
        // the host's stale reading is gone, not which local one replaced it.
        card.isDrivingRemote = false
        XCTAssertNotEqual(card.sessionColumn.readout, "91%", "the host's reading must not linger")
    }
}

extension HostStateModel {
    /// A fixture in the app's own "Mac Studio" convention
    /// (`ConnectionSwapTests`, `RemoteConnectCeremonyTests`, and every other
    /// remote-sharing test file in this suite name their stand-in host the
    /// same thing), built through the real `apply(_:)` parser rather than by
    /// poking `private(set)` properties, so a fixture can never drift from
    /// what a genuine payload actually produces.
    static func fixture(
        engines: [String: Bool] = [:],
        hostName: String = "Mac Studio"
    ) -> HostStateModel {
        let payload: [String: Any] = [
            "engines": engines.mapValues { ["available": $0] },
            "host": ["name": hostName],
        ]
        let data = try! JSONSerialization.data(withJSONObject: payload) // swiftlint:disable:this force_try
        let model = HostStateModel()
        model.apply(data)
        return model
    }
}
