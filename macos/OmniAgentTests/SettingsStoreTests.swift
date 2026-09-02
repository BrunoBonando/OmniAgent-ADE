import XCTest
@testable import OmniAgent

/// An in-memory `SettingsClient` — no socket, no `brain.db`, so
/// `SettingsStore`'s own conventions (defaulting, bool coding) are testable
/// in isolation from `SessionConnection`.
final class FakeSettingsClient: SettingsClient {
    private(set) var rows: [String: String]
    private(set) var setCalls: [(key: String, value: String)] = []
    var failing: Set<String> = []
    /// Keys whose *write* fails — `failing`'s counterpart for `setSetting`.
    /// Separate from `failing` on purpose: a row can be readable and still
    /// refuse a write (a socket that drops mid-request), and
    /// `RemoteSharingModelTests` needs exactly that to pin "a failed write
    /// leaves the in-memory value unchanged" without also faking a read
    /// failure.
    var failingWrites: Set<String> = []
    /// Every key read, in order — how a test asks whether a read happened at
    /// all (`RemoteSharingModelTests`' "a reconnect re-reads nothing").
    private(set) var getCalls: [String] = []

    init(rows: [String: String] = [:]) {
        self.rows = rows
    }

    /// Writes a row **behind the app's back**, the way the daemon does: it
    /// owns `remote_control_blocked` and appends to it on every Block, with
    /// no `setSetting` from this side. Recorded in neither `setCalls` nor
    /// `rows`' history for exactly that reason.
    func seedRow(_ key: String, _ value: String?) {
        rows[key] = value
    }

    func getSetting(key: String, completion: @escaping (Result<String?, Error>) -> Void) {
        getCalls.append(key)
        if failing.contains(key) {
            completion(.failure(SessionConnectionError.disconnected))
            return
        }
        completion(.success(rows[key]))
    }

    func setSetting(key: String, value: String, completion: ((Result<Void, Error>) -> Void)?) {
        if failingWrites.contains(key) {
            completion?(.failure(SessionConnectionError.disconnected))
            return
        }
        rows[key] = value
        setCalls.append((key, value))
        completion?(.success(()))
    }
}

final class SettingsStoreTests: XCTestCase {
    func testGetReturnsTheStoredValueAndNilWhenUnset() {
        let client = FakeSettingsClient(rows: ["review_memory": "true"])
        let store = SettingsStore(client: client)

        let setExpectation = expectation(description: "get")
        store.get("review_memory") { result in
            XCTAssertEqual(try? result.get(), "true")
            setExpectation.fulfill()
        }
        wait(for: [setExpectation], timeout: 1)

        let unsetExpectation = expectation(description: "unset")
        store.get("file_tree_width") { result in
            XCTAssertEqual(try? result.get(), .some(nil))
            unsetExpectation.fulfill()
        }
        wait(for: [unsetExpectation], timeout: 1)
    }

    func testSetForwardsKeyAndValueToTheClient() {
        let client = FakeSettingsClient()
        let store = SettingsStore(client: client)

        let expectation = expectation(description: "set")
        store.set("code_review_width", "320") { result in
            if case let .failure(error) = result { XCTFail("unexpected failure: \(error)") }
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1)

        XCTAssertEqual(client.setCalls.map(\.key), ["code_review_width"])
        XCTAssertEqual(client.setCalls.map(\.value), ["320"])
    }

    func testGetBoolOnlyTheExactStringTrueCountsAndUnsetFallsBackToTheDefault() {
        let client = FakeSettingsClient(rows: ["review_memory": "true", "garbage": "yes"])
        let store = SettingsStore(client: client)

        assertBool(store, key: "review_memory", default: false, expected: true)
        assertBool(store, key: "garbage", default: true, expected: false, message: "only the literal string \"true\" counts")
        assertBool(store, key: "unset", default: true, expected: true)
        assertBool(store, key: "unset", default: false, expected: false)
    }

    func testSetBoolWritesTheLiteralTrueOrFalseString() {
        let client = FakeSettingsClient()
        let store = SettingsStore(client: client)

        let firstExpectation = expectation(description: "set bool")
        store.setBool("review_memory", true) { _ in firstExpectation.fulfill() }
        wait(for: [firstExpectation], timeout: 1)
        XCTAssertEqual(client.rows["review_memory"], "true")

        let secondExpectation = expectation(description: "set bool false")
        store.setBool("review_memory", false) { _ in secondExpectation.fulfill() }
        wait(for: [secondExpectation], timeout: 1)
        XCTAssertEqual(client.rows["review_memory"], "false")
    }

    /// A read that *failed* is not a row that is unset. Collapsing the two
    /// (the old `switch try? result.get()`) put a control in its default
    /// position on a transient daemon error, and the next interaction wrote
    /// that default over the real row in the shared `brain.db` — the failure
    /// class `WorkspaceWindowController.layoutReadFailed` exists to prevent
    /// (final whole-branch review, Minor #11).
    func testGetBoolReportsAFailedReadAsNilRatherThanAsTheDefault() {
        let client = FakeSettingsClient(rows: ["review_memory": "true"])
        client.failing = ["review_memory"]
        let store = SettingsStore(client: client)

        for fallback in [true, false] {
            let expectation = expectation(description: "failed read, default \(fallback)")
            store.getBool("review_memory", default: fallback) { value in
                XCTAssertNil(value, "a failed read must not masquerade as the default")
                expectation.fulfill()
            }
            wait(for: [expectation], timeout: 1)
        }
    }

    private func assertBool(
        _ store: SettingsStore,
        key: String,
        default defaultValue: Bool,
        expected: Bool,
        message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let expectation = expectation(description: key)
        store.getBool(key, default: defaultValue) { value in
            XCTAssertEqual(value, expected, message, file: file, line: line)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1)
    }
}
