use std::{fmt, str::FromStr};

use serde::{Deserialize, Deserializer, Serialize, Serializer, de};

use crate::error::ProtocolError;

/// Raw bytes of a protocol identity encoded as a canonical UUID in JSON.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct UuidBytes([u8; 16]);

impl UuidBytes {
    pub const NIL: Self = Self([0; 16]);

    #[must_use]
    pub const fn new(bytes: [u8; 16]) -> Self {
        Self(bytes)
    }

    #[must_use]
    pub const fn as_bytes(&self) -> &[u8; 16] {
        &self.0
    }

    #[must_use]
    pub const fn into_bytes(self) -> [u8; 16] {
        self.0
    }

    pub fn parse(value: &str) -> Result<Self, ProtocolError> {
        let wire = value.as_bytes();
        let canonical = wire.len() == 36
            && [8, 13, 18, 23].into_iter().all(|index| wire[index] == b'-')
            && wire
                .iter()
                .enumerate()
                .all(|(index, byte)| matches!(index, 8 | 13 | 18 | 23) || byte.is_ascii_hexdigit());
        let compact_form = wire.len() == 32 && wire.iter().all(u8::is_ascii_hexdigit);
        if !canonical && !compact_form {
            return Err(ProtocolError::InvalidUuid(value.to_owned()));
        }

        let mut compact = [0_u8; 32];
        let mut length = 0;
        for byte in value.bytes() {
            if byte == b'-' {
                continue;
            }
            if length == compact.len() || !byte.is_ascii_hexdigit() {
                return Err(ProtocolError::InvalidUuid(value.to_owned()));
            }
            compact[length] = byte;
            length += 1;
        }
        if length != compact.len() {
            return Err(ProtocolError::InvalidUuid(value.to_owned()));
        }

        let mut bytes = [0_u8; 16];
        for (index, chunk) in compact.chunks_exact(2).enumerate() {
            bytes[index] = (hex_nibble(chunk[0]) << 4) | hex_nibble(chunk[1]);
        }
        Ok(Self(bytes))
    }
}

fn hex_nibble(byte: u8) -> u8 {
    match byte {
        b'0'..=b'9' => byte - b'0',
        b'a'..=b'f' => byte - b'a' + 10,
        b'A'..=b'F' => byte - b'A' + 10,
        _ => unreachable!("validated as ASCII hex"),
    }
}

impl fmt::Display for UuidBytes {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        for (index, byte) in self.0.iter().enumerate() {
            if matches!(index, 4 | 6 | 8 | 10) {
                formatter.write_str("-")?;
            }
            write!(formatter, "{byte:02x}")?;
        }
        Ok(())
    }
}

impl FromStr for UuidBytes {
    type Err = ProtocolError;

    fn from_str(value: &str) -> Result<Self, Self::Err> {
        Self::parse(value)
    }
}

impl Serialize for UuidBytes {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        serializer.collect_str(self)
    }
}

impl<'de> Deserialize<'de> for UuidBytes {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        let value = String::deserialize(deserializer)?;
        Self::parse(&value).map_err(de::Error::custom)
    }
}

macro_rules! protocol_id {
    ($name:ident) => {
        #[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
        pub struct $name(UuidBytes);

        impl $name {
            pub const NIL: Self = Self(UuidBytes::NIL);

            #[must_use]
            pub const fn new(bytes: [u8; 16]) -> Self {
                Self(UuidBytes::new(bytes))
            }

            #[must_use]
            pub const fn as_bytes(&self) -> &[u8; 16] {
                self.0.as_bytes()
            }

            #[must_use]
            pub const fn into_bytes(self) -> [u8; 16] {
                self.0.into_bytes()
            }
        }

        impl fmt::Display for $name {
            fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
                self.0.fmt(formatter)
            }
        }

        impl FromStr for $name {
            type Err = ProtocolError;

            fn from_str(value: &str) -> Result<Self, Self::Err> {
                UuidBytes::parse(value).map(Self)
            }
        }

        impl From<[u8; 16]> for $name {
            fn from(value: [u8; 16]) -> Self {
                Self::new(value)
            }
        }

        impl Serialize for $name {
            fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
            where
                S: Serializer,
            {
                self.0.serialize(serializer)
            }
        }

        impl<'de> Deserialize<'de> for $name {
            fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
            where
                D: Deserializer<'de>,
            {
                UuidBytes::deserialize(deserializer).map(Self)
            }
        }
    };
}

protocol_id!(ProviderId);
protocol_id!(ProviderProcessGenerationId);
protocol_id!(RequestId);
protocol_id!(AttemptId);
protocol_id!(ReservationId);
protocol_id!(LeaseId);

/// Compatibility alias for callers that use the shorter generation name.
pub type ProcessGenerationId = ProviderProcessGenerationId;

/// Monotonically increasing epoch for one provider WebSocket session.
#[derive(
    Debug, Clone, Copy, Default, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize,
)]
#[serde(transparent)]
pub struct SessionEpoch(pub u64);

/// Fences provider-scoped events to one process and WebSocket session.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ProviderSessionIdentity {
    pub provider_id: ProviderId,
    pub process_generation: ProviderProcessGenerationId,
    pub session_epoch: SessionEpoch,
}

/// The identities that fence every v2 control and binary frame.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AttemptIdentity {
    pub provider_id: ProviderId,
    pub provider_process_generation: ProviderProcessGenerationId,
    pub session_epoch: SessionEpoch,
    pub request_id: RequestId,
    pub attempt_id: AttemptId,
    pub reservation_id: ReservationId,
    pub lease_id: LeaseId,
}

/// Capability flags advertised during registration.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct ProtocolCapabilities {
    pub protocol_major: u16,
    pub protocol_minor: u16,
    /// Oldest minor version this implementation can interoperate with.
    #[serde(default, skip_serializing_if = "is_zero_u16")]
    pub minimum_compatible_minor: u16,
    #[serde(default, skip_serializing_if = "is_false")]
    pub prepared_leases: bool,
    #[serde(default, skip_serializing_if = "is_false")]
    pub start_authorization: bool,
    #[serde(default, skip_serializing_if = "is_false")]
    pub structured_errors: bool,
    #[serde(default, skip_serializing_if = "is_false")]
    pub start_ack: bool,
    #[serde(default, skip_serializing_if = "is_false")]
    pub abort_ack: bool,
    #[serde(default, skip_serializing_if = "is_false")]
    pub cancel_ack: bool,
    #[serde(default, skip_serializing_if = "is_false")]
    pub durable_terminals: bool,
    #[serde(default, skip_serializing_if = "is_false")]
    pub model_lifecycle_events: bool,
    #[serde(default, skip_serializing_if = "is_false")]
    pub binary_payload_frames: bool,
}

impl ProtocolCapabilities {
    #[must_use]
    pub fn supports_v2(&self) -> bool {
        self.protocol_major == crate::PROTOCOL_V2_MAJOR
            && self.minimum_compatible_minor <= self.protocol_minor
            && self.prepared_leases
            && self.start_authorization
            && self.durable_terminals
    }

    /// Computes the common feature set over the overlap of both supported
    /// minor-version ranges.
    ///
    /// Each side supports `[minimum_compatible_minor, protocol_minor]`.
    /// Different majors, invalid ranges, or disjoint ranges cannot negotiate.
    /// Provider process generation is deliberately absent: it is registration
    /// identity, not a commutative capability.
    #[must_use]
    pub fn negotiate(&self, peer: &Self) -> Option<Self> {
        let negotiated_minimum = self
            .minimum_compatible_minor
            .max(peer.minimum_compatible_minor);
        let negotiated_minor = self.protocol_minor.min(peer.protocol_minor);
        if self.protocol_major != peer.protocol_major
            || self.minimum_compatible_minor > self.protocol_minor
            || peer.minimum_compatible_minor > peer.protocol_minor
            || negotiated_minimum > negotiated_minor
        {
            return None;
        }
        Some(Self {
            protocol_major: self.protocol_major,
            protocol_minor: negotiated_minor,
            minimum_compatible_minor: negotiated_minimum,
            prepared_leases: self.prepared_leases && peer.prepared_leases,
            start_authorization: self.start_authorization && peer.start_authorization,
            structured_errors: self.structured_errors && peer.structured_errors,
            start_ack: self.start_ack && peer.start_ack,
            abort_ack: self.abort_ack && peer.abort_ack,
            cancel_ack: self.cancel_ack && peer.cancel_ack,
            durable_terminals: self.durable_terminals && peer.durable_terminals,
            model_lifecycle_events: self.model_lifecycle_events && peer.model_lifecycle_events,
            binary_payload_frames: self.binary_payload_frames && peer.binary_payload_frames,
        })
    }
}

/// Short compatibility name retained for the capability set.
pub type Capabilities = ProtocolCapabilities;

const fn is_false(value: &bool) -> bool {
    !*value
}

const fn is_zero_u16(value: &u16) -> bool {
    *value == 0
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn uuid_text_round_trip_is_canonical() {
        let id: RequestId = "00112233-4455-6677-8899-aabbccddeeff"
            .parse()
            .expect("valid UUID");
        assert_eq!(id.to_string(), "00112233-4455-6677-8899-aabbccddeeff");
        assert_eq!(
            serde_json::to_string(&id).expect("serialize"),
            r#""00112233-4455-6677-8899-aabbccddeeff""#
        );
        assert!(
            "001122334455-66778899aabbccddeeff"
                .parse::<RequestId>()
                .is_err()
        );
    }

    #[test]
    fn full_capability_set_is_required() {
        let mut capabilities = ProtocolCapabilities {
            protocol_major: 2,
            ..Default::default()
        };
        assert!(!capabilities.supports_v2());
        capabilities.prepared_leases = true;
        capabilities.start_authorization = true;
        capabilities.durable_terminals = true;
        assert!(capabilities.supports_v2());
    }

    #[test]
    fn negotiation_requires_minor_overlap_and_is_commutative() {
        let left = ProtocolCapabilities {
            protocol_major: 2,
            protocol_minor: 5,
            minimum_compatible_minor: 2,
            prepared_leases: true,
            ..Default::default()
        };
        let right = ProtocolCapabilities {
            protocol_major: 2,
            protocol_minor: 3,
            minimum_compatible_minor: 1,
            prepared_leases: true,
            start_ack: true,
            ..Default::default()
        };
        let negotiated = left.negotiate(&right).expect("overlap");
        assert_eq!(negotiated, right.negotiate(&left).expect("commutative"));
        assert_eq!(negotiated.minimum_compatible_minor, 2);
        assert_eq!(negotiated.protocol_minor, 3);
        assert!(negotiated.prepared_leases);
        assert!(!negotiated.start_ack);

        let disjoint = ProtocolCapabilities {
            protocol_major: 2,
            protocol_minor: 8,
            minimum_compatible_minor: 6,
            ..Default::default()
        };
        assert!(right.negotiate(&disjoint).is_none());
    }
}
