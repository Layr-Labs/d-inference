//! Axum API adapter (plan §7.1): route matching, middleware, auth
//! extraction, request normalization, SSE/JSON response construction, and
//! typed error mapping. It never mutates provider state and never
//! implements settlement rules — both live behind the frozen contracts.

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
use tokio_util::sync::CancellationToken;
use tracing::Instrument;
use uuid::Uuid;

use crate::contracts::AppState;
use crate::request_task::{
    shared_hedge_budget, ProviderKeyDirectory, RequestTaskDeps, StaticProviderKeys,
};

pub use errors::ApiError;
pub use limits::ConcurrencyLimits;

/// The Go-compatible plaintext body cap (plan §14).
pub const MAX_BODY_BYTES: usize = 16 * 1024 * 1024;

/// Indirection for the provider WebSocket endpoint: the session component
/// owns `provider_session::serve(ws, deps)`; integration wraps it as
/// `Arc::new(move |ws| Box::pin(provider_session::serve(ws, deps.clone())))`
/// so this adapter never depends on that module's internals.
pub type ProviderConnectHandler = Arc<dyn Fn(WebSocket) -> BoxFuture<'static, ()> + Send + Sync>;

/// Adapter configuration beyond what [`AppState`] carries.
pub struct HttpConfig {
    /// Provider X25519 key lookup for request encryption (wired to the
    /// fleet/session registry at integration).
    pub provider_keys: Arc<dyn ProviderKeyDirectory>,
    pub global_concurrency: usize,
    pub per_account_concurrency: usize,
    /// `GET /v1/providers/connect` upgrade target; `None` leaves the route
    /// answering 503 until the session component is wired.
    pub provider_connect: Option<ProviderConnectHandler>,
    /// Coordinator shutdown token propagated into request tasks.
    pub shutdown: CancellationToken,
}

impl Default for HttpConfig {
    fn default() -> Self {
        Self {
            provider_keys: Arc::new(StaticProviderKeys::default()),
            global_concurrency: 512,
            per_account_concurrency: 32,
            provider_connect: None,
            shutdown: CancellationToken::new(),
        }
    }
}

/// Shared router state.
#[derive(Clone)]
pub struct HttpState {
    pub app: AppState,
    pub limits: Arc<ConcurrencyLimits>,
    pub task_deps: RequestTaskDeps,
    provider_connect: Option<ProviderConnectHandler>,
}

impl axum::extract::FromRef<HttpState> for AppState {
    fn from_ref(state: &HttpState) -> AppState {
        state.app.clone()
    }
}

/// Canonical constructor (contracts entry-point convention): all consumer
/// routes with default wiring. `main` uses [`build_router_with`] to supply
/// the provider-key directory and the provider-connect handler.
pub fn build_router(state: AppState) -> Router {
    build_router_with(state, HttpConfig::default())
}

pub fn build_router_with(state: AppState, config: HttpConfig) -> Router {
    let hedge_budget = shared_hedge_budget(&state.policy);
    let task_deps = RequestTaskDeps::from_state(
        &state,
        config.provider_keys.clone(),
        hedge_budget,
        config.shutdown.clone(),
    );
    let http_state = HttpState {
        app: state,
        limits: Arc::new(ConcurrencyLimits::new(
            config.global_concurrency,
            config.per_account_concurrency,
        )),
        task_deps,
        provider_connect: config.provider_connect.clone(),
    };

    let mut router = Router::new()
        .route("/v1/chat/completions", post(chat::chat_completions))
        .route("/v1/models", get(models::list_models))
        .route("/v1/models/{id}", get(models::get_model))
        .route("/v1/encryption-key", get(models::encryption_key))
        .route("/healthz", get(models::healthz))
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
