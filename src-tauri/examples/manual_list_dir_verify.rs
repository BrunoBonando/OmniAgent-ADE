//! Manual, run-by-hand proof that `list_dir` (via `brain_ingest::walk::
//! list_dir`) does the real, gitignore-aware thing against real directories
//! on disk — NOT part of `cargo test` (deliberately points at this very
//! repo's own working tree rather than a synthetic fixture, so the proof is
//! "does it behave sanely on a real project a founder would actually open,"
//! matching this task's manual-verification ask).
//!
//! Prints two listings:
//! 1. This repo's root — proves `target/` (SKIP_DIRS) and `.git` (hidden
//!    dotfile default) never show up, while real source dirs/files do.
//! 2. `ui/` — the concrete case named in the task: a directory that
//!    directly contains a real `node_modules/`, which must NOT appear.
//!
//! Run:
//! ```sh
//! cargo run -p omniagent-ade --example manual_list_dir_verify
//! ```
use std::path::PathBuf;

fn repo_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("src-tauri has a parent")
        .to_path_buf()
}

fn print_listing(label: &str, dir: &std::path::Path) {
    println!("\n== {label} ({}) ==", dir.display());
    match brain_ingest::walk::list_dir(dir) {
        Ok(entries) => {
            for e in &entries {
                println!("  {}  {}", if e.is_dir { "dir " } else { "file" }, e.name);
            }
            println!("  ({} entries)", entries.len());
        }
        Err(e) => println!("  ERROR: {e}"),
    }
}

fn main() {
    println!("== manual list_dir verify ==");
    let root = repo_root();

    print_listing("repo root", &root);
    print_listing("ui/ (must NOT show node_modules)", &root.join("ui"));

    // A path that doesn't exist at all — the graceful-error path.
    print_listing("a path that doesn't exist", &root.join("no-such-directory-here"));

    // A path that's a file, not a directory — also graceful-error.
    print_listing("a path that's a file, not a dir", &root.join("Cargo.toml"));
}
