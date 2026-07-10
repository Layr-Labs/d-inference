//! Versioned wire contracts shared by the Rust coordinator and Swift provider.

/// The deployed JSON WebSocket protocol.
pub const PROTOCOL_V1_MAJOR: u16 = 1;

/// The prepared-lease and binary-payload protocol under migration.
pub const PROTOCOL_V2_MAJOR: u16 = 2;

/// Fixed header length for protocol-v2 encrypted payload frames.
pub const V2_BINARY_HEADER_LEN: usize = 192;
