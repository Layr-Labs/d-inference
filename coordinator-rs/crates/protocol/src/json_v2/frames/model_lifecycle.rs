//! Revision-fenced model lifecycle frames: `model_ready` and `model_gone`.

use serde::{Deserialize, Serialize};

/// Provider → coordinator: a model became ready to serve (plan §10.7).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ModelReadyFrame {
    pub model_id: String,
    /// Monotonically increasing provider-process state revision. The fleet
    /// reducer ignores older revisions, so a delayed heartbeat cannot
    /// resurrect a model after `model_gone`.
    pub state_revision: u64,
}

/// Provider → coordinator: a model is no longer servable (plan §10.7).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ModelGoneFrame {
    pub model_id: String,
    /// Same monotonic revision domain as [`ModelReadyFrame`].
    pub state_revision: u64,
}
