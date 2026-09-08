//! Per-session configuration, dependencies, and the immutable per-session
//! context shared by the reader and its demux handlers.

use std::sync::Arc;
use std::time::Duration;

use darkbloom_core::ids::{CoordinatorEpoch, ProviderId, SessionEpoch};

use crate::contracts::{self, CoordinatorKeys, FleetHandle, ProtocolGen, SessionLaneCaps};
use crate::trust::TrustVerifier;

use super::heartbeat;

/// Session tunables with pilot defaults mirroring the Go coordinator where
/// one exists.
#[derive(Debug, Clone)]
pub struct SessionConfig {
    /// Maximum inbound frame size (32 MiB — sized for sealed vision
    /// payloads; the WebSocket upgrade limit should carry the same value).
    pub max_frame_bytes: usize,
    /// Deadline for the registration frame on a fresh connection.
    pub registration_timeout: Duration,
    /// Read liveness bound (~Go's 90s heartbeat eviction sweep): a session
    /// with no inbound frame for this long is torn down.
    pub read_timeout: Duration,
    /// Attestation challenge cadence (initial challenge fires immediately).
    pub challenge_interval: Duration,
    /// Per-frame write deadline before the session is declared stalled
    /// (plan §18: writer stall closes the session).
    pub write_timeout: Duration,
    /// Zombie-stream cancel throttle per request id (Go `zombie_stream.go`).
    pub zombie_cancel_throttle: Duration,
    /// Lane capacities handed to the fleet in the
    /// [`SessionSeed`](crate::contracts::SessionSeed).
    pub lane_caps: SessionLaneCaps,
}

impl Default for SessionConfig {
    fn default() -> Self {
        Self {
            max_frame_bytes: 32 * 1024 * 1024,
            registration_timeout: Duration::from_secs(10),
            read_timeout: Duration::from_secs(90),
            challenge_interval: Duration::from_secs(5 * 60),
            write_timeout: Duration::from_secs(30),
            zombie_cancel_throttle: Duration::from_secs(10),
            lane_caps: SessionLaneCaps::default(),
        }
    }
}

/// Everything one session needs. Cheap to clone per connection.
#[derive(Clone)]
pub struct SessionDeps {
    pub fleet: FleetHandle,
    pub trust: Arc<TrustVerifier>,
    /// Coordinator X25519 identity (secret zeroized by the crypto layer).
    pub keys: Arc<CoordinatorKeys>,
    /// Resolves the provider's registration `auth_token` to its earnings
    /// account (the paid-routing beneficiary, plan §11.2). The pilot auth
    /// surface is API keys, so the ledger's [`contracts::ApiKeyStore`] is
    /// the resolver; [`NoProviderAuth`] disables beneficiary resolution for
    /// harnesses without a database.
    pub auth: Arc<dyn contracts::ApiKeyStore>,
    /// Single-active coordinator fence: v2 frames carrying a different
    /// coordinator epoch are dropped (plan §10.2).
    pub coordinator_epoch: CoordinatorEpoch,
    pub config: SessionConfig,
}

/// [`contracts::ApiKeyStore`] that resolves nothing: providers register
/// without a beneficiary and paid routing gates them out (plan §11.2).
pub struct NoProviderAuth;

#[async_trait::async_trait]
impl contracts::ApiKeyStore for NoProviderAuth {
    async fn validate(&self, _token: &str) -> Option<contracts::ApiKeyRecord> {
        None
    }
}

/// Immutable per-session facts shared by the reader and its demux handlers.
pub(crate) struct SessionContext {
    pub provider: ProviderId,
    pub epoch: SessionEpoch,
    pub protocol: ProtocolGen,
    /// The registered X25519 key every v1 encrypted chunk must be sent with.
    pub provider_x25519_b64: String,
    /// SE public key from a valid registration attestation; absent means no
    /// challenge round can verify (pilot: the provider stays at its
    /// registration verdict).
    pub se_public_key: Option<String>,
    pub statics: heartbeat::ProviderStatics,
}
