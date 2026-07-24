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
// CSS custom properties, so the HUD palette is duplicated here once.
const HUD_THEME = {
  background: "#0a0d12",
  foreground: "#c9d3de",
  cursor: "#4d8dff",
  cursorAccent: "#0a0d12",
  selectionBackground: "#1f2733",
  black: "#0a0d12",
  red: "#e5484d",
  green: "#43c98f",
  yellow: "#e8a23d",
  blue: "#4d8dff",
  magenta: "#8b7cf6",
  cyan: "#5fd4c8",
  white: "#c9d3de",
  brightBlack: "#66748a",
  brightRed: "#ff6b70",
  brightGreen: "#5eeaa8",
  brightYellow: "#ffbb5c",
  brightBlue: "#78a9ff",
  brightMagenta: "#a996ff",
  brightCyan: "#7fe8dc",
  brightWhite: "#eef2f7",
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
