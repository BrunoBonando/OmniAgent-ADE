import XCTest
@testable import OmniAgent

final class AuthGateStateTests: XCTestCase {
    func testSkippingLoginResolvesSignedOutWithNoPersona() {
        let resolved = AuthGateReducer.reduce(AuthGateReducer.initial, .skipLogin)
        XCTAssertEqual(resolved, AuthGateState(phase: .resolved, outcome: AuthGateOutcome(signedIn: false, persona: nil)))
    }

    func testSigningInMovesToPersonalizeWithNoOutcomeYet() {
        let state = AuthGateReducer.reduce(AuthGateReducer.initial, .signIn)
        XCTAssertEqual(state, AuthGateState(phase: .personalize, outcome: nil))
    }

    func testAnsweringThePersonaQuestionResolvesSignedInWithThatPersona() {
        let personalizing = AuthGateReducer.reduce(AuthGateReducer.initial, .signIn)
        let resolved = AuthGateReducer.reduce(personalizing, .answerSelected(persona: "student"))
        XCTAssertEqual(resolved, AuthGateState(phase: .resolved, outcome: AuthGateOutcome(signedIn: true, persona: "student")))
    }

    func testSkippingThePersonaQuestionStillResolvesSignedInWithNoPersona() {
        let personalizing = AuthGateReducer.reduce(AuthGateReducer.initial, .signIn)
        let resolved = AuthGateReducer.reduce(personalizing, .skipPersonalize)
        XCTAssertEqual(resolved, AuthGateState(phase: .resolved, outcome: AuthGateOutcome(signedIn: true, persona: nil)))
    }

    func testActionsThatDoNotMatchThePhaseAreIgnored() {
        // Can't skip-login from personalize, can't answer/skip-personalize from login.
        let personalizing = AuthGateReducer.reduce(AuthGateReducer.initial, .signIn)
        XCTAssertEqual(AuthGateReducer.reduce(personalizing, .skipLogin), personalizing)
        XCTAssertEqual(AuthGateReducer.reduce(AuthGateReducer.initial, .answerSelected(persona: "student")), AuthGateReducer.initial)
        XCTAssertEqual(AuthGateReducer.reduce(AuthGateReducer.initial, .skipPersonalize), AuthGateReducer.initial)

        let resolved = AuthGateReducer.reduce(AuthGateReducer.initial, .skipLogin)
        XCTAssertEqual(AuthGateReducer.reduce(resolved, .signIn), resolved, "a resolved gate cannot be reopened by another action")
    }

    // MARK: - Persistence conventions

    func testOnlyTheExactStringTrueCountsAsAlreadyResolved() {
        XCTAssertTrue(AuthGate.alreadyResolved("true"))
        XCTAssertFalse(AuthGate.alreadyResolved(nil))
        XCTAssertFalse(AuthGate.alreadyResolved("false"))
        XCTAssertFalse(AuthGate.alreadyResolved("garbage"))
    }

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

    func testAuthSummaryCoversSignedOutSignedInWithAndWithoutAPersona() {
        XCTAssertEqual(AuthGate.describeAuthSummary(signedInRaw: "false", personaRaw: nil), "Not signed in (dev mode).")
        XCTAssertEqual(AuthGate.describeAuthSummary(signedInRaw: nil, personaRaw: nil), "Bruno Bonando (dev mode).")
        XCTAssertEqual(
            AuthGate.describeAuthSummary(signedInRaw: "true", personaRaw: "research"),
            "Bruno Bonando — Research."
        )
    }
}
