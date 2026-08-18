import AppKit
import SwiftUI
import XCTest
@testable import OmniAgent

final class AuthGateCoordinatorTests: XCTestCase {
    func testNeedsPresentingIsTrueWhenUnresolvedAndFalseWhenResolved() {
        let unresolved = AuthGateCoordinator(settings: SettingsStore(client: FakeSettingsClient()))
        let unresolvedExpectation = expectation(description: "unresolved")
        unresolved.needsPresenting { needed in
            XCTAssertTrue(needed)
            unresolvedExpectation.fulfill()
        }
        wait(for: [unresolvedExpectation], timeout: 1)

        let resolved = AuthGateCoordinator(settings: SettingsStore(client: FakeSettingsClient(rows: ["auth_gate_resolved": "true"])))
        let resolvedExpectation = expectation(description: "resolved")
        resolved.needsPresenting { needed in
            XCTAssertFalse(needed)
            resolvedExpectation.fulfill()
        }
        wait(for: [resolvedExpectation], timeout: 1)
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

/// Answers every sign-in with a canned result — the `AuthSigning` seam's
/// test double, so no view-model test ever touches URLSession.
private struct StubAuthSigning: AuthSigning {
    var result: Result<AuthUser, AuthError>

    func login(email: String, password: String) async throws -> AuthUser {
        try result.get()
    }

    func loginWithApple(identityToken: String, givenName: String?, familyName: String?) async throws -> AuthUser {
        try result.get()
    }
}

/// Records the view model's `isBusy` at the moment the network call is in
/// flight — the only way to observe the flag's rising edge from outside.
private final class BusyProbeAuthSigning: AuthSigning {
    var model: AuthGateViewModel?
    private(set) var busyDuringLogin: Bool?
    private let user: AuthUser

    init(user: AuthUser) {
        self.user = user
    }

    func login(email: String, password: String) async throws -> AuthUser {
        busyDuringLogin = await MainActor.run { [model] in model?.isBusy }
        return user
    }

    func loginWithApple(identityToken: String, givenName: String?, familyName: String?) async throws -> AuthUser {
        user
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

    func testSendingSkipLoginResolvesAndInvokesOnResolvedExactlyOnce() {
        let model = AuthGateViewModel(signer: StubAuthSigning(result: .failure(.sessionExpired)))
        var outcomes: [AuthGateOutcome] = []
        model.onResolved = { outcomes.append($0) }

        model.send(.skipLogin)

        XCTAssertEqual(model.state.phase, .resolved)
        XCTAssertEqual(outcomes, [AuthGateOutcome(signedIn: false, persona: nil, accountEmail: nil, accountName: nil)])
    }

    @MainActor
    func testSuccessfulSignInDispatchesSignedInAndLandsInPersonalize() async {
        let model = AuthGateViewModel(signer: StubAuthSigning(result: .success(user())))
        var outcomes: [AuthGateOutcome] = []
        model.onResolved = { outcomes.append($0) }

        await model.signIn(email: "bruno@bonando.com", password: "hunter2")

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

        await model.signIn(email: "bruno@bonando.com", password: "hunter2")

        XCTAssertEqual(model.state.accountName, "Ada Lovelace")
    }

    @MainActor
    func testFailedSignInSurfacesTheErrorMessageAndStaysInLogin() async {
        let stub = StubAuthSigning(result: .failure(.invalidCredentials("Incorrect email or password")))
        let model = AuthGateViewModel(signer: stub)
        var outcomes: [AuthGateOutcome] = []
        model.onResolved = { outcomes.append($0) }

        await model.signIn(email: "bruno@bonando.com", password: "wrong")

        XCTAssertEqual(model.state.phase, .login)
        XCTAssertEqual(model.errorMessage, "Incorrect email or password")
        XCTAssertFalse(model.isBusy)
        XCTAssertTrue(outcomes.isEmpty)
    }

    @MainActor
    func testANetworkFailureSurfacesTheAuthErrorDescription() async {
        let stub = StubAuthSigning(result: .failure(.network("")))
        let model = AuthGateViewModel(signer: stub)

        await model.signIn(email: "bruno@bonando.com", password: "pw")

        XCTAssertEqual(model.errorMessage, "Could not reach the OmniAgent API.")
        XCTAssertEqual(model.state.phase, .login)
    }

    @MainActor
    func testBusyIsUpDuringTheRequestAndDownAfter() async {
        let probe = BusyProbeAuthSigning(user: user())
        let model = AuthGateViewModel(signer: probe)
        probe.model = model
        XCTAssertFalse(model.isBusy)

        await model.signIn(email: "bruno@bonando.com", password: "hunter2")

        XCTAssertEqual(probe.busyDuringLogin, true, "isBusy must be raised while the request is in flight")
        XCTAssertFalse(model.isBusy, "and lowered once it lands")
    }

    @MainActor
    func testANewAttemptClearsThePreviousErrorMessage() async {
        let model = AuthGateViewModel(signer: StubAuthSigning(result: .failure(.invalidCredentials("nope"))))
        await model.signIn(email: "a@b.com", password: "x")
        XCTAssertEqual(model.errorMessage, "nope")

        let retry = AuthGateViewModel(signer: StubAuthSigning(result: .success(user())))
        await retry.signIn(email: "a@b.com", password: "x")
        XCTAssertNil(retry.errorMessage)
    }

    func testAppleSignInAvailabilityTracksTheCodeSignaturesEntitlement() {
        // The test host is not signed with `com.apple.developer.applesignin`
        // — the exact state every current app build ships in — so the probe
        // must say no, and the default-constructed view model must hide the
        // Apple button (its only working outcome was ASAuthorizationError
        // 1000).
        XCTAssertFalse(AppleSignInCapability.probeEntitlement())
        let model = AuthGateViewModel(signer: StubAuthSigning(result: .failure(.sessionExpired)))
        XCTAssertFalse(model.appleSignInAvailable)

        // An entitled build (injected here; real once the Developer ID
        // provisioning profile carrying the entitlement lands) shows the
        // button again with no further code change.
        let entitled = AuthGateViewModel(
            signer: StubAuthSigning(result: .failure(.sessionExpired)),
            appleSignInAvailable: true
        )
        XCTAssertTrue(entitled.appleSignInAvailable)
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
