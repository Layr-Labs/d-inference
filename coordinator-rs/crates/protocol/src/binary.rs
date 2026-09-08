//! Binary encrypted-payload frame codec (plan §15.3).
//!
//! Protocol v2 moves the two hottest payloads — the encrypted prepare request
//! body and encrypted response chunks — from base64-in-JSON to binary
//! WebSocket frames: a fixed little-endian header carrying the full identity
//! and fencing set, followed by raw ciphertext. This removes the per-token
//! base64 + JSON encode/decode and roughly one-third wire inflation.
//!
//! Layout (all integers little-endian):
//!
//! | offset | size | field                          |
//! |--------|------|--------------------------------|
//! | 0      | 2    | magic `"DB"`                   |
//! | 2      | 1    | version (`1`)                  |
//! | 3      | 1    | frame kind                     |
//! | 4      | 16   | job_id (UUID bytes)            |
//! | 20     | 16   | attempt_id                     |
//! | 36     | 16   | lease_id (all-zero = absent)   |
//! | 52     | 8    | session_epoch u64              |
//! | 60     | 8    | coordinator_epoch u64          |
//! | 68     | 16   | dispatch_nonce                 |
//! | 84     | 32   | request_digest (SHA-256)       |
//! | 116    | 8    | sequence u64                   |
//! | 124    | 8    | cumulative_completion_tokens   |
//! | 132    | 4    | payload_len u32                |
//! | 136    | n    | raw ciphertext payload         |
//!
//! Invariants:
//! - A frame is exactly `HEADER_LEN + payload_len` bytes: trailing garbage is
//!   rejected, so a frame cannot smuggle a second frame.
//! - Decode is zero-copy: the payload is a [`Bytes`] slice of the input.
//! - The all-zero [`LeaseId`] encodes "no lease yet" (the prepare body is
//!   sent before the provider issues a lease); a real all-zero lease id is
//!   therefore unrepresentable, which is fine because providers generate
//!   random lease ids.
//! - The payload is ciphertext; nothing in this module inspects or logs it.

use bytes::{BufMut, Bytes, BytesMut};

use crate::json_v2::{
    AttemptId, CoordinatorEpoch, DispatchNonce, JobId, LeaseId, RequestDigest, SessionEpoch,
};

/// Two-byte frame magic.
pub const MAGIC: [u8; 2] = *b"DB";

/// Current binary frame version.
pub const VERSION: u8 = 1;

/// Fixed header length in bytes.
pub const HEADER_LEN: usize = 136;

/// What the ciphertext payload contains.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[repr(u8)]
pub enum FrameKind {
    /// Encrypted prepare request body (coordinator → provider).
    PrepareBody = 1,
    /// Encrypted response chunk (provider → coordinator).
    ResponseChunk = 2,
}

impl FrameKind {
    fn from_u8(v: u8) -> Option<Self> {
        match v {
            1 => Some(Self::PrepareBody),
            2 => Some(Self::ResponseChunk),
            _ => None,
        }
    }
}

/// Decoded fixed header of a binary encrypted-payload frame.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct BinaryFrameHeader {
    pub kind: FrameKind,
    pub job_id: JobId,
    pub attempt_id: AttemptId,
    /// `None` on the wire is the all-zero lease id.
    pub lease_id: Option<LeaseId>,
    pub session_epoch: SessionEpoch,
    pub coordinator_epoch: CoordinatorEpoch,
    pub dispatch_nonce: DispatchNonce,
    pub request_digest: RequestDigest,
    /// Chunk sequence number (0 for prepare bodies).
    pub sequence: u64,
    /// Cumulative completion tokens at this chunk (0 for prepare bodies).
    pub cumulative_completion_tokens: u64,
}

/// Typed decode/encode failures. No payload bytes ever appear in an error.
#[derive(Debug, Clone, Copy, PartialEq, Eq, thiserror::Error)]
pub enum BinaryFrameError {
    #[error("frame truncated: need at least {needed} bytes, got {got}")]
    Truncated { needed: usize, got: usize },
    #[error("bad frame magic")]
    BadMagic,
    #[error("unsupported frame version {0}")]
    UnsupportedVersion(u8),
    #[error("unknown frame kind {0}")]
    UnknownFrameKind(u8),
    #[error("frame length {len} exceeds maximum {max}")]
    Oversize { len: usize, max: usize },
    #[error("declared payload length {declared} does not match actual {actual}")]
    PayloadLengthMismatch { declared: usize, actual: usize },
    #[error("payload length {len} exceeds u32 range")]
    PayloadTooLong { len: usize },
}

/// Encodes a frame into a freshly allocated buffer.
///
/// The caller enforces any transport frame-size policy; this only rejects
/// payloads that cannot be represented in the u32 length field.
pub fn encode(header: &BinaryFrameHeader, payload: &[u8]) -> Result<Bytes, BinaryFrameError> {
    let payload_len = u32::try_from(payload.len())
        .map_err(|_| BinaryFrameError::PayloadTooLong { len: payload.len() })?;
    let mut buf = BytesMut::with_capacity(HEADER_LEN + payload.len());
    buf.put_slice(&MAGIC);
    buf.put_u8(VERSION);
    buf.put_u8(header.kind as u8);
    buf.put_slice(header.job_id.as_bytes());
    buf.put_slice(header.attempt_id.as_bytes());
    buf.put_slice(header.lease_id.unwrap_or_default().as_bytes());
    buf.put_u64_le(header.session_epoch.0);
    buf.put_u64_le(header.coordinator_epoch.0);
    buf.put_slice(header.dispatch_nonce.as_bytes());
    buf.put_slice(header.request_digest.as_bytes());
    buf.put_u64_le(header.sequence);
    buf.put_u64_le(header.cumulative_completion_tokens);
    buf.put_u32_le(payload_len);
    buf.put_slice(payload);
    debug_assert_eq!(buf.len(), HEADER_LEN + payload.len());
    Ok(buf.freeze())
}

/// Decodes one frame, returning the header and a zero-copy payload slice.
///
/// `max_frame_len` bounds the whole frame (header + payload); WebSocket
/// message limits should feed the same value so both layers agree.
pub fn decode(
    frame: &Bytes,
    max_frame_len: usize,
) -> Result<(BinaryFrameHeader, Bytes), BinaryFrameError> {
    if frame.len() > max_frame_len {
        return Err(BinaryFrameError::Oversize {
            len: frame.len(),
            max: max_frame_len,
        });
    }
    if frame.len() < HEADER_LEN {
        return Err(BinaryFrameError::Truncated {
            needed: HEADER_LEN,
            got: frame.len(),
        });
    }
    let b: &[u8] = frame;
    if b[0..2] != MAGIC {
        return Err(BinaryFrameError::BadMagic);
    }
    if b[2] != VERSION {
        return Err(BinaryFrameError::UnsupportedVersion(b[2]));
    }
    let kind = FrameKind::from_u8(b[3]).ok_or(BinaryFrameError::UnknownFrameKind(b[3]))?;

    let lease_bytes = take16(b, 36);
    let header = BinaryFrameHeader {
        kind,
        job_id: JobId(take16(b, 4)),
        attempt_id: AttemptId(take16(b, 20)),
        lease_id: (lease_bytes != [0u8; 16]).then_some(LeaseId(lease_bytes)),
        session_epoch: SessionEpoch(read_u64_le(b, 52)),
        coordinator_epoch: CoordinatorEpoch(read_u64_le(b, 60)),
        dispatch_nonce: DispatchNonce(take16(b, 68)),
        request_digest: RequestDigest(take32(b, 84)),
        sequence: read_u64_le(b, 116),
        cumulative_completion_tokens: read_u64_le(b, 124),
    };

    let declared = read_u32_le(b, 132) as usize;
    let actual = frame.len() - HEADER_LEN;
    if declared != actual {
        return Err(BinaryFrameError::PayloadLengthMismatch { declared, actual });
    }
    Ok((header, frame.slice(HEADER_LEN..)))
}

fn take16(b: &[u8], at: usize) -> [u8; 16] {
    let mut out = [0u8; 16];
    out.copy_from_slice(&b[at..at + 16]);
    out
}

fn take32(b: &[u8], at: usize) -> [u8; 32] {
    let mut out = [0u8; 32];
    out.copy_from_slice(&b[at..at + 32]);
    out
}

fn read_u64_le(b: &[u8], at: usize) -> u64 {
    u64::from_le_bytes(b[at..at + 8].try_into().expect("fixed 8-byte slice"))
}

fn read_u32_le(b: &[u8], at: usize) -> u32 {
    u32::from_le_bytes(b[at..at + 4].try_into().expect("fixed 4-byte slice"))
}

#[cfg(test)]
mod tests {
    use proptest::prelude::*;

    use super::*;

    const MAX: usize = 1 << 20;

    fn header(kind: FrameKind, lease: Option<[u8; 16]>) -> BinaryFrameHeader {
        BinaryFrameHeader {
            kind,
            job_id: JobId([0x11; 16]),
            attempt_id: AttemptId([0x22; 16]),
            lease_id: lease.map(LeaseId),
            session_epoch: SessionEpoch(3),
            coordinator_epoch: CoordinatorEpoch(4),
            dispatch_nonce: DispatchNonce([0x33; 16]),
            request_digest: RequestDigest([0x44; 32]),
            sequence: 5,
            cumulative_completion_tokens: 6,
        }
    }

    #[test]
    fn round_trip_with_and_without_lease() {
        for lease in [None, Some([0xaa; 16])] {
            let h = header(FrameKind::ResponseChunk, lease);
            let payload = b"ciphertext bytes".as_slice();
            let frame = encode(&h, payload).unwrap();
            assert_eq!(frame.len(), HEADER_LEN + payload.len());
            let (back, body) = decode(&frame, MAX).unwrap();
            assert_eq!(back, h);
            assert_eq!(&body[..], payload);
        }
    }

    #[test]
    fn zero_copy_payload() {
        let h = header(FrameKind::PrepareBody, None);
        let frame = encode(&h, &[9u8; 128]).unwrap();
        let (_, body) = decode(&frame, MAX).unwrap();
        // Same allocation: the payload pointer lives inside the frame buffer.
        let frame_range = frame.as_ptr() as usize..frame.as_ptr() as usize + frame.len();
        assert!(frame_range.contains(&(body.as_ptr() as usize)));
    }

    #[test]
    fn rejects_bad_magic_version_kind() {
        let h = header(FrameKind::PrepareBody, None);
        let frame = encode(&h, b"x").unwrap();

        let mut bad = BytesMut::from(&frame[..]);
        bad[0] = b'X';
        assert_eq!(
            decode(&bad.freeze(), MAX).unwrap_err(),
            BinaryFrameError::BadMagic
        );

        let mut bad = BytesMut::from(&frame[..]);
        bad[2] = 9;
        assert_eq!(
            decode(&bad.freeze(), MAX).unwrap_err(),
            BinaryFrameError::UnsupportedVersion(9)
        );

        let mut bad = BytesMut::from(&frame[..]);
        bad[3] = 200;
        assert_eq!(
            decode(&bad.freeze(), MAX).unwrap_err(),
            BinaryFrameError::UnknownFrameKind(200)
        );
    }

    #[test]
    fn rejects_oversize_and_length_mismatch() {
        let h = header(FrameKind::ResponseChunk, None);
        let frame = encode(&h, &[0u8; 64]).unwrap();
        assert_eq!(
            decode(&frame, frame.len() - 1).unwrap_err(),
            BinaryFrameError::Oversize {
                len: frame.len(),
                max: frame.len() - 1
            }
        );

        // Truncate payload: declared length no longer matches.
        let truncated = frame.slice(..frame.len() - 1);
        assert_eq!(
            decode(&truncated, MAX).unwrap_err(),
            BinaryFrameError::PayloadLengthMismatch {
                declared: 64,
                actual: 63
            }
        );

        // Extend with trailing garbage: also a mismatch.
        let mut extended = BytesMut::from(&frame[..]);
        extended.put_u8(0);
        assert_eq!(
            decode(&extended.freeze(), MAX).unwrap_err(),
            BinaryFrameError::PayloadLengthMismatch {
                declared: 64,
                actual: 65
            }
        );
    }

    #[test]
    fn rejects_truncated_header() {
        let h = header(FrameKind::ResponseChunk, None);
        let frame = encode(&h, b"payload").unwrap();
        for cut in [0usize, 1, 2, 3, 4, 35, 51, 83, 115, 131, HEADER_LEN - 1] {
            let short = frame.slice(..cut);
            assert_eq!(
                decode(&short, MAX).unwrap_err(),
                BinaryFrameError::Truncated {
                    needed: HEADER_LEN,
                    got: cut
                },
                "cut at {cut}"
            );
        }
    }

    proptest! {
        #[test]
        fn prop_round_trip(
            kind in prop_oneof![Just(FrameKind::PrepareBody), Just(FrameKind::ResponseChunk)],
            job in any::<[u8; 16]>(),
            attempt in any::<[u8; 16]>(),
            lease in any::<Option<[u8; 16]>>(),
            session in any::<u64>(),
            coord in any::<u64>(),
            nonce in any::<[u8; 16]>(),
            digest in any::<[u8; 32]>(),
            seq in any::<u64>(),
            cum in any::<u64>(),
            payload in proptest::collection::vec(any::<u8>(), 0..4096),
        ) {
            // The all-zero lease id wire-encodes as "absent" by design.
            let lease = lease.filter(|l| *l != [0u8; 16]);
            let h = BinaryFrameHeader {
                kind,
                job_id: JobId(job),
                attempt_id: AttemptId(attempt),
                lease_id: lease.map(LeaseId),
                session_epoch: SessionEpoch(session),
                coordinator_epoch: CoordinatorEpoch(coord),
                dispatch_nonce: DispatchNonce(nonce),
                request_digest: RequestDigest(digest),
                sequence: seq,
                cumulative_completion_tokens: cum,
            };
            let frame = encode(&h, &payload).unwrap();
            let (back, body) = decode(&frame, MAX).unwrap();
            prop_assert_eq!(back, h);
            prop_assert_eq!(&body[..], &payload[..]);
        }

        #[test]
        fn prop_truncation_never_panics_or_succeeds(
            payload in proptest::collection::vec(any::<u8>(), 0..512),
            cut_fraction in 0.0f64..1.0,
        ) {
            let h = header(FrameKind::ResponseChunk, Some([1; 16]));
            let frame = encode(&h, &payload).unwrap();
            let cut = ((frame.len() as f64) * cut_fraction) as usize;
            if cut < frame.len() {
                prop_assert!(decode(&frame.slice(..cut), MAX).is_err());
            }
        }

        #[test]
        fn prop_corrupt_prefix_rejected(byte0 in any::<u8>(), byte1 in any::<u8>()) {
            prop_assume!([byte0, byte1] != MAGIC);
            let h = header(FrameKind::PrepareBody, None);
            let frame = encode(&h, b"p").unwrap();
            let mut bad = BytesMut::from(&frame[..]);
            bad[0] = byte0;
            bad[1] = byte1;
            prop_assert_eq!(
                decode(&bad.freeze(), MAX).unwrap_err(),
                BinaryFrameError::BadMagic
            );
        }
    }
}
