import Foundation

/// What can go wrong talking to the relay's REST half. `LocalizedError` so
/// `error.localizedDescription` is what the ask card prints — the server's
/// own `detail` when it sent one, never a bare status number.
enum RelayError: Error, LocalizedError, Equatable {
    /// No access token in hand. Not an unauthenticated request: the caller's
    /// "sign in again" path, reached without a pointless round trip —
    /// `AuthClient.authorized`'s rule.
    case notSignedIn
    /// Any non-2xx: (status code, server detail or raw body).
    case server(Int, String)
    /// The request never got an HTTP response — offline, DNS, TLS, timeout.
    case network(String)
    /// A 2xx whose body does not decode: a server-contract break, reported
    /// as such rather than swallowed.
    case malformedResponse

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "Sign in to OmniAgent to use Remote Control."
        case let .server(status, detail):
            return detail.isEmpty ? "The relay answered \(status)." : detail
        case let .network(detail):
            return detail
        case .malformedResponse:
            return "The relay's response could not be read."
        }
    }
}

/// The relay's REST half — device registration, the device list, revocation
/// — next to `AuthClient` and built the same way (the remote-session-control
/// spec's §2 "Host authentication — device tokens" and §4 "`RelayClient.swift`",
/// docs/superpowers/specs/2026-08-30-remote-session-control-design.md).
///
/// Registration is the one moment the *app* is in the loop: the daemon has
/// to keep working with the app closed, so it cannot hold a 15-minute access
/// token. The app spends its access token once, on `POST /v1/relay/devices`,
/// and hands the long-lived device token straight to the daemon
/// (`SetSetting("relay_device_token", …)`). The token is returned exactly
/// once — only its SHA-256 is stored server-side — so it is never re-readable
/// and deleting the row revokes this Mac everywhere.
///
/// Not thread-safe, `AuthClient`'s reasoning: every caller is on the main
/// actor.
final class RelayClient {
    static let shared = RelayClient()

    /// A registered machine as the relay reports it — what the viewer side
    /// (B4) draws its sidebar sections from.
    struct Device: Codable, Equatable {
        let deviceID: String
        let name: String
        let online: Bool
        let lastSeenAt: String?

        enum CodingKeys: String, CodingKey {
            case deviceID = "device_id"
            case name
            case online
            case lastSeenAt = "last_seen_at"
        }
    }

    /// `POST /v1/relay/devices`' one-time answer.
    struct Registration: Codable, Equatable {
        let deviceID: String
        let token: String

        enum CodingKeys: String, CodingKey {
            case deviceID = "device_id"
            case token
        }
    }

    /// Relay origin. `UserDefaults` overrides it for staging and local dev —
    /// `AuthClient.baseURL`'s pattern, and a defaults key rather than an env
    /// var because a launched .app inherits no shell environment. Two keys
    /// are read: `OMNIAGENT_RELAY_BASE_URL` (this file's own, matching
    /// `OMNIAGENT_API_BASE_URL`) and `OMNIAGENT_RELAY_URL` (the name the
    /// daemon's env var carries in the spec, so one `defaults write` can set
    /// both sides while debugging).
    let baseURL: URL

    private let session: URLSession
    /// Read fresh per request: the access token is short-lived and rotates
    /// under a refresh, so capturing its *value* here would strand this
    /// client on the token that existed at construction.
    private let accessToken: () -> String?

    init(
        baseURL: URL? = nil,
        session: URLSession = .shared,
        accessToken: @escaping () -> String? = { AuthClient.shared.accessToken }
    ) {
        self.baseURL = baseURL
            ?? UserDefaults.standard.string(forKey: "OMNIAGENT_RELAY_BASE_URL").flatMap(URL.init(string:))
            ?? UserDefaults.standard.string(forKey: "OMNIAGENT_RELAY_URL").flatMap(URL.init(string:))
            ?? URL(string: "https://relay.omni-agent.ai")!
        self.session = session
        self.accessToken = accessToken
    }

    // MARK: - Public API

    /// `POST /v1/relay/devices` — registers this Mac and returns the device
    /// token, which the caller must hand to the daemon and then forget: the
    /// relay stores only its hash and will never say it again.
    func registerDevice(name: String) async throws -> Registration {
        let data = try await perform(request(path: "v1/relay/devices", method: "POST", body: ["name": name]))
        guard let registration = try? decoder.decode(Registration.self, from: data) else {
            throw RelayError.malformedResponse
        }
        return registration
    }

    /// `GET /v1/relay/devices` — every machine on this account, with the
    /// relay's own view of which are connected.
    func listDevices() async throws -> [Device] {
        let data = try await perform(request(path: "v1/relay/devices", method: "GET", body: nil))
        guard let devices = try? decoder.decode([Device].self, from: data) else {
            throw RelayError.malformedResponse
        }
        return devices
    }

    /// `DELETE /v1/relay/devices/{id}` — revokes a machine everywhere, at
    /// once: the daemon's next frame fails its hash lookup.
    func deleteDevice(id: String) async throws {
        _ = try await perform(request(path: "v1/relay/devices/\(id)", method: "DELETE", body: nil))
    }

    /// Where a viewer opens its WebSocket for a given machine. `wss` for an
    /// `https` relay, `ws` for a plain-`http` one (local dev only) — the
    /// scheme follows the base, so a test or a laptop pointed at
    /// `http://127.0.0.1` does not try TLS against a plaintext port.
    func viewerSocketURL(deviceID: String) -> URL {
        socketURL(path: "/v1/viewer/\(deviceID)")
    }

    /// The `relay_device_token` settings row, in the daemon's exact shape:
    /// `{"device_id","token","name","relay_url"}`. The relay URL travels with
    /// the token deliberately — the daemon must know which relay this token
    /// is good for without inheriting the app's `UserDefaults`.
    func deviceTokenRow(_ registration: Registration, name: String) -> String {
        let row: [String: String] = [
            "device_id": registration.deviceID,
            "token": registration.token,
            "name": name,
            "relay_url": baseURL.absoluteString,
        ]
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: row,
                // `.sortedKeys` for `write(_:to:)`'s change detection;
                // `.withoutEscapingSlashes` so the URL in the row reads as a
                // URL — `RemoteControlProjection.encode`'s reasoning.
                options: [.sortedKeys, .withoutEscapingSlashes]
            ),
            let json = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }
        return json
    }

    // MARK: - Internals

    /// One decoder for both shapes. `CodingKeys` rather than
    /// `.convertFromSnakeCase`: that strategy maps `device_id` to `deviceId`,
    /// not `deviceID`, so the acronym-cased properties need the keys spelled
    /// out anyway.
    private let decoder = JSONDecoder()

    private func socketURL(path: String) -> URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.scheme = baseURL.scheme == "http" ? "ws" : "wss"
        components?.path = path
        guard let url = components?.url else {
            // Unreachable for any base URL that parsed at init; a plain
            // string swap keeps this total rather than crashing the app over
            // a settings typo.
            return URL(string: "wss://\(baseURL.host ?? "relay.omni-agent.ai")\(path)")!
        }
        return url
    }

    private func request(path: String, method: String, body: [String: Any]?) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        return request
    }

    /// Attaches the bearer, runs the request, and folds everything that is
    /// not a 2xx into `RelayError` — `AuthClient.perform`/`authorized`'s
    /// shape, one place so every route reports failures identically.
    private func perform(_ request: URLRequest) async throws -> Data {
        guard let token = accessToken() else { throw RelayError.notSignedIn }
        var request = request
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw RelayError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw RelayError.network("Non-HTTP response from \(request.url?.absoluteString ?? "the relay").")
        }
        guard (200...299).contains(http.statusCode) else {
            throw RelayError.server(http.statusCode, detail(from: data))
        }
        return data
    }

    private func detail(from data: Data) -> String {
        if
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let detail = object["detail"] as? String
        {
            return detail
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
