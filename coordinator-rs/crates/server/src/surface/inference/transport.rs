use std::fmt;

use darkbloom_coordinator_protocol::crypto::SenderSealEnvelope;

use crate::crypto::{SenderSealKeyring, X25519PublicKey};

use super::{AdapterError, limits::MAX_BODY_BYTES};

pub const JSON_CONTENT_TYPE: &str = "application/json";
pub const SEALED_CONTENT_TYPE: &str = "application/eigeninference-sealed+json";

/// Opened consumer bytes plus the optional authenticated response recipient.
///
/// `Debug` deliberately reports only metadata. Request plaintext can therefore
/// be passed through ordinary error paths without accidentally logging prompts.
pub struct TransportRequest {
    plaintext: Vec<u8>,
    sender: Option<X25519PublicKey>,
}

impl TransportRequest {
    #[must_use]
    pub fn plaintext(&self) -> &[u8] {
        &self.plaintext
    }

    #[must_use]
    pub const fn sender(&self) -> Option<X25519PublicKey> {
        self.sender
    }

    #[must_use]
    pub fn into_plaintext(self) -> Vec<u8> {
        self.plaintext
    }
}

impl fmt::Debug for TransportRequest {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("TransportRequest")
            .field("plaintext_bytes", &self.plaintext.len())
            .field("sender_sealed", &self.sender.is_some())
            .finish()
    }
}

/// Opens JSON or the sender-seal wrapper with the same finite limit before and
/// after decryption.
pub fn open_transport_request(
    content_type: Option<&str>,
    body: &[u8],
    keyring: &SenderSealKeyring,
) -> Result<TransportRequest, AdapterError> {
    if body.len() > MAX_BODY_BYTES {
        return Err(AdapterError::payload_too_large());
    }
    match media_type(content_type).as_deref() {
        None | Some(JSON_CONTENT_TYPE) => Ok(TransportRequest {
            plaintext: body.to_vec(),
            sender: None,
        }),
        Some(SEALED_CONTENT_TYPE) => {
            crate::pilot::validate_json_structure(body).map_err(|_| {
                AdapterError::invalid("sealed request envelope is not valid JSON", None)
            })?;
            let envelope: SenderSealEnvelope = serde_json::from_slice(body).map_err(|_| {
                AdapterError::invalid("sealed request envelope is not valid JSON", None)
            })?;
            let sender =
                X25519PublicKey::from_base64(&envelope.ephemeral_public_key).map_err(|_| {
                    AdapterError::invalid(
                        "sealed request sender key is not canonical X25519 base64",
                        None,
                    )
                })?;
            let plaintext = keyring
                .open(&envelope)
                .map_err(|_| AdapterError::invalid("sealed request authentication failed", None))?;
            if plaintext.len() > MAX_BODY_BYTES {
                return Err(AdapterError::payload_too_large());
            }
            Ok(TransportRequest {
                plaintext,
                sender: Some(sender),
            })
        }
        Some(_) => Err(AdapterError::new(
            415,
            "unsupported_media_type",
            "invalid_request_error",
            "Content-Type must be application/json or application/eigeninference-sealed+json"
                .into(),
            None,
        )),
    }
}

fn media_type(content_type: Option<&str>) -> Option<String> {
    content_type.map(|value| {
        value
            .split(';')
            .next()
            .unwrap_or_default()
            .trim()
            .to_ascii_lowercase()
    })
}

#[cfg(test)]
mod tests {
    use darkbloom_coordinator_protocol::crypto::seal_sender_request;

    use crate::crypto::ProcessX25519Key;

    use super::*;

    const PRIVATE: &str = "XasIfmJKikt54X+Lg4AO5m87sSkmGLb9HC+LJ/+I4Os=";
    const PUBLIC: &str = "3p7bfXt9wbTTW2HC7OQ1Nz+DQ8hbeGdNrfx+FG+IK08=";

    #[test]
    fn sender_seal_wrapper_round_trips_and_debug_redacts_plaintext() {
        let key = ProcessX25519Key::from_base64("active", PRIVATE, PUBLIC).expect("key");
        let keyring = SenderSealKeyring::new("active", [key]).expect("keyring");
        let plaintext = br#"{"model":"m","input":"do not log me"}"#;
        let envelope = seal_sender_request(
            "active",
            keyring.active().public_key().as_bytes(),
            plaintext,
        )
        .expect("sender seal");
        let wire = serde_json::to_vec(&envelope).expect("envelope JSON");
        let opened = open_transport_request(Some(SEALED_CONTENT_TYPE), &wire, &keyring)
            .expect("open wrapper");
        assert_eq!(opened.plaintext(), plaintext);
        assert_eq!(
            opened.sender().expect("sender").to_base64(),
            envelope.ephemeral_public_key
        );
        assert!(!format!("{opened:?}").contains("do not log me"));
    }
}
