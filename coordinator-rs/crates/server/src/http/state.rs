//! The shared router state handed to every HTTP handler.

use std::sync::Arc;

use tokio_util::task::TaskTracker;

use crate::contracts::AppState;
use crate::request_task::RequestTaskDeps;

use super::config::{ProviderConnectHandler, ReadinessInputs};
use super::limits::ConcurrencyLimits;

/// Shared router state.
#[derive(Clone)]
pub struct HttpState {
    pub app: AppState,
    pub limits: Arc<ConcurrencyLimits>,
    pub task_deps: RequestTaskDeps,
    pub readiness: ReadinessInputs,
    /// Requests-phase task tracker (see
    /// [`HttpConfig::request_tracker`](super::HttpConfig)).
    pub request_tracker: TaskTracker,
    pub(super) provider_connect: Option<ProviderConnectHandler>,
    pub(super) provider_max_frame_bytes: usize,
}

impl axum::extract::FromRef<HttpState> for AppState {
    fn from_ref(state: &HttpState) -> AppState {
        state.app.clone()
    }
}
