use serde::{Deserialize, Serialize};

use crate::v2::{
    identity::{AttemptIdentity, ProviderSessionIdentity},
    terminal::{Digest, ProviderTerminal},
};

/// Coordinator request to validate input and reserve a non-generating lease.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Prepare {
    #[serde(flatten)]
    pub identity: AttemptIdentity,
    pub model: String,
    pub request_digest: Digest,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub body: Option<serde_json::Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub encrypted_body: Option<String>,
}

/// Provider response containing the exact prepared execution facts.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Prepared {
    #[serde(flatten)]
    pub identity: AttemptIdentity,
    pub lease_ttl_ms: u64,
    pub prompt_tokens: u64,
    pub max_output_tokens: u64,
    pub engine_queue_depth: u32,
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

/// Tagged coordinator-to-provider v2 control messages.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type")]
pub enum CoordinatorControlMessage {
    #[serde(rename = "prepare")]
    Prepare(Prepare),
    #[serde(rename = "start")]
    Start(Start),
    #[serde(rename = "abort")]
    Abort(Abort),
    #[serde(rename = "cancel")]
    Cancel(Cancel),
    #[serde(rename = "terminal_ack")]
    TerminalAck(TerminalAck),
}

/// Tagged provider-to-coordinator v2 control messages.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type")]
pub enum ProviderControlMessage {
    #[serde(rename = "prepared")]
    Prepared(Prepared),
    #[serde(rename = "start_ack", alias = "started")]
    StartAck(StartAck),
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
pub type AbortMessage = Abort;
pub type AbortedMessage = AbortAck;
pub type CancelMessage = Cancel;
pub type CancelledMessage = CancelAck;
pub type TerminalAckMessage = TerminalAck;
pub type StructuredErrorMessage = StructuredError;
pub type ModelReadyMessage = ModelReady;
pub type ModelGoneMessage = ModelGone;
