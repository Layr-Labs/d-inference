//! Provider WebSocket ingress — registration + heartbeats → FleetActor.

use axum::{
    extract::{
        ws::{Message, WebSocket, WebSocketUpgrade},
        State,
    },
    response::IntoResponse,
};
use darkbloom_core::{HealthMachine, ProviderSnapshot};
use darkbloom_protocol::WireMessage;
use futures_util::{SinkExt, StreamExt};
use serde_json::json;
use std::collections::HashSet;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};

use crate::http::AppState;

static SESSION_EPOCH: AtomicU64 = AtomicU64::new(1);

pub async fn provider_ws(
    ws: WebSocketUpgrade,
    State(state): State<Arc<AppState>>,
) -> impl IntoResponse {
    ws.on_upgrade(move |socket| handle_socket(socket, state))
}

async fn handle_socket(socket: WebSocket, state: Arc<AppState>) {
    let (mut sink, mut stream) = socket.split();
    let session_epoch = SESSION_EPOCH.fetch_add(1, Ordering::Relaxed);
    let mut provider_id: Option<String> = None;
    let mut registered_models: HashSet<String> = HashSet::new();

    while let Some(Ok(msg)) = stream.next().await {
        let text = match msg {
            Message::Text(t) => t.to_string(),
            Message::Binary(b) => String::from_utf8_lossy(&b).to_string(),
            Message::Close(_) => break,
            Message::Ping(p) => {
                let _ = sink.send(Message::Pong(p)).await;
                continue;
            }
            Message::Pong(_) => continue,
        };

        let wire = match WireMessage::parse(text.as_bytes()) {
            Ok(w) => w,
            Err(err) => {
                tracing::warn!(%err, "provider frame parse failed");
                continue;
            }
        };

        match wire.message_type() {
            darkbloom_protocol::MessageType::Register => {
                let id = wire
                    .rest
                    .get("public_key")
                    .and_then(|v| v.as_str())
                    .map(|s| s.to_string())
                    .unwrap_or_else(|| format!("anon-{session_epoch}"));
                provider_id = Some(id.clone());

                registered_models.clear();
                if let Some(models) = wire.rest.get("models").and_then(|v| v.as_array()) {
                    for m in models {
                        if let Some(mid) = m.get("id").and_then(|v| v.as_str()) {
                            registered_models.insert(mid.to_string());
                        }
                    }
                }
                // Warm-plane pilot: treat registered models as ready.
                let snap = ProviderSnapshot {
                    provider_id: id.clone(),
                    session_epoch,
                    trusted: true, // pilot: trust verification lands with full trust path
                    challenge_fresh: true,
                    encrypted_transport: wire
                        .rest
                        .get("encrypted_response_chunks")
                        .and_then(|v| v.as_bool())
                        .unwrap_or(false)
                        || wire.rest.get("public_key").is_some(),
                    ready_models: registered_models.clone(),
                    health: HealthMachine::healthy(),
                    data_lane_full: false,
                    predicted_first_content_ms: 100.0,
                    predicted_decode_ms: 200.0,
                };
                if let Err(err) = state.fleet.upsert_lifecycle(snap).await {
                    tracing::warn!(%err, "fleet upsert failed");
                }
                let ack = json!({
                    "type": "register_ack",
                    "provider_id": id,
                    "session_epoch": session_epoch,
                    "coordinator": "rust",
                });
                if sink
                    .send(Message::Text(ack.to_string().into()))
                    .await
                    .is_err()
                {
                    break;
                }
            }
            darkbloom_protocol::MessageType::Heartbeat => {
                let Some(id) = provider_id.clone() else {
                    continue;
                };
                let mut ready = registered_models.clone();
                if let Some(warm) = wire.rest.get("warm_models").and_then(|v| v.as_array()) {
                    for m in warm {
                        if let Some(mid) = m.as_str() {
                            ready.insert(mid.to_string());
                        }
                    }
                }
                if let Some(active) = wire.rest.get("active_model").and_then(|v| v.as_str()) {
                    ready.insert(active.to_string());
                }
                let snap = ProviderSnapshot {
                    provider_id: id,
                    session_epoch,
                    trusted: true,
                    challenge_fresh: true,
                    encrypted_transport: true,
                    ready_models: ready,
                    health: HealthMachine::healthy(),
                    data_lane_full: false,
                    predicted_first_content_ms: 80.0,
                    predicted_decode_ms: 150.0,
                };
                let _ = state.fleet.upsert_heartbeat(snap);
            }
            other => {
                tracing::debug!(?other, "ignoring provider frame in warm plane");
            }
        }
    }

    if let Some(id) = provider_id {
        let _ = state.fleet.remove(id, session_epoch).await;
    }
}
