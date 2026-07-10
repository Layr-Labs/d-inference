//! The start/started frame pair: idempotent emission authorization and its
//! acknowledgement.

use serde::{Deserialize, Serialize};

use super::scope::RequestScope;

/// Coordinator → provider: idempotent emission authorization. Resending the
/// same start identity is always safe; an ambiguous delivery never authorizes
/// an alternate (plan §9.2).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct StartFrame {
    #[serde(flatten)]
    pub scope: RequestScope,
}

/// Provider → coordinator: the start record is durable and emission has
/// begun (or prefill is still running with emission now authorized).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct StartedFrame {
    #[serde(flatten)]
    pub scope: RequestScope,
}
