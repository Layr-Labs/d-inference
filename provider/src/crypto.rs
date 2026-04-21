use anyhow::Result;
use crypto_box::{
    PublicKey, SalsaBox, SecretKey,
    aead::{Aead, AeadCore, OsRng},
};

/// Ephemeral X25519 key pair for E2E encryption.
///
/// Generated fresh on every provider launch. The secret exists only in this
/// process's memory, protected by PT_DENY_ATTACH + Hardened Runtime + SIP.
/// The attestation blob binds the public key to the SE signing identity.
pub struct NodeKeyPair {
    secret: SecretKey,
    public: PublicKey,
}

impl std::fmt::Debug for NodeKeyPair {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("NodeKeyPair")
            .field("public", &self.public_key_base64())
            .field("secret", &"[REDACTED]")
            .finish()
    }
}

impl NodeKeyPair {
    pub fn generate() -> Self {
        let secret = SecretKey::generate(&mut OsRng);
        let public = secret.public_key().clone();
        Self { secret, public }
    }

    pub fn public_key_base64(&self) -> String {
        use base64::Engine;
        base64::engine::general_purpose::STANDARD.encode(self.public.as_bytes())
    }

    pub fn public_key_bytes(&self) -> [u8; 32] {
        self.public.to_bytes()
    }

    pub fn decrypt(&self, consumer_public_bytes: &[u8; 32], ciphertext: &[u8]) -> Result<Vec<u8>> {
        if ciphertext.len() < 24 {
            anyhow::bail!("ciphertext too short: expected at least 24 bytes for nonce");
        }

        let consumer_pk = PublicKey::from(*consumer_public_bytes);
        let salsa_box = SalsaBox::new(&consumer_pk, &self.secret);

        let nonce_bytes: [u8; 24] = ciphertext[..24]
            .try_into()
            .context("failed to extract nonce")?;
        let nonce = nonce_bytes.into();

        salsa_box
            .decrypt(&nonce, &ciphertext[24..])
            .map_err(|e| anyhow::anyhow!("decryption failed: {e}"))
    }

    pub fn encrypt(&self, consumer_public_bytes: &[u8; 32], plaintext: &[u8]) -> Result<Vec<u8>> {
        let consumer_pk = PublicKey::from(*consumer_public_bytes);
        let salsa_box = SalsaBox::new(&consumer_pk, &self.secret);

        let nonce = SalsaBox::generate_nonce(&mut OsRng);
        let encrypted = salsa_box
            .encrypt(&nonce, plaintext)
            .map_err(|e| anyhow::anyhow!("encryption failed: {e}"))?;

        let mut result = Vec::with_capacity(24 + encrypted.len());
        result.extend_from_slice(&nonce);
        result.extend_from_slice(&encrypted);
        Ok(result)
    }
}

use anyhow::Context;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_generate_key_pair() {
        let kp = NodeKeyPair::generate();
        let pk_b64 = kp.public_key_base64();
        assert!(!pk_b64.is_empty());
        assert_eq!(pk_b64.len(), 44);
    }

    #[test]
    fn test_encrypt_decrypt_round_trip() {
        let provider = NodeKeyPair::generate();
        let consumer = NodeKeyPair::generate();

        let plaintext = b"Hello, encrypted world!";

        let ciphertext =
            encrypt_with_keypair(&consumer.secret, &provider.public_key_bytes(), plaintext)
                .unwrap();

        let decrypted = provider
            .decrypt(&consumer.public_key_bytes(), &ciphertext)
            .unwrap();

        assert_eq!(decrypted, plaintext);
    }

    #[test]
    fn test_provider_encrypt_consumer_decrypt() {
        let provider = NodeKeyPair::generate();
        let consumer = NodeKeyPair::generate();

        let plaintext = b"Response from provider";

        let ciphertext = provider
            .encrypt(&consumer.public_key_bytes(), plaintext)
            .unwrap();

        let decrypted =
            decrypt_with_keypair(&consumer.secret, &provider.public_key_bytes(), &ciphertext)
                .unwrap();

        assert_eq!(decrypted, plaintext);
    }

    #[test]
    fn test_decrypt_wrong_key_fails() {
        let provider = NodeKeyPair::generate();
        let consumer = NodeKeyPair::generate();
        let wrong_key = NodeKeyPair::generate();

        let plaintext = b"Secret message";

        let ciphertext =
            encrypt_with_keypair(&consumer.secret, &provider.public_key_bytes(), plaintext)
                .unwrap();

        let result = provider.decrypt(&wrong_key.public_key_bytes(), &ciphertext);
        assert!(result.is_err());
    }

    #[test]
    fn test_decrypt_too_short_ciphertext() {
        let provider = NodeKeyPair::generate();
        let consumer_pk = [0u8; 32];

        let result = provider.decrypt(&consumer_pk, &[0u8; 10]);
        assert!(result.is_err());
        assert!(result.unwrap_err().to_string().contains("too short"));
    }

    #[test]
    fn test_encrypt_decrypt_empty_plaintext() {
        let provider = NodeKeyPair::generate();
        let consumer = NodeKeyPair::generate();

        let plaintext = b"";

        let ciphertext =
            encrypt_with_keypair(&consumer.secret, &provider.public_key_bytes(), plaintext)
                .unwrap();

        let decrypted = provider
            .decrypt(&consumer.public_key_bytes(), &ciphertext)
            .unwrap();

        assert_eq!(decrypted, plaintext);
    }

    #[test]
    fn test_encrypt_decrypt_large_payload() {
        let provider = NodeKeyPair::generate();
        let consumer = NodeKeyPair::generate();

        let plaintext: Vec<u8> = (0..10_000).map(|i| (i % 256) as u8).collect();

        let ciphertext =
            encrypt_with_keypair(&consumer.secret, &provider.public_key_bytes(), &plaintext)
                .unwrap();

        let decrypted = provider
            .decrypt(&consumer.public_key_bytes(), &ciphertext)
            .unwrap();

        assert_eq!(decrypted, plaintext);
    }

    #[test]
    fn test_different_encryptions_produce_different_ciphertext() {
        let provider = NodeKeyPair::generate();
        let consumer = NodeKeyPair::generate();

        let plaintext = b"Same message";

        let ct1 = encrypt_with_keypair(&consumer.secret, &provider.public_key_bytes(), plaintext)
            .unwrap();

        let ct2 = encrypt_with_keypair(&consumer.secret, &provider.public_key_bytes(), plaintext)
            .unwrap();

        assert_ne!(ct1, ct2);

        let d1 = provider
            .decrypt(&consumer.public_key_bytes(), &ct1)
            .unwrap();
        let d2 = provider
            .decrypt(&consumer.public_key_bytes(), &ct2)
            .unwrap();
        assert_eq!(d1, plaintext);
        assert_eq!(d2, plaintext);
    }

    fn encrypt_with_keypair(
        sender_secret: &SecretKey,
        recipient_public: &[u8; 32],
        plaintext: &[u8],
    ) -> Result<Vec<u8>> {
        let recipient_pk = PublicKey::from(*recipient_public);
        let salsa_box = SalsaBox::new(&recipient_pk, sender_secret);

        let nonce = SalsaBox::generate_nonce(&mut OsRng);
        let encrypted = salsa_box
            .encrypt(&nonce, plaintext)
            .map_err(|e| anyhow::anyhow!("encryption failed: {e}"))?;

        let mut result = Vec::with_capacity(24 + encrypted.len());
        result.extend_from_slice(&nonce);
        result.extend_from_slice(&encrypted);
        Ok(result)
    }

    fn decrypt_with_keypair(
        receiver_secret: &SecretKey,
        sender_public: &[u8; 32],
        ciphertext: &[u8],
    ) -> Result<Vec<u8>> {
        if ciphertext.len() < 24 {
            anyhow::bail!("ciphertext too short");
        }

        let sender_pk = PublicKey::from(*sender_public);
        let salsa_box = SalsaBox::new(&sender_pk, receiver_secret);

        let nonce_bytes: [u8; 24] = ciphertext[..24].try_into().unwrap();
        let nonce = nonce_bytes.into();

        salsa_box
            .decrypt(&nonce, &ciphertext[24..])
            .map_err(|e| anyhow::anyhow!("decryption failed: {e}"))
    }

    #[test]
    fn test_encrypted_payload_go_coordinator_simulation() {
        use crate::protocol::EncryptedPayload;
        use base64::Engine;

        let provider = NodeKeyPair::generate();

        let ephemeral_secret = SecretKey::generate(&mut OsRng);
        let ephemeral_public = ephemeral_secret.public_key().clone();

        let plaintext_json =
            r#"{"model":"test","messages":[{"role":"user","content":"hello"}],"stream":true}"#;

        let provider_pk = PublicKey::from(provider.public_key_bytes());
        let salsa_box = SalsaBox::new(&provider_pk, &ephemeral_secret);
        let nonce = SalsaBox::generate_nonce(&mut OsRng);
        let encrypted = salsa_box
            .encrypt(&nonce, plaintext_json.as_bytes())
            .expect("encryption should succeed");

        let mut nonce_and_ciphertext = Vec::with_capacity(24 + encrypted.len());
        nonce_and_ciphertext.extend_from_slice(&nonce);
        nonce_and_ciphertext.extend_from_slice(&encrypted);

        let ephemeral_pk_b64 =
            base64::engine::general_purpose::STANDARD.encode(ephemeral_public.as_bytes());
        let ciphertext_b64 =
            base64::engine::general_purpose::STANDARD.encode(&nonce_and_ciphertext);

        let payload = EncryptedPayload {
            ephemeral_public_key: ephemeral_pk_b64.clone(),
            ciphertext: ciphertext_b64.clone(),
        };

        let ephemeral_pub_bytes: [u8; 32] = base64::engine::general_purpose::STANDARD
            .decode(&payload.ephemeral_public_key)
            .unwrap()
            .try_into()
            .unwrap();

        let ciphertext_bytes = base64::engine::general_purpose::STANDARD
            .decode(&payload.ciphertext)
            .unwrap();

        let decrypted = provider
            .decrypt(&ephemeral_pub_bytes, &ciphertext_bytes)
            .expect("decryption should succeed");

        assert_eq!(
            String::from_utf8(decrypted).unwrap(),
            plaintext_json,
            "decrypted body should match original plaintext"
        );
    }

    #[test]
    fn test_encrypted_payload_json_structure() {
        use crate::protocol::EncryptedPayload;
        use base64::Engine;

        let provider = NodeKeyPair::generate();
        let ephemeral_secret = SecretKey::generate(&mut OsRng);
        let ephemeral_public = ephemeral_secret.public_key().clone();

        let plaintext = b"test payload";

        let provider_pk = PublicKey::from(provider.public_key_bytes());
        let salsa_box = SalsaBox::new(&provider_pk, &ephemeral_secret);
        let nonce = SalsaBox::generate_nonce(&mut OsRng);
        let encrypted = salsa_box.encrypt(&nonce, &plaintext[..]).unwrap();

        let mut combined = Vec::new();
        combined.extend_from_slice(&nonce);
        combined.extend_from_slice(&encrypted);

        let payload = EncryptedPayload {
            ephemeral_public_key: base64::engine::general_purpose::STANDARD
                .encode(ephemeral_public.as_bytes()),
            ciphertext: base64::engine::general_purpose::STANDARD.encode(&combined),
        };

        let json = serde_json::to_string(&payload).unwrap();

        assert!(json.contains("\"ephemeral_public_key\":"));
        assert!(json.contains("\"ciphertext\":"));

        let parsed: EncryptedPayload = serde_json::from_str(&json).unwrap();
        let decoded_pk = base64::engine::general_purpose::STANDARD
            .decode(&parsed.ephemeral_public_key)
            .unwrap();
        assert_eq!(
            decoded_pk.len(),
            32,
            "ephemeral public key should be 32 bytes"
        );

        let decoded_ct = base64::engine::general_purpose::STANDARD
            .decode(&parsed.ciphertext)
            .unwrap();
        assert!(
            decoded_ct.len() >= 24,
            "ciphertext should be at least 24 bytes (nonce)"
        );
    }

    #[test]
    fn test_encrypted_payload_wrong_provider_key_fails() {
        use base64::Engine;

        let provider = NodeKeyPair::generate();
        let wrong_provider = NodeKeyPair::generate();

        let ephemeral_secret = SecretKey::generate(&mut OsRng);
        let provider_pk = PublicKey::from(provider.public_key_bytes());
        let salsa_box = SalsaBox::new(&provider_pk, &ephemeral_secret);
        let nonce = SalsaBox::generate_nonce(&mut OsRng);
        let encrypted = salsa_box.encrypt(&nonce, &b"secret data"[..]).unwrap();

        let mut combined = Vec::new();
        combined.extend_from_slice(&nonce);
        combined.extend_from_slice(&encrypted);

        let ephemeral_pub_bytes = ephemeral_secret.public_key().to_bytes();
        let result = wrong_provider.decrypt(&ephemeral_pub_bytes, &combined);
        assert!(result.is_err(), "Decryption with wrong key should fail");
    }

    #[test]
    fn test_encrypted_payload_decrypts_to_valid_json() {
        use base64::Engine;

        let provider = NodeKeyPair::generate();
        let ephemeral_secret = SecretKey::generate(&mut OsRng);
        let ephemeral_public = ephemeral_secret.public_key().clone();

        let body = serde_json::json!({
            "model": "mlx-community/Qwen2.5-7B-4bit",
            "messages": [
                {"role": "system", "content": "You are a helpful assistant."},
                {"role": "user", "content": "What is 2+2?"}
            ],
            "stream": true,
            "temperature": 0.7,
            "max_tokens": 1024
        });
        let plaintext = serde_json::to_vec(&body).unwrap();

        let provider_pk = PublicKey::from(provider.public_key_bytes());
        let salsa_box = SalsaBox::new(&provider_pk, &ephemeral_secret);
        let nonce = SalsaBox::generate_nonce(&mut OsRng);
        let encrypted = salsa_box.encrypt(&nonce, &plaintext[..]).unwrap();

        let mut combined = Vec::new();
        combined.extend_from_slice(&nonce);
        combined.extend_from_slice(&encrypted);

        let ephemeral_pub_bytes = ephemeral_public.to_bytes();
        let decrypted = provider.decrypt(&ephemeral_pub_bytes, &combined).unwrap();

        let parsed: serde_json::Value = serde_json::from_slice(&decrypted).unwrap();
        assert_eq!(parsed["model"], "mlx-community/Qwen2.5-7B-4bit");
        assert_eq!(parsed["stream"], true);
        assert_eq!(parsed["temperature"], 0.7);
        let messages = parsed["messages"].as_array().unwrap();
        assert_eq!(messages.len(), 2);
        assert_eq!(messages[1]["content"], "What is 2+2?");
    }
}
