//! Identity, epoch, and digest newtypes (plan section 19.3).
//!
//! Every identifier that crosses an authority boundary gets its own type so a
//! `JobId` can never be passed where an `AttemptId` is required. Epochs are
//! ordered newtypes because fencing (plan sections 9.1.2, 9.1.6, 10.2) is a
//! comparison, never an equality-only check. Digests are fixed 32-byte values
//! because terminal idempotency and conflict detection (plan sections 9.3,
//! 10.6) compare exact digests.
//!
//! The core crate never generates identifiers; the caller (server crate or a
//! test) constructs them explicitly.

use serde::{Deserialize, Serialize};
use uuid::Uuid;

macro_rules! uuid_id {
    ($(#[$doc:meta])* $name:ident) => {
        $(#[$doc])*
        #[derive(
            Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize,
        )]
        #[serde(transparent)]
        pub struct $name(Uuid);

        impl $name {
            #[must_use]
            pub const fn new(id: Uuid) -> Self {
                Self(id)
            }

            #[must_use]
            pub const fn get(self) -> Uuid {
                self.0
            }

            #[must_use]
            pub const fn as_bytes(&self) -> &[u8; 16] {
                self.0.as_bytes()
            }
        }

        impl core::fmt::Display for $name {
            fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
                write!(f, "{}", self.0)
            }
        }
    };
}

uuid_id!(
    /// One logical consumer request and its financial job (plan section 9.2.1).
    JobId
);
uuid_id!(
    /// One provider dispatch. Every dispatch gets a distinct attempt identity
    /// (plan section 9.2.2).
    AttemptId
);
uuid_id!(
    /// A provider-side prepared lease (plan section 10.3). Exact capacity
    /// authority; authorizes no emission until start.
    LeaseId
);
uuid_id!(
    /// A short-lived coordinator-local prepare permit (plan section 11.1).
    PermitId
);
uuid_id!(
    /// Stable provider identity, independent of any connection or session
    /// epoch (plan section 9.1.1).
    ProviderId
);
uuid_id!(
    /// A balance-holding account (consumer, provider beneficiary, platform, or
    /// referrer). Frozen beneficiary identities (plan section 12.4) are
    /// account ids.
    AccountId
);

macro_rules! epoch_u64 {
    ($(#[$doc:meta])* $name:ident) => {
        $(#[$doc])*
        #[derive(
            Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash,
            Serialize, Deserialize, Default,
        )]
        #[serde(transparent)]
        pub struct $name(u64);

        impl $name {
            #[must_use]
            pub const fn new(v: u64) -> Self {
                Self(v)
            }

            #[must_use]
            pub const fn get(self) -> u64 {
                self.0
            }

            /// The successor epoch, saturating at `u64::MAX`.
            #[must_use]
            pub const fn next(self) -> Self {
                Self(self.0.saturating_add(1))
            }
        }
    };
}

epoch_u64!(
    /// Active provider connection fence (plan sections 9.1.1, 9.1.2). Frames
    /// from stale session epochs cannot mutate live state.
    SessionEpoch
);
epoch_u64!(
    /// Single-active coordinator fence (plan sections 10.2, 20). Every
    /// financial command records the coordinator epoch that created it.
    CoordinatorEpoch
);
epoch_u64!(
    /// Monotonic trust epoch (plan sections 9.1.6, 9.1.8). A hard trust
    /// downgrade cannot be reversed by an older in-flight verifier result.
    TrustEpoch
);
epoch_u64!(
    /// Monotonic provider-process state revision carried by model lifecycle
    /// events and heartbeat snapshots (plan section 10.7). Older revisions
    /// are ignored so a delayed heartbeat cannot resurrect a gone model.
    StateRevision
);

/// Replay and substitution fence carried by every request frame
/// (plan section 10.2).
#[derive(
    Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize, Default,
)]
#[serde(transparent)]
pub struct DispatchNonce(u64);

impl DispatchNonce {
    #[must_use]
    pub const fn new(v: u64) -> Self {
        Self(v)
    }

    #[must_use]
    pub const fn get(self) -> u64 {
        self.0
    }
}

macro_rules! digest32 {
    ($(#[$doc:meta])* $name:ident) => {
        $(#[$doc])*
        #[derive(
            Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize,
        )]
        #[serde(transparent)]
        pub struct $name([u8; 32]);

        impl $name {
            #[must_use]
            pub const fn new(bytes: [u8; 32]) -> Self {
                Self(bytes)
            }

            #[must_use]
            pub const fn as_bytes(&self) -> &[u8; 32] {
                &self.0
            }
        }
    };
}

digest32!(
    /// Digest of the canonical encrypted request envelope (plan section 10.2).
    /// The provider compares inner and outer values after decryption.
    RequestDigest
);
digest32!(
    /// Digest of one canonical signed terminal (plan section 10.6). Duplicate
    /// terminals with the same digest are idempotent; the same attempt with a
    /// different digest is a protocol conflict that cannot move money.
    TerminalDigest
);

/// Consumer API key identity frozen into settlement terms
/// (plan section 12.4: consumer account and API key persist before start).
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(transparent)]
pub struct ApiKeyId(String);

impl ApiKeyId {
    #[must_use]
    pub fn new(id: impl Into<String>) -> Self {
        Self(id.into())
    }

    #[must_use]
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

/// Concrete model identity as routed and frozen (plan section 12.4).
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(transparent)]
pub struct ModelId(String);

impl ModelId {
    #[must_use]
    pub fn new(id: impl Into<String>) -> Self {
        Self(id.into())
    }

    #[must_use]
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl core::fmt::Display for ModelId {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        f.write_str(&self.0)
    }
}

/// Provider hardware class used for calibration keying (plan section 11.4:
/// windowed median of actual versus predicted per model and hardware class).
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(transparent)]
pub struct HardwareClass(String);

impl HardwareClass {
    #[must_use]
    pub fn new(class: impl Into<String>) -> Self {
        Self(class.into())
    }

    #[must_use]
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl core::fmt::Display for HardwareClass {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        f.write_str(&self.0)
    }
}
