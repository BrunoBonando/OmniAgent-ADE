import XCTest
@testable import OmniAgent

final class AuthGateStateTests: XCTestCase {
    private let signedIn = AuthGateAction.signedIn(
        email: "bruno@bonando.com",
        displayName: "Bruno Bonando",
        githubLogin: "brunobonando",
        picture: "https://cdn.test.invalid/bruno.png"
    )

    private var switching: AuthGateState {
        AuthGateReducer.reduce(AuthGateReducer.initial, signedIn)
    }

    func testSigningInMovesToSwitchingCarryingTheAccountWithNoOutcomeYet() {
        XCTAssertEqual(switching, AuthGateState(
            phase: .switching,
            outcome: nil,
            accountEmail: "bruno@bonando.com",
            accountName: "Bruno Bonando",
            githubLogin: "brunobonando",
            accountPicture: "https://cdn.test.invalid/bruno.png"
        ))
    }

    func testANilDisplayNameSurvivesIntoTheSwitchingPhase() {
        let state = AuthGateReducer.reduce(
            AuthGateReducer.initial,
            .signedIn(email: "a@b.com", displayName: nil, githubLogin: nil, picture: nil)
        )
        XCTAssertEqual(state.phase, .switching)
        XCTAssertEqual(state.accountEmail, "a@b.com")
        XCTAssertNil(state.accountName)
        XCTAssertNil(state.githubLogin, "an account with nothing linked carries nothing")
        XCTAssertNil(state.accountPicture, "nor a picture it does not have")
    }

    /// The account already answered the persona question once: it comes back
    /// with the account's data dir, and the gate resolves without asking.
    func testAccountReadyWithAPersonaResolvesSignedInWithoutAskingTheQuestion() {
        let resolved = AuthGateReducer.reduce(switching, .accountReady(persona: "research"))
        XCTAssertEqual(resolved.phase, .resolved)
        XCTAssertEqual(resolved.outcome, AuthGateOutcome(
            signedIn: true,
            persona: "research",
            accountEmail: "bruno@bonando.com",
            accountName: "Bruno Bonando",
            githubLogin: "brunobonando",
            accountPicture: "https://cdn.test.invalid/bruno.png"
        ))
    }

    func testAccountReadyWithoutAPersonaAsksTheQuestion() {
        for persona in [nil, ""] {
            let personalizing = AuthGateReducer.reduce(switching, .accountReady(persona: persona))
            XCTAssertEqual(personalizing.phase, .personalize)
            XCTAssertNil(personalizing.outcome)
            XCTAssertEqual(personalizing.accountEmail, "bruno@bonando.com", "the account rides along")
            XCTAssertEqual(personalizing.accountName, "Bruno Bonando")
        }
    }

    func testAnsweringThePersonaQuestionResolvesSignedInWithThatPersonaAndTheAccount() {
        let personalizing = AuthGateReducer.reduce(switching, .accountReady(persona: nil))
        let resolved = AuthGateReducer.reduce(personalizing, .answerSelected(persona: "student"))
        XCTAssertEqual(resolved.phase, .resolved)
        XCTAssertEqual(resolved.outcome, AuthGateOutcome(
            signedIn: true,
            persona: "student",
            accountEmail: "bruno@bonando.com",
            accountName: "Bruno Bonando",
            githubLogin: "brunobonando",
            accountPicture: "https://cdn.test.invalid/bruno.png"
        ))
    }

    func testSkippingThePersonaQuestionStillResolvesSignedInWithTheAccountAndNoPersona() {
        let personalizing = AuthGateReducer.reduce(switching, .accountReady(persona: nil))
        let resolved = AuthGateReducer.reduce(personalizing, .skipPersonalize)
        XCTAssertEqual(resolved.phase, .resolved)
        XCTAssertEqual(resolved.outcome, AuthGateOutcome(
            signedIn: true,
            persona: nil,
            accountEmail: "bruno@bonando.com",
            accountName: "Bruno Bonando",
            githubLogin: "brunobonando",
            accountPicture: "https://cdn.test.invalid/bruno.png"
        ))
    }

    func testActionsThatDoNotMatchThePhaseAreIgnored() {
        let initial = AuthGateReducer.initial
        XCTAssertEqual(AuthGateReducer.reduce(initial, .accountReady(persona: "student")), initial, "no account to be ready")
        XCTAssertEqual(AuthGateReducer.reduce(initial, .answerSelected(persona: "student")), initial)
        XCTAssertEqual(AuthGateReducer.reduce(initial, .skipPersonalize), initial)

        let switching = self.switching
        XCTAssertEqual(AuthGateReducer.reduce(switching, .answerSelected(persona: "student")), switching, "not asked yet")
        XCTAssertEqual(AuthGateReducer.reduce(switching, .skipPersonalize), switching)
        XCTAssertEqual(AuthGateReducer.reduce(switching, signedIn), switching, "a second sign-in while switching is ignored")

        let personalizing = AuthGateReducer.reduce(switching, .accountReady(persona: nil))
        XCTAssertEqual(AuthGateReducer.reduce(personalizing, .accountReady(persona: "x")), personalizing)
        XCTAssertEqual(AuthGateReducer.reduce(personalizing, signedIn), personalizing)

        let resolved = AuthGateReducer.reduce(switching, .accountReady(persona: "research"))
        XCTAssertEqual(AuthGateReducer.reduce(resolved, signedIn), resolved, "a resolved gate cannot be reopened by another action")
    }

    func testThereIsNoWayThroughTheGateWithoutSigningIn() {
        // Every action that is not `.signedIn` leaves the login phase alone.
        for action: AuthGateAction in [
            .accountReady(persona: nil), .accountReady(persona: "research"),
            .answerSelected(persona: "research"), .skipPersonalize,
        ] {
            XCTAssertEqual(AuthGateReducer.reduce(AuthGateReducer.initial, action).phase, .login)
        }
    }

    // MARK: - Persistence conventions

    func testUnsetOrAnythingButFalseReadsAsSignedIn() {
        XCTAssertTrue(AuthGate.resolveSignedIn(nil))
        XCTAssertTrue(AuthGate.resolveSignedIn("true"))
        XCTAssertTrue(AuthGate.resolveSignedIn("garbage"))
        XCTAssertFalse(AuthGate.resolveSignedIn("false"))
    }

    func testPersonaLabelResolvesAKnownIdAndFallsBackToNilForAnythingElse() {
        XCTAssertEqual(AuthGate.personaLabel("student"), "Student")
        XCTAssertNil(AuthGate.personaLabel(nil))
        XCTAssertNil(AuthGate.personaLabel(""))
        XCTAssertNil(AuthGate.personaLabel("not-a-real-id"))
    }

    func testAuthSummaryPrefersTheRealAccountWhenAnEmailIsPresent() {
        XCTAssertEqual(
            AuthGate.describeAuthSummary(
                signedInRaw: "true", personaRaw: "research",
                accountEmailRaw: "bruno@bonando.com", accountNameRaw: "Bruno Bonando"
            ),
            "Bruno Bonando — Research."
        )
        XCTAssertEqual(
            AuthGate.describeAuthSummary(
                signedInRaw: "true", personaRaw: "",
                accountEmailRaw: "bruno@bonando.com", accountNameRaw: "Bruno Bonando"
            ),
            "Bruno Bonando (bruno@bonando.com)."
        )
        XCTAssertEqual(
            AuthGate.describeAuthSummary(
                signedInRaw: "true", personaRaw: nil,
                accountEmailRaw: "bruno@bonando.com", accountNameRaw: ""
            ),
            "bruno@bonando.com.",
            "no display name — the email stands alone"
        )
        XCTAssertEqual(
            AuthGate.describeAuthSummary(
                signedInRaw: "true", personaRaw: "research",
                accountEmailRaw: "bruno@bonando.com", accountNameRaw: nil
            ),
            "bruno@bonando.com — Research."
        )
    }

    func testAuthSummaryFallsBackToTheLegacyFakeIdentityForOldRowsWithoutAnAccount() {
        // Rows persisted by the fake-login build wrote no account keys at all.
        XCTAssertEqual(
            AuthGate.describeAuthSummary(signedInRaw: nil, personaRaw: nil, accountEmailRaw: nil, accountNameRaw: nil),
            "Bruno Bonando (dev mode)."
        )
        XCTAssertEqual(
            AuthGate.describeAuthSummary(signedInRaw: "true", personaRaw: "research", accountEmailRaw: "", accountNameRaw: ""),
            "Bruno Bonando — Research."
        )
    }

    func testAuthSummaryReportsSignedOutRegardlessOfAnyStaleAccountRows() {
        XCTAssertEqual(
            AuthGate.describeAuthSummary(
                signedInRaw: "false", personaRaw: nil,
                accountEmailRaw: "bruno@bonando.com", accountNameRaw: "Bruno Bonando"
            ),
            "Not signed in (dev mode)."
        )
    }
}
