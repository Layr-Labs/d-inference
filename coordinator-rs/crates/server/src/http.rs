//! Axum HTTP adapter (Milestone 3 warm plane).

use axum::{
    extract::State,
    http::StatusCode,
    response::IntoResponse,
    routing::{get, post},
    Json, Router,
};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::sync::Arc;

use crate::fleet_actor::FleetHandle;
use crate::provider_ws::provider_ws;

#[derive(Clone)]
pub struct AppState {
    pub fleet: FleetHandle,
    pub encryption_kid: String,
    pub models: Vec<ModelCard>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ModelCard {
    pub id: String,
    pub object: String,
    pub owned_by: String,
}

pub fn router(state: AppState) -> Router {
    Router::new()
        .route("/health", get(health))
        .route("/readyz", get(readyz))
        .route("/v1/encryption-key", get(encryption_key))
        .route("/v1/models", get(list_models))
        .route("/v1/chat/completions", post(chat_completions))
        .route("/ws/provider", get(provider_ws))
        .fallback(unsupported)
        .with_state(Arc::new(state))
}

async fn health() -> Json<Value> {
    Json(json!({ "status": "ok", "coordinator": "rust" }))
}

async fn readyz(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    // Milestone 3: ready when FleetActor is reachable. DB ownership lands in M4.
    match state.fleet.admit(darkbloom_core::AdmitRequest {
        model: "__readyz_probe__".into(),
        attempt: darkbloom_core::AttemptId::new("readyz"),
        exclude_providers: Default::default(),
        require_tools: false,
        permit_ttl: std::time::Duration::from_millis(1),
    }).await {
        // Any decision (including RetryAfter) proves the actor is alive.
        Ok(_) => (StatusCode::OK, Json(json!({ "ready": true }))).into_response(),
        Err(_) => (
            StatusCode::SERVICE_UNAVAILABLE,
            Json(json!({ "ready": false, "reason": "fleet_actor_unavailable" })),
        )
            .into_response(),
    }
}

async fn encryption_key(State(state): State<Arc<AppState>>) -> Json<Value> {
    Json(json!({
        "kid": state.encryption_kid,
        "algorithm": "x25519-xsalsa20-poly1305",
        "note": "pilot stub — real key material wired in M3 trust path"
    }))
}

async fn list_models(State(state): State<Arc<AppState>>) -> Json<Value> {
    Json(json!({
        "object": "list",
        "data": state.models,
    }))
}

#[derive(Debug, Deserialize)]
struct ChatRequest {
    model: String,
    #[serde(default)]
    stream: bool,
    #[serde(default)]
    messages: Vec<Value>,
}

async fn chat_completions(
    State(state): State<Arc<AppState>>,
    Json(req): Json<ChatRequest>,
) -> impl IntoResponse {
    // Warm-plane stub: admit against fleet; without providers return 429.
    let decision = match state
        .fleet
        .admit(darkbloom_core::AdmitRequest {
            model: req.model.clone(),
            attempt: darkbloom_core::AttemptId::new(uuid::Uuid::new_v4().to_string()),
            exclude_providers: Default::default(),
            require_tools: false,
            permit_ttl: std::time::Duration::from_secs(2),
        })
        .await
    {
        Ok(d) => d,
        Err(_) => {
            return (
                StatusCode::SERVICE_UNAVAILABLE,
                Json(json!({
                    "error": { "message": "fleet unavailable", "type": "server_error" }
                })),
            )
                .into_response();
        }
    };

    match decision {
        darkbloom_core::AdmissionDecision::Prepare(permit) => {
            // Full prepare/start path lands with protocol-v2 provider sessions.
            // For the warm-plane scaffold, surface an explicit unsupported until
            // ProviderSession is wired (still proves admission works).
            (
                StatusCode::NOT_IMPLEMENTED,
                Json(json!({
                    "error": {
                        "message": format!(
                            "admitted to provider {} for model {}; prepare/start path not yet wired",
                            permit.provider_id, permit.model
                        ),
                        "type": "not_implemented",
                        "code": "warm_plane_stub",
                        "stream": req.stream,
                        "messages": req.messages.len()
                    }
                })),
            )
                .into_response()
        }
        darkbloom_core::AdmissionDecision::RetryAfter { reason, delay } => (
            StatusCode::TOO_MANY_REQUESTS,
            [(
                axum::http::header::RETRY_AFTER,
                format!("{}", delay.as_secs().max(1)),
            )],
            Json(json!({
                "error": {
                    "message": format!("retry after: {reason:?}"),
                    "type": "rate_limit_exceeded",
                    "code": "rate_limit_exceeded"
                }
            })),
        )
            .into_response(),
        darkbloom_core::AdmissionDecision::Reject { reason } => (
            StatusCode::SERVICE_UNAVAILABLE,
            Json(json!({
                "error": {
                    "message": format!("rejected: {reason:?}"),
                    "type": "server_error"
                }
            })),
        )
            .into_response(),
    }
}

async fn unsupported() -> impl IntoResponse {
    (
        StatusCode::NOT_IMPLEMENTED,
        Json(json!({
            "error": {
                "message": "endpoint not supported by Rust pilot; not proxied to Go",
                "type": "not_implemented",
                "code": "unsupported_route"
            }
        })),
    )
}
