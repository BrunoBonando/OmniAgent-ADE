# Flow-Style Layout — Design Spec

- **Date:** 2026-09-01
- **Status:** Approved by Bruno ("I really like the way Wispr Flow is organized … apply those changes, just keep our color theme for now")
- **Scope:** Native macOS app (`macos/`) only. Structure and placement; **no palette change** — every colour is an existing `ShellPalette` token.

## Context

Bruno compared the app against Wispr Flow's desktop app and liked how Flow is *organized*: a fixed feature menu on the left, the content as an inset floating card, a bell + account avatar top-right with a popover, and every page as title → tabs → card grid. This spec applies that organization to the existing Copilot-style shell (`2026-08-20-copilot-nav-redesign-design.md`) in the app's own dark language. Typography and card-language changes are deliberately out of scope (Bruno: "we'll change it later").

## 1. Window chrome

- The 38pt hand-drawn strip (`WorkspaceTitleBarView`) stays: traffic lights + sidebar toggle on the left.
- **Top-right, right→left:** the **account avatar** (24pt circle: picture / initials / `person.fill` glyph — the exact three modes `SidebarAccountRowView` had, now in a reusable `AccountAvatarView`), the **notifications bell** (`bell` symbol, a 6pt `ShellPalette.red` dot at its top-right while unread > 0), then the existing review-panel toggle (still hidden off the Desk). 8pt between controls, 12pt from the trailing edge. All three are in `controls` so they keep their clicks and everything else drags the window.
- Bell press → `WorkspaceWindowController.showNotifications(_:)`; avatar press → `showAccountMenu(_:)`. Both travel the responder chain like the sidebar toggle.

## 2. Content card

- **Amended 2026-09-02 — one ground.** The `PaneGroundView` gradient is the *window's* content view, behind the split: the sidebar, the title strip and the content column all sit on the one sheet, and the card is the only thing floating on it — Flow's window is one ground with a card on it, not a sidebar slab beside a content slab. The sidebar paints nothing of its own (its Liquid Glass sheet, blue wash and grey trailing hairline are gone; the review panel keeps its glass), `contentContainer` is a plain transparent view, and the split's divider is painted with nothing (`GroundSplitView`). The ground's blue is the one the glass column produced, measured off the built app: `44, 52, 87` → `29, 32, 52`, top-lit.
- Inside `contentContainer` sits one **`ContentCardView`**: layer-backed, corner radius 14 (continuous), `masksToBounds`. **Amended 2026-09-02 — tinted glass.** The card is a Liquid Glass sheet (`WorkspaceGlass.sheet`, macOS 26+) under every page, wearing its own two-stop wash `ShellPalette.contentCardTint` (`124, 136, 255 @ 0.10` → `70, 80, 150 @ 0.06`, top-lit) in a `ShellGlassTintView` — the same glass-plus-wash the review panel and the sidebar's cards are made of, a hue off the navy ground so the card reads as its own colour rather than a lighter patch of the same. Below 26 the wash sits on the flat `contentCardFill` with a 1pt `cardStroke` border standing in for the glass rim. The tint is a token so the theme Bruno will build later recolours the card from outside; nothing else about the card is colour.
- Pinned: **top = `WorkspaceTitleBarView.height`, leading/trailing/bottom = 12.** With the sidebar collapsed the card still sits 12pt off the window's left edge; with the review panel open it sits 12pt off the divider.
- The Desk (`workspace`), the To Do placeholder, Home, Insights, Settings and the docked Settings panel are **children of the card**, pinned to its four edges at 0. Pages no longer run under the title strip: `ShellScrollView`'s `topInset`/`topFade` for pages go to 0 (the card's edge is the boundary now).
- `sessionTitleField` stays in the strip (in `contentContainer`, outside the card).
- Settings panel: only **docked** or **hidden** — the "offered beside the gear" mode is deleted with the gear (§3). Docked = 12pt inside the card's left edge, 12pt below its top.

## 3. Sidebar (top to bottom)

- **Fixed nav rows:** Home, To Do List, **Insights** (`chart.bar.xaxis`), Search. Insights is a destination; Search still only raises the spotlight.
- **Workspaces** header + tree: unchanged.
- **Foot, top to bottom:** update card (when there is an update) → session/week limits card → system stats row → **footer rows** → 10pt.
- **Footer rows** are two `SidebarNavRowView`s: **Settings** (`gearshape`, lit while the destination is `.settings`, a 7pt `ShellPalette.red` badge dot at its trailing edge while an update is available or ready to restart) and **Help** (`questionmark.circle`, pops `NSApp.helpMenu` at the row).
- **The account row is removed** (`SidebarAccountRowView` deleted; the avatar moved to the title bar). Its gear is gone too, so `SettingsPanelPlace.offered`, `toggleSettingsPanel`, the panel's tip/drop and the click-away monitor are deleted with it. ⌘, and the menu still open Settings via `showSettings(section:)`.

## 4. Popovers (top-right)

Both reuse `HomeDropdown` — the app's own popover rows, not `NSMenu`.

- **Notifications:** header "Notifications"; one row per `notifier.entries` newest first — icon `circle.fill` tinted by the status's dot colour (`ShellDotsView`'s), title "`sessionLabel ?? title` · `NotificationFeed.subtitle(for:)` · `NotificationFeed.relativeTime`". Pressing a row runs `.focusPane(sessionID:)`. A last section offers "Mark all as read" and "Clear all". Empty: one disabled row "No notifications yet". Presenting the dropdown marks all read (`notifier.markAllRead()`); the bell's dot follows `NotificationFeed.unreadCount` and is refreshed wherever `persistNotifications` runs.
- **Account — amended 2026-09-02:** its own `AccountMenuView` in the same popover (`HomeDropdown.present`, the plumbing `show` now sits on), laid out like Flow's rather than as a searchable row list. Top to bottom, hairlines between: a 44pt `AccountAvatarView` beside the account's name (15 semibold) and email (13); "You are on OmniAgent Free" with an accent "Upgrade" pill (`PaneApprovalButton`) that opens `www.omni-agent.ai/pricing` until plans exist; then "Manage account" (→ Settings › Accounts). **No "Log out"** — it stays under Manage account, because it is not something anyone does every day (Bruno's call). Signed out: "Not signed in", no plan row, "Sign in" then "Manage account". Identity comes from the `auth_account_*` rows `refreshAccountSection` already reads, the picture from the title bar's avatar cache.

## 5. Page shell

`PageShellView` — the frame every page destination wears:

- 32pt top padding, 40pt sides. **Title** `ShellFont.ui(24, .semibold)` in `ShellPalette.ink`, top-left.
- Optional **tab strip** 14pt under the title: `ShellFont.ui(14, .medium)` labels, selected in `ink` with a 2pt `ink` underline, others `inkTertiary`; a `ShellPalette.hairline` rule under the strip spanning the content width. `onSelectTab` fires the index.
- Optional **trailing accessory** (a page-level action view) aligned with the title's baseline at the trailing edge.
- The **body** scrolls in a `ShellScrollView` under the header, no fade, no inset; the body fills the width (40pt padding).

## 6. Insights page (`.insights` destination)

`InsightsSurfaceView` = `PageShellView(title: "Insights")` with tabs **Usage** / **Activity**.

- **Usage:** a 3-up KPI row of `HomeCardView`s (spacing 16): **Sessions** (`totals.sessionsOpened`), **Tokens** (`totals.tokenCount`), **Active hours** (`avgActiveHoursPerDay × trackedDays`, one decimal) — each a `ShellFont.ui(34, .semibold)` numeral over an 11pt `.medium` all-caps `inkTertiary` label. Under it, one full-width card hosting the existing SwiftUI `UsageView` (`NSHostingView`) in its `embedded: true` form (no totals row, no opaque ground of its own) — the daily/hourly charts for free. The KPI numerals follow the viewer's locale (`Locale.current`, injectable for tests). Data: `UsageViewModel(store: usageRecorder.store, projectDirectory: brainAdmin)` rebuilt each time the page is shown, as `SettingsView` does.
- **Activity:** a second `ReviewPanelInsightsView` fed by `syncPageInsights()` — `syncReviewPanelInsights`'s logic over **every** terminal pane (all groups), lane titles "session · pane". Fed on show and on every status event while the page is on screen with the Activity tab picked; guarded exactly like its review-panel sibling.
- Spotlight: the destination row comes from `allCases`; the two tabs are rows of their own (`PaletteAction.showInsightsTab`).

## 7. Home on the shell

- `HomeSurfaceView` wears `PageShellView(title: "Home")`, no tabs. The 22.5%-of-height top air and the title-strip fade are gone (the shell's header anchors the page); the hero mark and composer stay, centred, 24pt under the header (the shell's own body padding).
- The column widens to fill the card: centred, ≤ 1080pt, ≥ 40pt from each side.
- Section gaps 72 → 32. **Up next** and **What's new** sit side by side (2-up, equal widths, 16pt gap); the suggestion cards (3-up) and Extend (2-up) rows are unchanged. Order: hero, composer, suggestions, the 2-up row, then **Extend your experience** — the user's own work above the marketing cards — with 40pt before the footer. Footer line unchanged.
- Every word the design says stays (`testTheHomeScreenSaysWhatTheDesignSays` keeps passing).

## 8. Spotlight rows (standing rule)

New rows, each with a `CommandPaletteTests` case: **Insights** (free, via `WorkspaceDestination.allCases`), **Insights › Usage** / **Insights › Activity**, **Notifications** (`bell`, subtitle "Title bar"), **Account** (`person.crop.circle`, "Title bar"), **Help** (`questionmark.circle`, "Sidebar"). Destination subtitles stop saying "under development" where the page is real: Home "start a session", Insights "usage and activity", Settings "the app's settings"; To Do List keeps "under development".

## 9. Out of scope (later, by Bruno's call)

Typography tier (display numerals beyond the KPI cards), card-language unification, the circular Share badge, referral / mobile cross-sell, the streak heatmap, ⓘ tooltips on metrics, any light theme.
