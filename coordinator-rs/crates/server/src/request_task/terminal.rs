//! Terminal receipts and settlement parameter construction (plan §10.6,
//! §12.6).
//!
//! v2 terminals use the protocol crate's canonical digest
//! (`darkbloom-terminal-v2`). v1 terminals have no signed canonical form on
//! the wire, so this module defines a deterministic coordinator-side digest
//! (`darkbloom-terminal-v1`: sorted-key compact JSON over the identity and
//! usage facts) purely for idempotency/conflict detection in the durable
//! layer — it carries no signature authority.

use serde_json::json;
use sha2::{Digest, Sha256};

use darkbloom_core::ids::{
    AttemptId, CoordinatorEpoch, JobId, SessionEpoch, TerminalDigest as CoreDigest,
};
use darkbloom_core::money::Tokens;
use darkbloom_core::request::{TerminalOutcome, TerminalSummary};
use darkbloom_core::settlement::ProviderClaimedUsage;
use darkbloom_protocol::crypto::terminal_digest;
use darkbloom_protocol::json_v1::UsageInfo;
use darkbloom_protocol::json_v2::{self, TerminalFrame};

use crate::contracts::SettleParams;
use crate::request_task::attempt::core_error_class;
use crate::request_task::funding::clamp_tokens;
use crate::request_task::types::UsageOut;

/// The provider facts the settlement transaction persists.
pub enum TerminalReceipt {
    V2 {
        frame: Box<TerminalFrame>,
        digest: [u8; 32],
    },
    V1 {
        usage: UsageInfo,
        se_signature: Option<String>,
        response_hash: Option<String>,
        digest: [u8; 32],
    },
    V1Error {
        status_code: u16,
        digest: [u8; 32],
    },
}

impl TerminalReceipt {
    pub fn digest(&self) -> [u8; 32] {
        match self {
            Self::V2 { digest, .. } | Self::V1 { digest, .. } | Self::V1Error { digest, .. } => {
                *digest
            }
        }
    }

    /// Raw terminal receipt for the durable table (`SettleParams`).
    pub fn to_json(&self) -> serde_json::Value {
        match self {
            Self::V2 { frame, .. } => {
                serde_json::to_value(json_v2::FrameV2::Terminal(frame.as_ref().clone()))
                    .unwrap_or(serde_json::Value::Null)
            }
            Self::V1 {
                usage,
                se_signature,
                response_hash,
                ..
            } => json!({
                "protocol": "v1",
                "type": "inference_complete",
                "usage": usage,
                "se_signature": se_signature.clone().unwrap_or_default(),
                "response_hash": response_hash.clone().unwrap_or_default(),
            }),
            Self::V1Error { status_code, .. } => json!({
                "protocol": "v1",
                "type": "inference_error",
                "status_code": status_code,
            }),
        }
    }

    pub fn claimed_usage(&self) -> ProviderClaimedUsage {
        match self {
            Self::V2 { frame, .. } => ProviderClaimedUsage {
                prompt_tokens: clamp_tokens(frame.usage.prompt_tokens),
                completion_tokens: clamp_tokens(frame.usage.completion_tokens),
            },
            Self::V1 { usage, .. } => ProviderClaimedUsage {
                prompt_tokens: clamp_tokens(usage.prompt_tokens.max(0) as u64),
                completion_tokens: clamp_tokens(usage.completion_tokens.max(0) as u64),
            },
            Self::V1Error { .. } => ProviderClaimedUsage {
                prompt_tokens: Tokens::ZERO,
                completion_tokens: Tokens::ZERO,
            },
        }
    }

    /// Consumer-facing usage facts at stream end.
    pub fn usage_out(&self) -> UsageOut {
        match self {
            Self::V2 { frame, .. } => UsageOut {
                prompt_tokens: frame.usage.prompt_tokens,
                completion_tokens: frame.usage.completion_tokens,
                reasoning_tokens: frame.usage.reasoning_tokens,
                se_signature: (!frame.se_signature.is_empty()).then(|| frame.se_signature.clone()),
                response_hash: Some(frame.response_hash.to_string()),
            },
            Self::V1 {
                usage,
                se_signature,
                response_hash,
                ..
            } => UsageOut {
                prompt_tokens: usage.prompt_tokens.max(0) as u64,
                completion_tokens: usage.completion_tokens.max(0) as u64,
                reasoning_tokens: usage.reasoning_tokens.max(0) as u64,
                se_signature: se_signature.clone(),
                response_hash: response_hash.clone(),
            },
            Self::V1Error { .. } => UsageOut::default(),
        }
    }
}

/// Builds the v2 receipt + reducer summary from a terminal frame. `None`
/// when the frame is structurally invalid (it can never acquire a digest,
/// so it can never settle — plan §10.6).
pub fn v2_receipt(frame: Box<TerminalFrame>) -> Option<(TerminalReceipt, TerminalSummary)> {
    let digest = terminal_digest::terminal_digest(&frame).ok()?;
    let outcome = match frame.outcome {
        json_v2::TerminalOutcome::Completed => TerminalOutcome::Completed,
        json_v2::TerminalOutcome::Cancelled => TerminalOutcome::Cancelled,
        json_v2::TerminalOutcome::Failed => TerminalOutcome::Error(
            frame
                .error_class
                .map(core_error_class)
                .unwrap_or(darkbloom_core::provider_error::ProviderErrorClass::Fault),
        ),
    };
    let digest_bytes = *digest.as_bytes();
    let receipt = TerminalReceipt::V2 {
        frame,
        digest: digest_bytes,
    };
    let summary = TerminalSummary {
        digest: CoreDigest::new(digest_bytes),
        outcome,
        usage: receipt.claimed_usage(),
    };
    Some((receipt, summary))
}

fn v1_canonical_digest(
    job: JobId,
    attempt: AttemptId,
    outcome: &str,
    usage: &UsageInfo,
    response_hash: &str,
) -> [u8; 32] {
    // Sorted keys, compact JSON, fixed domain — deterministic across
    // replays of the same v1 terminal facts.
    let canonical = json!({
        "attempt_id": attempt.to_string(),
        "completion_tokens": usage.completion_tokens,
        "domain": "darkbloom-terminal-v1",
        "job_id": job.to_string(),
        "outcome": outcome,
        "prompt_tokens": usage.prompt_tokens,
        "reasoning_tokens": usage.reasoning_tokens,
        "response_hash": response_hash,
    });
    let bytes = serde_json::to_vec(&canonical).unwrap_or_default();
    Sha256::digest(&bytes).into()
}

pub fn v1_complete_receipt(
    job: JobId,
    attempt: AttemptId,
    usage: Option<UsageInfo>,
    se_signature: Option<String>,
    response_hash: Option<String>,
) -> (TerminalReceipt, TerminalSummary) {
    let usage = usage.unwrap_or_default();
    let digest = v1_canonical_digest(
        job,
        attempt,
        "completed",
        &usage,
        response_hash.as_deref().unwrap_or(""),
    );
    let receipt = TerminalReceipt::V1 {
        usage,
        se_signature,
        response_hash,
        digest,
    };
    let summary = TerminalSummary {
        digest: CoreDigest::new(digest),
        outcome: TerminalOutcome::Completed,
        usage: receipt.claimed_usage(),
    };
    (receipt, summary)
}

pub fn v1_error_receipt(
    job: JobId,
    attempt: AttemptId,
    status_code: u16,
    class: darkbloom_core::provider_error::ProviderErrorClass,
) -> (TerminalReceipt, TerminalSummary) {
    let usage = UsageInfo::default();
    let digest = v1_canonical_digest(job, attempt, "error", &usage, "");
    let receipt = TerminalReceipt::V1Error {
        status_code,
        digest,
    };
    let summary = TerminalSummary {
        digest: CoreDigest::new(digest),
        outcome: TerminalOutcome::Error(class),
        usage: ProviderClaimedUsage {
            prompt_tokens: Tokens::ZERO,
            completion_tokens: Tokens::ZERO,
        },
    };
    (receipt, summary)
}

/// Everything the settlement parameter builder needs.
pub struct SettleInputs<'a> {
    pub job: JobId,
    pub attempt: AttemptId,
    pub receipt: &'a TerminalReceipt,
    pub accepted_sequence: u64,
    pub accepted_checkpoint: Tokens,
    /// v1 only: the frozen billable input is the billing claim (module docs
    /// in `request_task` — v1 has no signed exact tokenization; the
    /// provider's self-reported prompt count stays in the raw receipt).
    pub frozen_prompt_override: Option<Tokens>,
    /// Session epoch the attempt ran under (plan §9.1.3).
    pub origin_session_epoch: SessionEpoch,
    pub coordinator_epoch: CoordinatorEpoch,
}

/// Builds the settlement transaction parameters: provider-claimed usage
/// joined with the coordinator's independent accepted checkpoint
/// (plan §10.6 — the ledger caps billing at the checkpoint).
pub fn settle_params(inputs: &SettleInputs<'_>) -> SettleParams {
    let claimed = inputs.receipt.claimed_usage();
    let prompt_tokens = inputs
        .frozen_prompt_override
        .unwrap_or(claimed.prompt_tokens);
    SettleParams {
        operation_key: format!("job:{}:settle", inputs.job),
        job: inputs.job,
        attempt: inputs.attempt,
        terminal_digest: inputs.receipt.digest(),
        terminal_json: inputs.receipt.to_json(),
        prompt_tokens: u64::from(prompt_tokens.get()),
        completion_tokens_claimed: u64::from(claimed.completion_tokens.get()),
        accepted_sequence: inputs.accepted_sequence,
        accepted_cumulative_tokens: u64::from(inputs.accepted_checkpoint.get()),
        origin_session_epoch: inputs.origin_session_epoch,
        coordinator_epoch: inputs.coordinator_epoch,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use uuid::Uuid;

    #[test]
    fn v1_digest_is_deterministic_and_moves_with_usage() {
        let job = JobId::new(Uuid::from_u128(1));
        let attempt = AttemptId::new(Uuid::from_u128(2));
        let usage = UsageInfo {
            prompt_tokens: 10,
            completion_tokens: 20,
            reasoning_tokens: 0,
        };
        let (a, sa) = v1_complete_receipt(job, attempt, Some(usage), None, Some("h".into()));
        let (b, sb) = v1_complete_receipt(job, attempt, Some(usage), None, Some("h".into()));
        assert_eq!(a.digest(), b.digest());
        assert_eq!(sa.digest, sb.digest);

        let bumped = UsageInfo {
            completion_tokens: 21,
            ..usage
        };
        let (c, _) = v1_complete_receipt(job, attempt, Some(bumped), None, Some("h".into()));
        assert_ne!(a.digest(), c.digest());
    }
}
