// Warp-direction reskin: each sidebar chip gets a small circular avatar —
// the founder's reference shows "a small circular colored avatar/icon on
// the left" of every chip row. Purely decorative/derived (no new data): a
// fixed, muted palette cycled by a stable hash of a project **or session**
// id, so a given row always gets the same color across renders/relaunches
// without persisting anything new. Deliberately its own small palette
// rather than reusing `ENGINE_COLOR` — a project isn't an engine, and
// borrowing that palette would visually suggest a (false) engine
// association for projects that have no open sessions at all.
//
// Relocated out of `Sidebar.tsx` (left-pane redesign, Task 2) so
// `WorkspaceMenu.tsx` can share it without importing from `Sidebar.tsx`
// itself — that would be circular, since Sidebar renders WorkspaceMenu.
export const PROJECT_AVATAR_COLORS = ["#b696f2", "#a2e7f9", "#ed81c3", "#e8a23d", "#5fd4c8", "#78a9ff"];

export function idColor(id: string): string {
  let hash = 0;
  for (let i = 0; i < id.length; i++) hash = (hash * 31 + id.charCodeAt(i)) | 0;
  return PROJECT_AVATAR_COLORS[Math.abs(hash) % PROJECT_AVATAR_COLORS.length];
}
