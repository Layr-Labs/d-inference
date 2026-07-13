//! Versioned wire contracts shared by the coordinator and provider.

#![forbid(unsafe_code)]

pub mod crypto;
pub mod error;
pub mod limits;
pub mod raw_json;
pub mod v1;
pub mod v2;

pub use error::{CryptoError, ProtocolError, TerminalError};
pub use limits::{
    MAX_V2_BINARY_FRAME_LEN, MAX_V2_CIPHERTEXT_LEN, PROTOCOL_V1_MAJOR, PROTOCOL_V2_MAJOR,
    V2_BINARY_HEADER_LEN,
};
