import Foundation

/// FirstRun's pure phase state — a direct port of
/// `ui/src/onboarding/onboardingState.ts`, so "when does the picker give way
/// to a progress HUD, when does that give way to a completion banner" is
/// unit-testable without `FirstRunView`/a socket. `FirstRunController`
/// dispatches `.rootPicked` right when it calls `SessionConnection.startIngest`,
/// then folds every poll of `SessionConnection.ingestionStatus` through
/// `.statusPolled`.
enum OnboardingPhase: Equatable {
    case pick
    case ingesting
    case done
}

struct OnboardingState: Equatable {
    var phase: OnboardingPhase
    /// Whether we've ever observed `status.running == true` since the last
    /// `.rootPicked` — the only reliable way to tell "finished" apart from
    /// "hasn't started yet" when polling a status snapshot that starts out
    /// `running: false` before the daemon's background thread has run its
    /// first update.
    var everRunning: Bool
    var status: IngestionStatus?
}

enum OnboardingAction: Equatable {
    case rootPicked
    case statusPolled(status: IngestionStatus)
    case retry
}

enum OnboardingReducer {
    static let initial = OnboardingState(phase: .pick, everRunning: false, status: nil)

    static func reduce(_ state: OnboardingState, _ action: OnboardingAction) -> OnboardingState {
        switch action {
        case .rootPicked:
            return OnboardingState(phase: .ingesting, everRunning: false, status: nil)

        case let .statusPolled(status):
            guard state.phase == .ingesting else { return state }
            let everRunning = state.everRunning || status.running
            if everRunning, !status.running {
                return OnboardingState(phase: .done, everRunning: everRunning, status: status)
            }
            return OnboardingState(phase: state.phase, everRunning: everRunning, status: status)

        case .retry:
            return initial
        }
    }
}
