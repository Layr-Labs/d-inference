//! Structured provider error classes (plan section 10.5).
//!
//! Typed classes replace the Go coordinator's substring classification.
//! Human-readable text stays diagnostic and never drives control flow, so it
//! does not appear in this type at all.

use serde::{Deserialize, Serialize};

/// Typed provider error class carried in structured errors and terminals.
///
/// The coordinator action per class (plan section 10.5 table) is implemented
/// by the request reducer (alternate eligibility) and the health machine
/// (fault accounting), never by string matching.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ProviderErrorClass {
    /// Deterministic request shape or content error. Returned once, no retry.
    /// Never affects provider health (plan section 11.6).
    InvalidRequest,
    /// Exact provider capacity unavailable. Refreshes advisory state; one
    /// alternate allowed. Not a provider fault (plan section 11.6).
    Capacity,
    /// Model not resident or ready. Signals placement; 429 or one warm
    /// alternate.
    ModelNotReady,
    /// Provider update/shutdown drain. One alternate allowed.
    Draining,
    /// Confirmed cancellation. Lease released according to request state.
    Cancelled,
    /// Provider or engine failure. Health failure recorded; one alternate
    /// only if no attempt was start-authorized.
    Fault,
    /// Identity, encryption, or integrity failure. Hard fence, machine-wide
    /// (plan section 11.6: security state is separate and machine-wide).
    Security,
}

impl ProviderErrorClass {
    /// Whether this rejection class permits selecting a sequential alternate
    /// before start authorization (plan sections 10.5, 11.8).
    #[must_use]
    pub const fn allows_pre_start_alternate(self) -> bool {
        match self {
            Self::Capacity | Self::ModelNotReady | Self::Draining | Self::Fault => true,
            Self::InvalidRequest | Self::Cancelled | Self::Security => false,
        }
    }
}
