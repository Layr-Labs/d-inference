//! Per-attempt live state and wire-frame construction (plan §7.2, §10.2).
//!
//! One [`AttemptRuntime`] exists per provider dispatch. It owns the wire
//! identity (the demux key registered with the provider session), the
//! attempt key material, the v2 request scope, held preamble chunks, and
//! the accepted-chunk counters that feed the settlement checkpoint
//! (plan §10.6, §13.6).
//!
//! Wire identity convention (for provider-session integration): both v1 and
//! v2 attempts register `wire_id = attempt UUID string`. For v1 sessions the
//! same string is the `request_id` of the `inference_request` / `cancel`
//! frames, so provider echoes demux back to this attempt.

use bytes::Bytes;
use uuid::Uuid;

use darkbloom_core::ids::{AttemptId, CoordinatorEpoch, JobId, LeaseId, ProviderId, SessionEpoch};
use darkbloom_core::provider_error::ProviderErrorClass;
use darkbloom_protocol::binary::{self, BinaryFrameHeader, FrameKind};
use darkbloom_protocol::json_v1;
use darkbloom_protocol::json_v2::{
    self, AbortFrame, AbortReason, CancelFrame, FrameV2, PrepareFrame, RequestScope, StartFrame,
    TerminalAckFrame,
};

use crate::contracts::{ControlFrame, DataFrame, ProtocolGen, SessionHandle};
use crate::request_task::crypto::{AttemptCrypto, SealedBody};
use crate::request_task::terminal::TerminalReceipt;

fn v2_uuid16(bytes: &[u8; 16]) -> [u8; 16] {
    *bytes
}

pub fn v2_job(job: JobId) -> json_v2::JobId {
    json_v2::JobId(v2_uuid16(job.as_bytes()))
}

pub fn v2_attempt(attempt: AttemptId) -> json_v2::AttemptId {
    json_v2::AttemptId(v2_uuid16(attempt.as_bytes()))
}

pub fn v2_lease(lease: LeaseId) -> json_v2::LeaseId {
    json_v2::LeaseId(v2_uuid16(lease.as_bytes()))
}

/// Live state for one dispatched attempt.
pub struct AttemptRuntime {
    pub provider: ProviderId,
    pub session: SessionHandle,
    pub protocol: ProtocolGen,
    /// Demux key registered with the session (attempt UUID string).
    pub wire_id: String,
    pub crypto: AttemptCrypto,
    /// v2 request scope; `lease_id` filled once prepared.
    pub scope: RequestScope,
    pub lease: Option<LeaseId>,
    /// Role/lifecycle preamble held until first content commits
    /// (plan §9.2.7); forwarded in arrival order ahead of the committing
    /// chunk (mirrors Go held-chunk behavior).
    pub held_preamble: Vec<Bytes>,
    /// Accepted content-bearing chunks (the v1 checkpoint unit).
    pub content_chunks: u64,
    /// v2 sequence of the last chunk accepted into the consumer pipe.
    pub accepted_sequence: u64,
    /// Terminal facts held for the settlement transaction.
    pub receipt: Option<TerminalReceipt>,
    /// Absolute expiry timers, task-clock milliseconds.
    pub prepare_deadline_at: Option<darkbloom_core::time::TimestampMs>,
    pub lease_expiry_at: Option<darkbloom_core::time::TimestampMs>,
    /// Grant-time facts frozen for funding and calibration feedback.
    pub price: crate::contracts::PriceCard,
    pub beneficiary: Option<darkbloom_core::ids::AccountId>,
    /// The permit id the fleet minted for this attempt's grant; echoed
    /// verbatim in `FleetCommand::ReleasePermit` (single mint authority).
    pub permit_id: darkbloom_core::ids::PermitId,
    pub predicted_first_content: darkbloom_core::time::DurationMs,
    pub dispatched_at: darkbloom_core::time::TimestampMs,
    /// A cancel/abort frame has been submitted for this attempt (dedupes
    /// the v1 cancel backstop).
    pub cancel_sent: bool,
}

impl AttemptRuntime {
    pub fn new(
        id: AttemptId,
        provider: ProviderId,
        session: SessionHandle,
        crypto: AttemptCrypto,
        scope: RequestScope,
    ) -> Self {
        let protocol = session.protocol;
        Self {
            provider,
            session,
            protocol,
            wire_id: id.get().to_string(),
            crypto,
            scope,
            lease: None,
            held_preamble: Vec::new(),
            content_chunks: 0,
            accepted_sequence: 0,
            receipt: None,
            prepare_deadline_at: None,
            lease_expiry_at: None,
            price: crate::contracts::PriceCard::ZERO,
            beneficiary: None,
            permit_id: darkbloom_core::ids::PermitId::new(Uuid::nil()),
            predicted_first_content: darkbloom_core::time::DurationMs::ZERO,
            dispatched_at: darkbloom_core::time::TimestampMs::new(0),
            cancel_sent: false,
        }
    }

    /// Records a prepared lease into the scope for later request-scoped
    /// frames.
    pub fn record_lease(&mut self, lease: LeaseId) {
        self.lease = Some(lease);
        self.scope.lease_id = Some(v2_lease(lease));
    }

    fn scoped(&self) -> RequestScope {
        self.scope
    }

    /// The v2 prepare data-lane frame: JSON control part plus the binary
    /// encrypted body (plan §15.3).
    pub fn v2_prepare_frame(
        &self,
        model_id: &str,
        max_output_tokens: u64,
        first_content_budget_ms: u64,
        sealed: &SealedBody,
    ) -> Result<DataFrame, binary::BinaryFrameError> {
        let mut scope = self.scoped();
        scope.lease_id = None; // prepare carries no lease (frame invariant)
        let header = BinaryFrameHeader {
            kind: FrameKind::PrepareBody,
            job_id: scope.job_id,
            attempt_id: scope.attempt_id,
            lease_id: None,
            session_epoch: scope.session_epoch,
            coordinator_epoch: scope.coordinator_epoch,
            dispatch_nonce: scope.dispatch_nonce,
            request_digest: scope.request_digest,
            sequence: 0,
            cumulative_completion_tokens: 0,
        };
        let body = binary::encode(&header, &sealed.ciphertext)?;
        Ok(DataFrame::V2Prepare {
            frame: Box::new(FrameV2::Prepare(PrepareFrame {
                scope,
                model_id: model_id.to_owned(),
                max_output_tokens,
                first_content_budget_ms,
            })),
            binary_body: Some(body),
        })
    }

    /// The v1 `inference_request` data-lane frame, body pre-encrypted.
    pub fn v1_inference_request(&self, sealed: &SealedBody) -> DataFrame {
        let msg = json_v1::InferenceRequestMessage {
            request_id: self.wire_id.clone(),
            encrypted_body: Some(sealed.v1_payload()),
            ..Default::default()
        };
        let bytes = serde_json::to_vec(&msg).unwrap_or_default();
        DataFrame::V1InferenceRequest(Bytes::from(bytes))
    }

    pub fn start_frame(&self) -> ControlFrame {
        ControlFrame::V2(Box::new(FrameV2::Start(StartFrame {
            scope: self.scoped(),
        })))
    }

    pub fn abort_frame(&self, reason: AbortReason) -> ControlFrame {
        match self.protocol {
            ProtocolGen::V2 => ControlFrame::V2(Box::new(FrameV2::Abort(AbortFrame {
                scope: self.scoped(),
                reason,
            }))),
            // v1 has no abort; cancel is the only pre-terminal stop signal.
            ProtocolGen::V1 => ControlFrame::V1Cancel {
                request_id: self.wire_id.clone(),
            },
        }
    }

    pub fn cancel_frame(&self) -> ControlFrame {
        match self.protocol {
            ProtocolGen::V2 => ControlFrame::V2(Box::new(FrameV2::Cancel(CancelFrame {
                scope: self.scoped(),
            }))),
            ProtocolGen::V1 => ControlFrame::V1Cancel {
                request_id: self.wire_id.clone(),
            },
        }
    }

    /// The terminal acknowledgement sent only after the durable disposition
    /// committed (plan §12.8).
    pub fn terminal_ack_frame(
        &self,
        terminal_scope: RequestScope,
        digest: [u8; 32],
        disposition: json_v2::AckDisposition,
    ) -> ControlFrame {
        ControlFrame::V2(Box::new(FrameV2::TerminalAck(TerminalAckFrame {
            scope: terminal_scope,
            terminal_digest: json_v2::TerminalDigest(digest),
            disposition,
        })))
    }
}

/// Builds the v2 request scope for a fresh attempt: full identity and
/// fencing set (plan §10.2) with a random dispatch nonce.
pub fn new_scope(
    job: JobId,
    attempt: AttemptId,
    session_epoch: SessionEpoch,
    coordinator_epoch: CoordinatorEpoch,
    request_digest: json_v2::RequestDigest,
) -> RequestScope {
    let mut nonce = [0u8; 16];
    rand::RngCore::fill_bytes(&mut rand::rngs::OsRng, &mut nonce);
    RequestScope {
        job_id: v2_job(job),
        attempt_id: v2_attempt(attempt),
        lease_id: None,
        session_epoch: json_v2::SessionEpoch(session_epoch.get()),
        coordinator_epoch: json_v2::CoordinatorEpoch(coordinator_epoch.get()),
        dispatch_nonce: json_v2::DispatchNonce(nonce),
        request_digest,
    }
}

/// Maps a v2 structured error class to the core class (1:1).
pub fn core_error_class(class: json_v2::ErrorClass) -> ProviderErrorClass {
    match class {
        json_v2::ErrorClass::InvalidRequest => ProviderErrorClass::InvalidRequest,
        json_v2::ErrorClass::Capacity => ProviderErrorClass::Capacity,
        json_v2::ErrorClass::ModelNotReady => ProviderErrorClass::ModelNotReady,
        json_v2::ErrorClass::Draining => ProviderErrorClass::Draining,
        json_v2::ErrorClass::Cancelled => ProviderErrorClass::Cancelled,
        json_v2::ErrorClass::Fault => ProviderErrorClass::Fault,
        json_v2::ErrorClass::Security => ProviderErrorClass::Security,
    }
}

/// Classifies a v1 `inference_error` into the typed class the reducer
/// consumes (plan §10.5). v1 has no structured class, so this is the one
/// place status-code mapping lives; message text is used ONLY for the
/// well-known draining marker string.
pub fn classify_v1_error(status_code: u16, message: &str) -> ProviderErrorClass {
    if message.contains(json_v1::PROVIDER_DRAINING_FOR_UPDATE) {
        return ProviderErrorClass::Draining;
    }
    match status_code {
        400 | 413 | 422 => ProviderErrorClass::InvalidRequest,
        404 => ProviderErrorClass::ModelNotReady,
        409 | 429 | 503 => ProviderErrorClass::Capacity,
        _ => ProviderErrorClass::Fault,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn v1_error_classification() {
        assert_eq!(
            classify_v1_error(400, "bad"),
            ProviderErrorClass::InvalidRequest
        );
        assert_eq!(
            classify_v1_error(404, "no model"),
            ProviderErrorClass::ModelNotReady
        );
        assert_eq!(classify_v1_error(429, "busy"), ProviderErrorClass::Capacity);
        assert_eq!(classify_v1_error(500, "boom"), ProviderErrorClass::Fault);
        assert_eq!(
            classify_v1_error(500, json_v1::PROVIDER_DRAINING_FOR_UPDATE),
            ProviderErrorClass::Draining
        );
    }
}
