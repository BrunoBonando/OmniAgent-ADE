//! File-management operations for the file tree panel — the write/mutate
//! side of [`crate::walk::list_dir`]'s read-only single-level listing.
//! Founder feedback, 2026-07-25 (verbatim): "make sure the file view works
//! correctly, with it's own file visualization. It must work exactly like
//! the Finder from Mac OS." This module is the backend layer only; the
//! Finder-like UI (icons, context menu, drag-and-drop, multi-select, rename
//! UI) is a follow-up task on top of what's here.
//!
//! `src-tauri/src/commands.rs` wraps every `pub fn` below in a thin
//! `#[tauri::command]`, same split as `walk::list_dir` /
//! `commands::list_dir`.
//!
//! ## Safety model — read this before touching anything below
//!
//! These operations are real, destructive filesystem mutations (delete,
//! move, rename) against the user's actual project files. Every one of them
//! is scoped to a `project_root`: the frontend always knows which project's
//! file tree it's acting on (`ProjectInfo.path`), and every source and
//! destination path must resolve — via [`std::fs::canonicalize`], which also
//! resolves symlinks — to somewhere inside that root before any mutation
//! happens. This blocks both classic `../../..` traversal *and* symlink
//! tricks (a symlink physically inside the project whose target points
//! outside it): canonicalizing follows the symlink, so the resulting path is
//! checked against the *real* location, not the deceptive in-project one.
//! See [`within_root`]/[`within_root_as_child`] and the `traversal_safety`
//! test module below.
//!
//! The project root itself is never a valid *source* for rename/move/
//! duplicate/delete ([`within_root_as_child`]) — renaming or moving it would
//! place the result outside the root by construction (its new location is
//! computed relative to its *parent*, which sits above the root), and
//! deleting it would delete the whole project. It's still a valid
//! *destination directory* for move/create (you can drop a file directly
//! into the project root), which is what plain [`within_root`] is for.
//!
//! ## Never a permanent delete
//!
//! [`delete_to_trash`] goes through the `trash` crate exclusively — never
//! `std::fs::remove_file`/`remove_dir_all`. On macOS this moves the item to
//! `~/.Trash` via `NSFileManager.trashItemAtURL`, explicitly selected over
//! the crate's default `Finder`/AppleScript method (see
//! [`macos_trash_context`]'s doc comment for why). There is no code path in
//! this module that permanently unlinks a user's file.
//!
//! ## Collision policy
//!
//! Renaming/moving/creating onto an existing name is a hard error (`Err`),
//! never a silent overwrite. [`create_file`]/[`create_dir`] likewise error
//! on a name collision rather than auto-incrementing to an "untitled 2"
//! style name — simpler, and the frontend is better placed to prompt the
//! user for a name than to guess one for them. [`duplicate_path`] is the one
//! exception, by design: Finder's own "Duplicate" always succeeds by
//! picking the next free "copy"/"copy N" name rather than erroring.

use std::path::{Path, PathBuf};

// --------------------------------------------------------------- helpers

/// Canonicalizes `root` (the project root every operation is scoped to),
/// mapping the `io::Error` to a friendly message.
fn canonical_root(root: &Path) -> Result<PathBuf, String> {
    std::fs::canonicalize(root).map_err(|e| friendly_io_error(root, &e))
}

/// Canonicalizes `target` (which must already exist on disk) and verifies
/// the resolved path falls inside `canonical_root` — the core traversal/
/// symlink check shared by every operation in this module. Returns the
/// canonical target path on success. `canonical_root` must already be
/// canonicalized (see [`canonical_root`]) — this function does not
/// re-canonicalize it, so callers compute it once per command and reuse it
/// across however many paths that command needs to validate.
fn within_root(canonical_root: &Path, target: &Path) -> Result<PathBuf, String> {
    let canonical_target =
        std::fs::canonicalize(target).map_err(|e| friendly_io_error(target, &e))?;
    if !canonical_target.starts_with(canonical_root) {
        return Err(format!(
            "{} is outside the project and cannot be modified",
            target.display()
        ));
    }
    Ok(canonical_target)
}

/// Like [`within_root`], but additionally rejects `target` when it resolves
/// to `canonical_root` itself. Use this for the SOURCE of an in-place
/// mutation (rename/move/duplicate/delete) — see the module doc's "Safety
/// model" section for why the project root can't be one of those. Plain
/// [`within_root`] (equality allowed) is still correct for a destination
/// *directory* argument (`new_parent_dir`/`parent_dir`).
fn within_root_as_child(canonical_root: &Path, target: &Path) -> Result<PathBuf, String> {
    let canonical_target = within_root(canonical_root, target)?;
    if canonical_target == canonical_root {
        return Err("the project root itself cannot be modified".to_string());
    }
    Ok(canonical_target)
}

fn friendly_io_error(path: &Path, e: &std::io::Error) -> String {
    use std::io::ErrorKind::*;
    match e.kind() {
        NotFound => format!("{} does not exist", path.display()),
        PermissionDenied => format!("permission denied: {}", path.display()),
        _ => format!("couldn't access {}: {e}", path.display()),
    }
}

/// A bare filename for `rename_path`/`create_file`/`create_dir` — never a
/// path. Rejects anything that would let a "name" smuggle in a directory
/// traversal (a `new_name` containing `/` is a move, not a rename — see
/// [`rename_path`]'s doc comment).
fn validate_bare_name(name: &str) -> Result<(), String> {
    if name.is_empty() {
        return Err("name cannot be empty".to_string());
    }
    if name == "." || name == ".." {
        return Err(format!("\"{name}\" is not a valid name"));
    }
    if name.contains('/') {
        return Err(
            "name cannot contain a path separator — use move_path to relocate a file".to_string(),
        );
    }
    Ok(())
}

/// True if anything at all — including a broken symlink — already occupies
/// `path`. Deliberately not [`Path::exists`], which follows symlinks and
/// silently reports `false` for a dangling one, which would let a collision
/// check miss an already-occupied name.
fn occupied(path: &Path) -> bool {
    std::fs::symlink_metadata(path).is_ok()
}

// ------------------------------------------------------------------ rename

/// Renames a file/folder in place (same parent directory). `new_name` is a
/// bare filename, not a path — anything containing a path separator is
/// rejected, since that's a move, not a rename (use [`move_path`] instead).
/// Returns the new full (canonical) path on success. Errors, never silently
/// overwrites, if something already exists at the destination name.
pub fn rename_path(project_root: &Path, path: &Path, new_name: &str) -> Result<PathBuf, String> {
    validate_bare_name(new_name)?;
    let root = canonical_root(project_root)?;
    let source = within_root_as_child(&root, path)?;

    // `source` passed `within_root_as_child`, so it's a strict descendant of
    // `root` — its parent is therefore always within `root` too (it's a
    // shorter prefix of an already-validated path), no separate check
    // needed.
    let parent = source
        .parent()
        .ok_or_else(|| format!("{} has no parent directory", source.display()))?;
    let dest = parent.join(new_name);

    if occupied(&dest) {
        return Err(format!("a file named \"{new_name}\" already exists"));
    }

    std::fs::rename(&source, &dest).map_err(|e| friendly_io_error(&source, &e))?;
    Ok(dest)
}

// -------------------------------------------------------------------- move

/// Moves a file/folder into a different directory (same basename, new
/// parent) — what drag-and-drop-to-reparent in the frontend calls. Returns
/// the new full (canonical) path on success.
pub fn move_path(
    project_root: &Path,
    path: &Path,
    new_parent_dir: &Path,
) -> Result<PathBuf, String> {
    let root = canonical_root(project_root)?;
    let source = within_root_as_child(&root, path)?;
    let dest_parent = within_root(&root, new_parent_dir)?;

    if !dest_parent.is_dir() {
        return Err(format!("{} is not a directory", new_parent_dir.display()));
    }
    // Moving a folder into itself or one of its own descendants would
    // otherwise succeed at the OS level in confusing ways (or fail with an
    // opaque `rename` error) — reject it up front with a clear message.
    if dest_parent.starts_with(&source) {
        return Err("cannot move a folder into itself or one of its own subfolders".to_string());
    }

    let file_name = source
        .file_name()
        .ok_or_else(|| format!("{} has no file name", source.display()))?;
    let dest = dest_parent.join(file_name);

    if occupied(&dest) {
        return Err(format!(
            "a file named \"{}\" already exists in the destination",
            file_name.to_string_lossy()
        ));
    }

    std::fs::rename(&source, &dest).map_err(|e| friendly_io_error(&source, &e))?;
    Ok(dest)
}

// ------------------------------------------------------------- duplicate

/// Builds the next free Finder-style "copy" name for `original` next to
/// itself: `file.txt` -> `file copy.txt` -> `file copy 2.txt` -> `file copy
/// 3.txt` ... A file's extension is (like Finder/`Path::extension`) only the
/// last `.`-delimited suffix, so `archive.tar.gz` -> `archive.tar copy.gz`,
/// matching Finder's actual behavior rather than naively splitting on the
/// first dot. `exists` is injected so this stays pure/testable without
/// touching disk.
fn next_copy_name(original: &Path, exists: impl Fn(&Path) -> bool) -> PathBuf {
    let parent = original.parent().unwrap_or_else(|| Path::new(""));
    let stem = original
        .file_stem()
        .map(|s| s.to_string_lossy().into_owned())
        .unwrap_or_default();
    let ext = original
        .extension()
        .map(|s| s.to_string_lossy().into_owned());

    let build = |suffix: &str| -> PathBuf {
        let name = match &ext {
            Some(ext) => format!("{stem}{suffix}.{ext}"),
            None => format!("{stem}{suffix}"),
        };
        parent.join(name)
    };

    let mut candidate = build(" copy");
    let mut n = 2;
    while exists(&candidate) {
        candidate = build(&format!(" copy {n}"));
        n += 1;
    }
    candidate
}

/// Copies a file, or recursively copies a directory (symlinks inside a
/// duplicated directory are preserved as symlinks, not followed/flattened —
/// matches Finder), into the same parent with the next free Finder-style
/// "copy" name (see [`next_copy_name`]). Returns the new full (canonical)
/// path on success. Unlike every other write op here, this one is designed
/// to always succeed on a name collision (there is no "collision" — it just
/// picks the next free name), matching Finder's own Duplicate behavior.
pub fn duplicate_path(project_root: &Path, path: &Path) -> Result<PathBuf, String> {
    let root = canonical_root(project_root)?;
    let source = within_root_as_child(&root, path)?;

    let dest = next_copy_name(&source, occupied);

    if source.is_dir() {
        copy_dir_recursive(&source, &dest)?;
    } else {
        std::fs::copy(&source, &dest).map_err(|e| friendly_io_error(&source, &e))?;
    }
    Ok(dest)
}

fn copy_dir_recursive(src: &Path, dst: &Path) -> Result<(), String> {
    std::fs::create_dir(dst).map_err(|e| friendly_io_error(dst, &e))?;
    for entry in std::fs::read_dir(src).map_err(|e| friendly_io_error(src, &e))? {
        let entry = entry.map_err(|e| friendly_io_error(src, &e))?;
        let entry_path = entry.path();
        let file_type = entry
            .file_type()
            .map_err(|e| friendly_io_error(&entry_path, &e))?;
        let dest_path = dst.join(entry.file_name());

        if file_type.is_symlink() {
            let target = std::fs::read_link(&entry_path)
                .map_err(|e| friendly_io_error(&entry_path, &e))?;
            std::os::unix::fs::symlink(&target, &dest_path)
                .map_err(|e| friendly_io_error(&dest_path, &e))?;
        } else if file_type.is_dir() {
            copy_dir_recursive(&entry_path, &dest_path)?;
        } else {
            std::fs::copy(&entry_path, &dest_path).map_err(|e| friendly_io_error(&entry_path, &e))?;
        }
    }
    Ok(())
}

// --------------------------------------------------------------- delete

/// Selects the `NsFileManager` delete method over the `trash` crate's
/// default `Finder`/AppleScript method on macOS. The default shells out to
/// `osascript` to ask the Finder app to delete the file — which requires
/// Automation permission for whatever process calls it (a permission
/// dialog neither an automated test run nor, on first use, the app itself
/// can click through), plays a sound, and is measurably slower.
/// `NsFileManager` calls `NSFileManager.trashItemAtURL` directly: no extra
/// permission prompt, no sound, moves the item to the same real `~/.Trash`
/// Finder itself uses (still shows "Put Back" in Finder — see the `trash`
/// crate's own `DeleteMethod` doc comment) — and, critically, works
/// headlessly, which is what makes it reliably testable at all.
fn macos_trash_context() -> trash::TrashContext {
    let mut ctx = trash::TrashContext::new();
    #[cfg(target_os = "macos")]
    {
        use trash::macos::{DeleteMethod, TrashContextExtMacos};
        ctx.set_delete_method(DeleteMethod::NsFileManager);
    }
    ctx
}

/// Moves the file/folder to the macOS system Trash — **never** a permanent/
/// hard delete. Goes through the `trash` crate exclusively (see the module
/// doc's "Never a permanent delete" section) so an accidental delete is
/// always recoverable exactly the way Finder's delete is.
pub fn delete_to_trash(project_root: &Path, path: &Path) -> Result<(), String> {
    let root = canonical_root(project_root)?;
    let source = within_root_as_child(&root, path)?;
    macos_trash_context()
        .delete(&source)
        .map_err(|e| friendly_trash_error(&source, e))
}

/// Maps `trash::Error` to a clean message rather than leaning on its own
/// `Display` impl, which embeds `{self:?}` (raw `Debug`) verbatim — exactly
/// the "raw OS error debug string" this module's callers (the frontend)
/// must not be shown.
fn friendly_trash_error(path: &Path, err: trash::Error) -> String {
    use trash::Error::*;
    match err {
        Os { description, .. } => format!("couldn't move {} to Trash: {description}", path.display()),
        CouldNotAccess { target } => format!("{target} doesn't exist or can't be accessed"),
        TargetedRoot => format!("{} is a root folder and cannot be moved to Trash", path.display()),
        Unknown { description } => format!("couldn't move {} to Trash: {description}", path.display()),
        CanonicalizePath { original } => format!("couldn't resolve {}", original.display()),
        ConvertOsString { .. } => format!("{} has a name Trash can't handle", path.display()),
        other => format!("couldn't move {} to Trash: {other:?}", path.display()),
    }
}

// --------------------------------------------------------------- create

/// Creates a new empty file named `name` inside `parent_dir`. Errors on a
/// name collision (see the module doc's "Collision policy") rather than
/// auto-incrementing an "untitled 2" style name — the frontend prompts.
/// Returns the new full (canonical) path on success.
pub fn create_file(project_root: &Path, parent_dir: &Path, name: &str) -> Result<PathBuf, String> {
    let dest = prepare_create(project_root, parent_dir, name, "file")?;
    std::fs::File::create(&dest).map_err(|e| friendly_io_error(&dest, &e))?;
    Ok(dest)
}

/// Creates a new empty folder named `name` inside `parent_dir`. Same
/// collision policy as [`create_file`]. Returns the new full (canonical)
/// path on success.
pub fn create_dir(project_root: &Path, parent_dir: &Path, name: &str) -> Result<PathBuf, String> {
    let dest = prepare_create(project_root, parent_dir, name, "folder")?;
    std::fs::create_dir(&dest).map_err(|e| friendly_io_error(&dest, &e))?;
    Ok(dest)
}

/// Shared validation for `create_file`/`create_dir`: bare-name check,
/// root-scoped `parent_dir` check, "is actually a directory" check, and the
/// collision check — `kind` ("file"/"folder") only changes the collision
/// error's wording.
fn prepare_create(
    project_root: &Path,
    parent_dir: &Path,
    name: &str,
    kind: &str,
) -> Result<PathBuf, String> {
    validate_bare_name(name)?;
    let root = canonical_root(project_root)?;
    let parent = within_root(&root, parent_dir)?;
    if !parent.is_dir() {
        return Err(format!("{} is not a directory", parent_dir.display()));
    }
    let dest = parent.join(name);
    if occupied(&dest) {
        return Err(format!("a {kind} named \"{name}\" already exists"));
    }
    Ok(dest)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use tempfile::tempdir;

    /// Canonicalizes `p` for comparison in tests — tempdir roots themselves
    /// often sit behind a symlink on macOS (`/var` -> `/private/var`), and
    /// every function under test returns a canonical path, so assertions
    /// need to compare like with like.
    fn canon(p: &Path) -> PathBuf {
        std::fs::canonicalize(p).unwrap()
    }

    // ------------------------------------------------------------- rename

    #[test]
    fn rename_path_renames_a_file_in_place() {
        let root = tempdir().unwrap();
        let file = root.path().join("a.txt");
        fs::write(&file, "hi").unwrap();

        let new_path = rename_path(root.path(), &file, "b.txt").unwrap();

        assert_eq!(new_path, canon(root.path()).join("b.txt"));
        assert!(!file.exists());
        assert_eq!(fs::read_to_string(&new_path).unwrap(), "hi");
    }

    #[test]
    fn rename_path_renames_a_directory_in_place() {
        let root = tempdir().unwrap();
        let dir = root.path().join("olddir");
        fs::create_dir(&dir).unwrap();
        fs::write(dir.join("inner.txt"), "x").unwrap();

        let new_path = rename_path(root.path(), &dir, "newdir").unwrap();

        assert_eq!(new_path, canon(root.path()).join("newdir"));
        assert!(new_path.join("inner.txt").exists());
    }

    #[test]
    fn rename_path_rejects_a_new_name_containing_a_path_separator() {
        let root = tempdir().unwrap();
        let file = root.path().join("a.txt");
        fs::write(&file, "hi").unwrap();

        let err = rename_path(root.path(), &file, "sub/b.txt").unwrap_err();
        assert!(err.contains("path separator"), "{err}");
        assert!(file.exists(), "original must be untouched on rejection");
    }

    #[test]
    fn rename_path_rejects_empty_or_dot_names() {
        let root = tempdir().unwrap();
        let file = root.path().join("a.txt");
        fs::write(&file, "hi").unwrap();

        assert!(rename_path(root.path(), &file, "").is_err());
        assert!(rename_path(root.path(), &file, ".").is_err());
        assert!(rename_path(root.path(), &file, "..").is_err());
    }

    #[test]
    fn rename_path_errors_clearly_on_collision_and_does_not_overwrite() {
        let root = tempdir().unwrap();
        let a = root.path().join("a.txt");
        let b = root.path().join("b.txt");
        fs::write(&a, "A").unwrap();
        fs::write(&b, "B").unwrap();

        let err = rename_path(root.path(), &a, "b.txt").unwrap_err();
        assert!(err.contains("already exists"), "{err}");
        assert!(a.exists(), "source must be untouched");
        assert_eq!(fs::read_to_string(&b).unwrap(), "B", "destination must not be overwritten");
    }

    #[test]
    fn rename_path_rejects_renaming_the_project_root_itself() {
        let root = tempdir().unwrap();
        let err = rename_path(root.path(), root.path(), "renamed").unwrap_err();
        assert!(err.contains("root"), "{err}");
    }

    // --------------------------------------------------------------- move

    #[test]
    fn move_path_moves_a_file_into_a_different_directory() {
        let root = tempdir().unwrap();
        let file = root.path().join("a.txt");
        fs::write(&file, "hi").unwrap();
        let dest_dir = root.path().join("subdir");
        fs::create_dir(&dest_dir).unwrap();

        let new_path = move_path(root.path(), &file, &dest_dir).unwrap();

        assert_eq!(new_path, canon(&dest_dir).join("a.txt"));
        assert!(!file.exists());
        assert_eq!(fs::read_to_string(&new_path).unwrap(), "hi");
    }

    #[test]
    fn move_path_errors_clearly_on_collision_and_does_not_overwrite() {
        let root = tempdir().unwrap();
        let file = root.path().join("a.txt");
        fs::write(&file, "source").unwrap();
        let dest_dir = root.path().join("subdir");
        fs::create_dir(&dest_dir).unwrap();
        fs::write(dest_dir.join("a.txt"), "existing").unwrap();

        let err = move_path(root.path(), &file, &dest_dir).unwrap_err();
        assert!(err.contains("already exists"), "{err}");
        assert!(file.exists(), "source must be untouched");
        assert_eq!(fs::read_to_string(dest_dir.join("a.txt")).unwrap(), "existing");
    }

    #[test]
    fn move_path_rejects_moving_a_directory_into_its_own_descendant() {
        let root = tempdir().unwrap();
        let parent = root.path().join("parent");
        let child = parent.join("child");
        fs::create_dir_all(&child).unwrap();

        let err = move_path(root.path(), &parent, &child).unwrap_err();
        assert!(err.contains("itself"), "{err}");
        assert!(parent.exists());
    }

    #[test]
    fn move_path_rejects_a_non_directory_destination() {
        let root = tempdir().unwrap();
        let file = root.path().join("a.txt");
        fs::write(&file, "hi").unwrap();
        let not_a_dir = root.path().join("b.txt");
        fs::write(&not_a_dir, "x").unwrap();

        let err = move_path(root.path(), &file, &not_a_dir).unwrap_err();
        assert!(err.contains("not a directory"), "{err}");
    }

    #[test]
    fn move_path_rejects_moving_the_project_root_itself() {
        let root = tempdir().unwrap();
        let dest = root.path().join("dest");
        fs::create_dir(&dest).unwrap();
        let err = move_path(root.path(), root.path(), &dest).unwrap_err();
        assert!(err.contains("root"), "{err}");
    }

    // ---------------------------------------------------------- duplicate

    #[test]
    fn next_copy_name_follows_finder_convention() {
        let mut taken = std::collections::HashSet::new();

        let first = next_copy_name(Path::new("/p/file.txt"), |p| taken.contains(p));
        assert_eq!(first, PathBuf::from("/p/file copy.txt"));
        taken.insert(first);

        let second = next_copy_name(Path::new("/p/file.txt"), |p| taken.contains(p));
        assert_eq!(second, PathBuf::from("/p/file copy 2.txt"));
        taken.insert(second);

        let third = next_copy_name(Path::new("/p/file.txt"), |p| taken.contains(p));
        assert_eq!(third, PathBuf::from("/p/file copy 3.txt"));
    }

    #[test]
    fn next_copy_name_handles_no_extension_and_multi_dot_extension() {
        let none = |_: &Path| false;
        assert_eq!(
            next_copy_name(Path::new("/p/folder"), none),
            PathBuf::from("/p/folder copy")
        );
        // Only the LAST dot-suffix is the "extension" — matches Finder/
        // `Path::extension`, not a naive first-dot split.
        assert_eq!(
            next_copy_name(Path::new("/p/archive.tar.gz"), none),
            PathBuf::from("/p/archive.tar copy.gz")
        );
    }

    #[test]
    fn duplicate_path_copies_a_file_with_finder_copy_naming() {
        let root = tempdir().unwrap();
        let file = root.path().join("file.txt");
        fs::write(&file, "hello").unwrap();

        let first = duplicate_path(root.path(), &file).unwrap();
        assert_eq!(first, canon(root.path()).join("file copy.txt"));
        assert_eq!(fs::read_to_string(&first).unwrap(), "hello");

        let second = duplicate_path(root.path(), &file).unwrap();
        assert_eq!(second, canon(root.path()).join("file copy 2.txt"));

        // The original is untouched by either duplicate.
        assert!(file.exists());
    }

    #[test]
    fn duplicate_path_recursively_copies_a_directory() {
        let root = tempdir().unwrap();
        let dir = root.path().join("proj");
        fs::create_dir_all(dir.join("nested")).unwrap();
        fs::write(dir.join("a.txt"), "A").unwrap();
        fs::write(dir.join("nested/b.txt"), "B").unwrap();

        let dup = duplicate_path(root.path(), &dir).unwrap();

        assert_eq!(dup, canon(root.path()).join("proj copy"));
        assert_eq!(fs::read_to_string(dup.join("a.txt")).unwrap(), "A");
        assert_eq!(fs::read_to_string(dup.join("nested/b.txt")).unwrap(), "B");
        // Original untouched.
        assert!(dir.join("a.txt").exists());
    }

    #[test]
    fn duplicate_path_rejects_duplicating_the_project_root_itself() {
        let root = tempdir().unwrap();
        let err = duplicate_path(root.path(), root.path()).unwrap_err();
        assert!(err.contains("root"), "{err}");
    }

    // ------------------------------------------------------------ delete

    // Distinctive, unambiguously-ours name prefix for anything these tests
    // send to the REAL system Trash (this is a real `trash::delete` call,
    // not a mock — see the module doc's "Never a permanent delete" section
    // and `delete_to_trash`'s own doc comment on why `NsFileManager` was
    // chosen). Keeping the trashed basename distinctive (rather than
    // something generic like "throwaway.txt") makes end-of-task Trash
    // cleanup unambiguous — see the manual verification example.
    const TRASH_TEST_PREFIX: &str = "omniagent-ade-fileops-test-trash-me";

    #[test]
    fn delete_to_trash_removes_the_file_from_its_original_location() {
        let root = tempdir().unwrap();
        let file = root.path().join(format!("{TRASH_TEST_PREFIX}.txt"));
        fs::write(&file, "bye").unwrap();

        delete_to_trash(root.path(), &file).unwrap();

        assert!(!file.exists(), "file must be gone from its original location");
    }

    #[test]
    fn delete_to_trash_removes_a_directory_from_its_original_location() {
        let root = tempdir().unwrap();
        let dir = root.path().join(format!("{TRASH_TEST_PREFIX}-dir"));
        fs::create_dir(&dir).unwrap();
        fs::write(dir.join("inner.txt"), "x").unwrap();

        delete_to_trash(root.path(), &dir).unwrap();

        assert!(!dir.exists());
    }

    #[test]
    fn delete_to_trash_rejects_deleting_the_project_root_itself() {
        let root = tempdir().unwrap();
        let err = delete_to_trash(root.path(), root.path()).unwrap_err();
        assert!(err.contains("root"), "{err}");
        assert!(root.path().exists(), "root must survive the rejected call");
    }

    // ------------------------------------------------------------ create

    #[test]
    fn create_file_makes_an_empty_file() {
        let root = tempdir().unwrap();
        let new_path = create_file(root.path(), root.path(), "new.txt").unwrap();
        assert_eq!(new_path, canon(root.path()).join("new.txt"));
        assert_eq!(fs::read_to_string(&new_path).unwrap(), "");
    }

    #[test]
    fn create_file_errors_clearly_on_collision() {
        let root = tempdir().unwrap();
        fs::write(root.path().join("new.txt"), "existing").unwrap();
        let err = create_file(root.path(), root.path(), "new.txt").unwrap_err();
        assert!(err.contains("already exists"), "{err}");
        assert_eq!(fs::read_to_string(root.path().join("new.txt")).unwrap(), "existing");
    }

    #[test]
    fn create_dir_makes_an_empty_folder() {
        let root = tempdir().unwrap();
        let new_path = create_dir(root.path(), root.path(), "newdir").unwrap();
        assert_eq!(new_path, canon(root.path()).join("newdir"));
        assert!(new_path.is_dir());
    }

    #[test]
    fn create_dir_errors_clearly_on_collision() {
        let root = tempdir().unwrap();
        fs::create_dir(root.path().join("newdir")).unwrap();
        let err = create_dir(root.path(), root.path(), "newdir").unwrap_err();
        assert!(err.contains("already exists"), "{err}");
    }

    #[test]
    fn create_file_rejects_a_bare_name_containing_a_path_separator() {
        let root = tempdir().unwrap();
        let err = create_file(root.path(), root.path(), "sub/new.txt").unwrap_err();
        assert!(err.contains("path separator"), "{err}");
    }

    // -------------------------------------------------------- error messages

    #[test]
    fn errors_are_friendly_not_raw_debug_strings() {
        let root = tempdir().unwrap();
        let missing = root.path().join("does-not-exist.txt");

        let err = rename_path(root.path(), &missing, "b.txt").unwrap_err();
        assert!(!err.contains('{'), "looks like a raw Debug dump: {err}");
        assert!(err.contains("does not exist"), "{err}");
    }

    // --------------------------------------------------------- traversal_safety

    mod traversal_safety {
        use super::*;

        #[test]
        fn rejects_dotdot_traversal_out_of_the_root_for_every_op() {
            let root = tempdir().unwrap();
            let outside = tempdir().unwrap();
            let secret = outside.path().join("secret.txt");
            fs::write(&secret, "top secret").unwrap();

            // Reach `secret.txt` via `<root>/../<outside-dir-name>/secret.txt`
            // style traversal through the root itself.
            let traversal_path = root
                .path()
                .join("..")
                .join(outside.path().file_name().unwrap())
                .join("secret.txt");
            // Sanity: this really does point at the real file (canonicalizes
            // successfully) — the rejection must come from the root check,
            // not from the path simply not resolving.
            assert_eq!(std::fs::canonicalize(&traversal_path).unwrap(), canon(&secret));

            let rename_err = rename_path(root.path(), &traversal_path, "pwned.txt").unwrap_err();
            assert!(rename_err.contains("outside"), "{rename_err}");

            let delete_err = delete_to_trash(root.path(), &traversal_path).unwrap_err();
            assert!(delete_err.contains("outside"), "{delete_err}");

            let dup_err = duplicate_path(root.path(), &traversal_path).unwrap_err();
            assert!(dup_err.contains("outside"), "{dup_err}");

            let inside_dir = root.path().join("subdir");
            fs::create_dir(&inside_dir).unwrap();
            let move_err = move_path(root.path(), &traversal_path, &inside_dir).unwrap_err();
            assert!(move_err.contains("outside"), "{move_err}");

            // File must be completely untouched by every rejected attempt.
            assert_eq!(fs::read_to_string(&secret).unwrap(), "top secret");
        }

        #[test]
        fn rejects_a_classic_etc_passwd_style_traversal_string() {
            let root = tempdir().unwrap();
            let traversal = format!("{}/../../../../../../etc/passwd", root.path().display());
            let err = delete_to_trash(root.path(), Path::new(&traversal)).unwrap_err();
            // Whatever the exact message, it must not succeed, and
            // `/etc/passwd` must still be there.
            assert!(std::path::Path::new("/etc/passwd").exists(), "sanity: /etc/passwd exists");
            let _ = err; // rejection is the assertion; message wording isn't load-bearing here
        }

        #[test]
        fn rejects_a_destination_directory_reached_via_dotdot_traversal() {
            let root = tempdir().unwrap();
            let file = root.path().join("a.txt");
            fs::write(&file, "hi").unwrap();
            let outside = tempdir().unwrap();

            let traversal_dest = root
                .path()
                .join("..")
                .join(outside.path().file_name().unwrap());
            assert_eq!(std::fs::canonicalize(&traversal_dest).unwrap(), canon(outside.path()));

            let err = move_path(root.path(), &file, &traversal_dest).unwrap_err();
            assert!(err.contains("outside"), "{err}");
            assert!(file.exists(), "source must be untouched");
        }

        #[test]
        fn rejects_a_symlink_inside_the_root_pointing_outside_it() {
            let root = tempdir().unwrap();
            let outside = tempdir().unwrap();
            let secret = outside.path().join("secret.txt");
            fs::write(&secret, "top secret").unwrap();

            // A symlink physically located INSIDE the project root, but
            // whose target lives OUTSIDE it — the classic symlink-escape
            // trick. `canonicalize` must resolve through it.
            let link = root.path().join("sneaky-link");
            std::os::unix::fs::symlink(&secret, &link).unwrap();

            let rename_err = rename_path(root.path(), &link, "pwned.txt").unwrap_err();
            assert!(rename_err.contains("outside"), "{rename_err}");

            let delete_err = delete_to_trash(root.path(), &link).unwrap_err();
            assert!(delete_err.contains("outside"), "{delete_err}");

            assert_eq!(fs::read_to_string(&secret).unwrap(), "top secret");
        }

        #[test]
        fn rejects_a_symlinked_directory_inside_the_root_as_a_move_destination() {
            let root = tempdir().unwrap();
            let outside = tempdir().unwrap();
            let file = root.path().join("a.txt");
            fs::write(&file, "hi").unwrap();

            let link_dir = root.path().join("sneaky-dir-link");
            std::os::unix::fs::symlink(outside.path(), &link_dir).unwrap();

            let err = move_path(root.path(), &file, &link_dir).unwrap_err();
            assert!(err.contains("outside"), "{err}");
            assert!(file.exists());
            assert!(
                std::fs::read_dir(outside.path()).unwrap().next().is_none(),
                "nothing must have actually landed outside the root"
            );
        }

        #[test]
        fn rejects_creating_inside_a_symlinked_directory_pointing_outside_the_root() {
            let root = tempdir().unwrap();
            let outside = tempdir().unwrap();
            let link_dir = root.path().join("sneaky-dir-link");
            std::os::unix::fs::symlink(outside.path(), &link_dir).unwrap();

            let err = create_file(root.path(), &link_dir, "evil.txt").unwrap_err();
            assert!(err.contains("outside"), "{err}");
            assert!(
                std::fs::read_dir(outside.path()).unwrap().next().is_none(),
                "nothing must have actually landed outside the root"
            );
        }
    }
}
