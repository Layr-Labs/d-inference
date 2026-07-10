//! NaCl Box compatibility with Go's `golang.org/x/crypto/nacl/box`.

use base64::{Engine, engine::general_purpose::STANDARD};
use bytes::Bytes;
use crypto_box::{
    PublicKey, SalsaBox, SecretKey,
    aead::{Aead, AeadCore, OsRng},
};

use crate::{
    error::{CryptoError, ProtocolError},
    limits::{MAX_V2_CIPHERTEXT_LEN, V2_BINARY_HEADER_LEN},
    v1::EncryptedPayload,
    v2::{BinaryFrameHeader, decode_binary_frame, encode_binary_frame},
};

pub const X25519_KEY_LEN: usize = 32;
pub const NACL_BOX_NONCE_LEN: usize = 24;
pub const NACL_BOX_TAG_LEN: usize = 16;

/// Domain separator for the authenticated inner copy of a v2 binary header.
///
/// The bound plaintext is exactly:
/// `V2_FRAME_BINDING_DOMAIN || encoded_header[192] || application_plaintext`.
pub const V2_FRAME_BINDING_DOMAIN: &[u8] = b"darkbloom.protocol.v2.bound-frame\x00";

pub type BoxPayload = EncryptedPayload;

/// Low-level NaCl Box encryption with explicit keys and nonce.
///
/// This function does not bind protocol-v2 outer metadata. Protocol-v2 callers
/// must use [`seal_v2_frame`] instead.
pub fn encrypt_box(
    sender_private_key: &[u8; X25519_KEY_LEN],
    recipient_public_key: &[u8; X25519_KEY_LEN],
    nonce: &[u8; NACL_BOX_NONCE_LEN],
    plaintext: &[u8],
) -> Result<Vec<u8>, CryptoError> {
    let sender = SecretKey::from(*sender_private_key);
    let recipient = PublicKey::from(*recipient_public_key);
    SalsaBox::new(&recipient, &sender)
        .encrypt(nonce.into(), plaintext)
        .map_err(|_| CryptoError::EncryptionFailed)
}

/// Low-level NaCl Box decryption with explicit keys and nonce.
///
/// Successfully opening ciphertext does not authenticate an adjacent binary
/// header. Protocol-v2 callers must use [`open_v2_frame`] instead.
pub fn decrypt_box(
    recipient_private_key: &[u8; X25519_KEY_LEN],
    sender_public_key: &[u8; X25519_KEY_LEN],
    nonce: &[u8; NACL_BOX_NONCE_LEN],
    ciphertext: &[u8],
) -> Result<Vec<u8>, CryptoError> {
    if ciphertext.len() < NACL_BOX_TAG_LEN {
        return Err(CryptoError::TruncatedCiphertext);
    }
    let recipient = SecretKey::from(*recipient_private_key);
    let sender = PublicKey::from(*sender_public_key);
    SalsaBox::new(&sender, &recipient)
        .decrypt(nonce.into(), ciphertext)
        .map_err(|_| CryptoError::AuthenticationFailed)
}

/// A protocol-v2 frame decrypted only after its authenticated inner header was
/// proven byte-for-byte equal to the validated outer header.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OpenedV2Frame {
    pub header: BinaryFrameHeader,
    pub plaintext: Vec<u8>,
}

/// The safe high-level encryption path for protocol-v2 binary frames.
///
/// This computes `ciphertext_len`, encodes the final outer header, prepends a
/// domain-separated exact copy of those 192 bytes to the plaintext, and then
/// authenticates that inner copy with NaCl Box. Mutating any outer metadata
/// therefore causes [`open_v2_frame`] to reject the frame even though raw NaCl
/// Box decryption would otherwise succeed.
pub fn seal_v2_frame(
    sender_private_key: &[u8; X25519_KEY_LEN],
    recipient_public_key: &[u8; X25519_KEY_LEN],
    mut header: BinaryFrameHeader,
    plaintext: &[u8],
) -> Result<Bytes, CryptoError> {
    let bound_plaintext_len = V2_FRAME_BINDING_DOMAIN
        .len()
        .checked_add(V2_BINARY_HEADER_LEN)
        .and_then(|length| length.checked_add(plaintext.len()))
        .ok_or(ProtocolError::CiphertextLengthOverflow(plaintext.len()))?;
    let ciphertext_len = bound_plaintext_len
        .checked_add(NACL_BOX_TAG_LEN)
        .ok_or(ProtocolError::CiphertextLengthOverflow(plaintext.len()))?;
    if ciphertext_len > MAX_V2_CIPHERTEXT_LEN {
        return Err(ProtocolError::CiphertextTooLarge {
            actual: ciphertext_len,
            maximum: MAX_V2_CIPHERTEXT_LEN,
        }
        .into());
    }
    header.ciphertext_len = u32::try_from(ciphertext_len)
        .map_err(|_| ProtocolError::CiphertextLengthOverflow(ciphertext_len))?;
    let encoded_header = header.encode()?;

    let mut bound_plaintext = Vec::with_capacity(bound_plaintext_len);
    bound_plaintext.extend_from_slice(V2_FRAME_BINDING_DOMAIN);
    bound_plaintext.extend_from_slice(&encoded_header);
    bound_plaintext.extend_from_slice(plaintext);
    let ciphertext = encrypt_box(
        sender_private_key,
        recipient_public_key,
        &header.nonce,
        &bound_plaintext,
    )?;
    if ciphertext.len() != ciphertext_len {
        return Err(CryptoError::EncryptionFailed);
    }
    Ok(encode_binary_frame(&header, &ciphertext)?)
}

/// The safe high-level decryption path for protocol-v2 binary frames.
///
/// No application plaintext is returned until the domain separator and every
/// byte of the authenticated inner header exactly match the outer header.
pub fn open_v2_frame(
    recipient_private_key: &[u8; X25519_KEY_LEN],
    sender_public_key: &[u8; X25519_KEY_LEN],
    wire: &[u8],
) -> Result<OpenedV2Frame, CryptoError> {
    let frame = decode_binary_frame(wire)?;
    let mut bound_plaintext = decrypt_box(
        recipient_private_key,
        sender_public_key,
        &frame.header.nonce,
        frame.ciphertext,
    )?;
    let binding_len = V2_FRAME_BINDING_DOMAIN.len() + V2_BINARY_HEADER_LEN;
    if bound_plaintext.len() < binding_len {
        return Err(CryptoError::TruncatedFrameBinding);
    }
    if !bound_plaintext.starts_with(V2_FRAME_BINDING_DOMAIN)
        || bound_plaintext[V2_FRAME_BINDING_DOMAIN.len()..binding_len]
            != wire[..V2_BINARY_HEADER_LEN]
    {
        return Err(CryptoError::FrameHeaderBindingMismatch);
    }
    bound_plaintext.drain(..binding_len);
    Ok(OpenedV2Frame {
        header: frame.header,
        plaintext: bound_plaintext,
    })
}

/// Seals plaintext with a generated ephemeral sender key and nonce.
pub fn seal_box(
    recipient_public_key: &[u8; X25519_KEY_LEN],
    plaintext: &[u8],
) -> Result<BoxPayload, CryptoError> {
    let ephemeral = SecretKey::generate(&mut OsRng);
    let nonce = SalsaBox::generate_nonce(&mut OsRng);
    seal_box_with(
        &ephemeral.to_bytes(),
        recipient_public_key,
        nonce.as_ref(),
        plaintext,
    )
}

/// Deterministic variant used by cross-language vectors.
pub fn seal_box_with(
    sender_private_key: &[u8; X25519_KEY_LEN],
    recipient_public_key: &[u8; X25519_KEY_LEN],
    nonce: &[u8; NACL_BOX_NONCE_LEN],
    plaintext: &[u8],
) -> Result<BoxPayload, CryptoError> {
    let sender = SecretKey::from(*sender_private_key);
    let ciphertext = encrypt_box(sender_private_key, recipient_public_key, nonce, plaintext)?;
    let mut nonce_and_ciphertext = Vec::with_capacity(NACL_BOX_NONCE_LEN + ciphertext.len());
    nonce_and_ciphertext.extend_from_slice(nonce);
    nonce_and_ciphertext.extend_from_slice(&ciphertext);
    Ok(BoxPayload {
        ephemeral_public_key: STANDARD.encode(sender.public_key().as_bytes()),
        ciphertext: STANDARD.encode(nonce_and_ciphertext),
    })
}

/// Opens the current JSON wire payload (`ephemeral_public_key` plus base64
/// `nonce || ciphertext`).
pub fn open_box(
    recipient_private_key: &[u8; X25519_KEY_LEN],
    payload: &BoxPayload,
) -> Result<Vec<u8>, CryptoError> {
    let sender_public_key =
        decode_array::<X25519_KEY_LEN>("ephemeral_public_key", &payload.ephemeral_public_key)?;
    let nonce_and_ciphertext = decode_base64("ciphertext", &payload.ciphertext)?;
    if nonce_and_ciphertext.len() < NACL_BOX_NONCE_LEN + NACL_BOX_TAG_LEN {
        return Err(CryptoError::TruncatedCiphertext);
    }
    let nonce: [u8; NACL_BOX_NONCE_LEN] = nonce_and_ciphertext[..NACL_BOX_NONCE_LEN]
        .try_into()
        .map_err(|_| CryptoError::TruncatedCiphertext)?;
    decrypt_box(
        recipient_private_key,
        &sender_public_key,
        &nonce,
        &nonce_and_ciphertext[NACL_BOX_NONCE_LEN..],
    )
}

pub fn decode_base64(field: &'static str, encoded: &str) -> Result<Vec<u8>, CryptoError> {
    STANDARD
        .decode(encoded)
        .map_err(|source| CryptoError::InvalidBase64 { field, source })
}

pub fn decode_array<const N: usize>(
    field: &'static str,
    encoded: &str,
) -> Result<[u8; N], CryptoError> {
    let decoded = decode_base64(field, encoded)?;
    let actual = decoded.len();
    decoded.try_into().map_err(|_| CryptoError::InvalidLength {
        field,
        actual,
        expected: N,
    })
}
