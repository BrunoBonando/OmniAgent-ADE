# Editor Pane — Design Spec

Date: 2026-08-18
Status: approved in brainstorming; awaiting implementation plan

## Overview

Replace the dead left-menu "Files" destination button with a real **editor pane** kind in the native macOS app: a tabbed pane that opens, edits, and saves files with Monaco (VS Code's editor) as its editing surface, shows git diffs per file and repo-wide, and previews images and PDFs natively. Editor panes are the only pane kind with tabs; tabs drag between editor panes, reorder in place, and can create new panes by edge/hole drops.

**Native-rule exception (Bruno, 2026-08-18):** Monaco-in-WKWebView is allowed for the editor surface internals *only* — "we could open an exception here for the fully native rule. But only here." Tab strip, pane chrome, drag-and-drop, media viewers, and all other new UI remain native AppKit.

## Goals

- Remove the `.files` destination row (the "Coming in a later step" placeholder) from the left menu; keep the sidebar FILES tree, now functional.
- Click a file in the FILES tree → opens in an editor pane with VS Code preview-tab semantics.
- Edit and save with VS Code-style dirty indication (dot on tab, ⌘S, save affordance in the strip).
- Syntax highlighting by language, ⌘F find/replace, word-based autocomplete — inherited from Monaco.
- Per-file diff tabs (side-by-side vs HEAD) and a repo-wide Changes overview tab.
- Native image and PDF preview tabs.
- Tab drag-and-drop: reorder, move across editor panes, edge-insert new pane, drop on hole tile.
- Restore open editor panes/tabs across launches via a native-only settings row.

## Non-goals (v1) / future work

- **Full language intelligence (LSP)** — explicitly requested as a future roadmap item (rust-analyzer, typescript-language-server, …). v1 ships Monaco's word-based completion.
- **Hot exit** — unsaved buffer contents are not persisted across app quits (in-memory crash snapshots only).
- **FSEvents live file watching** — v1 checks modification dates on tab focus.
- **Editor gutter git markers** — considered and declined for v1 (per-file diff tab + Changes tab cover it).
- **Freeform VS Code split trees** — pane geometry stays the existing grid ladder; edge-drop inserts a grid pane, it does not create nested splits.
- Minimap disabled by default (revisit on request).

## 1. Pane kind and tab model

- New `PaneKind.editor` alongside `terminal` and `browser` (`PaneContentView.swift`). Editor panes are ordinary grid panes — same chrome, header, focus/swap rules, global 8-pane cap — and skip the PTY/daemon lifecycle exactly as browser panes do (`startSession: false`, exempt from the terminal cap).
- Each editor pane owns an ordered tab list. Tab kinds:
  - **File** — editable Monaco model. Dirty state shows a filled dot replacing the × close glyph (VS Code behavior); ⌘S saves the active tab; a "Save" affordance appears at the strip's right edge while the active tab is dirty.
  - **Diff** — one file's working-tree changes vs HEAD in Monaco's side-by-side diff editor, read-only. Title: `name.ext (Working Tree)`.
  - **Changes** — repo-wide overview of all changed files with lazily expanded hunks; at most one per pane. File rows link to that file's diff tab and to the editable file.
  - **Media** — read-only native preview, never dirty. Images (png, jpg, gif, webp, heic, tiff, icns, …) in a zoomable/scrollable `NSImageView` with checkerboard backing and a "W × H · size" caption; PDFs in a `PDFKit.PDFView` (continuous scroll, zoom, selection, ⌘F within the PDF). Viewer choice by extension + content sniff at open time. SVG opens as text in Monaco (as VS Code does).
- **Preview-tab semantics (VS Code-faithful):** single click in the FILES tree opens an italic *preview* tab in the most recently focused editor pane, creating a pane if none exists; the next single click reuses it. Double-click, editing the buffer, or dragging the tab pins it. A file already open anywhere is focused, never duplicated.
- **Closing:** closing a dirty tab prompts save/discard/cancel. A pane closes when its last tab closes. App quit prompts once per dirty file.

## 2. Monaco embedding

- One WKWebView per editor pane; one Monaco instance with one *model per file tab*. Tab switches swap models (undo history, scroll, selection preserved — VS Code's own architecture). Diff tabs toggle the same web view to Monaco's diff editor; the Changes tab renders as themed HTML in the same page. Media tabs swap the content area to a native view instead (see §4 container).
- **Assets offline:** a pinned Monaco release ships in the app bundle (`Resources/monaco/`), loaded via `loadFileURL(_:allowingReadAccessTo:)`. Upgrades are deliberate asset bumps.
- **Bridge:** explicit protocol over `WKScriptMessageHandler` (JS→Swift) + `evaluateJavaScript` (Swift→JS): open/close/switch model, set content, get content for save, dirty-changed, debounced content snapshot, ⌘S relay from inside Monaco to the native save path. **Swift owns all file I/O; Monaco never touches disk.** Language chosen from extension via Monaco's registry.
- **Inherited free:** highlighting, ⌘F find/replace with regex, word-based completion, bracket matching, multi-cursor.
- **Native fit:** custom Monaco theme bound to the app palette, tracking system light/dark; editor font aligned with terminal settings where sensible; context menu pruned to what works in the embedding.
- **External changes:** clean buffer + newer mtime on focus → silent reload. Dirty buffer + newer mtime → conflict state on the tab, keep-mine / take-disk prompt.
- `EditorPaneView` implements `PaneContentView` mirroring `BrowserPaneView`: no-op PTY surface (`scheduleResize`/`flushResize`), `primaryResponderView`, title/payload change callbacks wired in the controller.

## 3. Git diffs

- **Per-file diff:** Swift fetches `git show HEAD:<path>` (same subprocess pattern as `WorkspaceFiles.GitStatus`: `/usr/bin/env git`, `GIT_OPTIONAL_LOCKS=0`, off-main) and reads the working tree from disk; Monaco's diff editor computes and renders — no hunk parsing app-side. Untracked files diff against empty; renames show under the new path.
- **Changes tab:** file list from the porcelain status already collected for sidebar badges; `git diff HEAD -- <file>` parsed per file, lazily on unfold. Rendered as HTML in the pane's web view, same theme.
- **Entry points:**
  - The `+N −M` totals header above the FILES tree becomes clickable → Changes tab in the active editor pane (created if needed).
  - Clicking a badged file's git badge in the tree → that file's diff tab (clicking the name still opens the editor).
  - Command palette: "Show all changes", "Open diff for current file".
  - A "± Diff" affordance on file tabs whose file has changes, toggling editor ↔ diff.
- **Refresh:** diff/Changes tabs re-query on focus regained and when sidebar status polling detects change. No live streaming in v1.

## 4. Tab strip, drag-and-drop, container

- **Tab strip is native AppKit:** ~30 pt row inside `EditorPaneView` above the content area (the slot `BrowserPaneView` uses for its URL bar — zero shared-chrome changes). Tabs show extension icon, name, dirty-dot/× hover swap, italic preview titles; horizontal scroll on overflow.
- **Content area is a swap container:** active tab selects the WKWebView (file/diff/changes) or a native media view (image/PDF).
- **Drag-and-drop** extends the existing pane-drag pasteboard machinery with a tab pasteboard type:
  - Within a strip → live reorder with insertion indicator.
  - Another editor pane, center region → tab moves into that strip at the drop position; moving the last tab out closes the source pane.
  - Another editor pane, edge regions (outer ~25% per side) → new editor pane inserted adjacent in grid order holding the tab; ladder re-lays out (grid-faithful "edge split").
  - Hole tile / empty grid slot → new editor pane there.
  - Terminal/browser panes → rejected (no-drop cursor); those kinds never grow tabs.
  - All drops respect the 8-pane cap, matching existing pane-creation refusals.

## 5. Persistence

- New native-only settings row **`editor_panes_native`** (pattern: `browser_panes_native`; never the shared `layout` row, which the web/Tauri build rewrites and would drop unknown fields). Per pane: tab list (`path`, kind, pinned-vs-preview), active tab index, session group. `JSONSerialization` with `.sortedKeys`; read-once gate + deduped write cycle mirroring `BrowserPanesCodec` and its controller gates.
- Dirty buffer content is **not** persisted (no hot exit). On restore, files reload from disk; tabs whose file vanished restore as closed. `WorkspaceRestoration.persistedTabs` continues to exclude non-terminal kinds from the shared row.

## 6. Entry points and Files button removal

- Creation entry points mirror the browser pane's five: **⇧⌘E** menu item, toolbar button, command palette "New editor pane", sidebar row, hole-tile secondary action — plus implicit: FILES-tree file click (`WorkspaceFilesTreeView.onOpenFile`, currently unwired) and the §3 diff entry points.
- **Removed:** the `.files` `WorkspaceDestination` row, its placeholder branch in the window controller, and its "no changes" subtitle wiring. The FILES tree in the sidebar's lower half stays.
- Kind-awareness cosmetics mirrored where browser panes already special-case: session outline labels, sidebar row icons, pane header subtitle/a11y nouns, palette detail text.

## 7. Error handling

- **Binary/huge:** non-previewable binaries (executables, archives, …) get a "binary file — N KB" placeholder; files > ~10 MB open read-only with a banner.
- **Save failures:** native alert; buffer stays dirty; nothing lost.
- **Deleted on disk while open:** tab title gains "(deleted)"; buffer survives; save recreates.
- **Git failures / non-repo:** diff entry points absent outside a repo; a failed subprocess renders an inline error state in the tab, never a dead pane.
- **WKWebView crash:** Swift keeps ~2 s-debounced in-memory snapshots of dirty buffers; on `contentProcessDidTerminate`, reload Monaco and restore tabs *including unsaved edits*.

## 8. Testing

- **Pure model tests carry the weight:** tab-list semantics (preview reuse, pin-on-edit, no duplicate opens, last-tab-closes-pane), drop-zone geometry (center vs edge), grid insertion indices, `EditorPanesCodec` round-trip, language-from-extension and media-sniff mapping, changed-files parsing.
- **Restoration tests** mirroring `WorkspaceRestorationTests`: tabs/active index restore; editor panes stay out of the shared `layout` row; vanished files restore closed.
- **Layout tests:** offscreen render of tab strip states (dirty dot, preview italic, overflow), per repo convention.
- **Bridge smoke test:** WKWebView loads bundled Monaco and answers a ping — catches broken assets at test time.
- Monaco's own editing behavior is upstream's responsibility; not re-tested here.
