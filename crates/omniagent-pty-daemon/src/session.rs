use crate::protocol::SessionStatus;
use anyhow::{anyhow, Context, Result};
use brain_core::redact::redact;
use portable_pty::{CommandBuilder, NativePtySystem, PtySize, PtySystem};
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet, VecDeque};
use std::fs::OpenOptions;
use std::io::{Read, Write};
use std::path::PathBuf;
use std::sync::atomic::{AtomicU8, Ordering};
use std::sync::{Arc, Condvar, Mutex, Weak};
use std::time::{Duration, Instant};

pub const SCROLLBACK_LINES: usize = 3_000;
/// The most PTY sessions one daemon will host at once.
///
/// Eight is what the pane grid can draw, but that is eight *per workspace
/// session*, and the app runs several sessions side by side — so the
/// daemon's ceiling is the product, not the per-session number. It was 8,
/// which silently made the UI's per-session cap a whole-app cap: a second
/// session could not open a terminal once the first held a full grid.
///
/// This is a backstop against a runaway client, not a UI limit. The limit a
/// user meets is `PaneGrid.maxPanes` per session, mirrored on the Swift side
/// by `PaneWorkspaceView.maxTerminals` for this total.
///
/// Was 64 while a grid drew at most eight panes. The 4x3 rung raised the
/// per-session cap to twelve, and the assertion below is what forces this
/// number up with it.
pub const MAX_SESSIONS: usize = 96;
const OUTPUT_HISTORY_CHUNKS: usize = 256;
const EXITED_SESSION_RETENTION: Duration = Duration::from_secs(10);
const MAX_EXITED_SESSIONS: usize = MAX_SESSIONS * 2;

/// The UI draws up to twelve panes per workspace session (`PaneGrid.maxPanes`,
/// the 4x3 rung's capacity), across several sessions. A ceiling below that
/// product silently turns the per-session limit into a whole-app one: the next
/// terminal is refused here whichever session asked for it, and the user meets
/// a pane that will not start instead of a limit they can reason about. That
/// was the bug.
///
/// A `const` assertion rather than a test: this can only ever be wrong at
/// compile time, so it should fail the build rather than a test run.
const _: () = assert!(
    MAX_SESSIONS >= 8 * 12,
    "MAX_SESSIONS must cover eight sessions of twelve panes each -- \
     see PaneGrid.maxPanes and PaneWorkspaceView.maxTerminals on the Swift side"
);

// ---------------------------------------------------------------------------
// Agent status derivation
//
// Until now `refresh_shell_status` returned immediately unless the engine was
// `shell`, so a `claude`/`codex`/`copilot` session never reported a status at
// all -- which left every agent terminal's status light stuck on idle grey for
// its whole life.
//
// The thresholds and markers below are NOT new guesses. They are the values
// measured against real engines for the Tauri build and documented at length in
// `src-tauri/src/sessions.rs` ("Five-state session status"); this is a port of
// that research onto the daemon, not a second opinion about it.
//
// One thing does change, in this port's favour. That module had to reach for
// tmux because matching markers on a raw PTY stream "would match essentially
// nothing" -- Claude's TUI interleaves cursor-position escapes between
// individual words, so `Running 1 shell command` arrives as
// `Running\x1b[11G1\x1b[13Gshell\x1b[19Gcommand`. The daemon already keeps a
// `vt100::Parser`, so it has the same resolved screen tmux was being used for,
// and can match against `screen().contents()` directly.

/// Prompts an engine renders when it is blocked on the user's decision.
/// "Esc to cancel" is the footer every Claude selection dialog shares —
/// AskUserQuestion, the trust prompt, pickers — measured against v2.1.234;
/// the working-state hint is the distinct lowercase "esc to interrupt".
const ATTENTION_MARKERS: &[&str] = &["Do you want to", "Would you like to", "Esc to cancel"];

/// On screen while Claude runs a Bash tool. Deliberately screen state rather
/// than a stream latch: a running tool is a state that *ends*, and a latch
/// would leave the light stuck on after it did.
const TOOL_EXECUTION_SCREEN_MARKERS: &[&str] = &["to run in background)"];

/// The label Claude prints for a failed Bash tool. Matched with a following
/// non-zero value, which is what separates a rendered result field from prose.
const ERROR_MARKER: &str = "Exit code";

/// The glyphs Claude cycles through in its working footer.
///
/// Measured live against v2.1.234 through this daemon's own parser: a working
/// pane reads `✽ Brewing… (4m 59s · ↓ 17.2k tokens)`, and the moment the turn
/// ends the same line becomes `✻ Baked for 6m 32s`. Same glyph, so the glyph
/// alone decides nothing -- the ellipsis is what separates "still going" from
/// "took this long".
const WORKING_SPINNERS: [char; 6] = ['·', '✢', '✳', '✶', '✽', '✻'];

/// Longer than this without output and the engine is considered quiet.
const OUTPUT_QUIET_THRESHOLD: Duration = Duration::from_millis(700);

/// How long an unbroken run of output must last before it counts as work
/// rather than an idle TUI twitching. An idle `claude` is not silent: it emits
/// a tight burst every few seconds, which this is what rejects.
const SUSTAINED_ACTIVITY_MIN: Duration = Duration::from_millis(1000);

/// The engines echo, so typing alone produces sustained output. Within this
/// long of a keystroke the session is never called busy.
const TYPING_ECHO_GRACE: Duration = Duration::from_millis(1000);

/// Output/input timing behind the activity heuristic.
#[derive(Default)]
struct ActivityState {
    last_output_at: Option<Instant>,
    /// Start of the current unbroken run of output, reset by any gap longer
    /// than `OUTPUT_QUIET_THRESHOLD`.
    run_started_at: Option<Instant>,
    last_input_at: Option<Instant>,
}

impl ActivityState {
    fn record_output(&mut self, now: Instant) {
        let broken = self
            .last_output_at
            .map(|last| now.duration_since(last) > OUTPUT_QUIET_THRESHOLD)
            .unwrap_or(true);
        if broken {
            self.run_started_at = Some(now);
        }
        self.last_output_at = Some(now);
    }

    /// True when output is both *current* and has been going long enough to be
    /// work rather than a redraw twitch, and the user is not mid-keystroke.
    fn is_busy(&self, now: Instant) -> bool {
        if let Some(typed) = self.last_input_at {
            if now.duration_since(typed) < TYPING_ECHO_GRACE {
                return false;
            }
        }
        let Some(last) = self.last_output_at else {
            return false;
        };
        let Some(started) = self.run_started_at else {
            return false;
        };
        now.duration_since(last) <= OUTPUT_QUIET_THRESHOLD
            && now.duration_since(started) >= SUSTAINED_ACTIVITY_MIN
    }
}

fn contains_attention_marker(text: &str) -> bool {
    ATTENTION_MARKERS.iter().any(|marker| text.contains(marker))
}

/// True when Claude's working footer is on screen.
///
/// The activity heuristic below cannot carry this on its own: measured live,
/// a pane that was visibly `✽ Brewing…` flapped Ready/Thinking six times in ten
/// seconds, because Claude repaints with gaps wider than
/// `OUTPUT_QUIET_THRESHOLD` and runs shorter than `SUSTAINED_ACTIVITY_MIN`.
/// The footer is state, not cadence, so it holds for the whole turn.
fn contains_working_marker(text: &str) -> bool {
    text.lines().any(|line| {
        let line = line.trim_start();
        line.starts_with(WORKING_SPINNERS) && line.contains('…')
    })
}

fn contains_tool_execution_marker(text: &str) -> bool {
    TOOL_EXECUTION_SCREEN_MARKERS
        .iter()
        .any(|marker| text.contains(marker))
}

/// True when `text` reports a *non-zero* `Exit code`. The value may be
/// separated from the label by a colon and styling, so the first digit after
/// the label is what decides -- and `Exit code 0` is a success, not an error.
fn contains_error_marker(text: &str) -> bool {
    text.match_indices(ERROR_MARKER).any(|(index, _)| {
        match first_value_char_after(&text[index + ERROR_MARKER.len()..]) {
            Some(value) => value.is_ascii_digit() && value != '0',
            None => false,
        }
    })
}

/// The first character that could be a rendered *value*, skipping whitespace,
/// punctuation and any ANSI escape sequence in between.
///
/// Skipping escapes is the whole job. `Exit code: \x1b[1m0\x1b[0m` is a
/// success, but the first digit in that string is the `1` inside `\x1b[1m` —
/// so a naive "first digit after the label" reads every successful command as
/// a failure and paints a healthy terminal red. This matters even though the
/// caller normally passes `vt100` screen text (already free of escapes),
/// because being wrong here is silent and permanent-looking.
fn first_value_char_after(rest: &str) -> Option<char> {
    let mut chars = rest.chars();
    while let Some(candidate) = chars.next() {
        if candidate == '\u{1b}' {
            // A CSI sequence runs until its final byte, which is a letter (or
            // `~` for the editing keys).
            for skipped in chars.by_ref() {
                if skipped.is_ascii_alphabetic() || skipped == '~' {
                    break;
                }
            }
            continue;
        }
        if candidate.is_ascii_digit() || candidate.is_alphabetic() {
            return Some(candidate);
        }
    }
    None
}

struct Transcript {
    file: std::fs::File,
    pending: Vec<u8>,
}

impl Transcript {
    fn open(path: &PathBuf) -> Result<Self> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent).context("create transcript directory")?;
        }
        Ok(Self {
            file: OpenOptions::new()
                .create(true)
                .append(true)
                .open(path)
                .context("open transcript")?,
            pending: Vec::new(),
        })
    }

    fn write(&mut self, bytes: &[u8]) {
        self.pending.extend_from_slice(bytes);
        if let Some(end) = self.pending.iter().rposition(|byte| *byte == b'\n') {
            self.flush(end + 1);
        }
    }

    fn finish(&mut self) {
        self.flush(self.pending.len());
        let _ = self.file.flush();
    }

    fn flush(&mut self, end: usize) {
        if end == 0 {
            return;
        }
        let text = String::from_utf8_lossy(&self.pending[..end]);
        let _ = self.file.write_all(redact(&text).as_bytes());
        let _ = self.file.flush();
        self.pending.drain(..end);
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CreateSession {
    pub id: String,
    pub command: Vec<String>,
    pub cwd: Option<String>,
    #[serde(default)]
    pub env: HashMap<String, String>,
    pub cols: u16,
    pub rows: u16,
    pub transcript_path: Option<PathBuf>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SessionEvent {
    Output {
        sequence: u64,
        bytes: Vec<u8>,
    },
    ResyncRequired {
        sequence: u64,
    },
    Status {
        sequence: u64,
        status: SessionStatus,
        engine: String,
    },
    /// The grid changed (phase 2 §1). Broadcast like `Status`: subscribers
    /// only, never recorded in `history`, since it describes the session as
    /// it is now rather than a byte of its output to replay.
    Resized {
        sequence: u64,
        cols: u16,
        rows: u16,
    },
    Exited {
        sequence: u64,
        exit_code: Option<u32>,
    },
}

impl SessionEvent {
    pub fn sequence(&self) -> u64 {
        match self {
            Self::Output { sequence, .. }
            | Self::ResyncRequired { sequence }
            | Self::Status { sequence, .. }
            | Self::Resized { sequence, .. }
            | Self::Exited { sequence, .. } => *sequence,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AttachState {
    Resume(Vec<SessionEvent>),
    Snapshot { sequence: u64, bytes: Vec<u8> },
}

#[derive(Default)]
struct QueueState {
    events: VecDeque<SessionEvent>,
    resync_pending: bool,
    closed: bool,
}

struct SubscriptionInner {
    capacity: usize,
    state: Mutex<QueueState>,
    ready: Condvar,
}

impl SubscriptionInner {
    fn push(&self, event: SessionEvent) {
        let Ok(mut state) = self.state.lock() else {
            return;
        };
        if state.closed {
            return;
        }
        if matches!(event, SessionEvent::Output { .. }) {
            if state.resync_pending {
                return;
            }
            if state.events.len() >= self.capacity {
                let sequence = event.sequence();
                state.events.clear();
                state
                    .events
                    .push_back(SessionEvent::ResyncRequired { sequence });
                state.resync_pending = true;
                self.ready.notify_one();
                return;
            }
        } else if state.events.len() >= self.capacity {
            let lost_output = state
                .events
                .iter()
                .any(|queued| matches!(queued, SessionEvent::Output { .. }));
            let preserve_resync = state.resync_pending;
            state.events.clear();
            if lost_output || preserve_resync {
                state.events.push_back(SessionEvent::ResyncRequired {
                    sequence: event.sequence(),
                });
                state.resync_pending = true;
            }
        }
        state.events.push_back(event);
        self.ready.notify_one();
    }

    fn close(&self) {
        if let Ok(mut state) = self.state.lock() {
            state.closed = true;
            self.ready.notify_all();
        }
    }
}

#[derive(Clone)]
pub struct SessionSubscription {
    inner: Arc<SubscriptionInner>,
}

impl SessionSubscription {
    pub fn recv_timeout(
        &self,
        timeout: Duration,
    ) -> std::result::Result<SessionEvent, std::sync::mpsc::RecvTimeoutError> {
        let state = self
            .inner
            .state
            .lock()
            .map_err(|_| std::sync::mpsc::RecvTimeoutError::Disconnected)?;
        let (mut state, timed_out) = self
            .inner
            .ready
            .wait_timeout_while(state, timeout, |state| {
                state.events.is_empty() && !state.closed
            })
            .map_err(|_| std::sync::mpsc::RecvTimeoutError::Disconnected)?;
        let Some(event) = state.events.pop_front() else {
            return Err(if timed_out.timed_out() {
                std::sync::mpsc::RecvTimeoutError::Timeout
            } else {
                std::sync::mpsc::RecvTimeoutError::Disconnected
            });
        };
        if matches!(event, SessionEvent::ResyncRequired { .. }) {
            state.resync_pending = false;
        }
        Ok(event)
    }

    pub fn pending_len(&self) -> usize {
        self.inner
            .state
            .lock()
            .map(|state| state.events.len())
            .unwrap_or(0)
    }

    pub fn close(&self) {
        self.inner.close();
    }
}

impl Drop for SessionSubscription {
    fn drop(&mut self) {
        if Arc::strong_count(&self.inner) == 1 {
            self.inner.close();
        }
    }
}

struct TerminalState {
    parser: vt100::Parser,
    history: VecDeque<SessionEvent>,
    sequence: u64,
}

pub struct ManagedSession {
    pub id: String,
    master: Mutex<Box<dyn portable_pty::MasterPty + Send>>,
    writer: Mutex<Box<dyn Write + Send>>,
    child: Mutex<Box<dyn portable_pty::Child + Send + Sync>>,
    reader_thread: Mutex<Option<std::thread::JoinHandle<()>>>,
    terminal: Mutex<TerminalState>,
    /// The last applied grid, `(cols, rows)` — the size the program running
    /// in this PTY believes it has. Only a local client sets it; a remote
    /// viewer is told it and renders scaled (phase 2 §1).
    size: Mutex<(u16, u16)>,
    subscribers: Mutex<Vec<Weak<SubscriptionInner>>>,
    engine: String,
    status: Mutex<SessionStatus>,
    shell_command_state: AtomicU8,
    activity: Mutex<ActivityState>,
    exit_code: Mutex<Option<Option<u32>>>,
}

impl ManagedSession {
    pub fn write_input(&self, data: &[u8]) -> Result<()> {
        let mut writer = self
            .writer
            .lock()
            .map_err(|e| anyhow!("PTY writer lock poisoned: {e}"))?;
        writer.write_all(data).context("write to master PTY")?;
        writer.flush().context("flush master PTY")?;
        if self.engine == "shell" && data.iter().any(|byte| matches!(byte, b'\r' | b'\n')) {
            self.shell_command_state.store(1, Ordering::Release);
        }
        // The engines echo, so a keystroke produces output. Remember when the
        // user last typed so the activity heuristic does not read their typing
        // as the agent working.
        if let Ok(mut activity) = self.activity.lock() {
            activity.last_input_at = Some(Instant::now());
        }
        Ok(())
    }

    pub fn send_interrupt(&self) -> Result<()> {
        self.write_input(b"\x03")
    }

    /// The grid this session is running at, as last applied by [`Self::resize`].
    pub fn size(&self) -> (u16, u16) {
        self.size
            .lock()
            .map(|size| *size)
            // A poisoned lock still holds the last size written; reporting it
            // beats inventing a grid the program is not running at.
            .unwrap_or_else(|poisoned| *poisoned.into_inner())
    }

    pub fn resize(&self, cols: u16, rows: u16, pixel_width: u16, pixel_height: u16) -> Result<()> {
        self.master
            .lock()
            .map_err(|e| anyhow!("PTY master lock poisoned: {e}"))?
            .resize(PtySize {
                rows,
                cols,
                pixel_width,
                pixel_height,
            })
            .context("resize PTY")?;
        let sequence = {
            let mut terminal = self
                .terminal
                .lock()
                .map_err(|e| anyhow!("terminal lock poisoned: {e}"))?;
            terminal.parser.set_size(rows, cols);
            terminal.sequence
        };
        *self
            .size
            .lock()
            .map_err(|e| anyhow!("session size lock poisoned: {e}"))? = (cols, rows);
        // Told, not asked: attached clients re-pin to the new grid the way
        // they do for a status change.
        self.broadcast(SessionEvent::Resized {
            sequence,
            cols,
            rows,
        });
        Ok(())
    }

    pub fn subscribe(&self, capacity: usize) -> SessionSubscription {
        self.subscribe_inner(capacity)
    }

    fn subscribe_inner(&self, capacity: usize) -> SessionSubscription {
        let inner = Arc::new(SubscriptionInner {
            capacity: capacity.max(1),
            state: Mutex::new(QueueState::default()),
            ready: Condvar::new(),
        });
        if let Ok(mut subscribers) = self.subscribers.lock() {
            subscribers.push(Arc::downgrade(&inner));
        }
        SessionSubscription { inner }
    }

    pub fn attach(&self, after_sequence: Option<u64>) -> AttachState {
        self.attach_locked(after_sequence)
    }

    pub fn attach_and_subscribe(
        &self,
        after_sequence: Option<u64>,
        capacity: usize,
    ) -> (AttachState, SessionSubscription) {
        let terminal = self.terminal.lock();
        // Keep the exit record locked while registering the subscriber. This
        // makes a concurrent finish choose exactly one delivery path: either
        // it broadcasts after this subscription is registered, or we replay
        // the already-recorded exit below.
        let exit_code = self.exit_code.lock();
        let subscription = self.subscribe_inner(capacity);
        let (state, sequence) = match terminal {
            Ok(mut terminal) => {
                let sequence = terminal.sequence;
                (
                    Self::attach_from_terminal(&mut terminal, after_sequence),
                    sequence,
                )
            }
            Err(_) => (
                AttachState::Snapshot {
                    sequence: 0,
                    bytes: b"\x1b[H\x1b[2J".to_vec(),
                },
                0,
            ),
        };
        {
            let status = self
                .status
                .lock()
                .map(|status| *status)
                .unwrap_or(SessionStatus::Ready);
            subscription.inner.push(SessionEvent::Status {
                sequence,
                status,
                engine: self.engine.clone(),
            });
        }
        if let Ok(exit_code) = exit_code {
            if let Some(exit_code) = *exit_code {
                subscription.inner.push(SessionEvent::Exited {
                    sequence,
                    exit_code,
                });
            }
        }
        (state, subscription)
    }

    fn attach_locked(&self, after_sequence: Option<u64>) -> AttachState {
        let Ok(mut terminal) = self.terminal.lock() else {
            return AttachState::Snapshot {
                sequence: 0,
                bytes: b"\x1b[H\x1b[2J".to_vec(),
            };
        };
        Self::attach_from_terminal(&mut terminal, after_sequence)
    }

    fn attach_from_terminal(
        terminal: &mut TerminalState,
        after_sequence: Option<u64>,
    ) -> AttachState {
        if let Some(after) = after_sequence {
            let oldest = terminal
                .history
                .front()
                .map(SessionEvent::sequence)
                .unwrap_or(terminal.sequence.saturating_add(1));
            if after <= terminal.sequence && after.saturating_add(1) >= oldest {
                return AttachState::Resume(
                    terminal
                        .history
                        .iter()
                        .filter(|event| event.sequence() > after)
                        .cloned()
                        .collect(),
                );
            }
        }
        terminal.parser.set_scrollback(0);
        let mut bytes = b"\x1b[H\x1b[2J".to_vec();
        bytes.extend(terminal.parser.screen().contents_formatted());
        AttachState::Snapshot {
            sequence: terminal.sequence,
            bytes,
        }
    }

    pub fn scrollback_rows(&self) -> usize {
        let Ok(mut terminal) = self.terminal.lock() else {
            return 0;
        };
        terminal.parser.set_scrollback(usize::MAX);
        let rows = terminal.parser.screen().scrollback();
        terminal.parser.set_scrollback(0);
        rows
    }

    fn record_output(&self, bytes: &[u8]) {
        let event = {
            let Ok(mut terminal) = self.terminal.lock() else {
                return;
            };
            terminal.sequence = terminal.sequence.saturating_add(1);
            terminal.parser.process(bytes);
            let event = SessionEvent::Output {
                sequence: terminal.sequence,
                bytes: bytes.to_vec(),
            };
            terminal.history.push_back(event.clone());
            while terminal.history.len() > OUTPUT_HISTORY_CHUNKS {
                terminal.history.pop_front();
            }
            event
        };
        if let Ok(mut activity) = self.activity.lock() {
            activity.record_output(Instant::now());
        }
        self.broadcast(event);
    }

    fn broadcast(&self, event: SessionEvent) {
        let subscribers = {
            let Ok(mut subscribers) = self.subscribers.lock() else {
                return;
            };
            let mut live = Vec::with_capacity(subscribers.len());
            subscribers.retain(|subscriber| {
                if let Some(subscriber) = subscriber.upgrade() {
                    live.push(subscriber);
                    true
                } else {
                    false
                }
            });
            live
        };
        for subscriber in subscribers {
            subscriber.push(event.clone());
        }
    }

    /// Recomputes this session's status and broadcasts it when it changed.
    /// A shell is judged by what is in its foreground process group; an agent
    /// by what is on its screen and how it is behaving.
    fn refresh_status(&self) {
        let next = if self.engine == "shell" {
            self.shell_status()
        } else {
            self.agent_status()
        };
        let Some(next) = next else { return };
        self.publish_status(next);
    }

    /// What an agent engine is doing, in urgency order: a question it is
    /// blocked on, then a failure, then a tool, then thinking, then ready.
    ///
    /// Screen state rather than stream latches. A latch is right for an event
    /// but wrong for a *state* that ends -- the engine repaints constantly, so
    /// a latched marker would re-fire forever and the light would never go
    /// back. Reading the live screen means a prompt that is answered, or a
    /// failure that scrolls off, clears itself with no extra bookkeeping.
    fn agent_status(&self) -> Option<SessionStatus> {
        let screen = self
            .terminal
            .lock()
            .ok()
            .map(|terminal| terminal.parser.screen().contents())?;
        if contains_attention_marker(&screen) {
            return Some(SessionStatus::AwaitingApproval);
        }
        if contains_error_marker(&screen) {
            return Some(SessionStatus::Error);
        }
        if contains_tool_execution_marker(&screen) {
            return Some(SessionStatus::ToolExecution);
        }
        // Screen first, timing second: the footer is the engine saying it is
        // working, the heuristic only guesses. The guess stays as the fallback
        // for engines whose TUI this does not know.
        let busy = contains_working_marker(&screen)
            || self
                .activity
                .lock()
                .map(|activity| activity.is_busy(Instant::now()))
                .unwrap_or(false);
        Some(if busy {
            SessionStatus::Thinking
        } else {
            SessionStatus::Ready
        })
    }

    fn publish_status(&self, next: SessionStatus) {
        let changed = self
            .status
            .lock()
            .map(|mut status| {
                if *status == next {
                    false
                } else {
                    *status = next;
                    true
                }
            })
            .unwrap_or(false);
        if changed {
            let sequence = self
                .terminal
                .lock()
                .map(|terminal| terminal.sequence)
                .unwrap_or(0);
            self.broadcast(SessionEvent::Status {
                sequence,
                status: next,
                engine: self.engine.clone(),
            });
        }
    }

    fn shell_status(&self) -> Option<SessionStatus> {
        let foreground = self
            .master
            .lock()
            .ok()
            .and_then(|master| master.process_group_leader());
        let shell = self
            .child
            .lock()
            .ok()
            .and_then(|child| child.process_id())
            .map(i64::from);
        match (foreground, shell) {
            (Some(foreground), Some(shell)) if i64::from(foreground) != shell => {
                self.shell_command_state.store(2, Ordering::Release);
                Some(SessionStatus::ToolExecution)
            }
            _ if self.shell_command_state.load(Ordering::Acquire) == 2 => {
                self.shell_command_state.store(0, Ordering::Release);
                Some(SessionStatus::Ready)
            }
            _ => None,
        }
    }

    fn finish(&self, exit_code: Option<u32>) {
        let sequence = self
            .terminal
            .lock()
            .map(|terminal| terminal.sequence)
            .unwrap_or(0);
        if let Ok(mut ended) = self.exit_code.lock() {
            *ended = Some(exit_code);
        }
        self.broadcast(SessionEvent::Exited {
            sequence,
            exit_code,
        });
    }

    fn kill(&self) -> Result<()> {
        {
            self.child
                .lock()
                .map_err(|e| anyhow!("PTY child lock poisoned: {e}"))?
                .kill()
                .context("kill PTY child")?;
        }
        if let Some(reader) = self
            .reader_thread
            .lock()
            .map_err(|e| anyhow!("PTY reader lock poisoned: {e}"))?
            .take()
        {
            reader
                .join()
                .map_err(|_| anyhow!("PTY reader thread panicked"))?;
        }
        Ok(())
    }
}

#[derive(Default)]
struct RegistryState {
    sessions: HashMap<String, Arc<ManagedSession>>,
    creating: HashSet<String>,
    exited: HashMap<String, ExitedSession>,
}

struct ExitedSession {
    session: Arc<ManagedSession>,
    exited_at: Instant,
}

impl RegistryState {
    fn prune_exited(&mut self) {
        self.exited
            .retain(|_, exited| exited.exited_at.elapsed() < EXITED_SESSION_RETENTION);
        if self.exited.len() <= MAX_EXITED_SESSIONS {
            return;
        }
        let mut oldest = self
            .exited
            .iter()
            .map(|(id, exited)| (id.clone(), exited.exited_at))
            .collect::<Vec<_>>();
        oldest.sort_by_key(|(_, exited_at)| *exited_at);
        let remove = self.exited.len() - MAX_EXITED_SESSIONS;
        for (id, _) in oldest.into_iter().take(remove) {
            self.exited.remove(&id);
        }
    }
}

#[derive(Clone, Default)]
pub struct SessionRegistry {
    state: Arc<Mutex<RegistryState>>,
}

impl SessionRegistry {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn create_session(&self, request: CreateSession) -> Result<Arc<ManagedSession>> {
        {
            let mut state = self
                .state
                .lock()
                .map_err(|e| anyhow!("session registry lock poisoned: {e}"))?;
            state.prune_exited();
            state.exited.remove(&request.id);
            if state.sessions.contains_key(&request.id)
                || !state.creating.insert(request.id.clone())
            {
                return Err(anyhow!("session {} already exists", request.id));
            }
            if state.sessions.len() + state.creating.len() > MAX_SESSIONS {
                state.creating.remove(&request.id);
                return Err(anyhow!("maximum of {MAX_SESSIONS} sessions reached"));
            }
        }

        let spawned = spawn_session(&request);
        let (session, mut reader, mut transcript) = match spawned {
            Ok(spawned) => spawned,
            Err(error) => {
                if let Ok(mut state) = self.state.lock() {
                    state.creating.remove(&request.id);
                }
                return Err(error);
            }
        };

        {
            let mut state = self
                .state
                .lock()
                .map_err(|e| anyhow!("session registry lock poisoned: {e}"))?;
            state.creating.remove(&request.id);
            state
                .sessions
                .insert(request.id.clone(), Arc::clone(&session));
        }

        let weak_session = Arc::downgrade(&session);
        let weak_registry = Arc::downgrade(&self.state);
        let id = request.id;
        let reader_thread = std::thread::spawn(move || {
            let mut buffer = [0; 4096];
            loop {
                match reader.read(&mut buffer) {
                    Ok(0) | Err(_) => break,
                    Ok(read) => {
                        if let Some(transcript) = transcript.as_mut() {
                            transcript.write(&buffer[..read]);
                        }
                        if let Some(session) = weak_session.upgrade() {
                            session.record_output(&buffer[..read]);
                        } else {
                            break;
                        }
                    }
                }
            }
            if let Some(transcript) = transcript.as_mut() {
                transcript.finish();
            }
            let exit_code = weak_session.upgrade().and_then(|session| {
                session
                    .child
                    .lock()
                    .ok()
                    .and_then(|mut child| child.wait().ok())
                    .map(|status| status.exit_code())
            });
            let ended_session = weak_session.upgrade();
            if let Some(session) = &ended_session {
                session.finish(exit_code);
            }
            if let Some(registry) = weak_registry.upgrade() {
                if let Ok(mut registry) = registry.lock() {
                    registry.sessions.remove(&id);
                    if let Some(session) = ended_session {
                        registry.exited.insert(
                            id,
                            ExitedSession {
                                session,
                                exited_at: Instant::now(),
                            },
                        );
                        registry.prune_exited();
                    }
                }
            }
        });
        if let Ok(mut handle) = session.reader_thread.lock() {
            *handle = Some(reader_thread);
        }
        {
            let status_session = Arc::downgrade(&session);
            std::thread::spawn(move || loop {
                std::thread::sleep(Duration::from_millis(75));
                let Some(session) = status_session.upgrade() else {
                    return;
                };
                if session
                    .exit_code
                    .lock()
                    .map(|exit_code| exit_code.is_some())
                    .unwrap_or(true)
                {
                    return;
                }
                session.refresh_status();
            });
        }

        Ok(session)
    }

    pub fn get(&self, id: &str) -> Option<Arc<ManagedSession>> {
        self.state.lock().ok()?.sessions.get(id).cloned()
    }

    pub(crate) fn get_attachable(&self, id: &str) -> Option<Arc<ManagedSession>> {
        let mut state = self.state.lock().ok()?;
        state.prune_exited();
        state.sessions.get(id).cloned().or_else(|| {
            state
                .exited
                .get(id)
                .map(|exited| Arc::clone(&exited.session))
        })
    }

    pub fn list(&self) -> Vec<String> {
        let mut sessions = self
            .state
            .lock()
            .map(|mut state| {
                state.prune_exited();
                state.sessions.keys().cloned().collect::<Vec<_>>()
            })
            .unwrap_or_default();
        sessions.sort();
        sessions
    }

    pub fn kill(&self, id: &str) -> bool {
        let session = self
            .state
            .lock()
            .ok()
            .and_then(|mut state| state.sessions.remove(id));
        session.is_some_and(|session| session.kill().is_ok())
    }

    pub fn shutdown(&self) {
        let sessions = self
            .state
            .lock()
            .map(|mut state| {
                state.creating.clear();
                state.exited.clear();
                state.sessions.drain().map(|(_, session)| session).collect()
            })
            .unwrap_or_else(|_| Vec::new());
        for session in sessions {
            let _ = session.kill();
        }
    }
}

type SpawnedSession = (
    Arc<ManagedSession>,
    Box<dyn Read + Send>,
    Option<Transcript>,
);

/// Whether an inherited variable is a *parent agent session's* identity
/// rather than configuration a pane should keep.
///
/// Prefix-matched, not enumerated: `CLAUDE_CODE_CHILD_SESSION` was only the
/// symptom Bruno could see. `CLAUDE_CODE_SESSION_ID` is the one that actually
/// hurts, and the next release can add another. A caller that genuinely wants
/// one of these sets it in `CreateSession::env`, which is applied after this
/// and wins.
fn is_inherited_agent_identity(name: &str) -> bool {
    // ponytail: Claude only — Codex/agy don't export session markers today.
    // Add a prefix here if one starts to.
    name == "CLAUDECODE" || name.starts_with("CLAUDE_")
}

/// Drop the launching Claude session's identity from a pane's environment.
///
/// The daemon is long-lived and inherits whatever launched it — and it is
/// routinely launched from inside a Claude Code terminal, because that is what
/// `scripts/rebuild-app.sh` does. Left in place, every pane the daemon spawns
/// believes it *is* the launching session: `claude` sees
/// `CLAUDE_CODE_CHILD_SESSION` and refuses to save a transcript, and it adopts
/// the parent's `CLAUDE_CODE_SESSION_ID` — so every terminal in every window
/// lands on one shared conversation under one shared name, which is the exact
/// collision `--session-id` exists to prevent.
fn strip_inherited_agent_identity(command: &mut CommandBuilder) {
    for (key, _) in std::env::vars_os() {
        if is_inherited_agent_identity(&key.to_string_lossy()) {
            command.env_remove(&key);
        }
    }
}

fn spawn_session(request: &CreateSession) -> Result<SpawnedSession> {
    let engine = infer_engine(&request.command);
    let pair = NativePtySystem::default()
        .openpty(PtySize {
            rows: request.rows,
            cols: request.cols,
            pixel_width: 0,
            pixel_height: 0,
        })
        .context("open PTY")?;
    let mut command = if let Some(program) = request.command.first() {
        let mut command = CommandBuilder::new(program);
        command.args(request.command.iter().skip(1));
        command
    } else {
        CommandBuilder::new("/bin/zsh")
    };
    if let Some(cwd) = &request.cwd {
        command.cwd(cwd);
    }
    strip_inherited_agent_identity(&mut command);
    for (key, value) in &request.env {
        command.env(key, value);
    }

    let child = pair
        .slave
        .spawn_command(command)
        .context("spawn command in PTY")?;
    let reader = pair.master.try_clone_reader().context("clone PTY reader")?;
    let writer = pair.master.take_writer().context("take PTY writer")?;
    let transcript = request
        .transcript_path
        .as_ref()
        .map(Transcript::open)
        .transpose()?;

    Ok((
        Arc::new(ManagedSession {
            id: request.id.clone(),
            master: Mutex::new(pair.master),
            writer: Mutex::new(writer),
            child: Mutex::new(child),
            reader_thread: Mutex::new(None),
            terminal: Mutex::new(TerminalState {
                parser: vt100::Parser::new(request.rows, request.cols, SCROLLBACK_LINES),
                history: VecDeque::new(),
                sequence: 0,
            }),
            size: Mutex::new((request.cols, request.rows)),
            subscribers: Mutex::new(Vec::new()),
            engine,
            status: Mutex::new(SessionStatus::Ready),
            activity: Mutex::new(ActivityState::default()),
            shell_command_state: AtomicU8::new(0),
            exit_code: Mutex::new(None),
        }),
        reader,
        transcript,
    ))
}

fn infer_engine(command: &[String]) -> String {
    let binary = command
        .first()
        .and_then(|path| std::path::Path::new(path).file_name())
        .and_then(|name| name.to_str())
        .unwrap_or_default();
    match binary {
        "claude" | "codex" | "copilot" | "antigravity" => binary.to_string(),
        // AntiGravity's CLI is `agy`; without this it fell through to "shell"
        // and got the shell's status rules, which are wrong for an agent.
        "agy" => "antigravity".to_string(),
        _ => "shell".to_string(),
    }
}

#[cfg(test)]
mod status_tests {
    use super::*;

    /// The two markers that actually broke a pane — transcript saving and
    /// conversation identity — plus proof the filter is not just "anything
    /// with CLAUDE in it".
    #[test]
    fn parent_claude_session_markers_are_stripped_but_config_is_not() {
        assert!(is_inherited_agent_identity("CLAUDE_CODE_CHILD_SESSION"));
        assert!(is_inherited_agent_identity("CLAUDE_CODE_SESSION_ID"));
        assert!(is_inherited_agent_identity("CLAUDECODE"));
        assert!(!is_inherited_agent_identity("ANTHROPIC_API_KEY"));
        assert!(!is_inherited_agent_identity("PATH"));
    }

    #[test]
    fn antigravity_is_recognised_by_its_real_binary_name() {
        assert_eq!(infer_engine(&["/usr/local/bin/agy".into()]), "antigravity");
        assert_eq!(infer_engine(&["/usr/local/bin/claude".into()]), "claude");
        assert_eq!(infer_engine(&["/bin/zsh".into(), "-l".into()]), "shell");
    }

    #[test]
    fn an_approval_prompt_is_recognised() {
        assert!(contains_attention_marker("Do you want to create notes.txt?"));
        assert!(contains_attention_marker("Would you like to continue?"));
        // The shared selection-dialog footer: AskUserQuestion, trust prompt.
        assert!(contains_attention_marker(
            "Enter to select · ↑/↓ to navigate · Esc to cancel"
        ));
        assert!(contains_attention_marker("Enter to confirm · Esc to cancel"));
        assert!(!contains_attention_marker("Reading src/main.rs"));
        // The busy-state hint is lowercase and must not read as blocked.
        assert!(!contains_attention_marker("esc to interrupt"));
    }

    /// `Exit code 0` is a success. Getting this wrong paints a healthy
    /// terminal red for every command that succeeds.
    #[test]
    fn only_a_non_zero_exit_code_is_an_error() {
        assert!(contains_error_marker("Exit code 1"));
        assert!(contains_error_marker("Exit code 127"));
        assert!(!contains_error_marker("Exit code 0"));
        assert!(!contains_error_marker("no failure here"));
    }

    /// Claude renders the value differently at different pane widths: inline
    /// at 120 columns, and as a colon-label with styling between label and
    /// digit at the 80 a pane actually opens at.
    #[test]
    fn the_exit_code_value_is_found_through_styling() {
        assert!(contains_error_marker("Exit code: \u{1b}[1m2\u{1b}[0m"));
        assert!(!contains_error_marker("Exit code: \u{1b}[1m0\u{1b}[0m"));
    }

    /// Captured live from real v2.1.234 panes through this daemon's parser.
    /// The finished line is the one that used to be indistinguishable.
    #[test]
    fn a_working_footer_is_recognised_and_a_finished_one_is_not() {
        assert!(contains_working_marker("✽ Brewing… (4m 59s · ↓ 17.2k tokens)"));
        assert!(contains_working_marker(
            "✶ Beboppin'… (2m 28s · ↓ 7.4k tokens · thought for 1s)"
        ));
        assert!(contains_working_marker("  ✻ Recombobulating… (5s)"));
        assert!(!contains_working_marker("✻ Baked for 6m 32s"));
        assert!(!contains_working_marker("⏵⏵ auto mode on (shift+tab to cycle)"));
        // A truncated command line ends in an ellipsis too, but does not open
        // with a spinner.
        assert!(!contains_working_marker("  echo \"=== LOG ===\"; git log --oneli…"));
    }

    #[test]
    fn a_tool_run_is_recognised_on_screen() {
        assert!(contains_tool_execution_marker(
            "Bash(cargo test)  ctrl-b to run in background)"
        ));
        assert!(!contains_tool_execution_marker("nothing running"));
    }

    /// The measurement this heuristic exists for: an idle `claude` emits a
    /// tight burst every few seconds. A burst is not work.
    #[test]
    fn an_idle_burst_is_not_busy() {
        let start = Instant::now();
        let mut activity = ActivityState::default();
        activity.record_output(start);
        activity.record_output(start + Duration::from_millis(50));
        assert!(!activity.is_busy(start + Duration::from_millis(60)));
    }

    #[test]
    fn sustained_output_is_busy_until_it_goes_quiet() {
        let start = Instant::now();
        let mut activity = ActivityState::default();
        for step in 0..20 {
            activity.record_output(start + Duration::from_millis(step * 100));
        }
        let last = start + Duration::from_millis(1_900);
        assert!(activity.is_busy(last));
        // Quiet for longer than the threshold and it is no longer working.
        assert!(!activity.is_busy(last + Duration::from_millis(800)));
    }

    /// The engines echo, so typing produces sustained output. It must not read
    /// as the agent working.
    #[test]
    fn typing_never_reads_as_the_agent_working() {
        let start = Instant::now();
        let mut activity = ActivityState::default();
        for step in 0..20 {
            activity.record_output(start + Duration::from_millis(step * 100));
        }
        let last = start + Duration::from_millis(1_900);
        activity.last_input_at = Some(last);
        assert!(!activity.is_busy(last));

        // And it recovers once they stop typing but output keeps coming — the
        // agent really is working now.
        for step in 20..40 {
            activity.record_output(start + Duration::from_millis(step * 100));
        }
        assert!(activity.is_busy(start + Duration::from_millis(3_900)));
    }
}
