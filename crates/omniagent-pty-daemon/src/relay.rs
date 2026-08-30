//! The relay client — the daemon's outbound side of remote session control
//! (`docs/superpowers/specs/2026-08-30-remote-session-control-design.md`
//! §1 Topology, §3 Daemon changes, §6 Failure modes).
//!
//! While the `relay_device_token` row parses **and** the `remote_control`
//! projection shares at least one session, [`run_relay`] holds one outbound
//! **control** WebSocket to the relay (`/v1/device`, `Authorization: Bearer
//! <token>`). Every `{"open": "<conn_id>"}` the relay sends down it dials a
//! **data** WebSocket (`/v1/device/conn/{conn_id}`) and runs the ordinary
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
//! never drops the control socket. An emptied projection or removed token
//! closes the control socket and, with it, every data connection. A `401`
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

use crate::server::{remote_session_ids, serve_client, ClientContext, ClientTrust};

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

/// The `relay_device_token` row as written by the app after pairing.
#[derive(Clone, Debug, PartialEq, Eq, serde::Deserialize)]
pub struct DeviceCredential {
    pub device_id: String,
    pub token: String,
    pub name: String,
    pub relay_url: String,
}

/// `Some` iff the token row parses **and** the `remote_control` projection
/// shares at least one session — the two conditions under which the daemon
/// keeps a control socket open.
pub fn relay_config(store: &Store) -> Option<DeviceCredential> {
    let raw = store.get_setting(DEVICE_TOKEN_KEY).ok().flatten()?;
    let cred: DeviceCredential = serde_json::from_str(&raw).ok()?;
    (!remote_session_ids(store).is_empty()).then_some(cred)
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

/// Whether a relay-issued connection id is safe to interpolate into a path.
fn valid_conn_id(id: &str) -> bool {
    !id.is_empty()
        && id
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
}

/// The current relay config, re-reading the store after a rebuild the way
/// `server.rs`'s `lock_store` does.
fn current(ctx: &ClientContext) -> Option<DeviceCredential> {
    ctx.settings.lock().ok().and_then(|mut store| {
        let _ = store.reopen_if_replaced();
        relay_config(&store)
    })
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
    loop {
        let Some(cred) = current(&ctx) else {
            backoff = INITIAL_BACKOFF;
            ctx.settings_changed.notified().await;
            continue;
        };
        match control_session(&ctx, &cred, ping_every).await {
            Outcome::Unauthorized => {
                tracing::warn!("relay rejected the device token; waiting for a new one");
                // Every key pokes `settings_changed`; only a different token
                // row (or an emptied projection) is worth another attempt.
                while current(&ctx).as_ref() == Some(&cred) {
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
                    let open = serde_json::from_str::<serde_json::Value>(&text)
                        .ok()
                        .and_then(|v| v["open"].as_str().map(str::to_owned));
                    if let Some(id) = open {
                        if !valid_conn_id(&id) {
                            tracing::debug!("relay sent an invalid connection id; ignoring");
                        } else if data.len() >= MAX_DATA_CONNECTIONS {
                            tracing::warn!("relay open {id} refused: {MAX_DATA_CONNECTIONS} data connections already up");
                        } else {
                            data.spawn(data_connection(ctx.clone(), cred.clone(), id));
                        }
                    }
                }
                Some(Ok(Message::Close(_))) | Some(Err(_)) | None => return dropped(),
                Some(Ok(_)) => last_seen = Instant::now(),
            },
            _ = ctx.settings_changed.notified() => {
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
/// hand it to the ordinary handler as a `Remote` client.
async fn data_connection(ctx: ClientContext, cred: DeviceCredential, conn_id: String) {
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
    if let Err(error) =
        serve_client(tokio::io::join(reader, writer), ctx, ClientTrust::Remote).await
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
    fn relay_config_needs_both_a_token_row_and_a_non_empty_projection() {
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
            .set_setting(
                crate::server::REMOTE_CONTROL_KEY,
                r#"{"workspaces":[{"id":"w","name":"w","sessions":[{"id":"s1","title":"t","engine":"shell","group":null}]}]}"#,
            )
            .unwrap();
        assert_eq!(relay_config(&store), Some(cred("https://r")));
        store
            .set_setting(crate::server::REMOTE_CONTROL_KEY, r#"{"workspaces":[]}"#)
            .unwrap();
        assert_eq!(relay_config(&store), None, "empty projection turns it off");
        store.set_setting(DEVICE_TOKEN_KEY, "not json").unwrap();
        assert_eq!(relay_config(&store), None, "unparsable token row is off");
    }
}
