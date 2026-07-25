// Curated, extension-keyed icon set for the file tree (founder feedback,
// Part B, verbatim: the file view "must work exactly like the Finder from
// Mac OS"). See `state/fileTreeState.ts`'s "icons" section for the pure
// kind/accent resolution this only renders — `iconKindForEntry` picks one of
// four shape families (folder/folder-open, code, markup/docs, image,
// generic fallback — the brief's own categorization), `accentForEntry` picks
// a per-extension color layered on top.
//
// Inline SVG rather than an icon font or fetched OS icons: no new asset
// pipeline or font-loading flash, scales crisply at any panel width (the
// panel is now resizable — Task 9), and `currentColor` lets each glyph
// inherit this app's existing tokens the same way every other piece of
// chrome already does. The outer page/folder silhouette always stays
// neutral (`--ink-dim`, matching `.file-tree-chevron`'s own tone) — only the
// small glyph-in-the-page (brackets for code, lines for docs, a tiny
// picture for images) and the folder body take the accent color. This
// mirrors this app's established "a colored accent marks a sub-kind"
// language (`ENGINE_COLOR` dots in `PaneHeader`/`theme.ts`, the stale/
// attention dots in `Sidebar`) instead of introducing a second, louder
// visual vocabulary (e.g. full-color per-language logos) that would clash
// with the panel's otherwise quiet HUD aesthetic.
import type { FileIconKind } from "../state/fileTreeState";

interface FileIconProps {
  kind: FileIconKind;
  /** From `accentForEntry` — a CSS color (hex or `var(--token)`). */
  color: string;
}

const VIEWBOX_SIZE = 14;

function FolderGlyph({ open, color }: { open: boolean; color: string }) {
  return open ? (
    <path
      d="M1.5 4.3c0-.6.4-1 1-1h3l1.2 1.3h5.8c.6 0 1.05.5 1 1.1l-.9 5.4c-.1.5-.55.9-1 .9H2.5c-.6 0-1-.4-1-1z"
      fill={color}
      fillOpacity="0.16"
      stroke={color}
      strokeWidth="1.1"
      strokeLinejoin="round"
    />
  ) : (
    <path
      d="M1.5 3.6c0-.6.4-1 1-1h3l1.2 1.4h5.8c.6 0 1 .4 1 1v6.4c0 .6-.4 1-1 1h-10c-.6 0-1-.4-1-1z"
      fill="none"
      stroke={color}
      strokeWidth="1.1"
      strokeLinejoin="round"
    />
  );
}

/** The shared "page with a folded corner" silhouette every non-folder icon
 * is built on — always the neutral shape tone, never the accent color, so
 * the accent stays legible as "this is the type marker" rather than
 * competing with the outline. */
function PageOutline() {
  return (
    <>
      <path
        d="M3.6 1.4h4.3l3 3v8c0 .6-.45 1-1 1H3.6c-.55 0-1-.4-1-1V2.4c0-.55.45-1 1-1z"
        fill="none"
        stroke="currentColor"
        strokeWidth="1.1"
        strokeLinejoin="round"
      />
      <path d="M7.9 1.4v2.7c0 .5.4.9.9.9h2.6" fill="none" stroke="currentColor" strokeWidth="1.1" strokeLinejoin="round" />
    </>
  );
}

function CodeGlyph({ color }: { color: string }) {
  return (
    <>
      <path d="M5.7 7.7 4.3 9l1.4 1.3" fill="none" stroke={color} strokeWidth="1.1" strokeLinecap="round" strokeLinejoin="round" />
      <path d="M8.3 7.7 9.7 9l-1.4 1.3" fill="none" stroke={color} strokeWidth="1.1" strokeLinecap="round" strokeLinejoin="round" />
    </>
  );
}

function MarkupGlyph({ color }: { color: string }) {
  return <path d="M4.3 7.7h5.2M4.3 9.3h5.2M4.3 10.9h3.4" stroke={color} strokeWidth="1.1" strokeLinecap="round" />;
}

function ImageGlyph({ color }: { color: string }) {
  return (
    <>
      <circle cx="5.15" cy="7.75" r="0.85" fill={color} />
      <path d="M4 11 6.15 8.6l1.5 1.7 1.15-1.35L10 11z" fill="none" stroke={color} strokeWidth="1.1" strokeLinejoin="round" />
    </>
  );
}

export default function FileIcon({ kind, color }: FileIconProps) {
  return (
    <svg
      className="file-tree-icon"
      width={VIEWBOX_SIZE}
      height={VIEWBOX_SIZE}
      viewBox="0 0 14 14"
      aria-hidden="true"
      style={{ color: "var(--ink-dim)" }}
    >
      {kind === "folder" && <FolderGlyph open={false} color={color} />}
      {kind === "folder-open" && <FolderGlyph open={true} color={color} />}
      {kind === "code" && (
        <>
          <PageOutline />
          <CodeGlyph color={color} />
        </>
      )}
      {kind === "markup" && (
        <>
          <PageOutline />
          <MarkupGlyph color={color} />
        </>
      )}
      {kind === "image" && (
        <>
          <PageOutline />
          <ImageGlyph color={color} />
        </>
      )}
      {kind === "generic" && <PageOutline />}
    </svg>
  );
}
