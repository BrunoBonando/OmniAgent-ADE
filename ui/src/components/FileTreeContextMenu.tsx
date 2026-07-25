// The file tree's right-click menu (Part B, item 4). Same small-popover
// house style as `ProjectMenu.tsx` (transparent click-away backdrop — a
// context menu is a utility, not a modal moment) plus `EnginePicker.tsx`'s
// focus-on-open + Escape-to-close handling, since unlike `ProjectMenu` this
// one is positioned at the cursor rather than anchored under a fixed
// trigger row.
//
// Item visibility (FileTree.tsx decides WHAT `target`/`selectionCount` are;
// this component only decides which buttons that implies):
// - `target === null` (right-clicked empty tree space): New File/New Folder
//   only — nothing to open/rename/duplicate/trash when nothing was clicked.
// - `selectionCount > 1` (multiple rows selected, right-clicked one of
//   them): "Move to Trash (N)" only — every other action stays single-item
//   scoped rather than guessing which of N items "Rename"/"Open" should mean
//   (brief: "other actions can be single-item-only... your call, keep it
//   sensible").
// - Otherwise, a single real target: the full action set, with New File/New
//   Folder only offered when the target is a directory (matches the brief's
//   "available when right-clicking a folder or empty tree space").
import { useLayoutEffect, useRef, useState } from "react";

export interface FileTreeContextMenuTarget {
  path: string;
  name: string;
  is_dir: boolean;
}

interface FileTreeContextMenuProps {
  x: number;
  y: number;
  target: FileTreeContextMenuTarget | null;
  selectionCount: number;
  onOpen: () => void;
  onReveal: () => void;
  onRename: () => void;
  onDuplicate: () => void;
  onNewFile: () => void;
  onNewFolder: () => void;
  onMoveToTrash: () => void;
  onCopyPath: () => void;
  onClose: () => void;
}

export default function FileTreeContextMenu({
  x,
  y,
  target,
  selectionCount,
  onOpen,
  onReveal,
  onRename,
  onDuplicate,
  onNewFile,
  onNewFolder,
  onMoveToTrash,
  onCopyPath,
  onClose,
}: FileTreeContextMenuProps) {
  const menuRef = useRef<HTMLDivElement | null>(null);
  // Clamped so the menu never overflows the window — load-bearing here in a
  // way `ProjectMenu`/`EnginePicker` never had to worry about: the file
  // tree panel is docked at the RIGHT edge of the window, so every
  // right-click inside it opens a menu whose natural `x` is already close
  // to (or past) the right edge. Measured post-mount (an unrendered menu
  // has no real size to clamp against) rather than estimated, so it stays
  // correct regardless of how many items a given target shows.
  const [position, setPosition] = useState({ left: x, top: y });

  // `useLayoutEffect`, not `useEffect` — runs synchronously before the
  // browser paints, so the menu never flashes at the raw (unclamped)
  // cursor position for a frame before snapping on-screen.
  useLayoutEffect(() => {
    menuRef.current?.focus();
    const el = menuRef.current;
    if (!el) return;
    const rect = el.getBoundingClientRect();
    const margin = 6;
    const left = Math.min(x, window.innerWidth - rect.width - margin);
    const top = Math.min(y, window.innerHeight - rect.height - margin);
    setPosition({ left: Math.max(margin, left), top: Math.max(margin, top) });
  }, [x, y]);

  function handleKeyDown(e: React.KeyboardEvent) {
    if (e.key === "Escape") {
      e.preventDefault();
      onClose();
    }
  }

  function run(action: () => void) {
    action();
    onClose();
  }

  const isMultiSelect = target !== null && selectionCount > 1;
  const label = target ? target.name : "this folder";

  return (
    <>
      <div className="file-tree-menu-backdrop" onMouseDown={onClose} onContextMenu={(e) => e.preventDefault()} />
      <div
        ref={menuRef}
        className="file-tree-menu"
        role="menu"
        aria-label={target ? `${target.name} actions` : "New item"}
        tabIndex={-1}
        style={{ left: position.left, top: position.top }}
        onKeyDown={handleKeyDown}
        onMouseDown={(e) => e.stopPropagation()}
      >
        {target === null && (
          <>
            <button role="menuitem" onClick={() => run(onNewFile)}>
              New File
            </button>
            <button role="menuitem" onClick={() => run(onNewFolder)}>
              New Folder
            </button>
          </>
        )}

        {target !== null && isMultiSelect && (
          <button role="menuitem" className="file-tree-menu-danger" onClick={() => run(onMoveToTrash)}>
            Move {selectionCount} Items to Trash
          </button>
        )}

        {target !== null && !isMultiSelect && (
          <>
            <button role="menuitem" onClick={() => run(onOpen)}>
              Open
            </button>
            <button role="menuitem" onClick={() => run(onReveal)}>
              Reveal in Finder
            </button>
            <button role="menuitem" onClick={() => run(onRename)}>
              Rename
            </button>
            <button role="menuitem" onClick={() => run(onDuplicate)}>
              Duplicate
            </button>
            {target.is_dir && (
              <>
                <div className="file-tree-menu-sep" role="separator" />
                <button role="menuitem" onClick={() => run(onNewFile)}>
                  New File
                </button>
                <button role="menuitem" onClick={() => run(onNewFolder)}>
                  New Folder
                </button>
              </>
            )}
            <div className="file-tree-menu-sep" role="separator" />
            <button role="menuitem" onClick={() => run(onCopyPath)}>
              Copy Path
            </button>
            <button role="menuitem" className="file-tree-menu-danger" onClick={() => run(onMoveToTrash)}>
              Move {label} to Trash
            </button>
          </>
        )}
      </div>
    </>
  );
}
