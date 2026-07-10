//! Pure, transactional request reducer.

use serde::{Deserialize, Serialize};
use thiserror::Error;

use crate::{
    deadline::AbsoluteDeadline,
    ids::{AttemptId, Digest, EventId, FundingId, LeaseId, PermitId, ProviderId},
    money::MicroUsd,
    pricing::{PricingError, validate_charge},
    terminal::TerminalDisposition,
};

use super::state::{
    AppliedEvent, AttemptKind, AttemptReleaseReason, AttemptStatus, FundingReservation,
    InvariantError, ProviderFence, RequestContext, RequestState,
};

/// A legal input event for the request aggregate.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum RequestEvent {
    /// Reserves the maximum charge before routing.
    FundsReserved {
        /// Idempotent funding reservation identifier.
        funding_id: FundingId,
        /// Maximum authorized charge.
        amount: MicroUsd,
    },
    /// Confirms the caller is using the aggregate's original deadline.
    DeadlineAsserted {
        /// Deadline the caller believes is authoritative.
        deadline: AbsoluteDeadline,
    },
    /// Atomically acquires one lease and one permit for a provider attempt.
    AttemptPrepared {
        /// Unique attempt identifier.
        attempt_id: AttemptId,
        /// Bounded role of this attempt.
        kind: AttemptKind,
        /// Provider revision fence observed at preparation.
        provider: ProviderFence,
        /// Unique capacity lease.
        lease_id: LeaseId,
        /// Unique admission permit.
        permit_id: PermitId,
    },
    /// Returns a prepared attempt's lease and permit before authorization.
    AttemptReleased {
        /// Attempt whose resources are returned.
        attempt_id: AttemptId,
        /// Why the attempt ended before authorization.
        reason: AttemptReleaseReason,
    },
    /// Selects exactly one prepared attempt and atomically releases all losers.
    StartAuthorized {
        /// Winning attempt.
        attempt_id: AttemptId,
        /// Fresh provider revision fence.
        provider: ProviderFence,
    },
    /// Commits the first content-bearing provider output.
    FirstContent {
        /// Sole authorized attempt.
        attempt_id: AttemptId,
        /// Fresh provider revision fence.
        provider: ProviderFence,
    },
    /// Selects exactly one mutually exclusive accounting disposition.
    Terminated {
        /// Durable terminal outcome.
        disposition: TerminalDisposition,
    },
}

/// Persisted event identity and payload.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct RecordedRequestEvent {
    /// Stable event identifier.
    pub id: EventId,
    /// Digest computed over the canonical event payload.
    pub digest: Digest,
    /// Domain payload.
    pub payload: RequestEvent,
}

/// Whether a reducer call applied a transition or recognized a replay.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ApplyOutcome {
    /// A new event changed the aggregate.
    Applied,
    /// The exact event identity or payload digest was already accepted.
    Duplicate,
}

/// Successful pure reduction result.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Reduction {
    /// New immutable aggregate value.
    pub state: RequestState,
    /// Replay classification.
    pub outcome: ApplyOutcome,
}

/// Applies one event without mutating the input aggregate.
///
/// Invalid transitions are transactional: the caller retains the original
/// state. Exact replays are deterministic no-ops. Reusing an event identifier
/// or digest for a different payload is rejected.
pub fn reduce(
    state: &RequestState,
    event: &RecordedRequestEvent,
    context: &RequestContext,
) -> Result<Reduction, RequestError> {
    state.validate_invariants()?;

    if let Some(previous) = state.events.get(&event.id) {
        if previous.digest == event.digest && previous.payload == event.payload {
            return Ok(Reduction {
                state: state.clone(),
                outcome: ApplyOutcome::Duplicate,
            });
        }
        return Err(RequestError::EventReplayConflict { event_id: event.id });
    }

    if let Some(canonical_id) = state.digests.get(&event.digest) {
        let canonical = state
            .events
            .get(canonical_id)
            .ok_or(RequestError::Invariant(InvariantError::ReplayIndexCorrupt))?;
        if canonical.payload != event.payload {
            return Err(RequestError::DigestReplayConflict {
                digest: event.digest,
            });
        }
        let mut next = state.clone();
        next.events.insert(
            event.id,
            AppliedEvent {
                digest: event.digest,
                payload: event.payload.clone(),
            },
        );
        return Ok(Reduction {
            state: next,
            outcome: ApplyOutcome::Duplicate,
        });
    }

    if state.terminal.is_some() {
        return Err(RequestError::EventAfterTerminal);
    }
    if state
        .last_observed_at
        .is_some_and(|previous| context.now() < previous)
    {
        return Err(RequestError::ObservationTimeRegressed);
    }

    let mut next = state.clone();
    apply_new(&mut next, &event.payload, context)?;
    next.last_observed_at = Some(context.now());
    next.validate_invariants()?;
    next.events.insert(
        event.id,
        AppliedEvent {
            digest: event.digest,
            payload: event.payload.clone(),
        },
    );
    next.digests.insert(event.digest, event.id);

    Ok(Reduction {
        state: next,
        outcome: ApplyOutcome::Applied,
    })
}

fn apply_new(
    state: &mut RequestState,
    event: &RequestEvent,
    context: &RequestContext,
) -> Result<(), RequestError> {
    match event {
        RequestEvent::FundsReserved { funding_id, amount } => {
            require_before_deadline(state, context)?;
            if state.funding.is_some() {
                return Err(RequestError::FundingAlreadyReserved);
            }
            state.funding = Some(FundingReservation {
                id: *funding_id,
                amount: *amount,
            });
        }
        RequestEvent::DeadlineAsserted { deadline } => {
            if *deadline != state.deadline {
                return Err(RequestError::DeadlineMismatch {
                    fixed: state.deadline,
                    supplied: *deadline,
                });
            }
        }
        RequestEvent::AttemptPrepared {
            attempt_id,
            kind,
            provider,
            lease_id,
            permit_id,
        } => {
            prepare_attempt(
                state,
                context,
                *attempt_id,
                *kind,
                provider,
                *lease_id,
                *permit_id,
            )?;
        }
        RequestEvent::AttemptReleased { attempt_id, reason } => {
            if *reason == AttemptReleaseReason::Cancelled {
                return Err(RequestError::CancellationRequiresTerminal);
            }
            if state.authorized_attempt.is_some() || state.first_content {
                return Err(RequestError::FailoverAfterAuthorization);
            }
            let attempt = state
                .attempts
                .get(attempt_id)
                .ok_or(RequestError::UnknownAttempt(*attempt_id))?;
            if attempt.status() != AttemptStatus::Prepared {
                return Err(RequestError::AttemptNotPrepared(*attempt_id));
            }
            state.release_attempt(*attempt_id, AttemptStatus::Released { reason: *reason })?;
        }
        RequestEvent::StartAuthorized {
            attempt_id,
            provider,
        } => {
            authorize_start(state, context, *attempt_id, provider)?;
        }
        RequestEvent::FirstContent {
            attempt_id,
            provider,
        } => {
            record_first_content(state, context, *attempt_id, provider)?;
        }
        RequestEvent::Terminated { disposition } => {
            terminate(state, *disposition)?;
        }
    }
    Ok(())
}

fn prepare_attempt(
    state: &mut RequestState,
    context: &RequestContext,
    attempt_id: AttemptId,
    kind: AttemptKind,
    provider: &ProviderFence,
    lease_id: LeaseId,
    permit_id: PermitId,
) -> Result<(), RequestError> {
    require_before_deadline(state, context)?;
    require_funded(state)?;
    if state.authorized_attempt.is_some() || state.first_content {
        return Err(RequestError::FailoverAfterAuthorization);
    }
    if state.attempts.contains_key(&attempt_id) {
        return Err(RequestError::AttemptAlreadyExists(attempt_id));
    }
    if state.used_leases.contains(&lease_id) {
        return Err(RequestError::LeaseAlreadyUsed(lease_id));
    }
    if state.used_permits.contains(&permit_id) {
        return Err(RequestError::PermitAlreadyUsed(permit_id));
    }
    validate_fence(context, provider)?;

    match kind {
        AttemptKind::Primary => {
            if state.primary.is_some() || !state.attempts.is_empty() {
                return Err(RequestError::PrimaryAlreadyPrepared);
            }
            state.primary = Some(attempt_id);
        }
        AttemptKind::Alternate => {
            if state.alternate.is_some() {
                return Err(RequestError::AlternateAlreadyPrepared);
            }
            let primary_id = state.primary.ok_or(RequestError::AlternateBeforePrimary)?;
            let primary = state
                .attempts
                .get(&primary_id)
                .ok_or(RequestError::AlternateBeforePrimary)?;
            if !matches!(primary.status(), AttemptStatus::Released { .. }) {
                return Err(RequestError::AlternateBeforePrimaryReleased);
            }
            state.alternate = Some(attempt_id);
        }
        AttemptKind::Hedge => {
            if state.hedge.is_some() {
                return Err(RequestError::HedgeAlreadyPrepared);
            }
            let has_prepared_base = state.attempts.values().any(|attempt| {
                attempt.kind() != AttemptKind::Hedge && attempt.status() == AttemptStatus::Prepared
            });
            if !has_prepared_base {
                return Err(RequestError::HedgeWithoutPreparedBase);
            }
            state.hedge = Some(attempt_id);
        }
    }

    state.insert_attempt(attempt_id, kind, provider.clone(), lease_id, permit_id)?;
    Ok(())
}

fn authorize_start(
    state: &mut RequestState,
    context: &RequestContext,
    attempt_id: AttemptId,
    provider: &ProviderFence,
) -> Result<(), RequestError> {
    require_before_deadline(state, context)?;
    require_funded(state)?;
    if state.authorized_attempt.is_some() {
        return Err(RequestError::StartAlreadyAuthorized);
    }
    validate_fence(context, provider)?;
    let selected = state
        .attempts
        .get(&attempt_id)
        .ok_or(RequestError::UnknownAttempt(attempt_id))?;
    if selected.status() != AttemptStatus::Prepared {
        return Err(RequestError::AttemptNotPrepared(attempt_id));
    }
    if selected.provider() != provider {
        return Err(RequestError::StaleProviderFence {
            provider_id: provider.provider_id,
        });
    }

    let losers: Vec<_> = state
        .attempts
        .iter()
        .filter_map(|(id, attempt)| {
            (*id != attempt_id && attempt.status() == AttemptStatus::Prepared).then_some(*id)
        })
        .collect();
    for loser in losers {
        state.release_attempt(
            loser,
            AttemptStatus::Released {
                reason: AttemptReleaseReason::NotSelected,
            },
        )?;
    }
    state.authorize_attempt(attempt_id)?;
    state.authorized_attempt = Some(attempt_id);
    Ok(())
}

fn record_first_content(
    state: &mut RequestState,
    context: &RequestContext,
    attempt_id: AttemptId,
    provider: &ProviderFence,
) -> Result<(), RequestError> {
    if state.first_content {
        return Err(RequestError::FirstContentAlreadyRecorded);
    }
    if state.authorized_attempt != Some(attempt_id) {
        return Err(RequestError::ContentFromUnauthorizedAttempt);
    }
    validate_fence(context, provider)?;
    let attempt = state
        .attempts
        .get(&attempt_id)
        .ok_or(RequestError::UnknownAttempt(attempt_id))?;
    if attempt.status() != AttemptStatus::Authorized || attempt.provider() != provider {
        return Err(RequestError::StaleProviderFence {
            provider_id: provider.provider_id,
        });
    }
    state.first_content = true;
    Ok(())
}

fn terminate(
    state: &mut RequestState,
    disposition: TerminalDisposition,
) -> Result<(), RequestError> {
    let funding = state.funding.ok_or(RequestError::FundingRequired)?;
    if let TerminalDisposition::Settled { charged } = disposition {
        if state.authorized_attempt.is_none() {
            return Err(RequestError::SettlementBeforeAuthorization);
        }
        validate_charge(funding.amount, charged)?;
    }

    let held: Vec<_> = state
        .attempts
        .iter()
        .filter_map(|(id, attempt)| attempt.status().holds_resources().then_some(*id))
        .collect();
    for attempt_id in held {
        let status = if state.authorized_attempt == Some(attempt_id) {
            AttemptStatus::Completed
        } else {
            AttemptStatus::Released {
                reason: AttemptReleaseReason::Cancelled,
            }
        };
        state.release_attempt(attempt_id, status)?;
    }
    state.terminal = Some(disposition);
    Ok(())
}

fn require_funded(state: &RequestState) -> Result<(), RequestError> {
    if state.funding.is_none() {
        Err(RequestError::FundingRequired)
    } else {
        Ok(())
    }
}

fn require_before_deadline(
    state: &RequestState,
    context: &RequestContext,
) -> Result<(), RequestError> {
    if state.deadline.is_expired_at(context.now()) {
        Err(RequestError::DeadlineExpired)
    } else {
        Ok(())
    }
}

fn validate_fence(context: &RequestContext, supplied: &ProviderFence) -> Result<(), RequestError> {
    let current = context
        .provider(supplied.provider_id)
        .ok_or(RequestError::ProviderNotPresent(supplied.provider_id))?;
    if current != supplied {
        Err(RequestError::StaleProviderFence {
            provider_id: supplied.provider_id,
        })
    } else {
        Ok(())
    }
}

/// Rejected request trace or arithmetic failure.
#[derive(Clone, Debug, Eq, Error, PartialEq)]
pub enum RequestError {
    /// The same event identifier was paired with different content.
    #[error("event {event_id} replayed with a conflicting digest or payload")]
    EventReplayConflict {
        /// Conflicting event identifier.
        event_id: EventId,
    },
    /// The same digest was paired with a different payload.
    #[error("event digest replayed with conflicting payload: {digest:?}")]
    DigestReplayConflict {
        /// Conflicting payload digest.
        digest: Digest,
    },
    /// No new events are legal after terminal disposition.
    #[error("request already has a terminal disposition")]
    EventAfterTerminal,
    /// Event observation time moved backwards.
    #[error("request observation time regressed")]
    ObservationTimeRegressed,
    /// A second funding reservation was attempted.
    #[error("request funding is already reserved")]
    FundingAlreadyReserved,
    /// Provider work requires funding first.
    #[error("request funding must be reserved first")]
    FundingRequired,
    /// A caller attempted to replace the immutable deadline.
    #[error("deadline is fixed at {fixed:?}, not {supplied:?}")]
    DeadlineMismatch {
        /// Aggregate's original deadline.
        fixed: AbsoluteDeadline,
        /// Rejected deadline.
        supplied: AbsoluteDeadline,
    },
    /// New work cannot begin at or after the deadline.
    #[error("absolute request deadline has expired")]
    DeadlineExpired,
    /// Attempt identifiers are unique within a request.
    #[error("attempt {0} already exists")]
    AttemptAlreadyExists(AttemptId),
    /// The trace references an unknown attempt.
    #[error("unknown attempt {0}")]
    UnknownAttempt(AttemptId),
    /// The attempt is no longer in the prepared state.
    #[error("attempt {0} is not prepared")]
    AttemptNotPrepared(AttemptId),
    /// At most one primary attempt exists.
    #[error("primary attempt is already prepared")]
    PrimaryAlreadyPrepared,
    /// An alternate requires a primary.
    #[error("alternate attempt cannot precede the primary")]
    AlternateBeforePrimary,
    /// An alternate is legal only after primary pre-authorization failure.
    #[error("alternate attempt requires the primary to be released")]
    AlternateBeforePrimaryReleased,
    /// At most one alternate exists.
    #[error("alternate attempt is already prepared")]
    AlternateAlreadyPrepared,
    /// A hedge requires a concurrently prepared non-hedge attempt.
    #[error("hedge requires a prepared primary or alternate")]
    HedgeWithoutPreparedBase,
    /// At most one hedge exists.
    #[error("hedge attempt is already prepared")]
    HedgeAlreadyPrepared,
    /// A lease identifier cannot be acquired twice.
    #[error("lease {0} was already used")]
    LeaseAlreadyUsed(LeaseId),
    /// A permit identifier cannot be acquired twice.
    #[error("permit {0} was already used")]
    PermitAlreadyUsed(PermitId),
    /// Provider is absent from the authoritative context.
    #[error("provider {0} is absent from the current snapshot")]
    ProviderNotPresent(ProviderId),
    /// Session, trust, model, or model revision no longer matches.
    #[error("provider {provider_id} revision fence is stale")]
    StaleProviderFence {
        /// Provider with a stale fence.
        provider_id: ProviderId,
    },
    /// Failover and resource release are forbidden after authorization.
    #[error("failover is forbidden after start authorization or first content")]
    FailoverAfterAuthorization,
    /// Cancellation must atomically terminate and release every attempt.
    #[error("cancellation requires a terminal Released disposition")]
    CancellationRequiresTerminal,
    /// Exactly one start authorization is allowed.
    #[error("start was already authorized")]
    StartAlreadyAuthorized,
    /// Content came from an attempt that was not authorized.
    #[error("first content came from an unauthorized attempt")]
    ContentFromUnauthorizedAttempt,
    /// First content is a one-time transition.
    #[error("first content was already recorded")]
    FirstContentAlreadyRecorded,
    /// Settlement requires one authorized attempt.
    #[error("settlement requires start authorization")]
    SettlementBeforeAuthorization,
    /// Checked charge validation failed.
    #[error(transparent)]
    Pricing(#[from] PricingError),
    /// A reducer implementation invariant failed.
    #[error(transparent)]
    Invariant(#[from] InvariantError),
}
