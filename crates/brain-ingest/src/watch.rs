//! Incremental fs watcher (Task 2.3): debounced, re-ingests only the
//! projects whose files actually changed.
//!
//! ponytail: the watch loop itself (`watch_roots`) is a blocking `notify`
//! event loop — not unit-tested here, since exercising real filesystem
//! event timing in a test is inherently flaky. What *is* unit-tested is the
//! pure, deterministic part: "given a changed path, which project (if any)
//! owns it" (`project_for_path`), which is what the loop uses to decide what
//! to re-ingest.

use brain_core::Store;
use notify::{Event, RecommendedWatcher, RecursiveMode, Watcher};
use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::sync::mpsc::{channel, RecvTimeoutError};
use std::time::Duration;

/// Which of `roots` (name, path pairs) owns `changed`, if any. A path can be
/// under more than one root only if the roots themselves are nested, which
/// `discover_projects` never produces (it only looks at immediate
/// subdirectories of one parent) — so the first match is unambiguous.
pub(crate) fn project_for_path<'a>(
    roots: &'a [(String, PathBuf)],
    changed: &Path,
) -> Option<&'a str> {
    roots
        .iter()
        .find(|(_, root)| changed.starts_with(root))
        .map(|(name, _)| name.as_str())
}

/// Blocks forever, watching every root in `roots` and re-ingesting (via
/// `crate::ingest_project`) whichever projects had a file change since the
/// last debounce window. `debounce_ms` per PLAN.md Task 2.3 (2s in the CLI).
pub fn watch_roots(
    store: &Store,
    roots: &[(String, PathBuf)],
    debounce_ms: u64,
) -> anyhow::Result<()> {
    let (tx, rx) = channel::<notify::Result<Event>>();
    let mut watcher: RecommendedWatcher = notify::recommended_watcher(move |res| {
        let _ = tx.send(res);
    })?;
    for (_, path) in roots {
        watcher.watch(path, RecursiveMode::Recursive)?;
    }

    let mut dirty: HashSet<String> = HashSet::new();
    loop {
        match rx.recv_timeout(Duration::from_millis(debounce_ms)) {
            Ok(Ok(event)) => {
                for path in &event.paths {
                    if let Some(name) = project_for_path(roots, path) {
                        dirty.insert(name.to_string());
                    }
                }
            }
            Ok(Err(_)) => {} // ignore individual watch errors, keep watching
            Err(RecvTimeoutError::Timeout) => {
                if !dirty.is_empty() {
                    for (name, root) in roots {
                        if dirty.contains(name) {
                            let _ = crate::ingest_project(store, root, name);
                        }
                    }
                    dirty.clear();
                }
            }
            Err(RecvTimeoutError::Disconnected) => return Ok(()),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn roots() -> Vec<(String, PathBuf)> {
        vec![
            ("alpha".to_string(), PathBuf::from("/projects/alpha")),
            ("beta".to_string(), PathBuf::from("/projects/beta")),
        ]
    }

    #[test]
    fn resolves_changed_path_to_owning_project() {
        let r = roots();
        assert_eq!(
            project_for_path(&r, Path::new("/projects/alpha/src/main.rs")),
            Some("alpha")
        );
        assert_eq!(
            project_for_path(&r, Path::new("/projects/beta/README.md")),
            Some("beta")
        );
    }

    #[test]
    fn unrelated_path_resolves_to_no_project() {
        let r = roots();
        assert_eq!(project_for_path(&r, Path::new("/elsewhere/file.txt")), None);
    }
}
