//! Optional sender-to-coordinator sealed request envelope.

use serde::{Deserialize, Serialize};

use crate::{
    crypto::{BoxPayload, open_box, seal_box},
    error::CryptoError,
};

/// Current request wire shape. Unknown additive JSON fields remain compatible
/// through Serde's default field handling.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SenderSealEnvelope {
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub kid: String,
    pub ephemeral_public_key: String,
    /// Standard-base64 `nonce[24] || NaCl Box ciphertext`.
    pub ciphertext: String,
}

impl From<BoxPayload> for SenderSealEnvelope {
    fn from(payload: BoxPayload) -> Self {
        Self {
            kid: String::new(),
            ephemeral_public_key: payload.ephemeral_public_key,
            ciphertext: payload.ciphertext,
        }
    }
}

impl From<&SenderSealEnvelope> for BoxPayload {
    fn from(envelope: &SenderSealEnvelope) -> Self {
        Self {
            ephemeral_public_key: envelope.ephemeral_public_key.clone(),
            ciphertext: envelope.ciphertext.clone(),
        }
    }
}

pub fn seal_sender_request(
    kid: impl Into<String>,
    coordinator_public_key: &[u8; 32],
    plaintext: &[u8],
) -> Result<SenderSealEnvelope, CryptoError> {
    let mut envelope = SenderSealEnvelope::from(seal_box(coordinator_public_key, plaintext)?);
    envelope.kid = kid.into();
    Ok(envelope)
}

pub fn open_sender_request(
    coordinator_private_key: &[u8; 32],
    envelope: &SenderSealEnvelope,
) -> Result<Vec<u8>, CryptoError> {
    open_box(coordinator_private_key, &BoxPayload::from(envelope))
}

pub type SealedRequestEnvelope = SenderSealEnvelope;
pub use open_sender_request as open_sender_seal;
pub use seal_sender_request as sender_seal;
