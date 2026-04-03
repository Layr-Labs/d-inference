//! NaCl Box encryption primitives for the DGInf provider.
//!
//! Uses NaCl crypto_box (X25519 + XSalsa20-Poly1305) for cross-language
//! compatibility with PyNaCl on the consumer side.
//!
//! The provider's X25519 key pair is derived from the Secure Enclave at
//! startup via `dginf-enclave derive-e2e-key`. The private key exists only
//! in process memory and is never written to disk. The derivation is
//! deterministic (same SE chip = same X25519 key), so the public key is
//! stable across restarts.
//!
//! Fallback: if the Secure Enclave is unavailable, the key is loaded from
//! ~/.dginf/node_key (32 bytes, 0600 perms).

use anyhow::{Context, Result};
use crypto_box::{
    PublicKey, SalsaBox, SecretKey,
    aead::{Aead, AeadCore, OsRng},
};
use std::path::Path;

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

    /// Derive the E2E key pair from the Secure Enclave, falling back to file.
    ///
    /// Primary path: calls `dginf-enclave derive-e2e-key` which performs ECDH
    /// inside the SE hardware and returns a deterministic X25519 key. The
    /// private key never touches disk.
    ///
    /// Fallback: loads from `~/.dginf/node_key` if the SE is unavailable.
    pub fn load_or_generate(path: &Path) -> Result<Self> {
        match Self::from_secure_enclave() {
            Ok(kp) => {
                tracing::info!("E2E key derived from Secure Enclave (never on disk)");
                // Remove any legacy file-based key so it can't be extracted
                if path.exists() {
                    let _ = std::fs::remove_file(path);
                    tracing::info!("Removed legacy E2E key file: {}", path.display());
                }
                Ok(kp)
            }
            Err(e) => {
                tracing::warn!("SE E2E key derivation failed ({e}), falling back to file");
                if path.exists() {
                    Self::load(path)
                } else {
                    let kp = Self::generate();
                    kp.save(path)?;
                    Ok(kp)
                }
            }
        }
    }

    fn from_secure_enclave() -> Result<Self> {
        let enclave_bin = enclave_binary_path();
        if !enclave_bin.exists() {
            anyhow::bail!("dginf-enclave not found at {}", enclave_bin.display());
        }

        let output = std::process::Command::new(&enclave_bin)
            .args(["derive-e2e-key"])
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped())
            .output()
            .context("failed to run dginf-enclave derive-e2e-key")?;

        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            anyhow::bail!("dginf-enclave derive-e2e-key failed: {}", stderr.trim());
        }

        let json: serde_json::Value = serde_json::from_slice(&output.stdout)
            .context("failed to parse derive-e2e-key JSON")?;

        let private_key_b64 = json["private_key"]
            .as_str()
            .context("missing 'private_key' in derive-e2e-key output")?;

        use base64::Engine;
        let key_bytes = base64::engine::general_purpose::STANDARD
            .decode(private_key_b64)
            .context("invalid base64 in derived key")?;

        if key_bytes.len() != 32 {
            anyhow::bail!("derived key is {} bytes, expected 32", key_bytes.len());
        }

        let mut arr = [0u8; 32];
        arr.copy_from_slice(&key_bytes);
        let secret = SecretKey::from(arr);
        let public = secret.public_key().clone();
        Ok(Self { secret, public })
    }

    /// Load a key pair from a raw 32-byte secret key file.
    fn load(path: &Path) -> Result<Self> {
        let bytes = std::fs::read(path)
            .with_context(|| format!("failed to read key from {}", path.display()))?;
        if bytes.len() != 32 {
            anyhow::bail!(
                "invalid key file {}: expected 32 bytes, got {}",
                path.display(),
                bytes.len()
            );
        }
        let mut key_bytes = [0u8; 32];
        key_bytes.copy_from_slice(&bytes);
        let secret = SecretKey::from(key_bytes);
        let public = secret.public_key().clone();
        Ok(Self { secret, public })
    }

    /// Save the secret key to disk with restrictive permissions (0600).
    fn save(&self, path: &Path) -> Result<()> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)
                .with_context(|| format!("failed to create directory {}", parent.display()))?;
        }

        let secret_bytes = self.secret.to_bytes();
        std::fs::write(path, secret_bytes)
            .with_context(|| format!("failed to write key to {}", path.display()))?;

        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let perms = std::fs::Permissions::from_mode(0o600);
            std::fs::set_permissions(path, perms)
                .with_context(|| format!("failed to set permissions on {}", path.display()))?;
        }

        Ok(())
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

/// Return the default path for the node key file: ~/.dginf/node_key
pub fn default_key_path() -> Result<std::path::PathBuf> {
    let home = dirs::home_dir().context("could not determine home directory")?;
    Ok(home.join(".dginf").join("node_key"))
}

fn enclave_binary_path() -> std::path::PathBuf {
    let dginf_dir = dirs::home_dir()
        .unwrap_or_else(|| std::path::PathBuf::from("."))
        .join(".dginf");

    let bin_path = dginf_dir.join("bin/dginf-enclave");
    if bin_path.exists() {
        return bin_path;
    }

    let legacy_path = dginf_dir.join("dginf-enclave");
    if legacy_path.exists() {
        return legacy_path;
    }

    bin_path
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    #[test]
    fn test_generate_key_pair() {
        let kp = NodeKeyPair::generate();
        let pk_b64 = kp.public_key_base64();
        assert!(!pk_b64.is_empty());

        // Base64 of 32 bytes should be 44 chars (with padding)
        assert_eq!(pk_b64.len(), 44);
    }

    #[test]
    fn test_save_and_load() {
        let tmp = tempdir().unwrap();
        let path = tmp.path().join("node_key");

        let kp = NodeKeyPair::generate();
        kp.save(&path).unwrap();

        assert!(path.exists());

        // Check permissions on Unix
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let meta = std::fs::metadata(&path).unwrap();
            assert_eq!(meta.permissions().mode() & 0o777, 0o600);
        }

        let loaded = NodeKeyPair::load(&path).unwrap();
        assert_eq!(
            kp.public_key_base64(),
            loaded.public_key_base64(),
            "loaded key should match saved key"
        );
    }

    #[test]
    fn test_load_or_generate_creates_new() {
        let tmp = tempdir().unwrap();
        let path = tmp.path().join("node_key");

        assert!(!path.exists());
        let kp = NodeKeyPair::load_or_generate(&path).unwrap();
        assert!(path.exists());

        // Load again should return the same key
        let kp2 = NodeKeyPair::load_or_generate(&path).unwrap();
        assert_eq!(kp.public_key_base64(), kp2.public_key_base64());
    }

    #[test]
    fn test_load_or_generate_loads_existing() {
        let tmp = tempdir().unwrap();
        let path = tmp.path().join("node_key");

        let kp1 = NodeKeyPair::generate();
        kp1.save(&path).unwrap();

        let kp2 = NodeKeyPair::load_or_generate(&path).unwrap();
        assert_eq!(kp1.public_key_base64(), kp2.public_key_base64());
    }

    #[test]
    fn test_load_invalid_file() {
        let tmp = tempdir().unwrap();
        let path = tmp.path().join("bad_key");
        std::fs::write(&path, b"too short").unwrap();

        let result = NodeKeyPair::load(&path);
        assert!(result.is_err());
        assert!(
            result
                .unwrap_err()
                .to_string()
                .contains("expected 32 bytes")
        );
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
