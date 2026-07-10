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
//!
//! Module layout: [`config`] (bounds + router config), [`state`] (shared
//! router state), [`chat`] (`POST /v1/chat/completions`), [`models`]
//! (models/health/readiness), [`auth`], [`limits`], [`sealed`], [`sse`],
//! [`errors`], [`provider_ws`] (WebSocket upgrade), [`middleware`].

mod auth;
mod chat;
mod config;
mod errors;
pub mod limits;
mod middleware;
mod models;
mod provider_ws;
mod sealed;
pub mod sse;
mod state;

use axum::extract::DefaultBodyLimit;
use axum::routing::{get, post};
use axum::Router;

use crate::contracts::AppState;
use crate::request_task::{shared_hedge_budget, RequestTaskDeps};

pub use config::{
    HttpConfig, ProviderConnectHandler, ReadinessInputs, BODY_READ_TIMEOUT,
    DEFAULT_PROVIDER_MAX_FRAME_BYTES, MAX_BODY_BYTES,
};
pub use errors::ApiError;
pub use limits::ConcurrencyLimits;
pub use state::HttpState;

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
        limits: std::sync::Arc::new(ConcurrencyLimits::new(
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
    if let Some(provider) = provider_ws::wire_provider_route(config.provider_connect) {
        router = router.merge(provider);
    }
    router
        .layer(DefaultBodyLimit::max(MAX_BODY_BYTES))
        .layer(axum::middleware::from_fn(middleware::request_id_middleware))
        .with_state(http_state)
}
