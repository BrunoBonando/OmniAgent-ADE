// fixed, muted palette cycled by a stable hash of a project or session
// id, so a given row always gets the same color across renders/relaunches
// without persisting anything new.
export const PROJECT_AVATAR_COLORS = ["#b696f2", "#a2e7f9", "#ed81c3", "#e8a23d", "#5fd4c8", "#78a9ff"];

export function idColor(id: string): string {
  let hash = 0;
  for (let i = 0; i < id.length; i++) hash = (hash * 31 + id.charCodeAt(i)) | 0;
  return PROJECT_AVATAR_COLORS[Math.abs(hash) % PROJECT_AVATAR_COLORS.length];
}
