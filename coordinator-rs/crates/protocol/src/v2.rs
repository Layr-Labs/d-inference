//! Protocol v2 types (prepare / start / durable terminals).
//!
//! Stubbed in Milestone 1; fully implemented in Milestone 2.

use serde::{Deserialize, Serialize};

/// Capability flags negotiated at registration.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Capabilities {
    pub prepared_leases: bool,
    pub start_authorization: bool,
    pub structured_errors: bool,
    pub start_ack: bool,
    pub abort_ack: bool,
    pub cancel_ack: bool,
    pub durable_terminals: bool,
    pub model_lifecycle_events: bool,
    pub binary_payload_frames: bool,
}

/// Fixed-size binary encrypted payload header (64 bytes) — layout TBD in M2.
pub const BINARY_PAYLOAD_HEADER_LEN: usize = 64;
