use std::{
    collections::{BTreeMap, BTreeSet},
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, Ordering},
    },
    time::Duration,
};

use darkbloom_coordinator_core::{
    fleet::{
        Admission, CapacitySnapshot, FleetEvent, FleetSnapshot as CoreFleetSnapshot, FleetUpdate,
        ProviderSnapshot, reduce_fleet,
    },
    ids::{FleetRevision, LeaseId, ModelId, PermitId, ProviderId, RevisionError, SessionRevision},
};
use thiserror::Error;
use tokio::{
    sync::{OwnedSemaphorePermit, Semaphore, mpsc, oneshot, watch},
    time::{Instant, MissedTickBehavior},
};
use tokio_util::sync::CancellationToken;

use super::{
    message::{
        AdmissionRequest, FleetCommandError, FleetHandleError, HeartbeatPublishOutcome,
        LifecycleApplied, PermitLease, PermitRelease, PermitReleaseReason, ProviderHeartbeat,
        ProviderLifecycle, WriterHeadroom,
    },
    snapshot::{FleetActorStats, FleetSnapshot, ProviderRuntimeSnapshot},
};

/// Bounded mailbox, lease, provider, and writer-reserve policy.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct FleetActorConfig {
    /// Total reliable lifecycle/admission mailbox slots.
    pub reliable_mailbox_capacity: usize,
    /// Reliable slots admissions are forbidden to consume.
    pub reliable_correctness_reserve: usize,
    /// Maximum distinct providers waiting in the heartbeat lane.
    pub heartbeat_capacity: usize,
    /// Maximum providers retained by canonical fleet state.
    pub maximum_providers: usize,
    /// Maximum active permit leases retained by canonical fleet state.
    pub maximum_active_leases: usize,
    /// Maximum writer debits retained until a newer absolute report.
    pub maximum_writer_debits: usize,
    /// Maximum caller-selected permit TTL.
    pub maximum_lease_ttl: Duration,
    /// Frequency at which expired permit leases are reclaimed.
    pub lease_reap_interval: Duration,
    /// Provider writer item slots admissions are forbidden to consume.
    pub writer_correctness_item_reserve: usize,
    /// Provider writer bytes admissions are forbidden to consume.
    pub writer_correctness_byte_reserve: usize,
}

impl Default for FleetActorConfig {
    fn default() -> Self {
        Self {
            reliable_mailbox_capacity: 1_024,
            reliable_correctness_reserve: 64,
            heartbeat_capacity: 1_024,
            maximum_providers: 1_024,
            maximum_active_leases: 16_384,
            maximum_writer_debits: 16_384,
            maximum_lease_ttl: Duration::from_secs(5 * 60),
            lease_reap_interval: Duration::from_secs(1),
            writer_correctness_item_reserve: 8,
            writer_correctness_byte_reserve: 64 * 1_024,
        }
    }
}

impl FleetActorConfig {
    fn validate(self) -> Result<Self, FleetConfigError> {
        if self.reliable_mailbox_capacity == 0 {
            return Err(FleetConfigError::ZeroReliableCapacity);
        }
        if self.reliable_correctness_reserve == 0
            || self.reliable_correctness_reserve >= self.reliable_mailbox_capacity
        {
            return Err(FleetConfigError::InvalidReliableReserve);
        }
        if self.heartbeat_capacity == 0 {
            return Err(FleetConfigError::ZeroHeartbeatCapacity);
        }
        if self.maximum_providers == 0 {
            return Err(FleetConfigError::ZeroProviderLimit);
        }
        if self.maximum_active_leases == 0 {
            return Err(FleetConfigError::ZeroLeaseLimit);
        }
        if self.maximum_writer_debits == 0 {
            return Err(FleetConfigError::ZeroWriterDebitLimit);
        }
        if self.maximum_lease_ttl.is_zero() {
            return Err(FleetConfigError::ZeroMaximumLeaseTtl);
        }
        if self.lease_reap_interval.is_zero() {
            return Err(FleetConfigError::ZeroLeaseReapInterval);
        }
        if self.writer_correctness_item_reserve == 0 {
            return Err(FleetConfigError::ZeroWriterItemReserve);
        }
        if self.writer_correctness_byte_reserve == 0 {
            return Err(FleetConfigError::ZeroWriterByteReserve);
        }
        Ok(self)
    }
}

/// Invalid fleet actor bounds.
#[derive(Clone, Copy, Debug, Eq, Error, PartialEq)]
pub enum FleetConfigError {
    /// A Tokio bounded channel requires at least one slot.
    #[error("reliable mailbox capacity must be greater than zero")]
    ZeroReliableCapacity,
    /// At least one slot must remain for admissions and correctness traffic.
    #[error("reliable correctness reserve must be in 1..reliable mailbox capacity")]
    InvalidReliableReserve,
    /// The keyed heartbeat map must retain at least one provider.
    #[error("heartbeat capacity must be greater than zero")]
    ZeroHeartbeatCapacity,
    /// Canonical provider state must have a finite positive bound.
    #[error("maximum providers must be greater than zero")]
    ZeroProviderLimit,
    /// Permit state must have a finite positive bound.
    #[error("maximum active leases must be greater than zero")]
    ZeroLeaseLimit,
    /// Retained writer reservations must have a finite positive bound.
    #[error("maximum writer debits must be greater than zero")]
    ZeroWriterDebitLimit,
    /// Permit leases must expire.
    #[error("maximum permit lease TTL must be greater than zero")]
    ZeroMaximumLeaseTtl,
    /// Expiry collection must make progress.
    #[error("permit lease reap interval must be greater than zero")]
    ZeroLeaseReapInterval,
    /// At least one writer item must remain for correctness messages.
    #[error("writer correctness item reserve must be greater than zero")]
    ZeroWriterItemReserve,
    /// Writer byte admission must preserve bounded correctness traffic.
    #[error("writer correctness byte reserve must be greater than zero")]
    ZeroWriterByteReserve,
}

/// Coalescing heartbeat publication failure.
#[derive(Clone, Copy, Debug, Eq, Error, PartialEq)]
pub enum HeartbeatPublishError {
    /// Every keyed slot is occupied by another provider.
    #[error("heartbeat lane is full at {capacity} providers")]
    Full {
        /// Configured keyed bound.
        capacity: usize,
    },
    /// The fleet actor has terminated.
    #[error("fleet actor is unavailable")]
    ActorUnavailable,
}

/// Fatal actor failure. Returning one from `run` must terminate supervision.
#[derive(Debug, Error)]
pub enum FleetActorError {
    /// Every reliable handle disappeared without coordinated cancellation.
    #[error("fleet reliable mailbox closed before shutdown")]
    ReliableMailboxClosed,
    /// Global immutable revision space was exhausted.
    #[error(transparent)]
    Revision(#[from] RevisionError),
    /// An actor-generated pure-core transition violated a fleet invariant.
    #[error("actor-generated fleet transition failed: {0}")]
    InternalFleetState(#[source] darkbloom_coordinator_core::fleet::FleetStateError),
    /// Actor-owned capacity accounting violated a pure-core invariant.
    #[error("actor capacity accounting failed: {0}")]
    InternalCapacity(#[source] darkbloom_coordinator_core::fleet::CapacityError),
    /// Actor-owned resource accounting attempted an impossible transition.
    #[error("fleet actor invariant failed: {0}")]
    Invariant(&'static str),
}

#[derive(Clone, Copy, Debug)]
struct WriterDebit {
    bytes: usize,
    report_revision: u64,
    enqueued: bool,
}

#[derive(Clone, Debug)]
struct ProviderRuntime {
    provider: ProviderSnapshot,
    heartbeat_sequence: u64,
    writer_headroom: WriterHeadroom,
    writer_debits: BTreeMap<LeaseId, WriterDebit>,
}

impl ProviderRuntime {
    fn effective_writer_headroom(&self) -> (usize, usize) {
        let (items, bytes) = self
            .writer_debits
            .values()
            .fold((0_usize, 0_usize), |(items, bytes), debit| {
                (items.saturating_add(1), bytes.saturating_add(debit.bytes))
            });
        (
            self.writer_headroom.available_items().saturating_sub(items),
            self.writer_headroom.available_bytes().saturating_sub(bytes),
        )
    }

    fn apply_writer_report(&mut self, report: WriterHeadroom) {
        if report.revision() <= self.writer_headroom.revision() {
            return;
        }
        self.writer_debits
            .retain(|_, debit| !debit.enqueued || debit.report_revision >= report.revision());
        self.writer_headroom = report;
    }
}

#[derive(Clone, Debug)]
struct LeaseRecord {
    lease: PermitLease,
}

struct HeartbeatState {
    pending: BTreeMap<ProviderId, ProviderHeartbeat>,
}

struct HeartbeatInbox {
    capacity: usize,
    state: Mutex<HeartbeatState>,
    notify: tokio::sync::Notify,
    closed: AtomicBool,
}

impl HeartbeatInbox {
    fn new(capacity: usize) -> Self {
        Self {
            capacity,
            state: Mutex::new(HeartbeatState {
                pending: BTreeMap::new(),
            }),
            notify: tokio::sync::Notify::new(),
            closed: AtomicBool::new(false),
        }
    }

    fn publish(
        &self,
        heartbeat: ProviderHeartbeat,
    ) -> Result<HeartbeatPublishOutcome, HeartbeatPublishError> {
        if self.closed.load(Ordering::Acquire) {
            return Err(HeartbeatPublishError::ActorUnavailable);
        }
        let provider_id = heartbeat.provider_id();
        let mut state = self
            .state
            .lock()
            .unwrap_or_else(|poison| poison.into_inner());
        let outcome = if let Some(pending) = state.pending.get_mut(&provider_id) {
            if heartbeat.sequence() <= pending.sequence() {
                HeartbeatPublishOutcome::Stale
            } else {
                *pending = heartbeat;
                HeartbeatPublishOutcome::Coalesced
            }
        } else {
            if state.pending.len() >= self.capacity {
                return Err(HeartbeatPublishError::Full {
                    capacity: self.capacity,
                });
            }
            state.pending.insert(provider_id, heartbeat);
            HeartbeatPublishOutcome::Enqueued
        };
        drop(state);
        if outcome != HeartbeatPublishOutcome::Stale {
            self.notify.notify_one();
        }
        Ok(outcome)
    }

    fn pop(&self) -> Option<ProviderHeartbeat> {
        let mut state = self
            .state
            .lock()
            .unwrap_or_else(|poison| poison.into_inner());
        let provider_id = state.pending.keys().next().copied()?;
        state.pending.remove(&provider_id)
    }

    async fn recv(&self) -> ProviderHeartbeat {
        loop {
            if let Some(heartbeat) = self.pop() {
                return heartbeat;
            }
            let notified = self.notify.notified();
            if let Some(heartbeat) = self.pop() {
                return heartbeat;
            }
            notified.await;
        }
    }

    fn pending_len(&self) -> usize {
        self.state
            .lock()
            .unwrap_or_else(|poison| poison.into_inner())
            .pending
            .len()
    }

    fn close(&self) {
        self.closed.store(true, Ordering::Release);
        self.notify.notify_waiters();
    }
}

enum ReliableMessage {
    Lifecycle {
        update: ProviderLifecycle,
        response: oneshot::Sender<Result<LifecycleApplied, FleetCommandError>>,
    },
    RemoveProvider {
        provider_id: ProviderId,
        expected_session_revision: SessionRevision,
        response: oneshot::Sender<Result<LifecycleApplied, FleetCommandError>>,
    },
    Admit {
        request: AdmissionRequest,
        response: oneshot::Sender<Result<PermitLease, FleetCommandError>>,
        _admission_slot: OwnedSemaphorePermit,
    },
    WriterEnqueued {
        lease_id: LeaseId,
        response: oneshot::Sender<Result<(), FleetCommandError>>,
    },
    WriterHeadroom {
        provider_id: ProviderId,
        expected_session_revision: SessionRevision,
        report: WriterHeadroom,
        response: oneshot::Sender<Result<(), FleetCommandError>>,
    },
    RenewPermit {
        lease_id: LeaseId,
        ttl: Duration,
        response: oneshot::Sender<Result<PermitLease, FleetCommandError>>,
    },
    ReleasePermit {
        lease_id: LeaseId,
        reason: PermitReleaseReason,
        response: oneshot::Sender<Result<PermitRelease, FleetCommandError>>,
    },
}

/// Cloneable concrete integration handle for provider and request modules.
#[derive(Clone)]
pub struct FleetHandle {
    reliable_tx: mpsc::Sender<ReliableMessage>,
    heartbeat: Arc<HeartbeatInbox>,
    admission_slots: Arc<Semaphore>,
    snapshot_rx: watch::Receiver<Arc<FleetSnapshot>>,
}

impl FleetHandle {
    /// Reliably inserts or updates canonical provider lifecycle state.
    pub async fn apply_lifecycle(
        &self,
        update: ProviderLifecycle,
    ) -> Result<LifecycleApplied, FleetHandleError> {
        let (response, receive) = oneshot::channel();
        self.reliable_tx
            .send(ReliableMessage::Lifecycle { update, response })
            .await
            .map_err(|_| FleetHandleError::ActorUnavailable)?;
        receive
            .await
            .map_err(|_| FleetHandleError::ActorUnavailable)?
            .map_err(Into::into)
    }

    /// Reliably removes exactly one provider session.
    pub async fn remove_provider(
        &self,
        provider_id: ProviderId,
        expected_session_revision: SessionRevision,
    ) -> Result<LifecycleApplied, FleetHandleError> {
        let (response, receive) = oneshot::channel();
        self.reliable_tx
            .send(ReliableMessage::RemoveProvider {
                provider_id,
                expected_session_revision,
                response,
            })
            .await
            .map_err(|_| FleetHandleError::ActorUnavailable)?;
        receive
            .await
            .map_err(|_| FleetHandleError::ActorUnavailable)?
            .map_err(Into::into)
    }

    /// Publishes a latest-value heartbeat without waiting on actor work.
    pub fn publish_heartbeat(
        &self,
        heartbeat: ProviderHeartbeat,
    ) -> Result<HeartbeatPublishOutcome, HeartbeatPublishError> {
        self.heartbeat.publish(heartbeat)
    }

    /// Atomically admits one attempt and leases its capacity.
    ///
    /// Admission senders can occupy only the non-reserved portion of the
    /// reliable mailbox.
    pub async fn admit(&self, request: AdmissionRequest) -> Result<PermitLease, FleetHandleError> {
        let admission_slot = self
            .admission_slots
            .clone()
            .acquire_owned()
            .await
            .map_err(|_| FleetHandleError::ActorUnavailable)?;
        let (response, receive) = oneshot::channel();
        self.reliable_tx
            .send(ReliableMessage::Admit {
                request,
                response,
                _admission_slot: admission_slot,
            })
            .await
            .map_err(|_| FleetHandleError::ActorUnavailable)?;
        receive
            .await
            .map_err(|_| FleetHandleError::ActorUnavailable)?
            .map_err(Into::into)
    }

    /// Confirms that the provider writer accepted an admitted request frame.
    ///
    /// The debit remains until a strictly newer absolute writer report
    /// accounts for that enqueue.
    pub async fn mark_writer_enqueued(&self, lease_id: LeaseId) -> Result<(), FleetHandleError> {
        let (response, receive) = oneshot::channel();
        self.reliable_tx
            .send(ReliableMessage::WriterEnqueued { lease_id, response })
            .await
            .map_err(|_| FleetHandleError::ActorUnavailable)?;
        receive
            .await
            .map_err(|_| FleetHandleError::ActorUnavailable)?
            .map_err(Into::into)
    }

    /// Reliably applies a newer absolute writer measurement for one exact
    /// provider session.
    ///
    /// Request paths call this after every terminal writer receipt so actor
    /// debits cannot outlive the queue entry they conservatively reserved.
    pub async fn report_writer_headroom(
        &self,
        provider_id: ProviderId,
        expected_session_revision: SessionRevision,
        report: WriterHeadroom,
    ) -> Result<(), FleetHandleError> {
        let (response, receive) = oneshot::channel();
        self.reliable_tx
            .send(ReliableMessage::WriterHeadroom {
                provider_id,
                expected_session_revision,
                report,
                response,
            })
            .await
            .map_err(|_| FleetHandleError::ActorUnavailable)?;
        receive
            .await
            .map_err(|_| FleetHandleError::ActorUnavailable)?
            .map_err(Into::into)
    }

    /// Renews an active permit without changing its resource quantities.
    pub async fn renew_permit(
        &self,
        lease_id: LeaseId,
        ttl: Duration,
    ) -> Result<PermitLease, FleetHandleError> {
        let (response, receive) = oneshot::channel();
        self.reliable_tx
            .send(ReliableMessage::RenewPermit {
                lease_id,
                ttl,
                response,
            })
            .await
            .map_err(|_| FleetHandleError::ActorUnavailable)?;
        receive
            .await
            .map_err(|_| FleetHandleError::ActorUnavailable)?
            .map_err(Into::into)
    }

    /// Reliably releases an active permit for cancellation or terminal work.
    pub async fn release_permit(
        &self,
        lease_id: LeaseId,
        reason: PermitReleaseReason,
    ) -> Result<PermitRelease, FleetHandleError> {
        let (response, receive) = oneshot::channel();
        self.reliable_tx
            .send(ReliableMessage::ReleasePermit {
                lease_id,
                reason,
                response,
            })
            .await
            .map_err(|_| FleetHandleError::ActorUnavailable)?;
        receive
            .await
            .map_err(|_| FleetHandleError::ActorUnavailable)?
            .map_err(Into::into)
    }

    /// Returns the actor's immutable latest-value view.
    #[must_use]
    pub fn snapshot(&self) -> Arc<FleetSnapshot> {
        self.snapshot_rx.borrow().clone()
    }

    /// Returns currently occupied provider keys in the heartbeat lane.
    #[must_use]
    pub fn pending_heartbeats(&self) -> usize {
        self.heartbeat.pending_len()
    }

    /// Returns currently free reliable mailbox slots.
    #[must_use]
    pub fn reliable_remaining_capacity(&self) -> usize {
        self.reliable_tx.capacity()
    }

    /// Returns admission messages that may still enter the reliable lane.
    #[must_use]
    pub fn admission_remaining_capacity(&self) -> usize {
        self.admission_slots.available_permits()
    }
}

/// Single owner of mutable fleet state and all provider permit leases.
pub struct FleetActor {
    config: FleetActorConfig,
    reliable_rx: mpsc::Receiver<ReliableMessage>,
    heartbeat: Arc<HeartbeatInbox>,
    admission_slots: Arc<Semaphore>,
    snapshot_tx: watch::Sender<Arc<FleetSnapshot>>,
    state: ActorState,
}

impl FleetActor {
    /// Creates an actor and its concrete integration handle.
    pub fn new(
        config: FleetActorConfig,
        initial_revision: FleetRevision,
    ) -> Result<(Self, FleetHandle), FleetConfigError> {
        let config = config.validate()?;
        let (reliable_tx, reliable_rx) = mpsc::channel(config.reliable_mailbox_capacity);
        let admission_slots = Arc::new(Semaphore::new(
            config.reliable_mailbox_capacity - config.reliable_correctness_reserve,
        ));
        let heartbeat = Arc::new(HeartbeatInbox::new(config.heartbeat_capacity));
        let state = ActorState::new(config, initial_revision);
        let initial_snapshot = Arc::new(state.snapshot());
        let (snapshot_tx, snapshot_rx) = watch::channel(initial_snapshot);
        let handle = FleetHandle {
            reliable_tx,
            heartbeat: heartbeat.clone(),
            admission_slots: admission_slots.clone(),
            snapshot_rx,
        };
        Ok((
            Self {
                config,
                reliable_rx,
                heartbeat,
                admission_slots,
                snapshot_tx,
                state,
            },
            handle,
        ))
    }

    /// Runs until coordinated cancellation or a fatal actor failure.
    pub async fn run(mut self, cancellation: CancellationToken) -> Result<(), FleetActorError> {
        let mut reap = tokio::time::interval(self.config.lease_reap_interval);
        reap.set_missed_tick_behavior(MissedTickBehavior::Skip);
        // The first Tokio interval tick is immediate and intentionally reaps
        // leases before processing ordinary traffic.
        loop {
            tokio::select! {
                biased;
                () = cancellation.cancelled() => return Ok(()),
                reliable = self.reliable_rx.recv() => {
                    let Some(reliable) = reliable else {
                        return Err(FleetActorError::ReliableMailboxClosed);
                    };
                    self.handle_reliable(reliable)?;
                }
                heartbeat = self.heartbeat.recv() => {
                    self.state.apply_heartbeat(heartbeat)?;
                    self.publish_snapshot();
                }
                _ = reap.tick() => {
                    if self.state.expire_leases(Instant::now())? {
                        self.publish_snapshot();
                    }
                }
            }
        }
    }

    fn handle_reliable(&mut self, message: ReliableMessage) -> Result<(), FleetActorError> {
        match message {
            ReliableMessage::Lifecycle { update, response } => {
                let result = self.state.apply_lifecycle(update)?;
                if result.is_ok() {
                    self.publish_snapshot();
                }
                let _ = response.send(result);
            }
            ReliableMessage::RemoveProvider {
                provider_id,
                expected_session_revision,
                response,
            } => {
                let result = self
                    .state
                    .remove_provider(provider_id, expected_session_revision)?;
                if result.is_ok() {
                    self.publish_snapshot();
                }
                let _ = response.send(result);
            }
            ReliableMessage::Admit {
                request,
                response,
                _admission_slot,
            } => {
                let result = self.state.admit(request)?;
                let admitted_lease = result.as_ref().ok().map(PermitLease::lease_id);
                if result.is_ok() {
                    self.publish_snapshot();
                }
                if response.send(result).is_err()
                    && let Some(lease_id) = admitted_lease
                {
                    self.state.release_permit_internal(
                        lease_id,
                        PermitReleaseReason::BeforeWriterEnqueue,
                        false,
                    )?;
                    self.publish_snapshot();
                }
            }
            ReliableMessage::WriterEnqueued { lease_id, response } => {
                let result = self.state.mark_writer_enqueued(lease_id);
                if result.is_ok() {
                    self.publish_snapshot();
                }
                let _ = response.send(result);
            }
            ReliableMessage::WriterHeadroom {
                provider_id,
                expected_session_revision,
                report,
                response,
            } => {
                let result = self.state.report_writer_headroom(
                    provider_id,
                    expected_session_revision,
                    report,
                );
                if result.is_ok() {
                    self.publish_snapshot();
                }
                let _ = response.send(result);
            }
            ReliableMessage::RenewPermit {
                lease_id,
                ttl,
                response,
            } => {
                let result = self.state.renew_permit(lease_id, ttl);
                if result.is_ok() {
                    self.publish_snapshot();
                }
                let _ = response.send(result);
            }
            ReliableMessage::ReleasePermit {
                lease_id,
                reason,
                response,
            } => {
                let result = self.state.release_permit(lease_id, reason)?;
                if result.is_ok() {
                    self.publish_snapshot();
                }
                let _ = response.send(result);
            }
        }
        Ok(())
    }

    fn publish_snapshot(&self) {
        self.snapshot_tx
            .send_replace(Arc::new(self.state.snapshot()));
    }
}

impl Drop for FleetActor {
    fn drop(&mut self) {
        self.heartbeat.close();
        self.admission_slots.close();
    }
}

struct ActorState {
    config: FleetActorConfig,
    core: CoreFleetSnapshot,
    providers: BTreeMap<ProviderId, ProviderRuntime>,
    known_provider_ids: BTreeSet<ProviderId>,
    eligible_by_model: BTreeMap<ModelId, BTreeSet<ProviderId>>,
    leases: BTreeMap<LeaseId, LeaseRecord>,
    stats: FleetActorStats,
}

impl ActorState {
    fn new(config: FleetActorConfig, initial_revision: FleetRevision) -> Self {
        Self {
            config,
            core: CoreFleetSnapshot::new(initial_revision),
            providers: BTreeMap::new(),
            known_provider_ids: BTreeSet::new(),
            eligible_by_model: BTreeMap::new(),
            leases: BTreeMap::new(),
            stats: FleetActorStats::default(),
        }
    }

    fn next_revision(&self) -> Result<FleetRevision, RevisionError> {
        self.core.revision().checked_next()
    }

    fn apply_lifecycle(
        &mut self,
        update: ProviderLifecycle,
    ) -> Result<Result<LifecycleApplied, FleetCommandError>, FleetActorError> {
        let (incoming, writer_headroom) = update.into_parts();
        let provider_id = incoming.fence().provider_id;
        let existing = self.providers.get(&provider_id);
        if !self.known_provider_ids.contains(&provider_id)
            && self.known_provider_ids.len() >= self.config.maximum_providers
        {
            return Ok(Err(FleetCommandError::ProviderLimit {
                maximum: self.config.maximum_providers,
            }));
        }
        let active_leases = self.active_provider_leases(provider_id);
        if let Some(existing) = existing
            && existing.provider.fence() != incoming.fence()
            && active_leases != 0
        {
            return Ok(Err(FleetCommandError::ProviderBusy { provider_id }));
        }

        let incoming = if let Some(existing) = existing
            && active_leases != 0
        {
            let previous = existing.provider.capacity();
            let supplied = incoming.capacity();
            let capacity = match CapacitySnapshot::new(
                supplied.token_capacity(),
                previous.tokens_in_use(),
                supplied.kv_capacity(),
                previous.kv_in_use(),
                supplied.concurrency_limit(),
                previous.concurrency_in_use(),
            ) {
                Ok(capacity) => capacity,
                Err(error) => return Ok(Err(error.into())),
            };
            ProviderSnapshot::new(
                incoming.fence().clone(),
                incoming.hardware().clone(),
                incoming.traits().clone(),
                capacity,
                incoming.health(),
            )
        } else {
            incoming
        };

        let revision = self.next_revision()?;
        let next = match reduce_fleet(
            &self.core,
            FleetEvent {
                revision,
                update: FleetUpdate::Upsert(Box::new(incoming.clone())),
            },
        ) {
            Ok(next) => next,
            Err(error) => return Ok(Err(error.into())),
        };

        let runtime = if let Some(mut existing) = self.providers.remove(&provider_id) {
            if existing.provider.fence() != incoming.fence() {
                existing.writer_debits.clear();
                existing.heartbeat_sequence = 0;
            }
            existing.provider = incoming;
            existing.apply_writer_report(writer_headroom);
            existing
        } else {
            ProviderRuntime {
                provider: incoming,
                heartbeat_sequence: 0,
                writer_headroom,
                writer_debits: BTreeMap::new(),
            }
        };
        self.core = next;
        self.providers.insert(provider_id, runtime);
        self.known_provider_ids.insert(provider_id);
        self.rebuild_eligibility();
        Ok(Ok(LifecycleApplied { revision }))
    }

    fn remove_provider(
        &mut self,
        provider_id: ProviderId,
        expected_session_revision: SessionRevision,
    ) -> Result<Result<LifecycleApplied, FleetCommandError>, FleetActorError> {
        if !self.providers.contains_key(&provider_id) {
            return Ok(Err(FleetCommandError::ProviderNotFound(provider_id)));
        }
        let revision = self.next_revision()?;
        let next = match reduce_fleet(
            &self.core,
            FleetEvent {
                revision,
                update: FleetUpdate::Remove {
                    provider_id,
                    expected_session_revision,
                },
            },
        ) {
            Ok(next) => next,
            Err(error) => return Ok(Err(error.into())),
        };
        let lease_ids: Vec<_> = self
            .leases
            .iter()
            .filter_map(|(lease_id, record)| {
                (record.lease.provider().provider_id == provider_id).then_some(*lease_id)
            })
            .collect();
        for lease_id in lease_ids {
            self.leases.remove(&lease_id);
            self.stats.permits_released = self.stats.permits_released.saturating_add(1);
        }
        self.core = next;
        self.providers.remove(&provider_id);
        self.rebuild_eligibility();
        Ok(Ok(LifecycleApplied { revision }))
    }

    fn apply_heartbeat(&mut self, heartbeat: ProviderHeartbeat) -> Result<(), FleetActorError> {
        let provider_id = heartbeat.provider_id();
        let Some(runtime) = self.providers.get(&provider_id) else {
            self.stats.heartbeats_stale = self.stats.heartbeats_stale.saturating_add(1);
            return Ok(());
        };
        if heartbeat.sequence() == 0
            || heartbeat.sequence() <= runtime.heartbeat_sequence
            || heartbeat.fence() != runtime.provider.fence()
        {
            self.stats.heartbeats_stale = self.stats.heartbeats_stale.saturating_add(1);
            return Ok(());
        }

        let current = runtime.provider.capacity();
        let limits = heartbeat.capacity();
        let capacity = match CapacitySnapshot::new(
            limits.token_capacity(),
            current.tokens_in_use(),
            limits.kv_capacity(),
            current.kv_in_use(),
            limits.concurrency_limit(),
            current.concurrency_in_use(),
        ) {
            Ok(capacity) => capacity,
            Err(_) => {
                self.stats.heartbeats_rejected = self.stats.heartbeats_rejected.saturating_add(1);
                return Ok(());
            }
        };
        let provider = ProviderSnapshot::new(
            runtime.provider.fence().clone(),
            runtime.provider.hardware().clone(),
            runtime.provider.traits().clone(),
            capacity,
            heartbeat.health(),
        );
        self.apply_internal_provider(provider.clone())?;
        let runtime = self
            .providers
            .get_mut(&provider_id)
            .ok_or(FleetActorError::Invariant("heartbeat provider disappeared"))?;
        runtime.provider = provider;
        runtime.heartbeat_sequence = heartbeat.sequence();
        runtime.apply_writer_report(heartbeat.writer_headroom());
        self.stats.heartbeats_applied = self.stats.heartbeats_applied.saturating_add(1);
        self.rebuild_eligibility();
        Ok(())
    }

    fn admit(
        &mut self,
        request: AdmissionRequest,
    ) -> Result<Result<PermitLease, FleetCommandError>, FleetActorError> {
        if request.lease_ttl().is_zero() || request.lease_ttl() > self.config.maximum_lease_ttl {
            return Ok(Err(FleetCommandError::InvalidLeaseTtl {
                maximum: self.config.maximum_lease_ttl,
            }));
        }
        if self.leases.len() >= self.config.maximum_active_leases {
            return Ok(Err(FleetCommandError::LeaseLimit {
                maximum: self.config.maximum_active_leases,
            }));
        }
        if self.writer_debit_count() >= self.config.maximum_writer_debits {
            return Ok(Err(FleetCommandError::WriterReservationLimit {
                maximum: self.config.maximum_writer_debits,
            }));
        }
        let candidates = self.admission_candidates(&request);
        if candidates.is_empty() {
            return Ok(Err(FleetCommandError::NoEligibleProvider(
                request.model_id().clone(),
            )));
        }

        let mut last_error = None;
        let mut selected = None;
        for provider_id in candidates {
            match self.evaluate_admission(provider_id, &request) {
                Ok(admission) => {
                    selected = Some((provider_id, admission));
                    break;
                }
                Err(error) => {
                    if request.provider_id().is_some() {
                        return Ok(Err(error));
                    }
                    last_error = Some(error);
                }
            }
        }
        let Some((provider_id, admission)) = selected else {
            return Ok(Err(last_error.unwrap_or_else(|| {
                FleetCommandError::NoEligibleProvider(request.model_id().clone())
            })));
        };

        let lease_id = self.unused_lease_id();
        let permit_id = match request.kind() {
            darkbloom_coordinator_core::fleet::AdmissionKind::Regular => self.unused_permit_id(),
            darkbloom_coordinator_core::fleet::AdmissionKind::Probe(permit_id) => {
                if self.permit_is_active(permit_id) {
                    return Ok(Err(FleetCommandError::PermitAlreadyActive(permit_id)));
                }
                permit_id
            }
        };
        let expires_at = Instant::now()
            .checked_add(request.lease_ttl())
            .ok_or(FleetActorError::Invariant("permit lease deadline overflow"))?;
        let provider = self
            .providers
            .get(&provider_id)
            .ok_or(FleetActorError::Invariant("admission provider disappeared"))?
            .provider
            .fence()
            .clone();
        let updated = {
            let runtime = self
                .providers
                .get(&provider_id)
                .ok_or(FleetActorError::Invariant("admission provider disappeared"))?;
            ProviderSnapshot::new(
                runtime.provider.fence().clone(),
                runtime.provider.hardware().clone(),
                runtime.provider.traits().clone(),
                admission.projected_capacity,
                runtime.provider.health(),
            )
        };
        self.apply_internal_provider(updated.clone())?;
        let runtime = self
            .providers
            .get_mut(&provider_id)
            .ok_or(FleetActorError::Invariant("admission provider disappeared"))?;
        runtime.provider = updated;
        runtime.writer_debits.insert(
            lease_id,
            WriterDebit {
                bytes: request.writer_bytes(),
                report_revision: runtime.writer_headroom.revision(),
                enqueued: false,
            },
        );
        let lease = PermitLease::new(
            lease_id,
            permit_id,
            provider,
            request.demand(),
            request.writer_bytes(),
            expires_at,
        );
        self.leases.insert(
            lease_id,
            LeaseRecord {
                lease: lease.clone(),
            },
        );
        self.stats.permits_acquired = self.stats.permits_acquired.saturating_add(1);
        Ok(Ok(lease))
    }

    fn evaluate_admission(
        &self,
        provider_id: ProviderId,
        request: &AdmissionRequest,
    ) -> Result<Admission, FleetCommandError> {
        let runtime = self
            .providers
            .get(&provider_id)
            .ok_or(FleetCommandError::ProviderNotFound(provider_id))?;
        if runtime.provider.fence().model_id != *request.model_id() {
            return Err(FleetCommandError::ModelMismatch {
                provider_id,
                model_id: request.model_id().clone(),
            });
        }
        if request
            .expected_fence()
            .is_some_and(|expected| expected != runtime.provider.fence())
        {
            return Err(FleetCommandError::StaleProviderFence(provider_id));
        }
        let (available_items, available_bytes) = runtime.effective_writer_headroom();
        let required_items = self
            .config
            .writer_correctness_item_reserve
            .saturating_add(1);
        if available_items < required_items {
            return Err(FleetCommandError::WriterItemHeadroom {
                provider_id,
                available: available_items,
                reserve: self.config.writer_correctness_item_reserve,
            });
        }
        let required_bytes = self
            .config
            .writer_correctness_byte_reserve
            .saturating_add(request.writer_bytes());
        if available_bytes < required_bytes {
            return Err(FleetCommandError::WriterByteHeadroom {
                provider_id,
                available: available_bytes,
                requested: request.writer_bytes(),
                reserve: self.config.writer_correctness_byte_reserve,
            });
        }
        darkbloom_coordinator_core::fleet::admit(
            &runtime.provider,
            request.request_traits(),
            request.demand(),
            request.kind(),
        )
        .map_err(Into::into)
    }

    fn admission_candidates(&self, request: &AdmissionRequest) -> Vec<ProviderId> {
        if let Some(provider_id) = request.provider_id() {
            return vec![provider_id];
        }
        self.eligible_by_model
            .get(request.model_id())
            .map_or_else(Vec::new, |providers| providers.iter().copied().collect())
    }

    fn mark_writer_enqueued(&mut self, lease_id: LeaseId) -> Result<(), FleetCommandError> {
        let record = self
            .leases
            .get(&lease_id)
            .ok_or(FleetCommandError::LeaseNotFound(lease_id))?;
        let provider_id = record.lease.provider().provider_id;
        let runtime = self
            .providers
            .get_mut(&provider_id)
            .ok_or(FleetCommandError::ProviderNotFound(provider_id))?;
        let debit = runtime
            .writer_debits
            .get_mut(&lease_id)
            .ok_or(FleetCommandError::LeaseNotFound(lease_id))?;
        debit.enqueued = true;
        Ok(())
    }

    fn report_writer_headroom(
        &mut self,
        provider_id: ProviderId,
        expected_session_revision: SessionRevision,
        report: WriterHeadroom,
    ) -> Result<(), FleetCommandError> {
        let runtime = self
            .providers
            .get_mut(&provider_id)
            .ok_or(FleetCommandError::ProviderNotFound(provider_id))?;
        if runtime.provider.fence().session_revision != expected_session_revision {
            return Err(FleetCommandError::StaleProviderFence(provider_id));
        }
        runtime.apply_writer_report(report);
        Ok(())
    }

    fn renew_permit(
        &mut self,
        lease_id: LeaseId,
        ttl: Duration,
    ) -> Result<PermitLease, FleetCommandError> {
        if ttl.is_zero() || ttl > self.config.maximum_lease_ttl {
            return Err(FleetCommandError::InvalidLeaseTtl {
                maximum: self.config.maximum_lease_ttl,
            });
        }
        let record = self
            .leases
            .get_mut(&lease_id)
            .ok_or(FleetCommandError::LeaseNotFound(lease_id))?;
        let expires_at =
            Instant::now()
                .checked_add(ttl)
                .ok_or(FleetCommandError::InvalidLeaseTtl {
                    maximum: self.config.maximum_lease_ttl,
                })?;
        record.lease = PermitLease::new(
            record.lease.lease_id(),
            record.lease.permit_id(),
            record.lease.provider().clone(),
            record.lease.demand(),
            record.lease.writer_bytes(),
            expires_at,
        );
        Ok(record.lease.clone())
    }

    fn release_permit_internal(
        &mut self,
        lease_id: LeaseId,
        reason: PermitReleaseReason,
        expired: bool,
    ) -> Result<PermitRelease, FleetActorError> {
        let record = self
            .leases
            .get(&lease_id)
            .cloned()
            .ok_or(FleetActorError::Invariant("active permit disappeared"))?;
        let provider_id = record.lease.provider().provider_id;
        let runtime = self
            .providers
            .get(&provider_id)
            .ok_or(FleetActorError::Invariant("permit provider disappeared"))?;
        let capacity = runtime.provider.capacity();
        let demand = record.lease.demand();
        let released = CapacitySnapshot::new(
            capacity.token_capacity(),
            capacity
                .tokens_in_use()
                .checked_sub(demand.total_tokens())
                .map_err(|_| FleetActorError::Invariant("permit token underflow"))?,
            capacity.kv_capacity(),
            capacity
                .kv_in_use()
                .checked_sub(demand.kv_bytes())
                .map_err(|_| FleetActorError::Invariant("permit KV underflow"))?,
            capacity.concurrency_limit(),
            capacity
                .concurrency_in_use()
                .checked_sub(1)
                .ok_or(FleetActorError::Invariant("permit concurrency underflow"))?,
        )
        .map_err(FleetActorError::InternalCapacity)?;
        let provider = ProviderSnapshot::new(
            runtime.provider.fence().clone(),
            runtime.provider.hardware().clone(),
            runtime.provider.traits().clone(),
            released,
            runtime.provider.health(),
        );
        self.apply_internal_provider(provider.clone())?;
        let runtime = self
            .providers
            .get_mut(&provider_id)
            .ok_or(FleetActorError::Invariant("permit provider disappeared"))?;
        runtime.provider = provider;
        if runtime
            .writer_debits
            .get(&lease_id)
            .is_some_and(|debit| !debit.enqueued)
        {
            runtime.writer_debits.remove(&lease_id);
        }
        self.leases.remove(&lease_id);
        if expired {
            self.stats.permits_expired = self.stats.permits_expired.saturating_add(1);
        } else {
            self.stats.permits_released = self.stats.permits_released.saturating_add(1);
        }
        Ok(PermitRelease { lease_id, reason })
    }

    fn release_permit(
        &mut self,
        lease_id: LeaseId,
        reason: PermitReleaseReason,
    ) -> Result<Result<PermitRelease, FleetCommandError>, FleetActorError> {
        if !self.leases.contains_key(&lease_id) {
            return Ok(Err(FleetCommandError::LeaseNotFound(lease_id)));
        }
        self.release_permit_internal(lease_id, reason, false)
            .map(Ok)
    }

    fn expire_leases(&mut self, now: Instant) -> Result<bool, FleetActorError> {
        let expired: Vec<_> = self
            .leases
            .iter()
            .filter_map(|(lease_id, record)| {
                (record.lease.expires_at() <= now).then_some(*lease_id)
            })
            .collect();
        let changed = !expired.is_empty();
        for lease_id in expired {
            self.release_permit_internal(lease_id, PermitReleaseReason::AttemptReleased, true)?;
        }
        Ok(changed)
    }

    fn apply_internal_provider(
        &mut self,
        provider: ProviderSnapshot,
    ) -> Result<(), FleetActorError> {
        let revision = self.next_revision()?;
        self.core = reduce_fleet(
            &self.core,
            FleetEvent {
                revision,
                update: FleetUpdate::Upsert(Box::new(provider)),
            },
        )
        .map_err(FleetActorError::InternalFleetState)?;
        Ok(())
    }

    fn unused_lease_id(&self) -> LeaseId {
        loop {
            let lease_id = LeaseId::random();
            if !self.leases.contains_key(&lease_id) {
                return lease_id;
            }
        }
    }

    fn unused_permit_id(&self) -> PermitId {
        loop {
            let permit_id = PermitId::random();
            if !self.permit_is_active(permit_id) {
                return permit_id;
            }
        }
    }

    fn permit_is_active(&self, permit_id: PermitId) -> bool {
        self.leases
            .values()
            .any(|record| record.lease.permit_id() == permit_id)
    }

    fn active_provider_leases(&self, provider_id: ProviderId) -> usize {
        self.leases
            .values()
            .filter(|record| record.lease.provider().provider_id == provider_id)
            .count()
    }

    fn writer_debit_count(&self) -> usize {
        self.providers
            .values()
            .map(|runtime| runtime.writer_debits.len())
            .sum()
    }

    fn rebuild_eligibility(&mut self) {
        let mut eligible = BTreeMap::<ModelId, BTreeSet<ProviderId>>::new();
        for runtime in self.providers.values() {
            if runtime.provider.traits().template_render_ok() {
                eligible
                    .entry(runtime.provider.fence().model_id.clone())
                    .or_default()
                    .insert(runtime.provider.fence().provider_id);
            }
        }
        self.eligible_by_model = eligible;
    }

    fn snapshot(&self) -> FleetSnapshot {
        let providers = self
            .providers
            .iter()
            .map(|(provider_id, runtime)| {
                let (effective_writer_items, effective_writer_bytes) =
                    runtime.effective_writer_headroom();
                (
                    *provider_id,
                    ProviderRuntimeSnapshot::new(
                        runtime.provider.clone(),
                        runtime.heartbeat_sequence,
                        runtime.writer_headroom,
                        effective_writer_items,
                        effective_writer_bytes,
                        self.active_provider_leases(*provider_id),
                    ),
                )
            })
            .collect();
        let leases = self
            .leases
            .iter()
            .map(|(lease_id, record)| (*lease_id, record.lease.clone()))
            .collect();
        FleetSnapshot::new(
            self.core.clone(),
            providers,
            self.eligible_by_model.clone(),
            leases,
            self.stats,
        )
    }
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use darkbloom_coordinator_core::{
        fleet::{
            AdmissionDemand, AdmissionKind, CapacitySnapshot, FleetStateError, HealthState,
            ProviderSnapshot,
        },
        ids::{
            FleetRevision, HardwareClass, ModelId, ModelRevision, ProviderId, SessionId,
            SessionRevision, TrustRevision,
        },
        request::ProviderFence,
        tokens::{KvBytes, TokenCount},
        traits::{ProviderTraits, RequestTraits},
    };
    use tokio::{sync::oneshot, time::timeout};
    use tokio_util::sync::CancellationToken;
    use uuid::Uuid;

    use super::{
        ActorState, FleetActor, FleetActorConfig, HeartbeatInbox, HeartbeatPublishError,
        ReliableMessage,
    };
    use crate::{
        fleet::{
            AdmissionRequest, FleetCommandError, HeartbeatPublishOutcome, PermitReleaseReason,
            ProviderCapacity, ProviderHeartbeat, ProviderLifecycle, WriterHeadroom,
        },
        supervisor::{
            EssentialTaskError, Supervisor, SupervisorConfig, SupervisorError, SupervisorStatus,
        },
    };

    fn actor_config() -> FleetActorConfig {
        FleetActorConfig {
            reliable_mailbox_capacity: 16,
            reliable_correctness_reserve: 4,
            heartbeat_capacity: 16,
            maximum_providers: 16,
            maximum_active_leases: 64,
            maximum_writer_debits: 64,
            maximum_lease_ttl: Duration::from_secs(1),
            lease_reap_interval: Duration::from_millis(2),
            writer_correctness_item_reserve: 1,
            writer_correctness_byte_reserve: 16,
        }
    }

    fn provider_id(value: u128) -> ProviderId {
        ProviderId::new(Uuid::from_u128(value)).expect("nonzero provider")
    }

    fn provider(value: u128) -> ProviderSnapshot {
        provider_with_revisions(value, 1, 1, 1)
    }

    fn provider_with_revisions(
        value: u128,
        session_revision: u64,
        trust_revision: u64,
        model_revision: u64,
    ) -> ProviderSnapshot {
        ProviderSnapshot::new(
            ProviderFence {
                provider_id: provider_id(value),
                session_id: SessionId::new(Uuid::from_u128(value + 10_000))
                    .expect("nonzero session"),
                session_revision: SessionRevision::new(session_revision).expect("nonzero"),
                trust_revision: TrustRevision::new(trust_revision).expect("nonzero"),
                model_id: ModelId::new("model/test").expect("valid model"),
                model_revision: ModelRevision::new(model_revision).expect("nonzero"),
            },
            HardwareClass::new("m4-max").expect("valid hardware"),
            ProviderTraits::new(TokenCount::new(4_096), [], true),
            CapacitySnapshot::new(
                TokenCount::new(10_000),
                TokenCount::ZERO,
                KvBytes::new(100_000),
                KvBytes::ZERO,
                64,
                0,
            )
            .expect("valid capacity"),
            HealthState::new(),
        )
    }

    fn writer(revision: u64) -> WriterHeadroom {
        WriterHeadroom::new(revision, 128, 1_000_000).expect("valid writer report")
    }

    fn lifecycle(value: u128) -> ProviderLifecycle {
        ProviderLifecycle::new(provider(value), writer(1))
    }

    fn admission(ttl: Duration) -> AdmissionRequest {
        AdmissionRequest::any(
            ModelId::new("model/test").expect("valid model"),
            RequestTraits::new(TokenCount::new(30)),
            AdmissionDemand::new(TokenCount::new(10), TokenCount::new(20), KvBytes::new(100))
                .expect("valid demand"),
            AdmissionKind::Regular,
            128,
            ttl,
        )
    }

    fn heartbeat(provider: &ProviderSnapshot, sequence: u64) -> ProviderHeartbeat {
        ProviderHeartbeat::new(
            sequence,
            provider.fence().clone(),
            ProviderCapacity::new(
                provider.capacity().token_capacity(),
                provider.capacity().kv_capacity(),
                provider.capacity().concurrency_limit(),
            )
            .expect("valid limits"),
            provider.health(),
            writer(sequence.max(1)),
        )
    }

    #[test]
    fn stale_provider_revision_is_transactionally_rejected() {
        let mut state = ActorState::new(
            actor_config(),
            FleetRevision::new(1).expect("nonzero revision"),
        );
        state
            .apply_lifecycle(lifecycle(1))
            .expect("actor healthy")
            .expect("register");
        let revision = state.core.revision();
        let mut stale = provider(1);
        let stale_fence = ProviderFence {
            session_id: SessionId::new(Uuid::from_u128(99_999)).expect("nonzero"),
            ..stale.fence().clone()
        };
        stale = ProviderSnapshot::new(
            stale_fence,
            stale.hardware().clone(),
            stale.traits().clone(),
            stale.capacity(),
            stale.health(),
        );

        assert!(matches!(
            state.apply_lifecycle(ProviderLifecycle::new(stale, writer(2))),
            Ok(Err(FleetCommandError::FleetState(
                FleetStateError::StaleProviderRevision { .. }
            )))
        ));
        assert_eq!(state.core.revision(), revision);
        assert_eq!(
            state
                .providers
                .get(&provider_id(1))
                .expect("canonical provider")
                .provider
                .fence()
                .session_id,
            provider(1).fence().session_id
        );
    }

    #[test]
    fn heartbeat_lane_coalesces_latest_per_provider() {
        let inbox = HeartbeatInbox::new(2);
        let provider = provider(1);
        assert_eq!(
            inbox.publish(heartbeat(&provider, 1)),
            Ok(HeartbeatPublishOutcome::Enqueued)
        );
        assert_eq!(
            inbox.publish(heartbeat(&provider, 3)),
            Ok(HeartbeatPublishOutcome::Coalesced)
        );
        assert_eq!(
            inbox.publish(heartbeat(&provider, 2)),
            Ok(HeartbeatPublishOutcome::Stale)
        );
        assert_eq!(inbox.pending_len(), 1);
        assert_eq!(inbox.pop().expect("pending").sequence(), 3);
    }

    #[test]
    fn permit_conservation_holds_for_release_orders() {
        for lease_count in 1..=32 {
            let mut state = ActorState::new(
                actor_config(),
                FleetRevision::new(1).expect("nonzero revision"),
            );
            state
                .apply_lifecycle(lifecycle(1))
                .expect("actor healthy")
                .expect("register");
            let baseline = state
                .providers
                .get(&provider_id(1))
                .expect("provider")
                .provider
                .capacity();
            let mut leases = Vec::new();
            for _ in 0..lease_count {
                let lease = state
                    .admit(admission(Duration::from_secs(1)))
                    .expect("actor healthy")
                    .expect("admitted");
                leases.push(lease.lease_id());
            }
            for lease_id in leases.into_iter().rev() {
                state
                    .release_permit(lease_id, PermitReleaseReason::Terminal)
                    .expect("actor healthy")
                    .expect("released");
            }
            let final_capacity = state
                .providers
                .get(&provider_id(1))
                .expect("provider")
                .provider
                .capacity();
            assert_eq!(final_capacity, baseline);
            assert_eq!(state.leases.len(), 0);
            assert_eq!(state.stats.permits_acquired, lease_count);
            assert_eq!(state.stats.permits_released, lease_count);
        }
    }

    #[tokio::test]
    async fn permit_expiry_returns_capacity() {
        let mut config = actor_config();
        config.maximum_lease_ttl = Duration::from_millis(50);
        let (actor, handle) =
            FleetActor::new(config, FleetRevision::new(1).expect("nonzero revision"))
                .expect("actor");
        let cancellation = CancellationToken::new();
        let task = tokio::spawn(actor.run(cancellation.clone()));
        handle
            .apply_lifecycle(lifecycle(1))
            .await
            .expect("register");
        let lease = handle
            .admit(admission(Duration::from_millis(5)))
            .await
            .expect("admit");
        assert!(handle.snapshot().lease(lease.lease_id()).is_some());

        timeout(Duration::from_millis(100), async {
            loop {
                if handle.snapshot().active_lease_count() == 0 {
                    break;
                }
                tokio::task::yield_now().await;
            }
        })
        .await
        .expect("lease reaped");
        let snapshot = handle.snapshot();
        let capacity = snapshot
            .provider(provider_id(1))
            .expect("provider")
            .provider()
            .capacity();
        assert_eq!(capacity.tokens_in_use(), TokenCount::ZERO);
        assert_eq!(capacity.kv_in_use(), KvBytes::ZERO);
        assert_eq!(capacity.concurrency_in_use(), 0);
        assert_eq!(snapshot.stats().permits_acquired, 1);
        assert_eq!(snapshot.stats().permits_expired, 1);

        cancellation.cancel();
        task.await.expect("join").expect("clean actor shutdown");
    }

    #[tokio::test]
    async fn full_admission_lane_preserves_correctness_slot() {
        let mut config = actor_config();
        config.reliable_mailbox_capacity = 4;
        config.reliable_correctness_reserve = 1;
        let (actor, handle) =
            FleetActor::new(config, FleetRevision::new(1).expect("nonzero revision"))
                .expect("actor");
        let mut admission_receivers = Vec::new();
        for _ in 0..3 {
            let slot = handle
                .admission_slots
                .clone()
                .acquire_owned()
                .await
                .expect("slot");
            let (response, receive) = oneshot::channel();
            handle
                .reliable_tx
                .send(ReliableMessage::Admit {
                    request: admission(Duration::from_secs(1)),
                    response,
                    _admission_slot: slot,
                })
                .await
                .expect("admission enters lane");
            admission_receivers.push(receive);
        }
        assert_eq!(handle.admission_remaining_capacity(), 0);
        assert_eq!(handle.reliable_remaining_capacity(), 1);

        let (response, _receive) = oneshot::channel();
        handle
            .reliable_tx
            .send(ReliableMessage::Lifecycle {
                update: lifecycle(1),
                response,
            })
            .await
            .expect("correctness message enters reserved slot");
        assert_eq!(handle.reliable_remaining_capacity(), 0);
        assert_eq!(actor.reliable_rx.len(), 4);
        drop(admission_receivers);
    }

    #[tokio::test]
    async fn fatal_fleet_actor_exit_clears_supervisor_readiness() {
        let (actor, fleet_handle) = FleetActor::new(
            actor_config(),
            FleetRevision::new(1).expect("nonzero revision"),
        )
        .expect("actor");
        let (mut supervisor, mut supervisor_handle) = Supervisor::new(SupervisorConfig {
            startup_timeout: Duration::from_millis(100),
            shutdown_timeout: Duration::from_millis(100),
            maximum_tasks: 2,
        })
        .expect("supervisor");
        supervisor
            .spawn_essential("fleet-actor", |context| async move {
                context.mark_ready().expect("ready");
                actor
                    .run(context.cancellation_token())
                    .await
                    .map_err(|error| EssentialTaskError::new(error.to_string()))
            })
            .expect("spawn actor");
        let supervisor_task = tokio::spawn(supervisor.run());
        timeout(Duration::from_millis(100), async {
            while !supervisor_handle.is_ready() {
                supervisor_handle.changed().await.expect("status");
            }
        })
        .await
        .expect("supervisor ready");

        drop(fleet_handle);
        let result = timeout(Duration::from_millis(200), supervisor_task)
            .await
            .expect("fatal exit observed")
            .expect("supervisor join");
        assert!(matches!(
            result,
            Err(SupervisorError::EssentialFailed { .. })
        ));
        assert_eq!(
            supervisor_handle.readiness().status,
            SupervisorStatus::Fatal
        );
        assert!(!supervisor_handle.is_ready());
    }

    #[test]
    fn one_thousand_providers_and_heartbeats_remain_bounded() {
        let mut config = actor_config();
        config.maximum_providers = 1_000;
        config.heartbeat_capacity = 1_000;
        let mut state = ActorState::new(config, FleetRevision::new(1).expect("nonzero revision"));
        let inbox = HeartbeatInbox::new(1_000);
        for value in 1..=1_000_u128 {
            let provider = provider(value);
            state
                .apply_lifecycle(ProviderLifecycle::new(provider.clone(), writer(1)))
                .expect("actor healthy")
                .expect("within provider bound");
            assert_eq!(
                inbox.publish(heartbeat(&provider, 1)),
                Ok(HeartbeatPublishOutcome::Enqueued)
            );
        }
        assert_eq!(state.providers.len(), 1_000);
        assert_eq!(inbox.pending_len(), 1_000);
        assert!(matches!(
            state.apply_lifecycle(lifecycle(1_001)),
            Ok(Err(FleetCommandError::ProviderLimit { maximum: 1_000 }))
        ));
        assert_eq!(
            inbox.publish(heartbeat(&provider(1_001), 1)),
            Err(HeartbeatPublishError::Full { capacity: 1_000 })
        );
    }
}
