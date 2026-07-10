//! Protocol v2 registration extension (plan §10.1).
//!
//! A dual-stack provider embeds this object in its v1 `register` frame under
//! the `protocol_v2` key. A v1-only coordinator ignores the unknown key; a v2
//! coordinator negotiates from it. Version comparison is never a substitute
//! for capability negotiation: the coordinator sends only frames covered by
//! the advertised capability set.

use std::collections::BTreeSet;

use serde::{Deserialize, Serialize};

/// Well-known capability identifiers. The set is open: unknown capabilities
/// are carried and ignored, so a newer provider can advertise ahead of the
/// coordinator.
pub mod capability {
    /// Prepared leases + start authorization (plan §10.3).
    pub const PREPARED_LEASE: &str = "prepared_lease";
    /// Explicit `started` acknowledgement.
    pub const START_ACK: &str = "start_ack";
    /// Explicit `aborted` acknowledgement + abort tombstones.
    pub const ABORT_ACK: &str = "abort_ack";
    /// Explicit `cancelled` acknowledgement (durably quiescent).
    pub const CANCEL_ACK: &str = "cancel_ack";
    /// Structured error classes (plan §10.5).
    pub const STRUCTURED_ERRORS: &str = "structured_errors";
    /// Signed, journaled, replayed terminals (plan §10.6).
    pub const DURABLE_TERMINALS: &str = "durable_terminals";
    /// `model_ready` / `model_gone` lifecycle events (plan §10.7).
    pub const MODEL_LIFECYCLE: &str = "model_lifecycle";
    /// Binary encrypted-payload frames (plan §15.3).
    pub const BINARY_FRAMES: &str = "binary_frames";
}

/// The key under which the extension rides inside the v1 register frame.
pub const REGISTER_EXTENSION_KEY: &str = "protocol_v2";

/// The v2 registration extension.
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct RegistrationV2 {
    /// Protocol major version. Incompatible framing changes bump this.
    pub protocol_major: u32,
    /// Protocol minor version. Additive changes bump this.
    pub protocol_minor: u32,
    /// Advertised capability set (see [`capability`]). A `BTreeSet` keeps
    /// the wire encoding deterministic.
    pub capabilities: BTreeSet<String>,
    /// Current provider process generation: increments on every process
    /// start, so the coordinator can fence pre-restart state.
    pub process_generation: u64,
}

impl RegistrationV2 {
    /// Whether the provider advertised a capability.
    pub fn supports(&self, cap: &str) -> bool {
        self.capabilities.contains(cap)
    }

    /// Whether the provider supports the full reliable two-phase execution
    /// path required for paid v2 dispatch (plan §10.3, §10.6).
    pub fn supports_paid_v2(&self) -> bool {
        [
            capability::PREPARED_LEASE,
            capability::START_ACK,
            capability::ABORT_ACK,
            capability::CANCEL_ACK,
            capability::STRUCTURED_ERRORS,
            capability::DURABLE_TERMINALS,
        ]
        .iter()
        .all(|c| self.supports(c))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trip_and_negotiation() {
        let reg = RegistrationV2 {
            protocol_major: 2,
            protocol_minor: 0,
            capabilities: [
                capability::PREPARED_LEASE,
                capability::START_ACK,
                capability::ABORT_ACK,
                capability::CANCEL_ACK,
                capability::STRUCTURED_ERRORS,
                capability::DURABLE_TERMINALS,
                "future_unknown_capability",
            ]
            .iter()
            .map(|s| s.to_string())
            .collect(),
            process_generation: 12,
        };
        assert!(reg.supports_paid_v2());
        assert!(!reg.supports(capability::BINARY_FRAMES));

        let json = serde_json::to_string(&reg).unwrap();
        let back: RegistrationV2 = serde_json::from_str(&json).unwrap();
        assert_eq!(back, reg);
    }

    #[test]
    fn missing_any_required_capability_blocks_paid_v2() {
        let mut reg = RegistrationV2 {
            protocol_major: 2,
            protocol_minor: 1,
            capabilities: BTreeSet::new(),
            process_generation: 1,
        };
        assert!(!reg.supports_paid_v2());
        reg.capabilities
            .insert(capability::PREPARED_LEASE.to_owned());
        assert!(!reg.supports_paid_v2());
    }
}
