//! PTY session engine — plain Rust, no Tauri types.
//!
//! This module is the Tauri compatibility adapter for daemon-owned terminal
//! sessions. The daemon alone owns PTYs, child processes, transcripts, and
//! reaping; this layer preserves the existing command models, output sinks,
//! lifecycle hooks, and status/attention behavior. It is deliberately
//! decoupled from `tauri::AppHandle`/`State` so it can be integration-tested
//! through plain Rust calls (see `src-tauri/tests/session_test.rs`) — the thin
//! `#[tauri::command]` wrappers live in `commands.rs`.
//!
//! ## On-disk layout (under `<data_dir>/transcripts/`)
//! - `<session-id>.log` — raw PTY output, secret-redacted
//!   ([`brain_core::redact::redact`]), line-buffered so a secret split
//!   across two PTY reads still gets caught before it hits disk.
//! - `<session-id>.lifecycle.jsonl` — one JSON object per line, one line per
//!   lifecycle event. Two shapes (tagged by `"event"`):
//!   ```json
//!   {"event":"start","ts":1753500000,"engine":"claude","project":"demo","cwd":"/path"}
//!   {"event":"end","ts":1753500042,"exit_code":0,"signal":null,"killed":false}
//!   ```
//!   `ts` is unix seconds ([`brain_core::now_ts`]). `exit_code`/`signal` are
//!   `null` when unknown (e.g. the process was still starting up when the
//!   event fired). `killed` is `true` only when `SessionManager::kill` drove
//!   the shutdown, `false` for a natural exit (e.g. the user typed `exit`).
//!
//! ## Zero-config Claude wiring (DESIGN principle 5)
//! When `engine == "claude"`, [`SessionManager::create`] resolves the
//! `omniagent-mcp` binary built from this same workspace
//! ([`resolve_mcp_server_binary`]), writes a throwaway `--mcp-config` JSON
//! file registering it (with `OMNIAGENT_ADE_DATA_DIR` set in its `env`
//! block), and — if a `briefing` was supplied — forwards it verbatim via
//! `--append-system-prompt`. Codex receives the same MCP server through its
//! per-invocation `--config mcp_servers.omniagent=…` override. If the MCP
//! binary can't be found, either engine is still spawned without ADE wiring
//! (logged, never a hard failure — see [`resolve_mcp_server_binary`]'s doc
//! comment). Nothing is written to the user's own config.
//!
//! ## Attention detection (founder feedback, 2026-07-24)
//! Bruno: "every claude session[...] can notify the app whenever it needs
//! attention[...] that session can require attention, generate a badge".
//! Investigated three candidate signals before picking one:
//!
//! 1. **Claude Code's `Notification` hook event** — real, but every way to
//!    wire it (`~/.claude/settings.json`, a project's `.claude/settings.
//!    json`) requires the user to configure their own install, which is
//!    exactly what DESIGN principle 5 rules out. `claude --help` has no
//!    per-invocation hook flag (`--settings <file-or-json>` loads *general*
//!    settings for one invocation — same throwaway-file trick this module
//!    already uses for `--mcp-config` — but hooks specifically shell out to
//!    an arbitrary command, and configuring that non-interactively still
//!    reads as "asking the user to set something up" the moment it's their
//!    own persistent `settings.json` a plain terminal `claude` would also
//!    see; a throwaway `--settings` hook would be per-invocation and
//!    config-free in principle, but see #2 below for why a PTY-stream
//!    signal made this moot). Ruled out as the primary mechanism.
//! 2. **Plain BEL (`0x07`)** — empirically, stock `claude` (2.1.219) only
//!    ever emits `0x07` as the string terminator of `OSC` escape sequences
//!    (window-title updates, `ESC ] 0 ; <title> BEL`), which fire
//!    continuously during any activity (every spinner frame), not
//!    specifically at attention-worthy moments. A raw BEL count is pure
//!    noise here — verified by driving a real `claude` session through a
//!    Python-PTY probe and diffing BEL positions against a hex dump; every
//!    single occurrence traced back to a title-terminator, none to a
//!    standalone "ring the bell" gesture. Ruled out.
//! 3. **`OSC 777 notify` (`ESC ] 777 ; notify ; warp://cli-agent ; <json>
//!    BEL`)** — real, structured, and genuinely tempting: stock `claude`
//!    emits this with a machine-readable `{"event": "..."}` payload
//!    (`permission_request`, `stop`, `idle_prompt`, etc. — exactly the
//!    taxonomy Bruno described) whenever it's running with
//!    `TERM_PROGRAM=WarpTerminal` in its environment. But it's gated behind
//!    more than that single env var (setting only `TERM_PROGRAM` while
//!    stripping the rest of Warp's `WARP_*` vars does **not** unlock it —
//!    verified empirically), and reverse-engineering the rest of an
//!    undocumented, third-party terminal's proprietary detection heuristic
//!    just to spoof it crosses the line DESIGN principle 5 draws ("the
//!    engine runs completely unmodified... exactly as in a plain
//!    terminal") — we'd be lying to `claude` about its host, not just
//!    observing its stock behavior. Ruled out as something to build on,
//!    even though it's a genuinely interesting integration to know about.
//!
//! **What's actually implemented**: plain-text pattern matching on the raw
//! PTY stream for the literal markers `"Do you want to"` /
//! `"Would you like to"` ([`ATTENTION_MARKERS`]) — the exact copy stock
//! `claude` prints in its yes/no dialogs (the tool-permission confirmation,
//! verified against both a Bash-tool and a Write-tool prompt — different
//! trailing wording, shared "Do you want to" opening — and the plan-approval
//! dialog's "Would you like to proceed?"). This is
//! honestly the fragile, version-coupled fallback the founder brief itself
//! anticipated ("don't force a solution that doesn't reflect reality") —
//! it requires zero configuration and zero engine spoofing, which is the
//! one property that mattered most here. Not hard-gated to `engine ==
//! "claude"` (see the daemon-output processor for why — in short,
//! that would make it untestable through a real PTY without an actual
//! `claude` process, network access, and a live conversation); in practice
//! this is still effectively Claude-specific, since it's Claude Code's own
//! UI copy no other stock engine would print. Matches are debounced per
//! session via [`AttentionDebouncer`] so a single pending prompt's redraw
//! storm (dozens of re-renders a second while nothing has actually changed)
//! fires one
//! event, not hundreds.
//!
//! ## Resolving the real `PATH` for GUI-launched spawns (founder bug,
//! ## 2026-07-25)
//! Bruno hit this live in the packaged `.app`: opening a `"claude"` session
//! failed with `Couldn't start claude in <project>: spawn engine process`.
//! Root cause: `build_command` spawns `"claude"`/`"codex"` as bare command
//! names, which `portable_pty` resolves via whatever `PATH` this process
//! itself inherited at spawn time. A `.app` launched via Finder/`open`
//! inherits macOS's minimal default `PATH`
//! (`/usr/bin:/bin:/usr/sbin:/sbin`) — **not** the user's real shell `PATH`,
//! which lives in their shell startup files and is normally only assembled
//! when a real login shell starts (this is why `cargo tauri dev`, run from
//! inside an already-full-PATH terminal, never reproduced the bug: it
//! inherits the terminal's PATH, not a GUI launch's). On this machine, the
//! real `claude` binary is a symlink at `~/.local/bin/claude`, and
//! `~/.local/bin` is only added to `PATH` by `~/.zshrc`.
//!
//! [`resolve_shell_path`] fixes this the standard way GUI apps on macOS do
//! (VS Code and most Electron apps included): spawn the user's own
//! `$SHELL` once, non-interactively from *this* process's point of view,
//! and capture the `PATH` it ends up with. The exact invocation matters and
//! was verified empirically on this machine (see the commit message /
//! [`resolve_shell_path_for`]'s tests for the comparison) rather than
//! assumed: `<shell> -lc 'echo -n $PATH'` (login, non-interactive — the
//! "standard" advice) sources `.zshenv`/`.zprofile`/`.zlogin` but **not**
//! `.zshrc`, and this machine's `~/.local/bin` entry lives in `.zshrc` —
//! zsh only sources it for *interactive* shells, login or not. `<shell>
//! -ilc '...'` (login **and** interactive) does source `.zshrc` and
//! reliably produces the real, correct `PATH` (including `~/.local/bin`)
//! with clean single-line output — no banner/prompt noise leaked into
//! `stdout`, verified against this exact `$SHELL`/`~/.zshrc` combination.
//! That's the invocation used here.
//!
//! Resolution spawns a real subprocess, so it's cached process-wide after
//! the first call ([`cached_shell_path`], backed by a `std::sync::OnceLock`
//! — this module's first use of that pattern; nothing comparable existed
//! here before) rather than repeated per session. It also runs on a
//! background thread with a hard [`SHELL_PATH_RESOLUTION_TIMEOUT`] via a
//! channel `recv_timeout` (not a bare blocking call) — `stdin` is closed so
//! a profile script trying to interactively prompt gets immediate EOF
//! rather than hanging, but nothing rules out a truly pathological profile
//! (an infinite loop, a network call that never returns), and this sits on
//! session creation's critical path. Any failure — `$SHELL` unset, spawn
//! error, timeout, empty output — resolves to `None`, and callers
//! ([`apply_resolved_path`]) simply skip overriding `PATH`, falling back to
//! exactly today's behavior (bare-name resolution against whatever `PATH`
//! this process already inherited). PATH resolution failing must never
//! become a *new* way for session creation to fail.
//!
//! Applied to `"claude"` and `"codex"` (the bug's actual targets) and,
//! since it's free once computed and strictly more correct from the very
//! first prompt, to `"shell"` too — the engines themselves stay completely
//! stock; this only changes which `PATH` OmniAgent's own spawn call hands
//! them, never anything about how `claude`/`codex` are configured (DESIGN
//! principle 5, same zero-config boundary the rest of this module's docs
//! already describe).
//!
//! ## Session persistence via tmux (founder brief, 2026-07-26)
//! Bruno, verbatim: *"Every new claude or terminal or codex session, must be
//! stored, if not properly closed. […] if the user closes the application and
//! comes back to that session, the terminal, claude, codex (whatever) session
//! must be restored. […] Maybe it's nice to keep the session as tmux,
//! regardless of agent. I think it's easier, right?"* — and *"If the user
//! closes the terminal, tmux or claude session can be deleted."*
//!
//! It is easier, and it's uniform: the PTY child is no longer the engine
//! itself but `tmux attach-session` against a detached tmux session named
//! [`crate::tmux::session_name`]`(<session id>)` that the engine runs inside.
//! Everything else in this module is unchanged — the reader thread still sees
//! the same byte stream (now including tmux's redraws), the transcript is
//! still redacted, attention detection still works, `write`/`resize`/`kill`
//! keep their exact semantics from the frontend's point of view.
//!
//! What changes is what survives. Closing the app kills the attach client;
//! the tmux server keeps the engine process and its scrollback alive. The
//! next [`SessionManager::create`] carrying the *same* id finds that session
//! already present and attaches instead of spawning — the user is back in the
//! same live Claude conversation / shell, not a fresh one. `kill()` (the user
//! closing the tab) is the only thing that destroys it.
//!
//! **This requires a stable session id across app restarts, which the app did
//! not have.** [`generate_session_id`] mints a fresh
//! `sess-<nanos>-<counter>` per call, and `ui/src/state/sessions.ts`'s
//! `PersistedTab` deliberately never persisted the id ("engines are restarted
//! fresh on restore… so only the inputs to a fresh `session_create` call are
//! kept, never the old session id"). Hence
//! [`CreateSessionRequest::restore_id`]: the frontend persists the id it got
//! back and passes it in on relaunch. Without it, every relaunch would mint a
//! new id, find no tmux session under that name, and start a fresh engine —
//! i.e. exactly today's behavior, which is also the honest fallback when the
//! id is absent.
//!
//! Degradation, in order of preference:
//! 1. **tmux present, session exists** → attach. Full restoration.
//! 2. **tmux present, no session** → create it, attach. Fresh engine, but
//!    persistent from here on. If this was a *restore* attempt (an id came
//!    in) the `claude` engine reopens its own conversation — see below.
//! 3. **tmux absent** → spawn the engine directly into the PTY, exactly as
//!    before. Nothing survives an app close, but on a restore attempt
//!    `claude` still reopens its own conversation, so the *conversation*
//!    carries over even though the process doesn't. `codex`/`shell` have no
//!    equivalent and simply start fresh.
//!
//! A missing/broken tmux must never be a way for session creation to fail —
//! same rule [`resolve_shell_path`] already follows for `PATH`.
//!
//! ## Why tmux needs an *absolute* engine path (founder bug, 2026-07-26)
//! Bruno, verbatim: *"every terminal is a black screen"*. Every transcript in
//! his data dir held literally `no sessions\r` and nothing else, and every
//! lifecycle file an `exit_code: 1`. The whole chain was measured against real
//! tmux 3.7b / claude 2.1.220 rather than reasoned about:
//!
//! 1. **tmux resolves a pane's command against the environment of the tmux
//!    *client* that asked for it — never the per-session `-e PATH`.** `-e
//!    KEY=VALUE` does reach the pane process's environment (tmux module docs
//!    #4), but by then the `exec` has already happened, so it cannot help
//!    *find* the binary. Isolated against real tmux by crossing the two
//!    environments: a server started with a full `PATH` driven by a client
//!    with `env -i PATH=/usr/bin:/bin` could **not** run bare `claude`, while
//!    a server started with the minimal `PATH` driven by a full-`PATH` client
//!    could. The client is what matters — and an **absolute** program path
//!    works under either.
//! 2. The client here *is this app*: `Tmux::ensure_session` runs `tmux
//!    new-session` as a subprocess of OmniAgent. A GUI-launched `.app`
//!    inherits macOS's minimal default `PATH`
//!    (`/usr/bin:/bin:/usr/sbin:/sbin`) — the same environment
//!    [`resolve_shell_path`] already exists to work around. `claude` lives at
//!    `~/.local/bin/claude` on this machine, which only `~/.zshrc` adds. So
//!    the one process that had to be able to find `claude` was the one that
//!    couldn't.
//! 3. So `new-session -d -- claude …` **succeeds** (exit 0 — tmux reports on
//!    creating the pane, not on the `exec` inside it), the pane dies within
//!    ~150 ms, and `remain-on-exit off` destroys the session immediately. The
//!    last session going away takes the whole server with it.
//! 4. The `attach-session` that follows therefore finds **no server at all**,
//!    which is precisely the state tmux reports as `no sessions` (a *running*
//!    server missing that one session says `can't find session: X` instead —
//!    the distinction is what pinned this down). One line of text, then EOF:
//!    a black rectangle.
//!
//! Two things kept this invisible. It never reproduces from a terminal — a
//! `cargo run`/`cargo test` process has the user's full `PATH`, so the server
//! it starts resolves `claude` by bare name and everything works; only the
//! packaged, Finder-launched `.app` fails. And the retry ladder below could
//! not save it: all three rungs fail identically and instantly (the flags were
//! never the problem — the binary was), and the last rung is deliberately
//! unprobed, so its dead attach client was handed straight to the user.
//!
//! The fix is three-layered, root cause outward:
//! - [`resolve_engine_binary`] resolves every engine to an **absolute path**
//!   against the same shell-resolved `PATH` the engine itself is handed, so
//!   the tmux server's own environment stops mattering.
//! - [`tmux_session_survives_startup`] verifies a *freshly created* tmux
//!   session is still alive before its pane is handed over, so "the command
//!   never started" is caught on the tmux side — where it is observable —
//!   rather than only through the attach client, and **every** rung is checked,
//!   including the last.
//! - Phase 2 moved startup and exit observability into the persistent daemon;
//!   Tauri no longer creates a fallback PTY or attach child.
//!
//! ## Every `claude` pane owns its own conversation (founder bug, 2026-07-26)
//! The first version of rungs 2/3 above used `claude -c/--continue`, and it
//! was wrong in a way a single-session test can never catch. Bruno caught it:
//! `--continue` continues *the most recent conversation **in that
//! directory***, and this app's whole shape encourages several Claude panes
//! in one project folder. After a reboot (tmux is userspace — it dies with
//! the machine, so every restore falls to rung 2/3 at once) **every** pane in
//! a project would reopen the same, most-recent conversation: panes 2..N
//! silently lose their own history and become duplicates of pane 1. Not
//! hypothetical — this repo's own directory already holds 11 distinct
//! conversation `.jsonl` files.
//!
//! The fix is to stop letting "most recent" decide. `claude` has the right
//! primitives (verified against real `claude --help`, 2.1.220):
//! `--session-id <uuid>` ("Use a specific session ID for the conversation")
//! and `-r/--resume <uuid>` ("Resume a conversation by session ID"). So:
//!
//! - **first spawn** → `--session-id <U>`: OmniAgent, not Claude's
//!   most-recent heuristic, decides which conversation this pane owns.
//! - **restore that has to start a fresh engine** → `--resume <U>`: the pane
//!   gets *its own* conversation back, however many others share the folder.
//!
//! `U` is derived, not stored: [`claude_conversation_uuid`] is a UUIDv5 of
//! the OmniAgent session id under a fixed OmniAgent namespace, so the same id
//! always maps to the same conversation and **nothing new has to be
//! persisted** — `restore_id` (already round-tripping through the frontend)
//! remains the only piece of state. `codex`/`shell` are untouched.
//!
//! `--continue` is gone entirely. `--resume <U>` is strictly better on every
//! path that used it, and its directory-scoped "most recent" semantics *were*
//! the bug.
//!
//! ### The identity flags are booby traps, and are handled as ones
//! All measured on this machine against real `claude` 2.1.220, **not** assumed
//! from the help text — interactive, through a real PTY, in a trusted
//! directory:
//!
//! - `--resume <uuid>` with no such conversation **exits 1 after ~1.25 s**
//!   printing `No conversation found with session ID: <uuid>`. Every session
//!   that existed *before* this fix lands is exactly this case: its
//!   conversation was created without a chosen id, so the derived `U` names
//!   nothing.
//! - `--session-id <uuid>` for a conversation that already exists **exits 1
//!   after ~0.20 s** printing `Error: Session ID <uuid> is already in use.`
//!   (measured three times).
//! - `--session-id` accepts any `8-4-4-4-12` hex string — a nil UUID and a
//!   variant-0 UUID were both taken. The v5 value we derive is well inside
//!   what it validates, and it composes fine with this module's other flags
//!   (`--mcp-config`, `--append-system-prompt`), verified together.
//!
//! Passed naively, either failure turns "open a tab" into an instantly-dead
//! terminal — strictly worse than a fresh, working Claude. So every spawn
//! carrying an identity flag is probed for liveness ([`child_survives_startup`])
//! and, if the process bailed, **transparently respawned down a ladder**
//! ([`ClaudeIdentity::ladder`]) before `create` ever returns:
//! `--resume <U>` → `--session-id <U>` → stock `claude`. The middle rung is
//! what quietly *adopts* a pre-existing session: its old conversation is
//! unreachable, but the fresh one it starts is claimed under `U`, so from
//! that restore onward the pane is addressable and every later restore lands
//! on its own history. The caller sees one healthy session either way.
//!
//! Probe windows are sized per rung from those measurements
//! ([`RESUME_LIVENESS_WINDOW`], [`SESSION_ID_LIVENESS_WINDOW`]). Attaching to
//! a live tmux session carries no identity flag and is never probed, so the
//! ordinary restore still pays nothing.
//!
//! ## Five-state session status (founder brief, 2026-07-26, revised same day)
//! The first version of this was a three-state traffic light (*"Green means
//! ready for any new command, yellow means executing, red means requires
//! attention or input"*). Bruno then revised it to five, verbatim:
//!
//! > White/Blue: pulsing gradient — the agent is thinking, reasoning, or
//! > generating tokens. · Green: solid steady — a task completed successfully
//! > and results are ready or just waiting for input. · Amber/Yellow:
//! > breathing slow rhythm — the agent is paused, waiting for your approval. ·
//! > Red/Magenta: rapid flashing — an error occurred, a process failed, or a
//! > block exists. · Cyan/Teal: rapid chasing — active tool execution, like
//! > terminal commands or file writes.
//! >
//! > But only green, yellow or red generate a notification (in case the user
//! > is somewhere else…).
//!
//! → [`SessionStatus::Thinking` / `Ready` / `AwaitingApproval` / `Error` /
//! `ToolExecution`], pushed as `session-status:{id}` on change (payload:
//! [`SessionStatusEvent`], `notify` flag included — [`SessionStatus::notifies`]
//! is the single source of truth for that rule) and pullable on demand via
//! [`SessionManager::status`], which returns the identical shape so a tab can
//! render the right light the instant it mounts.
//!
//! ### Where the signals come from (all measured, 2026-07-26)
//!
//! The one structural fact everything below depends on: **the ADE reads
//! tmux's re-rendered stream, not the engine's own output.** That matters more
//! than it sounds. Claude Code's raw PTY output is *word-addressed* — its
//! "Running 1 shell command" line goes out as
//! `Running\x1b[11G1\x1b[13Gshell\x1b[19Gcommand…`, with a cursor-position
//! escape between every word — so plain substring matching against the raw
//! engine stream would match essentially nothing. tmux maintains its own
//! screen model and re-emits contiguous runs of text, which is why the marker
//! matching here works at all. Verified both ways against real `claude`
//! 2.1.220: the same marker that matches through tmux fails on the direct
//! stream.
//!
//! - **awaiting_approval (amber)** — the existing `ATTENTION_MARKERS` match
//!   (`"Do you want to"`), verified still contiguous through tmux:
//!   `" Do you want to create \x1b[1mnotes.txt\x1b(B\x1b[m?"`. Latched by the
//!   reader thread the moment the marker appears, cleared when the user next
//!   writes (answering is the only "handled" signal a stock engine gives).
//!   This latch reads the *raw* match, not the [`AttentionDebouncer`]-gated
//!   event: the debouncer exists to stop a redraw storm becoming 100
//!   notifications, but a status latch has no such problem, and using the
//!   debounced signal would mean a second prompt inside the 15 s cooldown
//!   never turned the light amber again. A pending prompt was measured
//!   repainting the full screen ~1.9×/s (17 repaints while one sat unanswered
//!   for 9 s), which is exactly why [`ATTENTION_INPUT_GRACE`] exists.
//! - **error (red)** — [`contains_error_marker`]: a non-zero `Exit code N`
//!   report, the line Claude Code renders for a failed Bash tool. The stream
//!   scan latches it; with tmux the **live pane is then the authority**
//!   ([`resolve_error`]), which is what keeps red from becoming permanent —
//!   the engine repaints constantly and every repaint re-delivers the same
//!   failure line, so a stream-only latch went red again within seconds of
//!   every acknowledgement, for the rest of the session. Instead the latch is
//!   held while the line is visible, suppressed once the user has typed, and
//!   released outright when the line scrolls off the pane. Note that
//!   Claude renders this **differently at different terminal widths** —
//!   inline with the digit adjacent at 120 columns, as a colon-label with the
//!   value bolded (an SGR escape between label and digit) at the 80 columns an
//!   ADE pane actually opens at — which is why the match is a label plus an
//!   escape-skipping value check rather than a plain `contains`. See
//!   [`ERROR_MARKER`] for both captures and for the live-run round that found
//!   it, and [`ATTENTION_INPUT_GRACE`] for the second live-run correction
//!   that made the two graces the same length.
//! - **tool_execution (cyan), `shell` sessions with tmux (the good case)** —
//!   the pane foreground-command signal, which the terminal host derives
//!   from the pane tty's foreground process group. Reads `zsh` at the prompt →
//!   **ready**; reads `sleep`/`cargo`/`vim`/… → **tool_execution**, because for
//!   a terminal session "a foreground command is running" *is* Bruno's cyan.
//!   Verified against real tmux including `sleep 4`, the case that produces no
//!   output at all and that therefore no activity heuristic could ever catch.
//! - **thinking (white/blue), `claude`/`codex`** — the foreground command is
//!   useless here (a real claude pane reports `2.1.220`, the process title
//!   Claude Code sets, and keeps reporting it while a tool runs), so these
//!   fall back to **sustained output activity**: output within
//!   [`OUTPUT_QUIET_THRESHOLD`] *and* an unbroken run already
//!   [`SUSTAINED_ACTIVITY_MIN`] long. The second condition is not decoration —
//!   see [`SUSTAINED_ACTIVITY_MIN`] for the idle-strobe measurement it comes
//!   from. Measured as fit for purpose here too: during a real Claude Bash
//!   tool run, the largest gap between output chunks was 0.23 s (p95 0.115 s),
//!   comfortably inside the 700 ms threshold, so a working engine never
//!   flickers to green mid-turn.
//! - **tool_execution (cyan), `claude`/`codex`** — the hard one, and the one
//!   place this deliberately does *less* than the brief. A busy engine is
//!   refined from `thinking` to `tool_execution` only when `tmux capture-pane`
//!   shows [`TOOL_EXECUTION_SCREEN_MARKERS`] on the live screen. Screen state,
//!   not stream events, precisely because a running tool is a state that ends
//!   and a latch would leave cyan stuck on. See that constant for the four
//!   candidate signals that were measured and rejected (including the
//!   process-tree approach, which real sampling showed is swamped by
//!   hook/status-line/MCP-server children).
//! - **without tmux** — every engine, including `shell`, falls back to the
//!   output-activity heuristic, and `claude`/`codex` can never reach
//!   `tool_execution` at all (no `capture-pane`). For `shell` the fallback is
//!   genuinely worse (a silent long-running command looks idle); it is the
//!   price of not having tmux, and one more reason the tmux path is the
//!   default.
//!
//! ### What does *not* fire, stated plainly
//!
//! A light the user will never see is worth naming as such:
//!
//! - **`error` for a `shell` session: never.** A failed command's exit status
//!   is genuinely unobtainable here without violating DESIGN principle 5.
//!   Investigated concretely against tmux 3.7b: `#{pane_dead_status}` is empty
//!   for a live pane (`pane_dead=0`) and only ever reports the *pane's root
//!   process* exit under `remain-on-exit on` — i.e. the shell itself dying,
//!   not a command inside it — and no other tmux format variable exposes a
//!   command exit status (`display-message -a` lists none). The standard
//!   robust answer is shell integration: a `precmd`/`PROMPT_COMMAND` hook
//!   reporting `$?`, or OSC 133 semantic prompt marks. Every route to it
//!   changes how the user's shell starts — editing their rc files (persistent,
//!   plainly out), or pointing `ZDOTDIR` at a directory we own (per-invocation,
//!   but it makes the shell start from *our* config instead of theirs, which
//!   is precisely "the engine no longer runs exactly as in a plain terminal").
//!   Ruled out. A `shell` session therefore has four reachable states, not
//!   five, and red is not one of them.
//! - **`thinking` for a `shell` session: never**, and correctly so — a shell
//!   does not think. Sustained output from a shell means a command is running,
//!   which is cyan.
//! - **`tool_execution` for `claude`/`codex` without tmux: never** (no
//!   `capture-pane`), and **only for Bash tools running longer than ~3 s** with
//!   tmux. Sub-3s tool calls and in-process tools (a file write) read as
//!   `thinking`. Less specific, never wrong.
//! - **`error` for `claude`/`codex`** covers a failed *tool* only. API errors,
//!   rate limits and refusals were not reproducible on demand and are not
//!   claimed. One further known hole, stated rather than papered over: once a
//!   failure has been acknowledged, a *second* failure occurring while the
//!   first is still visible on the pane is missed, because the suppression is
//!   "this pane still shows a failure the user answered for", not "this exact
//!   failure". Closing it would mean counting occurrences across repaints for
//!   a case that resolves itself as soon as the first line scrolls away.
//! - **`error` without tmux** falls back to a plain latch cleared by the next
//!   user write — no pane to reconcile against. Weaker, and the reason the
//!   tmux path is the default.
//!
//! Polling is centralized in one background thread ([`spawn_status_poller`])
//! at [`STATUS_POLL_INTERVAL`], not one thread per session, and it only emits
//! on an actual state *change* — never a per-frame firehose.
//!
//! ## Making CLIs render color (founder bug, 2026-07-25 — Bruno, verbatim:
//! ## "Can you fix the colors of the terminals? It's currently black and
//! ## white... I like when it's colorful just like claude normally is.")
//! `Terminal.tsx`'s xterm.js `theme` option already has the real, correct
//! ANSI 0-15 palette (sourced from Warp's own bundled theme data) — that
//! was never the bug. The actual cause is the same class of "GUI launch
//! doesn't inherit what a real terminal session would" gap the `PATH` fix
//! above exists for: `CommandBuilder::new` seeds a spawned command's env
//! from whatever THIS process itself inherited at construction time (see
//! `portable_pty::cmdbuilder::get_base_env`), and a `.app` launched via
//! Finder/`open` has no `TERM` at all (no controlling terminal) — unlike
//! `cargo tauri dev` run from an already-interactive shell, which is why
//! this, too, never reproduced outside the packaged app. CLIs like `claude`
//! detect color-capability partly from `TERM`/`COLORTERM`; a missing/absent
//! `TERM` commonly makes them fall back to plain monochrome output — which
//! looks exactly like "black and white" no matter how correct xterm.js's
//! own rendering theme is, since there are no color escape codes in the
//! byte stream for it to render in the first place. Verified for real: a
//! `shell` session running `TERM=dumb tput setaf 1` (a command that emits
//! an ANSI color escape only when the terminfo it's given actually supports
//! color) prints nothing but a `tput: unknown terminal "dumb"`-style error
//! to the pty and no escape bytes at all, whereas the same session with
//! this fix's `TERM=xterm-256color` applied prints the real
//! `\x1b[31m` escape sequence — a genuine before/after byte-level
//! difference, not just "the env var is set in code" (see this task's own
//! commit message / report for the exact transcript).
//!
//! [`apply_terminal_capability_env`] sets `TERM=xterm-256color` (the exact
//! terminal type xterm.js + its WebGL addon actually implement) and
//! `COLORTERM=truecolor` (the de facto signal modern CLIs, including
//! `claude`, check for 24-bit color) on every engine's spawned command,
//! unconditionally — unlike `PATH`, there's no real, discoverable "user's
//! actual value" to resolve here (a GUI launch's `TERM` isn't merely wrong,
//! it's absent), so the fix is to always assert the exact capability this
//! app's own terminal renderer supports rather than to propagate whatever
//! (if anything) this process happened to inherit. Applied to all three
//! engines (`claude`, `codex`, `shell`), same reasoning `apply_resolved_path`
//! above already gives for extending PATH resolution to `shell` too: this is
//! a terminal-capability signal every spawned interactive process benefits
//! from, not an engine-specific behavior — the engines themselves stay
//! completely stock, only the env OmniAgent's own spawn call hands them
//! changes (DESIGN principle 5).
//!
//! ## The two things a GUI-launched pane was still missing (founder bug,
//! ## 2026-07-26)
//! Bruno opened a claude session in the packaged app and got a working
//! banner drawn in mojibake, over three `SessionStart:startup hook error /
//! /bin/sh: node: command not found`. Both halves are the same empty-GUI-
//! environment story as `PATH` and `TERM` above, one layer further out —
//! what the *engine's own children* inherit:
//!
//! - **`PATH` never reached the pane.** `-e PATH=…` sets the tmux *session*
//!   environment (`show-environment` shows it) but a pane's `PATH` comes
//!   from the tmux **client** that ran `new-session` — measured three ways
//!   in `crate::tmux`'s module docs #4a. The pane therefore ran on
//!   `/usr/bin:/bin:/usr/sbin:/sbin`: `claude` itself started (it's passed
//!   as an absolute path — [`resolve_engine_binary`]), but every `node`,
//!   `git`, `gh` or `npm` it shelled out to was unfindable. Fixed in
//!   [`crate::tmux::Tmux::ensure_session`] by setting the env on the
//!   `new-session` command itself, not only as `-e` pairs.
//! - **No locale at all.** tmux decides UTF-8 mode from
//!   `LC_ALL`/`LC_CTYPE`/`LANG`; with none set, every ADE client reported
//!   `#{client_utf8}` = 0 and `capture-pane` returned invalid UTF-8, which
//!   is why claude's `──` frame arrived as `‚îÄ‚îÄ`. Filled by
//!   [`utf8_locale_override`], on the same "assert what the renderer
//!   supports" principle as `TERM`.

use std::collections::{HashMap, VecDeque};
use std::fs::OpenOptions;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{mpsc, Arc, Mutex, OnceLock, Weak};
use std::thread;
use std::time::{Duration, Instant};

use anyhow::{anyhow, Context, Result};
use serde::Serialize;
use uuid::Uuid;

use brain_core::now_ts;
#[cfg(test)]
use brain_core::redact::redact;
#[cfg(test)]
use portable_pty::{native_pty_system, Child, CommandBuilder, PtySize};

use crate::daemon::{self, DaemonEvent, DaemonSessions};

/// A callback invoked with `(session_id, raw_chunk)` for every chunk read
/// from a session's PTY, in real time, un-redacted (this is the "live
/// terminal" feed — redaction only applies to the on-disk transcript, see
/// module docs). The Tauri wrapper in `lib.rs` supplies one that calls
/// `app_handle.emit(&format!("session-output:{id}"), chunk)`;
/// tests supply one that pushes to an `mpsc` channel.
pub type OutputSink = Arc<dyn Fn(&str, &[u8]) + Send + Sync>;

/// Everything Phase 7's feedback loop needs to know about a session that
/// just ended — the argument to [`SessionEndHook`]. Fired once per session,
/// whichever way it ended (see [`SessionManager::kill`] and the natural-exit
/// path in the daemon event handler), always *after* the transcript's final
/// flush is guaranteed on disk (same ordering guarantee `kill()` already
/// gives its callers for the transcript file itself — see the module docs
/// on `SessionHandle::reader_thread`), so `event.transcript_path` is always
/// safe to read in full by the time a hook observes it.
#[derive(Debug, Clone, Serialize)]
pub struct SessionEndEvent {
    pub id: String,
    pub project: String,
    pub cwd: String,
    pub engine: String,
    pub transcript_path: PathBuf,
}

/// Invoked once per ended session — the hook point PLAN.md's Task 7.1 names
/// ("extend `sessions.rs`'s kill/exit path"). `lib.rs` wires this at boot
/// (via [`SessionManager::with_end_hook`]) to `feedback::on_session_end`,
/// which enqueues the `session_summary` enrichment job; plain
/// `SessionManager::new` callers (most existing tests) get no hook at all —
/// this is additive, not a required wiring step for every caller.
pub type SessionEndHook = Arc<dyn Fn(&SessionEndEvent) + Send + Sync>;

/// Invoked with just the session id when the PTY reader thread decides a
/// live session needs the user's attention (see the module docs' "Attention
/// detection" section for what triggers this and why). `lib.rs` wires this
/// at boot to emit `session-attention:{id}`, matching the existing
/// `session-output:{id}` naming convention; tests supply one that pushes to
/// a channel. Already debounced per session ([`AttentionDebouncer`]) by the
/// time this is called — callers don't need their own rate limiting.
pub type AttentionSink = Arc<dyn Fn(&str) + Send + Sync>;

/// The five-state session light Bruno specified (2026-07-26), replacing the
/// original three. His words, mapped to these variants:
///
/// | Founder's colour | Founder's meaning | Variant |
/// |---|---|---|
/// | White/Blue, pulsing gradient | "thinking, reasoning, or generating tokens" | [`Thinking`](Self::Thinking) |
/// | Green, solid steady | "a task completed successfully and results are ready or just waiting for input" | [`Ready`](Self::Ready) |
/// | Amber/Yellow, breathing | "paused, waiting for your approval" | [`AwaitingApproval`](Self::AwaitingApproval) |
/// | Red/Magenta, rapid flashing | "an error occurred, a process failed, or a block exists" | [`Error`](Self::Error) |
/// | Cyan/Teal, rapid chasing | "active tool execution, like terminal commands or file writes" | [`ToolExecution`](Self::ToolExecution) |
///
/// Serialized `snake_case` (`"thinking"` / `"ready"` / `"awaiting_approval"` /
/// `"error"` / `"tool_execution"`); those strings are the wire contract, in
/// both the `session-status:{id}` event payload ([`SessionStatusEvent`]) and
/// the `session_status` command's return value. Self-describing rather than
/// colour-named on purpose: the colour is a rendering decision the frontend
/// owns, and a backend that emitted `"amber"` would freeze it.
///
/// **Read the module docs' "Five-state session status" section before
/// rendering any of these.** Two of the five are approximations, and
/// `ToolExecution` is deliberately narrower for `claude`/`codex` than its name
/// suggests. That section states exactly what is measured, what is inferred,
/// and what never fires.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum SessionStatus {
    /// Green — idle, nothing running, waiting for the user.
    Ready,
    /// White/blue — the engine is working and isn't visibly running a tool:
    /// generating tokens, reasoning, calling the model.
    Thinking,
    /// Cyan — a real command/tool is executing (a shell session's foreground
    /// process, or a Claude Code Bash tool that is visibly still running).
    ToolExecution,
    /// Amber — paused on the user's approval (a Claude Code tool-permission
    /// prompt).
    AwaitingApproval,
    /// Red — something failed (a non-zero tool exit reported by the engine).
    Error,
}

impl SessionStatus {
    pub fn as_str(self) -> &'static str {
        match self {
            SessionStatus::Ready => "ready",
            SessionStatus::Thinking => "thinking",
            SessionStatus::ToolExecution => "tool_execution",
            SessionStatus::AwaitingApproval => "awaiting_approval",
            SessionStatus::Error => "error",
        }
    }

    /// Whether reaching this state is worth interrupting the user for —
    /// **the single source of truth for the notifications layer**, so the
    /// frontend never re-derives the rule (and never drifts from it).
    ///
    /// Bruno, 2026-07-26, verbatim: *"only green, yellow or red generate a
    /// notification (in case the user is somewhere else (maybe not in that
    /// terminal) or in another session or even workspace)."* — i.e. the three
    /// states that mean *something has settled and it's your turn again*:
    /// [`Ready`](Self::Ready) (done),
    /// [`AwaitingApproval`](Self::AwaitingApproval) (needs a decision),
    /// [`Error`](Self::Error) (needs a look).
    ///
    /// [`Thinking`](Self::Thinking) and [`ToolExecution`](Self::ToolExecution)
    /// are transient working states the user can watch if they care; notifying
    /// on them would fire every few seconds during ordinary work and train the
    /// user to ignore the channel entirely.
    ///
    /// Pure and total — a `match` with no wildcard arm, so adding a sixth
    /// state later fails to compile here rather than silently defaulting to
    /// "don't notify".
    pub fn notifies(self) -> bool {
        match self {
            SessionStatus::Ready | SessionStatus::AwaitingApproval | SessionStatus::Error => true,
            SessionStatus::Thinking | SessionStatus::ToolExecution => false,
        }
    }
}

/// The payload of a `session-status:{id}` event, and what
/// `commands::session_status` returns — one shape for push and pull, so a pane
/// that just mounted and a pane reacting to a transition read the same fields.
///
/// **On what's in here and what isn't.** `notify` is carried rather than left
/// for the frontend to recompute: it makes [`SessionStatus::notifies`] the one
/// place Bruno's rule lives, and a notifications panel can act on the event
/// without knowing the taxonomy at all. `engine` is carried because a
/// notification that says *which kind of session* wants you ("Claude needs
/// approval" vs "a terminal finished") is materially more useful than a bare
/// id, and it is free — the status poller already holds it.
///
/// `project` and the tab title deliberately are **not** carried. The frontend
/// already owns that mapping in its tab state, and both are *mutable*
/// (`roots::rename_project` exists) — a copy shipped inside every status event
/// would be a second, staleable source of truth for something the UI can
/// already resolve from the session id it is rendering.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct SessionStatusEvent {
    /// The session this is about. Redundant with the per-session event name,
    /// and kept anyway: it makes the payload self-contained for a single
    /// shared listener, a notifications queue, or a log line.
    pub id: String,
    pub status: SessionStatus,
    /// `status.notifies()`, precomputed. See [`SessionStatus::notifies`].
    pub notify: bool,
    /// `"claude"` / `"codex"` / `"shell"` — context for the notification text.
    pub engine: String,
}

impl SessionStatusEvent {
    fn new(id: &str, status: SessionStatus, engine: &str) -> Self {
        Self {
            id: id.to_string(),
            status,
            notify: status.notifies(),
            engine: engine.to_string(),
        }
    }
}

/// Invoked with the full [`SessionStatusEvent`] whenever a session's light
/// actually *changes* — never on every poll. `lib.rs` wires this at boot to
/// emit `session-status:{id}`, matching the existing
/// `session-output:{id}`/`session-attention:{id}` convention; tests supply
/// one that pushes to a channel. Registering it (via
/// [`SessionManager::with_status_sink`]) is also what starts the single
/// background poller — with no sink registered, nothing polls and status is
/// only ever computed on demand.
pub type StatusSink = Arc<dyn Fn(&SessionStatusEvent) + Send + Sync>;

/// Public shape returned by `session_create` — the Task 5.2 UI contract,
/// plus the two 2026-07-26 persistence flags.
#[derive(Debug, Clone, Serialize)]
pub struct SessionInfo {
    pub id: String,
    pub project: String,
    pub engine: String,
    pub cwd: String,
    pub created: i64,
    /// `true` when this call attached to an **already-running** engine
    /// (a tmux session that outlived the app closing) rather than starting a
    /// new one. The frontend can use it to skip a "starting…" placeholder, or
    /// to tell the user their session came back.
    pub restored: bool,
    /// `true` when this session is tmux-backed and will therefore survive the
    /// app closing. `false` means tmux wasn't available and this is a plain
    /// direct spawn (see the module docs' degradation ladder).
    pub persistent: bool,
}

/// Input to [`SessionManager::create`]. `engine` must be `"claude"`,
/// `"codex"`, or `"shell"`. `briefing`, when `Some`, is forwarded verbatim
/// to `claude --append-system-prompt` — this module does not generate or
/// interpret its contents (that's Task 5.2 / `get_context`'s job).
#[derive(Debug, Clone, Default, Serialize)]
pub struct CreateSessionRequest {
    pub project: String,
    pub engine: String,
    pub cwd: String,
    pub briefing: Option<String>,
    /// The id this session had before the app was closed — the whole
    /// mechanism behind "come back to the session you left" (module docs,
    /// "Session persistence via tmux").
    ///
    /// `None` (the default, and every path except layout restore) → a fresh
    /// id is minted and a fresh engine starts, exactly as before. `Some(id)`
    /// → that id is reused verbatim, which means the same tmux session name,
    /// the same transcript file, and — if the tmux session is still alive —
    /// an attach to the still-running engine instead of a new one.
    ///
    /// Validated by [`is_valid_session_id`] before use: it reaches the
    /// filesystem (`<id>.log`) and a tmux target, so an arbitrary string from
    /// the frontend is rejected rather than sanitized into something
    /// surprising.
    pub restore_id: Option<String>,
}

/// Everything needed to keep one live PTY session going.
struct SessionHandle {
    /// Temp `--mcp-config` file for `claude` sessions, if any; removed on
    /// kill/natural-exit cleanup.
    mcp_config_path: Option<PathBuf>,
    /// Carried from the original `CreateSessionRequest` purely so
    /// [`SessionManager::kill`] can build a [`SessionEndEvent`] without a
    /// second lookup once the handle's already been removed from the
    /// registry (see `kill`'s body) — nothing PTY-related reads these.
    project: String,
    cwd: String,
    engine: String,
    daemon_session: String,
    attached: bool,
    killing: Arc<AtomicBool>,
    output: Arc<Mutex<SessionOutputProcessor>>,
    display: Arc<SessionDisplay>,
    /// Live signals the status poller reads. Shared with the reader thread,
    /// which is what actually writes to them.
    activity: Arc<SessionActivity>,
}

const MAX_PENDING_DISPLAY_BYTES: usize = 1024 * 1024;

struct SessionDisplay {
    id: String,
    sink: OutputSink,
    state: Mutex<SessionDisplayState>,
}

struct SessionDisplayState {
    ready: bool,
    ended: bool,
    overflowed: bool,
    pending: VecDeque<Vec<u8>>,
    pending_bytes: usize,
}

struct DisplayReady {
    ended: bool,
    needs_snapshot: bool,
}

impl SessionDisplay {
    fn new(id: String, sink: OutputSink) -> Self {
        Self {
            id,
            sink,
            state: Mutex::new(SessionDisplayState {
                ready: false,
                ended: false,
                overflowed: false,
                pending: VecDeque::new(),
                pending_bytes: 0,
            }),
        }
    }

    fn receive(&self, bytes: &[u8]) {
        let mut state = self.state.lock().unwrap();
        if state.ready {
            drop(state);
            (self.sink)(&self.id, bytes);
            return;
        }
        state.pending.push_back(bytes.to_vec());
        state.pending_bytes = state.pending_bytes.saturating_add(bytes.len());
        while state.pending_bytes > MAX_PENDING_DISPLAY_BYTES {
            let Some(dropped) = state.pending.pop_front() else {
                break;
            };
            state.pending_bytes = state.pending_bytes.saturating_sub(dropped.len());
            state.overflowed = true;
        }
    }

    fn mark_ready(&self) -> DisplayReady {
        let (pending, ended, needs_snapshot) = {
            let mut state = self.state.lock().unwrap();
            state.ready = true;
            state.pending_bytes = 0;
            let ended = state.ended;
            let needs_snapshot = state.overflowed && !ended;
            state.overflowed = false;
            let pending = if needs_snapshot {
                state.pending.clear();
                VecDeque::new()
            } else {
                std::mem::take(&mut state.pending)
            };
            (pending, ended, needs_snapshot)
        };
        for bytes in pending {
            (self.sink)(&self.id, &bytes);
        }
        DisplayReady {
            ended,
            needs_snapshot,
        }
    }

    fn mark_ended(&self) -> bool {
        let mut state = self.state.lock().unwrap();
        state.ended = true;
        state.ready
    }
}

/// The per-session signals the traffic light is computed from — written by
/// the PTY reader thread, read by [`spawn_status_poller`] and
/// [`SessionManager::status`].
///
/// Held behind an `Arc` and cloned into the reader thread rather than looked
/// up through the session registry, specifically so the reader thread never
/// has to take the registry lock on the hot per-chunk path (which would put
/// it in contention with every `write`/`resize`/`create` on every 8 KiB of
/// output).
struct SessionActivity {
    /// Copied from the request so the poller can pick the right heuristic
    /// without a second lookup.
    engine: String,
    /// `None` for a direct (non-daemon) spawn — which is also exactly the
    /// condition that forces the output-activity heuristic for every engine.
    daemon_session: Option<String>,
    /// When the PTY last produced any bytes.
    last_output: Mutex<Instant>,
    /// When the user last typed into this session ([`SessionManager::write`]).
    /// `None` until they first do.
    ///
    /// Exists because the engines echo: every keystroke makes a `claude`/
    /// `codex` TUI repaint its input box, so a person typing a prompt IS
    /// "sustained output" to the activity heuristic, and the light (and since
    /// 2026-07-26, the whole pane border) lit up as busy while they typed.
    /// Founder, verbatim: "I also don't want the executing effect to be
    /// triggered when I'm typing." [`status_from_output_activity`] therefore
    /// refuses to call the session busy within [`TYPING_ECHO_GRACE`] of the
    /// last keystroke — see that constant for the trade-off.
    last_user_input: Mutex<Option<Instant>>,
    /// What the activity heuristic said at the moment the current typing
    /// burst BEGAN — `Some(busy status)` if the session was already visibly
    /// working, `None` if it was quiet. The typing grace returns this
    /// instead of forcing `Ready` (founder, 2026-07-26, second round: "it
    /// shouldn't change the status based on whether I'm hovering or typing.
    /// And whenever I do it, it turns into green. I don't like it.").
    ///
    /// Snapshotted only on a burst's FIRST keystroke ([`SessionActivity::
    /// mark_user_input`]): re-sampling on every keystroke would let the
    /// burst's own echo — which sustains a run past
    /// [`SUSTAINED_ACTIVITY_MIN`] under continuous typing — promote itself
    /// to busy mid-burst, which is the original bug this grace exists for.
    status_when_typing_began: Mutex<Option<SessionStatus>>,
    /// When the *current* run of continuous output began — reset whenever a
    /// gap longer than [`OUTPUT_QUIET_THRESHOLD`] breaks the run. Together
    /// with `last_output` this distinguishes "genuinely busy" from "an idle
    /// TUI twitched": see [`SUSTAINED_ACTIVITY_MIN`].
    busy_since: Mutex<Option<Instant>>,
    /// Latched by the reader thread on an [`ATTENTION_MARKERS`] hit; cleared
    /// by [`SessionManager::write`] (the user answering). Deliberately driven
    /// by the raw match rather than the debounced event — see the module docs.
    attention: AtomicBool,
    /// Latched by the reader thread on an [`ERROR_MARKER`] hit (a non-zero
    /// tool exit the engine printed); cleared by [`SessionManager::write`],
    /// same as `attention` and for the same reason — the user typing is the
    /// only "I've seen it" signal a stock engine gives us.
    ///
    /// A latch and not a screen-state check on purpose: a failure is an
    /// *event*, and Bruno's red means "an error occurred", not "an error is
    /// currently visible". The engine happily carries on afterwards (it will
    /// often narrate the failure and try something else), so without a latch
    /// the red would flash by in one poll tick and be missed by anyone not
    /// staring at the tab — which is exactly the person the notification is
    /// for.
    error: AtomicBool,
    /// The user has typed since `error` latched — they've seen the failure and
    /// moved on — but the failure line is still sitting on the pane.
    ///
    /// This exists because clearing the latch on write is *not enough*, and
    /// that was measured rather than predicted: driving a real `claude`
    /// through a failed tool and then continuing the conversation, the light
    /// went red again 3 s later, and again after that, because the engine
    /// repaints the whole pane constantly and every repaint re-delivers the
    /// same `Exit code: 1` line as genuinely new output. Red ended up latched
    /// permanently, drowning out every other state for the rest of the
    /// session (observed live: `ready → error → error → error`, final status
    /// `Error`).
    ///
    /// So for tmux-backed sessions the *screen* is the authority, not the
    /// stream: the latch stays set while the failure is visible, this flag
    /// suppresses it once the user has moved on, and
    /// [`compute_status`] drops both the moment the line scrolls off the pane
    /// — at which point a genuinely new failure can latch again. Without tmux
    /// there is no screen to consult, so [`SessionActivity::mark_user_input`]
    /// falls back to clearing the latch outright.
    error_dismissed: AtomicBool,
    /// Set by [`SessionManager::write`], consumed by the reader thread on its
    /// next chunk: discard the rolling marker window before scanning.
    ///
    /// Without this, clearing the latch above achieves nothing. The marker
    /// isn't a momentary event — it sits in a 4 KiB rolling window of recent
    /// output ([`ATTENTION_WINDOW_BYTES`]) — so the very next byte of output
    /// after the user answers re-scans that same window, re-matches the
    /// *old* prompt text, and instantly re-latches red. Caught by
    /// `attention_marker_turns_the_light_red_and_writing_clears_it`, which
    /// failed exactly this way before this existed.
    ///
    /// Clearing the window is also the semantically right rule: text printed
    /// *before* the user responded is no longer evidence of a pending
    /// prompt. Only output produced *after* their input can turn the light
    /// red again — which a genuinely still-pending prompt does immediately,
    /// since it redraws itself (marker included) roughly twice a second.
    clear_marker_window: AtomicBool,
    /// Last status handed to the [`StatusSink`] (or returned by
    /// [`SessionManager::status`]), so the poller can emit on change only.
    last_status: Mutex<Option<SessionStatus>>,
    /// Whether anything is actually consuming status for this session. When
    /// false the reader thread skips the attention scan entirely (unless an
    /// [`AttentionSink`] wants it), keeping the no-sink path exactly as cheap
    /// as it was before this feature existed.
    status_tracking: bool,
}

impl SessionActivity {
    fn new(engine: String, daemon_session: Option<String>, status_tracking: bool) -> Self {
        Self {
            engine,
            daemon_session,
            last_output: Mutex::new(Instant::now()),
            last_user_input: Mutex::new(None),
            status_when_typing_began: Mutex::new(None),
            busy_since: Mutex::new(None),
            attention: AtomicBool::new(false),
            error: AtomicBool::new(false),
            error_dismissed: AtomicBool::new(false),
            clear_marker_window: AtomicBool::new(false),
            last_status: Mutex::new(None),
            status_tracking,
        }
    }

    /// The user just typed into this session: stop holding either marker state
    /// (approval and error) on their behalf, and tell the reader thread to
    /// forget the output that produced them.
    ///
    /// Both respond to the same signal because there is no way to tell "the
    /// user answered the prompt" apart from "the user acknowledged the
    /// failure" — a stock engine reports neither. Typing is the only evidence
    /// either way.
    ///
    /// The two are *released* differently, though, and that asymmetry is the
    /// whole point of [`SessionActivity::error_dismissed`]. Approval clears
    /// outright: answering a prompt makes it leave the screen, so if the
    /// marker shows up again it really is a new prompt. A failure line does
    /// **not** leave the screen when acknowledged — it stays in the
    /// conversation — so clearing outright just means the next repaint
    /// re-latches it (measured: red became permanent). With tmux, the latch is
    /// therefore kept and merely marked dismissed, and [`compute_status`]
    /// releases it when the line actually scrolls off the pane. Without tmux
    /// there is no screen to ask, so the write is all we have and the latch is
    /// cleared the old way.
    fn mark_user_input(&self) {
        let now = Instant::now();
        if let Ok(mut last) = self.last_user_input.lock() {
            // A burst's first keystroke (nothing typed within the grace)
            // freezes what the light currently says; every keystroke after
            // it merely re-arms the grace. See `status_when_typing_began`.
            let new_burst =
                last.is_none_or(|t| now.saturating_duration_since(t) >= TYPING_ECHO_GRACE);
            if new_burst {
                if let Ok(mut held) = self.status_when_typing_began.lock() {
                    *held = self.raw_busy_status(now);
                }
            }
            *last = Some(now);
        }
        self.attention.store(false, Ordering::Relaxed);
        self.clear_marker_window.store(true, Ordering::Relaxed);
        if self.daemon_session.is_some() {
            // Only meaningful when there is a red light to acknowledge. A
            // write with nothing latched must not pre-dismiss a failure that
            // hasn't happened yet — which is exactly what it did in the first
            // draft, swallowing the failure of the very command the user had
            // just typed.
            if self.error.load(Ordering::Relaxed) {
                self.error_dismissed.store(true, Ordering::Relaxed);
            }
        } else {
            self.error.store(false, Ordering::Relaxed);
        }
    }

    /// The activity heuristic's raw answer, grace-free: `Some(busy status)`
    /// when output is both recent ([`OUTPUT_QUIET_THRESHOLD`]) and part of a
    /// sustained run ([`SUSTAINED_ACTIVITY_MIN`]), `None` when the session is
    /// quiet. The shared core of [`status_from_output_activity`] (which lays
    /// the typing grace over it) and the burst snapshot in
    /// [`SessionActivity::mark_user_input`] (which must ignore the grace —
    /// it's asking what was true as the typing began).
    fn raw_busy_status(&self, now: Instant) -> Option<SessionStatus> {
        let last = self
            .last_output
            .lock()
            .map(|g| *g)
            .unwrap_or_else(|e| *e.into_inner());
        if now.saturating_duration_since(last) >= OUTPUT_QUIET_THRESHOLD {
            return None;
        }
        let busy_since = self
            .busy_since
            .lock()
            .map(|g| *g)
            .unwrap_or_else(|e| *e.into_inner());
        match busy_since {
            Some(started) if now.saturating_duration_since(started) >= SUSTAINED_ACTIVITY_MIN => {
                Some(busy_status_for_engine(&self.engine))
            }
            _ => None,
        }
    }

    /// Called by the reader thread for every chunk off the PTY. Keeps both
    /// halves of the activity signal current: when output last arrived, and
    /// when the unbroken run it belongs to started.
    fn mark_output(&self) {
        let now = Instant::now();
        let gap = match self.last_output.lock() {
            Ok(mut last) => {
                let gap = now.saturating_duration_since(*last);
                *last = now;
                gap
            }
            Err(_) => return,
        };
        if let Ok(mut busy) = self.busy_since.lock() {
            // A gap longer than the quiet threshold ended the previous run,
            // so this chunk starts a new one.
            if busy.is_none() || gap >= OUTPUT_QUIET_THRESHOLD {
                *busy = Some(now);
            }
        }
    }
}

struct SessionOutputProcessor {
    decoder: Utf8ChunkDecoder,
    marker_window: String,
    attention_debouncer: AttentionDebouncer,
    last_user_input: Option<Instant>,
}

impl SessionOutputProcessor {
    fn new() -> Self {
        Self {
            decoder: Utf8ChunkDecoder::new(),
            marker_window: String::new(),
            attention_debouncer: AttentionDebouncer::new(ATTENTION_COOLDOWN),
            last_user_input: None,
        }
    }
}

/// The PTY session registry. One instance lives for the app's lifetime
/// (managed Tauri state in `lib.rs`); tests construct their own with a
/// scratch data dir and an in-memory sink.
pub struct SessionManager {
    data_dir: PathBuf,
    sink: OutputSink,
    sessions: Arc<Mutex<HashMap<String, SessionHandle>>>,
    /// Display bytes are held separately from lifecycle handles so an
    /// immediately-exiting session can still flush its final snapshot after
    /// the frontend registers `session-output:{id}` and performs its first
    /// resize. Lifecycle cleanup never waits for that renderer readiness.
    displays: Arc<Mutex<HashMap<String, Arc<SessionDisplay>>>>,
    /// Phase 7 feedback-loop hook, `None` by default (see [`SessionEndHook`]
    /// and [`SessionManager::with_end_hook`]).
    on_end: Option<SessionEndHook>,
    /// Founder-feedback attention hook, `None` by default (see
    /// [`AttentionSink`] and [`SessionManager::with_attention_sink`]).
    on_attention: Option<AttentionSink>,
    /// Traffic-light hook, `None` by default (see [`StatusSink`] and
    /// [`SessionManager::with_status_sink`]). Registering it also starts the
    /// single background poller.
    on_status: Option<StatusSink>,
    /// The sole PTY/process owner. `None` means session creation is unavailable.
    daemon_sessions: Option<DaemonSessions>,
    /// Guards the lazy, at-most-once spawn of the status poller (see
    /// [`SessionManager::with_status_sink`] for why it isn't spawned eagerly).
    status_poller: OnceLock<()>,
}

impl SessionManager {
    pub fn new(data_dir: PathBuf, sink: OutputSink) -> Self {
        let _ = std::fs::create_dir_all(transcripts_dir(&data_dir));
        Self {
            data_dir,
            sink,
            sessions: Arc::new(Mutex::new(HashMap::new())),
            displays: Arc::new(Mutex::new(HashMap::new())),
            on_end: None,
            on_attention: None,
            on_status: None,
            daemon_sessions: None,
            status_poller: OnceLock::new(),
        }
    }

    pub fn with_pty_daemon(mut self, client: DaemonSessions) -> Self {
        self.daemon_sessions = Some(client);
        self
    }

    /// Builder-style setter for daemon-backed persistence — the same additive
    /// shape (and the same reasoning) as [`with_end_hook`](Self::with_end_hook)
    /// and [`with_attention_sink`](Self::with_attention_sink): the daemon is
    /// app-level infrastructure wired once at boot in `lib.rs`
    /// ([`default_daemon_sessions`]), not a required constructor argument.
    /// Keeping it injectable gives tests a private daemon socket without
    /// changing production ownership.
    pub fn with_daemon_sessions(mut self, daemon_sessions: Option<DaemonSessions>) -> Self {
        self.daemon_sessions = daemon_sessions;
        self
    }

    /// Builder-style setter for the traffic-light hook (Bruno, 2026-07-26) —
    /// same additive shape as the hooks above.
    ///
    /// The background poller it implies is started lazily, on the first
    /// [`create`](Self::create), rather than here: that makes the builder
    /// calls order-independent (a poller spawned here would capture whatever
    /// `daemon_sessions` had been configured *so far*, silently degrading
    /// every status reading to the activity heuristic if a caller happened to
    /// write `.with_status_sink(…).with_daemon_sessions(…)`), and it means a
    /// manager that never opens a session never spawns a thread at all.
    pub fn with_status_sink(mut self, sink: StatusSink) -> Self {
        self.on_status = Some(sink);
        self
    }

    /// Builder-style setter for the Phase 7 feedback-loop hook. `lib.rs`
    /// calls this once at boot, after constructing the manager, to register
    /// `feedback::on_session_end`. Kept as a separate setter rather than a
    /// third `new()` parameter so every existing `SessionManager::new(...)`
    /// call site (this file's own tests, `session_test.rs`, ...) keeps
    /// compiling unchanged — the feedback loop is additive wiring, not a
    /// required constructor argument.
    pub fn with_end_hook(mut self, hook: SessionEndHook) -> Self {
        self.on_end = Some(hook);
        self
    }

    /// Builder-style setter for the founder-feedback attention hook —
    /// same additive shape as [`with_end_hook`](Self::with_end_hook) and for
    /// the same reason: every existing `SessionManager::new(...)` call site
    /// keeps compiling unchanged. `lib.rs` calls this once at boot to wire
    /// `session-attention:{id}` emission; most tests never call it, which
    /// makes the reader thread skip the (cheap but non-zero) detection work
    /// entirely — see [`process_daemon_output`].
    pub fn with_attention_sink(mut self, sink: AttentionSink) -> Self {
        self.on_attention = Some(sink);
        self
    }

    /// Creates (or adopts) a daemon-owned session, registers the Tauri-side
    /// compatibility metadata, and immediately subscribes to its daemon event
    /// stream. Display bytes remain buffered until the frontend's first
    /// resize/write proves its `session-output:{id}` listener is ready;
    /// lifecycle, status, attention, and exit processing start here.
    pub fn create(&self, req: CreateSessionRequest) -> Result<SessionInfo> {
        let (id, is_restore) = match req.restore_id.as_deref() {
            Some(rid) => {
                if !is_valid_session_id(rid) {
                    return Err(anyhow!(
                        "invalid restore_id {rid:?}: expected 1-{MAX_SESSION_ID_LEN} characters \
                         of [A-Za-z0-9_-] (it becomes a transcript filename and a tmux target)"
                    ));
                }
                (rid.to_string(), true)
            }
            None => (generate_session_id(), false),
        };
        if self.sessions.lock().unwrap().contains_key(&id) {
            return Err(anyhow!(
                "session {id} is already live in this app — restore_id must name a session \
                 from a *previous* run, not an open tab"
            ));
        }
        let created = now_ts();
        std::fs::create_dir_all(transcripts_dir(&self.data_dir))
            .context("create transcripts dir")?;
        let daemon = self
            .daemon_sessions
            .as_ref()
            .ok_or_else(|| anyhow!("PTY daemon is unavailable"))?;
        let daemon_name = daemon::session_name(&id);
        let restored = daemon
            .list()
            .map_err(|error| anyhow!(error))?
            .iter()
            .any(|session| session == &daemon_name);
        let engine_cmd = if restored {
            None
        } else {
            Some(build_engine_command(
                &req,
                &self.data_dir,
                &id,
                spawn_identity(&req.engine, is_restore, false),
            )?)
        };
        let mcp_config_path = engine_cmd
            .as_ref()
            .and_then(|command| command.mcp_config_path.clone());
        let mut mcp_cleanup_guard = McpConfigCleanupGuard::new(mcp_config_path.clone());
        if let Some(command) = engine_cmd {
            daemon
                .create_session(omniagent_pty_daemon::CreateSession {
                    id: daemon_name.clone(),
                    command: command.argv,
                    cwd: Some(command.cwd),
                    env: command.env.into_iter().collect(),
                    cols: 80,
                    rows: 24,
                    transcript_path: Some(transcript_path(&self.data_dir, &id)),
                })
                .map_err(|error| anyhow!(error))?;
        }

        append_lifecycle_event(
            &lifecycle_path(&self.data_dir, &id),
            &LifecycleEvent::Start {
                ts: created,
                engine: req.engine.clone(),
                project: req.project.clone(),
                cwd: req.cwd.clone(),
            },
        )
        .context("write start lifecycle event")?;

        let info = SessionInfo {
            id: id.clone(),
            project: req.project.clone(),
            engine: req.engine.clone(),
            cwd: req.cwd.clone(),
            created,
            restored,
            persistent: true,
        };

        let activity = Arc::new(SessionActivity::new(
            req.engine.clone(),
            Some(daemon_name.clone()),
            self.on_status.is_some(),
        ));
        let display = Arc::new(SessionDisplay::new(id.clone(), self.sink.clone()));
        let handle = SessionHandle {
            mcp_config_path,
            project: req.project.clone(),
            cwd: req.cwd.clone(),
            engine: req.engine.clone(),
            daemon_session: daemon_name.clone(),
            attached: false,
            killing: Arc::new(AtomicBool::new(false)),
            output: Arc::new(Mutex::new(SessionOutputProcessor::new())),
            display: Arc::clone(&display),
            activity,
        };

        self.displays.lock().unwrap().insert(id.clone(), display);
        self.sessions.lock().unwrap().insert(id, handle);
        if let Err(error) = self.ensure_attached(&info.id) {
            self.sessions.lock().unwrap().remove(&info.id);
            self.displays.lock().unwrap().remove(&info.id);
            if !restored {
                let _ = daemon.kill(&daemon_name);
            }
            return Err(error);
        }

        // Lazy, at-most-once: by now every builder has run, so the poller
        // sees the real daemon configuration (see `with_status_sink`).
        if let Some(status_sink) = &self.on_status {
            self.status_poller.get_or_init(|| {
                spawn_status_poller(Arc::downgrade(&self.sessions), status_sink.clone());
            });
        }

        mcp_cleanup_guard.disarm();
        Ok(info)
    }

    fn ensure_attached(&self, id: &str) -> Result<()> {
        let (daemon_name, activity, output, display, killing, project, cwd, engine) = {
            let mut sessions = self.sessions.lock().unwrap();
            let handle = sessions
                .get_mut(id)
                .ok_or_else(|| anyhow!("no such session: {id}"))?;
            if handle.attached {
                return Ok(());
            }
            handle.attached = true;
            (
                handle.daemon_session.clone(),
                Arc::clone(&handle.activity),
                Arc::clone(&handle.output),
                Arc::clone(&handle.display),
                Arc::clone(&handle.killing),
                handle.project.clone(),
                handle.cwd.clone(),
                handle.engine.clone(),
            )
        };
        let daemon = self
            .daemon_sessions
            .as_ref()
            .cloned()
            .ok_or_else(|| anyhow!("PTY daemon is unavailable"))?;
        let sessions = Arc::downgrade(&self.sessions);
        let displays = Arc::downgrade(&self.displays);
        let data_dir = self.data_dir.clone();
        let on_end = self.on_end.clone();
        let on_attention = self.on_attention.clone();
        let on_status = self.on_status.clone();
        let session_id = id.to_string();
        let callback_daemon = daemon.clone();
        let callback_daemon_name = daemon_name.clone();
        let callback_id = session_id.clone();
        let callback: crate::daemon::DaemonEventSink = Arc::new(move |event| match event {
            DaemonEvent::Snapshot { bytes, .. } | DaemonEvent::Output { bytes, .. } => {
                display.receive(&bytes);
                activity.mark_output();
                process_daemon_output(
                    &callback_id,
                    &bytes,
                    &activity,
                    &output,
                    on_attention.as_ref(),
                );
            }
            DaemonEvent::Status(status) => {
                if let Some(status_sink) = &on_status {
                    let event_engine = status.engine;
                    let status = protocol_status(status.status);
                    let changed = activity
                        .last_status
                        .lock()
                        .map(|mut last| {
                            let changed = *last != Some(status);
                            *last = Some(status);
                            changed
                        })
                        .unwrap_or(false);
                    if changed {
                        status_sink(&SessionStatusEvent::new(
                            &callback_id,
                            status,
                            &event_engine,
                        ));
                    }
                }
            }
            DaemonEvent::Attention { .. } => {
                activity.attention.store(true, Ordering::Relaxed);
                if let Some(attention_sink) = &on_attention {
                    attention_sink(&callback_id);
                }
            }
            DaemonEvent::ResyncRequired { .. } => {
                let _ = callback_daemon.reattach_session(&callback_daemon_name, None);
            }
            DaemonEvent::Exited { exit_code, .. } => {
                // Intentional kills finalize synchronously in `kill()` after
                // the daemon's response guarantees transcript flush/reap.
                // Letting this queued callback win that registry race would
                // make `kill()` return before lifecycle/feedback hooks finish.
                if !killing.load(Ordering::Relaxed) {
                    finish_session(
                        &sessions,
                        &displays,
                        &data_dir,
                        &callback_id,
                        exit_code,
                        false,
                        on_end.as_ref(),
                        &project,
                        &cwd,
                        &engine,
                    );
                }
            }
        });
        if let Err(error) = daemon.attach_session(&daemon_name, None, callback) {
            if let Some(handle) = self.sessions.lock().unwrap().get_mut(id) {
                handle.attached = false;
            }
            return Err(anyhow!(error));
        }
        Ok(())
    }

    fn mark_display_ready(&self, id: &str) -> Result<DisplayReady> {
        let display = self
            .displays
            .lock()
            .unwrap()
            .get(id)
            .cloned()
            .ok_or_else(|| anyhow!("no such session: {id}"))?;
        let ready = display.mark_ready();
        if ready.ended {
            self.displays.lock().unwrap().remove(id);
        }
        Ok(ready)
    }

    fn request_fresh_snapshot(&self, id: &str) -> Result<()> {
        let daemon_name = self
            .sessions
            .lock()
            .unwrap()
            .get(id)
            .ok_or_else(|| anyhow!("no such session: {id}"))?
            .daemon_session
            .clone();
        self.daemon_sessions
            .as_ref()
            .ok_or_else(|| anyhow!("PTY daemon is unavailable"))?
            .reattach_session(&daemon_name, None)
            .map_err(|error| anyhow!(error))
    }

    /// Writes raw bytes to a session's PTY (keystrokes, pasted text, etc).
    ///
    /// Also clears the attention latch: the user typing into a session that
    /// was blocked on them *is* the "handled it" signal — there is no other
    /// one available (a stock engine announces neither that it's waiting nor
    /// that it stopped waiting; see the module docs' attention-detection
    /// investigation). Known limit, stated plainly: any keystroke clears it,
    /// including one that doesn't actually dismiss the prompt (an arrow key
    /// while choosing an option). The light goes back to red on the next
    /// marker match, which a still-pending prompt redraws roughly twice a
    /// second, so a premature clear self-corrects within ~a second rather
    /// than sticking.
    pub fn write(&self, id: &str, data: &str) -> Result<()> {
        let display = self.mark_display_ready(id)?;
        if display.ended {
            return Err(anyhow!("no such session: {id}"));
        }
        if display.needs_snapshot {
            self.request_fresh_snapshot(id)?;
        }
        let (daemon_name, activity) = {
            let sessions = self.sessions.lock().unwrap();
            let handle = sessions
                .get(id)
                .ok_or_else(|| anyhow!("no such session: {id}"))?;
            (handle.daemon_session.clone(), Arc::clone(&handle.activity))
        };
        if !is_pointer_report(data) {
            activity.mark_user_input();
        }
        self.daemon_sessions
            .as_ref()
            .ok_or_else(|| anyhow!("PTY daemon is unavailable"))?
            .send_input(&daemon_name, data.as_bytes())
            .map_err(|error| anyhow!(error))
    }

    /// Resizes the PTY (call on terminal-pane resize / fit-addon changes).
    pub fn resize(&self, id: &str, cols: u16, rows: u16) -> Result<()> {
        let display = self.mark_display_ready(id)?;
        if display.ended {
            return Ok(());
        }
        if display.needs_snapshot {
            self.request_fresh_snapshot(id)?;
        }
        let daemon_name = self
            .sessions
            .lock()
            .unwrap()
            .get(id)
            .ok_or_else(|| anyhow!("no such session: {id}"))?
            .daemon_session
            .clone();
        self.daemon_sessions
            .as_ref()
            .ok_or_else(|| anyhow!("PTY daemon is unavailable"))?
            .resize(&daemon_name, cols, rows)
            .map_err(|error| anyhow!(error))
    }

    /// Kills the daemon-owned session. The daemon flushes the transcript and
    /// reaps its child before acknowledging the request.
    pub fn kill(&self, id: &str) -> Result<()> {
        let (daemon_name, killing, project, cwd, engine) = {
            let sessions = self.sessions.lock().unwrap();
            let handle = sessions
                .get(id)
                .ok_or_else(|| anyhow!("no such session: {id}"))?;
            (
                handle.daemon_session.clone(),
                Arc::clone(&handle.killing),
                handle.project.clone(),
                handle.cwd.clone(),
                handle.engine.clone(),
            )
        };
        killing.store(true, Ordering::Relaxed);
        self.daemon_sessions
            .as_ref()
            .ok_or_else(|| anyhow!("PTY daemon is unavailable"))?
            .kill(&daemon_name)
            .map_err(|error| anyhow!(error))?;
        finish_session(
            &Arc::downgrade(&self.sessions),
            &Arc::downgrade(&self.displays),
            &self.data_dir,
            id,
            None,
            true,
            self.on_end.as_ref(),
            &project,
            &cwd,
            &engine,
        );
        Ok(())
    }

    /// The Tauri adapter never owns a child process, so it has no PID.
    pub fn pid(&self, id: &str) -> Option<u32> {
        self.sessions
            .lock()
            .unwrap()
            .contains_key(id)
            .then_some(())?;
        None
    }

    /// The traffic light for one session, computed fresh right now — the
    /// pull side of the status API (`session_status` in `commands.rs`), so a
    /// tab can render the correct light the instant it mounts or is restored
    /// instead of waiting for the next `session-status:{id}` change event.
    ///
    /// `None` only when there's no such live session. Recording the result as
    /// the session's last-known status is deliberate: a pull that returns
    /// `thinking` has already told the caller what the next push would have,
    /// so suppressing that redundant push is correct, not a lost update.
    ///
    /// Returns the same [`SessionStatusEvent`] shape the push side emits —
    /// including `notify` — so a caller never has to branch on where the
    /// status came from.
    pub fn status(&self, id: &str) -> Option<SessionStatusEvent> {
        let activity = {
            let sessions = self.sessions.lock().unwrap();
            Arc::clone(&sessions.get(id)?.activity)
        };
        let status = compute_status(&activity, None, Instant::now());
        if let Ok(mut last) = activity.last_status.lock() {
            *last = Some(status);
        }
        Some(SessionStatusEvent::new(id, status, &activity.engine))
    }

    /// Checks if any open terminal session is currently executing a task (`Thinking` or `ToolExecution`).
    pub fn has_working_sessions(&self) -> bool {
        let ids: Vec<String> = {
            let sessions = self.sessions.lock().unwrap();
            sessions.keys().cloned().collect()
        };
        for id in ids {
            if let Some(event) = self.status(&id) {
                if matches!(
                    event.status,
                    SessionStatus::Thinking | SessionStatus::ToolExecution
                ) {
                    return true;
                }
            }
        }
        false
    }

    /// Sends SIGINT (\x03 / Ctrl+C) to all active working sessions to interrupt task execution
    /// without killing PTY sessions.
    pub fn stop_active_executions(&self) -> usize {
        let ids: Vec<String> = {
            let sessions = self.sessions.lock().unwrap();
            sessions.keys().cloned().collect()
        };
        let mut count = 0;
        for id in ids {
            if let Some(event) = self.status(&id) {
                if matches!(
                    event.status,
                    SessionStatus::Thinking | SessionStatus::ToolExecution
                ) {
                    let daemon_name = self
                        .sessions
                        .lock()
                        .unwrap()
                        .get(&id)
                        .map(|handle| handle.daemon_session.clone());
                    if daemon_name.is_some_and(|name| {
                        self.daemon_sessions
                            .as_ref()
                            .is_some_and(|daemon| daemon.send_interrupt(&name).is_ok())
                    }) {
                        count += 1;
                    }
                }
            }
        }
        count
    }

    pub fn pty_daemon_status(&self) -> (bool, bool, String, usize) {
        let Some(daemon) = &self.daemon_sessions else {
            return (false, false, String::new(), 0);
        };
        (
            true,
            daemon.is_alive(),
            daemon.socket_path().display().to_string(),
            daemon.list_sessions().len(),
        )
    }
}

fn process_daemon_output(
    id: &str,
    bytes: &[u8],
    activity: &SessionActivity,
    output: &Mutex<SessionOutputProcessor>,
    on_attention: Option<&AttentionSink>,
) {
    let Ok(mut output) = output.lock() else {
        return;
    };
    let decoded = output.decoder.decode(bytes);
    if on_attention.is_none() && !activity.status_tracking {
        return;
    }

    let now = Instant::now();
    if activity.clear_marker_window.swap(false, Ordering::Relaxed) {
        output.marker_window.clear();
        output.last_user_input = Some(now);
    }
    output.marker_window.push_str(&decoded);
    trim_to_last_n_bytes(&mut output.marker_window, ATTENTION_WINDOW_BYTES);
    let just_responded = output
        .last_user_input
        .is_some_and(|time| now.duration_since(time) < ATTENTION_INPUT_GRACE);
    if contains_error_marker(&output.marker_window) && !just_responded {
        activity.error.store(true, Ordering::Relaxed);
    }
    if contains_attention_marker(&output.marker_window) {
        if !just_responded {
            activity.attention.store(true, Ordering::Relaxed);
        }
        if output.attention_debouncer.should_fire(now) {
            if let Some(attention) = on_attention {
                attention(id);
            }
        }
    }
}

#[allow(clippy::too_many_arguments)]
fn finish_session(
    sessions: &Weak<Mutex<HashMap<String, SessionHandle>>>,
    displays: &Weak<Mutex<HashMap<String, Arc<SessionDisplay>>>>,
    data_dir: &Path,
    id: &str,
    exit_code: Option<u32>,
    killed: bool,
    on_end: Option<&SessionEndHook>,
    _project: &str,
    _cwd: &str,
    _engine: &str,
) {
    let Some(sessions) = sessions.upgrade() else {
        return;
    };
    let handle = sessions.lock().unwrap().remove(id);
    let Some(handle) = handle else {
        return;
    };
    if handle.display.mark_ended() {
        if let Some(displays) = displays.upgrade() {
            displays.lock().unwrap().remove(id);
        }
    }
    cleanup_mcp_config(&handle.mcp_config_path);
    let _ = append_lifecycle_event(
        &lifecycle_path(data_dir, id),
        &LifecycleEvent::End {
            ts: now_ts(),
            exit_code,
            signal: None,
            killed,
        },
    );
    if let Some(hook) = on_end {
        hook(&SessionEndEvent {
            id: id.to_string(),
            project: handle.project,
            cwd: handle.cwd,
            engine: handle.engine,
            transcript_path: transcript_path(data_dir, id),
        });
    }
}

fn protocol_status(status: omniagent_pty_daemon::protocol::SessionStatus) -> SessionStatus {
    match status {
        omniagent_pty_daemon::protocol::SessionStatus::Ready => SessionStatus::Ready,
        omniagent_pty_daemon::protocol::SessionStatus::Thinking => SessionStatus::Thinking,
        omniagent_pty_daemon::protocol::SessionStatus::ToolExecution => {
            SessionStatus::ToolExecution
        }
        omniagent_pty_daemon::protocol::SessionStatus::AwaitingApproval => {
            SessionStatus::AwaitingApproval
        }
        omniagent_pty_daemon::protocol::SessionStatus::Error => SessionStatus::Error,
    }
}

fn transcripts_dir(data_dir: &Path) -> PathBuf {
    data_dir.join("transcripts")
}

fn transcript_path(data_dir: &Path, id: &str) -> PathBuf {
    transcripts_dir(data_dir).join(format!("{id}.log"))
}

fn lifecycle_path(data_dir: &Path, id: &str) -> PathBuf {
    transcripts_dir(data_dir).join(format!("{id}.lifecycle.jsonl"))
}

static SESSION_COUNTER: AtomicU64 = AtomicU64::new(0);

/// `sess-<nanos-since-epoch-hex>-<counter-hex>` — unique within a process
/// lifetime without pulling in a UUID dependency for what is purely a local,
/// in-memory-registry key.
///
/// Deliberately **not** stable across app restarts (nanos + a per-process
/// counter), which is precisely why persistence needs
/// [`CreateSessionRequest::restore_id`]: the id can't be re-derived, so the
/// frontend has to carry it. Kept as-is rather than switching to something
/// content-derived — a session's identity genuinely is "this tab, opened at
/// this moment", and two tabs on the same project/cwd/engine must not
/// collide onto one tmux session.
fn generate_session_id() -> String {
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    let seq = SESSION_COUNTER.fetch_add(1, Ordering::Relaxed);
    format!("sess-{nanos:x}-{seq:x}")
}

/// Upper bound on an accepted `restore_id`. Generated ids are ~25 characters;
/// this leaves generous room while keeping the derived tmux session name and
/// transcript filename bounded.
const MAX_SESSION_ID_LEN: usize = 96;

/// Whether a caller-supplied id is safe to use as one. This is a *validation*
/// gate, not a sanitizer: the id becomes a filesystem path
/// (`<data_dir>/transcripts/<id>.log`) and a tmux target, so `../../etc/x` or
/// `a:b` must be rejected outright rather than quietly rewritten into some
/// other session's name. `[A-Za-z0-9_-]` has no path separators, no `.` (so
/// no traversal, and no tmux window/pane target syntax), and no shell
/// metacharacters.
fn is_valid_session_id(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= MAX_SESSION_ID_LEN
        && id
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
}

/// Process-wide cache for the resolved daemon manager ([`default_daemon_sessions`]).
static DAEMON_SESSIONS: OnceLock<Option<DaemonSessions>> = OnceLock::new();

/// The daemon-backed session manager OmniAgent should use in production:
/// resolved once per process against the user's real, shell-resolved `PATH`
/// (a GUI-launched `.app` has no Homebrew on its inherited `PATH` — the same
/// bug [`resolve_shell_path`] exists for), pinned to this app's private
/// socket, and pointed at this app's own config file.
///
/// `None` means the daemon binary could not be resolved. Session creation then
/// returns an availability error; the app never falls back to owning a PTY or
/// engine process itself.
pub fn default_daemon_sessions(data_dir: &Path) -> Option<DaemonSessions> {
    cached_or_init(&DAEMON_SESSIONS, || {
        let resolved = DaemonSessions::resolve(daemon::DEFAULT_SOCKET, cached_shell_path())?;
        Some(match daemon::write_config(data_dir) {
            Some(cfg) => resolved.with_config(cfg),
            None => resolved,
        })
    })
    .clone()
}

/// How long a `--resume <uuid>` spawn is watched before it's declared healthy.
///
/// Sized from a real measurement, not a guess: interactive `claude --resume
/// <uuid>` naming a conversation that doesn't exist prints `No conversation
/// found with session ID: <uuid>` and exits 1 after ~1.25 s (measured on
/// claude 2.1.220 through a real PTY), while a successful one is still
/// running well past that. 2.5 s is ~2× the observed failure latency —
/// comfortably past it without being an eternity on the one path that pays
/// it (a *restore* whose tmux session is gone; the ordinary restore attaches
/// and is never probed).
#[cfg(test)]
const RESUME_LIVENESS_WINDOW: Duration = Duration::from_millis(2500);

/// How long a `--session-id <uuid>` spawn is watched before it's declared
/// healthy. Much shorter than [`RESUME_LIVENESS_WINDOW`] because its only
/// failure mode is much faster: `--session-id` naming a conversation that
/// already exists prints `Error: Session ID <uuid> is already in use.` and
/// exits 1 after ~0.20 s (measured three times, same PTY harness) — this is
/// startup-time validation, not a store lookup that has to fail. 500 ms is
/// ~2.5× that.
///
/// This one is on the *new tab* path, which is why the size matters: a fresh
/// session's derived UUID cannot realistically already be in use (ids are
/// minted from nanos plus a per-process counter, so nothing re-derives an
/// old one), but "cannot realistically" is not "cannot", and the cost of
/// being wrong is a dead terminal. Half a second on tab creation buys the
/// guarantee that there is always a working Claude behind the pane.
#[cfg(test)]
const SESSION_ID_LIVENESS_WINDOW: Duration = Duration::from_millis(500);

/// Poll granularity for [`child_survives_startup`]. Fine enough that a
/// failure is detected (and the retry started) within a blink of the process
/// actually dying.
#[cfg(test)]
const CONTINUE_LIVENESS_POLL: Duration = Duration::from_millis(50);

/// `true` if `child` was still running at the end of `window` — i.e. it
/// didn't immediately refuse to start. Returns as soon as the child exits,
/// so the failure path is fast; only the healthy path waits out the window.
#[cfg(test)]
fn child_survives_startup(child: &mut Box<dyn Child + Send + Sync>, window: Duration) -> bool {
    let deadline = Instant::now() + window;
    while Instant::now() < deadline {
        match child.try_wait() {
            Ok(Some(_)) => return false,
            _ => thread::sleep(CONTINUE_LIVENESS_POLL),
        }
    }
    true
}

/// How long a **freshly created** tmux session is watched before its pane
/// counts as genuinely started (module docs, "Why tmux needs an absolute
/// engine path").
///
/// Sized from the measured failure it exists to catch, not from taste: a pane
/// whose command cannot be `exec`'d at all dies — and takes its session with
/// it — within ~150 ms (measured against real tmux 3.7b; `new-session` itself
/// still reports success, because it reports on creating the pane rather than
/// on the `exec` inside it). 300 ms is ~2× that.
///
/// Deliberately short, because unlike the identity probes this one is on
/// *every* new tab's critical path. It only has to separate "the command
/// never started" from "the command is running"; a slower death — `claude`
/// refusing a `--resume` after ~1.25 s — is still caught by
/// [`child_survives_startup`] on the attach client, which is what
/// [`ClaudeIdentity::liveness_window`] sizes. A session that already existed
/// is never watched at all: its engine has been running since before the app
/// restarted, so there is nothing to start.
#[cfg(test)]
const DAEMON_PANE_STARTUP_WINDOW: Duration = Duration::from_millis(300);

/// Poll granularity for [`daemon_session_survives_startup`]. Each poll is a
/// real daemon has-session request (single-digit milliseconds against a local
/// unix socket), so this trades a handful of cheap calls for detecting a dead
/// pane almost the instant it dies.
#[cfg(test)]
const DAEMON_PANE_STARTUP_POLL: Duration = Duration::from_millis(25);

/// Chooses whether (and for how long) a spawn attempt should be startup-probed.
///
/// With the daemon, the PTY child is always an attach client, and an attach
/// that exits immediately is a dead pane regardless of which identity rung
/// produced the underlying daemon session. So daemon-backed attempts are
/// always probed.
///
/// Without the daemon, probes are only for non-final identity rungs where
/// there is a lower fallback to try.
#[cfg(test)]
fn startup_probe_window(
    rung: usize,
    last_rung: usize,
    identity: ClaudeIdentity,
    daemon_attached: bool,
) -> Option<Duration> {
    if daemon_attached {
        Some(DAEMON_PANE_STARTUP_WINDOW)
    } else if rung < last_rung {
        Some(identity.liveness_window())
    } else {
        None
    }
}

/// `true` if the tmux session `name` was still alive at the end of `window` —
/// i.e. the command inside it did not immediately fail to start. Returns as
/// soon as the session is gone, so the failure path is fast; only the healthy
/// path waits out the window.
///
/// This is the daemon-side twin of [`child_survives_startup`], and it exists
/// because the PTY-side probe is blind here: with the daemon the PTY child is
/// the attach client, not the engine, so an engine that dies *before* the
/// client attaches leaves the client reporting `no sessions` rather than
/// the engine reporting anything. Asking the daemon directly is both earlier
/// and unambiguous.
#[cfg(test)]
fn daemon_session_survives_startup(t: &DaemonSessions, name: &str, window: Duration) -> bool {
    let deadline = Instant::now() + window;
    loop {
        if !t.has_session(name) {
            return false;
        }
        if Instant::now() >= deadline {
            return true;
        }
        thread::sleep(DAEMON_PANE_STARTUP_POLL);
    }
}

/// The absolute path of the binary an engine name refers to, resolved against
/// the user's real, shell-resolved `PATH` ([`cached_shell_path`]) with this
/// process's own `PATH` as a backstop.
///
/// See the module docs' "Why the daemon needs an absolute engine path" for
/// the founder bug behind it. In short: launching `claude …` inside a daemon
/// session `exec`s against the daemon **server's** environment, which for a
/// GUI-launched `.app` is macOS's minimal default `PATH`, so a bare engine
/// name is simply not found — and the session quietly disappears rather than
/// surfacing as an error.
///
/// `None` when the engine genuinely isn't installed anywhere on that `PATH`.
/// Callers keep the bare name in that case, so the spawn fails with the real
/// OS error naming the engine instead of with something invented here.
fn resolve_engine_binary(program: &str) -> Option<PathBuf> {
    let as_path = Path::new(program);
    // Already a path (`$SHELL` is always one): honour it as given, so nothing
    // here can ever redirect a session to a *different* binary than asked for.
    if program.contains(std::path::MAIN_SEPARATOR) {
        return daemon::is_executable_file(as_path).then(|| as_path.to_path_buf());
    }
    let search = cached_shell_path()
        .map(str::to_string)
        .or_else(|| std::env::var("PATH").ok())?;
    std::env::split_paths(&search)
        .map(|dir| dir.join(program))
        .find(|candidate| daemon::is_executable_file(candidate))
}

/// The namespace every OmniAgent-owned Claude conversation UUID is derived
/// under ([`claude_conversation_uuid`]).
///
/// Not a magic constant: it is itself `uuid5(NAMESPACE_URL,
/// "https://omni-agent.ai/ade/claude-conversation")` (that string is kept
/// beside it as `CLAUDE_CONVERSATION_NAMESPACE_URL`), so anyone — in any
/// language with a UUID library — can rederive it and check it, and
/// `the_namespace_is_the_documented_derivation_not_a_magic_constant` asserts
/// exactly that. Written out as a literal rather than computed at startup
/// because it must never drift: change it and every existing pane loses its
/// conversation.
const CLAUDE_CONVERSATION_NAMESPACE: Uuid = Uuid::from_u128(0x9337750e_5a2b_59c8_82f3_650bc0f53cfa);

/// The URL whose UUIDv5 is [`CLAUDE_CONVERSATION_NAMESPACE`]. Test-only
/// because nothing at runtime should ever recompute the namespace — the
/// literal above is the value, and this exists so the suite can prove where
/// that literal came from rather than leaving it to a commit message.
#[cfg(test)]
const CLAUDE_CONVERSATION_NAMESPACE_URL: &str = "https://omni-agent.ai/ade/claude-conversation";

/// The Claude conversation an OmniAgent session owns, as the `<uuid>` for
/// `claude --session-id` / `claude --resume`.
///
/// **Derived, never stored.** A UUIDv5 (RFC 4122 name-based, SHA-1) of the
/// OmniAgent session id under [`CLAUDE_CONVERSATION_NAMESPACE`]. That single
/// property — same session id, same UUID, forever, on any machine — is what
/// lets this fix ship without persisting anything new and without touching
/// the frontend contract: `restore_id` already round-trips the session id, so
/// the conversation id comes along for free.
///
/// Why this and not `--continue`: `--continue` picks the most recent
/// conversation *in the directory*, which makes every Claude pane in a
/// project collapse onto one conversation after a reboot (module docs, "Every
/// claude pane owns its own conversation"). A per-session UUID is the only
/// thing that keeps N panes in one folder distinct.
///
/// Verified against the real binary, not inferred: `claude --session-id`
/// accepts this exact shape (it validates the `8-4-4-4-12` hex form — a nil
/// UUID and a variant-0 UUID were both accepted, so a proper v5 is
/// comfortably inside it), and the conversation it then writes is named
/// `~/.claude/projects/<dir>/<this uuid>.jsonl`.
fn claude_conversation_uuid(session_id: &str) -> String {
    Uuid::new_v5(&CLAUDE_CONVERSATION_NAMESPACE, session_id.as_bytes()).to_string()
}

/// The conversation identity a given `create` should spawn with.
///
/// Three "no identity at all" cases converge on [`ClaudeIdentity::Stock`],
/// and lumping them together is deliberate — `Stock` is also the only value
/// whose ladder has a single rung, i.e. the only one that is never
/// liveness-probed:
///
/// - **an engine with no conversation concept** — `codex` and `shell` have
///   none. Giving them an identity would be a no-op on their argv but would
///   still arm the probe, making every new terminal tab wait out a window for
///   a flag it never carried. `claude` and `copilot` both accept the same
///   `--session-id`/`--resume` conversation flags, so both get an identity.
/// - **a live daemon session** — the engine has been running since before the
///   app closed; the argv is never used (`ensure_session` short-circuits)
///   and the PTY child is an attach client.
/// - the last rung of a ladder whose earlier rungs were refused.
fn spawn_identity(engine: &str, is_restore: bool, daemon_session_exists: bool) -> ClaudeIdentity {
    let has_conversation_identity = engine == "claude" || engine == "copilot";
    if !has_conversation_identity || daemon_session_exists {
        ClaudeIdentity::Stock
    } else if is_restore {
        ClaudeIdentity::Resume
    } else {
        ClaudeIdentity::Claim
    }
}

/// Which conversation-identity flag a `claude`/`copilot` spawn carries — the
/// thing that decides whether a restored pane gets *its own* history back or
/// somebody else's (module docs, "Every pane owns its own conversation").
///
/// Only meaningful for `claude` and `copilot`, which share the same
/// `--session-id`/`--resume` flag spellings; `codex` and `shell` ignore it
/// entirely and stay bit-for-bit stock.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ClaudeIdentity {
    /// `--session-id <U>` — a brand-new pane claiming the conversation it
    /// will own for the rest of its life.
    Claim,
    /// `--resume <U>` — a pane reopening the conversation it already owns,
    /// after the process behind it went away (app closed with no daemon
    /// session, or the daemon itself gone because the machine rebooted).
    Resume,
    /// No identity flag at all. Two very different situations converge here,
    /// and both genuinely want a stock engine: attaching to a still-live
    /// daemon session (the engine is already running; argv is never used), and
    /// the last rung of a ladder whose earlier rungs were refused.
    Stock,
}

impl ClaudeIdentity {
    /// The spawn attempts to make, in order, starting from this identity.
    ///
    /// Every ladder ends on [`Stock`](Self::Stock), which is what guarantees
    /// `create` can always hand back a working pane: a stock `claude` carries
    /// no flag that can be refused. The middle rung of the `Resume` ladder is
    /// the interesting one — it is how a session created *before* this fix
    /// existed gets adopted. Its old conversation was written without a
    /// chosen id, so `--resume <U>` finds nothing; the `--session-id <U>`
    /// retry starts a fresh conversation *under the right id*, and from that
    /// point on the pane restores its own history like any other.
    #[cfg(test)]
    fn ladder(self) -> Vec<Self> {
        match self {
            Self::Resume => vec![Self::Resume, Self::Claim, Self::Stock],
            Self::Claim => vec![Self::Claim, Self::Stock],
            Self::Stock => vec![Self::Stock],
        }
    }

    /// The argv fragment this identity contributes to a `claude` invocation.
    fn argv(self, session_id: &str) -> Vec<String> {
        match self {
            Self::Claim => vec![
                "--session-id".to_string(),
                claude_conversation_uuid(session_id),
            ],
            Self::Resume => vec!["--resume".to_string(), claude_conversation_uuid(session_id)],
            Self::Stock => Vec::new(),
        }
    }

    /// How long a spawn carrying this identity is watched before it counts as
    /// healthy — see the two window constants for the measurements behind the
    /// numbers.
    #[cfg(test)]
    fn liveness_window(self) -> Duration {
        match self {
            Self::Resume => RESUME_LIVENESS_WINDOW,
            Self::Claim => SESSION_ID_LIVENESS_WINDOW,
            // Direct-spawn path only: stock is the last rung and is not
            // identity-probed. (tmux-backed attempts are probed separately by
            // `startup_probe_window`.)
            Self::Stock => Duration::ZERO,
        }
    }
}

/// An engine invocation resolved for daemon-side creation.
struct EngineCommand {
    argv: Vec<String>,
    env: Vec<(String, String)>,
    cwd: String,
    /// Temp `--mcp-config` file for `claude` sessions, if any.
    mcp_config_path: Option<PathBuf>,
}

impl EngineCommand {
    /// Rewrites `argv[0]` to the engine binary's absolute path when it can be
    /// resolved ([`resolve_engine_binary`]), leaving the bare name alone when
    /// it can't. Applied to *both* spawn paths on purpose: the direct spawn
    /// doesn't need it (it inherits this process's `PATH` plus the `PATH` set
    /// on the `CommandBuilder`), but having one resolved program means the two
    /// paths can never launch a different binary as each other — which is the
    /// same reason `build_engine_command` is shared in the first place.
    fn resolve_program(&mut self) {
        if let Some(absolute) = resolve_engine_binary(&self.argv[0]) {
            self.argv[0] = absolute.to_string_lossy().into_owned();
        }
    }

    #[cfg(test)]
    fn to_command_builder(&self) -> CommandBuilder {
        let mut cmd = CommandBuilder::new(&self.argv[0]);
        for arg in &self.argv[1..] {
            cmd.arg(arg);
        }
        cmd.cwd(&self.cwd);
        for (k, v) in &self.env {
            cmd.env(k, v);
        }
        cmd
    }
}

/// Resolves a session request into the exact program, arguments and
/// environment to run — the single source of truth for engine wiring, shared
/// by the tmux and direct-spawn paths so tmux can never silently change how
/// an engine is invoked (DESIGN principle 5: tmux *wraps* stock engines, it
/// does not reconfigure them).
///
/// `identity` only ever applies to `claude` — see [`ClaudeIdentity`] and the
/// module docs' degradation ladder.
fn build_engine_command(
    req: &CreateSessionRequest,
    data_dir: &Path,
    session_id: &str,
    identity: ClaudeIdentity,
) -> Result<EngineCommand> {
    let mut cmd = build_engine_argv(req, data_dir, session_id, identity)?;
    // Absolute, so tmux's own environment stops deciding whether the engine
    // can be found at all — see [`resolve_engine_binary`].
    cmd.resolve_program();
    Ok(cmd)
}

/// The engine wiring proper: which program, which flags, which environment.
/// Split from [`build_engine_command`] only so that every arm below can be
/// written in terms of the *engine's own name* and have the absolute-path
/// resolution applied once, in one place, rather than three times.
fn build_engine_argv(
    req: &CreateSessionRequest,
    data_dir: &Path,
    session_id: &str,
    identity: ClaudeIdentity,
) -> Result<EngineCommand> {
    let env = engine_env();
    match req.engine.as_str() {
        "shell" => {
            let shell = preferred_shell_binary(std::env::var("SHELL").ok().as_deref());
            Ok(EngineCommand {
                argv: vec![shell],
                env,
                cwd: req.cwd.clone(),
                mcp_config_path: None,
            })
        }
        "codex" => {
            let mut argv = vec!["codex".to_string()];
            if let Some(bin) = resolve_mcp_server_binary() {
                let command = serde_json::to_string(&bin.to_string_lossy())?;
                let data_dir = serde_json::to_string(&data_dir.to_string_lossy())?;
                argv.push("--config".to_string());
                argv.push(format!(
                    "mcp_servers.omniagent={{command={command},args=[],env={{OMNIAGENT_ADE_DATA_DIR={data_dir}}}}}"
                ));
            } else {
                eprintln!(
                    "omniagent-ade: omniagent-mcp binary not found next to the app \
                     binary; launching codex for session {session_id} without ADE's MCP wiring"
                );
            }
            Ok(EngineCommand {
                argv,
                env,
                cwd: req.cwd.clone(),
                mcp_config_path: None,
            })
        }
        "claude" => {
            let mut argv = vec!["claude".to_string()];

            // Which conversation this pane owns, decided by OmniAgent rather
            // than by Claude's directory-scoped "most recent" heuristic —
            // first, so it reads the way it would be typed. See
            // [`ClaudeIdentity`] and [`claude_conversation_uuid`].
            argv.extend(identity.argv(session_id));

            let mcp_config_path = match resolve_mcp_server_binary() {
                Some(bin) => {
                    let cfg_path =
                        write_mcp_config(&bin, data_dir, session_id).context("write mcp config")?;
                    argv.push("--mcp-config".to_string());
                    argv.push(cfg_path.to_string_lossy().into_owned());
                    Some(cfg_path)
                }
                None => {
                    eprintln!(
                        "omniagent-ade: omniagent-mcp binary not found next to the app \
                         binary; launching claude for session {session_id} without ADE's \
                         MCP wiring (briefing, if any, still applies)"
                    );
                    None
                }
            };

            if let Some(briefing) = &req.briefing {
                argv.push("--append-system-prompt".to_string());
                argv.push(briefing.clone());
            }

            Ok(EngineCommand {
                argv,
                env,
                cwd: req.cwd.clone(),
                mcp_config_path,
            })
        }
        // Copilot gets ADE's conversation-identity flags (the same
        // `--session-id`/`--resume` spellings Claude uses — verified against
        // the real CLI) so a restored Copilot pane reopens *its own*
        // conversation, exactly like Claude. It is still spawned without an
        // `--mcp-config`: Copilot does not accept ADE's MCP config format, and
        // passing it would fail at launch.
        "copilot" => {
            let binary = crate::commands::agents::binary_for("copilot")
                .ok_or_else(|| anyhow!("no binary registered for engine \"copilot\""))?;
            let mut argv = vec![binary.to_string()];
            // Empty for `Stock` (a live-session attach or the ladder's last
            // rung), so an attaching/ stock Copilot stays bit-for-bit bare.
            argv.extend(identity.argv(session_id));
            Ok(EngineCommand {
                argv,
                env,
                cwd: req.cwd.clone(),
                mcp_config_path: None,
            })
        }
        // Antigravity is spawned bare: it accepts neither ADE's MCP config nor
        // any conversation-identity flags, so passing them would fail at
        // launch. The binary comes from `commands::agents::AGENTS` rather than
        // a literal, because the engine's name is not its executable (its CLI
        // is `agy`). That table is also what `agents_check_installed` reports
        // from, so an agent can never be detected as installed and then fail
        // to spawn.
        "antigravity" => {
            let binary = crate::commands::agents::binary_for("antigravity")
                .ok_or_else(|| anyhow!("no binary registered for engine \"antigravity\""))?;
            Ok(EngineCommand {
                argv: vec![binary.to_string()],
                env,
                cwd: req.cwd.clone(),
                mcp_config_path: None,
            })
        }
        other => Err(anyhow!(
            "unsupported engine: {other:?} (expected one of \"claude\", \"codex\", \
             \"shell\", \"copilot\", \"antigravity\")"
        )),
    }
}

/// The shell binary a `shell` session should execute.
///
/// `$SHELL` can be stale (for example, pointing to an uninstalled shell), so
/// this only trusts it when it is an executable path. Otherwise it falls back
/// to known system shells.
fn preferred_shell_binary(shell_env: Option<&str>) -> String {
    let from_env = shell_env.map(str::trim).filter(|s| !s.is_empty());
    for candidate in from_env.into_iter().chain(["/bin/zsh", "/bin/sh"]) {
        let path = Path::new(candidate);
        if daemon::is_executable_file(path) {
            return candidate.to_string();
        }
    }
    from_env.unwrap_or("/bin/zsh").to_string()
}

/// The environment every engine is handed, whichever way it's spawned.
///
/// `PATH` is the user's real, shell-resolved one ([`cached_shell_path`]) —
/// see the module docs' "Resolving the real PATH for GUI-launched spawns"
/// section. Omitted entirely when resolution fails, which leaves whatever
/// `PATH` this process itself inherited (the pre-fix behavior) rather than
/// inventing one. `TERM`/`COLORTERM` are always set ([`TERM_VALUE`],
/// [`COLORTERM_VALUE`]).
///
/// Under tmux these become `tmux new-session -e KEY=VALUE` pairs, verified to
/// reach the pane's process environment; under a direct spawn they're set on
/// the `CommandBuilder`. Same values either way — that's the point of having
/// one producer.
fn engine_env() -> Vec<(String, String)> {
    let mut env = Vec::new();
    if let Some(path) = cached_shell_path() {
        env.push(("PATH".to_string(), path.to_string()));
    }
    env.push(("TERM".to_string(), TERM_VALUE.to_string()));
    env.push(("COLORTERM".to_string(), COLORTERM_VALUE.to_string()));
    if let Some(locale) = utf8_locale_override(
        std::env::var("LC_ALL").ok().as_deref(),
        std::env::var("LC_CTYPE").ok().as_deref(),
        std::env::var("LANG").ok().as_deref(),
    ) {
        env.push(locale);
    }
    env
}

/// A UTF-8 locale for the spawned engine and the tmux client, when — and only
/// when — the ambient environment doesn't already name one.
///
/// Founder bug, 2026-07-26: claude's box-drawing frame arrived as mojibake
/// (`‚îÄ‚îÄ` where `──` belongs — UTF-8 bytes shown one glyph per byte).
/// Measured on his live server: every ADE tmux client reported
/// `#{client_utf8}` = **0**, and `capture-pane -p` returned bytes that aren't
/// valid UTF-8 — tmux had byte-split the pane. tmux decides UTF-8 mode from
/// `LC_ALL`/`LC_CTYPE`/`LANG`, and a Finder-launched `.app` has none of them
/// (the same empty-environment root cause as [`resolve_shell_path`] and
/// [`TERM_VALUE`]).
///
/// Asserted rather than resolved, for [`TERM_VALUE`]'s exact reason: xterm.js
/// decodes UTF-8 and nothing else, so "what should the encoding be" has one
/// right answer regardless of what a login shell would have said. A real
/// locale already in the environment (`tauri dev` from a terminal) is
/// respected untouched — this only fills a vacuum.
///
/// ponytail: the *language* half of `en_US.UTF-8` is a guess (it only moves
/// CLI number/date formatting), where the charset half is the actual fix. If
/// that ever matters, resolve `$LANG` from the login shell in the same spawn
/// [`spawn_and_capture_path`] already makes, rather than adding a second one.
fn utf8_locale_override(
    lc_all: Option<&str>,
    lc_ctype: Option<&str>,
    lang: Option<&str>,
) -> Option<(String, String)> {
    // `LC_ALL` outranks the other two, so if it is set to anything at all,
    // adding `LANG` cannot change the outcome — leave the environment alone
    // and let a deliberate setting stand, UTF-8 or not.
    if lc_all.is_some() {
        return None;
    }
    let names_utf8 = |v: Option<&str>| {
        v.is_some_and(|v| {
            let v = v.to_ascii_uppercase().replace('-', "");
            v.contains("UTF8")
        })
    };
    if names_utf8(lc_ctype) || names_utf8(lang) {
        return None;
    }
    Some(("LANG".to_string(), UTF8_LOCALE.to_string()))
}

/// The locale [`utf8_locale_override`] asserts when the environment names
/// none. `en_US.UTF-8` is present on every macOS install (`locale -a`), so
/// this can't fail the way a `de_DE.UTF-8`-style guess could.
const UTF8_LOCALE: &str = "en_US.UTF-8";

/// How long [`spawn_and_capture_path`] will wait for the login-shell
/// `PATH`-resolution subprocess before giving up and treating it as a
/// failure (see [`resolve_shell_path_for`]'s doc comment for the rest of
/// the guard: `stdin` is already closed, this timeout is the backstop for
/// whatever that doesn't cover). Generous relative to the real,
/// empirically-measured cost of this machine's own profile chain (well
/// under a second), but bounded — this sits on session creation's critical
/// path and must never be allowed to hang it.
const SHELL_PATH_RESOLUTION_TIMEOUT: Duration = Duration::from_secs(5);

/// The exact terminal type this app's xterm.js + WebGL addon implements —
/// see the module docs' "Making CLIs render color" section for the founder
/// bug behind it (a GUI-launched `.app` has no `TERM` at all, which makes
/// CLIs like `claude` fall back to plain, uncolored output). Unlike `PATH`,
/// this is always asserted rather than resolved: there's no "real" value to
/// discover from this process's own environment, so the right answer is
/// simply what this app's own renderer supports.
const TERM_VALUE: &str = "xterm-256color";
/// The de facto signal modern CLIs (including `claude`) check for 24-bit
/// color.
const COLORTERM_VALUE: &str = "truecolor";

/// Process-global cache for [`resolve_shell_path`]'s result — the spawn it
/// performs is real (if usually sub-second) latency, so it's paid once per
/// app run, not once per session. See [`cached_or_init`]'s doc comment for
/// why the caching *mechanism* is unit-tested against a fresh, local
/// `OnceLock` rather than this one.
static SHELL_PATH: OnceLock<Option<String>> = OnceLock::new();

/// Cached accessor for the app's actual use: resolves at most once per
/// process lifetime, reusing the cached `Option<String>` (itself `None`
/// when resolution failed) on every subsequent call.
fn cached_shell_path() -> Option<&'static str> {
    #[cfg(test)]
    if FORCE_SHELL_PATH_RESOLUTION_FAILURE.with(|f| f.get()) {
        return None;
    }
    #[cfg(test)]
    if let Some(overridden) = TEST_SHELL_PATH_OVERRIDE.with(|o| o.get()) {
        return Some(overridden);
    }
    cached_or_init(&SHELL_PATH, resolve_shell_path).as_deref()
}

// Test-only escape hatch, thread-local so it's naturally isolated from
// every other test running concurrently on its own worker thread (`cargo
// test`'s default execution model) — no cross-test races, no extra
// synchronization. Exists purely for
// `create_cleans_up_leaked_mcp_config_temp_file_when_spawn_fails`, whose
// whole premise (claude becomes unresolvable once its directory is
// filtered off `PATH`) this PATH-resolution fix otherwise permanently
// defeats on any machine where the real shell `PATH` *does* contain
// `claude` — which, after this fix, `apply_resolved_path` now consults
// unconditionally, regardless of what a test does to the ambient env.
// Compiled only under `#[cfg(test)]`; doesn't exist in a release binary.
#[cfg(test)]
thread_local! {
    static FORCE_SHELL_PATH_RESOLUTION_FAILURE: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
    /// Test-only `PATH` injection: makes `engine_env` hand a spawned engine a
    /// `PATH` of the test's choosing, so a test can put a fake `claude` in
    /// front of the real one **without touching the process-global `PATH`**.
    /// Thread-local for the same reason the flag above is — `cargo test` runs
    /// tests in parallel in one process, and the one existing test that does
    /// mutate the real `PATH`
    /// (`create_cleans_up_leaked_mcp_config_temp_file_when_spawn_fails`,
    /// which filters `claude` off it) would race catastrophically with a test
    /// that prepends a directory *containing* a `claude`: whichever wrote
    /// last would win, and that test's whole premise would silently invert.
    /// The value is a leaked `&'static str` because `cached_shell_path`
    /// returns one; a few bytes per test thread, in test builds only.
    static TEST_SHELL_PATH_OVERRIDE: std::cell::Cell<Option<&'static str>> = const { std::cell::Cell::new(None) };
}

/// Generic lazy-once cache: runs `init` the first time `cache` is empty,
/// reuses the stored result forever after — precisely `OnceLock::get_or_init`
/// with a name that reads at the call site. Pulled out as its own function
/// (rather than inlining `SHELL_PATH.get_or_init(resolve_shell_path)`
/// directly into [`cached_shell_path`]) purely so the caching mechanism
/// itself can be exercised in tests against a fresh, test-local `OnceLock`
/// and a call-counting closure — asserting a call count against the *real*
/// process-global `SHELL_PATH` would be racy under `cargo test`'s parallel,
/// shared-binary execution (some other test could resolve it first).
fn cached_or_init<T>(cache: &OnceLock<T>, init: impl FnOnce() -> T) -> &T {
    cache.get_or_init(init)
}

/// Resolves the user's real `PATH` by spawning their login shell — the
/// entry point [`cached_shell_path`] caches. Thin wrapper around
/// [`resolve_shell_path_for`] that supplies the real `$SHELL`; kept
/// separate so tests can drive the interesting logic directly with an
/// explicit `Option<&str>` instead of mutating the real process
/// environment (see [`resolve_shell_path_for`]'s tests for why that
/// matters here specifically).
fn resolve_shell_path() -> Option<String> {
    resolve_shell_path_for(std::env::var("SHELL").ok().as_deref())
}

/// Core PATH-resolution logic, parameterized over the shell to use instead
/// of reading `$SHELL` itself. `None` in, or any failure along the way
/// (spawn error, timeout, non-zero exit, empty output), all resolve to
/// `None` out — every one of those is "resolution failed", and every
/// caller already treats `None` as "fall back to today's behavior", so
/// there is no need to distinguish the reasons at this layer.
fn resolve_shell_path_for(shell: Option<&str>) -> Option<String> {
    let shell = shell?;
    spawn_and_capture_path(shell)
}

/// Spawns `<shell> -ilc 'echo -n $PATH'` and returns its trimmed stdout, or
/// `None` if the spawn fails, it doesn't finish within
/// [`SHELL_PATH_RESOLUTION_TIMEOUT`] (in which case the child is left to
/// exit on its own — the timeout only stops *this function* from waiting,
/// it doesn't try to kill a stuck child), it exits non-zero, or its output
/// is empty after trimming.
///
/// `-ilc` (login **and** interactive), not just `-lc` (login only) — see
/// the module docs' "Resolving the real PATH for GUI-launched spawns"
/// section for the empirical reasoning: on this machine (and commonly
/// elsewhere), `PATH` entries added in `.zshrc`/`.bashrc` only take effect
/// for *interactive* shells, login or not, while `-lc` alone only sources
/// the login-only files (`.zprofile`/`.zshenv`/`.zlogin` for zsh) — proven
/// empirically to miss `~/.local/bin` entirely on this machine, where it's
/// added in `.zshrc`.
///
/// Runs on a background thread and waits via a channel `recv_timeout`
/// rather than a bare blocking `Command::output()` call, specifically so a
/// pathological shell profile (infinite loop, a network call that never
/// returns) can't hang session creation forever — `stdin` is already closed
/// (`Stdio::null()`) so a profile script trying to interactively prompt
/// gets immediate EOF instead of blocking, which covers the common case,
/// but doesn't cover every conceivable hang.
fn spawn_and_capture_path(shell: &str) -> Option<String> {
    let shell = shell.to_string();
    let (tx, rx) = mpsc::channel();
    thread::spawn(move || {
        let result = std::process::Command::new(&shell)
            .arg("-ilc")
            .arg("echo -n $PATH")
            .stdin(std::process::Stdio::null())
            .output();
        let _ = tx.send(result);
    });

    let output = rx.recv_timeout(SHELL_PATH_RESOLUTION_TIMEOUT).ok()?.ok()?;
    if !output.status.success() {
        return None;
    }

    let path = String::from_utf8_lossy(&output.stdout).trim().to_string();
    if path.is_empty() {
        None
    } else {
        Some(path)
    }
}

/// Locates the `omniagent-mcp` binary built from this same workspace,
/// relative to the currently running app binary.
///
/// - **Dev** (`cargo tauri dev` / `cargo test`): both binaries land in the
///   same Cargo `target/{debug,release}/` directory, so they're plain
///   siblings.
/// - **Release bundle**: the app binary lives at
///   `OmniAgent.app/Contents/MacOS/omniagent-ade`; we look for
///   `OmniAgent.app/Contents/Resources/omniagent-mcp`.
///   TODO(Phase 8 packaging): nothing copies `omniagent-mcp` into
///   `Contents/Resources` yet — add it to `bundle.resources` in
///   `src-tauri/tauri.conf.json` (or wire it as a Tauri sidecar binary)
///   when Task 8.2 sets up `tauri build`. Until then, release builds will
///   hit the "binary not found" fallback below and Claude sessions launch
///   without MCP wiring — degraded but not broken (DESIGN 5.1: still fully
///   usable, terminals + lexical still work offline-style).
///
/// Returns `None` rather than erroring if it can't be found anywhere —
/// callers must treat that as "spawn claude without `--mcp-config`", never
/// a hard failure per DESIGN principle 5 (the engine must always still run).
pub fn resolve_mcp_server_binary() -> Option<PathBuf> {
    let exe = std::env::current_exe().ok()?;
    resolve_mcp_server_binary_from(&exe)
}

/// Pure, testable core of [`resolve_mcp_server_binary`]: given the path to
/// the running app binary, find the sibling `omniagent-mcp` binary.
pub fn resolve_mcp_server_binary_from(exe: &Path) -> Option<PathBuf> {
    let dir = exe.parent()?;

    let sibling = dir.join("omniagent-mcp");
    if sibling.is_file() {
        return Some(sibling);
    }

    // .app bundle layout: Contents/MacOS/<exe> -> Contents/Resources/omniagent-mcp
    let resources = dir.parent()?.join("Resources").join("omniagent-mcp");
    if resources.is_file() {
        return Some(resources);
    }

    None
}

fn write_mcp_config(mcp_binary: &Path, data_dir: &Path, session_id: &str) -> Result<PathBuf> {
    let config = serde_json::json!({
        "mcpServers": {
            "omniagent": {
                "command": mcp_binary.to_string_lossy(),
                "args": [],
                "env": {
                    "OMNIAGENT_ADE_DATA_DIR": data_dir.to_string_lossy(),
                }
            }
        }
    });
    let path = std::env::temp_dir().join(format!("omniagent-ade-mcp-{session_id}.json"));
    std::fs::write(&path, serde_json::to_vec_pretty(&config)?)
        .with_context(|| format!("write mcp config to {}", path.display()))?;
    Ok(path)
}

fn cleanup_mcp_config(path: &Option<PathBuf>) {
    if let Some(p) = path {
        let _ = std::fs::remove_file(p);
    }
}

/// RAII guard for the temp `--mcp-config` file `build_command` writes for
/// `claude` sessions (see [`write_mcp_config`]). `SessionManager::create`
/// arms one right after the file is written and disarms it only once the
/// session has been fully, successfully created and inserted into the
/// registry — ownership of the file's eventual cleanup passes to the
/// `SessionHandle` (and from there to `kill()`/the natural-exit path,
/// which already clean it up) at that point.
///
/// Any of `create()`'s several fallible steps between those two points
/// (`openpty`, `try_clone_reader`/`take_writer`, `spawn_command`,
/// `append_lifecycle_event`) returning early via `?` instead drops this
/// guard while still armed, deleting the file — without this, every one
/// of those failure paths leaked the file permanently into the system
/// temp dir. Realistic trigger: `claude` isn't on `PATH`, so every
/// "claude" session attempt fails at `spawn_command` and leaks one more
/// file, forever.
struct McpConfigCleanupGuard {
    path: Option<PathBuf>,
    armed: bool,
}

impl McpConfigCleanupGuard {
    fn new(path: Option<PathBuf>) -> Self {
        Self { path, armed: true }
    }

    /// Call once the session is fully, successfully created — the file
    /// (if any) is no longer this guard's responsibility from here on.
    fn disarm(&mut self) {
        self.armed = false;
    }
}

impl Drop for McpConfigCleanupGuard {
    fn drop(&mut self) {
        if self.armed {
            cleanup_mcp_config(&self.path);
        }
    }
}

#[derive(Serialize)]
#[serde(tag = "event", rename_all = "snake_case")]
enum LifecycleEvent {
    Start {
        ts: i64,
        engine: String,
        project: String,
        cwd: String,
    },
    End {
        ts: i64,
        exit_code: Option<u32>,
        signal: Option<String>,
        killed: bool,
    },
}

fn append_lifecycle_event(path: &Path, event: &LifecycleEvent) -> Result<()> {
    let mut f = OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)
        .with_context(|| format!("open lifecycle file {}", path.display()))?;
    let line = serde_json::to_string(event)?;
    writeln!(f, "{line}")?;
    Ok(())
}

/// Incrementally decodes a stream of raw PTY byte chunks as UTF-8,
/// buffering any incomplete trailing multi-byte sequence across calls
/// instead of lossy-converting each raw `read()` result independently.
///
/// PTY `read()`s aren't UTF-8-boundary-aligned: a multi-byte character
/// (box-drawing glyphs like `─│╭╮╰╯` from a TUI redraw, emoji, non-ASCII
/// text) can have its bytes split across two separate reads. Calling
/// `String::from_utf8_lossy` on each raw chunk independently (the bug this
/// type fixes) replaces *both* halves with `U+FFFD`, since neither half is
/// valid UTF-8 on its own, even though the two halves concatenated are
/// perfectly valid. This type instead keeps up to 3 trailing undecoded
/// bytes (the most a valid UTF-8 sequence can still be missing) from one
/// `decode()` call, prepends them to the next chunk, and only
/// lossy-converts the portion that's genuinely, unambiguously invalid —
/// using `std::str::from_utf8`'s error to distinguish "incomplete, might
/// still become valid" (`error_len() == None`, at the very end of the
/// slice) from "genuinely invalid" (`error_len() == Some(_)`), exactly how
/// a streaming UTF-8 decoder is supposed to work.
///
/// Deliberately NOT used for the raw byte stream handed to `sink` (the
/// live terminal view) — xterm.js handles raw bytes correctly on its own,
/// and buffering there would add latency to the live render path for zero
/// benefit. Only the transcript (`pending`) and attention-detection
/// (`marker_window`) paths, which both need real decoded text rather
/// than raw bytes, go through this.
struct Utf8ChunkDecoder {
    /// Trailing bytes from the previous `decode()` call that didn't form a
    /// complete, valid UTF-8 sequence yet — never more than 3 bytes (the
    /// longest a UTF-8 sequence can be missing and still possibly become
    /// valid with more bytes).
    carry: Vec<u8>,
}

impl Utf8ChunkDecoder {
    fn new() -> Self {
        Self { carry: Vec::new() }
    }

    /// Decodes one raw chunk, prepending any carry-over from the previous
    /// call. Returns the decoded text; any incomplete trailing sequence is
    /// retained internally rather than returned, to be prepended to the
    /// *next* `decode()` call.
    fn decode(&mut self, chunk: &[u8]) -> String {
        self.carry.extend_from_slice(chunk);

        let mut out = String::new();
        let mut start = 0usize;
        loop {
            match std::str::from_utf8(&self.carry[start..]) {
                Ok(s) => {
                    out.push_str(s);
                    self.carry.clear();
                    return out;
                }
                Err(e) => {
                    let valid_up_to = e.valid_up_to();
                    // Safe: `from_utf8` already told us this sub-slice is
                    // valid UTF-8.
                    out.push_str(
                        std::str::from_utf8(&self.carry[start..start + valid_up_to]).unwrap(),
                    );
                    match e.error_len() {
                        Some(bad_len) => {
                            // A genuinely invalid byte sequence (not just
                            // incomplete) -- lossy-replace it, same as
                            // `from_utf8_lossy` would, and keep decoding
                            // whatever comes after it in this same chunk.
                            out.push('\u{FFFD}');
                            start += valid_up_to + bad_len;
                        }
                        None => {
                            // The tail is a valid-so-far but incomplete
                            // sequence (ran out of bytes, not into a bad
                            // one) -- carry it over instead of guessing.
                            let tail = self.carry[start + valid_up_to..].to_vec();
                            self.carry = tail;
                            return out;
                        }
                    }
                }
            }
        }
    }

    /// Call once at EOF: there's no more data coming, so any bytes still
    /// held in `carry` are genuinely incomplete (not just "waiting for the
    /// next chunk") and are lossy-replaced rather than silently dropped —
    /// matching `from_utf8_lossy`'s behavior for the same bytes.
    #[cfg(test)]
    fn finish(&mut self) -> String {
        if self.carry.is_empty() {
            return String::new();
        }
        let out = String::from_utf8_lossy(&self.carry).into_owned();
        self.carry.clear();
        out
    }
}

#[cfg(test)]
fn flush_complete_lines(pending: &mut String, file: &mut Option<std::fs::File>) {
    if let Some(idx) = pending.rfind('\n') {
        let split_at = idx + 1;
        let complete: String = pending.drain(..split_at).collect();
        write_redacted(file, &complete);
    }
}

#[cfg(test)]
fn write_redacted(file: &mut Option<std::fs::File>, text: &str) {
    if let Some(f) = file {
        let redacted = redact(text);
        let _ = f.write_all(redacted.as_bytes());
        let _ = f.flush();
    }
}

// -------------------------------------------------------------------------
// Founder-feedback attention detection (see module docs for the
// investigation this came out of).
// -------------------------------------------------------------------------

/// Text stock `claude` prints when it genuinely needs the user:
///
/// - `"Do you want to"` — the shared opening of its tool-permission
///   confirmation dialog (verified against both a Bash-tool prompt, "Do you
///   want to proceed?", and a Write-tool prompt, "Do you want to create
///   notes.txt?" — the trailing wording differs per tool, the opening
///   doesn't).
/// - `"Would you like to"` — the plan-approval dialog's opening ("Would you
///   like to proceed?" after ExitPlanMode), added 2026-07-27 (founder:
///   "every yes or no question must be handled the same way"). Same numbered
///   select, so the panel's Approve ("1") answers it too — note that plan
///   mode's option 1 is "Yes, and auto-accept edits".
///
/// The startup trust prompt ("Quick safety check: Is this a project you
/// trust?") stays deliberately unmatched: it appears the moment the user
/// opens the session — they're looking at it — and blind-approving a trust
/// gate from a notification is exactly the wrong affordance.
const ATTENTION_MARKERS: &[&str] = &["Do you want to", "Would you like to"];

/// How much of the raw (un-redacted) output stream is kept around purely to
/// catch an `ATTENTION_MARKERS` entry split across two PTY `read()` calls.
/// Unlike the transcript's line-buffered redaction, this can't wait for a
/// bare `\n` to flush before checking — Claude's full-screen TUI redraws
/// with cursor-positioning escapes and `\r`, not bare newlines (see the
/// module docs on why the transcript logic has the same problem) — so this
/// is just a small rolling window instead. The longest marker here is well
/// under 64 bytes; 4096 is generous slack for a cheap `contains` scan.
const ATTENTION_WINDOW_BYTES: usize = 4096;

/// Minimum time between two `session-attention` events for the same
/// session. Chosen empirically: a real pending permission prompt was
/// observed redrawing its box roughly twice a second while the user hadn't
/// touched anything yet (a PTY probe run during this task's investigation
/// counted 100+ redraws over 51 real seconds) — without debouncing, every
/// single redraw would independently re-match the marker and fire another
/// event. 15s comfortably collapses an entire redraw storm into one event.
/// It's not trying to bound "how fresh can a second, genuinely different
/// prompt's badge be" — the frontend badge is a sticky boolean cleared only
/// on tab focus (`ui/src/state/sessions.ts`'s `tab/activated` case), not a
/// toast, so a suppressed event during the cooldown never hides a real
/// attention need; it just avoids re-announcing one already flagged.
const ATTENTION_COOLDOWN: Duration = Duration::from_secs(15);

/// How long after the user writes to a session the *status latches* refuse to
/// re-arm — shared by both markers, approval and error (the notification event
/// is unaffected — see the reader thread).
///
/// Clearing the rolling window on input isn't quite enough on its own: the
/// engine's very next repaint after the user answers still contains the
/// dialog they just answered, arrives as genuinely new output, and re-latches
/// red — leaving the light stuck on "needs you" for a prompt that's already
/// handled. Observed for real: through tmux this is load-dependent, and under
/// a fully parallel `cargo test` it happened on essentially every run.
///
/// 750 ms is comfortably longer than a repaint takes to arrive and much
/// shorter than a human answering a second prompt, so a genuinely
/// still-pending prompt (which redraws roughly twice a second) re-latches
/// within about a second of the grace lapsing. The cost of being wrong is
/// bounded and self-correcting in both directions: at worst the light is
/// green for ~1 s too long, never amber forever.
///
/// **The error latch deliberately shares this exact value, and that was a
/// correction.** A separate, much longer error grace (5 s) looked well
/// reasoned on paper — a failure the user just acknowledged has none of a
/// pending prompt's urgency about re-latching — and was flatly wrong in
/// practice. Driving a real `claude` through a failing tool exposed it
/// immediately: the single most common way a failure happens is *the user
/// approving a command that then fails*, and the engine reports that failure
/// within a second or two of the approval keystroke — i.e. inside the very
/// grace meant to protect against stale repaints, so red never fired at all.
/// Measured, not reasoned: run 1 of `manual_status_verify claude` went
/// approval → thinking → **ready**, silently swallowing a real `Exit code 1`.
///
/// A longer grace also never actually bought anything: it only *delays* a
/// repaint re-latch rather than preventing it, because the failure text stays
/// on screen either way. The window clear on user input is what does the real
/// work; this grace only has to outlast the echo of the user's own keystroke.
const ATTENTION_INPUT_GRACE: Duration = Duration::from_millis(750);

fn contains_attention_marker(text: &str) -> bool {
    ATTENTION_MARKERS.iter().any(|marker| text.contains(marker))
}

// -------------------------------------------------------------------------
// Error detection (Bruno's red, 2026-07-26: "an error occurred, a process
// failed, or a block exists"). See the module docs' "Five-state session
// status" section for the full investigation, including the zero-config wall
// that stops this from covering plain `shell` sessions at all.
// -------------------------------------------------------------------------

/// The label Claude Code prints in a tool-result line when a Bash tool exits
/// non-zero — measured, not guessed, against real `claude` 2.1.220 running
/// `ls /nonexistent-path-xyz-123` through this app's own tmux config.
///
/// **It renders in (at least) two forms, and which one you get depends on the
/// terminal width.** This cost a whole verification round to find, and is the
/// reason [`contains_error_marker`] is not a plain `contains`:
///
/// ```text
/// # 120 columns — inline, em-dash, digit immediately after the label:
/// ⎿  Exit code 1 — ls: /nonexistent-path-xyz-123: No such file or directory
///
/// # 80 columns (what a freshly-created ADE pane actually is) — a label with
/// # a colon, and the value bolded, i.e. an SGR escape *between* the two:
/// ⎿  Exit code: \x1b[1m1\x1b(B\x1b[m
/// ```
///
/// The first probe of this feature was done at 120 columns and produced a
/// marker (`"Exit code "`, trailing space, digit next) that matched nothing at
/// all in a real ADE session: the pane is opened at 24×80, so every live
/// session hit the second form. Only the label itself is common to both, so
/// only the label is matched, and the digit is looked for past any escapes.
///
/// Matching works at all because the ADE reads tmux's re-rendered stream:
/// Claude's *own* PTY output is word-addressed (`Running\x1b[11G1\x1b[13Gshell…`)
/// and would defeat any substring match (see the module docs).
///
/// A successful command prints **no** exit-code line in either form (verified
/// in the same real session: 197 occurrences of this label, every one of them
/// `Exit code: 1` from the failing command, none from the `sleep && echo` that
/// succeeded in the same run), so the label is already failure-specific. The
/// digit check is what keeps prose — "check the Exit code manually" — from
/// lighting a session red, and future-proofs an `Exit code: 0` that today
/// doesn't exist.
const ERROR_MARKER: &str = "Exit code";

/// True when `text` contains a non-zero `Exit code N` report.
///
/// The label must be followed by an actual numeric value — that is what
/// separates a rendered result field from prose — and that value must not be
/// `0`. "Followed by" is evaluated with [`first_value_char_after`], because
/// the value is commonly separated from the label by a colon and an SGR
/// escape (see [`ERROR_MARKER`]).
///
/// A small explicit scan rather than a regex: this runs on every PTY chunk of
/// every tracked session, and the crate has no regex dependency.
fn contains_error_marker(text: &str) -> bool {
    text.match_indices(ERROR_MARKER).any(|(idx, _)| {
        first_value_char_after(&text[idx + ERROR_MARKER.len()..])
            .is_some_and(|c| c.is_ascii_digit() && c != '0')
    })
}

/// The first character a *user* would see after a label — skipping ANSI escape
/// sequences and the `:`/whitespace a label uses to separate itself from its
/// value, and stopping at a line break (a value never lives on the next line).
///
/// Escapes have to be skipped structurally rather than by hunting for the
/// first digit: `\x1b[1m` (bold on, which is exactly what Claude wraps the
/// exit code in) *contains* the digit `1`, so a naive digit scan would report
/// "failure" for every bolded value on screen, including `Exit code: 0`.
///
/// Handles the two escape shapes that actually occur in this stream — CSI
/// (`ESC [` … final byte in `@`–`~`) and the character-set designators
/// (`ESC (B`, `ESC )0`) tmux emits — and treats anything else introduced by
/// `ESC` as a two-byte sequence. It is not a general terminal parser and does
/// not need to be: it only has to walk a handful of bytes between a label and
/// its value.
fn first_value_char_after(text: &str) -> Option<char> {
    let bytes = text.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        match bytes[i] {
            0x1b => {
                i += 1;
                match bytes.get(i) {
                    Some(b'[') => {
                        i += 1;
                        while i < bytes.len() && !(0x40..=0x7e).contains(&bytes[i]) {
                            i += 1;
                        }
                        i += 1; // the final byte
                    }
                    // `ESC (B`, `ESC )0` — designator plus its argument.
                    Some(b'(') | Some(b')') | Some(b'#') => i += 2,
                    Some(_) => i += 1,
                    None => return None,
                }
            }
            b':' | b' ' | b'\t' => i += 1,
            b'\r' | b'\n' => return None,
            _ => return text[i..].chars().next(),
        }
    }
    None
}

// -------------------------------------------------------------------------
// Tool-execution detection for claude/codex (Bruno's cyan). Screen state, not
// stream events — see `status_from_screen`.
// -------------------------------------------------------------------------

/// Text that is on a Claude Code screen **only while a Bash tool is actually
/// running**, matched against `tmux capture-pane` output.
///
/// Measured against real `claude` 2.1.220 wrapped in this app's tmux config,
/// running `sleep 8 && echo …`. Claude renders a live tool block:
///
/// ```text
/// ⏺  Running 1 shell command · 3s…
///   ⎿  $ sleep 8 && echo TOOL_DONE_MARKER (3s)
///      (ctrl+b ctrl+b (twice) to run in background)
/// ```
///
/// and replaces the whole block with `Ran 1 shell command` the moment it
/// finishes. The backgrounding hint is the marker used here because it is the
/// one line in that block that cannot survive the tool ending — it is the
/// affordance for a *running* command. (Note Claude even adapts it to its
/// host: outside tmux it reads `(ctrl+b to run in background)`, inside tmux
/// `(ctrl+b ctrl+b (twice) …)` — hence matching only the invariant tail.)
///
/// **Why not the more obvious candidates**, all measured and all rejected:
/// - `Running 1 shell command` — the noun phrase is per-tool-kind
///   (`Listing 1 directory…` for `ls`, and so on), so matching it would mean
///   tracking Claude Code's internal tool vocabulary release by release; and
///   the completed form (`Ran 1 shell command`) shares the same words, so
///   presence never meant "running" in the first place.
/// - The spinner line (`✻ Cascading… (14s · ↓ 92 tokens)`) — present for
///   thinking *and* tool execution alike, so it can't separate them; its verb
///   is randomised per turn anyway.
/// - The process tree under the pane's pid — the honest-looking answer, and it
///   fails hard in practice: sampling a real session's descendants showed a
///   constant churn of `sh`, `bash`, `node`, `bun`, `python` children spawned
///   by MCP servers, status-line commands and hooks, indistinguishable from a
///   Bash tool's own shell.
///
/// The honest cost of this marker: Claude only draws the elapsed timer (and
/// this hint) after the command has been running ~3 s, so tool executions
/// shorter than that never turn the light cyan — they read as `thinking`,
/// which is not a lie, just less specific. And like every marker here it is
/// UI copy: a future Claude Code that reworded it silently degrades this to
/// `thinking` rather than reporting anything wrong.
#[cfg(test)]
const TOOL_EXECUTION_SCREEN_MARKERS: &[&str] = &["to run in background)"];

/// Keeps `s` at most `max_bytes` long by dropping from the front, snapping
/// the cut point forward to the nearest `char` boundary (a `String` can't be
/// sliced/drained mid-character) — at most a few bytes' extra slack per
/// call since UTF-8 characters are never more than 4 bytes.
fn trim_to_last_n_bytes(s: &mut String, max_bytes: usize) {
    if s.len() <= max_bytes {
        return;
    }
    let mut cut = s.len() - max_bytes;
    while cut < s.len() && !s.is_char_boundary(cut) {
        cut += 1;
    }
    s.drain(..cut);
}

/// Per-session rate limiter for attention events — see [`ATTENTION_COOLDOWN`]
/// for the reasoning behind the default duration. Takes `Instant` as an
/// explicit parameter (rather than calling `Instant::now()` internally) so
/// its own tests can drive it with synthetic, zero-real-time timestamps
/// instead of sleeping — `Instant + Duration` arithmetic is deterministic
/// and doesn't require a real clock to advance.
struct AttentionDebouncer {
    cooldown: Duration,
    last_fired: Option<Instant>,
}

impl AttentionDebouncer {
    fn new(cooldown: Duration) -> Self {
        Self {
            cooldown,
            last_fired: None,
        }
    }

    /// Call once per marker match. Returns `true` exactly when the caller
    /// should actually fire the attention event (first-ever match, or the
    /// cooldown has elapsed since the last one it approved) — and records
    /// `now` as the new "last fired" instant whenever it does.
    fn should_fire(&mut self, now: Instant) -> bool {
        let fire = match self.last_fired {
            None => true,
            Some(last) => now.duration_since(last) >= self.cooldown,
        };
        if fire {
            self.last_fired = Some(now);
        }
        fire
    }
}

// -------------------------------------------------------------------------
// Traffic-light status (Bruno, 2026-07-26: "Green means ready for any new
// command, yellow means executing, red means requires attention or input").
// See the module docs for the per-engine heuristics and their limits.
// -------------------------------------------------------------------------

/// How often the single background poller re-evaluates every live session.
/// 300 ms is comfortably under the ~1 s at which a status light starts to
/// feel laggy, while keeping the tmux `display-message` cost (one short-lived
/// local IPC per tmux-backed session per tick) negligible. Nothing is emitted
/// unless the state actually changed, so this cadence is a *detection*
/// latency, not an event rate.
const STATUS_POLL_INTERVAL: Duration = Duration::from_millis(300);

/// How long a session must produce no output at all before the
/// output-activity heuristic calls it idle. Used for `claude`/`codex` always
/// (their pane command is uninformative), and for every engine when tmux
/// isn't available.
///
/// 700 ms is a deliberate compromise: long enough that the gaps *within* a
/// working engine's output (a model streaming a response, a TUI redrawing
/// between tool calls) don't flicker the light green, short enough that
/// finishing a turn shows up as ready almost immediately. It cannot
/// distinguish "thinking silently" from "waiting for input" — no stock engine
/// exposes a signal that could (module docs).
const OUTPUT_QUIET_THRESHOLD: Duration = Duration::from_millis(700);

/// How long an unbroken run of output must last before it counts as
/// "executing" rather than as an idle TUI twitching.
///
/// This exists because of a measurement, not a hunch. A real, *completely
/// idle* `claude` session (2.1.220, watched for 30 s through this very
/// module) is not silent: it emits a tight burst of ~3 chunks / ~2.5 KB —
/// all within about 50 ms of each other — and then says nothing for **4 to 8
/// seconds**, over and over. Recency alone therefore made the light flip to
/// yellow and back roughly every 8 s on a session where nothing whatsoever
/// was happening; observed live before this constant existed.
///
/// Requiring the run itself to be ≥ 1 s cleanly separates the two regimes:
/// an idle burst is over in ~50 ms and never qualifies, while real work
/// (streaming tokens, a tool's output) sustains output for seconds. The
/// trade-off is honest and bounded — "executing" appears about a second
/// late, and an engine that genuinely works in isolated sub-second bursts
/// several seconds apart reads as ready. tmux-backed `shell` sessions don't
/// rely on any of this: they get the exact foreground-command answer.
const SUSTAINED_ACTIVITY_MIN: Duration = Duration::from_millis(1000);

/// How long after a keystroke the activity heuristic refuses to call the
/// session busy (founder, 2026-07-26: "I also don't want the executing
/// effect to be triggered when I'm typing").
///
/// The problem it solves: the engines echo. Each keystroke makes a
/// `claude`/`codex` TUI repaint its input box, so someone typing at a normal
/// rhythm (a keystroke every few hundred ms) produces exactly the sustained
/// output run that [`status_from_output_activity`] reads as busy — the pane
/// lit up as "thinking" for the duration of every prompt the user typed.
/// While they keep typing, every keystroke re-arms this grace, so the light
/// stays quiet no matter how long the prompt; once they stop, the echo stops
/// with them and the quiet threshold wins anyway.
///
/// One second, same order as [`SUSTAINED_ACTIVITY_MIN`] and a judgment call
/// rather than a measurement: long enough to cover an engine's trailing
/// echo repaints, short enough that real work the user kicks off with Enter
/// shows busy at most a second later than it otherwise would (the run
/// clock keeps counting through the grace — suppression hides the label,
/// it does not reset the run).
///
/// What the grace DOES changed on 2026-07-26, second founder round. It used
/// to force `Ready`, which dipped a genuinely streaming session to green
/// under every keystroke — shipped as a "known, accepted edge", rejected on
/// sight ("whenever I do it, it turns into green. I don't like it"). It now
/// FREEZES the status at whatever was true as the burst began
/// ([`SessionActivity::status_when_typing_began`]): quiet stays quiet under
/// echo, busy stays busy under typing.
const TYPING_ECHO_GRACE: Duration = Duration::from_millis(1000);

/// Foreground commands that mean "this pane is sitting at a prompt". `-zsh`
/// / `-bash` are the login-shell argv[0] convention; `login` is what macOS
/// puts in front of a login shell.
#[cfg(test)]
const IDLE_SHELL_COMMANDS: &[&str] = &[
    "zsh", "bash", "fish", "sh", "dash", "ksh", "tcsh", "csh", "-zsh", "-bash", "-sh", "-fish",
    "login",
];

#[cfg(test)]
fn is_idle_shell_command(pane_command: &str) -> bool {
    IDLE_SHELL_COMMANDS.contains(&pane_command)
}

/// True when `data` consists purely of terminal pointer traffic: SGR mouse
/// reports (`ESC [ < b;x;y M|m` — presses, releases, wheel and motion),
/// legacy X10 reports (`ESC [ M` + 3 bytes), or focus in/out (`ESC [ I` /
/// `ESC [ O`).
///
/// Exists because the engines turn mouse tracking on, so xterm.js forwards
/// every pointer movement over the pane as PTY input — and counting that as
/// "the user typed" armed [`TYPING_ECHO_GRACE`] and cleared the attention
/// latch on a hover (founder, 2026-07-26: "it shouldn't change the status
/// based on whether I'm hovering"). Pointer reports still go TO the pty —
/// the TUI wants them — they just aren't evidence the user responded to
/// anything. A chunk mixing pointer reports with real keys counts as typing
/// (xterm.js emits them separately in practice; mixed means keys were hit).
fn is_pointer_report(data: &str) -> bool {
    let bytes = data.as_bytes();
    if bytes.is_empty() {
        return false;
    }
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] != 0x1b || i + 1 >= bytes.len() || bytes[i + 1] != b'[' {
            return false;
        }
        i += 2;
        match bytes.get(i) {
            Some(b'I') | Some(b'O') => i += 1,
            Some(b'M') => {
                // X10: exactly three payload bytes follow.
                i += 4;
                if i > bytes.len() {
                    return false;
                }
            }
            Some(b'<') => {
                i += 1;
                while i < bytes.len() && (bytes[i].is_ascii_digit() || bytes[i] == b';') {
                    i += 1;
                }
                if !matches!(bytes.get(i), Some(b'M') | Some(b'm')) {
                    return false;
                }
                i += 1;
            }
            _ => return false,
        }
    }
    true
}

/// What a tmux pane's foreground command tells us, if anything.
///
/// - A shell → the pane is at a prompt: **ready**, whatever the engine is.
/// - Anything else in a `shell` session → a real command is running:
///   **tool_execution**. For a terminal session, "a foreground command is
///   running" *is* Bruno's cyan ("active tool execution, like terminal
///   commands") — there is nothing else a shell could be doing. This is also
///   the case output-activity can't see at all (`sleep 4` prints nothing).
/// - Anything else in a `claude`/`codex` session → `None`: the engine is
///   *always* the pane's foreground command, so this signal carries no
///   information and the caller must fall back to output activity. Measured,
///   not assumed: a real `claude` 2.1.220 pane reports a stable process title
///   = `2.1.220` (the process title Claude Code sets), and it keeps reporting
///   that while a Bash tool runs, because Claude spawns tool commands as
///   ordinary children without handing them the tty's foreground process
///   group.
#[cfg(test)]
fn status_from_pane_command(pane_command: &str, engine: &str) -> Option<SessionStatus> {
    if is_idle_shell_command(pane_command) {
        return Some(SessionStatus::Ready);
    }
    if engine == "shell" {
        return Some(SessionStatus::ToolExecution);
    }
    None
}

/// The fallback signal: is this session *sustainedly* producing output, and
/// what does that mean for this engine?
///
/// Both halves of the activity test are required, and the second one is what
/// makes this usable rather than a strobe light (see
/// [`SUSTAINED_ACTIVITY_MIN`]): output must have arrived within
/// [`OUTPUT_QUIET_THRESHOLD`] **and** the unbroken run it belongs to must
/// already be [`SUSTAINED_ACTIVITY_MIN`] long.
///
/// The engine decides how "busy" is *labelled*, and this is the honest split:
/// a `shell` producing output is by definition running a command
/// (**tool_execution**), while a `claude`/`codex` producing output is the
/// engine working — which, absent a separate tool signal, is
/// **thinking**. See [`status_from_screen`] for the one case where that
/// second answer is refined into `ToolExecution`, and the module docs for why
/// it isn't refined more often.
fn status_from_output_activity(activity: &SessionActivity, now: Instant) -> SessionStatus {
    // Inside the typing grace the status is FROZEN at whatever was true when
    // the burst began ([`SessionActivity::status_when_typing_began`]): echo
    // must not light a quiet pane up, and — founder, 2026-07-26, second
    // round — a keystroke into a busy pane must not dip it to green either.
    // The run clock is left alone on purpose: the moment the grace expires,
    // a genuinely busy session is already past SUSTAINED_ACTIVITY_MIN and
    // reads busy immediately. (Freezing also means a session that finishes
    // mid-burst stays busy-coloured up to a grace past the last keystroke —
    // bounded, and self-correcting the moment the typing pauses.)
    let typed = activity
        .last_user_input
        .lock()
        .map(|g| *g)
        .unwrap_or_else(|e| *e.into_inner());
    if let Some(typed) = typed {
        if now.saturating_duration_since(typed) < TYPING_ECHO_GRACE {
            let held = activity
                .status_when_typing_began
                .lock()
                .map(|g| *g)
                .unwrap_or_else(|e| *e.into_inner());
            return held.unwrap_or(SessionStatus::Ready);
        }
    }
    activity
        .raw_busy_status(now)
        .unwrap_or(SessionStatus::Ready)
}

/// What "this session is producing sustained output" means for each engine.
fn busy_status_for_engine(engine: &str) -> SessionStatus {
    if engine == "shell" {
        SessionStatus::ToolExecution
    } else {
        SessionStatus::Thinking
    }
}

/// Refines a busy `claude`/`codex` session from `Thinking` to `ToolExecution`
/// when — and only when — its **visible screen** says a tool is running right
/// now.
///
/// `screen` is a legacy captured terminal snapshot. Using screen *state*
/// rather than the PTY *stream* was the point of this classifier: a
/// running tool is a state that ends, and a stream-scan latch would leave cyan
/// stuck on long after the command finished.
///
/// See [`TOOL_EXECUTION_SCREEN_MARKERS`] for what is matched and why that one
/// string, and the module docs for the far larger set of candidate signals
/// that were measured and rejected.
#[cfg(test)]
fn status_from_screen(screen: &str) -> Option<SessionStatus> {
    TOOL_EXECUTION_SCREEN_MARKERS
        .iter()
        .any(|m| screen.contains(m))
        .then_some(SessionStatus::ToolExecution)
}

/// The full five-state decision for one session, in priority order:
///
/// 1. **awaiting_approval** — blocked on the user. Outranks everything: it is
///    the only state where nothing at all will happen until they act.
/// 2. **error** — something failed and they should look. Below approval
///    because if the engine is *also* asking for permission, that's the
///    actionable one. With tmux this is reconciled against the live screen —
///    see [`resolve_error`].
/// 3. **tmux's foreground-command signal**, where it means anything (shell
///    sessions).
/// 4. **output activity** → `ready` / `thinking` / `tool_execution`, refined
///    for a busy `claude`/`codex` by a look at the screen
///    ([`status_from_screen`]).
///
/// The pane screen is captured **at most once per call and only when
/// something actually needs it** — a latched error to reconcile, or a busy
/// `claude`/`codex` whose busy-state is ambiguous. An idle session with no
/// error, and every `shell` session, costs exactly what it cost before any of
/// this existed: one `display-message`.
fn compute_status(
    activity: &SessionActivity,
    _daemon_sessions: Option<&DaemonSessions>,
    now: Instant,
) -> SessionStatus {
    if activity.attention.load(Ordering::Relaxed) {
        return SessionStatus::AwaitingApproval;
    }
    if activity.error.load(Ordering::Relaxed) && !activity.error_dismissed.load(Ordering::Relaxed) {
        return SessionStatus::Error;
    }
    status_from_output_activity(activity, now)
}

/// Decides whether a latched failure should still be shown, given what the
/// pane currently displays (`None` = no screen available: no tmux, or the
/// capture failed).
///
/// Three outcomes, and the middle one is the reason this function exists:
///
/// - **The failure is gone from the screen** → release everything. The line
///   has scrolled out of the conversation; there is nothing left to point at,
///   and a genuinely new failure must be able to latch again.
/// - **Still on screen, but the user has moved on** ([`SessionActivity::
///   error_dismissed`]) → don't report it. This is what stops the light
///   becoming permanently red: the engine repaints the pane constantly and
///   every repaint re-delivers the same failure line to the stream scanner.
/// - **Still on screen and not yet acknowledged** → red.
///
/// With no screen to consult the latch is taken at face value, except that a
/// dismissal is still honoured — a failure the user has already answered for
/// must not come back merely because tmux hiccupped.
#[cfg(test)]
fn resolve_error(activity: &SessionActivity, screen: Option<&str>) -> bool {
    if let Some(screen) = screen {
        if !contains_error_marker(screen) {
            activity.error.store(false, Ordering::Relaxed);
            activity.error_dismissed.store(false, Ordering::Relaxed);
            return false;
        }
    }
    !activity.error_dismissed.load(Ordering::Relaxed)
}

/// One background thread for the whole manager (not one per session) that
/// re-evaluates every live session's traffic light and calls `sink` **only on
/// a change**.
///
/// Holds a [`Weak`] reference to the session registry, so it shuts itself
/// down once the `SessionManager` and every reader thread are gone rather
/// than polling a dead app forever — which is also what makes the
/// "simulate the app dying by dropping the manager" test terminate cleanly.
///
/// Each tick snapshots `(id, Arc<SessionActivity>)` under the registry lock
/// and then **releases it** before computing anything: `compute_status` can
/// shell out to tmux, and holding the registry lock across a subprocess call
/// would stall every concurrent `write`/`resize`/`create` — the same mistake
/// the natural-exit path was already fixed for.
fn spawn_status_poller(
    sessions: Weak<Mutex<HashMap<String, SessionHandle>>>,
    sink: StatusSink,
) -> thread::JoinHandle<()> {
    thread::spawn(move || loop {
        thread::sleep(STATUS_POLL_INTERVAL);

        let Some(sessions) = sessions.upgrade() else {
            return; // the app (or the test) is gone
        };

        let snapshot: Vec<(String, Arc<SessionActivity>)> = {
            let Ok(guard) = sessions.lock() else {
                return;
            };
            guard
                .iter()
                .map(|(id, handle)| (id.clone(), Arc::clone(&handle.activity)))
                .collect()
        };
        // Registry lock released before any daemon call below.
        drop(sessions);

        let now = Instant::now();
        for (id, activity) in snapshot {
            let status = compute_status(&activity, None, now);
            let changed = match activity.last_status.lock() {
                Ok(mut last) => {
                    let changed = *last != Some(status);
                    if changed {
                        *last = Some(status);
                    }
                    changed
                }
                Err(_) => false,
            };
            if changed {
                sink(&SessionStatusEvent::new(&id, status, &activity.engine));
            }
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Materializes a request the way the direct-spawn path in `create()`
    /// does — `build_engine_command` + `to_command_builder`, i.e. the real
    /// production composition, not a parallel implementation. Exists only so
    /// the env-wiring tests below can inspect a `CommandBuilder` without
    /// spawning anything.
    fn build_command(
        req: &CreateSessionRequest,
        data_dir: &Path,
        session_id: &str,
    ) -> Result<(CommandBuilder, Option<PathBuf>)> {
        let engine_cmd = build_engine_command(req, data_dir, session_id, ClaudeIdentity::Claim)?;
        let cmd = engine_cmd.to_command_builder();
        Ok((cmd, engine_cmd.mcp_config_path))
    }

    #[test]
    fn resolves_dev_sibling_binary() {
        let tmp = tempfile::tempdir().unwrap();
        let target_debug = tmp.path().join("target/debug");
        std::fs::create_dir_all(&target_debug).unwrap();
        let exe = target_debug.join("omniagent-ade");
        let mcp = target_debug.join("omniagent-mcp");
        std::fs::write(&exe, b"fake").unwrap();
        std::fs::write(&mcp, b"fake").unwrap();

        let resolved = resolve_mcp_server_binary_from(&exe);
        assert_eq!(resolved, Some(mcp));
    }

    #[test]
    fn resolves_app_bundle_resources_binary() {
        let tmp = tempfile::tempdir().unwrap();
        let macos_dir = tmp.path().join("OmniAgent.app/Contents/MacOS");
        let resources_dir = tmp.path().join("OmniAgent.app/Contents/Resources");
        std::fs::create_dir_all(&macos_dir).unwrap();
        std::fs::create_dir_all(&resources_dir).unwrap();
        let exe = macos_dir.join("omniagent-ade");
        let mcp = resources_dir.join("omniagent-mcp");
        std::fs::write(&exe, b"fake").unwrap();
        std::fs::write(&mcp, b"fake").unwrap();

        let resolved = resolve_mcp_server_binary_from(&exe);
        assert_eq!(resolved, Some(mcp));
    }

    #[test]
    fn returns_none_gracefully_when_binary_missing() {
        let tmp = tempfile::tempdir().unwrap();
        let dir = tmp.path().join("target/debug");
        std::fs::create_dir_all(&dir).unwrap();
        let exe = dir.join("omniagent-ade");
        std::fs::write(&exe, b"fake").unwrap();

        assert_eq!(resolve_mcp_server_binary_from(&exe), None);
    }

    #[test]
    fn codex_gets_omniagent_mcp_wiring() {
        let exe = std::env::current_exe().unwrap();
        let sibling = exe.parent().unwrap().join("omniagent-mcp");
        std::fs::write(&sibling, b"fake").unwrap();
        struct RemoveOnDrop(PathBuf);
        impl Drop for RemoveOnDrop {
            fn drop(&mut self) {
                let _ = std::fs::remove_file(&self.0);
            }
        }
        let _sibling_guard = RemoveOnDrop(sibling.clone());

        let tmp = tempfile::tempdir().unwrap();
        let req = CreateSessionRequest {
            project: "demo".into(),
            engine: "codex".into(),
            cwd: tmp.path().to_string_lossy().into_owned(),
            briefing: None,
            restore_id: None,
        };
        let cmd = build_engine_command(&req, tmp.path(), "sess-codex-mcp", ClaudeIdentity::Stock)
            .unwrap();

        assert_eq!(cmd.argv[1], "--config");
        assert!(cmd.argv[2].contains("mcp_servers.omniagent="));
        assert!(cmd.argv[2].contains(&serde_json::to_string(&sibling.to_string_lossy()).unwrap()));
        assert!(
            cmd.argv[2].contains(&serde_json::to_string(&tmp.path().to_string_lossy()).unwrap())
        );
    }

    #[test]
    fn rejects_unknown_engine() {
        let tmp = tempfile::tempdir().unwrap();
        let req = CreateSessionRequest {
            project: "demo".into(),
            engine: "not-a-real-engine".into(),
            cwd: tmp.path().to_string_lossy().into_owned(),
            briefing: None,
            restore_id: None,
        };
        let err = build_command(&req, tmp.path(), "sess-test").unwrap_err();
        assert!(err.to_string().contains("unsupported engine"));
    }

    /// **The guard for the bug this dispatch actually shipped with.**
    ///
    /// When the frontend's engine list was widened from three agents to five,
    /// this match was left at three. Every unit test still passed — each one
    /// covered a single agent, and none asked "is every agent the app offers
    /// actually spawnable?". The result was a Copilot row the user could
    /// tick, install, and select, that then failed at `session_create` with
    /// "unsupported engine".
    ///
    /// So: walk the SAME table `agents_check_installed` reports from. Any
    /// agent that can be offered in the UI must build a command here, and its
    /// argv must lead with that agent's real binary (`agy`, not
    /// "antigravity"). Adding a row to `AGENTS` without an arm here now fails
    /// this test instead of shipping.
    #[test]
    fn every_offerable_agent_can_be_spawned() {
        let tmp = tempfile::tempdir().unwrap();

        for spec in crate::commands::agents::AGENTS {
            let req = CreateSessionRequest {
                project: "demo".into(),
                engine: spec.name.into(),
                cwd: tmp.path().to_string_lossy().into_owned(),
                briefing: None,
                restore_id: None,
            };
            let (cmd, _mcp_cfg) =
                build_command(&req, tmp.path(), "sess-test").unwrap_or_else(|e| {
                    panic!("engine {:?} is offered but cannot spawn: {e}", spec.name)
                });

            let argv = cmd.get_argv();
            let argv0 = argv
                .first()
                .unwrap_or_else(|| panic!("{}: empty argv", spec.name))
                .to_string_lossy()
                .into_owned();
            let argv0 = &argv0;
            match spec.binary {
                // Built-in: whatever $SHELL resolved to, not a table entry.
                None => assert!(!argv0.is_empty(), "{}: empty shell path", spec.name),
                Some(bin) => assert!(
                    argv0 == bin || argv0.ends_with(&format!("/{bin}")),
                    "{}: spawns {argv0:?}, expected its registered binary {bin:?}",
                    spec.name
                ),
            }
        }
    }

    /// Copilot restore parity with Claude: a fresh Copilot pane *claims* its
    /// conversation with `--session-id <uuid>`, and a restored one *resumes*
    /// it with `--resume <uuid>` — the same flags, and the same derived UUID,
    /// Claude uses. This is what lets a Copilot session come back to its own
    /// history after the daemon session is gone, instead of starting blank.
    #[test]
    fn copilot_claims_a_conversation_when_new_and_resumes_its_own_when_restored() {
        let tmp = tempfile::tempdir().unwrap();
        let req = CreateSessionRequest {
            project: "demo".into(),
            engine: "copilot".into(),
            cwd: tmp.path().to_string_lossy().into_owned(),
            briefing: None,
            restore_id: None,
        };
        let uuid = claude_conversation_uuid("sess-copilot");

        let claim = build_engine_argv(&req, tmp.path(), "sess-copilot", ClaudeIdentity::Claim)
            .unwrap()
            .argv;
        assert_eq!(
            claim,
            vec![
                "copilot".to_string(),
                "--session-id".to_string(),
                uuid.clone()
            ],
            "a new copilot pane must claim its conversation id"
        );

        let resume = build_engine_argv(&req, tmp.path(), "sess-copilot", ClaudeIdentity::Resume)
            .unwrap()
            .argv;
        assert_eq!(
            resume,
            vec!["copilot".to_string(), "--resume".to_string(), uuid],
            "a restored copilot pane must resume its own conversation"
        );

        // Stock (attaching to a live daemon session, or the ladder's last
        // rung) carries no flag — bit-for-bit the stock CLI.
        let stock = build_engine_argv(&req, tmp.path(), "sess-copilot", ClaudeIdentity::Stock)
            .unwrap()
            .argv;
        assert_eq!(stock, vec!["copilot".to_string()]);
    }

    /// Antigravity has no conversation-identity flags, so it must stay bare on
    /// every rung — the identity mechanism is Claude/Copilot-only.
    #[test]
    fn antigravity_never_carries_a_conversation_flag() {
        let tmp = tempfile::tempdir().unwrap();
        let req = CreateSessionRequest {
            project: "demo".into(),
            engine: "antigravity".into(),
            cwd: tmp.path().to_string_lossy().into_owned(),
            briefing: None,
            restore_id: None,
        };
        for identity in [
            ClaudeIdentity::Claim,
            ClaudeIdentity::Resume,
            ClaudeIdentity::Stock,
        ] {
            let argv = build_engine_argv(&req, tmp.path(), "sess-agy", identity)
                .unwrap()
                .argv;
            assert_eq!(argv, vec!["agy".to_string()], "{identity:?}");
        }
    }

    // -- Shell-PATH resolution (founder bug, 2026-07-25 -- see module docs
    // for the full "Resolving the real PATH for GUI-launched spawns"
    // writeup) --------------------------------------------------------

    /// Proves the caching *mechanism* itself: the `init` closure passed to
    /// `cached_or_init` must run at most once, no matter how many times the
    /// accessor is called, with every call after the first reusing the
    /// cached value. Deliberately uses a fresh, test-local `OnceLock` (not
    /// the real process-global `SHELL_PATH` `cached_shell_path` uses) so
    /// this is fully deterministic and independent of `cargo test`'s
    /// parallel, shared-binary execution -- a test asserting call counts
    /// against the *real* global cache would be racy, since some other test
    /// in this binary might resolve it first.
    #[test]
    fn cached_or_init_only_calls_the_resolver_once_across_multiple_calls() {
        let cache: OnceLock<Option<String>> = OnceLock::new();
        let calls = AtomicU64::new(0);

        let a = cached_or_init(&cache, || {
            calls.fetch_add(1, Ordering::SeqCst);
            Some("fake-resolved-path".to_string())
        });
        let b = cached_or_init(&cache, || {
            calls.fetch_add(1, Ordering::SeqCst);
            Some("fake-resolved-path".to_string())
        });
        let c = cached_or_init(&cache, || {
            calls.fetch_add(1, Ordering::SeqCst);
            Some("fake-resolved-path".to_string())
        });

        assert_eq!(a.as_deref(), Some("fake-resolved-path"));
        assert_eq!(a, b);
        assert_eq!(b, c);
        assert_eq!(
            calls.load(Ordering::SeqCst),
            1,
            "the resolver must run exactly once; later calls must reuse the cached value"
        );
    }

    /// Graceful fallback, case 1: no shell configured at all. Exercises
    /// `resolve_shell_path_for` directly with `None` rather than mutating
    /// the real `$SHELL` env var -- `resolve_shell_path` (the thin wrapper
    /// that actually reads `$SHELL`) is a one-line composition of this, and
    /// mutating process env vars here would risk racing the real,
    /// process-global `cached_shell_path` if some concurrently-running test
    /// happened to trigger its first-ever resolution at the same moment.
    #[test]
    fn resolve_shell_path_for_returns_none_when_no_shell_is_configured() {
        assert_eq!(resolve_shell_path_for(None), None);
    }

    /// Graceful fallback, case 2: `$SHELL` is set but doesn't point at a
    /// real, spawnable binary -- the spawn itself must fail cleanly, not
    /// panic or hang.
    #[test]
    fn resolve_shell_path_for_returns_none_when_the_shell_binary_does_not_exist() {
        assert_eq!(
            resolve_shell_path_for(Some("/no/such/shell/binary/on/this/machine")),
            None
        );
    }

    #[test]
    fn preferred_shell_binary_ignores_a_stale_shell_env_path() {
        let shell = preferred_shell_binary(Some("/no/such/shell/binary/on/this/machine"));
        assert_ne!(shell, "/no/such/shell/binary/on/this/machine");
        assert!(
            daemon::is_executable_file(Path::new(&shell)),
            "fallback shell must be executable, got {shell}"
        );
    }

    #[test]
    fn preferred_shell_binary_returns_an_executable_when_shell_env_is_missing() {
        let shell = preferred_shell_binary(None);
        assert!(
            daemon::is_executable_file(Path::new(&shell)),
            "missing $SHELL must still resolve to an executable shell, got {shell}"
        );
    }

    /// The real proof this task called out specifically: run the actual
    /// resolution logic against this machine's real `$SHELL`. Soft-guarded
    /// rather than hard-failed on the exact `~/.local/bin` marker, since a
    /// stock CI box won't have this developer's home directory -- but if
    /// that exact directory *is* present (i.e. this is genuinely Bruno's
    /// machine, where the bug was reported and `claude` really does live at
    /// `~/.local/bin/claude`), assert the resolution actually found it.
    #[test]
    fn resolve_shell_path_finds_the_real_login_shell_path_on_this_machine() {
        let Some(resolved) = resolve_shell_path() else {
            eprintln!(
                "resolve_shell_path() returned None on this machine (no $SHELL, or \
                 resolution failed) -- nothing further to assert"
            );
            return;
        };

        assert!(
            !resolved.trim().is_empty(),
            "a successful resolution must never yield an empty PATH"
        );

        let home = std::env::var("HOME").unwrap_or_default();
        let marker = format!("{home}/.local/bin");
        if std::path::Path::new(&marker).is_dir() {
            assert!(
                resolved.contains(&marker),
                "resolved PATH should contain {marker} on this machine, got: {resolved}"
            );
        } else {
            eprintln!(
                "note: {marker} doesn't exist on this machine, skipping the exact-marker \
                 assertion -- resolved PATH was: {resolved}"
            );
            let default_path = std::env::var("PATH").unwrap_or_default();
            assert_ne!(
                resolved.trim(),
                default_path.trim(),
                "when the exact marker isn't available, at least prove resolution produced \
                 something distinct from this test process's own bare PATH"
            );
        }
    }

    /// Wiring proof: `build_command` actually applies whatever
    /// `cached_shell_path()` resolves (or doesn't) to the spawned command's
    /// `PATH` env var, for every engine that should get it. Self-consistent
    /// regardless of which machine runs it -- compares against
    /// `cached_shell_path()`'s own live return value rather than a
    /// hardcoded expectation, so it holds whether resolution succeeds here
    /// or not.
    fn assert_build_command_applies_resolved_path(engine: &str) {
        let tmp = tempfile::tempdir().unwrap();
        let req = CreateSessionRequest {
            project: "demo".into(),
            engine: engine.into(),
            cwd: tmp.path().to_string_lossy().into_owned(),
            briefing: None,
            restore_id: None,
        };
        let (cmd, _mcp_path) =
            build_command(&req, tmp.path(), &format!("sess-test-path-{engine}")).unwrap();
        let got = cmd
            .get_env("PATH")
            .map(|s| s.to_string_lossy().into_owned());

        match cached_shell_path() {
            Some(expected) => assert_eq!(
                got.as_deref(),
                Some(expected),
                "{engine} session's PATH should be the resolved shell PATH"
            ),
            None => assert_eq!(
                got,
                std::env::var("PATH").ok(),
                "{engine} session's PATH should fall back to this process's own PATH \
                 when resolution fails"
            ),
        }
    }

    #[test]
    fn build_command_applies_resolved_path_to_claude() {
        assert_build_command_applies_resolved_path("claude");
    }

    #[test]
    fn build_command_applies_resolved_path_to_codex() {
        assert_build_command_applies_resolved_path("codex");
    }

    #[test]
    fn build_command_applies_resolved_path_to_shell() {
        assert_build_command_applies_resolved_path("shell");
    }

    // -- Terminal-capability env: TERM/COLORTERM (founder bug, 2026-07-25 --
    // "the terminals render black-and-white instead of colorful") ---------

    /// Wiring proof: `build_command` sets `TERM`/`COLORTERM` on the spawned
    /// command's env, for every engine, unconditionally -- see the module
    /// docs' "Making CLIs render color" section for why this is
    /// unconditional (always the same two literal values) rather than
    /// resolved/cached like `PATH` above: unlike `PATH`, there is no "real"
    /// value to discover from the user's environment -- a GUI launch simply
    /// has no `TERM` at all, and the correct fix is to assert the exact
    /// capability this app's own xterm.js + WebGL addon actually support,
    /// not to propagate whatever (if anything) this process happened to
    /// inherit.
    ///
    /// Deliberately forces THIS TEST PROCESS's own `TERM`/`COLORTERM` to
    /// something else first (`dumb`/unset), restored via RAII even if an
    /// assertion panics -- otherwise this assertion would silently pass for
    /// the wrong reason on any machine (this one included: a real terminal
    /// session's own shell already has `TERM=xterm-256color`,
    /// `COLORTERM=truecolor`) where `CommandBuilder::new`'s base-env
    /// inheritance (see `get_base_env` in the `portable-pty` crate) already
    /// happens to match the target values by coincidence, exactly the same
    /// "cargo tauri dev never reproduced the PATH bug" trap the module docs
    /// describe for `PATH` above -- proven empirically while writing this
    /// test: without the override below, this assertion passed even before
    /// `build_command` set anything, purely because this developer's own
    /// shell's `TERM`/`COLORTERM` already matched.
    fn assert_build_command_sets_terminal_capability_env(engine: &str) {
        struct RestoreEnvVar(&'static str, Option<std::ffi::OsString>);
        impl Drop for RestoreEnvVar {
            fn drop(&mut self) {
                match &self.1 {
                    Some(v) => std::env::set_var(self.0, v),
                    None => std::env::remove_var(self.0),
                }
            }
        }
        let _restore_term = RestoreEnvVar("TERM", std::env::var_os("TERM"));
        let _restore_colorterm = RestoreEnvVar("COLORTERM", std::env::var_os("COLORTERM"));
        std::env::set_var("TERM", "dumb");
        std::env::remove_var("COLORTERM");

        let tmp = tempfile::tempdir().unwrap();
        let req = CreateSessionRequest {
            project: "demo".into(),
            engine: engine.into(),
            cwd: tmp.path().to_string_lossy().into_owned(),
            briefing: None,
            restore_id: None,
        };
        let (cmd, _mcp_path) =
            build_command(&req, tmp.path(), &format!("sess-test-color-{engine}")).unwrap();

        assert_eq!(
            cmd.get_env("TERM")
                .map(|s| s.to_string_lossy().into_owned())
                .as_deref(),
            Some("xterm-256color"),
            "{engine} session's TERM should be set for real color support, regardless of \
             whatever (if anything) this process itself inherited"
        );
        assert_eq!(
            cmd.get_env("COLORTERM")
                .map(|s| s.to_string_lossy().into_owned())
                .as_deref(),
            Some("truecolor"),
            "{engine} session's COLORTERM should signal 24-bit color support"
        );
    }

    #[test]
    fn build_command_sets_terminal_capability_env_for_claude() {
        assert_build_command_sets_terminal_capability_env("claude");
    }

    #[test]
    fn build_command_sets_terminal_capability_env_for_codex() {
        assert_build_command_sets_terminal_capability_env("codex");
    }

    #[test]
    fn build_command_sets_terminal_capability_env_for_shell() {
        assert_build_command_sets_terminal_capability_env("shell");
    }

    /// Bug: every one of `create()`'s fallible steps *after*
    /// `write_mcp_config` writes the temp `--mcp-config` JSON file
    /// (`openpty`, `try_clone_reader`/`take_writer`, `spawn_command`,
    /// `append_lifecycle_event`) propagated its error via `?` without ever
    /// cleaning that file up -- only `kill()` and the natural-exit path
    /// (both post-success) did. Realistic trigger named in the bug report:
    /// `claude` isn't on `PATH`, so every "claude" session attempt fails at
    /// spawn and leaks one more file into the system temp dir forever.
    ///
    /// Reproduced end-to-end through the real `create()`, exactly that
    /// trigger: a fake sibling `omniagent-mcp` binary is dropped next to
    /// *this test binary itself* so `resolve_mcp_server_binary()` (which
    /// looks up `std::env::current_exe()`, exactly as `create()` calls it
    /// for real) genuinely finds it and writes the config file, then
    /// `PATH` is filtered (for the duration of the `create()` call only,
    /// restored via RAII even if an assertion below panics) to drop only
    /// the specific directory that actually contains a `claude`
    /// executable -- every *other* directory on `PATH` is left untouched,
    /// so anything else on this machine's `PATH` (notably `git`, which
    /// `feedback::tests::git_diff_stat_reports_uncommitted_changes`
    /// shells out to and which flaked when an earlier version of this
    /// test wiped `PATH` entirely and ran concurrently with it) keeps
    /// resolving normally for any test running in parallel with this one.
    /// (Two other failure triggers were tried first and rejected: a
    /// nonexistent `cwd` and an oversized `--append-system-prompt` value
    /// both let `spawn_command` return `Ok` -- the failure happens
    /// invisibly inside the forked child before `exec`, not in the
    /// parent's `spawn_command` call, on this PTY backend/OS -- so neither
    /// actually surfaces as an `Err` here, and worse, both leave a real
    /// child process spawned and running.)
    ///
    /// Updated 2026-07-25 for the shell-`PATH`-resolution fix
    /// (`apply_resolved_path`/`cached_shell_path`): filtering the ambient
    /// `PATH` alone no longer makes `claude` unresolvable, since
    /// `build_command` now overrides the spawned command's `PATH` with the
    /// user's real, shell-resolved one regardless of what this test does to
    /// the current process's env -- which is the fix working as intended,
    /// but it defeats this test's original trigger on any machine where
    /// `claude` really is reachable via the user's shell (this one
    /// included). `_force_resolution_failure` engages a thread-local,
    /// `#[cfg(test)]`-only escape hatch (see
    /// `FORCE_SHELL_PATH_RESOLUTION_FAILURE`'s doc comment) so
    /// `apply_resolved_path` skips its override for the duration of this
    /// test's own thread only, restoring the original filtered-`PATH`
    /// trigger without disturbing any other test's view of the real,
    /// process-global resolution cache.
    #[test]
    fn create_cleans_up_leaked_mcp_config_temp_file_when_spawn_fails() {
        struct ForceShellPathResolutionFailure;
        impl ForceShellPathResolutionFailure {
            fn engage() -> Self {
                FORCE_SHELL_PATH_RESOLUTION_FAILURE.with(|f| f.set(true));
                Self
            }
        }
        impl Drop for ForceShellPathResolutionFailure {
            fn drop(&mut self) {
                FORCE_SHELL_PATH_RESOLUTION_FAILURE.with(|f| f.set(false));
            }
        }
        let _force_resolution_failure = ForceShellPathResolutionFailure::engage();

        let exe = std::env::current_exe().unwrap();
        let sibling = exe.parent().unwrap().join("omniagent-mcp");
        std::fs::write(&sibling, b"fake").unwrap();
        struct RemoveOnDrop(PathBuf);
        impl Drop for RemoveOnDrop {
            fn drop(&mut self) {
                let _ = std::fs::remove_file(&self.0);
            }
        }
        let _sibling_guard = RemoveOnDrop(sibling);

        struct RestorePath(Option<std::ffi::OsString>);
        impl Drop for RestorePath {
            fn drop(&mut self) {
                match &self.0 {
                    Some(p) => std::env::set_var("PATH", p),
                    None => std::env::remove_var("PATH"),
                }
            }
        }
        let original_path = std::env::var_os("PATH");
        let _path_guard = RestorePath(original_path.clone());
        let filtered: Vec<PathBuf> = original_path
            .as_deref()
            .map(std::env::split_paths)
            .into_iter()
            .flatten()
            .filter(|dir| !dir.join("claude").is_file())
            .collect();
        std::env::set_var("PATH", std::env::join_paths(&filtered).unwrap());
        assert!(
            which_claude(&filtered).is_none(),
            "test setup bug: `claude` must not resolve under the filtered PATH"
        );

        // Pinned via `restore_id` so this test knows the exact temp filename
        // `write_mcp_config` will use, and can therefore assert on *its own*
        // file instead of counting every `omniagent-ade-mcp-*` in the shared
        // system temp dir. The counting version raced any other test that
        // opened a `claude` session concurrently (which now exists:
        // `a_claude_restore_whose_continue_is_refused_retries_without_it`) —
        // that session's own perfectly-legitimate config file inflated the
        // count and failed this assertion.
        let session_id = "sess-mcp-leak-probe";
        let expected_config =
            std::env::temp_dir().join(format!("omniagent-ade-mcp-{session_id}.json"));
        let _ = std::fs::remove_file(&expected_config);

        let tmp = tempfile::tempdir().unwrap();
        let manager = SessionManager::new(tmp.path().to_path_buf(), silent_sink());
        let req = CreateSessionRequest {
            project: "demo".into(),
            engine: "claude".into(),
            cwd: tmp.path().to_string_lossy().into_owned(),
            briefing: None,
            restore_id: Some(session_id.to_string()),
        };

        let err = manager
            .create(req)
            .expect_err("claude must fail to spawn once its directory is filtered off PATH");
        assert!(!err.to_string().is_empty());

        assert!(
            !expected_config.exists(),
            "the --mcp-config temp file written before the failing spawn step must not \
             survive: {}",
            expected_config.display()
        );
    }

    fn which_claude(dirs: &[PathBuf]) -> Option<PathBuf> {
        dirs.iter().map(|d| d.join("claude")).find(|p| p.is_file())
    }

    #[test]
    fn line_buffered_redaction_catches_secret_split_across_reads() {
        let tmp = tempfile::tempdir().unwrap();
        let file_path = tmp.path().join("t.log");
        let mut file = Some(std::fs::File::create(&file_path).unwrap());

        let mut pending = String::new();
        // Simulate the secret's key/value pair arriving in two separate
        // PTY reads, split mid-value.
        pending.push_str("API_KEY=abc");
        flush_complete_lines(&mut pending, &mut file);
        pending.push_str("123\n");
        flush_complete_lines(&mut pending, &mut file);

        drop(file);
        let contents = std::fs::read_to_string(&file_path).unwrap();
        assert!(!contents.contains("abc123"), "{contents}");
        assert!(contents.contains("[redacted]"));
    }

    #[test]
    fn transcript_reassembles_a_multibyte_char_split_across_two_pty_reads() {
        let tmp = tempfile::tempdir().unwrap();
        let file_path = tmp.path().join("t.log");
        let mut file = Some(std::fs::File::create(&file_path).unwrap());

        // "a─b" -- U+2500 BOX DRAWINGS LIGHT HORIZONTAL, UTF-8 bytes
        // E2 94 80 -- split mid-character across two separate PTY
        // `read()` feeds, the exact repro confirmed in review. Real PTY
        // reads aren't UTF-8-boundary-aligned; box-drawing glyphs like
        // this are exactly what a TUI redraw (Claude Code's own
        // full-screen UI) streams constantly.
        let full = "a─b\n";
        let bytes = full.as_bytes();
        assert_eq!(bytes, &[0x61, 0xE2, 0x94, 0x80, 0x62, 0x0A]);
        let chunk1 = &bytes[..3]; // 'a' + the first 2 bytes of the 3-byte sequence
        let chunk2 = &bytes[3..]; // the sequence's last byte + "b\n"

        let mut decoder = Utf8ChunkDecoder::new();
        let mut pending = String::new();

        pending.push_str(&decoder.decode(chunk1));
        flush_complete_lines(&mut pending, &mut file);
        pending.push_str(&decoder.decode(chunk2));
        flush_complete_lines(&mut pending, &mut file);

        drop(file);
        let contents = std::fs::read_to_string(&file_path).unwrap();
        assert_eq!(contents, full, "{contents:?}");
        assert!(
            !contents.contains('\u{FFFD}'),
            "multi-byte char split across reads must not corrupt to U+FFFD: {contents:?}"
        );
    }

    #[test]
    fn utf8_chunk_decoder_still_lossy_replaces_genuinely_invalid_bytes() {
        // 0xFF is never valid UTF-8 (standalone or as a lead byte) -- this
        // isn't an incomplete-sequence case, so it must still become
        // U+FFFD immediately, same as `from_utf8_lossy` would, rather than
        // being carried over forever waiting for bytes that would never
        // complete it.
        let mut decoder = Utf8ChunkDecoder::new();
        let decoded = decoder.decode(&[b'x', 0xFF, b'y']);
        assert_eq!(decoded, "x\u{FFFD}y");
        assert_eq!(decoder.finish(), "", "nothing left carried over");
    }

    #[test]
    fn utf8_chunk_decoder_finish_flushes_a_truly_incomplete_trailing_sequence_at_eof() {
        // If the byte stream ends (EOF) mid-character, there's no more
        // data ever coming for that sequence -- `finish()` must still
        // surface it (lossy-replaced) rather than silently dropping those
        // final bytes forever.
        let mut decoder = Utf8ChunkDecoder::new();
        // First two bytes of "─" (E2 94 80), never followed by the third.
        let decoded = decoder.decode(&[0x61, 0xE2, 0x94]);
        assert_eq!(
            decoded, "a",
            "the incomplete tail must be carried, not lost or corrupted"
        );
        let trailing = decoder.finish();
        assert_eq!(trailing, "\u{FFFD}");
    }

    fn silent_sink() -> OutputSink {
        Arc::new(|_id: &str, _chunk: &[u8]| {})
    }

    #[test]
    fn attention_marker_matches_both_observed_permission_dialog_wordings() {
        // The two real dialogs this was verified against (module docs):
        // a Bash-tool prompt and a Write-tool prompt, different trailing
        // wording, shared opening.
        assert!(contains_attention_marker("Do you want to proceed?"));
        assert!(contains_attention_marker(
            "Do you want to create notes.txt?"
        ));
        // Realistic surrounding noise (cursor-position junk, box-drawing
        // characters) shouldn't defeat the match — it's a substring check.
        assert!(contains_attention_marker(
            "\u{2502} Bash command \u{2502}\nDo you want to proceed?\n\u{2570}\u{2500}\u{256f}"
        ));
    }

    #[test]
    fn attention_marker_matches_the_plan_approval_dialog() {
        // ExitPlanMode's dialog uses different copy from the tool-permission
        // one ("Would you like to proceed?") — founder ask, 2026-07-27:
        // every yes/no question notifies and approves the same way.
        assert!(contains_attention_marker("Would you like to proceed?"));
    }

    #[test]
    fn attention_marker_ignores_unrelated_output() {
        assert!(!contains_attention_marker("hi\n"));
        assert!(!contains_attention_marker(
            "Quick safety check: Is this a project you trust?"
        ));
        assert!(!contains_attention_marker(""));
    }

    #[test]
    fn trim_to_last_n_bytes_snaps_to_a_char_boundary() {
        // "é" is 2 bytes (0xC3 0xA9) — a naive byte-offset cut here would
        // land mid-character and panic on `drain`.
        let mut s = "xé".to_string();
        assert_eq!(s.len(), 3);
        trim_to_last_n_bytes(&mut s, 2);
        // Cut point (byte 1) isn't a boundary, so it snaps forward to byte
        // 3 (the whole "é" survives, "x" gets dropped) rather than panicking.
        assert_eq!(s, "é");
    }

    #[test]
    fn trim_to_last_n_bytes_is_a_no_op_under_the_limit() {
        let mut s = "short".to_string();
        trim_to_last_n_bytes(&mut s, 4096);
        assert_eq!(s, "short");
    }

    // -- Session persistence: ids, conversation identity, daemon wrapping
    // (founder brief + founder bug, 2026-07-26) ------------------------

    #[test]
    fn generated_session_ids_are_accepted_by_the_restore_id_validator() {
        // The round trip that makes persistence work at all: the frontend
        // gets an id back from `create`, persists it, and hands it to the
        // next `create` as `restore_id` — so every id this module mints must
        // pass its own validator, and must survive `daemon::session_name`
        // unchanged (no character gets collapsed to `_`).
        for _ in 0..5 {
            let id = generate_session_id();
            assert!(is_valid_session_id(&id), "{id:?}");
            assert_eq!(
                daemon::session_name(&id),
                format!("{}{id}", daemon::SESSION_NAME_PREFIX),
                "a generated id must need no sanitizing"
            );
        }
    }

    #[test]
    fn restore_id_validation_rejects_path_traversal_and_tmux_target_syntax() {
        assert!(is_valid_session_id("sess-abc_123"));
        // Reaches the filesystem as `<id>.log`:
        assert!(!is_valid_session_id("../../etc/passwd"));
        assert!(!is_valid_session_id("a/b"));
        // `.` and `:` are tmux window/pane target separators:
        assert!(!is_valid_session_id("a.b"));
        assert!(!is_valid_session_id("a:b"));
        // Shell metacharacters / whitespace:
        assert!(!is_valid_session_id("a b"));
        assert!(!is_valid_session_id("a;rm -rf /"));
        assert!(!is_valid_session_id("a$(whoami)"));
        // Bounds:
        assert!(!is_valid_session_id(""));
        assert!(is_valid_session_id(&"x".repeat(MAX_SESSION_ID_LEN)));
        assert!(!is_valid_session_id(&"x".repeat(MAX_SESSION_ID_LEN + 1)));
    }

    // -- Per-pane conversation identity (founder bug, 2026-07-26) ---------

    /// The derivation's whole contract in one test: same session id → same
    /// UUID forever (that is what lets this ship with nothing new persisted),
    /// and a shape `claude --session-id` accepts.
    #[test]
    fn a_session_ids_conversation_uuid_is_stable_and_well_formed() {
        let a = claude_conversation_uuid("sess-18c1a2b3c4d5e6f-0");
        assert_eq!(a, claude_conversation_uuid("sess-18c1a2b3c4d5e6f-0"));

        // `8-4-4-4-12` lowercase hex — the form `claude --session-id`
        // validates (measured: it rejects anything else with `Invalid session
        // ID. Must be a valid UUID.`).
        let groups: Vec<&str> = a.split('-').collect();
        assert_eq!(
            groups.iter().map(|g| g.len()).collect::<Vec<_>>(),
            vec![8, 4, 4, 4, 12],
            "{a}"
        );
        assert!(
            a.chars().all(|c| c.is_ascii_hexdigit() || c == '-'),
            "{a} must be hex + hyphens"
        );
        assert!(
            a.chars().all(|c| !c.is_ascii_uppercase()),
            "{a} must be lowercase"
        );

        // RFC 4122 v5: version nibble 5, variant bits `10xx` (`8`/`9`/`a`/`b`).
        let parsed = Uuid::parse_str(&a).expect("must parse as a UUID");
        assert_eq!(parsed.get_version_num(), 5, "{a}");
        assert!(
            matches!(groups[3].chars().next(), Some('8' | '9' | 'a' | 'b')),
            "{a}"
        );
    }

    /// **The bug, as an assertion.** Many Claude panes live in one project
    /// folder — Bruno's own already has 11 stored conversations — and
    /// `--continue`'s "most recent in this directory" made every one of them
    /// restore the same conversation. Distinct sessions must derive distinct
    /// conversation ids, or the fix is no fix at all.
    #[test]
    fn every_session_derives_a_conversation_uuid_of_its_own() {
        let ids: Vec<String> = (0..64).map(|_| generate_session_id()).collect();
        let uuids: std::collections::HashSet<String> =
            ids.iter().map(|id| claude_conversation_uuid(id)).collect();
        assert_eq!(
            uuids.len(),
            ids.len(),
            "two sessions collided onto one conversation — panes would overwrite each other"
        );
        // Neighbouring ids (same nanosecond, adjacent counters) are the
        // realistic collision risk — two panes opened by one ⌘N burst.
        assert_ne!(
            claude_conversation_uuid("sess-18c1a2b3c4d5e6f-0"),
            claude_conversation_uuid("sess-18c1a2b3c4d5e6f-1")
        );
    }

    /// The namespace is a checkable derivation, not a number someone typed:
    /// it is the UUIDv5 of [`CLAUDE_CONVERSATION_NAMESPACE_URL`] under the
    /// standard URL namespace. Pinning it here means an accidental edit to
    /// the literal — which would silently orphan every existing pane's
    /// conversation — fails the suite instead of shipping.
    #[test]
    fn the_namespace_is_the_documented_derivation_not_a_magic_constant() {
        assert_eq!(
            CLAUDE_CONVERSATION_NAMESPACE,
            Uuid::new_v5(
                &Uuid::NAMESPACE_URL,
                CLAUDE_CONVERSATION_NAMESPACE_URL.as_bytes()
            )
        );
        assert_eq!(
            CLAUDE_CONVERSATION_NAMESPACE.to_string(),
            "9337750e-5a2b-59c8-82f3-650bc0f53cfa"
        );
        // And the derivation really is textbook RFC 4122 v5, so the ids stay
        // reproducible outside this codebase (the published vector every UUID
        // library ships a test for).
        assert_eq!(
            Uuid::new_v5(&Uuid::NAMESPACE_DNS, b"python.org").to_string(),
            "886313e1-3b8a-5372-9b90-0c9aee199e5d"
        );
    }

    /// Which flag each situation actually puts on the command line. A fresh
    /// pane *claims* its conversation; a restore that can't attach *resumes
    /// its own*; an attach carries nothing. Getting `Claim` onto a restore
    /// would refuse to start (`already in use`); getting `Resume` onto a new
    /// tab would graft it onto history it never had.
    #[test]
    fn claude_claims_a_conversation_when_new_and_resumes_its_own_when_restored() {
        let tmp = tempfile::tempdir().unwrap();
        let req = CreateSessionRequest {
            project: "demo".into(),
            engine: "claude".into(),
            cwd: tmp.path().to_string_lossy().into_owned(),
            briefing: None,
            restore_id: None,
        };

        let fresh =
            build_engine_command(&req, tmp.path(), "sess-fresh", ClaudeIdentity::Claim).unwrap();
        // `argv[0]` is the *resolved absolute path* to claude, not the bare
        // name — see the module docs' "Why tmux needs an absolute engine
        // path". What still has to hold is that it is claude and nothing else.
        assert_eq!(
            Path::new(&fresh.argv[0]).file_name().unwrap(),
            "claude",
            "{:?}",
            fresh.argv
        );
        assert_eq!(
            fresh.argv[1..3],
            [
                "--session-id".to_string(),
                claude_conversation_uuid("sess-fresh")
            ],
            "{:?}",
            fresh.argv
        );

        let restored =
            build_engine_command(&req, tmp.path(), "sess-restored", ClaudeIdentity::Resume)
                .unwrap();
        assert_eq!(
            restored.argv[1..3],
            [
                "--resume".to_string(),
                claude_conversation_uuid("sess-restored")
            ],
            "{:?}",
            restored.argv
        );

        let attached =
            build_engine_command(&req, tmp.path(), "sess-attached", ClaudeIdentity::Stock).unwrap();
        assert!(
            !attached
                .argv
                .iter()
                .any(|a| a == "--session-id" || a == "--resume"),
            "attaching to a live engine must carry no identity flag: {:?}",
            attached.argv
        );

        for cmd in [&fresh, &restored, &attached] {
            assert!(
                !cmd.argv.iter().any(|a| a == "--continue" || a == "-c"),
                "`--continue` is gone for good — it is the bug: {:?}",
                cmd.argv
            );
        }
        cleanup_mcp_config(&fresh.mcp_config_path);
        cleanup_mcp_config(&restored.mcp_config_path);
        cleanup_mcp_config(&attached.mcp_config_path);
    }

    /// Who gets an identity flag at all — and, just as importantly, who
    /// never pays the liveness probe that comes with one. A `shell` tab
    /// waiting out a `--resume` window for a flag it was never given would be
    /// a pure latency regression on the most common path there is.
    #[test]
    fn only_a_conversation_engine_spawning_a_fresh_engine_carries_an_identity() {
        use ClaudeIdentity::*;
        // `claude` and `copilot` share the same `--session-id`/`--resume`
        // conversation flags, so both restore their own history.
        for engine in ["claude", "copilot"] {
            assert_eq!(spawn_identity(engine, false, false), Claim, "{engine}");
            assert_eq!(spawn_identity(engine, true, false), Resume, "{engine}");
            // Attaching to a live daemon session: the engine never restarts.
            assert_eq!(spawn_identity(engine, true, true), Stock, "{engine}");
            assert_eq!(spawn_identity(engine, false, true), Stock, "{engine}");
        }
        for engine in ["codex", "shell", "antigravity"] {
            for is_restore in [false, true] {
                for daemon_exists in [false, true] {
                    assert_eq!(
                        spawn_identity(engine, is_restore, daemon_exists),
                        Stock,
                        "{engine} restore={is_restore} daemon={daemon_exists}"
                    );
                    // Single-rung ladder: no identity fallback work.
                    assert_eq!(
                        spawn_identity(engine, is_restore, daemon_exists)
                            .ladder()
                            .len(),
                        1
                    );
                }
            }
        }
    }

    /// Every ladder ends on an unflagged `claude`, which is the only reason
    /// `create` can promise a working pane: `Stock` carries nothing that can
    /// be refused. The `Resume` ladder's middle rung is how a session created
    /// *before* this fix gets adopted — see [`ClaudeIdentity::ladder`].
    #[test]
    fn every_identity_ladder_ends_on_a_spawn_that_cannot_be_refused() {
        use ClaudeIdentity::*;
        assert_eq!(Resume.ladder(), vec![Resume, Claim, Stock]);
        assert_eq!(Claim.ladder(), vec![Claim, Stock]);
        assert_eq!(Stock.ladder(), vec![Stock]);
        for start in [Resume, Claim, Stock] {
            assert_eq!(*start.ladder().last().unwrap(), Stock, "{start:?}");
        }
    }

    #[test]
    fn startup_probe_windows_cover_daemon_attach_and_identity_retries() {
        use ClaudeIdentity::*;

        // daemon-backed attempts are always checked, including the last rung.
        assert_eq!(
            startup_probe_window(0, 0, Stock, true),
            Some(DAEMON_PANE_STARTUP_WINDOW)
        );
        assert_eq!(
            startup_probe_window(2, 2, Stock, true),
            Some(DAEMON_PANE_STARTUP_WINDOW)
        );

        // direct spawns only probe non-final identity rungs.
        assert_eq!(
            startup_probe_window(0, 2, Resume, false),
            Some(RESUME_LIVENESS_WINDOW)
        );
        assert_eq!(
            startup_probe_window(1, 2, Claim, false),
            Some(SESSION_ID_LIVENESS_WINDOW)
        );
        assert_eq!(startup_probe_window(2, 2, Stock, false), None);
    }

    /// The liveness probe behind the identity-ladder retry, against real
    /// processes: one that dies immediately (`false` — and *fast*, it must
    /// not wait out the window) and one that keeps running (`true`).
    ///
    /// Both cases drain the PTY on a background thread, exactly as
    /// production does, because **that drain is what makes the probe work at
    /// all**: on macOS a process exiting with unflushed tty output cannot
    /// complete its exit until something reads the master, so an undrained
    /// child sits in the kernel's "exiting" state and `try_wait` reports
    /// "still running" indefinitely. Found the hard way — an earlier draft of
    /// this test (and of the old local spawn path) skipped the drain and the
    /// first assertion below failed after waiting out the full window. See
    /// historical local-spawn notes for the full write-up.
    #[test]
    fn child_survives_startup_distinguishes_an_instant_exit_from_a_healthy_process() {
        fn spawn_probe(script: &str) -> (Box<dyn Child + Send + Sync>, thread::JoinHandle<()>) {
            let pair = native_pty_system()
                .openpty(PtySize {
                    rows: 24,
                    cols: 80,
                    pixel_width: 0,
                    pixel_height: 0,
                })
                .unwrap();
            let mut reader = pair.master.try_clone_reader().unwrap();
            let mut cmd = CommandBuilder::new("/bin/sh");
            cmd.arg("-c");
            cmd.arg(script);
            let child = pair.slave.spawn_command(cmd).unwrap();
            drop(pair.slave);
            let drain = thread::spawn(move || {
                let mut buf = [0u8; 1024];
                while matches!(reader.read(&mut buf), Ok(n) if n > 0) {}
            });
            // The master must stay open for the drain thread's reads; it is
            // dropped when this pair goes out of scope at the end of the
            // enclosing statement, which is after the probe runs.
            std::mem::forget(pair.master);
            (child, drain)
        }

        // Stands in for a refused identity flag's measured real behavior:
        // print a complaint, exit 1, right away.
        let (mut child, drain) =
            spawn_probe("echo 'No conversation found with session ID: x'; exit 1");
        let started = Instant::now();
        assert!(
            !child_survives_startup(&mut child, Duration::from_secs(5)),
            "a process that exits immediately must be reported as not surviving"
        );
        assert!(
            started.elapsed() < Duration::from_secs(3),
            "the failure path must return as soon as the child exits, not wait out the \
             whole window (took {:?})",
            started.elapsed()
        );
        let _ = child.wait();
        let _ = drain.join();

        let (mut child, _drain) = spawn_probe("sleep 30");
        assert!(
            child_survives_startup(&mut child, Duration::from_millis(400)),
            "a running process must be reported as surviving"
        );
        let _ = child.kill();
        let _ = child.wait();
    }

    /// A fake `claude` on this thread's `PATH`, reproducing claude 2.1.220's
    /// real refusals: it exits 1 for any flag named in `refuse`, printing the
    /// message that binary actually prints, and otherwise announces the
    /// full argv it was given and stays alive.
    ///
    /// Uses [`TEST_SHELL_PATH_OVERRIDE`] rather than mutating the real
    /// `PATH`; see that thread-local's doc comment for the cross-test race
    /// that rules the obvious approach out.
    struct FakeClaude {
        _dir: tempfile::TempDir,
    }

    impl FakeClaude {
        fn refusing(refuse: &[&str]) -> Self {
            let dir = tempfile::tempdir().unwrap();
            let bin_dir = dir.path().join("fakebin");
            std::fs::create_dir_all(&bin_dir).unwrap();
            let mut script = String::from("#!/bin/sh\n");
            for flag in refuse {
                let message = match *flag {
                    "--resume" => "No conversation found with session ID: <uuid>",
                    "--session-id" => "Error: Session ID <uuid> is already in use.",
                    other => other,
                };
                script.push_str(&format!(
                    "for a in \"$@\"; do\n  if [ \"$a\" = \"{flag}\" ]; then\n    \
                     echo '{message}'\n    exit 1\n  fi\ndone\n"
                ));
            }
            script.push_str("echo \"FAKE_CLAUDE_ARGV:$*\"\nsleep 30\n");
            let fake_claude = bin_dir.join("claude");
            std::fs::write(&fake_claude, script).unwrap();
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                std::fs::set_permissions(&fake_claude, std::fs::Permissions::from_mode(0o755))
                    .unwrap();
            }
            TEST_SHELL_PATH_OVERRIDE.with(|o| {
                o.set(Some(Box::leak(
                    format!(
                        "{}:{}",
                        bin_dir.display(),
                        std::env::var("PATH").unwrap_or_default()
                    )
                    .into_boxed_str(),
                )))
            });
            Self { _dir: dir }
        }
    }

    impl Drop for FakeClaude {
        fn drop(&mut self) {
            TEST_SHELL_PATH_OVERRIDE.with(|o| o.set(None));
        }
    }

    /// Every engine reaches tmux as an **absolute** path. tmux `exec`s the
    /// argv against the server's environment, so a bare name is only as good
    /// as the environment the server happened to start with — see the module
    /// docs. Resolution uses the same shell-resolved `PATH` the engine itself
    /// is handed, so the two can never disagree.
    #[test]
    fn every_engine_reaches_tmux_by_absolute_path() {
        let _fake = FakeClaude::refusing(&[]);
        let tmp = tempfile::tempdir().unwrap();
        for engine in ["claude", "shell"] {
            let req = CreateSessionRequest {
                project: "demo".into(),
                engine: engine.into(),
                cwd: tmp.path().to_string_lossy().into_owned(),
                briefing: None,
                restore_id: None,
            };
            let cmd =
                build_engine_command(&req, tmp.path(), "sess-abs", ClaudeIdentity::Stock).unwrap();
            let program = Path::new(&cmd.argv[0]);
            assert!(
                program.is_absolute(),
                "{engine} reached tmux as {:?}, which the tmux server can only resolve if \
                 its own PATH happens to contain it",
                cmd.argv[0]
            );
            assert!(
                program.is_file(),
                "{engine} resolved to {program:?}, which is not a real file"
            );
        }
    }

    /// An engine that genuinely isn't installed keeps its bare name rather
    /// than becoming an empty or bogus path — `create` then fails with a real
    /// spawn error naming it, which is honest, instead of silently launching
    /// something else.
    #[test]
    fn an_engine_that_is_not_installed_keeps_its_bare_name() {
        assert_eq!(
            resolve_engine_binary("definitely-not-a-real-engine-9271"),
            None
        );
    }

    /// The daemon-side liveness check: a pane whose command cannot even be
    /// `exec`'d takes its session down instantly, and that must read as
    /// "this rung failed" rather than as a healthy session to attach to.
    #[test]
    fn daemon_session_survival_distinguishes_a_dead_pane_from_a_live_one() {
        let dir = tempfile::tempdir().unwrap();
        let socket = format!("omniagent-survive-{}", std::process::id());
        let t = DaemonSessions::resolve(&socket, cached_shell_path())
            .expect("the pty daemon must be available to run this test");
        let t = DaemonSessions::with_binary(t.binary(), &socket)
            .with_config(daemon::write_config(dir.path()).unwrap());

        // A command that cannot be exec'd at all — the founder bug's shape.
        let dead = t.ensure_session(
            "dead",
            dir.path(),
            &[],
            &["/no/such/binary/anywhere".to_string()],
        );
        assert!(
            !daemon_session_survives_startup(&t, "dead", DAEMON_PANE_STARTUP_WINDOW),
            "a pane whose command never started must not read as alive"
        );
        assert!(
            dead.is_err(),
            "daemon-backed creation should surface spawn failures for invalid binaries"
        );

        t.ensure_session(
            "alive",
            dir.path(),
            &[],
            &["/bin/sleep".into(), "60".into()],
        )
        .unwrap();
        assert!(
            daemon_session_survives_startup(&t, "alive", DAEMON_PANE_STARTUP_WINDOW),
            "a healthy pane must read as alive"
        );
        t.kill_server();
    }

    /// Conversation identity is Claude-specific; `codex` and `shell` have no
    /// equivalent and must stay bit-for-bit stock on every rung.
    #[test]
    fn identity_flags_never_leak_into_codex_or_shell_invocations() {
        let tmp = tempfile::tempdir().unwrap();
        for engine in ["codex", "shell"] {
            for identity in [
                ClaudeIdentity::Claim,
                ClaudeIdentity::Resume,
                ClaudeIdentity::Stock,
            ] {
                let req = CreateSessionRequest {
                    project: "demo".into(),
                    engine: engine.into(),
                    cwd: tmp.path().to_string_lossy().into_owned(),
                    briefing: None,
                    restore_id: None,
                };
                let cmd = build_engine_command(&req, tmp.path(), "sess-x", identity).unwrap();
                assert!(
                    !cmd.argv
                        .iter()
                        .any(|arg| arg == "--session-id" || arg == "--resume"),
                    "{engine} must not receive Claude identity flags under {identity:?}: {:?}",
                    cmd.argv
                );
            }
        }
    }

    /// The engine's argv must reach tmux as *separate* arguments — a
    /// briefing full of spaces and newlines is passed to `tmux new-session`
    /// verbatim, and tmux `exec`s a multi-argument command rather than
    /// handing it to a shell (verified against real tmux; see the tmux module
    /// docs). If this ever collapsed into one string, every briefing would
    /// become a shell-injection surface.
    #[test]
    fn a_multiline_briefing_stays_a_single_argv_entry() {
        let tmp = tempfile::tempdir().unwrap();
        let briefing = "# Briefing\n\n- decision: use $(whoami) 'quoted' \"stuff\"\n";
        let req = CreateSessionRequest {
            project: "demo".into(),
            engine: "claude".into(),
            cwd: tmp.path().to_string_lossy().into_owned(),
            briefing: Some(briefing.to_string()),
            restore_id: None,
        };
        let cmd =
            build_engine_command(&req, tmp.path(), "sess-briefing", ClaudeIdentity::Claim).unwrap();
        let idx = cmd
            .argv
            .iter()
            .position(|a| a == "--append-system-prompt")
            .expect("briefing should be wired");
        assert_eq!(cmd.argv[idx + 1], briefing);
        cleanup_mcp_config(&cmd.mcp_config_path);
    }

    /// The env one producer hands both spawn paths — asserted as a set of
    /// pairs here (the tmux `-e KEY=VALUE` form) rather than through a
    /// `CommandBuilder`, which the tests above already cover.
    #[test]
    fn engine_env_always_carries_the_terminal_capability_vars() {
        let env = engine_env();
        assert!(env.contains(&("TERM".to_string(), TERM_VALUE.to_string())));
        assert!(env.contains(&("COLORTERM".to_string(), COLORTERM_VALUE.to_string())));
        match cached_shell_path() {
            Some(p) => assert!(env.contains(&("PATH".to_string(), p.to_string()))),
            None => assert!(
                !env.iter().any(|(k, _)| k == "PATH"),
                "no resolved PATH means don't set one at all (inherit)"
            ),
        }
    }

    /// The mojibake half of the founder's 2026-07-26 report: with no locale
    /// in the environment tmux leaves UTF-8 mode off and byte-splits the
    /// pane, so claude's frame renders as `‚îÄ‚îÄ`. A vacuum gets filled; a
    /// locale that is already UTF-8, and any deliberate `LC_ALL`, are left
    /// exactly as they are.
    #[test]
    fn a_utf8_locale_is_asserted_only_when_the_environment_names_none() {
        let utf8 = Some(("LANG".to_string(), UTF8_LOCALE.to_string()));
        // The GUI case: nothing set at all.
        assert_eq!(utf8_locale_override(None, None, None), utf8);
        // Set, but not UTF-8 — tmux would still byte-split.
        assert_eq!(utf8_locale_override(None, None, Some("C")), utf8);
        assert_eq!(
            utf8_locale_override(None, Some("en_US.ISO8859-1"), None),
            utf8
        );
        // Already UTF-8, spelled either of the two common ways.
        assert_eq!(utf8_locale_override(None, None, Some("de_DE.UTF-8")), None);
        assert_eq!(utf8_locale_override(None, Some("en_US.utf8"), None), None);
        // `LC_ALL` outranks `LANG`, so adding one could not have helped —
        // whatever it says, it stands.
        assert_eq!(utf8_locale_override(Some("C"), None, None), None);
    }

    // -- Traffic-light status heuristics --------------------------------

    #[test]
    fn a_shell_at_its_prompt_reads_as_ready_for_every_engine() {
        for shell in ["zsh", "bash", "fish", "-zsh", "login"] {
            for engine in ["shell", "claude", "codex"] {
                assert_eq!(
                    status_from_pane_command(shell, engine),
                    Some(SessionStatus::Ready),
                    "{shell} in a {engine} session"
                );
            }
        }
    }

    #[test]
    fn a_running_command_in_a_shell_session_reads_as_tool_execution() {
        // Bruno's cyan is "active tool execution, like terminal commands" —
        // for a terminal session, a foreground command *is* that.
        for cmd in ["sleep", "cargo", "vim", "node", "git"] {
            assert_eq!(
                status_from_pane_command(cmd, "shell"),
                Some(SessionStatus::ToolExecution),
                "{cmd}"
            );
        }
    }

    /// The honest limit, encoded: for `claude`/`codex` the pane's foreground
    /// command is *always* the engine, so it says nothing about whether the
    /// engine is busy — `None` forces the caller to the activity heuristic
    /// instead of inventing an answer.
    #[test]
    fn the_engines_own_process_name_carries_no_information() {
        assert_eq!(status_from_pane_command("claude", "claude"), None);
        assert_eq!(status_from_pane_command("node", "claude"), None);
        assert_eq!(status_from_pane_command("codex", "codex"), None);
    }

    #[test]
    fn output_activity_reads_sustained_output_as_thinking_and_silence_as_ready() {
        let activity = SessionActivity::new("claude".into(), None, true);
        let now = Instant::now();
        // A run that started 2s ago and is still producing output.
        *activity.last_output.lock().unwrap() = now;
        *activity.busy_since.lock().unwrap() = Some(now - Duration::from_secs(2));

        assert_eq!(
            status_from_output_activity(&activity, now),
            SessionStatus::Thinking
        );
        assert_eq!(
            status_from_output_activity(&activity, now + OUTPUT_QUIET_THRESHOLD / 2),
            SessionStatus::Thinking
        );
        assert_eq!(
            status_from_output_activity(&activity, now + OUTPUT_QUIET_THRESHOLD),
            SessionStatus::Ready,
            "once output stops for the quiet threshold, it's ready"
        );
        assert_eq!(
            status_from_output_activity(&activity, now + Duration::from_secs(30)),
            SessionStatus::Ready
        );
    }

    /// The engine decides what "busy" *means*. A shell producing output is
    /// running a command (cyan); an agent CLI producing output is working on
    /// the turn (white/blue). This is the only place the two diverge, and
    /// `thinking` must never be reported for a `shell` — a shell doesn't think.
    #[test]
    fn busy_means_tool_execution_for_a_shell_and_thinking_for_an_engine() {
        assert_eq!(
            busy_status_for_engine("shell"),
            SessionStatus::ToolExecution
        );
        assert_eq!(busy_status_for_engine("claude"), SessionStatus::Thinking);
        assert_eq!(busy_status_for_engine("codex"), SessionStatus::Thinking);

        let shell = SessionActivity::new("shell".into(), None, true);
        let now = Instant::now();
        *shell.last_output.lock().unwrap() = now;
        *shell.busy_since.lock().unwrap() = Some(now - Duration::from_secs(2));
        assert_eq!(
            status_from_output_activity(&shell, now),
            SessionStatus::ToolExecution,
            "a shell streaming output is running a command, not thinking"
        );
    }

    /// Founder, 2026-07-26, second round: "it shouldn't change the status
    /// based on whether I'm hovering or typing. And whenever I do it, it
    /// turns into green. I don't like it." The grace used to force `Ready`
    /// for a second after every keystroke — an accepted edge at the time,
    /// now the bug. Typing must HOLD the status the session already had.
    #[test]
    fn typing_mid_run_holds_the_busy_status_instead_of_dipping_green() {
        let activity = SessionActivity::new("claude".into(), None, true);
        let now = Instant::now();
        // A genuinely busy session: sustained run, output still flowing.
        *activity.last_output.lock().unwrap() = now;
        *activity.busy_since.lock().unwrap() = Some(now - Duration::from_secs(3));
        assert_eq!(
            status_from_output_activity(&activity, now),
            SessionStatus::Thinking
        );

        // The user types into it (the real write path).
        activity.mark_user_input();
        assert_eq!(
            status_from_output_activity(&activity, Instant::now()),
            SessionStatus::Thinking,
            "a keystroke must not change what the light was already saying"
        );

        // And once the grace passes with output continuing, still busy —
        // the run clock never stopped.
        let after = now + TYPING_ECHO_GRACE + Duration::from_millis(50);
        *activity.last_output.lock().unwrap() = after;
        assert_eq!(
            status_from_output_activity(&activity, after),
            SessionStatus::Thinking
        );
    }

    /// Hovering a pane makes the TUI's mouse tracking stream reports through
    /// `write` — none of which is the user typing. Founder: "it shouldn't
    /// change the status based on whether I'm hovering".
    #[test]
    fn pointer_reports_do_not_count_as_typing() {
        // SGR motion/wheel/press — what xterm.js sends while hovering and
        // scrolling — alone or batched.
        assert!(is_pointer_report("\x1b[<35;80;24M"));
        assert!(is_pointer_report("\x1b[<64;10;5M\x1b[<65;10;6M"));
        assert!(is_pointer_report("\x1b[<0;3;3M\x1b[<0;3;3m"));
        // Legacy X10 encoding and focus in/out.
        assert!(is_pointer_report("\x1b[M !!"));
        assert!(is_pointer_report("\x1b[I"));
        assert!(is_pointer_report("\x1b[O"));

        // Real input — plain keys, Enter, arrows, ESC, pasted text — is
        // typing, even when it starts with an escape.
        assert!(!is_pointer_report("a"));
        assert!(!is_pointer_report("\r"));
        assert!(!is_pointer_report("\x1b[A"));
        assert!(!is_pointer_report("\x1b"));
        assert!(!is_pointer_report("\x1b[200~hello\x1b[201~"));
        // Mixed pointer + key counts as typing.
        assert!(!is_pointer_report("\x1b[<0;3;3Mq"));
        assert!(!is_pointer_report(""));
    }

    /// The original founder ask this grace exists for ("I also don't want
    /// the executing effect to be triggered when I'm typing") must survive
    /// the hold semantics: a burst that STARTS on a quiet session stays
    /// ready for its whole duration, even once the engine's own echo has
    /// sustained a run longer than [`SUSTAINED_ACTIVITY_MIN`].
    #[test]
    fn typing_echo_alone_never_reads_as_busy() {
        let activity = SessionActivity::new("claude".into(), None, true);
        // First keystroke lands on a quiet session (no run at all).
        activity.mark_user_input();
        let t0 = Instant::now();

        // 1.5s of continuous typing later: the echo itself has built a
        // sustained run, and the last keystroke is still inside the grace.
        *activity.busy_since.lock().unwrap() = Some(t0);
        *activity.last_output.lock().unwrap() = t0 + Duration::from_millis(1500);
        *activity.last_user_input.lock().unwrap() = Some(t0 + Duration::from_millis(1400));
        assert_eq!(
            status_from_output_activity(&activity, t0 + Duration::from_millis(1500)),
            SessionStatus::Ready,
            "echo during a burst that began quiet must never light the pane up"
        );
    }

    /// The measured idle-`claude` shape (module docs / [`SUSTAINED_ACTIVITY_MIN`]):
    /// a ~50 ms burst of TUI repaint every few seconds. It must NOT read as
    /// executing — that flicker is exactly what this rule exists to kill.
    #[test]
    fn an_isolated_idle_tui_burst_does_not_read_as_executing() {
        let activity = SessionActivity::new("claude".into(), None, true);
        let t0 = Instant::now();
        *activity.busy_since.lock().unwrap() = Some(t0);
        *activity.last_output.lock().unwrap() = t0 + Duration::from_millis(50);

        for offset_ms in [60u64, 200, 400, 600, 740] {
            assert_eq!(
                status_from_output_activity(&activity, t0 + Duration::from_millis(offset_ms)),
                SessionStatus::Ready,
                "a 50ms burst must never read as executing (at +{offset_ms}ms)"
            );
        }
    }

    /// `mark_output` is what maintains the run boundary: consecutive chunks
    /// extend one run, a gap longer than the quiet threshold starts a new one
    /// (so a burst every few seconds never accumulates into "busy").
    #[test]
    fn mark_output_starts_a_new_run_only_after_a_real_gap() {
        let activity = SessionActivity::new("claude".into(), None, true);

        activity.mark_output();
        let first_run = activity.busy_since.lock().unwrap().unwrap();

        // A chunk right behind it belongs to the same run.
        activity.mark_output();
        assert_eq!(
            activity.busy_since.lock().unwrap().unwrap(),
            first_run,
            "back-to-back chunks must not restart the run"
        );

        // After a gap longer than the quiet threshold, the run restarts.
        thread::sleep(OUTPUT_QUIET_THRESHOLD + Duration::from_millis(50));
        activity.mark_output();
        assert!(
            activity.busy_since.lock().unwrap().unwrap() > first_run,
            "a gap longer than the quiet threshold must start a new run"
        );
    }

    /// Amber outranks everything: a session blocked on the user must not be
    /// reported as merely "thinking" because it happens to be redrawing its
    /// prompt (which a real pending Claude prompt does ~1.9 times a second).
    #[test]
    fn awaiting_approval_outranks_every_other_signal() {
        let activity = SessionActivity::new("claude".into(), None, true);
        *activity.last_output.lock().unwrap() = Instant::now();
        *activity.busy_since.lock().unwrap() = Some(Instant::now() - Duration::from_secs(5));
        activity.attention.store(true, Ordering::Relaxed);
        // ...even with an error also latched: if the engine is asking for a
        // decision, that's the actionable state.
        activity.error.store(true, Ordering::Relaxed);
        assert_eq!(
            compute_status(&activity, None, Instant::now()),
            SessionStatus::AwaitingApproval
        );

        activity.attention.store(false, Ordering::Relaxed);
        assert_eq!(
            compute_status(&activity, None, Instant::now()),
            SessionStatus::Error,
            "with approval cleared, the latched failure is what the user needs to see"
        );

        activity.error.store(false, Ordering::Relaxed);
        assert_eq!(
            compute_status(&activity, None, Instant::now()),
            SessionStatus::Thinking
        );
    }

    /// The full five-state priority chain in one place, driven only through
    /// the latches and the activity clock (no tmux), so it asserts the
    /// ordering rather than any one signal's plumbing.
    #[test]
    fn compute_status_walks_the_five_states_in_priority_order() {
        let activity = SessionActivity::new("claude".into(), None, true);
        let now = Instant::now();

        // 1. quiet -> green
        *activity.last_output.lock().unwrap() = now - Duration::from_secs(10);
        assert_eq!(compute_status(&activity, None, now), SessionStatus::Ready);

        // 2. sustained output -> white/blue
        *activity.last_output.lock().unwrap() = now;
        *activity.busy_since.lock().unwrap() = Some(now - Duration::from_secs(3));
        assert_eq!(
            compute_status(&activity, None, now),
            SessionStatus::Thinking
        );

        // 3. a failure was reported -> red, even though it's still working
        activity.error.store(true, Ordering::Relaxed);
        assert_eq!(compute_status(&activity, None, now), SessionStatus::Error);

        // 4. and it now wants permission -> amber
        activity.attention.store(true, Ordering::Relaxed);
        assert_eq!(
            compute_status(&activity, None, now),
            SessionStatus::AwaitingApproval
        );

        // 5. the user types: both latches drop, and the typing grace HOLDS
        //    the busy state the session was already in — typing must not
        //    change the status (founder, 2026-07-26, second round; the
        //    grace used to force green here).
        activity.mark_user_input();
        let typed = activity.last_user_input.lock().unwrap().unwrap();
        assert_eq!(
            compute_status(&activity, None, typed),
            SessionStatus::Thinking
        );

        // 6. the grace expires with output still flowing: back to the live
        //    signal, seamlessly — the run clock counted right through.
        let after = typed + TYPING_ECHO_GRACE;
        *activity.last_output.lock().unwrap() = after;
        assert_eq!(
            compute_status(&activity, None, after),
            SessionStatus::Thinking
        );
    }

    /// A shell session, same chain, without tmux: the states it can reach are
    /// green and cyan — never `thinking`, and (per the module docs) never
    /// `error`, because a stock shell's per-command exit status is not
    /// obtainable without shell integration.
    #[test]
    fn a_shell_session_reaches_green_and_cyan_but_never_thinking() {
        let activity = SessionActivity::new("shell".into(), None, true);
        let now = Instant::now();

        *activity.last_output.lock().unwrap() = now - Duration::from_secs(10);
        assert_eq!(compute_status(&activity, None, now), SessionStatus::Ready);

        *activity.last_output.lock().unwrap() = now;
        *activity.busy_since.lock().unwrap() = Some(now - Duration::from_secs(3));
        assert_eq!(
            compute_status(&activity, None, now),
            SessionStatus::ToolExecution
        );
    }

    // -- error detection (Bruno's red) -----------------------------------

    /// Both real renderings of a failed Bash tool, captured verbatim from live
    /// `claude` 2.1.220 sessions through this app's own tmux config — the wide
    /// (120-column) inline form and the narrow (80-column, i.e. what an ADE
    /// pane actually is) label-and-bolded-value form.
    ///
    /// The narrow case is the one that matters most: an earlier marker built
    /// only from the 120-column probe matched *nothing* in a real session, and
    /// this test is what would have caught it.
    #[test]
    fn a_non_zero_exit_code_line_is_an_error_in_both_real_renderings() {
        assert!(
            contains_error_marker(
                "  \u{23bf}  Exit code 1 \u{2014} ls: /nonexistent-path-xyz-123: No such file or directory"
            ),
            "120-column inline form"
        );
        assert!(
            contains_error_marker("  \u{23bf}  Exit code: \u{1b}[1m1\u{1b}(B\u{1b}[m"),
            "80-column label form, with the value bolded — the one a real ADE pane produces"
        );
        for code in ["1", "2", "127", "130"] {
            assert!(
                contains_error_marker(&format!("Exit code {code} \u{2014} boom")),
                "exit {code} must read as a failure"
            );
            assert!(
                contains_error_marker(&format!("Exit code: \u{1b}[1m{code}\u{1b}(B\u{1b}[m")),
                "exit {code} must read as a failure in the label form too"
            );
        }
    }

    /// The ways this must NOT fire: a success line (should a future Claude
    /// Code start printing one — in either rendering), and prose that merely
    /// mentions the words.
    ///
    /// The bolded-zero case is the reason escapes are skipped structurally
    /// instead of by hunting for the first digit: `\u{1b}[1m` contains a `1`,
    /// so a naive scan would call a *successful* command a failure.
    #[test]
    fn a_zero_exit_code_and_bare_prose_are_not_errors() {
        assert!(
            !contains_error_marker("Exit code 0"),
            "a zero exit is a success, whatever the engine chooses to print"
        );
        assert!(
            !contains_error_marker("Exit code: \u{1b}[1m0\u{1b}(B\u{1b}[m"),
            "a bolded zero must not be read as the `1` inside the SGR escape"
        );
        assert!(!contains_error_marker(
            "check the Exit code manually before continuing"
        ));
        assert!(!contains_error_marker("Ran 1 shell command"));
        assert!(!contains_error_marker(""));
    }

    /// The escape-skipping helper on its own, including the shapes tmux
    /// actually emits.
    #[test]
    fn first_value_char_after_walks_past_escapes_and_label_punctuation() {
        assert_eq!(first_value_char_after("1"), Some('1'));
        assert_eq!(first_value_char_after(": 7"), Some('7'));
        assert_eq!(first_value_char_after("\u{1b}[1m4"), Some('4'));
        assert_eq!(first_value_char_after(": \u{1b}[1m\u{1b}(B9"), Some('9'));
        // A value never lives on the next line — don't wander onto it.
        assert_eq!(first_value_char_after(":\n1"), None);
        assert_eq!(first_value_char_after(""), None);
        assert_eq!(first_value_char_after("\u{1b}"), None);
        // Non-numeric values are found and simply aren't digits, which is
        // what makes the prose case above fall through.
        assert_eq!(first_value_char_after(" manually"), Some('m'));
    }

    /// Without tmux there is no screen to consult, so a user write is the only
    /// release available and clears the error latch outright — today's
    /// behaviour, preserved for the fallback path.
    #[test]
    fn without_tmux_a_user_write_clears_the_error_latch_outright() {
        let activity = SessionActivity::new("claude".into(), None, true);
        activity.error.store(true, Ordering::Relaxed);
        activity.attention.store(true, Ordering::Relaxed);
        activity.mark_user_input();
        assert!(!activity.error.load(Ordering::Relaxed));
        assert!(!activity.attention.load(Ordering::Relaxed));
    }

    /// With tmux, a user write marks the failure *dismissed* instead of
    /// clearing it, because the line is still on the pane and the engine will
    /// keep repainting it. This is the fix for a measured defect: clearing
    /// outright made red come back on the next repaint, over and over, until
    /// it was effectively permanent.
    #[test]
    fn with_daemon_a_user_write_dismisses_the_error_rather_than_clearing_it() {
        let activity = SessionActivity::new("claude".into(), Some("omniagent-x".into()), true);
        activity.error.store(true, Ordering::Relaxed);
        activity.mark_user_input();
        assert!(
            activity.error.load(Ordering::Relaxed),
            "the failure is still on the pane, so the latch stays"
        );
        assert!(activity.error_dismissed.load(Ordering::Relaxed));
    }

    /// A write with nothing latched must not *pre*-dismiss: otherwise typing a
    /// command and having that very command fail a second later would be
    /// silently swallowed — which is what the first draft did, caught by the
    /// tmux integration test.
    #[test]
    fn a_write_with_no_error_latched_does_not_pre_dismiss_a_future_failure() {
        let activity = SessionActivity::new("shell".into(), Some("omniagent-x".into()), true);
        activity.mark_user_input();
        assert!(
            !activity.error_dismissed.load(Ordering::Relaxed),
            "there was nothing to acknowledge"
        );

        // ...and the failure that follows still turns the light red.
        activity.error.store(true, Ordering::Relaxed);
        assert!(resolve_error(&activity, Some("  \u{23bf}  Exit code: 1\n")));
    }

    /// [`resolve_error`]'s three outcomes, driven directly.
    #[test]
    fn resolve_error_reports_only_an_unacknowledged_failure_that_is_still_on_screen() {
        let failing_screen = "  \u{23bf}  Exit code: 1\n";
        let clean_screen = "\u{273b} Cooked for 3s\n\u{276f} \n";

        // 1. On screen, not yet acknowledged -> red.
        let a = SessionActivity::new("claude".into(), Some("x".into()), true);
        a.error.store(true, Ordering::Relaxed);
        assert!(resolve_error(&a, Some(failing_screen)));

        // 2. Still on screen, but the user moved on -> not red, and the latch
        //    is deliberately kept (the line hasn't gone anywhere).
        a.mark_user_input();
        assert!(!resolve_error(&a, Some(failing_screen)));
        assert!(a.error.load(Ordering::Relaxed));

        // 3. Scrolled off the pane -> everything released, so the next real
        //    failure can latch again.
        assert!(!resolve_error(&a, Some(clean_screen)));
        assert!(!a.error.load(Ordering::Relaxed));
        assert!(!a.error_dismissed.load(Ordering::Relaxed));
    }

    /// The repaint storm that caused the live defect, replayed: once
    /// acknowledged, no number of screens still showing the same failure may
    /// turn the light red again.
    #[test]
    fn an_acknowledged_failure_does_not_come_back_on_repaint() {
        let screen = "  \u{23bf}  Exit code: 1\n\u{273b} Cascading\u{2026}\n";
        let activity = SessionActivity::new("claude".into(), Some("x".into()), true);
        activity.error.store(true, Ordering::Relaxed);
        activity.mark_user_input();

        for repaint in 0..25 {
            assert!(
                !resolve_error(&activity, Some(screen)),
                "repaint #{repaint} re-reported a failure the user already acknowledged"
            );
        }
    }

    #[test]
    fn daemon_status_reports_availability_from_runtime_mode() {
        let tmp = tempfile::tempdir().unwrap();
        let sink: OutputSink = Arc::new(|_, _| {});
        let manager =
            SessionManager::new(tmp.path().to_path_buf(), sink).with_daemon_sessions(None);
        let (available, running, _socket_path, session_count) = manager.pty_daemon_status();
        assert!(!available);
        assert!(!running);
        assert_eq!(session_count, 0);
    }

    /// No screen available (no tmux, or the capture failed): the latch is
    /// taken at face value, but a dismissal is still honoured — a failure the
    /// user answered for must not return because tmux hiccupped.
    #[test]
    fn resolve_error_without_a_screen_trusts_the_latch_but_still_honours_a_dismissal() {
        let activity = SessionActivity::new("claude".into(), Some("x".into()), true);
        activity.error.store(true, Ordering::Relaxed);
        assert!(resolve_error(&activity, None));
        activity.mark_user_input();
        assert!(!resolve_error(&activity, None));
    }

    // -- tool execution inside claude/codex (Bruno's cyan) ----------------

    /// The screen marker, taken verbatim from a live `claude` 2.1.220 pane
    /// running `sleep 8 && echo …` inside this app's tmux config — including
    /// the tmux-aware wording Claude switches to when it detects tmux, which
    /// is why only the invariant tail is matched.
    #[test]
    fn a_visibly_running_bash_tool_reads_as_tool_execution() {
        let screen = "\u{23fa}  Running 1 shell command \u{b7} 3s\u{2026}\n  \u{23bf}  $ sleep 8 && echo HI (3s)\n     (ctrl+b ctrl+b (twice) to run in background)\n";
        assert_eq!(
            status_from_screen(screen),
            Some(SessionStatus::ToolExecution)
        );
        // Outside tmux Claude words it differently; the matched tail is the
        // part that survives either way.
        assert_eq!(
            status_from_screen("     (ctrl+b to run in background)"),
            Some(SessionStatus::ToolExecution)
        );
    }

    /// A screen showing only the spinner is thinking, not tool execution —
    /// the spinner is present for both, which is exactly why it isn't the
    /// marker. And a screen showing a *finished* tool must not read as cyan.
    #[test]
    fn a_thinking_or_finished_screen_is_not_tool_execution() {
        assert_eq!(
            status_from_screen("\u{273b} Cascading\u{2026} (14s \u{b7} \u{2193} 92 tokens)"),
            None
        );
        assert_eq!(status_from_screen("  Ran 1 shell command"), None);
        assert_eq!(status_from_screen("\u{273b} Cooked for 17s"), None);
        assert_eq!(status_from_screen(""), None);
    }

    #[test]
    fn a_broken_tmux_never_breaks_status_it_just_falls_back() {
        let activity = SessionActivity::new(
            "shell".into(),
            Some("omniagent-does-not-exist".into()),
            true,
        );
        let now = Instant::now();
        *activity.last_output.lock().unwrap() = now;
        *activity.busy_since.lock().unwrap() = Some(now - Duration::from_secs(3));

        let broken = DaemonSessions::with_binary("/no/such/daemon/binary", "unused");
        // No legacy screen/process poll can answer: use the activity
        // heuristic, not a panic or a wrong hard answer.
        assert_eq!(
            compute_status(&activity, Some(&broken), now),
            SessionStatus::ToolExecution
        );
        assert_eq!(
            compute_status(&activity, Some(&broken), now + Duration::from_secs(5)),
            SessionStatus::Ready
        );
    }

    #[test]
    fn a_user_write_clears_both_the_latch_and_the_stale_window() {
        let activity = SessionActivity::new("claude".into(), None, true);
        activity.attention.store(true, Ordering::Relaxed);
        activity.mark_user_input();
        assert!(!activity.attention.load(Ordering::Relaxed));
        assert!(
            activity.clear_marker_window.swap(false, Ordering::Relaxed),
            "the reader thread must be told to discard the pre-response window"
        );
    }

    #[test]
    fn session_status_serializes_to_the_strings_the_frontend_renders() {
        // The wire contract. `as_str()` and serde must never drift apart:
        // one feeds logs and the other feeds the event payload.
        let all = [
            (SessionStatus::Ready, "ready"),
            (SessionStatus::Thinking, "thinking"),
            (SessionStatus::ToolExecution, "tool_execution"),
            (SessionStatus::AwaitingApproval, "awaiting_approval"),
            (SessionStatus::Error, "error"),
        ];
        for (status, wire) in all {
            assert_eq!(status.as_str(), wire);
            assert_eq!(
                serde_json::to_string(&status).unwrap(),
                format!("\"{wire}\""),
                "serde and as_str must agree for {wire}"
            );
        }
    }

    // -- notification worthiness (Bruno: "only green, yellow or red generate
    // a notification") ---------------------------------------------------

    /// The whole rule, exhaustively. This is the contract the notifications
    /// panel is allowed to trust instead of re-deriving.
    #[test]
    fn only_green_amber_and_red_are_notification_worthy() {
        assert!(SessionStatus::Ready.notifies(), "green: the task finished");
        assert!(
            SessionStatus::AwaitingApproval.notifies(),
            "amber: it needs a decision"
        );
        assert!(SessionStatus::Error.notifies(), "red: it needs a look");

        assert!(
            !SessionStatus::Thinking.notifies(),
            "white/blue is a transient working state"
        );
        assert!(
            !SessionStatus::ToolExecution.notifies(),
            "cyan is a transient working state"
        );
    }

    /// The flag on the payload must be exactly the classifier's answer — the
    /// point of carrying it is that there is only ever one rule.
    #[test]
    fn the_event_payload_carries_the_classifier_verdict_and_the_session_context() {
        for status in [
            SessionStatus::Ready,
            SessionStatus::Thinking,
            SessionStatus::ToolExecution,
            SessionStatus::AwaitingApproval,
            SessionStatus::Error,
        ] {
            let event = SessionStatusEvent::new("sess-abc", status, "claude");
            assert_eq!(event.id, "sess-abc");
            assert_eq!(event.status, status);
            assert_eq!(event.engine, "claude");
            assert_eq!(
                event.notify,
                status.notifies(),
                "notify must never disagree with SessionStatus::notifies()"
            );
        }
    }

    /// The serialized shape the frontend actually receives — asserted as
    /// JSON, since that (not the Rust struct) is the contract across the
    /// Tauri boundary.
    #[test]
    fn the_event_serializes_to_the_documented_json_shape() {
        let json = serde_json::to_value(SessionStatusEvent::new(
            "sess-1",
            SessionStatus::AwaitingApproval,
            "claude",
        ))
        .unwrap();
        assert_eq!(
            json,
            serde_json::json!({
                "id": "sess-1",
                "status": "awaiting_approval",
                "notify": true,
                "engine": "claude",
            })
        );
    }

    #[test]
    fn attention_debouncer_fires_once_for_a_burst_then_again_after_cooldown() {
        // Pure, no real sleeping — Instant + Duration arithmetic is
        // deterministic, so this drives the debouncer with synthetic
        // timestamps exactly like a real redraw storm would produce them,
        // without spending 15 real seconds per test run.
        let mut debouncer = AttentionDebouncer::new(Duration::from_secs(15));
        let t0 = Instant::now();

        // First match in a fresh session: always fires.
        assert!(debouncer.should_fire(t0));

        // A burst of re-matches within the cooldown window (mirrors the
        // empirically observed ~2 redraws/sec while a prompt sits pending)
        // must not fire again.
        for i in 1..=20u64 {
            let t = t0 + Duration::from_millis(i * 400); // spans ~8s, well under 15s
            assert!(
                !debouncer.should_fire(t),
                "burst re-match at +{}ms should have been suppressed",
                i * 400
            );
        }

        // Right at the boundary: still within cooldown, still suppressed.
        assert!(!debouncer.should_fire(t0 + Duration::from_millis(14_999)));

        // Once the cooldown has fully elapsed, a fresh match fires again.
        let t_after = t0 + Duration::from_secs(15);
        assert!(debouncer.should_fire(t_after));

        // ...and that new firing starts its own fresh cooldown window.
        assert!(!debouncer.should_fire(t_after + Duration::from_secs(1)));
    }
}
