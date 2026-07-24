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
        let contents = format!("---\norigin: {origin_str}\n---\n\n# {title}\n\n{redacted_body}\n");
        fs::write(&path, &contents)?;

        let id = format!("{project}:memory:{filename}");
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
            .expect("brain db write failed");

        for target in extract_relative_links(&redacted_body) {
            let dst_id = format!("{project}:doc:{target}");
            let _ = self.store.upsert_edge(&Edge {
                src: id.clone(),
                dst: dst_id,
                kind: EdgeKind::LinksTo,
                weight: 1.0,
            });
        }

        Ok(path)
    }

    pub fn read_all(&self, project: &str) -> io::Result<Vec<PathBuf>> {
        let project_dir = self.brain_dir.join(project);
        if !project_dir.exists() {
            return Ok(vec![]);
        }
        let mut paths: Vec<PathBuf> = fs::read_dir(&project_dir)?
            .filter_map(|e| e.ok())
            .map(|e| e.path())
            .filter(|p| p.extension().map(|e| e == "md").unwrap_or(false))
            .collect();
        paths.sort();
        Ok(paths)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::store::Origin;
    use tempfile::tempdir;

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
}
