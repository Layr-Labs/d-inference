//! Hard protocol limits applied before allocation or typed decoding.

/// The deployed JSON WebSocket protocol.
pub const PROTOCOL_V1_MAJOR: u16 = 1;

/// The prepared-lease and binary-payload protocol.
pub const PROTOCOL_V2_MAJOR: u16 = 2;

/// Fixed header length for protocol-v2 encrypted payload frames.
pub const V2_BINARY_HEADER_LEN: usize = 192;

/// Maximum authenticated ciphertext carried by one protocol-v2 binary frame.
pub const MAX_V2_CIPHERTEXT_LEN: usize = 16 * 1024 * 1024;

/// Maximum complete protocol-v2 binary frame.
pub const MAX_V2_BINARY_FRAME_LEN: usize = V2_BINARY_HEADER_LEN + MAX_V2_CIPHERTEXT_LEN;
