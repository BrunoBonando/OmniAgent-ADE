# Focus mode — design parity

Bring the native macOS "focus" (zoomed terminal) mode in line with the
authoritative design, `design/OmniAgent ADE.dc.html` lines 1062–1113
(`<!-- ── FOCUSED TERMINAL ── -->`). That snapshot was verified byte-identical
to the live Claude Design project `74a2e92e-…` on 2026-08-17, so it is the
source of truth here.

## What is wrong today

`PaneWorkspaceView`'s zoom (added in `95b0485` / `fe95a36`) is a first pass:

1. The blur backdrop is a subview of `PaneWorkspaceView`, sized to its
   `bounds`, so only the terminal area dims. The sidebar stays sharp. The
   design's overlay is full-bleed across the whole app content.
2. The zoomed pane is `gridBounds.insetBy(30)` — nearly the whole terminal
   area. The design is a centred card, `1080 × min(720, available)`.
3. The header does not change in focus mode: same 30pt bar, same 20pt icon
   button. The design swaps in a 34pt bar with a bigger title, a
   `session · terminal N of M` subtitle, and a labelled **"Exit focus · esc"**
   pill in place of the icon button.
4. There is no keyboard path in or out. The design's tooltip/hint carry a
   shortcut, and its exit button is labelled `esc`. Bruno's call: **⌘↩** in,
   **esc** or a click outside out.

## Global constraints

- Values from the design are used verbatim. Colours are sRGB, `.5px`
  hairlines are 0.5pt, `rgba(255,255,255,.05)` is `NSColor(white: 1, alpha: 0.05)`.
- Reduce Motion: every animation added here must land instantly under
  `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion`, matching the
  existing `setZoomed` guard.
- No `NSVisualEffectView` anywhere in this area. See `PaneZoomBackdropView`'s
  own doc comment: constructing one hangs the headless test host. Layer
  `backgroundFilters` only.
- The existing zoom invariants hold: zoom needs ≥2 panes on screen, and
  `validateZoom` still ends it on session switch, new terminal, or last
  sibling closing.
- `macos/` is the only build surface. Nothing in `ui/` or `src-tauri/`.
- Existing tests keep passing; new behaviour gets tests.

## Tasks

Three tasks, disjoint by symbol ownership so they can run concurrently.

### Task 1 — Full-window blur backdrop and the designed card frame
Owner of: `PaneWorkspaceView`'s `// MARK: - Zoom` section, `PaneZoomBackdropView`,
`PaneContainerView.isZoomed`'s `didSet` and `updateChrome()`.
See `.superpowers/sdd/focus-mode-design-parity/task-1-brief.md`.

### Task 2 — Focus-mode header and the "Exit focus · esc" button
Owner of: `PaneHeaderView`, `PaneHeaderButton`, `PaneContainerView.init`'s
header wiring and `descriptorChanged(_:)`.
See `.superpowers/sdd/focus-mode-design-parity/task-2-brief.md`.

### Task 3 — ⌘↩ enters focus, esc leaves it
Owner of: `AppDelegate`'s menu, `WorkspaceWindow`, `WorkspaceWindowController`.
See `.superpowers/sdd/focus-mode-design-parity/task-3-brief.md`.

## Deliberately not built

- The design's focus footer (`❯ Prompt Claude Code and press Enter…` plus a
  `⌃⌘F focus · ⌘⇧] next terminal` hint) is a mock of the terminal's own prompt
  line. SwiftTerm draws the real prompt; a second fake one below it would be a
  lie. The shortcut hint survives as the exit button's `· esc` label.
- The grid header's `⋮` "Terminal options" button (design line 826) is missing
  from the native header, but it is grid chrome, not focus chrome — out of
  scope here.
