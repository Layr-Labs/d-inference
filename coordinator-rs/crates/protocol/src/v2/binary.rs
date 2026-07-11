//! Fixed protocol-v2 encrypted binary frame layout.

use bytes::{BufMut, Bytes, BytesMut};

use crate::{
    error::ProtocolError,
    limits::{MAX_V2_CIPHERTEXT_LEN, V2_BINARY_HEADER_LEN},
    v2::identity::{
        AttemptId, AttemptIdentity, LeaseId, ProviderId, ProviderProcessGenerationId, RequestId,
        ReservationId, SessionEpoch,
    },
};

pub const MAGIC_RANGE: std::ops::Range<usize> = 0..4;
pub const KIND_OFFSET: usize = 4;
pub const FLAGS_OFFSET: usize = 5;
pub const HEADER_LEN_RANGE: std::ops::Range<usize> = 6..8;
pub const MAJOR_RANGE: std::ops::Range<usize> = 8..10;
pub const MINOR_RANGE: std::ops::Range<usize> = 10..12;
pub const PROVIDER_ID_RANGE: std::ops::Range<usize> = 12..28;
pub const PROCESS_GENERATION_RANGE: std::ops::Range<usize> = 28..44;
pub const SESSION_EPOCH_RANGE: std::ops::Range<usize> = 44..52;
pub const REQUEST_ID_RANGE: std::ops::Range<usize> = 52..68;
pub const ATTEMPT_ID_RANGE: std::ops::Range<usize> = 68..84;
pub const RESERVATION_ID_RANGE: std::ops::Range<usize> = 84..100;
pub const LEASE_ID_RANGE: std::ops::Range<usize> = 100..116;
pub const NONCE_RANGE: std::ops::Range<usize> = 116..140;
pub const ROLLING_DIGEST_RANGE: std::ops::Range<usize> = 140..172;
pub const SEQUENCE_RANGE: std::ops::Range<usize> = 172..180;
pub const CIPHERTEXT_LEN_RANGE: std::ops::Range<usize> = 180..184;
pub const CUMULATIVE_TOKENS_RANGE: std::ops::Range<usize> = 184..192;

/// Known encrypted payload frame kinds.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[repr(u8)]
pub enum BinaryFrameKind {
    /// Encrypted body associated with a prepare command.
    PreparePayload = 1,
    /// Encrypted provider response chunk.
    ResponseChunk = 2,
    /// Encrypted terminal payload, when negotiated.
    TerminalPayload = 3,
}

impl TryFrom<u8> for BinaryFrameKind {
    type Error = ProtocolError;

    fn try_from(value: u8) -> Result<Self, Self::Error> {
        match value {
            1 => Ok(Self::PreparePayload),
            2 => Ok(Self::ResponseChunk),
            3 => Ok(Self::TerminalPayload),
            other => Err(ProtocolError::UnknownFrameKind(other)),
        }
    }
}

/// Compatibility name for frame-kind users.
pub type FrameKind = BinaryFrameKind;

/// Validated binary frame flags.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Hash)]
pub struct BinaryFrameFlags(u8);

impl BinaryFrameFlags {
    pub const EMPTY: Self = Self(0);
    pub const FINAL: Self = Self(0x01);
    pub const RETRANSMIT: Self = Self(0x02);
    pub const KNOWN_MASK: u8 = Self::FINAL.0 | Self::RETRANSMIT.0;

    pub fn new(bits: u8) -> Result<Self, ProtocolError> {
        let unknown = bits & !Self::KNOWN_MASK;
        if unknown != 0 {
            return Err(ProtocolError::UnknownFrameFlags(unknown));
        }
        Ok(Self(bits))
    }

    #[must_use]
    pub const fn bits(self) -> u8 {
        self.0
    }

    #[must_use]
    pub const fn contains(self, flag: Self) -> bool {
        self.0 & flag.0 == flag.0
    }
}

impl std::ops::BitOr for BinaryFrameFlags {
    type Output = Self;

    fn bitor(self, rhs: Self) -> Self::Output {
        Self(self.0 | rhs.0)
    }
}

/// Compatibility name for validated flags.
pub type FrameFlags = BinaryFrameFlags;

/// The fixed 192-byte, network-byte-order protocol-v2 binary header.
///
/// `cumulative_tokens` is authenticated alongside `rolling_digest`, allowing
/// receivers to reproduce the rolling chain without parsing SSE payloads.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BinaryFrameHeader {
    pub kind: BinaryFrameKind,
    pub flags: BinaryFrameFlags,
    pub minor: u16,
    pub provider_id: ProviderId,
    pub provider_process_generation: ProviderProcessGenerationId,
    pub session_epoch: SessionEpoch,
    pub request_id: RequestId,
    pub attempt_id: AttemptId,
    pub reservation_id: ReservationId,
    pub lease_id: LeaseId,
    pub nonce: [u8; 24],
    pub rolling_digest: [u8; 32],
    pub sequence: u64,
    pub ciphertext_len: u32,
    pub cumulative_tokens: u64,
}

impl BinaryFrameHeader {
    pub const MAGIC: [u8; 4] = *b"DBV2";
    pub const MAJOR: u16 = crate::PROTOCOL_V2_MAJOR;

    /// Returns the request-attempt identity authenticated by this frame.
    #[must_use]
    pub const fn attempt_identity(&self) -> AttemptIdentity {
        AttemptIdentity {
            provider_id: self.provider_id,
            provider_process_generation: self.provider_process_generation,
            session_epoch: self.session_epoch,
            request_id: self.request_id,
            attempt_id: self.attempt_id,
            reservation_id: self.reservation_id,
            lease_id: self.lease_id,
        }
    }

    /// Encodes exactly 192 bytes in network byte order.
    pub fn encode(&self) -> Result<[u8; V2_BINARY_HEADER_LEN], ProtocolError> {
        validate_ciphertext_len(self.ciphertext_len)?;

        let mut output = [0_u8; V2_BINARY_HEADER_LEN];
        output[MAGIC_RANGE].copy_from_slice(&Self::MAGIC);
        output[KIND_OFFSET] = self.kind as u8;
        output[FLAGS_OFFSET] = self.flags.bits();
        output[HEADER_LEN_RANGE].copy_from_slice(&(V2_BINARY_HEADER_LEN as u16).to_be_bytes());
        output[MAJOR_RANGE].copy_from_slice(&Self::MAJOR.to_be_bytes());
        output[MINOR_RANGE].copy_from_slice(&self.minor.to_be_bytes());
        output[PROVIDER_ID_RANGE].copy_from_slice(self.provider_id.as_bytes());
        output[PROCESS_GENERATION_RANGE]
            .copy_from_slice(self.provider_process_generation.as_bytes());
        output[SESSION_EPOCH_RANGE].copy_from_slice(&self.session_epoch.0.to_be_bytes());
        output[REQUEST_ID_RANGE].copy_from_slice(self.request_id.as_bytes());
        output[ATTEMPT_ID_RANGE].copy_from_slice(self.attempt_id.as_bytes());
        output[RESERVATION_ID_RANGE].copy_from_slice(self.reservation_id.as_bytes());
        output[LEASE_ID_RANGE].copy_from_slice(self.lease_id.as_bytes());
        output[NONCE_RANGE].copy_from_slice(&self.nonce);
        output[ROLLING_DIGEST_RANGE].copy_from_slice(&self.rolling_digest);
        output[SEQUENCE_RANGE].copy_from_slice(&self.sequence.to_be_bytes());
        output[CIPHERTEXT_LEN_RANGE].copy_from_slice(&self.ciphertext_len.to_be_bytes());
        output[CUMULATIVE_TOKENS_RANGE].copy_from_slice(&self.cumulative_tokens.to_be_bytes());
        Ok(output)
    }

    /// Decodes a header without allocating or consulting its ciphertext length
    /// until all fixed fields have been validated.
    pub fn decode(input: &[u8]) -> Result<Self, ProtocolError> {
        if input.len() < V2_BINARY_HEADER_LEN {
            return Err(ProtocolError::TruncatedHeader {
                actual: input.len(),
                required: V2_BINARY_HEADER_LEN,
            });
        }
        if input[MAGIC_RANGE] != Self::MAGIC {
            return Err(ProtocolError::InvalidMagic);
        }

        let header_len = read_u16(input, HEADER_LEN_RANGE);
        if usize::from(header_len) != V2_BINARY_HEADER_LEN {
            return Err(ProtocolError::InvalidHeaderLength(header_len));
        }
        let major = read_u16(input, MAJOR_RANGE);
        if major != Self::MAJOR {
            return Err(ProtocolError::UnsupportedMajor(major));
        }
        let kind = BinaryFrameKind::try_from(input[KIND_OFFSET])?;
        let flags = BinaryFrameFlags::new(input[FLAGS_OFFSET])?;
        let ciphertext_len = read_u32(input, CIPHERTEXT_LEN_RANGE);
        validate_ciphertext_len(ciphertext_len)?;

        Ok(Self {
            kind,
            flags,
            minor: read_u16(input, MINOR_RANGE),
            provider_id: ProviderId::new(read_array(input, PROVIDER_ID_RANGE)),
            provider_process_generation: ProviderProcessGenerationId::new(read_array(
                input,
                PROCESS_GENERATION_RANGE,
            )),
            session_epoch: SessionEpoch(read_u64(input, SESSION_EPOCH_RANGE)),
            request_id: RequestId::new(read_array(input, REQUEST_ID_RANGE)),
            attempt_id: AttemptId::new(read_array(input, ATTEMPT_ID_RANGE)),
            reservation_id: ReservationId::new(read_array(input, RESERVATION_ID_RANGE)),
            lease_id: LeaseId::new(read_array(input, LEASE_ID_RANGE)),
            nonce: read_array(input, NONCE_RANGE),
            rolling_digest: read_array(input, ROLLING_DIGEST_RANGE),
            sequence: read_u64(input, SEQUENCE_RANGE),
            ciphertext_len,
            cumulative_tokens: read_u64(input, CUMULATIVE_TOKENS_RANGE),
        })
    }
}

/// Compatibility name for the fixed header.
pub type BinaryHeader = BinaryFrameHeader;

/// A validated frame borrowing ciphertext from the caller's input.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BinaryFrameRef<'a> {
    pub header: BinaryFrameHeader,
    pub ciphertext: &'a [u8],
}

/// Validates a complete frame and borrows its ciphertext without allocating.
pub fn decode_binary_frame(input: &[u8]) -> Result<BinaryFrameRef<'_>, ProtocolError> {
    let header = BinaryFrameHeader::decode(input)?;
    let ciphertext_len = header.ciphertext_len as usize;
    let expected = V2_BINARY_HEADER_LEN
        .checked_add(ciphertext_len)
        .ok_or(ProtocolError::CiphertextLengthOverflow(ciphertext_len))?;
    if input.len() != expected {
        return Err(ProtocolError::FrameLengthMismatch {
            actual: input.len(),
            expected,
        });
    }
    Ok(BinaryFrameRef {
        header,
        ciphertext: &input[V2_BINARY_HEADER_LEN..],
    })
}

/// Encodes a complete bounded frame.
pub fn encode_binary_frame(
    header: &BinaryFrameHeader,
    ciphertext: &[u8],
) -> Result<Bytes, ProtocolError> {
    if ciphertext.len() > MAX_V2_CIPHERTEXT_LEN {
        return Err(ProtocolError::CiphertextTooLarge {
            actual: ciphertext.len(),
            maximum: MAX_V2_CIPHERTEXT_LEN,
        });
    }
    if header.ciphertext_len as usize != ciphertext.len() {
        return Err(ProtocolError::FrameLengthMismatch {
            actual: ciphertext.len(),
            expected: header.ciphertext_len as usize,
        });
    }
    let encoded_header = header.encode()?;
    let mut output = BytesMut::with_capacity(V2_BINARY_HEADER_LEN + ciphertext.len());
    output.put_slice(&encoded_header);
    output.put_slice(ciphertext);
    Ok(output.freeze())
}

/// Short compatibility names for frame codecs.
pub use decode_binary_frame as decode_frame;
pub use encode_binary_frame as encode_frame;

fn validate_ciphertext_len(length: u32) -> Result<(), ProtocolError> {
    let length = length as usize;
    if length > MAX_V2_CIPHERTEXT_LEN {
        return Err(ProtocolError::CiphertextTooLarge {
            actual: length,
            maximum: MAX_V2_CIPHERTEXT_LEN,
        });
    }
    Ok(())
}

fn read_array<const N: usize>(input: &[u8], range: std::ops::Range<usize>) -> [u8; N] {
    let mut output = [0_u8; N];
    output.copy_from_slice(&input[range]);
    output
}

fn read_u16(input: &[u8], range: std::ops::Range<usize>) -> u16 {
    u16::from_be_bytes(read_array(input, range))
}

fn read_u32(input: &[u8], range: std::ops::Range<usize>) -> u32 {
    u32::from_be_bytes(read_array(input, range))
}

fn read_u64(input: &[u8], range: std::ops::Range<usize>) -> u64 {
    u64::from_be_bytes(read_array(input, range))
}
