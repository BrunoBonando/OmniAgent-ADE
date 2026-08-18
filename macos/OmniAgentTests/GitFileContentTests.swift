import XCTest
@testable import OmniAgent

/// Task 12: the two sides of a diff tab, straight out of git.
///
/// Every test builds its **own** throwaway repository in a temp directory —
/// never this repo's working tree, which several agents mutate concurrently
/// and whose HEAD moves mid-run.
final class GitFileContentTests: XCTestCase {
    private var repo: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        try skipUnlessGitIsAvailable()
        repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("git-file-content-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try git("init", "-q")
        try git("config", "user.email", "t@t")
        try git("config", "user.name", "t")
        try write("one\n", to: "a.txt")
        try git("add", ".")
        try git("commit", "-qm", "initial")
        try write("one\ntwo\n", to: "a.txt")
    }

    override func tearDownWithError() throws {
        if let repo { try? FileManager.default.removeItem(at: repo) }
        repo = nil
        try super.tearDownWithError()
    }

    // MARK: - Paths

    func testRelativePath() {
        XCTAssertEqual(
            GitFileContent.relativePath(of: repo.appendingPathComponent("a.txt"), underRoot: repo),
            "a.txt"
        )
        XCTAssertEqual(
            GitFileContent.relativePath(of: repo.appendingPathComponent("src/deep/a.txt"), underRoot: repo),
            "src/deep/a.txt",
            "git wants the whole repo-relative path, slash separated"
        )
        XCTAssertNil(GitFileContent.relativePath(of: URL(fileURLWithPath: "/etc/hosts"), underRoot: repo))
    }

    // MARK: - The HEAD side

    func testHeadVersion() {
        let done = expectation(description: "head")
        var onMainThread = false
        GitFileContent.headVersion(of: repo.appendingPathComponent("a.txt")) { result in
            onMainThread = Thread.isMainThread
            XCTAssertEqual(try? result.get(), "one\n", "HEAD's version, not the working tree's")
            done.fulfill()
        }
        wait(for: [done], timeout: 20)
        XCTAssertTrue(onMainThread, "the completion lands where the pane can use it")
    }

    /// A file that is not in HEAD legitimately diffs against nothing — that is
    /// a *new file*, not an error, and git says so by exiting non-zero.
    func testUntrackedDiffsAgainstEmpty() throws {
        try write("new\n", to: "b.txt")
        let done = expectation(description: "untracked")
        GitFileContent.headVersion(of: repo.appendingPathComponent("b.txt")) { result in
            XCTAssertEqual(try? result.get(), "")
            done.fulfill()
        }
        wait(for: [done], timeout: 20)
    }

    /// The mirror image: the file is gone from the working tree but still in
    /// HEAD, so the diff has a left-hand side and an empty right-hand one.
    func testDeletedFileKeepsItsHeadVersion() throws {
        try FileManager.default.removeItem(at: repo.appendingPathComponent("a.txt"))
        let done = expectation(description: "deleted")
        GitFileContent.headVersion(of: repo.appendingPathComponent("a.txt")) { result in
            XCTAssertEqual(try? result.get(), "one\n")
            done.fulfill()
        }
        wait(for: [done], timeout: 20)
    }

    func testOutsideARepoFails() {
        let done = expectation(description: "fail")
        let stray = URL(fileURLWithPath: "/private/tmp/definitely-not-a-repo-\(UUID().uuidString).txt")
        GitFileContent.headVersion(of: stray) { result in
            XCTAssertEqual(result, .failure(.notInRepository))
            done.fulfill()
        }
        wait(for: [done], timeout: 20)
    }

    // MARK: - The unified diff (the Changes tab's lazy expansion)

    func testUnifiedDiff() {
        let done = expectation(description: "diff")
        GitFileContent.unifiedDiff(of: repo.appendingPathComponent("a.txt")) { text in
            XCTAssertTrue(text?.contains("+two") ?? false, "got: \(text ?? "nil")")
            done.fulfill()
        }
        wait(for: [done], timeout: 20)
    }

    /// `git diff HEAD -- <untracked>` exits **0 with no output**, so the file
    /// would look unchanged. It has to fall back to a diff against
    /// `/dev/null`, which is git's own spelling of "all new".
    func testUnifiedDiffShowsAnUntrackedFileAsAllNew() throws {
        try write("new\n", to: "b.txt")
        let done = expectation(description: "untracked diff")
        GitFileContent.unifiedDiff(of: repo.appendingPathComponent("b.txt")) { text in
            XCTAssertTrue(text?.contains("+new") ?? false, "got: \(text ?? "nil")")
            done.fulfill()
        }
        wait(for: [done], timeout: 20)
    }

    func testUnifiedDiffOutsideARepoIsNil() {
        let done = expectation(description: "no repo")
        let stray = URL(fileURLWithPath: "/private/tmp/definitely-not-a-repo-\(UUID().uuidString).txt")
        GitFileContent.unifiedDiff(of: stray) { text in
            XCTAssertNil(text)
            done.fulfill()
        }
        wait(for: [done], timeout: 20)
    }

    // MARK: - Helpers

    private func write(_ contents: String, to relativePath: String) throws {
        let url = repo.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    private func git(_ arguments: String...) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", repo.path] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "git \(arguments.joined(separator: " ")) failed")
    }

    private func skipUnlessGitIsAvailable() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "--version"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { throw XCTSkip("git is not available on PATH") }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw XCTSkip("git is not available on PATH") }
    }
}
