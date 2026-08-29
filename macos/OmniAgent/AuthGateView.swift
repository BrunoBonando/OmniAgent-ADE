import AppKit
import AuthenticationServices
import SwiftUI

/// The I/O half of the auth gate: whether it needs showing, and persisting
/// whichever way it resolves — the three keys the web build's
/// `App.tsx`/`handleAuthGateResolved` established plus the four native-first
/// account rows real login added, behind `SettingsStore` so it is testable
/// without a socket. `AuthGateState.swift` owns the phase transitions;
/// `AuthGateWindowController` below owns turning this into a sheet on
/// screen.
final class AuthGateCoordinator {
    let settings: SettingsStore
    /// Where the signed-in flag is mirrored, so the launch decision can be
    /// made with no socket at all — see `AuthGate.needsSignIn(_:)`. Injectable
    /// so a test never writes the real app's defaults.
    let defaults: UserDefaults

    init(settings: SettingsStore, defaults: UserDefaults = .standard) {
        self.settings = settings
        self.defaults = defaults
    }

    /// Persists all seven keys the gate cares about and completes once every
    /// write has landed (or failed — a write failing here still dismisses
    /// the gate rather than trapping the user behind a broken settings row;
    /// the same "fail open" posture `App.tsx`'s own boot check documents).
    func resolve(_ outcome: AuthGateOutcome, completion: @escaping () -> Void) {
        persist(
            resolved: "true",
            signedIn: outcome.signedIn ? "true" : "false",
            persona: outcome.persona ?? "",
            accountEmail: outcome.accountEmail ?? "",
            accountName: outcome.accountName ?? "",
            githubLogin: outcome.githubLogin ?? "",
            accountPicture: outcome.accountPicture ?? "",
            completion: completion
        )
    }

    /// "Log out" / "Sign in" from the Settings screen's Account section —
    /// clears the persisted outcome (account identity included) so the gate
    /// shows again at the next launch, and offers the same view as a sheet
    /// right now without needing one.
    func reset(completion: @escaping () -> Void) {
        persist(
            resolved: "false",
            signedIn: "false",
            persona: "",
            accountEmail: "",
            accountName: "",
            githubLogin: "",
            accountPicture: "",
            completion: completion
        )
    }

    /// The Settings screen's Account section summary line. Chained
    /// single-key reads rather than `SettingsStore`'s batched `get([String])`
    /// on purpose: `DispatchGroup.notify` always hops a queue turn, even
    /// when every read already answered synchronously (as a test's fake
    /// client does), which would make this resolve one run-loop turn later
    /// than every other read in this file for no real benefit here — four
    /// keys is cheap enough to chain directly.
    func summary(completion: @escaping (String) -> Void) {
        settings.get(SettingsKey.authSignedIn) { [settings] signedInResult in
            let signedInRaw = try? signedInResult.get()
            settings.get(SettingsKey.authPersona) { personaResult in
                let personaRaw = try? personaResult.get()
                settings.get(SettingsKey.authAccountEmail) { emailResult in
                    let emailRaw = try? emailResult.get()
                    settings.get(SettingsKey.authAccountName) { nameResult in
                        let nameRaw = try? nameResult.get()
                        completion(AuthGate.describeAuthSummary(
                            signedInRaw: signedInRaw,
                            personaRaw: personaRaw,
                            accountEmailRaw: emailRaw,
                            accountNameRaw: nameRaw
                        ))
                    }
                }
            }
        }
    }

    /// Chained rather than fired in parallel behind a `DispatchGroup`, for
    /// the same reason `summary` chains its reads: `DispatchGroup.notify`
    /// always hops a queue turn, even against a synchronous fake client,
    /// which would make `completion` land a run-loop turn later than every
    /// write actually finished. Seven tiny writes in sequence costs nothing
    /// a user would notice.
    private func persist(
        resolved: String,
        signedIn: String,
        persona: String,
        accountEmail: String,
        accountName: String,
        githubLogin: String,
        accountPicture: String,
        completion: @escaping () -> Void
    ) {
        // Written first and synchronously: this is the only copy the launch
        // decision can read, and it must be true before the workspace window
        // it gates is allowed on screen. The rows below stay the source of
        // truth for everything the Settings screen shows.
        defaults.set(signedIn == "true", forKey: AuthGate.signedInDefaultsKey)
        settings.set(SettingsKey.authGateResolved, resolved) { [settings] _ in
            settings.set(SettingsKey.authSignedIn, signedIn) { _ in
                settings.set(SettingsKey.authPersona, persona) { _ in
                    settings.set(SettingsKey.authAccountEmail, accountEmail) { _ in
                        settings.set(SettingsKey.authAccountName, accountName) { _ in
                            settings.set(SettingsKey.authGithubLogin, githubLogin) { _ in
                                settings.set(SettingsKey.authAccountPicture, accountPicture) { _ in
                                    completion()
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

/// The one seam between the gate's UI and the network: `AuthGateViewModel`
/// signs in through this, production wires `AuthClient.shared`, and tests
/// wire a stub — nothing else about the view model needs a server.
///
/// Both halves of a web flow are here because both depend on the server the
/// app is pointed at: the authorize URL carries Core's own `redirect_uri`
/// (or, for GitHub, *is* a Core route), so a stub can answer with a URL no
/// test will ever open. The link/unlink pair and `restoreSession` come along
/// because "Connect GitHub…" needs a bearer token before it needs a browser.
protocol AuthSigning {
    /// `nil` until a login or a refresh lands. Read — never written —
    /// by the view model, to decide whether a link call needs a
    /// `restoreSession()` in front of it.
    var accessToken: String? { get }
    func authorizeURL(for provider: AuthProvider, state: String, nonce: String) -> URL
    func login(with provider: AuthProvider, code: String, codeVerifier: String, nonce: String) async throws -> AuthUser
    func linkGitHub(state: String, nonce: String) async throws
    func disconnectGitHub() async throws
    func restoreSession() async throws -> AuthUser
}

extension AuthClient: AuthSigning {}

/// How one Settings › Accounts GitHub operation ended. Exactly one of these
/// is reported on every path — including the ones that never reach the
/// network — so the caller's in-flight flag can never be left up, which is
/// the failure that blocks the button for the rest of the launch.
enum AuthLinkOutcome: Equatable {
    /// Done, with the account's GitHub handle as it now stands. A connect
    /// reports what it linked; a **disconnect reports `nil`** — linked to
    /// nothing is exactly what it leaves behind, and it lets both buttons
    /// end in the same one-line "write the row and re-read the section".
    case linked(githubLogin: String?)
    /// The user backed out on GitHub's page, or closed the browser. Nothing
    /// to write and nothing to read.
    case cancelled
    /// It failed, with the sentence to show for it.
    case failed(String)
}

/// Dispatches `AuthGateAction`s against the pure reducer, republishes the
/// result for SwiftUI, and owns the async sign-in work: the reducer only
/// ever sees a *successful* login (as `.signedIn`), while in-flight and
/// failed attempts live here as `isBusy`/`errorMessage`.
///
/// Two jobs, one object — see `intent`. The login screen's own model signs
/// in; Settings › Accounts builds a second one to connect or disconnect
/// GitHub on an account that is *already* signed in. The browser round trip
/// is the same one either way; only where the result goes differs (the gate
/// reducer, or `onLinkOutcome`).
final class AuthGateViewModel: ObservableObject {
    /// What this model is for. `.signIn` resolves the gate; `.linkGitHub`
    /// serves Settings › Accounts' GitHub pair and never touches the
    /// reducer — there is no gate to resolve, the account is signed in
    /// already.
    enum Intent: Equatable {
        case signIn
        case linkGitHub
    }

    @Published private(set) var state = AuthGateReducer.initial
    /// The sign-in round trip is in flight — from the moment the browser
    /// opens until the exchange lands. The screen disables its controls off
    /// this instead of racing double-submits.
    @Published private(set) var isBusy = false
    /// The last failed attempt's human-readable reason, cleared on the next
    /// attempt. `nil` while nothing has failed.
    @Published private(set) var errorMessage: String?
    var onResolved: ((AuthGateOutcome) -> Void)?
    /// Where a `.linkGitHub` model reports instead of the reducer — exactly
    /// once per `connectGitHub()`/`disconnectGitHub()`, on every path.
    var onLinkOutcome: ((AuthLinkOutcome) -> Void)?
    /// The window the web sign-in anchors its browser sheet to — the login
    /// window for the gate (set by `AuthGateWindowController`), the
    /// workspace window for a link (set by `WorkspaceWindowController`).
    var presentationWindow: (() -> NSWindow?)?
    /// How the browser sheet is opened, answering whether it could be put on
    /// screen. `nil` is the real `ASWebAuthenticationSession`; a test wires
    /// this to see *which* URL the flow reached — which is half of what
    /// "connect GitHub" means — without a browser ever appearing.
    var webAuthOpener: ((URL) -> Bool)?

    let intent: Intent

    /// This attempt's PKCE secrets. Regenerated by every press of a provider
    /// button, so a callback left over from an abandoned attempt fails the
    /// `state` comparison in `handleCallback` instead of being redeemed.
    private(set) var pkce = PKCE()

    /// Whose flow is running: written just before the browser opens, and
    /// what `handleCallback` requires an arriving callback to be from.
    /// Internal rather than private because a test drives `handleCallback`
    /// directly — standing in for the browser, and so for this write too.
    var attemptProvider: AuthProvider = .apple

    /// The URL scheme Core bounces the browser back into. Registered in
    /// `macos/OmniAgent/Info.plist`; `ASWebAuthenticationSession` matches the
    /// callback on it and hands the URL straight to this object, so the app's
    /// own `application(_:open:)` never sees it.
    static let callbackScheme = "omniagent"

    /// Shown when the browser closed without either a usable callback or an
    /// error to quote — a state no completed flow produces, so it says the
    /// one useful thing rather than inventing a cause.
    static let incompleteMessage = "Sign-in didn't complete — try again."

    /// Shown for any callback that cannot prove it belongs to the running
    /// attempt: the wrong provider's path, or a `state` that isn't this
    /// attempt's PKCE state — a stale callback from an abandoned attempt, a
    /// URL some other process fabricated, or a page inside the authorize
    /// flow trying to put its own words on this screen. Nothing in such a
    /// URL is read — not the code, and not its `error` text either.
    static let stateMismatchMessage = "Sign-in response didn't match this app — try again."

    /// Shown when a GitHub connect or disconnect has no session behind it.
    /// GitHub is linked *onto* an OmniAgent account rather than being an
    /// account of its own here, so with no session there is nothing to link
    /// it to — and telling the user to sign in is the only move that helps.
    static let signInFirstMessage = "Sign in first — GitHub connects to your OmniAgent account."

    private let signer: AuthSigning
    /// Retains the running web-auth session and its presentation anchor —
    /// `ASWebAuthenticationSession` keeps neither itself nor its
    /// `presentationContextProvider` alive (the latter is a weak reference),
    /// so without these two the browser closes the instant `start()` returns.
    private var webAuthSession: ASWebAuthenticationSession?
    private var anchorProvider: AuthPresentationAnchor?

    init(signer: AuthSigning = AuthClient.shared, intent: Intent = .signIn) {
        self.signer = signer
        self.intent = intent
        // A link model only ever runs GitHub's flow, so its attempt is armed
        // from the start rather than at the browser.
        if intent == .linkGitHub { attemptProvider = .github }
    }

    func send(_ action: AuthGateAction) {
        state = AuthGateReducer.reduce(state, action)
        if state.phase == .resolved, let outcome = state.outcome {
            onResolved?(outcome)
        }
    }

    /// Opens `provider`'s web sign-in in a `ASWebAuthenticationSession`
    /// browser sheet anchored to the login window. The session watches for
    /// the `omniagent://` callback Core bounces the browser into and hands
    /// the URL to `handleCallback`; a cancel closes it silently.
    ///
    /// Apple's is not the native `ASAuthorizationController` flow, and it
    /// cannot be: that needs the restricted `com.apple.developer.applesignin`
    /// entitlement, which Developer ID distribution cannot carry (Apple DTS
    /// — see `OmniAgent.entitlements`). GitHub's has no native flow to want.
    @MainActor
    func signIn(with provider: AuthProvider) {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        // A fresh verifier per attempt: the previous one's callback must not
        // be redeemable after the user backs out and starts again.
        pkce = PKCE()
        openBrowser(for: provider)
    }

    /// "Connect GitHub…" on Settings › Accounts. Two steps, in this order and
    /// no other: Core is told to expect this attempt's `state`/`nonce` **on
    /// the signed-in account** — a bearer call — before the browser is sent
    /// anywhere. Start the browser first and the callback comes back as a
    /// second identity rather than a link.
    @MainActor
    func connectGitHub() {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        pkce = PKCE()
        let attempt = pkce
        Task { @MainActor in
            do {
                try await authorized { try await $0.linkGitHub(state: attempt.state, nonce: attempt.nonce) }
            } catch {
                fail(Self.gitHubMessage(for: error))
                return
            }
            openBrowser(for: .github)
        }
    }

    /// "Disconnect" on Settings › Accounts. No browser and no callback: one
    /// bearer `DELETE`, reported through `onLinkOutcome` exactly as a
    /// connect is, so the caller has one ending to handle rather than two.
    @MainActor
    func disconnectGitHub() {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        Task { @MainActor in
            do {
                try await authorized { try await $0.disconnectGitHub() }
                isBusy = false
                onLinkOutcome?(.linked(githubLogin: nil))
            } catch {
                fail(Self.gitHubMessage(for: error))
            }
        }
    }

    /// Runs a bearer-authorized call, refreshing the session first when
    /// there is no token in hand. The access token is in memory only, so a
    /// launch that has not refreshed yet has none while the refresh cookie
    /// in URLSession's jar is still perfectly good — that gap is exactly
    /// what this closes.
    private func authorized(_ body: (AuthSigning) async throws -> Void) async throws {
        if signer.accessToken == nil { _ = try await signer.restoreSession() }
        try await body(signer)
    }

    /// The `omniagent://auth/<provider>?…` URL Core bounces the browser into,
    /// turned into either a signed-in state, a link, or a message. Internal
    /// (not private) because this — not the browser sheet — is where every
    /// decision in the flow lives, and a test can drive it directly.
    @MainActor
    func handleCallback(_ url: URL) async {
        // The callback means a request is under way even when the attempt
        // that opened the browser belongs to an earlier run loop turn.
        isBusy = true
        errorMessage = nil
        // Whose callback is this? The session intercepts *any* `omniagent://`
        // navigation its browser makes, so a GitHub attempt can be handed an
        // `/auth/apple` URL — by an abandoned attempt, or by a page inside
        // the flow. A callback from a provider this attempt never went to
        // proves nothing about it, so it is refused before anything in it is
        // read, in the app's own words.
        guard AuthProvider.callbackPath(of: url) == attemptProvider.callbackPath else {
            fail(Self.stateMismatchMessage)
            return
        }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? {
            query.first { $0.name == name }?.value.flatMap { $0.isEmpty ? nil : $0 }
        }
        // `state` next, before a single field of this URL is believed —
        // including `error`, which is shown to the user verbatim. A page
        // reached from inside the authorize flow (an open redirect, an
        // injected page) could otherwise write its own sentence into this
        // app's error label as first-party copy. Core sends `state` on its
        // error callbacks too, so nothing legitimate is lost.
        guard value("state") == pkce.state else {
            fail(Self.stateMismatchMessage)
            return
        }
        if let failure = value("error") {
            // Backing out on the provider's page is the one `error` that is
            // not an error: Apple and GitHub each form-post their own
            // identifier for it (`user_cancelled_authorize`,
            // `access_denied`) and Core relays that verbatim, so quoting it
            // would put a protocol token on screen as this app's copy. The
            // guards above have already run, so a forged cancel never
            // reaches here — it gets the mismatch message like any other
            // callback that cannot prove it belongs to this attempt.
            guard failure != attemptProvider.cancelError else {
                cancel()
                return
            }
            // Otherwise: Core's own words for what the provider (or its own
            // callback) refused — it is the only side that knows.
            fail(failure)
            return
        }
        guard let code = value("code") else {
            fail(Self.incompleteMessage)
            return
        }
        await complete(code: code)
    }

    /// Redeems the one-time code at `/v1/auth/<provider>/exchange` and hands
    /// the account on: to the reducer as `.signedIn` for the gate, or to
    /// `onLinkOutcome` for a link, which has no gate to resolve.
    @MainActor
    private func complete(code: String) async {
        let attempt = pkce
        do {
            let user = try await signer.login(
                with: attemptProvider,
                code: code,
                codeVerifier: attempt.verifier,
                nonce: attempt.nonce
            )
            isBusy = false
            switch intent {
            case .signIn:
                send(.signedIn(
                    email: user.email,
                    displayName: Self.displayName(of: user),
                    githubLogin: user.githubLogin,
                    picture: user.picture
                ))
            case .linkGitHub:
                onLinkOutcome?(.linked(githubLogin: user.githubLogin))
            }
        } catch {
            fail(Self.message(for: error))
        }
    }

    @MainActor
    private func failWebAuth(_ error: Error?) {
        if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
            cancel() // the user closed the browser
            return
        }
        fail(error.map { Self.message(for: $0) } ?? Self.incompleteMessage)
    }

    /// Every dead end in one place: the screen comes back with something to
    /// read, and a link model — which has no screen of its own — reports the
    /// same sentence to whoever asked for the link.
    @MainActor
    private func fail(_ message: String) {
        isBusy = false
        errorMessage = message
        if intent == .linkGitHub { onLinkOutcome?(.failed(message)) }
    }

    /// The user backed out. There are two ways to do it — closing the
    /// browser window, and Cancel on the provider's page — and they arrive on
    /// opposite paths (a session error, a callback URL) for one intent, so
    /// they end the same way: the screen as they left it, ready to try
    /// again, with nothing to read. Routing both through here is also what
    /// lets a `handleCallback` test cover the browser-close branch, which no
    /// test can reach directly.
    @MainActor
    private func cancel() {
        isBusy = false
        errorMessage = nil
        if intent == .linkGitHub { onLinkOutcome?(.cancelled) }
    }

    /// Builds and starts the browser sheet for `provider`, arming this
    /// attempt with it.
    @MainActor
    private func openBrowser(for provider: AuthProvider) {
        attemptProvider = provider
        let url = signer.authorizeURL(for: provider, state: pkce.state, nonce: pkce.nonce)
        if let webAuthOpener {
            // The same contract `start()` has below: false means nothing
            // could be put on screen, which must lower `isBusy` rather than
            // leave a disabled button with nothing to press.
            if !webAuthOpener(url) { fail(Self.incompleteMessage) }
            return
        }
        let anchor = AuthPresentationAnchor { [weak self] in self?.presentationWindow?() }
        let session = ASWebAuthenticationSession(
            url: url,
            callbackURLScheme: Self.callbackScheme
        ) { [weak self] url, error in
            Task { @MainActor in
                guard let self else { return }
                self.webAuthSession = nil
                self.anchorProvider = nil
                if let url {
                    await self.handleCallback(url)
                } else {
                    self.failWebAuth(error)
                }
            }
        }
        session.presentationContextProvider = anchor
        // Deliberately not ephemeral: reusing Safari's cookies is what makes
        // the second sign-in a single click instead of a full password + 2FA
        // round trip.
        session.prefersEphemeralWebBrowserSession = false
        anchorProvider = anchor
        webAuthSession = session
        // `start()` answers false when the browser could not be put on
        // screen at all. Ignoring that would leave `isBusy` up forever, with
        // the button disabled and nothing to press — the one failure mode
        // this screen must never have.
        guard session.start() else {
            webAuthSession = nil
            anchorProvider = nil
            fail(Self.incompleteMessage)
            return
        }
    }

    /// What the gate calls this account: the server's `name` when set, else
    /// first + last joined, else nothing (the email then stands alone).
    static func displayName(of user: AuthUser) -> String? {
        if let name = user.name?.trimmingCharacters(in: .whitespaces), !name.isEmpty {
            return name
        }
        let joined = [user.firstName, user.lastName]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return joined.isEmpty ? nil : joined
    }

    private static func message(for error: Error) -> String {
        (error as? AuthError)?.errorDescription ?? error.localizedDescription
    }

    /// `message(for:)`, except that "your session expired" is the wrong
    /// thing to tell someone whose GitHub button needs an account: on these
    /// two paths a dead session means *sign in*, which is what to say.
    private static func gitHubMessage(for error: Error) -> String {
        (error as? AuthError) == .sessionExpired ? signInFirstMessage : message(for: error)
    }
}

/// Says which window the web-auth browser sheet hangs off. A separate object
/// only because `ASWebAuthenticationPresentationContextProviding` requires
/// NSObject, which an otherwise pure `ObservableObject` view model has no
/// business becoming.
private final class AuthPresentationAnchor: NSObject, ASWebAuthenticationPresentationContextProviding {
    private let anchor: () -> NSWindow?

    init(anchor: @escaping () -> NSWindow?) {
        self.anchor = anchor
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        anchor() ?? NSApp.keyWindow ?? NSWindow()
    }
}

/// The gate's two screens: the real sign-in screen from
/// `design/OmniAgent ADE.dc.html`'s `data-screen-label="Sign in"` (story
/// panel + 452px auth card, now with a provider button each for Apple and
/// GitHub), and the personalize question carried over unchanged from the
/// previous build.
///
/// Animation policy (hard-won): at most one one-shot opacity/offset on
/// appear, driven by a single `withAnimation` — nested animation groups have
/// SIGSEGV'd the test host before — and even that is skipped under
/// Reduce Motion. The design's drifting blobs, typing loop and blinking
/// carets are all deliberately static here.

/// GitHub's official mark, bundled as a base64-encoded PNG rather than a
/// bundle resource — SF Symbols has no GitHub glyph to reach for the way
/// `applelogo` does. `isTemplate` is what lets it tint the same way an SF
/// Symbol image does.
enum GitHubMark {
    static let image: NSImage? = {
        guard let d = Data(base64Encoded: base64) else { return nil }
        let i = NSImage(data: d)
        i?.isTemplate = true
        return i
    }()

    private static let base64 = "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"
}

struct AuthGateContentView: View {
    @ObservedObject var model: AuthGateViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedPersona: String?
    @State private var appeared = false
    @State private var hoveredApple = false
    @State private var hoveredGitHub = false

    /// The whole two-panel screen; the story panel gets whatever is left.
    /// Internal because `AuthGateWindowController` sizes the gate's window
    /// from it — the window is this screen and nothing else.
    static let sheetSize = CGSize(width: 1040, height: 640)
    private static let cardWidth: CGFloat = 452

    var body: some View {
        Group {
            switch model.state.phase {
            case .login:
                signInScreen
            case .personalize:
                personalizeScreen
                    .frame(width: 420)
                    .padding(28)
            case .resolved:
                Color.clear.frame(width: 420, height: 240)
            }
        }
        .background(OmniAgentPalette.background)
        .foregroundStyle(OmniAgentPalette.textPrimary)
    }

    // MARK: - Sign in (design: div[data-screen-label="Sign in"])

    private var signInScreen: some View {
        HStack(spacing: 0) {
            storyPanel
            authCard
        }
        .frame(width: Self.sheetSize.width, height: Self.sheetSize.height)
        .background(SignInPalette.screenBackground)
        .onAppear {
            if reduceMotion {
                appeared = true
            } else {
                withAnimation(.easeOut(duration: 0.45)) { appeared = true }
            }
        }
    }

    // MARK: Story panel

    private var storyPanel: some View {
        ZStack(alignment: .topLeading) {
            SignInPalette.storyBackground
            // The design's three drifting gradient blobs, held still.
            blob(SignInPalette.indigo.opacity(0.42), diameter: 520)
                .position(x: 170, y: 120)
            blob(Color.omniRGB(217, 119, 87, 0.30), diameter: 560, blurRadius: 34)
                .position(x: 428, y: 540)
            blob(Color.omniRGB(49, 134, 255, 0.26), diameter: 380)
                .position(x: 390, y: 433)
            gridOverlay
            storyContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    private func blob(_ color: Color, diameter: CGFloat, blurRadius: CGFloat = 30) -> some View {
        Circle()
            .fill(RadialGradient(
                colors: [color, color.opacity(0)],
                center: .center,
                startRadius: 0,
                endRadius: diameter / 2
            ))
            .frame(width: diameter, height: diameter)
            .blur(radius: blurRadius)
            .allowsHitTesting(false)
    }

    /// The faint 46px grid, faded out radially from the upper-left the way
    /// the design's mask-image does.
    private var gridOverlay: some View {
        Canvas { context, size in
            var lines = Path()
            var x: CGFloat = 0
            while x <= size.width {
                lines.move(to: CGPoint(x: x, y: 0))
                lines.addLine(to: CGPoint(x: x, y: size.height))
                x += 46
            }
            var y: CGFloat = 0
            while y <= size.height {
                lines.move(to: CGPoint(x: 0, y: y))
                lines.addLine(to: CGPoint(x: size.width, y: y))
                y += 46
            }
            context.stroke(lines, with: .color(.white.opacity(0.035)), lineWidth: 0.5)
        }
        .mask(
            RadialGradient(
                gradient: Gradient(stops: [
                    .init(color: .black, location: 0.2),
                    .init(color: .clear, location: 0.75),
                ]),
                center: UnitPoint(x: 0.3, y: 0.3),
                startRadius: 0,
                endRadius: 620
            )
        )
        .allowsHitTesting(false)
    }

    private var storyContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            logoRow
            Spacer(minLength: 0)
            headlineBlock
            Spacer(minLength: 0)
            statusBullets
        }
        .padding(EdgeInsets(top: 38, leading: 42, bottom: 38, trailing: 42))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .opacity(appeared ? 1 : 0)
    }

    private var logoRow: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                .resizable()
                .frame(width: 34, height: 34)
            Text("OmniAgent")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(SignInPalette.primaryText)
            Text("ADE 0.9")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(SignInPalette.chipText)
                .padding(EdgeInsets(top: 3, leading: 7, bottom: 3, trailing: 7))
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.07)))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.white.opacity(0.1), lineWidth: 0.5))
        }
    }

    private var headlineBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Design: 51px/1.12, -.025em. `minimumScaleFactor` absorbs the
            // difference between the design's full-width story panel and
            // this sheet's narrower one without ever truncating.
            Text("Every agent, one window,\none shared brain.")
                .font(.system(size: 51, weight: .semibold))
                .kerning(-1.2)
                .lineSpacing(4)
                .minimumScaleFactor(0.7)
                .lineLimit(2)
                .foregroundStyle(SignInPalette.headline)
                .padding(.bottom, 16)
            Text(
                "Run Claude Code, Codex, AntiGravity and plain shells side by side. "
                    + "They stay briefed on the same local graph of your codebase — and you keep the approvals."
            )
            .font(.system(size: 16))
            .lineSpacing(7)
            .foregroundStyle(SignInPalette.bodyText)
            .frame(maxWidth: 430, alignment: .leading)
            .padding(.bottom, 26)
            activityCard
        }
        .frame(maxWidth: 520, alignment: .leading)
    }

    /// The agent-activity card — static rows, no typing loop, no blinking
    /// caret (see the type comment's animation policy).
    private var activityCard: some View {
        VStack(alignment: .leading, spacing: 7) {
            activityRow(engine: .claude, text: "● Edit src/auth/token.service.ts — 12 tests green")
            activityRow(engine: .codex, text: "▸ Wrote 4 replay cases for webhooks")
            activityRow(engine: .antigravity, text: "◆ Migration 0043 ready to apply")
            HStack(spacing: 8) {
                Spacer().frame(width: 12)
                Text("❯")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(SignInPalette.periwinkle)
                RoundedRectangle(cornerRadius: 1)
                    .fill(SignInPalette.periwinkle)
                    .frame(width: 7, height: 13)
            }
            .padding(.top, 2)
        }
        .padding(12)
        .frame(width: 440, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 11).fill(Color.omniRGB(10, 10, 14, 0.55)))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(Color.white.opacity(0.09), lineWidth: 0.5))
    }

    private func activityRow(engine: Engine, text: String) -> some View {
        HStack(spacing: 8) {
            if let icon = engine.iconImage {
                Image(nsImage: icon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 17, height: 17)
            }
            Text(text)
                .font(.system(size: 12.5, design: .monospaced))
                .foregroundStyle(SignInPalette.monoText)
                .lineLimit(1)
        }
    }

    /// The design lays these in one row across a much wider panel; stacked
    /// here so nothing wraps or truncates at this sheet's width.
    private var statusBullets: some View {
        VStack(alignment: .leading, spacing: 8) {
            statusBullet(SignInPalette.green, "Local-first — graph and transcripts stay on disk")
            statusBullet(SignInPalette.periwinkle, "Stock engines, unmodified")
            statusBullet(SignInPalette.amber, "You approve every write")
        }
    }

    private func statusBullet(_ dot: Color, _ text: String) -> some View {
        HStack(spacing: 6) {
            Circle().fill(dot).frame(width: 5, height: 5)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(SignInPalette.mutedText)
        }
    }

    // MARK: Auth card

    private var authCard: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 0) {
                Text("Welcome back")
                    .font(.system(size: 27, weight: .semibold))
                    .foregroundStyle(SignInPalette.titleText)
                    .padding(.bottom, 6)
                Text("Sign in to sync your settings and license.")
                    .font(.system(size: 15))
                    .foregroundStyle(SignInPalette.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 22)

                // The two ways in. Password sign-in left with the web
                // build; the provider web flows are the whole login screen
                // now.
                appleButton
                githubButton
                    .padding(.top, 10)

                if let message = model.errorMessage {
                    Text(message)
                        .font(.system(size: 13))
                        .foregroundStyle(SignInPalette.errorText)
                        .fixedSize(horizontal: false, vertical: true)
                        // Wraps, but only so far: the card is a fixed 640pt,
                        // and a long server `detail` left unbounded pushes
                        // the skip link and the footer off the bottom of it.
                        .lineLimit(3)
                        .padding(.top, 12)
                }

                skipLink
                    .padding(.top, 16)

                privacyFooter
                    .padding(.top, 22)
            }
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 10)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 48)
        .frame(width: Self.cardWidth, height: Self.sheetSize.height)
        .background(SignInPalette.cardBackground)
        .overlay(alignment: .leading) {
            Rectangle().fill(Color.white.opacity(0.08)).frame(width: 0.5)
        }
    }

    private var appleButton: some View {
        providerButton(title: "Continue with Apple", symbol: "applelogo", hovered: $hoveredApple) {
            model.signIn(with: .apple)
        }
    }

    /// GitHub's mark comes from `GitHubMark.image` (a bundled bitmap, since
    /// SF Symbols has no GitHub glyph) — `providerButton` reaches for it
    /// whenever `symbol` is nil. If it fails to decode, the row falls back
    /// to the word alone, same as before.
    private var githubButton: some View {
        providerButton(title: "Continue with GitHub", symbol: nil, hovered: $hoveredGitHub) {
            model.signIn(with: .github)
        }
    }

    /// One provider row, drawn the same for every provider — both buttons go
    /// dead together while an attempt is in flight, since a second browser
    /// sheet over the first is not a thing this screen can recover from.
    private func providerButton(
        title: String,
        symbol: String?,
        hovered: Binding<Bool>,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Color.omniRGB(245, 245, 247))
                } else if let mark = GitHubMark.image {
                    Image(nsImage: mark)
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 16, height: 16)
                        .foregroundStyle(Color.omniRGB(245, 245, 247))
                }
                Text(title)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(SignInPalette.primaryText)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.35))
            }
            .padding(.horizontal, 13)
            .frame(height: 42)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(Color.white.opacity(hovered.wrappedValue ? 0.1 : 0.055))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .stroke(Color.white.opacity(hovered.wrappedValue ? 0.22 : 0.12), lineWidth: 0.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .onHover { hovered.wrappedValue = $0 }
        .disabled(model.isBusy)
    }

    /// Founder direction: the dev escape hatch stays — the API may be
    /// unreachable, and the app is useful without an account.
    private var skipLink: some View {
        Button("Continue without signing in") { model.send(.skipLogin) }
            .buttonStyle(.plain)
            .font(.system(size: 12.5))
            .foregroundStyle(SignInPalette.faintText)
            .frame(maxWidth: .infinity)
            .disabled(model.isBusy)
    }

    private var privacyFooter: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "checkmark.shield")
                .font(.system(size: 14))
                .foregroundStyle(SignInPalette.green)
            Text("Your account only syncs settings and license. Code, transcripts and the brain never leave this Mac.")
                .font(.system(size: 12.5))
                .lineSpacing(3)
                .foregroundStyle(SignInPalette.faintText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 16)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.white.opacity(0.07)).frame(height: 0.5)
        }
    }

    // MARK: - Personalize (unchanged from the previous build)

    private var personalizeScreen: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("> getting to know you_")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(OmniAgentPalette.accent)
            Text("What best describes what you'll use OmniAgent for?")
                .font(.title2.bold())
            Text("Doesn't change anything today — just helps get the defaults right later.")
                .font(.subheadline)
                .foregroundStyle(OmniAgentPalette.textSecondary)

            VStack(spacing: 6) {
                ForEach(AuthGate.personaOptions) { option in
                    Button {
                        selectedPersona = option.id
                    } label: {
                        HStack {
                            Text(option.label)
                            Spacer()
                        }
                        .padding(8)
                        .background(
                            selectedPersona == option.id ? OmniAgentPalette.accent.opacity(0.22) : Color.clear
                        )
                        .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack(spacing: 10) {
                Button("Continue") {
                    if let selectedPersona { model.send(.answerSelected(persona: selectedPersona)) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedPersona == nil)
                Button("Skip this question") { model.send(.skipPersonalize) }
            }
        }
    }
}

/// Shared SwiftUI palette values matching the AppKit workspace's own colors
/// (`WorkspaceWindowController`'s near-black background,
/// `PaneContainerView`'s focused-border blue) — one place so every SwiftUI
/// screen this task adds reads as the same app rather than the system
/// default light/dark theme.
enum OmniAgentPalette {
    static let background = Color(red: 8 / 255, green: 10 / 255, blue: 14 / 255)
    static let panel = Color(red: 14 / 255, green: 17 / 255, blue: 23 / 255)
    static let textPrimary = Color(red: 224 / 255, green: 229 / 255, blue: 237 / 255)
    static let textSecondary = Color(red: 140 / 255, green: 150 / 255, blue: 168 / 255)
    static let accent = Color(red: 65 / 255, green: 132 / 255, blue: 255 / 255)
}

/// The sign-in screen's own palette, lifted verbatim from the design's
/// hex/rgba values so the SwiftUI build reads as the same screen.
private enum SignInPalette {
    static let screenBackground = Color.omniRGB(8, 8, 10) // #08080a
    static let storyBackground = Color.omniRGB(10, 10, 16) // #0a0a10
    static let cardBackground = Color.omniRGB(18, 18, 21, 0.96)
    static let headline = Color.omniRGB(244, 244, 248) // #f4f4f8
    static let titleText = Color.omniRGB(240, 240, 244) // #f0f0f4
    static let primaryText = Color.omniRGB(232, 232, 238) // #e8e8ee
    static let bodyText = Color.omniRGB(154, 154, 166) // #9a9aa6
    static let monoText = Color.omniRGB(198, 198, 208) // #c6c6d0
    static let mutedText = Color.omniRGB(124, 124, 134) // #7c7c86
    static let faintText = Color.omniRGB(101, 101, 111) // #65656f
    static let chipText = Color.omniRGB(139, 139, 149) // #8b8b95
    static let indigo = Color.omniRGB(95, 107, 255) // #5f6bff
    static let periwinkle = Color.omniRGB(139, 149, 255) // #8b95ff
    static let green = Color.omniRGB(78, 201, 122) // #4ec97a
    static let amber = Color.omniRGB(240, 180, 70) // #f0b446
    static let errorText = Color.omniRGB(255, 122, 122)
}

private extension Color {
    static func omniRGB(_ red: Double, _ green: Double, _ blue: Double, _ alpha: Double = 1) -> Color {
        Color(.sRGB, red: red / 255, green: green / 255, blue: blue / 255, opacity: alpha)
    }
}

/// Hosts `AuthGateContentView`. Two shapes, one flow: `over: nil` is the
/// login window at launch, standing on its own with nothing behind it; a
/// window makes it a sheet on that window — the native shape of the web's
/// `overlay-backdrop`, which the Settings screen's "Sign in" row uses.
final class AuthGateWindowController {
    private let coordinator: AuthGateCoordinator
    /// The gate's window. Readable so a test can measure the real thing —
    /// where it opens and how big it is *is* the launch shape.
    private(set) var sheetWindow: NSWindow?

    init(coordinator: AuthGateCoordinator) {
        self.coordinator = coordinator
    }

    /// Shows the gate — the Settings screen's Account section "Sign in" row
    /// re-runs the same flow rather than a second one.
    func present(over window: NSWindow?, completion: (() -> Void)? = nil) {
        let model = AuthGateViewModel()
        model.onResolved = { [weak self] outcome in
            guard let self else { return }
            coordinator.resolve(outcome) { [weak self] in
                self?.dismiss()
                completion?()
            }
        }
        // One size for every phase. `NSHostingController` sizes the window
        // from whatever the view currently prefers, so left alone the window
        // would shrink to the personalize card's 420pt mid-flow — and, since
        // a resize holds the top-left corner, walk out of the centre it
        // opened in. The phases lay themselves out inside a fixed screen.
        let hosting = NSHostingController(
            rootView: AuthGateContentView(model: model)
                .frame(width: AuthGateContentView.sheetSize.width, height: AuthGateContentView.sheetSize.height)
        )
        // Edge to edge. `fullSizeContentView` runs the content view under the
        // title bar, but SwiftUI still insets its layout by that safe area,
        // which left the window's own grey painting a band across the top of
        // the screen. Nothing on this screen wants a safe area.
        hosting.safeAreaRegions = []
        let sheet = NSWindow(contentViewController: hosting)
        sheet.styleMask = [.titled, .fullSizeContentView]
        sheet.titlebarAppearsTransparent = true
        sheet.titleVisibility = .hidden
        sheet.isReleasedWhenClosed = false
        // What shows behind the window's own rounded corners, and for the
        // instant before SwiftUI's first paint: the screen's colour rather
        // than the system window grey.
        sheet.backgroundColor = NSColor(SignInPalette.screenBackground)
        // Apple's web sign-in browser sheet anchors to this window itself.
        model.presentationWindow = { [weak sheet] in sheet }
        sheetWindow = sheet
        if let window {
            window.beginSheet(sheet)
        } else {
            centerOnScreen(sheet)
            sheet.makeKeyAndOrderFront(nil)
        }
    }

    /// Puts the launch window at the middle of the screen — and does it
    /// without `NSWindow.center()`, which is wrong here twice over: it biases
    /// the window above centre by design, and it places whatever size the
    /// window has *at that moment*, which is before SwiftUI has reported
    /// one. That is what parked the login screen in the top-right quadrant.
    private func centerOnScreen(_ window: NSWindow) {
        window.setContentSize(AuthGateContentView.sheetSize)
        guard let screen = window.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = window.frame.size
        window.setFrameOrigin(NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2
        ))
    }

    private func dismiss() {
        guard let sheet = sheetWindow else { return }
        if let parent = sheet.sheetParent {
            parent.endSheet(sheet)
        } else {
            sheet.orderOut(nil)
        }
        sheetWindow = nil
    }
}
