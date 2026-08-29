//! HTTP adapter configuration: body/ingress bounds, the provider-connect
//! indirection, readiness inputs, and the router config.

use std::sync::Arc;

use axum::extract::ws::WebSocket;
use futures::future::BoxFuture;
use tokio::sync::watch;
use tokio_util::sync::CancellationToken;
use tokio_util::task::TaskTracker;

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

/// Adapter configuration beyond what
/// [`AppState`](crate::contracts::AppState) carries.
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
