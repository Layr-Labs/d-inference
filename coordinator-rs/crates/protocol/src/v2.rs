//! Protocol v2 types: prepare/start/terminal and binary payload headers.

use serde::{Deserialize, Serialize};

/// Fixed-size binary encrypted payload header length.
pub const BINARY_PAYLOAD_HEADER_LEN: usize = 64;

/// Capability flags negotiated at registration.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Capabilities {
    pub protocol_major: u16,
    pub protocol_minor: u16,
    #[serde(default)]
    pub prepared_leases: bool,
    #[serde(default)]
    pub start_authorization: bool,
    #[serde(default)]
    pub structured_errors: bool,
    #[serde(default)]
    pub start_ack: bool,
    #[serde(default)]
    pub abort_ack: bool,
    #[serde(default)]
    pub cancel_ack: bool,
    #[serde(default)]
    pub durable_terminals: bool,
    #[serde(default)]
    pub model_lifecycle_events: bool,
    #[serde(default)]
    pub binary_payload_frames: bool,
    #[serde(default)]
    pub process_generation: i64,
}

impl Capabilities {
    pub fn supports_v2(&self) -> bool {
        self.protocol_major >= 2
            && self.prepared_leases
            && self.start_authorization
            && self.durable_terminals
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AttemptIdentity {
    pub job_id: String,
    pub attempt_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub lease_id: Option<String>,
    pub session_epoch: u64,
    pub coordinator_epoch: u64,
    pub dispatch_nonce: String,
    pub request_digest: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub provider_generation: Option<i64>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum StructuredErrorClass {
    InvalidRequest,
    Capacity,
    ModelNotReady,
    Draining,
    Cancelled,
    Fault,
    Security,
}

/// Binary encrypted-payload frame header (64 bytes, little-endian fields).
///
/// Layout:
/// - 0..2   magic `b"DB"`
/// - 2      version (=2)
/// - 3      frame_type
/// - 4..12  session_epoch (u64 LE)
/// - 12..20 coordinator_epoch (u64 LE)
/// - 20..28 sequence (u64 LE)
/// - 28..44 job_id hash prefix (16 bytes)
/// - 44..60 attempt_id hash prefix (16 bytes)
/// - 60..64 reserved
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BinaryPayloadHeader {
    pub frame_type: u8,
    pub session_epoch: u64,
    pub coordinator_epoch: u64,
    pub sequence: u64,
    pub job_id_prefix: [u8; 16],
    pub attempt_id_prefix: [u8; 16],
}

impl BinaryPayloadHeader {
    pub const MAGIC: [u8; 2] = *b"DB";
    pub const VERSION: u8 = 2;
    pub const FRAME_PREPARE_BODY: u8 = 1;
    pub const FRAME_CHUNK: u8 = 2;

    pub fn encode(&self) -> [u8; BINARY_PAYLOAD_HEADER_LEN] {
        let mut out = [0u8; BINARY_PAYLOAD_HEADER_LEN];
        out[0..2].copy_from_slice(&Self::MAGIC);
        out[2] = Self::VERSION;
        out[3] = self.frame_type;
        out[4..12].copy_from_slice(&self.session_epoch.to_le_bytes());
        out[12..20].copy_from_slice(&self.coordinator_epoch.to_le_bytes());
        out[20..28].copy_from_slice(&self.sequence.to_le_bytes());
        out[28..44].copy_from_slice(&self.job_id_prefix);
        out[44..60].copy_from_slice(&self.attempt_id_prefix);
        out
    }

    pub fn decode(bytes: &[u8]) -> Option<Self> {
        if bytes.len() < BINARY_PAYLOAD_HEADER_LEN {
            return None;
        }
        if bytes[0..2] != Self::MAGIC || bytes[2] != Self::VERSION {
            return None;
        }
        let mut job = [0u8; 16];
        let mut attempt = [0u8; 16];
        job.copy_from_slice(&bytes[28..44]);
        attempt.copy_from_slice(&bytes[44..60]);
        Some(Self {
            frame_type: bytes[3],
            session_epoch: u64::from_le_bytes(bytes[4..12].try_into().ok()?),
            coordinator_epoch: u64::from_le_bytes(bytes[12..20].try_into().ok()?),
            sequence: u64::from_le_bytes(bytes[20..28].try_into().ok()?),
            job_id_prefix: job,
            attempt_id_prefix: attempt,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn capabilities_require_full_v2_set() {
        let mut caps = Capabilities {
            protocol_major: 2,
            ..Default::default()
        };
        assert!(!caps.supports_v2());
        caps.prepared_leases = true;
        caps.start_authorization = true;
        caps.durable_terminals = true;
        assert!(caps.supports_v2());
    }

    #[test]
    fn binary_header_round_trip() {
        let hdr = BinaryPayloadHeader {
            frame_type: BinaryPayloadHeader::FRAME_CHUNK,
            session_epoch: 9,
            coordinator_epoch: 3,
            sequence: 42,
            job_id_prefix: [1; 16],
            attempt_id_prefix: [2; 16],
        };
        let encoded = hdr.encode();
        assert_eq!(encoded.len(), BINARY_PAYLOAD_HEADER_LEN);
        let decoded = BinaryPayloadHeader::decode(&encoded).unwrap();
        assert_eq!(decoded, hdr);
    }

    #[test]
    fn binary_header_rejects_truncation() {
        assert!(BinaryPayloadHeader::decode(&[0u8; 8]).is_none());
    }
}

/// Build a binary WebSocket payload: header || ciphertext.
pub fn encode_binary_payload(header: &BinaryPayloadHeader, ciphertext: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(BINARY_PAYLOAD_HEADER_LEN + ciphertext.len());
    out.extend_from_slice(&header.encode());
    out.extend_from_slice(ciphertext);
    out
}

/// Split a binary payload into header + ciphertext.
pub fn decode_binary_payload(bytes: &[u8]) -> Option<(BinaryPayloadHeader, &[u8])> {
    if bytes.len() < BINARY_PAYLOAD_HEADER_LEN {
        return None;
    }
    let hdr = BinaryPayloadHeader::decode(bytes)?;
    Some((hdr, &bytes[BINARY_PAYLOAD_HEADER_LEN..]))
}

#[cfg(test)]
mod binary_payload_tests {
    use super::*;

    #[test]
    fn wraps_ciphertext() {
        let hdr = BinaryPayloadHeader {
            frame_type: BinaryPayloadHeader::FRAME_CHUNK,
            session_epoch: 1,
            coordinator_epoch: 2,
            sequence: 9,
            job_id_prefix: [3; 16],
            attempt_id_prefix: [4; 16],
        };
        let payload = encode_binary_payload(&hdr, b"cipher");
        let (decoded, ct) = decode_binary_payload(&payload).unwrap();
        assert_eq!(decoded, hdr);
        assert_eq!(ct, b"cipher");
    }

    #[test]
    fn frame_chunk_constant_is_two() {
        assert_eq!(BinaryPayloadHeader::FRAME_CHUNK, 2);
        assert_eq!(BINARY_PAYLOAD_HEADER_LEN, 64);
    }
}
