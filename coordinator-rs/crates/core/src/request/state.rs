//! Request aggregate state and invariant inspection.

use std::collections::{BTreeMap, BTreeSet};

use serde::{Deserialize, Serialize};
use thiserror::Error;

use crate::{
    deadline::{AbsoluteDeadline, EpochMillis},
    ids::{
        AttemptId, Digest, EventId, FundingId, LeaseId, ModelId, ModelRevision, PermitId,
        ProviderId, RequestId, SessionId, SessionRevision, TrustRevision,
    },
    money::MicroUsd,
    terminal::TerminalDisposition,
};

use super::reducer::RequestEvent;

/// Session, trust, and loaded-model revisions used to fence provider actions.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct ProviderFence {
    /// Stable provider identity.
    pub provider_id: ProviderId,
    /// Current process session identity.
    pub session_id: SessionId,
    /// Monotonic session revision.
    pub session_revision: SessionRevision,
    /// Monotonic trust decision revision.
    pub trust_revision: TrustRevision,
    /// Loaded model identity.
    pub model_id: ModelId,
    /// Monotonic loaded-model revision.
    pub model_revision: ModelRevision,
}

/// Immutable reducer inputs that are intentionally not persisted in an event.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RequestContext {
    now: EpochMillis,
    providers: BTreeMap<ProviderId, ProviderFence>,
}

impl RequestContext {
    /// Creates an empty provider view at a specific wall-clock observation.
    #[must_use]
    pub fn new(now: EpochMillis) -> Self {
        Self {
            now,
            providers: BTreeMap::new(),
        }
    }

    /// Inserts the authoritative fence for a provider.
    #[must_use]
    pub fn with_provider(mut self, fence: ProviderFence) -> Self {
        self.providers.insert(fence.provider_id, fence);
        self
    }

    /// Returns the observation time.
    #[must_use]
    pub const fn now(&self) -> EpochMillis {
        self.now
    }

    pub(crate) fn provider(&self, provider_id: ProviderId) -> Option<&ProviderFence> {
        self.providers.get(&provider_id)
    }
}

/// The bounded role of an attempt in one request.
#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AttemptKind {
    /// The first selected provider.
    Primary,
    /// One sequential failover after the primary is released.
    Alternate,
    /// One concurrently prepared speculative attempt.
    Hedge,
}

/// Why a prepared attempt released its lease and permit.
#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AttemptReleaseReason {
    /// The provider failed before start authorization.
    PreAuthorizationFailure,
    /// The authorized provider failed before any output was committed.
    PreContentFailure,
    /// Another prepared attempt won authorization.
    NotSelected,
    /// The request was cancelled before authorization.
    Cancelled,
}

/// Lifecycle of a bounded routing attempt.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum AttemptStatus {
    /// Lease and permit are held while start is not yet authorized.
    Prepared,
    /// Lease and permit were released before authorization.
    Released {
        /// Why resources were returned.
        reason: AttemptReleaseReason,
    },
    /// This is the sole start-authorized attempt and its resources are held.
    Authorized,
    /// The request terminated and this attempt's resources were returned.
    Completed,
}

impl AttemptStatus {
    pub(crate) const fn holds_resources(self) -> bool {
        matches!(self, Self::Prepared | Self::Authorized)
    }
}

/// One provider attempt and its capacity resources.
#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct Attempt {
    id: AttemptId,
    kind: AttemptKind,
    provider: ProviderFence,
    lease_id: LeaseId,
    permit_id: PermitId,
    status: AttemptStatus,
}

impl Attempt {
    /// Returns the attempt identifier.
    #[must_use]
    pub const fn id(&self) -> AttemptId {
        self.id
    }

    /// Returns the attempt role.
    #[must_use]
    pub const fn kind(&self) -> AttemptKind {
        self.kind
    }

    /// Returns the provider revision fence captured at preparation.
    #[must_use]
    pub const fn provider(&self) -> &ProviderFence {
        &self.provider
    }

    /// Returns the lease identifier.
    #[must_use]
    pub const fn lease_id(&self) -> LeaseId {
        self.lease_id
    }

    /// Returns the permit identifier.
    #[must_use]
    pub const fn permit_id(&self) -> PermitId {
        self.permit_id
    }

    /// Returns the current attempt status.
    #[must_use]
    pub const fn status(&self) -> AttemptStatus {
        self.status
    }
}

/// Funding reserved before any provider capacity is acquired.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct FundingReservation {
    /// Idempotent funding operation identifier.
    pub id: FundingId,
    /// Maximum authorized charge.
    pub amount: MicroUsd,
}

/// Conservation counters for request-scoped capacity resources.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq, Serialize)]
pub struct ResourceAccounting {
    acquired_leases: u64,
    released_leases: u64,
    acquired_permits: u64,
    released_permits: u64,
}

impl ResourceAccounting {
    /// Number of leases ever acquired.
    #[must_use]
    pub const fn acquired_leases(self) -> u64 {
        self.acquired_leases
    }

    /// Number of leases returned.
    #[must_use]
    pub const fn released_leases(self) -> u64 {
        self.released_leases
    }

    /// Number of permits ever acquired.
    #[must_use]
    pub const fn acquired_permits(self) -> u64 {
        self.acquired_permits
    }

    /// Number of permits returned.
    #[must_use]
    pub const fn released_permits(self) -> u64 {
        self.released_permits
    }

    /// Number of leases currently held.
    pub fn active_leases(self) -> Result<u64, InvariantError> {
        self.acquired_leases
            .checked_sub(self.released_leases)
            .ok_or(InvariantError::LeaseUnderflow)
    }

    /// Number of permits currently held.
    pub fn active_permits(self) -> Result<u64, InvariantError> {
        self.acquired_permits
            .checked_sub(self.released_permits)
            .ok_or(InvariantError::PermitUnderflow)
    }

    pub(crate) fn acquire_pair(&mut self) -> Result<(), InvariantError> {
        self.acquired_leases = self
            .acquired_leases
            .checked_add(1)
            .ok_or(InvariantError::CounterOverflow)?;
        self.acquired_permits = self
            .acquired_permits
            .checked_add(1)
            .ok_or(InvariantError::CounterOverflow)?;
        Ok(())
    }

    pub(crate) fn release_pair(&mut self) -> Result<(), InvariantError> {
        if self.active_leases()? == 0 {
            return Err(InvariantError::LeaseUnderflow);
        }
        if self.active_permits()? == 0 {
            return Err(InvariantError::PermitUnderflow);
        }
        self.released_leases = self
            .released_leases
            .checked_add(1)
            .ok_or(InvariantError::CounterOverflow)?;
        self.released_permits = self
            .released_permits
            .checked_add(1)
            .ok_or(InvariantError::CounterOverflow)?;
        Ok(())
    }
}

/// Stored replay identity for one accepted event.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub(crate) struct AppliedEvent {
    pub(crate) digest: Digest,
    pub(crate) payload: RequestEvent,
}

/// Complete pure request aggregate.
#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct RequestState {
    pub(crate) request_id: RequestId,
    pub(crate) deadline: AbsoluteDeadline,
    pub(crate) last_observed_at: Option<EpochMillis>,
    pub(crate) funding: Option<FundingReservation>,
    pub(crate) attempts: BTreeMap<AttemptId, Attempt>,
    pub(crate) primary: Option<AttemptId>,
    pub(crate) alternate: Option<AttemptId>,
    pub(crate) hedge: Option<AttemptId>,
    pub(crate) authorized_attempt: Option<AttemptId>,
    pub(crate) first_content: bool,
    pub(crate) terminal: Option<TerminalDisposition>,
    pub(crate) resources: ResourceAccounting,
    pub(crate) used_leases: BTreeSet<LeaseId>,
    pub(crate) used_permits: BTreeSet<PermitId>,
    pub(crate) events: BTreeMap<EventId, AppliedEvent>,
    pub(crate) digests: BTreeMap<Digest, EventId>,
}

impl RequestState {
    /// Creates a request with one immutable absolute deadline.
    #[must_use]
    pub fn new(request_id: RequestId, deadline: AbsoluteDeadline) -> Self {
        Self {
            request_id,
            deadline,
            last_observed_at: None,
            funding: None,
            attempts: BTreeMap::new(),
            primary: None,
            alternate: None,
            hedge: None,
            authorized_attempt: None,
            first_content: false,
            terminal: None,
            resources: ResourceAccounting::default(),
            used_leases: BTreeSet::new(),
            used_permits: BTreeSet::new(),
            events: BTreeMap::new(),
            digests: BTreeMap::new(),
        }
    }

    /// Returns the stable request identifier.
    #[must_use]
    pub const fn request_id(&self) -> RequestId {
        self.request_id
    }

    /// Returns the immutable absolute deadline.
    #[must_use]
    pub const fn deadline(&self) -> AbsoluteDeadline {
        self.deadline
    }

    /// Returns the sole funding reservation, if accepted.
    #[must_use]
    pub const fn funding(&self) -> Option<FundingReservation> {
        self.funding
    }

    /// Returns an attempt by identifier.
    #[must_use]
    pub fn attempt(&self, id: AttemptId) -> Option<&Attempt> {
        self.attempts.get(&id)
    }

    /// Iterates attempts in stable identifier order.
    pub fn attempts(&self) -> impl Iterator<Item = &Attempt> {
        self.attempts.values()
    }

    /// Returns the sole start-authorized attempt.
    #[must_use]
    pub const fn authorized_attempt(&self) -> Option<AttemptId> {
        self.authorized_attempt
    }

    /// Returns whether content has been committed to the consumer.
    #[must_use]
    pub const fn has_first_content(&self) -> bool {
        self.first_content
    }

    /// Returns the one terminal disposition.
    #[must_use]
    pub const fn terminal(&self) -> Option<TerminalDisposition> {
        self.terminal
    }

    /// Returns resource-conservation counters.
    #[must_use]
    pub const fn resources(&self) -> ResourceAccounting {
        self.resources
    }

    /// Returns true after exactly one terminal disposition is accepted.
    #[must_use]
    pub const fn is_terminal(&self) -> bool {
        self.terminal.is_some()
    }

    /// Checks all aggregate invariants without mutating state.
    pub fn validate_invariants(&self) -> Result<(), InvariantError> {
        let held = u64::try_from(
            self.attempts
                .values()
                .filter(|attempt| attempt.status.holds_resources())
                .count(),
        )
        .map_err(|_| InvariantError::CounterOverflow)?;

        let active_leases = self.resources.active_leases()?;
        let active_permits = self.resources.active_permits()?;
        if active_leases != held {
            return Err(InvariantError::LeaseLeak {
                accounting: active_leases,
                held,
            });
        }
        if active_permits != held {
            return Err(InvariantError::PermitLeak {
                accounting: active_permits,
                held,
            });
        }
        if self.resources.acquired_leases != self.resources.acquired_permits
            || self.resources.released_leases != self.resources.released_permits
        {
            return Err(InvariantError::UnpairedResources);
        }
        if self.first_content && self.authorized_attempt.is_none() {
            return Err(InvariantError::ContentWithoutAuthorization);
        }
        if !self.attempts.is_empty() && self.funding.is_none() {
            return Err(InvariantError::AttemptWithoutFunding);
        }
        for (slot, kind) in [
            (self.primary, AttemptKind::Primary),
            (self.alternate, AttemptKind::Alternate),
            (self.hedge, AttemptKind::Hedge),
        ] {
            let matching = self
                .attempts
                .values()
                .filter(|attempt| attempt.kind == kind)
                .count();
            if matching > 1
                || slot.is_some() != (matching == 1)
                || slot.is_some_and(|id| {
                    self.attempts.get(&id).map(|attempt| attempt.kind) != Some(kind)
                })
            {
                return Err(InvariantError::AttemptRoleCardinality);
            }
        }
        let authorized_count = self
            .attempts
            .values()
            .filter(|attempt| {
                matches!(
                    attempt.status,
                    AttemptStatus::Authorized | AttemptStatus::Completed
                )
            })
            .count();
        if authorized_count > 1
            || (self.authorized_attempt.is_some() && authorized_count != 1)
            || (self.authorized_attempt.is_none() && authorized_count != 0)
        {
            return Err(InvariantError::AuthorizationCardinality);
        }
        if self.terminal.is_some() && held != 0 {
            return Err(InvariantError::TerminalResourceLeak);
        }
        if let Some(authorized_id) = self.authorized_attempt {
            let authorized = self
                .attempts
                .get(&authorized_id)
                .ok_or(InvariantError::AuthorizationCardinality)?;
            let expected_status = if self.terminal.is_some() {
                AttemptStatus::Completed
            } else {
                AttemptStatus::Authorized
            };
            if authorized.status != expected_status {
                return Err(InvariantError::AuthorizationCardinality);
            }
        }
        if self.terminal.is_some() && self.funding.is_none() {
            return Err(InvariantError::TerminalWithoutFunding);
        }
        if matches!(self.terminal, Some(TerminalDisposition::Settled { .. }))
            && self.authorized_attempt.is_none()
        {
            return Err(InvariantError::SettlementWithoutAuthorization);
        }
        if self.attempts.len() != self.used_leases.len()
            || self.attempts.len() != self.used_permits.len()
            || self.attempts.values().any(|attempt| {
                !self.used_leases.contains(&attempt.lease_id)
                    || !self.used_permits.contains(&attempt.permit_id)
            })
        {
            return Err(InvariantError::ResourceIdentifierReuse);
        }
        for event in self.events.values() {
            let canonical_id = self
                .digests
                .get(&event.digest)
                .ok_or(InvariantError::ReplayIndexCorrupt)?;
            let canonical = self
                .events
                .get(canonical_id)
                .ok_or(InvariantError::ReplayIndexCorrupt)?;
            if canonical.digest != event.digest || canonical.payload != event.payload {
                return Err(InvariantError::ReplayIndexCorrupt);
            }
        }
        if self
            .digests
            .values()
            .any(|id| !self.events.contains_key(id))
        {
            return Err(InvariantError::ReplayIndexCorrupt);
        }
        Ok(())
    }

    pub(crate) fn insert_attempt(
        &mut self,
        id: AttemptId,
        kind: AttemptKind,
        provider: ProviderFence,
        lease_id: LeaseId,
        permit_id: PermitId,
    ) -> Result<(), InvariantError> {
        self.resources.acquire_pair()?;
        self.used_leases.insert(lease_id);
        self.used_permits.insert(permit_id);
        self.attempts.insert(
            id,
            Attempt {
                id,
                kind,
                provider,
                lease_id,
                permit_id,
                status: AttemptStatus::Prepared,
            },
        );
        Ok(())
    }

    pub(crate) fn release_attempt(
        &mut self,
        id: AttemptId,
        status: AttemptStatus,
    ) -> Result<(), InvariantError> {
        let attempt = self
            .attempts
            .get_mut(&id)
            .ok_or(InvariantError::AuthorizationCardinality)?;
        if attempt.status.holds_resources() {
            self.resources.release_pair()?;
        }
        attempt.status = status;
        Ok(())
    }

    pub(crate) fn authorize_attempt(&mut self, id: AttemptId) -> Result<(), InvariantError> {
        let attempt = self
            .attempts
            .get_mut(&id)
            .ok_or(InvariantError::AuthorizationCardinality)?;
        if attempt.status != AttemptStatus::Prepared {
            return Err(InvariantError::AuthorizationCardinality);
        }
        attempt.status = AttemptStatus::Authorized;
        Ok(())
    }
}

/// Internal consistency failure. A successful reducer transition never
/// produces one of these states.
#[derive(Clone, Copy, Debug, Eq, Error, PartialEq)]
pub enum InvariantError {
    /// More leases were released than acquired.
    #[error("lease accounting underflow")]
    LeaseUnderflow,
    /// More permits were released than acquired.
    #[error("permit accounting underflow")]
    PermitUnderflow,
    /// A conservation counter overflowed.
    #[error("resource accounting counter overflow")]
    CounterOverflow,
    /// Active lease accounting disagrees with held attempts.
    #[error("lease accounting has {accounting} active but {held} attempts hold leases")]
    LeaseLeak {
        /// Accounting balance.
        accounting: u64,
        /// Number of attempts holding resources.
        held: u64,
    },
    /// Active permit accounting disagrees with held attempts.
    #[error("permit accounting has {accounting} active but {held} attempts hold permits")]
    PermitLeak {
        /// Accounting balance.
        accounting: u64,
        /// Number of attempts holding resources.
        held: u64,
    },
    /// Leases and permits were not acquired and returned as pairs.
    #[error("lease and permit accounting is not paired")]
    UnpairedResources,
    /// Content exists without one authorized attempt.
    #[error("first content exists without start authorization")]
    ContentWithoutAuthorization,
    /// Provider capacity exists without prior funding.
    #[error("provider attempt exists without funding")]
    AttemptWithoutFunding,
    /// Primary, alternate, or hedge role cardinality is invalid.
    #[error("attempt role cardinality or role index is invalid")]
    AttemptRoleCardinality,
    /// Start authorization cardinality is not zero or one.
    #[error("start authorization cardinality is invalid")]
    AuthorizationCardinality,
    /// A terminal request still owns provider capacity.
    #[error("terminal request leaked lease or permit")]
    TerminalResourceLeak,
    /// A terminal accounting decision has no funding reservation.
    #[error("terminal request has no funding reservation")]
    TerminalWithoutFunding,
    /// A settlement exists without authorized inference.
    #[error("settlement exists without start authorization")]
    SettlementWithoutAuthorization,
    /// A lease or permit identifier was reused.
    #[error("lease or permit identifier was reused")]
    ResourceIdentifierReuse,
    /// Event-ID and digest replay indexes disagree.
    #[error("event replay indexes are inconsistent")]
    ReplayIndexCorrupt,
}
