import Foundation
import Security

/// Whether this build can actually run the Sign in with Apple flow.
///
/// `com.apple.developer.applesignin` is a *restricted* entitlement that is
/// deliberately absent until a Developer ID provisioning profile carrying it
/// exists (see `OmniAgent.entitlements`). In a build without it, every click
/// on the Apple button dies with `ASAuthorizationError` 1000 — a guaranteed
/// dead end. Asking the running code signature itself
/// (`SecTaskCopyValueForEntitlement`) instead of hardcoding a flag means the
/// login screen's Apple button reappears automatically in the exact build
/// that finally signs with the entitlement, and can never show in one where
/// pressing it cannot work.
enum AppleSignInCapability {
    static let isEnabled: Bool = probeEntitlement()

    /// Split out so tests can call the probe directly: the test host is not
    /// signed with the entitlement, which pins down the "hidden" branch.
    static func probeEntitlement() -> Bool {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        return SecTaskCopyValueForEntitlement(
            task, "com.apple.developer.applesignin" as CFString, nil
        ) != nil
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
}

/// Every way an auth call fails, pre-sorted into the buckets the login UI
/// actually branches on — so the view layer switches on cases instead of
/// re-parsing status codes or FastAPI `{"detail": …}` bodies.
enum AuthError: Error, LocalizedError, Equatable {
    /// 401 from login — wrong email/password, or an Apple identity token the
    /// server rejected (invalid, expired, or missing an email claim). Carries
    /// the server's `detail` string.
    case invalidCredentials(String)
    /// 403 from login — the Turnstile bot check failed, or the account is
    /// disabled. Carries the server's `detail` string; `errorDescription`
    /// translates the bot-check case into plain words (see below).
    case forbidden(String)
    /// Any other non-2xx: (status code, server detail or raw body).
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
            // And only builds whose signature carries the Sign in with Apple
            // entitlement have a Turnstile-free route to offer.
            if detail == "Bot verification failed." {
                let remedy = AppleSignInCapability.isEnabled
                    ? "Use Sign in with Apple instead — it doesn't go through that check."
                    : "Password sign-in isn't available from this build against this server yet — continue without signing in for now."
                return "The server's bot check (Cloudflare Turnstile) blocked this sign-in — the native app can't show the verification widget. \(remedy)"
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
/// (`OmniAgent-Core`, `api.omni-agent.ai`) — login, Sign in with Apple,
/// refresh, logout. URLSession only, no dependencies.
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

    /// `POST /v1/auth/login/apple` with the ASAuthorization identity token.
    /// Core verifies it against Apple's JWKS (issuer appleid.apple.com,
    /// audience = the app's bundle id, `digital.bruno.omniagent`) and creates
    /// the account on first sign-in — which is why the given/family name ride
    /// along: Apple only hands them to the client on that very first
    /// authorization, so this is the one chance to store them. Nil on later
    /// sign-ins is normal and encodes as JSON null. No Turnstile on this
    /// route; rate-limited server-side like login/google (5 per 15 min).
    func loginWithApple(identityToken: String, givenName: String?, familyName: String?) async throws -> AuthUser {
        try await authenticate(path: "v1/auth/login/apple", body: [
            "identity_token": identityToken,
            "given_name": givenName ?? NSNull(),
            "family_name": familyName ?? NSNull(),
        ])
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
    /// anything else `.server`).
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
