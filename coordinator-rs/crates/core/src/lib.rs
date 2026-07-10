//! Pure state and policy for the Rust coordinator.

/// Compatibility boundary exported by the pure core.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct ProtocolSupport {
    /// Oldest protocol major this coordinator can decode.
    pub minimum_major: u16,
    /// Preferred protocol major for capable providers.
    pub preferred_major: u16,
}

impl Default for ProtocolSupport {
    fn default() -> Self {
        Self {
            minimum_major: darkbloom_coordinator_protocol::PROTOCOL_V1_MAJOR,
            preferred_major: darkbloom_coordinator_protocol::PROTOCOL_V2_MAJOR,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::ProtocolSupport;

    #[test]
    fn protocol_support_spans_v1_migration_to_v2() {
        let support = ProtocolSupport::default();
        assert_eq!(support.minimum_major, 1);
        assert_eq!(support.preferred_major, 2);
    }
}
