//! Coordinator long-lived X25519 key for sender-sealed requests.

use darkbloom_protocol::{open_box, seal_box};
use crypto_box::{PublicKey, SecretKey};
use crypto_box::aead::OsRng;
use serde_json::{json, Value};
use std::sync::Arc;
use zeroize::Zeroize;

pub struct CoordinatorKeys {
    secret: SecretKey,
    public: PublicKey,
    kid: String,
}

impl CoordinatorKeys {
    pub fn generate(kid: impl Into<String>) -> Arc<Self> {
        let secret = SecretKey::generate(&mut OsRng);
        let public = secret.public_key();
        Arc::new(Self {
            secret,
            public,
            kid: kid.into(),
        })
    }

    pub fn from_seed(seed: [u8; 32], kid: impl Into<String>) -> Arc<Self> {
        let secret = SecretKey::from(seed);
        let public = secret.public_key();
        Arc::new(Self {
            secret,
            public,
            kid: kid.into(),
        })
    }

    pub fn kid(&self) -> &str {
        &self.kid
    }

    pub fn public_key_bytes(&self) -> [u8; 32] {
        *self.public.as_bytes()
    }

    pub fn public_key_b64(&self) -> String {
        use base64::Engine;
        base64::engine::general_purpose::STANDARD.encode(self.public_key_bytes())
    }

    pub fn encryption_key_json(&self) -> Value {
        json!({
            "kid": self.kid,
            "algorithm": "x25519-xsalsa20-poly1305",
            "public_key": self.public_key_b64(),
        })
    }

    /// Decrypt a sealed blob produced with seal_box layout (nonce||eph_pk||ct).
    pub fn open(&self, sealed: &[u8]) -> Result<Vec<u8>, String> {
        open_box(&self.secret.to_bytes(), sealed).map_err(|e| e.to_string())
    }

    /// Seal to an arbitrary recipient (tests / re-encrypt to provider).
    pub fn seal_to(&self, recipient_pk: &[u8; 32], plaintext: &[u8]) -> Result<Vec<u8>, String> {
        let _ = self; // sender is ephemeral inside seal_box
        seal_box(recipient_pk, plaintext).map_err(|e| e.to_string())
    }
}

impl Drop for CoordinatorKeys {
    fn drop(&mut self) {
        let mut bytes = self.secret.to_bytes();
        bytes.zeroize();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trip_via_public_key() {
        let keys = CoordinatorKeys::generate("test-kid");
        let sealed = seal_box(&keys.public_key_bytes(), b"hello").unwrap();
        let plain = keys.open(&sealed).unwrap();
        assert_eq!(plain, b"hello");
        let doc = keys.encryption_key_json();
        assert_eq!(doc["kid"], "test-kid");
        assert!(doc["public_key"].as_str().unwrap().len() > 20);
    }
}
