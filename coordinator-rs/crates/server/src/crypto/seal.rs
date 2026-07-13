//! Bounded sender-seal key selection and provider request sealing.

use std::{collections::BTreeMap, sync::Arc};

use darkbloom_coordinator_protocol::{
    CryptoError,
    crypto::{SenderSealEnvelope, open_v2_frame, seal_box, seal_box_with},
    v1::EncryptedPayload,
    v2::{BinaryFrameHeader, encode_binary_frame},
};
use thiserror::Error;
use zeroize::Zeroizing;

use super::key::{ProcessX25519Key, X25519PublicKey};

/// Hard upper bound on retained process decryption keys.
pub const MAX_PROCESS_KEYS: usize = 16;

/// Process keys addressable by sender-seal `kid`.
#[derive(Debug)]
pub struct SenderSealKeyring {
    active_kid: Arc<str>,
    keys: BTreeMap<Arc<str>, Arc<ProcessX25519Key>>,
}

impl SenderSealKeyring {
    /// Builds a finite keyring and requires the active key to be present.
    pub fn new(
        active_kid: impl Into<Arc<str>>,
        keys: impl IntoIterator<Item = ProcessX25519Key>,
    ) -> Result<Self, SealKeyringError> {
        let active_kid = active_kid.into();
        let mut by_id = BTreeMap::new();
        for key in keys {
            if by_id.len() == MAX_PROCESS_KEYS {
                return Err(SealKeyringError::TooManyKeys {
                    maximum: MAX_PROCESS_KEYS,
                });
            }
            let kid: Arc<str> = Arc::from(key.kid());
            if by_id.insert(kid.clone(), Arc::new(key)).is_some() {
                return Err(SealKeyringError::DuplicateKeyId(kid));
            }
        }
        if !by_id.contains_key(&active_kid) {
            return Err(SealKeyringError::ActiveKeyMissing(active_kid));
        }
        Ok(Self {
            active_kid,
            keys: by_id,
        })
    }

    /// Active public key advertised by the encryption-key endpoint.
    #[must_use]
    pub fn active(&self) -> &ProcessX25519Key {
        self.keys
            .get(&self.active_kid)
            .expect("constructor established active process key")
    }

    /// Opens an envelope only with the exact addressed process key.
    pub fn open(&self, envelope: &SenderSealEnvelope) -> Result<Vec<u8>, SenderSealError> {
        if envelope.kid.is_empty() {
            return Err(SenderSealError::MissingKeyId);
        }
        let key = self
            .keys
            .get(envelope.kid.as_str())
            .ok_or_else(|| SenderSealError::UnknownKeyId(Arc::from(envelope.kid.as_str())))?;
        key.open_sender(envelope).map_err(SenderSealError::Crypto)
    }

    /// Seals one response payload to the sender with the active process key.
    pub fn seal_to_sender(
        &self,
        sender_public_key: X25519PublicKey,
        plaintext: &[u8],
    ) -> Result<String, SenderSealError> {
        self.active()
            .seal_to_sender(sender_public_key, plaintext)
            .map_err(SenderSealError::Crypto)
    }

    /// Number of retained process keys.
    #[must_use]
    pub fn len(&self) -> usize {
        self.keys.len()
    }

    /// Returns whether no keys are retained.
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.keys.is_empty()
    }
}

/// Seals one request to a provider's attested transport key.
pub fn seal_for_provider(
    provider_key: X25519PublicKey,
    plaintext: &[u8],
) -> Result<EncryptedPayload, CryptoError> {
    seal_box(provider_key.as_bytes(), plaintext)
}

/// One provider request envelope plus the ephemeral private half needed to
/// authenticate that provider's direct protocol-v2 response frames.
#[derive(Debug)]
pub struct ProviderRequestSeal {
    payload: EncryptedPayload,
    private_key: Zeroizing<[u8; 32]>,
}

impl ProviderRequestSeal {
    /// Encrypted request body sent in `Prepare`.
    #[must_use]
    pub const fn payload(&self) -> &EncryptedPayload {
        &self.payload
    }

    /// Opens a provider response only after the encrypted inner header is
    /// proven byte-for-byte equal to the validated outer header.
    pub fn open_response(
        &self,
        provider_key: X25519PublicKey,
        header: &BinaryFrameHeader,
        ciphertext: &[u8],
    ) -> Result<Vec<u8>, CryptoError> {
        let wire = encode_binary_frame(header, ciphertext)?;
        open_v2_frame(&self.private_key, provider_key.as_bytes(), &wire)
            .map(|opened| opened.plaintext)
    }
}

/// Seals exact consumer bytes while retaining only the request-scoped
/// ephemeral private key required for authenticated response decryption.
pub fn seal_request_for_provider(
    provider_key: X25519PublicKey,
    plaintext: &[u8],
) -> Result<ProviderRequestSeal, CryptoError> {
    use crypto_box::{SecretKey, aead::OsRng};

    let ephemeral = SecretKey::generate(&mut OsRng);
    let private_key = Zeroizing::new(ephemeral.to_bytes());
    let nonce = rand::random::<[u8; 24]>();
    let payload = seal_box_with(&private_key, provider_key.as_bytes(), &nonce, plaintext)?;
    Ok(ProviderRequestSeal {
        payload,
        private_key,
    })
}

/// Invalid finite keyring configuration.
#[derive(Clone, Debug, Eq, Error, PartialEq)]
pub enum SealKeyringError {
    /// More historical keys were configured than the hard bound permits.
    #[error("process keyring exceeds {maximum} keys")]
    TooManyKeys {
        /// Hard key count.
        maximum: usize,
    },
    /// A key identifier appeared more than once.
    #[error("duplicate process key identifier {0}")]
    DuplicateKeyId(Arc<str>),
    /// The selected active key is absent.
    #[error("active process key {0} is missing")]
    ActiveKeyMissing(Arc<str>),
}

/// Sender-seal open failure.
#[derive(Debug, Error)]
pub enum SenderSealError {
    /// Every sealed request must address a concrete key.
    #[error("sender-seal key identifier is missing")]
    MissingKeyId,
    /// No retained process key matches the envelope.
    #[error("unknown sender-seal key identifier {0}")]
    UnknownKeyId(Arc<str>),
    /// Authenticated decryption failed.
    #[error(transparent)]
    Crypto(#[from] CryptoError),
}

#[cfg(test)]
mod tests {
    use base64::{Engine, engine::general_purpose::STANDARD};
    use darkbloom_coordinator_protocol::crypto::seal_sender_request;

    use super::*;

    const PRIVATE: &str = "XasIfmJKikt54X+Lg4AO5m87sSkmGLb9HC+LJ/+I4Os=";
    const PUBLIC: &str = "3p7bfXt9wbTTW2HC7OQ1Nz+DQ8hbeGdNrfx+FG+IK08=";

    #[test]
    fn provider_box_and_sender_seal_round_trip_with_tamper_rejection() {
        let key = ProcessX25519Key::from_base64("active", PRIVATE, PUBLIC).expect("key");
        let provider_payload =
            seal_for_provider(key.public_key(), b"provider request").expect("provider seal");
        assert_eq!(
            key.open_box(&provider_payload).expect("provider open"),
            b"provider request"
        );
        let keyring = SenderSealKeyring::new("active", [key]).expect("keyring");
        let mut envelope = seal_sender_request(
            "active",
            keyring.active().public_key().as_bytes(),
            b"sealed request",
        )
        .expect("seal");
        assert_eq!(keyring.open(&envelope).expect("open"), b"sealed request");

        let mut ciphertext = STANDARD
            .decode(&envelope.ciphertext)
            .expect("generated base64");
        *ciphertext.last_mut().expect("ciphertext") ^= 1;
        envelope.ciphertext = STANDARD.encode(ciphertext);
        assert!(matches!(
            keyring.open(&envelope),
            Err(SenderSealError::Crypto(CryptoError::AuthenticationFailed))
        ));
        envelope.kid = "retired".to_owned();
        assert!(matches!(
            keyring.open(&envelope),
            Err(SenderSealError::UnknownKeyId(_))
        ));
    }
}
