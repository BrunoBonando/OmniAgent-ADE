// Wraps @xterm/xterm around one live PTY session (sessions.rs's frozen
// SessionInfo contract). Stays mounted for the whole lifetime of a tab —
// even while another tab is active — because the Rust side only streams
// `session-output:{id}` events to whoever is listening right now; unmounting
// (and re-listening later) would silently drop everything the PTY printed
// while the tab was in the background. Visibility is CSS-only (`display`).
import { useCallback, useEffect, useRef } from "react";
import { Terminal as XTerm } from "@xterm/xterm";
import { FitAddon } from "@xterm/addon-fit";
import { WebglAddon } from "@xterm/addon-webgl";
import { listen, type UnlistenFn } from "@tauri-apps/api/event";
import { getCurrentWebview } from "@tauri-apps/api/webview";
import "@xterm/xterm/css/xterm.css";
import { sessionResize, sessionWrite } from "../lib/tauri";
import { engineTitleFromTerminalTitle } from "../lib/autoTitle";
import { resolveTerminalTheme, type TerminalThemeId } from "../lib/terminalThemes";
import PaneInstallOverlay from "./PaneInstallOverlay";
import type { AgentsState } from "../state/agents";
import type { Engine } from "../state/sessions";

interface TerminalProps {
  sessionId: string;
  visible: boolean;
  focused: boolean;
  /** This pane's terminal color-theme override — `undefined` renders
   * `terminalThemes.ts`'s global default. See `TabInfo.themeId`'s doc
   * (sessions.ts) for the global-default-with-per-pane-override design. */
  themeId?: TerminalThemeId;
  /** Agent-generated short title from xterm's OSC title event. */
  onEngineTitle?: (sessionId: string, title: string) => void;
  agentState: AgentsState;
  tabEngine: Engine;
}

// Background/foreground/cursor palette now lives in `../lib/terminalThemes`
// (`TERMINAL_THEMES.standard` is this file's former `HUD_THEME`, verbatim —
// see that module's own doc for the Warp-sourced provenance and the
// founder's "push the background almost black" follow-up ask). Kept in
// sync with App.css's --void/--ink/--signal/--line tokens the same way the
// original HUD_THEME was — xterm doesn't read CSS custom properties, so
// the palette is still duplicated by hand, just one file over now that
// there's more than one preset to hold.

function base64ToBytes(b64: string): Uint8Array {
  const bin = atob(b64);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

export default function Terminal({ sessionId, visible, focused, themeId, onEngineTitle, agentState, tabEngine }: TerminalProps) {
  const containerRef = useRef<HTMLDivElement | null>(null);
  const loadingRef = useRef<HTMLDivElement | null>(null);
  const termRef = useRef<XTerm | null>(null);
  const fitRef = useRef<FitAddon | null>(null);
  const retryTimerRef = useRef<number | null>(null);
  // Lets the mount effect (keyed only on `[sessionId]`, see below) always
  // call the LATEST `onEngineTitle` prop without needing it in that effect's
  // deps — the same ref-for-a-callback pattern used throughout this
  // codebase to keep a mount-once effect from re-running on every prop
  // change (see `Workspace.tsx`'s module doc on why `<Terminal>` must stay
  // mounted for a session's whole lifetime).
  const onEngineTitleRef = useRef(onEngineTitle);
  useEffect(() => {
    onEngineTitleRef.current = onEngineTitle;
  }, [onEngineTitle]);

  const hasUsableSize = (cols: number, rows: number) => cols > 0 && rows > 0;

  // Dismiss the per-pane loading overlay. Stable across renders (empty deps)
  // so both the mount effect and the visibility effect can reference it in
  // their closures without needing it in the dependency arrays. Pure DOM
  // manipulation — no React state, no re-render, no interruption to the PTY
  // stream.
  const dismissLoading = useCallback(() => {
    const el = loadingRef.current;
    if (!el || el.hasAttribute("data-ready")) return;
    el.setAttribute("data-ready", "");
  }, []);

  /** Shared fit-with-retry used by both the mount effect and the visibility
   * effect. Attempts up to `maxAttempts` times, each `intervalMs` ms apart.
   * Returns early on first success. The timer id is stored in retryTimerRef
   * so the cleanup path can cancel it. An optional `onFirstSuccess` callback
   * fires once after the very first successful fit — used to hide the loading
   * overlay without triggering a React re-render. */
  const scheduleRetryFit = (
    fit: FitAddon,
    term: XTerm,
    maxAttempts: number,
    intervalMs: number,
    onFirstSuccess?: () => void,
  ) => {
    let attempt = 0;
    const tryFit = () => {
      try { fit.fit(); } catch { /* ignore — xterm not yet ready */ }
      if (hasUsableSize(term.cols, term.rows)) {
        void sessionResize(sessionId, term.cols, term.rows);
        onFirstSuccess?.();
        return;
      }
      if (attempt >= maxAttempts) return;
      attempt += 1;
      retryTimerRef.current = window.setTimeout(tryFit, intervalMs);
    };
    tryFit();
  };

  // Mount once per session id — see module doc comment for why this must
  // not depend on `visible`.
  useEffect(() => {
    const container = containerRef.current;
    if (!container) return;

    const term = new XTerm({
      convertEol: true,
      fontFamily:
        '"JetBrains Mono", "IBM Plex Mono", ui-monospace, SFMono-Regular, Menlo, monospace',
      fontSize: 13,
      lineHeight: 1.35,
      theme: resolveTerminalTheme(themeId),
      cursorBlink: true,
      cursorStyle: "bar",
      scrollback: 3000,
      allowProposedApi: true,
    });
    const fit = new FitAddon();
    term.loadAddon(fit);
    term.open(container);

    termRef.current = term;
    fitRef.current = fit;

    // Defer WebGL initialisation so it doesn't block multiple terminals'
    // first paint.  xterm renders fine with its Canvas/DOM fallback while
    // the GPU context spins up in the background; `setTimeout 0` yields
    // to the browser's layout and paint tasks first.
    const webglTimer = window.setTimeout(() => {
      if (cancelled) return;
      try {
        const webgl = new WebglAddon();
        webgl.onContextLoss(() => webgl.dispose());
        term.loadAddon(webgl);
      } catch (err) {
        // WebGL unavailable (headless/CI, unsupported GPU path, jsdom in
        // tests) — xterm's DOM renderer still works, just without the GPU
        // fast path. Never fatal (DESIGN: terminals must always work).
        console.warn("omniagent-ade: WebGL addon unavailable, falling back to DOM renderer", err);
      }
    }, 0);

    // Initial fit — 60 retries at 100 ms intervals (6 s window) so that when
    // several panes open simultaneously the browser has enough time to settle
    // every container's layout before we give up.  The wider window directly
    // fixes the "some terminals stay blank on multi-pane open" symptom: the
    // previous 20×50 ms window (1 s) was too tight when 4–8 terminals all
    // competed for the layout pass at once.
    if (visible) {
      scheduleRetryFit(fit, term, 60, 100, dismissLoading);
    }

    let submittedPrompt = false;

    const dataDisposable = term.onData((data) => {
      void sessionWrite(sessionId, data);
      if (/\r|\n/.test(data)) submittedPrompt = true;
    });

    const titleDisposable = term.onTitleChange?.((title) => {
      if (!submittedPrompt) return;
      const usefulTitle = engineTitleFromTerminalTitle(tabEngine, title);
      if (usefulTitle) onEngineTitleRef.current?.(sessionId, usefulTitle);
    });

    // Debounced resize handler: when multiple terminals open simultaneously
    // the mosaic grid fires a ResizeObserver notification on every pane at
    // once.  Without the debounce each terminal would immediately kick off its
    // own 20-attempt retry loop, hammering the main thread.  50 ms is enough
    // to batch the burst into one callback per pane.
    let resizeDebounceTick: number | null = null;
    const resizeObserver = new ResizeObserver(() => {
      if (resizeDebounceTick !== null) clearTimeout(resizeDebounceTick);
      resizeDebounceTick = window.setTimeout(() => {
        resizeDebounceTick = null;
        scheduleRetryFit(fit, term, 20, 50);
      }, 50);
    });
    resizeObserver.observe(container);

    let cancelled = false;
    let unlistenOutput: UnlistenFn | undefined;
    let unlistenDrop: UnlistenFn | undefined;

    // Rolling text buffer for error pattern detection.
    // We only keep the last 500 chars — enough to catch any multi-line error
    // message without unbounded growth.
    let outputBuf = "";
    let copilotRestartTimer: number | null = null;

    void listen<string>(`session-output:${sessionId}`, (event) => {
      const bytes = base64ToBytes(event.payload);
      term.write(bytes);

      // Detect the Copilot CLI error "No session, task, or name matched
      // '<uuid>'." which fires when --resume references a session that no
      // longer exists.  Buffer the plain text of the last chunk and restart
      // with a bare `copilot` (no --resume / --session-id) after a short
      // delay so the shell has time to return to its prompt.
      if (tabEngine === "copilot") {
        const text = new TextDecoder("utf-8", { fatal: false }).decode(bytes);
        outputBuf = (outputBuf + text).slice(-500);
        if (
          outputBuf.includes("No session, task, or name matched") &&
          copilotRestartTimer === null
        ) {
          outputBuf = "";
          copilotRestartTimer = window.setTimeout(() => {
            copilotRestartTimer = null;
            void sessionWrite(sessionId, "copilot\r");
          }, 1200);
        }
      }
    }).then((unlisten) => {
      if (cancelled) {
        unlisten();
        return;
      }
      unlistenOutput = unlisten;
    });

    // Drag-and-drop: a file dropped from Finder onto *this* terminal pastes
    // its quoted path into that terminal's input (DESIGN 3.1). The event is
    // window-global in Tauri v2 (there's no per-element HTML5 drop target),
    // so every mounted Terminal listens and self-selects by checking
    // whether the drop's physical position lands inside its own (visible)
    // bounding box.
    void getCurrentWebview()
      .onDragDropEvent((event) => {
        if (event.payload.type !== "drop") return;
        const el = containerRef.current;
        if (!el || el.offsetParent === null) return; // not the visible tab
        const logical = event.payload.position.toLogical(window.devicePixelRatio || 1);
        const rect = el.getBoundingClientRect();
        if (
          logical.x < rect.left ||
          logical.x > rect.right ||
          logical.y < rect.top ||
          logical.y > rect.bottom
        ) {
          return;
        }
        const paths = event.payload.paths;
        if (!paths || paths.length === 0) return;
        const quoted = paths.map((p) => `"${p}"`).join(" ");
        void sessionWrite(sessionId, `${quoted} `);
        term.focus();
      })
      .then((unlisten) => {
        if (cancelled) {
          unlisten();
          return;
        }
        unlistenDrop = unlisten;
      });

    return () => {
      cancelled = true;
      dataDisposable.dispose();
      titleDisposable?.dispose();
      resizeObserver.disconnect();
      if (resizeDebounceTick !== null) clearTimeout(resizeDebounceTick);
      if (retryTimerRef.current !== null) {
        clearTimeout(retryTimerRef.current);
        retryTimerRef.current = null;
      }
      if (copilotRestartTimer !== null) {
        clearTimeout(copilotRestartTimer);
      }
      unlistenOutput?.();
      unlistenDrop?.();
      term.dispose();
      termRef.current = null;
      fitRef.current = null;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [sessionId]);

  // Live theme swap: `xterm.js`'s `Terminal.options` is mutable at runtime
  // (unlike the constructor-only options above), so picking a new theme in
  // PaneHeader's 3-dot menu re-paints this pane immediately without tearing
  // down/recreating the xterm instance — doing that would drop scrollback
  // and momentarily interrupt the live PTY output stream, which the
  // mount-once-per-session-id effect above exists specifically to avoid.
  useEffect(() => {
    const term = termRef.current;
    if (!term) return;
    term.options.theme = resolveTerminalTheme(themeId);
  }, [themeId]);

  // Re-fit whenever this tab becomes visible.
  // Double-RAF: the first frame schedules a layout pass after display:none→block;
  // the second frame reads the resolved dimensions. Without the second frame the
  // container's clientWidth is often still 0 on the first read, producing a
  // black terminal that only recovers on the next manual resize.
  useEffect(() => {
    if (!visible) return;
    let raf1: number;
    let raf2: number;
    raf1 = requestAnimationFrame(() => {
      raf2 = requestAnimationFrame(() => {
        const term = termRef.current;
        const fit = fitRef.current;
        if (!term || !fit) return;
        scheduleRetryFit(fit, term, 40, 100, dismissLoading);
      });
    });
    return () => {
      cancelAnimationFrame(raf1);
      cancelAnimationFrame(raf2);
    };
  }, [visible, sessionId]); // eslint-disable-line react-hooks/exhaustive-deps

  useEffect(() => {
    if (focused) termRef.current?.focus();
  }, [focused, sessionId]);

  return (
    <div
      ref={containerRef}
      className="terminal-container"
      style={{ display: visible ? "block" : "none" }}
      data-session-id={sessionId}
    >
      {/* Logo-animation overlay shown while xterm is initialising. Dismissed
          via DOM attribute (no React state) so it never causes a re-render or
          interrupts the PTY stream — see `dismissLoading` above. */}
      <div ref={loadingRef} className="terminal-loading" aria-hidden="true">
        <div className="terminal-loading-logo" />
      </div>
      {agentState.installing.has(tabEngine) && (
        <PaneInstallOverlay
          agent={tabEngine}
          status={agentState.installing.get(tabEngine)!}
        />
      )}
    </div>
  );
}
