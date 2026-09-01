# Self-update — design

> 2026-09-01. Decisions in this doc are Bruno's, taken 2026-09-01.

The app updates itself from `dl.omni-agent.ai`. A widget above the sidebar's
nav rows carries the whole story: **Update available → Updating… (progress) →
App updated, restart required**. Settings › General, the OmniAgent menu and
the Home page all reach the same one object.

## 1. What already exists

| Piece | State |
|---|---|
| Versioning | `MARKETING_VERSION` = `CURRENT_PROJECT_VERSION` = `1.7.20`, semver, bumped by `scripts/bump-build-version.sh` |
| Artifact | `rebuild-app.sh` → `target/native-macos-dist/OmniAgent_<version>_universal.dmg`, signed + notarized + stapled |
| Host | `https://dl.omni-agent.ai/` is live and **empty** (one `hello.txt`); no `/releases/` yet |
| Updater | **Nothing.** No Sparkle, no appcast, no update code anywhere in the tree |

So the versioning and the artifact are done; the feed, the framework and every
UI surface are not.

## 2. Decisions

- **Sparkle 2.x**, via SPM. Not hand-rolled.
- **Custom `SPUUserDriver`.** Sparkle's stock windows never appear. Our driver
  is the sidebar widget; every Sparkle callback maps to one widget state.
- **Install now, relaunch on the user's word.** Download and install proceed
  as soon as the widget is pressed; the app does not restart itself. The
  widget's terminal state is a Restart button.
- **Check automatically, download on click.** Check on launch and once a day.
  Nothing downloads until the widget is pressed.
- **Settings › General**, one block. No new `SettingsSection` case.
- Stable channel only. A beta channel is one extra feed URL away; not built.

## 3. The daemon is the hard part

Installing replaces `/Applications/OmniAgent.app` — the bundle that *contains
the running PTY daemon*. This is the exact trap `rebuild-app.sh` documents at
length: leave the daemon up and the install silently keeps running the old
one from an unlinked inode, so daemon-side changes look shipped and are not.

Sparkle gives us the seam:

```
SPUUpdaterDelegate.updater(_:shouldPostponeRelaunchForUpdate:untilInvokingBlock:)
  -> return true
  -> if local sessions are live: the house liquid-glass ask ("3 sessions will end")
  -> DaemonPersistenceController.terminateDaemon (pid off the socket's LOCAL_PEERPID)
  -> invoke the block  ->  Sparkle relaunches the new app, which respawns the daemon
```

This is the same shape as `switchAccount` / `logOutOfAccount`, and it honours
the standing rule: **never kill a busy daemon without asking.** The ask fires
at Restart, not at download — pressing "Update" costs a user nothing.

Also verify: `DaemonServiceRegistrar`'s LaunchAgent has a bundle-relative
`Program`, so the path survives the swap; confirm launchd does not resurrect
the old binary between terminate and relaunch.

## 4. Widget states

One `SidebarUpdateWidgetView` sharing a stack with `SidebarClaudeLimitsView`
at the foot of the column — the same sheet of liquid glass, the same 14pt
radius, the same 8pt gutter, so the two read as one stack of cards. `isHidden`
when there is nothing to say, and being a stack child is what makes hiding it
give the room back instead of leaving a gap above the gauges.

It carries an accent wash over the glass and a slow band of light that crosses
the card only while something is waiting to be taken (`.available`,
`.readyToRestart`) — never while it is working, and never under Reduce Motion.
States map 1:1 to `SPUUserDriver`:

| Widget | Sparkle callback |
|---|---|
| *(hidden)* | idle / `dismissUpdateInstallation` |
| `Update available · 1.7.21` + press to start | `showUpdateFound(…)` — reply held until pressed |
| `Updating…` + determinate bar | `showDownloadDidStart` → `showDownloadDidReceiveData(ofLength:)` → `showExtractionReceivedProgress` |
| `App updated — Restart` | `showReadyToInstallAndRelaunch` — reply held until Restart is pressed |
| `Update failed` + retry | `showUpdaterError` |

The reply blocks are held, not answered immediately — that is what turns
Sparkle's modal flow into a widget the user drives at their own pace.

## 5. Feed and publishing

- `SUFeedURL` = `https://dl.omni-agent.ai/releases/appcast.xml`
- `SUPublicEDKey` = the base64 public key from `generate_keys`; the private
  key stays in Bruno's login keychain and is never in the repo.
- `scripts/publish-release.sh`: run `generate_appcast` over
  `target/native-macos-dist/`, then `curl -T` the DMG and `appcast.xml` to
  `$OMNIAGENT_DL/releases/`. Credentials from `$OMNIAGENT_DL_AUTH` — never
  committed.

**Cloudflare caches `appcast.xml`.** Overwrite it and the edge may keep
serving the old one, so a release appears not to exist. One-time fix: a
Cloudflare Cache Rule bypassing cache for `/releases/appcast.xml`. Sparkle's
own no-cache policy only defeats the *local* URL cache, not the edge.

Two trust anchors, both free: Sparkle's EdDSA signature on the DMG, and
Sparkle's own check that the new app's Apple code signature matches the
running one. No new entitlement, no privileged helper.

## 6. Signing

`Sparkle.framework` embeds nested code — `Autoupdate.app`, `Updater.app`,
XPC services — each of which must be signed inner-out with the same identity.
`dist.sh sign` currently signs the daemon and the bundle only; it must learn
the framework. `dist.sh preflight` must assert the Sparkle helpers carry our
Team ID and the hardened runtime, the same way it already does for the daemon.

We are not sandboxed, so the XPC installer services are optional; keep them
(they ship inside the framework) rather than surgically deleting them.

## 7. Surfaces

Every one of these drives the same `UpdateController`:

- Sidebar card, directly above `SidebarClaudeLimitsView` (session/week).
- Settings › General: version line, **Check Now**, auto-check toggle, and the
  widget's current state.
- OmniAgent menu: **Check for Updates…**, straight after About.
- Home: one `HomeCardView` row, visible only when an update is available.
- Spotlight: "Check for Updates", "Install Update", "Restart to Update" —
  mandatory per the repo's *Spotlight finds everything* rule, with
  `CommandPaletteTests` cases.
