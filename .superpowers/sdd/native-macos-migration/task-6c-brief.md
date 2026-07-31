# Task 6c — Persistence service: SMAppService/LaunchAgent for the PTY daemon

Sub-task of plan Task 6 (`docs/plans/native-macos-migration.md`), split for implementer-sized review. Plan bullet:

> Bundle/register the service through `SMAppService` with its LaunchAgent plist, status UI, degraded app-owned mode, termination cleanup, restart-loss reporting, preview bundle/data separation, and existing production data reuse.

**Depends on Task 6b** for a settings-surface home for the status UI (read `.superpowers/sdd/native-macos-migration/task-6b-report.md` for where its SwiftUI settings screen lives and how to add a section to it). If 6b's settings screen doesn't have an obvious extension point, a small standalone status window is an acceptable fallback — note the choice in your report.

## What exists today (confirmed by research — nothing below exists yet; you're building all of it)

- The "service" being registered is `omniagent-pty-daemon` (`crates/omniagent-pty-daemon`) — the same daemon Tasks 2-3 already built. Today the native app connects to it over a Unix socket at a fixed path (`macos/OmniAgent/AppDelegate.swift`'s `socketURL`: `OMNIAGENT_PTY_SOCKET` env override, else `~/.omniagent-ade/omniagent-pty.sock`) and — per the Tauri-side auto-launcher precedent in `docs/superpowers/plans/2026-07-27-native-pty-daemon.md` — auto-spawns it if not already running. There is **no existing `SMAppService`, LaunchAgent plist, or persistence-service registration anywhere in this repo** (checked docs, code, and all prior phase reports). You are inventing this mechanism from this plan bullet alone.
- `brain-core`'s data dir defaults to `~/Library/Application Support/OmniAgent-ADE` (`crates/brain-core/src/store.rs:268-276`, override via `OMNIAGENT_ADE_DATA_DIR`) — "existing production data reuse" means a production-registered service must resolve to this exact path unchanged, not a new default.

## Required behavior

- Register `omniagent-pty-daemon` as an `SMAppService.agent(plistName:)` (user-level LaunchAgent — matches "existing production data reuse" under the user's home dir; do not use `.daemon`, which is root/system-level and wrong for a per-user PTY session owner) with its own LaunchAgent plist (label, program path, `KeepAlive`/`RunAtLoad` as appropriate for a long-lived per-user service).
- **Degraded app-owned mode**: if `SMAppService` registration or launch fails, or the user hasn't approved it in System Settings > Login Items, the app must fall back to spawning/owning the daemon process itself (today's implicit behavior) rather than failing outright. Surface which mode is active in the status UI.
- **Termination cleanup**: quitting the app must NOT kill the daemon or its live PTY sessions when the daemon is running as a registered service (that persistence is the entire point) — cleanup is limited to the app's own registration bookkeeping/status state. In degraded app-owned mode, current Task 4/5 cleanup behavior (`applicationWillTerminate` → `workspace?.stop()`) is the reference for what "the app's own state" means; do not change daemon-owned-session teardown semantics.
- **Restart-loss reporting**: detect when the service was restarted (e.g. crashed and relaunched by `launchd`) since the app last observed it, and report which sessions (if any) were lost via the status UI, rather than silently reattaching to nothing.
- **Preview bundle/data separation**: a preview/beta build must use a distinct data dir, socket path, and LaunchAgent label from a production build, so the two never collide on the same machine. Production installs keep today's paths unchanged (see data dir above, and `AppDelegate.swift`'s socket path).
- No App Sandbox (plan-wide constraint: "the initial direct-download build is not App Sandbox enabled") — do not add sandbox entitlements here; that would conflict with direct PTY/process ownership.

## Global constraints that bind this task

- Keep Rust PTY/process ownership as-is — this task changes how the daemon process is *launched/registered*, not its ownership model or protocol.
- macOS 14 target, AppKit primary / SwiftUI for low-frequency surfaces (status UI belongs in the latter).
- Follow TDD for behavior changes — the registration/degraded-mode/restart-detection logic should be unit-testable independent of an actual `SMAppService` approval flow (which cannot be exercised in CI); structure it so the decision logic (which mode to use, how to detect restart) is testable, and the actual `SMAppService` calls are a thin, separately-isolated layer.

## Verification

- `./macos/build.sh test`
- `./macos/build.sh build`
- `git diff --check`

Commit all Task 6c work and write `.superpowers/sdd/native-macos-migration/task-6c-report.md`, including how you tested the untestable-in-CI parts (manual verification steps, if any, clearly labeled as such).
