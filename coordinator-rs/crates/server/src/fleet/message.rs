use std::time::Duration;

use darkbloom_coordinator_core::{
    fleet::{
        AdmissionDemand, AdmissionError, AdmissionKind, CapacityError, CapacitySnapshot,
        FleetStateError, HealthState, ProviderSnapshot,
    },
    ids::{FleetRevision, LeaseId, ModelId, PermitId, ProviderId},
    request::ProviderFence,
    tokens::{KvBytes, TokenCount},
    traits::RequestTraits,
};
use thiserror::Error;
use tokio::time::Instant;

/// Capacity limits reported by a provider heartbeat.
///
/// In-use counters are deliberately absent. The actor is authoritative for
/// those counters while permits are leased.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct ProviderCapacity {
    token_capacity: TokenCount,
    kv_capacity: KvBytes,
    concurrency_limit: u32,
}

impl ProviderCapacity {
    /// Creates validated capacity limits.
    pub fn new(
        token_capacity: TokenCount,
        kv_capacity: KvBytes,
        concurrency_limit: u32,
    ) -> Result<Self, CapacityError> {
        CapacitySnapshot::new(
            token_capacity,
            TokenCount::ZERO,
            kv_capacity,
            KvBytes::ZERO,
            concurrency_limit,
            0,
        )?;
        Ok(Self {
            token_capacity,
            kv_capacity,
            concurrency_limit,
        })
    }

    /// Returns the total token budget.
    #[must_use]
    pub const fn token_capacity(self) -> TokenCount {
        self.token_capacity
    }

    /// Returns the total KV-cache budget.
    #[must_use]
    pub const fn kv_capacity(self) -> KvBytes {
        self.kv_capacity
    }

    /// Returns the maximum concurrent request count.
    #[must_use]
    pub const fn concurrency_limit(self) -> u32 {
        self.concurrency_limit
    }
}

/// Latest absolute headroom measurement from one provider writer.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct WriterHeadroom {
    revision: u64,
    available_items: usize,
    available_bytes: usize,
}

impl WriterHeadroom {
    /// Creates a headroom report with a nonzero monotonic revision.
    pub const fn new(
        revision: u64,
        available_items: usize,
        available_bytes: usize,
    ) -> Result<Self, WriterHeadroomError> {
        if revision == 0 {
            return Err(WriterHeadroomError::ZeroRevision);
        }
        Ok(Self {
            revision,
            available_items,
            available_bytes,
        })
    }

    /// Returns the writer report revision.
    #[must_use]
    pub const fn revision(self) -> u64 {
        self.revision
    }

    /// Returns free writer queue items before actor reservations.
    #[must_use]
    pub const fn available_items(self) -> usize {
        self.available_items
    }

    /// Returns free writer queue bytes before actor reservations.
    #[must_use]
    pub const fn available_bytes(self) -> usize {
        self.available_bytes
    }
}

/// Invalid writer headroom report.
#[derive(Clone, Copy, Debug, Eq, Error, PartialEq)]
pub enum WriterHeadroomError {
    /// Writer report revisions begin at one.
    #[error("writer headroom revision must be greater than zero")]
    ZeroRevision,
}

/// Reliable provider registration or canonical lifecycle update.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ProviderLifecycle {
    provider: ProviderSnapshot,
    writer_headroom: WriterHeadroom,
}

impl ProviderLifecycle {
    /// Creates a lifecycle update.
    #[must_use]
    pub const fn new(provider: ProviderSnapshot, writer_headroom: WriterHeadroom) -> Self {
        Self {
            provider,
            writer_headroom,
        }
    }

    /// Returns the pure-core provider value.
    #[must_use]
    pub const fn provider(&self) -> &ProviderSnapshot {
        &self.provider
    }

    /// Returns the writer headroom bundled with this lifecycle update.
    #[must_use]
    pub const fn writer_headroom(&self) -> WriterHeadroom {
        self.writer_headroom
    }

    pub(crate) fn into_parts(self) -> (ProviderSnapshot, WriterHeadroom) {
        (self.provider, self.writer_headroom)
    }
}

/// Coalescible provider heartbeat.
///
/// Revisions that alter session, trust, or model identity belong on the
/// reliable lifecycle lane. A heartbeat is accepted only when its fence still
/// exactly matches the actor's canonical fence.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ProviderHeartbeat {
    sequence: u64,
    fence: ProviderFence,
    capacity: ProviderCapacity,
    health: HealthState,
    writer_headroom: WriterHeadroom,
}

impl ProviderHeartbeat {
    /// Creates a fixed-size heartbeat without request content.
    #[must_use]
    pub const fn new(
        sequence: u64,
        fence: ProviderFence,
        capacity: ProviderCapacity,
        health: HealthState,
        writer_headroom: WriterHeadroom,
    ) -> Self {
        Self {
            sequence,
            fence,
            capacity,
            health,
            writer_headroom,
        }
    }

    /// Returns the stable provider key used for coalescing.
    #[must_use]
    pub const fn provider_id(&self) -> ProviderId {
        self.fence.provider_id
    }

    /// Returns the provider-local monotonic heartbeat sequence.
    #[must_use]
    pub const fn sequence(&self) -> u64 {
        self.sequence
    }

    /// Returns the revision fence observed by the heartbeat.
    #[must_use]
    pub const fn fence(&self) -> &ProviderFence {
        &self.fence
    }

    /// Returns reported capacity limits.
    #[must_use]
    pub const fn capacity(&self) -> ProviderCapacity {
        self.capacity
    }

    /// Returns reported circuit health.
    #[must_use]
    pub const fn health(&self) -> HealthState {
        self.health
    }

    /// Returns reported writer queue headroom.
    #[must_use]
    pub const fn writer_headroom(&self) -> WriterHeadroom {
        self.writer_headroom
    }
}

/// Result of publishing to the keyed heartbeat lane.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum HeartbeatPublishOutcome {
    /// This provider did not already have a pending heartbeat.
    Enqueued,
    /// A newer heartbeat replaced the provider's pending heartbeat.
    Coalesced,
    /// An equal or older pending heartbeat revision was rejected.
    Stale,
}

/// Atomic request for provider capacity and writer queue headroom.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AdmissionRequest {
    provider_id: Option<ProviderId>,
    model_id: ModelId,
    expected_fence: Option<ProviderFence>,
    request_traits: RequestTraits,
    demand: AdmissionDemand,
    kind: AdmissionKind,
    writer_bytes: usize,
    lease_ttl: Duration,
}

impl AdmissionRequest {
    /// Creates an admission request that may select any eligible provider.
    #[must_use]
    pub fn any(
        model_id: ModelId,
        request_traits: RequestTraits,
        demand: AdmissionDemand,
        kind: AdmissionKind,
        writer_bytes: usize,
        lease_ttl: Duration,
    ) -> Self {
        Self {
            provider_id: None,
            model_id,
            expected_fence: None,
            request_traits,
            demand,
            kind,
            writer_bytes,
            lease_ttl,
        }
    }

    /// Restricts admission to one provider.
    #[must_use]
    pub const fn for_provider(mut self, provider_id: ProviderId) -> Self {
        self.provider_id = Some(provider_id);
        self
    }

    /// Requires an exact canonical fence at admission time.
    #[must_use]
    pub fn with_expected_fence(mut self, fence: ProviderFence) -> Self {
        self.provider_id = Some(fence.provider_id);
        self.expected_fence = Some(fence);
        self
    }

    /// Returns the optional requested provider.
    #[must_use]
    pub const fn provider_id(&self) -> Option<ProviderId> {
        self.provider_id
    }

    /// Returns the required loaded model.
    #[must_use]
    pub const fn model_id(&self) -> &ModelId {
        &self.model_id
    }

    /// Returns the optional exact provider fence.
    #[must_use]
    pub const fn expected_fence(&self) -> Option<&ProviderFence> {
        self.expected_fence.as_ref()
    }

    /// Returns compatibility traits.
    #[must_use]
    pub const fn request_traits(&self) -> &RequestTraits {
        &self.request_traits
    }

    /// Returns token and KV demand.
    #[must_use]
    pub const fn demand(&self) -> AdmissionDemand {
        self.demand
    }

    /// Returns regular or probe admission mode.
    #[must_use]
    pub const fn kind(&self) -> AdmissionKind {
        self.kind
    }

    /// Returns the writer byte reservation needed before dispatch.
    #[must_use]
    pub const fn writer_bytes(&self) -> usize {
        self.writer_bytes
    }

    /// Returns the requested permit lease TTL.
    #[must_use]
    pub const fn lease_ttl(&self) -> Duration {
        self.lease_ttl
    }
}

/// Capacity permit owned by one request attempt.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PermitLease {
    lease_id: LeaseId,
    permit_id: PermitId,
    provider: ProviderFence,
    demand: AdmissionDemand,
    writer_bytes: usize,
    expires_at: Instant,
}

impl PermitLease {
    pub(crate) const fn new(
        lease_id: LeaseId,
        permit_id: PermitId,
        provider: ProviderFence,
        demand: AdmissionDemand,
        writer_bytes: usize,
        expires_at: Instant,
    ) -> Self {
        Self {
            lease_id,
            permit_id,
            provider,
            demand,
            writer_bytes,
            expires_at,
        }
    }

    /// Returns the unique lease identity.
    #[must_use]
    pub const fn lease_id(&self) -> LeaseId {
        self.lease_id
    }

    /// Returns the admission/probe permit identity.
    #[must_use]
    pub const fn permit_id(&self) -> PermitId {
        self.permit_id
    }

    /// Returns the exact provider revision fence captured by admission.
    #[must_use]
    pub const fn provider(&self) -> &ProviderFence {
        &self.provider
    }

    /// Returns reserved token and KV capacity.
    #[must_use]
    pub const fn demand(&self) -> AdmissionDemand {
        self.demand
    }

    /// Returns reserved writer bytes.
    #[must_use]
    pub const fn writer_bytes(&self) -> usize {
        self.writer_bytes
    }

    /// Returns the monotonic lease expiry instant.
    #[must_use]
    pub const fn expires_at(&self) -> Instant {
        self.expires_at
    }
}

/// Why a permit was returned to the fleet.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum PermitReleaseReason {
    /// Dispatch failed before the provider writer accepted the request.
    BeforeWriterEnqueue,
    /// The consumer cancelled an active or prepared attempt.
    Cancelled,
    /// The request reached its one terminal disposition.
    Terminal,
    /// A non-terminal attempt lost selection or failed.
    AttemptReleased,
}

/// Result of a reliable permit release.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct PermitRelease {
    /// Released lease.
    pub lease_id: LeaseId,
    /// Reason supplied by the request owner.
    pub reason: PermitReleaseReason,
}

/// Expected command rejection. These errors do not terminate the actor.
#[derive(Clone, Debug, Error, PartialEq)]
pub enum FleetCommandError {
    /// The provider is not currently registered.
    #[error("provider {0} is not registered")]
    ProviderNotFound(ProviderId),
    /// The configured maximum provider count was reached.
    #[error("fleet provider limit of {maximum} reached")]
    ProviderLimit {
        /// Configured provider bound.
        maximum: usize,
    },
    /// The configured maximum active lease count was reached.
    #[error("fleet active lease limit of {maximum} reached")]
    LeaseLimit {
        /// Configured lease bound.
        maximum: usize,
    },
    /// Writer debits awaiting a newer absolute report reached their bound.
    #[error("fleet retained writer reservation limit of {maximum} reached")]
    WriterReservationLimit {
        /// Configured retained writer-debit bound.
        maximum: usize,
    },
    /// A lifecycle replacement would invalidate active permits.
    #[error("provider {provider_id} has active permits during a session or model transition")]
    ProviderBusy {
        /// Busy provider.
        provider_id: ProviderId,
    },
    /// The requested model does not match the canonical loaded model.
    #[error("provider {provider_id} does not serve model {model_id}")]
    ModelMismatch {
        /// Provider selected by the caller.
        provider_id: ProviderId,
        /// Required model.
        model_id: ModelId,
    },
    /// No provider in the model eligibility index can serve the request.
    #[error("no provider is eligible for model {0}")]
    NoEligibleProvider(ModelId),
    /// The caller's provider fence is no longer canonical.
    #[error("provider {0} revision fence is stale")]
    StaleProviderFence(ProviderId),
    /// A permit TTL must be nonzero and no greater than the configured bound.
    #[error("permit TTL must be in the range 1ns..={maximum:?}")]
    InvalidLeaseTtl {
        /// Configured maximum TTL.
        maximum: Duration,
    },
    /// Provider writer item headroom would consume its correctness reserve.
    #[error(
        "provider {provider_id} writer has {available} item slots; admission needs one plus reserve {reserve}"
    )]
    WriterItemHeadroom {
        /// Provider whose writer is full.
        provider_id: ProviderId,
        /// Effective available item slots.
        available: usize,
        /// Correctness item reserve.
        reserve: usize,
    },
    /// Provider writer byte headroom would consume its correctness reserve.
    #[error(
        "provider {provider_id} writer has {available} bytes; admission needs {requested} plus reserve {reserve}"
    )]
    WriterByteHeadroom {
        /// Provider whose writer is full.
        provider_id: ProviderId,
        /// Effective available bytes.
        available: usize,
        /// Admission frame bytes.
        requested: usize,
        /// Correctness byte reserve.
        reserve: usize,
    },
    /// The permit does not exist or has already been released.
    #[error("permit lease {0} is not active")]
    LeaseNotFound(LeaseId),
    /// A probe attempted to reuse an active permit identity.
    #[error("permit {0} is already active")]
    PermitAlreadyActive(PermitId),
    /// The pure-core admission policy rejected the request.
    #[error(transparent)]
    Admission(#[from] AdmissionError),
    /// The pure-core revision reducer rejected a lifecycle update.
    #[error(transparent)]
    FleetState(#[from] FleetStateError),
    /// Capacity limits cannot be reduced below current reservations.
    #[error(transparent)]
    Capacity(#[from] CapacityError),
}

/// Error returned by a fleet handle operation.
#[derive(Clone, Debug, Error, PartialEq)]
pub enum FleetHandleError {
    /// The actor's reliable mailbox is closed.
    #[error("fleet actor is unavailable")]
    ActorUnavailable,
    /// The actor rejected a validly delivered command.
    #[error(transparent)]
    Command(#[from] FleetCommandError),
}

/// Successful lifecycle mutation.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct LifecycleApplied {
    /// New canonical fleet revision.
    pub revision: FleetRevision,
}
