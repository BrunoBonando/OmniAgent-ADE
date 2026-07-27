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
//! destination path must resolve to somewhere inside that root before any
//! mutation happens. This blocks classic `../../..` traversal *and* symlink
//! tricks that use a directory symlink to smuggle a path outside the root —
//! but, critically, it must NOT block (or redirect) an operation on a
//! symlink *itself*: renaming/moving/deleting/duplicating a symlink must act
//! on the link entry, never silently follow through to whatever it points
//! at (exactly like Finder/`mv`/`rm` — a symlink is a first-class file-tree
//! entry, not a transparent window onto its target).
//!
//! Two containment checks exist for this reason, and using the wrong one
//! for a given argument is the whole difference between correct and buggy:
//! - [`within_root`] fully [`std::fs::canonicalize`]s the path, resolving
//!   every symlink including the final component. Correct for a
//!   *destination directory* argument (`new_parent_dir`/`parent_dir`) —
//!   the operation writes *inside* that directory, so resolving what it
//!   really is matters.
//! - [`within_root_leaf`]/[`within_root_as_child`] canonicalize only the
//!   target's *parent* directory (still closing both `..` traversal and a
//!   symlinked-intermediate-directory escape), then reattach the target's
//!   own literal file name. Correct for the item an in-place mutation
//!   (rename/move/duplicate/delete) actually acts on — a symlink leaf
//!   passed this way stays a symlink all the way to `fs::rename`/
//!   `trash::delete`/`fs::copy`, which act on the leaf entry exactly as
//!   given, never through it.
//!
//! See the `traversal_safety` and `symlinks` test modules below.
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
///
/// This fully resolves `target`, including its final path component — for a
/// symlink, the returned path is the symlink's RESOLVED TARGET, not the
/// link itself. That's exactly right for a destination *directory* argument
/// (`new_parent_dir`/`parent_dir`): the operation writes *inside* that
/// directory, so resolving what the directory actually is (symlink or not)
/// is the correct containment check. It is deliberately NOT used for the
/// item being mutated in place (rename/move/duplicate/delete) — see
/// [`within_root_leaf`] for that case.
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

/// The containment check for the item an in-place mutation (rename/move/
/// duplicate/delete) actually operates on. Unlike [`within_root`], this
/// does NOT canonicalize `target` itself — doing so would resolve a
/// symlink's final path component through to whatever it points at, which
/// is the bug this function fixes: every caller below (`fs::rename`,
/// `trash::delete`, `fs::copy`) must act on the literal entry the user
/// selected (a symlink stays a symlink), never silently follow through to
/// its target, exactly like Finder/`mv`/`rm`.
///
/// Containment is still fully enforced: `target`'s PARENT directory is
/// canonicalized (closing both classic `..` traversal and a symlink trick
/// in an intermediate *parent* directory) and checked against
/// `canonical_root`; the returned path is that canonical parent joined with
/// `target`'s own literal file name. `fs::rename`/`trash::delete`/etc. act
/// on the leaf entry exactly as given, not through it, so this is safe to
/// pass to them even when the leaf itself is a symlink whose target lives
/// outside the root — only the link entry (which lives inside the root) is
/// ever touched, never the outside target.
fn within_root_leaf(canonical_root: &Path, target: &Path) -> Result<PathBuf, String> {
    let file_name = target
        .file_name()
        .ok_or_else(|| format!("{} has no file name", target.display()))?;
    let parent = target.parent().unwrap_or_else(|| Path::new(""));
    let canonical_parent =
        std::fs::canonicalize(parent).map_err(|e| friendly_io_error(target, &e))?;
    if !canonical_parent.starts_with(canonical_root) {
        return Err(format!(
            "{} is outside the project and cannot be modified",
            target.display()
        ));
    }
    let safe_path = canonical_parent.join(file_name);
    // symlink_metadata (not `exists()`/`Path::is_*`) so a dangling symlink
    // still counts as "found" — matches `occupied`'s reasoning below.
    if std::fs::symlink_metadata(&safe_path).is_err() {
        return Err(format!("{} does not exist", target.display()));
    }
    Ok(safe_path)
}

/// Like [`within_root_leaf`], but additionally rejects `target` when it IS
/// `canonical_root` itself. Use this for the SOURCE of an in-place mutation
/// (rename/move/duplicate/delete) — see the module doc's "Safety model"
/// section for why the project root can't be one of those.
///
/// The root-equality check alone uses a full [`std::fs::canonicalize`] of
/// `target` (resolving any symlinks in it) — safe here because the result
/// is only ever compared for equality, never used as the operation path
/// (that still comes from [`within_root_leaf`], which preserves the leaf).
/// This also means a symlink *alias* of the project root is correctly
/// caught as "the root", not treated as some other in-root entry.
fn within_root_as_child(canonical_root: &Path, target: &Path) -> Result<PathBuf, String> {
    if let Ok(canonical_target) = std::fs::canonicalize(target) {
        if canonical_target == canonical_root {
            return Err("the project root itself cannot be modified".to_string());
        }
    }
    within_root_leaf(canonical_root, target)
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

    // Residual race, documented rather than silently left: unlike
    // `create_file`'s `create_new` (an atomic "create iff absent" syscall),
    // `std::fs::rename` has no cross-platform/std equivalent for "rename
    // only if the destination is absent" — on most platforms (including
    // macOS) a plain `rename()` silently replaces an existing destination.
    // macOS itself does have an atomic primitive for this (`renamex_np`
    // with `RENAME_EXCL`), but reaching it means an FFI call via the `libc`
    // crate, which isn't a dependency of this crate — adding one is out of
    // scope for this fix. So this `occupied()` check is kept immediately
    // adjacent to the `rename` call below (no filesystem work happens in
    // between) to make the window as narrow as practically possible without
    // a new dependency, not to close it completely: a second process could
    // still create `dest` in the gap between this check and the `rename`
    // call, in which case that rename would silently overwrite it.
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

    // See `rename_path`'s matching comment: this is the same narrowed-but-
    // not-fully-closed collision race, for the same reason (no std-only
    // atomic "rename iff absent" primitive without adding a `libc`
    // dependency for macOS's `renamex_np`/`RENAME_EXCL`) — kept immediately
    // adjacent to the `rename` call below rather than earlier in the
    // function.
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
///
/// If `path` is itself a symlink, this recreates a new symlink pointing at
/// the same target ([`std::os::unix::fs::symlink`]) rather than copying the
/// target's resolved bytes — matches real Finder, which duplicates an alias
/// as another alias, not as a copy of whatever it points to.
/// `symlink_metadata` (not [`Path::is_dir`], which follows symlinks) is
/// what makes this distinguishable from the plain-directory case below.
pub fn duplicate_path(project_root: &Path, path: &Path) -> Result<PathBuf, String> {
    let root = canonical_root(project_root)?;
    let source = within_root_as_child(&root, path)?;

    let dest = next_copy_name(&source, occupied);

    let source_type = std::fs::symlink_metadata(&source)
        .map_err(|e| friendly_io_error(&source, &e))?
        .file_type();

    if source_type.is_symlink() {
        let link_target =
            std::fs::read_link(&source).map_err(|e| friendly_io_error(&source, &e))?;
        std::os::unix::fs::symlink(&link_target, &dest)
            .map_err(|e| friendly_io_error(&dest, &e))?;
    } else if source_type.is_dir() {
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
            let target =
                std::fs::read_link(&entry_path).map_err(|e| friendly_io_error(&entry_path, &e))?;
            std::os::unix::fs::symlink(&target, &dest_path)
                .map_err(|e| friendly_io_error(&dest_path, &e))?;
        } else if file_type.is_dir() {
            copy_dir_recursive(&entry_path, &dest_path)?;
        } else {
            std::fs::copy(&entry_path, &dest_path)
                .map_err(|e| friendly_io_error(&entry_path, &e))?;
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
        Os { description, .. } => {
            format!("couldn't move {} to Trash: {description}", path.display())
        }
        CouldNotAccess { target } => format!("{target} doesn't exist or can't be accessed"),
        TargetedRoot => format!(
            "{} is a root folder and cannot be moved to Trash",
            path.display()
        ),
        Unknown { description } => {
            format!("couldn't move {} to Trash: {description}", path.display())
        }
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
///
/// `prepare_create`'s `occupied()` check happens first (for a fast, clear
/// error in the common non-racy case), but the actual write below uses
/// [`std::fs::OpenOptions::create_new`] rather than `File::create` — this is
/// what actually closes the race, not the earlier check: `create_new` is
/// itself an atomic "create iff absent" syscall (`O_CREAT | O_EXCL`), so
/// even if something else creates `dest` in the gap between the check above
/// and this call, this fails with `AlreadyExists` instead of silently
/// truncating it — the module doc's "never a silent overwrite" policy,
/// actually enforced rather than merely checked-then-hoped-for.
pub fn create_file(project_root: &Path, parent_dir: &Path, name: &str) -> Result<PathBuf, String> {
    let dest = prepare_create(project_root, parent_dir, name, "file")?;
    std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&dest)
        .map_err(|e| {
            if e.kind() == std::io::ErrorKind::AlreadyExists {
                format!("a file named \"{name}\" already exists")
            } else {
                friendly_io_error(&dest, &e)
            }
        })?;
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
        assert_eq!(
            fs::read_to_string(&b).unwrap(),
            "B",
            "destination must not be overwritten"
        );
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
        assert_eq!(
            fs::read_to_string(dest_dir.join("a.txt")).unwrap(),
            "existing"
        );
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

        assert!(
            !file.exists(),
            "file must be gone from its original location"
        );
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
        assert_eq!(
            fs::read_to_string(root.path().join("new.txt")).unwrap(),
            "existing"
        );
    }

    /// Bug 2 (TOCTOU): `prepare_create`'s `occupied()` pre-check happens
    /// before the real write, so a sequential "file already exists" test
    /// like `create_file_errors_clearly_on_collision` above only proves the
    /// non-racy path. This proves the ACTUAL fix — that the write itself
    /// (`OpenOptions::create_new`) is what closes the race — by racing many
    /// threads at the real create_new-vs-existing-file collision: under the
    /// old `File::create` (which truncates silently on an existing file,
    /// no error at all), every thread would report `Ok`. Under the fix,
    /// exactly one thread's `create_new` wins the atomic create and every
    /// other thread gets a real `Err` — proving the collision is now caught
    /// at the syscall itself, not just by the earlier best-effort check.
    #[test]
    fn create_file_atomically_rejects_a_concurrent_create_new_collision() {
        let root = tempdir().unwrap();
        let barrier = std::sync::Arc::new(std::sync::Barrier::new(8));
        let root_path = std::sync::Arc::new(root.path().to_path_buf());

        let handles: Vec<_> = (0..8)
            .map(|_| {
                let barrier = std::sync::Arc::clone(&barrier);
                let root_path = std::sync::Arc::clone(&root_path);
                std::thread::spawn(move || {
                    barrier.wait(); // maximize the chance every thread races the same window
                    create_file(&root_path, &root_path, "race.txt")
                })
            })
            .collect();

        let results: Vec<Result<PathBuf, String>> =
            handles.into_iter().map(|h| h.join().unwrap()).collect();

        let ok_count = results.iter().filter(|r| r.is_ok()).count();
        let err_count = results.iter().filter(|r| r.is_err()).count();
        assert_eq!(
            ok_count, 1,
            "exactly one create_new should win: {results:?}"
        );
        assert_eq!(
            err_count, 7,
            "every loser must get a real Err, not silently succeed: {results:?}"
        );
        for r in &results {
            if let Err(e) = r {
                assert!(e.contains("already exists"), "{e}");
            }
        }

        // The file must exist and be empty — no partial/garbled content
        // from two writers ever raced onto the same fd.
        let contents = fs::read_to_string(root.path().join("race.txt")).unwrap();
        assert_eq!(contents, "");
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
            assert_eq!(
                std::fs::canonicalize(&traversal_path).unwrap(),
                canon(&secret)
            );

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
            assert!(
                std::path::Path::new("/etc/passwd").exists(),
                "sanity: /etc/passwd exists"
            );
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
            assert_eq!(
                std::fs::canonicalize(&traversal_dest).unwrap(),
                canon(outside.path())
            );

            let err = move_path(root.path(), &file, &traversal_dest).unwrap_err();
            assert!(err.contains("outside"), "{err}");
            assert!(file.exists(), "source must be untouched");
        }

        #[test]
        fn operating_on_a_symlink_whose_target_is_outside_root_only_touches_the_link() {
            // A symlink physically located INSIDE the project root, whose
            // target lives OUTSIDE it, is NOT an escape: rename/delete act
            // on the link entry itself (see `within_root_leaf`'s doc
            // comment and the `symlinks` test module below), which lives
            // entirely inside the root. This replaces the old pre-fix
            // expectation that such an operation must be rejected as
            // "outside" — that old behavior was itself downstream of the
            // Bug 1 symlink-resolution bug (canonicalizing the leaf, which
            // this module no longer does for an in-place mutation's
            // source). What must still be true, and is asserted below: the
            // OUTSIDE target is never touched by any of it.
            let root = tempdir().unwrap();
            let outside = tempdir().unwrap();
            let secret = outside.path().join("secret.txt");
            fs::write(&secret, "top secret").unwrap();

            let link = root.path().join("sneaky-link");
            std::os::unix::fs::symlink(&secret, &link).unwrap();

            let renamed = rename_path(root.path(), &link, "renamed-link").unwrap();
            assert!(
                std::fs::symlink_metadata(&renamed)
                    .unwrap()
                    .file_type()
                    .is_symlink(),
                "renaming a symlink must still be a symlink afterward"
            );
            assert_eq!(fs::read_to_string(&secret).unwrap(), "top secret");

            delete_to_trash(root.path(), &renamed).unwrap();
            assert!(!renamed.exists(), "the link entry must be gone");
            assert_eq!(
                fs::read_to_string(&secret).unwrap(),
                "top secret",
                "the outside target must survive the link's own delete"
            );
        }

        #[test]
        fn rejects_a_source_reached_through_a_symlinked_intermediate_directory_pointing_outside_the_root(
        ) {
            // The escape attempt Bug 1's fix must still close: not a
            // symlink LEAF (that's fine now, see the test above), but a
            // symlink DIRECTORY inside the root used as an intermediate
            // path component to reach a file that's actually outside the
            // root. `within_root_leaf` canonicalizes the target's *parent*
            // (which resolves through this symlinked directory to a
            // location outside `canonical_root`), so this must still be
            // rejected even though the leaf itself is never canonicalized.
            let root = tempdir().unwrap();
            let outside = tempdir().unwrap();
            let real_file = outside.path().join("real.txt");
            fs::write(&real_file, "top secret").unwrap();

            let link_dir = root.path().join("sneaky-dir-link");
            std::os::unix::fs::symlink(outside.path(), &link_dir).unwrap();
            let path_through_link = link_dir.join("real.txt");

            let rename_err = rename_path(root.path(), &path_through_link, "pwned.txt").unwrap_err();
            assert!(rename_err.contains("outside"), "{rename_err}");

            let delete_err = delete_to_trash(root.path(), &path_through_link).unwrap_err();
            assert!(delete_err.contains("outside"), "{delete_err}");

            let dup_err = duplicate_path(root.path(), &path_through_link).unwrap_err();
            assert!(dup_err.contains("outside"), "{dup_err}");

            assert_eq!(fs::read_to_string(&real_file).unwrap(), "top secret");
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

    // Bug 1: operations on a symlink must act on the link entry itself,
    // never silently follow through to whatever it points at — exactly
    // like Finder/`mv`/`rm`. Every test here uses a symlink target that
    // lives INSIDE the same root (unlike `traversal_safety`'s outside-root
    // cases above), so what's being proven is purely "does the operation
    // affect the link or the target", not a containment question.
    mod symlinks {
        use super::*;

        #[test]
        fn rename_path_renames_the_link_entry_target_unaffected() {
            let root = tempdir().unwrap();
            let real = root.path().join("real.txt");
            fs::write(&real, "real content").unwrap();
            let link = root.path().join("link.txt");
            std::os::unix::fs::symlink(&real, &link).unwrap();

            let new_path = rename_path(root.path(), &link, "renamed-link.txt").unwrap();

            assert!(
                std::fs::symlink_metadata(&new_path)
                    .unwrap()
                    .file_type()
                    .is_symlink(),
                "the renamed entry must still be a symlink"
            );
            assert_eq!(
                std::fs::read_link(&new_path).unwrap(),
                real,
                "must still point at the same target"
            );
            // The target itself: untouched, unmoved, unrenamed.
            assert!(
                real.exists(),
                "real.txt must still exist under its original name"
            );
            assert_eq!(fs::read_to_string(&real).unwrap(), "real content");
            assert!(
                !link.exists(),
                "the old link name is gone (it was renamed, not left behind)"
            );
        }

        #[test]
        fn move_path_moves_the_link_entry_target_unaffected() {
            let root = tempdir().unwrap();
            let real = root.path().join("real.txt");
            fs::write(&real, "real content").unwrap();
            let link = root.path().join("link.txt");
            std::os::unix::fs::symlink(&real, &link).unwrap();
            let dest_dir = root.path().join("subdir");
            fs::create_dir(&dest_dir).unwrap();

            let new_path = move_path(root.path(), &link, &dest_dir).unwrap();

            assert!(
                std::fs::symlink_metadata(&new_path)
                    .unwrap()
                    .file_type()
                    .is_symlink(),
                "the moved entry must still be a symlink"
            );
            assert_eq!(std::fs::read_link(&new_path).unwrap(), real);
            assert!(
                real.exists(),
                "real.txt must still exist in its original place"
            );
            assert_eq!(fs::read_to_string(&real).unwrap(), "real content");
            assert!(
                !link.exists(),
                "the old link location is gone (it was moved, not left behind)"
            );
        }

        #[test]
        fn delete_to_trash_trashes_only_the_link_target_remains_on_disk() {
            let root = tempdir().unwrap();
            let real = root.path().join(format!("{TRASH_TEST_PREFIX}-real.txt"));
            fs::write(&real, "real content").unwrap();
            let link = root.path().join(format!("{TRASH_TEST_PREFIX}-link.txt"));
            std::os::unix::fs::symlink(&real, &link).unwrap();

            delete_to_trash(root.path(), &link).unwrap();

            assert!(!link.exists(), "the link entry must be gone");
            assert!(
                real.exists(),
                "the target file must remain on disk, untouched"
            );
            assert_eq!(fs::read_to_string(&real).unwrap(), "real content");
        }

        #[test]
        fn duplicate_path_of_a_symlink_creates_a_new_symlink_not_a_content_copy() {
            let root = tempdir().unwrap();
            let real = root.path().join("real.txt");
            fs::write(&real, "real content").unwrap();
            let link = root.path().join("link.txt");
            std::os::unix::fs::symlink(&real, &link).unwrap();

            let dup = duplicate_path(root.path(), &link).unwrap();

            assert_eq!(dup, canon(root.path()).join("link copy.txt"));
            assert!(
                std::fs::symlink_metadata(&dup)
                    .unwrap()
                    .file_type()
                    .is_symlink(),
                "the duplicate must be a symlink, not a plain-file copy of the target's bytes"
            );
            assert_eq!(
                std::fs::read_link(&dup).unwrap(),
                real,
                "the duplicate symlink must point at the same target as the original"
            );
            // Original link and its target are both untouched.
            assert!(link.exists());
            assert_eq!(fs::read_to_string(&real).unwrap(), "real content");
        }

        #[test]
        fn duplicate_path_of_a_symlinked_directory_preserves_it_as_a_symlink() {
            // `duplicate_path`'s directory branch (`copy_dir_recursive`)
            // already preserved symlinks found INSIDE a duplicated
            // directory (see its doc comment) — this proves the symlink
            // check now also applies when the duplicated item's TOP-LEVEL
            // entry is itself a symlink to a directory, which used to be
            // misclassified by `source.is_dir()` (follows symlinks) as a
            // plain directory and recursively copied instead of relinked.
            let root = tempdir().unwrap();
            let real_dir = root.path().join("real-dir");
            fs::create_dir(&real_dir).unwrap();
            fs::write(real_dir.join("inner.txt"), "inner").unwrap();
            let link = root.path().join("dir-link");
            std::os::unix::fs::symlink(&real_dir, &link).unwrap();

            let dup = duplicate_path(root.path(), &link).unwrap();

            assert!(
                std::fs::symlink_metadata(&dup)
                    .unwrap()
                    .file_type()
                    .is_symlink(),
                "duplicating a symlinked directory must produce another symlink"
            );
            assert_eq!(std::fs::read_link(&dup).unwrap(), real_dir);
        }
    }
}
