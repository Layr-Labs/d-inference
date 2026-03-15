//! NaCl Box encryption primitives for the DGInf provider.
//!
//! Uses NaCl crypto_box (X25519 + XSalsa20-Poly1305) for cross-language
//! compatibility with PyNaCl on the consumer side.
//!
//! NOTE: This module is NOT currently used in the inference request flow.
//! The provider receives plain JSON from the coordinator (which runs in a
//! GCP Confidential VM). The coordinator handles the consumer trust boundary.
//! This module is kept for future coordinator-to-provider encryption.
//!
//! The provider's X25519 key pair is:
//!   - Generated on first run and saved to ~/.dginf/node_key (32 bytes, 0600 perms)
//!   - Loaded on subsequent runs from the same path
//!   - Public key is sent to the coordinator during registration
//!   - Public key is optionally bound to the Secure Enclave attestation,
//!     proving the same device controls both keys

use anyhow::{Context, Result};
use crypto_box::{
    aead::{Aead, AeadCore, OsRng},
    PublicKey, SalsaBox, SecretKey,
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

    /// Load a key pair from disk, or generate and save a new one.
    pub fn load_or_generate(path: &Path) -> Result<Self> {
        if path.exists() {
            Self::load(path)
        } else {
            let kp = Self::generate();
            kp.save(path)?;
            Ok(kp)
        }
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

        // Set file permissions to 0600 (owner read/write only)
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
        assert!(result.unwrap_err().to_string().contains("expected 32 bytes"));
    }

    #[test]
    fn test_encrypt_decrypt_round_trip() {
        // Simulate provider and consumer key pairs
        let provider = NodeKeyPair::generate();
        let consumer = NodeKeyPair::generate();

        let plaintext = b"Hello, encrypted world!";

        // Consumer encrypts with provider's public key
        let ciphertext = encrypt_with_keypair(
            &consumer.secret,
            &provider.public_key_bytes(),
            plaintext,
        )
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
        let decrypted = decrypt_with_keypair(
            &consumer.secret,
            &provider.public_key_bytes(),
            &ciphertext,
        )
        .unwrap();

        assert_eq!(decrypted, plaintext);
    }

    #[test]
    fn test_decrypt_wrong_key_fails() {
        let provider = NodeKeyPair::generate();
        let consumer = NodeKeyPair::generate();
        let wrong_key = NodeKeyPair::generate();

        let plaintext = b"Secret message";

        let ciphertext = encrypt_with_keypair(
            &consumer.secret,
            &provider.public_key_bytes(),
            plaintext,
        )
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

        let ciphertext = encrypt_with_keypair(
            &consumer.secret,
            &provider.public_key_bytes(),
            plaintext,
        )
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

        let ciphertext = encrypt_with_keypair(
            &consumer.secret,
            &provider.public_key_bytes(),
            &plaintext,
        )
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

        let ct1 = encrypt_with_keypair(
            &consumer.secret,
            &provider.public_key_bytes(),
            plaintext,
        )
        .unwrap();

        let ct2 = encrypt_with_keypair(
            &consumer.secret,
            &provider.public_key_bytes(),
            plaintext,
        )
        .unwrap();

        // Different nonces should produce different ciphertext
        assert_ne!(ct1, ct2);

        // But both should decrypt to the same plaintext
        let d1 = provider.decrypt(&consumer.public_key_bytes(), &ct1).unwrap();
        let d2 = provider.decrypt(&consumer.public_key_bytes(), &ct2).unwrap();
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
}
