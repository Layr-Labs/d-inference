//! Registration-frame handling: first-frame decode, protocol-v2 detection,
//! attestation verification, and stable provider identity (plan §7.4,
//! §9.1.1, §10.1).

use axum::extract::ws::{Message, WebSocket};
use serde::Deserialize;
use sha2::{Digest, Sha256};
use uuid::Uuid;

use darkbloom_core::ids::{ModelId, ProviderId};
use darkbloom_protocol::json_v1::{msg_type, peek_type, RegisterMessage};
use darkbloom_protocol::json_v2::{RegistrationV2, REGISTER_EXTENSION_KEY};

use crate::contracts::{ProtocolGen, RegistrationSummary};
use crate::trust::RegistrationVerdict;

use super::heartbeat::ProviderStatics;
use super::SessionDeps;

/// Namespace for stable provider identity derivation. Fixed forever: change
/// it and every provider on the network gets a new identity.
pub const PROVIDER_ID_NAMESPACE: Uuid = Uuid::from_u128(0xd1cb_100f_7a1d_4b0e_9f3a_5c2e_8d47_a916);

/// Derives the stable [`ProviderId`] from the wire identity string.
///
/// Contract note: the plan calls for UUIDv5, but the frozen workspace
/// manifest enables only the uuid crate's `v4`/`serde` features (no `v5`,
/// and SHA-1 is not otherwise available). This derives the same property —
/// a deterministic, namespaced, collision-resistant UUID — via
/// SHA-256(namespace ‖ name) truncated to 16 bytes with RFC 9562 version 8
/// ("custom") and variant bits. Stronger hash, identical stability
/// semantics; reported for the integration phase.
#[must_use]
pub fn stable_provider_id(stable_identity: &str) -> ProviderId {
    let mut hasher = Sha256::new();
    hasher.update(PROVIDER_ID_NAMESPACE.as_bytes());
    hasher.update(stable_identity.as_bytes());
    let digest = hasher.finalize();
    let mut bytes = [0u8; 16];
    bytes.copy_from_slice(&digest[..16]);
    bytes[6] = (bytes[6] & 0x0f) | 0x80; // version 8 (custom, name-based)
    bytes[8] = (bytes[8] & 0x3f) | 0x80; // RFC 9562 variant
    ProviderId::new(Uuid::from_bytes(bytes))
}

/// Stable identity preference order, mirroring Go
/// `stableProviderIdentityLocked` (registry/health_ejection.go): attested
/// serial, then attested SE public key, then the registered X25519 key.
/// The last resort is a per-connection random identity — the same "no
/// stable identity" degradation Go has (account linkage, the Go `acct:`
/// tier, is resolved by the store integration, not the session).
fn stable_identity_string(verdict: &RegistrationVerdict, x25519_b64: &str) -> String {
    if let Some(serial) = &verdict.serial_number {
        return format!("serial:{serial}");
    }
    if let Some(se_key) = &verdict.se_public_key {
        return format!("sekey:{se_key}");
    }
    if !x25519_b64.is_empty() {
        return format!("x25519:{x25519_b64}");
    }
    format!("conn:{}", Uuid::new_v4())
}

#[derive(Debug, thiserror::Error)]
pub(crate) enum RegistrationError {
    #[error("timed out waiting for registration frame")]
    Timeout,
    #[error("socket closed before registration")]
    SocketClosed,
    #[error("registration frame exceeds size limit")]
    TooLarge,
    #[error("first frame is not a register message")]
    NotRegister,
    #[error("malformed register frame")]
    Decode,
}

pub(crate) struct RegistrationOutcome {
    pub summary: RegistrationSummary,
    pub verdict: RegistrationVerdict,
    pub statics: ProviderStatics,
}

/// Sidecar decode of the v2 registration extension riding inside the v1
/// register frame under [`REGISTER_EXTENSION_KEY`] (plan §10.1).
#[derive(Deserialize, Default)]
struct RegisterExtension {
    protocol_v2: Option<RegistrationV2>,
}

/// Reads and verifies the registration frame. Consumes frames until the
/// first text frame (control frames are tolerated), bounded by the
/// registration deadline.
pub(crate) async fn register(
    socket: &mut WebSocket,
    deps: &SessionDeps,
) -> Result<RegistrationOutcome, RegistrationError> {
    let data = read_first_text(socket, deps).await?;
    if peek_type(&data) != Some(msg_type::REGISTER) {
        // The scanner is conservative; confirm via a full decode before
        // rejecting so escaped-type frames still register.
        let full = darkbloom_protocol::json_v1::ProviderMessage::decode(&data);
        if !matches!(
            full,
            Ok(darkbloom_protocol::json_v1::ProviderMessage::Register(_))
        ) {
            return Err(RegistrationError::NotRegister);
        }
    }
    let register: RegisterMessage =
        serde_json::from_slice(&data).map_err(|_| RegistrationError::Decode)?;
    let extension: RegisterExtension = serde_json::from_slice(&data).unwrap_or_default();
    let v2 = extension.protocol_v2;
    debug_assert_eq!(REGISTER_EXTENSION_KEY, "protocol_v2");

    // Verify what identity evidence is present (SE attestation is optional
    // at the pilot trust level; the trust floor decides routability).
    let attestation_raw = register
        .attestation
        .as_ref()
        .map(|raw| raw.get().to_owned());
    let verdict = deps
        .trust
        .verify_registration(attestation_raw, register.public_key.clone())
        .await;

    let identity = stable_identity_string(&verdict, &register.public_key);
    let provider = stable_provider_id(&identity);
    let protocol = match &v2 {
        Some(ext) if ext.protocol_major == 2 => ProtocolGen::V2,
        _ => ProtocolGen::V1,
    };

    let models: Vec<ModelId> = register
        .models
        .iter()
        .flatten()
        .map(|m| ModelId::new(m.id.clone()))
        .collect();
    let statics = ProviderStatics {
        supports_vision: register.models.iter().flatten().any(|m| m.is_vision),
        // Pilot scope: every dual-stack provider release meets the tools
        // capability floor; media routing is not in the pilot surface.
        supports_tools: true,
        supports_media: false,
    };

    // Marker capabilities ride the frozen capabilities seam: the hardware
    // class (calibration key, plan §11.4) and the trait-support flags the
    // fleet's hard gates read before the first heartbeat.
    let mut capabilities: Vec<String> = v2
        .as_ref()
        .map(|ext| ext.capabilities.iter().cloned().collect())
        .unwrap_or_default();
    capabilities.push(format!(
        "{}{}",
        crate::fleet::HW_CLASS_CAPABILITY_PREFIX,
        hardware_class(&register)
    ));
    if statics.supports_vision {
        capabilities.push(crate::fleet::SUPPORTS_VISION_CAPABILITY.to_owned());
    }
    if statics.supports_tools {
        capabilities.push(crate::fleet::SUPPORTS_TOOLS_CAPABILITY.to_owned());
    }
    if statics.supports_media {
        capabilities.push(crate::fleet::SUPPORTS_MEDIA_CAPABILITY.to_owned());
    }

    let summary = RegistrationSummary {
        provider,
        wire_identity: identity,
        protocol,
        version: register.version.clone(),
        public_key_b64: register.public_key.clone(),
        models,
        // Beneficiary (auth token -> account) resolution is a store seam
        // wired at integration; paid routing stays gated until then.
        beneficiary: None,
        capabilities,
    };

    tracing::info!(
        provider = %provider,
        protocol = ?protocol,
        version = %summary.version,
        models = summary.models.len(),
        "provider registered"
    );

    Ok(RegistrationOutcome {
        summary,
        verdict,
        statics,
    })
}

/// Calibration hardware class: chip family + tier (Go `chipClassKey`
/// semantics — a fast tier must never lend its rate to a slow one).
fn hardware_class(register: &RegisterMessage) -> String {
    let hw = &register.hardware;
    let family = pick(&hw.chip_family, &hw.chip_name);
    let tier = &hw.chip_tier;
    let raw = if tier.is_empty() {
        family.to_owned()
    } else {
        format!("{family}-{tier}")
    };
    let class: String = raw
        .to_ascii_lowercase()
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() { c } else { '-' })
        .collect();
    if class.is_empty() {
        "unknown".to_owned()
    } else {
        class
    }
}

fn pick<'a>(primary: &'a str, fallback: &'a str) -> &'a str {
    if primary.is_empty() {
        fallback
    } else {
        primary
    }
}

async fn read_first_text(
    socket: &mut WebSocket,
    deps: &SessionDeps,
) -> Result<Vec<u8>, RegistrationError> {
    let deadline = tokio::time::Instant::now() + deps.config.registration_timeout;
    loop {
        let frame = tokio::time::timeout_at(deadline, socket.recv())
            .await
            .map_err(|_| RegistrationError::Timeout)?;
        match frame {
            None => return Err(RegistrationError::SocketClosed),
            Some(Err(_)) => return Err(RegistrationError::SocketClosed),
            Some(Ok(Message::Text(text))) => {
                if text.as_str().len() > deps.config.max_frame_bytes {
                    return Err(RegistrationError::TooLarge);
                }
                return Ok(text.as_str().as_bytes().to_vec());
            }
            Some(Ok(Message::Binary(_))) => return Err(RegistrationError::NotRegister),
            Some(Ok(Message::Close(_))) => return Err(RegistrationError::SocketClosed),
            // Ping/pong are transport noise before registration.
            Some(Ok(_)) => continue,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stable_id_is_deterministic_and_namespaced() {
        let a = stable_provider_id("serial:ABC");
        let b = stable_provider_id("serial:ABC");
        let c = stable_provider_id("serial:ABD");
        assert_eq!(a, b);
        assert_ne!(a, c);
        // RFC 9562 version 8 + variant bits.
        let bytes = a.get().into_bytes();
        assert_eq!(bytes[6] >> 4, 0x8);
        assert_eq!(bytes[8] >> 6, 0b10);
    }

    #[test]
    fn identity_preference_order() {
        let verdict = |serial: Option<&str>, key: Option<&str>| RegistrationVerdict {
            trust_epoch: darkbloom_core::ids::TrustEpoch::new(1),
            verdict: crate::contracts::TrustVerdict::SelfSigned,
            se_public_key: key.map(str::to_owned),
            serial_number: serial.map(str::to_owned),
        };
        assert_eq!(
            stable_identity_string(&verdict(Some("S1"), Some("K1")), "X1"),
            "serial:S1"
        );
        assert_eq!(
            stable_identity_string(&verdict(None, Some("K1")), "X1"),
            "sekey:K1"
        );
        assert_eq!(
            stable_identity_string(&verdict(None, None), "X1"),
            "x25519:X1"
        );
        assert!(stable_identity_string(&verdict(None, None), "").starts_with("conn:"));
    }
}
