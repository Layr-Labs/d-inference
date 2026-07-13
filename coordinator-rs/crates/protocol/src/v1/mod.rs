//! Typed compatibility model for the deployed JSON WebSocket protocol.

pub mod inference;
pub mod model;
pub mod registration;
pub mod trust;

use serde::{Deserialize, Deserializer, Serialize, Serializer};

use crate::{
    error::ProtocolError,
    raw_json::{RegistrationSignedBytes, registration_signed_bytes},
};

pub use inference::*;
pub use model::*;
pub use registration::*;
pub use trust::*;

/// JSON number that preserves whether the wire used an integer or floating
/// representation while still rejecting non-numeric values.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(transparent)]
pub struct JsonNumber(pub serde_json::Number);

impl JsonNumber {
    #[must_use]
    pub fn as_f64(&self) -> Option<f64> {
        self.0.as_f64()
    }

    #[must_use]
    pub fn is_zero(&self) -> bool {
        self.0.as_i64() == Some(0) || self.0.as_u64() == Some(0) || self.0.as_f64() == Some(0.0)
    }
}

impl Default for JsonNumber {
    fn default() -> Self {
        Self(serde_json::Number::from(0))
    }
}

/// Three-state field used where omitted and explicit JSON `null` are distinct.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub enum OptionalNullable<T> {
    #[default]
    Missing,
    Null,
    Value(T),
}

impl<T> OptionalNullable<T> {
    #[must_use]
    pub const fn is_missing(&self) -> bool {
        matches!(self, Self::Missing)
    }

    #[must_use]
    pub const fn is_null(&self) -> bool {
        matches!(self, Self::Null)
    }

    #[must_use]
    pub const fn as_ref(&self) -> OptionalNullable<&T> {
        match self {
            Self::Missing => OptionalNullable::Missing,
            Self::Null => OptionalNullable::Null,
            Self::Value(value) => OptionalNullable::Value(value),
        }
    }
}

impl<T: Serialize> Serialize for OptionalNullable<T> {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        match self {
            Self::Missing | Self::Null => serializer.serialize_none(),
            Self::Value(value) => value.serialize(serializer),
        }
    }
}

impl<'de, T: Deserialize<'de>> Deserialize<'de> for OptionalNullable<T> {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        Option::<T>::deserialize(deserializer).map(|value| match value {
            Some(value) => Self::Value(value),
            None => Self::Null,
        })
    }
}

pub type FieldPresence<T> = OptionalNullable<T>;

/// Every committed provider-to-coordinator protocol-v1 message.
#[derive(Debug, Serialize, Deserialize)]
#[serde(tag = "type")]
pub enum ProviderMessage {
    #[serde(rename = "register")]
    Register(Registration),
    #[serde(rename = "heartbeat")]
    Heartbeat(Heartbeat),
    #[serde(rename = "inference_accepted")]
    InferenceAccepted(InferenceAccepted),
    #[serde(rename = "inference_response_chunk")]
    InferenceResponseChunk(InferenceResponseChunk),
    #[serde(rename = "inference_complete")]
    InferenceComplete(InferenceComplete),
    #[serde(rename = "inference_error")]
    InferenceError(InferenceError),
    #[serde(rename = "attestation_response")]
    AttestationResponse(AttestationResponse),
    #[serde(rename = "code_attestation_response")]
    CodeAttestationResponse(CodeAttestationResponse),
    #[serde(rename = "load_model_status")]
    LoadModelStatus(LoadModelStatus),
    #[serde(rename = "prefetch_model_status")]
    PrefetchModelStatus(PrefetchModelStatus),
    #[serde(rename = "models_update")]
    ModelsUpdate(ModelsUpdate),
}

impl ProviderMessage {
    #[must_use]
    pub const fn message_type(&self) -> &'static str {
        match self {
            Self::Register(_) => "register",
            Self::Heartbeat(_) => "heartbeat",
            Self::InferenceAccepted(_) => "inference_accepted",
            Self::InferenceResponseChunk(_) => "inference_response_chunk",
            Self::InferenceComplete(_) => "inference_complete",
            Self::InferenceError(_) => "inference_error",
            Self::AttestationResponse(_) => "attestation_response",
            Self::CodeAttestationResponse(_) => "code_attestation_response",
            Self::LoadModelStatus(_) => "load_model_status",
            Self::PrefetchModelStatus(_) => "prefetch_model_status",
            Self::ModelsUpdate(_) => "models_update",
        }
    }
}

/// Every committed coordinator-to-provider protocol-v1 message.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type")]
pub enum CoordinatorMessage {
    #[serde(rename = "inference_request")]
    InferenceRequest(InferenceRequest),
    #[serde(rename = "cancel")]
    Cancel(Cancel),
    #[serde(rename = "attestation_challenge")]
    AttestationChallenge(AttestationChallenge),
    #[serde(rename = "runtime_status")]
    RuntimeStatus(RuntimeStatus),
    #[serde(rename = "load_model")]
    LoadModel(LoadModel),
    #[serde(rename = "prefetch_model")]
    PrefetchModel(PrefetchModel),
    #[serde(rename = "desired_models")]
    DesiredModels(DesiredModels),
    #[serde(rename = "trust_status")]
    TrustStatus(TrustStatus),
}

impl CoordinatorMessage {
    #[must_use]
    pub const fn message_type(&self) -> &'static str {
        match self {
            Self::InferenceRequest(_) => "inference_request",
            Self::Cancel(_) => "cancel",
            Self::AttestationChallenge(_) => "attestation_challenge",
            Self::RuntimeStatus(_) => "runtime_status",
            Self::LoadModel(_) => "load_model",
            Self::PrefetchModel(_) => "prefetch_model",
            Self::DesiredModels(_) => "desired_models",
            Self::TrustStatus(_) => "trust_status",
        }
    }
}

/// Typed provider frame plus signed slices borrowed from its original bytes.
#[derive(Debug)]
pub struct ParsedProviderMessage<'a> {
    pub message: ProviderMessage,
    pub signed_registration: RegistrationSignedBytes<'a>,
}

#[derive(Deserialize)]
struct TypeEnvelope<'a> {
    #[serde(rename = "type")]
    message_type: &'a str,
}

/// Extracts signed raw values first, rejects unknown discriminators, and only
/// then performs typed parsing.
pub fn parse_provider_message(wire: &[u8]) -> Result<ParsedProviderMessage<'_>, ProtocolError> {
    let signed_registration = registration_signed_bytes(wire)?;
    let envelope: TypeEnvelope<'_> = serde_json::from_slice(wire)?;
    if !matches!(
        envelope.message_type,
        "register"
            | "heartbeat"
            | "inference_accepted"
            | "inference_response_chunk"
            | "inference_complete"
            | "inference_error"
            | "attestation_response"
            | "code_attestation_response"
            | "load_model_status"
            | "prefetch_model_status"
            | "models_update"
    ) {
        return Err(ProtocolError::UnknownMessageType(
            envelope.message_type.to_owned(),
        ));
    }
    let message = serde_json::from_slice(wire)?;
    if let ProviderMessage::Register(registration) = &message {
        registration.validate()?;
    }
    Ok(ParsedProviderMessage {
        message,
        signed_registration,
    })
}

pub fn parse_coordinator_message(wire: &[u8]) -> Result<CoordinatorMessage, ProtocolError> {
    let envelope: TypeEnvelope<'_> = serde_json::from_slice(wire)?;
    if !matches!(
        envelope.message_type,
        "inference_request"
            | "cancel"
            | "attestation_challenge"
            | "runtime_status"
            | "load_model"
            | "prefetch_model"
            | "desired_models"
            | "trust_status"
    ) {
        return Err(ProtocolError::UnknownMessageType(
            envelope.message_type.to_owned(),
        ));
    }
    Ok(serde_json::from_slice(wire)?)
}

pub type ProviderToCoordinatorMessage = ProviderMessage;
pub type CoordinatorToProviderMessage = CoordinatorMessage;
