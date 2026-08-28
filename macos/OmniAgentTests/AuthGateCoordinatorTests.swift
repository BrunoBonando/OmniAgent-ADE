import AppKit
import SwiftUI
import XCTest
@testable import OmniAgent

final class AuthGateCoordinatorTests: XCTestCase {
    /// The launch gate cannot ask the daemon whether to show itself — a
    /// settings read is a socket round trip, and this window has to be on
    /// screen before the socket is. So the signed-in flag is mirrored into
    /// `UserDefaults`, and that mirror is what the launch reads.
    func testTheSignedInFlagIsMirroredIntoDefaultsForTheLaunchDecision() throws {
        let defaults = try throwawayDefaults()
        let coordinator = AuthGateCoordinator(
            settings: SettingsStore(client: FakeSettingsClient()),
            defaults: defaults
        )
        XCTAssertTrue(AuthGate.needsSignIn(defaults), "nothing signed in yet, so the gate shows")

        resolve(coordinator, AuthGateOutcome(
            signedIn: true,
            persona: "research",
            accountEmail: "bruno@bonando.com",
            accountName: "Bruno Bonando"
        ))
        XCTAssertFalse(AuthGate.needsSignIn(defaults), "a real sign-in is what puts the gate away")

        // "Continue without signing in" is an answer for this launch only —
        // the whole difference between a login screen and a first-run screen.
        resolve(coordinator, AuthGateOutcome(signedIn: false, persona: nil, accountEmail: nil, accountName: nil))
        XCTAssertTrue(AuthGate.needsSignIn(defaults))

        resolve(coordinator, AuthGateOutcome(signedIn: true, persona: nil, accountEmail: "x@y.z", accountName: nil))
        XCTAssertFalse(AuthGate.needsSignIn(defaults))

        // Settings → Account → "Log out".
        let reset = expectation(description: "reset")
        coordinator.reset { reset.fulfill() }
        wait(for: [reset], timeout: 1)
        XCTAssertTrue(AuthGate.needsSignIn(defaults), "logging out brings the gate back next launch")
    }

    private func resolve(_ coordinator: AuthGateCoordinator, _ outcome: AuthGateOutcome) {
        let done = expectation(description: "resolve")
        coordinator.resolve(outcome) { done.fulfill() }
        wait(for: [done], timeout: 1)
    }

    /// A suite of its own, torn down after: these tests must never write the
    /// real app's defaults, which is where the real launch decision lives.
    private func throwawayDefaults() throws -> UserDefaults {
        let name = "digital.bruno.omniagent.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        return defaults
    }

    func testResolvingASignedInOutcomeWritesAllFiveKeys() {
        let client = FakeSettingsClient()
        let coordinator = AuthGateCoordinator(settings: SettingsStore(client: client))

        let expectation = expectation(description: "resolve")
        coordinator.resolve(AuthGateOutcome(
            signedIn: true,
            persona: "research",
            accountEmail: "bruno@bonando.com",
            accountName: "Bruno Bonando"
        )) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1)

        XCTAssertEqual(client.rows["auth_gate_resolved"], "true")
        XCTAssertEqual(client.rows["auth_signed_in"], "true")
        XCTAssertEqual(client.rows["auth_persona"], "research")
        XCTAssertEqual(client.rows["auth_account_email"], "bruno@bonando.com")
        XCTAssertEqual(client.rows["auth_account_name"], "Bruno Bonando")
    }

    func testResolvingASkipWritesEmptyStringsForPersonaAndAccount() {
        let client = FakeSettingsClient()
        let coordinator = AuthGateCoordinator(settings: SettingsStore(client: client))

        let expectation = expectation(description: "resolve")
        coordinator.resolve(AuthGateOutcome(signedIn: false, persona: nil, accountEmail: nil, accountName: nil)) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1)

        XCTAssertEqual(client.rows["auth_signed_in"], "false")
        XCTAssertEqual(client.rows["auth_persona"], "")
        XCTAssertEqual(client.rows["auth_account_email"], "")
        XCTAssertEqual(client.rows["auth_account_name"], "")
    }

    func testResetClearsAllFiveKeysToTheSignedOutUnresolvedShape() {
        let client = FakeSettingsClient(rows: [
            "auth_gate_resolved": "true", "auth_signed_in": "true", "auth_persona": "student",
            "auth_account_email": "bruno@bonando.com", "auth_account_name": "Bruno Bonando",
        ])
        let coordinator = AuthGateCoordinator(settings: SettingsStore(client: client))

        let expectation = expectation(description: "reset")
        coordinator.reset { expectation.fulfill() }
        wait(for: [expectation], timeout: 1)

        XCTAssertEqual(client.rows["auth_gate_resolved"], "false")
        XCTAssertEqual(client.rows["auth_signed_in"], "false")
        XCTAssertEqual(client.rows["auth_persona"], "")
        XCTAssertEqual(client.rows["auth_account_email"], "")
        XCTAssertEqual(client.rows["auth_account_name"], "")
    }

    func testSummaryPrefersTheRealAccountRows() {
        let client = FakeSettingsClient(rows: [
            "auth_signed_in": "true", "auth_persona": "devops-infra",
            "auth_account_email": "bruno@bonando.com", "auth_account_name": "Bruno Bonando",
        ])
        let coordinator = AuthGateCoordinator(settings: SettingsStore(client: client))

        let expectation = expectation(description: "summary")
        coordinator.summary { summary in
            XCTAssertEqual(summary, "Bruno Bonando — DevOps & Infrastructure.")
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1)
    }

    func testSummaryFallsBackToTheLegacyIdentityWhenNoAccountRowsExist() {
        let client = FakeSettingsClient(rows: ["auth_signed_in": "true", "auth_persona": "devops-infra"])
        let coordinator = AuthGateCoordinator(settings: SettingsStore(client: client))

        let expectation = expectation(description: "summary")
        coordinator.summary { summary in
            XCTAssertEqual(summary, "Bruno Bonando — DevOps & Infrastructure.")
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1)
    }
}

// MARK: - View model

/// Answers every exchange with a canned result and records what it was
/// asked to redeem — the `AuthSigning` seam's test double, so no view-model
/// test ever touches URLSession or opens a browser.
private final class StubAuthSigning: AuthSigning {
    struct Exchange: Equatable {
        let code: String
        let codeVerifier: String
        let nonce: String
    }

    let result: Result<AuthUser, AuthError>
    private(set) var exchanges: [Exchange] = []

    init(result: Result<AuthUser, AuthError>) {
        self.result = result
    }

    /// Never opened by a test — `signInWithApple` (the one method that would
    /// hand this to a browser) is exactly the part these tests do not drive.
    func appleAuthorizeURL(state: String, nonce: String) -> URL {
        URL(string: "https://appleid.apple.com/auth/authorize?state=\(state)&nonce=\(nonce)")!
    }

    func loginWithApple(code: String, codeVerifier: String, nonce: String) async throws -> AuthUser {
        exchanges.append(Exchange(code: code, codeVerifier: codeVerifier, nonce: nonce))
        return try result.get()
    }
}

/// Records the view model's `isBusy` at the moment the network call is in
/// flight — the only way to observe the flag's rising edge from outside.
private final class BusyProbeAuthSigning: AuthSigning {
    var model: AuthGateViewModel?
    private(set) var busyDuringExchange: Bool?
    private let user: AuthUser

    init(user: AuthUser) {
        self.user = user
    }

    func appleAuthorizeURL(state: String, nonce: String) -> URL {
        URL(string: "https://appleid.apple.com/auth/authorize")!
    }

    func loginWithApple(code: String, codeVerifier: String, nonce: String) async throws -> AuthUser {
        busyDuringExchange = await MainActor.run { [model] in model?.isBusy }
        return user
    }
}

final class AuthGateViewModelTests: XCTestCase {
    private func user(
        email: String = "bruno@bonando.com",
        firstName: String? = nil,
        lastName: String? = nil,
        name: String? = "Bruno Bonando"
    ) -> AuthUser {
        AuthUser(
            id: "user-1",
            email: email,
            firstName: firstName,
            lastName: lastName,
            name: name,
            role: "user",
            authProvider: "password",
            emailVerified: true
        )
    }

    /// The `omniagent://auth/apple?…` URL Core bounces the browser into.
    private func callback(code: String? = nil, state: String? = nil, error: String? = nil) -> URL {
        var components = URLComponents(string: "omniagent://auth/apple")!
        components.queryItems = [
            code.map { URLQueryItem(name: "code", value: $0) },
            error.map { URLQueryItem(name: "error", value: $0) },
            state.map { URLQueryItem(name: "state", value: $0) },
        ].compactMap { $0 }
        return components.url!
    }

    func testSendingSkipLoginResolvesAndInvokesOnResolvedExactlyOnce() {
        let model = AuthGateViewModel(signer: StubAuthSigning(result: .failure(.sessionExpired)))
        var outcomes: [AuthGateOutcome] = []
        model.onResolved = { outcomes.append($0) }

        model.send(.skipLogin)

        XCTAssertEqual(model.state.phase, .resolved)
        XCTAssertEqual(outcomes, [AuthGateOutcome(signedIn: false, persona: nil, accountEmail: nil, accountName: nil)])
    }

    /// PKCE's whole job is that the exchange call can prove it belongs to
    /// the same attempt that opened the browser — so the challenge has to be
    /// the real S256 one Core will recompute, pinned here to RFC 7636's
    /// published vector rather than to whatever this implementation emits.
    func testThePKCEChallengeIsRFC7636sS256Vector() {
        XCTAssertEqual(
            PKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
            "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
        )

        let pkce = PKCE()
        XCTAssertEqual(pkce.verifier.count, 43, "32 random bytes, base64url, unpadded")
        XCTAssertEqual(pkce.state, PKCE.challenge(for: pkce.verifier), "state is the verifier's challenge")
        XCTAssertEqual(pkce.nonce.count, 32, "16 random bytes as hex")
        XCTAssertNil(pkce.nonce.rangeOfCharacter(from: CharacterSet(charactersIn: "0123456789abcdef").inverted))
        // base64url, so nothing that would need re-encoding in a query.
        let base64URL = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        XCTAssertNil(pkce.verifier.rangeOfCharacter(from: base64URL.inverted), "got: \(pkce.verifier)")
        XCTAssertNil(pkce.state.rangeOfCharacter(from: base64URL.inverted), "got: \(pkce.state)")
        // And a secret per attempt, never a constant.
        XCTAssertNotEqual(PKCE().verifier, pkce.verifier)
    }

    @MainActor
    func testAMatchingCallbackRedeemsTheCodeWithThisAttemptsVerifierAndNonce() async {
        let stub = StubAuthSigning(result: .success(user()))
        let model = AuthGateViewModel(signer: stub)
        let pkce = model.pkce
        var outcomes: [AuthGateOutcome] = []
        model.onResolved = { outcomes.append($0) }

        await model.handleAppleCallback(callback(code: "one-time-code", state: pkce.state))

        XCTAssertEqual(stub.exchanges, [StubAuthSigning.Exchange(
            code: "one-time-code",
            codeVerifier: pkce.verifier,
            nonce: pkce.nonce
        )])
        XCTAssertEqual(model.state.phase, .personalize)
        XCTAssertEqual(model.state.accountEmail, "bruno@bonando.com")
        XCTAssertEqual(model.state.accountName, "Bruno Bonando")
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.isBusy)
        XCTAssertTrue(outcomes.isEmpty, "personalize is not resolved yet")

        model.send(.answerSelected(persona: "research"))
        XCTAssertEqual(outcomes, [AuthGateOutcome(
            signedIn: true,
            persona: "research",
            accountEmail: "bruno@bonando.com",
            accountName: "Bruno Bonando"
        )])
    }

    @MainActor
    func testSignInDerivesTheDisplayNameFromFirstAndLastNameWhenNameIsAbsent() async {
        let stub = StubAuthSigning(result: .success(user(firstName: "Ada", lastName: "Lovelace", name: nil)))
        let model = AuthGateViewModel(signer: stub)

        await model.handleAppleCallback(callback(code: "c", state: model.pkce.state))

        XCTAssertEqual(model.state.accountName, "Ada Lovelace")
    }

    /// A callback whose `state` is not this attempt's — a leftover from an
    /// abandoned attempt, or something another process on the Mac
    /// fabricated. The code must never be redeemed.
    @MainActor
    func testACallbackWithTheWrongStateIsRefusedWithoutTouchingTheServer() async {
        let stub = StubAuthSigning(result: .success(user()))
        let model = AuthGateViewModel(signer: stub)

        await model.handleAppleCallback(callback(code: "stolen-code", state: "someone-elses-state"))

        XCTAssertTrue(stub.exchanges.isEmpty, "a mismatched state must never reach the exchange")
        XCTAssertEqual(model.errorMessage, "Sign-in response didn't match this app — try again.")
        XCTAssertEqual(model.state.phase, .login)
        XCTAssertFalse(model.isBusy)
    }

    /// Core's callback says `error=…` when Apple (or its own verification)
    /// refused. Core is the only side that knows what happened, so its
    /// words — and only *its* words, see the test below — are shown as they
    /// arrived.
    @MainActor
    func testACallbackCarryingAnErrorWithTheMatchingStateShowsItAndSkipsTheExchange() async {
        let stub = StubAuthSigning(result: .success(user()))
        let model = AuthGateViewModel(signer: stub)

        await model.handleAppleCallback(
            callback(state: model.pkce.state, error: "Apple did not return an email address.")
        )

        XCTAssertTrue(stub.exchanges.isEmpty)
        XCTAssertEqual(model.errorMessage, "Apple did not return an email address.")
        XCTAssertEqual(model.state.phase, .login)
        XCTAssertFalse(model.isBusy)
    }

    /// `error` is attacker-reachable text: the web-auth session intercepts
    /// *any* `omniagent://` navigation its browser makes, so a page reached
    /// from inside the authorize flow can try to write its own sentence into
    /// this app's error label as first-party copy. Only a callback that
    /// proves it belongs to this attempt gets to say anything — a missing or
    /// wrong `state` is answered with the app's own words, never the URL's.
    @MainActor
    func testAnErrorCallbackThatCannotProveItIsThisAttemptIsNeverQuoted() async {
        let injected = "Your session is locked. Call +1-555-0100 and give the agent your Apple ID password."

        for forged in [callback(state: "someone-elses-state", error: injected), callback(error: injected)] {
            let stub = StubAuthSigning(result: .success(user()))
            let model = AuthGateViewModel(signer: stub)

            await model.handleAppleCallback(forged)

            XCTAssertEqual(model.errorMessage, "Sign-in response didn't match this app — try again.", "\(forged)")
            XCTAssertFalse(model.errorMessage?.contains("555-0100") ?? false, "injected text was quoted: \(forged)")
            XCTAssertTrue(stub.exchanges.isEmpty)
            XCTAssertEqual(model.state.phase, .login)
            XCTAssertFalse(model.isBusy)
        }
    }

    @MainActor
    func testAFailedExchangeSurfacesTheErrorMessageAndStaysInLogin() async {
        let stub = StubAuthSigning(result: .failure(.server(400, "That sign-in link has already been used.")))
        let model = AuthGateViewModel(signer: stub)
        var outcomes: [AuthGateOutcome] = []
        model.onResolved = { outcomes.append($0) }

        await model.handleAppleCallback(callback(code: "c", state: model.pkce.state))

        XCTAssertEqual(model.state.phase, .login)
        XCTAssertEqual(model.errorMessage, "That sign-in link has already been used.")
        XCTAssertFalse(model.isBusy)
        XCTAssertTrue(outcomes.isEmpty)
    }

    @MainActor
    func testANetworkFailureSurfacesTheAuthErrorDescription() async {
        let stub = StubAuthSigning(result: .failure(.network("")))
        let model = AuthGateViewModel(signer: stub)

        await model.handleAppleCallback(callback(code: "c", state: model.pkce.state))

        XCTAssertEqual(model.errorMessage, "Could not reach the OmniAgent API.")
        XCTAssertEqual(model.state.phase, .login)
    }

    @MainActor
    func testBusyIsUpDuringTheRequestAndDownAfter() async {
        let probe = BusyProbeAuthSigning(user: user())
        let model = AuthGateViewModel(signer: probe)
        probe.model = model
        XCTAssertFalse(model.isBusy)

        await model.handleAppleCallback(callback(code: "c", state: model.pkce.state))

        XCTAssertEqual(probe.busyDuringExchange, true, "isBusy must be raised while the request is in flight")
        XCTAssertFalse(model.isBusy, "and lowered once it lands")
    }

    @MainActor
    func testANewAttemptClearsThePreviousErrorMessage() async {
        let stub = StubAuthSigning(result: .success(user()))
        let model = AuthGateViewModel(signer: stub)

        await model.handleAppleCallback(callback(code: "c", state: "wrong"))
        XCTAssertNotNil(model.errorMessage)

        await model.handleAppleCallback(callback(code: "c", state: model.pkce.state))
        XCTAssertNil(model.errorMessage, "the retry's own attempt must clear the last one's message")
        XCTAssertEqual(model.state.phase, .personalize)
    }
}

// MARK: - Offscreen render (repo convention: verify AppKit/SwiftUI layout by
// rendering the real view to a PNG from a test — screen capture is
// unavailable in background sessions). Pass the output path via
// `TEST_RUNNER_AUTH_GATE_RENDER_PATH=...` on the xcodebuild command line
// (xcodebuild strips the `TEST_RUNNER_` prefix before handing the variable
// to the test host); without it the PNG lands in NSTemporaryDirectory().

final class AuthGateRenderTests: XCTestCase {
    /// Hosts the login-phase `AuthGateContentView` in an `NSHostingView` at
    /// 1000x620, renders it offscreen, and writes the PNG for a human (or a
    /// pixel check) to look at. The in-test assertions only guard against
    /// unambiguous catastrophes: a zero-size render, or a screen that painted
    /// as one flat sheet of nothing.
    @MainActor
    func testLoginScreenRendersToPNG() throws {
        let model = AuthGateViewModel(signer: StubAuthSigning(result: .failure(.network(""))))
        XCTAssertEqual(model.state.phase, .login, "the reducer's initial phase is the sign-in screen")

        let hosting = NSHostingView(rootView: AuthGateContentView(model: model))
        hosting.frame = NSRect(x: 0, y: 0, width: 1000, height: 620)

        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        // Ordering the window in is what fires SwiftUI's `onAppear`; the
        // spin then lets the screen's single 0.45s appear animation finish
        // so nothing is captured at opacity 0.
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        window.displayIfNeeded()

        let rep = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        XCTAssertGreaterThanOrEqual(rep.pixelsWide, 1000, "render must not be zero-size")
        XCTAssertGreaterThanOrEqual(rep.pixelsHigh, 620, "render must not be zero-size")

        // A screen that failed to lay out paints as one flat colour; the
        // real sign-in screen has a story panel, gradient blobs, a card and
        // text, so a coarse sample grid must see plenty of distinct colours.
        var seen = Set<String>()
        for x in stride(from: 10, to: rep.pixelsWide, by: max(1, rep.pixelsWide / 20)) {
            for y in stride(from: 10, to: rep.pixelsHigh, by: max(1, rep.pixelsHigh / 20)) {
                if let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) {
                    seen.insert(String(
                        format: "%.3f/%.3f/%.3f",
                        color.redComponent, color.greenComponent, color.blueComponent
                    ))
                }
            }
        }
        XCTAssertGreaterThan(seen.count, 5, "render is a flat sheet — the screen did not lay out")

        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        let path = ProcessInfo.processInfo.environment["AUTH_GATE_RENDER_PATH"]
            ?? (NSTemporaryDirectory() as NSString).appendingPathComponent("auth-gate-login.png")
        try png.write(to: URL(fileURLWithPath: path))
    }
}

// MARK: - Launch window shape

/// The gate is the app's front door now: `present(over: nil)` is a window of
/// its own, opened before the workspace window exists. Two things that shape
/// has to get right which a sheet never had to — where it opens, and that
/// the screen it hosts runs to the window's own edges.
final class AuthGateWindowTests: XCTestCase {
    @MainActor
    func testTheLaunchWindowOpensAtTheCentreOfTheScreen() throws {
        let window = try presentLaunchWindow()
        let screen = try XCTUnwrap(window.screen ?? NSScreen.main)

        // The size has to be the screen's own before the position can mean
        // anything: `NSWindow.center()` used to run while the window was
        // still its default size, so the login screen grew out of a corner
        // of the centre point instead of standing on it.
        XCTAssertEqual(window.frame.width, AuthGateContentView.sheetSize.width, accuracy: 0.5)
        XCTAssertEqual(window.frame.height, AuthGateContentView.sheetSize.height, accuracy: 0.5)
        XCTAssertEqual(window.frame.midX, screen.visibleFrame.midX, accuracy: 1)
        XCTAssertEqual(window.frame.midY, screen.visibleFrame.midY, accuracy: 1)
    }

    /// The window is `fullSizeContentView`, but SwiftUI still insets its
    /// layout by the title bar's safe area unless told not to — which showed
    /// up as a black band across the top of the sign-in screen, exactly as
    /// wide as a title bar. Two ways to see it: the content view grew by the
    /// inset, and the story panel's glow stopped short of the top edge.
    @MainActor
    func testTheScreenPaintsToTheWindowsTopEdgeWithNoTitleBarBand() throws {
        let window = try presentLaunchWindow()
        let content = try XCTUnwrap(window.contentView)
        XCTAssertEqual(
            content.bounds.height,
            AuthGateContentView.sheetSize.height,
            accuracy: 0.5,
            "a safe-area inset would make the content taller than the screen it holds"
        )

        let frameView = content.superview ?? content
        let rep = try XCTUnwrap(frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds))
        frameView.cacheDisplay(in: frameView.bounds, to: rep)
        let scale = max(1, rep.pixelsWide / Int(frameView.bounds.width))
        let top = try XCTUnwrap(rep.colorAt(x: 60 * scale, y: scale)?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(
            top.blueComponent - top.redComponent,
            0.05,
            "the story panel's indigo glow must reach the window's top edge, not a band of window background"
        )

        if let png = rep.representation(using: .png, properties: [:]) {
            let path = ProcessInfo.processInfo.environment["AUTH_GATE_WINDOW_RENDER_PATH"]
                ?? (NSTemporaryDirectory() as NSString).appendingPathComponent("auth-gate-window.png")
            try png.write(to: URL(fileURLWithPath: path))
        }
    }

    /// The real controller, presented the way the launch presents it. The
    /// window is ordered in (SwiftUI lays out and fires `onAppear` only for
    /// a window that is on screen) and ordered out again on teardown.
    @MainActor
    private func presentLaunchWindow() throws -> NSWindow {
        let controller = AuthGateWindowController(
            coordinator: AuthGateCoordinator(settings: SettingsStore(client: FakeSettingsClient()))
        )
        controller.present(over: nil)
        let window = try XCTUnwrap(controller.sheetWindow)
        addTeardownBlock { @MainActor in window.orderOut(nil) }
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        return window
    }
}
