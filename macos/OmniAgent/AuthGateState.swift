import Foundation

/// The sign-in + "getting to know you" gate's pure state — originally a
/// direct port of `ui/src/onboarding/authGateState.ts`, kept as a pure
/// reducer so the phase transitions are unit-testable without
/// `AuthGateView`/`NSHostingController`/a socket/a network.
///
/// The login is real: `AuthGateViewModel` runs Apple's or GitHub's web
/// sign-in and redeems the result at Core's `/v1/auth/<provider>/exchange`
/// through `AuthClient`, and only dispatches `.signedIn` after the server
/// said yes. There is no way through without it (2026-08-30 account-scoped
/// workspace spec: "It's not allowed anymore to use the app without being
/// logged on") — the "Continue without signing in" escape hatch is gone.
///
/// Between sign-in and the persona question sits `.switching`: the window
/// controller moves the daemon onto the account's own data directory, then
/// reports what that directory already knows (`.accountReady`). An account
/// that answered the persona question before is not asked again.
enum AuthGatePhase: Equatable {
    case login
    /// "Opening your workspace…" — the account switch is running.
    case switching
    case personalize
    case resolved
}

struct AuthGateOutcome: Equatable {
    /// Always `true` for an outcome the gate produces now; kept because the
    /// Settings screen and `AuthGateCoordinator.persist` read it, and it is
    /// the field a log-out writes `false` through.
    let signedIn: Bool
    /// The selected `PersonaOption.id`, or `nil` if the personalization
    /// question was skipped.
    let persona: String?
    /// The Core account's email address.
    let accountEmail: String?
    /// The account's display name ("Bruno Bonando"), or `nil` when the
    /// server has none for it.
    let accountName: String?
    /// The GitHub handle linked to the account, or `nil` when none is.
    /// Defaulted, and the one `var` here, so the constructions that have
    /// nothing to say about GitHub stay about what they are testing;
    /// `AuthGateState.accountEmail` below sets the same precedent.
    var githubLogin: String? = nil
    /// The account's profile-picture URL, or `nil` when it has none.
    /// Defaulted for `githubLogin`'s reason.
    var accountPicture: String? = nil
}

struct AuthGateState: Equatable {
    var phase: AuthGatePhase
    /// Non-nil exactly when `phase == .resolved`.
    var outcome: AuthGateOutcome?
    /// The signed-in identity, carried from `.signedIn` through the
    /// switching and personalize phases into the outcome.
    var accountEmail: String? = nil
    var accountName: String? = nil
    var githubLogin: String? = nil
    var accountPicture: String? = nil
}

enum AuthGateAction: Equatable {
    /// A *successful* real login — `AuthGateViewModel` dispatches this only
    /// after `AuthClient` returned a user; the reducer never sees a failed
    /// attempt (that stays view-model state as `errorMessage`).
    case signedIn(email: String, displayName: String?, githubLogin: String?, picture: String?)
    /// The account switch finished and the account's data dir was read:
    /// `persona` is its `auth_persona` row, `nil`/empty when it never
    /// answered. Dispatched by `AuthGateViewModel` from the `onSwitching`
    /// hook's answer.
    case accountReady(persona: String?)
    case answerSelected(persona: String)
    case skipPersonalize
}

enum AuthGateReducer {
    static let initial = AuthGateState(phase: .login, outcome: nil)

    static func reduce(_ state: AuthGateState, _ action: AuthGateAction) -> AuthGateState {
        switch action {
        case let .signedIn(email, displayName, githubLogin, picture):
            guard state.phase == .login else { return state }
            return AuthGateState(
                phase: .switching,
                outcome: nil,
                accountEmail: email,
                accountName: displayName,
                githubLogin: githubLogin,
                accountPicture: picture
            )

        case let .accountReady(persona):
            guard state.phase == .switching else { return state }
            if let persona, !persona.isEmpty {
                return resolved(state, persona: persona)
            }
            return AuthGateState(
                phase: .personalize,
                outcome: nil,
                accountEmail: state.accountEmail,
                accountName: state.accountName,
                githubLogin: state.githubLogin,
                accountPicture: state.accountPicture
            )

        case let .answerSelected(persona):
            guard state.phase == .personalize else { return state }
            return resolved(state, persona: persona)

        case .skipPersonalize:
            guard state.phase == .personalize else { return state }
            return resolved(state, persona: nil)
        }
    }

    private static func resolved(_ state: AuthGateState, persona: String?) -> AuthGateState {
        AuthGateState(
            phase: .resolved,
            outcome: AuthGateOutcome(
                signedIn: true,
                persona: persona,
                accountEmail: state.accountEmail,
                accountName: state.accountName,
                githubLogin: state.githubLogin,
                accountPicture: state.accountPicture
            ),
            accountEmail: state.accountEmail,
            accountName: state.accountName,
            githubLogin: state.githubLogin,
            accountPicture: state.accountPicture
        )
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
    /// The gate latches on *signed in*: only a real sign-in puts it away,
    /// and a log-out brings it back — a login screen, not a first-run one.
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
