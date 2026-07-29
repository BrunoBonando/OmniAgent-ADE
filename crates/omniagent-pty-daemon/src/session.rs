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
pub const MAX_SESSIONS: usize = 8;
const OUTPUT_HISTORY_CHUNKS: usize = 256;
const EXITED_SESSION_RETENTION: Duration = Duration::from_secs(10);
const MAX_EXITED_SESSIONS: usize = MAX_SESSIONS * 2;

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
    subscribers: Mutex<Vec<Weak<SubscriptionInner>>>,
    engine: String,
    status: Mutex<SessionStatus>,
    shell_command_state: AtomicU8,
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
        Ok(())
    }

    pub fn send_interrupt(&self) -> Result<()> {
        self.write_input(b"\x03")
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
        self.terminal
            .lock()
            .map_err(|e| anyhow!("terminal lock poisoned: {e}"))?
            .parser
            .set_size(rows, cols);
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
        if self.engine == "shell" {
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

    fn refresh_shell_status(&self) {
        if self.engine != "shell" {
            return;
        }
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
        let next = match (foreground, shell) {
            (Some(foreground), Some(shell)) if i64::from(foreground) != shell => {
                self.shell_command_state.store(2, Ordering::Release);
                SessionStatus::ToolExecution
            }
            _ if self.shell_command_state.load(Ordering::Acquire) == 2 => {
                self.shell_command_state.store(0, Ordering::Release);
                SessionStatus::Ready
            }
            _ => return,
        };
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
        if session.engine == "shell" {
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
                session.refresh_shell_status();
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
            subscribers: Mutex::new(Vec::new()),
            engine,
            status: Mutex::new(SessionStatus::Ready),
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
        _ => "shell".to_string(),
    }
}
