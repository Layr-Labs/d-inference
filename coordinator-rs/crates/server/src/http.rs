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
use crate::ledger::MemoryLedger;
use crate::mock_provider::{openai_chat_response, run_mock_completion};
use crate::provider_ws::provider_ws;
use crate::request_task::{spawn_request_task, ControlEvent};
use darkbloom_core::{AttemptId, JobId, LeaseId};
use tokio::sync::Mutex;
use uuid::Uuid;

#[derive(Clone)]
pub struct AppState {
    pub fleet: FleetHandle,
    pub encryption_kid: String,
    pub models: Vec<ModelCard>,
    /// Pilot ledger (process-local). Postgres/SQLx replaces this in M4.
    pub ledger: Arc<Mutex<MemoryLedger>>,
    pub pilot_account: String,
    /// Comma-separated pilot API keys (env DARKBLOOM_PILOT_API_KEYS). Empty = open.
    pub pilot_api_keys: Arc<Vec<String>>,
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
        .route("/v1/admin/quiescence", get(quiescence))
        .fallback(unsupported)
        .with_state(Arc::new(state))
}

fn extract_bearer(headers: &axum::http::HeaderMap) -> Option<String> {
    let auth = headers.get(axum::http::header::AUTHORIZATION)?.to_str().ok()?;
    auth.strip_prefix("Bearer ")
        .or_else(|| auth.strip_prefix("bearer "))
        .map(|s| s.trim().to_string())
}

fn authorize_pilot(state: &AppState, headers: &axum::http::HeaderMap) -> Result<(), StatusCode> {
    if state.pilot_api_keys.is_empty() {
        return Ok(());
    }
    let Some(token) = extract_bearer(headers) else {
        return Err(StatusCode::UNAUTHORIZED);
    };
    if state.pilot_api_keys.iter().any(|k| k == &token) {
        Ok(())
    } else {
        Err(StatusCode::UNAUTHORIZED)
    }
}

async fn quiescence(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    // Warm-plane inventory — expand as workers land.
    let (bal, wdr) = {
        let led = state.ledger.lock().await;
        led.balance(&state.pilot_account)
    };
    Json(json!({
        "ready": true,
        "pilot_account_balance_micro_usd": bal,
        "pilot_account_withdrawable_micro_usd": wdr,
        "fleet_actor": "up",
        "note": "full quiescence counters land with RequestTask tracking"
    }))
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
    headers: axum::http::HeaderMap,
    Json(req): Json<ChatRequest>,
) -> impl IntoResponse {
    if let Err(status) = authorize_pilot(&state, &headers) {
        return (
            status,
            Json(json!({
                "error": { "message": "invalid pilot api key", "type": "invalid_request_error", "code": "invalid_api_key" }
            })),
        )
            .into_response();
    }
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
            let user_text = req
                .messages
                .iter()
                .rev()
                .find_map(|m| m.get("content").and_then(|c| c.as_str()))
                .unwrap_or("");

            // RequestTask owns the absolute deadline and control transitions.
            let job_id = JobId::new(format!("job-{}", Uuid::new_v4()));
            let (task_handle, mut task) =
                spawn_request_task(job_id.clone(), std::time::Duration::from_secs(30));
            let attempt = permit.attempt.clone();
            let lease = LeaseId::new(format!("lease-{}", Uuid::new_v4()));
            if task
                .apply(ControlEvent::Reserved {
                    job: job_id.clone(),
                })
                .and_then(|_| {
                    task.apply(ControlEvent::Admitted {
                        attempt: attempt.clone(),
                        permit: permit.clone(),
                    })
                })
                .and_then(|_| {
                    task.apply(ControlEvent::Prepared {
                        attempt: attempt.clone(),
                        lease: lease.clone(),
                    })
                })
                .and_then(|_| {
                    task.apply(ControlEvent::StartAuthorized {
                        attempt: attempt.clone(),
                        lease: lease.clone(),
                    })
                })
                .and_then(|_| {
                    task.apply(ControlEvent::Started {
                        attempt: attempt.clone(),
                        lease: lease.clone(),
                    })
                })
                .is_err()
            {
                return (
                    StatusCode::GATEWAY_TIMEOUT,
                    Json(json!({
                        "error": {
                            "message": "request task rejected transition or deadline",
                            "type": "timeout",
                            "code": "deadline_exceeded"
                        }
                    })),
                )
                    .into_response();
            }
            // Keep handle alive for cancel/backpressure signals from the pipe path.
            let _ = task_handle;

            let mut ledger = state.ledger.lock().await;
            match run_mock_completion(&mut ledger, &state.pilot_account, &permit, user_text) {
                Ok(completion) => {
                    let _ = task.apply(ControlEvent::FirstContent {
                        attempt: AttemptId::new(completion.attempt_id.clone()),
                        lease: lease.clone(),
                    });
                    let _ = task.apply(ControlEvent::ProviderTerminal {
                        attempt: AttemptId::new(completion.attempt_id.clone()),
                        lease: lease.clone(),
                    });
                    let _ = task.apply(ControlEvent::FinalizeDone);
                    if req.stream {
                        let chunk = openai_chat_response(&completion, true);
                        let done = json!({"id": completion.job_id, "object":"chat.completion.chunk","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]});
                        let body = format!(
                            "data: {}\n\ndata: {}\n\ndata: [DONE]\n\n",
                            chunk, done
                        );
                        (
                            StatusCode::OK,
                            [
                                (axum::http::header::CONTENT_TYPE, "text/event-stream"),
                                (axum::http::header::CACHE_CONTROL, "no-cache"),
                            ],
                            body,
                        )
                            .into_response()
                    } else {
                        let body = openai_chat_response(&completion, false);
                        (StatusCode::OK, Json(body)).into_response()
                    }
                }
                Err(err) => (
                    StatusCode::PAYMENT_REQUIRED,
                    Json(json!({
                        "error": {
                            "message": err,
                            "type": "insufficient_funds",
                            "code": "insufficient_funds"
                        }
                    })),
                )
                    .into_response(),
            }
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
