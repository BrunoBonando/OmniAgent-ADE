import Sparkle
import XCTest
@testable import OmniAgent

/// The self-update state machine, its widget, and the spotlight rows it puts
/// up. Deliberately free of Sparkle: `UpdateController`'s `SPUUserDriver`
/// methods are thin wrappers over the plain-value transitions exercised here,
/// so the whole sequence runs without an appcast, a network, or an
/// `SUAppcastItem` (which has no public initialiser worth faking).
@MainActor
final class UpdateControllerTests: XCTestCase {
    // MARK: - The state machine

    func testTheWholeSequenceFromFoundToReady() {
        let controller = UpdateController()
        var seen: [UpdateState] = []
        controller.onStateChange = { seen.append($0) }

        controller.foundUpdate(version: "1.8.0")
        controller.downloadStarted(expectedBytes: 100)
        controller.downloadProgressed(byBytes: 50)
        controller.extractionProgressed(0.5)
        controller.readyToInstall(version: "1.8.0") { _ in }

        XCTAssertEqual(
            seen,
            [
                .available(version: "1.8.0"),
                .updating(fraction: 0),
                // Half the bytes is 0.4, not 0.5: unpacking and installing own
                // the last fifth of the bar.
                .updating(fraction: 0.4),
                .updating(fraction: 0.9),
                .readyToRestart(version: "1.8.0"),
            ]
        )
    }

    func testProgressIsIndeterminateUntilTheServerSaysHowBig() {
        let controller = UpdateController()
        controller.downloadStarted(expectedBytes: 0)
        XCTAssertEqual(controller.state, .updating(fraction: nil))
        // A bar frozen at zero reads as stuck, so bytes with no total still
        // do not invent a fraction.
        controller.downloadProgressed(byBytes: 4096)
        XCTAssertEqual(controller.state, .updating(fraction: nil))
    }

    func testProgressNeverExceedsTheBar() {
        let controller = UpdateController()
        controller.downloadStarted(expectedBytes: 10)
        controller.downloadProgressed(byBytes: 999)
        XCTAssertEqual(controller.state, .updating(fraction: 0.8))
        controller.extractionProgressed(5)
        XCTAssertEqual(controller.state, .updating(fraction: 1))
    }

    func testNoUpdateEndsAUserInitiatedCheckWithoutDisturbingAnythingElse() {
        let controller = UpdateController()
        controller.foundUpdate(version: "1.8.0")
        // A background check finding nothing must not clear a found update.
        controller.foundNothing()
        XCTAssertEqual(controller.state, .available(version: "1.8.0"))
    }

    func testFailureIsItsOwnStateAndDropsTheHeldReplies() {
        let controller = UpdateController()
        controller.foundUpdate(version: "1.8.0")
        controller.failed("the network went away")
        XCTAssertEqual(controller.state, .failed("the network went away"))
        // Nothing to download any more: the reply Sparkle handed over is gone
        // with the failed session, so pressing must not pretend otherwise.
        controller.downloadUpdate()
        XCTAssertEqual(controller.state, .failed("the network went away"))
    }

    func testIdleIsTheOnlyInvisibleState() {
        XCTAssertFalse(UpdateState.idle.isVisible)
        for state: UpdateState in [
            .checking,
            .available(version: "1.8.0"),
            .updating(fraction: nil),
            .readyToRestart(version: "1.8.0"),
            .failed("x"),
        ] {
            XCTAssertTrue(state.isVisible, "\(state) has something to say")
        }
    }

    // MARK: - Consent

    /// The rule this whole feature turns on: restarting ends every live
    /// terminal session, so it is asked for before anything irreversible —
    /// and a "no" must leave the update exactly where it was.
    func testDecliningTheRestartKeepsTheUpdateOffered() {
        let controller = UpdateController()
        var asked = 0
        controller.confirmRestart = { decide in
            asked += 1
            decide(false)
        }
        controller.readyToInstall(version: "1.8.0") { _ in
            XCTFail("a declined restart must not install anything")
        }
        controller.restartToUpdate()

        XCTAssertEqual(asked, 1)
        XCTAssertEqual(controller.state, .readyToRestart(version: "1.8.0"), "declining changes nothing")
    }

    func testTheDaemonStopperIsNotAskedAnythingBecauseConsentAlreadyHappened() {
        // Two separate seams on purpose: by the time Sparkle is ready to
        // relaunch, the bundle is already swapped and there is no longer a
        // "no" to offer. `confirmRestart` is the only place that can refuse.
        let controller = UpdateController()
        var stopped = false
        controller.confirmRestart = { $0(true) }
        controller.daemonStopper = { proceed in
            stopped = true
            proceed()
        }
        var installed: SPUUserUpdateChoice?
        controller.readyToInstall(version: "1.8.0") { installed = $0 }
        controller.restartToUpdate()

        XCTAssertEqual(installed, .install, "confirming hands Sparkle the go-ahead")
        XCTAssertEqual(controller.state, .updating(fraction: 1))
        // The stopper has not run yet: it runs from Sparkle's relaunch
        // callback, after the bundle is swapped, not from the press.
        XCTAssertFalse(stopped)
    }

    // MARK: - The sidebar widget

    func testTheWidgetIsHiddenUntilThereIsSomethingToSay() {
        let widget = SidebarUpdateWidgetView()
        widget.apply(.idle)
        XCTAssertTrue(widget.isHidden)
        widget.apply(.available(version: "1.8.0"))
        XCTAssertFalse(widget.isHidden)
    }

    func testTheWidgetSaysWhatIsHappening() {
        let widget = SidebarUpdateWidgetView()
        widget.apply(.checking)
        XCTAssertEqual(widget.titleText, "Checking for updates…")
        widget.apply(.available(version: "1.8.0"))
        XCTAssertEqual(widget.titleText, "Update available · 1.8.0")
        widget.apply(.updating(fraction: 0.5))
        XCTAssertEqual(widget.titleText, "Updating…")
        widget.apply(.readyToRestart(version: "1.8.0"))
        XCTAssertEqual(widget.titleText, "Update ready · 1.8.0 — Restart")
        widget.apply(.failed("nope"))
        XCTAssertEqual(widget.titleText, "Update failed — Retry")
    }

    func testTheWidgetPressesOnlyWhereThereIsSomethingToPress() {
        let widget = SidebarUpdateWidgetView()
        var downloads = 0, restarts = 0, retries = 0
        widget.onDownload = { downloads += 1 }
        widget.onRestart = { restarts += 1 }
        widget.onRetry = { retries += 1 }

        widget.apply(.available(version: "1.8.0"))
        widget.onPress?()
        widget.apply(.readyToRestart(version: "1.8.0"))
        widget.onPress?()
        widget.apply(.failed("x"))
        widget.onPress?()
        XCTAssertEqual([downloads, restarts, retries], [1, 1, 1])

        // Mid-download a press must not cancel anything by accident.
        widget.apply(.updating(fraction: 0.3))
        widget.onPress?()
        widget.apply(.checking)
        widget.onPress?()
        XCTAssertEqual([downloads, restarts, retries], [1, 1, 1])
    }

    // MARK: - Spotlight
    //
    // "Spotlight finds everything" is a standing repo rule: a navigable thing
    // is a row the day it lands.

    func testTheSpotlightOffersTheUpdateActionThatCanActuallyBeTaken() {
        func rows(_ state: UpdateState) -> [PaletteCommand] {
            CommandPaletteModel.build(
                panes: [], paneOrder: [], focusedPaneID: nil, updateState: state
            ).filter { $0.id.hasPrefix("update:") }
        }

        XCTAssertEqual(rows(.idle).map(\.id), ["update:check"])
        XCTAssertEqual(rows(.failed("x")).map(\.id), ["update:check"])
        XCTAssertEqual(rows(.available(version: "1.8.0")).map(\.id), ["update:download"])
        XCTAssertEqual(rows(.readyToRestart(version: "1.8.0")).map(\.id), ["update:restart"])
        // Nothing to offer while work is already in flight.
        XCTAssertEqual(rows(.checking), [])
        XCTAssertEqual(rows(.updating(fraction: 0.5)), [])
    }

    func testTheSpotlightRowsSayWhereTheyLiveAndWhatTheyCost() {
        let available = CommandPaletteModel.build(
            panes: [], paneOrder: [], focusedPaneID: nil,
            updateState: .available(version: "1.8.0")
        ).first { $0.id == "update:download" }
        XCTAssertEqual(available?.subtitle, "Version 1.8.0 is available")
        XCTAssertEqual(available?.detail, "1.8.0")

        let ready = CommandPaletteModel.build(
            panes: [], paneOrder: [], focusedPaneID: nil,
            updateState: .readyToRestart(version: "1.8.0")
        ).first { $0.id == "update:restart" }
        XCTAssertEqual(
            ready?.subtitle,
            "Ends any running terminal sessions",
            "the row says the price before it is taken"
        )
    }

    func testTheUpdateRowsAreTypeable() {
        let rows = CommandPaletteModel.build(
            panes: [], paneOrder: [], focusedPaneID: nil, updateState: .idle
        ).filter { $0.id.hasPrefix("update:") }
        let keywords = rows.first?.keywords ?? ""
        for typed in ["update", "upgrade", "version", "release"] {
            XCTAssertTrue(keywords.contains(typed), "someone would type \"\(typed)\"")
        }
    }

    // MARK: - The other two surfaces

    func testSettingsGeneralSpellsOutEachState() {
        let view = SettingsSurfaceView()
        view.applyUpdateState(.available(version: "1.8.0"))
        XCTAssertEqual(view.updateStatusField.stringValue, "Version 1.8.0 is available.")
        XCTAssertEqual(view.updateButton.title, "Download Update")

        view.applyUpdateState(.updating(fraction: 0.42))
        XCTAssertEqual(view.updateStatusField.stringValue, "Updating… 42%")
        XCTAssertFalse(view.updateButton.isEnabled, "nothing to press while it works")

        view.applyUpdateState(.readyToRestart(version: "1.8.0"))
        XCTAssertTrue(view.updateStatusField.stringValue.contains("running terminal sessions"))
        XCTAssertTrue(view.updateButton.isEnabled)
    }

    func testSettingsShowsTheUpdateBlockOnGeneralAndNowhereElse() {
        let view = SettingsSurfaceView()
        view.select(.general)
        XCTAssertFalse(view.updateButton.isHidden)
        XCTAssertTrue(view.subtitleField.isHidden, "General has a screen now, not a promise")
        view.select(.themes)
        XCTAssertTrue(view.updateButton.isHidden)
        XCTAssertFalse(view.subtitleField.isHidden)
    }

    func testHomesPillFollowsTheSameStates() {
        let home = HomeSurfaceView()
        home.applyUpdateState(.idle)
        XCTAssertEqual(home.updatePill.label.stringValue, "Check for updates")
        home.applyUpdateState(.available(version: "1.8.0"))
        XCTAssertEqual(home.updatePill.label.stringValue, "Download 1.8.0")
        home.applyUpdateState(.readyToRestart(version: "1.8.0"))
        XCTAssertEqual(home.updatePill.label.stringValue, "Restart to update")
    }
}
