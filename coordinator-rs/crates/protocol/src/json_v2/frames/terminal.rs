//! The signed terminal frame, its usage/checkpoint payloads, and the
//! terminal acknowledgement.

use serde::{Deserialize, Serialize};

use super::scope::RequestScope;
use crate::json_v2::error_class::ErrorClass;
use crate::json_v2::ids::{ResponseHash, SessionEpoch, TerminalDigest};

/// Terminal outcome for one attempt.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TerminalOutcome {
    Completed,
    Cancelled,
    Failed,
}

impl TerminalOutcome {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Completed => "completed",
            Self::Cancelled => "cancelled",
            Self::Failed => "failed",
        }
    }
}

/// Token counts covered by the terminal signature.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct TerminalUsage {
    pub prompt_tokens: u64,
    pub completion_tokens: u64,
    pub reasoning_tokens: u64,
}

/// The provider's rolling-hash checkpoint at its last emitted chunk
/// (plan §10.6). Settlement joins this with the coordinator's independent
/// last-accepted checkpoint; a mismatch cannot increase consumer charge.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct RollingHashCheckpoint {
    /// Sequence number of the last content-bearing chunk.
    pub sequence: u64,
    /// Cumulative completion tokens at that chunk.
    pub cumulative_completion_tokens: u64,
    /// Rolling response hash at that chunk.
    pub rolling_hash: ResponseHash,
}

/// Provider → coordinator: the one canonical signed terminal per attempt
/// (plan §10.6). Journaled and fsynced provider-side before send; replayed on
/// reconnect until acknowledged.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TerminalFrame {
    /// `lease_id` is required. `scope.session_epoch` is the *delivery*
    /// session (replays arrive on later connections); `origin_session_epoch`
    /// below is where the attempt actually ran.
    #[serde(flatten)]
    pub scope: RequestScope,
    /// Stable provider identity that executed the attempt.
    pub provider_id: String,
    /// Concrete model build that served the attempt.
    pub model_id: String,
    /// Connection epoch the attempt ran under (plan §9.1 rule 3).
    pub origin_session_epoch: SessionEpoch,
    pub outcome: TerminalOutcome,
    /// Present iff `outcome` is not `completed`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error_class: Option<ErrorClass>,
    pub usage: TerminalUsage,
    /// Final generated-token count, which may exceed the accepted completion
    /// tokens when the consumer pipe closed early.
    pub generated_tokens: u64,
    /// SHA-256 over the full response content.
    pub response_hash: ResponseHash,
    pub checkpoint: RollingHashCheckpoint,
    /// base64 DER ECDSA P-256 Secure Enclave signature over the canonical
    /// terminal bytes (see [`crate::crypto::terminal_digest`]).
    pub se_signature: String,
}

/// Durable disposition returned with a terminal acknowledgement.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AckDisposition {
    /// Receipt and financial disposition committed for the first time.
    Recorded,
    /// Same attempt + same terminal digest: prior disposition returned.
    Duplicate,
    /// Same attempt + different terminal digest: protocol conflict; no
    /// financial mutation (plan §12.8).
    Conflict,
}

/// Coordinator → provider: sent only after the durable receipt and financial
/// disposition commit (plan §12.8). The provider then deletes its journal
/// entry.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct TerminalAckFrame {
    #[serde(flatten)]
    pub scope: RequestScope,
    /// Digest of the canonical terminal being acknowledged.
    pub terminal_digest: TerminalDigest,
    pub disposition: AckDisposition,
}
