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

    func testResolvingWritesAllThreeKeys() {
        let client = FakeSettingsClient()
        let coordinator = AuthGateCoordinator(settings: SettingsStore(client: client))

        let expectation = expectation(description: "resolve")
        coordinator.resolve(AuthGateOutcome(signedIn: true, persona: "research")) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1)

        XCTAssertEqual(client.rows["auth_gate_resolved"], "true")
        XCTAssertEqual(client.rows["auth_signed_in"], "true")
        XCTAssertEqual(client.rows["auth_persona"], "research")
    }

    func testResolvingASkippedPersonaWritesAnEmptyPersonaString() {
        let client = FakeSettingsClient()
        let coordinator = AuthGateCoordinator(settings: SettingsStore(client: client))

        let expectation = expectation(description: "resolve")
        coordinator.resolve(AuthGateOutcome(signedIn: false, persona: nil)) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1)

        XCTAssertEqual(client.rows["auth_signed_in"], "false")
        XCTAssertEqual(client.rows["auth_persona"], "")
    }

    func testResetClearsAllThreeKeysToTheSignedOutUnresolvedShape() {
        let client = FakeSettingsClient(rows: [
            "auth_gate_resolved": "true", "auth_signed_in": "true", "auth_persona": "student",
        ])
        let coordinator = AuthGateCoordinator(settings: SettingsStore(client: client))

        let expectation = expectation(description: "reset")
        coordinator.reset { expectation.fulfill() }
        wait(for: [expectation], timeout: 1)

        XCTAssertEqual(client.rows["auth_gate_resolved"], "false")
        XCTAssertEqual(client.rows["auth_signed_in"], "false")
        XCTAssertEqual(client.rows["auth_persona"], "")
    }

    func testSummaryReadsBothKeysThroughDescribeAuthSummary() {
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

final class AuthGateViewModelTests: XCTestCase {
    func testSendingSkipLoginResolvesAndInvokesOnResolvedExactlyOnce() {
        let model = AuthGateViewModel()
        var outcomes: [AuthGateOutcome] = []
        model.onResolved = { outcomes.append($0) }

        model.send(.skipLogin)

        XCTAssertEqual(model.state.phase, .resolved)
        XCTAssertEqual(outcomes, [AuthGateOutcome(signedIn: false, persona: nil)])
    }

    func testSendingSignInThenAnAnswerResolvesOnceWithThePersona() {
        let model = AuthGateViewModel()
        var outcomes: [AuthGateOutcome] = []
        model.onResolved = { outcomes.append($0) }

        model.send(.signIn)
        XCTAssertEqual(model.state.phase, .personalize)
        XCTAssertTrue(outcomes.isEmpty, "not resolved yet")

        model.send(.answerSelected(persona: "research"))
        XCTAssertEqual(outcomes, [AuthGateOutcome(signedIn: true, persona: "research")])
    }
}
