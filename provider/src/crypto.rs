//! NaCl Box encryption primitives for the Darkbloom provider.
//!
//! Uses NaCl crypto_box (X25519 + XSalsa20-Poly1305) for wire compatibility
//! with the coordinator.
//!
//! The provider's long-term X25519 key is derived inside the signed provider
//! process from an opaque Secure Enclave P-256 key-agreement identity blob.
//! The plaintext X25519 secret only exists in process memory; disk only holds
//! a device-bound Secure Enclave handle that must be reloaded by the same
//! Secure Enclave before the secret can be deterministically re-derived.
//! Text mode intentionally refuses any plaintext file-based fallback.

use anyhow::{Context, Result};
use crypto_box::{
    PublicKey, SalsaBox, SecretKey,
    aead::{Aead, AeadCore, OsRng},
};
/// A provider's long-lived X25519 key pair used for E2E encryption.
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
    /// Generate a new random key pair.
    pub fn generate() -> Self {
        let secret = SecretKey::generate(&mut OsRng);
        let public = secret.public_key().clone();
        Self { secret, public }
    }

    /// Load the privacy-preserving text E2E key pair.
    ///
    /// The root key lives as an opaque Secure Enclave key-agreement identity
    /// blob. We deterministically derive the X25519 secret inside this process
    /// from that identity and refuse any plaintext disk key fallback.
    pub fn load_or_generate() -> Result<Self> {
        #[cfg(target_os = "macos")]
        {
            let secret_bytes = crate::secure_enclave_key::load_or_create_x25519_secret()
                .context("failed to load Secure Enclave-backed E2E key")?;
            let secret = SecretKey::from(secret_bytes);
            let public = secret.public_key().clone();
            maybe_purge_legacy_e2e_files();
            Ok(Self { secret, public })
        }

        #[cfg(not(target_os = "macos"))]
        {
            anyhow::bail!("text E2E keys require macOS Secure Enclave support");
        }
    }

    /// Load the existing privacy-preserving text E2E key pair without mutating
    /// any on-disk or Secure Enclave state.
    pub fn load_existing() -> Result<Option<Self>> {
        #[cfg(target_os = "macos")]
        {
            let Some(secret_bytes) = crate::secure_enclave_key::load_existing_x25519_secret()
                .context("failed to inspect Secure Enclave-backed E2E key")?
            else {
                return Ok(None);
            };
            let secret = SecretKey::from(secret_bytes);
            let public = secret.public_key().clone();
            Ok(Some(Self { secret, public }))
        }

        #[cfg(not(target_os = "macos"))]
        {
            anyhow::bail!("text E2E keys require macOS Secure Enclave support");
        }
    }

    /// Return the public key as a base64-encoded string.
    pub fn public_key_base64(&self) -> String {
        use base64::Engine;
        base64::engine::general_purpose::STANDARD.encode(self.public.as_bytes())
    }

    /// Return the raw public key bytes.
    pub fn public_key_bytes(&self) -> [u8; 32] {
        self.public.to_bytes()
    }

    /// Decrypt a message from a consumer given their ephemeral public key.
    ///
    /// The ciphertext is expected in NaCl Box format: 24-byte nonce || encrypted data.
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

    /// Encrypt a response for a consumer given their ephemeral public key.
    ///
    /// Returns nonce || ciphertext in NaCl Box format.
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

pub fn delete_persistent_key() -> Result<()> {
    #[cfg(target_os = "macos")]
    crate::secure_enclave_key::delete_persistent_key()?;

    purge_legacy_e2e_files();
    Ok(())
}

pub fn legacy_node_key_paths() -> Vec<std::path::PathBuf> {
    legacy_secret_paths("node_key")
}

pub fn legacy_enclave_e2e_key_paths() -> Vec<std::path::PathBuf> {
    legacy_secret_paths("enclave_e2e_ka.data")
}

fn purge_legacy_e2e_files() {
    for path in [legacy_node_key_paths(), legacy_enclave_e2e_key_paths()]
        .into_iter()
        .flatten()
        .filter(|path| path.exists())
    {
        match std::fs::remove_file(&path) {
            Ok(()) => tracing::info!("Removed legacy E2E secret file: {}", path.display()),
            Err(err) => tracing::warn!(
                "Failed to remove legacy E2E secret file {}: {err}",
                path.display()
            ),
        }
    }
}

fn maybe_purge_legacy_e2e_files() {
    match crate::secure_enclave_key::has_persisted_x25519_identity() {
        Ok(true) => purge_legacy_e2e_files(),
        Ok(false) => tracing::info!(
            "Preserving legacy E2E files because no canonical Secure Enclave identity is persisted yet"
        ),
        Err(err) => tracing::warn!(
            "Failed to determine whether canonical Secure Enclave identity is persisted; preserving legacy E2E files: {err}"
        ),
    }
}

fn legacy_secret_paths(file_name: &str) -> Vec<std::path::PathBuf> {
    dirs::home_dir()
        .map(|home| {
            [".darkbloom", ".dginf", ".eigeninference"]
                .into_iter()
                .map(|dir| home.join(dir).join(file_name))
                .collect()
        })
        .unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Mutex, OnceLock};

    fn env_lock() -> &'static Mutex<()> {
        static LOCK: OnceLock<Mutex<()>> = OnceLock::new();
        LOCK.get_or_init(|| Mutex::new(()))
    }

    #[test]
    fn test_generate_key_pair() {
        let kp = NodeKeyPair::generate();
        let pk_b64 = kp.public_key_base64();
        assert!(!pk_b64.is_empty());

        // Base64 of 32 bytes should be 44 chars (with padding)
        assert_eq!(pk_b64.len(), 44);
    }

    #[test]
    fn test_encrypt_decrypt_round_trip() {
        // Simulate provider and consumer key pairs
        let provider = NodeKeyPair::generate();
        let consumer = NodeKeyPair::generate();

        let plaintext = b"Hello, encrypted world!";

        // Consumer encrypts with provider's public key
        let ciphertext =
            encrypt_with_keypair(&consumer.secret, &provider.public_key_bytes(), plaintext)
                .unwrap();

        // Provider decrypts with consumer's public key
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

        // Provider encrypts response for consumer
        let ciphertext = provider
            .encrypt(&consumer.public_key_bytes(), plaintext)
            .unwrap();

        // Consumer decrypts
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

        // Trying to decrypt with wrong consumer public key should fail
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
    fn test_maybe_purge_legacy_e2e_files_preserves_legacy_when_canonical_identity_missing() {
        let _guard = env_lock().lock().unwrap();
        let tmp = tempfile::tempdir().unwrap();
        let home = tmp.path();
        let legacy_path = home.join(".darkbloom/node_key");
        std::fs::create_dir_all(legacy_path.parent().unwrap()).unwrap();
        std::fs::write(&legacy_path, b"legacy").unwrap();

        let old_home = std::env::var_os("HOME");
        unsafe {
            std::env::set_var("HOME", home);
        }

        maybe_purge_legacy_e2e_files();

        assert!(
            legacy_path.exists(),
            "legacy key should survive until the canonical identity exists"
        );

        match old_home {
            Some(value) => unsafe { std::env::set_var("HOME", value) },
            None => unsafe { std::env::remove_var("HOME") },
        }
    }

    #[test]
    fn test_maybe_purge_legacy_e2e_files_removes_legacy_after_canonical_identity_persists() {
        let _guard = env_lock().lock().unwrap();
        let tmp = tempfile::tempdir().unwrap();
        let home = tmp.path();
        let legacy_path = home.join(".darkbloom/node_key");
        let canonical_path = home.join(".darkbloom/e2e_key.data");
        std::fs::create_dir_all(legacy_path.parent().unwrap()).unwrap();
        std::fs::write(&legacy_path, b"legacy").unwrap();
        std::fs::write(&canonical_path, b"canonical").unwrap();

        let old_home = std::env::var_os("HOME");
        unsafe {
            std::env::set_var("HOME", home);
        }

        maybe_purge_legacy_e2e_files();

        assert!(
            !legacy_path.exists(),
            "legacy key should be removed once the canonical identity exists"
        );

        match old_home {
            Some(value) => unsafe { std::env::set_var("HOME", value) },
            None => unsafe { std::env::remove_var("HOME") },
        }
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

        // Simulate a large prompt
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

        // Different nonces should produce different ciphertext
        assert_ne!(ct1, ct2);

        // But both should decrypt to the same plaintext
        let d1 = provider
            .decrypt(&consumer.public_key_bytes(), &ct1)
            .unwrap();
        let d2 = provider
            .decrypt(&consumer.public_key_bytes(), &ct2)
            .unwrap();
        assert_eq!(d1, plaintext);
        assert_eq!(d2, plaintext);
    }

    /// Helper: encrypt using a consumer's secret key and the provider's public key.
    /// This simulates what the Python SDK consumer does.
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

    /// Helper: decrypt using a consumer's secret key and the provider's public key.
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

    // -----------------------------------------------------------------------
    // Encrypted payload decryption — simulating Go coordinator flow
    // -----------------------------------------------------------------------

    /// Simulate the Go coordinator's encryption: generate an ephemeral keypair,
    /// encrypt a JSON body with the provider's public key, produce an
    /// EncryptedPayload (base64 fields), then decrypt on the provider side.
    #[test]
    fn test_encrypted_payload_go_coordinator_simulation() {
        use crate::protocol::EncryptedPayload;
        use base64::Engine;

        let provider = NodeKeyPair::generate();

        // --- Simulate Go coordinator side ---
        // 1. Generate ephemeral X25519 keypair (coordinator does this per request)
        let ephemeral_secret = SecretKey::generate(&mut OsRng);
        let ephemeral_public = ephemeral_secret.public_key().clone();

        // 2. Build the plaintext JSON body (OpenAI-compatible inference request)
        let plaintext_json =
            r#"{"model":"test","messages":[{"role":"user","content":"hello"}],"stream":true}"#;

        // 3. Encrypt with NaCl Box: ephemeral_secret + provider_public
        let provider_pk = PublicKey::from(provider.public_key_bytes());
        let salsa_box = SalsaBox::new(&provider_pk, &ephemeral_secret);
        let nonce = SalsaBox::generate_nonce(&mut OsRng);
        let encrypted = salsa_box
            .encrypt(&nonce, plaintext_json.as_bytes())
            .expect("encryption should succeed");

        // 4. Combine nonce || ciphertext (NaCl Box convention)
        let mut nonce_and_ciphertext = Vec::with_capacity(24 + encrypted.len());
        nonce_and_ciphertext.extend_from_slice(&nonce);
        nonce_and_ciphertext.extend_from_slice(&encrypted);

        // 5. Base64-encode for JSON transport (what Go coordinator does)
        let ephemeral_pk_b64 =
            base64::engine::general_purpose::STANDARD.encode(ephemeral_public.as_bytes());
        let ciphertext_b64 =
            base64::engine::general_purpose::STANDARD.encode(&nonce_and_ciphertext);

        let payload = EncryptedPayload {
            ephemeral_public_key: ephemeral_pk_b64.clone(),
            ciphertext: ciphertext_b64.clone(),
        };

        // --- Provider side: decrypt ---
        // Decode base64 fields
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

        // Verify round-trip
        assert_eq!(
            String::from_utf8(decrypted).unwrap(),
            plaintext_json,
            "decrypted body should match original plaintext"
        );
    }

    /// Verify that the EncryptedPayload JSON structure matches what the Go
    /// coordinator sends (field names, base64 encoding).
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

        // Verify JSON field names match Go coordinator expectations
        assert!(json.contains("\"ephemeral_public_key\":"));
        assert!(json.contains("\"ciphertext\":"));

        // Verify base64 values are valid
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

    /// Decrypting with the wrong provider key should fail.
    #[test]
    fn test_encrypted_payload_wrong_provider_key_fails() {
        use base64::Engine;

        let provider = NodeKeyPair::generate();
        let wrong_provider = NodeKeyPair::generate();

        // Encrypt for `provider`
        let ephemeral_secret = SecretKey::generate(&mut OsRng);
        let ephemeral_public = ephemeral_secret.public_key().clone();
        let provider_pk = PublicKey::from(provider.public_key_bytes());
        let salsa_box = SalsaBox::new(&provider_pk, &ephemeral_secret);
        let nonce = SalsaBox::generate_nonce(&mut OsRng);
        let encrypted = salsa_box.encrypt(&nonce, &b"secret data"[..]).unwrap();

        let mut combined = Vec::new();
        combined.extend_from_slice(&nonce);
        combined.extend_from_slice(&encrypted);

        // Try to decrypt with `wrong_provider` — should fail
        let ephemeral_pub_bytes = ephemeral_public.to_bytes();
        let result = wrong_provider.decrypt(&ephemeral_pub_bytes, &combined);
        assert!(result.is_err(), "Decryption with wrong key should fail");
    }

    /// Verify that decrypted JSON can be parsed as a valid inference request body.
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

        // Encrypt
        let provider_pk = PublicKey::from(provider.public_key_bytes());
        let salsa_box = SalsaBox::new(&provider_pk, &ephemeral_secret);
        let nonce = SalsaBox::generate_nonce(&mut OsRng);
        let encrypted = salsa_box.encrypt(&nonce, &plaintext[..]).unwrap();

        let mut combined = Vec::new();
        combined.extend_from_slice(&nonce);
        combined.extend_from_slice(&encrypted);

        // Decrypt
        let ephemeral_pub_bytes = ephemeral_public.to_bytes();
        let decrypted = provider.decrypt(&ephemeral_pub_bytes, &combined).unwrap();

        // Parse as JSON and verify fields
        let parsed: serde_json::Value = serde_json::from_slice(&decrypted).unwrap();
        assert_eq!(parsed["model"], "mlx-community/Qwen2.5-7B-4bit");
        assert_eq!(parsed["stream"], true);
        assert_eq!(parsed["temperature"], 0.7);
        let messages = parsed["messages"].as_array().unwrap();
        assert_eq!(messages.len(), 2);
        assert_eq!(messages[1]["content"], "What is 2+2?");
    }
}
