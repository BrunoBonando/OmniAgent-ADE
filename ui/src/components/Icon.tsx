// The app's icon set. Replaces the unicode glyphs (⑂ ⧉ ↺ ↗ ⋯ ▤ ⇄ ✓ ✗) that
// used to stand in for icons — those rendered at 9-13px in whatever the
// platform font happened to have for that codepoint, so they had no shared
// stroke weight, no shared optical size, and half of them (⑂ for a branch,
// ▤ for a file count) only read as their meaning if you already knew.
//
// Geometry is Lucide's (ISC), inlined rather than adding `lucide-react`:
// a dozen paths is a dozen paths, and this app already draws its folder /
// person / inbox glyphs the same way.
//
// ponytail: no per-icon components, no barrel file, no size tokens. One
// record, one component. Add a name to the record when something needs one.

export type IconName =
  | "branch"
  | "files"
  | "compare"
  | "copy"
  | "undo"
  | "external"
  | "chevron-right"
  | "chevron-down"
  | "more"
  | "check"
  | "checklist"
  | "info"
  | "plus"
  | "x";

const PATHS: Record<IconName, React.ReactNode> = {
  branch: (
    <>
      <line x1="6" y1="3" x2="6" y2="15" />
      <circle cx="18" cy="6" r="3" />
      <circle cx="6" cy="18" r="3" />
      <path d="M18 9a9 9 0 0 1-9 9" />
    </>
  ),
  files: (
    <>
      <path d="M15 2H8a2 2 0 0 0-2 2v12a2 2 0 0 0 2 2h9a2 2 0 0 0 2-2V6z" />
      <path d="M15 2v4h4" />
      <path d="M3 7v13a2 2 0 0 0 2 2h9" />
    </>
  ),
  compare: (
    <>
      <circle cx="18" cy="18" r="3" />
      <circle cx="6" cy="6" r="3" />
      <path d="M13 6h3a2 2 0 0 1 2 2v7" />
      <path d="M11 18H8a2 2 0 0 1-2-2V9" />
    </>
  ),
  copy: (
    <>
      <rect x="9" y="9" width="13" height="13" rx="2" />
      <path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1" />
    </>
  ),
  undo: (
    <>
      <path d="M3 12a9 9 0 1 0 9-9 9.75 9.75 0 0 0-6.74 2.74L3 8" />
      <path d="M3 3v5h5" />
    </>
  ),
  external: (
    <>
      <path d="M15 3h6v6" />
      <path d="M10 14 21 3" />
      <path d="M18 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2h6" />
    </>
  ),
  "chevron-right": <path d="m9 18 6-6-6-6" />,
  "chevron-down": <path d="m6 9 6 6 6-6" />,
  more: (
    <>
      <circle cx="12" cy="12" r="1.4" fill="currentColor" stroke="none" />
      <circle cx="19" cy="12" r="1.4" fill="currentColor" stroke="none" />
      <circle cx="5" cy="12" r="1.4" fill="currentColor" stroke="none" />
    </>
  ),
  check: <path d="M20 6 9 17l-5-5" />,
  checklist: (
    <>
      <path d="m3 17 2 2 4-4" />
      <path d="m3 7 2 2 4-4" />
      <path d="M13 6h8" />
      <path d="M13 12h8" />
      <path d="M13 18h8" />
    </>
  ),
  info: (
    <>
      <circle cx="12" cy="12" r="10" />
      <path d="M12 16v-4" />
      <path d="M12 8h.01" />
    </>
  ),
  plus: (
    <>
      <path d="M5 12h14" />
      <path d="M12 5v14" />
    </>
  ),
  x: (
    <>
      <path d="M18 6 6 18" />
      <path d="m6 6 12 12" />
    </>
  ),
};

interface IconProps {
  name: IconName;
  /** Rendered box in px. 16 is the default control size; drop to 12-13 for
   * icons sitting inline with 10-11px metadata text. */
  size?: number;
  className?: string;
  /** Lucide's own default is 2 (on a 24 viewBox). Nudge up for icons that
   * render below ~13px, where 2 thins out to under a device pixel. */
  strokeWidth?: number;
}

export default function Icon({ name, size = 16, className, strokeWidth = 2 }: IconProps) {
  return (
    <svg
      className={className ? `icon ${className}` : "icon"}
      width={size}
      height={size}
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth={strokeWidth}
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
      focusable="false"
    >
      {PATHS[name]}
    </svg>
  );
}
