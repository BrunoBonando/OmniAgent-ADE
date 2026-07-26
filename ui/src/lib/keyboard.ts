export function ownsCtrlOnlyShortcut(event: KeyboardEvent): boolean {
  return (
    event.ctrlKey &&
    !event.metaKey &&
    !event.altKey &&
    !event.shiftKey &&
    document.querySelector('[role="dialog"], [role="menu"]') === null
  );
}
