//! Small path utilities shared by the ingestion passes (code/docs/gitmine).
//! Everything here works on project-relative, forward-slash ("posix") path
//! strings so node ids are stable across the walker's absolute paths.

use std::path::Path;

/// `file`'s path relative to `root`, rendered with forward slashes.
/// `None` if `file` isn't under `root` at all.
pub(crate) fn rel_posix(root: &Path, file: &Path) -> Option<String> {
    let rel = file.strip_prefix(root).ok()?;
    Some(
        rel.components()
            .map(|c| c.as_os_str().to_string_lossy().into_owned())
            .collect::<Vec<_>>()
            .join("/"),
    )
}

/// The directory portion of a relative posix path ("" for a top-level file).
pub(crate) fn parent_dir(rel: &str) -> String {
    match rel.rfind('/') {
        Some(i) => rel[..i].to_string(),
        None => String::new(),
    }
}

/// Joins `dir` with a relative `spec` (which may use `.`/`..`), normalizing
/// the result to a posix path with no `.`/`..` segments. Doesn't touch disk —
/// callers check the result against the set of files actually walked.
pub(crate) fn normalize_join(dir: &str, spec: &str) -> String {
    let mut parts: Vec<&str> = if dir.is_empty() {
        Vec::new()
    } else {
        dir.split('/').collect()
    };
    for comp in spec.split('/') {
        match comp {
            "" | "." => {}
            ".." => {
                parts.pop();
            }
            other => parts.push(other),
        }
    }
    parts.join("/")
}

/// Turns a Rust-style dotted module path segment (`foo.bar`) into a posix
/// path segment (`foo/bar`). Used by the Python import resolver.
pub(crate) fn dotted_to_path(dotted: &str) -> String {
    dotted.replace('.', "/")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rel_posix_strips_root_and_uses_forward_slashes() {
        let root = Path::new("/tmp/proj");
        let file = Path::new("/tmp/proj/src/auth.ts");
        assert_eq!(rel_posix(root, file).as_deref(), Some("src/auth.ts"));
    }

    #[test]
    fn parent_dir_handles_top_level_and_nested() {
        assert_eq!(parent_dir("README.md"), "");
        assert_eq!(parent_dir("src/auth.ts"), "src");
        assert_eq!(parent_dir("a/b/c.rs"), "a/b");
    }

    #[test]
    fn normalize_join_resolves_dot_and_dotdot() {
        assert_eq!(normalize_join("src", "./util"), "src/util");
        assert_eq!(normalize_join("src/inner", "../util"), "src/util");
        assert_eq!(normalize_join("", "docs/notes.md"), "docs/notes.md");
    }
}
