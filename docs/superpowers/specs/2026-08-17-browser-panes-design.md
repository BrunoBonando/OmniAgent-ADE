# Browser Panes — Design

Date: 2026-08-17
Status: Approved (Bruno, 2026-08-17)
Scope: native macOS app (`macos/`) only. `ui/` is legacy; no new UI work lands there.

## Goal

Let the user add a **browser** or a **terminal** to any pane in the grid, so a full
working browser and terminals coexist in the same pane-grid configuration.
Milestone 2 adds a **console** pane kind that controls a browser pane from a
different pane (mirrored `console.*` output + JS REPL).

Agents do not see or control browser panes in this version (human-only surface).

## Background (verified against code, 2026-08-17)

- `PaneGrid` (`macos/OmniAgent/PaneGrid.swift`) is a pure value struct, content-
  agnostic (opaque string pane ids, `__pane-hole-` prefix reserved), pinned to the
  TypeScript oracle via `fixtures/native-macos-compat/pane-grid.json`. **It must not
  learn about pane kinds.** Shape ladder caps at 8 panes per session.
- Terminal identity is concentrated at one seam: `PaneContainerView.surface` is
  hard-typed `let surface: TerminalSurfaceView` (`PaneWorkspaceView.swift:1322`),
  built once per pane by the injected `makeSurface: (String) -> TerminalSurfaceView`
  factory (`PaneWorkspaceView.swift:172`; production wiring
  `WorkspaceWindowController.swift:213-215`). Container→surface touchpoints:
  `focus`, `isSelected`, `scheduleResize`, `flushResize`, `suspendsDrawing`, and the
  `surface.terminalView` identity check in `reclaimFirstResponder`
  (`PaneWorkspaceView.swift:710-711`).
- Zoom/focus-mode overlay, drag-swap, divider resize, and `adoptFocus` (superview
  walk to the containing `PaneContainerView`) are already content-agnostic.
- The load-bearing invariant today is **pane id == daemon PTY session id**.
  `WorkspaceWindowController` owns all session lifecycle: every add funnels into
  `addPane(_:startSession:)` (~line 1253); restore calls `ensureSession(id)` for
  EVERY pane id (lines 799, 844) and `createSession` defaults a missing engine to
  `.shell` — an unfiltered browser pane id would silently spawn a login shell;
  `closePane` unconditionally `connection.kill`s (line 746); orphan reaping kills
  daemon sessions not in `allPaneIDs` (harmless to browser ids).
- Persistence: `PersistedTab` (project/engine/cwd required) lives in the brain.db
  `"layout"` settings row, byte-shared with the legacy web build's
  `ui/src/state/sessions.ts` codec. Both deserializers hard-drop tabs with an
  unrecognized engine (`PersistedLayout.swift:181-190`), and the web codec strips
  unknown fields on rewrite. **Browser panes must therefore stay out of this row.**
- Caps: `PaneGrid.maxPanes = 8` per session; `PaneWorkspaceView.maxTerminals = 64`
  mirroring daemon `MAX_SESSIONS = 64` (the "8" comment at
  `WorkspaceWindowController.swift:857` is stale — fix in passing).

## Design

### 1. Content seam: `PaneContentView` protocol

A protocol (NSView subclass requirement) covering exactly the container's real
contract:

- `focus()`
- `isSelected: Bool { get set }`
- `scheduleResize()` / `flushResize()` — no-ops for browser (WKWebView lays itself out)
- `suspendsDrawing: Bool { get set }` — no-op for browser (WebKit manages occlusion)
- `primaryResponderView: NSView { get }` — replaces the `surface.terminalView`
  identity check in `reclaimFirstResponder`

`TerminalSurfaceView` conforms (near-zero changes; `primaryResponderView` returns
`terminalView`). `PaneContainerView.surface` becomes the protocol type. The factory
becomes `(PaneDescriptor) -> PaneContentView`; `addPane` is its only call site, so
grid/zoom/drag/divider/adoptFocus code is untouched.

`PaneDescriptor` gains `kind`: `.terminal` | `.browser` (with a URL taking cwd's
role). Browser is a pane **kind**, orthogonal to `Engine` — never a new Engine case
(`EngineLauncher`'s exhaustive switches stay closed). Browser pane ids are minted in
the existing `SessionIdentifier` shape (grid uniqueness; orphan reaping stays inert).

### 2. `BrowserPaneView` (new file)

WKWebView-backed `PaneContentView`:

- URL/search field (typing a non-URL searches; scheme-less input gets `https://`),
  back/forward/reload buttons.
- `isInspectable = true` — right-click → Inspect Element opens the real Safari Web
  Inspector (WebKit hosts it; it cannot be re-parented into our grid — that is why
  the console pane exists as a separate kind).
- Publishes page title into the pane-header title path the way OSC titles do;
  loading state drives the header spinner where the working ring spins today.
- Shared persistent `WKWebsiteDataStore` across all browser panes (logins stick,
  like a normal browser). Shared process pool.
- `target=_blank` / popups navigate in place. Downloads go to `~/Downloads` via
  `WKDownloadDelegate`.
- First responder is WKWebView's internal content view; `primaryResponderView`
  returns the WKWebView and `adoptFocus`'s superview walk already handles clicks.

### 3. Lifecycle branches (`WorkspaceWindowController`)

Branch on `kind` at the four choke points:

- `addPane`: browser panes skip `ensureSession`/conversation-claim/usage
  recording/OSC title-cwd wiring.
- Both restore loops (799, 844) filter `ensureSession` to terminal panes.
- `closePane` skips `connection.kill` for browser panes (view teardown only).
- Session menu actions (interrupt/kill/reattach, option-as-meta) disable when a
  browser pane is focused (`validateMenuItem`).

Caps: browser panes do **not** count against the 64-PTY `maxTerminals` budget; only
the 8-per-session grid geometry bounds them. Cap checks are re-derived consistently
everywhere enablement is computed (validateMenuItem, addPane guard, preflights).

### 4. Add affordances ("everywhere terminals can")

- File menu: **New Browser Pane, ⇧⌘T** (nil-targeted, next to New Terminal Pane ⌘T).
- Toolbar: fifth item bound to `newBrowserPane(_:)`; enablement via the existing
  synthetic-menu-item probe.
- Command palette: `.newBrowserPane` action + row beside "New terminal pane";
  switch-to-pane rows show URL/page title for browser panes instead of engine.
- Sidebar per-session add-row and the empty-cell hole tile become terminal/browser
  choosers (primary click stays "new terminal"; browser is the explicit second
  affordance).
- Sidebar rows: globe glyph + page-title label for browser panes; nil-status dots
  already render idle-gray for session-less panes. Session naming gets a browser arm
  ("Browser 2" numbering, page title/URL fallback ladder in `SessionOutline`).
- Header chrome: globe/favicon instead of engine badge; page title as title; URL as
  subtitle (replaces "session · terminal N of M" wording where kind-inappropriate);
  accessibility strings become kind-aware.

### 5. Persistence: last-URL only, native-only

Browser web state is **not** persisted (no history, scroll, or per-pane web-view
state). A simple native-only settings row (its own `SettingsKey`, never the shared
`"layout"` row) records the open browser panes' last loaded URLs (with group +
order). On relaunch, browser panes are recreated from that record with a fresh load
of their last URL. The shared layout row and the web codec are untouched; a
browser pane in the grid must never cause the shared row to gain fields or lose
tabs. Console panes (milestone 2) are not persisted in v1.

### 6. Milestone 2: Console pane kind

`.console` pane: binds to a target browser pane via a picker in its own header
(default: most recently focused browser pane).

- Mirrors `console.log/warn/error` (+ uncaught errors) from the bound page via an
  injected `WKUserScript` + `WKScriptMessageHandler`, into a scrolling log view.
- REPL input line evaluates JavaScript in the bound page
  (`evaluateJavaScript`) and prints results/errors inline.
- Rebinds cleanly when its browser pane closes (picker empties; log notes it).
- Ships after milestone 1 is green; browser panes must not depend on it.

### 7. Focus mode & keys

Zoom/focus-mode cards work unchanged (reparenting is content-agnostic; focus
reclaim uses `primaryResponderView`). Esc exits focus mode for browser panes the
same as terminals (v1 accepts that pages lose Esc while zoomed). `initialFirstResponder`
paths are checked for the protocol type.

## Testing

1. **Seam retype first, suite green before any browser code**: the protocol change
   ripples through `PaneWorkspaceViewTests`' helpers and dozens of
   `container.surface.terminalView` dereferences — land it mechanically with all
   existing tests passing.
2. `BrowserPaneView` unit tests (URL normalization/search fallback, title
   publishing, nav button state, download routing decision).
3. Last-URL persistence round-trip tests (own settings row; absent row = no browser
   panes; malformed entries dropped per-entry) + a regression test asserting the
   shared `"layout"` row is byte-identical with browser panes present.
4. Mixed-grid tests: identity survival across add/close/swap/zoom with mixed kinds;
   restore loops never call `ensureSession` for browser ids; `closePane` never
   `kill`s a browser id.
5. Offscreen-render layout verification for the browser pane chrome (existing
   AppKit render-to-PNG test convention).
6. Milestone 2: console capture/REPL tests against a local test page.

## Risks

- Missed lifecycle branch spawns real PTYs (restore loops, `.shell` default) —
  covered by tests in §Testing 4.
- Test blast radius of the seam retype — mitigated by landing it as its own green
  step.
- Memory: hidden panes are deliberately kept alive; dozens of live WKWebViews are
  heavier than SwiftTerm buffers. v1 relies on the shared process pool + WebKit's
  own suspension; revisit if real usage hurts.
- Esc/key routing around WKWebView differs from SwiftTerm; focus reclaim must use
  `primaryResponderView` everywhere the terminal view was compared by identity.

## Out of scope

- Agent (MCP) visibility/control of browser panes.
- Tabs inside a browser pane; embedded Elements/Network inspector panels.
- Persisting console panes, web history, or session state.
- Any `ui/` (legacy web) changes; any daemon-protocol or MCP-contract changes.
