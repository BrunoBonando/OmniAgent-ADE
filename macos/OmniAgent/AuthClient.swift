import CryptoKit
import Foundation
import Security

/// The one-attempt secrets of a web sign-in flow, generated fresh for every
/// press of "Continue with Apple"/"Continue with GitHub" (and every
/// "Connect GitHub…") and carried from the authorize URL through to the
/// exchange call.
///
/// Why PKCE at all when the app has no client secret to protect: the
/// browser's redirect back into `omniagent://` is the weakest hop in the
/// flow — any process on the Mac could, in principle, register the same URL
/// scheme and catch the one-time code. `state` is the SHA256 of a verifier
/// only this launch of the app knows, so a stolen code is worthless without
/// the verifier the exchange call also has to present, and a callback that
/// wasn't produced by *this* attempt fails the comparison in
/// `AuthGateViewModel.handleCallback`.
///
/// - `verifier`: 32 random bytes, base64url, unpadded (43 characters) — the
///   RFC 7636 shape, which is also what Core validates against.
/// - `state`: base64url(SHA256(verifier)), unpadded. Doubles as the OAuth
///   `state` parameter *and* the PKCE challenge — the provider echoes it
///   back verbatim through Core's callback.
/// - `nonce`: 16 random bytes as 32 hex characters; Core checks it against
///   the `nonce` claim of the id_token Apple returns to the exchange.
struct PKCE {
    let verifier: String
    let state: String
    let nonce: String

    init() {
        let verifier = Self.base64URL(Self.randomBytes(32))
        self.verifier = verifier
        state = Self.challenge(for: verifier)
        nonce = Self.randomBytes(16).map { String(format: "%02x", $0) }.joined()
    }

    /// The PKCE S256 challenge for a verifier: base64url(SHA256(ascii)), no
    /// padding. Exposed so a test can pin it to RFC 7636's published vector
    /// rather than to whatever this implementation happens to produce.
    static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    private static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else {
            // The system CSPRNG failing is not a real-world state, but
            // silently continuing with a buffer of zeroes would be a
            // predictable verifier — the one outcome worse than failing.
            preconditionFailure("SecRandomCopyBytes failed")
        }
        return Data(bytes)
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// The identity providers Core's web sign-in flows speak for. Everything
/// that differs between them is here, so the view model, the login screen
/// and `AuthClient` all branch on one value instead of three copies of the
/// same `if apple`.
///
/// Both flows have the same shape: open a browser at an authorize URL, get
/// bounced back into `omniagent://auth/<provider>?code&state`, redeem the
/// one-time code at Core. Only the three facts below differ.
enum AuthProvider: String, CaseIterable, Equatable {
    case apple
    case github

    /// The path half of the `omniagent://` URL Core bounces the browser
    /// into — `/auth/apple`, `/auth/github`. The running attempt's own
    /// value is what an arriving callback has to match before a single
    /// field of it is believed; see `AuthGateViewModel.handleCallback`.
    var callbackPath: String { "/auth/\(rawValue)" }

    /// What the provider form-posts as `error` when the user presses Cancel
    /// on its own authorize page, which Core relays verbatim. A protocol
    /// identifier, not a sentence — so it must never reach the error label.
    var cancelError: String {
        switch self {
        case .apple: return "user_cancelled_authorize"
        case .github: return "access_denied"
        }
    }

    /// Core's route that redeems this provider's one-time code.
    var exchangePath: String { "v1/auth/\(rawValue)/exchange" }

    /// A callback URL's path in the same spelling `callbackPath` uses.
    /// `omniagent://auth/github` parses as host `auth` and path `/github` —
    /// the scheme is followed by an authority — so the two halves have to be
    /// joined back before they can be compared.
    static func callbackPath(of url: URL) -> String {
        let joined = "/\(url.host ?? "")\(url.path)"
        return joined.count > 1 && joined.hasSuffix("/") ? String(joined.dropLast()) : joined
    }
}

/// The signed-in identity the Core API's `POST /v1/auth/*` endpoints return —
/// the subset of Core's `UserResponse` the native app actually renders (auth
/// gate greeting, settings account row). Core sends more fields
/// (`enabled`, `onboarding_completed`, timestamps, …); `JSONDecoder` ignores
/// keys the type doesn't declare, so tolerating server-side additions costs
/// nothing and this type never needs to chase the full shape.
///
/// Field names are the client-side camelCase spellings of Core's snake_case
/// wire names (`first_name`, `auth_provider`, `email_verified`), mapped by the
/// decoder's `.convertFromSnakeCase` — see `AuthClient.decoder`.
struct AuthUser: Decodable, Equatable {
    let id: String
    let email: String
    let firstName: String?
    let lastName: String?
    let name: String?
    let role: String
    let authProvider: String
    let emailVerified: Bool
    /// The GitHub handle linked to this account (`github_login` on the
    /// wire), or `nil` when none is. Note this is *not* `authProvider`: an
    /// account that signs in with Apple can still have GitHub connected
    /// from Settings › Accounts, and that is the pair the Accounts section
    /// shows.
    let githubLogin: String?
}

/// Every way an auth call fails, pre-sorted into the buckets the login UI
/// actually branches on — so the view layer switches on cases instead of
/// re-parsing status codes or FastAPI `{"detail": …}` bodies.
enum AuthError: Error, LocalizedError, Equatable {
    /// 401 from login — wrong email/password, or an Apple sign-in Core
    /// rejected outright. Carries the server's `detail` string.
    case invalidCredentials(String)
    /// 403 from login — the Turnstile bot check failed, or the account is
    /// disabled. Carries the server's `detail` string; `errorDescription`
    /// translates the bot-check case into plain words (see below).
    case forbidden(String)
    /// Any other non-2xx: (status code, server detail or raw body). This is
    /// where the Apple exchange's own failures land — 400 (the one-time code
    /// expired, was replayed, or the verifier/nonce didn't match), 409 (the
    /// email already belongs to another sign-in method) and 429 (rate
    /// limited) — and `errorDescription` shows Core's `detail` verbatim,
    /// because Core is the only side that knows which of those happened.
    case server(Int, String)
    /// The request never got an HTTP response — offline, DNS, TLS, timeout.
    case network(String)
    /// 401 from `/v1/auth/refresh` — the refresh cookie is gone, revoked, or
    /// expired. Not a failure to surface as an error dialog: the caller shows
    /// the login screen again.
    case sessionExpired

    var errorDescription: String? {
        switch self {
        case let .invalidCredentials(detail):
            return detail.isEmpty ? "Invalid email or password." : detail
        case let .forbidden(detail):
            // Core's exact wording for a failed Turnstile check. Repeating it
            // verbatim would strand the user — the native login form has no
            // Turnstile widget to retry, so the honest message is what
            // happened and what actually works. (The login endpoint sends
            // "turnstile_token": null and Core only enforces the check when
            // Turnstile is configured server-side.) Do NOT suggest signing in
            // from the web app: a browser session shares nothing with this
            // app's cookie jar and cannot exempt the next native attempt.
            if detail == "Bot verification failed." {
                return "The server's bot check (Cloudflare Turnstile) blocked this sign-in — the native app "
                    + "can't show the verification widget. Password sign-in isn't available from this build "
                    + "against this server yet — continue without signing in for now."
            }
            return detail.isEmpty ? "This account is not allowed to sign in." : detail
        case let .server(status, detail):
            return detail.isEmpty ? "The server returned an error (HTTP \(status))." : detail
        case let .network(message):
            return message.isEmpty ? "Could not reach the OmniAgent API." : message
        case .sessionExpired:
            return "Your session has expired. Please sign in again."
        }
    }
}

/// The native app's client for Core's `/v1/auth` endpoints
/// (`OmniAgent-Core`, `api.omni-agent.ai`) — login, the Apple and GitHub web
/// flows, linking/unlinking GitHub, refresh, logout. URLSession only, no
/// dependencies.
///
/// Token model, and why there is no manual cookie code here:
/// - The short-lived **access token** arrives in the JSON body
///   (`access_token`) and lives in memory as `accessToken` — callers attach
///   it as `Authorization: Bearer …` to authenticated Core calls.
/// - The long-lived **refresh token** arrives as an `HttpOnly` `Set-Cookie`
///   and is deliberately never touched: URLSession stores it in the session's
///   `HTTPCookieStorage` and re-attaches it to `/v1/auth/refresh` on its own.
///   For the default `.shared` session that storage is the app's persistent
///   cookie jar, which survives relaunches — which is the entire reason
///   `restoreSession()` works cold, at launch, with no credential store of
///   our own. Hand-rolling cookie persistence would only re-implement that,
///   worse.
///
/// Not thread-safe by design: `accessToken` is a plain stored property, and
/// every caller in the app talks to `AuthClient.shared` from the main actor.
final class AuthClient {
    static let shared = AuthClient()

    /// Core API origin. `UserDefaults` key `OMNIAGENT_API_BASE_URL` overrides
    /// it (staging, local dev) — same override-by-defaults pattern as the
    /// daemon's `OMNIAGENT_ADE_DATA_DIR`, but readable/writable with
    /// `defaults write digital.bruno.omniagent …` instead of an env var,
    /// because a launched .app doesn't inherit a shell environment.
    let baseURL: URL

    /// The current bearer token, `nil` until a login/refresh succeeds and
    /// again after `logout()`. In-memory only, on purpose: it's short-lived
    /// server-side, and persisting it would just add a stale-token startup
    /// path that `restoreSession()` already covers properly.
    private(set) var accessToken: String?

    private let session: URLSession

    /// One decoder, one convention: Core speaks snake_case
    /// (`access_token`, `first_name`), Swift reads camelCase.
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    init(baseURL: URL? = nil, session: URLSession = .shared) {
        self.baseURL = baseURL
            ?? UserDefaults.standard.string(forKey: "OMNIAGENT_API_BASE_URL").flatMap(URL.init(string:))
            ?? URL(string: "https://api.omni-agent.ai")!
        self.session = session
    }

    // MARK: - Public API

    /// `POST /v1/auth/login` with email + password. On 200, stores the access
    /// token and returns the user; the refresh cookie is stored by URLSession
    /// (see the type comment). Throws `.invalidCredentials` on 401,
    /// `.forbidden` on 403 (bot check / disabled account).
    func login(email: String, password: String) async throws -> AuthUser {
        // "turnstile_token" is sent as an explicit JSON null, not omitted —
        // that is the shape Core's login model declares, and the reason the
        // body is built with JSONSerialization + NSNull rather than an
        // Encodable struct (JSONEncoder drops nil optionals by default).
        try await authenticate(path: "v1/auth/login", body: [
            "email": email,
            "password": password,
            "turnstile_token": NSNull(),
        ])
    }

    /// The Services ID Apple's *web* sign-in flow authenticates against —
    /// the `client_id` of the authorize URL, and therefore the `aud` claim of
    /// the id_token Core verifies. Deliberately not the app's bundle id
    /// (`digital.bruno.omniagent`): a native `ASAuthorizationController`
    /// flow would use the bundle id, but that flow needs the restricted
    /// `com.apple.developer.applesignin` entitlement, which Developer ID
    /// distribution cannot carry (see `OmniAgent.entitlements`). The web
    /// flow authenticates as a Services ID instead, and Core's verifier is
    /// configured for this one.
    static let appleServicesID = "ai.omni-agent.signin"

    /// The URL `ASWebAuthenticationSession` opens to start `provider`'s web
    /// sign-in. The two are not the same kind of URL and deliberately are
    /// not made to look alike: Apple's is Apple's own authorize endpoint,
    /// carrying Core's callback as `redirect_uri`; GitHub's is *Core's*
    /// start route, which redirects on to GitHub with the client id and
    /// scopes only Core knows. Both carry this attempt's `state` and
    /// `nonce`, and both end at `omniagent://auth/<provider>`.
    func authorizeURL(for provider: AuthProvider, state: String, nonce: String) -> URL {
        switch provider {
        case .apple:
            return appleAuthorizeURL(state: state, nonce: nonce)
        case .github:
            var components = URLComponents(
                url: baseURL.appendingPathComponent("v1/auth/github/start"),
                resolvingAgainstBaseURL: false
            )!
            components.queryItems = [
                URLQueryItem(name: "state", value: state),
                URLQueryItem(name: "nonce", value: nonce),
            ]
            // Only fails for a query no `URLQueryItem` can produce.
            return components.url!
        }
    }

    /// Apple's half of `authorizeURL(for:state:nonce:)`. `redirect_uri`
    /// points at *Core*, not at the app: Apple only redirects to https
    /// endpoints registered on the Services ID, and `response_mode=form_post`
    /// (mandatory once `scope` asks for name or email) POSTs the result,
    /// which a custom URL scheme cannot receive. Core takes the POST and
    /// bounces the browser on to `omniagent://auth/apple?code=…&state=…`.
    ///
    /// Built with `URLComponents` so the space-separated `response_type` and
    /// `scope` values percent-encode themselves rather than being hand-glued
    /// into a query string.
    private func appleAuthorizeURL(state: String, nonce: String) -> URL {
        var components = URLComponents(string: "https://appleid.apple.com/auth/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: Self.appleServicesID),
            URLQueryItem(
                name: "redirect_uri",
                value: baseURL.appendingPathComponent("v1/auth/apple/callback").absoluteString
            ),
            URLQueryItem(name: "response_type", value: "code id_token"),
            URLQueryItem(name: "response_mode", value: "form_post"),
            URLQueryItem(name: "scope", value: "name email"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "nonce", value: nonce),
        ]
        // Only fails for a query no `URLQueryItem` can produce.
        return components.url!
    }

    /// `POST /v1/auth/<provider>/exchange` — the second half of a web flow.
    /// `code` is the **one-time code Core minted** for this app (not the
    /// provider's authorization code, which Core already redeemed
    /// server-side), and it is redeemed exactly once: `code_verifier` proves
    /// this is the same app launch that opened the authorize URL, and
    /// `nonce` is matched against what the provider returned (Apple's
    /// id_token claim). Core creates the account on first sign-in from the
    /// name/email the provider posted to its callback, so unlike the old
    /// native flow there is nothing name-shaped for the client to pass
    /// along. No Turnstile on these routes; rate-limited server-side.
    func login(with provider: AuthProvider, code: String, codeVerifier: String, nonce: String) async throws -> AuthUser {
        try await authenticate(path: provider.exchangePath, body: [
            "code": code,
            "code_verifier": codeVerifier,
            "nonce": nonce,
        ])
    }

    /// `POST /v1/auth/github/link` — GitHub's *other* entry point: not a way
    /// in, but a link onto the account already signed in, so Settings ›
    /// Accounts can connect GitHub without a second identity. Core arms the
    /// attempt with this `state`/`nonce` and answers 204; the browser is
    /// then sent to the same start URL a sign-in uses, and the callback is
    /// redeemed at the same exchange route.
    ///
    /// Bearer-authorized, which is the whole reason `restoreSession()` runs
    /// at launch for a signed-in mirror: without a token there is no
    /// account to link *to*.
    func linkGitHub(state: String, nonce: String) async throws {
        try await authorized(path: "v1/auth/github/link", method: "POST", body: ["state": state, "nonce": nonce])
    }

    /// `DELETE /v1/auth/github` — unlinks GitHub from the signed-in account.
    /// Bearer-authorized, 204 on success. Nothing local to clean up beyond
    /// the `auth_github_login` row the caller clears.
    func disconnectGitHub() async throws {
        try await authorized(path: "v1/auth/github", method: "DELETE", body: nil)
    }

    /// `POST /v1/auth/refresh` — the cold-start "am I still signed in?"
    /// probe. Sends no body and no bearer token; the persisted refresh
    /// cookie in the session's `HTTPCookieStorage` is the credential, and
    /// URLSession attaches it (and stores the rotated replacement from the
    /// response) automatically. 401 means the session is gone —
    /// `.sessionExpired`, show the login screen.
    func restoreSession() async throws -> AuthUser {
        let (data, http) = try await perform(request(path: "v1/auth/refresh", body: nil))
        switch http.statusCode {
        case 200...299:
            return try storeSession(from: data)
        case 401:
            throw AuthError.sessionExpired
        default:
            throw AuthError.server(http.statusCode, detail(from: data))
        }
    }

    /// `POST /v1/auth/logout` — asks Core to revoke the refresh token and
    /// clear its cookie, then forgets the access token locally. Best-effort
    /// on purpose: if the network is down the server-side session dies on its
    /// own schedule anyway, and holding the UI hostage to confirm a sign-out
    /// would be worse than an unrevoked-but-expiring token. The local token
    /// is cleared no matter what.
    func logout() async {
        defer { accessToken = nil }
        var req = request(path: "v1/auth/logout", body: nil)
        if let token = accessToken {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        _ = try? await session.data(for: req)
    }

    // MARK: - Shared plumbing

    /// The `{"access_token", "user"}` envelope every successful auth response
    /// shares. `token_type` (login only, always "bearer") is deliberately not
    /// declared — refresh omits it, and nothing branches on it.
    private struct SessionEnvelope: Decodable {
        let accessToken: String
        let user: AuthUser
    }

    /// FastAPI's standard error body. `detail` can be a validation-error
    /// array on 422; that decodes as a failure here and the caller falls back
    /// to the raw body, which is still more useful than swallowing it.
    private struct ErrorBody: Decodable {
        let detail: String
    }

    /// The login-shaped call: POST a JSON body, map the shared status-code
    /// contract (200 stores the session, 401 credentials, 403 forbidden,
    /// anything else `.server`). The Apple exchange's 400/409/429 all fall
    /// into that last bucket on purpose — each one's `detail` is a distinct
    /// sentence only Core can write, and `.server` shows it verbatim.
    private func authenticate(path: String, body: [String: Any]) async throws -> AuthUser {
        let (data, http) = try await perform(request(path: path, body: body))
        switch http.statusCode {
        case 200...299:
            return try storeSession(from: data)
        case 401:
            throw AuthError.invalidCredentials(detail(from: data))
        case 403:
            throw AuthError.forbidden(detail(from: data))
        default:
            throw AuthError.server(http.statusCode, detail(from: data))
        }
    }

    /// The bearer-authorized, nothing-to-decode call: the GitHub link and
    /// unlink routes both answer 204. A missing access token is
    /// `.sessionExpired` rather than an unauthenticated request, so the
    /// caller's "restore the session and try again" path is reached without
    /// a pointless round trip — and a 401 says the same thing, since the
    /// token in hand has expired.
    private func authorized(path: String, method: String, body: [String: Any]?) async throws {
        guard let token = accessToken else { throw AuthError.sessionExpired }
        var request = request(path: path, body: body)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, http) = try await perform(request)
        switch http.statusCode {
        case 200...299:
            return
        case 401:
            throw AuthError.sessionExpired
        default:
            throw AuthError.server(http.statusCode, detail(from: data))
        }
    }

    private func request(path: String, body: [String: Any]?) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            // The bodies here are flat string/null dictionaries; this cannot
            // actually throw for them, and `try!` would still be wrong the
            // day someone adds a non-plist value.
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        return request
    }

    /// Runs the request, folding every transport-level failure (offline,
    /// DNS, TLS, timeout — anything before an HTTP status exists) into
    /// `.network` so callers see exactly one non-HTTP case.
    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw AuthError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw AuthError.network("Non-HTTP response from \(request.url?.absoluteString ?? "the API").")
        }
        return (data, http)
    }

    private func storeSession(from data: Data) throws -> AuthUser {
        guard let envelope = try? decoder.decode(SessionEnvelope.self, from: data) else {
            // A 2xx whose body doesn't decode is a server-contract break, not
            // a credentials problem — report it as such instead of crashing
            // or pretending the login failed.
            throw AuthError.server(200, "The server's response could not be read.")
        }
        accessToken = envelope.accessToken
        return envelope.user
    }

    private func detail(from data: Data) -> String {
        if let body = try? decoder.decode(ErrorBody.self, from: data) {
            return body.detail
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
