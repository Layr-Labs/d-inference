//! Linearizable reservation and activation of stable provider sessions.

use std::{
    collections::BTreeMap,
    sync::{Arc, Mutex},
};

use darkbloom_coordinator_protocol::{
    PROTOCOL_V1_MAJOR, PROTOCOL_V2_MAJOR,
    v1::Registration,
    v2::{
        ProtocolCapabilities, ProviderId, ProviderProcessGenerationId, ProviderSessionTracker,
        RegisterAcknowledgement, SessionAllocationError, SessionEpoch,
    },
};
use thiserror::Error;
use tokio_util::sync::CancellationToken;
use uuid::Uuid;

use crate::crypto::SessionEpochStore;

use super::types::{NegotiatedProtocol, SessionIdentity};

/// Finite identity and negotiation policy for the in-process provider registry.
#[derive(Clone, Debug)]
pub struct ProviderRegistryConfig {
    /// Maximum stable provider identities retained for monotonic epochs.
    pub maximum_providers: usize,
    /// Coordinator's complete protocol-v2 capability range.
    pub coordinator_capabilities: ProtocolCapabilities,
    /// Canonical uncompressed P-256 public key used in v2 replay-fence ACKs.
    pub coordinator_replay_fence_public_key: Option<Arc<str>>,
}

impl ProviderRegistryConfig {
    fn validate(self) -> Result<Self, ProviderRegistryConfigError> {
        if self.maximum_providers == 0 {
            return Err(ProviderRegistryConfigError::ZeroProviderLimit);
        }
        if !self.coordinator_capabilities.supports_v2() {
            return Err(ProviderRegistryConfigError::IncompleteCoordinatorV2);
        }
        Ok(self)
    }
}

/// Invalid registry configuration.
#[derive(Clone, Copy, Debug, Eq, Error, PartialEq)]
pub enum ProviderRegistryConfigError {
    /// Epoch history needs a finite positive identity bound.
    #[error("provider registry limit must be greater than zero")]
    ZeroProviderLimit,
    /// Advertising partial v2 would make fallback dependent on implementation details.
    #[error("coordinator capabilities must contain the complete protocol-v2 contract")]
    IncompleteCoordinatorV2,
}

/// Registration reservation failure.
#[derive(Clone, Debug, Eq, Error, PartialEq)]
pub enum SessionReservationError {
    /// Registry cannot retain another stable identity without losing epochs.
    #[error("provider registry limit of {maximum} reached")]
    ProviderLimit {
        /// Configured provider bound.
        maximum: usize,
    },
    /// Only the explicitly implemented majors are accepted.
    #[error("unsupported provider protocol major {0}")]
    UnsupportedProtocolMajor(u16),
    /// Explicit v2 identity is mandatory even if capabilities later downgrade.
    #[error("protocol-v2 registration is missing provider_process_generation")]
    MissingProviderProcessGeneration,
    /// Internal reservation IDs cannot wrap without accepting stale handles.
    #[error("provider session reservation sequence exhausted")]
    ReservationSequenceExhausted,
    /// Session epochs cannot wrap.
    #[error("provider session epoch exhausted")]
    SessionEpochExhausted,
    /// A negotiated v2 ACK requires a canonical replay-fence verification key.
    #[error("negotiated v2 registration requires a canonical coordinator replay-fence key")]
    InvalidCoordinatorReplayFencePublicKey,
    /// The durable epoch allocator failed before any active-session mutation.
    #[error("durable provider session epoch allocation failed: {0}")]
    DurableEpoch(Arc<str>),
    /// An externally fsynced epoch must advance the registry's local history.
    #[error("durable provider session epoch did not advance local history")]
    StaleDurableEpoch,
}

/// Activation failure with transactional stale handling.
#[derive(Clone, Copy, Debug, Eq, Error, PartialEq)]
pub enum SessionActivationError {
    /// A newer reservation superseded this one or this handle was already used.
    #[error("provider session reservation is stale")]
    StaleReservation,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct ReservationToken(u64);

#[derive(Debug)]
struct ActiveSession {
    identity: SessionIdentity,
    protocol: NegotiatedProtocol,
    cancellation: CancellationToken,
}

#[derive(Debug)]
struct ProviderEntry {
    last_session_epoch: SessionEpoch,
    latest_reservation: Option<ReservationToken>,
    active: Option<ActiveSession>,
}

#[derive(Debug, Default)]
struct RegistryState {
    entries: BTreeMap<ProviderId, ProviderEntry>,
    next_reservation: u64,
}

/// One negotiated but not yet current registration.
#[derive(Clone, Debug)]
pub struct SessionReservation {
    token: ReservationToken,
    identity: SessionIdentity,
    protocol: NegotiatedProtocol,
    acknowledgement: RegisterAcknowledgement,
}

impl SessionReservation {
    /// Reserved provider-session identity.
    #[must_use]
    pub const fn identity(&self) -> SessionIdentity {
        self.identity
    }

    /// Explicit protocol selected for this registration.
    #[must_use]
    pub const fn protocol(&self) -> &NegotiatedProtocol {
        &self.protocol
    }

    /// Generation-bound response to place on the registration connection.
    #[must_use]
    pub const fn acknowledgement(&self) -> &RegisterAcknowledgement {
        &self.acknowledgement
    }
}

/// Result of atomically making a reservation current.
#[derive(Debug)]
pub struct SessionActivation {
    /// Lease whose drop can remove only this exact session.
    pub lease: SessionLease,
    /// Replaced identity, when this activation fenced an older connection.
    pub replaced: Option<SessionIdentity>,
    /// Protocol selected for the exact replaced identity.
    pub replaced_protocol: Option<NegotiatedProtocol>,
}

/// Exact-current registry lease.
///
/// Dropping an old lease after replacement cannot remove the replacement:
/// teardown compares provider, generation, and epoch under the registry lock.
#[derive(Debug)]
pub struct SessionLease {
    registry: Arc<ProviderRegistry>,
    identity: SessionIdentity,
    cancellation: CancellationToken,
}

impl SessionLease {
    /// Current identity owned by this lease.
    #[must_use]
    pub const fn identity(&self) -> SessionIdentity {
        self.identity
    }

    /// Token cancelled by replacement, explicit shutdown, or lease drop.
    #[must_use]
    pub fn cancellation_token(&self) -> CancellationToken {
        self.cancellation.clone()
    }
}

impl Drop for SessionLease {
    fn drop(&mut self) {
        self.cancellation.cancel();
        self.registry.remove_if_current(self.identity);
    }
}

/// Sole allocator of provider session epochs and current connections.
#[derive(Debug)]
pub struct ProviderRegistry {
    config: ProviderRegistryConfig,
    epoch_store: Option<Arc<SessionEpochStore>>,
    state: Mutex<RegistryState>,
}

impl ProviderRegistry {
    /// Creates an empty bounded registry.
    pub fn new(config: ProviderRegistryConfig) -> Result<Self, ProviderRegistryConfigError> {
        Ok(Self {
            config: config.validate()?,
            epoch_store: None,
            state: Mutex::new(RegistryState::default()),
        })
    }

    /// Creates a registry whose epochs are fsynced before a reservation can be
    /// acknowledged or made current.
    pub fn new_with_epoch_store(
        config: ProviderRegistryConfig,
        epoch_store: Arc<SessionEpochStore>,
    ) -> Result<Self, ProviderRegistryConfigError> {
        Ok(Self {
            config: config.validate()?,
            epoch_store: Some(epoch_store),
            state: Mutex::new(RegistryState::default()),
        })
    }

    /// Reserves negotiation and a monotonic epoch from a typed registration.
    pub fn reserve(
        &self,
        provider_id: ProviderId,
        registration: &Registration,
    ) -> Result<SessionReservation, SessionReservationError> {
        self.reserve_offer(
            provider_id,
            registration.provider_process_generation,
            registration.protocol_capabilities.as_ref(),
        )
    }

    /// Reserves using an epoch already fsynced by the bounded durable-I/O
    /// pool. Production registration uses this path so no filesystem work can
    /// execute under a Tokio worker or the registry mutex.
    pub fn reserve_with_epoch(
        &self,
        provider_id: ProviderId,
        registration: &Registration,
        allocated_epoch: SessionEpoch,
    ) -> Result<SessionReservation, SessionReservationError> {
        self.reserve_offer_inner(
            provider_id,
            registration.provider_process_generation,
            registration.protocol_capabilities.as_ref(),
            Some(allocated_epoch),
        )
    }

    /// Reserves from the registration fields that determine session identity.
    ///
    /// This method is useful for an authentication boundary that validates the
    /// full registration before passing only its stable identity offer here.
    pub fn reserve_offer(
        &self,
        provider_id: ProviderId,
        provider_process_generation: Option<ProviderProcessGenerationId>,
        provider_capabilities: Option<&ProtocolCapabilities>,
    ) -> Result<SessionReservation, SessionReservationError> {
        self.reserve_offer_inner(
            provider_id,
            provider_process_generation,
            provider_capabilities,
            None,
        )
    }

    fn reserve_offer_inner(
        &self,
        provider_id: ProviderId,
        provider_process_generation: Option<ProviderProcessGenerationId>,
        provider_capabilities: Option<&ProtocolCapabilities>,
        allocated_epoch: Option<SessionEpoch>,
    ) -> Result<SessionReservation, SessionReservationError> {
        let capabilities = explicit_capabilities(provider_capabilities)?;
        let generation = match provider_process_generation {
            Some(generation) => generation,
            None if capabilities.protocol_major == PROTOCOL_V2_MAJOR => {
                return Err(SessionReservationError::MissingProviderProcessGeneration);
            }
            None => ProviderProcessGenerationId::new(*Uuid::new_v4().as_bytes()),
        };

        let mut state = self.lock_state();
        if !state.entries.contains_key(&provider_id)
            && state.entries.len() >= self.config.maximum_providers
        {
            return Err(SessionReservationError::ProviderLimit {
                maximum: self.config.maximum_providers,
            });
        }

        let last_epoch = state
            .entries
            .get(&provider_id)
            .map(|entry| entry.last_session_epoch);
        let mut tracker = last_epoch.map_or_else(
            || ProviderSessionTracker::new(provider_id),
            |epoch| ProviderSessionTracker::resume(provider_id, epoch),
        );
        let mut acknowledgement = tracker
            .acknowledge(
                generation,
                &capabilities,
                &self.config.coordinator_capabilities,
                self.config.coordinator_replay_fence_public_key.as_deref(),
            )
            .map_err(map_allocation_error)?;
        if let Some(allocated_epoch) = allocated_epoch {
            if last_epoch.is_some_and(|last| allocated_epoch <= last) || allocated_epoch.0 == 0 {
                return Err(SessionReservationError::StaleDurableEpoch);
            }
            acknowledgement.session_epoch = allocated_epoch;
        } else if let Some(epoch_store) = &self.epoch_store {
            // Allocation is an atomic-file write plus file and parent-directory
            // fsync. It intentionally precedes every in-process reservation or
            // active-session mutation; a crash may leave a harmless gap, never
            // a reused epoch.
            acknowledgement.session_epoch = epoch_store.allocate(provider_id).map_err(|error| {
                SessionReservationError::DurableEpoch(Arc::from(error.to_string()))
            })?;
        }
        let next_reservation = state
            .next_reservation
            .checked_add(1)
            .ok_or(SessionReservationError::ReservationSequenceExhausted)?;
        let token = ReservationToken(next_reservation);
        let protocol = acknowledgement
            .protocol_capabilities
            .clone()
            .map_or(NegotiatedProtocol::V1, NegotiatedProtocol::V2);
        let identity = SessionIdentity {
            provider_id,
            provider_process_generation: generation,
            session_epoch: acknowledgement.session_epoch,
        };

        state.next_reservation = next_reservation;
        let entry = state
            .entries
            .entry(provider_id)
            .or_insert_with(|| ProviderEntry {
                last_session_epoch: acknowledgement.session_epoch,
                latest_reservation: None,
                active: None,
            });
        entry.last_session_epoch = acknowledgement.session_epoch;
        entry.latest_reservation = Some(token);
        Ok(SessionReservation {
            token,
            identity,
            protocol,
            acknowledgement,
        })
    }

    /// Makes only the latest reservation current.
    ///
    /// Stale activation returns before changing the active entry or cancelling
    /// any connection. A successful replacement is installed under the lock;
    /// its predecessor is cancelled only after the lock is released.
    pub fn activate(
        self: &Arc<Self>,
        reservation: &SessionReservation,
    ) -> Result<SessionActivation, SessionActivationError> {
        let cancellation = CancellationToken::new();
        let (replaced, replaced_protocol, replaced_cancellation) = {
            let mut state = self.lock_state();
            let Some(entry) = state.entries.get_mut(&reservation.identity.provider_id) else {
                return Err(SessionActivationError::StaleReservation);
            };
            if entry.latest_reservation != Some(reservation.token)
                || entry.last_session_epoch != reservation.identity.session_epoch
            {
                return Err(SessionActivationError::StaleReservation);
            }

            entry.latest_reservation = None;
            let replaced = entry.active.replace(ActiveSession {
                identity: reservation.identity,
                protocol: reservation.protocol.clone(),
                cancellation: cancellation.clone(),
            });
            (
                replaced.as_ref().map(|active| active.identity),
                replaced.as_ref().map(|active| active.protocol.clone()),
                replaced.map(|active| active.cancellation),
            )
        };
        if let Some(previous) = replaced_cancellation {
            previous.cancel();
        }
        Ok(SessionActivation {
            lease: SessionLease {
                registry: self.clone(),
                identity: reservation.identity,
                cancellation,
            },
            replaced,
            replaced_protocol,
        })
    }

    /// Abandons a reservation only if no newer registration superseded it.
    pub fn abandon(&self, reservation: &SessionReservation) -> bool {
        let mut state = self.lock_state();
        let Some(entry) = state.entries.get_mut(&reservation.identity.provider_id) else {
            return false;
        };
        if entry.latest_reservation != Some(reservation.token) {
            return false;
        }
        entry.latest_reservation = None;
        true
    }

    /// Returns the exact current identity for a stable provider.
    #[must_use]
    pub fn current(&self, provider_id: ProviderId) -> Option<SessionIdentity> {
        self.lock_state()
            .entries
            .get(&provider_id)
            .and_then(|entry| entry.active.as_ref())
            .map(|active| active.identity)
    }

    /// Returns whether the supplied provider generation and epoch are current.
    #[must_use]
    pub fn is_current(&self, identity: SessionIdentity) -> bool {
        self.current(identity.provider_id) == Some(identity)
    }

    /// Number of retained stable identities, including disconnected history.
    #[must_use]
    pub fn provider_count(&self) -> usize {
        self.lock_state().entries.len()
    }

    /// Number of currently active provider sessions.
    #[must_use]
    pub fn active_count(&self) -> usize {
        self.lock_state()
            .entries
            .values()
            .filter(|entry| entry.active.is_some())
            .count()
    }

    fn remove_if_current(&self, identity: SessionIdentity) -> bool {
        let mut state = self.lock_state();
        let Some(entry) = state.entries.get_mut(&identity.provider_id) else {
            return false;
        };
        if entry.active.as_ref().map(|active| active.identity) != Some(identity) {
            return false;
        }
        entry.active = None;
        true
    }

    fn lock_state(&self) -> std::sync::MutexGuard<'_, RegistryState> {
        self.state
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
    }
}

fn explicit_capabilities(
    capabilities: Option<&ProtocolCapabilities>,
) -> Result<ProtocolCapabilities, SessionReservationError> {
    let capabilities = capabilities.cloned().unwrap_or(ProtocolCapabilities {
        protocol_major: PROTOCOL_V1_MAJOR,
        ..ProtocolCapabilities::default()
    });
    if !matches!(
        capabilities.protocol_major,
        PROTOCOL_V1_MAJOR | PROTOCOL_V2_MAJOR
    ) {
        return Err(SessionReservationError::UnsupportedProtocolMajor(
            capabilities.protocol_major,
        ));
    }
    Ok(capabilities)
}

fn map_allocation_error(error: SessionAllocationError) -> SessionReservationError {
    match error {
        SessionAllocationError::SessionEpochExhausted => {
            SessionReservationError::SessionEpochExhausted
        }
        SessionAllocationError::InvalidCoordinatorReplayFencePublicKey => {
            SessionReservationError::InvalidCoordinatorReplayFencePublicKey
        }
    }
}

#[cfg(test)]
mod tests {
    use base64::{Engine, engine::general_purpose::STANDARD};

    use super::*;

    fn provider(value: u8) -> ProviderId {
        ProviderId::new([value; 16])
    }

    fn generation(value: u8) -> ProviderProcessGenerationId {
        ProviderProcessGenerationId::new([value; 16])
    }

    fn complete_v2() -> ProtocolCapabilities {
        ProtocolCapabilities {
            protocol_major: 2,
            protocol_minor: 3,
            minimum_compatible_minor: 1,
            prepared_leases: true,
            start_authorization: true,
            structured_errors: true,
            start_ack: true,
            abort_ack: true,
            cancel_ack: true,
            durable_terminals: true,
            model_lifecycle_events: true,
            binary_payload_frames: true,
            coordinator_replay_fences: true,
        }
    }

    fn replay_key() -> Arc<str> {
        let mut raw = [0x44; 65];
        raw[0] = 0x04;
        Arc::from(STANDARD.encode(raw))
    }

    fn registry(maximum_providers: usize) -> Arc<ProviderRegistry> {
        Arc::new(
            ProviderRegistry::new(ProviderRegistryConfig {
                maximum_providers,
                coordinator_capabilities: complete_v2(),
                coordinator_replay_fence_public_key: Some(replay_key()),
            })
            .expect("registry"),
        )
    }

    #[test]
    fn epochs_are_monotonic_across_reconnects() {
        let registry = registry(4);
        let first = registry
            .reserve_offer(provider(1), Some(generation(2)), Some(&complete_v2()))
            .expect("first");
        let second = registry
            .reserve_offer(provider(1), Some(generation(3)), Some(&complete_v2()))
            .expect("second");
        assert_eq!(first.identity().session_epoch, SessionEpoch(1));
        assert_eq!(second.identity().session_epoch, SessionEpoch(2));
        assert_eq!(first.identity().provider_id, second.identity().provider_id);
    }

    #[test]
    fn stale_concurrent_activation_has_zero_current_side_effects() {
        let registry = registry(4);
        let first = registry
            .reserve_offer(provider(1), Some(generation(2)), Some(&complete_v2()))
            .expect("first");
        let second = registry
            .reserve_offer(provider(1), Some(generation(3)), Some(&complete_v2()))
            .expect("second");
        let active = registry.activate(&second).expect("latest activation");
        assert_eq!(registry.current(provider(1)), Some(second.identity()));
        assert!(matches!(
            registry.activate(&first),
            Err(SessionActivationError::StaleReservation)
        ));
        assert_eq!(registry.current(provider(1)), Some(second.identity()));
        assert!(!active.lease.cancellation_token().is_cancelled());
    }

    #[test]
    fn replacement_cancels_old_but_old_teardown_cannot_remove_new() {
        let registry = registry(4);
        let first = registry
            .reserve_offer(provider(1), Some(generation(2)), Some(&complete_v2()))
            .expect("first");
        let first = registry.activate(&first).expect("activate first");
        let old_cancellation = first.lease.cancellation_token();
        let second = registry
            .reserve_offer(provider(1), Some(generation(3)), Some(&complete_v2()))
            .expect("second");
        let second = registry.activate(&second).expect("activate replacement");
        assert_eq!(second.replaced, Some(first.lease.identity()));
        assert!(matches!(
            second.replaced_protocol.as_ref(),
            Some(NegotiatedProtocol::V2(_))
        ));
        assert!(old_cancellation.is_cancelled());
        drop(first);
        assert_eq!(registry.current(provider(1)), Some(second.lease.identity()));
    }

    #[test]
    fn explicit_v1_and_v2_negotiation_are_acknowledged() {
        let registry = registry(4);
        let v1 = registry
            .reserve_offer(provider(1), None, None)
            .expect("legacy v1");
        assert_eq!(v1.protocol(), &NegotiatedProtocol::V1);
        assert!(v1.acknowledgement().protocol_capabilities.is_none());
        assert!(
            v1.acknowledgement()
                .coordinator_replay_fence_public_key
                .is_none()
        );

        let v2 = registry
            .reserve_offer(provider(2), Some(generation(4)), Some(&complete_v2()))
            .expect("v2");
        assert!(matches!(v2.protocol(), NegotiatedProtocol::V2(_)));
        assert_eq!(
            v2.acknowledgement().provider_process_generation,
            generation(4)
        );
        assert_eq!(
            v2.acknowledgement()
                .coordinator_replay_fence_public_key
                .as_deref(),
            Some(replay_key().as_ref())
        );
    }

    #[test]
    fn incomplete_v2_overlap_explicitly_selects_v1() {
        let registry = registry(4);
        let incomplete = ProtocolCapabilities {
            binary_payload_frames: false,
            ..complete_v2()
        };
        let reservation = registry
            .reserve_offer(provider(1), Some(generation(2)), Some(&incomplete))
            .expect("defined downgrade");
        assert_eq!(reservation.protocol(), &NegotiatedProtocol::V1);
        assert!(
            reservation
                .acknowledgement()
                .coordinator_replay_fence_public_key
                .is_none()
        );
    }

    #[test]
    fn malformed_negotiation_does_not_consume_an_epoch() {
        let registry = Arc::new(
            ProviderRegistry::new(ProviderRegistryConfig {
                maximum_providers: 4,
                coordinator_capabilities: complete_v2(),
                coordinator_replay_fence_public_key: None,
            })
            .expect("registry"),
        );
        assert!(matches!(
            registry.reserve_offer(provider(1), Some(generation(2)), Some(&complete_v2())),
            Err(SessionReservationError::InvalidCoordinatorReplayFencePublicKey)
        ));
        let v1 = registry
            .reserve_offer(provider(1), None, None)
            .expect("first successful reservation");
        assert_eq!(v1.identity().session_epoch, SessionEpoch(1));
    }

    #[test]
    fn unsupported_major_and_missing_v2_generation_are_rejected() {
        let registry = registry(4);
        let unknown = ProtocolCapabilities {
            protocol_major: 9,
            ..ProtocolCapabilities::default()
        };
        assert!(matches!(
            registry.reserve_offer(provider(1), None, Some(&unknown)),
            Err(SessionReservationError::UnsupportedProtocolMajor(9))
        ));
        assert!(matches!(
            registry.reserve_offer(provider(1), None, Some(&complete_v2())),
            Err(SessionReservationError::MissingProviderProcessGeneration)
        ));
        assert_eq!(registry.provider_count(), 0);
    }

    #[test]
    fn one_thousand_stable_sessions_remain_bounded() {
        let registry = registry(1_000);
        let mut leases = Vec::with_capacity(1_000);
        for value in 1..=1_000_u128 {
            let id = ProviderId::new(value.to_be_bytes());
            let reservation = registry
                .reserve_offer(id, None, None)
                .expect("within bound");
            leases.push(registry.activate(&reservation).expect("activate").lease);
        }
        assert_eq!(registry.provider_count(), 1_000);
        assert_eq!(registry.active_count(), 1_000);
        let overflow = ProviderId::new(1_001_u128.to_be_bytes());
        assert!(matches!(
            registry.reserve_offer(overflow, None, None),
            Err(SessionReservationError::ProviderLimit { maximum: 1_000 })
        ));
        drop(leases);
        assert_eq!(registry.provider_count(), 1_000);
        assert_eq!(registry.active_count(), 0);
    }
}
