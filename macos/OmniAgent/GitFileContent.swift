import Foundation

/// Why a diff could not be produced. `.notInRepository` is the one the pane
/// turns into an inline message; `.gitFailed` is everything else git can do.
enum GitFileContentError: Error, Equatable {
    case notInRepository
    case gitFailed
}

/// Per-file git content for diff tabs.
///
/// The same subprocess dialect as `GitStatus` — `/usr/bin/env git`,
/// `GIT_OPTIONAL_LOCKS=0`, run off the main thread and answered on it — reused
/// rather than re-implemented (`GitStatus.runGit`). Monaco computes the diffs;
/// this only fetches the two sides, plus one already-unified diff for the
/// Changes tab's lazy expansion.
enum GitFileContent {
    /// `url` expressed the way `git show HEAD:<path>` wants it: repo-relative
    /// under `root`, `/`-separated, no leading slash. `nil` outside the root.
    ///
    /// Both sides go through `GitStatus.canonicalPath`, so a `/var/folders/…`
    /// URL and the `/private/var/folders/…` the same file also answers to do
    /// not silently fail the prefix test.
    static func relativePath(of url: URL, underRoot root: URL) -> String? {
        let path = GitStatus.canonicalPath(url)
        let rootPath = GitStatus.canonicalPath(root)
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard path.hasPrefix(prefix) else { return nil }
        return String(path.dropFirst(prefix.count))
    }

    /// The HEAD version of `url` — the left-hand side of a diff tab.
    ///
    /// A file that is not in HEAD (untracked, or newly added and not yet
    /// committed) is `.success("")`: a new file legitimately diffs against
    /// nothing, and rendering that as an error would be wrong. Only a file
    /// that is not in a repository at all, or a git that failed for some
    /// other reason, is an error the caller shows.
    static func headVersion(of url: URL, completion: @escaping (Result<String, GitFileContentError>) -> Void) {
        queue.async {
            guard let root = GitStatus.repoRoot(for: url),
                  let relative = relativePath(of: url, underRoot: root)
            else {
                DispatchQueue.main.async { completion(.failure(.notInRepository)) }
                return
            }
            let result: Result<String, GitFileContentError>
            if !isInHead(relative, root: root) {
                result = .success("")
            } else if let content = GitStatus.runGit(["show", "HEAD:\(relative)"], in: root) {
                result = .success(content)
            } else {
                result = .failure(.gitFailed)
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// One file's unified diff against HEAD — the Changes tab's lazy hunks.
    /// `nil` means "no repository, or git could not answer"; the caller shows
    /// that as a line of text inside the row rather than as a failure of the
    /// whole tab.
    static func unifiedDiff(of url: URL, completion: @escaping (String?) -> Void) {
        queue.async {
            guard let root = GitStatus.repoRoot(for: url),
                  let relative = relativePath(of: url, underRoot: root)
            else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            var text = GitStatus.runGit(["diff", "HEAD", "--", relative], in: root)
            // An untracked file is not in HEAD, so `git diff HEAD` exits **0
            // with no output** — the file would read as unchanged. Diff it
            // against `/dev/null` instead, which is git's own spelling of
            // "all new". `--no-index` exits 1 whenever the two differ, which
            // is the entire reason `runGit` takes `acceptExitCodes`.
            if text?.isEmpty != false, !isInHead(relative, root: root) {
                text = GitStatus.runGit(
                    ["diff", "--no-index", "--", "/dev/null", relative],
                    in: root,
                    acceptExitCodes: [0, 1]
                )
            }
            DispatchQueue.main.async { completion(text) }
        }
    }

    /// Whether HEAD carries `relative` at all.
    ///
    /// Asked separately rather than inferred from a failure, because
    /// `runGit` collapses every failure to `nil` and "not in HEAD" is a
    /// *normal* outcome here: `git cat-file -e HEAD:<path>` exits non-zero
    /// quietly when the path is absent (and when there is no HEAD yet, which
    /// is a repository with no commits — also "all new").
    private static func isInHead(_ relative: String, root: URL) -> Bool {
        GitStatus.runGit(["cat-file", "-e", "HEAD:\(relative)"], in: root) != nil
    }

    private static let queue = DispatchQueue(
        label: "ai.omni-agent.ade.editor.git-file-content",
        qos: .userInitiated
    )
}
