//! Per-attempt request encryption and chunk decryption (plan §15.4).
//!
//! Key model, mirroring the Go coordinator (`consumer.go` dispatch + the
//! `chunkKeyCache`):
//!
//! - **v1**: each attempt generates a fresh X25519 session keypair. The
//!   request body is NaCl-Box sealed to the provider's registered public
//!   key with the session secret; the envelope's `ephemeral_public_key` IS
//!   the session public key, and the provider seals response chunks back to
//!   it with its registered key. One shared key per attempt is precomputed
//!   (`box.Precompute` equivalent) so per-chunk decryption is a symmetric
//!   open only. The provider session forwards v1 chunk payloads as RAW
//!   ciphertext bytes (base64-decoded `nonce || box`); this task owns the
//!   key material and the decryption.
//! - **v2**: the prepare body is sealed to the provider key with the
//!   COORDINATOR's long-lived identity secret (the binary frame header,
//!   plan §15.3, has no ephemeral-key field; the provider learns the
//!   coordinator key at registration). Response chunks are sealed back to
//!   the coordinator key, so the per-attempt shared key is
//!   `precompute(provider_pub, coordinator_secret)`.
//!
//! The `request_digest` fencing value (plan §10.2) is `SHA-256(nonce ||
//! box)` of the encrypted body — the canonical encrypted request envelope.
//!
//! Nothing here logs plaintext, ciphertext, or key bytes.

use bytes::Bytes;
use sha2::{Digest, Sha256};

use darkbloom_protocol::crypto::nacl_box::{self, PublicKey, SecretKey, SharedKey, NONCE_LEN};
use darkbloom_protocol::json_v1::EncryptedPayload;
use darkbloom_protocol::json_v2::RequestDigest;

/// Key material for one attempt's encrypted leg.
pub struct AttemptCrypto {
    /// Shared key for decrypting provider→coordinator chunks.
    chunk_shared: SharedKey,
}

/// A sealed request body plus the fencing digest derived from it.
pub struct SealedBody {
    /// `nonce || box` ciphertext bytes.
    pub ciphertext: Vec<u8>,
    /// Base64 sender public key as it appears on a v1 envelope.
    pub sender_public_b64: String,
    pub digest: RequestDigest,
}

#[derive(Debug, thiserror::Error)]
pub enum CryptoSetupError {
    #[error("provider public key invalid")]
    BadProviderKey,
    #[error("encryption failed")]
    EncryptFailed,
}

impl AttemptCrypto {
    /// v1: fresh session keypair per attempt; chunks come back sealed to it
    /// with the provider's registered key.
    pub fn seal_v1(
        provider_public_b64: &str,
        plaintext: &[u8],
    ) -> Result<(Self, SealedBody), CryptoSetupError> {
        let provider_pub = parse_provider(provider_public_b64)?;
        let (session_pub, session_secret) = nacl_box::generate_keypair();
        let sealed = seal_to(&provider_pub, &session_secret, &session_pub, plaintext)?;
        let chunk_shared = nacl_box::precompute_shared_key(&provider_pub, &session_secret);
        Ok((Self { chunk_shared }, sealed))
    }

    /// v2: sealed with the coordinator identity secret; chunks come back
    /// sealed to the coordinator key.
    pub fn seal_v2(
        provider_public_b64: &str,
        coordinator_secret: &SecretKey,
        plaintext: &[u8],
    ) -> Result<(Self, SealedBody), CryptoSetupError> {
        let provider_pub = parse_provider(provider_public_b64)?;
        let coordinator_pub = coordinator_secret.public_key();
        let sealed = seal_to(
            &provider_pub,
            coordinator_secret,
            &coordinator_pub,
            plaintext,
        )?;
        let chunk_shared = nacl_box::precompute_shared_key(&provider_pub, coordinator_secret);
        Ok((Self { chunk_shared }, sealed))
    }

    /// Opens one chunk's raw `nonce || box` ciphertext with the precomputed
    /// per-attempt shared key (Go `DecryptWithSharedKey`).
    pub fn open_chunk(&self, ciphertext: &[u8]) -> Option<Bytes> {
        nacl_box::open_bytes_with_shared_key(ciphertext, &self.chunk_shared)
            .ok()
            .map(Bytes::from)
    }
}

fn parse_provider(b64: &str) -> Result<PublicKey, CryptoSetupError> {
    nacl_box::parse_public_key(b64).map_err(|_| CryptoSetupError::BadProviderKey)
}

fn seal_to(
    recipient: &PublicKey,
    sender_secret: &SecretKey,
    sender_public: &PublicKey,
    plaintext: &[u8],
) -> Result<SealedBody, CryptoSetupError> {
    let mut nonce = [0u8; NONCE_LEN];
    rand::RngCore::fill_bytes(&mut rand::rngs::OsRng, &mut nonce);
    let ciphertext = nacl_box::seal_bytes(plaintext, &nonce, recipient, sender_secret)
        .map_err(|_| CryptoSetupError::EncryptFailed)?;
    let digest = RequestDigest(Sha256::digest(&ciphertext).into());
    Ok(SealedBody {
        ciphertext,
        sender_public_b64: nacl_box::encode_public_key(sender_public),
        digest,
    })
}

impl SealedBody {
    /// The v1 wire envelope (`encrypted_body`).
    pub fn v1_payload(&self) -> EncryptedPayload {
        use base64::engine::general_purpose::STANDARD as BASE64;
        use base64::Engine;
        EncryptedPayload {
            ephemeral_public_key: self.sender_public_b64.clone(),
            ciphertext: BASE64.encode(&self.ciphertext),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn v1_round_trip_provider_chunks() {
        let (provider_pub, provider_secret) = nacl_box::generate_keypair();
        let provider_b64 = nacl_box::encode_public_key(&provider_pub);

        let (crypto, sealed) = AttemptCrypto::seal_v1(&provider_b64, b"{\"model\":\"m\"}").unwrap();
        // Provider opens the request with its secret and the envelope key.
        let opened = nacl_box::open(&sealed.v1_payload(), &provider_secret).unwrap();
        assert_eq!(opened, b"{\"model\":\"m\"}");

        // Provider seals a chunk back to the session key with its own key.
        let session_pub = nacl_box::parse_public_key(&sealed.sender_public_b64).unwrap();
        let nonce = [3u8; NONCE_LEN];
        let wire =
            nacl_box::seal_bytes(b"data: {}", &nonce, &session_pub, &provider_secret).unwrap();
        assert_eq!(crypto.open_chunk(&wire).unwrap().as_ref(), b"data: {}");
    }

    #[test]
    fn v2_uses_coordinator_identity() {
        let (provider_pub, provider_secret) = nacl_box::generate_keypair();
        let provider_b64 = nacl_box::encode_public_key(&provider_pub);
        let (_, coordinator_secret) = nacl_box::generate_keypair();

        let (crypto, sealed) =
            AttemptCrypto::seal_v2(&provider_b64, &coordinator_secret, b"body").unwrap();
        let opened = nacl_box::open_bytes(
            &sealed.ciphertext,
            &coordinator_secret.public_key(),
            &provider_secret,
        )
        .unwrap();
        assert_eq!(opened, b"body");

        let nonce = [9u8; NONCE_LEN];
        let wire = nacl_box::seal_bytes(
            b"chunk",
            &nonce,
            &coordinator_secret.public_key(),
            &provider_secret,
        )
        .unwrap();
        assert_eq!(crypto.open_chunk(&wire).unwrap().as_ref(), b"chunk");
    }

    #[test]
    fn digest_is_over_ciphertext() {
        let (provider_pub, _) = nacl_box::generate_keypair();
        let provider_b64 = nacl_box::encode_public_key(&provider_pub);
        let (_, sealed) = AttemptCrypto::seal_v1(&provider_b64, b"x").unwrap();
        let expect: [u8; 32] = Sha256::digest(&sealed.ciphertext).into();
        assert_eq!(sealed.digest, RequestDigest(expect));
    }
}
