import XCTest

@testable import OmniAgent

/// Intercepts every request on the stub session and answers from
/// `RelayStubProtocol.handler` — `AuthClientTests`' pattern (that file's stub
/// is `private` to it, so this is its twin rather than a shared helper: the
/// two clients speak different shapes and a shared stub would have to serve
/// both).
private final class RelayStubProtocol: URLProtocol {
    static var handler: ((URLRequest) -> (status: Int, body: String))?
    static var requests: [URLRequest] = []

    static func reset() {
        handler = nil
        requests = []
    }

    /// `.ephemeral` so the stub session shares no cookie jar or cache with
    /// the real `.shared` session the app uses.
    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RelayStubProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append(request)
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
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

extension URLRequest {
    /// The body as the protocol sees it: URLSession converts `httpBody` into
    /// a stream before a `URLProtocol` ever gets the request, so
    /// `httpBody` is nil here even for requests that sent one.
    fileprivate func bodyData() -> Data {
        if let httpBody { return httpBody }
        guard let stream = httpBodyStream else { return Data() }
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

/// `RelayClient` — the REST half of remote session control (the
/// remote-session-control spec's §2 "Host authentication — device tokens"
/// and §4 "`RelayClient.swift`").
final class RelayClientTests: XCTestCase {
    override func setUp() {
        super.setUp()
        RelayStubProtocol.reset()
    }

    override func tearDown() {
        RelayStubProtocol.reset()
        super.tearDown()
    }

    private func makeClient(accessToken: @escaping () -> String? = { "tok" }) -> RelayClient {
        RelayClient(
            baseURL: URL(string: "https://relay.test")!,
            session: RelayStubProtocol.session(),
            accessToken: accessToken
        )
    }

    func testRegisterDevicePostsNameWithBearerAndDecodesRegistration() async throws {
        RelayStubProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/v1/relay/devices")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
            let body = (try? JSONSerialization.jsonObject(with: request.bodyData())) as? [String: String]
            XCTAssertEqual(body?["name"], "M4x Studio")
            return (200, #"{"device_id":"d1","token":"secret"}"#)
        }
        let client = makeClient()

        let reg = try await client.registerDevice(name: "M4x Studio")

        XCTAssertEqual(reg, .init(deviceID: "d1", token: "secret"))
        XCTAssertEqual(client.viewerSocketURL(deviceID: "d1").absoluteString, "wss://relay.test/v1/viewer/d1")
        XCTAssertTrue(client.deviceTokenRow(reg, name: "M4x Studio").contains(#""relay_url":"https://relay.test""#))
    }

    /// The row handed to the daemon is the spec's exact shape — snake_case,
    /// four keys, the token never anywhere else.
    func testDeviceTokenRowIsTheDaemonsContract() {
        let client = makeClient()
        XCTAssertEqual(
            client.deviceTokenRow(.init(deviceID: "d1", token: "secret"), name: "M4x Studio"),
            #"{"device_id":"d1","name":"M4x Studio","relay_url":"https://relay.test","token":"secret"}"#
        )
    }

    func testListDevicesDecodesSnakeCase() async throws {
        RelayStubProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/v1/relay/devices")
            return (200, #"[{"device_id":"d1","name":"Mac","online":true,"last_seen_at":null}]"#)
        }
        let client = makeClient()

        let devices = try await client.listDevices()

        XCTAssertEqual(devices, [.init(deviceID: "d1", name: "Mac", online: true, lastSeenAt: nil)])
    }

    func testDeleteDeviceSendsDeleteToTheDeviceRoute() async throws {
        RelayStubProtocol.handler = { _ in (204, "") }
        let client = makeClient()

        try await client.deleteDevice(id: "d1")

        XCTAssertEqual(RelayStubProtocol.requests.map(\.httpMethod), ["DELETE"])
        XCTAssertEqual(RelayStubProtocol.requests.first?.url?.path, "/v1/relay/devices/d1")
    }

    /// No token in hand is not an unauthenticated request: it is the caller's
    /// "sign in again" path, reached without a pointless round trip —
    /// `AuthClient.authorized`'s rule.
    func testMissingAccessTokenThrowsBeforeAnyRequest() async {
        RelayStubProtocol.handler = { _ in
            XCTFail("no request expected without an access token")
            return (500, "")
        }
        let client = makeClient(accessToken: { nil })
        do {
            _ = try await client.listDevices()
            XCTFail("listDevices should throw without an access token")
        } catch {}
        XCTAssertEqual(RelayStubProtocol.requests.count, 0)
    }

    /// A non-2xx carries the server's own words to the ask card, rather than
    /// a bare status number.
    func testNonSuccessStatusThrowsWithTheServersDetail() async {
        RelayStubProtocol.handler = { _ in (403, #"{"detail":"device limit reached"}"#) }
        let client = makeClient()
        do {
            _ = try await client.registerDevice(name: "Mac")
            XCTFail("a 403 should throw")
        } catch {
            XCTAssertTrue(
                error.localizedDescription.contains("device limit reached"),
                "the server's detail should survive into the error: \(error.localizedDescription)"
            )
        }
    }

    /// A local relay (`http://`) gets `ws://`, not `wss://`.
    func testViewerSocketURLFollowsTheBaseSchemeForPlainHTTP() {
        let client = RelayClient(
            baseURL: URL(string: "http://127.0.0.1:8080")!,
            session: RelayStubProtocol.session(),
            accessToken: { "tok" }
        )
        XCTAssertEqual(client.viewerSocketURL(deviceID: "d1").absoluteString, "ws://127.0.0.1:8080/v1/viewer/d1")
    }
}
