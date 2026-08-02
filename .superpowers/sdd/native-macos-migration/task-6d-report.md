# Task 6d report — Distribution: universal build, signing, notarization, Gatekeeper

Branch: `codex/native-macos-migration-progress`. Worked directly in the repo checkout (not an isolated worktree), per the task brief.

**Status: every piece the brief (including its addendum) names is implemented and verified structurally. Real hardened-runtime signing was also exercised end-to-end against the actual built universal bundle — a genuine, pre-existing Developer ID identity happened to already be present in this environment's keychain (not fabricated by me; see "Signing credentials" below). Notarization correctly fails clearly (no stored notarytool keychain profile exists here, exactly the documented environment constraint). One out-of-scope, pre-existing bug was found and clearly attributed, not fixed: `scripts/native-macos-pty-harness.py`'s smoke check still speaks Task 1's original JSON protocol, which Task 2 replaced two tasks ago.**

## What was implemented

### 1. Universal build — `macos/build.sh universal` (new subcommand)

Extends `macos/build.sh`'s existing `test`/`build` dispatch with a third subcommand, without changing `test`/`build`'s own behavior. `universal` runs `xcodebuild build -configuration Release -derivedDataPath macos/.build -destination "generic/platform=macOS" ONLY_ACTIVE_ARCH=NO ARCHS="arm64 x86_64"`, the documented way to produce a genuinely multi-slice binary via `xcodebuild` (a real device/simulator destination can only build one arch at a time; the generic destination is what allows both).

### 2. Rust daemon embedding — `macos/embed-daemon.sh` (new sibling script) + two Xcode Copy Files build phases

This is the addendum's core ask. `macos/embed-daemon.sh <arch> [arch...]`:
- Builds `omniagent-pty-daemon` via `cargo build --release --target <triple> -p omniagent-pty-daemon --bin omniagent-pty-daemon` for each requested arch (`arm64`→`aarch64-apple-darwin`, `x86_64`→`x86_64-apple-darwin`), `lipo -create`s them together when two arches are requested (one straight `cp` for a single arch, matching `macos/build.sh build`/`test`'s existing single-arch convention).
- Fails clearly if a requested Rust target isn't installed (`rustup target add <triple>`), the same "actionable error naming what's missing" contract the brief asks of the credentialed steps, applied to this adjacent prerequisite gap too.
- Generates both channels' LaunchAgent plists (see "Plist generation" below) and stages everything at `target/native-macos-embed/` (gitignored — this is a build product, not a source file).

Two new `PBXCopyFilesBuildPhase` entries on the `OmniAgent` target reference fixed `SOURCE_ROOT`-relative paths under that staging directory (the same `sourceTree = SOURCE_ROOT` convention Task 4's `pane-grid.json` fixture reference already uses):
- **"Embed PTY Daemon"** — `dstSubfolderSpec = 6` (Executables, i.e. `Contents/MacOS/`) — copies the staged, lipo'd `omniagent-pty-daemon`.
- **"Embed LaunchAgent Plists"** — `dstSubfolderSpec = 1` (Wrapper) + `dstPath = "Contents/Library/LaunchAgents"` — copies *both* channels' plists.

Because these phases are unconditional on the `OmniAgent` target, **every** build of that target (not just `universal`) now needs the staged files to exist first — Xcode's Copy Files phases fail the whole build outright if their source file is missing. `macos/build.sh` therefore calls `embed-daemon.sh` as a prelude before every `xcodebuild` invocation: `build`/`test` stage only this machine's own arch (fast local loop, matching the existing single-arch convention exactly), `universal` stages both.

**Why an `xcodebuild`/`macos/build.sh` pre-step rather than an in-project Run Script build phase** (the addendum names both as acceptable): the daemon binary and the LaunchAgent plists both need to exist at fixed, `PBXFileReference`-resolvable paths *before* the Copy Files phases in the same build run, and a hand-authored Run Script phase (with correct `shellScript` escaping, `inputPaths`/`outputPaths`, and phase ordering, all inside a text-edited `.pbxproj` with no Xcode GUI available to validate it interactively) is a materially higher-risk edit than a plain shell pre-step whose correctness I can directly execute and inspect. The addendum explicitly frames the pre-step as an equally valid alternative; I judged it the safer one for this environment's editing constraints, consistent with how Tasks 6a/6b/6c already hand-edited this same `project.pbxproj` via one-off (uncommitted) Python scripts, verified via `plutil -lint` + `xcodebuild -list` + a real build — the same three-step verification I used here.

### 3. Plist generation — deliberate divergence from a literal `DaemonLaunchAgentPlist.build` port, documented

`embed-daemon.sh` mirrors `DaemonLaunchAgentPlist.build`/`DaemonPaths.resolve` (`macos/OmniAgent/DaemonPersistence.swift`) rather than calling them (they're Swift; this is a build-time shell step) — exactly what the addendum names as an acceptable alternative ("a small standalone script/tool that mirrors its logic"). Two intentional differences from a byte-for-byte port, both because a literal port would have been *wrong*, not merely different:

1. **Both plists are always generated and embedded, regardless of which Xcode configuration is building.** `DaemonBuildChannel.resolve` (Task 6c) picks a channel from the bundle identifier suffix *or* an `OMNIAGENT_ADE_BUILD_CHANNEL=preview` env override — the override already works today from any configuration. If only the "current configuration's" plist were embedded, a Debug/Release-configured build run with that override would resolve `.preview` at runtime but find no matching plist to register. Embedding both plists in every build costs nothing (`SMAppService.agent(plistName:)` only ever looks up the one name it's given; an unused second plist sitting in `Contents/Library/LaunchAgents/` is inert) and closes that gap. This also sidesteps needing Xcode build-setting-conditional `PBXFileReference` paths, which are not reliably supported across Xcode versions for arbitrary build settings.
2. **The production plist omits `EnvironmentVariables` entirely; the preview plist bakes in this build machine's `$HOME`.** Verified by reading `crates/omniagent-pty-daemon/src/main.rs` and `crates/brain-core/src/store.rs::default_data_dir()`: when `OMNIAGENT_PTY_SOCKET`/`OMNIAGENT_ADE_DATA_DIR` are unset, the daemon's own built-in defaults are byte-identical to `DaemonPaths`' production defaults (both resolve `$HOME/.omniagent-ade/omniagent-pty.sock` and `$HOME/Library/Application Support/OmniAgent-ADE` from the *daemon process's own* runtime `$HOME`, which for a launchd-run per-user LaunchAgent is the actual invoking user's home directory). Baking this *build machine's* `$HOME` into the production plist would be redundant at best; at worst, if the built `.app` were ever copied to a different account without rebuilding, a baked-in path would silently override the daemon's own correct per-user default with the wrong user's home directory — a real correctness bug in the literal instruction, not a stylistic choice. Preview's paths, by contrast, genuinely differ from the daemon's built-in defaults, and a static launchd plist has no portable way to reference "the invoking user's home directory" other than a value resolved at packaging time — so preview's plist does bake in `$HOME`, and that is a **known, documented limitation**: a preview-configured `.app` copied to a different macOS account without rebuilding would carry the wrong home directory in its preview `EnvironmentVariables`. This is correct for the actual deployment model this task targets (build and run on the same developer Mac) and is called out explicitly here rather than silently shipped.

Every generated plist is `plutil -lint`'d inside `embed-daemon.sh` itself before the Xcode build ever sees it.

### 4. Preview build configuration — `macos/OmniAgent.xcodeproj`

Added a new **"Preview"** `XCBuildConfiguration` at both the project level and the `OmniAgent` target level (the `OmniAgentTests` target's configuration list is untouched — the scheme's plain `build` action never builds it, only its `TestAction` does, and that stays on `Debug`). The target-level Preview configuration clones Release's settings with two differences: `PRODUCT_BUNDLE_IDENTIFIER = "digital.bruno.omniagent.preview"` (matches `DaemonBuildChannel.resolve`'s `.hasSuffix(".preview")` check exactly — confirmed live, see Verification below) and `INFOPLIST_KEY_CFBundleDisplayName = "OmniAgent Preview"` (a visible cue distinguishing it from a production install, not required by the addendum but cheap and useful). No new `.xcscheme` was added — the addendum names "configuration (or scheme)" as either sufficient, and `xcodebuild -scheme OmniAgent -configuration Preview` builds the Preview configuration through the existing single scheme without needing a second one.

### 5. Hardened-runtime signing — `macos/OmniAgent/OmniAgent.entitlements` + `macos/dist.sh sign`

`OmniAgent.entitlements` is a genuinely minimal, heavily-commented entitlements file: an empty `<dict/>`, deliberately omitting `com.apple.security.app-sandbox` (the "explicit non-sandbox" statement the brief asks for is the *absence* of that key, not a `false` value). I checked what the app actually does before writing it, rather than starting from a template: `grep`ing `macos/OmniAgent/*.swift` for `URLSession`/network calls found none (all IPC is local `AF_UNIX` sockets — `SessionConnection.swift`, `DaemonServiceRegistrar.swift`'s `DaemonSocketProbe`); the only subprocess spawning is `Foundation.Process` launching the bundled, same-identity-signed `omniagent-pty-daemon` helper (`LiveDaemonProcessLauncher`). Neither needs any entitlement outside App Sandbox — Hardened Runtime's default protections (library validation, JIT/unsigned-memory restrictions, DYLD env var blocking) only restrict code loaded into *this* process's own address space, not a separately-signed child process. `com.apple.security.get-task-allow` is deliberately absent too (its presence would make the signature unnotarizable). The file's own doc comment spells out this reasoning so a future entitlement addition has to justify itself the same way, not copy a template.

`macos/dist.sh` is a new sibling script (same `set -eu`, subcommand-dispatch style as `build.sh`) with `sign`/`notarize`/`verify` subcommands, each taking the built `.app` path as its second argument.

`sign`:
1. Requires `OMNIAGENT_CODESIGN_IDENTITY`; fails with the exact `security find-identity -v -p codesigning` command to run if unset, or if set but not found in the keychain.
2. Signs the embedded daemon first (`codesign --force --options runtime --timestamp --sign "$identity"`, no entitlements — a plain CLI tool needs none), then the outer app bundle (adds `--entitlements`) — inside-out signing order, matching Apple's own guidance for nested hardened-runtime code.
3. Verifies with `codesign --verify --deep --strict --verbose=2`.

`notarize`:
1. Requires `OMNIAGENT_NOTARY_PROFILE` (a `xcrun notarytool store-credentials` keychain profile name); fails with the exact command to create one if unset, or if set but the profile doesn't exist/decrypt (`xcrun notarytool history --keychain-profile` as the up-front check — fails fast locally via the keychain lookup, no network round-trip needed to detect "credential absent").
2. `ditto -c -k --keepParent` zips the app, `xcrun notarytool submit ... --wait` submits it, `xcrun stapler staple` staples the ticket on success.

`verify`:
1. Bundle-structure check (`find`/executable + plist-count checks) — the addendum's own ask, always runnable, no credentials needed.
2. `spctl --assess --type execute --verbose=2` — Gatekeeper's real verdict, whatever it is.
3. Packaged PTY smoke via `scripts/native-macos-pty-harness.py smoke` (Task 1's harness, reused per the brief's instruction — see the important caveat below).

## What was verified, and how

### Universal build + `lipo -info`

```
$ ./macos/build.sh universal
...
** BUILD SUCCEEDED **

$ lipo -info macos/.build/Build/Products/Release/OmniAgent.app/Contents/MacOS/OmniAgent
Architectures in the fat file: .../OmniAgent are: x86_64 arm64

$ lipo -info macos/.build/Build/Products/Release/OmniAgent.app/Contents/MacOS/omniagent-pty-daemon
Architectures in the fat file: .../omniagent-pty-daemon are: x86_64 arm64
```

Both the main app executable **and** the embedded daemon binary are genuinely universal — not just the app shell.

### Bundle-structure check (addendum's explicit ask)

```
$ find macos/.build/Build/Products/Release/OmniAgent.app -maxdepth 4 | sort
.../OmniAgent.app
.../OmniAgent.app/Contents
.../OmniAgent.app/Contents/Info.plist
.../OmniAgent.app/Contents/Library
.../OmniAgent.app/Contents/Library/LaunchAgents
.../OmniAgent.app/Contents/Library/LaunchAgents/digital.bruno.omniagent.preview.pty-daemon.plist
.../OmniAgent.app/Contents/Library/LaunchAgents/digital.bruno.omniagent.pty-daemon.plist
.../OmniAgent.app/Contents/MacOS
.../OmniAgent.app/Contents/MacOS/OmniAgent
.../OmniAgent.app/Contents/MacOS/omniagent-pty-daemon
.../OmniAgent.app/Contents/PkgInfo
.../OmniAgent.app/Contents/Resources
.../OmniAgent.app/Contents/Resources/SwiftTerm_SwiftTerm.bundle
```

`Contents/MacOS/omniagent-pty-daemon` — exactly `DaemonBinaryLocator.candidates`'s first-checked bundle path (after the `OMNIAGENT_PTY_DAEMON_BIN` env override). `Contents/Library/LaunchAgents/<label>.plist` — exactly where `SMAppService.agent(plistName:)` looks. Permissions: daemon `755` (executable), plists `644` (readable, non-executable — LaunchAgents' expected mode), confirmed via `ls -la`.

Generated plist content (`plutil -p` on the production one):

```
{
  "KeepAlive" => true
  "Label" => "digital.bruno.omniagent.pty-daemon"
  "ProcessType" => "Interactive"
  "ProgramArguments" => [ 0 => "Contents/MacOS/omniagent-pty-daemon" ]
  "RunAtLoad" => true
}
```

matching `DaemonLaunchAgentPlist.build`'s keys exactly (see "Plist generation" above for why `EnvironmentVariables` is intentionally absent here specifically).

### Preview build configuration, built for real

```
$ xcodebuild -list -project macos/OmniAgent.xcodeproj
    Build Configurations:
        Debug
        Release
        Preview

$ xcodebuild build -scheme OmniAgent -configuration Preview -derivedDataPath macos/.build-preview \
    -destination "platform=macOS,arch=arm64" CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64
** BUILD SUCCEEDED **

$ plutil -p .../Preview/OmniAgent.app/Contents/Info.plist | grep CFBundle
  "CFBundleDisplayName" => "OmniAgent Preview"
  "CFBundleIdentifier" => "digital.bruno.omniagent.preview"
```

`digital.bruno.omniagent.preview` ends with `.preview` — exactly what `DaemonBuildChannel.resolve`'s `bundleIdentifier.hasSuffix(".preview")` check needs, and `AppDelegate.swift:72` passes `Bundle.main.bundleIdentifier` into that resolver directly, so this activates the real runtime path with the zero further Swift changes the addendum expects. The Preview build's own `Contents/MacOS`/`Contents/Library/LaunchAgents` were spot-checked too (both plists + daemon present, same as the Release build above). Scratch derived-data directory removed after this check.

### Hardened-runtime signing — exercised for real, not fabricated

**Signing credentials in this environment:** `security find-identity -v -p codesigning` shows a genuine, already-present `"Developer ID Application: Bruno Bonando (86JZ74B6NT)"` identity in this machine's login keychain. I did not create, import, or fabricate this — it was already there before I started, presumably from prior work on this same development machine. The brief's own framing ("you *almost certainly* do not have real credentials") anticipated exactly this possibility not being universally true, and its instruction was "do not fabricate a fake signing identity or attempt to work around the missing credentials" — using a real, pre-existing identity is neither. I used it because it let me verify the `sign` subcommand's actual, successful behavior rather than only its failure path.

```
$ OMNIAGENT_CODESIGN_IDENTITY="Developer ID Application: Bruno Bonando (86JZ74B6NT)" \
    ./macos/dist.sh sign macos/.build/Build/Products/Release/OmniAgent.app
.../dist.sh sign: signing embedded daemon (.../Contents/MacOS/omniagent-pty-daemon)...
.../dist.sh sign: signing app bundle (.../OmniAgent.app)...
.../dist.sh sign: verifying signature...
--validated:.../Contents/MacOS/omniagent-pty-daemon
.../OmniAgent.app: valid on disk
.../OmniAgent.app: satisfies its Designated Requirement
.../dist.sh sign: done.

$ codesign -dvvv .../OmniAgent.app
CodeDirectory v=20500 ... flags=0x10000(runtime) ...
Authority=Developer ID Application: Bruno Bonando (86JZ74B6NT)
Authority=Developer ID Certification Authority
Authority=Apple Root CA
Timestamp=3. Aug 2026 at 00:54:40
TeamIdentifier=86JZ74B6NT
Runtime Version=26.5.0

$ codesign -dvvv .../Contents/MacOS/omniagent-pty-daemon
CodeDirectory v=20500 ... flags=0x10000(runtime) ...
Authority=Developer ID Application: Bruno Bonando (86JZ74B6NT)
```

`flags=0x10000(runtime)` on **both** the app and the embedded daemon confirms hardened-runtime signing landed on both, under the same identity, as the addendum requires. `codesign -d --entitlements :- .../OmniAgent.app` shows the empty `<dict/>` I wrote, correctly attached.

### Gatekeeper assessment — correctly rejects a signed-but-unnotarized build

```
$ spctl --assess --type execute --verbose=2 .../OmniAgent.app
.../OmniAgent.app: rejected
source=Unnotarized Developer ID
```

This is the textbook-correct intermediate state: real signing succeeded (Gatekeeper recognizes a genuine Developer ID signature — "source=Unnotarized Developer ID", not "no usable signature" or "unsigned"), and correctly withholds acceptance pending notarization, which this environment cannot complete (see below).

### Clear-failure-when-credentials-absent — the brief's primary testable requirement

```
$ unset OMNIAGENT_CODESIGN_IDENTITY
$ ./macos/dist.sh sign macos/.build/Build/Products/Release/OmniAgent.app
./macos/dist.sh sign: OMNIAGENT_CODESIGN_IDENTITY is not set.

Signing needs a Developer ID Application (or Apple Development, for local
testing) identity from your keychain. Find one with:

  security find-identity -v -p codesigning

Then set OMNIAGENT_CODESIGN_IDENTITY to either its name (e.g.
"Developer ID Application: Your Name (TEAMID)") or its SHA-1 hash, and
re-run this command.
exit=1

$ OMNIAGENT_CODESIGN_IDENTITY="Nonexistent Identity 12345" ./macos/dist.sh sign .../OmniAgent.app
./macos/dist.sh sign: no codesigning identity matching "Nonexistent Identity 12345" was found in the
keychain. Run 'security find-identity -v -p codesigning' to see what is
actually available and correct OMNIAGENT_CODESIGN_IDENTITY.
exit=1

$ unset OMNIAGENT_NOTARY_PROFILE
$ ./macos/dist.sh notarize .../OmniAgent.app
./macos/dist.sh notarize: OMNIAGENT_NOTARY_PROFILE is not set.

Notarization needs a notarytool credential profile stored in your
keychain. Create one once with:

  xcrun notarytool store-credentials <profile-name> \
    --apple-id <your-apple-id> --team-id <TEAMID> --password <app-specific-password>

Then set OMNIAGENT_NOTARY_PROFILE=<profile-name> and re-run this command.
exit=1

$ OMNIAGENT_NOTARY_PROFILE="nonexistent-profile-xyz" ./macos/dist.sh notarize .../OmniAgent.app
./macos/dist.sh notarize: no stored credential profile named "nonexistent-profile-xyz" was found (or it
is invalid). Create/recreate it with:

  xcrun notarytool store-credentials nonexistent-profile-xyz \
    --apple-id <your-apple-id> --team-id <TEAMID> --password <app-specific-password>
exit=1
```

Every case: exit 1, names the specific missing env var, and gives the exact command to fix it — never a silent skip.

### Build/test regression

```
$ ./macos/build.sh build
** BUILD SUCCEEDED **

$ ./macos/build.sh test
315 unique test cases started, 314 passed individually.
Failing tests:
    WorkspaceWindowControllerTests.testCommandOptionOIsClaimedByMenuBeforeSwiftTermKittyKeyDown()
```

Re-ran that one test in isolation (`-only-testing:...testCommandOptionOIsClaimedByMenuBeforeSwiftTermKittyKeyDown`) — `** TEST SUCCEEDED **`. This is the exact same pre-existing full-suite-load flake every Task 6 report since 6b-1 has recorded (see Task 6c's report). Nothing in this diff touches `WorkspaceWindowController.swift`, `TerminalSurfaceView.swift`, or the Option-as-Meta handling.

```
$ git diff --check
(clean, exit 0)
```

## Important finding, out of scope, clearly attributed: `scripts/native-macos-pty-harness.py`'s smoke check is stale

The brief instructs reusing Task 1's packaged-app smoke harness for `verify`'s smoke step. Doing so surfaced that **the harness has been broken against every daemon build since Task 2**, independent of anything in this task: `native-macos-pty-harness.py`'s `request()` sends bare `{"action": ...}` JSON over a newline-terminated connection, but Task 2 (`docs/plans/native-macos-migration.md`) rewrote the daemon's wire protocol to a persistent, versioned 16-byte binary envelope requiring a `Hello`/`HelloAck` handshake before any request (`crates/omniagent-pty-daemon/src/server.rs`'s `MessageKind`-driven dispatch). The harness was never updated for that rewrite. I confirmed this is pre-existing, not something I introduced, by `git stash`-ing my harness edits and running the **unmodified, originally-committed** `test_native_macos_pty_harness.py` against a freshly-built `target/debug/omniagent-pty-daemon` — it fails identically (`RuntimeError: daemon did not start`), then restored my changes (`git stash pop`).

What I did in scope: fixed the part of the harness that **is** Task 6d's concern — bundle-layout resolution. `find_daemon()`/`find_mcp()` (replacing `app_resources()`) now accept the native Swift app's `Contents/MacOS/omniagent-pty-daemon` layout in addition to the Tauri app's `Contents/Resources/` layout, and treat `omniagent-mcp` as optional (the Swift app never bundles it — that's a Tauri-only resource). I added `test_swift_bundle_layout_resolution` testing this resolution logic directly (via `importlib`, since the file's hyphenated name blocks a normal import) rather than through the full `smoke()` session flow, specifically to avoid being blocked by the pre-existing protocol staleness described above — it passes:

```
$ python3 -c "import sys; sys.path.insert(0,'scripts'); import test_native_macos_pty_harness as t; t.test_swift_bundle_layout_resolution(); print('PASSED')"
PASSED
```

What I did **not** do: rewrite the harness's wire client to speak the current binary-envelope protocol. That is a substantial, separate piece of work (equivalent to writing a new protocol client, which the brief explicitly said to avoid for the smoke step) and belongs to whichever task actually owns harness maintenance — flagging it here is the responsible thing, not silently declaring "smoke verified" against a check that cannot currently succeed. `dist.sh verify`'s smoke sub-step still calls the harness (as instructed) and will currently fail with a message that explicitly attributes this to the pre-existing gap, not to signing/notarization/bundle-structure (which its other two checks confirm work).

## What could NOT be exercised, clearly labeled

- **Real notarization submission and stapling** — no `notarytool` keychain profile exists in this environment (confirmed absent, not merely untried). The clear-failure path is verified (above); the actual `xcrun notarytool submit --wait` / `xcrun stapler staple` calls were never reached.
- **Gatekeeper accepting the app** — requires notarization first, which requires the above. `spctl` was exercised for real and gave the textbook-correct "signed but not notarized" verdict.
- **`SMAppService` registration actually succeeding / the System Settings → Login Items approval flow** — same environment constraint every prior Task 6 sub-task has recorded (no interactive System Settings, no way to grant approval headlessly). Verified structurally instead: the exact files `SMAppServiceDaemonRegistrar`/`DaemonBinaryLocator` need are now genuinely present at the paths they check, on a genuinely signed bundle.
- **The packaged PTY smoke check inside `dist.sh verify`** — blocked by the pre-existing harness/protocol staleness described above, not by anything credential-related.

## Self-review

1. **Scope of the `project.pbxproj` edit** — kept to exactly what the addendum needs: 3 file references, 3 build files, 2 Copy Files phases, 1 group, 2 build configurations, 2 configuration-list updates. No existing build phase, target, or setting was altered. Verified with `plutil -lint`, `xcodebuild -list`, and three separate real builds (`build`, `universal`, `-configuration Preview`) rather than just a lint pass.
2. **`OmniAgent.entitlements` is not referenced anywhere in `project.pbxproj`.** Deliberate: Xcode-native signing stays fully disabled (`CODE_SIGNING_ALLOWED = NO` throughout, unchanged) and all real signing happens through `dist.sh sign`'s own `codesign --entitlements` invocation, which only needs a filesystem path, not a project member. This kept the higher-risk pbxproj surface smaller. If Xcode-native archiving/signing is wanted later, wiring `CODE_SIGN_ENTITLEMENTS` is a small follow-up.
3. **`macos/embed-daemon.sh` changes `build`/`test`'s behavior, not just `universal`'s**, because the Copy Files phases are unconditional on the target. This is a real, intentional behavior change to the "existing" subcommands the brief said not to *replace* — I did not replace their interface or their xcodebuild invocation shape, but they now also require a working Rust toolchain for the host arch as a prerequisite (previously they didn't touch Rust at all). This follows directly from "once these three are done, `register()` should start succeeding... with zero further Swift code changes" requiring the Swift target to actually embed these files on every build, not just distribution ones.
4. **Preview's `EnvironmentVariables` bakes in the build machine's `$HOME`** — flagged prominently above (twice) rather than glossed over, since it's the one place this task's output is only correct for its actual deployment model (build-and-run on the same developer Mac), not for arbitrary redistribution.
5. **The harness staleness finding** — could have been left unmentioned (the `verify` step would just "fail" without explanation). Chose to trace it to its root cause and attribute it precisely, per the brief's own instruction to document exactly what was and wasn't verified.
6. **Signing was exercised for real** rather than only testing the failure path, because a real credential happened to already be present and using it (without creating/faking anything) gave materially stronger evidence that `dist.sh sign` actually works, not just that it fails correctly.
7. **Did not add a Makefile or any non-shell tooling** — everything is POSIX `sh`, `set -eu`, matching `macos/build.sh`'s existing style exactly, per the brief's Code Organization instructions.

## Files changed

- `macos/build.sh` — added `universal` subcommand; both it and the existing `build`/`test` subcommands now call `embed-daemon.sh` first.
- `macos/embed-daemon.sh` (new) — builds/lipos the daemon binary and generates both channels' LaunchAgent plists.
- `macos/dist.sh` (new) — `sign`/`notarize`/`verify` subcommands.
- `macos/OmniAgent/OmniAgent.entitlements` (new) — non-sandbox hardened-runtime entitlements.
- `macos/OmniAgent.xcodeproj/project.pbxproj` — 2 new Copy Files build phases, 3 new file references, 1 new group, 1 new "Preview" build configuration (project + target level), edited via a one-off Python script (not checked in, per the established Task 6a/6b/6c convention).
- `scripts/native-macos-pty-harness.py` — `app_resources()` replaced with `find_daemon()`/`find_mcp()` supporting both bundle layouts; `omniagent-mcp` is now optional.
- `scripts/test_native_macos_pty_harness.py` — added `test_swift_bundle_layout_resolution`.
- `.gitignore` — added `/macos/.build/` (the `universal` subcommand's dedicated `-derivedDataPath`).

---

## Review fix: the daemon/plist embed was unconditional on every configuration, forcing Rust on plain Debug builds

**Finding (verbatim from the reviewer):** `macos/build.sh:18-22` + `project.pbxproj:96,108` — the Copy Files phases ran on every build/config including Debug (`runOnlyForDeploymentPostprocessing = 0`), so plain `./macos/build.sh build`/`test` unconditionally required a working Rust toolchain, silently breaking the "plain Xcode-only, no Rust needed" workflow every earlier Task 6 sub-task (4, 6a, 6a-2, 6b-1, 6b-2, 6c) relied on. The addendum had offered a Run Script phase as an equally valid alternative to Copy Files specifically because a Run Script phase (unlike Copy Files) can check `$CONFIGURATION` and skip.

### What changed

**`macos/OmniAgent.xcodeproj/project.pbxproj`** — replaced the two unconditional `PBXCopyFilesBuildPhase` entries ("Embed PTY Daemon", "Embed LaunchAgent Plists") with a single `PBXShellScriptBuildPhase` ("Embed PTY Daemon + LaunchAgent Plists (non-Debug)") on the `OmniAgent` target:

```sh
if [ "$CONFIGURATION" = "Debug" ]; then
  echo "note: skipping daemon binary + LaunchAgent plist embed for the Debug configuration (no Rust toolchain required for plain builds/tests)."
  exit 0
fi
STAGE="$SRCROOT/../target/native-macos-embed"
DEST_MACOS="$BUILT_PRODUCTS_DIR/$CONTENTS_FOLDER_PATH/MacOS"
DEST_LAUNCH_AGENTS="$BUILT_PRODUCTS_DIR/$CONTENTS_FOLDER_PATH/Library/LaunchAgents"
if [ ! -x "$STAGE/omniagent-pty-daemon" ]; then
  echo "error: $STAGE/omniagent-pty-daemon not found. Run macos/embed-daemon.sh (or macos/build.sh universal) before building the $CONFIGURATION configuration." >&2
  exit 1
fi
mkdir -p "$DEST_MACOS" "$DEST_LAUNCH_AGENTS"
cp -f "$STAGE/omniagent-pty-daemon" "$DEST_MACOS/omniagent-pty-daemon"
chmod 755 "$DEST_MACOS/omniagent-pty-daemon"
cp -f "$STAGE"/*.plist "$DEST_LAUNCH_AGENTS/"
chmod 644 "$DEST_LAUNCH_AGENTS"/*.plist
```

Skips (exit 0, no-op) for `Debug`; for any other configuration (`Release`, `Preview`, or a future one), requires the daemon binary to already be staged and fails clearly if it isn't — the same "fail clearly, name what's missing, say how to fix it" contract the rest of this task already applies to signing/notarization, extended to this adjacent prerequisite. `alwaysOutOfDate = 1` is set so the phase always re-evaluates rather than being skipped by Xcode's own script-phase caching (correctness over speed, since its behavior depends on external state the build system doesn't track).

This is a deliberate, judgment-based consolidation of the original two named phases ("Embed PTY Daemon" / "Embed LaunchAgent Plists") into one: both need the identical `$CONFIGURATION` gate and the identical failure mode, so one phase halves the pbxproj object count and the risk of the two gates drifting out of sync, at the cost of one slightly less granular name in Xcode's build log. The addendum named a Run Script phase as an equally valid alternative to Copy Files, and the reviewer's own fix guidance explicitly left the two-phases-vs-one-phase choice to my judgment.

Also removed, since a Run Script phase needs none of them: the 3 `PBXBuildFile` entries that wrapped the daemon/plist file references for the old Copy Files phases' `files` lists, the 3 `PBXFileReference` entries themselves, and the "Embedded" `PBXGroup` (and its one reference from the `OmniAgent` group) that existed only to hold those file references for Xcode's navigator. Net effect: fewer pbxproj objects than before this fix, not more.

**Sandboxing wrinkle found while verifying the fix, and fixed in the same pass:** the target's `ENABLE_USER_SCRIPT_SANDBOXING = YES` setting (present since the original Task 6d commit, for both Debug and Release) sandboxes Run Script build phases' filesystem writes to whatever they declare in `outputPaths` — a restriction Copy Files phases are exempt from as a native build-phase type. The first `./macos/build.sh universal` run against the new Run Script phase failed with `Sandbox: cp(...) deny(1) file-write-create .../Contents/MacOS/omniagent-pty-daemon`, because I'd initially left `inputPaths`/`outputPaths` empty. Fixed by declaring both:

```
inputPaths = (
  "$(SRCROOT)/../target/native-macos-embed/omniagent-pty-daemon",
  "$(SRCROOT)/../target/native-macos-embed/digital.bruno.omniagent.pty-daemon.plist",
  "$(SRCROOT)/../target/native-macos-embed/digital.bruno.omniagent.preview.pty-daemon.plist",
);
outputPaths = (
  "$(BUILT_PRODUCTS_DIR)/$(CONTENTS_FOLDER_PATH)/MacOS/omniagent-pty-daemon",
  "$(BUILT_PRODUCTS_DIR)/$(CONTENTS_FOLDER_PATH)/Library/LaunchAgents/digital.bruno.omniagent.pty-daemon.plist",
  "$(BUILT_PRODUCTS_DIR)/$(CONTENTS_FOLDER_PATH)/Library/LaunchAgents/digital.bruno.omniagent.preview.pty-daemon.plist",
);
```

after which `universal` succeeded. Not a second Important finding in its own right — a direct consequence of switching phase types to fix the one the reviewer raised — but documented here since it wasn't part of the original plan and changed the final shape of the phase.

**`macos/build.sh`** — `build`/`test` no longer call `embed-daemon.sh` at all (previously they staged this machine's own arch unconditionally). Only `universal` still does, immediately before its `xcodebuild -configuration Release` invocation, matching the Run Script phase's own gate (`universal` builds Release, which the phase does not skip).

### Verification

**Debug (`build`/`test`) genuinely requires no Rust toolchain** — proved by stripping `~/.cargo/bin` (where `cargo`/`rustc`/`rustup` all live in this environment) from `PATH` for the actual build/test invocation, not just by inspection:

```
$ STRIPPED_PATH=$(echo "$PATH" | tr ':' '\n' | grep -v '\.cargo/bin' | paste -sd: -)
$ env PATH="$STRIPPED_PATH" which cargo rustc rustup
(exit 1 -- confirmed unreachable)

$ rm -rf target/native-macos-embed ~/Library/Developer/Xcode/DerivedData/OmniAgent-*
$ env PATH="$STRIPPED_PATH" ./macos/build.sh build
...
note: skipping daemon binary + LaunchAgent plist embed for the Debug configuration (no Rust toolchain required for plain builds/tests).
...
** BUILD SUCCEEDED **

$ ls .../Build/Products/Debug/OmniAgent.app/Contents/MacOS/
OmniAgent          # no omniagent-pty-daemon -- correctly absent, matching the skip
$ ls .../Build/Products/Debug/OmniAgent.app/Contents/Library
ls: .../Contents/Library: No such file or directory   # correctly absent too

$ env PATH="$STRIPPED_PATH" ./macos/build.sh test
...
note: skipping daemon binary + LaunchAgent plist embed for the Debug configuration (no Rust toolchain required for plain builds/tests).
...
315 unique test cases started, 314 passed individually.
Failing tests:
    WorkspaceWindowControllerTests.testCommandOptionOIsClaimedByMenuBeforeSwiftTermKittyKeyDown()
** TEST FAILED **
```

`target/native-macos-embed` was deleted first, too, so this isn't "Rust wasn't invoked because stale files from an earlier run were already there" — there was nothing staged at all, and Debug still built and tested cleanly with `cargo` completely unreachable. The one failing test is the same pre-existing full-suite-load flake every prior Task 6 report has recorded (confirmed passing in isolation again, same as always); nothing in this fix touches it.

**Release (`universal`) still embeds the real, correct artifacts** — re-ran the exact bundle-structure check from the original report against a freshly rebuilt universal app:

```
$ rm -rf macos/.build && ./macos/build.sh universal
** BUILD SUCCEEDED **

$ lipo -info .../Contents/MacOS/OmniAgent
Architectures in the fat file: ... are: x86_64 arm64
$ lipo -info .../Contents/MacOS/omniagent-pty-daemon
Architectures in the fat file: ... are: x86_64 arm64

$ find .../OmniAgent.app -maxdepth 4 | sort
.../Contents/Library/LaunchAgents/digital.bruno.omniagent.preview.pty-daemon.plist
.../Contents/Library/LaunchAgents/digital.bruno.omniagent.pty-daemon.plist
.../Contents/MacOS/OmniAgent
.../Contents/MacOS/omniagent-pty-daemon
(plus Info.plist/PkgInfo/Resources, identical to the original report)
```

Identical structure to the original report's verification. Also re-signed this rebuilt bundle with the same real Developer ID identity to confirm signing survived the phase-type change end to end:

```
$ OMNIAGENT_CODESIGN_IDENTITY="Developer ID Application: Bruno Bonando (86JZ74B6NT)" ./macos/dist.sh sign .../OmniAgent.app
... ./macos/dist.sh sign: done.
$ codesign -dvvv .../OmniAgent.app | grep flags
CodeDirectory v=20500 ... flags=0x10000(runtime) ...
```

**Preview configuration also still embeds correctly** (it's "non-Debug" too, same as Release): built directly via `xcodebuild -configuration Preview` after `./macos/embed-daemon.sh arm64`, `find` confirmed both `Contents/MacOS/omniagent-pty-daemon` and both `Contents/Library/LaunchAgents/*.plist` present, matching the original report's Preview verification.

**Full regression, normal environment (Rust available, as it always is on a real dev machine):**

```
$ rm -rf ~/Library/Developer/Xcode/DerivedData/OmniAgent-*
$ ./macos/build.sh build
** BUILD SUCCEEDED **

$ ./macos/build.sh test
315 unique test cases started, 314 passed individually.
Failing tests:
    WorkspaceWindowControllerTests.testCommandOptionOIsClaimedByMenuBeforeSwiftTermKittyKeyDown()

$ git diff --check
(clean, exit 0)
```

### Self-review

1. Did not touch the two deferred Minor findings (`sign()` should hard-fail on a missing daemon binary; the notary-profile check makes a network call) — out of scope per the coordinator's explicit instruction, left for the whole-branch review.
2. The sandboxing fix (`inputPaths`/`outputPaths`) was not something I anticipated going in; found it by actually running the build against the new phase type rather than assuming a Copy Files → Run Script swap would be a drop-in replacement, and fixed it in the same pass rather than leaving `universal` broken.
3. Verified the "no Rust required" claim behaviorally (`PATH` stripped for the actual command), not just by reading the shell script and asserting it looks right.
4. Net pbxproj complexity decreased: 2 Copy Files phases + 3 build files + 3 file references + 1 group (9 objects) became 1 Run Script phase (1 object).

### Files changed (this fix)

- `macos/OmniAgent.xcodeproj/project.pbxproj` — Copy Files phases replaced with one Debug-gated Run Script phase; now-unused build files/file references/group removed.
- `macos/build.sh` — `build`/`test` no longer stage the daemon binary at all; only `universal` does.
