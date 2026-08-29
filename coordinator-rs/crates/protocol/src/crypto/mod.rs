//! Cryptographic compatibility with the Go coordinator and Swift provider.
//!
//! - [`nacl_box`]: NaCl Box (X25519 + XSalsa20-Poly1305) seal/open matching
//!   Go `golang.org/x/crypto/nacl/box` and the [`EncryptedPayload`] wire
//!   shape, including `box.Precompute`-compatible shared keys for the
//!   per-chunk hot path.
//! - [`sealed_sender`]: the consumer → coordinator sealed-transport envelope
//!   from `coordinator/api/sender_encryption.go` (JSON bodies and SSE
//!   events).
//! - [`signing`]: Secure Enclave P-256 ECDSA verification over challenge
//!   data, raw signed attestation bytes, and the canonical status JSON from
//!   `coordinator/attestation/attestation.go`.
//! - [`terminal_digest`]: the canonical serialization, digest, and signature
//!   domain for protocol-v2 signed terminals.
//!
//! [`EncryptedPayload`]: crate::json_v1::EncryptedPayload

pub mod nacl_box;
pub mod sealed_sender;
pub mod signing;
pub mod terminal_digest;

/// Failures across the crypto modules. Variants never carry key material,
/// plaintext, or ciphertext bytes — only key *identifiers* (kids), which are
/// public values.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum CryptoError {
    #[error("invalid base64 public key")]
    InvalidPublicKeyEncoding,
    #[error("invalid public key length {0} (expected 32)")]
    InvalidPublicKeyLength(usize),
    #[error("invalid base64 ciphertext")]
    InvalidCiphertextEncoding,
    #[error("ciphertext shorter than the 24-byte nonce prefix")]
    CiphertextTooShort,
    #[error("decryption failed — wrong key or tampered data")]
    DecryptionFailed,
    #[error("encryption failed")]
    EncryptionFailed,
    #[error("sealed to kid {got:?} but coordinator key is {expected:?}")]
    KidMismatch { got: String, expected: String },
    #[error("missing 'data: ' SSE prefix")]
    MalformedSseLine,
}
