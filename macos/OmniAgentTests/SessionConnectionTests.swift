import Darwin
import XCTest
@testable import OmniAgent

final class SessionConnectionTests: XCTestCase {
    func testReconnectReattachesAfterLatestRawOutputSequence() throws {
        let socketPath = "/tmp/omniagent-\(UUID().uuidString.prefix(8)).sock"
        let server = try UnixTestServer(path: socketPath)
        let initialAttach = expectation(description: "initial sequence attach")
        let rawOutput = expectation(description: "raw output")
        let resumedAttach = expectation(description: "reattach after reconnect")

        server.run { firstClient in
            let hello = try readFrame(from: firstClient)
            try writeFrame(
                SessionFrame(
                    kind: .helloAck,
                    requestOrSequence: hello.requestOrSequence,
                    payload: try JSONSerialization.data(withJSONObject: ["protocol_version": 1])
                ),
                to: firstClient,
                splitAt: 7
            )
            let attach = try readFrame(from: firstClient)
            let firstPayload = try XCTUnwrap(
                JSONSerialization.jsonObject(with: attach.payload) as? [String: Any]
            )
            XCTAssertEqual((firstPayload["after_sequence"] as? NSNumber)?.uint64Value, 40)
            initialAttach.fulfill()
            try writeFrame(
                SessionFrame(
                    kind: .output,
                    requestOrSequence: 41,
                    payload: try RawPayload.encode(
                        sessionID: "native-terminal",
                        bytes: Data([0, 0xff, 0x1b, 0x5b])
                    )
                ),
                to: firstClient,
                splitAt: 19
            )
            Darwin.close(firstClient)

            let secondClient = try server.accept()
            let reconnectHello = try readFrame(from: secondClient)
            try writeFrame(
                SessionFrame(
                    kind: .helloAck,
                    requestOrSequence: reconnectHello.requestOrSequence,
                    payload: try JSONSerialization.data(withJSONObject: ["protocol_version": 1])
                ),
                to: secondClient
            )
            let reattach = try readFrame(from: secondClient)
            let resumedPayload = try XCTUnwrap(
                JSONSerialization.jsonObject(with: reattach.payload) as? [String: Any]
            )
            XCTAssertEqual((resumedPayload["after_sequence"] as? NSNumber)?.uint64Value, 41)
            resumedAttach.fulfill()
            Darwin.close(secondClient)
        }

        let connection = SessionConnection(
            socketURL: URL(fileURLWithPath: socketPath),
            reconnectDelay: 0.02
        )
        var attached = false
        connection.onStateChange = { state in
            guard state == .connected, !attached else { return }
            attached = true
            connection.attach(sessionID: "native-terminal", afterSequence: 40)
        }
        connection.onTerminalData = { sessionID, bytes, sequence, isSnapshot in
            XCTAssertEqual(sessionID, "native-terminal")
            XCTAssertEqual(bytes, Data([0, 0xff, 0x1b, 0x5b]))
            XCTAssertEqual(sequence, 41)
            XCTAssertFalse(isSnapshot)
            rawOutput.fulfill()
        }
        connection.connect()

        wait(for: [initialAttach, rawOutput, resumedAttach], timeout: 3)
        connection.disconnect()
        server.stop()
    }

    // MARK: - Restart-loss reporting (Task 6c)

    /// The daemon restarted while this session was attached: the reconnect
    /// after `firstClient` drops finds a *new* daemon that has never heard
    /// of "native-terminal" (`Attach` -> `.error`, "session not found").
    /// `onReattachFailed` is the signal `DaemonPersistenceController` turns
    /// into a restart-loss report — this test is the contract for it.
    func testReconnectReportsReattachFailureWhenTheDaemonNoLongerKnowsTheSession() throws {
        let socketPath = "/tmp/omniagent-\(UUID().uuidString.prefix(8)).sock"
        let server = try UnixTestServer(path: socketPath)
        let initialAttach = expectation(description: "initial attach")
        let reattachRejected = expectation(description: "reattach rejected")

        server.run { firstClient in
            let hello = try readFrame(from: firstClient)
            try writeFrame(
                SessionFrame(
                    kind: .helloAck,
                    requestOrSequence: hello.requestOrSequence,
                    payload: try JSONSerialization.data(withJSONObject: ["protocol_version": 1])
                ),
                to: firstClient
            )
            _ = try readFrame(from: firstClient)
            initialAttach.fulfill()
            Darwin.close(firstClient)

            let secondClient = try server.accept()
            let reconnectHello = try readFrame(from: secondClient)
            try writeFrame(
                SessionFrame(
                    kind: .helloAck,
                    requestOrSequence: reconnectHello.requestOrSequence,
                    payload: try JSONSerialization.data(withJSONObject: ["protocol_version": 1])
                ),
                to: secondClient
            )
            let reattach = try readFrame(from: secondClient)
            try writeFrame(
                SessionFrame(
                    kind: .error,
                    requestOrSequence: reattach.requestOrSequence,
                    payload: try JSONSerialization.data(
                        withJSONObject: ["message": "session native-terminal not found"]
                    )
                ),
                to: secondClient
            )
            reattachRejected.fulfill()
            Darwin.close(secondClient)
        }

        let connection = SessionConnection(
            socketURL: URL(fileURLWithPath: socketPath),
            reconnectDelay: 0.02
        )
        var attached = false
        connection.onStateChange = { state in
            guard state == .connected, !attached else { return }
            attached = true
            connection.attach(sessionID: "native-terminal", afterSequence: nil)
        }
        var reportedLoss: [String] = []
        let onReattachFailedCalled = expectation(description: "onReattachFailed fired")
        connection.onReattachFailed = { sessionID in
            reportedLoss.append(sessionID)
            onReattachFailedCalled.fulfill()
        }
        connection.connect()

        wait(for: [initialAttach, reattachRejected, onReattachFailedCalled], timeout: 3)
        XCTAssertEqual(reportedLoss, ["native-terminal"])
        connection.disconnect()
        server.stop()
    }

    /// Minor #10: `pendingReattachSessions` was pruned only on the `.error`
    /// branch, so every *successful* reattach left an entry behind — one per
    /// session per reconnect, forever. Two reconnects, both reattaching
    /// successfully, must leave nothing behind.
    func testASuccessfulReattachDoesNotAccumulateTrackingEntriesAcrossReconnects() throws {
        let socketPath = "/tmp/omniagent-\(UUID().uuidString.prefix(8)).sock"
        let server = try UnixTestServer(path: socketPath)
        let firstAttach = expectation(description: "first attach answered")
        let secondAttach = expectation(description: "reattach answered")

        func answerSnapshot(_ client: Int32, request: UInt64) throws {
            // The daemon answers an attach with a Snapshot carrying a
            // *sequence*, not the attach's request id — the exact reason the
            // entry could not be found by request id on the success path.
            try writeFrame(
                SessionFrame(
                    kind: .snapshot,
                    requestOrSequence: 7,
                    payload: try RawPayload.encode(sessionID: "native-terminal", bytes: Data("hi".utf8))
                ),
                to: client
            )
        }

        server.run { firstClient in
            let hello = try readFrame(from: firstClient)
            try writeFrame(
                SessionFrame(
                    kind: .helloAck,
                    requestOrSequence: hello.requestOrSequence,
                    payload: try JSONSerialization.data(withJSONObject: ["protocol_version": 1])
                ),
                to: firstClient
            )
            let attach = try readFrame(from: firstClient)
            try answerSnapshot(firstClient, request: attach.requestOrSequence)
            firstAttach.fulfill()
            Darwin.close(firstClient)

            let secondClient = try server.accept()
            let reconnectHello = try readFrame(from: secondClient)
            try writeFrame(
                SessionFrame(
                    kind: .helloAck,
                    requestOrSequence: reconnectHello.requestOrSequence,
                    payload: try JSONSerialization.data(withJSONObject: ["protocol_version": 1])
                ),
                to: secondClient
            )
            let reattach = try readFrame(from: secondClient)
            try answerSnapshot(secondClient, request: reattach.requestOrSequence)
            secondAttach.fulfill()
            Darwin.close(secondClient)
        }

        let connection = SessionConnection(
            socketURL: URL(fileURLWithPath: socketPath),
            reconnectDelay: 0.02
        )
        var attached = false
        connection.onStateChange = { state in
            guard state == .connected, !attached else { return }
            attached = true
            connection.attach(sessionID: "native-terminal", afterSequence: nil)
        }
        let snapshots = expectation(description: "two snapshots delivered")
        snapshots.expectedFulfillmentCount = 2
        connection.onTerminalData = { _, _, _, isSnapshot in
            if isSnapshot { snapshots.fulfill() }
        }
        connection.connect()

        wait(for: [firstAttach, secondAttach, snapshots], timeout: 3)
        XCTAssertEqual(
            connection.pendingReattachCount,
            0,
            "a confirmed reattach must not leave a tracking entry behind"
        )
        connection.disconnect()
        XCTAssertEqual(connection.pendingReattachCount, 0, "and disconnecting clears the rest")
        server.stop()
    }

    // MARK: - Settings / brain client methods (Task 6a)

    func testGetSettingSendsTheKeyAndDecodesAnOptionalValue() throws {
        let socketPath = "/tmp/omniagent-\(UUID().uuidString.prefix(8)).sock"
        let server = try UnixTestServer(path: socketPath)
        let responded = expectation(description: "getSetting responded")

        server.run { client in
            try Self.ackHello(on: client)
            let request = try readFrame(from: client)
            XCTAssertEqual(request.kind, .getSetting)
            let payload = try XCTUnwrap(
                JSONSerialization.jsonObject(with: request.payload) as? [String: Any]
            )
            XCTAssertEqual(payload["key"] as? String, "layout")
            try writeFrame(
                SessionFrame(
                    kind: .response,
                    requestOrSequence: request.requestOrSequence,
                    payload: try JSONSerialization.data(withJSONObject: ["value": "{\"tabs\":[]}"])
                ),
                to: client
            )
        }

        let connection = SessionConnection(
            socketURL: URL(fileURLWithPath: socketPath),
            reconnectDelay: 0.02
        )
        var sent = false
        connection.onStateChange = { state in
            guard state == .connected, !sent else { return }
            sent = true
            connection.getSetting(key: "layout") { result in
                XCTAssertEqual(try? result.get(), "{\"tabs\":[]}")
                responded.fulfill()
            }
        }
        connection.connect()

        wait(for: [responded], timeout: 3)
        connection.disconnect()
        server.stop()
    }

    func testGetSettingDecodesAMissingValueAsNil() throws {
        let socketPath = "/tmp/omniagent-\(UUID().uuidString.prefix(8)).sock"
        let server = try UnixTestServer(path: socketPath)
        let responded = expectation(description: "getSetting responded")

        server.run { client in
            try Self.ackHello(on: client)
            let request = try readFrame(from: client)
            try writeFrame(
                SessionFrame(
                    kind: .response,
                    requestOrSequence: request.requestOrSequence,
                    payload: try JSONSerialization.data(withJSONObject: ["value": NSNull()])
                ),
                to: client
            )
        }

        let connection = SessionConnection(
            socketURL: URL(fileURLWithPath: socketPath),
            reconnectDelay: 0.02
        )
        var sent = false
        connection.onStateChange = { state in
            guard state == .connected, !sent else { return }
            sent = true
            connection.getSetting(key: "does-not-exist") { result in
                switch result {
                case let .success(value):
                    XCTAssertNil(value)
                case let .failure(error):
                    XCTFail("getSetting failed: \(error)")
                }
                responded.fulfill()
            }
        }
        connection.connect()

        wait(for: [responded], timeout: 3)
        connection.disconnect()
        server.stop()
    }

    func testSetSettingSendsTheKeyAndValueAndCompletesOnResponse() throws {
        let socketPath = "/tmp/omniagent-\(UUID().uuidString.prefix(8)).sock"
        let server = try UnixTestServer(path: socketPath)
        let responded = expectation(description: "setSetting responded")

        server.run { client in
            try Self.ackHello(on: client)
            let request = try readFrame(from: client)
            XCTAssertEqual(request.kind, .setSetting)
            let payload = try XCTUnwrap(
                JSONSerialization.jsonObject(with: request.payload) as? [String: Any]
            )
            XCTAssertEqual(payload["key"] as? String, "layout")
            XCTAssertEqual(payload["value"] as? String, "{\"tabs\":[]}")
            try writeFrame(
                SessionFrame(
                    kind: .response,
                    requestOrSequence: request.requestOrSequence,
                    payload: try JSONSerialization.data(withJSONObject: ["ok": true])
                ),
                to: client
            )
        }

        let connection = SessionConnection(
            socketURL: URL(fileURLWithPath: socketPath),
            reconnectDelay: 0.02
        )
        var sent = false
        connection.onStateChange = { state in
            guard state == .connected, !sent else { return }
            sent = true
            connection.setSetting(key: "layout", value: "{\"tabs\":[]}") { result in
                if case let .failure(error) = result {
                    XCTFail("setSetting failed: \(error)")
                }
                responded.fulfill()
            }
        }
        connection.connect()

        wait(for: [responded], timeout: 3)
        connection.disconnect()
        server.stop()
    }

    func testListProjectsSendsAnEmptyPayloadAndDecodesTheProjectSummaries() throws {
        let socketPath = "/tmp/omniagent-\(UUID().uuidString.prefix(8)).sock"
        let server = try UnixTestServer(path: socketPath)
        let responded = expectation(description: "listProjects responded")

        server.run { client in
            try Self.ackHello(on: client)
            let request = try readFrame(from: client)
            XCTAssertEqual(request.kind, .brainListProjects)
            try writeFrame(
                SessionFrame(
                    kind: .response,
                    requestOrSequence: request.requestOrSequence,
                    payload: try JSONSerialization.data(withJSONObject: [
                        "projects": [
                            ["id": "demo", "label": "demo", "path": "/tmp/demo"],
                            ["id": "other", "label": "Other", "path": NSNull()],
                        ],
                    ])
                ),
                to: client
            )
        }

        let connection = SessionConnection(
            socketURL: URL(fileURLWithPath: socketPath),
            reconnectDelay: 0.02
        )
        var sent = false
        connection.onStateChange = { state in
            guard state == .connected, !sent else { return }
            sent = true
            connection.listProjects { result in
                let projects = try? result.get()
                XCTAssertEqual(
                    projects,
                    [
                        BrainProjectSummary(id: "demo", label: "demo", path: "/tmp/demo"),
                        BrainProjectSummary(id: "other", label: "Other", path: nil),
                    ]
                )
                responded.fulfill()
            }
        }
        connection.connect()

        wait(for: [responded], timeout: 3)
        connection.disconnect()
        server.stop()
    }

    func testGetContextSendsTheProjectAndDecodesTheBriefing() throws {
        let socketPath = "/tmp/omniagent-\(UUID().uuidString.prefix(8)).sock"
        let server = try UnixTestServer(path: socketPath)
        let responded = expectation(description: "getContext responded")

        server.run { client in
            try Self.ackHello(on: client)
            let request = try readFrame(from: client)
            XCTAssertEqual(request.kind, .brainGetContext)
            let payload = try XCTUnwrap(
                JSONSerialization.jsonObject(with: request.payload) as? [String: Any]
            )
            XCTAssertEqual(payload["project"] as? String, "demo")
            try writeFrame(
                SessionFrame(
                    kind: .response,
                    requestOrSequence: request.requestOrSequence,
                    payload: try JSONSerialization.data(withJSONObject: [
                        "context": [
                            "summary": "A demo project.",
                            "recent_decisions": [
                                ["id": "demo:d1", "kind": "memory", "project": "demo", "label": "Decision: x"],
                            ],
                            "related_projects": [],
                            "memory_notes": [],
                        ],
                    ])
                ),
                to: client
            )
        }

        let connection = SessionConnection(
            socketURL: URL(fileURLWithPath: socketPath),
            reconnectDelay: 0.02
        )
        var sent = false
        connection.onStateChange = { state in
            guard state == .connected, !sent else { return }
            sent = true
            connection.getContext(project: "demo") { result in
                let context = try? result.get()
                XCTAssertEqual(context?.summary, "A demo project.")
                XCTAssertEqual(context?.recentDecisions.count, 1)
                XCTAssertEqual(context?.recentDecisions.first?.id, "demo:d1")
                XCTAssertEqual(context?.recentDecisions.first?.path, nil)
                XCTAssertEqual(context?.relatedProjects, [])
                XCTAssertEqual(context?.memoryNotes, [])
                responded.fulfill()
            }
        }
        connection.connect()

        wait(for: [responded], timeout: 3)
        connection.disconnect()
        server.stop()
    }

    // MARK: - Roots / ingestion / search client methods (Task 6a-2)

    func testStartIngestSendsThePathAndCompletesOnAck() throws {
        let socketPath = "/tmp/omniagent-\(UUID().uuidString.prefix(8)).sock"
        let server = try UnixTestServer(path: socketPath)
        let responded = expectation(description: "startIngest responded")

        server.run { client in
            try Self.ackHello(on: client)
            let request = try readFrame(from: client)
            XCTAssertEqual(request.kind, .rootsStartIngest)
            let payload = try XCTUnwrap(
                JSONSerialization.jsonObject(with: request.payload) as? [String: Any]
            )
            XCTAssertEqual(payload["path"] as? String, "/tmp/projects")
            try writeFrame(
                SessionFrame(
                    kind: .response,
                    requestOrSequence: request.requestOrSequence,
                    payload: try JSONSerialization.data(withJSONObject: ["ok": true])
                ),
                to: client
            )
        }

        let connection = SessionConnection(
            socketURL: URL(fileURLWithPath: socketPath),
            reconnectDelay: 0.02
        )
        var sent = false
        connection.onStateChange = { state in
            guard state == .connected, !sent else { return }
            sent = true
            connection.startIngest(path: "/tmp/projects") { result in
                if case .failure(let error) = result { XCTFail("unexpected failure: \(error)") }
                responded.fulfill()
            }
        }
        connection.connect()

        wait(for: [responded], timeout: 3)
        connection.disconnect()
        server.stop()
    }

    func testIngestionStatusDecodesTheSnapshot() throws {
        let socketPath = "/tmp/omniagent-\(UUID().uuidString.prefix(8)).sock"
        let server = try UnixTestServer(path: socketPath)
        let responded = expectation(description: "ingestionStatus responded")

        server.run { client in
            try Self.ackHello(on: client)
            let request = try readFrame(from: client)
            XCTAssertEqual(request.kind, .rootsIngestionStatus)
            try writeFrame(
                SessionFrame(
                    kind: .response,
                    requestOrSequence: request.requestOrSequence,
                    payload: try JSONSerialization.data(withJSONObject: [
                        "status": [
                            "running": true,
                            "projects_total": 3,
                            "projects_done": 1,
                            "current_project": "demo",
                            "total_nodes": 42,
                            "error": NSNull(),
                        ],
                    ])
                ),
                to: client
            )
        }

        let connection = SessionConnection(
            socketURL: URL(fileURLWithPath: socketPath),
            reconnectDelay: 0.02
        )
        var sent = false
        connection.onStateChange = { state in
            guard state == .connected, !sent else { return }
            sent = true
            connection.ingestionStatus { result in
                let status = try? result.get()
                XCTAssertEqual(
                    status,
                    IngestionStatus(
                        running: true,
                        projectsTotal: 3,
                        projectsDone: 1,
                        currentProject: "demo",
                        totalNodes: 42,
                        error: nil
                    )
                )
                responded.fulfill()
            }
        }
        connection.connect()

        wait(for: [responded], timeout: 3)
        connection.disconnect()
        server.stop()
    }

    func testRootsListDecodesEveryPersistedRoot() throws {
        let socketPath = "/tmp/omniagent-\(UUID().uuidString.prefix(8)).sock"
        let server = try UnixTestServer(path: socketPath)
        let responded = expectation(description: "rootsList responded")

        server.run { client in
            try Self.ackHello(on: client)
            let request = try readFrame(from: client)
            XCTAssertEqual(request.kind, .rootsList)
            try writeFrame(
                SessionFrame(
                    kind: .response,
                    requestOrSequence: request.requestOrSequence,
                    payload: try JSONSerialization.data(withJSONObject: ["roots": ["/tmp/projects"]])
                ),
                to: client
            )
        }

        let connection = SessionConnection(
            socketURL: URL(fileURLWithPath: socketPath),
            reconnectDelay: 0.02
        )
        var sent = false
        connection.onStateChange = { state in
            guard state == .connected, !sent else { return }
            sent = true
            connection.rootsList { result in
                XCTAssertEqual(try? result.get(), ["/tmp/projects"])
                responded.fulfill()
            }
        }
        connection.connect()

        wait(for: [responded], timeout: 3)
        connection.disconnect()
        server.stop()
    }

    func testBiggestProjectDecodesNilWhenNothingIngestedYet() throws {
        let socketPath = "/tmp/omniagent-\(UUID().uuidString.prefix(8)).sock"
        let server = try UnixTestServer(path: socketPath)
        let responded = expectation(description: "biggestProject responded")

        server.run { client in
            try Self.ackHello(on: client)
            let request = try readFrame(from: client)
            XCTAssertEqual(request.kind, .rootsBiggestProject)
            try writeFrame(
                SessionFrame(
                    kind: .response,
                    requestOrSequence: request.requestOrSequence,
                    payload: try JSONSerialization.data(withJSONObject: ["project": NSNull()])
                ),
                to: client
            )
        }

        let connection = SessionConnection(
            socketURL: URL(fileURLWithPath: socketPath),
            reconnectDelay: 0.02
        )
        var sent = false
        connection.onStateChange = { state in
            guard state == .connected, !sent else { return }
            sent = true
            connection.biggestProject { result in
                switch result {
                case let .success(project):
                    XCTAssertNil(project)
                case let .failure(error):
                    XCTFail("biggestProject failed: \(error)")
                }
                responded.fulfill()
            }
        }
        connection.connect()

        wait(for: [responded], timeout: 3)
        connection.disconnect()
        server.stop()
    }

    func testAddProjectSendsPathAndNameAndDecodesTheSummary() throws {
        let socketPath = "/tmp/omniagent-\(UUID().uuidString.prefix(8)).sock"
        let server = try UnixTestServer(path: socketPath)
        let responded = expectation(description: "addProject responded")

        server.run { client in
            try Self.ackHello(on: client)
            let request = try readFrame(from: client)
            XCTAssertEqual(request.kind, .rootsAddProject)
            let payload = try XCTUnwrap(
                JSONSerialization.jsonObject(with: request.payload) as? [String: Any]
            )
            XCTAssertEqual(payload["path"] as? String, "/tmp/one-project")
            XCTAssertEqual(payload["name"] as? String, "My Project")
            try writeFrame(
                SessionFrame(
                    kind: .response,
                    requestOrSequence: request.requestOrSequence,
                    payload: try JSONSerialization.data(withJSONObject: [
                        "project": ["id": "My Project", "label": "My Project", "path": "/tmp/one-project"],
                    ])
                ),
                to: client
            )
        }

        let connection = SessionConnection(
            socketURL: URL(fileURLWithPath: socketPath),
            reconnectDelay: 0.02
        )
        var sent = false
        connection.onStateChange = { state in
            guard state == .connected, !sent else { return }
            sent = true
            connection.addProject(path: "/tmp/one-project", name: "My Project") { result in
                XCTAssertEqual(
                    try? result.get(),
                    BrainProjectSummary(id: "My Project", label: "My Project", path: "/tmp/one-project")
                )
                responded.fulfill()
            }
        }
        connection.connect()

        wait(for: [responded], timeout: 3)
        connection.disconnect()
        server.stop()
    }

    func testRenameProjectSendsIdAndNewLabelAndCompletesOnAck() throws {
        let socketPath = "/tmp/omniagent-\(UUID().uuidString.prefix(8)).sock"
        let server = try UnixTestServer(path: socketPath)
        let responded = expectation(description: "renameProject responded")

        server.run { client in
            try Self.ackHello(on: client)
            let request = try readFrame(from: client)
            XCTAssertEqual(request.kind, .rootsRenameProject)
            let payload = try XCTUnwrap(
                JSONSerialization.jsonObject(with: request.payload) as? [String: Any]
            )
            XCTAssertEqual(payload["id"] as? String, "demo")
            XCTAssertEqual(payload["new_label"] as? String, "Renamed")
            try writeFrame(
                SessionFrame(
                    kind: .response,
                    requestOrSequence: request.requestOrSequence,
                    payload: try JSONSerialization.data(withJSONObject: ["ok": true])
                ),
                to: client
            )
        }

        let connection = SessionConnection(
            socketURL: URL(fileURLWithPath: socketPath),
            reconnectDelay: 0.02
        )
        var sent = false
        connection.onStateChange = { state in
            guard state == .connected, !sent else { return }
            sent = true
            connection.renameProject(id: "demo", newLabel: "Renamed") { result in
                if case .failure(let error) = result { XCTFail("unexpected failure: \(error)") }
                responded.fulfill()
            }
        }
        connection.connect()

        wait(for: [responded], timeout: 3)
        connection.disconnect()
        server.stop()
    }

    func testPausedProjectsAndSetPausedRoundTrip() throws {
        let socketPath = "/tmp/omniagent-\(UUID().uuidString.prefix(8)).sock"
        let server = try UnixTestServer(path: socketPath)
        let pausedResponded = expectation(description: "setPaused responded")
        let listResponded = expectation(description: "pausedProjects responded")

        server.run { client in
            try Self.ackHello(on: client)
            let setRequest = try readFrame(from: client)
            XCTAssertEqual(setRequest.kind, .rootsSetPaused)
            let setPayload = try XCTUnwrap(
                JSONSerialization.jsonObject(with: setRequest.payload) as? [String: Any]
            )
            XCTAssertEqual(setPayload["project"] as? String, "demo")
            XCTAssertEqual(setPayload["paused"] as? Bool, true)
            try writeFrame(
                SessionFrame(
                    kind: .response,
                    requestOrSequence: setRequest.requestOrSequence,
                    payload: try JSONSerialization.data(withJSONObject: ["ok": true])
                ),
                to: client
            )

            let listRequest = try readFrame(from: client)
            XCTAssertEqual(listRequest.kind, .rootsPausedProjects)
            try writeFrame(
                SessionFrame(
                    kind: .response,
                    requestOrSequence: listRequest.requestOrSequence,
                    payload: try JSONSerialization.data(withJSONObject: ["projects": ["demo"]])
                ),
                to: client
            )
        }

        let connection = SessionConnection(
            socketURL: URL(fileURLWithPath: socketPath),
            reconnectDelay: 0.02
        )
        var sent = false
        connection.onStateChange = { state in
            guard state == .connected, !sent else { return }
            sent = true
            connection.setPaused(project: "demo", paused: true) { result in
                if case .failure(let error) = result { XCTFail("unexpected failure: \(error)") }
                pausedResponded.fulfill()
                connection.pausedProjects { result in
                    XCTAssertEqual(try? result.get(), ["demo"])
                    listResponded.fulfill()
                }
            }
        }
        connection.connect()

        wait(for: [pausedResponded, listResponded], timeout: 3)
        connection.disconnect()
        server.stop()
    }

    func testStalenessDecodesEveryProjectsReading() throws {
        let socketPath = "/tmp/omniagent-\(UUID().uuidString.prefix(8)).sock"
        let server = try UnixTestServer(path: socketPath)
        let responded = expectation(description: "staleness responded")

        server.run { client in
            try Self.ackHello(on: client)
            let request = try readFrame(from: client)
            XCTAssertEqual(request.kind, .rootsStaleness)
            try writeFrame(
                SessionFrame(
                    kind: .response,
                    requestOrSequence: request.requestOrSequence,
                    payload: try JSONSerialization.data(withJSONObject: [
                        "projects": [
                            ["project": "demo", "last_ingested": 1_700_000_000, "stale": false],
                            ["project": "old", "last_ingested": NSNull(), "stale": false],
                        ],
                    ])
                ),
                to: client
            )
        }

        let connection = SessionConnection(
            socketURL: URL(fileURLWithPath: socketPath),
            reconnectDelay: 0.02
        )
        var sent = false
        connection.onStateChange = { state in
            guard state == .connected, !sent else { return }
            sent = true
            connection.staleness { result in
                XCTAssertEqual(
                    try? result.get(),
                    [
                        ProjectStaleness(project: "demo", lastIngested: 1_700_000_000, stale: false),
                        ProjectStaleness(project: "old", lastIngested: nil, stale: false),
                    ]
                )
                responded.fulfill()
            }
        }
        connection.connect()

        wait(for: [responded], timeout: 3)
        connection.disconnect()
        server.stop()
    }

    func testReingestProjectSendsTheProjectAndCompletesOnAck() throws {
        let socketPath = "/tmp/omniagent-\(UUID().uuidString.prefix(8)).sock"
        let server = try UnixTestServer(path: socketPath)
        let responded = expectation(description: "reingestProject responded")

        server.run { client in
            try Self.ackHello(on: client)
            let request = try readFrame(from: client)
            XCTAssertEqual(request.kind, .rootsReingestProject)
            let payload = try XCTUnwrap(
                JSONSerialization.jsonObject(with: request.payload) as? [String: Any]
            )
            XCTAssertEqual(payload["project"] as? String, "demo")
            try writeFrame(
                SessionFrame(
                    kind: .response,
                    requestOrSequence: request.requestOrSequence,
                    payload: try JSONSerialization.data(withJSONObject: ["ok": true])
                ),
                to: client
            )
        }

        let connection = SessionConnection(
            socketURL: URL(fileURLWithPath: socketPath),
            reconnectDelay: 0.02
        )
        var sent = false
        connection.onStateChange = { state in
            guard state == .connected, !sent else { return }
            sent = true
            connection.reingestProject(project: "demo") { result in
                if case .failure(let error) = result { XCTFail("unexpected failure: \(error)") }
                responded.fulfill()
            }
        }
        connection.connect()

        wait(for: [responded], timeout: 3)
        connection.disconnect()
        server.stop()
    }

    func testRebuildBrainSendsAnEmptyPayloadAndCompletesOnAck() throws {
        let socketPath = "/tmp/omniagent-\(UUID().uuidString.prefix(8)).sock"
        let server = try UnixTestServer(path: socketPath)
        let responded = expectation(description: "rebuildBrain responded")

        server.run { client in
            try Self.ackHello(on: client)
            let request = try readFrame(from: client)
            XCTAssertEqual(request.kind, .rootsRebuild)
            try writeFrame(
                SessionFrame(
                    kind: .response,
                    requestOrSequence: request.requestOrSequence,
                    payload: try JSONSerialization.data(withJSONObject: ["ok": true])
                ),
                to: client
            )
        }

        let connection = SessionConnection(
            socketURL: URL(fileURLWithPath: socketPath),
            reconnectDelay: 0.02
        )
        var sent = false
        connection.onStateChange = { state in
            guard state == .connected, !sent else { return }
            sent = true
            connection.rebuildBrain { result in
                if case .failure(let error) = result { XCTFail("unexpected failure: \(error)") }
                responded.fulfill()
            }
        }
        connection.connect()

        wait(for: [responded], timeout: 3)
        connection.disconnect()
        server.stop()
    }

    func testSearchSendsTheQueryAndScopeAndDecodesResults() throws {
        let socketPath = "/tmp/omniagent-\(UUID().uuidString.prefix(8)).sock"
        let server = try UnixTestServer(path: socketPath)
        let responded = expectation(description: "search responded")

        server.run { client in
            try Self.ackHello(on: client)
            let request = try readFrame(from: client)
            XCTAssertEqual(request.kind, .brainSearch)
            let payload = try XCTUnwrap(
                JSONSerialization.jsonObject(with: request.payload) as? [String: Any]
            )
            XCTAssertEqual(payload["query"] as? String, "parse_config")
            XCTAssertEqual(payload["scope"] as? String, "demo")
            try writeFrame(
                SessionFrame(
                    kind: .response,
                    requestOrSequence: request.requestOrSequence,
                    payload: try JSONSerialization.data(withJSONObject: [
                        "results": [
                            ["id": "demo:parse_config", "kind": "memory", "project": "demo", "label": "parse_config"],
                        ],
                    ])
                ),
                to: client
            )
        }

        let connection = SessionConnection(
            socketURL: URL(fileURLWithPath: socketPath),
            reconnectDelay: 0.02
        )
        var sent = false
        connection.onStateChange = { state in
            guard state == .connected, !sent else { return }
            sent = true
            connection.search(query: "parse_config", scope: "demo") { result in
                let results = try? result.get()
                XCTAssertEqual(results?.count, 1)
                XCTAssertEqual(results?.first?.id, "demo:parse_config")
                responded.fulfill()
            }
        }
        connection.connect()

        wait(for: [responded], timeout: 3)
        connection.disconnect()
        server.stop()
    }

    /// The daemon can answer `Hello` with an `Error` instead of an ack — the
    /// two ends are on different protocol versions, the machine is in use by
    /// another Mac, or this viewer is blocked
    /// (`docs/superpowers/specs/2026-09-01-remote-environment-sharing-design.md`
    /// §3). They do not want the same response, and the difference is the
    /// point of `isTerminalRefusal`: only skew needs a human before anything
    /// can change. This is the classifier on its own; the two cases below run
    /// it through a real socket.
    func testOnlyTheVersionRefusalIsTerminal() {
        XCTAssertTrue(
            SessionConnection.isTerminalRefusal("update OmniAgent on Mac mini")
        )
        for transient in [
            "in use by MacBook Pro",
            "viewer v-air is disconnected until Remote Control is turned off and on again",
            "viewer v-air was disconnected while connecting",
            "The daemon refused the connection.",
        ] {
            XCTAssertFalse(
                SessionConnection.isTerminalRefusal(transient),
                "\(transient) clears itself and must not park the connection"
            )
        }
    }

    /// "in use by ‹machine›" is transient — the other Mac disconnects, or the
    /// relay reaps the dead socket a re-dial after a blip raced. Parking there
    /// would turn a refusal that resolves in a second into one that needs the
    /// user to start over, so it keeps dialling on the existing backoff.
    func testAnInUseRefusalKeepsDialling() throws {
        let socketPath = "/tmp/omniagent-\(UUID().uuidString.prefix(8)).sock"
        let server = try UnixTestServer(path: socketPath)
        let redialled = expectation(description: "a second dial reached the daemon")

        server.run { firstClient in
            try Self.refuse(on: firstClient, with: "in use by MacBook Pro")
            // The second dial is the assertion: it has to arrive at all.
            let secondClient = try server.accept()
            try Self.refuse(on: secondClient, with: "in use by MacBook Pro")
            redialled.fulfill()
        }

        let connection = SessionConnection(
            socketURL: URL(fileURLWithPath: socketPath),
            reconnectDelay: 0.02
        )
        var reported: String?
        connection.onError = { error in
            guard reported == nil else { return }
            reported = error.localizedDescription
        }
        connection.connect()

        wait(for: [redialled], timeout: 3)
        XCTAssertEqual(reported, "in use by MacBook Pro")
        connection.disconnect()
        server.stop()
    }

    /// Its opposite: "update OmniAgent on ‹machine›" cannot come true until
    /// somebody updates the other Mac, so it arrives once, as a sentence, and
    /// ends the dial. Phase 1 redialled instead — four times a second, with a
    /// dead keyboard and the explanation nowhere.
    func testAnErrorAnsweringHelloEndsTheDialInsteadOfLooping() throws {
        let socketPath = "/tmp/omniagent-\(UUID().uuidString.prefix(8)).sock"
        let server = try UnixTestServer(path: socketPath)
        let refused = expectation(description: "the refusal reaches the caller")
        let redialled = expectation(description: "a second dial")
        redialled.isInverted = true

        server.run { client in
            try Self.refuse(on: client, with: "update OmniAgent on Mac mini")
        }

        let connection = SessionConnection(
            socketURL: URL(fileURLWithPath: socketPath),
            reconnectDelay: 0.02
        )
        var reported: String?
        connection.onError = { error in
            guard reported == nil else { return }
            reported = error.localizedDescription
            refused.fulfill()
        }
        var dials = 0
        connection.onStateChange = { state in
            guard state == .connecting else { return }
            dials += 1
            if dials > 1 { redialled.fulfill() }
        }
        connection.connect()

        // The inverted expectation is what the timeout is spent on: at a 0.02s
        // seed delay, a looping client would have dialled dozens of times.
        wait(for: [refused, redialled], timeout: 2)
        XCTAssertEqual(reported, "update OmniAgent on Mac mini")
        connection.disconnect()
        server.stop()
    }

    /// Reads this client's `Hello`, answers it with `Error(message)` — the
    /// daemon's shape for every handshake refusal — and hangs up.
    private static func refuse(on client: Int32, with message: String) throws {
        let hello = try readFrame(from: client)
        try writeFrame(
            SessionFrame(
                kind: .error,
                requestOrSequence: hello.requestOrSequence,
                payload: try JSONSerialization.data(withJSONObject: ["message": message])
            ),
            to: client
        )
        Darwin.close(client)
    }

    private static func ackHello(on client: Int32) throws {
        let hello = try readFrame(from: client)
        try writeFrame(
            SessionFrame(
                kind: .helloAck,
                requestOrSequence: hello.requestOrSequence,
                payload: try JSONSerialization.data(withJSONObject: ["protocol_version": 1])
            ),
            to: client
        )
    }
}

private final class UnixTestServer {
    private let path: String
    private let listener: Int32
    private let queue = DispatchQueue(label: "digital.bruno.omniagent.test-daemon")

    init(path: String) throws {
        self.path = path
        unlink(path)
        listener = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw POSIXError(.EIO) }
        // Reuses `SessionConnection.swift`'s own `withUnixSocketAddress` (made
        // non-private for exactly this — see its doc comment) rather than a
        // second, easy-to-drift copy of this unsafe-pointer code.
        let result = try withUnixSocketAddress(path: path) {
            Darwin.bind(listener, $0, $1)
        }
        guard result == 0, Darwin.listen(listener, 2) == 0 else {
            Darwin.close(listener)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    func run(_ body: @escaping (Int32) throws -> Void) {
        queue.async {
            do {
                try body(try self.accept())
            } catch {
                XCTFail("test daemon failed: \(error)")
            }
        }
    }

    func accept() throws -> Int32 {
        let client = Darwin.accept(listener, nil, nil)
        guard client >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return client
    }

    func stop() {
        Darwin.close(listener)
        unlink(path)
    }
}

private func readFrame(from descriptor: Int32) throws -> SessionFrame {
    let header = try readExactly(16, from: descriptor)
    let length = Int(header.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
    var decoder = FrameDecoder()
    return try XCTUnwrap(try decoder.append(header + readExactly(length, from: descriptor)).first)
}

private func readExactly(_ count: Int, from descriptor: Int32) throws -> Data {
    var data = Data()
    while data.count < count {
        var bytes = [UInt8](repeating: 0, count: count - data.count)
        let readCount = Darwin.read(descriptor, &bytes, bytes.count)
        guard readCount > 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ECONNRESET)
        }
        data.append(contentsOf: bytes.prefix(readCount))
    }
    return data
}

private func writeFrame(
    _ frame: SessionFrame,
    to descriptor: Int32,
    splitAt: Int? = nil
) throws {
    let data = try frame.encoded()
    if let splitAt {
        try writeAll(data.prefix(splitAt), to: descriptor)
        usleep(5_000)
        try writeAll(data.suffix(from: splitAt), to: descriptor)
    } else {
        try writeAll(data[...], to: descriptor)
    }
}

private func writeAll(_ data: Data.SubSequence, to descriptor: Int32) throws {
    var written = 0
    try data.withUnsafeBytes { bytes in
        while written < data.count {
            let count = Darwin.write(
                descriptor,
                bytes.baseAddress!.advanced(by: written),
                data.count - written
            )
            guard count > 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            written += count
        }
    }
}
