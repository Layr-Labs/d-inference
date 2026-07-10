//! Wire protocol types shared with the Swift provider.
//!
//! Milestone 1 delivers v1 JSON compatibility. Protocol v2 (prepare/start,
//! binary encrypted payload frames, durable terminals) lands in Milestone 2.

#![deny(unsafe_code)]

pub mod crypto;
pub mod messages;
pub mod v2;

pub use crypto::{open_box, seal_box, BoxError};
pub use messages::{MessageType, ProtocolError, WireMessage};
