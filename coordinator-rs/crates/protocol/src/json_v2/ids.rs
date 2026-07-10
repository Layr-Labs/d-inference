//! Identity and fencing newtypes shared by the v2 JSON frames and the binary
//! frame codec.
//!
//! Wire encodings:
//! - [`JobId`] / [`AttemptId`] / [`LeaseId`]: 16 raw bytes; JSON as the
//!   canonical lowercase hyphenated UUID string.
//! - [`DispatchNonce`]: 16 raw bytes; JSON as 32 lowercase hex chars.
//! - [`RequestDigest`] / [`ResponseHash`] / [`TerminalDigest`]: 32 raw bytes
//!   (SHA-256); JSON as 64 lowercase hex chars.
//! - [`SessionEpoch`] / [`CoordinatorEpoch`]: plain JSON integers; u64
//!   little-endian in binary frames.

use std::fmt;

use serde::{Deserialize, Deserializer, Serialize, Serializer};

fn parse_hex_exact<const N: usize>(s: &str) -> Result<[u8; N], String> {
    let mut out = [0u8; N];
    hex::decode_to_slice(s, &mut out).map_err(|_| format!("expected {} hex chars", N * 2))?;
    Ok(out)
}

macro_rules! hex_id {
    ($(#[doc = $doc:literal])* $name:ident, $len:expr) => {
        $(#[doc = $doc])*
        #[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Default)]
        pub struct $name(pub [u8; $len]);

        impl $name {
            pub const LEN: usize = $len;

            pub fn as_bytes(&self) -> &[u8; $len] {
                &self.0
            }

            pub fn from_hex(s: &str) -> Result<Self, String> {
                parse_hex_exact::<$len>(s).map(Self)
            }
        }

        impl From<[u8; $len]> for $name {
            fn from(b: [u8; $len]) -> Self {
                Self(b)
            }
        }

        impl fmt::Display for $name {
            fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
                f.write_str(&hex::encode(self.0))
            }
        }

        impl Serialize for $name {
            fn serialize<S: Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
                s.serialize_str(&hex::encode(self.0))
            }
        }

        impl<'de> Deserialize<'de> for $name {
            fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
                let s = <std::borrow::Cow<'de, str>>::deserialize(d)?;
                Self::from_hex(&s).map_err(serde::de::Error::custom)
            }
        }
    };
}

macro_rules! uuid_id {
    ($(#[doc = $doc:literal])* $name:ident) => {
        $(#[doc = $doc])*
        #[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Default)]
        pub struct $name(pub [u8; 16]);

        impl $name {
            pub const LEN: usize = 16;

            pub fn as_bytes(&self) -> &[u8; 16] {
                &self.0
            }

            /// Parses the canonical hyphenated UUID form
            /// (`xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`).
            pub fn parse(s: &str) -> Result<Self, String> {
                let b = s.as_bytes();
                if b.len() != 36 || b[8] != b'-' || b[13] != b'-' || b[18] != b'-' || b[23] != b'-' {
                    return Err("expected canonical hyphenated uuid".to_owned());
                }
                let compact: String = s.chars().filter(|c| *c != '-').collect();
                parse_hex_exact::<16>(&compact).map(Self)
            }
        }

        impl From<[u8; 16]> for $name {
            fn from(b: [u8; 16]) -> Self {
                Self(b)
            }
        }

        impl fmt::Display for $name {
            fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
                let h = hex::encode(self.0);
                write!(
                    f,
                    "{}-{}-{}-{}-{}",
                    &h[0..8],
                    &h[8..12],
                    &h[12..16],
                    &h[16..20],
                    &h[20..32]
                )
            }
        }

        impl Serialize for $name {
            fn serialize<S: Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
                s.serialize_str(&self.to_string())
            }
        }

        impl<'de> Deserialize<'de> for $name {
            fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
                let s = <std::borrow::Cow<'de, str>>::deserialize(d)?;
                Self::parse(&s).map_err(serde::de::Error::custom)
            }
        }
    };
}

macro_rules! epoch_id {
    ($(#[doc = $doc:literal])* $name:ident) => {
        $(#[doc = $doc])*
        #[derive(
            Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Default, Serialize, Deserialize,
        )]
        #[serde(transparent)]
        pub struct $name(pub u64);

        impl From<u64> for $name {
            fn from(v: u64) -> Self {
                Self(v)
            }
        }

        impl fmt::Display for $name {
            fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
                self.0.fmt(f)
            }
        }
    };
}

uuid_id! {
    /// Logical financial and consumer request identity (plan §10.2).
    JobId
}
uuid_id! {
    /// One provider dispatch identity; each dispatch gets a fresh one.
    AttemptId
}
uuid_id! {
    /// Provider-issued prepared-lease identity.
    LeaseId
}

hex_id! {
    /// Replay and substitution fence, unique per dispatch (plan §10.2).
    DispatchNonce, 16
}
hex_id! {
    /// SHA-256 digest of the canonical encrypted request envelope.
    RequestDigest, 32
}
hex_id! {
    /// SHA-256 rolling/final response hash.
    ResponseHash, 32
}
hex_id! {
    /// SHA-256 digest of the canonical signed terminal
    /// (see [`crate::crypto::terminal_digest`]).
    TerminalDigest, 32
}

epoch_id! {
    /// Active provider connection fence: one WebSocket connection epoch.
    SessionEpoch
}
epoch_id! {
    /// Single-active coordinator fence.
    CoordinatorEpoch
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn uuid_round_trip() {
        let id = JobId(*b"\x01\x23\x45\x67\x89\xab\xcd\xef\x01\x23\x45\x67\x89\xab\xcd\xef");
        let s = id.to_string();
        assert_eq!(s, "01234567-89ab-cdef-0123-456789abcdef");
        assert_eq!(JobId::parse(&s).unwrap(), id);
        let json = serde_json::to_string(&id).unwrap();
        assert_eq!(json, format!("\"{s}\""));
        assert_eq!(serde_json::from_str::<JobId>(&json).unwrap(), id);
    }

    #[test]
    fn uuid_rejects_malformed() {
        assert!(JobId::parse("01234567-89ab-cdef-0123").is_err());
        assert!(JobId::parse("0123456789abcdef0123456789abcdef").is_err());
        assert!(JobId::parse("01234567-89ab-cdef-0123-456789abcdeg").is_err());
    }

    #[test]
    fn hex_round_trip() {
        let d = RequestDigest([0xab; 32]);
        let json = serde_json::to_string(&d).unwrap();
        assert_eq!(json.len(), 66);
        assert_eq!(serde_json::from_str::<RequestDigest>(&json).unwrap(), d);
        assert!(RequestDigest::from_hex("abcd").is_err());
    }
}
