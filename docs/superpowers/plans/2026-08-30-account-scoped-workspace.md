# Account-Scoped Workspace Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Only the signed-in account sees its sessions and workspaces: the local data dir becomes per-account (selected by a pointer file), sign-in is mandatory, sign-in switches the daemon to the account's directory (asking first when it would end running sessions), and log-out tears the workspace, daemon and menu bar item down until someone signs in again.

**Architecture:** One indirection in `brain_core::Store::default_data_dir()` (root → `root/accounts/<id>` when `root/current-account` names an account) and its Swift twin `AccountDirectory`; the daemon reads the pointer once at startup and moves a pre-account install's data into the first account dir. The app writes the pointer, SIGTERMs the daemon through the connected socket's peer pid, waits for the socket to drop, drops its panes and once-flags, and lets the existing reconnect/restore path rebuild the account's workspace. The auth gate gains a `.switching` phase between sign-in and the persona question so that switch happens before the workspace is shown.

**Tech Stack:** Rust 2021 (rusqlite, sha2, tokio), Swift 5 / AppKit / SwiftUI / CryptoKit, XCTest, Xcode project `macos/OmniAgent.xcodeproj`.

**Spec:** `docs/superpowers/specs/2026-08-30-account-scoped-workspace-design.md`

## Global Constraints

- `<id>` = first 16 hex chars of SHA-256 of the lower-cased, trimmed account email (spec §Approach A). Test vector used on both sides: `"Bruno@Bonando.com "` → `fc44b18d5588b1d6` (SHA-256 of `bruno@bonando.com` is `fc44b18d5588b1d6861963a7c32bc81b0e7f4320ddf7ace0f043e00b050413c8`).
- Pointer file: `<root>/current-account`; absent or blank = signed out = data dir is the root. `OMNIAGENT_ADE_DATA_DIR` keeps overriding the *root* only. The LaunchAgent plist keeps `OMNIAGENT_ADE_DATA_DIR=<root>`.
- Legacy migration moves exactly `brain.db` (+ `-wal`, `-shm`), `brain/`, `transcripts/` — only when `root/accounts/` did not exist yet **and** `root/brain.db` exists; done in Rust by the daemon before `bind`; the app never moves files.
- Modal copy (house modal `presentWindowAsk`, `.critical`): switch — title "Move your workspace to your account?", message "This restarts the daemon and ends N running session(s).", buttons **Not now** / **Restart now**; logout — title "Log out and end N running session(s)?", buttons **Cancel** / **Log out**. Menu bar first item: **"Logged in as {name}"** (`auth_account_name`, falling back to the email).
- "Opening your workspace…" is the `.switching` card's text.
- `auth_persona` is **not** cleared on logout.
- **The running production daemon is never terminated by whoever executes this plan.** Verification is `cargo test`, `xcodebuild … -only-testing:` runs and the full suite. Never `pkill omniagent-pty-daemon`; never run `scripts/rebuild-app.sh` without `--keep-daemon`; never trigger log-out or account switch in the installed production app. Optional end-to-end checks use the Preview configuration only (own bundle id `digital.bruno.omniagent.preview`, own socket, own data dir).
- Tests use throwaway `UserDefaults` suites (never `.standard`), inject fakes for daemon termination and use a temporary directory as the account root, and never touch the network.
- Commit after every task with the trailer `Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>`; push after each commit. Before staging, `git status` must show only this task's files (other sessions share this worktree — stage by path, never `git add -A`; never `git stash`).
- Full-suite commands: `cargo test --workspace` and `caffeinate -disu ./macos/build.sh test` (`-di` alone is not enough). Known pre-existing failures (memory, 2026-08-30): daemon `server_protocol` timeouts, the sidebar divider-drag test; hover-card and ingest git-cochange tests are load-flaky.
- Targeted Swift test command (used throughout; `<Class>[/<test>]` varies):
  `caffeinate -disu xcodebuild test -project macos/OmniAgent.xcodeproj -scheme OmniAgent -destination "platform=macOS,arch=arm64" CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64 -only-testing:OmniAgentTests/<Class>` — do **not** add `-derivedDataPath` (targeted runs with it can hang in XCTest `recordIssue`).

---

## File map

| File | Responsibility after this plan |
|---|---|
| `crates/brain-core/Cargo.toml` | gains `sha2 = "0.10"` (not in `Cargo.lock` today; `digest` already is via `sha1`) |
| `crates/brain-core/src/store.rs` | `data_root()`, `current_account_file()`, `account_dir_id()`, `read_current_account()`, `resolve_data_dir()`, `default_data_dir()` (pointer-aware), `adopt_legacy_data()` + unit tests |
| `crates/omniagent-pty-daemon/src/server.rs` | `bind` adopts legacy data before opening the store; unit tests share an env lock |
| `macos/OmniAgent/AccountDirectory.swift` (new) | Swift twin of the pointer resolution |
| `macos/OmniAgentTests/AccountDirectoryTests.swift` (new) | its tests, including the cross-language vector |
| `macos/OmniAgent/SessionConnection.swift` | `peerProcessID()` |
| `macos/OmniAgent/DaemonServiceRegistrar.swift` | `DaemonTerminating` + `LiveDaemonTerminator` |
| `macos/OmniAgent/DaemonPersistenceController.swift` | `terminateDaemon(pid:completion:)` |
| `macos/OmniAgent/AuthGateState.swift`, `AuthGateView.swift` | no skip path; `.switching`; `.accountReady`; `onSwitching` hook; persona kept on reset |
| `macos/OmniAgent/WorkspaceWindowController.swift` | `switchAccount`, `resetForAccountSwitch`, launch/adoption wiring, logout teardown, signed-out guards, `onSignedInStateChanged`, `accountDisplayLabel` |
| `macos/OmniAgent/AppDelegate.swift`, `MenuBarController.swift` | menu bar exists only while signed in; "Logged in as …" |
| `macos/OmniAgent.xcodeproj/project.pbxproj` | registers the two new Swift files |
| `.github/copilot-instructions.md` (+ generated `CLAUDE.md` etc. via `scripts/sync-instructions.sh`), `README.md` | per-account data dirs, the pointer file, the never-kill-a-busy-daemon rule |

---

### Task 1: brain-core — account id and pointer-aware `default_data_dir()`

**Files:**
- Modify: `crates/brain-core/Cargo.toml` (dependencies)
- Modify: `crates/brain-core/src/store.rs:322-335` (`impl Store` / `default_data_dir`), tests appended at the end of the file

**Interfaces:**
- Consumes: nothing new.
- Produces (all `pub`, on `Store`): `fn data_root() -> PathBuf`; `fn current_account_file(root: &Path) -> PathBuf`; `fn account_dir_id(email: &str) -> String`; `fn read_current_account(root: &Path) -> Option<String>`; `fn resolve_data_dir(root: &Path) -> PathBuf`; `fn default_data_dir() -> PathBuf` (signature unchanged, now pointer-aware). Module constants `pub const CURRENT_ACCOUNT_FILE: &str = "current-account"; pub const ACCOUNTS_DIR: &str = "accounts";`.

- [ ] **Step 1: Add the `sha2` dependency**

`sha2` is not a dependency of any workspace crate and is absent from `Cargo.lock` (checked 2026-08-30; only `sha1`/`digest`/`ring` are present, and `ring` belongs to the daemon's TLS stack — `brain-core` sits below it and must not take a TLS crate for a hash). In `crates/brain-core/Cargo.toml` add under `[dependencies]`:

```toml
sha2 = "0.10"
```

`cargo test -p brain-core` in Step 3 updates `Cargo.lock`; commit the lock change with this task.

- [ ] **Step 2: Write the failing tests**

Append to the end of `crates/brain-core/src/store.rs`:

```rust
#[cfg(test)]
mod account_scope_tests {
    // The per-account data directory (docs/superpowers/specs/
    // 2026-08-30-account-scoped-workspace-design.md, "Approach A"): one
    // pointer file at the root selects `root/accounts/<id>`.
    use super::*;
    use std::sync::Mutex;
    use tempfile::tempdir;

    /// `default_data_dir` reads the process-global `OMNIAGENT_ADE_DATA_DIR`,
    /// and `cargo test` runs test functions on parallel threads — every test
    /// here that touches the env var holds this for its whole body. The
    /// pure-function tests below take an explicit root and need no lock.
    static ENV_LOCK: Mutex<()> = Mutex::new(());

    fn with_env_root<T>(root: &Path, body: impl FnOnce() -> T) -> T {
        let _guard = ENV_LOCK.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        std::env::set_var("OMNIAGENT_ADE_DATA_DIR", root);
        let out = body();
        std::env::remove_var("OMNIAGENT_ADE_DATA_DIR");
        out
    }

    #[test]
    fn account_dir_id_is_the_first_16_hex_of_sha256_of_the_normalized_email() {
        // The same vector is pinned in AccountDirectoryTests.swift — the two
        // sides must agree byte for byte or the app and the daemon would
        // pick different directories for one account.
        assert_eq!(Store::account_dir_id("Bruno@Bonando.com "), "fc44b18d5588b1d6");
        assert_eq!(Store::account_dir_id("bruno@bonando.com"), "fc44b18d5588b1d6");
        assert_eq!(Store::account_dir_id("bruno@bonando.com").len(), 16);
        assert_ne!(Store::account_dir_id("other@bonando.com"), "fc44b18d5588b1d6");
    }

    #[test]
    fn current_account_file_lives_at_the_root() {
        assert_eq!(
            Store::current_account_file(Path::new("/x/root")),
            PathBuf::from("/x/root/current-account")
        );
    }

    #[test]
    fn read_current_account_trims_and_rejects_blank_or_unsafe_ids() {
        let dir = tempdir().unwrap();
        assert_eq!(Store::read_current_account(dir.path()), None, "no file");

        std::fs::write(Store::current_account_file(dir.path()), "  fc44b18d5588b1d6\n").unwrap();
        assert_eq!(Store::read_current_account(dir.path()).as_deref(), Some("fc44b18d5588b1d6"));

        std::fs::write(Store::current_account_file(dir.path()), "   \n").unwrap();
        assert_eq!(Store::read_current_account(dir.path()), None, "blank means signed out");

        std::fs::write(Store::current_account_file(dir.path()), "../../etc").unwrap();
        assert_eq!(
            Store::read_current_account(dir.path()),
            None,
            "only hex ids are ever joined onto the root"
        );
    }

    #[test]
    fn resolve_data_dir_follows_the_pointer_and_falls_back_to_the_root() {
        let dir = tempdir().unwrap();
        assert_eq!(Store::resolve_data_dir(dir.path()), dir.path());

        std::fs::write(Store::current_account_file(dir.path()), "fc44b18d5588b1d6").unwrap();
        assert_eq!(
            Store::resolve_data_dir(dir.path()),
            dir.path().join("accounts").join("fc44b18d5588b1d6")
        );
    }

    #[test]
    fn default_data_dir_honors_the_env_root_with_and_without_a_pointer() {
        let dir = tempdir().unwrap();
        with_env_root(dir.path(), || {
            assert_eq!(Store::data_root(), dir.path());
            assert_eq!(Store::default_data_dir(), dir.path(), "no pointer: the root, as before");

            std::fs::write(Store::current_account_file(dir.path()), "fc44b18d5588b1d6\n").unwrap();
            assert_eq!(
                Store::default_data_dir(),
                dir.path().join("accounts").join("fc44b18d5588b1d6")
            );
            assert_eq!(Store::data_root(), dir.path(), "the env override is the root, never the account dir");

            std::fs::write(Store::current_account_file(dir.path()), "\n").unwrap();
            assert_eq!(Store::default_data_dir(), dir.path(), "a blank pointer is signed out");
        });
    }

    #[test]
    fn default_data_dir_without_the_env_override_is_under_home() {
        let dir = tempdir().unwrap();
        let _guard = ENV_LOCK.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        std::env::remove_var("OMNIAGENT_ADE_DATA_DIR");
        let previous_home = std::env::var_os("HOME");
        std::env::set_var("HOME", dir.path());

        let root = Store::data_root();
        assert_eq!(root, dir.path().join("Library/Application Support/OmniAgent-ADE"));
        assert_eq!(Store::default_data_dir(), root);

        match previous_home {
            Some(home) => std::env::set_var("HOME", home),
            None => std::env::remove_var("HOME"),
        }
    }
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `cargo test -p brain-core account_scope_tests`
Expected: compile error `no function or associated item named `account_dir_id` found for struct `Store`` (and the same for `data_root`, `current_account_file`, `read_current_account`, `resolve_data_dir`).

- [ ] **Step 4: Implement the resolution**

In `crates/brain-core/src/store.rs`, above `impl Store {` (line 322) add:

```rust
/// The pointer file at the data root naming the signed-in account —
/// written and removed by the native app (`AccountDirectory.swift`), read
/// once at startup by every process that opens the store through
/// [`Store::default_data_dir`]. Absent or blank means signed out.
pub const CURRENT_ACCOUNT_FILE: &str = "current-account";
/// Where the per-account data directories live under the root.
pub const ACCOUNTS_DIR: &str = "accounts";
```

Replace `default_data_dir` (`store.rs:323-335`) with:

```rust
    /// The data **root**: honors the `OMNIAGENT_ADE_DATA_DIR` env var
    /// override (used by tests and by `OMNIAGENT_ADE_DATA_DIR=... brain
    /// ingest` manual runs) and otherwise falls back to
    /// `~/Library/Application Support/OmniAgent-ADE` per the Global
    /// Constraints. The root holds [`CURRENT_ACCOUNT_FILE`] and the
    /// [`ACCOUNTS_DIR`]; user data lives in whichever directory
    /// [`Self::default_data_dir`] resolves to.
    pub fn data_root() -> PathBuf {
        if let Ok(dir) = std::env::var("OMNIAGENT_ADE_DATA_DIR") {
            if !dir.trim().is_empty() {
                return PathBuf::from(dir);
            }
        }
        let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".to_string());
        PathBuf::from(home).join("Library/Application Support/OmniAgent-ADE")
    }

    /// `root/current-account`.
    pub fn current_account_file(root: &Path) -> PathBuf {
        root.join(CURRENT_ACCOUNT_FILE)
    }

    /// The account's directory name: the first 16 hex characters of the
    /// SHA-256 of the lower-cased, trimmed email. Stable, filesystem-safe,
    /// and no PII in the path. `AccountDirectory.accountID(forEmail:)` is
    /// the Swift twin and both pin the same test vector.
    pub fn account_dir_id(email: &str) -> String {
        use sha2::{Digest, Sha256};
        let normalized = email.trim().to_lowercase();
        let digest = Sha256::digest(normalized.as_bytes());
        digest[..8].iter().map(|byte| format!("{byte:02x}")).collect()
    }

    /// The id the pointer names, or `None` when signed out (no file, or a
    /// blank one). Anything but hex digits is treated as absent rather than
    /// joined onto the root: the file is user-writable, and `../` in it must
    /// never move the store out of the root.
    pub fn read_current_account(root: &Path) -> Option<String> {
        let raw = std::fs::read_to_string(Self::current_account_file(root)).ok()?;
        let id = raw.trim();
        if id.is_empty() || !id.chars().all(|c| c.is_ascii_hexdigit()) {
            return None;
        }
        Some(id.to_string())
    }

    /// `root/accounts/<id>` while the pointer names an account, else the
    /// root itself — the one indirection every crate and the app share.
    pub fn resolve_data_dir(root: &Path) -> PathBuf {
        match Self::read_current_account(root) {
            Some(id) => root.join(ACCOUNTS_DIR).join(id),
            None => root.to_path_buf(),
        }
    }

    /// Resolves the local-first data directory: [`Self::data_root`] with the
    /// account pointer applied. Existing callers (the daemon, `brain`,
    /// `omniagent-mcp`) keep calling this and gain account scoping for
    /// free; tests that set `OMNIAGENT_ADE_DATA_DIR` to a temp dir with no
    /// pointer see exactly what they saw before.
    pub fn default_data_dir() -> PathBuf {
        Self::resolve_data_dir(&Self::data_root())
    }
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `cargo test -p brain-core`
Expected: all tests pass, including the 6 new `account_scope_tests` and the pre-existing `tests/store_test.rs` env-var test (a temp root with no pointer resolves to itself).

Run: `cargo test --workspace` (the daemon's and mcp-server's contract tests all go through `default_data_dir` with pointer-less temp roots).
Expected: unchanged results (known pre-existing failures only, per Global Constraints).

- [ ] **Step 6: Commit**

```bash
git add crates/brain-core/Cargo.toml Cargo.lock crates/brain-core/src/store.rs
git commit -m "feat(brain-core): resolve the data dir through the current-account pointer

default_data_dir() now applies root/current-account -> root/accounts/<id>,
where <id> is the first 16 hex of SHA-256 of the normalized email. The
env override still sets the root only.

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
git push
```

---

### Task 2: brain-core — `Store::adopt_legacy_data`

**Files:**
- Modify: `crates/brain-core/src/store.rs` (`impl Store`, after `default_data_dir`; tests appended to `account_scope_tests`)

**Interfaces:**
- Consumes: `ACCOUNTS_DIR` (Task 1).
- Produces: `pub fn adopt_legacy_data(root: &Path, account_dir: &Path) -> std::io::Result<bool>` — `true` when it moved the legacy artefacts.

- [ ] **Step 1: Write the failing tests**

Inside `mod account_scope_tests` (Task 1) add:

```rust
    /// Every legacy artefact the migration is responsible for, plus one
    /// bystander it must leave alone.
    fn seed_legacy_root(root: &Path) {
        Store::open(root).unwrap().set_setting("layout", "legacy-layout").unwrap();
        std::fs::write(root.join("brain.db-wal"), b"wal").unwrap();
        std::fs::write(root.join("brain.db-shm"), b"shm").unwrap();
        std::fs::create_dir_all(root.join("brain").join("proj")).unwrap();
        std::fs::write(root.join("brain").join("proj").join("note.md"), "# note").unwrap();
        std::fs::create_dir_all(root.join("transcripts")).unwrap();
        std::fs::write(root.join("transcripts").join("s1.log"), "hello").unwrap();
        std::fs::write(root.join("unrelated.txt"), "stays").unwrap();
    }

    #[test]
    fn adopt_legacy_data_moves_the_three_artefacts_into_the_first_account_dir() {
        let dir = tempdir().unwrap();
        let root = dir.path();
        seed_legacy_root(root);
        let account = root.join("accounts").join("fc44b18d5588b1d6");

        assert!(Store::adopt_legacy_data(root, &account).unwrap());

        for name in ["brain.db", "brain.db-wal", "brain.db-shm", "brain", "transcripts"] {
            assert!(!root.join(name).exists(), "{name} left the root");
            assert!(account.join(name).exists(), "{name} arrived in the account dir");
        }
        assert_eq!(
            std::fs::read_to_string(account.join("brain").join("proj").join("note.md")).unwrap(),
            "# note"
        );
        assert!(root.join("unrelated.txt").exists(), "only the three artefacts move");
        let moved = Store::open(&account).unwrap();
        assert_eq!(moved.get_setting("layout").unwrap().as_deref(), Some("legacy-layout"));
    }

    #[test]
    fn adopt_legacy_data_is_a_no_op_once_any_account_dir_exists() {
        let dir = tempdir().unwrap();
        let root = dir.path();
        seed_legacy_root(root);
        let first = root.join("accounts").join("fc44b18d5588b1d6");
        assert!(Store::adopt_legacy_data(root, &first).unwrap());
        assert!(!Store::adopt_legacy_data(root, &first).unwrap(), "idempotent");

        // A later account starts empty: the legacy data belongs to the first.
        Store::open(root).unwrap().set_setting("layout", "written-later-at-root").unwrap();
        let second = root.join("accounts").join("0123456789abcdef");
        assert!(!Store::adopt_legacy_data(root, &second).unwrap());
        assert!(root.join("brain.db").exists(), "nothing moved");
        assert!(!second.join("brain.db").exists());
    }

    #[test]
    fn adopt_legacy_data_does_nothing_without_a_root_brain_db_or_for_the_root_itself() {
        let dir = tempdir().unwrap();
        let root = dir.path();
        std::fs::create_dir_all(root.join("transcripts")).unwrap();
        let account = root.join("accounts").join("fc44b18d5588b1d6");
        assert!(!Store::adopt_legacy_data(root, &account).unwrap(), "no brain.db: a fresh install");
        assert!(!root.join("accounts").exists(), "and nothing was created either");
        assert!(root.join("transcripts").exists());

        seed_legacy_root(root);
        assert!(!Store::adopt_legacy_data(root, root).unwrap(), "signed out: the root serves itself");
        assert!(root.join("brain.db").exists());
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cargo test -p brain-core account_scope_tests::adopt`
Expected: compile error `no function or associated item named `adopt_legacy_data``.

- [ ] **Step 3: Implement `adopt_legacy_data`**

In `impl Store`, directly after `default_data_dir` (Task 1), add:

```rust
    /// One-time migration of a pre-account install: moves `root/brain.db`
    /// (+ `-wal`, `-shm`), `root/brain/` and `root/transcripts/` into
    /// `account_dir`, but only the very first time an account directory is
    /// created (`root/accounts` did not exist yet) and only when there is a
    /// `root/brain.db` to move. Every later account starts empty.
    ///
    /// Called by the daemon before it opens the store — the daemon is the
    /// sole owner of these files, and at that moment nothing has them open.
    /// The app never moves files itself. A `rename` within one root stays
    /// on one filesystem, so this is atomic per artefact and never copies.
    pub fn adopt_legacy_data(root: &Path, account_dir: &Path) -> std::io::Result<bool> {
        if account_dir == root {
            return Ok(false);
        }
        if root.join(ACCOUNTS_DIR).exists() {
            return Ok(false);
        }
        if !root.join("brain.db").is_file() {
            return Ok(false);
        }
        std::fs::create_dir_all(account_dir)?;
        for name in ["brain.db", "brain.db-wal", "brain.db-shm", "brain", "transcripts"] {
            let from = root.join(name);
            if from.exists() {
                std::fs::rename(&from, account_dir.join(name))?;
            }
        }
        Ok(true)
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cargo test -p brain-core`
Expected: all pass (9 `account_scope_tests`).

- [ ] **Step 5: Commit**

```bash
git add crates/brain-core/src/store.rs
git commit -m "feat(brain-core): adopt a pre-account install's data into the first account dir

Store::adopt_legacy_data moves brain.db (+wal/shm), brain/ and
transcripts/ once — only while root/accounts does not exist yet.

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
git push
```

---

### Task 3: daemon — adopt legacy data before `bind`

**Files:**
- Modify: `crates/omniagent-pty-daemon/src/server.rs:176-178` (`DaemonServer::bind`) and `:1085-1124` (`mod tests`)

**Interfaces:**
- Consumes: `Store::data_root()`, `Store::default_data_dir()`, `Store::adopt_legacy_data` (Tasks 1–2), `Store::current_account_file`.
- Produces: `bind()` opens the account directory the pointer names and migrates legacy data first. No signature change.

- [ ] **Step 1: Write the failing test and serialize the env-var tests**

Replace the whole `mod tests` at `server.rs:1085-1124` with:

```rust
#[cfg(test)]
mod tests {
    use super::*;

    /// Both tests below mutate the process-global `OMNIAGENT_ADE_DATA_DIR`.
    /// They live here (this unit-test binary) rather than in
    /// `tests/server_protocol.rs`, which runs many concurrent tests that
    /// would race the env var — and they serialize against each other
    /// through this lock, held across the awaits (a tokio mutex, so no
    /// `await_holding_lock` lint).
    static ENV_LOCK: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

    /// Task 6a regression: `bind()` — the real entry point `run_daemon`/
    /// `main.rs` use in production — must resolve the shared brain-store
    /// data directory via `brain_core::Store::default_data_dir()`, honoring
    /// `OMNIAGENT_ADE_DATA_DIR` exactly like every other crate does, and
    /// NOT derive it from the socket path's own parent directory. The bug
    /// this catches: `bind()` used to open `Store::open(runtime_dir)` (the
    /// socket's directory), which silently pointed every brain read — and
    /// the `layout` setting — at an unshared, essentially-empty `brain.db`
    /// instead of the one the app actually reads and writes.
    #[tokio::test]
    async fn bind_resolves_the_shared_data_dir_via_default_data_dir_not_the_socket_path() {
        let _env = ENV_LOCK.lock().await;
        let scratch = tempfile::tempdir().unwrap();
        let data_dir = scratch.path().join("shared-brain-data");
        std::env::set_var("OMNIAGENT_ADE_DATA_DIR", &data_dir);

        let socket_path = scratch.path().join("elsewhere-entirely").join("daemon.sock");
        let server = DaemonServer::bind(socket_path).await.unwrap();

        assert_eq!(server.data_dir, data_dir);
        assert_eq!(server.data_dir, Store::default_data_dir());
        // Proves the socket's own directory played no part in the result.
        assert_ne!(server.data_dir, scratch.path().join("elsewhere-entirely"));
        assert!(data_dir.join("brain.db").exists());

        drop(server);
        std::env::remove_var("OMNIAGENT_ADE_DATA_DIR");
    }

    /// The account-scoped workspace (2026-08-30 spec): with a pointer at the
    /// root, `bind()` opens `root/accounts/<id>` — and on the first such
    /// start moves the pre-account `brain.db` there, so the developer's
    /// existing layout, roots and transcripts come back under the account
    /// instead of being left behind at the root.
    #[tokio::test]
    async fn bind_follows_the_current_account_pointer_and_adopts_legacy_data_once() {
        let _env = ENV_LOCK.lock().await;
        let scratch = tempfile::tempdir().unwrap();
        let root = scratch.path().join("root");
        // The pre-account install: a brain.db at the root with a row in it.
        Store::open(&root).unwrap().set_setting("layout", "legacy-layout").unwrap();
        std::fs::write(Store::current_account_file(&root), "fc44b18d5588b1d6\n").unwrap();
        std::env::set_var("OMNIAGENT_ADE_DATA_DIR", &root);

        let socket_path = scratch.path().join("run").join("daemon.sock");
        let server = DaemonServer::bind(socket_path).await.unwrap();

        let account_dir = root.join("accounts").join("fc44b18d5588b1d6");
        assert_eq!(server.data_dir, account_dir);
        assert!(!root.join("brain.db").exists(), "the legacy brain.db moved");
        assert_eq!(
            server.settings.lock().unwrap().get_setting("layout").unwrap().as_deref(),
            Some("legacy-layout"),
            "and the daemon is serving it from the account dir"
        );

        drop(server);
        std::env::remove_var("OMNIAGENT_ADE_DATA_DIR");
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cargo test -p omniagent-pty-daemon --lib bind_follows_the_current_account_pointer`
Expected: FAIL — `bind` opens `Store::default_data_dir()` (the account dir, empty) without moving anything: `assertion failed: !root.join("brain.db").exists()`.

- [ ] **Step 3: Adopt legacy data in `bind`**

Replace `DaemonServer::bind` (`server.rs:171-178`) with:

```rust
    /// Binds the daemon socket at `socket_path` and opens the shared brain
    /// store at `brain_core::Store::default_data_dir()` — honoring
    /// `OMNIAGENT_ADE_DATA_DIR` exactly like every other crate in this
    /// workspace does (PLAN.md's Local-first constraint: "Env override
    /// `OMNIAGENT_ADE_DATA_DIR` for tests — every crate must honor it").
    ///
    /// The directory is account-scoped: `root/current-account` selects
    /// `root/accounts/<id>` (2026-08-30 account-scoped-workspace spec). The
    /// pointer is read exactly once, here — the app restarts the daemon to
    /// move it between accounts. Before the store is opened, and so before
    /// any file is held open, a pre-account install's data is moved into
    /// the first account directory (`Store::adopt_legacy_data`).
    pub async fn bind(socket_path: PathBuf) -> Result<Self> {
        let root = Store::data_root();
        let data_dir = Store::default_data_dir();
        if data_dir != root
            && Store::adopt_legacy_data(&root, &data_dir)
                .context("move the pre-account brain data into the account directory")?
        {
            tracing::info!(
                root = %root.display(),
                account_dir = %data_dir.display(),
                "adopted the pre-account brain data into the account directory"
            );
        }
        Self::bind_with_data_dir(socket_path, data_dir).await
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cargo test -p omniagent-pty-daemon --lib`
Expected: both `tests::bind_*` pass. Then `cargo test -p omniagent-pty-daemon` — unchanged apart from the known `server_protocol` timeouts, and `cargo clippy -p omniagent-pty-daemon --all-targets` reports nothing new.

- [ ] **Step 5: Commit**

```bash
git add crates/omniagent-pty-daemon/src/server.rs
git commit -m "feat(daemon): open the account directory the pointer names, adopting legacy data first

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
git push
```

---

### Task 4: Swift `AccountDirectory` — the pointer's twin

**Files:**
- Create: `macos/OmniAgent/AccountDirectory.swift`
- Create: `macos/OmniAgentTests/AccountDirectoryTests.swift`
- Modify: `macos/OmniAgent.xcodeproj/project.pbxproj` (four lines per new file)
- Modify: `macos/OmniAgent/DaemonPersistence.swift:39-49` (doc comment on `DaemonPaths.dataDir`)

**Interfaces:**
- Consumes: nothing.
- Produces: `enum AccountDirectory` with `static let pointerFileName = "current-account"`, `static let accountsDirectoryName = "accounts"`, `static func accountID(forEmail: String) -> String`, `static func currentAccountFile(root: URL) -> URL`, `static func readCurrentAccount(root: URL) -> String?`, `static func writeCurrentAccount(_ id: String, root: URL) throws`, `static func clearCurrentAccount(root: URL) throws`, `static func dataDir(root: URL) -> URL`.

- [ ] **Step 1: Register both files in the Xcode project**

Edit `macos/OmniAgent.xcodeproj/project.pbxproj` (ids `…108`/`…109` are unused; verified 2026-08-30 with `grep -c`). Four insertions per file, each directly **after** the anchor line quoted:

1. PBXBuildFile section — after line `		10000000000000000000038 /* DaemonPersistence.swift in Sources */ = {isa = PBXBuildFile; fileRef = 20000000000000000000039 /* DaemonPersistence.swift */; };`:
```
		10000000000000000000108 /* AccountDirectory.swift in Sources */ = {isa = PBXBuildFile; fileRef = 20000000000000000000108 /* AccountDirectory.swift */; };
		10000000000000000000109 /* AccountDirectoryTests.swift in Sources */ = {isa = PBXBuildFile; fileRef = 20000000000000000000109 /* AccountDirectoryTests.swift */; };
```
2. PBXFileReference section — after line `		20000000000000000000039 /* DaemonPersistence.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = DaemonPersistence.swift; sourceTree = "<group>"; };`:
```
		20000000000000000000108 /* AccountDirectory.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = AccountDirectory.swift; sourceTree = "<group>"; };
		20000000000000000000109 /* AccountDirectoryTests.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = AccountDirectoryTests.swift; sourceTree = "<group>"; };
```
3. Group children — in the `OmniAgent` group, after `				20000000000000000000039 /* DaemonPersistence.swift */,`:
```
				20000000000000000000108 /* AccountDirectory.swift */,
```
   and in the `OmniAgentTests` group, after `				2000000000000000000003F /* DaemonPersistenceTests.swift */,`:
```
				20000000000000000000109 /* AccountDirectoryTests.swift */,
```
4. Sources build phases — in the app target's phase, after `				10000000000000000000038 /* DaemonPersistence.swift in Sources */,`:
```
				10000000000000000000108 /* AccountDirectory.swift in Sources */,
```
   and in the test target's phase, after `				1000000000000000000003E /* DaemonPersistenceTests.swift in Sources */,`:
```
				10000000000000000000109 /* AccountDirectoryTests.swift in Sources */,
```

- [ ] **Step 2: Write the failing tests**

Create `macos/OmniAgentTests/AccountDirectoryTests.swift`:

```swift
import XCTest
@testable import OmniAgent

/// `AccountDirectory` is the Swift twin of `brain_core::Store`'s pointer
/// resolution (crates/brain-core/src/store.rs, `account_scope_tests`). The
/// app writes the pointer, the daemon reads it — so the id derivation and
/// the file's shape are pinned to the same vectors on both sides.
final class AccountDirectoryTests: XCTestCase {
    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("omniagent-account-root-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testAccountIDMatchesTheRustVector() {
        // The same vector `Store::account_dir_id` pins: SHA-256 of the
        // lower-cased, trimmed email, first 16 hex characters.
        XCTAssertEqual(AccountDirectory.accountID(forEmail: "Bruno@Bonando.com "), "fc44b18d5588b1d6")
        XCTAssertEqual(AccountDirectory.accountID(forEmail: "bruno@bonando.com"), "fc44b18d5588b1d6")
        XCTAssertEqual(AccountDirectory.accountID(forEmail: "bruno@bonando.com").count, 16)
        XCTAssertNotEqual(AccountDirectory.accountID(forEmail: "other@bonando.com"), "fc44b18d5588b1d6")
    }

    func testThePointerFileLivesAtTheRoot() {
        let root = URL(fileURLWithPath: "/x/root", isDirectory: true)
        XCTAssertEqual(AccountDirectory.currentAccountFile(root: root).path, "/x/root/current-account")
    }

    func testReadingTrimsAndRejectsBlankOrUnsafeIDs() throws {
        let root = try temporaryRoot()
        XCTAssertNil(AccountDirectory.readCurrentAccount(root: root), "no file")

        try "  fc44b18d5588b1d6\n".write(to: AccountDirectory.currentAccountFile(root: root), atomically: true, encoding: .utf8)
        XCTAssertEqual(AccountDirectory.readCurrentAccount(root: root), "fc44b18d5588b1d6")

        try "   \n".write(to: AccountDirectory.currentAccountFile(root: root), atomically: true, encoding: .utf8)
        XCTAssertNil(AccountDirectory.readCurrentAccount(root: root), "blank means signed out")

        try "../../etc".write(to: AccountDirectory.currentAccountFile(root: root), atomically: true, encoding: .utf8)
        XCTAssertNil(AccountDirectory.readCurrentAccount(root: root), "only hex ids are ever joined onto the root")
    }

    func testWriteThenReadThenClearRoundTrips() throws {
        let root = try temporaryRoot()
        try AccountDirectory.writeCurrentAccount("fc44b18d5588b1d6", root: root)
        XCTAssertEqual(
            try String(contentsOf: AccountDirectory.currentAccountFile(root: root), encoding: .utf8),
            "fc44b18d5588b1d6\n",
            "one id, one trailing newline — what the Rust reader trims"
        )
        XCTAssertEqual(AccountDirectory.readCurrentAccount(root: root), "fc44b18d5588b1d6")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: root.appendingPathComponent("accounts").path),
            "the app never creates accounts/ — that would defeat the daemon's one-time legacy migration"
        )

        try AccountDirectory.clearCurrentAccount(root: root)
        XCTAssertNil(AccountDirectory.readCurrentAccount(root: root))
        XCTAssertNoThrow(try AccountDirectory.clearCurrentAccount(root: root), "clearing twice is fine")
    }

    func testWriteCreatesAMissingRoot() throws {
        let root = try temporaryRoot().appendingPathComponent("not-yet", isDirectory: true)
        try AccountDirectory.writeCurrentAccount("fc44b18d5588b1d6", root: root)
        XCTAssertEqual(AccountDirectory.readCurrentAccount(root: root), "fc44b18d5588b1d6")
    }

    func testDataDirFollowsThePointerAndFallsBackToTheRoot() throws {
        let root = try temporaryRoot()
        XCTAssertEqual(AccountDirectory.dataDir(root: root).path, root.path)
        try AccountDirectory.writeCurrentAccount("fc44b18d5588b1d6", root: root)
        XCTAssertEqual(
            AccountDirectory.dataDir(root: root).path,
            root.appendingPathComponent("accounts").appendingPathComponent("fc44b18d5588b1d6").path
        )
    }
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `caffeinate -disu xcodebuild test -project macos/OmniAgent.xcodeproj -scheme OmniAgent -destination "platform=macOS,arch=arm64" CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64 -only-testing:OmniAgentTests/AccountDirectoryTests`
Expected: build fails — `cannot find 'AccountDirectory' in scope` (the app file does not exist yet; the project references it, so also `Build input file cannot be found` until Step 4).

- [ ] **Step 4: Implement `AccountDirectory`**

Create `macos/OmniAgent/AccountDirectory.swift`:

```swift
import CryptoKit
import Foundation

/// The account pointer — Swift twin of `brain_core::Store`'s
/// `current_account_file`/`account_dir_id`/`resolve_data_dir`
/// (crates/brain-core/src/store.rs). The data **root** is
/// `DaemonPaths.dataDir`; while `<root>/current-account` names an account,
/// every process resolves its data dir to `<root>/accounts/<id>`, otherwise
/// to the root (signed out).
///
/// The app is the only writer of the pointer and never creates `accounts/`
/// itself: the daemon creates the account directory when it starts, and its
/// one-time legacy migration (`Store::adopt_legacy_data`) keys off
/// `accounts/` not existing yet. The daemon reads the pointer once at
/// startup, so moving between accounts is a daemon restart
/// (`WorkspaceWindowController.switchAccount`).
enum AccountDirectory {
    static let pointerFileName = "current-account"
    static let accountsDirectoryName = "accounts"

    /// First 16 hex characters of the SHA-256 of the lower-cased, trimmed
    /// email — `Store::account_dir_id`, byte for byte (both pin the same
    /// test vector).
    static func accountID(forEmail email: String) -> String {
        let normalized = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let digest = SHA256.hash(data: Data(normalized.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    static func currentAccountFile(root: URL) -> URL {
        root.appendingPathComponent(pointerFileName)
    }

    /// The id the pointer names, or `nil` when signed out (no file, or a
    /// blank one). Anything but hex digits reads as absent — the file is
    /// user-writable and `../` in it must never leave the root.
    static func readCurrentAccount(root: URL) -> String? {
        guard let raw = try? String(contentsOf: currentAccountFile(root: root), encoding: .utf8) else {
            return nil
        }
        let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, id.allSatisfy(\.isHexDigit) else { return nil }
        return id
    }

    /// One id and a trailing newline; atomic, so a daemon starting mid-write
    /// sees either the old pointer or the new one.
    static func writeCurrentAccount(_ id: String, root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try (id + "\n").write(to: currentAccountFile(root: root), atomically: true, encoding: .utf8)
    }

    /// Signed out. Removing a pointer that is already gone is not an error.
    static func clearCurrentAccount(root: URL) throws {
        let file = currentAccountFile(root: root)
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        try FileManager.default.removeItem(at: file)
    }

    /// `Store::resolve_data_dir`: the account directory, or the root.
    static func dataDir(root: URL) -> URL {
        guard let id = readCurrentAccount(root: root) else { return root }
        return root
            .appendingPathComponent(accountsDirectoryName, isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
    }
}
```

In `macos/OmniAgent/DaemonPersistence.swift`, extend the doc comment on `DaemonPaths` (above `let dataDir: URL`, line 41) with:

```swift
    /// `dataDir` is the data **root** — where `current-account` and
    /// `accounts/` live, and what the LaunchAgent plist hands the daemon as
    /// `OMNIAGENT_ADE_DATA_DIR`. The directory user data actually lives in
    /// is `AccountDirectory.dataDir(root:)`; the daemon resolves it the same
    /// way at startup.
```

- [ ] **Step 5: Run the tests to verify they pass**

Run the Step 3 command again.
Expected: `AccountDirectoryTests` — 6 tests pass.

- [ ] **Step 6: Commit**

```bash
git add macos/OmniAgent/AccountDirectory.swift macos/OmniAgentTests/AccountDirectoryTests.swift macos/OmniAgent.xcodeproj/project.pbxproj macos/OmniAgent/DaemonPersistence.swift
git commit -m "feat(macos): AccountDirectory, the Swift twin of the current-account pointer

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
git push
```

---

### Task 5: `SessionConnection.peerProcessID()` and `DaemonPersistenceController.terminateDaemon`

**Files:**
- Modify: `macos/OmniAgent/SessionConnection.swift` (after `disconnect()`, line 260-266)
- Modify: `macos/OmniAgent/DaemonServiceRegistrar.swift` (append after `LiveDaemonProcessHandle`)
- Modify: `macos/OmniAgent/DaemonPersistenceController.swift:29-61` (stored `terminator`, init), `:66-84` (convenience init), new method after `start()`
- Test: `macos/OmniAgentTests/DaemonPersistenceControllerTests.swift`

**Interfaces:**
- Consumes: `DaemonSocketProbe.isReachable(at:)`, `bindAndListenTestSocket(at:)` (DaemonServiceRegistrarTests.swift:55, internal).
- Produces: `SessionConnection.peerProcessID() -> pid_t?`; `protocol DaemonTerminating { func terminate(pid: pid_t?, socketURL: URL, timeout: TimeInterval, completion: @escaping (Bool) -> Void) }`; `final class LiveDaemonTerminator: DaemonTerminating`; `DaemonPersistenceController.init(paths:registrar:processLauncher:resolveBinaryPath:socketReachable:terminator:)` (new last parameter, defaulted to `LiveDaemonTerminator()`); `DaemonPersistenceController.terminateDaemon(pid: pid_t?, completion: @escaping () -> Void)`.

- [ ] **Step 1: Write the failing tests**

In `macos/OmniAgentTests/DaemonPersistenceControllerTests.swift`, after `FakeDaemonProcessLauncher` (line 46) add:

```swift
/// A scripted `DaemonTerminating`: records what it was asked to end and
/// answers at once — the real one sends SIGTERM and polls a socket, which
/// no test may do to the developer's live daemon.
private final class FakeDaemonTerminator: DaemonTerminating {
    private(set) var calls: [(pid: pid_t?, socketURL: URL)] = []
    var result = true

    func terminate(pid: pid_t?, socketURL: URL, timeout: TimeInterval, completion: @escaping (Bool) -> Void) {
        calls.append((pid, socketURL))
        completion(result)
    }
}
```

Change `makeController` (lines 55-68) to thread a terminator through:

```swift
    private func makeController(
        registrar: FakeDaemonServiceRegistrar,
        launcher: FakeDaemonProcessLauncher = FakeDaemonProcessLauncher(),
        binaryPath: String? = "/Applications/OmniAgent.app/Contents/MacOS/omniagent-pty-daemon",
        socketReachable: Bool = false,
        terminator: FakeDaemonTerminator = FakeDaemonTerminator()
    ) -> DaemonPersistenceController {
        DaemonPersistenceController(
            paths: paths,
            registrar: registrar,
            processLauncher: launcher,
            resolveBinaryPath: { binaryPath },
            socketReachable: { socketReachable },
            terminator: terminator
        )
    }
```

Append before the final `}` of the class:

```swift
    // MARK: - Account switch: terminate + respawn

    func testTerminateDaemonSignalsThePidAndRespawnsInAppOwnedMode() {
        let registrar = FakeDaemonServiceRegistrar(status: .notRegistered, registerOutcome: .failed)
        let launcher = FakeDaemonProcessLauncher()
        let terminator = FakeDaemonTerminator()
        let controller = makeController(registrar: registrar, launcher: launcher, terminator: terminator)
        controller.start()
        XCTAssertEqual(launcher.launchCallCount, 1)

        var completed = 0
        controller.terminateDaemon(pid: 4242) { completed += 1 }

        XCTAssertEqual(terminator.calls.map(\.pid), [4242])
        XCTAssertEqual(terminator.calls.map(\.socketURL), [paths.socketURL])
        XCTAssertEqual(launcher.launchCallCount, 2, "app-owned: nothing else will bring a daemon back")
        XCTAssertEqual(completed, 1)
    }

    func testTerminateDaemonLeavesTheRespawnToLaunchdForARegisteredService() {
        let registrar = FakeDaemonServiceRegistrar(status: .enabled, registerOutcome: .registered(.enabled))
        let launcher = FakeDaemonProcessLauncher()
        let terminator = FakeDaemonTerminator()
        let controller = makeController(
            registrar: registrar, launcher: launcher, socketReachable: true, terminator: terminator
        )
        controller.start()
        XCTAssertEqual(launcher.launchCallCount, 0)

        var completed = 0
        controller.terminateDaemon(pid: nil) { completed += 1 }

        XCTAssertEqual(terminator.calls.count, 1, "the wait for the socket to drop still runs")
        XCTAssertEqual(launcher.launchCallCount, 0, "launchd's KeepAlive owns the respawn")
        XCTAssertEqual(completed, 1)
    }

    // MARK: - SessionConnection.peerProcessID

    /// The pid the terminator signals comes off the connected AF_UNIX
    /// descriptor (`LOCAL_PEERPID`), so it is always the daemon this app is
    /// actually talking to — never a pid file that could be stale. Exercised
    /// against a real listening socket owned by this very process.
    func testPeerProcessIDReadsTheListeningProcessOffTheConnectedDescriptor() throws {
        let path = "/tmp/omniagent-peerpid-\(UUID().uuidString.prefix(8)).sock"
        let listener = try bindAndListenTestSocket(at: path)
        defer {
            Darwin.close(listener)
            unlink(path)
        }
        let connection = SessionConnection(socketURL: URL(fileURLWithPath: path))
        XCTAssertNil(connection.peerProcessID(), "nothing connected yet")

        connection.connect()
        let connected = expectation(description: "the descriptor is connected")
        DispatchQueue.global().async {
            for _ in 0..<100 where connection.peerProcessID() == nil {
                Thread.sleep(forTimeInterval: 0.02)
            }
            connected.fulfill()
        }
        wait(for: [connected], timeout: 5)

        XCTAssertEqual(connection.peerProcessID(), getpid(), "the listener is this very process")
        connection.disconnect()
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `caffeinate -disu xcodebuild test -project macos/OmniAgent.xcodeproj -scheme OmniAgent -destination "platform=macOS,arch=arm64" CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64 -only-testing:OmniAgentTests/DaemonPersistenceControllerTests`
Expected: build fails — `cannot find type 'DaemonTerminating' in scope`, `extra argument 'terminator' in call`, `value of type 'SessionConnection' has no member 'peerProcessID'`.

- [ ] **Step 3: Implement `peerProcessID()`**

In `macos/OmniAgent/SessionConnection.swift`, after `disconnect()` (line 266) add:

```swift
    /// The pid on the other end of the connected unix-socket descriptor —
    /// `getsockopt(SOL_LOCAL, LOCAL_PEERPID)` — i.e. the daemon this
    /// connection is actually attached to, which is the only daemon
    /// `DaemonPersistenceController.terminateDaemon` may ever signal. `nil`
    /// while disconnected and for the relay transport, where the peer is a
    /// WebSocket on another machine. Read on `ioQueue`, where the descriptor
    /// is owned, so it can never race a connect or a close.
    func peerProcessID() -> pid_t? {
        ioQueue.sync {
            guard descriptor >= 0 else { return nil }
            var pid: pid_t = 0
            var length = socklen_t(MemoryLayout<pid_t>.size)
            // <sys/un.h>: SOL_LOCAL is 0, LOCAL_PEERPID is 0x002; both are
            // plain integer macros and import into Swift as-is.
            guard getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0, pid > 0 else {
                return nil
            }
            return pid
        }
    }
```

(If the compiler cannot find `SOL_LOCAL`/`LOCAL_PEERPID`, declare them at file scope in `SessionConnection.swift`: `private let SOL_LOCAL: Int32 = 0` and `private let LOCAL_PEERPID: Int32 = 0x002` — the values from `<sys/un.h>`.)

- [ ] **Step 4: Implement the terminator and `terminateDaemon`**

Append to `macos/OmniAgent/DaemonServiceRegistrar.swift`:

```swift
// MARK: - Account switch: ending the running daemon

/// Ends the daemon on the other side of the socket and waits for it to be
/// gone. The one place the app is allowed to end a daemon — and it is only
/// ever reached after the user agreed to (`WorkspaceWindowController.
/// switchAccount`/`logOutOfAccount` ask first whenever sessions would end):
/// "Do not kill the daemon on your choice. Just do it if I allow."
protocol DaemonTerminating {
    /// SIGTERM `pid` (when known — the daemon's own handler shuts every PTY
    /// down and unlinks its socket) and poll `socketURL` until nothing
    /// answers, for at most `timeout`. Completes on the main queue with
    /// whether the socket actually dropped.
    func terminate(pid: pid_t?, socketURL: URL, timeout: TimeInterval, completion: @escaping (Bool) -> Void)
}

final class LiveDaemonTerminator: DaemonTerminating {
    func terminate(pid: pid_t?, socketURL: URL, timeout: TimeInterval, completion: @escaping (Bool) -> Void) {
        if let pid, pid > 0 {
            Darwin.kill(pid, SIGTERM)
        }
        let deadline = Date().addingTimeInterval(timeout)
        DispatchQueue.global(qos: .userInitiated).async {
            var gone = !DaemonSocketProbe.isReachable(at: socketURL)
            while !gone, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.1)
                gone = !DaemonSocketProbe.isReachable(at: socketURL)
            }
            DispatchQueue.main.async { completion(gone) }
        }
    }
}
```

In `macos/OmniAgent/DaemonPersistenceController.swift`:

After `private let socketReachable: () -> Bool` (line 40) add:

```swift
    /// How a daemon is ended for an account switch — the real SIGTERM +
    /// socket poll in production, a recorder in tests.
    private let terminator: DaemonTerminating
```

Replace the designated `init` (lines 49-61) with:

```swift
    init(
        paths: DaemonPaths,
        registrar: DaemonServiceRegistrar,
        processLauncher: DaemonProcessLaunching,
        resolveBinaryPath: @escaping () -> String?,
        socketReachable: @escaping () -> Bool,
        terminator: DaemonTerminating = LiveDaemonTerminator()
    ) {
        self.paths = paths
        self.registrar = registrar
        self.processLauncher = processLauncher
        self.resolveBinaryPath = resolveBinaryPath
        self.socketReachable = socketReachable
        self.terminator = terminator
    }
```

After `start()` (line 109) add:

```swift
    /// Ends the running daemon so the next one reads the account pointer
    /// afresh (2026-08-30 account-scoped-workspace spec, "Account switch"
    /// step 4). `pid` is `SessionConnection.peerProcessID()` — the daemon
    /// this app is attached to, or `nil` when it is not attached to one, in
    /// which case only the wait runs. Once the socket has dropped, launchd's
    /// `KeepAlive` brings a registered service back by itself; in app-owned
    /// mode nothing else would, so `start()` respawns it. The existing
    /// `SessionConnection` reconnect then attaches to whichever came up.
    ///
    /// This is the only method in the daemon-persistence mechanism that
    /// touches the daemon process, and its callers ask the user first
    /// whenever sessions would end — see `DaemonTerminating`.
    func terminateDaemon(pid: pid_t?, completion: @escaping () -> Void) {
        terminator.terminate(pid: pid, socketURL: paths.socketURL, timeout: 5) { [weak self] _ in
            guard let self else {
                completion()
                return
            }
            ownedProcess = nil
            if mode == .appOwned {
                start()
            }
            completion()
        }
    }
```

The convenience `init(paths:)` (lines 66-84) needs no change: the new parameter is defaulted.

- [ ] **Step 5: Run the tests to verify they pass**

Run the Step 2 command.
Expected: `DaemonPersistenceControllerTests` all pass (3 new). Also run `-only-testing:OmniAgentTests/DaemonPersistenceTests` and `-only-testing:OmniAgentTests/SessionConnectionTests` (if that class exists; otherwise skip) — unchanged.

- [ ] **Step 6: Commit**

```bash
git add macos/OmniAgent/SessionConnection.swift macos/OmniAgent/DaemonServiceRegistrar.swift macos/OmniAgent/DaemonPersistenceController.swift macos/OmniAgentTests/DaemonPersistenceControllerTests.swift
git commit -m "feat(macos): peerProcessID() and an injectable terminateDaemon for account switches

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
git push
```

---

### Task 6: Auth gate — no skip path, `.switching`, `.accountReady`, persona survives reset

**Files:**
- Modify: `macos/OmniAgent/AuthGateState.swift:1-130` (doc comment, `AuthGatePhase`, `AuthGateAction`, `AuthGateReducer`)
- Modify: `macos/OmniAgent/AuthGateView.swift:56-71` (`reset`), `:107-137` (`persist`), `:208-215` (`onSwitching`), `:283-294` (`send`), `:623-638` (phase switch), `:873-874` + `:955-964` (skip link), `:1072-1153` (`AuthGateWindowController`)
- Test: `macos/OmniAgentTests/AuthGateStateTests.swift` (rewrite the reducer half), `macos/OmniAgentTests/AuthGateCoordinatorTests.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces: `AuthGatePhase.switching`; `AuthGateAction.accountReady(persona: String?)` (`.skipLogin` removed); `AuthGateViewModel.onSwitching: ((String, @escaping (String?) -> Void) -> Void)?`; `AuthGateWindowController.onSwitching` (same type), `AuthGateWindowController.activeModel: AuthGateViewModel?` (read-only), `AuthGateWindowController.raise()`; `AuthGateCoordinator.reset` leaves `auth_persona` untouched.

- [ ] **Step 1: Write the failing reducer tests**

In `macos/OmniAgentTests/AuthGateStateTests.swift`, replace lines 12-81 (the six reducer tests, from `testSkippingLoginResolvesSignedOutWithNoPersonaAndNoAccount` through `testActionsThatDoNotMatchThePhaseAreIgnored`) with:

```swift
    private var switching: AuthGateState {
        AuthGateReducer.reduce(AuthGateReducer.initial, signedIn)
    }

    func testSigningInMovesToSwitchingCarryingTheAccountWithNoOutcomeYet() {
        XCTAssertEqual(switching, AuthGateState(
            phase: .switching,
            outcome: nil,
            accountEmail: "bruno@bonando.com",
            accountName: "Bruno Bonando",
            githubLogin: "brunobonando",
            accountPicture: "https://cdn.test.invalid/bruno.png"
        ))
    }

    func testANilDisplayNameSurvivesIntoTheSwitchingPhase() {
        let state = AuthGateReducer.reduce(
            AuthGateReducer.initial,
            .signedIn(email: "a@b.com", displayName: nil, githubLogin: nil, picture: nil)
        )
        XCTAssertEqual(state.phase, .switching)
        XCTAssertEqual(state.accountEmail, "a@b.com")
        XCTAssertNil(state.accountName)
        XCTAssertNil(state.githubLogin, "an account with nothing linked carries nothing")
        XCTAssertNil(state.accountPicture, "nor a picture it does not have")
    }

    /// The account already answered the persona question once: it comes back
    /// with the account's data dir, and the gate resolves without asking.
    func testAccountReadyWithAPersonaResolvesSignedInWithoutAskingTheQuestion() {
        let resolved = AuthGateReducer.reduce(switching, .accountReady(persona: "research"))
        XCTAssertEqual(resolved.phase, .resolved)
        XCTAssertEqual(resolved.outcome, AuthGateOutcome(
            signedIn: true,
            persona: "research",
            accountEmail: "bruno@bonando.com",
            accountName: "Bruno Bonando",
            githubLogin: "brunobonando",
            accountPicture: "https://cdn.test.invalid/bruno.png"
        ))
    }

    func testAccountReadyWithoutAPersonaAsksTheQuestion() {
        for persona in [nil, ""] {
            let personalizing = AuthGateReducer.reduce(switching, .accountReady(persona: persona))
            XCTAssertEqual(personalizing.phase, .personalize)
            XCTAssertNil(personalizing.outcome)
            XCTAssertEqual(personalizing.accountEmail, "bruno@bonando.com", "the account rides along")
            XCTAssertEqual(personalizing.accountName, "Bruno Bonando")
        }
    }

    func testAnsweringThePersonaQuestionResolvesSignedInWithThatPersonaAndTheAccount() {
        let personalizing = AuthGateReducer.reduce(switching, .accountReady(persona: nil))
        let resolved = AuthGateReducer.reduce(personalizing, .answerSelected(persona: "student"))
        XCTAssertEqual(resolved.phase, .resolved)
        XCTAssertEqual(resolved.outcome, AuthGateOutcome(
            signedIn: true,
            persona: "student",
            accountEmail: "bruno@bonando.com",
            accountName: "Bruno Bonando",
            githubLogin: "brunobonando",
            accountPicture: "https://cdn.test.invalid/bruno.png"
        ))
    }

    func testSkippingThePersonaQuestionStillResolvesSignedInWithTheAccountAndNoPersona() {
        let personalizing = AuthGateReducer.reduce(switching, .accountReady(persona: nil))
        let resolved = AuthGateReducer.reduce(personalizing, .skipPersonalize)
        XCTAssertEqual(resolved.phase, .resolved)
        XCTAssertEqual(resolved.outcome, AuthGateOutcome(
            signedIn: true,
            persona: nil,
            accountEmail: "bruno@bonando.com",
            accountName: "Bruno Bonando",
            githubLogin: "brunobonando",
            accountPicture: "https://cdn.test.invalid/bruno.png"
        ))
    }

    func testActionsThatDoNotMatchThePhaseAreIgnored() {
        let initial = AuthGateReducer.initial
        XCTAssertEqual(AuthGateReducer.reduce(initial, .accountReady(persona: "student")), initial, "no account to be ready")
        XCTAssertEqual(AuthGateReducer.reduce(initial, .answerSelected(persona: "student")), initial)
        XCTAssertEqual(AuthGateReducer.reduce(initial, .skipPersonalize), initial)

        let switching = self.switching
        XCTAssertEqual(AuthGateReducer.reduce(switching, .answerSelected(persona: "student")), switching, "not asked yet")
        XCTAssertEqual(AuthGateReducer.reduce(switching, .skipPersonalize), switching)
        XCTAssertEqual(AuthGateReducer.reduce(switching, signedIn), switching, "a second sign-in while switching is ignored")

        let personalizing = AuthGateReducer.reduce(switching, .accountReady(persona: nil))
        XCTAssertEqual(AuthGateReducer.reduce(personalizing, .accountReady(persona: "x")), personalizing)
        XCTAssertEqual(AuthGateReducer.reduce(personalizing, signedIn), personalizing)

        let resolved = AuthGateReducer.reduce(switching, .accountReady(persona: "research"))
        XCTAssertEqual(AuthGateReducer.reduce(resolved, signedIn), resolved, "a resolved gate cannot be reopened by another action")
    }

    func testThereIsNoWayThroughTheGateWithoutSigningIn() {
        // Every action that is not `.signedIn` leaves the login phase alone.
        for action: AuthGateAction in [
            .accountReady(persona: nil), .accountReady(persona: "research"),
            .answerSelected(persona: "research"), .skipPersonalize,
        ] {
            XCTAssertEqual(AuthGateReducer.reduce(AuthGateReducer.initial, action).phase, .login)
        }
    }
```

- [ ] **Step 2: Write the failing coordinator / view-model / window tests**

In `macos/OmniAgentTests/AuthGateCoordinatorTests.swift`:

1. Replace `testResetClearsAllSevenKeysToTheSignedOutUnresolvedShape` (lines 120-139) with:

```swift
    /// Log-out clears the mirror, the gate flags and the account identity —
    /// but **not** the persona: it belongs to the account and comes back
    /// with the account's data dir the next time it signs in (2026-08-30
    /// spec, "Logout" step 3).
    func testResetClearsTheAccountRowsButKeepsThePersona() {
        let client = FakeSettingsClient(rows: [
            "auth_gate_resolved": "true", "auth_signed_in": "true", "auth_persona": "student",
            "auth_account_email": "bruno@bonando.com", "auth_account_name": "Bruno Bonando",
            "auth_github_login": "brunobonando", "auth_account_picture": "https://cdn.test.invalid/bruno.png",
        ])
        let coordinator = AuthGateCoordinator(settings: SettingsStore(client: client))

        let expectation = expectation(description: "reset")
        coordinator.reset { expectation.fulfill() }
        wait(for: [expectation], timeout: 1)

        XCTAssertEqual(client.rows["auth_gate_resolved"], "false")
        XCTAssertEqual(client.rows["auth_signed_in"], "false")
        XCTAssertEqual(client.rows["auth_persona"], "student", "the persona is the account's, not the session's")
        XCTAssertFalse(client.setCalls.contains { $0.key == "auth_persona" }, "and is not even rewritten")
        XCTAssertEqual(client.rows["auth_account_email"], "")
        XCTAssertEqual(client.rows["auth_account_name"], "")
        XCTAssertEqual(client.rows["auth_github_login"], "", "a log-out unlinks GitHub locally too")
        XCTAssertEqual(client.rows["auth_account_picture"], "", "and takes the avatar with it")
    }
```

2. Delete `testSendingSkipLoginResolvesAndInvokesOnResolvedExactlyOnce` (lines 336-349) and `testOnSignedInNeverFiresForSkipLogin` (lines 429-437).

3. In `testOnSignedInFiresOnceRightAwayNotAfterThePersonaStep`, after the line `XCTAssertTrue(outcomes.isEmpty, "onResolved still waits for the persona step")` add:

```swift
        XCTAssertEqual(model.state.phase, .personalize, "no switch hook wired: the account has no persona on record, so the question is asked")
```

4. After that test add:

```swift
    /// The window controller wires `onSwitching` to the account switch: the
    /// hook gets the account's email, does its work (the pointer write, the
    /// daemon restart), and answers with the persona the account's own data
    /// dir holds. A persona means no question; the gate resolves on it.
    @MainActor
    func testTheSwitchHookGetsTheEmailAndAPersonaItReportsSkipsTheQuestion() async {
        let stub = StubAuthSigning(result: .success(user()))
        let model = AuthGateViewModel(signer: stub)
        let pkce = model.pkce
        var handedEmail: String?
        var signedInFired = 0
        var outcomes: [AuthGateOutcome] = []
        model.onSignedIn = { signedInFired += 1 }
        model.onResolved = { outcomes.append($0) }
        model.onSwitching = { email, ready in
            handedEmail = email
            ready("research")
        }

        await model.handleCallback(callback(code: "one-time-code", state: pkce.state))

        XCTAssertEqual(handedEmail, "bruno@bonando.com")
        XCTAssertEqual(signedInFired, 1, "marked signed in before the switch, so a quit mid-switch does not ask again")
        XCTAssertEqual(model.state.phase, .resolved)
        XCTAssertEqual(outcomes.map(\.persona), ["research"])
    }

    /// The card between sign-in and the workspace: a hook that answers later
    /// leaves the model in `.switching` until it does.
    @MainActor
    func testTheGateStaysOnTheSwitchingCardUntilTheHookAnswers() async {
        let model = AuthGateViewModel(signer: StubAuthSigning(result: .success(user())))
        let pkce = model.pkce
        var answer: ((String?) -> Void)?
        model.onSwitching = { _, ready in answer = ready }

        await model.handleCallback(callback(code: "one-time-code", state: pkce.state))
        XCTAssertEqual(model.state.phase, .switching)

        answer?(nil)
        XCTAssertEqual(model.state.phase, .personalize, "no persona on record: ask")
    }
```

5. In `AuthGateWindowTests` (end of file), add before `presentLaunchWindow`:

```swift
    /// The controller passes the hook through to the model it builds and
    /// exposes that model, so the window's switch can be driven end to end
    /// without a browser: sign in → hook → persona → resolved → dismissed.
    @MainActor
    func testPresentHandsTheSwitchHookTheEmailAndResolvesOnItsAnswer() throws {
        let client = FakeSettingsClient()
        let controller = AuthGateWindowController(
            coordinator: AuthGateCoordinator(settings: SettingsStore(client: client), defaults: try throwawayDefaults())
        )
        var handedEmail: String?
        controller.onSwitching = { email, ready in
            handedEmail = email
            ready("research")
        }
        var completed = 0
        controller.present(over: nil) { completed += 1 }
        let window = try XCTUnwrap(controller.sheetWindow)
        addTeardownBlock { @MainActor in window.orderOut(nil) }
        let model = try XCTUnwrap(controller.activeModel)

        model.send(.signedIn(email: "bruno@bonando.com", displayName: "Bruno Bonando", githubLogin: nil, picture: nil))

        XCTAssertEqual(handedEmail, "bruno@bonando.com")
        XCTAssertEqual(completed, 1)
        XCTAssertNil(controller.activeModel, "resolved and dismissed")
        XCTAssertNil(controller.sheetWindow)
        XCTAssertEqual(client.rows["auth_signed_in"], "true")
        XCTAssertEqual(client.rows["auth_persona"], "research")
    }

    private func throwawayDefaults() throws -> UserDefaults {
        let name = "digital.bruno.omniagent.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        return defaults
    }
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `caffeinate -disu xcodebuild test -project macos/OmniAgent.xcodeproj -scheme OmniAgent -destination "platform=macOS,arch=arm64" CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64 -only-testing:OmniAgentTests/AuthGateStateTests -only-testing:OmniAgentTests/AuthGateCoordinatorTests -only-testing:OmniAgentTests/AuthGateViewModelTests -only-testing:OmniAgentTests/AuthGateWindowTests`
Expected: build fails — `type 'AuthGatePhase' has no member 'switching'`, `type 'AuthGateAction' has no member 'accountReady'`, `value of type 'AuthGateViewModel' has no member 'onSwitching'`, `has no member 'activeModel'`.

- [ ] **Step 4: Rewrite the reducer**

Replace `macos/OmniAgent/AuthGateState.swift:1-130` (everything above `struct PersonaOption`) with:

```swift
import Foundation

/// The sign-in + "getting to know you" gate's pure state — originally a
/// direct port of `ui/src/onboarding/authGateState.ts`, kept as a pure
/// reducer so the phase transitions are unit-testable without
/// `AuthGateView`/`NSHostingController`/a socket/a network.
///
/// The login is real: `AuthGateViewModel` runs Apple's or GitHub's web
/// sign-in and redeems the result at Core's `/v1/auth/<provider>/exchange`
/// through `AuthClient`, and only dispatches `.signedIn` after the server
/// said yes. There is no way through without it (2026-08-30 account-scoped
/// workspace spec: "It's not allowed anymore to use the app without being
/// logged on") — the "Continue without signing in" escape hatch is gone.
///
/// Between sign-in and the persona question sits `.switching`: the window
/// controller moves the daemon onto the account's own data directory, then
/// reports what that directory already knows (`.accountReady`). An account
/// that answered the persona question before is not asked again.
enum AuthGatePhase: Equatable {
    case login
    /// "Opening your workspace…" — the account switch is running.
    case switching
    case personalize
    case resolved
}

struct AuthGateOutcome: Equatable {
    /// Always `true` for an outcome the gate produces now; kept because the
    /// Settings screen and `AuthGateCoordinator.persist` read it, and it is
    /// the field a log-out writes `false` through.
    let signedIn: Bool
    /// The selected `PersonaOption.id`, or `nil` if the personalization
    /// question was skipped.
    let persona: String?
    /// The Core account's email address.
    let accountEmail: String?
    /// The account's display name ("Bruno Bonando"), or `nil` when the
    /// server has none for it.
    let accountName: String?
    /// The GitHub handle linked to the account, or `nil` when none is.
    /// Defaulted, and the one `var` here, so the constructions that have
    /// nothing to say about GitHub stay about what they are testing;
    /// `AuthGateState.accountEmail` below sets the same precedent.
    var githubLogin: String? = nil
    /// The account's profile-picture URL, or `nil` when it has none.
    /// Defaulted for `githubLogin`'s reason.
    var accountPicture: String? = nil
}

struct AuthGateState: Equatable {
    var phase: AuthGatePhase
    /// Non-nil exactly when `phase == .resolved`.
    var outcome: AuthGateOutcome?
    /// The signed-in identity, carried from `.signedIn` through the
    /// switching and personalize phases into the outcome.
    var accountEmail: String? = nil
    var accountName: String? = nil
    var githubLogin: String? = nil
    var accountPicture: String? = nil
}

enum AuthGateAction: Equatable {
    /// A *successful* real login — `AuthGateViewModel` dispatches this only
    /// after `AuthClient` returned a user; the reducer never sees a failed
    /// attempt (that stays view-model state as `errorMessage`).
    case signedIn(email: String, displayName: String?, githubLogin: String?, picture: String?)
    /// The account switch finished and the account's data dir was read:
    /// `persona` is its `auth_persona` row, `nil`/empty when it never
    /// answered. Dispatched by `AuthGateViewModel` from the `onSwitching`
    /// hook's answer.
    case accountReady(persona: String?)
    case answerSelected(persona: String)
    case skipPersonalize
}

enum AuthGateReducer {
    static let initial = AuthGateState(phase: .login, outcome: nil)

    static func reduce(_ state: AuthGateState, _ action: AuthGateAction) -> AuthGateState {
        switch action {
        case let .signedIn(email, displayName, githubLogin, picture):
            guard state.phase == .login else { return state }
            return AuthGateState(
                phase: .switching,
                outcome: nil,
                accountEmail: email,
                accountName: displayName,
                githubLogin: githubLogin,
                accountPicture: picture
            )

        case let .accountReady(persona):
            guard state.phase == .switching else { return state }
            if let persona, !persona.isEmpty {
                return resolved(state, persona: persona)
            }
            return AuthGateState(
                phase: .personalize,
                outcome: nil,
                accountEmail: state.accountEmail,
                accountName: state.accountName,
                githubLogin: state.githubLogin,
                accountPicture: state.accountPicture
            )

        case let .answerSelected(persona):
            guard state.phase == .personalize else { return state }
            return resolved(state, persona: persona)

        case .skipPersonalize:
            guard state.phase == .personalize else { return state }
            return resolved(state, persona: nil)
        }
    }

    private static func resolved(_ state: AuthGateState, persona: String?) -> AuthGateState {
        AuthGateState(
            phase: .resolved,
            outcome: AuthGateOutcome(
                signedIn: true,
                persona: persona,
                accountEmail: state.accountEmail,
                accountName: state.accountName,
                githubLogin: state.githubLogin,
                accountPicture: state.accountPicture
            ),
            accountEmail: state.accountEmail,
            accountName: state.accountName,
            githubLogin: state.githubLogin,
            accountPicture: state.accountPicture
        )
    }
}
```

Also in the same file, `AuthGate.needsSignIn`'s doc comment (lines 168-172) mentions "Continue without signing in"; replace those five lines with:

```swift
    /// The gate latches on *signed in*: only a real sign-in puts it away,
    /// and a log-out brings it back — a login screen, not a first-run one.
```

- [ ] **Step 5: Keep the persona on `reset`, and add the switching hook to the view model**

In `macos/OmniAgent/AuthGateView.swift`:

1. Replace `reset` (lines 56-71) with:

```swift
    /// "Log out" from the Settings screen's Account section — clears the
    /// mirror, the gate flags and the account identity rows so the gate
    /// shows again. **`auth_persona` is deliberately left alone**: it is the
    /// account's answer, lives in the account's own data dir, and comes back
    /// with it (2026-08-30 spec, "Logout" step 3).
    func reset(completion: @escaping () -> Void) {
        persist(
            resolved: "false",
            signedIn: "false",
            persona: nil,
            accountEmail: "",
            accountName: "",
            githubLogin: "",
            accountPicture: "",
            completion: completion
        )
    }
```

2. Replace `persist` (lines 101-137) with:

```swift
    /// Chained rather than fired in parallel behind a `DispatchGroup`, for
    /// the same reason `summary` chains its reads: `DispatchGroup.notify`
    /// always hops a queue turn, even against a synchronous fake client,
    /// which would make `completion` land a run-loop turn later than every
    /// write actually finished. Seven tiny writes in sequence costs nothing
    /// a user would notice. `persona: nil` leaves that row untouched — the
    /// log-out path.
    private func persist(
        resolved: String,
        signedIn: String,
        persona: String?,
        accountEmail: String,
        accountName: String,
        githubLogin: String,
        accountPicture: String,
        completion: @escaping () -> Void
    ) {
        // Written first and synchronously: this is the only copy the launch
        // decision can read, and it must be true before the workspace window
        // it gates is allowed on screen. The rows below stay the source of
        // truth for everything the Settings screen shows.
        defaults.set(signedIn == "true", forKey: AuthGate.signedInDefaultsKey)
        let settings = settings
        settings.set(SettingsKey.authGateResolved, resolved) { _ in
            settings.set(SettingsKey.authSignedIn, signedIn) { _ in
                let afterPersona = {
                    settings.set(SettingsKey.authAccountEmail, accountEmail) { _ in
                        settings.set(SettingsKey.authAccountName, accountName) { _ in
                            settings.set(SettingsKey.authGithubLogin, githubLogin) { _ in
                                settings.set(SettingsKey.authAccountPicture, accountPicture) { _ in
                                    completion()
                                }
                            }
                        }
                    }
                }
                if let persona {
                    settings.set(SettingsKey.authPersona, persona) { _ in afterPersona() }
                } else {
                    afterPersona()
                }
            }
        }
    }
```

3. In `AuthGateViewModel`, after `var onSignedIn: (() -> Void)?` (line 215) add:

```swift
    /// The account switch. Fired once when a sign-in succeeds — `.login`
    /// moving to `.switching` — with the account's email; the hook does the
    /// switch and answers with the persona the account's own data dir holds
    /// (`auth_persona`, or `nil`), which this model dispatches as
    /// `.accountReady`. `AuthGateWindowController` wires it to
    /// `WorkspaceWindowController.switchAccount`. Unset, the switch is a
    /// no-op and the persona question is asked, as it always was.
    var onSwitching: ((String, @escaping (String?) -> Void) -> Void)?
```

4. Replace `send` (lines 283-294) with:

```swift
    func send(_ action: AuthGateAction) {
        let wasLogin = state.phase == .login
        state = AuthGateReducer.reduce(state, action)
        if state.phase == .resolved, let outcome = state.outcome {
            onResolved?(outcome)
            return
        }
        // Only a successful `.signedIn` moves `.login` to `.switching` —
        // see `markSignedIn`. The hook's answer comes back through `send`
        // again, so it is called last: nothing here runs after it.
        guard wasLogin, state.phase == .switching else { return }
        onSignedIn?()
        let ready: (String?) -> Void = { [weak self] persona in
            self?.send(.accountReady(persona: persona))
        }
        if let onSwitching {
            onSwitching(state.accountEmail ?? "", ready)
        } else {
            ready(nil)
        }
    }
```

- [ ] **Step 6: The switching card, no skip link**

In `AuthGateContentView`:

1. Replace the phase switch (lines 625-634) with:

```swift
            switch model.state.phase {
            case .login:
                signInScreen
            case .switching:
                switchingScreen
            case .personalize:
                personalizeScreen
                    .frame(width: 420)
                    .padding(28)
            case .resolved:
                Color.clear.frame(width: 420, height: 240)
            }
```

2. Delete the two lines `skipLink` / `.padding(.top, 16)` (873-874) inside `authCard`, and the whole `skipLink` property with its doc comment (lines 955-964).

3. After `personalizeScreen` (before the closing `}` of `AuthGateContentView`) add:

```swift
    // MARK: - Switching (between sign-in and the workspace)

    /// While `WorkspaceWindowController.switchAccount` moves the daemon onto
    /// the account's data directory. Static on purpose — see the type
    /// comment's animation policy.
    private var switchingScreen: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
                .tint(SignInPalette.periwinkle)
            Text("Opening your workspace…")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(SignInPalette.titleText)
        }
        .frame(width: Self.sheetSize.width, height: Self.sheetSize.height)
        .background(SignInPalette.screenBackground)
    }
```

- [ ] **Step 7: The window controller's hook, model and `raise()`**

Replace `AuthGateWindowController` (lines 1072-1153) with:

```swift
/// Hosts `AuthGateContentView`. Two shapes, one flow: `over: nil` is the
/// login window at launch, standing on its own with nothing behind it; a
/// window makes it a sheet on that window — the native shape of the web's
/// `overlay-backdrop`, which the Settings screen's "Sign in" row uses.
final class AuthGateWindowController {
    private let coordinator: AuthGateCoordinator
    /// The gate's window. Readable so a test can measure the real thing —
    /// where it opens and how big it is *is* the launch shape.
    private(set) var sheetWindow: NSWindow?
    /// The model behind the window while one is up — readable so a test can
    /// drive the gate without a browser (`AuthGateWindowTests`).
    private(set) var activeModel: AuthGateViewModel?
    /// The account switch, passed through to every model this presents —
    /// `AuthGateViewModel.onSwitching`'s contract. Set once by
    /// `WorkspaceWindowController`.
    var onSwitching: ((String, @escaping (String?) -> Void) -> Void)?

    init(coordinator: AuthGateCoordinator) {
        self.coordinator = coordinator
    }

    /// Shows the gate — the Settings screen's Account section "Sign in" row
    /// re-runs the same flow rather than a second one.
    func present(over window: NSWindow?, completion: (() -> Void)? = nil) {
        let model = AuthGateViewModel()
        model.onSignedIn = { [weak self] in self?.coordinator.markSignedIn() }
        model.onSwitching = { [weak self] email, ready in
            guard let self, let onSwitching else {
                ready(nil)
                return
            }
            onSwitching(email, ready)
        }
        model.onResolved = { [weak self] outcome in
            guard let self else { return }
            coordinator.resolve(outcome) { [weak self] in
                self?.dismiss()
                completion?()
            }
        }
        // One size for every phase. `NSHostingController` sizes the window
        // from whatever the view currently prefers, so left alone the window
        // would shrink to the personalize card's 420pt mid-flow — and, since
        // a resize holds the top-left corner, walk out of the centre it
        // opened in. The phases lay themselves out inside a fixed screen.
        let hosting = NSHostingController(
            rootView: AuthGateContentView(model: model)
                .frame(width: AuthGateContentView.sheetSize.width, height: AuthGateContentView.sheetSize.height)
        )
        // Edge to edge. `fullSizeContentView` runs the content view under the
        // title bar, but SwiftUI still insets its layout by that safe area,
        // which left the window's own grey painting a band across the top of
        // the screen. Nothing on this screen wants a safe area.
        hosting.safeAreaRegions = []
        let sheet = NSWindow(contentViewController: hosting)
        sheet.styleMask = [.titled, .fullSizeContentView]
        sheet.titlebarAppearsTransparent = true
        sheet.titleVisibility = .hidden
        sheet.isReleasedWhenClosed = false
        // What shows behind the window's own rounded corners, and for the
        // instant before SwiftUI's first paint: the screen's colour rather
        // than the system window grey.
        sheet.backgroundColor = NSColor(SignInPalette.screenBackground)
        // Apple's web sign-in browser sheet anchors to this window itself.
        model.presentationWindow = { [weak sheet] in sheet }
        sheetWindow = sheet
        activeModel = model
        if let window {
            window.beginSheet(sheet)
        } else {
            centerOnScreen(sheet)
            sheet.makeKeyAndOrderFront(nil)
        }
    }

    /// Brings a standing login window back to the front — what the Dock's
    /// reopen and `WorkspaceWindowController.showWindow` do while nobody is
    /// signed in, instead of showing the workspace.
    func raise() {
        guard let sheetWindow, sheetWindow.sheetParent == nil else { return }
        sheetWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Puts the launch window at the middle of the screen — and does it
    /// without `NSWindow.center()`, which is wrong here twice over: it biases
    /// the window above centre by design, and it places whatever size the
    /// window has *at that moment*, which is before SwiftUI has reported
    /// one. That is what parked the login screen in the top-right quadrant.
    private func centerOnScreen(_ window: NSWindow) {
        window.setContentSize(AuthGateContentView.sheetSize)
        guard let screen = window.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = window.frame.size
        window.setFrameOrigin(NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2
        ))
    }

    private func dismiss() {
        guard let sheet = sheetWindow else { return }
        if let parent = sheet.sheetParent {
            parent.endSheet(sheet)
        } else {
            sheet.orderOut(nil)
        }
        sheetWindow = nil
        activeModel = nil
    }
}
```

- [ ] **Step 8: Run the tests to verify they pass**

Run the Step 3 command.
Expected: all four classes pass. Then build the whole app target once to catch any remaining `.skipLogin` reference: `caffeinate -disu ./macos/build.sh build` — expected: succeeds (the only other `.skipLogin` use was the deleted skip link).

- [ ] **Step 9: Commit**

```bash
git add macos/OmniAgent/AuthGateState.swift macos/OmniAgent/AuthGateView.swift macos/OmniAgentTests/AuthGateStateTests.swift macos/OmniAgentTests/AuthGateCoordinatorTests.swift
git commit -m "feat(macos): sign-in is mandatory; the gate switches accounts before the persona step

Removes the skip path, adds the .switching phase and .accountReady, hands
the account switch to a hook on the gate window, and keeps auth_persona
across a log-out.

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
git push
```

---

### Task 7: `WorkspaceWindowController.switchAccount` and the sign-in / launch wiring

**Files:**
- Modify: `macos/OmniAgent/WorkspaceWindowController.swift` — properties (after line 424 `var serverSessionRevoker`), `init` (line 477-493 and after `super.init(window: window)` at 577), `start()`'s `.connected` arm (1342-1355), `applyRestoredPanes` (3040-3073), `presentLaunchGate` (4656-4670), `authGateDidResolve` (4701-4706), `seedAccountFromMirror` (4723-4733), `refreshAccountSection` (4796-4832); new methods in a `// MARK: - Account switch` section placed right after `presentOnboardingIfNeeded` (5013-5017)
- Test: `macos/OmniAgentTests/WorkspaceWindowControllerTests.swift` (new tests + one new helper next to `makeEmptyController` at 2526)

**Interfaces:**
- Consumes: `AccountDirectory` (Task 4); `DaemonPersistenceController.terminateDaemon(pid:completion:)`, `SessionConnection.peerProcessID()` (Task 5); `AuthGateWindowController.onSwitching`/`activeModel` (Task 6); existing `presentWindowAsk`, `menuBarSummary()`, `PaneWorkspaceView.closePane(_:)`.
- Produces on `WorkspaceWindowController`: `init(connection:panes:notifier:daemonPersistence:remoteMachines:settingsClient:authDefaults:)` (new trailing `authDefaults: UserDefaults = .standard`); `var accountRoot: URL`; `private(set) var currentAccountID: String?`; `var daemonTerminator: ((@escaping () -> Void) -> Void)?`; `var onSignedInStateChanged: ((Bool) -> Void)?`; `private(set) var awaitingSignIn: Bool`; `private(set) var accountDisplayLabel: String`; `var launchGateModel: AuthGateViewModel?`; `func switchAccount(toEmail: String, completion: @escaping () -> Void)`; `func resetForAccountSwitch()`; `func runWhenConnected(_ body: @escaping () -> Void)`; `static func runningSessionsPhrase(_ count: Int) -> String`. Task 8 uses `awaitingSignIn`, `accountRoot`, `daemonTerminator`, `resetForAccountSwitch`, `onSignedInStateChanged`; Task 9 uses `accountDisplayLabel`, `onSignedInStateChanged`.

- [ ] **Step 1: Write the failing tests**

In `macos/OmniAgentTests/WorkspaceWindowControllerTests.swift`, next to `makeEmptyController()` (line 2526) add:

```swift
    /// An empty window whose settings rows and launch mirror are both
    /// throwaway — the shape every account-switch test wants: nothing on
    /// screen to end, nothing of the developer's touched.
    private func makeEmptyController(
        settingsClient: SettingsClient,
        defaults: UserDefaults
    ) -> WorkspaceWindowController {
        WorkspaceWindowController(
            connection: SessionConnection(
                socketURL: URL(fileURLWithPath: "/tmp/omniagent-controller-test.sock")
            ),
            panes: [],
            settingsClient: settingsClient,
            authDefaults: defaults
        )
    }

    /// A data root of this test's own, removed after: the pointer file the
    /// switch writes must never land in the developer's real
    /// `~/Library/Application Support/OmniAgent-ADE`.
    private func temporaryAccountRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("omniagent-account-root-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    /// The ask's button by title, pressed — `PaneAskOverlayView` draws its
    /// options as `PaneApprovalButton`s.
    private func press(_ title: String, on overlay: PaneAskOverlayView) {
        let button = overlay.subviews.compactMap { $0 as? PaneApprovalButton }.first { $0.title == title }
        XCTAssertNotNil(button, "no \"\(title)\" button on the ask")
        button?.onClick?()
    }
```

Add these tests (anywhere in the class, e.g. after `testTheWorkspaceWindowWaitsBehindTheLaunchGate`):

```swift
    // MARK: - Account switch (2026-08-30 account-scoped workspace spec)

    func testRunningSessionsPhrasePluralizes() {
        XCTAssertEqual(WorkspaceWindowController.runningSessionsPhrase(1), "1 running session")
        XCTAssertEqual(WorkspaceWindowController.runningSessionsPhrase(3), "3 running sessions")
    }

    /// Nothing running: the pointer is written and the daemon restarted with
    /// no question asked — the ordinary post-logout sign-in.
    func testSwitchAccountWritesThePointerAndRestartsTheDaemonWhenNothingIsRunning() throws {
        let controller = makeEmptyController(settingsClient: FakeSettingsClient(), defaults: try throwawayDefaults())
        defer { controller.close() }
        let root = try temporaryAccountRoot()
        controller.accountRoot = root
        XCTAssertNil(controller.currentAccountID)
        var terminated = 0
        controller.daemonTerminator = { done in
            terminated += 1
            done()
        }

        var completed = 0
        controller.switchAccount(toEmail: "Bruno@Bonando.com ") { completed += 1 }

        XCTAssertNil(controller.windowAskOverlay, "no sessions to end, nothing to ask")
        XCTAssertEqual(AccountDirectory.readCurrentAccount(root: root), "fc44b18d5588b1d6")
        XCTAssertEqual(controller.currentAccountID, "fc44b18d5588b1d6")
        XCTAssertEqual(terminated, 1)
        XCTAssertEqual(completed, 1)
    }

    /// The pointer already names this account: the running daemon is already
    /// serving it, so there is nothing to restart.
    func testSwitchAccountLeavesTheDaemonAloneWhenThePointerAlreadyNamesTheAccount() throws {
        let controller = makeEmptyController(settingsClient: FakeSettingsClient(), defaults: try throwawayDefaults())
        defer { controller.close() }
        let root = try temporaryAccountRoot()
        try AccountDirectory.writeCurrentAccount("fc44b18d5588b1d6", root: root)
        controller.accountRoot = root
        XCTAssertEqual(controller.currentAccountID, "fc44b18d5588b1d6", "read when the root is set")
        var terminated = 0
        controller.daemonTerminator = { done in
            terminated += 1
            done()
        }

        var completed = 0
        controller.switchAccount(toEmail: "bruno@bonando.com") { completed += 1 }

        XCTAssertEqual(terminated, 0, "same account: the daemon is already on its directory")
        XCTAssertEqual(completed, 1)
        XCTAssertEqual(AccountDirectory.readCurrentAccount(root: root), "fc44b18d5588b1d6")
    }

    /// Sessions are running (the legacy daemon on first upgrade): the house
    /// modal asks first, and "Not now" leaves no pointer behind, keeps the
    /// panes, and still completes — signed in on the current daemon.
    func testSwitchAccountAsksWhenSessionsAreRunningAndNotNowLeavesEverythingAsItWas() throws {
        let controller = makeController(settingsClient: FakeSettingsClient())
        defer { controller.close() }
        XCTAssertEqual(controller.menuBarSummary().sessionCount, 1)
        let root = try temporaryAccountRoot()
        controller.accountRoot = root
        var terminated = 0
        controller.daemonTerminator = { done in
            terminated += 1
            done()
        }

        var completed = 0
        controller.switchAccount(toEmail: "bruno@bonando.com") { completed += 1 }

        let ask = try XCTUnwrap(controller.windowAskOverlay, "a running session means asking first")
        XCTAssertEqual(ask.options.map(\.title), ["Not now", "Restart now"])
        XCTAssertEqual(completed, 0, "nothing decided yet")
        XCTAssertEqual(terminated, 0, "and the daemon is untouched while the question is up")

        press("Not now", on: ask)

        XCTAssertNil(controller.windowAskOverlay)
        XCTAssertNil(AccountDirectory.readCurrentAccount(root: root), "no pointer: asked again next launch")
        XCTAssertNil(controller.currentAccountID)
        XCTAssertEqual(terminated, 0)
        XCTAssertEqual(controller.workspaceView.allPaneIDs.count, 1, "the workspace keeps working on the current daemon")
        XCTAssertEqual(completed, 1, "and the sign-in completes anyway")
    }

    func testSwitchAccountRestartNowWritesThePointerEndsTheDaemonAndDropsThePanes() throws {
        let client = FakeSettingsClient()
        let controller = makeController(settingsClient: client)
        defer { controller.close() }
        let root = try temporaryAccountRoot()
        controller.accountRoot = root
        var terminated = 0
        controller.daemonTerminator = { done in
            terminated += 1
            done()
        }

        var completed = 0
        controller.switchAccount(toEmail: "bruno@bonando.com") { completed += 1 }
        press("Restart now", on: try XCTUnwrap(controller.windowAskOverlay))

        XCTAssertEqual(AccountDirectory.readCurrentAccount(root: root), "fc44b18d5588b1d6")
        XCTAssertEqual(controller.currentAccountID, "fc44b18d5588b1d6")
        XCTAssertEqual(terminated, 1)
        XCTAssertEqual(completed, 1)
        XCTAssertEqual(controller.workspaceView.allPaneIDs, [], "the old daemon's panes are gone")
        XCTAssertEqual(controller.menuBarSummary().sessionCount, 0)
        XCTAssertFalse(
            client.setCalls.contains { $0.key == SettingsKey.layout },
            "dropped without persisting: the account's own layout row must not be overwritten with an empty one"
        )
    }

    /// The first launch of this build over data written before accounts
    /// existed: the mirror says signed in but no pointer is on disk. The
    /// adoption waits until the layout is back on screen — so the running
    /// sessions it would end can be counted — then asks.
    func testALaunchWithTheMirrorTrueButNoPointerOffersTheAdoptionOnceTheLayoutIsRestored() throws {
        let defaults = try throwawayDefaults()
        defaults.set(true, forKey: AuthGate.signedInDefaultsKey)
        let client = FakeSettingsClient(rows: [
            "auth_signed_in": "true", "auth_account_email": "bruno@bonando.com", "auth_account_name": "Bruno Bonando",
        ])
        let controller = makeEmptyController(settingsClient: client, defaults: defaults)
        defer { controller.close() }
        let root = try temporaryAccountRoot()
        controller.accountRoot = root
        controller.sessionRestorer = {}
        controller.sessionEnsurer = { _ in }
        controller.daemonTerminator = { $0() }

        var revealed = 0
        controller.presentLaunchGate(defaults: defaults) { revealed += 1 }
        XCTAssertEqual(revealed, 1, "signed in: straight in, as before")
        XCTAssertNil(controller.windowAskOverlay, "nothing to count yet")

        controller.applyRestoredPanes([WorkspaceRestoration.bootstrapPane(sessionID: "legacy-1")])

        let ask = try XCTUnwrap(controller.windowAskOverlay, "the layout is on screen: now the sessions can be counted")
        XCTAssertEqual(ask.options.map(\.title), ["Not now", "Restart now"])
        press("Not now", on: ask)
        XCTAssertNil(AccountDirectory.readCurrentAccount(root: root))
    }

    func testALaunchWithThePointerAlreadyOnDiskNeverAsks() throws {
        let defaults = try throwawayDefaults()
        defaults.set(true, forKey: AuthGate.signedInDefaultsKey)
        let client = FakeSettingsClient(rows: ["auth_signed_in": "true", "auth_account_email": "bruno@bonando.com"])
        let controller = makeEmptyController(settingsClient: client, defaults: defaults)
        defer { controller.close() }
        let root = try temporaryAccountRoot()
        try AccountDirectory.writeCurrentAccount("fc44b18d5588b1d6", root: root)
        controller.accountRoot = root
        controller.sessionRestorer = {}
        controller.sessionEnsurer = { _ in }
        var terminated = 0
        controller.daemonTerminator = { done in
            terminated += 1
            done()
        }

        controller.presentLaunchGate(defaults: defaults) {}
        controller.applyRestoredPanes([WorkspaceRestoration.bootstrapPane(sessionID: "s1")])

        XCTAssertNil(controller.windowAskOverlay)
        XCTAssertEqual(terminated, 0, "the daemon is already on the account's directory")
    }

    /// Signing in end to end without a browser: the gate hands the email to
    /// the switch, the switch restarts the daemon, the account's persona is
    /// read once the new daemon is up, and the gate resolves on it without
    /// asking the persona question.
    func testSigningInRunsTheSwitchAndSkipsThePersonaQuestionTheAccountAlreadyAnswered() throws {
        let strangers = Set(NSApp.windows.map(ObjectIdentifier.init))
        addTeardownBlock {
            for window in NSApp.windows where !strangers.contains(ObjectIdentifier(window)) {
                window.orderOut(nil)
            }
        }
        let defaults = try throwawayDefaults()
        let client = FakeSettingsClient(rows: ["auth_persona": "research"])
        let controller = makeEmptyController(settingsClient: client, defaults: defaults)
        defer { controller.close() }
        let root = try temporaryAccountRoot()
        controller.accountRoot = root
        var terminated = 0
        controller.daemonTerminator = { done in
            terminated += 1
            done()
        }
        var signedInStates: [Bool] = []
        controller.onSignedInStateChanged = { signedInStates.append($0) }

        controller.start()
        var revealed = 0
        controller.presentLaunchGate(defaults: defaults) { revealed += 1 }
        let model = try XCTUnwrap(controller.launchGateModel, "the login window is up")

        model.send(.signedIn(email: "bruno@bonando.com", displayName: "Bruno Bonando", githubLogin: nil, picture: nil))

        XCTAssertEqual(AccountDirectory.readCurrentAccount(root: root), "fc44b18d5588b1d6")
        XCTAssertEqual(terminated, 1)
        XCTAssertEqual(model.state.phase, .switching, "the persona is read from the *new* daemon, so the card waits for it")
        XCTAssertEqual(revealed, 0)

        // The restarted daemon comes up.
        controller.connection.onStateChange?(.connected)

        XCTAssertEqual(revealed, 1, "resolved without a persona question: the account answered it before")
        XCTAssertNil(controller.launchGateModel, "and the login window is gone")
        XCTAssertEqual(client.rows["auth_signed_in"], "true")
        XCTAssertEqual(client.rows["auth_persona"], "research")
        XCTAssertEqual(signedInStates, [true])
        XCTAssertFalse(controller.awaitingSignIn)
    }

    func testTheAccountLabelIsTheNameFallingBackToTheEmail() throws {
        let named = makeEmptyController(
            settingsClient: FakeSettingsClient(rows: [
                "auth_signed_in": "true", "auth_account_email": "bruno@bonando.com", "auth_account_name": "Bruno Bonando",
            ]),
            defaults: try throwawayDefaults()
        )
        defer { named.close() }
        named.refreshAccountSection()
        XCTAssertEqual(named.accountDisplayLabel, "Bruno Bonando")

        let nameless = makeEmptyController(
            settingsClient: FakeSettingsClient(rows: ["auth_signed_in": "true", "auth_account_email": "bruno@bonando.com"]),
            defaults: try throwawayDefaults()
        )
        defer { nameless.close() }
        nameless.refreshAccountSection()
        XCTAssertEqual(nameless.accountDisplayLabel, "bruno@bonando.com")

        let signedOut = makeEmptyController(
            settingsClient: FakeSettingsClient(rows: ["auth_signed_in": "false", "auth_account_email": "bruno@bonando.com"]),
            defaults: try throwawayDefaults()
        )
        defer { signedOut.close() }
        signedOut.refreshAccountSection()
        XCTAssertEqual(signedOut.accountDisplayLabel, "")
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `caffeinate -disu xcodebuild test -project macos/OmniAgent.xcodeproj -scheme OmniAgent -destination "platform=macOS,arch=arm64" CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64 -only-testing:OmniAgentTests/WorkspaceWindowControllerTests`
Expected: build fails — `extra argument 'authDefaults' in call`, `has no member 'accountRoot'`, `'switchAccount'`, `'daemonTerminator'`, `'runningSessionsPhrase'`, `'launchGateModel'`, `'accountDisplayLabel'`, `'onSignedInStateChanged'`, `'awaitingSignIn'`.

- [ ] **Step 3: Properties and init**

In `WorkspaceWindowController.swift`, after `var serverSessionRevoker: (() -> Void)?` (line 424) add:

```swift
    /// Ends the running daemon for an account switch — `nil` is the real
    /// thing, `daemonPersistence.terminateDaemon` with the pid off the
    /// connected socket. A test substitutes a recorder: no test may signal
    /// the developer's live daemon.
    var daemonTerminator: ((@escaping () -> Void) -> Void)?
    /// Fires `true` when the gate resolves signed in and `false` when the
    /// account logs out — `AppDelegate` creates and releases the menu bar
    /// item on it (2026-08-30 spec, "Menu bar").
    var onSignedInStateChanged: ((Bool) -> Void)?
    /// The data root the account pointer lives in — `DaemonPaths.dataDir`,
    /// the same directory the LaunchAgent plist hands the daemon. Settable so
    /// a test points it at a scratch directory; reading the pointer back is
    /// what `currentAccountID` starts from.
    var accountRoot: URL {
        didSet { currentAccountID = AccountDirectory.readCurrentAccount(root: accountRoot) }
    }
    /// What the pointer named when the root was read, kept current after
    /// every write — `switchAccount`'s "already serving this account" test.
    private(set) var currentAccountID: String?
    /// The mirror said signed in but no pointer was on disk: the first launch
    /// of this build over pre-account data. Consumed by
    /// `adoptLegacyAccountIfNeeded` once the layout is restored.
    private var legacyAdoptionPending = false
    /// Between the login window going up and the gate resolving — nothing
    /// is restored from a signed-out daemon, and `showWindow` raises the
    /// login window instead of the workspace.
    private(set) var awaitingSignIn = false
    /// Work that needs the daemon: run at once when connected, else the
    /// moment the next `.connected` lands (`runWhenConnected`).
    private var pendingConnectedWork: [() -> Void] = []
    /// "Bruno Bonando", or the email when the account has no name, or `""`
    /// while signed out — the menu bar's "Logged in as …" line. Kept from
    /// `refreshAccountSection`'s reads so the menu can be built without a
    /// round trip.
    private(set) var accountDisplayLabel = ""
    /// The login window's model while it is up — for tests that drive a
    /// sign-in without a browser.
    var launchGateModel: AuthGateViewModel? { authGateWindow.activeModel }
```

Change the `init` signature (lines 477-484) to:

```swift
    init(
        connection: SessionConnection,
        panes: [RestoredPane],
        notifier: SessionNotifier = SessionNotifier(delivery: UserNotificationDelivery()),
        daemonPersistence: DaemonPersistenceController = DaemonPersistenceController(),
        remoteMachines: RemoteMachinesModel = RemoteMachinesModel(),
        settingsClient: SettingsClient? = nil,
        authDefaults: UserDefaults = .standard
    ) {
```

and in its body change `let authGateCoordinator = AuthGateCoordinator(settings: settingsStore)` (line 491) to:

```swift
        // `authDefaults` is where the signed-in mirror lives — the real
        // app's domain in production, a throwaway suite in tests, which must
        // never sign the developer's install in or out (`RealPreferencesGuard`).
        let authGateCoordinator = AuthGateCoordinator(settings: settingsStore, defaults: authDefaults)
```

Before `self.daemonPersistence = daemonPersistence` (line 487) add:

```swift
        accountRoot = daemonPersistence.paths.dataDir
        currentAccountID = AccountDirectory.readCurrentAccount(root: daemonPersistence.paths.dataDir)
```

Directly after `super.init(window: window)` (line 577) add:

```swift
        // The gate's account switch: the pointer, the daemon restart, then
        // the persona the account's own data dir holds — read from the
        // *new* daemon, so it waits for the reconnect.
        authGateWindow.onSwitching = { [weak self] email, ready in
            guard let self else {
                ready(nil)
                return
            }
            switchAccount(toEmail: email) { [weak self] in
                guard let self else {
                    ready(nil)
                    return
                }
                runWhenConnected { [weak self] in
                    guard let self else {
                        ready(nil)
                        return
                    }
                    settingsStore.get(SettingsKey.authPersona) { result in
                        let persona = (try? result.get()) ?? nil
                        ready((persona ?? "").isEmpty ? nil : persona)
                    }
                }
            }
        }
```

- [ ] **Step 4: The `.connected` arm, launch gate and resolve**

Replace the `.connected` arm of `start()` (lines 1343-1355) with:

```swift
            case .connected:
                applyConnectionStatus(nil)
                // Nothing is restored while the login window is up: that
                // daemon serves the empty root, and restoring "nothing" there
                // would bootstrap a pane and write a layout row for the next
                // sign-in to find as a running session to end. The gate
                // resolving runs the same restore (`authGateDidResolve`).
                if !awaitingSignIn {
                    restoreAccountStateIfNeeded()
                }
                refreshProjectLabels()
                // The launch read ran before the daemon was up and failed;
                // this is the first time the rows can actually be read.
                refreshAccountSection()
                didConnect = true
                presentOnboardingIfNeeded()
                let work = pendingConnectedWork
                pendingConnectedWork.removeAll()
                for body in work {
                    body()
                }
```

Add right after `start()`'s closing brace's sibling `stop()` (i.e. after line 1454) — or anywhere in the class:

```swift
    /// Everything the daemon's data dir holds for this account, read once
    /// per connection — the once-flags inside each make a reconnect cheap.
    private func restoreAccountStateIfNeeded() {
        restoreWorkspaceIfNeeded()
        restoreUsageAnalyticsIfNeeded()
        restoreWorkspaceCustomizationsIfNeeded()
        restoreClosedWorkspacesIfNeeded()
        restoreRemoteControlIfNeeded()
    }

    /// Runs `body` now if the socket is up, else on the next `.connected`.
    func runWhenConnected(_ body: @escaping () -> Void) {
        if didConnect {
            body()
        } else {
            pendingConnectedWork.append(body)
        }
    }
```

At the end of `applyRestoredPanes` (after `restoreReviewPanelIfNeeded()`, line 3072) add:

```swift
        // The first launch over pre-account data: only now, with the panes
        // back, can the sessions the switch would end be counted.
        adoptLegacyAccountIfNeeded()
```

Replace `presentLaunchGate` (lines 4656-4670) with:

```swift
    func presentLaunchGate(defaults: UserDefaults = .standard, completion: @escaping () -> Void) {
        guard AuthGate.needsSignIn(defaults) else {
            // A pointer on disk means the daemon already serves this
            // account's directory. None means the first launch of this
            // build over pre-account data: the adoption runs once the layout
            // is on screen (`adoptLegacyAccountIfNeeded`), the one case the
            // "Move your workspace" ask exists for.
            legacyAdoptionPending = currentAccountID == nil
            restoreServerSession()
            authGateDidResolve()
            completion()
            return
        }
        awaitingSignIn = true
        // `over: nil` — a window of its own, centred, with nothing behind it.
        // A sheet needs a parent window on screen, and the whole point here is
        // that there isn't one yet.
        authGateWindow.present(over: nil) { [weak self] in
            self?.authGateDidResolve()
            completion()
        }
    }
```

Replace `authGateDidResolve` (lines 4700-4706) with:

```swift
    /// The gate is answered — always signed in now.
    private func authGateDidResolve() {
        awaitingSignIn = false
        authGateResolved = true
        seedAccountFromMirror()
        refreshAccountSection()
        // The socket may have come up while the login window was up, with
        // nothing restored on purpose; this account's rows are readable now.
        if didConnect {
            restoreAccountStateIfNeeded()
        }
        presentOnboardingIfNeeded()
        onSignedInStateChanged?(true)
    }
```

In `seedAccountFromMirror` (line 4732, after `applyAccountRow(name: nil, pictureURL: "")`) add:

```swift
        if !signedIn { accountDisplayLabel = "" }
```

In `refreshAccountSection`, directly before `applyAccountRow(` (line 4825) add:

```swift
                            accountDisplayLabel = signedIn ? (display ?? "") : ""
```

- [ ] **Step 5: `switchAccount`, `resetForAccountSwitch` and the adoption**

After `presentOnboardingIfNeeded` (line 5017) add:

```swift
    // MARK: - Account switch (2026-08-30 account-scoped workspace spec)

    /// "1 running session" / "3 running sessions" — the asks' count.
    static func runningSessionsPhrase(_ count: Int) -> String {
        "\(count) running session\(count == 1 ? "" : "s")"
    }

    /// Moves the daemon onto `email`'s data directory. The pointer names
    /// the account; the daemon reads it once at startup; so a change of
    /// account is a daemon restart — and a restart ends every session the
    /// daemon runs. That is the one thing this app never does on its own:
    /// with sessions running, the house modal asks first, and **Not now**
    /// leaves no pointer behind and completes as signed in on the current
    /// daemon (asked again next launch). A signed-out daemon has no
    /// sessions, so the ordinary post-logout sign-in never asks.
    ///
    /// The pointer is written on the decision rather than before the ask, so
    /// there is never a moment where a pointer sits on disk with no restart
    /// behind it — a crash-relaunched daemon would otherwise migrate the
    /// data without anyone having agreed to it.
    func switchAccount(toEmail email: String, completion: @escaping () -> Void) {
        let id = AccountDirectory.accountID(forEmail: email)
        guard currentAccountID != id else {
            // The running daemon already serves this account's directory.
            completion()
            return
        }
        let sessions = menuBarSummary().sessionCount
        guard sessions > 0 else {
            commitAccountSwitch(to: id, completion: completion)
            return
        }
        presentWindowAsk(
            title: "Move your workspace to your account?",
            message: "This restarts the daemon and ends \(Self.runningSessionsPhrase(sessions)).",
            severity: .critical,
            options: [
                PaneAskOption("Not now") { _ in completion() },
                PaneAskOption("Restart now", isPrimary: true) { [weak self] _ in
                    self?.commitAccountSwitch(to: id, completion: completion)
                },
            ],
            onCancel: { completion() }
        )
    }

    /// The decided half: pointer, then the daemon, then this window.
    private func commitAccountSwitch(to id: String, completion: @escaping () -> Void) {
        do {
            try AccountDirectory.writeCurrentAccount(id, root: accountRoot)
        } catch {
            applyConnectionStatus("Couldn't write the account pointer — \(error.localizedDescription)")
            completion()
            return
        }
        currentAccountID = id
        // The pointer is on disk before SIGTERM, so whichever daemon comes
        // up next — launchd's or ours — reads the new value.
        terminateDaemon { [weak self] in
            guard let self else {
                completion()
                return
            }
            resetForAccountSwitch()
            completion()
        }
    }

    /// `daemonPersistence.terminateDaemon` with the pid off the connected
    /// socket, behind the test seam.
    private func terminateDaemon(completion: @escaping () -> Void) {
        if let daemonTerminator {
            daemonTerminator(completion)
            return
        }
        daemonPersistence.terminateDaemon(pid: connection.peerProcessID(), completion: completion)
    }

    /// Forgets the daemon that just went away: every pane, without
    /// persisting (the account's own rows must not be overwritten with an
    /// empty layout), every per-pane record, every restore once-flag, and
    /// the connect/onboarding latches — so the next `.connected` restores
    /// whatever the *new* daemon's directory holds. Terminal panes whose
    /// sessions are gone come back through `handleReattachFailure →
    /// ensureSession` as new terminals resuming their conversations.
    func resetForAccountSwitch() {
        // Write gates first, so nothing below persists anything.
        layoutReadDispatched = false
        layoutReadCompleted = false
        notificationsReadDispatched = false
        notificationsReadCompleted = false
        browserPanesReadDispatched = false
        browserPanesReadCompleted = false
        editorPanesReadDispatched = false
        editorPanesReadCompleted = false
        customizationsReadDispatched = false
        customizationsReadCompleted = false
        closedWorkspacesReadDispatched = false
        closedWorkspacesReadCompleted = false
        sessionMetaReadDispatched = false
        sessionMetaReadCompleted = false
        reviewPanelReadDispatched = false
        reviewPanelReadCompleted = false
        remoteControlReadDispatched = false
        usageReadDispatched = false
        usageReadCompleted = false

        for id in workspace.allPaneIDs {
            homeLaunches[id]?.cancel()
            resumeSpawns.removeValue(forKey: id)
            readySessions.remove(id)
            ensuringSessions.remove(id)
            sessionStatus.removeValue(forKey: id)
            lastStatus.removeValue(forKey: id)
            lastStatusEventAt.removeValue(forKey: id)
            activity.forget(paneID: id)
            statusSeries.forget(paneID: id)
            workspace.closePane(id)
        }
        homeLaunches.removeAll()
        lastFocusedEditorPaneID = nil
        recentSessionGroupIDs.removeAll()
        sessionMeta = [:]
        reviewPanelStates = [:]
        workspaceCustomizations = [:]
        closedWorkspaceIDs = []
        remoteControlWorkspaceIDs = []
        hasRelayDeviceToken = false
        projectLabels = [:]
        workspaces = []
        selectedProjectID = nil
        notifier.restore([])
        usageRecorder.restore(UsageAnalyticsStore())

        didConnect = false
        onboardingDispatched = false
        reloadOutline()
        if destination == .home { refreshHomeChips() }
    }

    /// The first launch of this build over data written before accounts
    /// existed (`presentLaunchGate` set the flag: mirror true, no pointer).
    /// Reads the account's email from the rows — still at the root, where
    /// the legacy daemon serves them — and runs the switch, which asks
    /// whenever sessions are running. Rows the legacy fake-login build
    /// wrote carry no email; those installs stay at the root until a real
    /// sign-in. A read that fails leaves the flag armed for the next
    /// connection.
    private func adoptLegacyAccountIfNeeded() {
        guard legacyAdoptionPending else { return }
        settingsStore.get(SettingsKey.authAccountEmail) { [weak self] result in
            guard let self, let email = try? result.get() else { return }
            legacyAdoptionPending = false
            guard !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            switchAccount(toEmail: email) {}
        }
    }
```

- [ ] **Step 6: Run the tests to verify they pass**

Run the Step 2 command.
Expected: all `WorkspaceWindowControllerTests` pass, including the 9 new ones. The pre-existing `testTheWorkspaceWindowWaitsBehindTheLaunchGate` still passes (signed-out defaults present the gate; signed-in defaults go straight in).

Also run `-only-testing:OmniAgentTests/WorkspaceWindowControllerTask6b2Tests -only-testing:OmniAgentTests/EditorPaneIntegrationTests` — expected unchanged (they call the init without `authDefaults`, which is defaulted).

- [ ] **Step 7: Commit**

```bash
git add macos/OmniAgent/WorkspaceWindowController.swift macos/OmniAgentTests/WorkspaceWindowControllerTests.swift
git commit -m "feat(macos): switchAccount moves the daemon onto the account's data dir, asking before ending sessions

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
git push
```

---

### Task 8: Logout tears down; signed-out guards

**Files:**
- Modify: `macos/OmniAgent/WorkspaceWindowController.swift` — `showWindow` (1332-1337), `logOutOfAccount` (4853-4870), `performAccountDeletion`'s reset branch (4901-4907), new helpers next to `switchAccount`
- Test: `macos/OmniAgentTests/WorkspaceWindowControllerTests.swift` — the spotlight account-rows test (lines 1687-1740) and new tests

**Interfaces:**
- Consumes: Task 7's `awaitingSignIn`, `accountRoot`, `daemonTerminator`, `terminateDaemon(completion:)`, `resetForAccountSwitch()`, `onSignedInStateChanged`, `authGateDidResolve()`; `AuthGateWindowController.raise()` (Task 6).
- Produces: `logOutOfAccount()` asks when sessions run, then revokes, resets (persona kept), terminates, clears the pointer, drops the workspace, orders the window out, fires `onSignedInStateChanged?(false)`, presents the gate over `nil`; `showWindow` raises the login window while `awaitingSignIn`.

- [ ] **Step 1: Update the existing spotlight test and write the failing tests**

In `testSpotlightAccountRowsRunTheAccountSectionsOwnActions` (the test containing `controller.run(.signOut)`, around lines 1687-1740): replace the block from `// \`AuthGateCoordinator\` mirrors the flag into the *app's* defaults,` through `XCTAssertEqual(presented, 2)` with:

```swift
        // A log-out ends the daemon and the pointer; both go through seams
        // so the developer's real daemon and data root are never touched.
        controller.accountRoot = try temporaryAccountRoot()
        var terminated = 0
        controller.daemonTerminator = { done in
            terminated += 1
            done()
        }
        let gateCameBack = expectation(description: "the login screen is offered after logging out")
        controller.authGatePresenter = { completion in
            presented += 1
            gateCameBack.fulfill()
            completion()
        }
        controller.run(.signOut)
        // One session is on screen, so the row asks before ending it.
        let logoutAsk = try XCTUnwrap(controller.windowAskOverlay, "a running session means asking first")
        XCTAssertEqual(logoutAsk.options.map(\.title), ["Cancel", "Log out"])
        XCTAssertEqual(revoked, 0, "nothing happens until the question is answered")
        press("Log out", on: logoutAsk)
        XCTAssertEqual(revoked, 1, "the server session is revoked, not only the local rows")
        XCTAssertFalse(
            controller.authGateCoordinator.defaults.bool(forKey: AuthGate.signedInDefaultsKey),
            "the launch gate's mirror is cleared, so the next launch asks again"
        )
        wait(for: [gateCameBack], timeout: 5)
        XCTAssertEqual(presented, 2)
        XCTAssertEqual(terminated, 1)
```

That test builds its controller with `makeController()`, whose coordinator writes `.standard`; change the test's first line `let controller = makeController()` to `let controller = makeController(settingsClient: FakeSettingsClient(), defaults: try throwawayDefaults())` and add this helper next to `makeController(settingsClient:)` (line 2516):

```swift
    private func makeController(settingsClient: SettingsClient, defaults: UserDefaults) -> WorkspaceWindowController {
        WorkspaceWindowController(
            connection: SessionConnection(
                socketURL: URL(fileURLWithPath: "/tmp/omniagent-controller-test.sock")
            ),
            panes: [WorkspaceRestoration.bootstrapPane(sessionID: "native-terminal")],
            settingsClient: settingsClient,
            authDefaults: defaults
        )
    }
```

(If that test also asserts `controller.settingsView.accountField.stringValue == "Not signed in"` afterwards, keep it — it still holds.)

Add new tests after the Task 7 ones:

```swift
    // MARK: - Logout teardown

    /// Nothing running: no question. Revoke, reset, end the daemon, delete
    /// the pointer, drop the workspace, hide the window, tell the app
    /// delegate, and put the login window up on its own.
    func testLogOutWithNothingRunningTearsTheWorkspaceDownAndOffersTheGateAlone() throws {
        let defaults = try throwawayDefaults()
        defaults.set(true, forKey: AuthGate.signedInDefaultsKey)
        let client = FakeSettingsClient(rows: [
            "auth_signed_in": "true", "auth_persona": "research", "auth_account_email": "bruno@bonando.com",
        ])
        let controller = makeEmptyController(settingsClient: client, defaults: defaults)
        defer { controller.close() }
        let root = try temporaryAccountRoot()
        try AccountDirectory.writeCurrentAccount("fc44b18d5588b1d6", root: root)
        controller.accountRoot = root
        var terminated = 0
        var order: [String] = []
        controller.daemonTerminator = { done in
            terminated += 1
            order.append("terminate")
            done()
        }
        controller.serverSessionRevoker = { order.append("revoke") }
        var signedInStates: [Bool] = []
        controller.onSignedInStateChanged = { state in
            signedInStates.append(state)
            order.append(state ? "signed-in" : "signed-out")
        }
        var resolveGate: (() -> Void)?
        controller.authGatePresenter = { completion in
            order.append("gate")
            resolveGate = completion
        }
        controller.showWindow(nil)
        XCTAssertTrue(try XCTUnwrap(controller.window).isVisible)

        controller.logOutOfAccount()

        XCTAssertNil(controller.windowAskOverlay, "nothing to end, nothing to ask")
        XCTAssertEqual(order, ["revoke", "terminate", "signed-out", "gate"])
        XCTAssertEqual(terminated, 1)
        XCTAssertNil(AccountDirectory.readCurrentAccount(root: root), "the pointer is gone: the next daemon serves the root")
        XCTAssertNil(controller.currentAccountID)
        XCTAssertEqual(client.rows["auth_signed_in"], "false")
        XCTAssertEqual(client.rows["auth_persona"], "research", "the persona belongs to the account and stays with it")
        XCTAssertFalse(try XCTUnwrap(controller.window).isVisible, "only the login window is on screen")
        XCTAssertTrue(controller.awaitingSignIn)
        XCTAssertEqual(signedInStates, [false])

        // Reopen while signed out raises the gate, not the workspace.
        controller.showWindow(nil)
        XCTAssertFalse(try XCTUnwrap(controller.window).isVisible, "the workspace stays hidden until someone signs in")

        // Sign in again: the workspace comes back.
        resolveGate?()
        XCTAssertFalse(controller.awaitingSignIn)
        XCTAssertTrue(try XCTUnwrap(controller.window).isVisible)
        XCTAssertEqual(signedInStates, [false, true])
    }

    func testLogOutWithSessionsRunningAsksFirstAndCancelChangesNothing() throws {
        let controller = makeController(settingsClient: FakeSettingsClient(rows: ["auth_signed_in": "true"]), defaults: try throwawayDefaults())
        defer { controller.close() }
        let root = try temporaryAccountRoot()
        try AccountDirectory.writeCurrentAccount("fc44b18d5588b1d6", root: root)
        controller.accountRoot = root
        var terminated = 0
        controller.daemonTerminator = { done in
            terminated += 1
            done()
        }
        var revoked = 0
        controller.serverSessionRevoker = { revoked += 1 }
        controller.authGatePresenter = { _ in XCTFail("nothing was logged out") }

        controller.logOutOfAccount()

        let ask = try XCTUnwrap(controller.windowAskOverlay)
        XCTAssertEqual(ask.options.map(\.title), ["Cancel", "Log out"])
        press("Cancel", on: ask)

        XCTAssertNil(controller.windowAskOverlay)
        XCTAssertEqual(revoked, 0)
        XCTAssertEqual(terminated, 0)
        XCTAssertEqual(AccountDirectory.readCurrentAccount(root: root), "fc44b18d5588b1d6")
        XCTAssertEqual(controller.workspaceView.allPaneIDs.count, 1)
        XCTAssertFalse(controller.awaitingSignIn)
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `caffeinate -disu xcodebuild test -project macos/OmniAgent.xcodeproj -scheme OmniAgent -destination "platform=macOS,arch=arm64" CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64 -only-testing:OmniAgentTests/WorkspaceWindowControllerTests`
Expected: the three logout tests fail — `logOutOfAccount` does not ask (`XCTUnwrap(controller.windowAskOverlay)` fails), does not terminate (`terminated == 0`), the window stays visible.

- [ ] **Step 3: The signed-out guard in `showWindow`**

Replace `showWindow` (lines 1332-1337) with:

```swift
    /// The workspace never shows while nobody is signed in: the Dock's
    /// reopen, the menu bar and every other route through here raise the
    /// login window instead (2026-08-30 spec, "Sign-in is mandatory").
    override func showWindow(_ sender: Any?) {
        guard !awaitingSignIn else {
            authGateWindow.raise()
            return
        }
        super.showWindow(sender)
        window?.center()
        window?.makeKeyAndOrderFront(sender)
        focusTerminal(sender)
    }
```

- [ ] **Step 4: The logout teardown**

Replace `logOutOfAccount` (lines 4847-4870, doc comment included) with:

```swift
    /// "Log out": ask if it ends sessions; revoke the session server-side;
    /// clear the persisted outcome (account rows included, persona kept —
    /// it is the account's); end the daemon and delete the pointer, so the
    /// next daemon serves the empty root; drop the workspace; order this
    /// window and its sheets out; tell `AppDelegate` (the menu bar item
    /// goes); and put the login window up on its own, exactly like launch
    /// (2026-08-30 spec, "Logout").
    func logOutOfAccount() {
        guard !accountActionInFlight else { return }
        let sessions = menuBarSummary().sessionCount
        guard sessions > 0 else {
            performLogout()
            return
        }
        presentWindowAsk(
            title: "Log out and end \(Self.runningSessionsPhrase(sessions))?",
            message: "Your workspace comes back the next time this account signs in, with new terminals.",
            severity: .critical,
            options: [
                PaneAskOption("Cancel") { _ in },
                PaneAskOption("Log out", isPrimary: true) { [weak self] _ in self?.performLogout() },
            ]
        )
    }

    /// The confirmed half of `logOutOfAccount`, and what account deletion
    /// ends in: after the account is gone the app is in exactly the state a
    /// sign-out leaves it.
    private func performLogout() {
        guard !accountActionInFlight else { return }
        accountActionInFlight = true
        if let serverSessionRevoker {
            serverSessionRevoker()
        } else {
            Task { await AuthClient.shared.logout() }
        }
        authGateCoordinator.reset { [weak self] in
            guard let self else { return }
            // Straight off the mirror `reset` has just cleared, so the page
            // stops saying "Signed in as …" even when the rows cannot be
            // read back.
            seedAccountFromMirror()
            refreshAccountSection()
            tearDownForSignedOut()
        }
    }

    /// Steps 4–6 of the spec's logout: daemon, pointer, workspace, window,
    /// menu bar, login window. `awaitingSignIn` goes up first so a
    /// `.connected` from the restarted (signed-out) daemon restores nothing.
    private func tearDownForSignedOut() {
        awaitingSignIn = true
        authGateResolved = false
        terminateDaemon { [weak self] in
            guard let self else { return }
            do {
                try AccountDirectory.clearCurrentAccount(root: accountRoot)
            } catch {
                applyConnectionStatus("Couldn't remove the account pointer — \(error.localizedDescription)")
            }
            currentAccountID = nil
            resetForAccountSwitch()
            hideWorkspaceForSignIn()
            onSignedInStateChanged?(false)
            accountActionInFlight = false
            presentSignInAfterLogout()
        }
    }

    /// This window and everything hanging off it, off screen — the login
    /// window is the only thing on screen while nobody is signed in.
    private func hideWorkspaceForSignIn() {
        dismissWindowAsk()
        dismissCustomizeCard()
        if let window {
            if let sheet = window.attachedSheet {
                window.endSheet(sheet)
            }
            window.orderOut(nil)
        }
        settingsWindowController.window?.orderOut(nil)
        inspector.window?.orderOut(nil)
    }

    /// The launch gate again, over nothing. Its resolution runs the sign-in
    /// flow (`AuthGateWindowController.onSwitching` → `switchAccount`) and
    /// brings the workspace window back.
    private func presentSignInAfterLogout() {
        let resolved: () -> Void = { [weak self] in
            guard let self else { return }
            authGateDidResolve()
            showWindow(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        if let authGatePresenter {
            authGatePresenter(resolved)
        } else {
            authGateWindow.present(over: nil, completion: resolved)
        }
    }
```

In `performAccountDeletion` (lines 4884-4907), replace the `authGateCoordinator.reset { … presentAccountGate() }` block (the `do` branch's body after `try await AuthClient.shared.deleteAccount()`) with:

```swift
                accountActionInFlight = false
                performLogout()
```

so deletion ends in the same teardown as a log-out (the server-side revoke inside `performLogout` is a harmless no-op on a deleted account).

- [ ] **Step 5: Run the tests to verify they pass**

Run the Step 2 command.
Expected: all `WorkspaceWindowControllerTests` pass. Also run `-only-testing:OmniAgentTests/CommandPaletteTests` (the `.signOut` row still dispatches to `logOutOfAccount`; rows unchanged, no new destinations — the Spotlight rule is satisfied) — expected unchanged.

- [ ] **Step 6: Commit**

```bash
git add macos/OmniAgent/WorkspaceWindowController.swift macos/OmniAgentTests/WorkspaceWindowControllerTests.swift
git commit -m "feat(macos): logging out ends the daemon, clears the pointer and leaves only the login window

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
git push
```

---

### Task 9: Menu bar — only while signed in, "Logged in as {name}"

**Files:**
- Modify: `macos/OmniAgent/MenuBarController.swift:36-102` (`MenuBarMenu.build`), `:107-150` (`MenuBarController`)
- Modify: `macos/OmniAgent/AppDelegate.swift:6-7` (properties), `:19-67` (`applicationDidFinishLaunching`), new method
- Test: `macos/OmniAgentTests/MenuBarControllerTests.swift`

**Interfaces:**
- Consumes: `WorkspaceWindowController.accountDisplayLabel`, `.onSignedInStateChanged` (Task 7).
- Produces: `MenuBarMenu.build(into:summary:accountLabel:revealSession:createInWorkspace:chooseFolder:showSettings:quit:)` (new `accountLabel: String` after `summary`); `MenuBarMenu.accountLine(_:) -> String`; `MenuBarController.deinit` removes the status item; `AppDelegate.menuBar` readable, `AppDelegate.signedInStateChanged(_:workspace:)`.

- [ ] **Step 1: Write the failing tests**

In `macos/OmniAgentTests/MenuBarControllerTests.swift`:

1. Add `accountLabel: "Bruno Bonando",` directly after `summary: …,` in every existing `MenuBarMenu.build(` call (five calls: lines 21-29, 58-66, 82-90, 102-110, 128-136).
2. In `testEmptySummaryHasNoSessionRows`, replace the expected items and the two assertions after them with:

```swift
        // Account line, headline, separator, Create Session…, separator,
        // Settings…, separator, Quit — nothing about sessions when there
        // are none.
        XCTAssertEqual(menu.items.map(\.title), [
            "Logged in as Bruno Bonando",
            "0 sessions · 0 terminals · 0 working agents",
            "",
            "Create Session…",
            "",
            "Settings…",
            "",
            "Quit",
        ])
        XCTAssertTrue(menu.items[2].isSeparatorItem)
        XCTAssertFalse(menu.items[0].isEnabled, "the account line is a label, not a choice")
        XCTAssertFalse(menu.items[1].isEnabled, "and so is the headline")
```

3. Append before the class's closing brace:

```swift
    // MARK: - Account (2026-08-30 account-scoped workspace spec)

    func testTheFirstLineSaysWhoIsLoggedIn() {
        XCTAssertEqual(MenuBarMenu.accountLine("Bruno Bonando"), "Logged in as Bruno Bonando")
        XCTAssertEqual(MenuBarMenu.accountLine("bruno@bonando.com"), "Logged in as bruno@bonando.com")
        XCTAssertEqual(MenuBarMenu.accountLine(""), "Logged in", "rows not read yet: no invented name")
    }

    /// The status item exists only between the gate resolving signed in and
    /// a log-out: `AppDelegate` creates and releases the controller on the
    /// window's `onSignedInStateChanged`.
    func testTheStatusItemExistsOnlyWhileSignedIn() {
        let delegate = AppDelegate()
        let workspace = WorkspaceWindowController(
            connection: SessionConnection(socketURL: URL(fileURLWithPath: "/tmp/omniagent-menubar-test.sock")),
            panes: []
        )
        defer { workspace.close() }
        XCTAssertNil(delegate.menuBar, "nothing in the menu bar before anyone signs in")

        delegate.signedInStateChanged(true, workspace: workspace)
        XCTAssertNotNil(delegate.menuBar)
        let first = delegate.menuBar
        delegate.signedInStateChanged(true, workspace: workspace)
        XCTAssertTrue(delegate.menuBar === first, "a second sign-in keeps the one item")

        delegate.signedInStateChanged(false, workspace: workspace)
        XCTAssertNil(delegate.menuBar, "logging out takes the item down")
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `caffeinate -disu xcodebuild test -project macos/OmniAgent.xcodeproj -scheme OmniAgent -destination "platform=macOS,arch=arm64" CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64 -only-testing:OmniAgentTests/MenuBarControllerTests`
Expected: build fails — `extra argument 'accountLabel' in call`, `type 'MenuBarMenu' has no member 'accountLine'`, `'menuBar' is inaccessible due to 'private' protection level`, `has no member 'signedInStateChanged'`.

- [ ] **Step 3: The menu**

In `macos/OmniAgent/MenuBarController.swift`, replace `MenuBarMenu.build`'s signature and first lines (lines 40-52) with:

```swift
    static func build(
        into menu: NSMenu,
        summary: MenuBarSummary,
        accountLabel: String,
        revealSession: @escaping (String) -> Void,
        createInWorkspace: @escaping (String) -> Void,
        chooseFolder: @escaping () -> Void,
        showSettings: @escaping () -> Void,
        quit: @escaping () -> Void
    ) {
        menu.removeAllItems()
        menu.autoenablesItems = false

        // The item exists only while signed in, and its first line says for
        // whom (2026-08-30 spec: "logged in as {name}").
        menu.addItem(disabledItem(accountLine(accountLabel)))
        menu.addItem(disabledItem(headline(summary)))
```

After `headline(_:)` (line 91) add:

```swift
    /// "Logged in as Bruno Bonando" — `auth_account_name`, falling back to
    /// the email (`WorkspaceWindowController.accountDisplayLabel`); just
    /// "Logged in" until the rows have been read.
    static func accountLine(_ label: String) -> String {
        label.isEmpty ? "Logged in" : "Logged in as \(label)"
    }
```

In `MenuBarController`, after `init` (before `menuNeedsUpdate`) add:

```swift
    /// Released by `AppDelegate` on log-out: the item leaves the menu bar
    /// with the controller, not at the app's exit.
    deinit {
        NSStatusBar.system.removeStatusItem(statusItem)
    }
```

and in `menuNeedsUpdate` add `accountLabel: workspace.accountDisplayLabel,` directly after `summary: workspace.menuBarSummary(),`.

- [ ] **Step 4: The app delegate**

In `macos/OmniAgent/AppDelegate.swift`:

Replace `private var menuBar: MenuBarController?` (line 7) with:

```swift
    /// The status item — alive only while signed in (`signedInStateChanged`).
    private(set) var menuBar: MenuBarController?
```

Delete the line `menuBar = MenuBarController(workspace: workspace)` (line 48) and, directly before `workspace.start()` (line 51), add:

```swift
        // The menu bar item follows the account: created when the gate
        // resolves signed in, gone on log-out.
        workspace.onSignedInStateChanged = { [weak self, weak workspace] signedIn in
            guard let self, let workspace else { return }
            signedInStateChanged(signedIn, workspace: workspace)
        }
```

After `applicationShouldHandleReopen` (line 91) add:

```swift
    /// `WorkspaceWindowController.onSignedInStateChanged`'s target — internal
    /// so `MenuBarControllerTests` can drive it without a launch.
    func signedInStateChanged(_ signedIn: Bool, workspace: WorkspaceWindowController) {
        if signedIn {
            if menuBar == nil {
                menuBar = MenuBarController(workspace: workspace)
            }
        } else {
            menuBar = nil
        }
    }
```

Also update the doc comment on `applicationShouldHandleReopen` (lines 84-86) to:

```swift
    /// The Dock icon's standard reopen gesture, now that the window can be
    /// hidden without the app quitting — the same "bring it to the front"
    /// the menu bar icon's own items do. While nobody is signed in,
    /// `WorkspaceWindowController.showWindow` raises the login window instead.
```

- [ ] **Step 5: Run the tests to verify they pass**

Run the Step 2 command.
Expected: `MenuBarControllerTests` all pass (7 tests).

- [ ] **Step 6: Commit**

```bash
git add macos/OmniAgent/MenuBarController.swift macos/OmniAgent/AppDelegate.swift macos/OmniAgentTests/MenuBarControllerTests.swift
git commit -m "feat(macos): the menu bar item exists only while signed in and says who is logged in

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
git push
```

---

### Task 10: Docs, the standing rule, full suites

**Files:**
- Modify: `.github/copilot-instructions.md:49-50` (then regenerate `AGENTS.md`, `CLAUDE.md`, `CODEX.md`, `ANTIGRAVITY.md` with `./scripts/sync-instructions.sh`)
- Modify: `README.md:21`

- [ ] **Step 1: Document the per-account data dir and the rule**

In `.github/copilot-instructions.md`, replace lines 49-50:

```
- Storage: SQLite "brain" DB (rebuildable) + durable Markdown memory under:
  `~/Library/Application Support/OmniAgent-ADE/brain/` — override with `OMNIAGENT_ADE_DATA_DIR`.
```

with:

```
- Storage: SQLite "brain" DB (rebuildable) + durable Markdown memory under a **data root**, `~/Library/Application Support/OmniAgent-ADE/` — override the root with `OMNIAGENT_ADE_DATA_DIR`. The root is per-account (`docs/superpowers/specs/2026-08-30-account-scoped-workspace-design.md`): it holds a pointer file `current-account` naming the signed-in account (`<id>` = first 16 hex of SHA-256 of the lower-cased, trimmed email — `Store::account_dir_id` / `AccountDirectory.accountID(forEmail:)`), and while the pointer exists every crate and the app resolve the data dir to `<root>/accounts/<id>/` (`brain_core::Store::default_data_dir()`, `macos/OmniAgent/AccountDirectory.swift`); absent or blank, the root itself (signed out). The daemon reads the pointer **once at startup**, so switching accounts is a daemon restart (`WorkspaceWindowController.switchAccount`); on the first start into an account dir it moves a pre-account install's `brain.db`/`brain/`/`transcripts/` there (`Store::adopt_legacy_data`). The app writes and removes the pointer and never moves files or creates `accounts/`.
- **Never kill a busy daemon on your own** (standing rule, 2026-08-30): the app ends the daemon only after the user confirms in the house modal when it has running sessions (`switchAccount` / `logOutOfAccount`, via `DaemonPersistenceController.terminateDaemon` with the pid off the socket's `LOCAL_PEERPID`), and a developer never terminates the running production daemon to test this — use `scripts/rebuild-app.sh --keep-daemon`, targeted `xcodebuild test … -only-testing:` runs with fake terminators, and the Preview configuration (bundle id `digital.bruno.omniagent.preview`, own socket + data dir) for end-to-end checks.
```

Run `./scripts/sync-instructions.sh` (regenerates the four agent files verbatim from the authoritative file).

In `README.md`, replace line 21 with:

```
Everything lives under `~/Library/Application Support/OmniAgent-ADE/` by default — the data **root**. It holds a pointer file, `current-account`, naming the signed-in account; while it exists, the data dir is `accounts/<id>/` under the root (one directory per account, so only the signed-in account sees its brain, workspaces and transcripts), otherwise the root itself. Inside the data dir: `brain.db` (the derived, rebuildable graph — see the sidebar's "About" panel for "Rebuild brain"), `brain/<project>/*.md` (durable Markdown memory — never deleted by a rebuild), and `transcripts/` (per-session PTY logs). Override the root with `OMNIAGENT_ADE_DATA_DIR` (every crate honors it) — useful for a scratch/test data dir instead of your real one. The daemon reads the pointer once at startup; the app restarts it to switch accounts, asking first whenever that would end running sessions.
```

- [ ] **Step 2: Run the full suites**

Run: `cargo test --workspace`
Expected: pass, except the known pre-existing `server_protocol` timeouts (Global Constraints). Also `cargo clippy --all-targets --all-features` — no new warnings; `cargo fmt --all --check` — clean.

Run: `caffeinate -disu ./macos/build.sh test`
Expected: pass, except the known pre-existing divider-drag failure and the load-flaky hover-card test. Confirm specifically that `AuthGateStateTests`, `AuthGateCoordinatorTests`, `AuthGateViewModelTests`, `AuthGateWindowTests`, `AccountDirectoryTests`, `DaemonPersistenceControllerTests`, `MenuBarControllerTests`, `WorkspaceWindowControllerTests`, `CommandPaletteTests`, `SettingsViewModelTests` and `NavigationSidebarTests` are green. If `RealPreferencesGuard`'s snapshot shows the developer's `auth.signedIn` changed after the run, a test is still on `.standard` — find it (`grep -n "authDefaults\|throwawayDefaults" macos/OmniAgentTests/*.swift`) and give it a throwaway suite before committing.

- [ ] **Step 3: Commit the docs**

```bash
git add .github/copilot-instructions.md AGENTS.md CLAUDE.md CODEX.md ANTIGRAVITY.md README.md
git commit -m "docs: per-account data dirs, the current-account pointer and the never-kill-a-busy-daemon rule

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
git push
```

- [ ] **Step 4 (optional): end-to-end on the Preview channel — never the production daemon**

The Preview configuration has its own bundle id (`digital.bruno.omniagent.preview`), socket (`~/.omniagent-ade/preview/omniagent-pty.sock`), data root (`~/Library/Application Support/OmniAgent-ADE-Preview`) and LaunchAgent label, so nothing here touches the production daemon or data. Its "Embed PTY Daemon" build phase needs the daemon staged first:

```bash
./macos/embed-daemon.sh arm64
caffeinate -disu xcodebuild build -project macos/OmniAgent.xcodeproj -scheme OmniAgent -configuration Preview -derivedDataPath macos/.build-preview -destination "platform=macOS,arch=arm64" CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64
open macos/.build-preview/Build/Products/Preview/OmniAgent.app
```

Walk: sign in (Apple or GitHub) → the "Opening your workspace…" card → workspace opens empty (fresh preview root) → `cat "$HOME/Library/Application Support/OmniAgent-ADE-Preview/current-account"` prints the id → open a terminal pane → Settings › Accounts › Log out → the ask names 1 running session → Log out → the workspace window and the menu bar item disappear, only the login window remains, the pointer file is gone → sign in again → the workspace comes back with the same layout and a new terminal, no persona question. Then quit the preview app and (this is the preview daemon only) `launchctl bootout gui/$(id -u)/digital.bruno.omniagent.preview.pty-daemon` to stop it.

- [ ] **Step 5 (per spec, last): the packaged build, leaving the production daemon alone**

```bash
./scripts/rebuild-app.sh --keep-daemon
```

`--keep-daemon` is mandatory: the running production daemon must survive this. The script bumps the build version in the Xcode project by itself (never bump by hand) — commit the resulting `macos/OmniAgent.xcodeproj/project.pbxproj` change afterwards (`git add macos/OmniAgent.xcodeproj/project.pbxproj && git commit -m "chore: bump build version" --trailer "Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>" && git push`). Verify the app relaunched (`pgrep -x OmniAgent`; `open -a OmniAgent` if empty). On its first launch the installed app sees mirror true + no pointer and, once the layout is restored, offers "Move your workspace to your account?" — **do not answer it on Bruno's behalf**; the modal exists so he decides when the production daemon restarts.

---

## Self-review against the spec

- Approach A pointer resolution in Rust (`default_data_dir`, env override root-only) — Task 1; Swift twin — Task 4; id derivation + cross-language vector — Tasks 1 & 4. LaunchAgent plist unchanged (still `OMNIAGENT_ADE_DATA_DIR=<root>`).
- One-time legacy migration in Rust, called by the daemon before `bind` — Tasks 2 & 3. The app never moves files.
- Sign-in mandatory: skip action and button removed; workspace shown only after the gate; `showWindow`/reopen raise the login window while signed out — Tasks 6 & 8. Menu bar absent while signed out — Task 9.
- Account switch steps 1–5 (pointer, compare, ask with the exact copy and Not now, SIGTERM via `LOCAL_PEERPID` + wait ≤5 s + respawn in app-owned mode, `resetForAccountSwitch`) — Tasks 5 & 7.
- Sign-in flow: `.switching` phase, "Opening your workspace…", `switchAccount` then `auth_persona` → `.accountReady`, `markSignedIn` still at `.signedIn` — Tasks 6 & 7. Launch with mirror true: pointer → straight in; no pointer → `switchAccount` with the email from the rows (asks when sessions run) — Task 7.
- Logout steps 1–6 with the exact copy; `auth_persona` kept — Tasks 6 & 8.
- Menu bar lifecycle via `onSignedInStateChanged`; "Logged in as {name}" from `auth_account_name` falling back to the email — Tasks 7 & 9.
- CommandPalette: no new destinations; `signIn`/`signOut` rows already exist and still dispatch to the same methods — verified in Task 8 Step 5.
- Testing section: every listed Rust and Swift case has a test above; whole suites in Task 10; Preview-only end-to-end; final `rebuild-app.sh --keep-daemon`.

## Deviations from the spec and assumptions (also listed in the reply)

1. **Pointer written on the decision, not before the ask.** Spec step 1 writes the pointer first and "Not now" removes it; here `switchAccount` writes it only when no ask is needed or after "Restart now". Same observable outcome (no pointer after Not now), without a window where a pointer exists with no restart behind it. Spec's "written before SIGTERM" still holds.
2. **"Already serving this account" is decided by the pointer alone**, without the "and the socket is up" half: if the pointer is unchanged and nothing is listening, whichever daemon comes up next reads that same pointer, so there is nothing to restart.
3. **`terminateDaemon` takes the pid** (`terminateDaemon(pid:completion:)`) because `DaemonPersistenceController` has no `SessionConnection`; `WorkspaceWindowController` passes `connection.peerProcessID()`. Respawn only in app-owned mode, exactly as the spec says — for a registered service, launchd's `KeepAlive` is trusted.
4. **Signed-out guard keys off `awaitingSignIn`** (up between showing the gate and its resolution, and from logout on) rather than reading `AuthGate.needsSignIn` in `showWindow`: the many existing tests that call `showWindow(nil)` never present a gate and must keep working regardless of the developer's real mirror.
5. **Nothing is restored from a signed-out daemon**: the `.connected` arm skips the restore while `awaitingSignIn`, and the gate resolving restores instead. Without this the empty root daemon would get a bootstrap pane and a layout row, and the very next sign-in would ask about "1 running session" — contradicting the spec's "the ordinary post-logout sign-in never asks".
6. **Legacy adoption runs after the layout is restored** (`applyRestoredPanes` → `adoptLegacyAccountIfNeeded`) so `menuBarSummary().sessionCount` counts the legacy daemon's sessions. Rows from the fake-login era carry no email; those installs stay at the root until a real sign-in. A failed email read re-arms for the next connection.
7. **Persona read after the restart waits for `.connected`** (`runWhenConnected`), because it must come from the new daemon; the switching card stays up until then.
8. **`WorkspaceWindowController.init` gains `authDefaults: UserDefaults = .standard`** so tests can give the coordinator a throwaway suite (the constraint "never .standard"); production is unchanged.
9. **`resetForAccountSwitch` drops dirty editor buffers without prompting**; the logout/switch asks are the confirmation. Account deletion now ends in the same teardown as logout.
10. **`AuthGateOutcome.signedIn` is kept** (always `true` from the gate now) because `AuthGateCoordinator.persist`, Settings and tests read it; removing it is churn outside the spec.
11. **`SettingsViewModel.signOut` (SettingsView.swift:139)** — the legacy SwiftUI settings window's own sign-out — is left as is; `WorkspaceWindowController` no longer presents that window (the in-window Settings page routes through `logOutOfAccount`).
12. `sha2 = "0.10"` is added to `brain-core` (not previously in the workspace; `digest` was, via `sha1`).
