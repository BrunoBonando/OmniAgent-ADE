# Sidebar Account Menu Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move the mocked account identity to a full-width bottom-left sidebar row and put Review, About, and Keyboard shortcuts inside its existing submenu.

**Architecture:** Keep `AccountBadge` as the sole account trigger/menu and let `Sidebar` own the existing Review/About panels. Remove account props and rendering from `AppChrome`; pass the same auth state from `App` to `Sidebar`.

**Tech Stack:** React 19, TypeScript, CSS, Vitest, Testing Library

## Global Constraints

- Keep the existing mocked login and identity state.
- Reuse the existing account menu, Review panel, About panel, and Keyboard shortcuts sheet.
- Add no dependency, component, or state store.
- Keep notifications in the title bar.

---

### Task 1: Extend the account trigger and submenu

**Files:**
- Modify: `ui/src/state/accountBadgeState.ts`
- Modify: `ui/src/components/AccountBadge.tsx`
- Modify: `ui/src/components/AccountBadge.test.tsx`
- Modify: `ui/src/App.css`

**Interfaces:**
- Consumes: existing `signedInRaw`, `personaRaw`, and `onResetAuthGate` props.
- Produces: optional `onOpenReview?: () => void` and `onOpenAbout?: () => void` callbacks; menu item IDs `"review"` and `"about"`.

- [ ] **Step 1: Write failing component tests**

Add tests that render the full mocked identity in the trigger, open the menu, click “Review session summaries” and “About OmniAgent ADE”, and assert the supplied callbacks fire while the menu closes.

- [ ] **Step 2: Verify the focused test fails**

Run: `cd ui && npm test -- src/components/AccountBadge.test.tsx`

Expected: FAIL because the full name and new menu rows do not exist.

- [ ] **Step 3: Implement the minimal account changes**

Add the two menu items to `accountMenuItems`, render the display name beside the existing avatar, route the two IDs to their callbacks, and add a small disclosure glyph. Update the account CSS from a 20px circular title-bar button to a full-width sidebar row; anchor `.account-menu` above and to the right with `bottom: 100%`, `left: 0`, and a small bottom margin.

- [ ] **Step 4: Verify the focused test passes**

Run: `cd ui && npm test -- src/components/AccountBadge.test.tsx`

Expected: PASS.

### Task 2: Move the account surface into the sidebar

**Files:**
- Modify: `ui/src/components/Sidebar.tsx`
- Modify: `ui/src/components/Sidebar.test.tsx`
- Modify: `ui/src/components/AppChrome.tsx`
- Modify: `ui/src/components/AppChrome.test.tsx`
- Modify: `ui/src/App.tsx`
- Modify: `ui/src/App.css`

**Interfaces:**
- `Sidebar` consumes `authSignedIn: string | null`, `authPersona: string | null`, and `onResetAuthGate: () => void`.
- `AppChrome` no longer consumes auth props.

- [ ] **Step 1: Write failing placement and interaction tests**

In `Sidebar.test.tsx`, supply auth props and assert the bottom account row shows “Bruno Bonando”; open its menu, click Review and About in separate tests, and assert the existing dialogs open. Assert the old shortcut hint and standalone Review/About controls are absent.

In `AppChrome.test.tsx`, assert notifications remain and `.account-badge-anchor` is absent.

- [ ] **Step 2: Verify the focused tests fail**

Run: `cd ui && npm test -- src/components/Sidebar.test.tsx src/components/AppChrome.test.tsx`

Expected: FAIL because the account trigger is still in `AppChrome` and absent from `Sidebar`.

- [ ] **Step 3: Implement the minimal placement change**

Render `AccountBadge` in `.sidebar-footer`, pass its Review/About callbacks to the existing local panel state, and delete the old hint and standalone buttons. Remove `AccountBadge` and auth props from `AppChrome`. Move the three auth props in `App.tsx` from `AppChrome` to `Sidebar`. Keep `.sidebar-footer` as a simple bottom border container for the full-width trigger.

- [ ] **Step 4: Verify focused and full UI checks**

Run:

```bash
cd ui
npm test -- src/components/Sidebar.test.tsx src/components/AppChrome.test.tsx src/components/AccountBadge.test.tsx
npm test
npm run build
```

Expected: all tests and the production build pass.

- [ ] **Step 5: Commit the implementation**

Commit only the files changed for this feature with:

```bash
git add ui/src/state/accountBadgeState.ts ui/src/components/AccountBadge.tsx ui/src/components/AccountBadge.test.tsx ui/src/components/Sidebar.tsx ui/src/components/Sidebar.test.tsx ui/src/components/AppChrome.tsx ui/src/components/AppChrome.test.tsx ui/src/App.tsx ui/src/App.css
git commit -m "feat: move account menu to sidebar"
```
