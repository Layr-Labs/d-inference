//! Protocol v2 frames (plan §10).
//!
//! [`FrameV2`] is a serde internally-tagged enum on `"type"`. Unlike v1,
//! decoding is strict for required fields: v2 providers are a new dual-stack
//! release, so there is no legacy leniency to preserve. Unknown fields are
//! still ignored for additive forward compatibility.
//!
//! Every request-scoped frame carries the full [`RequestScope`] identity and
//! fencing set (plan §10.2). An acknowledgement (`started`, `aborted`,
//! `cancelled`, `terminal_ack`) proves the named state transition, not merely
//! receipt of the command.

use serde::{Deserialize, Serialize};

use super::error_class::ErrorClass;
use super::ids::{
    AttemptId, CoordinatorEpoch, DispatchNonce, JobId, LeaseId, RequestDigest, ResponseHash,
    SessionEpoch, TerminalDigest,
};

/// Identity and fencing fields carried by every request-scoped v2 frame
/// (plan §10.2). Flattened into each frame's top level.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct RequestScope {
    pub job_id: JobId,
    pub attempt_id: AttemptId,
    /// Present on every frame at or after `prepared`. `prepare` has no lease
    /// yet. [`FrameV2::validate`] enforces presence per frame kind.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub lease_id: Option<LeaseId>,
    pub session_epoch: SessionEpoch,
    pub coordinator_epoch: CoordinatorEpoch,
    pub dispatch_nonce: DispatchNonce,
    pub request_digest: RequestDigest,
}

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

/// Any protocol v2 frame, tagged by `"type"`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum FrameV2 {
    Prepare(PrepareFrame),
    Prepared(PreparedFrame),
    Start(StartFrame),
    Started(StartedFrame),
    Abort(AbortFrame),
    Aborted(AbortedFrame),
    Cancel(CancelFrame),
    Cancelled(CancelledFrame),
    Terminal(TerminalFrame),
    TerminalAck(TerminalAckFrame),
    ModelReady(ModelReadyFrame),
    ModelGone(ModelGoneFrame),
}

/// A structural violation of the v2 frame invariants.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum FrameV2Error {
    #[error("{frame} frame requires a lease_id")]
    MissingLease { frame: &'static str },
    #[error("prepare frame must not carry a lease_id")]
    UnexpectedLease,
    #[error("terminal outcome {outcome} requires an error_class")]
    MissingErrorClass { outcome: &'static str },
    #[error("completed terminal must not carry an error_class")]
    UnexpectedErrorClass,
}

impl FrameV2 {
    /// The wire `type` tag for this frame.
    pub fn type_str(&self) -> &'static str {
        match self {
            Self::Prepare(_) => "prepare",
            Self::Prepared(_) => "prepared",
            Self::Start(_) => "start",
            Self::Started(_) => "started",
            Self::Abort(_) => "abort",
            Self::Aborted(_) => "aborted",
            Self::Cancel(_) => "cancel",
            Self::Cancelled(_) => "cancelled",
            Self::Terminal(_) => "terminal",
            Self::TerminalAck(_) => "terminal_ack",
            Self::ModelReady(_) => "model_ready",
            Self::ModelGone(_) => "model_gone",
        }
    }

    /// The request scope, for request-scoped frames.
    pub fn scope(&self) -> Option<&RequestScope> {
        match self {
            Self::Prepare(f) => Some(&f.scope),
            Self::Prepared(f) => Some(&f.scope),
            Self::Start(f) => Some(&f.scope),
            Self::Started(f) => Some(&f.scope),
            Self::Abort(f) => Some(&f.scope),
            Self::Aborted(f) => Some(&f.scope),
            Self::Cancel(f) => Some(&f.scope),
            Self::Cancelled(f) => Some(&f.scope),
            Self::Terminal(f) => Some(&f.scope),
            Self::TerminalAck(f) => Some(&f.scope),
            Self::ModelReady(_) | Self::ModelGone(_) => None,
        }
    }

    /// Enforces the per-frame structural invariants that the type system
    /// leaves open: lease presence and terminal error-class coherence.
    pub fn validate(&self) -> Result<(), FrameV2Error> {
        let require_lease = |frame: &'static str, scope: &RequestScope| {
            if scope.lease_id.is_none() {
                Err(FrameV2Error::MissingLease { frame })
            } else {
                Ok(())
            }
        };
        match self {
            Self::Prepare(f) => {
                if f.scope.lease_id.is_some() {
                    return Err(FrameV2Error::UnexpectedLease);
                }
                Ok(())
            }
            Self::Prepared(f) => require_lease("prepared", &f.scope),
            Self::Start(f) => require_lease("start", &f.scope),
            Self::Started(f) => require_lease("started", &f.scope),
            Self::Abort(f) => require_lease("abort", &f.scope),
            Self::Aborted(f) => require_lease("aborted", &f.scope),
            Self::Cancel(f) => require_lease("cancel", &f.scope),
            Self::Cancelled(f) => require_lease("cancelled", &f.scope),
            Self::Terminal(f) => {
                require_lease("terminal", &f.scope)?;
                match (f.outcome, f.error_class) {
                    (TerminalOutcome::Completed, Some(_)) => {
                        Err(FrameV2Error::UnexpectedErrorClass)
                    }
                    (TerminalOutcome::Failed, None) => Err(FrameV2Error::MissingErrorClass {
                        outcome: f.outcome.as_str(),
                    }),
                    _ => Ok(()),
                }
            }
            Self::TerminalAck(f) => require_lease("terminal_ack", &f.scope),
            Self::ModelReady(_) | Self::ModelGone(_) => Ok(()),
        }
    }

    /// Decodes one v2 frame.
    pub fn decode(data: &[u8]) -> serde_json::Result<Self> {
        serde_json::from_slice(data)
    }

    /// Encodes the frame as a JSON byte vector.
    pub fn encode(&self) -> serde_json::Result<Vec<u8>> {
        serde_json::to_vec(self)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn scope_with_lease() -> RequestScope {
        RequestScope {
            job_id: JobId([1; 16]),
            attempt_id: AttemptId([2; 16]),
            lease_id: Some(LeaseId([3; 16])),
            session_epoch: SessionEpoch(7),
            coordinator_epoch: CoordinatorEpoch(9),
            dispatch_nonce: DispatchNonce([4; 16]),
            request_digest: RequestDigest([5; 32]),
        }
    }

    #[test]
    fn tagged_round_trip() {
        let frame = FrameV2::Prepared(PreparedFrame {
            scope: scope_with_lease(),
            ttl_ms: 1500,
            billable_input_tokens: 2048,
            resource: ResourceFacts {
                kv_reserved_tokens: 4096,
                kv_headroom_tokens: 65536,
                batch_running: 3,
            },
            execution: ExecutionFacts {
                engine_queue_depth: 1,
                prefill_can_start: true,
                predicted_first_content_ms: Some(220),
            },
        });
        let bytes = frame.encode().unwrap();
        let value: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(value["type"], "prepared");
        assert_eq!(value["lease_id"], "03030303-0303-0303-0303-030303030303");
        assert_eq!(value["dispatch_nonce"], "04040404040404040404040404040404");
        let back = FrameV2::decode(&bytes).unwrap();
        assert_eq!(back, frame);
        assert_eq!(back.type_str(), "prepared");
        back.validate().unwrap();
    }

    #[test]
    fn prepare_rejects_lease_and_others_require_it() {
        let mut scope = scope_with_lease();
        let prepare = FrameV2::Prepare(PrepareFrame {
            scope,
            model_id: "m".into(),
            max_output_tokens: 128,
            first_content_budget_ms: 5000,
        });
        assert_eq!(prepare.validate(), Err(FrameV2Error::UnexpectedLease));

        scope.lease_id = None;
        let start = FrameV2::Start(StartFrame { scope });
        assert_eq!(
            start.validate(),
            Err(FrameV2Error::MissingLease { frame: "start" })
        );
    }

    #[test]
    fn terminal_error_class_coherence() {
        let mut terminal = TerminalFrame {
            scope: scope_with_lease(),
            provider_id: "prov-1".into(),
            model_id: "m".into(),
            origin_session_epoch: SessionEpoch(6),
            outcome: TerminalOutcome::Failed,
            error_class: None,
            usage: TerminalUsage::default(),
            generated_tokens: 0,
            response_hash: ResponseHash::default(),
            checkpoint: RollingHashCheckpoint::default(),
            se_signature: String::new(),
        };
        assert_eq!(
            FrameV2::Terminal(terminal.clone()).validate(),
            Err(FrameV2Error::MissingErrorClass { outcome: "failed" })
        );
        terminal.outcome = TerminalOutcome::Completed;
        terminal.error_class = Some(ErrorClass::Fault);
        assert_eq!(
            FrameV2::Terminal(terminal).validate(),
            Err(FrameV2Error::UnexpectedErrorClass)
        );
    }

    #[test]
    fn model_lifecycle_round_trip() {
        let frame = FrameV2::ModelGone(ModelGoneFrame {
            model_id: "qwen-3-8b".into(),
            state_revision: 42,
        });
        let bytes = frame.encode().unwrap();
        assert_eq!(FrameV2::decode(&bytes).unwrap(), frame);
        assert!(frame.scope().is_none());
    }

    #[test]
    fn optional_fields_omitted() {
        let frame = FrameV2::Started(StartedFrame {
            scope: scope_with_lease(),
        });
        let value: serde_json::Value = serde_json::from_slice(&frame.encode().unwrap()).unwrap();
        let obj = value.as_object().unwrap();
        assert!(obj.contains_key("lease_id"));

        let no_lease = FrameV2::Prepare(PrepareFrame {
            scope: RequestScope {
                lease_id: None,
                ..scope_with_lease()
            },
            model_id: "m".into(),
            max_output_tokens: 1,
            first_content_budget_ms: 1,
        });
        let value: serde_json::Value = serde_json::from_slice(&no_lease.encode().unwrap()).unwrap();
        assert!(!value.as_object().unwrap().contains_key("lease_id"));
    }
}
