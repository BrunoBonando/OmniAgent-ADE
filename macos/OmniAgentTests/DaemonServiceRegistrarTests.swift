import Darwin
import XCTest
@testable import OmniAgent

/// `DaemonSocketProbe` — the reviewed fix: file presence is not "a daemon
/// is already running". A Unix domain socket file survives its owning
/// process dying uncleanly (`SIGKILL`, a panic before its own cleanup
/// runs), so the probe must actually attempt a `connect()`, mirroring
/// `src-tauri/src/daemon.rs`'s `remove_stale_socket_if_unreachable()`.
final class DaemonSocketProbeTests: XCTestCase {
    private func scratchPath() -> String {
        "/tmp/omniagent-probe-\(UUID().uuidString.prefix(8)).sock"
    }

    func testNoFileAtAllIsNotReachable() {
        let path = scratchPath()
        XCTAssertFalse(DaemonSocketProbe.isReachable(at: URL(fileURLWithPath: path)))
    }

    func testALiveListeningSocketIsReachable() throws {
        let path = scratchPath()
        let listener = try bindAndListenTestSocket(at: path)
        defer {
            Darwin.close(listener)
            unlink(path)
        }

        XCTAssertTrue(DaemonSocketProbe.isReachable(at: URL(fileURLWithPath: path)))
    }

    /// The exact scenario the review named: the daemon process died without
    /// unlinking its socket (no `accept()` loop left to clean up after
    /// itself), so the file is still there, but nothing answers a connect.
    func testAStaleSocketFileWithNothingListeningIsNotReachable() throws {
        let path = scratchPath()
        let listener = try bindAndListenTestSocket(at: path)
        Darwin.close(listener) // simulate the owning process dying uncleanly
        defer { unlink(path) }

        XCTAssertTrue(FileManager.default.fileExists(atPath: path), "the file itself must survive")
        XCTAssertFalse(DaemonSocketProbe.isReachable(at: URL(fileURLWithPath: path)))
    }

    func testAPlainNonSocketFileIsNotReachable() {
        let path = scratchPath()
        FileManager.default.createFile(atPath: path, contents: Data("not a socket".utf8))
        defer { unlink(path) }

        XCTAssertFalse(DaemonSocketProbe.isReachable(at: URL(fileURLWithPath: path)))
    }
}

/// Not `private`: `DaemonPersistenceControllerTests` reuses this to set up
/// the same "stale socket file" scenario for its own end-to-end spawn test.
func bindAndListenTestSocket(at path: String) throws -> Int32 {
    unlink(path)
    let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    let result = try withUnixSocketAddress(path: path) {
        Darwin.bind(descriptor, $0, $1)
    }
    guard result == 0, Darwin.listen(descriptor, 2) == 0 else {
        let code = errno
        Darwin.close(descriptor)
        throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }
    return descriptor
}
