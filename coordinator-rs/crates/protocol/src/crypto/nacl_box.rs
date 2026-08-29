//! NaCl Box compatibility with Go `golang.org/x/crypto/nacl/box` and the
//! Swift provider (swift-sodium).
//!
//! Wire format (Go `coordinator/internal/e2e`):
//! - [`EncryptedPayload.ephemeral_public_key`]: base64 of the sender's
//!   32-byte X25519 public key.
//! - [`EncryptedPayload.ciphertext`]: base64 of `24-byte nonce ||
//!   XSalsa20-Poly1305 box output`.
//!
//! The construction is exactly `crypto_box` (X25519 → HSalsa20 KDF →
//! XSalsa20-Poly1305), so [`crypto_box::SalsaBox`] interoperates directly.
//! [`precompute_shared_key`] reproduces Go `box.Precompute` byte-for-byte:
//! `HSalsa20(X25519(secret, public), zeros)` — one scalar multiplication for
//! a whole stream of chunks, with [`open_with_shared_key`] mirroring
//! `box.OpenAfterPrecomputation` on the per-chunk hot path.
//!
//! Secrets: [`crypto_box::SecretKey`] zeroizes on drop; [`SharedKey`] does
//! too. Decrypted plaintext is returned to the caller, who owns its
//! lifetime (plan §15.4).
//!
//! [`EncryptedPayload.ephemeral_public_key`]: crate::json_v1::EncryptedPayload
//! [`EncryptedPayload.ciphertext`]: crate::json_v1::EncryptedPayload

use base64::engine::general_purpose::STANDARD as BASE64;
use base64::Engine;
use crypto_box::aead::generic_array::GenericArray;
use crypto_box::aead::Aead;
use crypto_secretbox::aead::KeyInit;
use crypto_secretbox::XSalsa20Poly1305;
use curve25519_dalek::montgomery::MontgomeryPoint;
use rand::rngs::OsRng;
use rand::RngCore;
use salsa20::cipher::consts::U10;
use zeroize::{Zeroize, ZeroizeOnDrop};

use super::CryptoError;
use crate::json_v1::EncryptedPayload;

pub use crypto_box::{PublicKey, SecretKey};

/// NaCl Box nonce length.
pub const NONCE_LEN: usize = 24;

/// X25519 key length.
pub const KEY_LEN: usize = 32;

/// Generates a fresh X25519 keypair from the OS RNG.
pub fn generate_keypair() -> (PublicKey, SecretKey) {
    let mut bytes = [0u8; KEY_LEN];
    OsRng.fill_bytes(&mut bytes);
    let secret = SecretKey::from(bytes);
    bytes.zeroize();
    (secret.public_key(), secret)
}

/// Parses a base64-encoded 32-byte X25519 public key (Go `ParsePublicKey`).
pub fn parse_public_key(b64: &str) -> Result<PublicKey, CryptoError> {
    let bytes = BASE64
        .decode(b64)
        .map_err(|_| CryptoError::InvalidPublicKeyEncoding)?;
    let arr: [u8; KEY_LEN] = bytes
        .as_slice()
        .try_into()
        .map_err(|_| CryptoError::InvalidPublicKeyLength(bytes.len()))?;
    Ok(PublicKey::from(arr))
}

/// Encodes a public key the way every wire field carries it: standard base64.
pub fn encode_public_key(key: &PublicKey) -> String {
    BASE64.encode(key.as_bytes())
}

/// Seals `plaintext` to `recipient` with a fresh random nonce (Go `Encrypt`).
/// The sender's public key is derived from `sender_secret` and embedded in
/// the payload.
pub fn seal(
    plaintext: &[u8],
    recipient: &PublicKey,
    sender_secret: &SecretKey,
) -> Result<EncryptedPayload, CryptoError> {
    let mut nonce = [0u8; NONCE_LEN];
    OsRng.fill_bytes(&mut nonce);
    seal_with_nonce(plaintext, &nonce, recipient, sender_secret)
}

/// Deterministic seal with a caller-supplied nonce.
///
/// Nonce reuse under the same key pair breaks XSalsa20-Poly1305; use this
/// only for fixed-vector interop tests or when the caller manages nonce
/// uniqueness itself.
pub fn seal_with_nonce(
    plaintext: &[u8],
    nonce: &[u8; NONCE_LEN],
    recipient: &PublicKey,
    sender_secret: &SecretKey,
) -> Result<EncryptedPayload, CryptoError> {
    let wire = seal_bytes(plaintext, nonce, recipient, sender_secret)?;
    Ok(EncryptedPayload {
        ephemeral_public_key: encode_public_key(&sender_secret.public_key()),
        ciphertext: BASE64.encode(wire),
    })
}

/// Opens a payload with the recipient's secret key (Go `Decrypt` /
/// `DecryptWithPrivateKey`): the sender's public key comes from the payload.
pub fn open(
    payload: &EncryptedPayload,
    recipient_secret: &SecretKey,
) -> Result<Vec<u8>, CryptoError> {
    let sender_pub = parse_public_key(&payload.ephemeral_public_key)?;
    let wire = BASE64
        .decode(&payload.ciphertext)
        .map_err(|_| CryptoError::InvalidCiphertextEncoding)?;
    open_bytes(&wire, &sender_pub, recipient_secret)
}

/// Seals raw bytes, returning `nonce || box_output` (the inner format of
/// every `ciphertext` field).
pub fn seal_bytes(
    plaintext: &[u8],
    nonce: &[u8; NONCE_LEN],
    their_public: &PublicKey,
    my_secret: &SecretKey,
) -> Result<Vec<u8>, CryptoError> {
    let sbox = crypto_box::SalsaBox::new(their_public, my_secret);
    let ct = sbox
        .encrypt(GenericArray::from_slice(nonce), plaintext)
        .map_err(|_| CryptoError::EncryptionFailed)?;
    let mut wire = Vec::with_capacity(NONCE_LEN + ct.len());
    wire.extend_from_slice(nonce);
    wire.extend_from_slice(&ct);
    Ok(wire)
}

/// Opens `nonce || box_output` bytes.
pub fn open_bytes(
    wire: &[u8],
    their_public: &PublicKey,
    my_secret: &SecretKey,
) -> Result<Vec<u8>, CryptoError> {
    if wire.len() < NONCE_LEN {
        return Err(CryptoError::CiphertextTooShort);
    }
    let (nonce, ct) = wire.split_at(NONCE_LEN);
    let sbox = crypto_box::SalsaBox::new(their_public, my_secret);
    sbox.decrypt(GenericArray::from_slice(nonce), ct)
        .map_err(|_| CryptoError::DecryptionFailed)
}

/// A precomputed NaCl Box shared key, byte-identical to Go `box.Precompute`.
/// Zeroized on drop.
#[derive(Clone, Zeroize, ZeroizeOnDrop)]
pub struct SharedKey([u8; KEY_LEN]);

impl SharedKey {
    /// Raw key bytes — needed for cross-language equality assertions.
    pub fn as_bytes(&self) -> &[u8; KEY_LEN] {
        &self.0
    }
}

impl std::fmt::Debug for SharedKey {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("SharedKey(..)")
    }
}

/// Derives the NaCl Box shared key for `(peer_public, my_secret)` once, so a
/// stream of chunks from one peer skips the per-message X25519 scalar
/// multiplication (Go `box.Precompute`): `HSalsa20(X25519(secret, public),
/// zeros)`. Symmetric: both sides derive the same key.
pub fn precompute_shared_key(peer_public: &PublicKey, my_secret: &SecretKey) -> SharedKey {
    let product = MontgomeryPoint(*peer_public.as_bytes()).mul_clamped(my_secret.to_bytes());
    let key = salsa20::hsalsa::<U10>(
        GenericArray::from_slice(&product.0),
        &GenericArray::default(),
    );
    SharedKey(key.into())
}

/// Opens a payload's `ciphertext` with a precomputed shared key (Go
/// `DecryptWithSharedKey` / `box.OpenAfterPrecomputation`).
///
/// The caller MUST have already verified that the payload's
/// `ephemeral_public_key` is the peer key the shared key was derived from —
/// this performs only the symmetric open.
pub fn open_with_shared_key(
    payload: &EncryptedPayload,
    shared: &SharedKey,
) -> Result<Vec<u8>, CryptoError> {
    let wire = BASE64
        .decode(&payload.ciphertext)
        .map_err(|_| CryptoError::InvalidCiphertextEncoding)?;
    open_bytes_with_shared_key(&wire, shared)
}

/// Opens `nonce || box_output` bytes with a precomputed shared key.
pub fn open_bytes_with_shared_key(wire: &[u8], shared: &SharedKey) -> Result<Vec<u8>, CryptoError> {
    if wire.len() < NONCE_LEN {
        return Err(CryptoError::CiphertextTooShort);
    }
    let (nonce, ct) = wire.split_at(NONCE_LEN);
    let sb = XSalsa20Poly1305::new(GenericArray::from_slice(&shared.0));
    crypto_box::aead::Aead::decrypt(&sb, GenericArray::from_slice(nonce), ct)
        .map_err(|_| CryptoError::DecryptionFailed)
}

/// Seals raw bytes with a precomputed shared key (Go
/// `box.SealAfterPrecomputation`), returning `nonce || box_output`.
pub fn seal_bytes_with_shared_key(
    plaintext: &[u8],
    nonce: &[u8; NONCE_LEN],
    shared: &SharedKey,
) -> Result<Vec<u8>, CryptoError> {
    let sb = XSalsa20Poly1305::new(GenericArray::from_slice(&shared.0));
    let ct = crypto_box::aead::Aead::encrypt(&sb, GenericArray::from_slice(nonce), plaintext)
        .map_err(|_| CryptoError::EncryptionFailed)?;
    let mut wire = Vec::with_capacity(NONCE_LEN + ct.len());
    wire.extend_from_slice(nonce);
    wire.extend_from_slice(&ct);
    Ok(wire)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn seal_open_round_trip() {
        let (provider_pub, provider_secret) = generate_keypair();
        let (_, session_secret) = generate_keypair();
        for plaintext in [&b""[..], b"x", "こんにちは 🌍".as_bytes()] {
            let payload = seal(plaintext, &provider_pub, &session_secret).unwrap();
            let opened = open(&payload, &provider_secret).unwrap();
            assert_eq!(opened, plaintext);
        }
    }

    #[test]
    fn shared_key_paths_agree_with_direct_box() {
        let (provider_pub, provider_secret) = generate_keypair();
        let (session_pub, session_secret) = generate_keypair();

        let a = precompute_shared_key(&provider_pub, &session_secret);
        let b = precompute_shared_key(&session_pub, &provider_secret);
        assert_eq!(a.as_bytes(), b.as_bytes());

        let payload = seal(b"chunk", &provider_pub, &session_secret).unwrap();
        assert_eq!(open_with_shared_key(&payload, &b).unwrap(), b"chunk");

        let nonce = [7u8; NONCE_LEN];
        let wire = seal_bytes_with_shared_key(b"reverse", &nonce, &a).unwrap();
        assert_eq!(
            open_bytes(&wire, &session_pub, &provider_secret).unwrap(),
            b"reverse"
        );
    }

    #[test]
    fn tamper_and_wrong_key_fail() {
        let (provider_pub, provider_secret) = generate_keypair();
        let (_, session_secret) = generate_keypair();
        let payload = seal(b"secret", &provider_pub, &session_secret).unwrap();

        let mut wire = BASE64.decode(&payload.ciphertext).unwrap();
        let last = wire.len() - 1;
        wire[last] ^= 1;
        let tampered = EncryptedPayload {
            ephemeral_public_key: payload.ephemeral_public_key.clone(),
            ciphertext: BASE64.encode(&wire),
        };
        assert_eq!(
            open(&tampered, &provider_secret).unwrap_err(),
            CryptoError::DecryptionFailed
        );

        let (_, wrong_secret) = generate_keypair();
        assert_eq!(
            open(&payload, &wrong_secret).unwrap_err(),
            CryptoError::DecryptionFailed
        );
    }

    #[test]
    fn malformed_payloads_are_typed_errors() {
        let (_, secret) = generate_keypair();
        let bad_pub = EncryptedPayload {
            ephemeral_public_key: "!!!".into(),
            ciphertext: BASE64.encode([0u8; 30]),
        };
        assert_eq!(
            open(&bad_pub, &secret).unwrap_err(),
            CryptoError::InvalidPublicKeyEncoding
        );

        let short = EncryptedPayload {
            ephemeral_public_key: BASE64.encode([9u8; 32]),
            ciphertext: BASE64.encode([0u8; 10]),
        };
        assert_eq!(
            open(&short, &secret).unwrap_err(),
            CryptoError::CiphertextTooShort
        );

        let wrong_len = EncryptedPayload {
            ephemeral_public_key: BASE64.encode([9u8; 31]),
            ciphertext: BASE64.encode([0u8; 30]),
        };
        assert_eq!(
            open(&wrong_len, &secret).unwrap_err(),
            CryptoError::InvalidPublicKeyLength(31)
        );
    }
}
