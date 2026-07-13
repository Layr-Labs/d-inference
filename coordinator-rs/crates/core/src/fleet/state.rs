//! Immutable fleet snapshots and revision-fenced updates.

use std::collections::BTreeMap;

use serde::Serialize;
use thiserror::Error;

use crate::{
    ids::{FleetRevision, HardwareClass, ProviderId, SessionRevision},
    request::ProviderFence,
    tokens::{KvBytes, TokenCount},
    traits::ProviderTraits,
};

use super::health::HealthState;

/// Provider capacity counters from one immutable fleet snapshot.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
pub struct CapacitySnapshot {
    token_capacity: TokenCount,
    tokens_in_use: TokenCount,
    kv_capacity: KvBytes,
    kv_in_use: KvBytes,
    concurrency_limit: u32,
    concurrency_in_use: u32,
}

impl CapacitySnapshot {
    /// Creates capacity after validating all used values against their limits.
    pub fn new(
        token_capacity: TokenCount,
        tokens_in_use: TokenCount,
        kv_capacity: KvBytes,
        kv_in_use: KvBytes,
        concurrency_limit: u32,
        concurrency_in_use: u32,
    ) -> Result<Self, CapacityError> {
        if concurrency_limit == 0 {
            return Err(CapacityError::ZeroConcurrencyLimit);
        }
        if tokens_in_use > token_capacity {
            return Err(CapacityError::TokensOverCapacity);
        }
        if kv_in_use > kv_capacity {
            return Err(CapacityError::KvOverCapacity);
        }
        if concurrency_in_use > concurrency_limit {
            return Err(CapacityError::ConcurrencyOverCapacity);
        }
        Ok(Self {
            token_capacity,
            tokens_in_use,
            kv_capacity,
            kv_in_use,
            concurrency_limit,
            concurrency_in_use,
        })
    }

    /// Total token budget.
    #[must_use]
    pub const fn token_capacity(self) -> TokenCount {
        self.token_capacity
    }

    /// Token budget currently reserved.
    #[must_use]
    pub const fn tokens_in_use(self) -> TokenCount {
        self.tokens_in_use
    }

    /// Total KV-cache budget.
    #[must_use]
    pub const fn kv_capacity(self) -> KvBytes {
        self.kv_capacity
    }

    /// KV-cache bytes currently reserved.
    #[must_use]
    pub const fn kv_in_use(self) -> KvBytes {
        self.kv_in_use
    }

    /// Maximum concurrent requests.
    #[must_use]
    pub const fn concurrency_limit(self) -> u32 {
        self.concurrency_limit
    }

    /// Concurrent requests currently reserved.
    #[must_use]
    pub const fn concurrency_in_use(self) -> u32 {
        self.concurrency_in_use
    }
}

/// Invalid provider capacity snapshot.
#[derive(Clone, Copy, Debug, Eq, Error, PartialEq)]
pub enum CapacityError {
    /// A provider cannot advertise a zero concurrency limit.
    #[error("concurrency limit must be greater than zero")]
    ZeroConcurrencyLimit,
    /// Reserved tokens exceed the total token budget.
    #[error("tokens in use exceed token capacity")]
    TokensOverCapacity,
    /// Reserved KV bytes exceed KV capacity.
    #[error("KV bytes in use exceed KV capacity")]
    KvOverCapacity,
    /// Active concurrency exceeds its limit.
    #[error("concurrency in use exceeds concurrency limit")]
    ConcurrencyOverCapacity,
}

/// Provider state captured in one fleet revision.
#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct ProviderSnapshot {
    fence: ProviderFence,
    hardware: HardwareClass,
    traits: ProviderTraits,
    capacity: CapacitySnapshot,
    health: HealthState,
}

/// Fence retained after provider removal to reject delayed session updates.
#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct ProviderTombstone {
    removed_at_revision: FleetRevision,
    fence: ProviderFence,
}

impl ProviderTombstone {
    /// Returns the fleet revision that removed the provider.
    #[must_use]
    pub const fn removed_at_revision(&self) -> FleetRevision {
        self.removed_at_revision
    }

    /// Returns the last accepted provider fence.
    #[must_use]
    pub const fn fence(&self) -> &ProviderFence {
        &self.fence
    }
}

impl ProviderSnapshot {
    /// Creates a provider snapshot.
    #[must_use]
    pub fn new(
        fence: ProviderFence,
        hardware: HardwareClass,
        traits: ProviderTraits,
        capacity: CapacitySnapshot,
        health: HealthState,
    ) -> Self {
        Self {
            fence,
            hardware,
            traits,
            capacity,
            health,
        }
    }

    /// Returns the provider revision fence.
    #[must_use]
    pub const fn fence(&self) -> &ProviderFence {
        &self.fence
    }

    /// Returns the calibration hardware class.
    #[must_use]
    pub const fn hardware(&self) -> &HardwareClass {
        &self.hardware
    }

    /// Returns capability traits.
    #[must_use]
    pub const fn traits(&self) -> &ProviderTraits {
        &self.traits
    }

    /// Returns capacity counters.
    #[must_use]
    pub const fn capacity(&self) -> CapacitySnapshot {
        self.capacity
    }

    /// Returns circuit-breaker health.
    #[must_use]
    pub const fn health(&self) -> HealthState {
        self.health
    }
}

/// Fleet update at one globally monotonic revision.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct FleetEvent {
    /// New fleet revision.
    pub revision: FleetRevision,
    /// Provider mutation.
    pub update: FleetUpdate,
}

/// One immutable provider-map mutation.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum FleetUpdate {
    /// Inserts or replaces a provider snapshot.
    Upsert(Box<ProviderSnapshot>),
    /// Removes a provider only if the session revision still matches.
    Remove {
        /// Provider to remove.
        provider_id: ProviderId,
        /// Session revision observed by the disconnecting caller.
        expected_session_revision: SessionRevision,
    },
}

/// Immutable fleet view used by admission and scoring.
#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct FleetSnapshot {
    revision: FleetRevision,
    providers: BTreeMap<ProviderId, ProviderSnapshot>,
    tombstones: BTreeMap<ProviderId, ProviderTombstone>,
}

impl FleetSnapshot {
    /// Creates an empty snapshot at an explicit nonzero revision.
    #[must_use]
    pub fn new(revision: FleetRevision) -> Self {
        Self {
            revision,
            providers: BTreeMap::new(),
            tombstones: BTreeMap::new(),
        }
    }

    /// Returns the global fleet revision.
    #[must_use]
    pub const fn revision(&self) -> FleetRevision {
        self.revision
    }

    /// Returns one provider snapshot.
    #[must_use]
    pub fn provider(&self, id: ProviderId) -> Option<&ProviderSnapshot> {
        self.providers.get(&id)
    }

    /// Returns the last removed fence for an absent provider.
    #[must_use]
    pub fn tombstone(&self, id: ProviderId) -> Option<&ProviderTombstone> {
        self.tombstones.get(&id)
    }

    /// Iterates providers in stable identifier order.
    pub fn providers(&self) -> impl Iterator<Item = &ProviderSnapshot> {
        self.providers.values()
    }
}

/// Applies one revision-fenced fleet event without mutating its input.
pub fn reduce(state: &FleetSnapshot, event: FleetEvent) -> Result<FleetSnapshot, FleetStateError> {
    if event.revision <= state.revision {
        return Err(FleetStateError::StaleFleetRevision {
            current: state.revision,
            supplied: event.revision,
        });
    }

    let mut providers = state.providers.clone();
    let mut tombstones = state.tombstones.clone();
    match event.update {
        FleetUpdate::Upsert(incoming) => {
            let provider_id = incoming.fence.provider_id;
            if let Some(existing) = providers.get(&provider_id) {
                validate_provider_revision(existing.fence(), incoming.fence())?;
            } else if let Some(tombstone) = tombstones.get(&provider_id) {
                validate_tombstone_successor(tombstone, incoming.fence())?;
                tombstones.remove(&provider_id);
            }
            providers.insert(provider_id, *incoming);
        }
        FleetUpdate::Remove {
            provider_id,
            expected_session_revision,
        } => {
            let existing = providers
                .get(&provider_id)
                .ok_or(FleetStateError::ProviderNotFound(provider_id))?;
            if existing.fence.session_revision != expected_session_revision {
                return Err(FleetStateError::StaleProviderRevision { provider_id });
            }
            let removed = providers
                .remove(&provider_id)
                .ok_or(FleetStateError::ProviderNotFound(provider_id))?;
            tombstones.insert(
                provider_id,
                ProviderTombstone {
                    removed_at_revision: event.revision,
                    fence: removed.fence,
                },
            );
        }
    }
    Ok(FleetSnapshot {
        revision: event.revision,
        providers,
        tombstones,
    })
}

fn validate_provider_revision(
    existing: &ProviderFence,
    incoming: &ProviderFence,
) -> Result<(), FleetStateError> {
    let provider_id = incoming.provider_id;
    let session_conflicts = if incoming.session_revision == existing.session_revision {
        incoming.session_id != existing.session_id
    } else {
        incoming.session_revision < existing.session_revision
            || incoming.session_id == existing.session_id
    };
    if session_conflicts
        || incoming.trust_revision < existing.trust_revision
        || incoming.model_revision < existing.model_revision
        || (incoming.model_id != existing.model_id
            && incoming.model_revision <= existing.model_revision)
    {
        return Err(FleetStateError::StaleProviderRevision { provider_id });
    }
    Ok(())
}

fn validate_tombstone_successor(
    tombstone: &ProviderTombstone,
    incoming: &ProviderFence,
) -> Result<(), FleetStateError> {
    if incoming.session_revision <= tombstone.fence.session_revision
        || incoming.session_id == tombstone.fence.session_id
    {
        return Err(FleetStateError::RemovedSessionRevision {
            provider_id: incoming.provider_id,
            removed_at: tombstone.removed_at_revision,
        });
    }
    validate_provider_revision(&tombstone.fence, incoming)
}

/// Rejected fleet update.
#[derive(Clone, Copy, Debug, Eq, Error, PartialEq)]
pub enum FleetStateError {
    /// Fleet events must increase the global revision.
    #[error("stale fleet revision {supplied:?}; current is {current:?}")]
    StaleFleetRevision {
        /// Current snapshot revision.
        current: FleetRevision,
        /// Rejected revision.
        supplied: FleetRevision,
    },
    /// Provider session, trust, or model revision regressed or conflicted.
    #[error("provider {provider_id} supplied a stale revision")]
    StaleProviderRevision {
        /// Provider with a stale update.
        provider_id: ProviderId,
    },
    /// An update attempted to resurrect a removed provider session.
    #[error("provider {provider_id} session was removed at fleet revision {removed_at:?}")]
    RemovedSessionRevision {
        /// Provider whose delayed session update was rejected.
        provider_id: ProviderId,
        /// Fleet revision that installed the tombstone.
        removed_at: FleetRevision,
    },
    /// A disconnect referenced an absent provider.
    #[error("provider {0} is not in the fleet snapshot")]
    ProviderNotFound(ProviderId),
}
