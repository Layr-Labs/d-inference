//! Secure-Enclave trust verification and configured provider identity.

mod blocking;
mod challenge;
mod credentials;
mod registration;

use serde::{Deserialize, Serialize};

pub use blocking::{
    BlockingVerificationError, BoundedBlockingVerifier, EpochVerified, VerificationEpoch,
};
pub use challenge::{
    ChallengeExpectation, ChallengeTrust, ChallengeVerificationError, verify_challenge,
};
pub use credentials::{
    ConfiguredProviderCredential, CredentialConfigError, CredentialError, CredentialRegistry,
    PendingCredential,
};
pub use registration::{
    P256PublicIdentity, RegistrationTrust, RegistrationVerificationError, verify_registration,
    verify_signature,
};

/// Cryptographically established provider trust level.
#[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum TrustLevel {
    /// No valid Secure Enclave evidence.
    Untrusted,
    /// Raw registration and fresh challenge signatures bind the SE and X25519 keys.
    SelfSigned,
    /// An external Apple/MDM verifier upgraded the same bound identity.
    Hardware,
}

/// Minimum level required by a routing surface.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct TrustFloor(TrustLevel);

impl TrustFloor {
    /// Public traffic requires hardware-backed external verification.
    pub const PUBLIC: Self = Self(TrustLevel::Hardware);
    /// Private/self-route traffic still requires valid SE key binding.
    pub const SELF_ROUTE: Self = Self(TrustLevel::SelfSigned);

    /// Creates an explicit floor.
    #[must_use]
    pub const fn new(level: TrustLevel) -> Self {
        Self(level)
    }

    /// Required level.
    #[must_use]
    pub const fn required(self) -> TrustLevel {
        self.0
    }

    /// Returns whether verified evidence meets this floor.
    #[must_use]
    pub const fn allows(self, actual: TrustLevel) -> bool {
        actual as u8 >= self.0 as u8
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn trust_floor_never_upgrades_self_reported_evidence() {
        assert!(TrustFloor::SELF_ROUTE.allows(TrustLevel::SelfSigned));
        assert!(!TrustFloor::PUBLIC.allows(TrustLevel::SelfSigned));
        assert!(TrustFloor::PUBLIC.allows(TrustLevel::Hardware));
    }
}
