import Foundation

/// The sign-in + "getting to know you" gate's pure state — originally a
/// direct port of `ui/src/onboarding/authGateState.ts`, kept as a pure
/// reducer so the phase transitions are unit-testable without
/// `AuthGateView`/`NSHostingController`/a socket/a network.
///
/// The login itself is real now: `AuthGateViewModel` calls Core's
/// `/v1/auth/login` (or `/v1/auth/login/apple`) through `AuthClient` and only
/// dispatches `.signedIn` after the server said yes. What survives from the
/// fake era, by founder direction, is the escape hatch: "Continue without
/// signing in" (`.skipLogin`) stays a first-class exit while the product is
/// in development, because the API may be unreachable and the app is
/// local-first anyway.
enum AuthGatePhase: Equatable {
    case login
    case personalize
    case resolved
}

struct AuthGateOutcome: Equatable {
    /// Whether the user actually signed in (true) or picked
    /// "Continue without signing in" (false).
    let signedIn: Bool
    /// The selected `PersonaOption.id`, or `nil` if never signed in, or
    /// signed in but the personalization question was skipped.
    let persona: String?
    /// The Core account's email address, or `nil` when sign-in was skipped.
    let accountEmail: String?
    /// The account's display name ("Bruno Bonando"), or `nil` when the
    /// server has none for it — or when sign-in was skipped.
    let accountName: String?
}

struct AuthGateState: Equatable {
    var phase: AuthGatePhase
    /// Non-nil exactly when `phase == .resolved`.
    var outcome: AuthGateOutcome?
    /// The signed-in identity, carried from `.signedIn` through the
    /// personalize phase into the outcome. Both stay `nil` on the skip path.
    var accountEmail: String? = nil
    var accountName: String? = nil
}

enum AuthGateAction: Equatable {
    case skipLogin
    /// A *successful* real login — `AuthGateViewModel` dispatches this only
    /// after `AuthClient` returned a user; the reducer never sees a failed
    /// attempt (that stays view-model state as `errorMessage`).
    case signedIn(email: String, displayName: String?)
    case answerSelected(persona: String)
    case skipPersonalize
}

enum AuthGateReducer {
    static let initial = AuthGateState(phase: .login, outcome: nil)

    static func reduce(_ state: AuthGateState, _ action: AuthGateAction) -> AuthGateState {
        switch action {
        case .skipLogin:
            guard state.phase == .login else { return state }
            return AuthGateState(
                phase: .resolved,
                outcome: AuthGateOutcome(signedIn: false, persona: nil, accountEmail: nil, accountName: nil)
            )

        case let .signedIn(email, displayName):
            guard state.phase == .login else { return state }
            return AuthGateState(phase: .personalize, outcome: nil, accountEmail: email, accountName: displayName)

        case let .answerSelected(persona):
            guard state.phase == .personalize else { return state }
            return AuthGateState(
                phase: .resolved,
                outcome: AuthGateOutcome(
                    signedIn: true,
                    persona: persona,
                    accountEmail: state.accountEmail,
                    accountName: state.accountName
                ),
                accountEmail: state.accountEmail,
                accountName: state.accountName
            )

        case .skipPersonalize:
            guard state.phase == .personalize else { return state }
            return AuthGateState(
                phase: .resolved,
                outcome: AuthGateOutcome(
                    signedIn: true,
                    persona: nil,
                    accountEmail: state.accountEmail,
                    accountName: state.accountName
                ),
                accountEmail: state.accountEmail,
                accountName: state.accountName
            )
        }
    }
}

struct PersonaOption: Equatable, Identifiable {
    let id: String
    let label: String
}

/// Persistence conventions and static content shared by `AuthGateView` (the
/// gate itself) and the Settings screen's Account section — both read the
/// same `SettingsKey.auth*` rows, so the "what counts as signed in" rule
/// lives here once rather than twice.
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

    /// The fake-login era's stand-in identity. Kept ONLY as the display
    /// fallback for rows persisted before real login existed — a
    /// `auth_signed_in = "true"` row with no `auth_account_email` beside it.
    /// New sign-ins always carry a real email and never show this.
    static let fakeAccountName = "Bruno Bonando"

    /// Where `AuthGateCoordinator` mirrors the signed-in flag.
    static let signedInDefaultsKey = "auth.signedIn"

    /// The launch question, and the one rule in this file that deliberately
    /// does **not** go through `SettingsStore`: a settings read is a round
    /// trip over the daemon socket, so it cannot answer before the socket is
    /// up — which is far too late for a window that has to be the first thing
    /// on screen. The mirror is a `UserDefaults` bool, read synchronously, so
    /// a slow or dead daemon delays nothing.
    ///
    /// The gate latches on *signed in*, not on "resolved once": clicking
    /// "Continue without signing in" is an answer for that launch, not
    /// forever. That is the whole difference between a login screen and a
    /// first-run screen, and it is why an install that has already resolved
    /// the old gate starts asking again.
    static func needsSignIn(_ defaults: UserDefaults = .standard) -> Bool {
        !defaults.bool(forKey: signedInDefaultsKey)
    }

    /// **Unset defaults to signed in** — so an install predating the gate
    /// shows the signed-in experience without clicking through a login.
    /// Only the explicit string `"false"` — exactly what "Log out"/
    /// "Continue without signing in" write — means signed out. Deliberately
    /// the mirror image of the `"true"`-only convention `authGateResolved`
    /// is written with, for the opposite default.
    static func resolveSignedIn(_ settingValue: String?) -> Bool {
        settingValue != "false"
    }

    /// `nil` for an unknown/empty id — callers treat that as "no answer".
    static func personaLabel(_ id: String?) -> String? {
        guard let id, !id.isEmpty else { return nil }
        return personaOptions.first { $0.id == id }?.label
    }

    /// The Settings screen's Account section summary line.
    ///
    /// Prefers the real account (email + optional display name) whenever an
    /// `auth_account_email` row exists; `fakeAccountName` + "(dev mode)"
    /// survives only as the rendering of legacy rows persisted by the
    /// fake-login build, which wrote no account keys at all.
    static func describeAuthSummary(
        signedInRaw: String?,
        personaRaw: String?,
        accountEmailRaw: String?,
        accountNameRaw: String?
    ) -> String {
        guard resolveSignedIn(signedInRaw) else { return "Not signed in (dev mode)." }
        let email = (accountEmailRaw ?? "").trimmingCharacters(in: .whitespaces)
        if !email.isEmpty {
            let name = (accountNameRaw ?? "").trimmingCharacters(in: .whitespaces)
            if let label = personaLabel(personaRaw) {
                return "\(name.isEmpty ? email : name) — \(label)."
            }
            return name.isEmpty ? "\(email)." : "\(name) (\(email))."
        }
        if let label = personaLabel(personaRaw) {
            return "\(fakeAccountName) — \(label)."
        }
        return "\(fakeAccountName) (dev mode)."
    }
}
