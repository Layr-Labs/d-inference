use serde::{Deserialize, Serialize};
use thiserror::Error;

use crate::{
    v1::EncryptedPayload,
    v2::{
        identity::{
            AttemptIdentity, ProviderId, ProviderProcessGenerationId, ProviderSessionIdentity,
            ReplayFenceProofId, SessionEpoch,
        },
        terminal::{Digest, ProviderTerminal, TerminalSignature},
    },
};

const PREPARE_PAYLOAD_DIGEST_DOMAIN: &[u8] = b"darkbloom.protocol.v2.prepare-payload\0";

#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum PrepareValidationError {
    #[error("encrypted prepare payload uses invalid or non-canonical base64")]
    InvalidEncryptedPayload,
}

/// Coordinator request to validate input and reserve a non-generating lease.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Prepare {
    #[serde(flatten)]
    pub identity: AttemptIdentity,
    pub model: String,
    pub request_digest: Digest,
    pub encrypted_body: EncryptedPayload,
}

impl Prepare {
    pub fn encrypted_payload_digest(
        payload: &EncryptedPayload,
    ) -> Result<Digest, PrepareValidationError> {
        use base64::{Engine, engine::general_purpose::STANDARD};

        let public_key = STANDARD
            .decode(&payload.ephemeral_public_key)
            .map_err(|_| PrepareValidationError::InvalidEncryptedPayload)?;
        let ciphertext = STANDARD
            .decode(&payload.ciphertext)
            .map_err(|_| PrepareValidationError::InvalidEncryptedPayload)?;
        if public_key.len() != 32
            || STANDARD.encode(&public_key) != payload.ephemeral_public_key
            || STANDARD.encode(&ciphertext) != payload.ciphertext
        {
            return Err(PrepareValidationError::InvalidEncryptedPayload);
        }

        let mut input = Vec::with_capacity(
            PREPARE_PAYLOAD_DIGEST_DOMAIN.len() + public_key.len() + ciphertext.len(),
        );
        input.extend_from_slice(PREPARE_PAYLOAD_DIGEST_DOMAIN);
        input.extend_from_slice(&public_key);
        input.extend_from_slice(&ciphertext);
        Ok(Digest::of(&input))
    }
}

/// Provider response containing the exact prepared execution facts.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Prepared {
    #[serde(flatten)]
    pub identity: AttemptIdentity,
    pub model: String,
    pub request_digest: Digest,
    pub lease_ttl_ms: u64,
    pub prompt_tokens: u64,
    pub max_output_tokens: u64,
    pub engine_queue_depth: u32,
    pub reserved_kv_bytes: u64,
    pub reserved_media_bytes: u64,
    pub prefill_can_begin: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub estimated_prefill_ms: Option<u64>,
}

/// Idempotent authorization to begin generation for a prepared lease.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Start {
    #[serde(flatten)]
    pub identity: AttemptIdentity,
}

/// Provider acknowledgement that start authorization is durable.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct StartAck {
    #[serde(flatten)]
    pub identity: AttemptIdentity,
}

/// Reconciliation query for one exact historical attempt and lease.
///
/// The stable provider may answer this query on a newer process/session, but
/// every field in the queried identity remains the historical start identity.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct QueryAttempt {
    #[serde(flatten)]
    pub identity: AttemptIdentity,
}

/// Provider's durable knowledge of one exact historical attempt.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AttemptStatusState {
    Unknown,
    Prepared,
    Started,
    Terminal,
}

/// Reconciliation response derived from the provider's prepared state,
/// funded-start journal, terminal journal, and abort tombstones.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AttemptStatus {
    #[serde(flatten)]
    pub identity: AttemptIdentity,
    pub state: AttemptStatusState,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub terminal_digest: Option<Digest>,
}

impl AttemptStatus {
    #[must_use]
    pub const fn digest_shape_is_valid(&self) -> bool {
        matches!(
            (self.state, self.terminal_digest),
            (AttemptStatusState::Terminal, Some(_))
                | (
                    AttemptStatusState::Unknown
                        | AttemptStatusState::Prepared
                        | AttemptStatusState::Started,
                    None
                )
        )
    }
}

/// Idempotent tombstone for a lease that has not started.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Abort {
    #[serde(flatten)]
    pub identity: AttemptIdentity,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
}

/// Provider acknowledgement that an abort is durable and quiescent.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AbortAck {
    #[serde(flatten)]
    pub identity: AttemptIdentity,
}

/// Idempotent cancellation for an attempt that may have started.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Cancel {
    #[serde(flatten)]
    pub identity: AttemptIdentity,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
}

/// Provider acknowledgement that a cancelled attempt is quiescent.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CancelAck {
    #[serde(flatten)]
    pub identity: AttemptIdentity,
}

/// Coordinator disposition after durable terminal receipt.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TerminalDisposition {
    Settled,
    Released,
    SettledReviewed,
    ReleasedReviewed,
    Late,
    Conflict,
}

/// Coordinator acknowledgement of durable terminal processing.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TerminalAck {
    #[serde(flatten)]
    pub identity: AttemptIdentity,
    pub terminal_digest: Digest,
    pub disposition: TerminalDisposition,
}

/// Stable machine-readable provider error classes.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum StructuredErrorClass {
    InvalidRequest,
    Capacity,
    ModelNotReady,
    Draining,
    Cancelled,
    Fault,
    Security,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct StructuredError {
    #[serde(flatten)]
    pub identity: AttemptIdentity,
    pub class: StructuredErrorClass,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub message: Option<String>,
}

/// Signed coordinator authority proving that delayed starts through one
/// provider-process session epoch can no longer arrive. Providers persist this
/// proof before reclaiming any covered abort tombstones.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CoordinatorReplayFenceProof {
    pub proof_id: ReplayFenceProofId,
    pub provider_id: ProviderId,
    pub provider_process_generation: ProviderProcessGenerationId,
    pub through_session_epoch: SessionEpoch,
    pub coordinator_revision: u64,
    pub proof_digest: Digest,
    pub coordinator_signature: TerminalSignature,
}

/// Provider acknowledgement that one signed replay fence was durably applied.
///
/// Identity is provider/process scoped because replay proofs deliberately
/// survive WebSocket replacement; the proof ID selects the exact journal row.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReplayFenceAck {
    pub proof_id: ReplayFenceProofId,
    pub provider_id: ProviderId,
    pub provider_process_generation: ProviderProcessGenerationId,
}

impl CoordinatorReplayFenceProof {
    #[must_use]
    pub fn computed_digest(&self) -> Digest {
        let canonical = format!(
            concat!(
                r#"{{"coordinator_revision":{},"proof_id":"{}","provider_id":"{}","#,
                r#""provider_process_generation":"{}","schema":"darkbloom.coordinator-replay-fence-proof.v1","#,
                r#""through_session_epoch":{}}}"#
            ),
            self.coordinator_revision,
            self.proof_id,
            self.provider_id,
            self.provider_process_generation,
            self.through_session_epoch.0,
        );
        Digest::of(canonical.as_bytes())
    }

    #[must_use]
    pub fn digest_is_valid(&self) -> bool {
        self.proof_digest == self.computed_digest()
    }
}

/// Tagged coordinator-to-provider v2 control messages.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type")]
pub enum CoordinatorControlMessage {
    #[serde(rename = "prepare")]
    Prepare(Prepare),
    #[serde(rename = "start")]
    Start(Start),
    #[serde(rename = "query_attempt")]
    QueryAttempt(QueryAttempt),
    #[serde(rename = "abort")]
    Abort(Abort),
    #[serde(rename = "cancel")]
    Cancel(Cancel),
    #[serde(rename = "terminal_ack")]
    TerminalAck(TerminalAck),
    #[serde(rename = "coordinator_replay_fence")]
    CoordinatorReplayFence(CoordinatorReplayFenceProof),
}

/// Tagged provider-to-coordinator v2 control messages.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type")]
pub enum ProviderControlMessage {
    #[serde(rename = "prepared")]
    Prepared(Prepared),
    #[serde(rename = "start_ack", alias = "started")]
    StartAck(StartAck),
    #[serde(rename = "attempt_status")]
    AttemptStatus(AttemptStatus),
    #[serde(rename = "abort_ack", alias = "aborted")]
    AbortAck(AbortAck),
    #[serde(rename = "cancel_ack", alias = "cancelled")]
    CancelAck(CancelAck),
    #[serde(rename = "provider_terminal")]
    Terminal(ProviderTerminal),
    #[serde(rename = "structured_error")]
    StructuredError(StructuredError),
    #[serde(rename = "model_ready")]
    ModelReady(ModelReady),
    #[serde(rename = "model_gone")]
    ModelGone(ModelGone),
    #[serde(rename = "replay_fence_ack")]
    ReplayFenceAck(ReplayFenceAck),
}

/// Provider model became locally verified and available.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ModelReady {
    #[serde(flatten)]
    pub identity: ProviderSessionIdentity,
    pub model: String,
    pub state_revision: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub weight_hash: Option<String>,
}

/// Provider model ceased to be locally available.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ModelGone {
    #[serde(flatten)]
    pub identity: ProviderSessionIdentity,
    pub model: String,
    pub state_revision: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
}

pub type PrepareMessage = Prepare;
pub type PreparedMessage = Prepared;
pub type StartMessage = Start;
pub type StartedMessage = StartAck;
pub type QueryAttemptMessage = QueryAttempt;
pub type AttemptStatusMessage = AttemptStatus;
pub type AbortMessage = Abort;
pub type AbortedMessage = AbortAck;
pub type CancelMessage = Cancel;
pub type CancelledMessage = CancelAck;
pub type TerminalAckMessage = TerminalAck;
pub type StructuredErrorMessage = StructuredError;
pub type ModelReadyMessage = ModelReady;
pub type ModelGoneMessage = ModelGone;
pub type CoordinatorReplayFenceProofMessage = CoordinatorReplayFenceProof;
pub type ReplayFenceAckMessage = ReplayFenceAck;
