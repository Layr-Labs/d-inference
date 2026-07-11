use std::collections::{BTreeMap, BTreeSet};

use darkbloom_coordinator_core::{
    fleet::{FleetSnapshot as CoreFleetSnapshot, ProviderSnapshot},
    ids::{FleetRevision, LeaseId, ModelId, ProviderId},
};

use super::message::{PermitLease, WriterHeadroom};

/// Public runtime view of one provider.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ProviderRuntimeSnapshot {
    provider: ProviderSnapshot,
    heartbeat_sequence: u64,
    writer_headroom: WriterHeadroom,
    effective_writer_items: usize,
    effective_writer_bytes: usize,
    active_leases: usize,
}

impl ProviderRuntimeSnapshot {
    pub(crate) const fn new(
        provider: ProviderSnapshot,
        heartbeat_sequence: u64,
        writer_headroom: WriterHeadroom,
        effective_writer_items: usize,
        effective_writer_bytes: usize,
        active_leases: usize,
    ) -> Self {
        Self {
            provider,
            heartbeat_sequence,
            writer_headroom,
            effective_writer_items,
            effective_writer_bytes,
            active_leases,
        }
    }

    /// Returns the pure-core provider snapshot.
    #[must_use]
    pub const fn provider(&self) -> &ProviderSnapshot {
        &self.provider
    }

    /// Returns the latest applied provider heartbeat sequence.
    #[must_use]
    pub const fn heartbeat_sequence(&self) -> u64 {
        self.heartbeat_sequence
    }

    /// Returns the latest absolute writer report.
    #[must_use]
    pub const fn writer_headroom(&self) -> WriterHeadroom {
        self.writer_headroom
    }

    /// Returns writer item headroom after actor reservations.
    #[must_use]
    pub const fn effective_writer_items(&self) -> usize {
        self.effective_writer_items
    }

    /// Returns writer byte headroom after actor reservations.
    #[must_use]
    pub const fn effective_writer_bytes(&self) -> usize {
        self.effective_writer_bytes
    }

    /// Returns active permit leases assigned to this provider.
    #[must_use]
    pub const fn active_leases(&self) -> usize {
        self.active_leases
    }
}

/// Monotonic actor counters useful for readiness and boundedness assertions.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct FleetActorStats {
    /// Heartbeats applied to canonical state.
    pub heartbeats_applied: u64,
    /// Heartbeats rejected after a newer sequence or fence was observed.
    pub heartbeats_stale: u64,
    /// Heartbeats rejected because limits contradicted active reservations.
    pub heartbeats_rejected: u64,
    /// Permits successfully acquired.
    pub permits_acquired: u64,
    /// Permits explicitly released.
    pub permits_released: u64,
    /// Permits reclaimed at their TTL.
    pub permits_expired: u64,
}

/// Immutable latest-value fleet view published by the actor.
#[derive(Clone, Debug)]
pub struct FleetSnapshot {
    core: CoreFleetSnapshot,
    providers: BTreeMap<ProviderId, ProviderRuntimeSnapshot>,
    eligible_by_model: BTreeMap<ModelId, BTreeSet<ProviderId>>,
    leases: BTreeMap<LeaseId, PermitLease>,
    stats: FleetActorStats,
}

impl FleetSnapshot {
    pub(crate) const fn new(
        core: CoreFleetSnapshot,
        providers: BTreeMap<ProviderId, ProviderRuntimeSnapshot>,
        eligible_by_model: BTreeMap<ModelId, BTreeSet<ProviderId>>,
        leases: BTreeMap<LeaseId, PermitLease>,
        stats: FleetActorStats,
    ) -> Self {
        Self {
            core,
            providers,
            eligible_by_model,
            leases,
            stats,
        }
    }

    /// Returns the canonical global fleet revision.
    #[must_use]
    pub const fn revision(&self) -> FleetRevision {
        self.core.revision()
    }

    /// Returns the underlying pure-core snapshot.
    #[must_use]
    pub const fn core(&self) -> &CoreFleetSnapshot {
        &self.core
    }

    /// Returns one provider runtime view.
    #[must_use]
    pub fn provider(&self, provider_id: ProviderId) -> Option<&ProviderRuntimeSnapshot> {
        self.providers.get(&provider_id)
    }

    /// Iterates providers in stable identity order.
    pub fn providers(&self) -> impl Iterator<Item = &ProviderRuntimeSnapshot> {
        self.providers.values()
    }

    /// Returns the number of registered providers.
    #[must_use]
    pub fn provider_count(&self) -> usize {
        self.providers.len()
    }

    /// Iterates providers eligible for a loaded model in stable order.
    pub fn eligible_providers(&self, model_id: &ModelId) -> impl Iterator<Item = ProviderId> + '_ {
        self.eligible_by_model
            .get(model_id)
            .into_iter()
            .flat_map(|providers| providers.iter().copied())
    }

    /// Returns an active permit lease.
    #[must_use]
    pub fn lease(&self, lease_id: LeaseId) -> Option<&PermitLease> {
        self.leases.get(&lease_id)
    }

    /// Iterates active permit leases in stable identity order.
    pub fn leases(&self) -> impl Iterator<Item = &PermitLease> {
        self.leases.values()
    }

    /// Returns the active permit count.
    #[must_use]
    pub fn active_lease_count(&self) -> usize {
        self.leases.len()
    }

    /// Returns monotonic actor counters.
    #[must_use]
    pub const fn stats(&self) -> FleetActorStats {
        self.stats
    }
}
