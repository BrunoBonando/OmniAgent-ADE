//! Lightweight, single-level filesystem watcher registry backing the file
//! tree panel's live-refresh (Part A, founder feedback 2026-07-25: the file
//! view "must work exactly like the Finder from Mac OS" — if a file/folder
//! changes outside the app while the tree has that directory expanded, the
//! tree should reflect it without a manual refresh).
//!
//! Distinct from [`crate::watch::watch_roots`] (the ingestion watcher this
//! reuses the `notify` crate/pattern from): that one recursively watches
//! whole project roots and re-ingests into the graph DB. This one watches
//! exactly the directories the frontend currently has expanded in the file
//! tree, one `notify` watcher per directory, **non-recursively** — matching
//! [`crate::walk::list_dir`]'s own single-level semantics, so a change deep
//! inside a collapsed subfolder doesn't trigger a refresh of a directory
//! that isn't even showing it.
//!
//! ## Lifecycle — avoiding the two obvious failure modes
//!
//! - **Leaking watchers forever**: [`DirWatchRegistry::watch`] is keyed by
//!   the exact path string the frontend passed and is idempotent — calling
//!   it again for an already-watched path is a no-op, not a second watcher
//!   ([`DirWatchRegistry::watched_count`] proves this in tests). The
//!   frontend calls [`DirWatchRegistry::unwatch`] on every collapse, which
//!   drops the underlying `notify::RecommendedWatcher` (dropping it stops
//!   the OS-level FSEvents stream) — so an expand/collapse cycle never
//!   accumulates background watchers. Deliberately keyed by the *literal*
//!   input path rather than a canonicalized one: canonicalizing would
//!   require the directory to still exist, and a directory watched, then
//!   deleted out from under the app, then collapsed, must still be
//!   unwatchable — a canonicalize-keyed map would silently fail to find the
//!   entry to remove in exactly that case, which is its own leak.
//! - **Watching nothing when the frontend expects updates**: `watch` returns
//!   `Err` (rather than silently no-op-ing) when the directory can't
//!   actually be watched (doesn't exist, `notify` itself fails to attach),
//!   so the frontend can tell the difference between "watching" and "tried
//!   and failed."
//!
//! No debounce here, unlike the ingestion watcher: each directory-level
//! watcher already only covers what one open tree node shows, and the
//! frontend's reaction to `dir-changed:{path}` is a cheap, idempotent
//! `list_dir` re-fetch — coalescing a burst of events into fewer emits would
//! save a few redundant IPC round-trips at the cost of real complexity, not
//! worth it at this scale (ponytail).

use notify::{RecommendedWatcher, RecursiveMode, Watcher};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

/// Called with the (literal, as-passed-to-`watch`) path of the directory
/// that changed. `src-tauri`'s `lib.rs` wires this to
/// `app_handle.emit(&format!("dir-changed:{path}"), ..)` in its `.setup()`
/// closure — the same "closure captures the `AppHandle`" pattern already
/// used there for `OutputSink`/`AttentionSink` (`sessions.rs`).
pub type ChangeSink = Arc<dyn Fn(&Path) + Send + Sync>;

/// Tauri-managed state: one registry per app, holding zero or more live
/// per-directory watchers. Safe to call from multiple Tauri command
/// invocations concurrently — everything goes through one internal
/// [`Mutex`].
pub struct DirWatchRegistry {
    sink: ChangeSink,
    watchers: Mutex<HashMap<PathBuf, RecommendedWatcher>>,
}

impl DirWatchRegistry {
    pub fn new(sink: ChangeSink) -> Self {
        Self {
            sink,
            watchers: Mutex::new(HashMap::new()),
        }
    }

    /// Starts watching `dir` for changes at its own level, emitting via the
    /// sink on every fs event `notify` reports for it. Idempotent: a second
    /// call for a path that's already watched is a no-op (`Ok(())`,
    /// existing watcher untouched) rather than spinning up a duplicate.
    pub fn watch(&self, dir: &Path) -> Result<(), String> {
        let key = dir.to_path_buf();
        let mut watchers = self
            .watchers
            .lock()
            .map_err(|_| "dir watch registry mutex poisoned".to_string())?;
        if watchers.contains_key(&key) {
            return Ok(());
        }

        let sink = self.sink.clone();
        let emit_path = key.clone();
        let mut watcher = notify::recommended_watcher(move |res: notify::Result<notify::Event>| {
            if res.is_ok() {
                sink(&emit_path);
            }
        })
        .map_err(|e| format!("couldn't start watching {}: {e}", dir.display()))?;

        watcher
            .watch(dir, RecursiveMode::NonRecursive)
            .map_err(|e| format!("couldn't watch {}: {e}", dir.display()))?;

        watchers.insert(key, watcher);
        Ok(())
    }

    /// Stops watching `dir`, if it was being watched — a no-op (not an
    /// error) if it wasn't. Dropping the `RecommendedWatcher` tears down the
    /// OS-level watch, so this is all that's needed to release it.
    pub fn unwatch(&self, dir: &Path) -> Result<(), String> {
        let mut watchers = self
            .watchers
            .lock()
            .map_err(|_| "dir watch registry mutex poisoned".to_string())?;
        watchers.remove(dir);
        Ok(())
    }

    /// Number of directories currently watched — used by tests to prove
    /// `watch` is idempotent (no duplicate watcher on a repeated call).
    pub fn watched_count(&self) -> usize {
        self.watchers.lock().map(|w| w.len()).unwrap_or(0)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::sync::mpsc::{channel, RecvTimeoutError};
    use std::time::Duration;
    use tempfile::tempdir;

    /// A `ChangeSink` that forwards every call over an `mpsc` channel, so
    /// tests can block-with-timeout for an event instead of guessing at a
    /// fixed sleep duration.
    fn recording_sink() -> (ChangeSink, std::sync::mpsc::Receiver<PathBuf>) {
        let (tx, rx) = channel::<PathBuf>();
        let sink: ChangeSink = Arc::new(move |p: &Path| {
            let _ = tx.send(p.to_path_buf());
        });
        (sink, rx)
    }

    /// Waits up to `timeout` for at least one event on `rx`, draining any
    /// further ones that arrive within a short settle window — real FSEvents
    /// delivery can report a single fs write as more than one event.
    fn wait_for_event(rx: &std::sync::mpsc::Receiver<PathBuf>, timeout: Duration) -> Option<PathBuf> {
        let first = match rx.recv_timeout(timeout) {
            Ok(p) => p,
            Err(RecvTimeoutError::Timeout) => return None,
            Err(RecvTimeoutError::Disconnected) => return None,
        };
        while rx.recv_timeout(Duration::from_millis(100)).is_ok() {}
        Some(first)
    }

    #[test]
    fn watch_then_a_real_fs_change_fires_the_sink() {
        let dir = tempdir().unwrap();
        let (sink, rx) = recording_sink();
        let registry = DirWatchRegistry::new(sink);

        registry.watch(dir.path()).unwrap();
        // Give the OS-level FSEvents stream a moment to actually attach
        // before writing — matches this codebase's existing tolerance for
        // real fs-watcher timing (`watch.rs`'s own debounce loop).
        std::thread::sleep(Duration::from_millis(300));

        fs::write(dir.path().join("new.txt"), "hi").unwrap();

        let got = wait_for_event(&rx, Duration::from_secs(5));
        assert_eq!(got, Some(dir.path().to_path_buf()), "the sink must fire with the watched dir's path");
    }

    #[test]
    fn watch_is_idempotent_no_duplicate_watcher_on_a_repeated_call() {
        let dir = tempdir().unwrap();
        let (sink, _rx) = recording_sink();
        let registry = DirWatchRegistry::new(sink);

        registry.watch(dir.path()).unwrap();
        assert_eq!(registry.watched_count(), 1);
        registry.watch(dir.path()).unwrap();
        registry.watch(dir.path()).unwrap();
        assert_eq!(registry.watched_count(), 1, "a repeated watch() must not create a duplicate watcher");
    }

    #[test]
    fn unwatch_stops_further_events() {
        let dir = tempdir().unwrap();
        let (sink, rx) = recording_sink();
        let registry = DirWatchRegistry::new(sink);

        registry.watch(dir.path()).unwrap();
        std::thread::sleep(Duration::from_millis(300));
        fs::write(dir.path().join("first.txt"), "a").unwrap();
        assert!(wait_for_event(&rx, Duration::from_secs(5)).is_some(), "sanity: watch works before unwatch");

        registry.unwatch(dir.path()).unwrap();
        assert_eq!(registry.watched_count(), 0);
        std::thread::sleep(Duration::from_millis(300));

        fs::write(dir.path().join("second.txt"), "b").unwrap();
        assert!(
            wait_for_event(&rx, Duration::from_secs(2)).is_none(),
            "no event must fire for a directory after it's been unwatched"
        );
    }

    #[test]
    fn unwatch_on_a_path_that_was_never_watched_is_a_graceful_no_op() {
        let dir = tempdir().unwrap();
        let (sink, _rx) = recording_sink();
        let registry = DirWatchRegistry::new(sink);
        registry.unwatch(dir.path()).unwrap();
    }

    #[test]
    fn unwatch_works_even_after_the_watched_directory_itself_was_deleted() {
        // Proves the "keyed by literal path, not canonicalized" design
        // decision in the module doc: a canonicalize-on-unwatch approach
        // would fail to resolve a deleted directory and leak the watcher.
        let parent = tempdir().unwrap();
        let dir = parent.path().join("goes-away");
        fs::create_dir(&dir).unwrap();
        let (sink, _rx) = recording_sink();
        let registry = DirWatchRegistry::new(sink);

        registry.watch(&dir).unwrap();
        assert_eq!(registry.watched_count(), 1);

        fs::remove_dir(&dir).unwrap();
        registry.unwatch(&dir).unwrap();
        assert_eq!(registry.watched_count(), 0, "unwatch must still release the watcher for a now-deleted dir");
    }

    #[test]
    fn watch_rejects_a_directory_that_does_not_exist() {
        let parent = tempdir().unwrap();
        let missing = parent.path().join("no-such-dir");
        let (sink, _rx) = recording_sink();
        let registry = DirWatchRegistry::new(sink);

        assert!(registry.watch(&missing).is_err());
        assert_eq!(registry.watched_count(), 0);
    }
}
