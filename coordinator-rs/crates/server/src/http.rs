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

use crate::crypto_keys::CoordinatorKeys;
use crate::deposits::apply_stripe_deposit;
use crate::external_events::ExternalEventInbox;
use crate::fleet_actor::FleetHandle;
use crate::ledger::MemoryLedger;
use crate::mock_provider::{complete_authorized_job, openai_chat_response};
use crate::outbox::Outbox;
use crate::ownership::Gate as OwnershipGate;
use crate::provider_hub::{OutboundCmd, ProviderHub, SharedHub};
use crate::provider_ws::provider_ws;
use crate::request_task::{spawn_request_task, ControlEvent};
use crate::sealed::decrypt_request_body;
use crate::telemetry::TelemetrySink;
use crate::terminal_ingest::{ingest_terminal, MemoryTerminalStore, TerminalIngest};
use darkbloom_core::{ChunkCheckpoint, AttemptId, JobId, LeaseId, PlacementController};
use tokio::sync::Mutex;
use uuid::Uuid;

#[derive(Clone)]
pub struct AppState {
    pub fleet: FleetHandle,
    pub hub: SharedHub,
    pub keys: Arc<CoordinatorKeys>,
    pub models: Vec<ModelCard>,
    /// Pilot ledger (process-local). Postgres/SQLx replaces this in M4.
    pub ledger: Arc<Mutex<MemoryLedger>>,
    pub placement: Arc<Mutex<PlacementController>>,
    pub telemetry: Arc<TelemetrySink>,
    pub pilot_account: String,
    /// Comma-separated pilot API keys (env DARKBLOOM_PILOT_API_KEYS). Empty = open.
    pub pilot_api_keys: Arc<Vec<String>>,
    pub coordinator_epoch: u64,
    /// Single-active fencing gate (plan §20).
    pub ownership: Arc<OwnershipGate>,
    /// Stripe / external-event idempotency inbox (plan §12).
    pub external_events: Arc<Mutex<ExternalEventInbox>>,
    /// Durable side-effect outbox (plan §12); process-local until SQLx.
    pub outbox: Arc<Mutex<Outbox>>,
    /// Terminal disposition store for replay ACK without double settle.
    pub terminals: Arc<Mutex<MemoryTerminalStore>>,
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
        // Responses API — same handler; body uses `input` or `messages` (pilot accepts messages).
        .route("/v1/responses", post(chat_completions))
        .route("/v1/completions", post(completions_unsupported))
        .route("/v1/messages", post(messages_unsupported))
        .route("/ws/provider", get(provider_ws))
        .route("/v1/admin/quiescence", get(quiescence))
        .route("/v1/admin/deposits", post(admin_deposit))
        .route("/v1/admin/force-settle", post(admin_force_settle))
        .route(
            "/v1/admin/recover-undispatched",
            post(admin_recover_undispatched),
        )
        .route("/v1/admin/held-review", post(admin_held_review))
        .route("/v1/admin/terminal-ingest", post(admin_terminal_ingest))
        .fallback(unsupported)
        .with_state(Arc::new(state))
}

async fn completions_unsupported() -> impl IntoResponse {
    (
        StatusCode::NOT_IMPLEMENTED,
        Json(json!({
            "error": {
                "message": "legacy /v1/completions not in Rust pilot; use /v1/chat/completions",
                "type": "not_implemented",
                "code": "unsupported_route"
            }
        })),
    )
}

async fn messages_unsupported() -> impl IntoResponse {
    (
        StatusCode::NOT_IMPLEMENTED,
        Json(json!({
            "error": {
                "message": "Anthropic /v1/messages not in Rust pilot; use /v1/chat/completions",
                "type": "not_implemented",
                "code": "unsupported_route"
            }
        })),
    )
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
    let (bal, wdr, active_jobs, held_start_authorized, held_job_ids) = {
        let led = state.ledger.lock().await;
        let (b, w) = led.balance(&state.pilot_account);
        (
            b,
            w,
            led.active_job_count(),
            led.held_start_authorized_count(),
            led.held_start_authorized_job_ids(),
        )
    };
    let (placement_version, demand) = {
        let p = state.placement.lock().await;
        let demand: serde_json::Map<String, Value> = p
            .desired()
            .into_iter()
            .map(|d| {
                (
                    d.model_id.clone(),
                    json!({
                        "target_replicas": d.target_replicas,
                        "demand": p.demand_for(&d.model_id),
                    }),
                )
            })
            .collect();
        (p.version().0, demand)
    };
    let external_events_seen = state.external_events.lock().await.len();
    let (outbox_pending, outbox_retryable) = {
        let box_ = state.outbox.lock().await;
        (box_.len(), box_.pending_under_retry_cap())
    };
    let late_terminals = state.terminals.lock().await.late_count();
    // Quiescent only when no active jobs and no retryable outbox work.
    let ready = active_jobs == 0 && outbox_retryable == 0;
    let status = if ready {
        StatusCode::OK
    } else {
        StatusCode::SERVICE_UNAVAILABLE
    };
    (
        status,
        Json(json!({
            "ready": ready,
            "pilot_account_balance_micro_usd": bal,
            "pilot_account_withdrawable_micro_usd": wdr,
            "active_jobs": active_jobs,
            "held_start_authorized": held_start_authorized,
            "held_start_authorized_job_ids": held_job_ids,
            "placement_version": placement_version,
            "placement_demand": demand,
            "telemetry_emitted": state.telemetry.emitted(),
            "telemetry_dropped": state.telemetry.dropped(),
            "fleet_actor": "up",
            "ownership_holding": state.ownership.holding(),
            "ownership_epoch": state.ownership.epoch().0,
            "external_events_seen": external_events_seen,
            "outbox_pending": outbox_pending,
            "outbox_retryable": outbox_retryable,
            "late_terminals": late_terminals,
        })),
    )
}

async fn health() -> Json<Value> {
    Json(json!({ "status": "ok", "coordinator": "rust" }))
}

#[derive(Debug, Deserialize)]
struct AdminTerminalIngestRequest {
    job_id: String,
    attempt_id: String,
    terminal_digest: String,
    #[serde(default)]
    se_signature: String,
    #[serde(default)]
    outcome: String,
}

/// Replay ACK for a provider terminal without moving money (plan §4.6).
async fn admin_terminal_ingest(
    State(state): State<Arc<AppState>>,
    headers: axum::http::HeaderMap,
    Json(req): Json<AdminTerminalIngestRequest>,
) -> impl IntoResponse {
    if let Err(err) = state.ownership.assert_holding() {
        return (
            StatusCode::SERVICE_UNAVAILABLE,
            Json(json!({
                "error": {
                    "message": format!("{err}"),
                    "type": "server_error",
                    "code": "ownership_lost"
                }
            })),
        )
            .into_response();
    }
    if let Err(status) = authorize_pilot(&state, &headers) {
        return (
            status,
            Json(json!({
                "error": {
                    "message": "invalid pilot api key",
                    "type": "invalid_request_error",
                    "code": "invalid_api_key"
                }
            })),
        )
            .into_response();
    }
    let mut store = state.terminals.lock().await;
    match ingest_terminal(
        &mut store,
        TerminalIngest {
            job_id: req.job_id,
            attempt_id: req.attempt_id,
            terminal_digest: req.terminal_digest,
            se_signature: req.se_signature,
            outcome: req.outcome,
        },
    ) {
        Ok(ack) => (StatusCode::OK, Json(ack)).into_response(),
        Err(err) => (
            StatusCode::BAD_REQUEST,
            Json(json!({
                "error": {
                    "message": format!("{err}"),
                    "type": "invalid_request_error",
                    "code": "terminal_ingest_failed"
                }
            })),
        )
            .into_response(),
    }
}

#[derive(Debug, Deserialize)]
struct AdminDepositRequest {
    /// Stripe (or other) event id — idempotency key with `source`.
    event_id: String,
    #[serde(default = "default_deposit_source")]
    source: String,
    /// Micro-USD total credit. Defaults to pilot account when omitted.
    amount_micro_usd: i64,
    #[serde(default)]
    withdrawable_micro_usd: i64,
    #[serde(default)]
    account: Option<String>,
}

fn default_deposit_source() -> String {
    "stripe".into()
}

/// Pilot-only deposit apply (mirrors Go ApplyStripeDeposit via ExternalEventInbox).
/// Auth: same pilot API keys as chat. Not a production Stripe webhook.
async fn admin_deposit(
    State(state): State<Arc<AppState>>,
    headers: axum::http::HeaderMap,
    Json(req): Json<AdminDepositRequest>,
) -> impl IntoResponse {
    if let Err(err) = state.ownership.assert_holding() {
        return (
            StatusCode::SERVICE_UNAVAILABLE,
            Json(json!({
                "error": {
                    "message": format!("{err}"),
                    "type": "server_error",
                    "code": "ownership_lost"
                }
            })),
        )
            .into_response();
    }
    if let Err(status) = authorize_pilot(&state, &headers) {
        return (
            status,
            Json(json!({
                "error": {
                    "message": "invalid pilot api key",
                    "type": "invalid_request_error",
                    "code": "invalid_api_key"
                }
            })),
        )
            .into_response();
    }
    if req.event_id.is_empty() || req.amount_micro_usd <= 0 {
        return (
            StatusCode::BAD_REQUEST,
            Json(json!({
                "error": {
                    "message": "event_id required and amount_micro_usd must be > 0",
                    "type": "invalid_request_error",
                    "code": "invalid_deposit"
                }
            })),
        )
            .into_response();
    }
    let account = req
        .account
        .unwrap_or_else(|| state.pilot_account.clone());
    let applied = {
        let mut inbox = state.external_events.lock().await;
        let mut ledger = state.ledger.lock().await;
        match apply_stripe_deposit(
            &mut inbox,
            &mut ledger,
            &req.source,
            &req.event_id,
            &account,
            req.amount_micro_usd,
            req.withdrawable_micro_usd,
        ) {
            Ok(applied) => applied,
            Err(err) => {
                return (
                    StatusCode::BAD_REQUEST,
                    Json(json!({
                        "error": {
                            "message": format!("{err}"),
                            "type": "invalid_request_error",
                            "code": "deposit_failed"
                        }
                    })),
                )
                    .into_response();
            }
        }
    };
    if applied {
        let mut box_ = state.outbox.lock().await;
        box_
            .enqueue_critical(
                "billing.deposit_applied",
                &json!({
                    "source": req.source,
                    "event_id": req.event_id,
                    "account": account,
                    "amount_micro_usd": req.amount_micro_usd,
                    "withdrawable_micro_usd": req.withdrawable_micro_usd,
                })
                .to_string(),
            )
            .expect("critical outbox enqueue must not fail for valid kind");
    }
    let (bal, wdr) = {
        let ledger = state.ledger.lock().await;
        ledger.balance(&account)
    };
    (
        StatusCode::OK,
        Json(json!({
            "applied": applied,
            "account": account,
            "source": req.source,
            "event_id": req.event_id,
            "balance_micro_usd": bal,
            "withdrawable_micro_usd": wdr,
        })),
    )
        .into_response()
}

#[derive(Debug, Deserialize)]
struct AdminForceSettleRequest {
    job_id: String,
    /// Micro-USD charge; clamped to reservation (DECISIONS #17/#23).
    actual_micro_usd: i64,
    #[serde(default)]
    terminal_digest: Option<String>,
    #[serde(default)]
    account: Option<String>,
}

/// Ops force-settle for a start_authorized held job (DECISIONS #17).
/// Clears the hold so quiescence can become ready after review.
async fn admin_force_settle(
    State(state): State<Arc<AppState>>,
    headers: axum::http::HeaderMap,
    Json(req): Json<AdminForceSettleRequest>,
) -> impl IntoResponse {
    if let Err(err) = state.ownership.assert_holding() {
        return (
            StatusCode::SERVICE_UNAVAILABLE,
            Json(json!({
                "error": {
                    "message": format!("{err}"),
                    "type": "server_error",
                    "code": "ownership_lost"
                }
            })),
        )
            .into_response();
    }
    if let Err(status) = authorize_pilot(&state, &headers) {
        return (
            status,
            Json(json!({
                "error": {
                    "message": "invalid pilot api key",
                    "type": "invalid_request_error",
                    "code": "invalid_api_key"
                }
            })),
        )
            .into_response();
    }
    if req.job_id.is_empty() {
        return (
            StatusCode::BAD_REQUEST,
            Json(json!({
                "error": {
                    "message": "job_id required",
                    "type": "invalid_request_error",
                    "code": "invalid_job_id"
                }
            })),
        )
            .into_response();
    }
    if req.actual_micro_usd < 0 {
        return (
            StatusCode::BAD_REQUEST,
            Json(json!({
                "error": {
                    "message": "actual_micro_usd must be >= 0",
                    "type": "invalid_request_error",
                    "code": "invalid_amount"
                }
            })),
        )
            .into_response();
    }
    let account = req
        .account
        .unwrap_or_else(|| state.pilot_account.clone());
    let digest = req
        .terminal_digest
        .filter(|d| !d.is_empty())
        .unwrap_or_else(|| format!("force-settle:{}", req.job_id));

    let (action, charged) = {
        let mut led = state.ledger.lock().await;
        if led.job_disposition(&req.job_id).is_some() {
            ("already_terminal".to_string(), 0_i64)
        } else if !led.job_funded_start(&req.job_id) {
            ("skipped".to_string(), 0_i64)
        } else if led.job_reserved_total(&req.job_id).is_none() {
            ("already_terminal".to_string(), 0_i64)
        } else {
            let reserved = led.job_reserved_total(&req.job_id).map(|m| m.0).unwrap_or(0);
            let charge = req.actual_micro_usd.min(reserved).max(0);
            match led.settle_capped_as(
                crate::ledger::OperationKey(format!("force_settle:{}", req.job_id)),
                &req.job_id,
                &account,
                req.actual_micro_usd,
                reserved,
                &digest,
                "force_settled",
            ) {
                Ok(true) => ("released".to_string(), charge),
                Ok(false) => ("already_terminal".to_string(), 0),
                Err(err) => {
                    return (
                        StatusCode::CONFLICT,
                        Json(json!({
                            "error": {
                                "message": format!("{err}"),
                                "type": "invalid_request_error",
                                "code": "force_settle_failed"
                            }
                        })),
                    )
                        .into_response();
                }
            }
        }
    };

    if action == "released" {
        let mut box_ = state.outbox.lock().await;
        let _ = box_.enqueue_critical(
            "inference.settled",
            &json!({
                "job_id": req.job_id,
                "terminal_digest": digest,
                "charged_micro_usd": charged,
                "disposition": "force_settled",
            })
            .to_string(),
        );
    }

    let (bal, held) = {
        let led = state.ledger.lock().await;
        (led.balance(&account).0, led.held_start_authorized_count())
    };
    (
        StatusCode::OK,
        Json(json!({
            "action": action,
            "job_id": req.job_id,
            "account": account,
            "terminal_digest": digest,
            "balance_micro_usd": bal,
            "held_start_authorized": held,
        })),
    )
        .into_response()
}

#[derive(Debug, Deserialize)]
struct AdminRecoverUndispatchedRequest {
    job_id: String,
    #[serde(default)]
    account: Option<String>,
}

/// Release a reserved-but-not-start_authorized job (DECISIONS #16 recovery path).
/// Refuses start_authorized jobs — those require force-settle.
async fn admin_recover_undispatched(
    State(state): State<Arc<AppState>>,
    headers: axum::http::HeaderMap,
    Json(req): Json<AdminRecoverUndispatchedRequest>,
) -> impl IntoResponse {
    if let Err(err) = state.ownership.assert_holding() {
        return (
            StatusCode::SERVICE_UNAVAILABLE,
            Json(json!({
                "error": {
                    "message": format!("{err}"),
                    "type": "server_error",
                    "code": "ownership_lost"
                }
            })),
        )
            .into_response();
    }
    if let Err(status) = authorize_pilot(&state, &headers) {
        return (
            status,
            Json(json!({
                "error": {
                    "message": "invalid pilot api key",
                    "type": "invalid_request_error",
                    "code": "invalid_api_key"
                }
            })),
        )
            .into_response();
    }
    if req.job_id.is_empty() {
        return (
            StatusCode::BAD_REQUEST,
            Json(json!({
                "error": {
                    "message": "job_id required",
                    "type": "invalid_request_error",
                    "code": "invalid_job_id"
                }
            })),
        )
            .into_response();
    }
    let account = req
        .account
        .unwrap_or_else(|| state.pilot_account.clone());

    let action = {
        let mut led = state.ledger.lock().await;
        if led.job_disposition(&req.job_id).is_some()
            || led.job_reserved_total(&req.job_id).is_none()
        {
            "already_terminal"
        } else if led.job_funded_start(&req.job_id) {
            "skipped"
        } else {
            match led.release(
                crate::ledger::OperationKey(format!("recovery_release:{}", req.job_id)),
                &req.job_id,
                &account,
            ) {
                Ok(true) => "released",
                Ok(false) => "already_terminal",
                Err(err) => {
                    return (
                        StatusCode::CONFLICT,
                        Json(json!({
                            "error": {
                                "message": format!("{err}"),
                                "type": "invalid_request_error",
                                "code": "recover_undispatched_failed"
                            }
                        })),
                    )
                        .into_response();
                }
            }
        }
    };

    let (bal, active) = {
        let led = state.ledger.lock().await;
        (led.balance(&account).0, led.active_job_count())
    };
    (
        StatusCode::OK,
        Json(json!({
            "action": action,
            "job_id": req.job_id,
            "account": account,
            "balance_micro_usd": bal,
            "active_jobs": active,
        })),
    )
        .into_response()
}

#[derive(Debug, Deserialize)]
struct AdminHeldReviewRequest {
    job_id: String,
}

/// Classify a start_authorized held job without moving money (DECISIONS #16/#41).
async fn admin_held_review(
    State(state): State<Arc<AppState>>,
    headers: axum::http::HeaderMap,
    Json(req): Json<AdminHeldReviewRequest>,
) -> impl IntoResponse {
    if let Err(err) = state.ownership.assert_holding() {
        return (
            StatusCode::SERVICE_UNAVAILABLE,
            Json(json!({
                "error": {
                    "message": format!("{err}"),
                    "type": "server_error",
                    "code": "ownership_lost"
                }
            })),
        )
            .into_response();
    }
    if let Err(status) = authorize_pilot(&state, &headers) {
        return (
            status,
            Json(json!({
                "error": {
                    "message": "invalid pilot api key",
                    "type": "invalid_request_error",
                    "code": "invalid_api_key"
                }
            })),
        )
            .into_response();
    }
    if req.job_id.is_empty() {
        return (
            StatusCode::BAD_REQUEST,
            Json(json!({
                "error": {
                    "message": "job_id required",
                    "type": "invalid_request_error",
                    "code": "invalid_job_id"
                }
            })),
        )
            .into_response();
    }

    let (action, bal, held, reserved) = {
        let led = state.ledger.lock().await;
        let classified = crate::recovery::classify_held_job(&led, &req.job_id);
        let action = match classified {
            crate::recovery::RecoveryAction::HeldForReview => "held_for_review",
            crate::recovery::RecoveryAction::Skipped => "skipped",
            crate::recovery::RecoveryAction::AlreadyTerminal => "already_terminal",
            crate::recovery::RecoveryAction::Released => "already_terminal",
        };
        (
            action,
            led.balance(&state.pilot_account).0,
            led.held_start_authorized_count(),
            led.job_reserved_total(&req.job_id).map(|m| m.0).unwrap_or(0),
        )
    };
    (
        StatusCode::OK,
        Json(json!({
            "action": action,
            "job_id": req.job_id,
            "reserved_micro_usd": reserved,
            "balance_micro_usd": bal,
            "held_start_authorized": held,
        })),
    )
        .into_response()
}

async fn readyz(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    if let Err(err) = state.ownership.assert_holding() {
        return (
            StatusCode::SERVICE_UNAVAILABLE,
            Json(json!({ "ready": false, "reason": "ownership_lost", "detail": format!("{err}") })),
        )
            .into_response();
    }
    // FleetActor must be reachable for admission.
    match state.fleet.admit(darkbloom_core::AdmitRequest {
        model: "__readyz_probe__".into(),
        attempt: darkbloom_core::AttemptId::new("readyz"),
        exclude_providers: Default::default(),
        require_tools: false,
        permit_ttl: std::time::Duration::from_millis(1),
            allow_half_open_probe: false,
    }).await {
        // Any decision (including RetryAfter) proves the actor is alive.
        Ok(_) => (StatusCode::OK, Json(json!({
            "ready": true,
            "ownership_epoch": state.ownership.epoch().0,
        }))).into_response(),
        Err(_) => (
            StatusCode::SERVICE_UNAVAILABLE,
            Json(json!({ "ready": false, "reason": "fleet_actor_unavailable" })),
        )
            .into_response(),
    }
}

async fn encryption_key(State(state): State<Arc<AppState>>) -> Json<Value> {
    Json(state.keys.encryption_key_json())
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
    Json(raw): Json<Value>,
) -> impl IntoResponse {
    if let Err(err) = state.ownership.assert_holding() {
        return (
            StatusCode::SERVICE_UNAVAILABLE,
            Json(json!({
                "error": {
                    "message": format!("{err}"),
                    "type": "server_error",
                    "code": "ownership_lost"
                }
            })),
        )
            .into_response();
    }
    if let Err(status) = authorize_pilot(&state, &headers) {
        return (
            status,
            Json(json!({
                "error": { "message": "invalid pilot api key", "type": "invalid_request_error", "code": "invalid_api_key" }
            })),
        )
            .into_response();
    }
    let parsed = match decrypt_request_body(&state.keys, &raw) {
        Ok(v) => v,
        Err(err) => {
            return (
                StatusCode::BAD_REQUEST,
                Json(json!({
                    "error": {
                        "message": err,
                        "type": "invalid_request_error",
                        "code": "invalid_sealed_body"
                    }
                })),
            )
                .into_response();
        }
    };
    let req: ChatRequest = match serde_json::from_value(parsed) {
        Ok(r) => r,
        Err(err) => {
            return (
                StatusCode::BAD_REQUEST,
                Json(json!({
                    "error": {
                        "message": format!("invalid chat body: {err}"),
                        "type": "invalid_request_error"
                    }
                })),
            )
                .into_response();
        }
    };
    // Warm-plane stub: admit against fleet; without providers return 429.
    let decision = match state
        .fleet
        .admit(darkbloom_core::AdmitRequest {
            model: req.model.clone(),
            attempt: darkbloom_core::AttemptId::new(uuid::Uuid::new_v4().to_string()),
            exclude_providers: Default::default(),
            require_tools: false,
            permit_ttl: std::time::Duration::from_secs(2),
            allow_half_open_probe: false,
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
            let dispatch_nonce = Uuid::new_v4().to_string();
            let request_digest = format!("sha256:{}", Uuid::new_v4());
            let predicted_ttft_ms = 100.0_f64;
            let admit_started = std::time::Instant::now();

            // Short-lived prepare permit must still be valid before we send prepare.
            if permit.is_expired(admit_started.elapsed()) {
                return (
                    StatusCode::TOO_MANY_REQUESTS,
                    [(
                        axum::http::header::RETRY_AFTER,
                        "1".to_string(),
                    )],
                    Json(json!({
                        "error": {
                            "message": "prepare permit expired before dispatch",
                            "type": "rate_limit_exceeded",
                            "code": "permit_expired"
                        }
                    })),
                )
                    .into_response();
            }

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
            let _ = task_handle;

            // Durable provisional reservation before any provider prepare.
            {
                let mut ledger = state.ledger.lock().await;
                if let Err(err) = ledger.reserve(
                    crate::ledger::OperationKey(format!("reserve:{}", job_id.as_str())),
                    job_id.as_str(),
                    &state.pilot_account,
                    100_000,
                ) {
                    return (
                        StatusCode::PAYMENT_REQUIRED,
                        Json(json!({
                            "error": {
                                "message": format!("{err}"),
                                "type": "insufficient_funds",
                                "code": "insufficient_funds"
                            }
                        })),
                    )
                        .into_response();
                }
            }

            // Prefer live provider prepare/start when the hub has a session.
            // Only fall back to in-process mock when no provider is attached.
            let prepare_result = state
                .hub
                .prepare(
                    &permit.provider_id,
                    attempt.as_str(),
                    ProviderHub::prepare_frame(
                        job_id.as_str(),
                        attempt.as_str(),
                        lease.as_str(),
                        0,
                        state.coordinator_epoch,
                        &dispatch_nonce,
                        &request_digest,
                        &permit.model,
                        None,
                    ),
                    std::time::Duration::from_secs(5),
                )
                .await;

            let use_live = match &prepare_result {
                Ok(_) => true,
                Err(crate::provider_hub::HubError::NotConnected) => false,
                Err(crate::provider_hub::HubError::Timeout) => {
                    let mut ledger = state.ledger.lock().await;
                    let _ = ledger.release(
                        crate::ledger::OperationKey(format!("release:{}", job_id.as_str())),
                        job_id.as_str(),
                        &state.pilot_account,
                    );
                    let _ = task.apply(ControlEvent::PrepareExpired);
                    let mut p = state.placement.lock().await;
                    p.signal_demand(&req.model);
                    return (
                        StatusCode::GATEWAY_TIMEOUT,
                        Json(json!({
                            "error": {
                                "message": "prepare timed out; lease expired",
                                "type": "timeout",
                                "code": "prepare_expired"
                            }
                        })),
                    )
                        .into_response();
                }
                Err(err) => {
                    let mut ledger = state.ledger.lock().await;
                    let _ = ledger.release(
                        crate::ledger::OperationKey(format!("release:{}", job_id.as_str())),
                        job_id.as_str(),
                        &state.pilot_account,
                    );
                    // model_not_ready / capacity → placement demand signal (no queue).
                    let err_s = format!("{err}");
                    if err_s.contains("model_not_ready") || err_s.contains("capacity") {
                        let mut p = state.placement.lock().await;
                        p.signal_demand(&req.model);
                    }
                    return (
                        StatusCode::BAD_GATEWAY,
                        Json(json!({
                            "error": {
                                "message": format!("prepare failed: {err}"),
                                "type": "server_error",
                                "code": "provider_prepare_failed"
                            }
                        })),
                    )
                        .into_response();
                }
            };

            // One-round-trip resize+authorize (DECISIONS #18). Same amount for
            // pilot; production will pass the refined estimate from prepare ETA.
            {
                let mut ledger = state.ledger.lock().await;
                let reserved = ledger
                    .job_reserved_total(job_id.as_str())
                    .map(|m| m.0)
                    .unwrap_or(100_000);
                if let Err(err) = ledger.resize_and_authorize(
                    crate::ledger::OperationKey(format!("resize_auth:{}", job_id.as_str())),
                    job_id.as_str(),
                    &state.pilot_account,
                    reserved,
                ) {
                    // Not start_authorized yet on failure — safe to release.
                    let _ = ledger.release(
                        crate::ledger::OperationKey(format!("release:{}", job_id.as_str())),
                        job_id.as_str(),
                        &state.pilot_account,
                    );
                    return (
                        StatusCode::CONFLICT,
                        Json(json!({
                            "error": {
                                "message": format!("{err}"),
                                "type": "server_error",
                                "code": "start_authorize_conflict"
                            }
                        })),
                    )
                        .into_response();
                }
            }

            if use_live {
                let _ = task.apply(ControlEvent::Prepared {
                    attempt: attempt.clone(),
                    lease: lease.clone(),
                });
                let _ = task.apply(ControlEvent::StartAuthorized {
                    attempt: attempt.clone(),
                    lease: lease.clone(),
                });
                match state
                    .hub
                    .start(
                        &permit.provider_id,
                        attempt.as_str(),
                        ProviderHub::start_frame(
                            job_id.as_str(),
                            attempt.as_str(),
                            lease.as_str(),
                            0,
                            state.coordinator_epoch,
                            &dispatch_nonce,
                            &request_digest,
                        ),
                        std::time::Duration::from_secs(5),
                    )
                    .await
                {
                    Ok(_) => {
                        let _ = task.apply(ControlEvent::Started {
                            attempt: attempt.clone(),
                            lease: lease.clone(),
                        });
                    }
                    Err(err) => {
                        // Start-authorized: do not release or redispatch.
                        // Leave the job held for recovery/review (DECISIONS #16).
                        state.telemetry.try_emit(crate::telemetry::TelemetryEvent {
                            name: "inference.start_failed_held".into(),
                            tags: vec![
                                ("model".into(), permit.model.clone()),
                                ("provider".into(), permit.provider_id.clone()),
                            ],
                        });
                        return (
                            StatusCode::BAD_GATEWAY,
                            Json(json!({
                                "error": {
                                    "message": format!("start failed: {err}; reservation held for review"),
                                    "type": "server_error",
                                    "code": "provider_start_failed_held"
                                }
                            })),
                        )
                            .into_response();
                    }
                }
            } else {
                let _ = task.apply(ControlEvent::Prepared {
                    attempt: attempt.clone(),
                    lease: lease.clone(),
                });
                let _ = task.apply(ControlEvent::StartAuthorized {
                    attempt: attempt.clone(),
                    lease: lease.clone(),
                });
                let _ = task.apply(ControlEvent::Started {
                    attempt: attempt.clone(),
                    lease: lease.clone(),
                });
            }

            let mode = if use_live {
                "rust-live-prepare"
            } else {
                "rust-mock"
            };
            // For streaming, billable cap tracks pipe-accepted tokens (here: full mock output).
            let billable_cap = if req.stream {
                Some(1_000i64) // full mock charge when checkpoint accepts the stream
            } else {
                None
            };
            let mut ledger = state.ledger.lock().await;
            match complete_authorized_job(
                &mut ledger,
                &state.pilot_account,
                job_id.as_str(),
                &permit,
                lease.as_str(),
                user_text,
                mode,
                billable_cap,
            ) {
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
                    // Record disposition for replay ACK (plan §4.6) + outbox side effect.
                    {
                        let ack = json!({
                            "type": "terminal_ack",
                            "job_id": completion.job_id,
                            "attempt_id": completion.attempt_id,
                            "lease_id": lease.as_str(),
                            "terminal_digest": completion.terminal_digest,
                            "disposition": "settled",
                        });
                        let mut terms = state.terminals.lock().await;
                        terms.record(
                            &completion.attempt_id,
                            &completion.terminal_digest,
                            "settled",
                            Some(ack),
                        );
                    }
                    {
                        let mut box_ = state.outbox.lock().await;
                        box_
                            .enqueue_critical(
                                "inference.settled",
                                &json!({
                                    "job_id": completion.job_id,
                                    "attempt_id": completion.attempt_id,
                                    "terminal_digest": completion.terminal_digest,
                                    "charged_micro_usd": completion.charged.0,
                                })
                                .to_string(),
                            )
                            .expect("critical outbox enqueue must not fail for valid kind");
                    }
                    state.telemetry.try_emit(crate::telemetry::TelemetryEvent {
                        name: "inference.settled".into(),
                        tags: vec![
                            ("model".into(), completion.model.clone()),
                            ("mode".into(), completion.mode.clone()),
                            ("provider".into(), completion.provider_id.clone()),
                        ],
                    });
                    // Online calibration sample from this request's observed latency.
                    let actual_ttft_ms = admit_started.elapsed().as_secs_f64() * 1000.0;
                    state.fleet.record_ttft(
                        completion.model.clone(),
                        predicted_ttft_ms,
                        actual_ttft_ms.max(1.0),
                    );
                    // Terminal ACK after durable disposition (plan §12.8).
                    let ack = json!({
                        "type": "terminal_ack",
                        "job_id": completion.job_id,
                        "attempt_id": completion.attempt_id,
                        "lease_id": lease.as_str(),
                        "session_epoch": 0,
                        "coordinator_epoch": state.coordinator_epoch,
                        "dispatch_nonce": dispatch_nonce,
                        "request_digest": request_digest,
                        "terminal_digest": completion.terminal_digest,
                        "disposition": "settled",
                    });
                    // Best-effort: provider may already be gone.
                    let _ = state.hub.attach_send_best_effort(
                        &permit.provider_id,
                        OutboundCmd::Text(ack.to_string()),
                    );
                    if req.stream {
                        // Sequenced pipe → ChunkCheckpoint linearizes billable tokens.
                        let (pipe, _reader) = crate::chunk_pipe::bounded_chunk_pipe(16, 64 * 1024);
                        let mut cp = ChunkCheckpoint::default();
                        let tokens = completion.completion_tokens.max(0) as u64;
                        let _ = crate::stream_billing::pipe_and_checkpoint(
                            &pipe,
                            &mut cp,
                            completion.content.as_bytes(),
                            tokens,
                            &completion.terminal_digest,
                        );
                        let billable = cp.billable_completion_tokens() as i32;
                        let mut streamed = completion;
                        streamed.completion_tokens = billable;
                        let chunk = openai_chat_response(&streamed, true);
                        let done = json!({"id": streamed.job_id, "object":"chat.completion.chunk","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]});
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
        darkbloom_core::AdmissionDecision::RetryAfter { reason, delay } => {
            // Cold demand → placement signal (no internal queue).
            {
                let mut p = state.placement.lock().await;
                p.signal_demand(&req.model);
            }
            state.telemetry.try_emit(crate::telemetry::TelemetryEvent {
                name: "admission.retry_after".into(),
                tags: vec![("model".into(), req.model.clone())],
            });
            (
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
            .into_response()
        }
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
