use thiserror::Error;

/// Errors produced while parsing JSON or protocol-v2 binary frames.
#[derive(Debug, Error)]
pub enum ProtocolError {
    #[error("invalid JSON: {0}")]
    Json(#[from] serde_json::Error),
    #[error("unknown message type {0:?}")]
    UnknownMessageType(String),
    #[error("protocol-v2 header is truncated: got {actual} bytes, need {required}")]
    TruncatedHeader { actual: usize, required: usize },
    #[error("invalid protocol-v2 magic")]
    InvalidMagic,
    #[error("invalid protocol-v2 header length {0}")]
    InvalidHeaderLength(u16),
    #[error("unsupported protocol major {0}")]
    UnsupportedMajor(u16),
    #[error("unknown protocol-v2 frame kind {0}")]
    UnknownFrameKind(u8),
    #[error("unknown protocol-v2 frame flags 0x{0:02x}")]
    UnknownFrameFlags(u8),
    #[error("ciphertext length {actual} exceeds hard limit {maximum}")]
    CiphertextTooLarge { actual: usize, maximum: usize },
    #[error("protocol-v2 frame length mismatch: got {actual}, expected {expected}")]
    FrameLengthMismatch { actual: usize, expected: usize },
    #[error("ciphertext length {0} cannot be represented on the wire")]
    CiphertextLengthOverflow(usize),
    #[error("invalid UUID text {0:?}")]
    InvalidUuid(String),
    #[error("protocol-v2 registration is missing provider_process_generation")]
    MissingProviderProcessGeneration,
}

/// NaCl Box and sender-seal validation errors.
#[derive(Debug, Error)]
pub enum CryptoError {
    #[error("invalid protocol frame: {0}")]
    Protocol(#[from] ProtocolError),
    #[error("{field} is not valid base64: {source}")]
    InvalidBase64 {
        field: &'static str,
        #[source]
        source: base64::DecodeError,
    },
    #[error("{field} decoded to {actual} bytes, expected {expected}")]
    InvalidLength {
        field: &'static str,
        actual: usize,
        expected: usize,
    },
    #[error("ciphertext is shorter than nonce plus authenticator")]
    TruncatedCiphertext,
    #[error("NaCl Box authentication failed")]
    AuthenticationFailed,
    #[error("NaCl Box encryption failed")]
    EncryptionFailed,
    #[error("decrypted protocol-v2 frame is shorter than its binding prefix")]
    TruncatedFrameBinding,
    #[error("authenticated inner protocol-v2 header does not match the outer header")]
    FrameHeaderBindingMismatch,
}

/// Canonical terminal validation errors.
#[derive(Debug, Error, PartialEq, Eq)]
pub enum TerminalError {
    #[error("terminal identity does not match the active attempt")]
    IdentityMismatch,
    #[error("terminal digest does not match canonical terminal bytes")]
    DigestMismatch,
    #[error("terminal signature is empty")]
    MissingSignature,
    #[error("terminal signature does not verify for the provider identity")]
    SignatureIdentityMismatch,
}
