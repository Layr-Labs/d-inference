//! NaCl Box compatibility helpers.
//!
//! The Go coordinator uses `golang.org/x/crypto/nacl/box` with a random nonce
//! prepended. Milestone 1 goldens exercise the same construction via crypto_box.

use crypto_box::{
    aead::{Aead, AeadCore, OsRng},
    PublicKey, SecretKey, SalsaBox,
};
use thiserror::Error;
use zeroize::Zeroize;

const NONCE_LEN: usize = 24;

#[derive(Debug, Error)]
pub enum BoxError {
    #[error("invalid key length")]
    BadKey,
    #[error("ciphertext too short")]
    Truncated,
    #[error("decrypt failed")]
    Decrypt,
    #[error("encrypt failed")]
    Encrypt,
}

/// Encrypt with an ephemeral sender key.
/// Layout: `nonce(24) || ephemeral_public_key(32) || ciphertext`.
pub fn seal_box(recipient_pk: &[u8; 32], plaintext: &[u8]) -> Result<Vec<u8>, BoxError> {
    let recipient = PublicKey::from(*recipient_pk);
    let ephemeral = SecretKey::generate(&mut OsRng);
    let nonce = SalsaBox::generate_nonce(&mut OsRng);
    let box_ = SalsaBox::new(&recipient, &ephemeral);
    let ciphertext = box_.encrypt(&nonce, plaintext).map_err(|_| BoxError::Encrypt)?;

    let mut out = Vec::with_capacity(NONCE_LEN + 32 + ciphertext.len());
    out.extend_from_slice(&nonce);
    out.extend_from_slice(ephemeral.public_key().as_bytes());
    out.extend_from_slice(&ciphertext);

    let mut doomed = ephemeral.to_bytes();
    doomed.zeroize();
    Ok(out)
}

/// Decrypt a blob produced by [`seal_box`].
pub fn open_box(recipient_sk: &[u8; 32], sealed: &[u8]) -> Result<Vec<u8>, BoxError> {
    if sealed.len() < NONCE_LEN + 32 + 16 {
        return Err(BoxError::Truncated);
    }
    let nonce = crypto_box::Nonce::from_slice(&sealed[..NONCE_LEN]);
    let eph_bytes: [u8; 32] = sealed[NONCE_LEN..NONCE_LEN + 32]
        .try_into()
        .map_err(|_| BoxError::BadKey)?;
    let eph_pk = PublicKey::from(eph_bytes);
    let sk = SecretKey::from(*recipient_sk);
    let box_ = SalsaBox::new(&eph_pk, &sk);
    box_
        .decrypt(nonce, &sealed[NONCE_LEN + 32..])
        .map_err(|_| BoxError::Decrypt)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trip() {
        let sk = SecretKey::generate(&mut OsRng);
        let sealed = seal_box(sk.public_key().as_bytes(), b"hello darkbloom").unwrap();
        let plain = open_box(&sk.to_bytes(), &sealed).unwrap();
        assert_eq!(plain, b"hello darkbloom");
    }
}
