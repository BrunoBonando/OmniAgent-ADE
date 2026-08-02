import XCTest
@testable import OmniAgent

/// An in-memory `SettingsClient` — no socket, no `brain.db`, so
/// `SettingsStore`'s own conventions (defaulting, bool coding) are testable
/// in isolation from `SessionConnection`.
final class FakeSettingsClient: SettingsClient {
    private(set) var rows: [String: String]
    private(set) var setCalls: [(key: String, value: String)] = []
    var failing: Set<String> = []

    init(rows: [String: String] = [:]) {
        self.rows = rows
    }

    func getSetting(key: String, completion: @escaping (Result<String?, Error>) -> Void) {
        if failing.contains(key) {
            completion(.failure(SessionConnectionError.disconnected))
            return
        }
        completion(.success(rows[key]))
    }

    func setSetting(key: String, value: String, completion: ((Result<Void, Error>) -> Void)?) {
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
