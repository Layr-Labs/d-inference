//! Structured provider error classes (plan §10.5).
//!
//! Replaces the Go coordinator's substring classification. Human-readable
//! text stays diagnostic; only this enum drives control flow.

use serde::{Deserialize, Serialize};

/// Typed provider error class.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ErrorClass {
    /// Deterministic request shape or content error. Return once, no retry.
    InvalidRequest,
    /// Exact provider capacity unavailable. Refresh advisory state; one
    /// alternate allowed.
    Capacity,
    /// Model not resident or ready. Signal placement; 429 or one warm
    /// alternate.
    ModelNotReady,
    /// Provider update/shutdown drain. One alternate allowed.
    Draining,
    /// Confirmed cancellation. Release lease according to request state.
    Cancelled,
    /// Provider or engine failure. Health failure; one alternate only if no
    /// attempt was start-authorized.
    Fault,
    /// Identity, encryption, or integrity failure. Hard fence provider.
    Security,
}

impl ErrorClass {
    /// The wire string for this class.
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::InvalidRequest => "invalid_request",
            Self::Capacity => "capacity",
            Self::ModelNotReady => "model_not_ready",
            Self::Draining => "draining",
            Self::Cancelled => "cancelled",
            Self::Fault => "fault",
            Self::Security => "security",
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn wire_names_are_snake_case() {
        for (class, wire) in [
            (ErrorClass::InvalidRequest, "\"invalid_request\""),
            (ErrorClass::Capacity, "\"capacity\""),
            (ErrorClass::ModelNotReady, "\"model_not_ready\""),
            (ErrorClass::Draining, "\"draining\""),
            (ErrorClass::Cancelled, "\"cancelled\""),
            (ErrorClass::Fault, "\"fault\""),
            (ErrorClass::Security, "\"security\""),
        ] {
            assert_eq!(serde_json::to_string(&class).unwrap(), wire);
            assert_eq!(serde_json::from_str::<ErrorClass>(wire).unwrap(), class);
            assert_eq!(format!("\"{}\"", class.as_str()), wire);
        }
    }
}
