//! Value types crossing the HTTP ↔ request-task seam (plan §7.1, §7.2).
//!
//! The HTTP adapter normalizes the consumer request once into
//! [`NormalizedRequest`] and hands it to [`crate::request_task::run`]. The
//! task reports progress through the bounded [`ConsumerEvent`] channel
//! (first content commits the stream) and returns one [`TaskReport`] the
//! adapter maps to an HTTP status when nothing was committed.

use bytes::Bytes;
use tokio::sync::mpsc;

use darkbloom_core::ids::{AccountId, ApiKeyId, JobId};
use darkbloom_core::money::MicroUsd;
use darkbloom_core::request::RequestOutcome;
use darkbloom_core::time::TimestampMs;

use crate::contracts::LedgerError;

/// One consumer request, parsed and normalized exactly once (plan §15.4).
#[derive(Debug)]
pub struct NormalizedRequest {
    pub job: JobId,
    pub account: AccountId,
    /// API key identity frozen into settlement terms (plan §12.4). The
    /// pilot auth surface is API keys only.
    pub api_key: ApiKeyId,
    pub spend_cap: Option<MicroUsd>,
    /// Public model id the consumer asked for (echoed in every response).
    pub public_model: String,
    /// Concrete build id after alias resolution (routed, billed, served).
    pub concrete_model: String,
    /// Canonical provider-bound body: model rewritten to the concrete
    /// build, `max_tokens` bounded. Serialized once; encrypted per attempt.
    pub body: Bytes,
    pub stream: bool,
    /// Routing estimate: content bytes / 4 (mirrors Go
    /// `estimatePromptTokens`).
    pub estimated_prompt_tokens: u64,
    /// Explicit consumer bound or the injected default (Go
    /// `defaultMaxOutputTokens`).
    pub requested_max_tokens: u64,
    pub needs_vision: bool,
    pub needs_tools: bool,
    /// Paid public routing (requires a provider beneficiary, plan §11.2).
    pub paid: bool,
    /// Where committed output flows. The task never writes a byte before
    /// first content (pre-content failover stays invisible, plan §7.8).
    pub consumer: mpsc::Sender<ConsumerEvent>,
}

/// Usage facts surfaced to the consumer at stream end.
#[derive(Debug, Clone, Default)]
pub struct UsageOut {
    pub prompt_tokens: u64,
    pub completion_tokens: u64,
    pub reasoning_tokens: u64,
    pub se_signature: Option<String>,
    pub response_hash: Option<String>,
}

/// Events flowing task → HTTP adapter over the bounded consumer channel.
#[derive(Debug)]
pub enum ConsumerEvent {
    /// One SSE-ready plaintext chunk payload (bare JSON, no `data: `
    /// prefix), model field already rewritten to the public id.
    Chunk(Bytes),
    /// Terminal success: the adapter emits the final usage chunk and
    /// `data: [DONE]`.
    Completed(UsageOut),
    /// Post-content in-band failure: the adapter emits one SSE error event
    /// and ends the stream (mirrors Go `inference.in_band_error`).
    Failed { message: String, error_type: String },
}

/// What one request task resolved to. `outcome` is the reducer's single
/// consumer-facing disposition; `ledger_error` refines HTTP mapping
/// (insufficient funds → 402) when the failure came from a money leg.
#[derive(Debug)]
pub struct TaskReport {
    pub outcome: RequestOutcome,
    pub committed: bool,
    pub ledger_error: Option<LedgerError>,
    pub usage: Option<UsageOut>,
}

/// Monotonic task clock. The reducer wants [`TimestampMs`] and refuses
/// deadline events that fire early (plan §9.2.5), so `now()` must never go
/// backwards relative to armed timers: it is anchored once to the wall
/// clock and advanced by the tokio monotonic clock (which also makes
/// paused-time tests deterministic).
#[derive(Debug, Clone, Copy)]
pub struct Clock {
    base_ms: i64,
    started: tokio::time::Instant,
}

impl Clock {
    pub fn start() -> Self {
        Self {
            base_ms: chrono::Utc::now().timestamp_millis(),
            started: tokio::time::Instant::now(),
        }
    }

    pub fn now(&self) -> TimestampMs {
        let elapsed = i64::try_from(self.started.elapsed().as_millis()).unwrap_or(i64::MAX);
        TimestampMs::new(self.base_ms.saturating_add(elapsed))
    }

    /// The tokio instant at which `at` (task time) is reached.
    pub fn instant_at(&self, at: TimestampMs) -> tokio::time::Instant {
        let delta_ms = at.get().saturating_sub(self.base_ms).max(0);
        self.started + std::time::Duration::from_millis(delta_ms as u64)
    }
}
