import Foundation

/// The fake sign-in + "getting to know you" gate's pure state — a direct
/// port of `ui/src/onboarding/authGateState.ts`, field-for-field and
/// function-for-function, so the phase transitions are unit-testable without
/// `AuthGateView`/`NSHostingController`/a socket.
///
/// Founder direction (verbatim, carried over from the TypeScript oracle):
/// "let's skip the Import but let's Focus on getting to know the user after
/// a login, but they can use it without login for now while in development.
/// Login must be fake for now, just to test the workflow." Nothing here ever
/// makes a network call or checks a real credential — "sign in" always
/// succeeds, "skip" is an equally first-class exit.
enum AuthGatePhase: Equatable {
    case login
    case personalize
    case resolved
}

struct AuthGateOutcome: Equatable {
    /// Whether the user went through the fake "Continue" (true) or picked
    /// "Continue without signing in" (false).
    let signedIn: Bool
    /// The selected `PersonaOption.id`, or `nil` if never signed in, or
    /// signed in but the personalization question was skipped.
    let persona: String?
}

struct AuthGateState: Equatable {
    var phase: AuthGatePhase
    /// Non-nil exactly when `phase == .resolved`.
    var outcome: AuthGateOutcome?
}

enum AuthGateAction: Equatable {
    case skipLogin
    case signIn
    case answerSelected(persona: String)
    case skipPersonalize
}

enum AuthGateReducer {
    static let initial = AuthGateState(phase: .login, outcome: nil)

    static func reduce(_ state: AuthGateState, _ action: AuthGateAction) -> AuthGateState {
        switch action {
        case .skipLogin:
            guard state.phase == .login else { return state }
            return AuthGateState(phase: .resolved, outcome: AuthGateOutcome(signedIn: false, persona: nil))

        case .signIn:
            guard state.phase == .login else { return state }
            return AuthGateState(phase: .personalize, outcome: nil)

        case let .answerSelected(persona):
            guard state.phase == .personalize else { return state }
            return AuthGateState(phase: .resolved, outcome: AuthGateOutcome(signedIn: true, persona: persona))

        case .skipPersonalize:
            guard state.phase == .personalize else { return state }
            return AuthGateState(phase: .resolved, outcome: AuthGateOutcome(signedIn: true, persona: nil))
        }
    }
}

struct PersonaOption: Equatable, Identifiable {
    let id: String
    let label: String
}

/// Persistence conventions and static content shared by `AuthGateView` (the
/// gate itself) and the Settings screen's Account section — both read the
/// same three `SettingsKey.authGate*` rows, so the "what counts as signed
/// in" rule lives here once rather than twice.
enum AuthGate {
    static let personaOptions: [PersonaOption] = [
        PersonaOption(id: "software-engineering", label: "Software Engineering"),
        PersonaOption(id: "data-ml", label: "Data & ML"),
        PersonaOption(id: "devops-infra", label: "DevOps & Infrastructure"),
        PersonaOption(id: "product-design", label: "Product & Design"),
        PersonaOption(id: "research", label: "Research"),
        PersonaOption(id: "student", label: "Student"),
        PersonaOption(id: "other", label: "Other"),
    ]

    /// Bruno, verbatim: "I know that we didn't implement the login part yet,
    /// so just make a fake one as if I was logged in as BrunoBonando." NOT a
    /// real account: no credential, no server, no profile.
    static let fakeAccountName = "Bruno Bonando"

    /// The "already resolved, don't show the gate again" check —
    /// `App.tsx`'s boot effect applies this to the raw `authGateResolved`
    /// read. Only the exact string `"true"` counts; unset/`"false"`/garbage
    /// all mean "show the gate".
    static func alreadyResolved(_ settingValue: String?) -> Bool {
        settingValue == "true"
    }

    /// **Unset defaults to signed in** — so a fresh install shows the
    /// signed-in experience without clicking through a login that isn't
    /// real. Only the explicit string `"false"` — exactly what "Log out"/
    /// "Continue without signing in" write — means signed out. Deliberately
    /// the mirror image of `alreadyResolved`'s "only an explicit 'true'
    /// counts" convention, for the opposite default.
    static func resolveSignedIn(_ settingValue: String?) -> Bool {
        settingValue != "false"
    }

    /// `nil` for an unknown/empty id — callers treat that as "no answer".
    static func personaLabel(_ id: String?) -> String? {
        guard let id, !id.isEmpty else { return nil }
        return personaOptions.first { $0.id == id }?.label
    }

    /// The Settings screen's Account section summary line — the native twin
    /// of `describeAuthSummary`.
    static func describeAuthSummary(signedInRaw: String?, personaRaw: String?) -> String {
        guard resolveSignedIn(signedInRaw) else { return "Not signed in (dev mode)." }
        if let label = personaLabel(personaRaw) {
            return "\(fakeAccountName) — \(label)."
        }
        return "\(fakeAccountName) (dev mode)."
    }
}
