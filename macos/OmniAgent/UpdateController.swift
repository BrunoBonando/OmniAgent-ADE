import AppKit
import Sparkle

// The app updating itself, from `dl.omni-agent.ai/releases/appcast.xml`.
//
// Sparkle drives the cycle -- fetching the feed, checking the EdDSA signature
// and the Apple code signature, mounting the disk image, swapping the bundle --
// but none of Sparkle's own windows ever appear. This class *is* the user
// driver, and everything it has to say it says through one small widget above
// the sidebar's nav rows:
//
//     Update available -> Updating... (progress) -> Update ready, restart
//
// The trick that makes that possible is holding Sparkle's reply blocks instead
// of answering them. Sparkle hands over a `reply` when it finds an update and
// again when the download is ready to install; a stock UI answers immediately
// from a modal. Here the blocks are stored and called only when the user
// presses the widget, which turns a sequence of dialogs into a strip the user
// advances at their own pace.

/// What the widget (and Settings, and Home) is showing. One value, read by
/// every surface, so there is no second copy of update state to keep in sync.
enum UpdateState: Equatable {
    case idle
    /// A user-initiated check is in flight. Background checks stay `.idle`
    /// until they find something -- a spinner nobody asked for is noise.
    case checking
    case available(version: String)
    /// Downloading, unpacking and installing, as one bar. `fraction` is nil
    /// until the server says how big the download is.
    case updating(fraction: Double?)
    /// Downloaded and verified; the swap happens on restart.
    case readyToRestart(version: String)
    case failed(String)

    /// Whether the widget shows at all. Everything else is a state worth a row.
    var isVisible: Bool { self != .idle }
}

@MainActor
final class UpdateController: NSObject {
    /// Called on every state change, on the main thread.
    var onStateChange: ((UpdateState) -> Void)?

    /// Asked before the restart is committed, answering true to go ahead.
    /// The app puts up the house ask here when terminal sessions are live,
    /// because restarting ends every one of them.
    ///
    /// This runs *before* anything is installed, which is the whole point of
    /// its being separate from `daemonStopper` below: by the time Sparkle is
    /// ready to relaunch, the bundle has already been swapped, and a "cancel"
    /// there would be a promise nobody can keep.
    var confirmRestart: ((@escaping (Bool) -> Void) -> Void) = { decide in decide(true) }

    /// How the app stops the PTY daemon, calling the passed block once it is
    /// gone. No asking happens here -- consent was taken in `confirmRestart`.
    /// Injected rather than reached for so this class knows nothing about
    /// daemons and the whole state machine stays testable.
    ///
    /// It is not optional in spirit: with no stopper set the relaunch goes
    /// ahead and the *old* daemon survives inside a replaced bundle, which is
    /// the exact failure `rebuild-app.sh` documents. `AppDelegate` always sets
    /// one; the default only keeps tests honest.
    var daemonStopper: ((@escaping () -> Void) -> Void) = { proceed in proceed() }

    private(set) var state: UpdateState = .idle {
        didSet {
            guard state != oldValue else { return }
            onStateChange?(state)
        }
    }

    /// Sparkle's "shall I download this?" reply, held until the user presses.
    private var updateFoundReply: ((SPUUserUpdateChoice) -> Void)?
    /// Sparkle's "shall I install and relaunch?" reply, held until Restart.
    private var readyToInstallReply: ((SPUUserUpdateChoice) -> Void)?
    private var expectedBytes: UInt64 = 0
    private var receivedBytes: UInt64 = 0
    private var pendingVersion: String?

    private var updater: SPUUpdater?

    /// The running app's own version, for the Settings and Home surfaces.
    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    // MARK: Lifecycle

    /// Starts Sparkle's update cycle: a check shortly after launch, then one
    /// every `SUScheduledCheckInterval` (a day). Safe to call once, from
    /// `applicationDidFinishLaunching`.
    func start() {
        let updater = SPUUpdater(
            hostBundle: .main,
            applicationBundle: .main,
            userDriver: self,
            delegate: self
        )
        do {
            try updater.start()
            self.updater = updater
        } catch {
            // Not fatal and not worth a widget: an updater that will not start
            // (an unsigned dev build, a missing feed URL) means this build
            // cannot update itself, which is normal for a local build.
            NSLog("OmniAgent: Sparkle did not start: \(error.localizedDescription)")
        }
    }

    /// The Check for Updates… command: menu, Settings, Home, spotlight.
    func checkForUpdates() {
        guard let updater, updater.canCheckForUpdates else { return }
        state = .checking
        updater.checkForUpdates()
    }

    /// The widget was pressed while an update was available: start downloading.
    func downloadUpdate() {
        guard let reply = updateFoundReply else { return }
        updateFoundReply = nil
        state = .updating(fraction: nil)
        reply(.install)
    }

    /// The widget's Restart was pressed: install and relaunch. The daemon is
    /// stopped on the way through -- see `shouldPostponeRelaunchForUpdate`.
    ///
    /// The reply is only consumed once the user has actually confirmed, so a
    /// declined restart leaves the widget exactly where it was and pressing
    /// again works.
    func restartToUpdate() {
        guard let reply = readyToInstallReply else { return }
        confirmRestart { [weak self] confirmed in
            guard let self, confirmed else { return }
            readyToInstallReply = nil
            state = .updating(fraction: 1)
            reply(.install)
        }
    }

    /// Put the widget away without giving up the update -- the held reply
    /// stays held, so pressing Check for Updates brings it straight back.
    func dismiss() {
        if case .failed = state { state = .idle }
    }

    // MARK: State machine
    //
    // The Sparkle protocol methods below are deliberately thin wrappers over
    // these. Tests drive these directly with plain values, so the whole
    // sequence can be exercised without constructing an `SUAppcastItem` or
    // running a real update.

    func foundUpdate(version: String) {
        pendingVersion = version
        state = .available(version: version)
    }

    func downloadStarted(expectedBytes: UInt64) {
        self.expectedBytes = expectedBytes
        receivedBytes = 0
        state = .updating(fraction: expectedBytes > 0 ? 0 : nil)
    }

    func downloadProgressed(byBytes bytes: UInt64) {
        receivedBytes += bytes
        guard expectedBytes > 0 else {
            state = .updating(fraction: nil)
            return
        }
        // The download is the long pole; unpacking and installing share the
        // last fifth so the bar keeps moving after the bytes stop arriving.
        let downloaded = min(1, Double(receivedBytes) / Double(expectedBytes))
        state = .updating(fraction: downloaded * 0.8)
    }

    func extractionProgressed(_ progress: Double) {
        state = .updating(fraction: 0.8 + min(1, max(0, progress)) * 0.2)
    }

    /// `reply` is Sparkle's install-and-relaunch block. It is a parameter
    /// rather than something the driver method sets separately because
    /// `restartToUpdate` refuses without one -- correctly: with no reply held
    /// there is nothing to install, and a Restart button that quietly does
    /// nothing is worse than no button.
    func readyToInstall(version: String, reply: ((SPUUserUpdateChoice) -> Void)? = nil) {
        if let reply { readyToInstallReply = reply }
        pendingVersion = version
        state = .readyToRestart(version: version)
    }

    func failed(_ message: String) {
        updateFoundReply = nil
        readyToInstallReply = nil
        state = .failed(message)
    }

    func foundNothing() {
        if state == .checking { state = .idle }
    }
}

// MARK: - SPUUserDriver

extension UpdateController: SPUUserDriver {
    func show(
        _ request: SPUUpdatePermissionRequest,
        reply: @escaping (SUUpdatePermissionResponse) -> Void
    ) {
        // Never asked in practice -- `SUEnableAutomaticChecks` in Info.plist
        // answers it -- but the protocol requires it and a silent hang here
        // would stall the whole cycle. No system profile: the feed is a static
        // file on our own host and has nothing to do with it.
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        state = .checking
    }

    func showUpdateFound(
        with appcastItem: SUAppcastItem,
        state updateState: SPUUserUpdateState,
        reply: @escaping (SPUUserUpdateChoice) -> Void
    ) {
        // Held, not answered. This is what makes the widget a widget.
        //
        // Except when Sparkle has already downloaded the update (it can resume
        // one from a previous launch): there is nothing left to ask for, so go
        // straight to the Restart state rather than offering a download that
        // has happened.
        if updateState.stage == .downloaded {
            readyToInstall(version: appcastItem.displayVersionString, reply: reply)
        } else {
            updateFoundReply = reply
            foundUpdate(version: appcastItem.displayVersionString)
        }
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {}

    func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        foundNothing()
        acknowledgement()
    }

    func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        failed(error.localizedDescription)
        acknowledgement()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        downloadStarted(expectedBytes: 0)
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        downloadStarted(expectedBytes: expectedContentLength)
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        downloadProgressed(byBytes: length)
    }

    func showDownloadDidStartExtractingUpdate() {
        extractionProgressed(0)
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        extractionProgressed(progress)
    }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        // Held. The widget now says "restart", and the user decides when --
        // which matters here more than in most apps, because the restart ends
        // every live terminal session.
        readyToInstall(version: pendingVersion ?? "", reply: reply)
    }

    func showInstallingUpdate(
        withApplicationTerminated applicationTerminated: Bool,
        retryTerminatingApplication: @escaping () -> Void
    ) {
        state = .updating(fraction: 1)
    }

    func showUpdateInstalledAndRelaunched(
        _ relaunched: Bool,
        acknowledgement: @escaping () -> Void
    ) {
        state = .idle
        acknowledgement()
    }

    func dismissUpdateInstallation() {
        // Sparkle ends the session here, including after a *successful* staged
        // install. Clearing the state then would take the Restart row off the
        // sidebar and leave the user with a downloaded update and no way to
        // apply it, so the two states that still have something to say survive.
        switch state {
        case .readyToRestart, .failed: break
        default: state = .idle
        }
    }
}

// MARK: - SPUUpdaterDelegate

extension UpdateController: SPUUpdaterDelegate {
    /// **The reason this feature is not just "call Sparkle".**
    ///
    /// The bundle being replaced contains the running PTY daemon. Leave it up
    /// and the new app finds something already listening on the socket, does
    /// not respawn (`DaemonPersistence.shouldSpawn`), and keeps talking to the
    /// *old* daemon running from an unlinked inode -- so every daemon-side
    /// change looks shipped and is not. This is the same trap
    /// `scripts/rebuild-app.sh` spends twenty lines of comment on.
    ///
    /// Postponing the relaunch is where it gets stopped: `daemonStopper` calls
    /// `installHandler` only once the daemon is actually gone. It does not ask
    /// anything -- by this point the new bundle is already in place, so there
    /// is no longer a "no" to offer. The asking happened in `confirmRestart`.
    nonisolated func updater(
        _ updater: SPUUpdater,
        shouldPostponeRelaunchForUpdate item: SUAppcastItem,
        untilInvokingBlock installHandler: @escaping () -> Void
    ) -> Bool {
        MainActor.assumeIsolated {
            daemonStopper(installHandler)
        }
        return true
    }
}
