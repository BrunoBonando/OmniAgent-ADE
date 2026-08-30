import XCTest
@testable import OmniAgent

/// Intercepts every request on the stub session and answers from
/// `AuthClientStubProtocol.handler` — no sockets, no live Core API. The body
/// is drained from `httpBodyStream` at intercept time because URLSession
/// converts `httpBody` into a stream before the protocol ever sees the
/// request, so `request.httpBody` is nil here even for requests that sent
/// one.
private final class AuthClientStubProtocol: URLProtocol {
    struct Recorded {
        let request: URLRequest
        let body: Data?
    }

    static var handler: ((URLRequest) -> (status: Int, body: Data))?
    static var recorded: [Recorded] = []

    static func reset() {
        handler = nil
        recorded = []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.recorded.append(Recorded(request: request, body: Self.drainBody(of: request)))
        guard let handler = Self.handler, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let (status, body) = handler(request)
        let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func drainBody(of request: URLRequest) -> Data? {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

final class AuthClientTests: XCTestCase {
    override func setUp() {
        super.setUp()
        AuthClientStubProtocol.reset()
    }

    override func tearDown() {
        AuthClientStubProtocol.reset()
        super.tearDown()
    }

    /// A client whose URLSession routes every request into the stub protocol.
    /// `.ephemeral` so the stub session shares no cookie jar or cache with
    /// the real `.shared` session other tests (or the app) might touch.
    private func makeClient() -> AuthClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AuthClientStubProtocol.self]
        return AuthClient(
            baseURL: URL(string: "https://api.test.invalid")!,
            session: URLSession(configuration: configuration)
        )
    }

    /// A full Core `UserResponse` — including the fields `AuthUser` does not
    /// declare (`enabled`, `onboarding_completed`, timestamps) — to prove the
    /// decoder tolerates the whole wire shape, not a trimmed fixture.
    private let userJSON = """
    {"id":"usr-1","email":"ada@example.com","first_name":"Ada","last_name":"Lovelace",\
    "name":"Ada Lovelace","picture":null,"role":"user","auth_provider":"password",\
    "email_verified":true,"enabled":true,"company_id":null,"onboarding_completed":true,\
    "github_login":null,\
    "last_login_at":"2026-08-17T10:00:00Z","created_at":"2026-01-01T00:00:00Z",\
    "updated_at":"2026-08-17T10:00:00Z"}
    """

    private func loginResponse(token: String) -> Data {
        Data("""
        {"access_token":"\(token)","token_type":"bearer","user":\(userJSON)}
        """.utf8)
    }

    private func lastBodyJSON() throws -> [String: Any] {
        let body = try XCTUnwrap(AuthClientStubProtocol.recorded.last?.body, "no request body was captured")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    // MARK: - login

    func testLoginSuccessDecodesUserAndStoresAccessToken() async throws {
        AuthClientStubProtocol.handler = { _ in (200, self.loginResponse(token: "tok-123")) }
        let client = makeClient()

        let user = try await client.login(email: "ada@example.com", password: "hunter2")

        XCTAssertEqual(user, AuthUser(
            id: "usr-1",
            email: "ada@example.com",
            firstName: "Ada",
            lastName: "Lovelace",
            name: "Ada Lovelace",
            picture: nil,
            role: "user",
            authProvider: "password",
            emailVerified: true,
            githubLogin: nil
        ))
        XCTAssertEqual(client.accessToken, "tok-123")

        let request = try XCTUnwrap(AuthClientStubProtocol.recorded.last?.request)
        XCTAssertEqual(request.url?.path, "/v1/auth/login")
        XCTAssertEqual(request.httpMethod, "POST")

        // Contract: "turnstile_token" is an explicit null in the body, not an
        // omitted key.
        let body = try lastBodyJSON()
        XCTAssertEqual(body["email"] as? String, "ada@example.com")
        XCTAssertEqual(body["password"] as? String, "hunter2")
        XCTAssertTrue(body.keys.contains("turnstile_token"))
        XCTAssertTrue(body["turnstile_token"] is NSNull)
    }

    func testLogin401ThrowsInvalidCredentialsWithServerDetail() async {
        AuthClientStubProtocol.handler = { _ in
            (401, Data(#"{"detail":"Incorrect email or password"}"#.utf8))
        }
        let client = makeClient()

        do {
            _ = try await client.login(email: "ada@example.com", password: "wrong")
            XCTFail("expected AuthError.invalidCredentials")
        } catch {
            XCTAssertEqual(error as? AuthError, .invalidCredentials("Incorrect email or password"))
        }
        XCTAssertNil(client.accessToken)
    }

    func testLogin403BotCheckThrowsForbiddenWithReadableExplanation() async {
        AuthClientStubProtocol.handler = { _ in
            (403, Data(#"{"detail":"Bot verification failed."}"#.utf8))
        }
        let client = makeClient()

        do {
            _ = try await client.login(email: "ada@example.com", password: "hunter2")
            XCTFail("expected AuthError.forbidden")
        } catch let error as AuthError {
            XCTAssertEqual(error, .forbidden("Bot verification failed."))
            // The user-facing message must explain the Turnstile situation in
            // plain words, not parrot the server's bare detail string.
            let message = error.errorDescription ?? ""
            XCTAssertNotEqual(message, "Bot verification failed.")
            XCTAssertTrue(message.localizedCaseInsensitiveContains("bot check"), "got: \(message)")
            XCTAssertTrue(message.contains("Turnstile"), "got: \(message)")
            // And it must not recommend non-remedies: a web-app session
            // shares nothing with this app's cookie jar and cannot exempt
            // the next native attempt, and pointing at the Apple button is
            // no use either — this is the *password* route's bot check, and
            // Apple's own web flow never reaches it.
            XCTAssertFalse(message.localizedCaseInsensitiveContains("web app"), "got: \(message)")
            XCTAssertFalse(message.contains("Apple"), "got: \(message)")
        } catch {
            XCTFail("expected AuthError, got \(error)")
        }
    }

    // MARK: - Sign in with Apple (web flow)

    func testAppleAuthorizeURLCarriesTheServicesIDAndCoresCallback() throws {
        let url = makeClient().authorizeURL(for: .apple, state: "the-state", nonce: "the-nonce")

        XCTAssertEqual(url.host, "appleid.apple.com")
        XCTAssertEqual(url.path, "/auth/authorize")

        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let query = Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })

        // The web flow authenticates as the Services ID, never as the app's
        // bundle id — that is the whole difference from the native flow
        // Developer ID builds cannot run.
        XCTAssertEqual(query["client_id"], "ai.omni-agent.signin")
        XCTAssertEqual(query["client_id"], AuthClient.appleServicesID)
        // Apple posts the result to Core, not to the app: a custom URL
        // scheme cannot receive a form_post.
        XCTAssertEqual(query["redirect_uri"], "https://api.test.invalid/v1/auth/apple/callback")
        XCTAssertEqual(query["response_type"], "code id_token")
        XCTAssertEqual(query["response_mode"], "form_post")
        XCTAssertEqual(query["scope"], "name email")
        XCTAssertEqual(query["state"], "the-state")
        XCTAssertEqual(query["nonce"], "the-nonce")

        // The space-separated values have to survive as percent-encoding,
        // not as raw spaces or "+".
        let raw = try XCTUnwrap(url.absoluteString.split(separator: "?").last).description
        XCTAssertTrue(raw.contains("response_type=code%20id_token"), "got: \(raw)")
        XCTAssertTrue(raw.contains("scope=name%20email"), "got: \(raw)")
    }

    func testLoginWithApplePostsTheOneTimeCodeVerifierAndNonce() async throws {
        AuthClientStubProtocol.handler = { _ in (200, self.loginResponse(token: "tok-apple")) }
        let client = makeClient()

        _ = try await client.login(
            with: .apple,
            code: "one-time-code",
            codeVerifier: "the-verifier",
            nonce: "the-nonce"
        )

        let request = try XCTUnwrap(AuthClientStubProtocol.recorded.last?.request)
        XCTAssertEqual(request.url?.path, "/v1/auth/apple/exchange")
        XCTAssertEqual(request.httpMethod, "POST")

        let body = try lastBodyJSON()
        XCTAssertEqual(body["code"] as? String, "one-time-code")
        XCTAssertEqual(body["code_verifier"] as? String, "the-verifier")
        XCTAssertEqual(body["nonce"] as? String, "the-nonce")
        // No Turnstile on the Apple route.
        XCTAssertFalse(body.keys.contains("turnstile_token"))

        XCTAssertEqual(client.accessToken, "tok-apple")
    }

    /// 400 (expired/replayed code, verifier or nonce mismatch), 409 (the
    /// email already belongs to another sign-in method) and 429 all carry a
    /// sentence only Core can write — the client must quote it, not
    /// translate it into a status code the user cannot act on.
    func testAnExchangeConflictSurfacesTheServersDetailVerbatim() async {
        let detail = "That email already signs in with a password. Sign in that way, then link Apple."
        AuthClientStubProtocol.handler = { _ in
            (409, Data(#"{"detail":"\#(detail)"}"#.utf8))
        }
        let client = makeClient()

        do {
            _ = try await client.login(with: .apple, code: "c", codeVerifier: "v", nonce: "n")
            XCTFail("expected AuthError.server")
        } catch let error as AuthError {
            XCTAssertEqual(error, .server(409, detail))
            XCTAssertEqual(error.errorDescription, detail)
        } catch {
            XCTFail("expected AuthError, got \(error)")
        }
        XCTAssertNil(client.accessToken)
    }

    // MARK: - Sign in with GitHub, and linking it

    /// GitHub's start URL is *Core's* route, not GitHub's: only Core knows
    /// the OAuth client id and the scopes to ask for, so the app opens
    /// Core and Core redirects on. All the app contributes is this
    /// attempt's PKCE state and nonce.
    func testGitHubAuthorizeURLIsCoresStartRouteCarryingStateAndNonce() throws {
        let url = makeClient().authorizeURL(for: .github, state: "the-state", nonce: "the-nonce")

        XCTAssertEqual(url.host, "api.test.invalid", "the app's own API base, not github.com")
        XCTAssertEqual(url.path, "/v1/auth/github/start")

        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let query = Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
        XCTAssertEqual(query["state"], "the-state")
        XCTAssertEqual(query["nonce"], "the-nonce")
    }

    func testLoginWithGitHubRedeemsTheCodeAtGitHubsOwnExchangeRoute() async throws {
        AuthClientStubProtocol.handler = { _ in (200, self.loginResponse(token: "tok-github")) }
        let client = makeClient()

        _ = try await client.login(
            with: .github,
            code: "one-time-code",
            codeVerifier: "the-verifier",
            nonce: "the-nonce"
        )

        let request = try XCTUnwrap(AuthClientStubProtocol.recorded.last?.request)
        XCTAssertEqual(request.url?.path, "/v1/auth/github/exchange", "not Apple's route")
        XCTAssertEqual(request.httpMethod, "POST")

        let body = try lastBodyJSON()
        XCTAssertEqual(body["code"] as? String, "one-time-code")
        XCTAssertEqual(body["code_verifier"] as? String, "the-verifier")
        XCTAssertEqual(body["nonce"] as? String, "the-nonce")
        XCTAssertEqual(client.accessToken, "tok-github")
    }

    /// The wire field Settings › Accounts is built on. Absent (Apple's
    /// exchange, an account with nothing linked) decodes as `nil` rather
    /// than failing the whole envelope.
    func testTheUserDecodesItsGitHubLoginAndToleratesItsAbsence() async throws {
        let linked = """
        {"id":"usr-1","email":"ada@example.com","first_name":null,"last_name":null,"name":null,\
        "role":"user","auth_provider":"apple","email_verified":true,"github_login":"adalovelace"}
        """
        AuthClientStubProtocol.handler = { _ in
            (200, Data("""
            {"access_token":"tok","user":\(linked)}
            """.utf8))
        }
        let user = try await makeClient().login(with: .github, code: "c", codeVerifier: "v", nonce: "n")
        XCTAssertEqual(user.githubLogin, "adalovelace")

        AuthClientStubProtocol.handler = { _ in (200, self.loginResponse(token: "tok")) }
        let unlinked = try await makeClient().login(with: .apple, code: "c", codeVerifier: "v", nonce: "n")
        XCTAssertNil(unlinked.githubLogin)
    }

    /// The wire field the sidebar's account chip draws its avatar from.
    /// Null (an email/password account, or a provider that carries none)
    /// decodes as `nil` rather than failing the envelope.
    func testTheUserDecodesItsProfilePictureAndToleratesItsAbsence() async throws {
        let withPicture = """
        {"id":"usr-1","email":"ada@example.com","first_name":null,"last_name":null,"name":null,\
        "picture":"https://cdn.example.com/ada.png",\
        "role":"user","auth_provider":"apple","email_verified":true,"github_login":null}
        """
        AuthClientStubProtocol.handler = { _ in
            (200, Data("""
            {"access_token":"tok","user":\(withPicture)}
            """.utf8))
        }
        let user = try await makeClient().login(with: .apple, code: "c", codeVerifier: "v", nonce: "n")
        XCTAssertEqual(user.picture, "https://cdn.example.com/ada.png")

        AuthClientStubProtocol.handler = { _ in (200, self.loginResponse(token: "tok")) }
        let none = try await makeClient().login(with: .apple, code: "c", codeVerifier: "v", nonce: "n")
        XCTAssertNil(none.picture, "an explicit null is no picture")
    }

    /// Linking is the signed-in half of GitHub: it must present the bearer
    /// token, or Core has no account to link the callback onto.
    func testLinkGitHubPostsTheStateAndNonceWithTheBearerToken() async throws {
        AuthClientStubProtocol.handler = { request in
            request.url?.path == "/v1/auth/github/link" ? (204, Data()) : (200, self.loginResponse(token: "tok-123"))
        }
        let client = makeClient()
        _ = try await client.login(email: "ada@example.com", password: "hunter2")

        try await client.linkGitHub(state: "the-state", nonce: "the-nonce")

        let request = try XCTUnwrap(AuthClientStubProtocol.recorded.last?.request)
        XCTAssertEqual(request.url?.path, "/v1/auth/github/link")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tok-123")

        let body = try lastBodyJSON()
        XCTAssertEqual(body["state"] as? String, "the-state")
        XCTAssertEqual(body["nonce"] as? String, "the-nonce")
        XCTAssertFalse(body.keys.contains("code"), "nothing to redeem yet — the browser has not run")
    }

    func testDisconnectGitHubSendsADeleteWithTheBearerToken() async throws {
        AuthClientStubProtocol.handler = { request in
            request.httpMethod == "DELETE" ? (204, Data()) : (200, self.loginResponse(token: "tok-123"))
        }
        let client = makeClient()
        _ = try await client.login(email: "ada@example.com", password: "hunter2")

        try await client.disconnectGitHub()

        let request = try XCTUnwrap(AuthClientStubProtocol.recorded.last?.request)
        XCTAssertEqual(request.url?.path, "/v1/auth/github")
        XCTAssertEqual(request.httpMethod, "DELETE")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tok-123")
    }

    func testDeleteAccountSendsADeleteToMeWithTheBearerTokenAndForgetsIt() async throws {
        AuthClientStubProtocol.handler = { request in
            request.httpMethod == "DELETE" ? (204, Data()) : (200, self.loginResponse(token: "tok-123"))
        }
        let client = makeClient()
        _ = try await client.login(email: "ada@example.com", password: "hunter2")

        try await client.deleteAccount()

        let request = try XCTUnwrap(AuthClientStubProtocol.recorded.last?.request)
        XCTAssertEqual(request.url?.path, "/v1/auth/me")
        XCTAssertEqual(request.httpMethod, "DELETE")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tok-123")
        XCTAssertNil(client.accessToken, "the account is gone, and so is the token for it")
    }

    /// Access tokens live in memory only and expire in fifteen minutes, so a
    /// "Delete account…" pressed an hour into a session meets a 401 — while
    /// the refresh cookie in the jar is still perfectly good. Refresh once
    /// and send it again, rather than telling a signed-in user their session
    /// expired and leaving them on a page that still says "Signed in as …".
    func testDeleteAccountRefreshesAndRetriesWhenTheAccessTokenHasExpired() async throws {
        AuthClientStubProtocol.handler = { request in
            switch (request.url?.path, request.httpMethod) {
            case ("/v1/auth/refresh", _):
                return (200, Data("""
                {"access_token":"tok-fresh","user":\(self.userJSON)}
                """.utf8))
            case ("/v1/auth/me", "DELETE"):
                // Only the refreshed token is accepted; the stale one 401s.
                return request.value(forHTTPHeaderField: "Authorization") == "Bearer tok-fresh"
                    ? (204, Data())
                    : (401, Data(#"{"detail":"Token expired"}"#.utf8))
            default:
                return (200, self.loginResponse(token: "tok-stale"))
            }
        }
        let client = makeClient()
        _ = try await client.login(email: "ada@example.com", password: "hunter2")

        try await client.deleteAccount()

        XCTAssertEqual(
            AuthClientStubProtocol.recorded.suffix(3).map { $0.request.url?.path },
            ["/v1/auth/me", "/v1/auth/refresh", "/v1/auth/me"],
            "the 401 is answered by a refresh and one retry, not by giving up"
        )
        XCTAssertEqual(
            AuthClientStubProtocol.recorded.last?.request.value(forHTTPHeaderField: "Authorization"),
            "Bearer tok-fresh"
        )
        XCTAssertNil(client.accessToken)
    }

    /// No token in hand is `.sessionExpired` without a request: the caller's
    /// No token in hand is `.sessionExpired` without a request: the caller's
    /// answer to that is to refresh and try again, and a request that cannot
    /// possibly succeed is a round trip spent proving it.
    func testABearerCallWithNoTokenFailsAsSessionExpiredWithoutReachingTheServer() async {
        AuthClientStubProtocol.handler = { _ in (204, Data()) }
        let client = makeClient()

        do {
            try await client.linkGitHub(state: "s", nonce: "n")
            XCTFail("expected AuthError.sessionExpired")
        } catch {
            XCTAssertEqual(error as? AuthError, .sessionExpired)
        }
        XCTAssertTrue(AuthClientStubProtocol.recorded.isEmpty, "nothing was sent")
    }

    // MARK: - restoreSession

    func testRestoreSessionSuccessReturnsUserAndStoresRotatedToken() async throws {
        // Refresh's envelope has no "token_type" — the client must not
        // require it.
        AuthClientStubProtocol.handler = { _ in
            (200, Data("""
            {"access_token":"tok-refreshed","user":\(self.userJSON)}
            """.utf8))
        }
        let client = makeClient()

        let user = try await client.restoreSession()

        XCTAssertEqual(user.id, "usr-1")
        XCTAssertEqual(client.accessToken, "tok-refreshed")

        let request = try XCTUnwrap(AuthClientStubProtocol.recorded.last?.request)
        XCTAssertEqual(request.url?.path, "/v1/auth/refresh")
        XCTAssertEqual(request.httpMethod, "POST")
    }

    func testRestoreSession401ThrowsSessionExpired() async {
        AuthClientStubProtocol.handler = { _ in
            (401, Data(#"{"detail":"Invalid refresh token"}"#.utf8))
        }
        let client = makeClient()

        do {
            _ = try await client.restoreSession()
            XCTFail("expected AuthError.sessionExpired")
        } catch {
            XCTAssertEqual(error as? AuthError, .sessionExpired)
        }
        XCTAssertNil(client.accessToken)
    }

    // MARK: - logout

    func testLogoutPostsLogoutAndClearsAccessToken() async throws {
        AuthClientStubProtocol.handler = { request in
            request.url?.path == "/v1/auth/logout" ? (204, Data()) : (200, self.loginResponse(token: "tok-123"))
        }
        let client = makeClient()
        _ = try await client.login(email: "ada@example.com", password: "hunter2")
        XCTAssertEqual(client.accessToken, "tok-123")

        await client.logout()

        XCTAssertNil(client.accessToken)
        let request = try XCTUnwrap(AuthClientStubProtocol.recorded.last?.request)
        XCTAssertEqual(request.url?.path, "/v1/auth/logout")
        XCTAssertEqual(request.httpMethod, "POST")
    }

    func testLogoutClearsAccessTokenEvenWhenTheServerIsUnreachable() async throws {
        AuthClientStubProtocol.handler = { request in
            request.url?.path == "/v1/auth/logout" ? (500, Data()) : (200, self.loginResponse(token: "tok-123"))
        }
        let client = makeClient()
        _ = try await client.login(email: "ada@example.com", password: "hunter2")

        await client.logout()

        XCTAssertNil(client.accessToken, "logout is best-effort: the local token must clear regardless of the server")
    }
}
