# App Review notes — OmniAgent (macOS)

Paste the section below into App Store Connect → App Information → App Review Information → **Notes**. It is written as plain text on purpose (short lines, no markdown syntax that would survive badly in that field).

---

## Text to paste

What this app is:
OmniAgent is a native macOS terminal workspace for AI coding assistants (Claude Code, Codex, GitHub Copilot CLI, Google AntiGravity). It gives each of those command-line tools a workspace: project sidebar, terminals, an editor pane, and a browser pane, all local to the Mac. The app does not include, download, or install any of those CLIs — the user installs whichever ones they already use, the normal way (Homebrew, npm, a vendor installer), outside this app, before or after using OmniAgent. If a CLI is not on the user's PATH, OmniAgent shows its menu row greyed out ("Codex — not installed"); it never runs an installer on the user's behalf. There is no `curl | bash`, no `npm install -g`, and no other in-app code-fetching path anywhere in the shipped bundle.

Background process (the PTY daemon):
Opening a terminal pane spawns a small persistent helper process, `omniagent-pty-daemon`, that owns the real PTYs/shells so a terminal session survives an app relaunch. It is registered with `SMAppService.agent` (the standard, Apple-sanctioned login-item mechanism) — its LaunchAgent plist ships inside the app bundle at `Contents/Library/LaunchAgents` and the binary itself is `Contents/MacOS/omniagent-pty-daemon`, signed with the same identity as the app. The user can see, disable, or remove it at any time in System Settings → General → Login Items, the same surface every other login item uses; OmniAgent also deep-links there from its own Settings screen. The daemon listens only on a local Unix-domain socket (`~/.omniagent-ade/omniagent-pty.sock`), created with `0600` permissions and a peer-UID check that rejects any connecting process that isn't the same local user — nothing remote, and no other user on the same Mac, can talk to it.

Network access:
The app talks to a short, fixed list of hosts:
- `api.omni-agent.ai` — our own backend, for sign-in and account calls.
- `appleid.apple.com` — Sign in with Apple's web authentication flow.
- The signed-in provider's small avatar image (Apple/GitHub CDN), shown in the sidebar.
- `github.com` — only when the user explicitly chooses "Open on GitHub" for a repository they already opened.
- `www.google.com` — only as the search fallback when the user types a plain query (not a URL) into a browser pane.
- Whatever URL the user types or clicks inside a browser pane. That pane is a general-purpose embedded browser the user drives themselves, the same way any app with an in-app browser works; the app does not navigate it on its own.
There is no third-party analytics or crash-reporting SDK, and no telemetry call leaves the Mac: usage counters (sessions opened, terminals opened, etc.) are computed and stored locally in the app's own SQLite database and are never uploaded.

Local data and privacy:
Terminal transcripts and the AI agents' memory notes are stored locally on the Mac (`~/Library/Application Support/OmniAgent-ADE`), never uploaded to us or to any third party. A redaction pass removes recognizable secret patterns (API keys, tokens) before anything is written to that local memory store.

Sign-in:
The app offers three choices on first launch:
1. Sign in with Apple — the web-based flow (Apple's `appleid.apple.com`, opened in the system browser/web view), used because this app is Developer ID/non-MAS and native Sign in with Apple isn't available to it.
2. Sign in with GitHub — GitHub's own OAuth device/web flow.
3. **Continue without signing in** — the app is fully usable with no account at all; sign-in only unlocks optional cloud sync/account features layered on top of the local-first terminal workspace.
For App Review, please use option 3, "Continue without signing in" — it requires no credentials and exercises the full terminal/editor/browser workspace exactly as any user would experience it without an account.

Test account:
TODO(Bruno): create reviewer account — mint a throwaway api.omni-agent.ai account (email + password, or a GitHub test identity) if App Review specifically wants to exercise the signed-in path; otherwise "Continue without signing in" above covers full functionality and no credentials are needed.

Third-party names and marks:
The app displays the names/icons of the AI CLIs it can front-end for: Claude / Claude Code (Anthropic), Codex (OpenAI), GitHub Copilot (GitHub/Microsoft), and AntiGravity (Google). OmniAgent is an independent, unaffiliated client for these tools — it is not endorsed by, sponsored by, or affiliated with Anthropic, OpenAI, GitHub, Microsoft, or Google. These are used nominatively, to tell the user which installed CLI a given terminal pane is running.
