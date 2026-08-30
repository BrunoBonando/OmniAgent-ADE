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

        // Signing in is the only way past the gate, so a resolution that
        // carries no sign-in — the flow was dismissed, or it failed — must
        // leave the mirror false and the gate up again next launch. There is
        // no "continue without signing in" answer to record.
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

    /// `AuthGateWindowController` calls this the moment `AuthGateViewModel`
    /// reports a successful sign-in — before the persona step, unlike
    /// `resolve`. A user who quits between "Continue with GitHub" and
    /// picking a persona must not be asked to sign in again next launch.
    func testMarkSignedInPutsTheGateAwayBeforeTheFlowFinishes() throws {
        let defaults = try throwawayDefaults()
        let coordinator = AuthGateCoordinator(
            settings: SettingsStore(client: FakeSettingsClient()),
            defaults: defaults
        )
        XCTAssertTrue(AuthGate.needsSignIn(defaults))

        coordinator.markSignedIn()
        XCTAssertFalse(
            AuthGate.needsSignIn(defaults),
            "a successful sign-in must not wait for the persona step to put the gate away"
        )
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

    func testResolvingASignedInOutcomeWritesAllSevenKeys() throws {
        let client = FakeSettingsClient()
        let coordinator = AuthGateCoordinator(settings: SettingsStore(client: client), defaults: try throwawayDefaults())

        let expectation = expectation(description: "resolve")
        coordinator.resolve(AuthGateOutcome(
            signedIn: true,
            persona: "research",
            accountEmail: "bruno@bonando.com",
            accountName: "Bruno Bonando",
            githubLogin: "brunobonando",
            accountPicture: "https://cdn.test.invalid/bruno.png"
        )) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1)

        XCTAssertEqual(client.rows["auth_gate_resolved"], "true")
        XCTAssertEqual(client.rows["auth_signed_in"], "true")
        XCTAssertEqual(client.rows["auth_persona"], "research")
        XCTAssertEqual(client.rows["auth_account_email"], "bruno@bonando.com")
        XCTAssertEqual(client.rows["auth_account_name"], "Bruno Bonando")
        XCTAssertEqual(client.rows["auth_github_login"], "brunobonando")
        XCTAssertEqual(client.rows["auth_account_picture"], "https://cdn.test.invalid/bruno.png")
    }

    /// `resolve` persists whatever `AuthGateOutcome` it is handed — nil
    /// fields become empty strings, not unwritten rows. This exact
    /// signed-out shape no longer comes out of the reducer (the mandatory
    /// sign-in gate has no skip path), but `resolve`'s own nil-to-""
    /// contract is worth pinning independently of what can reach it.
    func testResolvingAnOutcomeWithNilFieldsWritesEmptyStringsForPersonaAndAccount() throws {
        let client = FakeSettingsClient()
        let coordinator = AuthGateCoordinator(settings: SettingsStore(client: client), defaults: try throwawayDefaults())

        let expectation = expectation(description: "resolve")
        coordinator.resolve(AuthGateOutcome(signedIn: false, persona: nil, accountEmail: nil, accountName: nil)) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1)

        XCTAssertEqual(client.rows["auth_signed_in"], "false")
        XCTAssertEqual(client.rows["auth_persona"], "")
        XCTAssertEqual(client.rows["auth_account_email"], "")
        XCTAssertEqual(client.rows["auth_account_name"], "")
        XCTAssertEqual(client.rows["auth_github_login"], "")
        XCTAssertEqual(client.rows["auth_account_picture"], "", "an outcome with no picture writes no picture")
    }

    /// Log-out clears the mirror, the gate flags and the account identity —
    /// but **not** the persona: it belongs to the account and comes back
    /// with the account's data dir the next time it signs in (2026-08-30
    /// spec, "Logout" step 3).
    func testResetClearsTheAccountRowsButKeepsThePersona() throws {
        let client = FakeSettingsClient(rows: [
            "auth_gate_resolved": "true", "auth_signed_in": "true", "auth_persona": "student",
            "auth_account_email": "bruno@bonando.com", "auth_account_name": "Bruno Bonando",
            "auth_github_login": "brunobonando", "auth_account_picture": "https://cdn.test.invalid/bruno.png",
        ])
        let coordinator = AuthGateCoordinator(settings: SettingsStore(client: client), defaults: try throwawayDefaults())

        let expectation = expectation(description: "reset")
        coordinator.reset { expectation.fulfill() }
        wait(for: [expectation], timeout: 1)

        XCTAssertEqual(client.rows["auth_gate_resolved"], "false")
        XCTAssertEqual(client.rows["auth_signed_in"], "false")
        XCTAssertEqual(client.rows["auth_persona"], "student", "the persona is the account's, not the session's")
        XCTAssertFalse(client.setCalls.contains { $0.key == "auth_persona" }, "and is not even rewritten")
        XCTAssertEqual(client.rows["auth_account_email"], "")
        XCTAssertEqual(client.rows["auth_account_name"], "")
        XCTAssertEqual(client.rows["auth_github_login"], "", "a log-out unlinks GitHub locally too")
        XCTAssertEqual(client.rows["auth_account_picture"], "", "and takes the avatar with it")
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

    /// The GitHub row's mark: bundled as a base64 PNG (no bundle resource,
    /// no new Swift file) rather than an SF Symbol — SF Symbols has none for
    /// GitHub. `isTemplate` is what makes it tint like `applelogo` does, and
    /// a roughly square mark keeps it visually balanced beside the SF
    /// Symbol on the Apple row above it.
    func testGitHubMarkDecodesAsASquareTemplateImage() throws {
        let image = try XCTUnwrap(GitHubMark.image, "the bundled GitHub mark must decode")
        XCTAssertTrue(image.isTemplate, "isTemplate is what lets it tint like applelogo")

        let size = image.size
        XCTAssertGreaterThan(size.width, 0)
        XCTAssertGreaterThan(size.height, 0)
        XCTAssertEqual(size.width / size.height, 1, accuracy: 0.1, "the mark should be roughly square")

        // Guards the actual regression: an earlier source PNG was
        // black-on-white with no alpha channel, so the template render (which
        // is alpha-driven) filled in as a solid white square. Reading the
        // decoded bitmap's own alpha catches that without needing to draw
        // the image into a context (and its flip-vs-not ambiguity).
        let bitmap = try XCTUnwrap(
            image.representations.compactMap { $0 as? NSBitmapImageRep }.first,
            "expected a bitmap representation from the decoded PNG"
        )
        func alpha(_ x: Int, _ y: Int) -> CGFloat {
            bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0
        }
        XCTAssertLessThan(alpha(1, 1), 0.1, "corner must be transparent background, not a filled square")

        // Not literally pixel (width/2, height/2): the octocat glyph's own
        // negative space (between its two arms) sits at the image's exact
        // geometric centre, so that pixel is transparent by design — sampled
        // and confirmed against the decoded asset. The head just above it is
        // the nearest solid, unambiguously "middle" part of the mark.
        let midX = bitmap.pixelsWide / 2
        let headY = bitmap.pixelsHigh / 2 - (bitmap.pixelsHigh / 4)
        XCTAssertGreaterThan(alpha(midX, headY), 0.5, "the glyph itself must be opaque, not just the background")
    }
}

// MARK: - View model

/// Answers every exchange with a canned result and records what it was
/// asked to redeem — the `AuthSigning` seam's test double, so no view-model
/// test ever touches URLSession or opens a browser.
private final class StubAuthSigning: AuthSigning {
    struct Exchange: Equatable {
        let provider: AuthProvider
        let code: String
        let codeVerifier: String
        let nonce: String
    }

    struct Link: Equatable {
        let state: String
        let nonce: String
    }

    let result: Result<AuthUser, AuthError>
    private(set) var exchanges: [Exchange] = []
    private(set) var links: [Link] = []
    private(set) var disconnects = 0
    private(set) var restores = 0
    /// What the link/unlink calls answer with; `nil` is success.
    var linkFailure: AuthError?
    /// What `restoreSession()` answers with; `nil` is success, and a success
    /// also mints the token a bearer call needs.
    var restoreFailure: AuthError?
    var accessToken: String?

    init(result: Result<AuthUser, AuthError>, accessToken: String? = "tok") {
        self.result = result
        self.accessToken = accessToken
    }

    /// Never opened by a test — `signIn(with:)` (the one method that would
    /// hand this to a browser) is exactly the part these tests do not drive.
    func authorizeURL(for provider: AuthProvider, state: String, nonce: String) -> URL {
        URL(string: "https://example.invalid/\(provider.rawValue)?state=\(state)&nonce=\(nonce)")!
    }

    func login(with provider: AuthProvider, code: String, codeVerifier: String, nonce: String) async throws -> AuthUser {
        exchanges.append(Exchange(provider: provider, code: code, codeVerifier: codeVerifier, nonce: nonce))
        return try result.get()
    }

    func linkGitHub(state: String, nonce: String) async throws {
        if let linkFailure { throw linkFailure }
        links.append(Link(state: state, nonce: nonce))
    }

    func disconnectGitHub() async throws {
        if let linkFailure { throw linkFailure }
        disconnects += 1
    }

    func restoreSession() async throws -> AuthUser {
        restores += 1
        if let restoreFailure { throw restoreFailure }
        accessToken = "refreshed"
        return try result.get()
    }
}

/// Records the view model's `isBusy` at the moment the network call is in
/// flight — the only way to observe the flag's rising edge from outside.
private final class BusyProbeAuthSigning: AuthSigning {
    var model: AuthGateViewModel?
    private(set) var busyDuringExchange: Bool?
    private let user: AuthUser
    var accessToken: String? = "tok"

    init(user: AuthUser) {
        self.user = user
    }

    func authorizeURL(for provider: AuthProvider, state: String, nonce: String) -> URL {
        URL(string: "https://example.invalid/\(provider.rawValue)")!
    }

    func login(with provider: AuthProvider, code: String, codeVerifier: String, nonce: String) async throws -> AuthUser {
        busyDuringExchange = await MainActor.run { [model] in model?.isBusy }
        return user
    }

    func linkGitHub(state: String, nonce: String) async throws {}
    func disconnectGitHub() async throws {}
    func restoreSession() async throws -> AuthUser { user }
}

final class AuthGateViewModelTests: XCTestCase {
    private func user(
        email: String = "bruno@bonando.com",
        firstName: String? = nil,
        lastName: String? = nil,
        name: String? = "Bruno Bonando",
        githubLogin: String? = nil,
        picture: String? = nil
    ) -> AuthUser {
        AuthUser(
            id: "user-1",
            email: email,
            firstName: firstName,
            lastName: lastName,
            name: name,
            picture: picture,
            role: "user",
            authProvider: "password",
            emailVerified: true,
            githubLogin: githubLogin
        )
    }

    /// The `omniagent://auth/<provider>?…` URL Core bounces the browser into.
    private func callback(
        code: String? = nil,
        state: String? = nil,
        error: String? = nil,
        provider: AuthProvider = .apple
    ) -> URL {
        var components = URLComponents(string: "omniagent://auth/\(provider.rawValue)")!
        components.queryItems = [
            code.map { URLQueryItem(name: "code", value: $0) },
            error.map { URLQueryItem(name: "error", value: $0) },
            state.map { URLQueryItem(name: "state", value: $0) },
        ].compactMap { $0 }
        return components.url!
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

        await model.handleCallback(callback(code: "one-time-code", state: pkce.state))

        XCTAssertEqual(stub.exchanges, [StubAuthSigning.Exchange(
            provider: .apple,
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

    /// The bug this guards: quitting between a successful sign-in and the
    /// persona step used to leave the launch gate's own "am I signed in"
    /// mirror unset, so the *next* launch asked the user to sign in again
    /// despite the account already being connected. `onSignedIn` — which
    /// `AuthGateWindowController` wires straight to
    /// `AuthGateCoordinator.markSignedIn()` — must fire the moment sign-in
    /// succeeds, not wait for the persona step, and must not fire again on
    /// the persona answer.
    @MainActor
    func testOnSignedInFiresOnceRightAwayNotAfterThePersonaStep() async {
        let stub = StubAuthSigning(result: .success(user()))
        let model = AuthGateViewModel(signer: stub)
        let pkce = model.pkce
        var signedInFired = 0
        var outcomes: [AuthGateOutcome] = []
        model.onSignedIn = { signedInFired += 1 }
        model.onResolved = { outcomes.append($0) }

        await model.handleCallback(callback(code: "one-time-code", state: pkce.state))
        XCTAssertEqual(signedInFired, 1, "the gate must be marked signed-in right away")
        XCTAssertTrue(outcomes.isEmpty, "onResolved still waits for the persona step")
        XCTAssertEqual(model.state.phase, .personalize, "no switch hook wired: the account has no persona on record, so the question is asked")

        model.send(.answerSelected(persona: "research"))
        XCTAssertEqual(signedInFired, 1, "answering the persona question does not fire it a second time")
        XCTAssertEqual(outcomes.count, 1)
    }

    /// The window controller wires `onSwitching` to the account switch: the
    /// hook gets the account's email, does its work (the pointer write, the
    /// daemon restart), and answers with the persona the account's own data
    /// dir holds. A persona means no question; the gate resolves on it.
    @MainActor
    func testTheSwitchHookGetsTheEmailAndAPersonaItReportsSkipsTheQuestion() async {
        let stub = StubAuthSigning(result: .success(user()))
        let model = AuthGateViewModel(signer: stub)
        let pkce = model.pkce
        var handedEmail: String?
        var signedInFired = 0
        var outcomes: [AuthGateOutcome] = []
        model.onSignedIn = { signedInFired += 1 }
        model.onResolved = { outcomes.append($0) }
        model.onSwitching = { email, ready in
            handedEmail = email
            ready("research")
        }

        await model.handleCallback(callback(code: "one-time-code", state: pkce.state))

        XCTAssertEqual(handedEmail, "bruno@bonando.com")
        XCTAssertEqual(signedInFired, 1, "marked signed in before the switch, so a quit mid-switch does not ask again")
        XCTAssertEqual(model.state.phase, .resolved)
        XCTAssertEqual(outcomes.map(\.persona), ["research"])
    }

    /// The card between sign-in and the workspace: a hook that answers later
    /// leaves the model in `.switching` until it does.
    @MainActor
    func testTheGateStaysOnTheSwitchingCardUntilTheHookAnswers() async {
        let model = AuthGateViewModel(signer: StubAuthSigning(result: .success(user())))
        let pkce = model.pkce
        var answer: ((String?) -> Void)?
        model.onSwitching = { _, ready in answer = ready }

        await model.handleCallback(callback(code: "one-time-code", state: pkce.state))
        XCTAssertEqual(model.state.phase, .switching)

        answer?(nil)
        XCTAssertEqual(model.state.phase, .personalize, "no persona on record: ask")
    }

    @MainActor
    func testSignInDerivesTheDisplayNameFromFirstAndLastNameWhenNameIsAbsent() async {
        let stub = StubAuthSigning(result: .success(user(firstName: "Ada", lastName: "Lovelace", name: nil)))
        let model = AuthGateViewModel(signer: stub)

        await model.handleCallback(callback(code: "c", state: model.pkce.state))

        XCTAssertEqual(model.state.accountName, "Ada Lovelace")
    }

    /// A callback whose `state` is not this attempt's — a leftover from an
    /// abandoned attempt, or something another process on the Mac
    /// fabricated. The code must never be redeemed.
    @MainActor
    func testACallbackWithTheWrongStateIsRefusedWithoutTouchingTheServer() async {
        let stub = StubAuthSigning(result: .success(user()))
        let model = AuthGateViewModel(signer: stub)

        await model.handleCallback(callback(code: "stolen-code", state: "someone-elses-state"))

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

        await model.handleCallback(
            callback(state: model.pkce.state, error: "Apple did not return an email address.")
        )

        XCTAssertTrue(stub.exchanges.isEmpty)
        XCTAssertEqual(model.errorMessage, "Apple did not return an email address.")
        XCTAssertEqual(model.state.phase, .login)
        XCTAssertFalse(model.isBusy)
    }

    /// Pressing Cancel on Apple's own authorize page arrives as an `error`
    /// like any refusal, but it is the user's own decision — and Apple's
    /// word for it is a protocol identifier, not a sentence. Showing
    /// `user_cancelled_authorize` in the error label would read as this
    /// app's copy, blaming the user for backing out.
    @MainActor
    func testBackingOutOnApplesPageLeavesTheLoginScreenWithNothingToRead() async {
        let stub = StubAuthSigning(result: .success(user()))
        let model = AuthGateViewModel(signer: stub)

        await model.handleCallback(
            callback(state: model.pkce.state, error: "user_cancelled_authorize")
        )

        XCTAssertNil(model.errorMessage, "a cancel is not a failure to report")
        XCTAssertFalse(model.isBusy, "the button has to come back")
        XCTAssertEqual(model.state.phase, .login)
        XCTAssertTrue(stub.exchanges.isEmpty, "there is no code to redeem")
    }

    /// A forged cancel is still a forgery: the state guard runs first, so
    /// even the one `error` value the app treats specially cannot reach that
    /// branch without proving it belongs to this attempt.
    @MainActor
    func testAForgedCancelIsRefusedByTheStateGuardLikeAnyOtherCallback() async {
        let stub = StubAuthSigning(result: .success(user()))
        let model = AuthGateViewModel(signer: stub)

        await model.handleCallback(
            callback(state: "someone-elses-state", error: "user_cancelled_authorize")
        )

        XCTAssertEqual(model.errorMessage, "Sign-in response didn't match this app — try again.")
        XCTAssertFalse(model.isBusy)
        XCTAssertEqual(model.state.phase, .login)
        XCTAssertTrue(stub.exchanges.isEmpty)
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

            await model.handleCallback(forged)

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

        await model.handleCallback(callback(code: "c", state: model.pkce.state))

        XCTAssertEqual(model.state.phase, .login)
        XCTAssertEqual(model.errorMessage, "That sign-in link has already been used.")
        XCTAssertFalse(model.isBusy)
        XCTAssertTrue(outcomes.isEmpty)
    }

    @MainActor
    func testANetworkFailureSurfacesTheAuthErrorDescription() async {
        let stub = StubAuthSigning(result: .failure(.network("")))
        let model = AuthGateViewModel(signer: stub)

        await model.handleCallback(callback(code: "c", state: model.pkce.state))

        XCTAssertEqual(model.errorMessage, "Could not reach the OmniAgent API.")
        XCTAssertEqual(model.state.phase, .login)
    }

    @MainActor
    func testBusyIsUpDuringTheRequestAndDownAfter() async {
        let probe = BusyProbeAuthSigning(user: user())
        let model = AuthGateViewModel(signer: probe)
        probe.model = model
        XCTAssertFalse(model.isBusy)

        await model.handleCallback(callback(code: "c", state: model.pkce.state))

        XCTAssertEqual(probe.busyDuringExchange, true, "isBusy must be raised while the request is in flight")
        XCTAssertFalse(model.isBusy, "and lowered once it lands")
    }

    // MARK: - GitHub

    /// GitHub's callback is redeemed at GitHub's own exchange route, with
    /// this attempt's verifier and nonce — the same proof Apple's half
    /// presents, against a different provider.
    @MainActor
    func testAGitHubCallbackRedeemsTheCodeAtGitHubsExchange() async {
        let stub = StubAuthSigning(result: .success(user(githubLogin: "brunobonando")))
        let model = AuthGateViewModel(signer: stub)
        model.attemptProvider = .github
        let pkce = model.pkce

        await model.handleCallback(callback(code: "gh-code", state: pkce.state, provider: .github))

        XCTAssertEqual(stub.exchanges, [StubAuthSigning.Exchange(
            provider: .github,
            code: "gh-code",
            codeVerifier: pkce.verifier,
            nonce: pkce.nonce
        )])
        XCTAssertEqual(model.state.phase, .personalize)
        XCTAssertEqual(model.state.githubLogin, "brunobonando", "the handle rides into the outcome")
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.isBusy)
    }

    /// GitHub spells "the user pressed Cancel" `access_denied`, not Apple's
    /// `user_cancelled_authorize`. Both are protocol identifiers, and
    /// neither is a sentence to show anyone.
    @MainActor
    func testBackingOutOnGitHubsPageLeavesTheScreenWithNothingToRead() async {
        let stub = StubAuthSigning(result: .success(user()))
        let model = AuthGateViewModel(signer: stub)
        model.attemptProvider = .github

        await model.handleCallback(
            callback(state: model.pkce.state, error: "access_denied", provider: .github)
        )

        XCTAssertNil(model.errorMessage, "a cancel is not a failure to report")
        XCTAssertFalse(model.isBusy)
        XCTAssertEqual(model.state.phase, .login)
        XCTAssertTrue(stub.exchanges.isEmpty)

        // And the other provider's word for it is not this provider's: an
        // Apple cancel arriving in a GitHub attempt is just an error.
        await model.handleCallback(
            callback(state: model.pkce.state, error: "user_cancelled_authorize", provider: .github)
        )
        XCTAssertEqual(model.errorMessage, "user_cancelled_authorize")
    }

    /// The session intercepts *any* `omniagent://` navigation its browser
    /// makes, so a GitHub attempt can be handed an `/auth/apple` callback.
    /// It proves nothing about this attempt, so nothing in it is read — not
    /// even a `state` that happens to match.
    @MainActor
    func testACallbackFromTheOtherProviderIsRefusedBeforeAnythingInItIsRead() async {
        let stub = StubAuthSigning(result: .success(user()))
        let model = AuthGateViewModel(signer: stub)
        model.attemptProvider = .github

        await model.handleCallback(callback(code: "code", state: model.pkce.state, provider: .apple))

        XCTAssertEqual(model.errorMessage, "Sign-in response didn't match this app — try again.")
        XCTAssertTrue(stub.exchanges.isEmpty, "the wrong provider's code must never be redeemed")
        XCTAssertEqual(model.state.phase, .login)
        XCTAssertFalse(model.isBusy)
    }

    /// "Connect GitHub…" arms Core with this attempt *on the signed-in
    /// account* before the browser goes anywhere, sends the browser to
    /// Core's start URL, and reports the linked handle to its caller instead
    /// of resolving a gate there is none of.
    @MainActor
    func testConnectGitHubLinksFirstThenOpensTheStartURLAndReportsTheHandle() async {
        let stub = StubAuthSigning(result: .success(user(githubLogin: "brunobonando")))
        let model = AuthGateViewModel(signer: stub, intent: .linkGitHub)
        var outcomes: [AuthLinkOutcome] = []
        model.onLinkOutcome = { outcomes.append($0) }
        var opened: URL?
        let browser = expectation(description: "the browser is sent somewhere")
        model.webAuthOpener = { url in
            opened = url
            browser.fulfill()
            return true
        }

        model.connectGitHub()
        await fulfillment(of: [browser], timeout: 2)

        XCTAssertEqual(
            stub.links,
            [StubAuthSigning.Link(state: model.pkce.state, nonce: model.pkce.nonce)],
            "Core has to be told to expect this attempt before the browser runs"
        )
        XCTAssertEqual(model.attemptProvider, .github)
        XCTAssertEqual(
            opened,
            stub.authorizeURL(for: .github, state: model.pkce.state, nonce: model.pkce.nonce),
            "and the browser goes to the provider's start URL for this attempt"
        )
        XCTAssertTrue(outcomes.isEmpty, "the browser has not answered yet")

        await model.handleCallback(callback(code: "gh-code", state: model.pkce.state, provider: .github))

        XCTAssertEqual(outcomes, [.linked(githubLogin: "brunobonando")])
        XCTAssertEqual(model.state.phase, .login, "a link never drives the gate reducer")
    }

    /// The access token lives in memory only, so a launch that has not
    /// refreshed has none while the refresh cookie is still good. The link
    /// call refreshes first rather than failing on a session that is fine.
    @MainActor
    func testConnectGitHubRefreshesTheSessionWhenThereIsNoTokenInHand() async {
        let stub = StubAuthSigning(result: .success(user()), accessToken: nil)
        let model = AuthGateViewModel(signer: stub, intent: .linkGitHub)
        let browser = expectation(description: "the browser is sent somewhere")
        model.webAuthOpener = { _ in
            browser.fulfill()
            return true
        }

        model.connectGitHub()
        await fulfillment(of: [browser], timeout: 2)

        XCTAssertEqual(stub.restores, 1)
        XCTAssertEqual(stub.links.count, 1, "and the link went out after the refresh, not instead of it")
    }

    /// No session at all: the honest answer is to sign in, not "your session
    /// expired" — and it has to reach the caller, or the button stays dead.
    @MainActor
    func testConnectGitHubWithNoSessionSaysToSignInFirstAndReportsIt() async {
        let stub = StubAuthSigning(result: .success(user()), accessToken: nil)
        stub.restoreFailure = .sessionExpired
        let model = AuthGateViewModel(signer: stub, intent: .linkGitHub)
        model.webAuthOpener = { _ in
            XCTFail("no browser may open without an account to link onto")
            return false
        }
        let outcomes = await collect(from: model) { model.connectGitHub() }

        XCTAssertEqual(outcomes, [.failed(AuthGateViewModel.signInFirstMessage)])
        XCTAssertTrue(AuthGateViewModel.signInFirstMessage.hasPrefix("Sign in first"))
        XCTAssertTrue(stub.links.isEmpty, "nothing to link onto")
        XCTAssertFalse(model.isBusy, "the button has to come back")
    }

    /// Disconnect has no browser and no callback: one bearer call, reported
    /// through the same one ending a connect uses — `nil`, since linked to
    /// nothing is exactly what it leaves behind.
    @MainActor
    func testDisconnectGitHubReportsTheAccountAsLinkedToNothing() async {
        let stub = StubAuthSigning(result: .success(user()))
        let model = AuthGateViewModel(signer: stub, intent: .linkGitHub)

        let outcomes = await collect(from: model) { model.disconnectGitHub() }

        XCTAssertEqual(stub.disconnects, 1)
        XCTAssertEqual(outcomes, [.linked(githubLogin: nil)])
        XCTAssertFalse(model.isBusy)
    }

    /// A failed disconnect must report too — an in-flight flag left up is a
    /// button that does nothing for the rest of the launch.
    @MainActor
    func testAFailedDisconnectReportsTheServersOwnWords() async {
        let stub = StubAuthSigning(result: .success(user()))
        stub.linkFailure = .server(409, "GitHub is the only sign-in method on this account.")
        let model = AuthGateViewModel(signer: stub, intent: .linkGitHub)

        let outcomes = await collect(from: model) { model.disconnectGitHub() }

        XCTAssertEqual(outcomes, [.failed("GitHub is the only sign-in method on this account.")])
    }

    /// Runs `work` and waits for the one `onLinkOutcome` it must produce —
    /// these paths report from inside a `Task`, so nothing about them is
    /// observable on the line after the call.
    @MainActor
    private func collect(
        from model: AuthGateViewModel,
        _ work: () -> Void
    ) async -> [AuthLinkOutcome] {
        var outcomes: [AuthLinkOutcome] = []
        let reported = expectation(description: "the link outcome is reported")
        model.onLinkOutcome = { outcome in
            outcomes.append(outcome)
            reported.fulfill()
        }
        work()
        await fulfillment(of: [reported], timeout: 2)
        return outcomes
    }

    /// Backing out of a link is not a failure either — and the caller has to
    /// hear about it all the same.
    @MainActor
    func testBackingOutOfALinkReportsACancelAndWritesNothing() async {
        let stub = StubAuthSigning(result: .success(user()))
        let model = AuthGateViewModel(signer: stub, intent: .linkGitHub)
        var outcomes: [AuthLinkOutcome] = []
        model.onLinkOutcome = { outcomes.append($0) }

        await model.handleCallback(
            callback(state: model.pkce.state, error: "access_denied", provider: .github)
        )

        XCTAssertEqual(outcomes, [.cancelled])
        XCTAssertTrue(stub.exchanges.isEmpty)
    }

    @MainActor
    func testANewAttemptClearsThePreviousErrorMessage() async {
        let stub = StubAuthSigning(result: .success(user()))
        let model = AuthGateViewModel(signer: stub)

        await model.handleCallback(callback(code: "c", state: "wrong"))
        XCTAssertNotNil(model.errorMessage)

        await model.handleCallback(callback(code: "c", state: model.pkce.state))
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

    /// The controller passes the hook through to the model it builds and
    /// exposes that model, so the window's switch can be driven end to end
    /// without a browser: sign in → hook → persona → resolved → dismissed.
    @MainActor
    func testPresentHandsTheSwitchHookTheEmailAndResolvesOnItsAnswer() throws {
        let client = FakeSettingsClient()
        let controller = AuthGateWindowController(
            coordinator: AuthGateCoordinator(settings: SettingsStore(client: client), defaults: try throwawayDefaults())
        )
        var handedEmail: String?
        controller.onSwitching = { email, ready in
            handedEmail = email
            ready("research")
        }
        var completed = 0
        controller.present(over: nil) { completed += 1 }
        let window = try XCTUnwrap(controller.sheetWindow)
        addTeardownBlock { @MainActor in window.orderOut(nil) }
        let model = try XCTUnwrap(controller.activeModel)

        model.send(.signedIn(email: "bruno@bonando.com", displayName: "Bruno Bonando", githubLogin: nil, picture: nil))

        XCTAssertEqual(handedEmail, "bruno@bonando.com")
        XCTAssertEqual(completed, 1)
        XCTAssertNil(controller.activeModel, "resolved and dismissed")
        XCTAssertNil(controller.sheetWindow)
        XCTAssertEqual(client.rows["auth_signed_in"], "true")
        XCTAssertEqual(client.rows["auth_persona"], "research")
    }

    private func throwawayDefaults() throws -> UserDefaults {
        let name = "digital.bruno.omniagent.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        return defaults
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
