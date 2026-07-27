//! Manual, run-by-hand proof that Part A's file tree write-side commands do
//! the real thing against a real tempdir copy of `fixtures/sample-project`
//! — NOT part of `cargo test`: this mutates a real (if scratch) directory
//! tree AND performs one real delete into the actual macOS system Trash,
//! confirmed via Finder AppleScript and cleaned up again afterward so it
//! doesn't leave test junk in the user's actual Trash (same courtesy the
//! automated `delete_to_trash` tests extend by using a distinctive,
//! obviously-ours filename — see `brain_ingest::fileops`'s test module —
//! except here we go one step further and actually verify+remove it, since
//! that's this task's explicit manual-verification ask).
//!
//! Exercises, in order: `create_file`, `create_dir`, `rename_path`,
//! `move_path`, `duplicate_path` (twice, proving the "copy"/"copy 2" Finder
//! naming), a rejected `../../etc/passwd`-style traversal attempt, and
//! finally a real `delete_to_trash` — verified against `~/.Trash` itself,
//! not just "the file left its original location" (which is all the
//! automated tests can reliably assert in CI-like conditions; see that
//! module's doc comment for why).
//!
//! Run:
//! ```sh
//! cargo run -p omniagent-ade --example manual_fileops_verify
//! ```
use std::path::{Path, PathBuf};
use std::process::Command;

use omniagent_ade_lib::commands::{
    create_dir, create_file, delete_to_trash, duplicate_path, move_path, rename_path,
};

fn copy_dir_recursive(src: &Path, dst: &Path) {
    std::fs::create_dir_all(dst).expect("create_dir_all");
    for entry in std::fs::read_dir(src).expect("read_dir") {
        let entry = entry.expect("dir entry");
        let file_type = entry.file_type().expect("file_type");
        let dest_path = dst.join(entry.file_name());
        if file_type.is_dir() {
            copy_dir_recursive(&entry.path(), &dest_path);
        } else if file_type.is_file() {
            std::fs::copy(entry.path(), &dest_path).expect("copy file");
        }
        // No symlinks in the fixture — nothing else to handle.
    }
}

/// Runs a one-line AppleScript and returns its trimmed stdout. Used only to
/// *observe* the real Finder Trash (query + cleanup) — never to perform the
/// actual delete, which goes through `delete_to_trash` -> the `trash` crate
/// -> `NSFileManager`, exactly like the app does.
fn osascript(script: &str) -> String {
    let out = Command::new("osascript")
        .arg("-e")
        .arg(script)
        .output()
        .expect("run osascript");
    assert!(
        out.status.success(),
        "osascript failed: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    String::from_utf8_lossy(&out.stdout).trim().to_string()
}

/// `count (every item of trash whose name is "<name>")` — an integer that's
/// `0` (never an error) when nothing matches, unlike `get name of every
/// item ...` on an empty result set.
fn count_in_trash(name: &str) -> String {
    osascript(&format!(
        r#"tell application "Finder" to (count (every item of trash whose name is "{name}"))"#
    ))
}

fn main() {
    println!("== manual fileops verify ==");

    let fixture = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("src-tauri has a parent")
        .join("fixtures/sample-project");

    let scratch = std::env::temp_dir().join(format!(
        "omniagent-ade-fileops-verify-{}",
        std::process::id()
    ));
    let project = scratch.join("sample-project");
    println!(
        "copying fixture:\n  from {}\n  to   {}",
        fixture.display(),
        project.display()
    );
    copy_dir_recursive(&fixture, &project);
    let root = project.to_string_lossy().into_owned();

    println!("\n-- create_file / create_dir --");
    let new_file = create_file(root.clone(), root.clone(), "verify-notes.md".to_string())
        .expect("create_file");
    println!("create_file -> {new_file}");
    let new_dir =
        create_dir(root.clone(), root.clone(), "verify-scratch".to_string()).expect("create_dir");
    println!("create_dir  -> {new_dir}");

    println!("\n-- rename_path --");
    let renamed = rename_path(
        root.clone(),
        new_file.clone(),
        "verify-notes-renamed.md".to_string(),
    )
    .expect("rename_path");
    println!("rename_path -> {renamed}");

    println!("\n-- move_path --");
    let moved = move_path(root.clone(), renamed.clone(), new_dir.clone()).expect("move_path");
    println!("move_path   -> {moved}");
    assert!(Path::new(&moved).exists());
    assert!(
        !Path::new(&renamed).exists(),
        "source must be gone after a move"
    );

    println!("\n-- duplicate_path (Finder \"copy\"/\"copy N\" naming) --");
    let dup1 = duplicate_path(root.clone(), moved.clone()).expect("duplicate_path #1");
    println!("duplicate #1 -> {dup1}");
    let dup2 = duplicate_path(root.clone(), moved.clone()).expect("duplicate_path #2");
    println!("duplicate #2 -> {dup2}");
    assert!(dup1.ends_with("copy.md"), "{dup1}");
    assert!(dup2.ends_with("copy 2.md"), "{dup2}");
    assert!(
        Path::new(&moved).exists(),
        "original must survive being duplicated"
    );

    println!("\n-- path-traversal rejection (safety proof) --");
    // Enough `..` segments to actually reach the filesystem root and land on
    // the real `/etc/passwd` (rather than just bottoming out on a
    // not-found), so this demonstrates the "outside the project" rejection
    // specifically — the same one the automated traversal_safety tests in
    // `brain_ingest::fileops` prove exhaustively.
    let up_levels = std::fs::canonicalize(&root)
        .expect("canonicalize root")
        .components()
        .count()
        - 1;
    let traversal = format!("{root}{}/etc/passwd", "/..".repeat(up_levels));
    match delete_to_trash(root.clone(), traversal) {
        Ok(()) => {
            panic!("SAFETY BUG: a ../../etc/passwd-style traversal delete must never succeed")
        }
        Err(e) => println!("correctly rejected: {e}"),
    }
    assert!(
        Path::new("/etc/passwd").exists(),
        "sanity: /etc/passwd must still be untouched"
    );

    println!("\n-- delete_to_trash, verified against the REAL macOS Trash --");
    let trash_name = format!(
        "omniagent-ade-manual-verify-trash-me-{}.txt",
        std::process::id()
    );
    let trash_target =
        create_file(root.clone(), root.clone(), trash_name.clone()).expect("create throwaway file");
    println!("throwaway file: {trash_target}");

    let before = count_in_trash(&trash_name);
    assert_eq!(
        before, "0",
        "sanity: this pid-unique name must not already be in the Trash"
    );

    delete_to_trash(root.clone(), trash_target.clone()).expect("delete_to_trash");
    let gone_from_original_location = !Path::new(&trash_target).exists();
    println!("delete_to_trash returned Ok; gone from its original location: {gone_from_original_location}");
    assert!(gone_from_original_location);

    let after = count_in_trash(&trash_name);
    println!("Finder confirms {after} matching item(s) now in ~/.Trash");
    assert_eq!(
        after, "1",
        "the file must have actually landed in the real system Trash, not vanished"
    );

    println!("cleaning up: permanently removing just this one item from the real Trash ...");
    osascript(&format!(
        r#"tell application "Finder" to delete (every item of trash whose name is "{trash_name}")"#
    ));
    let after_cleanup = count_in_trash(&trash_name);
    println!("Finder confirms {after_cleanup} matching item(s) remain after cleanup");
    assert_eq!(
        after_cleanup, "0",
        "cleanup must have removed the test junk from the real Trash"
    );

    println!("\n== summary ==");
    println!("  create_file / create_dir : ok");
    println!("  rename_path              : ok");
    println!("  move_path                : ok (source gone, dest present)");
    println!("  duplicate_path naming    : ok (\"... copy.md\", \"... copy 2.md\")");
    println!("  traversal rejected       : ok (/etc/passwd untouched)");
    println!(
        "  delete_to_trash          : ok — confirmed present in real ~/.Trash, then cleaned up"
    );
    println!(
        "\nscratch project dir left on disk for inspection: {}",
        project.display()
    );
}
