//! The prepare/prepared frame pair and the resource/execution facts a
//! prepared lease reports.

use serde::{Deserialize, Serialize};

use super::scope::RequestScope;

/// Coordinator → provider: validate, tokenize, and reserve a prepared lease.
///
/// The encrypted request body travels separately in a binary
/// [`prepare_body`](crate::binary::FrameKind::PrepareBody) frame carrying the
/// same identifiers; the provider joins the two on (`job_id`, `attempt_id`,
/// `dispatch_nonce`) and cross-checks `request_digest` after decryption.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PrepareFrame {
    #[serde(flatten)]
    pub scope: RequestScope,
    /// Concrete model build to serve.
    pub model_id: String,
    /// Funded output bound the lease must be able to hold.
    pub max_output_tokens: u64,
    /// Remaining share of the absolute first-content deadline, as a duration.
    /// Advisory: lets the provider report honest execution facts against it.
    pub first_content_budget_ms: u64,
}

/// Exact resource facts returned with a prepared lease (plan §10.3).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct ResourceFacts {
    /// KV budget reserved for this lease (prompt + funded output bound).
    pub kv_reserved_tokens: u64,
    /// Engine KV headroom remaining after this reservation.
    pub kv_headroom_tokens: u64,
    /// Requests actively decoding in the batch at prepare time.
    pub batch_running: u32,
}

/// Execution facts returned with a prepared lease (plan §10.3): they convert
/// a stale-capacity mistake into one fast pre-start re-route instead of a
/// multi-second first-content penalty.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct ExecutionFacts {
    /// Requests queued ahead of this lease in the engine scheduler.
    pub engine_queue_depth: u32,
    /// Whether speculative prefill can begin immediately.
    pub prefill_can_start: bool,
    /// Provider's honest first-content ETA, when it can estimate one.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub predicted_first_content_ms: Option<u64>,
}

/// Provider → coordinator: a non-generating prepared lease was reserved.
/// Speculative prefill starts now; emission stays gated on `start`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PreparedFrame {
    /// `lease_id` is required here — the lease is being issued.
    #[serde(flatten)]
    pub scope: RequestScope,
    /// Provider-local monotonic lease expiry, as a duration (never a
    /// cross-machine wall-clock timestamp).
    pub ttl_ms: u64,
    /// Exact billable input tokens (rendered + tokenized). Accepted only
    /// within the coordinator's request-shape upper bound (plan §12.5).
    pub billable_input_tokens: u64,
    pub resource: ResourceFacts,
    pub execution: ExecutionFacts,
}
