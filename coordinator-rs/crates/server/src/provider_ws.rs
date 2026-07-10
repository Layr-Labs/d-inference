//! Provider WebSocket ingress — registration, heartbeats, prepare/start replies.

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
use serde_json::{json, Value};
use std::collections::HashSet;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use tokio::sync::mpsc;

use crate::http::AppState;
use crate::provider_hub::{InboundReply, OutboundCmd};

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
    // Placeholder channel until register attaches the real hub lane.
    let (_dummy_tx, mut outbound_rx) = mpsc::channel::<OutboundCmd>(1);
    let mut attached = false;

    loop {
        tokio::select! {
            biased;
            cmd = outbound_rx.recv(), if attached => {
                match cmd {
                    Some(OutboundCmd::Text(t)) => {
                        if sink.send(Message::Text(t.into())).await.is_err() {
                            break;
                        }
                    }
                    None => {
                        attached = false;
                    }
                }
            }
            msg = stream.next() => {
                let Some(Ok(msg)) = msg else { break; };
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
                        let snap = ProviderSnapshot {
                            provider_id: id.clone(),
                            session_epoch,
                            trusted: true,
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
                        outbound_rx = state.hub.attach(id.clone(), session_epoch).await;
                        attached = true;
                        let ack = json!({
                            "type": "register_ack",
                            "provider_id": id,
                            "session_epoch": session_epoch,
                            "coordinator": "rust",
                        });
                        if sink.send(Message::Text(ack.to_string().into())).await.is_err() {
                            break;
                        }
                    }
                    darkbloom_protocol::MessageType::Heartbeat => {
                        let Some(id) = provider_id.clone() else { continue; };
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
                    darkbloom_protocol::MessageType::Prepared
                    | darkbloom_protocol::MessageType::Started
                    | darkbloom_protocol::MessageType::Aborted
                    | darkbloom_protocol::MessageType::Cancelled
                    | darkbloom_protocol::MessageType::ProviderTerminal
                    | darkbloom_protocol::MessageType::StructuredError => {
                        let Some(id) = provider_id.as_deref() else { continue; };
                        let attempt = wire
                            .rest
                            .get("attempt_id")
                            .and_then(|v| v.as_str())
                            .unwrap_or("");
                        if attempt.is_empty() {
                            continue;
                        }
                        let mut full = serde_json::Map::new();
                        full.insert("type".into(), json!(wire.msg_type));
                        for (k, v) in &wire.rest {
                            full.insert(k.clone(), v.clone());
                        }
                        let value = Value::Object(full);
                        let reply = match wire.message_type() {
                            darkbloom_protocol::MessageType::Prepared => InboundReply::Prepared(value),
                            darkbloom_protocol::MessageType::Started => InboundReply::Started(value),
                            darkbloom_protocol::MessageType::Aborted => InboundReply::Aborted(value),
                            darkbloom_protocol::MessageType::Cancelled => InboundReply::Cancelled(value),
                            darkbloom_protocol::MessageType::ProviderTerminal => InboundReply::Terminal(value),
                            darkbloom_protocol::MessageType::StructuredError => {
                                InboundReply::StructuredError(value)
                            }
                            _ => continue,
                        };
                        state.hub.deliver_reply(id, attempt, reply).await;
                    }
                    other => {
                        tracing::debug!(?other, "ignoring provider frame in warm plane");
                    }
                }
            }
        }
    }

    if let Some(id) = provider_id {
        state.hub.detach(&id, session_epoch).await;
        let _ = state.fleet.remove(id, session_epoch).await;
    }
}
