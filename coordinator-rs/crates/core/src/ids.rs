//! Validated identifiers and monotonically increasing revisions.

use std::fmt;

use serde::{Deserialize, Serialize};
use thiserror::Error;
use uuid::Uuid;

/// Error returned when a UUID-backed identifier is nil.
#[derive(Clone, Copy, Debug, Eq, Error, PartialEq)]
#[error("{kind} must not be the nil UUID")]
pub struct IdentifierError {
    kind: &'static str,
}

macro_rules! uuid_identifier {
    ($(#[$meta:meta])* $name:ident, $kind:literal) => {
        $(#[$meta])*
        #[derive(Clone, Copy, Debug, Eq, Hash, Ord, PartialEq, PartialOrd, Serialize, Deserialize)]
        #[serde(try_from = "Uuid", into = "Uuid")]
        pub struct $name(Uuid);

        impl $name {
            /// Creates an identifier after rejecting the nil UUID.
            pub fn new(value: Uuid) -> Result<Self, IdentifierError> {
                if value.is_nil() {
                    Err(IdentifierError { kind: $kind })
                } else {
                    Ok(Self(value))
                }
            }

            /// Generates a random version-4 identifier.
            #[must_use]
            pub fn random() -> Self {
                Self(Uuid::new_v4())
            }

            /// Returns the underlying UUID.
            #[must_use]
            pub const fn as_uuid(self) -> Uuid {
                self.0
            }
        }

        impl TryFrom<Uuid> for $name {
            type Error = IdentifierError;

            fn try_from(value: Uuid) -> Result<Self, Self::Error> {
                Self::new(value)
            }
        }

        impl From<$name> for Uuid {
            fn from(value: $name) -> Self {
                value.0
            }
        }

        impl fmt::Display for $name {
            fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
                self.0.fmt(formatter)
            }
        }
    };
}

uuid_identifier!(
    /// Stable identifier for one consumer request.
    RequestId,
    "request identifier"
);
uuid_identifier!(
    /// Stable identifier for one routing attempt.
    AttemptId,
    "attempt identifier"
);
uuid_identifier!(
    /// Stable identifier for one provider.
    ProviderId,
    "provider identifier"
);
uuid_identifier!(
    /// Identifier for one provider process session.
    SessionId,
    "session identifier"
);
uuid_identifier!(
    /// Identifier for a capacity lease.
    LeaseId,
    "lease identifier"
);
uuid_identifier!(
    /// Identifier for an admission or probe permit.
    PermitId,
    "permit identifier"
);
uuid_identifier!(
    /// Identifier for a persisted domain event.
    EventId,
    "event identifier"
);
uuid_identifier!(
    /// Identifier for a funding reservation.
    FundingId,
    "funding identifier"
);

/// Error returned when a textual identifier is invalid.
#[derive(Clone, Copy, Debug, Eq, Error, PartialEq)]
pub enum TextIdentifierError {
    /// The identifier is empty or only whitespace.
    #[error("{kind} must not be empty")]
    Empty {
        /// Human-readable identifier kind.
        kind: &'static str,
    },
    /// Leading or trailing whitespace would make identity ambiguous.
    #[error("{kind} must not have surrounding whitespace")]
    SurroundingWhitespace {
        /// Human-readable identifier kind.
        kind: &'static str,
    },
    /// The identifier exceeds the storage and comparison bound.
    #[error("{kind} exceeds {maximum} bytes")]
    TooLong {
        /// Human-readable identifier kind.
        kind: &'static str,
        /// Maximum accepted UTF-8 byte length.
        maximum: usize,
    },
    /// Control characters are not legal in identifiers.
    #[error("{kind} contains a control character")]
    ControlCharacter {
        /// Human-readable identifier kind.
        kind: &'static str,
    },
}

const MAX_TEXT_IDENTIFIER_BYTES: usize = 256;

fn validate_text_identifier(value: &str, kind: &'static str) -> Result<(), TextIdentifierError> {
    if value.trim().is_empty() {
        return Err(TextIdentifierError::Empty { kind });
    }
    if value.trim() != value {
        return Err(TextIdentifierError::SurroundingWhitespace { kind });
    }
    if value.len() > MAX_TEXT_IDENTIFIER_BYTES {
        return Err(TextIdentifierError::TooLong {
            kind,
            maximum: MAX_TEXT_IDENTIFIER_BYTES,
        });
    }
    if value.chars().any(char::is_control) {
        return Err(TextIdentifierError::ControlCharacter { kind });
    }
    Ok(())
}

macro_rules! text_identifier {
    ($(#[$meta:meta])* $name:ident, $kind:literal) => {
        $(#[$meta])*
        #[derive(Clone, Debug, Eq, Hash, Ord, PartialEq, PartialOrd, Serialize, Deserialize)]
        #[serde(try_from = "String", into = "String")]
        pub struct $name(String);

        impl $name {
            /// Creates an identifier after validating its canonical text.
            pub fn new(value: impl Into<String>) -> Result<Self, TextIdentifierError> {
                let value = value.into();
                validate_text_identifier(&value, $kind)?;
                Ok(Self(value))
            }

            /// Returns the canonical identifier text.
            #[must_use]
            pub fn as_str(&self) -> &str {
                &self.0
            }
        }

        impl TryFrom<String> for $name {
            type Error = TextIdentifierError;

            fn try_from(value: String) -> Result<Self, Self::Error> {
                Self::new(value)
            }
        }

        impl From<$name> for String {
            fn from(value: $name) -> Self {
                value.0
            }
        }

        impl fmt::Display for $name {
            fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
                self.0.fmt(formatter)
            }
        }
    };
}

text_identifier!(
    /// Canonical model registry identifier.
    ModelId,
    "model identifier"
);
text_identifier!(
    /// Canonical hardware-class identifier used for calibration.
    HardwareClass,
    "hardware class"
);

/// A fixed-width digest used to identify event payloads.
#[derive(Clone, Copy, Debug, Eq, Hash, Ord, PartialEq, PartialOrd, Serialize, Deserialize)]
#[serde(transparent)]
pub struct Digest([u8; Self::LENGTH]);

impl Digest {
    /// Digest width in bytes.
    pub const LENGTH: usize = 32;

    /// Creates a digest from an exact-width byte array.
    #[must_use]
    pub const fn new(bytes: [u8; Self::LENGTH]) -> Self {
        Self(bytes)
    }

    /// Returns the digest bytes.
    #[must_use]
    pub const fn as_bytes(&self) -> &[u8; Self::LENGTH] {
        &self.0
    }
}

/// Error returned when a digest does not have the required width.
#[derive(Clone, Copy, Debug, Eq, Error, PartialEq)]
#[error("digest must contain exactly {expected} bytes, got {actual}")]
pub struct DigestLengthError {
    /// Required digest length.
    pub expected: usize,
    /// Supplied digest length.
    pub actual: usize,
}

impl TryFrom<&[u8]> for Digest {
    type Error = DigestLengthError;

    fn try_from(value: &[u8]) -> Result<Self, Self::Error> {
        let bytes = value.try_into().map_err(|_| DigestLengthError {
            expected: Self::LENGTH,
            actual: value.len(),
        })?;
        Ok(Self(bytes))
    }
}

/// Error returned for zero or overflowing revisions.
#[derive(Clone, Copy, Debug, Eq, Error, PartialEq)]
pub enum RevisionError {
    /// Revisions begin at one.
    #[error("{kind} must be greater than zero")]
    Zero {
        /// Human-readable revision kind.
        kind: &'static str,
    },
    /// The revision cannot be advanced without wrapping.
    #[error("{kind} overflow")]
    Overflow {
        /// Human-readable revision kind.
        kind: &'static str,
    },
}

macro_rules! revision {
    ($(#[$meta:meta])* $name:ident, $kind:literal) => {
        $(#[$meta])*
        #[derive(Clone, Copy, Debug, Eq, Hash, Ord, PartialEq, PartialOrd, Serialize, Deserialize)]
        #[serde(try_from = "u64", into = "u64")]
        pub struct $name(u64);

        impl $name {
            /// Creates a nonzero revision.
            pub const fn new(value: u64) -> Result<Self, RevisionError> {
                if value == 0 {
                    Err(RevisionError::Zero { kind: $kind })
                } else {
                    Ok(Self(value))
                }
            }

            /// Returns the revision value.
            #[must_use]
            pub const fn get(self) -> u64 {
                self.0
            }

            /// Returns the next revision, rejecting numeric overflow.
            pub fn checked_next(self) -> Result<Self, RevisionError> {
                self.0
                    .checked_add(1)
                    .map(Self)
                    .ok_or(RevisionError::Overflow { kind: $kind })
            }
        }

        impl TryFrom<u64> for $name {
            type Error = RevisionError;

            fn try_from(value: u64) -> Result<Self, Self::Error> {
                Self::new(value)
            }
        }

        impl From<$name> for u64 {
            fn from(value: $name) -> Self {
                value.0
            }
        }
    };
}

revision!(
    /// Coordinator ownership epoch.
    Epoch,
    "epoch"
);
revision!(
    /// Provider session revision.
    SessionRevision,
    "session revision"
);
revision!(
    /// Provider trust revision.
    TrustRevision,
    "trust revision"
);
revision!(
    /// Provider model-state revision.
    ModelRevision,
    "model revision"
);
revision!(
    /// Immutable fleet snapshot revision.
    FleetRevision,
    "fleet revision"
);
revision!(
    /// Calibration observation-stream revision.
    CalibrationRevision,
    "calibration revision"
);

#[cfg(test)]
mod tests {
    use super::{Digest, ModelId, RequestId, SessionRevision};
    use uuid::Uuid;

    #[test]
    fn identifiers_reject_ambiguous_values() {
        assert!(RequestId::new(Uuid::nil()).is_err());
        assert!(ModelId::new(" model").is_err());
        assert!(ModelId::new("").is_err());
        assert!(SessionRevision::new(0).is_err());
        assert!(Digest::try_from(&[0_u8; 31][..]).is_err());
    }
}
