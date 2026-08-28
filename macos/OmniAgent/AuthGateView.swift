import AppKit
import AuthenticationServices
import SwiftUI

/// The I/O half of the auth gate: whether it needs showing, and persisting
/// whichever way it resolves — the three keys the web build's
/// `App.tsx`/`handleAuthGateResolved` established plus the two native-first
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

    /// Persists all five keys the gate cares about and completes once every
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
            completion: completion
        )
    }

    /// "Log out" / "Sign in" from the Settings screen's Account section —
    /// clears the persisted outcome (account identity included) so the gate
    /// shows again at the next launch, and offers the same view as a sheet
    /// right now without needing one.
    func reset(completion: @escaping () -> Void) {
        persist(resolved: "false", signedIn: "false", persona: "", accountEmail: "", accountName: "", completion: completion)
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
    /// write actually finished. Five tiny writes in sequence costs nothing
    /// a user would notice.
    private func persist(
        resolved: String,
        signedIn: String,
        persona: String,
        accountEmail: String,
        accountName: String,
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
                            completion()
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
/// Both halves of Apple's web flow are here because both depend on the
/// server the app is pointed at: the authorize URL carries Core's own
/// `redirect_uri`, so a stub can answer with a URL no test will ever open.
protocol AuthSigning {
    func appleAuthorizeURL(state: String, nonce: String) -> URL
    func loginWithApple(code: String, codeVerifier: String, nonce: String) async throws -> AuthUser
}

extension AuthClient: AuthSigning {}

/// Dispatches `AuthGateAction`s against the pure reducer, republishes the
/// result for SwiftUI, and owns the async sign-in work: the reducer only
/// ever sees a *successful* login (as `.signedIn`), while in-flight and
/// failed attempts live here as `isBusy`/`errorMessage`.
final class AuthGateViewModel: ObservableObject {
    @Published private(set) var state = AuthGateReducer.initial
    /// The Apple sign-in round trip is in flight — from the moment the
    /// browser opens until the exchange lands. The screen disables its
    /// controls off this instead of racing double-submits.
    @Published private(set) var isBusy = false
    /// The last failed attempt's human-readable reason, cleared on the next
    /// attempt. `nil` while nothing has failed.
    @Published private(set) var errorMessage: String?
    var onResolved: ((AuthGateOutcome) -> Void)?
    /// The window Apple's web sign-in anchors its browser sheet to — set by
    /// `AuthGateWindowController` to the login window itself.
    var presentationWindow: (() -> NSWindow?)?

    /// This attempt's PKCE secrets. Regenerated by every press of the Apple
    /// button, so a callback left over from an abandoned attempt fails the
    /// `state` comparison in `handleAppleCallback` instead of being redeemed.
    private(set) var pkce = PKCE()

    /// The URL scheme Core bounces the browser back into. Registered in
    /// `macos/OmniAgent/Info.plist`; `ASWebAuthenticationSession` matches the
    /// callback on it and hands the URL straight to this object, so the app's
    /// own `application(_:open:)` never sees it.
    static let callbackScheme = "omniagent"

    /// Shown when the browser closed without either a usable callback or an
    /// error to quote — a state no completed flow produces, so it says the
    /// one useful thing rather than inventing a cause.
    static let incompleteMessage = "Sign-in didn't complete — try again."

    /// Shown for any callback whose `state` isn't this attempt's PKCE state:
    /// a stale callback from an abandoned attempt, a URL some other process
    /// fabricated, or a page inside the authorize flow trying to put its own
    /// words on this screen. Nothing in such a URL is read — not the code,
    /// and not its `error` text either.
    static let stateMismatchMessage = "Sign-in response didn't match this app — try again."

    private let signer: AuthSigning
    /// Retains the running web-auth session and its presentation anchor —
    /// `ASWebAuthenticationSession` keeps neither itself nor its
    /// `presentationContextProvider` alive (the latter is a weak reference),
    /// so without these two the browser closes the instant `start()` returns.
    private var webAuthSession: ASWebAuthenticationSession?
    private var anchorProvider: AuthPresentationAnchor?

    init(signer: AuthSigning = AuthClient.shared) {
        self.signer = signer
    }

    func send(_ action: AuthGateAction) {
        state = AuthGateReducer.reduce(state, action)
        if state.phase == .resolved, let outcome = state.outcome {
            onResolved?(outcome)
        }
    }

    /// Opens Apple's web sign-in in a `ASWebAuthenticationSession` browser
    /// sheet anchored to the login window. The session watches for the
    /// `omniagent://` callback Core bounces the browser into and hands the
    /// URL to `handleAppleCallback`; a cancel closes it silently.
    ///
    /// Not the native `ASAuthorizationController` flow, and it cannot be:
    /// that needs the restricted `com.apple.developer.applesignin`
    /// entitlement, which Developer ID distribution cannot carry (Apple DTS
    /// — see `OmniAgent.entitlements`).
    @MainActor
    func signInWithApple() {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        // A fresh verifier per attempt: the previous one's callback must not
        // be redeemable after the user backs out and starts again.
        pkce = PKCE()
        let anchor = AuthPresentationAnchor { [weak self] in self?.presentationWindow?() }
        let session = ASWebAuthenticationSession(
            url: signer.appleAuthorizeURL(state: pkce.state, nonce: pkce.nonce),
            callbackURLScheme: Self.callbackScheme
        ) { [weak self] url, error in
            Task { @MainActor in
                guard let self else { return }
                self.webAuthSession = nil
                self.anchorProvider = nil
                if let url {
                    await self.handleAppleCallback(url)
                } else {
                    self.failAppleSignIn(error)
                }
            }
        }
        session.presentationContextProvider = anchor
        // Deliberately not ephemeral: reusing Safari's cookies is what makes
        // the second sign-in a single click instead of a full Apple ID
        // password + 2FA round trip.
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
            isBusy = false
            errorMessage = Self.incompleteMessage
            return
        }
    }

    /// The `omniagent://auth/apple?…` URL Core bounces the browser into,
    /// turned into either a signed-in state or a message. Internal (not
    /// private) because this — not the browser sheet — is where every
    /// decision in the flow lives, and a test can drive it directly.
    @MainActor
    func handleAppleCallback(_ url: URL) async {
        // The callback means a request is under way even when the attempt
        // that opened the browser belongs to an earlier run loop turn.
        isBusy = true
        errorMessage = nil
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? {
            query.first { $0.name == name }?.value.flatMap { $0.isEmpty ? nil : $0 }
        }
        // `state` first, before a single field of this URL is believed —
        // including `error`, which is shown to the user verbatim. The
        // session intercepts *any* `omniagent://` navigation its browser
        // makes, so a page reached from inside the authorize flow (an open
        // redirect, an injected page) could otherwise write its own sentence
        // into this app's error label as first-party copy. Core sends
        // `state` on its error callbacks too, so nothing legitimate is lost.
        guard value("state") == pkce.state else {
            isBusy = false
            errorMessage = Self.stateMismatchMessage
            return
        }
        if let failure = value("error") {
            // Core's own words for what Apple (or its own callback) refused
            // — it is the only side that knows.
            isBusy = false
            errorMessage = failure
            return
        }
        guard let code = value("code") else {
            isBusy = false
            errorMessage = Self.incompleteMessage
            return
        }
        await completeAppleSignIn(code: code)
    }

    /// Redeems the one-time code at `/v1/auth/apple/exchange` and, on
    /// success, hands the account to the reducer — the same `.signedIn`
    /// transition the whole gate has always resolved through.
    @MainActor
    private func completeAppleSignIn(code: String) async {
        let attempt = pkce
        do {
            let user = try await signer.loginWithApple(
                code: code,
                codeVerifier: attempt.verifier,
                nonce: attempt.nonce
            )
            isBusy = false
            send(.signedIn(email: user.email, displayName: Self.displayName(of: user)))
        } catch {
            isBusy = false
            errorMessage = Self.message(for: error)
        }
    }

    @MainActor
    private func failAppleSignIn(_ error: Error?) {
        isBusy = false
        if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
            return // the user closed the browser — not an error to report
        }
        errorMessage = error.map { Self.message(for: $0) } ?? Self.incompleteMessage
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
/// panel + 452px auth card), and the personalize question carried over
/// unchanged from the previous build.
///
/// Animation policy (hard-won): at most one one-shot opacity/offset on
/// appear, driven by a single `withAnimation` — nested animation groups have
/// SIGSEGV'd the test host before — and even that is skipped under
/// Reduce Motion. The design's drifting blobs, typing loop and blinking
/// carets are all deliberately static here.
struct AuthGateContentView: View {
    @ObservedObject var model: AuthGateViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedPersona: String?
    @State private var appeared = false
    @State private var hoveredApple = false

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
                Text("Sign in with your Apple ID to sync your settings and license.")
                    .font(.system(size: 15))
                    .foregroundStyle(SignInPalette.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 22)

                // The only way in. Password sign-in left with the web
                // build; Apple's web flow is the whole login screen now.
                appleButton

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
        Button { model.signInWithApple() } label: {
            HStack(spacing: 10) {
                Image(systemName: "applelogo")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Color.omniRGB(245, 245, 247))
                Text("Continue with Apple")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(SignInPalette.primaryText)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.35))
            }
            .padding(.horizontal, 13)
            .frame(height: 42)
            .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(hoveredApple ? 0.1 : 0.055)))
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .stroke(Color.white.opacity(hoveredApple ? 0.22 : 0.12), lineWidth: 0.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .onHover { hoveredApple = $0 }
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
