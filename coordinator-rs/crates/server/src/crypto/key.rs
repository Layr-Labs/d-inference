//! Process X25519 key material and canonical public-key values.

use std::{fmt, sync::Arc};

use base64::{Engine, engine::general_purpose::STANDARD};
use darkbloom_coordinator_protocol::{
    CryptoError,
    crypto::{
        SenderSealEnvelope, X25519_KEY_LEN, open_box, open_sender_request, seal_box, seal_box_with,
    },
    v1::EncryptedPayload,
};
use subtle::ConstantTimeEq;
use thiserror::Error;
use zeroize::Zeroizing;

const X25519_BASE64_LEN: usize = 44;

/// A validated X25519 public key.
#[derive(Clone, Copy, Eq, Hash, Ord, PartialEq, PartialOrd)]
pub struct X25519PublicKey([u8; X25519_KEY_LEN]);

impl X25519PublicKey {
    /// Decodes a canonical, standard-base64 X25519 public key.
    pub fn from_base64(encoded: &str) -> Result<Self, ProcessKeyError> {
        if encoded.len() != X25519_BASE64_LEN {
            return Err(ProcessKeyError::InvalidPublicKey);
        }
        let decoded = STANDARD
            .decode(encoded)
            .map_err(|_| ProcessKeyError::InvalidPublicKey)?;
        if decoded.len() != X25519_KEY_LEN || STANDARD.encode(&decoded) != encoded {
            return Err(ProcessKeyError::InvalidPublicKey);
        }
        let bytes: [u8; X25519_KEY_LEN] = decoded
            .try_into()
            .map_err(|_| ProcessKeyError::InvalidPublicKey)?;
        if bool::from(bytes.ct_eq(&[0; X25519_KEY_LEN])) {
            return Err(ProcessKeyError::InvalidPublicKey);
        }
        Ok(Self(bytes))
    }

    /// Constructs a nonzero public key from exact bytes.
    pub fn from_bytes(bytes: [u8; X25519_KEY_LEN]) -> Result<Self, ProcessKeyError> {
        if bool::from(bytes.ct_eq(&[0; X25519_KEY_LEN])) {
            return Err(ProcessKeyError::InvalidPublicKey);
        }
        Ok(Self(bytes))
    }

    /// Returns the exact key bytes.
    #[must_use]
    pub const fn as_bytes(&self) -> &[u8; X25519_KEY_LEN] {
        &self.0
    }

    /// Returns canonical standard base64.
    #[must_use]
    pub fn to_base64(self) -> String {
        STANDARD.encode(self.0)
    }

    /// Compares key bytes without data-dependent early return.
    #[must_use]
    pub fn ct_eq(&self, other: &Self) -> bool {
        bool::from(self.0.ct_eq(&other.0))
    }
}

impl fmt::Debug for X25519PublicKey {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_tuple("X25519PublicKey")
            .field(&self.to_base64())
            .finish()
    }
}

/// The coordinator process key used to open sender-sealed requests.
///
/// Construction performs a real NaCl Box round trip, proving that the
/// configured public key corresponds to the configured private key.
pub struct ProcessX25519Key {
    kid: Arc<str>,
    private_key: Zeroizing<[u8; X25519_KEY_LEN]>,
    public_key: X25519PublicKey,
}

impl ProcessX25519Key {
    /// Loads and binds one canonical base64 keypair.
    pub fn from_base64(
        kid: impl Into<Arc<str>>,
        private_key: &str,
        public_key: &str,
    ) -> Result<Self, ProcessKeyError> {
        let kid = kid.into();
        if kid.is_empty() || kid.len() > 256 || kid.chars().any(char::is_control) {
            return Err(ProcessKeyError::InvalidKeyId);
        }
        if private_key.len() != X25519_BASE64_LEN {
            return Err(ProcessKeyError::InvalidPrivateKey);
        }
        let decoded = Zeroizing::new(
            STANDARD
                .decode(private_key)
                .map_err(|_| ProcessKeyError::InvalidPrivateKey)?,
        );
        if decoded.len() != X25519_KEY_LEN || STANDARD.encode(decoded.as_slice()) != private_key {
            return Err(ProcessKeyError::InvalidPrivateKey);
        }
        let mut private_key = Zeroizing::new([0; X25519_KEY_LEN]);
        private_key.copy_from_slice(decoded.as_slice());
        Self::from_secret_parts(kid, private_key, X25519PublicKey::from_base64(public_key)?)
    }

    /// Loads one exact private/public pair.
    pub fn from_parts(
        kid: impl Into<Arc<str>>,
        private_key: [u8; X25519_KEY_LEN],
        public_key: X25519PublicKey,
    ) -> Result<Self, ProcessKeyError> {
        Self::from_secret_parts(kid, Zeroizing::new(private_key), public_key)
    }

    fn from_secret_parts(
        kid: impl Into<Arc<str>>,
        private_key: Zeroizing<[u8; X25519_KEY_LEN]>,
        public_key: X25519PublicKey,
    ) -> Result<Self, ProcessKeyError> {
        let kid = kid.into();
        if kid.is_empty() || kid.len() > 256 || kid.chars().any(char::is_control) {
            return Err(ProcessKeyError::InvalidKeyId);
        }
        if bool::from(private_key.ct_eq(&[0; X25519_KEY_LEN])) {
            return Err(ProcessKeyError::InvalidPrivateKey);
        }
        let probe = b"darkbloom.process-x25519-key-binding";
        let sealed = seal_box(public_key.as_bytes(), probe)
            .map_err(|_| ProcessKeyError::PublicPrivateMismatch)?;
        let opened =
            open_box(&private_key, &sealed).map_err(|_| ProcessKeyError::PublicPrivateMismatch)?;
        if !bool::from(opened.as_slice().ct_eq(probe)) {
            return Err(ProcessKeyError::PublicPrivateMismatch);
        }
        Ok(Self {
            kid,
            private_key,
            public_key,
        })
    }

    /// Stable key identifier advertised to senders.
    #[must_use]
    pub fn kid(&self) -> &str {
        &self.kid
    }

    /// Public half of the process key.
    #[must_use]
    pub const fn public_key(&self) -> X25519PublicKey {
        self.public_key
    }

    /// Opens a standard protocol NaCl Box payload.
    pub fn open_box(&self, payload: &EncryptedPayload) -> Result<Vec<u8>, CryptoError> {
        open_box(&self.private_key, payload)
    }

    /// Opens a sender-sealed envelope without exposing the process private key.
    pub fn open_sender(&self, envelope: &SenderSealEnvelope) -> Result<Vec<u8>, CryptoError> {
        open_sender_request(&self.private_key, envelope)
    }

    /// Seals response bytes back to a sender while retaining this process key
    /// as the authenticated static sender identity.
    pub fn seal_to_sender(
        &self,
        sender_public_key: X25519PublicKey,
        plaintext: &[u8],
    ) -> Result<String, CryptoError> {
        let nonce = rand::random::<[u8; 24]>();
        seal_box_with(
            &self.private_key,
            sender_public_key.as_bytes(),
            &nonce,
            plaintext,
        )
        .map(|payload| payload.ciphertext)
    }
}

impl fmt::Debug for ProcessX25519Key {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("ProcessX25519Key")
            .field("kid", &self.kid)
            .field("public_key", &self.public_key)
            .finish_non_exhaustive()
    }
}

/// Invalid or mismatched process key configuration.
#[derive(Clone, Copy, Debug, Eq, Error, PartialEq)]
pub enum ProcessKeyError {
    /// The key identifier is empty, oversized, or contains a control character.
    #[error("invalid process X25519 key identifier")]
    InvalidKeyId,
    /// The private key is not canonical base64 containing 32 nonzero bytes.
    #[error("invalid process X25519 private key")]
    InvalidPrivateKey,
    /// The public key is not canonical base64 containing 32 nonzero bytes.
    #[error("invalid X25519 public key")]
    InvalidPublicKey,
    /// A real authenticated round trip did not bind the configured pair.
    #[error("process X25519 public and private keys do not match")]
    PublicPrivateMismatch,
}

#[cfg(test)]
mod tests {
    use super::*;

    const PRIVATE: &str = "XasIfmJKikt54X+Lg4AO5m87sSkmGLb9HC+LJ/+I4Os=";
    const PUBLIC: &str = "3p7bfXt9wbTTW2HC7OQ1Nz+DQ8hbeGdNrfx+FG+IK08=";
    const WRONG_PUBLIC: &str = "hSDwCYkwp1R0i33ctD73Wg2/Og0mOBr066SpjqqbTmo=";

    #[test]
    fn real_x25519_pair_is_bound_and_mismatch_fails() {
        let key = ProcessX25519Key::from_base64("process-1", PRIVATE, PUBLIC).expect("valid pair");
        assert_eq!(key.public_key().to_base64(), PUBLIC);
        assert_eq!(key.kid(), "process-1");
        assert_eq!(
            ProcessX25519Key::from_base64("process-1", PRIVATE, WRONG_PUBLIC)
                .expect_err("mismatch"),
            ProcessKeyError::PublicPrivateMismatch
        );
    }

    #[test]
    fn canonical_nonzero_keys_are_required() {
        assert!(X25519PublicKey::from_base64("AAAA").is_err());
        assert!(X25519PublicKey::from_base64(&STANDARD.encode([0; X25519_KEY_LEN])).is_err());
    }
}
