// Wraps @xterm/xterm around one live PTY session (sessions.rs's frozen
// SessionInfo contract). Stays mounted for the whole lifetime of a tab —
// even while another tab is active — because the Rust side only streams
// `session-output:{id}` events to whoever is listening right now; unmounting
// (and re-listening later) would silently drop everything the PTY printed
// while the tab was in the background. Visibility is CSS-only (`display`).
import { useEffect, useRef } from "react";
import { Terminal as XTerm } from "@xterm/xterm";
import { FitAddon } from "@xterm/addon-fit";
import { WebglAddon } from "@xterm/addon-webgl";
import { listen, type UnlistenFn } from "@tauri-apps/api/event";
import { getCurrentWebview } from "@tauri-apps/api/webview";
import "@xterm/xterm/css/xterm.css";
import { sessionResize, sessionWrite } from "../lib/tauri";

interface TerminalProps {
  sessionId: string;
  visible: boolean;
}

// Matches the --void/--ink/--signal tokens in App.css — xterm doesn't read
// CSS custom properties, so the HUD palette is duplicated here once (keep
// both in sync — see App.css's own :root comment).
//
// Warp *exact*-color pass (founder ask, 2026-07-25, verbatim: "I want the
// theme to be exactly this colors"): background/foreground/cursor/
// cursorAccent/selectionBackground below are kept in sync with App.css's
// new --void/--ink/--signal/--line tokens exactly, same no-seam rule as
// before. The ANSI red/green/yellow/blue/magenta/cyan (+ bright, + black/
// white) are new: Warp publishes its own bundled default-dark terminal
// theme as open-source YAML (github.com/warpdotdev/themes,
// warp_bundled/warp_dark.yaml — the literal "Warp Dark" preset the app
// ships with, confirmed via that repo's own README plus Warp's
// how-we-designed-themes blog post referencing "our default dark ...
// theme"). Unlike the old BridgeSpace reference (a parsed-output rendering
// with no real ANSI palette to sample), this is Warp's actual terminal
// color data — copied verbatim below rather than guessed, which the
// founder's brief called out as the highest-value, most literal part of
// "exactly this colors" since it's the terminal palette itself.
const HUD_THEME = {
  background: "#16171c",
  foreground: "#e8e9ec",
  cursor: "#9aa7e6",
  cursorAccent: "#16171c",
  selectionBackground: "#2c2d34",
  // ANSI 0-7 / 8-15, verbatim from warp_bundled/warp_dark.yaml's
  // terminal_colors.normal / .bright (black/white are that file's own
  // normal.black+bright.black / normal.white+bright.white, not the theme's
  // separate top-level background/foreground fields above).
  black: "#616161",
  red: "#ff8272",
  green: "#b4fa72",
  yellow: "#fefdc2",
  blue: "#a5d5fe",
  magenta: "#ff8ffd",
  cyan: "#d0d1fe",
  white: "#f1f1f1",
  brightBlack: "#8e8e8e",
  brightRed: "#ffc4bd",
  brightGreen: "#d6fcb9",
  brightYellow: "#fefdd5",
  brightBlue: "#c1e3fe",
  brightMagenta: "#ffb1fe",
  brightCyan: "#e5e6fe",
  brightWhite: "#feffff",
};

function base64ToBytes(b64: string): Uint8Array {
  const bin = atob(b64);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

export default function Terminal({ sessionId, visible }: TerminalProps) {
  const containerRef = useRef<HTMLDivElement | null>(null);
  const termRef = useRef<XTerm | null>(null);
  const fitRef = useRef<FitAddon | null>(null);

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
      theme: HUD_THEME,
      cursorBlink: true,
      cursorStyle: "bar",
      scrollback: 10000,
      allowProposedApi: true,
    });
    const fit = new FitAddon();
    term.loadAddon(fit);
    term.open(container);

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

    termRef.current = term;
    fitRef.current = fit;

    const fitAndReportSize = () => {
      try {
        fit.fit();
      } catch {
        return;
      }
      void sessionResize(sessionId, term.cols, term.rows);
    };
    fitAndReportSize();

    const dataDisposable = term.onData((data) => {
      void sessionWrite(sessionId, data);
    });

    const resizeObserver = new ResizeObserver(() => fitAndReportSize());
    resizeObserver.observe(container);

    let cancelled = false;
    let unlistenOutput: UnlistenFn | undefined;
    let unlistenDrop: UnlistenFn | undefined;

    void listen<string>(`session-output:${sessionId}`, (event) => {
      term.write(base64ToBytes(event.payload));
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
      resizeObserver.disconnect();
      unlistenOutput?.();
      unlistenDrop?.();
      term.dispose();
      termRef.current = null;
      fitRef.current = null;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [sessionId]);

  // Re-fit and refocus whenever this tab becomes the visible one (covers
  // both "just switched to it" and "window resized while it was hidden").
  useEffect(() => {
    if (!visible) return;
    const frame = requestAnimationFrame(() => {
      const term = termRef.current;
      const fit = fitRef.current;
      if (!term || !fit) return;
      try {
        fit.fit();
      } catch {
        // container not laid out yet — next resize/visibility flip retries.
      }
      term.focus();
      void sessionResize(sessionId, term.cols, term.rows);
    });
    return () => cancelAnimationFrame(frame);
  }, [visible, sessionId]);

  return (
    <div
      ref={containerRef}
      className="terminal-surface"
      style={{ display: visible ? "block" : "none" }}
      data-session-id={sessionId}
    />
  );
}
