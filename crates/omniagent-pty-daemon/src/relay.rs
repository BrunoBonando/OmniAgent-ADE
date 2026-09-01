//! The relay client — the daemon's outbound side of remote session control
//! (`docs/superpowers/specs/2026-08-30-remote-session-control-design.md`
//! §1 Topology, §3 Daemon changes, §6 Failure modes).
//!
//! While the `relay_device_token` row parses, the `remote_sharing` switch is
//! on **and** the host's own app is attached (spec §2's three conditions,
//! [`sharing_should_be_live`]), [`run_relay`] holds one outbound **control**
//! WebSocket to the relay (`/v1/device`, `Authorization: Bearer <token>`).
//! Every `{"open": "<conn_id>"}` the relay sends down it dials a **data**
//! WebSocket (`/v1/device/conn/{conn_id}`) and runs the ordinary
//! per-connection handler over it with [`ClientTrust::Remote`] — the relay is
//! a dumb pipe, so the daemon protocol (`protocol.rs`) is unchanged; binary
//! messages carry the byte stream and frames may span messages.
//!
//! The relay URL comes from the token row (`relay_url`, `https://…` →
//! `wss://`, `http://` → `ws://` for tests), never from an env var.
//!
//! Settings changes arrive through `ClientContext::settings_changed`, which
//! the `SetSetting` handler pokes after **every** key — so each wake re-reads
//! [`relay_config`] and compares before doing anything; an unrelated write
//! never drops the control socket — and, since one of the three conditions is
//! not a settings row at all, every wait is also bounded by [`RECHECK_EVERY`].
//! Sharing switched off, the token removed, or the host's app gone past the
//! grace closes the control socket and, with it, every data connection. A `401`
//! (or `403`) from the relay stops retrying until the token row changes. A
//! control socket that goes silent for three ping intervals is treated as
//! half-open and re-dialled — TCP alone would not notice for minutes.

use std::time::{Duration, Instant};

use anyhow::Result;
use brain_core::Store;
use bytes::Bytes;
use futures_util::{SinkExt, StreamExt};
use tokio::task::JoinSet;
use tokio_tungstenite::connect_async;
use tokio_tungstenite::tungstenite::client::IntoClientRequest;
use tokio_tungstenite::tungstenite::http::header::AUTHORIZATION;
use tokio_tungstenite::tungstenite::{Error as WsError, Message};

use crate::connections::AssertedIdentity;
use crate::server::{
    remote_control_active, serve_client, sharing_should_be_live, ClientContext, ClientTrust,
};

/// The settings row holding the device credential the relay issued at pairing.
pub const DEVICE_TOKEN_KEY: &str = "relay_device_token";
/// Both sides ping every 30 s — Cloudflare drops idle WebSockets at ~100 s (spec §1).
const PING_EVERY: Duration = Duration::from_secs(30);
const INITIAL_BACKOFF: Duration = Duration::from_secs(1);
const MAX_BACKOFF: Duration = Duration::from_secs(30);
/// Silent for this many ping intervals → the socket is half-open (spec §6
/// "host asleep / offline", a hard-killed relay pod): nothing arrives, our
/// pings still "succeed" into the kernel buffer, and TCP would take minutes
/// to give up. The relay pings every 30 s too, so a live socket is never
/// silent for one interval, let alone three.
const SILENT_INTERVALS: u32 = 3;
/// Data connections per control session — one per viewer.
const MAX_DATA_CONNECTIONS: usize = 64;
/// How often the sharing condition is re-tested while this task is waiting.
///
/// Two of its three parts are settings rows, and every `SetSetting` pokes
/// `settings_changed`. The third is not a settings write at all: a local app
/// connecting or disappearing writes nothing, and the grace expiring
/// (`server::LOCAL_ABSENCE_GRACE`) is not an event — nothing would ever wake
/// this task to notice it. So every wait here is bounded by this tick, which
/// is what brings the control channel down within a second of the grace
/// running out, and back up within a second of the app returning.
const RECHECK_EVERY: Duration = Duration::from_secs(1);

/// The `relay_device_token` row as written by the app after pairing.
#[derive(Clone, Debug, PartialEq, Eq, serde::Deserialize)]
pub struct DeviceCredential {
    pub device_id: String,
    pub token: String,
    pub name: String,
    pub relay_url: String,
}

/// `Some` iff the token row parses **and** `remote_sharing` is on (spec
/// §2) — the two conditions under which the daemon keeps a control socket
/// open. Machine-wide, not per-workspace: an idle Mac with sharing on stays
/// reachable regardless of what `remote_control` does or does not list, or a
/// Mac would only ever appear on the other Mac while it happened to be busy.
pub fn relay_config(store: &Store) -> Option<DeviceCredential> {
    let raw = store.get_setting(DEVICE_TOKEN_KEY).ok().flatten()?;
    let cred: DeviceCredential = serde_json::from_str(&raw).ok()?;
    remote_control_active(store).then_some(cred)
}

fn ws_url(cred: &DeviceCredential, path: &str) -> String {
    let base = cred.relay_url.trim_end_matches('/');
    let base = base
        .replacen("https://", "wss://", 1)
        .replacen("http://", "ws://", 1);
    format!("{base}{path}")
}

fn request(
    cred: &DeviceCredential,
    path: &str,
) -> Result<tokio_tungstenite::tungstenite::http::Request<()>> {
    let mut req = ws_url(cred, path).into_client_request()?;
    req.headers_mut()
        .insert(AUTHORIZATION, format!("Bearer {}", cred.token).parse()?);
    Ok(req)
}

/// Why one control session ended.
enum Outcome {
    /// The relay refused the token (401/403): stop until the token row changes.
    Unauthorized,
    /// The socket dropped, or never connected (`uptime` is zero then): back
    /// off and retry. `uptime` is how long the session was up past the
    /// hello — a session that lived a while resets the backoff; one the relay
    /// accepted and dropped at once must not, or the loop would tighten to
    /// one dial per second against a relay that is up but broken.
    Dropped { uptime: Duration },
    /// The config we connected with is no longer current: re-read and act now.
    ConfigChanged,
}

/// The relay's `viewer` dictionary, or `None` when it did not send one
/// (spec §9).
///
/// An **object** is required, not merely something that deserializes: a
/// missing key is `Value::Null`, and so is an explicit `"viewer": null`, and
/// both must come back `None` rather than as an all-`None` identity that a
/// later check might mistake for an assertion. Unknown keys inside the object
/// are ignored, so the relay can add fields without a daemon release.
fn asserted_viewer(value: &serde_json::Value) -> Option<AssertedIdentity> {
    value.as_object()?;
    serde_json::from_value(value.clone()).ok()
}

/// Whether a relay-issued connection id is safe to interpolate into a path.
fn valid_conn_id(id: &str) -> bool {
    !id.is_empty()
        && id
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
}

/// What the *settings rows* say to dial with, re-reading the store after a
/// rebuild the way `server.rs`'s `lock_store` does. Not the whole condition:
/// see [`current`].
fn configured(ctx: &ClientContext) -> Option<DeviceCredential> {
    ctx.settings.lock().ok().and_then(|mut store| {
        let _ = store.reopen_if_replaced();
        relay_config(&store)
    })
}

/// The credential to hold a control channel with **right now**, or `None` if
/// this machine should not have one open at all.
///
/// Two questions under one lock: [`configured`] answers what to dial with,
/// and [`sharing_should_be_live`] answers whether to be dialling — the full
/// three-way condition of spec §2, whose third part (a local app is attached,
/// which is also what forbids chaining) no settings write ever announces.
/// Everything in this file that decides whether to open, keep or close the
/// control channel goes through here, so the local condition needs no separate
/// path of its own.
fn current(ctx: &ClientContext) -> Option<DeviceCredential> {
    ctx.settings.lock().ok().and_then(|mut store| {
        let _ = store.reopen_if_replaced();
        relay_config(&store).filter(|_| sharing_should_be_live(&store, &ctx.connections))
    })
}

/// The [`RECHECK_EVERY`] ticker, on an absolute schedule.
///
/// An `Interval` rather than a `sleep` recreated per wait, because the wait
/// this drives sits in a `select!` next to the relay's own traffic: a `sleep`
/// would be dropped and restarted every time anything else arrived, so a relay
/// that chattered faster than the interval could keep the sharing condition
/// from ever being re-tested — and a host whose app had quit would go on being
/// shared for exactly as long as the chatter lasted.
///
/// `Delay` on missed ticks because this machine sleeps: an hour suspended must
/// not come back as an hour's worth of catch-up ticks, all asking the same
/// question.
fn recheck_ticker() -> tokio::time::Interval {
    let mut ticker = tokio::time::interval(RECHECK_EVERY);
    ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    ticker
}

/// Waits for a settings write or for the next [`RECHECK_EVERY`] tick,
/// whichever comes first; the caller re-reads [`current`] and compares either
/// way. Both halves are cancel-safe, and the ticker keeps its schedule across
/// calls.
async fn changed_or_recheck(ctx: &ClientContext, recheck: &mut tokio::time::Interval) {
    tokio::select! {
        _ = ctx.settings_changed.notified() => {}
        _ = recheck.tick() => {}
    }
}

/// Drives the control and data connections forever. Spawned once by
/// `DaemonServer::serve` when the relay is enabled; tests call it directly.
pub async fn run_relay(ctx: ClientContext) {
    run_relay_with(ctx, PING_EVERY).await
}

/// [`run_relay`] with the ping interval (and so the liveness window,
/// `SILENT_INTERVALS` × `ping_every`) chosen by the caller — the seam the
/// loopback tests use to make a silent relay time out in milliseconds.
pub async fn run_relay_with(ctx: ClientContext, ping_every: Duration) {
    // tokio-tungstenite builds its rustls `ClientConfig` from the process
    // default provider; pin `ring` here so a `wss://` connect can never panic
    // on an ambiguous or missing provider. `Err` only means one is already
    // installed, which is equally fine.
    let _ = rustls::crypto::ring::default_provider().install_default();
    let mut backoff = INITIAL_BACKOFF;
    // One ticker for the life of the task, shared by both waits below: the
    // condition is re-tested on a schedule rather than on each wait's own
    // clock.
    let mut recheck = recheck_ticker();
    loop {
        let Some(cred) = current(&ctx) else {
            backoff = INITIAL_BACKOFF;
            // Not `settings_changed` alone: the commonest reason to be here is
            // that the host's app has not connected yet (or has just been
            // replaced by `rebuild-app.sh`), and its return pokes nothing.
            changed_or_recheck(&ctx, &mut recheck).await;
            continue;
        };
        match control_session(&ctx, &cred, ping_every, &mut recheck).await {
            Outcome::Unauthorized => {
                tracing::warn!("relay rejected the device token; waiting for a new one");
                // Every key pokes `settings_changed`; only a different token
                // row (or sharing switched off) is worth another attempt.
                //
                // [`configured`] rather than [`current`], and no tick: what is
                // being waited for here is a *credential* the relay might
                // accept. Testing the whole condition would let the host's app
                // merely restarting fall out of this wait and re-dial the same
                // rejected token.
                while configured(&ctx).as_ref() == Some(&cred) {
                    ctx.settings_changed.notified().await;
                }
                backoff = INITIAL_BACKOFF;
            }
            Outcome::ConfigChanged => backoff = INITIAL_BACKOFF,
            Outcome::Dropped { uptime } => {
                // A session that outlived the longest backoff was a healthy
                // one: its drop is a fresh outage, not the next step of the
                // one we were already backing off from.
                if uptime >= MAX_BACKOFF {
                    backoff = INITIAL_BACKOFF;
                }
                // A settings write (a re-pair, a workspace toggled) cuts the
                // wait short — the next iteration re-reads the config anyway,
                // so a stale credential is never dialled.
                tokio::select! {
                    _ = tokio::time::sleep(backoff) => {}
                    _ = ctx.settings_changed.notified() => {}
                }
                backoff = (backoff * 2).min(MAX_BACKOFF);
            }
        }
    }
}

async fn control_session(
    ctx: &ClientContext,
    cred: &DeviceCredential,
    ping_every: Duration,
    recheck: &mut tokio::time::Interval,
) -> Outcome {
    let never_connected = Outcome::Dropped {
        uptime: Duration::ZERO,
    };
    let req = match request(cred, "/v1/device") {
        Ok(req) => req,
        Err(error) => {
            tracing::warn!("relay control request could not be built: {error}");
            return never_connected;
        }
    };
    let (ws, _) = match connect_async(req).await {
        Ok(ok) => ok,
        Err(WsError::Http(resp)) if matches!(resp.status().as_u16(), 401 | 403) => {
            return Outcome::Unauthorized
        }
        Err(error) => {
            tracing::debug!("relay control connect failed: {error}");
            return never_connected;
        }
    };
    let (mut sink, mut stream) = ws.split();
    let hello = serde_json::json!({
        "hostname": cred.name,
        "daemon_version": env!("CARGO_PKG_VERSION"),
    });
    if sink
        .send(Message::Text(hello.to_string().into()))
        .await
        .is_err()
    {
        return never_connected;
    }
    tracing::info!("relay control socket up as device {}", cred.device_id);
    let connected = Instant::now();
    let dropped = || Outcome::Dropped {
        uptime: connected.elapsed(),
    };
    // Dropped on every return path, which aborts every data connection —
    // spec §3: "projection empties or token removed → close control channel
    // and all data connections".
    let mut data = JoinSet::new();
    let mut ping = tokio::time::interval(ping_every);
    ping.tick().await;
    // Liveness: anything the relay sends (its pings, pongs to ours, opens)
    // refreshes this; silence for `SILENT_INTERVALS` intervals is a dead link.
    let mut last_seen = Instant::now();
    loop {
        tokio::select! {
            _ = ping.tick() => {
                if last_seen.elapsed() > ping_every * SILENT_INTERVALS {
                    tracing::warn!("relay control socket silent for {:?}; re-dialling", last_seen.elapsed());
                    return dropped();
                }
                if sink.send(Message::Ping(Bytes::new())).await.is_err() {
                    return dropped();
                }
            }
            msg = stream.next() => match msg {
                Some(Ok(Message::Text(text))) => {
                    last_seen = Instant::now();
                    let message = serde_json::from_str::<serde_json::Value>(&text).ok();
                    let open = message
                        .as_ref()
                        .and_then(|v| v["open"].as_str().map(str::to_owned));
                    if let Some(id) = open {
                        // Parsed from the *same* message as the connection id
                        // and passed down beside it, so the identity a data
                        // socket is served under can only ever be the one the
                        // relay attached to that `conn_id` (spec §9).
                        let asserted = message.as_ref().and_then(|v| asserted_viewer(&v["viewer"]));
                        if !valid_conn_id(&id) {
                            tracing::debug!("relay sent an invalid connection id; ignoring");
                        } else if data.len() >= MAX_DATA_CONNECTIONS {
                            tracing::warn!("relay open {id} refused: {MAX_DATA_CONNECTIONS} data connections already up");
                        } else {
                            data.spawn(data_connection(ctx.clone(), cred.clone(), id, asserted));
                        }
                    }
                }
                Some(Ok(Message::Close(_))) | Some(Err(_)) | None => return dropped(),
                Some(Ok(_)) => last_seen = Instant::now(),
            },
            // The condition is re-tested on every settings write *and* on a
            // tick, because the local-app half of it (spec §2 condition 3)
            // changes without one — and because the 5 s grace expiring is not
            // an event that could poke anything. Closing here is what drops
            // every viewer: the `JoinSet` of data connections goes with this
            // function's frame.
            _ = changed_or_recheck(ctx, recheck) => {
                if current(ctx).as_ref() != Some(cred) {
                    let _ = sink.close().await;
                    return Outcome::ConfigChanged;
                }
            }
            Some(_) = data.join_next(), if !data.is_empty() => {}
        }
    }
}

/// One relayed viewer: dial the data socket, adapt it to a byte stream and
/// hand it to the ordinary handler as a `Remote` client — carrying the
/// identity the relay asserted for this `conn_id` (spec §9).
///
/// `asserted` is `None` only when the relay opened a connection it did not
/// describe. That is **refused outright** rather than served with an empty
/// identity: the account check in `server.rs` exists to be run on every remote
/// connection, and a check that can be skipped by omitting a field is not a
/// check. The socket is still dialled first so the waiting viewer is closed on
/// at once instead of hanging until the relay times it out.
async fn data_connection(
    ctx: ClientContext,
    cred: DeviceCredential,
    conn_id: String,
    asserted: Option<AssertedIdentity>,
) {
    let Ok(req) = request(&cred, &format!("/v1/device/conn/{conn_id}")) else {
        return;
    };
    let (ws, _) = match connect_async(req).await {
        Ok(ok) => ok,
        Err(error) => {
            tracing::debug!("relay data connect for {conn_id} failed: {error}");
            return;
        }
    };
    let Some(asserted) = asserted else {
        tracing::warn!(
            "relay opened {conn_id} with no asserted viewer identity; closing it unserved"
        );
        let (mut sink, _) = ws.split();
        let _ = sink.close().await;
        return;
    };
    let (sink, stream) = ws.split();
    let reader = tokio_util::io::StreamReader::new(stream.filter_map(|message| {
        std::future::ready(match message {
            Ok(Message::Binary(bytes)) => Some(Ok::<Bytes, std::io::Error>(bytes)),
            Ok(Message::Close(_)) | Err(_) => Some(Err(std::io::Error::new(
                std::io::ErrorKind::ConnectionReset,
                "relay closed",
            ))),
            Ok(_) => None,
        })
    }));
    let writer = tokio_util::io::SinkWriter::new(tokio_util::io::CopyToBytes::new(
        sink.sink_map_err(|error| std::io::Error::new(std::io::ErrorKind::BrokenPipe, error))
            .with(|bytes: Bytes| {
                std::future::ready(Ok::<_, std::io::Error>(Message::Binary(bytes)))
            }),
    ));
    if let Err(error) = serve_client(
        tokio::io::join(reader, writer),
        ctx,
        ClientTrust::Remote(Box::new(asserted)),
    )
    .await
    {
        tracing::debug!("relayed client {conn_id} ended: {error}");
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cred(relay_url: &str) -> DeviceCredential {
        DeviceCredential {
            device_id: "dev".into(),
            token: "tok".into(),
            name: "Mac".into(),
            relay_url: relay_url.into(),
        }
    }

    #[test]
    fn ws_url_maps_http_schemes_to_websocket_schemes() {
        assert_eq!(
            ws_url(&cred("https://relay.omni-agent.ai"), "/v1/device"),
            "wss://relay.omni-agent.ai/v1/device"
        );
        assert_eq!(
            ws_url(&cred("http://127.0.0.1:9/"), "/v1/device/conn/c1"),
            "ws://127.0.0.1:9/v1/device/conn/c1"
        );
        assert_eq!(
            ws_url(&cred("wss://relay.omni-agent.dev"), "/v1/device"),
            "wss://relay.omni-agent.dev/v1/device"
        );
    }

    #[test]
    fn connection_ids_are_path_safe_or_ignored() {
        assert!(valid_conn_id("c1"));
        assert!(valid_conn_id("conn-42_ab"));
        assert!(!valid_conn_id(""));
        assert!(!valid_conn_id("../device"));
        assert!(!valid_conn_id("c1/../../v1/other"));
        assert!(!valid_conn_id("c 1"));
        assert!(!valid_conn_id("c1?x=1"));
    }

    #[test]
    fn request_carries_the_bearer_token() {
        let req = request(&cred("https://relay.omni-agent.ai"), "/v1/device").unwrap();
        assert_eq!(req.headers()[AUTHORIZATION], "Bearer tok");
        assert_eq!(req.uri().path(), "/v1/device");
    }

    #[test]
    fn relay_config_needs_both_a_token_row_and_sharing_enabled() {
        let store = Store::open_in_memory().unwrap();
        assert_eq!(relay_config(&store), None);
        store
            .set_setting(
                DEVICE_TOKEN_KEY,
                r#"{"device_id":"dev","token":"tok","name":"Mac","relay_url":"https://r"}"#,
            )
            .unwrap();
        assert_eq!(relay_config(&store), None, "token alone is not enough");
        store
            .set_setting(crate::server::REMOTE_SHARING_KEY, r#"{"enabled":true}"#)
            .unwrap();
        assert_eq!(relay_config(&store), Some(cred("https://r")));
        store
            .set_setting(crate::server::REMOTE_SHARING_KEY, r#"{"enabled":false}"#)
            .unwrap();
        assert_eq!(
            relay_config(&store),
            None,
            "sharing switched off turns it off"
        );
        store.set_setting(DEVICE_TOKEN_KEY, "not json").unwrap();
        assert_eq!(relay_config(&store), None, "unparsable token row is off");
    }

    /// Sharing is machine-wide now, not per-workspace: turning it on opens
    /// the tunnel with `remote_control` never touched at all, and that
    /// machine must still be reachable — it is exactly the idle Mac a viewer
    /// wants to open a session *on*. The tunnel (`relay_config`) and the
    /// per-session authorization list (`remote_session_ids`) are decoupled
    /// concerns: the former no longer reads `remote_control` at all.
    #[test]
    fn sharing_enabled_opens_the_tunnel_with_no_projection_at_all() {
        let store = Store::open_in_memory().unwrap();
        store
            .set_setting(
                DEVICE_TOKEN_KEY,
                r#"{"device_id":"dev","token":"tok","name":"Mac","relay_url":"https://r"}"#,
            )
            .unwrap();
        store
            .set_setting(crate::server::REMOTE_SHARING_KEY, r#"{"enabled":true}"#)
            .unwrap();
        assert_eq!(relay_config(&store), Some(cred("https://r")));
        // …and it stays an authorization boundary of its own: no projection
        // shares no sessions, even with the tunnel up.
        assert!(crate::server::remote_session_ids(&store).is_empty());
    }
}
