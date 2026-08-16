import XCTest
@testable import OmniAgent

/// The FILES tree's data layer: one directory level from `FileManager`, and
/// `git status --porcelain=v1 -z` turned into per-row badges.
///
/// Almost everything here is exercised through the pure surfaces —
/// `GitStatus.parse(porcelainZ:)` takes a string, `changedCount(under:)`
/// takes a map — so the interesting rules are tested with no filesystem at
/// all. The handful of cases that genuinely need real inodes build them in a
/// temporary directory this class owns and deletes.
final class WorkspaceFilesTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceFilesTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        tempDirectory = nil
        try super.tearDownWithError()
    }

    // MARK: - Porcelain parsing

    func testParsesTheThreeEverydayStates() {
        let badges = GitStatus.parse(porcelainZ: "A  added.txt\0 D gone.txt\0 M mod.txt\0")

        XCTAssertEqual(badges, [
            "added.txt": .added,
            "gone.txt": .deleted,
            "mod.txt": .modified,
        ])
    }

    func testParsesUntrackedFiles() {
        let badges = GitStatus.parse(porcelainZ: "?? new.txt\0")

        XCTAssertEqual(badges, ["new.txt": .untracked])
    }

    /// The subtle one. `-z` prints a rename as **two** records — the new path
    /// carrying the `XY` prefix, then a bare original path — so a parser that
    /// treats every record as a status line reads `old name.txt` as an entry
    /// whose status is `ol` and then desynchronises everything after it.
    func testParsesTheTwoRecordRenameFormAndStaysInSyncAfterIt() {
        let badges = GitStatus.parse(
            porcelainZ: "R  new name.txt\0old name.txt\0 M after.txt\0"
        )

        XCTAssertEqual(badges, [
            "new name.txt": .renamed,
            // The record that follows the rename must still be read as a
            // status line, which only happens if the original path was
            // consumed rather than parsed.
            "after.txt": .modified,
        ])
        XCTAssertNil(badges["old name.txt"], "the original path is not a row of its own")
        XCTAssertNil(badges["ld name.txt"], "the original path was misread as a status record")
    }

    func testARenamedThenModifiedFileStaysRenamed() {
        let badges = GitStatus.parse(porcelainZ: "RM new.txt\0old.txt\0?? last.txt\0")

        XCTAssertEqual(badges, ["new.txt": .renamed, "last.txt": .untracked])
    }

    /// A copy uses the same two-record framing as a rename, so it has to
    /// consume the original path too — even though it badges as `.added`.
    func testACopyAlsoConsumesItsOriginalPathRecord() {
        let badges = GitStatus.parse(porcelainZ: "C  copy.txt\0source.txt\0 M after.txt\0")

        XCTAssertEqual(badges, ["copy.txt": .added, "after.txt": .modified])
    }

    func testParsesEveryUnmergedCombinationAsConflicted() {
        let badges = GitStatus.parse(
            porcelainZ: "DD a\0AU b\0UD c\0UA d\0DU e\0AA f\0UU g\0"
        )

        XCTAssertEqual(badges, [
            "a": .conflicted, "b": .conflicted, "c": .conflicted, "d": .conflicted,
            "e": .conflicted, "f": .conflicted, "g": .conflicted,
        ])
    }

    /// `-z` never quotes or escapes, unlike the newline format, so a path with
    /// spaces (or quotes) arrives verbatim and must not be unescaped or split.
    func testParsesPathsContainingSpacesAndQuotesVerbatim() {
        let badges = GitStatus.parse(
            porcelainZ: " M sub dir/a file.txt\0?? \"quoted\" name.txt\0"
        )

        XCTAssertEqual(badges, [
            "sub dir/a file.txt": .modified,
            "\"quoted\" name.txt": .untracked,
        ])
    }

    /// The whole reason for asking git for `-z`: records are framed by NUL,
    /// so a newline inside a path is just another character.
    func testANewlineInsideAPathIsNotARecordBoundary() {
        let badges = GitStatus.parse(porcelainZ: " M we\nird.txt\0?? after.txt\0")

        XCTAssertEqual(badges, ["we\nird.txt": .modified, "after.txt": .untracked])
    }

    func testEmptyInputYieldsNoBadges() {
        XCTAssertEqual(GitStatus.parse(porcelainZ: ""), [:])
        XCTAssertEqual(GitStatus.parse(porcelainZ: "\0"), [:])
    }

    func testGarbageRecordsAreSkippedRatherThanCrashing() {
        // Too short, and a record with no space separator.
        XCTAssertEqual(GitStatus.parse(porcelainZ: "x\0MM\0MMnospace\0 M ok.txt\0"), ["ok.txt": .modified])
    }

    /// `--untracked-files=normal` collapses a wholly untracked directory into
    /// one `?? dir/` record. The trailing slash has to go, or the directory's
    /// own row can never find its badge.
    func testCollapsedUntrackedDirectoryLosesItsTrailingSlash() {
        let badges = GitStatus.parse(porcelainZ: "?? newdir/\0")

        XCTAssertEqual(badges, ["newdir": .untracked])
    }

    // MARK: - changedCount

    func testChangedCountAggregatesNestedDirectories() {
        let status = GitStatus(root: URL(fileURLWithPath: "/repo"), badges: [
            "src/a.swift": .modified,
            "src/deep/b.swift": .added,
            "src/deep/c.swift": .deleted,
            "srcery/z.swift": .modified,
            "README.md": .untracked,
        ])

        XCTAssertEqual(status.changedCount(under: "src"), 3)
        XCTAssertEqual(status.changedCount(under: "src/deep"), 2)
        XCTAssertEqual(status.changedCount(under: "src/deep/"), 2, "a trailing slash is tolerated")
        XCTAssertEqual(
            status.changedCount(under: "src"), 3,
            "a sibling whose name merely starts with `src` must not be counted"
        )
        XCTAssertEqual(status.changedCount(under: "nope"), 0)
    }

    func testChangedCountForTheRootCountsEveryChange() {
        let status = GitStatus(root: URL(fileURLWithPath: "/repo"), badges: [
            "a": .modified, "b/c": .added, "b/d/e": .deleted,
        ])

        XCTAssertEqual(status.changedCount(under: ""), 3)
        XCTAssertEqual(status.changedCount(under: "/"), 3)
    }

    // MARK: - children(of:)

    func testListsDirectoriesBeforeFilesEachSortedCaseInsensitively() throws {
        try makeDirectory("Zeta")
        try makeDirectory("alpha")
        try makeFile("Beta.txt")
        try makeFile("apple.txt")

        let names = WorkspaceFiles.children(of: tempDirectory).map(\.name)

        // A plain ASCII sort would give ["Zeta", "alpha", "Beta.txt", "apple.txt"].
        XCTAssertEqual(names, ["alpha", "Zeta", "apple.txt", "Beta.txt"])
        XCTAssertEqual(
            WorkspaceFiles.children(of: tempDirectory).map(\.isDirectory),
            [true, true, false, false]
        )
    }

    func testSkipsHiddenEntries() throws {
        try makeFile(".env")
        try makeDirectory(".hidden")
        try makeFile("visible.txt")

        XCTAssertEqual(WorkspaceFiles.children(of: tempDirectory).map(\.name), ["visible.txt"])
    }

    func testSkipsBuildOutputAndDependencyDirectories() throws {
        for name in ["node_modules", "target", "build", "DerivedData", ".git", "src"] {
            try makeDirectory(name)
        }

        XCTAssertEqual(WorkspaceFiles.children(of: tempDirectory).map(\.name), ["src"])
    }

    func testAFileNamedLikeASkippedDirectoryIsStillListed() throws {
        try makeFile("build")

        XCTAssertEqual(WorkspaceFiles.children(of: tempDirectory).map(\.name), ["build"])
    }

    func testAsyncListAnswersOnTheMainThreadWithTheSameLevel() throws {
        try makeDirectory("dir")
        try makeFile("a.txt")

        let answered = expectation(description: "listed")
        var names: [String] = []
        var onMainThread = false
        WorkspaceFiles.list(tempDirectory) { nodes in
            onMainThread = Thread.isMainThread
            names = nodes.map(\.name)
            answered.fulfill()
        }
        wait(for: [answered], timeout: 10)

        XCTAssertTrue(onMainThread)
        XCTAssertEqual(names, ["dir", "a.txt"])
    }

    func testANonExistentDirectoryListsNothingRatherThanThrowing() {
        let missing = tempDirectory.appendingPathComponent("does-not-exist")

        XCTAssertEqual(WorkspaceFiles.children(of: missing), [])
    }

    func testAPlainFileListsNothing() throws {
        let file = try makeFile("a.txt")

        XCTAssertEqual(WorkspaceFiles.children(of: file), [])
    }

    // MARK: - Annotation

    func testAnnotatedChildrenCarryFileBadgesAndDirectoryCounts() throws {
        try makeDirectory("src")
        try makeFile("README.md")
        try makeFile("clean.txt")

        let status = GitStatus(root: tempDirectory, badges: [
            "README.md": .modified,
            "src/a.swift": .added,
            "src/deep/b.swift": .deleted,
        ])

        let nodes = WorkspaceFiles.children(of: tempDirectory, annotatedWith: status)

        XCTAssertEqual(nodes.map(\.name), ["src", "clean.txt", "README.md"])
        XCTAssertEqual(nodes[0].changedCount, 2, "the directory aggregates everything beneath it")
        XCTAssertNil(nodes[0].gitBadge, "a directory with no record of its own carries no badge")
        XCTAssertNil(nodes[1].gitBadge)
        XCTAssertEqual(nodes[2].gitBadge, .modified)
        XCTAssertEqual(nodes[2].changedCount, 0, "files never aggregate")
    }

    func testAnnotationWithoutAStatusLeavesEveryRowUnannotated() throws {
        try makeFile("a.txt")

        let nodes = WorkspaceFiles.children(of: tempDirectory, annotatedWith: nil)

        XCTAssertEqual(nodes.map(\.gitBadge), [nil])
    }

    func testACollapsedUntrackedDirectoryGetsItsOwnBadge() throws {
        try makeDirectory("newdir")

        let status = GitStatus(
            root: tempDirectory,
            badges: GitStatus.parse(porcelainZ: "?? newdir/\0")
        )

        XCTAssertEqual(
            WorkspaceFiles.children(of: tempDirectory, annotatedWith: status).first?.gitBadge,
            .untracked
        )
    }

    // MARK: - relativePath / repoRoot

    func testRelativePathIsRepositoryRelativeAndNilOutsideTheRepository() {
        let status = GitStatus(root: tempDirectory, badges: [:])

        XCTAssertEqual(status.relativePath(for: tempDirectory), "")
        XCTAssertEqual(
            status.relativePath(for: tempDirectory.appendingPathComponent("src/a.swift")),
            "src/a.swift"
        )
        XCTAssertNil(status.relativePath(for: URL(fileURLWithPath: "/elsewhere/a.swift")))
        XCTAssertNil(
            status.relativePath(for: tempDirectory.deletingLastPathComponent()),
            "an ancestor of the root is not inside it"
        )
    }

    func testRepoRootWalksUpToTheDirectoryHoldingDotGit() throws {
        try makeDirectory(".git")
        let nested = try makeDirectory("a/b/c")
        let file = nested.appendingPathComponent("d.txt")
        try "x".write(to: file, atomically: true, encoding: .utf8)

        let expected = tempDirectory.standardizedFileURL.resolvingSymlinksInPath().path
        XCTAssertEqual(GitStatus.repoRoot(for: nested)?.resolvingSymlinksInPath().path, expected)
        XCTAssertEqual(
            GitStatus.repoRoot(for: file)?.resolvingSymlinksInPath().path, expected,
            "a file starts the walk at its parent directory"
        )
    }

    /// A linked worktree or submodule stores `.git` as a *file*, not a
    /// directory — the walk has to accept both.
    func testRepoRootAcceptsADotGitFile() throws {
        try "gitdir: /somewhere/else".write(
            to: tempDirectory.appendingPathComponent(".git"), atomically: true, encoding: .utf8
        )
        let nested = try makeDirectory("a")

        XCTAssertEqual(
            GitStatus.repoRoot(for: nested)?.resolvingSymlinksInPath().path,
            tempDirectory.standardizedFileURL.resolvingSymlinksInPath().path
        )
    }

    func testRepoRootIsNilWhenNoAncestorHasADotGit() throws {
        let nested = try makeDirectory("a/b")

        XCTAssertNil(GitStatus.repoRoot(for: nested))
    }

    // MARK: - Live `git` plumbing

    /// One end-to-end pass so an argument typo cannot hide behind the pure
    /// parser tests. Skipped rather than failed where `git` is unavailable.
    func testLoadReadsARealRepository() throws {
        try makeGitRepository()
        try makeFile("untracked.txt")

        let status = try XCTUnwrap(GitStatus.load(repoRoot: tempDirectory))

        XCTAssertEqual(status.badges["untracked.txt"], .untracked)
    }

    func testLoadReturnsNilOutsideARepositoryRatherThanCrashing() throws {
        try skipUnlessGitIsAvailable()

        XCTAssertNil(
            GitStatus.load(repoRoot: tempDirectory),
            "git exits non-zero outside a repository, which is not an error the tree can show"
        )
    }

    func testAsyncLoadAnswersOnTheMainThread() throws {
        try makeGitRepository()
        try makeFile("untracked.txt")

        let answered = expectation(description: "status loaded")
        var badges: [String: GitBadge] = [:]
        var onMainThread = false
        GitStatus.load(repoRoot: tempDirectory) { status in
            onMainThread = Thread.isMainThread
            badges = status?.badges ?? [:]
            answered.fulfill()
        }
        wait(for: [answered], timeout: 20)

        XCTAssertTrue(onMainThread)
        XCTAssertEqual(badges["untracked.txt"], .untracked)
    }

    // MARK: - Helpers

    @discardableResult
    private func makeDirectory(_ relativePath: String) throws -> URL {
        let url = tempDirectory.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    private func makeFile(_ relativePath: String, contents: String = "x") throws -> URL {
        let url = tempDirectory.appendingPathComponent(relativePath)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - Branch

    /// The pane header's branch badge. Read straight out of `.git/HEAD` rather
    /// than by spawning `git`, so the shapes that file can take are the thing
    /// worth pinning down.
    func testTheBranchComesFromHeadAndDetachedHeadHasNone() throws {
        try makeGitRepository()
        let root = try XCTUnwrap(tempDirectory)

        XCTAssertEqual(GitBranch.current(repoRoot: root), "main")

        // A branch name may contain slashes; only the `refs/heads/` prefix goes.
        try "ref: refs/heads/feat/voice-latency\n".write(
            to: root.appendingPathComponent(".git/HEAD"),
            atomically: true,
            encoding: .utf8
        )
        XCTAssertEqual(GitBranch.current(repoRoot: root), "feat/voice-latency")

        // A detached HEAD stores a bare SHA — not a branch, so no badge.
        try "9fceb02c9f1d3e0c8b5a7d6e4f3a2b1c0d9e8f77\n".write(
            to: root.appendingPathComponent(".git/HEAD"),
            atomically: true,
            encoding: .utf8
        )
        XCTAssertNil(GitBranch.current(repoRoot: root))

        // Outside a repository there is nothing to report and nothing to crash on.
        XCTAssertNil(GitBranch.forDirectory("/"))
        XCTAssertNil(GitBranch.forDirectory(""))
    }

    private func makeGitRepository() throws {
        try skipUnlessGitIsAvailable()
        XCTAssertEqual(runGit(["init", "-q", tempDirectory.path]), 0, "git init failed")
    }

    private func skipUnlessGitIsAvailable() throws {
        guard runGit(["--version"]) == 0 else {
            throw XCTSkip("git is not available on PATH")
        }
    }

    /// Runs `git` with output discarded and returns its exit status, or -1 if
    /// it could not be spawned at all.
    private func runGit(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return -1
        }
        process.waitUntilExit()
        return process.terminationStatus
    }
}
