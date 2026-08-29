//! The tagged [`FrameV2`] enum: dispatch, structural validation, and codec.

use serde::{Deserialize, Serialize};

use super::abort_cancel::{AbortFrame, AbortedFrame, CancelFrame, CancelledFrame};
use super::model_lifecycle::{ModelGoneFrame, ModelReadyFrame};
use super::prepare::{PrepareFrame, PreparedFrame};
use super::scope::RequestScope;
use super::start::{StartFrame, StartedFrame};
use super::terminal::{TerminalAckFrame, TerminalFrame, TerminalOutcome};

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
    use super::super::prepare::{ExecutionFacts, ResourceFacts};
    use super::super::terminal::{RollingHashCheckpoint, TerminalUsage};
    use super::*;
    use crate::json_v2::error_class::ErrorClass;
    use crate::json_v2::ids::{
        AttemptId, CoordinatorEpoch, DispatchNonce, JobId, LeaseId, RequestDigest, ResponseHash,
        SessionEpoch,
    };

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
