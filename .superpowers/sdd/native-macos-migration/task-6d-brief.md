# Task 6d — Distribution: universal build, signing, notarization, Gatekeeper

Sub-task of plan Task 6 (`docs/plans/native-macos-migration.md`), split for implementer-sized review, and the last of Task 6's four sub-tasks (no dependency on 6a-6c beyond `./macos/build.sh` existing, which it already does from Task 4). Plan bullet:

> Add universal build, hardened-runtime signing, notarization/stapling scripts, Gatekeeper/install smoke verification, and explicit non-sandbox entitlements. Scripts must fail clearly when credentials are absent.

## What exists today

- `macos/build.sh` (Task 4) already builds/tests the app via `xcodebuild` against `macos/OmniAgent.xcodeproj`. Extend it (or add sibling scripts alongside it) rather than replacing its existing `build`/`test` subcommands.
- No existing entitlements file, signing, notarization, or universal-build configuration exists in `macos/` yet — this is new.

## Required behavior

- **Universal build**: produce a single binary/app bundle containing both `arm64` and `x86_64` slices (`xcodebuild ... ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO` or equivalent), verifiable with `lipo -info` on the produced binary.
- **Hardened-runtime signing**: codesign the app bundle with the hardened runtime flag (`--options runtime`) and an **explicit non-sandbox entitlements file** (no `com.apple.security.app-sandbox` entitlement — the plan is explicit that the initial direct-download build is not sandboxed; include only the entitlements the app actually needs, e.g. whatever's required for PTY/process spawning and network/socket access, and no more).
- **Notarization/stapling**: a script that submits the signed, zipped app to Apple's notary service (`notarytool submit ... --wait`) and staples the ticket (`stapler staple`) on success.
- **Gatekeeper/install smoke verification**: after stapling, verify with `spctl --assess --type execute` (or equivalent) that Gatekeeper accepts the app, plus a basic install smoke check (app launches / bundle structure is intact) — reuse the existing packaged-app smoke harness from Task 1 (`docs/plans/native-macos-migration.md` Task 1) if applicable rather than writing a new one from scratch.
- **Fail clearly when credentials are absent**: signing identity, notarization Apple ID/API key, and any other required secret must be checked up front; a missing credential produces a clear, actionable error message (which env var / keychain item is missing, and how to provide it) and a non-zero exit — never a silent skip or a broken/unsigned artifact presented as success.

## Constraints on your environment

You almost certainly do not have real Apple Developer signing/notarization credentials available in this sandbox. That's expected and is not a blocker: **the testable behavior is the clear-failure path**, not an actual signed/notarized artifact. Verify your scripts fail with a clear, correct error message when the relevant env vars/keychain identities are absent, and that the universal-build/entitlements steps that don't require real credentials (build, lipo check, entitlements file validity, ad-hoc signing if that's a meaningful intermediate check) still work. Do not fabricate a fake signing identity or attempt to work around the missing credentials — document exactly what you could and couldn't exercise in your report.

## Global constraints that bind this task

- No App Sandbox — explicit non-sandbox entitlements, not merely omitted ones.
- Scripts live alongside `macos/build.sh` and follow its conventions (shell style, subcommand structure) rather than introducing a new build-tooling pattern.

## Addendum — Task 6c's deferred resource-embedding (read this, it's new since this brief was first written)

Task 6c (`.superpowers/sdd/native-macos-migration/task-6c-report.md`) built the full `SMAppService`/LaunchAgent persistence mechanism, but deliberately deferred the Xcode-side resource embedding to this task — it is now part of Task 6d's required behavior, not optional:

- **Embed the compiled `omniagent-pty-daemon` Rust binary into the app bundle at `Contents/MacOS/omniagent-pty-daemon`** — this is the exact path `DaemonBinaryLocator.candidates` (in `macos/OmniAgent/DaemonPersistence.swift`) checks first, after its `OMNIAGENT_PTY_DAEMON_BIN` env override. The binary must be **signed under the same identity as the app** (hardened-runtime signing, same as the app bundle itself) for Gatekeeper/notarization to accept the bundle as a whole. Building it is a `cargo build --release -p omniagent-pty-daemon` step that needs wiring into the Xcode build (a Run Script build phase, matching however the existing Tauri build already bundles this binary as a resource — check `src-tauri`'s build process for precedent — or an equivalent `xcodebuild`/`macos/build.sh` pre-step).
- **Add an Xcode Copy Files build phase that installs the LaunchAgent plist at `Contents/Library/LaunchAgents/`.** The plist *content* is already built and unit-tested — `DaemonLaunchAgentPlist.build` in `macos/OmniAgent/DaemonPersistence.swift` — it currently has no production caller (deliberately, per Task 6c's report: "this function's real consumer is Task 6d"). You need to actually generate/write this plist file into the bundle at build time (e.g. a Run Script phase that calls into the app to emit it, or a small standalone script/tool that mirrors its logic) and copy it to the right bundle location with the right file permissions LaunchAgents expect.
- **Activate the preview build channel.** Task 6c's channel-resolution *policy* is complete and tested (bundle-id suffix distinguishes preview from production, plus an `OMNIAGENT_ADE_BUILD_CHANNEL=preview` env override that already works) — but only Debug/Release Xcode build configurations exist today, both using the same bundle id `digital.bruno.omniagent`. Add a build configuration (or scheme) that uses a distinct preview bundle id, matching what Task 6c's `DaemonPaths`/channel resolution already expects. Document exactly what bundle-id suffix/naming convention you chose.

Once these three are done, `SMAppServiceDaemonRegistrar.register()` should start succeeding on a properly signed+installed build with zero further Swift code changes — verify this is at least structurally true (the right files land in the right places in the built bundle) even though full end-to-end registration approval can't be exercised without real signing credentials and interactive System Settings approval (same environment constraint as the rest of this task — see "Constraints on your environment" above).

## Verification

- Run the new script(s) with credentials absent and confirm the clear-failure behavior directly (paste the actual output in your report).
- `./macos/build.sh build` still passes.
- Verify the built bundle actually contains `Contents/MacOS/omniagent-pty-daemon` and `Contents/Library/LaunchAgents/<label>.plist` at the right paths (e.g. via `find`/`ls` on the built `.app`, pasted in your report) — this is the concrete, checkable proof the addendum above landed correctly.
- `git diff --check`

Commit all Task 6d work and write `.superpowers/sdd/native-macos-migration/task-6d-report.md`.
