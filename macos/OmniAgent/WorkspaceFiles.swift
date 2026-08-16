import Foundation

/// The git annotation a FILES row can carry.
///
/// Deliberately a *display* vocabulary, not a transcription of git's
/// two-character porcelain codes: the sidebar shows one badge per row, so
/// the 30-odd `XY` combinations collapse into the six states a reader
/// actually distinguishes.
enum GitBadge: Equatable {
    case modified
    case added
    case deleted
    case untracked
    case renamed
    case conflicted
}

/// One row of the FILES tree.
///
/// A value, not a node in a live tree: `WorkspaceFiles.children(of:)`
/// produces exactly one directory level per call, so expansion stays lazy
/// and a huge repo never costs more than the directories the user opened.
struct WorkspaceFileNode: Equatable {
    let name: String
    let url: URL
    let isDirectory: Bool
    /// File-level annotation. `nil` means "clean, or not in a repo".
    var gitBadge: GitBadge?
    /// Directory-level annotation: how many changed files live beneath this
    /// row. Always 0 for files.
    var changedCount: Int

    init(
        name: String,
        url: URL,
        isDirectory: Bool,
        gitBadge: GitBadge? = nil,
        changedCount: Int = 0
    ) {
        self.name = name
        self.url = url
        self.isDirectory = isDirectory
        self.gitBadge = gitBadge
        self.changedCount = changedCount
    }
}

/// Listing a workspace directory for the sidebar's FILES tree.
///
/// The app is deliberately not sandboxed (see `OmniAgent.entitlements`), so
/// this is plain `FileManager` against real paths — no daemon round-trip, no
/// security-scoped bookmarks.
enum WorkspaceFiles {
    /// Directories that are never worth a row: build output and dependency
    /// caches, which are large, uninteresting, and (for `node_modules` in
    /// particular) expensive to even enumerate.
    ///
    /// `.git` is here for the same reason even though the leading-dot rule
    /// below already hides it — the intent should not depend on that rule
    /// surviving a future change.
    static let skippedDirectoryNames: Set<String> = [
        "node_modules", ".git", "target", "build", "DerivedData",
    ]

    /// One directory level, sorted for display: directories first, then
    /// files, each group case-insensitively by name.
    ///
    /// Never throws. An unreadable, missing, or non-directory `url` is a
    /// perfectly ordinary thing for a sidebar to be pointed at (a deleted
    /// project root, a permission-denied folder), and the honest answer is
    /// an empty level rather than an error the tree has nowhere to put.
    static func children(of url: URL) -> [WorkspaceFileNode] {
        let contents: [URL]
        do {
            contents = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: []
            )
        } catch {
            return []
        }

        var nodes: [WorkspaceFileNode] = []
        nodes.reserveCapacity(contents.count)
        for child in contents {
            let name = child.lastPathComponent
            guard !name.isEmpty, !name.hasPrefix(".") else { continue }
            let isDirectory = isDirectory(child)
            if isDirectory, skippedDirectoryNames.contains(name) { continue }
            nodes.append(
                WorkspaceFileNode(
                    name: name,
                    url: child.standardizedFileURL,
                    isDirectory: isDirectory
                )
            )
        }

        nodes.sort { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            let comparison = lhs.name.caseInsensitiveCompare(rhs.name)
            if comparison != .orderedSame { return comparison == .orderedAscending }
            // Only reachable on a case-sensitive volume; keeps the sort total
            // (and therefore deterministic) rather than relying on stability
            // `Array.sort` does not promise.
            return lhs.name < rhs.name
        }
        return nodes
    }

    /// The same level, with each row annotated from an already-loaded
    /// `GitStatus`.
    ///
    /// Split from `children(of:)` because the listing is instant and the
    /// status is a subprocess: the tree can draw unannotated rows now and
    /// take the badges whenever `GitStatus.load(repoRoot:completion:)`
    /// answers.
    static func children(of url: URL, annotatedWith status: GitStatus?) -> [WorkspaceFileNode] {
        let nodes = children(of: url)
        guard let status else { return nodes }
        return nodes.map { node in
            var annotated = node
            annotated.gitBadge = status.badge(for: node.url)
            if node.isDirectory, let relative = status.relativePath(for: node.url) {
                annotated.changedCount = status.changedCount(under: relative)
            }
            return annotated
        }
    }

    /// `children(of:)` off the main thread, answering on it.
    ///
    /// Listing one level is usually instant, but "usually" is not a promise a
    /// UI can rely on: a network volume or a cold directory with tens of
    /// thousands of entries makes `contentsOfDirectory` block for as long as
    /// it takes. Expanding a folder must never be able to freeze the window.
    static func list(_ url: URL, completion: @escaping ([WorkspaceFileNode]) -> Void) {
        listQueue.async {
            let nodes = children(of: url)
            DispatchQueue.main.async { completion(nodes) }
        }
    }

    private static let listQueue = DispatchQueue(
        label: "ai.omni-agent.ade.workspace-files.list",
        qos: .userInitiated
    )

    private static func isDirectory(_ url: URL) -> Bool {
        if let flag = try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory {
            return flag
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return false }
        return isDir.boolValue
    }
}

/// A snapshot of `git status` for one repository, as a relative-path -> badge
/// map plus the aggregation the tree needs.
///
/// A snapshot, deliberately: no watcher, no cache, no invalidation rules.
/// Whoever owns the tree decides when a new one is worth loading.
struct GitStatus {
    /// The repository root every key in `badges` is relative to.
    let root: URL
    /// Repository-relative path -> badge. Paths use `/`, never have a
    /// leading or trailing slash, and are exactly what git printed.
    let badges: [String: GitBadge]

    /// Cached once so per-row lookups do not re-resolve `/var` -> `/private/var`
    /// on every keystroke.
    private let resolvedRootPath: String

    init(root: URL, badges: [String: GitBadge]) {
        self.root = root
        self.badges = badges
        self.resolvedRootPath = GitStatus.canonicalPath(root)
    }

    // MARK: - Loading

    /// Synchronous load. **Never call this on the main thread** — `git status`
    /// in a large repository is comfortably slow enough to drop frames. It is
    /// `internal` rather than `private` only so tests can drive it against a
    /// temporary repository; production callers want the completion form.
    static func load(repoRoot: URL) -> GitStatus? {
        guard let output = runGit(
            ["status", "--porcelain=v1", "-z", "--untracked-files=normal"],
            in: repoRoot
        ) else { return nil }
        return GitStatus(root: repoRoot, badges: parse(porcelainZ: output))
    }

    /// Load off the main thread and answer on it.
    ///
    /// The whole reason this type exists as a snapshot: the subprocess runs
    /// on `loadQueue`, and the sidebar only ever sees a finished value.
    static func load(repoRoot: URL, completion: @escaping (GitStatus?) -> Void) {
        loadQueue.async {
            let status = load(repoRoot: repoRoot)
            DispatchQueue.main.async { completion(status) }
        }
    }

    private static let loadQueue = DispatchQueue(
        label: "ai.omni-agent.ade.workspace-files.git-status",
        qos: .utility
    )

    /// Runs `git` and returns stdout, or `nil` for any failure at all —
    /// git missing from `PATH`, spawn refused, a non-zero exit (not a
    /// repository, a corrupt index). A sidebar with no badges is a fine
    /// outcome; a crash is not.
    private static func runGit(_ arguments: [String], in directory: URL) -> String? {
        let process = Process()
        // `/usr/bin/env` rather than a hard-coded `/usr/bin/git` so a
        // Homebrew or Xcode-toolchain git on the user's PATH is honoured
        // when the app is launched from a shell.
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        process.currentDirectoryURL = directory

        var environment = ProcessInfo.processInfo.environment
        // Read-only status: never take `index.lock`, so a background refresh
        // can never lose a race with a `git` the user is running themselves.
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        process.environment = environment

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        // Drain before waiting: a repository with thousands of changes will
        // fill the pipe buffer, and waiting first would deadlock.
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Parsing

    /// Parses `git status --porcelain=v1 -z` output. Pure: no filesystem, no
    /// subprocess, no `self` — which is the point, because the `-z` framing
    /// is the part most likely to be wrong.
    ///
    /// The framing, verified against real `git` output:
    ///
    /// - Records are NUL-*terminated*, so the split yields a trailing empty
    ///   record that is simply skipped.
    /// - Each record is `XY` + one space + the path. Unlike the newline
    ///   format, `-z` never quotes or escapes, so a path containing spaces,
    ///   quotes or newlines arrives verbatim and needs no unescaping.
    /// - **A rename or copy occupies two records**: `R  <new>\0<old>\0`
    ///   (git reverses the `old -> new` order of the newline format). The
    ///   second record is a bare path with no `XY` prefix, so failing to
    ///   consume it would make the parser read `old name.txt` as a status
    ///   line and desynchronise everything after it.
    static func parse(porcelainZ: String) -> [String: GitBadge] {
        let records = porcelainZ.split(separator: "\0", omittingEmptySubsequences: false)
        var badges: [String: GitBadge] = [:]
        var index = 0

        while index < records.count {
            let record = records[index]
            index += 1
            // "XY p" is the shortest legal record; anything shorter is the
            // trailing empty split or garbage.
            guard record.count >= 4 else { continue }

            let x = record[record.startIndex]
            let y = record[record.index(after: record.startIndex)]
            let separator = record.index(record.startIndex, offsetBy: 2)
            guard record[separator] == " " else { continue }
            let path = String(record[record.index(after: separator)...])
            guard !path.isEmpty else { continue }

            // Only an *index*-side rename/copy carries the original path.
            // git's v1 porcelain does not do worktree rename detection, so
            // `y` is never R/C in practice — keying the extra-record consume
            // off `x` alone means a hypothetical ` R` could never make us
            // swallow the following entry.
            if x == "R" || x == "C" {
                index += 1
            }

            guard let badge = badge(x: x, y: y) else { continue }
            badges[normalize(path)] = badge
        }
        return badges
    }

    /// One badge from a porcelain `XY` pair, most-alarming-state-wins.
    ///
    /// Conflicts outrank everything (they block a commit), then untracked
    /// (`??` is the only code where both halves mean one thing), then
    /// rename, then deletion, then addition, and finally modification as the
    /// catch-all for `M`/`T`.
    private static func badge(x: Character, y: Character) -> GitBadge? {
        if x == "?" && y == "?" { return .untracked }
        // `!!` only appears with --ignored, which is never requested; treat
        // it as "no badge" rather than inventing a state for it.
        if x == "!" && y == "!" { return nil }
        // git's unmerged set: DD, AU, UD, UA, DU, AA, UU.
        if x == "U" || y == "U" || (x == "D" && y == "D") || (x == "A" && y == "A") {
            return .conflicted
        }
        if x == "R" || y == "R" { return .renamed }
        // A copy produced a file that was not there before; "added" is what a
        // reader of the tree understands, and the badge vocabulary has no
        // separate copy state.
        if x == "C" || y == "C" { return .added }
        if x == "D" || y == "D" { return .deleted }
        if x == "A" || y == "A" { return .added }
        if x == " " && y == " " { return nil }
        return .modified
    }

    /// Untracked *directories* are collapsed by `--untracked-files=normal`
    /// into a single `?? dir/` record. Dropping the trailing slash is what
    /// lets the directory's own row find its badge, since node paths never
    /// carry one.
    private static func normalize(_ path: String) -> String {
        var trimmed = Substring(path)
        while trimmed.hasSuffix("/") { trimmed = trimmed.dropLast() }
        return String(trimmed)
    }

    // MARK: - Lookup

    /// The repository containing `url`, found by walking up for a `.git`
    /// entry. `.git` is matched as either a directory or a file, because a
    /// linked worktree or submodule stores a `.git` *file* pointing at the
    /// real directory.
    static func repoRoot(for url: URL) -> URL? {
        var directory = url.standardizedFileURL
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDir),
           !isDir.boolValue {
            directory = directory.deletingLastPathComponent()
        }

        while true {
            let marker = directory.appendingPathComponent(".git").path
            if FileManager.default.fileExists(atPath: marker) { return directory }
            let parent = directory.deletingLastPathComponent().standardizedFileURL
            // `/` is its own parent; that is the loop's only exit on a miss.
            if parent.path == directory.path { return nil }
            directory = parent
        }
    }

    /// `url` expressed the way `badges` keys are: repository-relative, `/`
    /// separated, no leading slash. `""` for the root itself, `nil` for
    /// anything outside the repository.
    func relativePath(for url: URL) -> String? {
        let path = GitStatus.canonicalPath(url)
        if path == resolvedRootPath { return "" }
        let prefix = resolvedRootPath.hasSuffix("/") ? resolvedRootPath : resolvedRootPath + "/"
        guard path.hasPrefix(prefix) else { return nil }
        return String(path.dropFirst(prefix.count))
    }

    /// The badge for a file (or a collapsed untracked directory) at `url`.
    func badge(for url: URL) -> GitBadge? {
        guard let relative = relativePath(for: url), !relative.isEmpty else { return nil }
        return badges[relative]
    }

    /// How many changed files sit beneath a repository-relative directory
    /// path. `""` means the repository root, i.e. every change.
    ///
    /// A linear scan of the map, on purpose: the alternative is a prefix
    /// index that has to be rebuilt on every status refresh, to save
    /// microseconds on a map that holds one entry per changed file.
    func changedCount(under relativeDirPath: String) -> Int {
        let directory = GitStatus.normalize(relativeDirPath)
        if directory.isEmpty { return badges.count }
        let prefix = directory + "/"
        return badges.keys.reduce(into: 0) { total, key in
            if key.hasPrefix(prefix) { total += 1 }
        }
    }

    /// Symlink-resolved and standardized, so a `/var/folders/...` URL and the
    /// `/private/var/folders/...` the same file also answers to compare equal.
    private static func canonicalPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}

/// The branch a terminal is sitting on, for its header badge.
///
/// Read straight off `.git/HEAD` rather than by running `git`: this is asked
/// once per pane and again on every directory change, and spawning a process
/// for a single line of a file is the kind of cost that only shows up once
/// eight panes are open. A detached HEAD stores a bare SHA, which is not a
/// branch and so reports `nil` — the badge simply does not appear.
enum GitBranch {
    static func current(repoRoot: URL) -> String? {
        let head = repoRoot.appendingPathComponent(".git/HEAD")
        guard let contents = try? String(contentsOf: head, encoding: .utf8) else { return nil }
        let line = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let ref = line.split(separator: " ").last, line.hasPrefix("ref:") else { return nil }
        return String(ref.replacingOccurrences(of: "refs/heads/", with: ""))
    }

    /// The branch for whatever repository `path` lives in, or `nil` when it is
    /// not in one.
    static func forDirectory(_ path: String) -> String? {
        guard !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        guard let root = GitStatus.repoRoot(for: url) else { return nil }
        return current(repoRoot: root)
    }
}
