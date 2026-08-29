//! The narrow async ledger facade and its parameter/outcome types
//! (plan §7.5, §12). Invariant: every money movement crosses this seam
//! with an idempotent operation key and the coordinator fencing epoch.

use async_trait::async_trait;

use darkbloom_core::ids::{
    AccountId, ApiKeyId, AttemptId, CoordinatorEpoch, JobId, LeaseId, ProviderId, SessionEpoch,
};
use darkbloom_core::money::MicroUsd;
use darkbloom_core::settlement::FrozenTerms;

#[derive(Debug, Clone)]
pub struct ReserveParams {
    pub operation_key: String,
    pub job: JobId,
    pub account: AccountId,
    pub api_key: Option<ApiKeyId>,
    pub public_model: String,
    pub concrete_model: String,
    pub hold: MicroUsd,
    pub spend_cap: Option<MicroUsd>,
    pub first_content_deadline_ms: i64,
    pub request_deadline_ms: i64,
    pub coordinator_epoch: CoordinatorEpoch,
}

#[derive(Debug, Clone, Copy)]
pub struct ReserveOutcome {
    pub reserved_total: MicroUsd,
    pub reserved_withdrawable: MicroUsd,
}

#[derive(Debug, Clone)]
pub struct ResizeFreezeParams {
    pub operation_key: String,
    pub job: JobId,
    pub attempt: AttemptId,
    pub new_hold: MicroUsd,
    pub frozen: FrozenTerms,
    pub lease: LeaseId,
    pub provider: ProviderId,
    /// Session epoch the attempt was dispatched under (plan §10.2); recorded
    /// on the durable attempt row.
    pub session_epoch: SessionEpoch,
    /// Dispatch nonce from the attempt's wire scope (plan §10.2).
    pub dispatch_nonce: [u8; 16],
    /// Canonical encrypted-request digest from the attempt's wire scope.
    pub request_digest: [u8; 32],
    pub coordinator_epoch: CoordinatorEpoch,
}

#[derive(Debug, Clone)]
pub struct SettleParams {
    pub operation_key: String,
    pub job: JobId,
    pub attempt: AttemptId,
    pub terminal_digest: [u8; 32],
    /// Raw terminal receipt for the durable table.
    pub terminal_json: serde_json::Value,
    pub prompt_tokens: u64,
    pub completion_tokens_claimed: u64,
    pub accepted_sequence: u64,
    pub accepted_cumulative_tokens: u64,
    /// Session epoch the attempt actually RAN under (plan §9.1.3): the v2
    /// terminal's `origin_session_epoch`; for v1, the dispatch session.
    pub origin_session_epoch: SessionEpoch,
    pub coordinator_epoch: CoordinatorEpoch,
    /// Whether the terminal's Secure Enclave signature was verified against
    /// the provider's registered SE key before intake (plan §12.6 step 3).
    /// The session is the verifying layer (it holds the key material);
    /// settle is defense-in-depth: an UNVERIFIED v2 terminal parks the job
    /// in review instead of paying. v1 terminals have no signed canonical
    /// form — they carry `false` and settle on transport trust (Go parity).
    pub signature_verified: bool,
}

#[derive(Debug, Clone, Copy)]
pub struct SettleOutcome {
    pub charged: MicroUsd,
    pub refunded: MicroUsd,
    pub provider_payout: MicroUsd,
    pub flagged_for_review: bool,
}

#[derive(Debug, Clone)]
pub struct ReleaseParams {
    pub operation_key: String,
    pub job: JobId,
    pub reason: String,
    pub coordinator_epoch: CoordinatorEpoch,
}

#[derive(Debug, thiserror::Error)]
pub enum LedgerError {
    #[error("insufficient funds")]
    InsufficientFunds,
    #[error("spend cap exceeded")]
    SpendCapExceeded,
    #[error("state conflict: {0}")]
    Conflict(String),
    #[error("coordinator epoch fenced")]
    EpochFenced,
    #[error("database unavailable: {0}")]
    Unavailable(String),
}

/// Narrow async ledger seam (plan §7.5). Implemented by `ledger::Ledger`
/// over SQLx; request tasks depend only on this trait so the components can
/// be developed and tested independently.
#[async_trait]
pub trait LedgerFacade: Send + Sync {
    async fn reserve(&self, p: ReserveParams) -> Result<ReserveOutcome, LedgerError>;
    async fn resize_freeze(&self, p: ResizeFreezeParams) -> Result<(), LedgerError>;
    async fn mark_running(&self, job: JobId) -> Result<(), LedgerError>;
    async fn settle(&self, p: SettleParams) -> Result<SettleOutcome, LedgerError>;
    async fn release(&self, p: ReleaseParams) -> Result<(), LedgerError>;
    async fn move_to_review(&self, job: JobId, reason: String) -> Result<(), LedgerError>;
}
