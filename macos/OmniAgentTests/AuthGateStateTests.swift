import XCTest
@testable import OmniAgent

final class AuthGateStateTests: XCTestCase {
    private let signedIn = AuthGateAction.signedIn(
        email: "bruno@bonando.com",
        displayName: "Bruno Bonando",
        githubLogin: "brunobonando"
    )

    func testSkippingLoginResolvesSignedOutWithNoPersonaAndNoAccount() {
        let resolved = AuthGateReducer.reduce(AuthGateReducer.initial, .skipLogin)
        XCTAssertEqual(resolved, AuthGateState(
            phase: .resolved,
            outcome: AuthGateOutcome(signedIn: false, persona: nil, accountEmail: nil, accountName: nil)
        ))
    }

    func testSigningInMovesToPersonalizeCarryingTheAccountWithNoOutcomeYet() {
        let state = AuthGateReducer.reduce(AuthGateReducer.initial, signedIn)
        XCTAssertEqual(state, AuthGateState(
            phase: .personalize,
            outcome: nil,
            accountEmail: "bruno@bonando.com",
            accountName: "Bruno Bonando",
            githubLogin: "brunobonando"
        ))
    }

    func testANilDisplayNameSurvivesIntoThePersonalizePhase() {
        let state = AuthGateReducer.reduce(
            AuthGateReducer.initial,
            .signedIn(email: "a@b.com", displayName: nil, githubLogin: nil)
        )
        XCTAssertEqual(state.accountEmail, "a@b.com")
        XCTAssertNil(state.accountName)
        XCTAssertNil(state.githubLogin, "an account with nothing linked carries nothing")
    }

    func testAnsweringThePersonaQuestionResolvesSignedInWithThatPersonaAndTheAccount() {
        let personalizing = AuthGateReducer.reduce(AuthGateReducer.initial, signedIn)
        let resolved = AuthGateReducer.reduce(personalizing, .answerSelected(persona: "student"))
        XCTAssertEqual(resolved.phase, .resolved)
        XCTAssertEqual(resolved.outcome, AuthGateOutcome(
            signedIn: true,
            persona: "student",
            accountEmail: "bruno@bonando.com",
            accountName: "Bruno Bonando",
            githubLogin: "brunobonando"
        ))
    }

    func testSkippingThePersonaQuestionStillResolvesSignedInWithTheAccountAndNoPersona() {
        let personalizing = AuthGateReducer.reduce(AuthGateReducer.initial, signedIn)
        let resolved = AuthGateReducer.reduce(personalizing, .skipPersonalize)
        XCTAssertEqual(resolved.phase, .resolved)
        XCTAssertEqual(resolved.outcome, AuthGateOutcome(
            signedIn: true,
            persona: nil,
            accountEmail: "bruno@bonando.com",
            accountName: "Bruno Bonando",
            githubLogin: "brunobonando"
        ))
    }

    func testActionsThatDoNotMatchThePhaseAreIgnored() {
        // Can't skip-login from personalize, can't answer/skip-personalize from login.
        let personalizing = AuthGateReducer.reduce(AuthGateReducer.initial, signedIn)
        XCTAssertEqual(AuthGateReducer.reduce(personalizing, .skipLogin), personalizing)
        XCTAssertEqual(AuthGateReducer.reduce(AuthGateReducer.initial, .answerSelected(persona: "student")), AuthGateReducer.initial)
        XCTAssertEqual(AuthGateReducer.reduce(AuthGateReducer.initial, .skipPersonalize), AuthGateReducer.initial)

        let resolved = AuthGateReducer.reduce(AuthGateReducer.initial, .skipLogin)
        XCTAssertEqual(AuthGateReducer.reduce(resolved, signedIn), resolved, "a resolved gate cannot be reopened by another action")
        XCTAssertEqual(AuthGateReducer.reduce(personalizing, signedIn), personalizing, "a second sign-in while personalizing is ignored")
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
