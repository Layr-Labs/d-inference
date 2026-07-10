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
use crate::mock_provider::{complete_authorized_job, openai_chat_response, MockCompletion};
use crate::outbox::Outbox;
use crate::ownership::Gate as OwnershipGate;
use crate::provider_hub::{OutboundCmd, ProviderHub, SharedHub, StartResult};
use crate::provider_ws::provider_ws;
use crate::request_task::{spawn_request_task, ControlEvent};
use crate::recovery::{force_settle_held_on, recover_undispatched_on, RecoveryAction};
use crate::sealed::decrypt_request_body;
use crate::telemetry::TelemetrySink;
use crate::terminal_ingest::{ingest_terminal, MemoryTerminalStore, TerminalIngest};
use crate::terminal_validate::validate_provider_terminal;
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
        .route("/v1/admin/adopt-job", post(admin_adopt_job))
        .route("/v1/admin/cancel-attempt", post(admin_cancel_attempt))
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

/// Shared ownership + pilot-key gate for mutating admin routes.
fn require_admin(
    state: &AppState,
    headers: &axum::http::HeaderMap,
) -> Result<(), axum::response::Response> {
    require_holding(state)?;
    if let Err(status) = authorize_pilot(state, headers) {
        return Err((
            status,
            Json(json!({
                "error": {
                    "message": "invalid pilot api key",
                    "type": "invalid_request_error",
                    "code": "invalid_api_key"
                }
            })),
        )
            .into_response());
    }
    Ok(())
}

/// Poll until ownership is lost (DECISIONS #65/#66).
async fn watch_ownership_lost(gate: Arc<OwnershipGate>) {
    loop {
        tokio::time::sleep(std::time::Duration::from_millis(25)).await;
        if gate.assert_holding().is_err() {
            break;
        }
    }
}

fn ownership_lost_held_response(message: &str) -> axum::response::Response {
    (
        StatusCode::SERVICE_UNAVAILABLE,
        Json(json!({
            "error": {
                "message": message,
                "type": "server_error",
                "code": "ownership_lost"
            }
        })),
    )
        .into_response()
}

/// Money-mutation fencing: re-check ownership at every ledger boundary (DECISIONS #47).
fn require_holding(state: &AppState) -> Result<(), axum::response::Response> {
    if let Err(err) = state.ownership.assert_holding() {
        return Err((
            StatusCode::SERVICE_UNAVAILABLE,
            Json(json!({
                "error": {
                    "message": format!("{err}"),
                    "type": "server_error",
                    "code": "ownership_lost"
                }
            })),
        )
            .into_response());
    }
    Ok(())
}

fn require_nonempty_job_id(job_id: &str) -> Result<(), axum::response::Response> {
    if job_id.is_empty() {
        return Err((
            StatusCode::BAD_REQUEST,
            Json(json!({
                "error": {
                    "message": "job_id required",
                    "type": "invalid_request_error",
                    "code": "invalid_job_id"
                }
            })),
        )
            .into_response());
    }
    Ok(())
}

/// Release a reserved job and enqueue critical `inference.released` (DECISIONS #43).
/// Refuses to move money after ownership loss (DECISIONS #47/#52).
async fn release_job_with_outbox(
    state: &AppState,
    op: crate::ledger::OperationKey,
    job_id: &str,
    account: &str,
) -> Result<bool, crate::ledger::LedgerError> {
    if state.ownership.assert_holding().is_err() {
        return Err(crate::ledger::LedgerError::OwnershipLost);
    }
    let epoch = state.ownership.epoch().0;
    let refunded = {
        let mut led = state.ledger.lock().await;
        let reserved = led.job_reserved_total(job_id).map(|m| m.0).unwrap_or(0);
        match led.release_fenced(epoch, op, job_id, account)? {
            true => Some(reserved),
            false => None,
        }
    };
    if let Some(amount) = refunded {
        {
            // Durable released disposition for reconnect/audit (DECISIONS #60).
            let mut terms = state.terminals.lock().await;
            crate::terminal_ingest::record_released_disposition(&mut terms, job_id);
        }
        let mut box_ = state.outbox.lock().await;
        let _ = box_.enqueue_released(job_id, account, amount);
        Ok(true)
    } else {
        Ok(false)
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
    lease_id: String,
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
    if let Err(resp) = require_admin(&state, &headers) {
        return resp;
    }
    let mut store = state.terminals.lock().await;
    match ingest_terminal(
        &mut store,
        TerminalIngest {
            job_id: req.job_id,
            attempt_id: req.attempt_id,
            terminal_digest: req.terminal_digest,
            lease_id: req.lease_id,
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
    if let Err(resp) = require_admin(&state, &headers) {
        return resp;
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

    // Re-check holding immediately before money move (DECISIONS #47/#64).
    if let Err(resp) = require_holding(&state) {
        return resp;
    }

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
                let (status, code) = match &err {
                    crate::deposits::DepositError::External(
                        crate::external_events::ExternalEventError::Conflict(_),
                    ) => (StatusCode::CONFLICT, "deposit_payload_conflict"),
                    _ => (StatusCode::BAD_REQUEST, "deposit_failed"),
                };
                return (
                    status,
                    Json(json!({
                        "error": {
                            "message": format!("{err}"),
                            "type": "invalid_request_error",
                            "code": code
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
    if let Err(resp) = require_admin(&state, &headers) {
        return resp;
    }
    if let Err(resp) = require_nonempty_job_id(&req.job_id) {
        return resp;
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

    // Re-check holding immediately before money move (DECISIONS #47/#62).
    if let Err(resp) = require_holding(&state) {
        return resp;
    }

    let (action, charged) = {
        let mut led = state.ledger.lock().await;
        let reserved = led.job_reserved_total(&req.job_id).map(|m| m.0).unwrap_or(0);
        let charge = req.actual_micro_usd.min(reserved).max(0);
        match force_settle_held_on(
            &mut led,
            state.ownership.epoch().0,
            &req.job_id,
            &account,
            req.actual_micro_usd,
            &digest,
        ) {
            Ok(RecoveryAction::Released) => ("released".to_string(), charge),
            Ok(RecoveryAction::AlreadyTerminal) => ("already_terminal".to_string(), 0),
            Ok(RecoveryAction::Skipped) | Ok(RecoveryAction::HeldForReview) => {
                ("skipped".to_string(), 0)
            }
            Err(err) => {
                let (status, code) = match &err {
                    crate::ledger::LedgerError::OwnershipLost => (
                        StatusCode::SERVICE_UNAVAILABLE,
                        "ownership_lost",
                    ),
                    _ => (StatusCode::CONFLICT, "force_settle_failed"),
                };
                return (
                    status,
                    Json(json!({
                        "error": {
                            "message": format!("{err}"),
                            "type": "invalid_request_error",
                            "code": code
                        }
                    })),
                )
                    .into_response();
            }
        }
    };

    if action == "released" {
        {
            let mut terms = state.terminals.lock().await;
            let ack = json!({
                "type": "terminal_ack",
                "job_id": req.job_id,
                "attempt_id": "",
                "lease_id": "",
                "terminal_digest": digest,
                "disposition": "force_settled",
            });
            terms.record_bound(
                &req.job_id,
                "",
                &digest,
                "force_settled",
                Some(ack),
                "",
                "",
            );
        }
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
    if let Err(resp) = require_admin(&state, &headers) {
        return resp;
    }
    if let Err(resp) = require_nonempty_job_id(&req.job_id) {
        return resp;
    }
    let account = req
        .account
        .unwrap_or_else(|| state.pilot_account.clone());

    // Re-check holding immediately before money move (DECISIONS #47/#63).
    if let Err(resp) = require_holding(&state) {
        return resp;
    }

    let (action, refunded) = {
        let mut led = state.ledger.lock().await;
        let reserved = led.job_reserved_total(&req.job_id).map(|m| m.0).unwrap_or(0);
        match recover_undispatched_on(
            &mut led,
            state.ownership.epoch().0,
            &req.job_id,
            &account,
        ) {
            Ok(RecoveryAction::Released) => ("released".to_string(), Some(reserved)),
            Ok(RecoveryAction::AlreadyTerminal) => ("already_terminal".to_string(), None),
            Ok(RecoveryAction::Skipped) | Ok(RecoveryAction::HeldForReview) => {
                ("skipped".to_string(), None)
            }
            Err(err) => {
                let (status, code) = match &err {
                    crate::ledger::LedgerError::OwnershipLost => (
                        StatusCode::SERVICE_UNAVAILABLE,
                        "ownership_lost",
                    ),
                    _ => (StatusCode::CONFLICT, "recover_undispatched_failed"),
                };
                return (
                    status,
                    Json(json!({
                        "error": {
                            "message": format!("{err}"),
                            "type": "invalid_request_error",
                            "code": code
                        }
                    })),
                )
                    .into_response();
            }
        }
    };

    if let Some(amount) = refunded {
        {
            let mut terms = state.terminals.lock().await;
            crate::terminal_ingest::record_released_disposition(&mut terms, &req.job_id);
        }
        let mut box_ = state.outbox.lock().await;
        let _ = box_.enqueue_released(&req.job_id, &account, amount);
    }

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
    if let Err(resp) = require_admin(&state, &headers) {
        return resp;
    }
    if let Err(resp) = require_nonempty_job_id(&req.job_id) {
        return resp;
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

#[derive(Debug, Deserialize)]
struct AdminAdoptJobRequest {
    job_id: String,
}

/// Rebind an orphaned job to the current fencing epoch after ownership re-acquire
/// (DECISIONS #66). Does not move money — follow with recover/force-settle.
async fn admin_adopt_job(
    State(state): State<Arc<AppState>>,
    headers: axum::http::HeaderMap,
    Json(req): Json<AdminAdoptJobRequest>,
) -> impl IntoResponse {
    if let Err(resp) = require_admin(&state, &headers) {
        return resp;
    }
    if let Err(resp) = require_nonempty_job_id(&req.job_id) {
        return resp;
    }
    if let Err(resp) = require_holding(&state) {
        return resp;
    }
    let epoch = state.ownership.epoch().0;
    let (prev, current) = {
        let mut led = state.ledger.lock().await;
        match led.adopt_fencing_epoch(&req.job_id, epoch) {
            Ok(prev) => (prev, epoch),
            Err(err) => {
                return (
                    StatusCode::CONFLICT,
                    Json(json!({
                        "error": {
                            "message": format!("{err}"),
                            "type": "invalid_request_error",
                            "code": "adopt_job_failed"
                        }
                    })),
                )
                    .into_response();
            }
        }
    };
    (
        StatusCode::OK,
        Json(json!({
            "action": "adopted",
            "job_id": req.job_id,
            "previous_fencing_epoch": prev,
            "fencing_epoch": current,
        })),
    )
        .into_response()
}

#[derive(Debug, Deserialize)]
struct AdminCancelAttemptRequest {
    job_id: String,
    attempt_id: String,
    lease_id: String,
    provider_id: String,
    #[serde(default)]
    dispatch_nonce: String,
    #[serde(default)]
    request_digest: String,
}

/// Ops cancel for a start_authorized attempt (DECISIONS #68).
/// Sends provider cancel; does not release money — await terminal / force-settle.
/// Reserved-not-started jobs should use recover-undispatched instead.
async fn admin_cancel_attempt(
    State(state): State<Arc<AppState>>,
    headers: axum::http::HeaderMap,
    Json(req): Json<AdminCancelAttemptRequest>,
) -> impl IntoResponse {
    if let Err(resp) = require_admin(&state, &headers) {
        return resp;
    }
    if let Err(resp) = require_nonempty_job_id(&req.job_id) {
        return resp;
    }
    if req.attempt_id.is_empty() || req.provider_id.is_empty() || req.lease_id.is_empty() {
        return (
            StatusCode::BAD_REQUEST,
            Json(json!({
                "error": {
                    "message": "attempt_id, lease_id, and provider_id required",
                    "type": "invalid_request_error",
                    "code": "invalid_cancel_attempt"
                }
            })),
        )
            .into_response();
    }
    if let Err(resp) = require_holding(&state) {
        return resp;
    }

    let (action, reserved) = {
        let led = state.ledger.lock().await;
        if led.job_disposition(&req.job_id).is_some() {
            ("already_terminal".to_string(), 0_i64)
        } else if !led.job_funded_start(&req.job_id) {
            ("skipped".to_string(), 0_i64)
        } else {
            (
                "cancelled_await_terminal".to_string(),
                led.job_reserved_total(&req.job_id).map(|m| m.0).unwrap_or(0),
            )
        }
    };

    if action == "cancelled_await_terminal" {
        match crate::abort::cancel_attempt(
            &state.hub,
            &req.provider_id,
            &req.job_id,
            &req.attempt_id,
            &req.lease_id,
            state.coordinator_epoch,
            &req.dispatch_nonce,
            &req.request_digest,
        )
        .await
        {
            Ok(()) => {}
            Err(err) => {
                return (
                    StatusCode::BAD_GATEWAY,
                    Json(json!({
                        "error": {
                            "message": format!("cancel failed: {err}"),
                            "type": "server_error",
                            "code": "cancel_attempt_failed"
                        }
                    })),
                )
                    .into_response();
            }
        }
    }

    let held = state.ledger.lock().await.held_start_authorized_count();
    (
        StatusCode::OK,
        Json(json!({
            "action": action,
            "job_id": req.job_id,
            "attempt_id": req.attempt_id,
            "reserved_micro_usd": reserved,
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
    if let Err(resp) = require_admin(&state, &headers) {
        return resp;
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
                if let Err(resp) = require_holding(&state) {
                    return resp;
                }
                let mut ledger = state.ledger.lock().await;
                if let Err(err) = ledger.reserve_with_epoch(
                    crate::ledger::OperationKey(format!("reserve:{}", job_id.as_str())),
                    job_id.as_str(),
                    &state.pilot_account,
                    100_000,
                    state.ownership.epoch().0,
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
            // Abort prepare if ownership is stolen mid-wait (DECISIONS #67).
            let prepare_result = match tokio::select! {
                res = state.hub.prepare(
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
                ) => res.map(Some),
                _ = watch_ownership_lost(state.ownership.clone()) => Ok(None),
            } {
                Ok(Some(v)) => Ok(v),
                Ok(None) => {
                    state.telemetry.try_emit(crate::telemetry::TelemetryEvent {
                        name: "inference.ownership_lost_prepare_held".into(),
                        tags: vec![
                            ("model".into(), permit.model.clone()),
                            ("provider".into(), permit.provider_id.clone()),
                        ],
                    });
                    return ownership_lost_held_response(
                        "ownership lost during prepare; reservation held for adopt+recover",
                    );
                }
                Err(e) => Err(e),
            };

            let use_live = match &prepare_result {
                Ok(_) => true,
                Err(crate::provider_hub::HubError::NotConnected) => false,
                Err(crate::provider_hub::HubError::Timeout) => {
                    let _ = release_job_with_outbox(
                        &state,
                        crate::ledger::OperationKey(format!("release:{}", job_id.as_str())),
                        job_id.as_str(),
                        &state.pilot_account,
                    )
                    .await;
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
                    let _ = release_job_with_outbox(
                        &state,
                        crate::ledger::OperationKey(format!("release:{}", job_id.as_str())),
                        job_id.as_str(),
                        &state.pilot_account,
                    )
                    .await;
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
                if let Err(resp) = require_holding(&state) {
                    return resp;
                }
                let resize_err = {
                    let mut ledger = state.ledger.lock().await;
                    let reserved = ledger
                        .job_reserved_total(job_id.as_str())
                        .map(|m| m.0)
                        .unwrap_or(100_000);
                    match ledger.resize_and_authorize_fenced(
                        state.ownership.epoch().0,
                        crate::ledger::OperationKey(format!(
                            "resize_auth:{}",
                            job_id.as_str()
                        )),
                        job_id.as_str(),
                        &state.pilot_account,
                        reserved,
                    ) {
                        Ok(_) => None,
                        Err(crate::ledger::LedgerError::OwnershipLost) => {
                            return (
                                StatusCode::SERVICE_UNAVAILABLE,
                                Json(json!({
                                    "error": {
                                        "message": "ownership_lost",
                                        "type": "server_error",
                                        "code": "ownership_lost"
                                    }
                                })),
                            )
                                .into_response();
                        }
                        Err(err) => Some(err),
                    }
                };
                if let Some(err) = resize_err {
                    // Not start_authorized yet on failure — safe to release.
                    let _ = release_job_with_outbox(
                        &state,
                        crate::ledger::OperationKey(format!("release:{}", job_id.as_str())),
                        job_id.as_str(),
                        &state.pilot_account,
                    )
                    .await;
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

            let completion_result = if use_live {
                let _ = task.apply(ControlEvent::Prepared {
                    attempt: attempt.clone(),
                    lease: lease.clone(),
                });
                let _ = task.apply(ControlEvent::StartAuthorized {
                    attempt: attempt.clone(),
                    lease: lease.clone(),
                });
                // Abort start wait if ownership is stolen (DECISIONS #67).
                let start_res = match tokio::select! {
                    res = state.hub.start(
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
                    ) => res.map(Some),
                    _ = watch_ownership_lost(state.ownership.clone()) => Ok(None),
                } {
                    Ok(Some(v)) => Ok(v),
                    Ok(None) => {
                        state.telemetry.try_emit(crate::telemetry::TelemetryEvent {
                            name: "inference.ownership_lost_start_held".into(),
                            tags: vec![
                                ("model".into(), permit.model.clone()),
                                ("provider".into(), permit.provider_id.clone()),
                            ],
                        });
                        return ownership_lost_held_response(
                            "ownership lost during start; reservation held for adopt+force-settle",
                        );
                    }
                    Err(e) => Err(e),
                };
                let terminal = match start_res {
                    Ok(StartResult::Started(_)) => {
                        let _ = task.apply(ControlEvent::Started {
                            attempt: attempt.clone(),
                            lease: lease.clone(),
                        });
                        // Live settle requires a real provider_terminal (DECISIONS #44).
                        // Abort wait if ownership is stolen mid-flight (DECISIONS #65).
                        let terminal_wait = state.hub.wait_terminal(
                            &permit.provider_id,
                            attempt.as_str(),
                            std::time::Duration::from_secs(30),
                        );
                        match tokio::select! {
                            res = terminal_wait => res.map(Some),
                            _ = watch_ownership_lost(state.ownership.clone()) => Ok(None),
                        } {
                            Ok(Some(v)) => v,
                            Ok(None) => {
                                state.telemetry.try_emit(crate::telemetry::TelemetryEvent {
                                    name: "inference.ownership_lost_held".into(),
                                    tags: vec![
                                        ("model".into(), permit.model.clone()),
                                        ("provider".into(), permit.provider_id.clone()),
                                    ],
                                });
                                return ownership_lost_held_response(
                                    "ownership lost while awaiting provider terminal; reservation held for review",
                                );
                            }
                            Err(err) => {
                                state.telemetry.try_emit(crate::telemetry::TelemetryEvent {
                                    name: "inference.terminal_timeout_held".into(),
                                    tags: vec![
                                        ("model".into(), permit.model.clone()),
                                        ("provider".into(), permit.provider_id.clone()),
                                    ],
                                });
                                return (
                                    StatusCode::GATEWAY_TIMEOUT,
                                    Json(json!({
                                        "error": {
                                            "message": format!(
                                                "provider terminal timed out: {err}; reservation held for review"
                                            ),
                                            "type": "timeout",
                                            "code": "provider_terminal_timeout_held"
                                        }
                                    })),
                                )
                                    .into_response();
                            }
                        }
                    }
                    Ok(StartResult::Terminal(v)) => {
                        let _ = task.apply(ControlEvent::Started {
                            attempt: attempt.clone(),
                            lease: lease.clone(),
                        });
                        v
                    }
                    Err(err) => {
                        // Start-authorized: do not release or redispatch.
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
                };

                let (digest, prompt_tokens, completion_tokens) = match validate_provider_terminal(
                    &terminal,
                    job_id.as_str(),
                    attempt.as_str(),
                    lease.as_str(),
                    state.coordinator_epoch,
                    &dispatch_nonce,
                    &request_digest,
                ) {
                    Ok(v) => v,
                    Err(reason) => {
                        state.telemetry.try_emit(crate::telemetry::TelemetryEvent {
                            name: "inference.terminal_invalid_held".into(),
                            tags: vec![
                                ("provider".into(), permit.provider_id.clone()),
                                ("reason".into(), reason.clone()),
                            ],
                        });
                        return (
                            StatusCode::BAD_GATEWAY,
                            Json(json!({
                                "error": {
                                    "message": format!(
                                        "provider terminal invalid ({reason}); reservation held for review"
                                    ),
                                    "type": "server_error",
                                    "code": "provider_terminal_invalid_held"
                                }
                            })),
                        )
                            .into_response();
                    }
                };
                let se_signature = terminal
                    .get("se_signature")
                    .and_then(|v| v.as_str())
                    .unwrap_or("")
                    .to_string();
                // Pilot pricing: 10 µUSD per completion token until public price tables land.
                let charged = (completion_tokens as i64) * 10;
                // Stream: defer settle until after chunk checkpoint (DECISIONS #49).
                let live_completion = if req.stream {
                    let reserved = {
                        let led = state.ledger.lock().await;
                        led.job_reserved_total(job_id.as_str())
                            .unwrap_or(darkbloom_core::MicroUsd(0))
                    };
                    MockCompletion {
                        job_id: job_id.as_str().to_string(),
                        attempt_id: attempt.as_str().to_string(),
                        provider_id: permit.provider_id.clone(),
                        model: permit.model.clone(),
                        content: format!(
                            "[rust-live] provider={} digest={}",
                            permit.provider_id, digest
                        ),
                        prompt_tokens,
                        completion_tokens,
                        reserved,
                        charged: darkbloom_core::MicroUsd(0),
                        terminal_digest: digest,
                        se_signature: se_signature.clone(),
                        mode: "rust-live".into(),
                    }
                } else {
                    if let Err(resp) = require_holding(&state) {
                        return resp;
                    }
                    let mut ledger = state.ledger.lock().await;
                    ledger.record_attempt(
                        attempt.as_str(),
                        job_id.as_str(),
                        &permit.provider_id,
                        "started",
                    );
                    if let Err(err) = ledger.settle_capped_fenced(
                        state.ownership.epoch().0,
                        crate::ledger::OperationKey(format!("settle:{}", job_id.as_str())),
                        job_id.as_str(),
                        &state.pilot_account,
                        charged,
                        charged,
                        &digest,
                    ) {
                        let (status, code) = match &err {
                            crate::ledger::LedgerError::OwnershipLost => (
                                StatusCode::SERVICE_UNAVAILABLE,
                                "ownership_lost",
                            ),
                            _ => (StatusCode::CONFLICT, "live_settle_conflict"),
                        };
                        return (
                            status,
                            Json(json!({
                                "error": {
                                    "message": format!("live settle failed: {err}"),
                                    "type": "server_error",
                                    "code": code
                                }
                            })),
                        )
                            .into_response();
                    }
                    let reserved = ledger
                        .job_reserved_total(job_id.as_str())
                        .unwrap_or(darkbloom_core::MicroUsd(0));
                    MockCompletion {
                        job_id: job_id.as_str().to_string(),
                        attempt_id: attempt.as_str().to_string(),
                        provider_id: permit.provider_id.clone(),
                        model: permit.model.clone(),
                        content: format!(
                            "[rust-live] provider={} digest={}",
                            permit.provider_id, digest
                        ),
                        prompt_tokens,
                        completion_tokens,
                        reserved,
                        charged: darkbloom_core::MicroUsd(charged.max(0)),
                        terminal_digest: digest,
                        se_signature,
                        mode: "rust-live".into(),
                    }
                };
                Ok::<_, String>(live_completion)
            } else {
                if let Err(resp) = require_holding(&state) {
                    return resp;
                }
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
                let mut ledger = state.ledger.lock().await;
                // Stream defers settle until after chunk checkpoint (DECISIONS #49).
                complete_authorized_job(
                    &mut ledger,
                    &state.pilot_account,
                    job_id.as_str(),
                    &permit,
                    lease.as_str(),
                    user_text,
                    "rust-mock",
                    None,
                    !req.stream,
                )
            };

            match completion_result {
                Ok(mut completion) => {
                    let _ = task.apply(ControlEvent::FirstContent {
                        attempt: AttemptId::new(completion.attempt_id.clone()),
                        lease: lease.clone(),
                    });
                    let _ = task.apply(ControlEvent::ProviderTerminal {
                        attempt: AttemptId::new(completion.attempt_id.clone()),
                        lease: lease.clone(),
                    });
                    let _ = task.apply(ControlEvent::FinalizeDone);

                    // Stream: checkpoint accepted tokens, then settle (DECISIONS #49).
                    let stream_body = if req.stream {
                        let (pipe, _reader) = crate::chunk_pipe::bounded_chunk_pipe(16, 64 * 1024);
                        let mut cp = ChunkCheckpoint::default();
                        // Billable tokens = min(provider claim, content-derived estimate)
                        // so inflated completion_tokens cannot overcharge.
                        let tokens = crate::stream_billing::stream_billable_tokens(
                            completion.completion_tokens.max(0) as u64,
                            completion.content.len(),
                        );
                        let _ = crate::stream_billing::pipe_and_checkpoint(
                            &pipe,
                            &mut cp,
                            completion.content.as_bytes(),
                            tokens,
                            &completion.terminal_digest,
                        );
                        let billable_tokens = cp.billable_completion_tokens() as i64;
                        let billable_cap =
                            crate::stream_billing::billable_cap_micro_usd(&cp, 10);
                        // Provider-claimed actual (live: tokens*10; mock: 1000).
                        let actual = if completion.mode == "rust-mock" {
                            1_000i64
                        } else {
                            (completion.completion_tokens as i64) * 10
                        };
                        if let Err(resp) = require_holding(&state) {
                            return resp;
                        }
                        {
                            let mut ledger = state.ledger.lock().await;
                            if completion.mode == "rust-live" {
                                ledger.record_attempt(
                                    &completion.attempt_id,
                                    &completion.job_id,
                                    &completion.provider_id,
                                    "started",
                                );
                            }
                            match ledger.settle_capped_fenced(
                                state.ownership.epoch().0,
                                crate::ledger::OperationKey(format!(
                                    "settle:{}",
                                    completion.job_id
                                )),
                                &completion.job_id,
                                &state.pilot_account,
                                actual,
                                billable_cap,
                                &completion.terminal_digest,
                            ) {
                                Ok(_) => {
                                    completion.charged = darkbloom_core::MicroUsd(
                                        actual.min(billable_cap).max(0),
                                    );
                                    completion.completion_tokens = billable_tokens as i32;
                                }
                                Err(err) => {
                                    let (status, code) = match &err {
                                        crate::ledger::LedgerError::OwnershipLost => (
                                            StatusCode::SERVICE_UNAVAILABLE,
                                            "ownership_lost",
                                        ),
                                        _ => (StatusCode::CONFLICT, "stream_settle_conflict"),
                                    };
                                    return (
                                        status,
                                        Json(json!({
                                            "error": {
                                                "message": format!("stream settle failed: {err}"),
                                                "type": "server_error",
                                                "code": code
                                            }
                                        })),
                                    )
                                        .into_response();
                                }
                            }
                        }
                        let chunk = openai_chat_response(&completion, true);
                        let done = json!({"id": completion.job_id, "object":"chat.completion.chunk","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]});
                        Some(format!(
                            "data: {}\n\ndata: {}\n\ndata: [DONE]\n\n",
                            chunk, done
                        ))
                    } else {
                        None
                    };

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
                        terms.record_bound(
                            &completion.job_id,
                            &completion.attempt_id,
                            &completion.terminal_digest,
                            "settled",
                            Some(ack),
                            lease.as_str(),
                            &completion.se_signature,
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
                    if let Some(body) = stream_body {
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
