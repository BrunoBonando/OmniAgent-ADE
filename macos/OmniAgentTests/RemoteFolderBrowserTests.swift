import AppKit
import Darwin
import XCTest

@testable import OmniAgent

/// "Add local folder…" while this Mac is driving another (2026-09-01 remote
/// environment sharing spec §4/§6, Task 28): `RemoteFolderBrowser` is the
/// whole daemon-facing contract, proven here against a real (fake)
/// `ListDirectory` server; `RemoteFolderBrowserView` is a driven state
/// machine and is proven synchronously, the same split `RemoteSessionPicker
/// Tests` uses for its own sheet.
final class RemoteFolderBrowserTests: XCTestCase {
    // MARK: - RemoteFolderBrowser (Task 28's own required test)

    /// The literal contract Task 28's brief pins: a directory listing comes
    /// back as `[DirectoryEntry]`, and only a directory can be chosen —
    /// proven against a real socket server standing in for the daemon, since
    /// this connection could just as well be the `.webSocket` one this Mac
    /// uses while driving another machine.
    func testAddFolderBrowsesTheHostNotThisMacWhileDriving() async throws {
        let socketPath = "/tmp/omniagent-\(UUID().uuidString.prefix(8)).sock"
        let server = try FolderBrowserTestServer(path: socketPath)
        server.run { client in
            try Self.answerHello(on: client)
            let request = try readFrame(from: client)
            XCTAssertEqual(request.kind, .listDirectory)
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: request.payload) as? [String: Any])
            XCTAssertEqual(payload["path"] as? String, "/Users/bonando")
            try writeFrame(
                SessionFrame(
                    kind: .response,
                    requestOrSequence: request.requestOrSequence,
                    payload: Data(
                        #"{"entries":[{"name":"Documents","is_dir":true},{"name":"notes.md","is_dir":false}],"truncated":false}"#
                            .utf8
                    )
                ),
                to: client
            )
            Darwin.close(client)
        }

        let connection = try await Self.connected(to: socketPath)
        let browser = RemoteFolderBrowser(connection: connection)
        let entries = try await browser.list("/Users/bonando")

        XCTAssertEqual(entries.map(\.name), ["Documents", "notes.md"])
        XCTAssertTrue(browser.canChoose(entries[0])) // a directory
        XCTAssertFalse(browser.canChoose(entries[1])) // a file
        XCTAssertFalse(browser.truncated)

        connection.disconnect()
        server.stop()
    }

    /// The daemon's own cap (`LIST_DIRECTORY_MAX_ENTRIES`, 512) is a fact the
    /// sheet has to render, not swallow — `truncated` carries it straight
    /// through rather than being dropped on the way to `[DirectoryEntry]`.
    func testATruncatedListingIsReportedNotSwallowed() async throws {
        let socketPath = "/tmp/omniagent-\(UUID().uuidString.prefix(8)).sock"
        let server = try FolderBrowserTestServer(path: socketPath)
        server.run { client in
            try Self.answerHello(on: client)
            let request = try readFrame(from: client)
            try writeFrame(
                SessionFrame(
                    kind: .response,
                    requestOrSequence: request.requestOrSequence,
                    payload: Data(#"{"entries":[{"name":"a","is_dir":false}],"truncated":true}"#.utf8)
                ),
                to: client
            )
            Darwin.close(client)
        }

        let connection = try await Self.connected(to: socketPath)
        let browser = RemoteFolderBrowser(connection: connection)
        XCTAssertFalse(browser.truncated, "nothing has been listed yet")
        _ = try await browser.list("/usr/bin")
        XCTAssertTrue(browser.truncated)

        connection.disconnect()
        server.stop()
    }

    /// An unreadable path (Task 9's own daemon-side contract: "an error, not
    /// a panic") reaches this side as a thrown `Error`, not a crash and not
    /// an empty listing pretending to be a real one.
    func testAnUnreadablePathThrowsRatherThanReturningAnEmptyListing() async throws {
        let socketPath = "/tmp/omniagent-\(UUID().uuidString.prefix(8)).sock"
        let server = try FolderBrowserTestServer(path: socketPath)
        server.run { client in
            try Self.answerHello(on: client)
            let request = try readFrame(from: client)
            try writeFrame(
                SessionFrame(
                    kind: .error,
                    requestOrSequence: request.requestOrSequence,
                    payload: Data(#"{"message":"Permission denied"}"#.utf8)
                ),
                to: client
            )
            Darwin.close(client)
        }

        let connection = try await Self.connected(to: socketPath)
        let browser = RemoteFolderBrowser(connection: connection)
        do {
            _ = try await browser.list("/root")
            XCTFail("expected the daemon's Error frame to surface as a thrown error")
        } catch {
            // Any error is the contract; the message itself is
            // `SessionConnection`'s own concern, already covered there.
        }

        connection.disconnect()
        server.stop()
    }

    // MARK: - WorkspaceWindowController.usesNativeOpenPanel (Task 28's own required test)

    /// The one fact every folder-pick call site asks the same way, rather
    /// than each guessing at `isDrivingRemote` inline.
    func testTheLocalPanelIsUsedWhenNotDriving() {
        XCTAssertTrue(WorkspaceWindowController.usesNativeOpenPanel(isDrivingRemote: false))
        XCTAssertFalse(WorkspaceWindowController.usesNativeOpenPanel(isDrivingRemote: true))
    }

    // MARK: - RemoteFolderBrowserView (driven state, no daemon needed)

    func testLoadingShowsOnePlaceholderRow() {
        let view = RemoteFolderBrowserView(machineName: "Studio", startingAt: "/Users/bonando")
        XCTAssertEqual(view.numberOfRowsForTesting, 1)
    }

    func testAppliedEntriesBecomeRowsAndOnlyDirectoriesAreSelectable() {
        let view = RemoteFolderBrowserView(machineName: nil, startingAt: "/Users/bonando")
        view.apply(
            path: "/Users/bonando",
            entries: [
                DirectoryEntry(name: "Documents", isDir: true),
                DirectoryEntry(name: "notes.md", isDir: false),
            ],
            truncated: false
        )
        XCTAssertEqual(view.numberOfRowsForTesting, 2)
        let table = NSTableView()
        XCTAssertTrue(view.tableView(table, shouldSelectRow: 0), "a directory row is selectable")
        XCTAssertFalse(view.tableView(table, shouldSelectRow: 1), "a file row is not")
    }

    func testAnEmptyFolderShowsAPlaceholderRowRatherThanNoRowsAtAll() {
        let view = RemoteFolderBrowserView(machineName: nil, startingAt: "/tmp")
        view.apply(path: "/tmp", entries: [], truncated: false)
        XCTAssertEqual(view.numberOfRowsForTesting, 1)
        let table = NSTableView()
        XCTAssertFalse(view.tableView(table, shouldSelectRow: 0), "a placeholder is not a choice")
    }

    func testATruncatedListingShowsItsOwnLabelAndAnUntruncatedOneHidesIt() {
        let view = RemoteFolderBrowserView(machineName: nil, startingAt: "/usr")
        view.apply(path: "/usr", entries: [DirectoryEntry(name: "bin", isDir: true)], truncated: true)
        XCTAssertFalse(view.isTruncatedLabelHiddenForTesting)
        view.apply(path: "/usr", entries: [DirectoryEntry(name: "bin", isDir: true)], truncated: false)
        XCTAssertTrue(view.isTruncatedLabelHiddenForTesting)
    }

    /// A double-click descends into the folder that was clicked — the same
    /// row `ListDirectory` will be asked about next, joined onto the
    /// directory currently being browsed rather than re-derived some other
    /// way.
    func testDoubleClickingADirectoryRowNavigatesIntoIt() {
        let view = RemoteFolderBrowserView(machineName: nil, startingAt: "/Users/bonando")
        view.apply(
            path: "/Users/bonando",
            entries: [DirectoryEntry(name: "Documents", isDir: true)],
            truncated: false
        )
        var navigated: [String] = []
        view.onNavigate = { navigated.append($0) }
        view.doubleClickForTesting(at: 0)
        XCTAssertEqual(navigated, ["/Users/bonando/Documents"])
    }

    /// The up chevron always goes to the *parent* of the directory currently
    /// on screen, never something derived from a selection.
    func testUpButtonNavigatesToTheParentOfTheCurrentDirectory() {
        let view = RemoteFolderBrowserView(machineName: nil, startingAt: "/Users/bonando/Documents")
        var navigated: [String] = []
        view.onNavigate = { navigated.append($0) }
        view.upTappedForTesting()
        XCTAssertEqual(navigated, ["/Users/bonando"])
    }

    /// `deletingLastPathComponent` answers `""` for a top-level entry, which
    /// is root itself, not nothing.
    func testParentPathOfATopLevelDirectoryIsRoot() {
        XCTAssertEqual(RemoteFolderBrowserView.parentPath(of: "/Users"), "/")
        XCTAssertEqual(RemoteFolderBrowserView.parentPath(of: "/Users/bonando"), "/Users")
    }

    /// Root has no parent to go up to.
    func testTheUpButtonIsDisabledAtRootAndEnabledEverywhereElse() {
        XCTAssertFalse(RemoteFolderBrowserView(machineName: nil, startingAt: "/").isUpButtonEnabledForTesting)
        XCTAssertTrue(
            RemoteFolderBrowserView(machineName: nil, startingAt: "/Users/bonando").isUpButtonEnabledForTesting
        )
    }

    /// With a directory selected, Add commits *that* subfolder without
    /// entering it — `NSOpenPanel`'s own "Choose" behaviour for a selected
    /// row, ported to a sheet that browses one directory at a time.
    func testAddWithASelectedSubfolderCommitsTheSubfolderNotTheCurrentDirectory() {
        let view = RemoteFolderBrowserView(machineName: nil, startingAt: "/Users/bonando")
        view.apply(
            path: "/Users/bonando",
            entries: [
                DirectoryEntry(name: "Documents", isDir: true),
                DirectoryEntry(name: "notes.md", isDir: false),
            ],
            truncated: false
        )
        var added: [String] = []
        view.onAdd = { added.append($0) }
        view.selectEntryForTesting(at: 0)
        view.activateAdd()
        XCTAssertEqual(added, ["/Users/bonando/Documents"])
    }

    /// Selecting a file is refused by `shouldSelectRow`, so
    /// `selectEntryForTesting` on a file index is a no-op — Add then falls
    /// back to the directory being browsed, proving a file can never become
    /// the target.
    func testAFileRowCanNeverBecomeTheAddTarget() {
        let view = RemoteFolderBrowserView(machineName: nil, startingAt: "/Users/bonando")
        view.apply(
            path: "/Users/bonando",
            entries: [DirectoryEntry(name: "notes.md", isDir: false)],
            truncated: false
        )
        var added: [String] = []
        view.onAdd = { added.append($0) }
        view.selectEntryForTesting(at: 0)
        view.activateAdd()
        XCTAssertEqual(added, ["/Users/bonando"], "a file can't be selected, so Add falls back to the folder itself")
    }

    /// With nothing selected, Add commits the directory currently on screen
    /// — the folder someone opened the sheet to add, with no need to
    /// re-select it from inside its own listing.
    func testAddWithNothingSelectedCommitsTheCurrentDirectory() {
        let view = RemoteFolderBrowserView(machineName: nil, startingAt: "/Users/bonando")
        view.apply(path: "/Users/bonando", entries: [DirectoryEntry(name: "Documents", isDir: true)], truncated: false)
        var added: [String] = []
        view.onAdd = { added.append($0) }
        view.activateAdd()
        XCTAssertEqual(added, ["/Users/bonando"])
    }

    /// Nothing has answered yet: Add has nothing to commit, and does not
    /// silently answer with a stale or empty path.
    func testAddWhileStillLoadingDoesNothing() {
        let view = RemoteFolderBrowserView(machineName: nil, startingAt: "/Users/bonando")
        var added: [String] = []
        view.onAdd = { added.append($0) }
        view.activateAdd()
        XCTAssertTrue(added.isEmpty)
    }

    /// One answer per sheet, whichever route it arrives by — the same rule
    /// `RemoteSessionPickerView` follows.
    func testCancelFiresOnlyOnce() {
        let view = RemoteFolderBrowserView(machineName: nil, startingAt: "/Users/bonando")
        var cancellations = 0
        view.onCancel = { cancellations += 1 }
        view.cancel()
        view.cancel()
        XCTAssertEqual(cancellations, 1)
    }

    /// A modal that goes up as a zero-sized or off-window card is the
    /// failure no row assertion would catch — the same reasoning
    /// `RemoteSessionPickerViewTests`' layout test gives.
    func testTheCardLaysItselfOutOverTheWindow() {
        let window = testWindow()
        let view = RemoteFolderBrowserView(machineName: nil, startingAt: "/Users/bonando")
        view.frame = window.contentView!.bounds
        view.autoresizingMask = [.width, .height]
        window.contentView!.addSubview(view)
        view.apply(path: "/Users/bonando", entries: [DirectoryEntry(name: "Documents", isDir: true)], truncated: false)
        view.layoutSubtreeIfNeeded()

        XCTAssertEqual(view.frame, window.contentView?.bounds, "the glass covers the window")
        XCTAssertGreaterThan(view.cardFrameForTesting.width, 0)
        XCTAssertGreaterThan(view.cardFrameForTesting.height, 0)
    }

    // MARK: - RemoteFolderBrowserController

    /// One at a time, and no window means no sheet — `RemoteSessionPicker
    /// Controller`'s own two facts, proven the same way for this sheet.
    func testPresentIsOneAtATimeAndRefusesWithoutAWindow() {
        let window = testWindow()
        let controller = RemoteFolderBrowserController()
        let connection = SessionConnection(socketURL: URL(fileURLWithPath: "/tmp/omniagent-folder-browser-unused.sock"))
        XCTAssertTrue(
            controller.present(
                over: window,
                browser: RemoteFolderBrowser(connection: connection),
                machineName: nil,
                startingAt: "/Users/bonando",
                onAdd: { _ in }
            )
        )
        XCTAssertFalse(
            controller.present(
                over: window,
                browser: RemoteFolderBrowser(connection: connection),
                machineName: nil,
                startingAt: "/Users/bonando",
                onAdd: { _ in }
            ),
            "a second click on the menu item must not stack two sheets of glass"
        )
        controller.dismiss()
        XCTAssertNil(controller.view)

        XCTAssertFalse(
            controller.present(
                over: nil,
                browser: RemoteFolderBrowser(connection: connection),
                machineName: nil,
                startingAt: "/Users/bonando",
                onAdd: { _ in }
            )
        )
    }

    // MARK: - Helpers

    private static func answerHello(on client: Int32) throws {
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

    private static func connected(to socketPath: String) async throws -> SessionConnection {
        let connection = SessionConnection(socketURL: URL(fileURLWithPath: socketPath))
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var resumed = false
            connection.onStateChange = { state in
                guard state == .connected, !resumed else { return }
                resumed = true
                continuation.resume()
            }
            connection.connect()
        }
        return connection
    }

    /// A window to mount the sheet in. Never ordered front — these are
    /// structural assertions, and a test that steals the screen is a test
    /// nobody runs twice.
    private func testWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 620))
        return window
    }
}

/// A minimal stand-in daemon: accepts one connection and hands the accepted
/// descriptor to `body`, which the caller (never on the main thread) does
/// its own frame reading/writing over. Mirrors `SessionConnectionTests
/// .swift`'s `UnixTestServer` — a small private duplicate per file is this
/// codebase's own convention for this harness, rather than a shared type
/// several test files would need to agree on the shape of.
private final class FolderBrowserTestServer {
    private let path: String
    private let listener: Int32
    private let queue = DispatchQueue(label: "digital.bruno.omniagent.folder-browser-test-daemon")

    init(path: String) throws {
        self.path = path
        unlink(path)
        listener = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw POSIXError(.EIO) }
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
                let client = Darwin.accept(self.listener, nil, nil)
                guard client >= 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                try body(client)
            } catch {
                XCTFail("test daemon failed: \(error)")
            }
        }
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

private func writeFrame(_ frame: SessionFrame, to descriptor: Int32) throws {
    try writeAll(try frame.encoded()[...], to: descriptor)
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
