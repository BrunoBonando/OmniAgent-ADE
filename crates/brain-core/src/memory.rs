use crate::redact::redact;
use crate::store::{now_ts, Edge, EdgeKind, Node, NodeKind, Origin, Store};
use once_cell::sync::Lazy;
use regex::Regex;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};

static REL_LINK: Lazy<Regex> = Lazy::new(|| Regex::new(r"\[[^\]]*\]\(([^)]+)\)").unwrap());

pub struct Memory<'a> {
    store: &'a Store,
    brain_dir: PathBuf,
}

fn slugify(title: &str) -> String {
    let mut slug = String::new();
    let mut last_dash = false;
    for c in title.to_lowercase().chars() {
        if c.is_ascii_alphanumeric() {
            slug.push(c);
            last_dash = false;
        } else if !last_dash {
            slug.push('-');
            last_dash = true;
        }
    }
    slug.trim_matches('-').to_string()
}

fn extract_relative_links(body: &str) -> Vec<String> {
    REL_LINK
        .captures_iter(body)
        .filter_map(|c| c.get(1).map(|m| m.as_str().to_string()))
        .filter(|target| !target.starts_with("http://") && !target.starts_with("https://"))
        .collect()
}

impl<'a> Memory<'a> {
    /// `data_dir` is the same root passed to `Store::open`; memory notes live
    /// under `data_dir/brain/<project>/`.
    pub fn new(store: &'a Store, data_dir: &Path) -> Memory<'a> {
        Memory {
            store,
            brain_dir: data_dir.join("brain"),
        }
    }

    pub fn write_note(
        &self,
        project: &str,
        title: &str,
        body: &str,
        origin: Origin,
    ) -> io::Result<PathBuf> {
        self.write_note_with_status(project, title, body, origin, false)
            .map(|(path, _id)| path)
    }

    /// Same as [`Memory::write_note`], plus Task 7.1's review-mode gate:
    /// when `pending` is true, the frontmatter gets a `status: pending` line
    /// and the new node is registered in `Store::mark_pending` — the single
    /// mechanism `search`/`get_context` use to hide it until someone
    /// approves or discards it (see `store.rs`'s `pending_notes` docs).
    /// Returns the node id alongside the path (unlike `write_note`) because
    /// Task 7.1's caller (`brain-ingest::enrich::write_session_summary`)
    /// needs it immediately after to attach `Touched` edges — recomputing
    /// the id via `slugify` a second time at the call site would just be
    /// duplicating logic that already lives here.
    pub fn write_note_with_status(
        &self,
        project: &str,
        title: &str,
        body: &str,
        origin: Origin,
        pending: bool,
    ) -> io::Result<(PathBuf, String)> {
        let redacted_body = redact(body);
        let project_dir = self.brain_dir.join(project);
        fs::create_dir_all(&project_dir)?;

        let date = chrono::Local::now().format("%Y-%m-%d");
        let slug = slugify(title);
        let filename = format!("{date}-{slug}.md");
        let path = project_dir.join(&filename);

        let origin_str = match origin {
            Origin::UserAuthored => "user",
            Origin::MachineSummary => "machine",
            Origin::Extracted => "extracted",
        };
        let status_line = if pending { "status: pending\n" } else { "" };
        let contents = format!(
            "---\norigin: {origin_str}\n{status_line}---\n\n# {title}\n\n{redacted_body}\n"
        );
        fs::write(&path, &contents)?;

        let id = format!("{project}:memory:{filename}");
        // Bug 4: these two Store writes can genuinely fail — e.g. SQLite
        // returning `DatabaseBusy` when a concurrent writer holds the lock
        // past `Store::open`'s busy_timeout (see `store.rs`) — and this
        // function already promises an `io::Result`, so a real failure here
        // must propagate as `Err`, not panic via `.expect(...)` (this
        // function runs from `brain-ingest::enrich`'s unsupervised
        // background drain-loop thread, where a panic has no supervisor).
        self.store
            .upsert_node(&Node {
                id: id.clone(),
                kind: NodeKind::Memory,
                project: project.to_string(),
                label: title.to_string(),
                path: Some(path.to_string_lossy().to_string()),
                summary: Some(redacted_body.chars().take(280).collect()),
                origin,
                updated: now_ts(),
            })
            .map_err(io::Error::other)?;

        if pending {
            self.store
                .mark_pending(&id, project)
                .map_err(io::Error::other)?;
        }

        for target in extract_relative_links(&redacted_body) {
            let dst_id = format!("{project}:doc:{target}");
            let _ = self.store.upsert_edge(&Edge {
                src: id.clone(),
                dst: dst_id,
                kind: EdgeKind::LinksTo,
                weight: 1.0,
            });
        }

        Ok((path, id))
    }

    /// Rewrites a note's on-disk `status: pending` frontmatter line to
    /// `status: approved` after `Store::approve_pending` lifts the DB-level
    /// hold — keeps the Markdown file honest as the record of what actually
    /// happened (DESIGN.md 3.5: "Markdown is ground truth for memory").
    /// The DB row is what actually gates visibility; this is a best-effort
    /// consistency pass, so a missing/unwritable file is swallowed rather
    /// than failing the approve action (the note is still visible either
    /// way once `approve_pending` has run).
    pub fn mark_note_approved_on_disk(path: &Path) {
        let Ok(contents) = fs::read_to_string(path) else {
            return;
        };
        if !contents.contains("status: pending\n") {
            return;
        }
        let updated = contents.replacen("status: pending\n", "status: approved\n", 1);
        let _ = fs::write(path, updated);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::store::Origin;
    use std::time::Duration;
    use tempfile::tempdir;

    /// Bug 4: `write_note_with_status` used to `.expect("brain db write
    /// failed")` on its `store.upsert_node`/`store.mark_pending` calls,
    /// turning any real SQLite failure into a panic instead of the `Err`
    /// its own `io::Result` return type promises. A real, realistic way to
    /// force that failure without touching `Store`'s internals: hold an
    /// exclusive write transaction open on a SECOND connection to the same
    /// on-disk `brain.db` file, from a background thread, for longer than
    /// `Store::open`'s 5000ms `busy_timeout` (see `store.rs`) — this is
    /// exactly the "can't acquire SQLite's lock within its busy_timeout"
    /// scenario the bug report describes, not a contrived injection.
    #[test]
    fn write_note_with_status_surfaces_a_contended_db_write_as_err_not_panic() {
        let dir = tempdir().unwrap();
        let store = Store::open(dir.path()).unwrap();
        let memory = Memory::new(&store, dir.path());

        let blocker_dir = dir.path().to_path_buf();
        let handle = std::thread::spawn(move || {
            let blocker = Store::open(&blocker_dir).unwrap();
            blocker
                .with_transaction(|s| -> rusqlite::Result<()> {
                    // A real write is what actually takes SQLite's write
                    // lock (a bare BEGIN in WAL mode does not). Held well
                    // past the 5000ms busy_timeout (SQLite's busy-wait
                    // backoff can overshoot the nominal timeout slightly on
                    // its last retry, so a tight margin here is flaky) —
                    // this must comfortably outlast the writer's own
                    // busy_timeout retries below.
                    s.set_setting("lock-holder", "1")?;
                    std::thread::sleep(Duration::from_millis(8000));
                    Ok(())
                })
                .unwrap();
        });

        // Give the background thread time to actually acquire the write
        // lock before racing it.
        std::thread::sleep(Duration::from_millis(300));

        let result = memory.write_note_with_status(
            "p1",
            "Should not panic",
            "body",
            Origin::MachineSummary,
            false,
        );

        handle.join().unwrap();

        assert!(
            result.is_err(),
            "a lock-contended DB write must surface as a normal Err, not a panic"
        );
    }

    #[test]
    fn write_note_lands_on_disk_and_as_node() {
        let dir = tempdir().unwrap();
        let store = Store::open(dir.path()).unwrap();
        let memory = Memory::new(&store, dir.path());

        let path = memory
            .write_note(
                "p1",
                "Chose SQLite",
                "Because it is embedded.",
                Origin::UserAuthored,
            )
            .unwrap();

        assert!(path.exists());
        let contents = fs::read_to_string(&path).unwrap();
        assert!(contents.contains("Because it is embedded."));

        let hits = store.search("SQLite", Some("p1"), 10).unwrap();
        assert_eq!(hits.len(), 1);
        assert_eq!(hits[0].origin, Origin::UserAuthored);
    }

    #[test]
    fn write_note_redacts_secrets_before_persisting() {
        let dir = tempdir().unwrap();
        let store = Store::open(dir.path()).unwrap();
        let memory = Memory::new(&store, dir.path());

        let path = memory
            .write_note(
                "p1",
                "Debug session",
                "API_KEY=abc123 was the bug",
                Origin::MachineSummary,
            )
            .unwrap();

        let contents = fs::read_to_string(&path).unwrap();
        assert!(!contents.contains("abc123"));
        assert!(contents.contains("[redacted]"));
    }

    #[test]
    fn write_note_records_origin() {
        let dir = tempdir().unwrap();
        let store = Store::open(dir.path()).unwrap();
        let memory = Memory::new(&store, dir.path());

        memory
            .write_note(
                "p1",
                "Auto summary",
                "did some work",
                Origin::MachineSummary,
            )
            .unwrap();

        let hits = store.search("summary", Some("p1"), 10).unwrap();
        assert_eq!(hits[0].origin, Origin::MachineSummary);
    }

    #[test]
    fn write_note_with_status_pending_lands_with_frontmatter_and_hidden_from_search() {
        let dir = tempdir().unwrap();
        let store = Store::open(dir.path()).unwrap();
        let memory = Memory::new(&store, dir.path());

        let (path, id) = memory
            .write_note_with_status(
                "p1",
                "Session: add auth",
                "did some session work",
                Origin::MachineSummary,
                true,
            )
            .unwrap();

        let contents = fs::read_to_string(&path).unwrap();
        assert!(contents.contains("status: pending\n"), "{contents}");
        assert!(store.is_pending(&id).unwrap());

        // Task 7.1: pending notes are hidden from search until approved.
        let hits = store.search("session", Some("p1"), 10).unwrap();
        assert!(hits.is_empty(), "{hits:?}");

        store.approve_pending(&id).unwrap();
        let hits = store.search("session", Some("p1"), 10).unwrap();
        assert_eq!(hits.len(), 1);
    }

    #[test]
    fn write_note_with_status_false_behaves_like_write_note() {
        let dir = tempdir().unwrap();
        let store = Store::open(dir.path()).unwrap();
        let memory = Memory::new(&store, dir.path());

        let (path, id) = memory
            .write_note_with_status("p1", "Note", "body", Origin::UserAuthored, false)
            .unwrap();

        let contents = fs::read_to_string(&path).unwrap();
        assert!(!contents.contains("status:"), "{contents}");
        assert!(!store.is_pending(&id).unwrap());
    }

    #[test]
    fn mark_note_approved_on_disk_rewrites_the_status_line() {
        let dir = tempdir().unwrap();
        let store = Store::open(dir.path()).unwrap();
        let memory = Memory::new(&store, dir.path());

        let (path, _id) = memory
            .write_note_with_status("p1", "Pending note", "body", Origin::MachineSummary, true)
            .unwrap();

        Memory::mark_note_approved_on_disk(&path);

        let contents = fs::read_to_string(&path).unwrap();
        assert!(contents.contains("status: approved\n"), "{contents}");
        assert!(!contents.contains("status: pending"), "{contents}");
    }
}
