//! Explicit protocol-v2 registration negotiation and session allocation.

use serde::{Deserialize, Serialize};
use thiserror::Error;

use crate::v2::{ProtocolCapabilities, ProviderId, ProviderProcessGenerationId, SessionEpoch};

/// Coordinator response that binds one registration to a stable provider and
/// a newly allocated WebSocket-session epoch.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RegisterAcknowledgement {
    pub provider_id: ProviderId,
    pub provider_process_generation: ProviderProcessGenerationId,
    pub session_epoch: SessionEpoch,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub protocol_capabilities: Option<ProtocolCapabilities>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub coordinator_replay_fence_public_key: Option<String>,
}

/// Tagged coordinator registration response carried on the JSON control path.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type")]
pub enum RegistrationResponse {
    #[serde(rename = "register_ack")]
    RegisterAck(RegisterAcknowledgement),
}

/// A provider cannot safely allocate another session once its epoch is
/// exhausted; wrapping would make stale frames current again.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Error)]
pub enum SessionAllocationError {
    #[error("provider session epoch exhausted")]
    SessionEpochExhausted,
    #[error("negotiated v2 register ACK requires a canonical P-256 replay-fence public key")]
    InvalidCoordinatorReplayFencePublicKey,
}

/// Allocates strictly increasing session epochs for one stable provider ID.
///
/// The tracker is intended to live with the coordinator's durable provider
/// identity record. Every accepted WebSocket registration calls
/// [`Self::acknowledge`]; reconnects therefore retain `provider_id` while
/// advancing `session_epoch`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProviderSessionTracker {
    provider_id: ProviderId,
    last_session_epoch: Option<SessionEpoch>,
}

impl ProviderSessionTracker {
    #[must_use]
    pub const fn new(provider_id: ProviderId) -> Self {
        Self {
            provider_id,
            last_session_epoch: None,
        }
    }

    /// Restores the tracker from the coordinator's durable provider record.
    #[must_use]
    pub const fn resume(provider_id: ProviderId, last_session_epoch: SessionEpoch) -> Self {
        Self {
            provider_id,
            last_session_epoch: Some(last_session_epoch),
        }
    }

    #[must_use]
    pub const fn provider_id(&self) -> ProviderId {
        self.provider_id
    }

    #[must_use]
    pub const fn last_session_epoch(&self) -> Option<SessionEpoch> {
        self.last_session_epoch
    }

    /// Allocates the next session and negotiates only the explicit capability
    /// overlap. Provider binary version strings never participate.
    pub fn acknowledge(
        &mut self,
        provider_process_generation: ProviderProcessGenerationId,
        provider_capabilities: &ProtocolCapabilities,
        coordinator_capabilities: &ProtocolCapabilities,
        coordinator_replay_fence_public_key: Option<&str>,
    ) -> Result<RegisterAcknowledgement, SessionAllocationError> {
        let next_epoch = match self.last_session_epoch {
            None => SessionEpoch(1),
            Some(previous) => SessionEpoch(
                previous
                    .0
                    .checked_add(1)
                    .ok_or(SessionAllocationError::SessionEpochExhausted)?,
            ),
        };
        let protocol_capabilities = provider_capabilities
            .negotiate(coordinator_capabilities)
            .filter(ProtocolCapabilities::supports_v2);
        let coordinator_replay_fence_public_key = if protocol_capabilities.is_some() {
            let encoded = coordinator_replay_fence_public_key
                .filter(|value| replay_fence_public_key_is_valid(value))
                .ok_or(SessionAllocationError::InvalidCoordinatorReplayFencePublicKey)?;
            Some(encoded.to_owned())
        } else {
            None
        };
        let acknowledgement = RegisterAcknowledgement {
            provider_id: self.provider_id,
            provider_process_generation,
            session_epoch: next_epoch,
            protocol_capabilities,
            coordinator_replay_fence_public_key,
        };
        self.last_session_epoch = Some(next_epoch);
        Ok(acknowledgement)
    }
}

fn replay_fence_public_key_is_valid(encoded: &str) -> bool {
    use base64::{Engine, engine::general_purpose::STANDARD};

    let Ok(raw) = STANDARD.decode(encoded) else {
        return false;
    };
    raw.len() == 65 && raw.first() == Some(&0x04) && STANDARD.encode(raw) == encoded
}
