//! Axum API adapter (plan §7.1): route matching, middleware, auth
//! extraction, request normalization, SSE/JSON response construction, and
//! typed error mapping. It never mutates provider state and never
//! implements settlement rules — both live behind the frozen contracts.
//!
//! # Networking posture (plan §14–§16; socket layer in [`crate::serve`])
//!
//! - **Ingress ordering**: `POST /v1/chat/completions` authenticates and
//!   acquires the concurrency permits from headers BEFORE collecting the
//!   body ([`chat`] module docs) — a shed request never buffers a body.
//!   Body collection is bounded by [`MAX_BODY_BYTES`] and
//!   [`BODY_READ_TIMEOUT`]; the pre-header slowloris window is closed by
//!   the serve loop's header-read timeout.
//! - **No blanket timeout layer**: there is intentionally no
//!   `tower::timeout`/`tower_http` response timeout on this router — a
//!   long SSE generation must never be killed by a generic layer. Request
//!   lifetime is owned by the request task's deadlines (plan §16).
//! - **SSE flush**: streaming bodies are chunked (no Content-Length), one
//!   complete SSE event per body frame, flushed per frame by hyper, with
//!   `Cache-Control: no-cache, no-store` and `X-Accel-Buffering: no`
//!   (see [`chat`]).
//! - **Provider WebSocket**: message and frame caps are both set at the
//!   upgrade (32 MiB, sealed-vision sized); keepalive is provider
//!   heartbeats + the session's 90 s read deadline (no coordinator-sent
//!   pings); permessage-deflate is never negotiated (axum does not offer
//!   the extension — chunk payloads are ciphertext, compression is waste).

mod auth;
mod chat;
mod errors;
pub mod limits;
mod models;
mod sealed;
pub mod sse;

use std::sync::Arc;

use axum::extract::ws::WebSocket;
use axum::extract::{DefaultBodyLimit, State, WebSocketUpgrade};
use axum::http::{HeaderValue, Request};
use axum::middleware::{self, Next};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use axum::Router;
use futures::future::BoxFuture;
use tokio::sync::watch;
use tokio_util::sync::CancellationToken;
use tokio_util::task::TaskTracker;
use tracing::Instrument;
use uuid::Uuid;

use crate::contracts::AppState;
use crate::request_task::{shared_hedge_budget, RequestTaskDeps};

pub use errors::ApiError;
pub use limits::ConcurrencyLimits;

/// The Go-compatible plaintext body cap (plan §14).
pub const MAX_BODY_BYTES: usize = 16 * 1024 * 1024;

/// Slow-body bound: maximum wall time to receive one request body after
/// headers (plan §14). Applies only where a body is collected — never to
/// responses, so SSE streams are exempt by construction.
pub const BODY_READ_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(30);

/// Default provider WebSocket frame cap — sized for sealed vision payloads
/// (mirrors `provider_session::SessionConfig::max_frame_bytes`).
pub const DEFAULT_PROVIDER_MAX_FRAME_BYTES: usize = 32 * 1024 * 1024;

/// Indirection for the provider WebSocket endpoint: the session component
/// owns `provider_session::serve(ws, deps)`; integration wraps it as
/// `Arc::new(move |ws| Box::pin(provider_session::serve(ws, deps.clone())))`
/// so this adapter never depends on that module's internals.
pub type ProviderConnectHandler = Arc<dyn Fn(WebSocket) -> BoxFuture<'static, ()> + Send + Sync>;

/// Live readiness inputs for `/readyz` (plan §20): watch channels fed by
/// the ownership keeper and the supervisor's admission gate. The defaults
/// are always-true channels for tests and tooling that run without a
/// database (a dropped sender keeps reporting its last value).
#[derive(Clone)]
pub struct ReadinessInputs {
    /// The ownership lock-holding connection is healthy (plan §20).
    pub ownership_healthy: watch::Receiver<bool>,
    /// Admission is open (flips false as the FIRST shutdown action).
    pub admission_open: watch::Receiver<bool>,
}

impl Default for ReadinessInputs {
    fn default() -> Self {
        Self {
            ownership_healthy: watch::channel(true).1,
            admission_open: watch::channel(true).1,
        }
    }
}

/// Adapter configuration beyond what [`AppState`] carries.
pub struct HttpConfig {
    pub global_concurrency: usize,
    pub per_account_concurrency: usize,
    /// `GET /v1/providers/connect` upgrade target; `None` leaves the route
    /// answering 503 until the session component is wired.
    pub provider_connect: Option<ProviderConnectHandler>,
    /// Maximum WebSocket message size for provider connections.
    pub provider_max_frame_bytes: usize,
    /// Readiness watch channels (see [`ReadinessInputs`]).
    pub readiness: ReadinessInputs,
    /// Coordinator shutdown token propagated into request tasks.
    pub shutdown: CancellationToken,
    /// Tracker every spawned request task registers with (plan §15.1 step 2:
    /// the supervisor's requests phase drains THESE tasks before workers and
    /// sessions stop). `bootstrap` passes the requests-phase tracker; the
    /// default is a standalone tracker for harnesses without a supervisor.
    pub request_tracker: TaskTracker,
}

impl Default for HttpConfig {
    fn default() -> Self {
        Self {
            global_concurrency: 512,
            per_account_concurrency: 32,
            provider_connect: None,
            provider_max_frame_bytes: DEFAULT_PROVIDER_MAX_FRAME_BYTES,
            readiness: ReadinessInputs::default(),
            shutdown: CancellationToken::new(),
            request_tracker: TaskTracker::new(),
        }
    }
}

/// Shared router state.
#[derive(Clone)]
pub struct HttpState {
    pub app: AppState,
    pub limits: Arc<ConcurrencyLimits>,
    pub task_deps: RequestTaskDeps,
    pub readiness: ReadinessInputs,
    /// Requests-phase task tracker (see [`HttpConfig::request_tracker`]).
    pub request_tracker: TaskTracker,
    provider_connect: Option<ProviderConnectHandler>,
    provider_max_frame_bytes: usize,
}

impl axum::extract::FromRef<HttpState> for AppState {
    fn from_ref(state: &HttpState) -> AppState {
        state.app.clone()
    }
}

/// Canonical constructor (contracts entry-point convention): all consumer
/// routes with default wiring. `main` uses [`build_router_with`] to supply
/// the provider-connect handler and readiness inputs.
pub fn build_router(state: AppState) -> Router {
    build_router_with(state, HttpConfig::default())
}

/// Builds the full router. This is where THE process-global hedge budget is
/// constructed (plan §11.8, one bounded budget shared by every request
/// task): `main`/`bootstrap` call this exactly once per process.
pub fn build_router_with(state: AppState, config: HttpConfig) -> Router {
    let hedge_budget = shared_hedge_budget(&state.policy);
    let task_deps = RequestTaskDeps::from_state(&state, hedge_budget, config.shutdown.clone());
    let http_state = HttpState {
        app: state,
        limits: Arc::new(ConcurrencyLimits::new(
            config.global_concurrency,
            config.per_account_concurrency,
        )),
        task_deps,
        readiness: config.readiness.clone(),
        request_tracker: config.request_tracker.clone(),
        provider_connect: config.provider_connect.clone(),
        provider_max_frame_bytes: config.provider_max_frame_bytes,
    };

    let mut router = Router::new()
        .route("/v1/chat/completions", post(chat::chat_completions))
        .route("/v1/models", get(models::list_models))
        .route("/v1/models/{id}", get(models::get_model))
        .route("/v1/encryption-key", get(models::encryption_key))
        .route("/healthz", get(models::healthz))
        // Alias: the prod host Caddy (deploy/gcp/prod/Caddyfile) probes the
        // upstream at `health_uri /health` every 2 s — without this route
        // the proxy would mark the coordinator unhealthy and shed ALL
        // traffic as 429.
        .route("/health", get(models::healthz))
        .route("/readyz", get(models::readyz));
    if let Some(provider) = wire_provider_route(config.provider_connect) {
        router = router.merge(provider);
    }
    router
        .layer(DefaultBodyLimit::max(MAX_BODY_BYTES))
        .layer(middleware::from_fn(request_id_middleware))
        .with_state(http_state)
}

/// The provider WebSocket route, present only when the session handler is
/// wired (concurrent-module seam; see [`ProviderConnectHandler`]).
fn wire_provider_route(handler: Option<ProviderConnectHandler>) -> Option<Router<HttpState>> {
    handler.as_ref()?;
    Some(Router::new().route("/v1/providers/connect", get(provider_connect)))
}

async fn provider_connect(State(state): State<HttpState>, upgrade: WebSocketUpgrade) -> Response {
    match state.provider_connect.clone() {
        Some(handler) => upgrade
            // Both caps must carry the same value: tungstenite's DEFAULT
            // frame cap is 16 MiB, which would reject a single-frame sealed
            // vision payload that the 32 MiB message cap allows.
            .max_message_size(state.provider_max_frame_bytes)
            .max_frame_size(state.provider_max_frame_bytes)
            .on_upgrade(move |socket| async move { handler(socket).await })
            .into_response(),
        None => ApiError::Internal("provider session component not wired").into_response(),
    }
}

/// Request-id propagation plus a per-request tracing span (plan §7.1
/// middleware). The job id gets its own span inside the chat handler.
async fn request_id_middleware(request: Request<axum::body::Body>, next: Next) -> Response {
    let request_id = request
        .headers()
        .get("x-request-id")
        .and_then(|v| v.to_str().ok())
        .map(str::to_owned)
        .unwrap_or_else(|| Uuid::new_v4().to_string());
    let span = tracing::info_span!(
        "http",
        request_id = %request_id,
        method = %request.method(),
        path = %request.uri().path(),
    );
    let mut response = next.run(request).instrument(span).await;
    if let Ok(value) = HeaderValue::from_str(&request_id) {
        response.headers_mut().insert("x-request-id", value);
    }
    response
}
