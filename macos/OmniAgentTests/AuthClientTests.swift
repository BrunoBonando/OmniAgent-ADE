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
            role: "user",
            authProvider: "password",
            emailVerified: true
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
            // the next native attempt, and in a build without the Sign in
            // with Apple entitlement (this test host, like every current
            // build) the Apple button is a guaranteed dead end and is not
            // even shown.
            XCTAssertFalse(message.localizedCaseInsensitiveContains("web app"), "got: \(message)")
            XCTAssertFalse(AppleSignInCapability.isEnabled, "test host must not carry the entitlement")
            XCTAssertFalse(message.contains("Apple"), "got: \(message)")
        } catch {
            XCTFail("expected AuthError, got \(error)")
        }
    }

    // MARK: - loginWithApple

    func testLoginWithApplePostsIdentityTokenAndNames() async throws {
        AuthClientStubProtocol.handler = { _ in (200, self.loginResponse(token: "tok-apple")) }
        let client = makeClient()

        // familyName nil on purpose: Apple only supplies names on the first
        // authorization, so nil-encoded-as-null is the steady-state shape.
        _ = try await client.loginWithApple(identityToken: "jwt.identity.token", givenName: "Ada", familyName: nil)

        let request = try XCTUnwrap(AuthClientStubProtocol.recorded.last?.request)
        XCTAssertEqual(request.url?.path, "/v1/auth/login/apple")
        XCTAssertEqual(request.httpMethod, "POST")

        let body = try lastBodyJSON()
        XCTAssertEqual(body["identity_token"] as? String, "jwt.identity.token")
        XCTAssertEqual(body["given_name"] as? String, "Ada")
        XCTAssertTrue(body.keys.contains("family_name"))
        XCTAssertTrue(body["family_name"] is NSNull)
        // No Turnstile on the Apple route.
        XCTAssertFalse(body.keys.contains("turnstile_token"))

        XCTAssertEqual(client.accessToken, "tok-apple")
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
