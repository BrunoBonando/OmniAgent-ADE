# App Store Readiness — No-Behaviour-Change Fix Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close every App Store rejection risk in `docs/appstore-rejection-risks.html` that can be closed **without changing how the shipped native app behaves**, and turn the rest into explicit product decisions with sized options.

**Architecture:** Additive only — bundle metadata (privacy manifest, Info.plist keys), build-config gating of a debug surface, a new `dist.sh preflight` gate, a Help menu + two bundled legal pages, and one additive feature Apple mandates (account deletion: Core endpoint + Settings › Accounts button). Nothing existing is removed or rerouted. The four "critical" architecture items (sandbox, PTY, daemon persistence, socket location) cannot be fixed without changing behaviour and are listed as decisions, not tasks.

**Tech Stack:** Swift/AppKit (`macos/`), XCTest (hosted in the app — `Bundle.main` is `OmniAgent.app` in tests), POSIX sh (`macos/dist.sh`), Python/FastAPI + pytest (`OmniAgent-Core`, cross-repo), HTML docs.

**Spec:** `docs/appstore-rejection-risks.html` (the audit) + this plan's "Re-scored risk table" (the corrections).

## Global Constraints

- **No behaviour change to the app.** Existing features keep working exactly as today. Additive UI (a Help menu, a new button, a new palette row) is allowed; removing/redirecting/gating any existing user-facing feature is not.
- `macos/` is the only shipping artifact (standing decision 2026-08-03). Tauri code (`src-tauri/`, `ui/`) is legacy, gated by `scripts/cutover.sh` (0/2, CLOSED) — **do not touch it**.
- Spotlight finds everything (standing rule 2026-08-28): every new menu item / settings button gets a `PaletteCommand` row + a `CommandPaletteTests` test in the same commit.
- Modal questions use `presentWindowAsk` + `PaneAskOverlayView.Severity.critical`, never `NSAlert` (memory: modal-question-liquid-glass-standard).
- Commit trailer: `Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>`; push after every commit; never `git stash`; check mtimes before staging (shared worktree).
- Run the macOS suite as `caffeinate -disu ./macos/build.sh test`.
- Web Inspector opt-in for developers must survive: `defaults write digital.bruno.omniagent OMNIAGENT_WEB_INSPECTOR -bool YES`.

---

## Context

**Interactive twin of this plan:** https://claude.ai/code/artifact/938df400-5193-42db-a631-399327f2a8a1 — "OmniAgent Store Preflight": 31 checks with what each verifies, file:line evidence, PASS / FIX / BLOCKED / EXTERNAL / STALE state, what the fix does, behaviour impact, plus the task ledger (A0–C1, hours) and decisions D1–D4. Task A0 lands it in the repo as `docs/appstore-readiness.html`.

`docs/appstore-rejection-risks.html` (commit `05a2b76`) lists 13 risks. Exploration against the **native** app (the only artifact that ships) shows the report is partly stale — 4 of its evidence trails point at Tauri code that is not in the bundle — and that several "fixes" it asks for are behaviour changes Bruno has ruled out. This plan (a) re-scores each risk against `macos/`, (b) delivers every fix that is purely additive/metadata, sized by effort, and (c) names the remaining product decisions with their cost so they can be decided, not drifted into.

### Re-scored risk table (native app, 2026-08-30)

| # | Report item | Report sev. | Native reality | Re-scored | Disposition |
|---|---|---|---|---|---|
| 1 | App Sandbox absent | critical | True. `OmniAgent.entitlements` = `<dict/>`; socket at `~/.omniagent-ade/omniagent-pty.sock`; data at `~/Library/Application Support/OmniAgent-ADE`. | **critical** | **DECISION D1** — cannot sandbox without breaking terminals |
| 2 | Arbitrary PTY/shell execution | critical | True by design. `session.rs:1042-1070` spawns client-chosen argv or `/bin/zsh`. | **critical** | **DECISION D1** (same root) |
| 3 | Persistent daemon / LaunchAgent | critical | Already the Apple-approved pattern: `SMAppService.agent`, plist in `Contents/Library/LaunchAgents`, user toggle lives in System Settings › Login Items (app deep-links there). Remaining gaps: `KeepAlive=true` with no idle exit; `DaemonBinaryLocator` also accepts `$PATH`/env-var binaries. | **high → medium** | Task A4 (locator) · D1 for the rest |
| 4 | Helper binaries in Resources | high | **Stale (Tauri).** Native daemon is at `Contents/MacOS/omniagent-pty-daemon`, signed same identity with `--options runtime`. | **low** | Task A5 preflight verifies it |
| 5 | In-app `curl \| bash` / `npm -g` installers | critical | **Stale (Tauri).** Zero install code in `macos/`; `EngineLauncher.isInstalled` only greys the menu row. | **none** | Task B2 corrects the report |
| 6 | Broad file access, no bookmarks | high | True, but only matters under sandbox. Three `NSOpenPanel` sites exist; missing `NSDownloadsFolderUsageDescription`. | **medium** | Task A2 (usage strings) · D1 |
| 7 | Browser pane: arbitrary sites, `file://`, silent downloads to ~/Downloads | high | True (`BrowserPaneView.swift:161-164, 220-231`). Save-panel routing = behaviour change. | **medium** | D2 |
| 8 | `isInspectable` in release | medium | True — **3 sites**, not 2 (`BrowserPaneView:45`, `EditorWebView:63`, `ReviewPanelBrowserView:326`); zero `#if DEBUG` in the target. | **medium** | **Task A3** |
| 9 | Privacy disclosures | high | No privacy policy anywhere (SaaS Signup links to `/privacy` + `/terms`, which don't exist either). No `PrivacyInfo.xcprivacy`. Analytics are **local-only** (SQLite via daemon; no URLSession). Hosts contacted: `api.omni-agent.ai`, `appleid.apple.com`, avatar CDN, user-typed URLs. | **high** | **Tasks A1, B1** |
| 10 | External AI/service disclosures | high | True; first-run consent = behaviour change. Sign-in footer already says code/transcripts never leave the Mac. | **medium** | Task B1 (policy text) + B2 (review notes) · D3 |
| 11 | Third-party trademarks/icons | medium | True + **worse**: the four SVGs are lifted from `lobehub/lobe-icons` (MIT — attribution required, currently absent). No disclaimer text exists. | **medium** | **Task B1** (notices + disclaimer) · D4 for logo replacement |
| 12 | Account deletion | high | Confirmed absent in app, Core (`auth.py` has no `DELETE /me`) and SaaS. Guideline 5.1.1(v) mandates it. | **high** | **Task C1** (additive, cross-repo) |
| 13 | Pipeline is Developer ID only | medium | True; no `archive`/`-exportArchive`, no MAS config, no entitlement/team-ID/manifest checks in `dist.sh verify`. | **medium** | **Task A5** (preflight) · D1 for the MAS lane |

### Task list by effort (the deliverable)

| ID | Task | Tier | Effort | Behaviour impact | Repo |
|---|---|---|---|---|---|
| A0 | File the plan (docs/superpowers/plans + My-Brain) | Easy | 15 min | none | ADE, My-Brain |
| A1 | Add `PrivacyInfo.xcprivacy` privacy manifest | Easy | 30 min | none | ADE |
| A2 | Info.plist: Downloads usage string, copyright, encryption exemption | Easy | 20 min | none (TCC prompt text only) | ADE |
| A3 | Gate `isInspectable` (3 sites) behind DEBUG / defaults flag | Easy | 45 min | dev-only: Web Inspector off by default in Release, opt-in via defaults | ADE |
| A4 | `DaemonBinaryLocator`: `$PATH`/env fallbacks only in DEBUG | Easy | 30 min | none in Release (bundle candidate always wins there) | ADE |
| A5 | `dist.sh preflight` — entitlements, team IDs, manifest, plist keys, MAS gate readout | Medium | 2 h | none | ADE |
| B1 | Help menu → bundled Privacy Policy + Third-Party Notices (with lobe-icons/SwiftTerm/Monaco licences + not-affiliated disclaimer) + palette rows | Medium | 2–3 h | additive UI only | ADE |
| B2 | App Review notes doc + correct the HTML report's evidence/severities | Easy | 1 h | none | ADE |
| C1 | Account deletion: `DELETE /v1/auth/me` in Core + Settings › Accounts "Delete account…" with critical ask + palette row | Complex | 4–6 h + Core prod deploy | additive feature | Core, ADE |
| D1–D4 | Product decisions (sandbox/MAS edition, downloads, first-run consent, logos) | — | see §Decisions | behaviour change — **not in scope** | — |

Total in-scope effort: **~12–15 h** (A: ~4.5 h, B: ~4 h, C: ~5 h + deploy).

---

## Tier A — Easy, zero behaviour change

### Task A0: File the plan and the preflight page

**Files:**
- Create: `docs/appstore-readiness.html` — copy of the interactive preflight page built in the planning session (scratchpad `appstore-readiness.html`, published as the "OmniAgent Store Preflight" artifact). It is the human-readable twin of this plan: every check, its evidence, state, fix and the task ledger. Keep it in sync when a task lands (flip the row's `state` to `pass`, tick the ledger).
- Create: `docs/superpowers/plans/2026-08-30-appstore-readiness.md` (copy of this plan)
- Create: `My-Brain/projects/omniagent-ade/sources/2026-08-30-appstore-readiness-plan.md` (short pointer + the re-scored table)
- Modify: `My-Brain/projects/omniagent-ade/README.md` (one line under a new "App Store readiness" heading linking the source), `My-Brain/INDEX.md`, `My-Brain/log.md` (per `My-Brain/CLAUDE.md` schema)

- [ ] **Step 1:** Copy this plan file verbatim to `docs/superpowers/plans/2026-08-30-appstore-readiness.md`.
- [ ] **Step 2:** Write the My-Brain source note (re-scored table + link to the ADE plan) and update README/INDEX/log per the My-Brain schema.
- [ ] **Step 3:** Commit both repos: `docs: file App Store readiness plan` (ADE), `brain: OmniAgent-ADE App Store readiness plan` (My-Brain). Push.

### Task A1: Privacy manifest

**Files:**
- Create: `macos/OmniAgent/PrivacyInfo.xcprivacy`
- Modify: `macos/OmniAgent.xcodeproj/project.pbxproj` (add a `PBXFileReference` + `PBXBuildFile` in the app target's Resources phase — follow the `monaco` pattern at lines 93 / 330 / 465 / 647)
- Test: `macos/OmniAgentTests/BundleComplianceTests.swift` (new)

**Why these categories:** `UserDefaults` is read/written (`AuthGateState.swift:173`, `AuthClient.swift:238`, `EngineLauncher.swift:478-552`) → `NSPrivacyAccessedAPICategoryUserDefaults` reason `CA92.1`. File modification dates are read (`EditorPaneView.swift:559-560`) → `NSPrivacyAccessedAPICategoryFileTimestamp` reason `C617.1`. No tracking, no collected data (analytics never leave the Mac; account email/name/picture are collected by Core under the *App Privacy* questionnaire, not the manifest — the manifest's `NSPrivacyCollectedDataTypes` describes what the app itself sends, which for the signed-in account is email + name → declare `NSPrivacyCollectedDataTypeEmailAddress` and `NSPrivacyCollectedDataTypeName`, purpose App Functionality, not linked for tracking).

- [ ] **Step 1: Write the failing test**

```swift
// macos/OmniAgentTests/BundleComplianceTests.swift
import XCTest

/// The App Store / notarisation bundle facts a reviewer would check first.
/// Tests are hosted in OmniAgent.app, so `Bundle.main` *is* the bundle.
final class BundleComplianceTests: XCTestCase {
    func testThePrivacyManifestIsBundledAndDeclaresTheAPIsTheAppUses() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"))
        let plist = try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: Any])
        XCTAssertEqual(plist["NSPrivacyTracking"] as? Bool, false)
        let apis = try XCTUnwrap(plist["NSPrivacyAccessedAPITypes"] as? [[String: Any]])
        let types = apis.compactMap { $0["NSPrivacyAccessedAPIType"] as? String }
        XCTAssertEqual(Set(types), ["NSPrivacyAccessedAPICategoryUserDefaults", "NSPrivacyAccessedAPICategoryFileTimestamp"])
    }
}
```

- [ ] **Step 2: Run it — expect FAIL** (`XCTUnwrap` on the missing resource): `caffeinate -disu ./macos/build.sh test 2>&1 | grep -A3 BundleComplianceTests`

- [ ] **Step 3: Create the manifest**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>NSPrivacyTracking</key><false/>
  <key>NSPrivacyTrackingDomains</key><array/>
  <key>NSPrivacyCollectedDataTypes</key>
  <array>
    <dict>
      <key>NSPrivacyCollectedDataType</key><string>NSPrivacyCollectedDataTypeEmailAddress</string>
      <key>NSPrivacyCollectedDataTypeLinked</key><true/>
      <key>NSPrivacyCollectedDataTypeTracking</key><false/>
      <key>NSPrivacyCollectedDataTypePurposes</key><array><string>NSPrivacyCollectedDataTypePurposeAppFunctionality</string></array>
    </dict>
    <dict>
      <key>NSPrivacyCollectedDataType</key><string>NSPrivacyCollectedDataTypeName</string>
      <key>NSPrivacyCollectedDataTypeLinked</key><true/>
      <key>NSPrivacyCollectedDataTypeTracking</key><false/>
      <key>NSPrivacyCollectedDataTypePurposes</key><array><string>NSPrivacyCollectedDataTypePurposeAppFunctionality</string></array>
    </dict>
  </array>
  <key>NSPrivacyAccessedAPITypes</key>
  <array>
    <dict>
      <key>NSPrivacyAccessedAPIType</key><string>NSPrivacyAccessedAPICategoryUserDefaults</string>
      <key>NSPrivacyAccessedAPITypeReasons</key><array><string>CA92.1</string></array>
    </dict>
    <dict>
      <key>NSPrivacyAccessedAPIType</key><string>NSPrivacyAccessedAPICategoryFileTimestamp</string>
      <key>NSPrivacyAccessedAPITypeReasons</key><array><string>C617.1</string></array>
    </dict>
  </array>
</dict>
</plist>
```

- [ ] **Step 4:** Add it to the pbxproj as a resource of the `OmniAgent` target (file reference next to `Info.plist`; build file in the app's `PBXResourcesBuildPhase` — the same phase that carries `monaco in Resources`, line ~647). `plutil -lint macos/OmniAgent/PrivacyInfo.xcprivacy`.
- [ ] **Step 5:** Run the test — expect PASS. Also `./macos/build.sh build && ls macos/.build/Build/Products/Debug/OmniAgent.app/Contents/Resources/PrivacyInfo.xcprivacy`.
- [ ] **Step 6:** Commit `feat(macos): bundle the privacy manifest`. Push.

### Task A2: Info.plist keys

**Files:**
- Modify: `macos/OmniAgent/Info.plist` (the on-disk partial merges into the generated plist — one edit covers Debug/Release/Preview; do **not** triplicate `INFOPLIST_KEY_*` in the pbxproj)
- Test: `macos/OmniAgentTests/BundleComplianceTests.swift`

- [ ] **Step 1: Failing test** (append to `BundleComplianceTests`):

```swift
    func testTheInfoPlistCarriesTheStoreFacingKeys() {
        let info = Bundle.main.infoDictionary ?? [:]
        XCTAssertEqual(info["LSApplicationCategoryType"] as? String, "public.app-category.developer-tools")
        XCTAssertEqual(info["ITSAppUsesNonExemptEncryption"] as? Bool, false)
        XCTAssertEqual(info["NSHumanReadableCopyright"] as? String, "© 2026 Bruno Bonando. All rights reserved.")
        for key in ["NSDocumentsFolderUsageDescription", "NSDesktopFolderUsageDescription", "NSDownloadsFolderUsageDescription"] {
            XCTAssertFalse((info[key] as? String ?? "").isEmpty, key)
        }
    }
```

- [ ] **Step 2:** Run — expect FAIL on `ITSAppUsesNonExemptEncryption` / copyright / Downloads.
- [ ] **Step 3:** Add to `macos/OmniAgent/Info.plist` inside the top-level `<dict>`:

```xml
  <key>ITSAppUsesNonExemptEncryption</key><false/>
  <key>NSHumanReadableCopyright</key><string>© 2026 Bruno Bonando. All rights reserved.</string>
  <key>NSDownloadsFolderUsageDescription</key><string>OmniAgent saves files you download in a browser pane to your Downloads folder.</string>
```

(`ITSAppUsesNonExemptEncryption=false` is correct: the app only uses HTTPS/OS crypto, the exempt category. It is inert for Developer ID builds.)

- [ ] **Step 4:** Run — expect PASS. Commit `chore(macos): store-facing Info.plist keys`. Push.

### Task A3: Web Inspector off by default in Release

**Files:**
- Create: `macos/OmniAgent/WebInspectorPolicy.swift`
- Modify: `macos/OmniAgent/BrowserPaneView.swift:45`, `macos/OmniAgent/EditorWebView.swift:63`, `macos/OmniAgent/ReviewPanelBrowserView.swift:326`
- Test: `macos/OmniAgentTests/WebInspectorPolicyTests.swift`

**Interfaces:** Produces `enum WebInspectorPolicy { static func isEnabled(defaults: UserDefaults = .standard, debugBuild: Bool = WebInspectorPolicy.isDebugBuild) -> Bool; static let defaultsKey = "OMNIAGENT_WEB_INSPECTOR" }`.

- [ ] **Step 1: Failing test**

```swift
import XCTest
@testable import OmniAgent

final class WebInspectorPolicyTests: XCTestCase {
    private func defaults(_ value: Bool?) -> UserDefaults {
        let d = UserDefaults(suiteName: "WebInspectorPolicyTests.\(UUID())")!
        if let value { d.set(value, forKey: WebInspectorPolicy.defaultsKey) }
        return d
    }
    func testDebugBuildsAlwaysInspect() {
        XCTAssertTrue(WebInspectorPolicy.isEnabled(defaults: defaults(nil), debugBuild: true))
        XCTAssertTrue(WebInspectorPolicy.isEnabled(defaults: defaults(false), debugBuild: true))
    }
    func testReleaseBuildsInspectOnlyWhenTheDefaultOptsIn() {
        XCTAssertFalse(WebInspectorPolicy.isEnabled(defaults: defaults(nil), debugBuild: false))
        XCTAssertTrue(WebInspectorPolicy.isEnabled(defaults: defaults(true), debugBuild: false))
    }
}
```

- [ ] **Step 2:** Run — expect compile failure (`WebInspectorPolicy` undefined).
- [ ] **Step 3: Implement**

```swift
// macos/OmniAgent/WebInspectorPolicy.swift
import Foundation

/// Whether the app's WKWebViews (browser pane, editor pane, review-panel
/// browser) expose Safari's Web Inspector. Always in Debug; in Release only
/// when a developer opts in with
/// `defaults write digital.bruno.omniagent OMNIAGENT_WEB_INSPECTOR -bool YES`
/// — a shipped app should not carry a debug surface by default
/// (docs/appstore-rejection-risks.html, "Release WebViews are inspectable").
enum WebInspectorPolicy {
    static let defaultsKey = "OMNIAGENT_WEB_INSPECTOR"

    static var isDebugBuild: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    static func isEnabled(defaults: UserDefaults = .standard, debugBuild: Bool = isDebugBuild) -> Bool {
        debugBuild || defaults.bool(forKey: defaultsKey)
    }
}
```

Then at each of the three sites replace `= true` with `= WebInspectorPolicy.isEnabled()`:
- `BrowserPaneView.swift:45` → `if #available(macOS 13.3, *) { webView.isInspectable = WebInspectorPolicy.isEnabled() }`
- `EditorWebView.swift:63` → `webView.isInspectable = WebInspectorPolicy.isEnabled()`
- `ReviewPanelBrowserView.swift:326` → `if #available(macOS 13.3, *) { web.isInspectable = WebInspectorPolicy.isEnabled() }`

- [ ] **Step 4:** Run — expect PASS. `grep -n "isInspectable = true" macos/OmniAgent/` must return nothing.
- [ ] **Step 5:** Commit `fix(macos): Web Inspector is opt-in in Release builds`. Push.

### Task A4: Daemon binary locator — no `$PATH`/env-var binaries in Release

**Files:**
- Modify: `macos/OmniAgent/DaemonServiceRegistrar.swift:106-126` (`DaemonBinaryLocator.candidates`)
- Test: `macos/OmniAgentTests/DaemonPersistenceTests.swift:198-220`

**Why this is not a behaviour change:** in every non-Debug configuration the embed phase (`project.pbxproj:193`) hard-fails if the daemon is missing, so `Contents/MacOS/omniagent-pty-daemon` always exists and wins (candidate #2). The `$PATH`/env fallbacks are only ever *reached* in Debug builds, which skip the embed. Gating them on `debugBuild` removes an attack surface a reviewer would flag ("exec whatever `omniagent-pty-daemon` is on PATH") while keeping the dev workflow.

- [ ] **Step 1: Failing test** (add to `DaemonPersistenceTests`):

```swift
    func testReleaseBuildsOnlyLaunchTheBundledDaemon() {
        let candidates = DaemonBinaryLocator.candidates(
            bundleURL: URL(fileURLWithPath: "/Applications/OmniAgent.app"),
            environment: ["OMNIAGENT_PTY_DAEMON_BIN": "/custom/daemon", "PATH": "/usr/bin:/usr/local/bin"],
            debugBuild: false
        )
        XCTAssertEqual(candidates, [
            "/Applications/OmniAgent.app/Contents/MacOS/omniagent-pty-daemon",
            "/Applications/OmniAgent.app/Contents/Resources/omniagent-pty-daemon",
        ])
    }
```

(Read the existing `candidates(...)` signature at `DaemonServiceRegistrar.swift:106` first and mirror its parameter labels; the existing tests at `:198` and `:212` pass `environment:` and must keep passing — give `debugBuild` a default of `WebInspectorPolicy.isDebugBuild`… no: keep it independent — add `static var isDebugBuild` to `DaemonBinaryLocator` with the same `#if DEBUG` body, and default the parameter to it.)

- [ ] **Step 2:** Run — expect compile failure (no `debugBuild:` label).
- [ ] **Step 3:** Implement: add the `debugBuild: Bool = isDebugBuild` parameter; wrap the env-override branch (`:111-113`) and the `$PATH` loop (`:120-125`) in `if debugBuild { … }`. Update the two existing tests to pass `debugBuild: true` so they keep asserting the Debug behaviour.
- [ ] **Step 4:** Run — expect PASS. Commit `fix(macos): Release builds only launch the bundled PTY daemon`. Push.

### Task A5: `dist.sh preflight` — the store-readiness gate

**Files:**
- Modify: `macos/dist.sh` (new `preflight` subcommand; add to the `case` at lines 31 and 291, usage text, and a `preflight()` function after `verify()`)
- Modify: `CLAUDE.md` § "Native macOS app" (one bullet describing `preflight`), then `./scripts/sync-instructions.sh CLAUDE.md`

**What it checks (against a built, signed `.app`) — Developer-ID checks fail the run, MAS checks are informational unless `--mas` is passed:**

- [ ] **Step 1:** Add `preflight` to both `case` lists and usage. Then:

```sh
# --- preflight: what App Review / notarisation looks at before anything runs ---
# Developer-ID facts fail the run. The "MAS gate" section only reports (the
# sandbox is absent by decision — docs/appstore-rejection-risks.html) unless
# `--mas` is given, which turns those lines into failures too.
preflight() {
  want_mas=0; [ "${3:-}" = "--mas" ] && want_mas=1
  status=0
  fail() { echo "$0 preflight: FAIL $*" >&2; status=1; }
  mas()  { if [ "$want_mas" = 1 ]; then fail "[MAS] $*"; else echo "$0 preflight: MAS-GATE $*" >&2; fi; }
  info="$app/Contents/Info.plist"

  echo "$0 preflight: signatures ------------------------------------------" >&2
  app_team=$(codesign -dv "$app" 2>&1 | sed -n 's/^TeamIdentifier=//p')
  daemon_team=$(codesign -dv "$daemon" 2>&1 | sed -n 's/^TeamIdentifier=//p')
  [ -n "$app_team" ] || fail "app is not signed with a Team ID"
  [ "$app_team" = "$daemon_team" ] || fail "daemon Team ID ($daemon_team) != app Team ID ($app_team)"
  codesign -dv "$daemon" 2>&1 | grep -q 'flags=.*runtime' || fail "daemon lacks hardened runtime"

  echo "$0 preflight: entitlements ----------------------------------------" >&2
  ents=$(codesign -d --entitlements :- "$app" 2>/dev/null || true)
  echo "$ents" | grep -q 'get-task-allow' && fail "com.apple.security.get-task-allow present (debug entitlement)"
  echo "$ents" | grep -q 'com.apple.security.app-sandbox' || mas "App Sandbox entitlement absent"

  echo "$0 preflight: bundle metadata -------------------------------------" >&2
  [ -f "$app/Contents/Resources/PrivacyInfo.xcprivacy" ] || fail "PrivacyInfo.xcprivacy missing"
  for key in LSApplicationCategoryType NSHumanReadableCopyright ITSAppUsesNonExemptEncryption \
             NSDocumentsFolderUsageDescription NSDesktopFolderUsageDescription NSDownloadsFolderUsageDescription; do
    /usr/libexec/PlistBuddy -c "Print :$key" "$info" >/dev/null 2>&1 || fail "Info.plist lacks $key"
  done
  plist=$(find "$app/Contents/Library/LaunchAgents" -name '*.plist' | head -1)
  [ -n "$plist" ] || fail "no LaunchAgent plist"
  [ -n "$plist" ] && { /usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$plist" | grep -q '^Contents/MacOS/' \
    || fail "LaunchAgent Program is not bundle-relative"; }
  [ -f "$app/Contents/Resources/Legal/privacy-policy.html" ] || fail "bundled privacy policy missing (Task B1)"
  [ -f "$app/Contents/Resources/Legal/third-party-notices.html" ] || fail "bundled third-party notices missing (Task B1)"

  echo "$0 preflight: MAS gate (informational unless --mas) -----------------" >&2
  mas "socket path ~/.omniagent-ade is outside any sandbox container (D1)"
  mas "no Mac App Store build configuration / archive lane (D1)"

  [ "$status" = 0 ] && echo "$0 preflight: OK" >&2
  return $status
}
```

- [ ] **Step 2:** Wire `preflight) preflight ;;` into the dispatch `case` at line ~291 (the existing `*) "$action" "$app" ;;` style — match whatever the file does for `sign`/`verify`).
- [ ] **Step 3:** Run against the installed app: `./macos/dist.sh preflight /Applications/OmniAgent.app`. Expected: FAIL lines for the manifest/plist keys/legal pages **until A1, A2, B1 are installed**, MAS-GATE lines always, exit ≠ 0. After a rebuild with A1/A2/B1: `preflight: OK`, exit 0; with `--mas`: exit ≠ 0 with three `[MAS]` lines.
- [ ] **Step 4:** Add the CLAUDE.md bullet, run `./scripts/sync-instructions.sh CLAUDE.md`. Commit `feat(dist): preflight subcommand for store-facing bundle checks`. Push.

---

## Tier B — Medium, additive only

### Task B1: Help menu → Privacy Policy & Third-Party Notices (+ disclaimer, + licences)

**Files:**
- Create: `macos/OmniAgent/Resources/Legal/privacy-policy.html`, `macos/OmniAgent/Resources/Legal/third-party-notices.html`
- Modify: `macos/OmniAgent.xcodeproj/project.pbxproj` — add `Resources/Legal` as a **folder reference** in the app's Resources phase (exactly the `monaco` pattern: `lastKnownFileType = folder; path = Resources/Legal`)
- Modify: `macos/OmniAgent/AppDelegate.swift` (`ApplicationMenus.install`, after the Window menu, ~line 355): a Help menu
- Modify: `macos/OmniAgent/CommandPalette.swift` (`PaletteAction` + two rows in `CommandPaletteModel.build`), `macos/OmniAgent/WorkspaceWindowController.swift` (`run(_:)` at 2911 + two `@objc` responder methods)
- Test: `macos/OmniAgentTests/CommandPaletteTests.swift`, `macos/OmniAgentTests/BundleComplianceTests.swift`

**Interfaces:** Produces `enum LegalDocument: String, CaseIterable { case privacyPolicy = "privacy-policy", thirdPartyNotices = "third-party-notices"; var title: String; var url: URL? }` and `PaletteAction.openLegal(LegalDocument)`.

**Lazy choice (ponytail):** the pages open in the user's default browser via `NSWorkspace.shared.open(fileURL)` — one line, no in-app viewer, no new pane. Upgrade path if wanted later: open in a browser pane via `newBrowserPane` with the file URL.

- [ ] **Step 1: Failing tests**

```swift
// CommandPaletteTests
    func testTheLegalPagesAreSpotlightRows() {
        let commands = CommandPaletteModel.build(panes: [], paneOrder: [], focusedPaneID: nil)
        let rows = commands.filter { if case .openLegal = $0.action { return true } else { return false } }
        XCTAssertEqual(rows.map(\.title), ["Privacy Policy", "Third-Party Notices"])
        XCTAssertTrue(rows.allSatisfy { $0.subtitle == "Help" && $0.keywords.contains("legal") })
        XCTAssertEqual(rows.first?.action, .openLegal(.privacyPolicy))
    }
// BundleComplianceTests
    func testBothLegalPagesAreBundled() {
        for doc in LegalDocument.allCases { XCTAssertNotNil(doc.url, doc.rawValue) }
    }
```

- [ ] **Step 2:** Run — expect compile failure.
- [ ] **Step 3: Write the two HTML pages.** Plain HTML, inline CSS, `<title>`. Content requirements (author fully — no placeholders):
  - **privacy-policy.html** — sections: *What stays on this Mac* (project files, brain index `brain.db`, Markdown memory, transcripts, usage analytics — all under `~/Library/Application Support/OmniAgent-ADE`, never transmitted; secret redaction runs before transcripts/memory are written, and its limits: API-key/token/password/Bearer/AWS/`sk-` shapes only); *What the OmniAgent account sends* (email, name, avatar URL to `api.omni-agent.ai` on sign-in; a refresh cookie stored by the system cookie jar; GitHub login handle if linked; nothing else — no code, no transcripts); *Third-party tools you run* (Claude Code, Codex, Copilot, AntiGravity are CLIs you install; when you start one, it talks to its own provider under that provider's terms — OmniAgent only launches it); *Browser panes* (load the URLs you type; downloads land in ~/Downloads); *Your choices* (Continue without signing in; Log out; Delete account — Settings › Accounts; Rebuild/delete the brain; Login Items in System Settings); *Contact* (bruno@bonando.com). Date it 2026-08-30.
  - **third-party-notices.html** — (1) **Trademark disclaimer:** "Claude and Claude Code are trademarks of Anthropic, PBC. Codex and OpenAI are trademarks of OpenAI. GitHub and Copilot are trademarks of GitHub, Inc. AntiGravity and Google are trademarks of Google LLC. OmniAgent is not affiliated with, endorsed by, or sponsored by any of them; names and marks are used only to identify the tools you choose to run." (2) **Licences**, each with full MIT text once and a per-project attribution line: SwiftTerm (Miguel de Icaza, MIT), Monaco Editor (Microsoft, MIT — copy the text from `Resources/monaco/LICENSE-monaco.txt`), lobe-icons (LobeHub, MIT — the engine SVGs in `Assets.xcassets/Engine*.imageset`).
- [ ] **Step 4: Implement**

```swift
// in CommandPalette.swift, near PaletteAction
/// The two pages under Help, bundled under Resources/Legal and opened in the
/// default browser — a reviewer's first question and a licence obligation
/// (lobe-icons, SwiftTerm, Monaco are MIT: attribution is not optional).
enum LegalDocument: String, CaseIterable {
    case privacyPolicy = "privacy-policy"
    case thirdPartyNotices = "third-party-notices"
    var title: String { self == .privacyPolicy ? "Privacy Policy" : "Third-Party Notices" }
    var url: URL? { Bundle.main.url(forResource: rawValue, withExtension: "html", subdirectory: "Legal") }
}
// PaletteAction: add
    case openLegal(LegalDocument)
// CommandPaletteModel.build: after the Settings rows
        for doc in LegalDocument.allCases {
            commands.append(PaletteCommand(
                id: "help:\(doc.rawValue)", title: doc.title, detail: nil,
                action: .openLegal(doc), keywords: "help legal privacy licence license trademark",
                section: .places, subtitle: "Help", symbol: doc == .privacyPolicy ? "hand.raised" : "doc.text"))
        }
```

```swift
// WorkspaceWindowController.run(_:)
        case let .openLegal(doc):
            if let url = doc.url { NSWorkspace.shared.open(url) }
// responder-chain targets for the menu (same file, near showSettings:)
    @objc func showPrivacyPolicy(_ sender: Any?) { run(.openLegal(.privacyPolicy)) }
    @objc func showThirdPartyNotices(_ sender: Any?) { run(.openLegal(.thirdPartyNotices)) }
```

```swift
// AppDelegate.swift ApplicationMenus.install, after `NSApp.windowsMenu = window`
        let help = NSMenu(title: "Help")
        main.addItem(withSubmenu: help)
        help.addItem(item("Privacy Policy", Selector(("showPrivacyPolicy:"))))
        help.addItem(item("Third-Party Notices", Selector(("showThirdPartyNotices:"))))
        NSApp.helpMenu = help
```

- [ ] **Step 5:** Run tests — expect PASS. Launch the Debug app (`./macos/build.sh build` then `open` the product) and confirm Help › Privacy Policy opens the page in the browser; ⌘K "privacy" shows the row.
- [ ] **Step 6:** Commit `feat(macos): Help menu with bundled privacy policy and third-party notices`. Push.

**External dependency (not this repo):** App Store Connect needs a *hosted* privacy-policy URL and the SaaS Signup already links `/privacy` + `/terms` that 404. Publish the same text at `https://www.omni-agent.ai/privacy` (OmniAgent-Website) — file as a follow-up in My-Brain, do not block on it.

### Task B2: App Review notes + correct the report

**Files:**
- Create: `docs/appstore/review-notes.md`
- Modify: `docs/appstore-rejection-risks.html` (`risks` array only)

- [ ] **Step 1:** Write `docs/appstore/review-notes.md` — the text to paste into App Store Connect's "Notes for Review": what the app is (a terminal workspace for AI coding CLIs the user installs themselves); that no CLI is bundled or installed by the app; the daemon (what it is, `SMAppService.agent`, user control in System Settings › Login Items, socket `0600` + peer-UID check); network hosts (`api.omni-agent.ai`, `appleid.apple.com`, user-typed URLs); sign-in options (Apple web flow, GitHub) and "Continue without signing in" as the reviewer path; a test account placeholder line marked `TODO(Bruno): create reviewer account` — the only acceptable TODO, it is a credential Bruno must mint.
- [ ] **Step 2:** Edit the `risks` array in the HTML: replace Tauri evidence with native paths from the re-scored table; set installer risk to `severity: "low"` with summary "Native app has no installer code (Tauri-only, gated by cutover.sh)"; helper-packaging to `"low"` with the `Contents/MacOS` fact; add `ReviewPanelBrowserView.swift:326` to the inspectable evidence; add a `status` string per risk (`"fixed: Task A3"`, `"decision D1"`, …) and render it as a fourth `.detail` card. Recompute nothing else — the counters derive from the array.
- [ ] **Step 3:** Open the HTML in a browser, confirm the counters and the new card render. Commit `docs: App Review notes; re-score rejection risks against the native app`. Push.

---

## Tier C — Complex, additive feature (Apple-mandated)

### Task C1: Account deletion

**Files (Core — `/Users/bonando/Documents/Bruno.Digital/OmniAgent-Core`):**
- Modify: `omniagent/api/routers/auth.py` (new route next to `update_me`, ~line 2085)
- Test: `tests/test_auth.py`

**Files (ADE):**
- Modify: `macos/OmniAgent/AuthClient.swift` (after `disconnectGitHub`, ~line 361), `macos/OmniAgent/CommandPalette.swift` (`PaletteAction.deleteAccount` + row), `macos/OmniAgent/SettingsSurfaceView.swift` (third button + `onDeleteAccount`), `macos/OmniAgent/WorkspaceWindowController.swift` (`deleteAccount()` beside `logOutOfAccount()` at 4419; wire `settingsView.onDeleteAccount` beside line 915; `run(_:)`)
- Test: `macos/OmniAgentTests/CommandPaletteTests.swift`, `macos/OmniAgentTests/SettingsSurfaceViewTests.swift` (or wherever `applyAccount` is tested — `grep -ln applyAccount macos/OmniAgentTests`)

**Interfaces:** Core: `DELETE /v1/auth/me` → 204, bearer-authorized, hard-deletes the `users` row (FKs already `CASCADE` for `refresh_tokens`, `SET NULL` elsewhere — see `omniagent/db/models.py` FK list). ADE: `AuthClient.deleteAccount() async throws` → `authorized(path: "v1/auth/me", method: "DELETE", body: nil)`.

- [ ] **Step 1 (Core): failing test** in `tests/test_auth.py`, mirroring `test_get_me` (`client`, `user` fixtures):

```python
async def test_delete_me_removes_the_user_and_their_sessions(client: AsyncClient, user: User, db: AsyncSession):
    headers = await _auth_headers(client, user)   # reuse whatever helper test_get_me uses
    resp = await client.delete("/v1/auth/me", headers=headers)
    assert resp.status_code == 204
    assert (await client.get("/v1/auth/me", headers=headers)).status_code == 401
    assert await db.get(User, user.id) is None
```

- [ ] **Step 2:** `pytest tests/test_auth.py -k delete_me` — expect 405/404.
- [ ] **Step 3 (Core): implement**

```python
@router.delete("/me", status_code=204)
async def delete_me(
    user: Annotated[User, Depends(get_current_user)],
    db: Annotated[AsyncSession, Depends(get_db)],
    response: Response,
) -> None:
    """Delete the signed-in account (App Store Guideline 5.1.1(v)).

    Hard delete: refresh tokens cascade, everything else the user owned is
    detached (`ondelete="SET NULL"`) rather than destroyed — a deleted
    person's company data is the company's, not theirs.
    """
    _clear_github(user)
    await db.delete(user)
    await db.commit()
    response.delete_cookie("refresh_token")   # match the cookie name/path logout() uses
```

Check `logout()` at `auth.py:~1800` for the exact cookie name/path/domain and reuse its `delete_cookie` call verbatim.

- [ ] **Step 4:** pytest — expect PASS. Commit in Core `feat(auth): DELETE /v1/auth/me — account deletion`. Push. **Deploy to prod** (memory: core-deploy-from-this-mac — `KUBECONFIG=~/.kube/k3s-lens.yaml`, back up secrets before any secret patch). Verify: `curl -X DELETE https://api.omni-agent.ai/v1/auth/me` → 401 (route exists, needs auth).
- [ ] **Step 5 (ADE): failing tests**

```swift
// CommandPaletteTests — next to the logout-row test
    func testDeleteAccountIsARowOnlyWhileSignedIn() {
        let on = CommandPaletteModel.build(panes: [], paneOrder: [], focusedPaneID: nil, signedIn: true)
        let off = CommandPaletteModel.build(panes: [], paneOrder: [], focusedPaneID: nil, signedIn: false)
        XCTAssertTrue(on.contains { $0.action == .deleteAccount && $0.subtitle == "Settings › Accounts" })
        XCTAssertFalse(off.contains { $0.action == .deleteAccount })
    }
// SettingsSurfaceView tests
    func testDeleteAccountButtonShowsOnlyWhileSignedInOnAccounts() {
        let view = SettingsSurfaceView(); view.show(.accounts)   // use the real section-show API name
        view.applyAccount(email: "a@b.c", signedIn: true)
        XCTAssertFalse(view.deleteAccountButton.isHidden)
        view.applyAccount(email: nil, signedIn: false)
        XCTAssertTrue(view.deleteAccountButton.isHidden)
    }
```

(`build(...)` already takes `signedIn:` — the logout row depends on it; confirm the label at `CommandPaletteModel.build`'s signature.)

- [ ] **Step 6:** Run — expect compile failures.
- [ ] **Step 7 (ADE): implement**

```swift
// AuthClient.swift
    /// `DELETE /v1/auth/me` — deletes the signed-in account server-side.
    /// Bearer-authorized, 204. The caller then does exactly what logout does
    /// locally; Core has already dropped the refresh token.
    func deleteAccount() async throws {
        try await authorized(path: "v1/auth/me", method: "DELETE", body: nil)
        accessToken = nil
    }
```

```swift
// CommandPalette.swift — PaletteAction
    /// Settings › Accounts' destructive third button. A row only while
    /// signed in: deleting nothing is a dead end, not an offer.
    case deleteAccount
// CommandPaletteModel.build — after the logout/signin pair
        if signedIn {
            commands.append(PaletteCommand(
                id: "settings:accounts:delete", title: "Delete account…", detail: nil,
                action: .deleteAccount, keywords: accountKeywords + " delete remove erase",
                section: .places, subtitle: "Settings › Accounts", symbol: "person.crop.circle.badge.minus"))
        }
```

```swift
// SettingsSurfaceView.swift — beside githubButton
    let deleteAccountButton = NSButton(title: "Delete account…", target: nil, action: nil)
    var onDeleteAccount: (() -> Void)?
    // in init: same bezel/font/target setup as accountButton; action #selector(deleteAccountPressed);
    // append after githubButton in the column; in the section switch hide with `!isAccounts`.
    // in applyAccount: deleteAccountButton.isHidden = !(section == .accounts && signedIn)
    @objc private func deleteAccountPressed() { onDeleteAccount?() }
```

```swift
// WorkspaceWindowController.swift — beside logOutOfAccount()
    /// "Delete account…": one critical ask, then Core's DELETE, then the
    /// same local teardown as logging out.
    func deleteAccount() {
        guard !accountActionInFlight else { return }
        presentWindowAsk(
            title: "Delete your OmniAgent account?",
            message: "This removes your account and its sign-in sessions from omni-agent.ai. Nothing on this Mac — projects, brain, transcripts — is touched.",
            severity: .critical,
            options: [
                PaneAskOption("Cancel", isPrimary: false) { _ in },
                PaneAskOption("Delete account", isPrimary: true) { [weak self] _ in self?.performAccountDeletion() },
            ]
        )
    }

    private func performAccountDeletion() {
        accountActionInFlight = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await AuthClient.shared.deleteAccount()
                authGateCoordinator.reset { [weak self] in
                    guard let self else { return }
                    seedAccountFromMirror(); refreshAccountSection()
                    accountActionInFlight = false
                    presentAccountGate()
                }
            } catch {
                accountActionInFlight = false
                presentWindowAsk(title: "Could not delete the account", message: error.localizedDescription,
                                 severity: .critical, options: [PaneAskOption("OK", isPrimary: true) { _ in }])
            }
        }
    }
// run(_:): case .deleteAccount: deleteAccount()
// wiring near line 915: settingsView.onDeleteAccount = { [weak self] in self?.deleteAccount() }
```

(Check `PaneAskOption`'s initializer signature in `PaneAsk.swift` and match it; the pattern above mirrors `presentWindowAsk`'s own `options.map`.)

- [ ] **Step 8:** Run the suite — expect PASS. Manual: sign in with a throwaway account on the installed app, Settings › Accounts › Delete account… → critical red card → confirm → sign-in gate appears; `curl` `/v1/auth/refresh` with the old cookie → 401.
- [ ] **Step 9:** Commit `feat(macos): delete account from Settings › Accounts`. Push. Rebuild + install: `scripts/rebuild-app.sh` (restarts the daemon — memory: restart-daemon-with-app). Verify relaunch with `pgrep -x OmniAgent`.

---

## Decisions (behaviour changes — out of scope, need Bruno's call)

| ID | Decision | What it would take | Rough size |
|---|---|---|---|
| **D1** | **Is Mac App Store a target at all?** Sandbox = the app's terminals cannot spawn the user's shell with their environment, cannot reach `~/.omniagent-ade`, and the daemon inherits the container. Realistic MAS options: (a) a **MAS edition without terminal/daemon** (brain, editor, browser, chat only) as a second target + App Group socket; (b) stay Developer ID forever and treat this report as hardening only. | (a) new target, entitlements, socket relocation, feature flags, MAS archive lane, native Sign in with Apple (entitlement reversal noted in `OmniAgent.entitlements`), separate QA. (b) nothing — Tiers A–C are the whole job. | (a) 3–5 weeks · (b) 0 |
| D2 | Downloads through a save panel; `file://` scoped to workspace roots | `BrowserPaneView.swift:161-179, 220-231` | 1 day |
| D3 | First-run consent sheet before launching a third-party CLI | new onboarding step + persisted flag | 1 day |
| D4 | Replace provider logos with neutral glyphs | 4 assets + `EngineIcon.swift` | 0.5 day |

Recommendation: decide D1 first; if (b), D2–D4 are optional polish and everything above ships as hardening of the Developer ID build.

---

## Verification (end-to-end)

1. `caffeinate -disu ./macos/build.sh test` — all green, including `BundleComplianceTests`, `WebInspectorPolicyTests`, the new `DaemonPersistenceTests`/`CommandPaletteTests` cases.
2. `scripts/rebuild-app.sh` (universal, sign, notarize, DMG, install) → `./macos/dist.sh verify /Applications/OmniAgent.app` (existing gate) → `./macos/dist.sh preflight /Applications/OmniAgent.app` → `preflight: OK`, exit 0; `--mas` → exit 1 with three `[MAS]` lines.
3. `codesign -d --entitlements :- /Applications/OmniAgent.app` still prints an empty dict (nothing changed in the Developer ID entitlements).
4. Installed app: terminals, browser, editor, Desk, sign-in all behave as before (no behaviour change). Safari › Develop shows **no** OmniAgent web views until `defaults write digital.bruno.omniagent OMNIAGENT_WEB_INSPECTOR -bool YES` + relaunch.
5. Help menu present with both pages; ⌘K "privacy" / "notices" / "delete account" find their rows.
6. Core: `pytest tests/test_auth.py` green; prod route answers 401 unauthenticated.
7. `docs/appstore-rejection-risks.html` opens with the corrected counters and per-risk status cards.

## Self-review

- Spec coverage: every one of the 13 risks maps to a task (A1–C1) or a decision (D1–D4) in the re-scored table.
- No placeholders except the reviewer-account credential in B2, which only Bruno can mint.
- Names used consistently: `WebInspectorPolicy.isEnabled(defaults:debugBuild:)`, `DaemonBinaryLocator.candidates(..., debugBuild:)`, `LegalDocument`, `PaletteAction.openLegal` / `.deleteAccount`, `AuthClient.deleteAccount()`, `SettingsSurfaceView.deleteAccountButton` / `onDeleteAccount`, `dist.sh preflight [--mas]`.
