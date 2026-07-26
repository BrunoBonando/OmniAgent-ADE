# Sidebar Account Menu Design

## Goal

Keep the existing mocked login state, but move its account affordance from the
top-right title bar to the bottom of the left sidebar. The account affordance
must show the user's avatar and name, and clicking it must open the existing
account submenu.

## Layout

The sidebar ends with one full-width account row:

```text
┌────────────────────────┐
│ [B] Bruno Bonando    ▴ │
└────────────────────────┘
```

It replaces the current shortcut hint and footer controls. The notifications
button remains in the title bar; the account button does not.

The row uses the existing mocked identity and signed-out fallback. Long names
truncate instead of widening the sidebar. Keyboard focus remains visible.

## Interaction

Clicking the account row toggles the existing account menu. Because the trigger
is at the bottom of the sidebar, the menu opens upward and toward the workspace.
Clicking the backdrop or the trigger again closes it.

The menu keeps its existing actions and adds:

- Review session summaries
- About OmniAgent ADE

Keyboard shortcuts remains an account-menu option. Review and About open their
existing panels; they no longer have separate sidebar controls.

## Components and Data Flow

`App.tsx` continues to own auth settings and reset behavior. It passes the
existing auth values and reset callback to `Sidebar`, which renders
`AccountBadge` in its footer. `AccountBadge` receives callbacks for opening the
existing Review and About panels.

`AppChrome` stops rendering `AccountBadge` and continues rendering
`NotificationsPanel`.

No login, identity persistence, new menu component, or new state store is
introduced.

## Verification

Focused component tests will verify:

- the title bar no longer contains the account trigger;
- the sidebar shows the mocked user's avatar and full name at its bottom;
- clicking the row opens the account menu;
- Review and About appear inside that menu and open their existing panels;
- the old standalone footer controls and shortcut hint are absent.

The existing account action tests must continue to pass.
