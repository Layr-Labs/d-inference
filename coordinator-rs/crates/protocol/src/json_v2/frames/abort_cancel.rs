//! The abort/aborted and cancel/cancelled frame pairs: idempotent teardown
//! of not-started leases and started attempts.

use serde::{Deserialize, Serialize};

use super::scope::RequestScope;

/// Why the coordinator abandoned a prepared lease. Advisory diagnostics for
/// the provider; never drives provider control flow.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AbortReason {
    /// This lease lost the prepare-hedge funding race (plan §11.8).
    HedgeLoss,
    /// The consumer went away before start authorization.
    ClientGone,
    /// The reservation resize/freeze transaction failed (plan §12.5).
    FundingFailed,
    /// Prepared execution facts cannot meet the first-content budget.
    DeadlineUnreachable,
    /// Coordinator shutdown or ownership loss.
    Shutdown,
}

/// Coordinator → provider: idempotent abort of a not-started lease. The
/// provider tombstones the lease; a tombstone rejects every later start.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct AbortFrame {
    #[serde(flatten)]
    pub scope: RequestScope,
    pub reason: AbortReason,
}

/// Provider → coordinator: the lease is tombstoned, speculative prefill is
/// discarded, and no output can ever be emitted for this attempt.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct AbortedFrame {
    #[serde(flatten)]
    pub scope: RequestScope,
}

/// Coordinator → provider: idempotent cancellation of a started attempt.
/// Must produce a terminal (plan §10.3).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct CancelFrame {
    #[serde(flatten)]
    pub scope: RequestScope,
}

/// Provider → coordinator: the attempt is durably quiescent and cannot later
/// emit output (plan §10.2).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct CancelledFrame {
    #[serde(flatten)]
    pub scope: RequestScope,
}
