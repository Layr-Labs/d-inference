//! The per-request async driver around the pure core reducer
//! (`darkbloom_core::request`, plan §7.2).
//!
//! The reducer owns every lifecycle decision; this driver only:
//!
//! 1. delivers observations (ledger results, fleet decisions, provider
//!    frames, timers, consumer signals) as [`Event`]s, and
//! 2. executes the returned [`Effect`]s (send frames, run transactions,
//!    release permits, answer the consumer).
//!
//! No lifecycle transition is decided here (plan §19.3). All I/O helpers are
//! bounded; the pump tasks live in a [`JoinSet`] aborted when the driver
//! drops, so nothing detaches from the task's scope.

use std::collections::{HashMap, VecDeque};

use bytes::Bytes;
use tokio::sync::mpsc;
use tokio::task::JoinSet;
use uuid::Uuid;

use darkbloom_core::fleet::hedge::HedgeToken;
use darkbloom_core::ids::{AttemptId, LeaseId, PermitId, ProviderId, SessionEpoch};
use darkbloom_core::money::Tokens;
use darkbloom_core::request::{
    AttemptState, Deadlines, Effect, Event, HedgeOffer, Phase, PreparedFacts, RequestMachine,
    RequestOutcome,
};
use darkbloom_core::time::{DurationMs, TimestampMs};
use darkbloom_protocol::json_v1::UsageInfo;
use darkbloom_protocol::json_v2::{AbortReason, AckDisposition};

use crate::contracts::{
    AdmitOutcome, AdmitRequest, AttemptEvent, AttemptSinks, ChunkFrame, FleetCommand,
    FleetObservation, LedgerError, OnWire, ProtocolGen, WriteError,
};
use crate::request_task::attempt::{
    classify_v1_error, core_error_class, new_scope, AttemptRuntime,
};
use crate::request_task::classify::{classify, rewrite_chunk_model, strip_sse_prefix, ChunkClass};
use crate::request_task::crypto::AttemptCrypto;
use crate::request_task::funding::{
    clamp_tokens, release_params, reserve_params, resize_freeze_params, FreezeInputs, ReserveInputs,
};
use crate::request_task::terminal::{
    settle_params, v1_complete_receipt, v1_error_receipt, v2_receipt,
};
use crate::request_task::types::{Clock, ConsumerEvent, TaskReport, UsageOut};
use crate::request_task::{NormalizedRequest, RequestTaskDeps};

/// Interval for resending the same idempotent start while its ack is
/// outstanding (plan §10.3).
const START_RETRY_INTERVAL: DurationMs = DurationMs::new(2_000);

/// Merged inputs from all pump tasks.
enum TaskInput {
    Attempt(AttemptId, AttemptEvent),
    Chunk(AttemptId, ChunkFrame),
    Wire {
        attempt: AttemptId,
        kind: WireKind,
        result: WireOutcome,
    },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum WireKind {
    Prepare,
    Start,
    Abort,
    Cancel,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum WireOutcome {
    Confirmed,
    Failed,
    Ambiguous,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum TimerKind {
    FirstContent,
    Total,
    Hedge,
    PrepareDeadline(AttemptId),
    LeaseExpiry(AttemptId),
    StartRetry,
    TerminalWait,
    CancelEvidence,
    StreamIdle,
}

/// Permit bookkeeping with a Drop backstop: releasing on drop is safe
/// because `FleetCommand::ReleasePermit` is idempotent (plan §9.2.10) and
/// `teardown()` drains the map first on every ordinary exit path, making
/// the Drop a no-op there.
struct PermitLedger {
    fleet_commands: mpsc::Sender<FleetCommand>,
    permits: HashMap<AttemptId, (ProviderId, PermitId)>,
}

impl PermitLedger {
    fn new(fleet_commands: mpsc::Sender<FleetCommand>) -> Self {
        Self {
            fleet_commands,
            permits: HashMap::new(),
        }
    }

    fn insert(&mut self, attempt: AttemptId, provider: ProviderId, permit: PermitId) {
        self.permits.insert(attempt, (provider, permit));
    }

    fn remove(&mut self, attempt: &AttemptId) -> Option<(ProviderId, PermitId)> {
        self.permits.remove(attempt)
    }

    fn release_all(&mut self) {
        for (_, (provider, permit)) in self.permits.drain() {
            let _ = self
                .fleet_commands
                .try_send(FleetCommand::ReleasePermit { provider, permit });
        }
    }
}

impl Drop for PermitLedger {
    fn drop(&mut self) {
        self.release_all();
    }
}

pub(super) struct Driver {
    deps: RequestTaskDeps,
    req: NormalizedRequest,
    clock: Clock,
    machine: RequestMachine,
    queue: VecDeque<Event>,
    inputs_tx: mpsc::Sender<TaskInput>,
    inputs_rx: mpsc::Receiver<TaskInput>,
    pumps: JoinSet<()>,
    runtimes: HashMap<AttemptId, AttemptRuntime>,
    pending_grants: HashMap<AttemptId, Box<crate::contracts::AdmitGrant>>,
    /// Fleet-minted permit identity per attempt (plan §9.2.10): retained
    /// from grant until the release effect fires, independent of whether
    /// the runtime was ever constructed. Drop-guarded: if the driver future
    /// is dropped without running `teardown()` (e.g. a caller races it
    /// against a shutdown token), remaining permits are still released
    /// instead of waiting for hard expiry.
    attempt_permits: PermitLedger,
    hedge_tokens: HashMap<AttemptId, HedgeToken>,
    // Absolute deadlines fixed at ingress (plan §9.2.5, §16).
    first_content_deadline: TimestampMs,
    total_deadline: TimestampMs,
    first_content_fired: bool,
    total_fired: bool,
    hedge_at: Option<TimestampMs>,
    hedge_fired: bool,
    start_retry_at: Option<TimestampMs>,
    terminal_wait_at: Option<TimestampMs>,
    cancel_evidence_at: Option<TimestampMs>,
    idle_at: Option<TimestampMs>,
    consumer_gone: bool,
    pipe_stalled: bool,
    mark_running_done: bool,
    fatal: bool,
    outcome: Option<RequestOutcome>,
    ledger_error: Option<LedgerError>,
    usage_out: Option<UsageOut>,
}

impl Driver {
    pub(super) fn new(deps: RequestTaskDeps, req: NormalizedRequest) -> Self {
        let permit_ledger = PermitLedger::new(deps.fleet.commands.clone());
        let clock = Clock::start();
        let now = clock.now();
        let policy = &deps.policy;
        let per_token_ms =
            policy.first_content_per_prompt_token.as_millis() as u64 * req.estimated_prompt_tokens;
        let first_content_deadline = now.saturating_add(DurationMs::new(
            policy.first_content_base.as_millis() as u64 + per_token_ms,
        ));
        let total_deadline =
            now.saturating_add(DurationMs::new(policy.request_deadline.as_millis() as u64));
        let machine = RequestMachine::new(
            req.job,
            Deadlines {
                first_content: first_content_deadline,
                total: total_deadline,
            },
        );
        // Bounded merged-input channel: sized to absorb the chunk pipe plus
        // control traffic; overflow backpressures into the per-attempt pipe,
        // whose `Full` is the 13.6 grace-window boundary.
        let (inputs_tx, inputs_rx) = mpsc::channel(policy.pipe_max_items.max(16) + 64);
        Self {
            deps,
            req,
            clock,
            machine,
            queue: VecDeque::new(),
            inputs_tx,
            inputs_rx,
            pumps: JoinSet::new(),
            runtimes: HashMap::new(),
            pending_grants: HashMap::new(),
            attempt_permits: permit_ledger,
            hedge_tokens: HashMap::new(),
            first_content_deadline,
            total_deadline,
            first_content_fired: false,
            total_fired: false,
            hedge_at: None,
            hedge_fired: false,
            start_retry_at: None,
            terminal_wait_at: None,
            cancel_evidence_at: None,
            idle_at: None,
            consumer_gone: false,
            pipe_stalled: false,
            mark_running_done: false,
            fatal: false,
            outcome: None,
            ledger_error: None,
            usage_out: None,
        }
    }

    pub(super) async fn drive(mut self) -> TaskReport {
        self.reserve().await;
        while !self.machine.is_finished() && !self.fatal {
            let timer = self.next_timer();
            let sleep_at = timer.map(|(at, _)| self.clock.instant_at(at));
            tokio::select! {
                biased;
                _ = self.deps.shutdown.cancelled(), if !self.consumer_gone => {
                    self.on_consumer_gone().await;
                }
                _ = self.req.consumer.closed(), if !self.consumer_gone => {
                    self.on_consumer_gone().await;
                }
                input = self.inputs_rx.recv() => match input {
                    Some(TaskInput::Attempt(id, ev)) => self.on_attempt_event(id, ev).await,
                    Some(TaskInput::Chunk(id, frame)) => self.on_chunk(id, frame).await,
                    Some(TaskInput::Wire { attempt, kind, result }) => {
                        self.on_wire(attempt, kind, result).await;
                    }
                    None => break,
                },
                _ = tokio::time::sleep_until(sleep_at.unwrap_or_else(tokio::time::Instant::now)),
                    if sleep_at.is_some() =>
                {
                    if let Some((_, kind)) = timer {
                        self.on_timer(kind).await;
                    }
                }
            }
        }
        self.teardown().await;
        TaskReport {
            outcome: self.outcome.unwrap_or(RequestOutcome::ProviderLost),
            committed: self.machine.committed_attempt().is_some(),
            ledger_error: self.ledger_error,
            usage: self.usage_out,
        }
    }

    // ------------------------------------------------------------------
    // Reducer plumbing
    // ------------------------------------------------------------------

    fn push(&mut self, event: Event) {
        self.queue.push_back(event);
    }

    /// Applies one event, then drains every cascaded event the executed
    /// effects produced. Ordering matters: the v1 commit ladder feeds
    /// `PreparedArrived` and must observe `start_authorized` before the
    /// first `ContentAccepted`.
    async fn feed_now(&mut self, event: Event) {
        self.apply(event).await;
        while let Some(next) = self.queue.pop_front() {
            self.apply(next).await;
        }
    }

    async fn apply(&mut self, event: Event) {
        let name = event.name();
        let now = self.clock.now();
        match self.machine.apply(event, now) {
            Ok((next, effects)) => {
                self.machine = next;
                for effect in effects {
                    self.execute(effect).await;
                }
                self.after_apply();
            }
            Err(err) => {
                // Benign races (late acks, stale timers) are rejected with
                // the machine unchanged; that is expected, not an error.
                tracing::debug!(job = %self.req.job, event = name, %err, "reducer rejected event");
            }
        }
    }

    fn after_apply(&mut self) {
        let now = self.clock.now();
        let phase = self.machine.phase();
        if self.machine.funded_attempt().is_some() || !matches!(phase, Phase::Preparing) {
            self.hedge_at = None;
        }
        if matches!(phase, Phase::AwaitingTerminal { .. }) && self.terminal_wait_at.is_none() {
            self.terminal_wait_at = Some(now.saturating_add(DurationMs::new(
                self.deps.policy.terminal_wait.as_millis() as u64,
            )));
        }
        if !matches!(phase, Phase::Starting { .. }) {
            self.start_retry_at = None;
        }
        if self.outcome.is_some() && !self.machine.is_finished() {
            self.ensure_cancel_backstop();
        }
    }

    /// v1 sessions have no abort/cancel acknowledgement, so once the
    /// consumer has been answered we proactively cancel every open v1
    /// attempt and bound the evidence wait — otherwise a cancelled v1
    /// request would hold its reservation until the total deadline.
    fn ensure_cancel_backstop(&mut self) {
        let open: Vec<AttemptId> = self
            .machine
            .attempts()
            .iter()
            .filter(|a| !a.state.is_closed())
            .map(|a| a.id)
            .collect();
        if open.is_empty() {
            return;
        }
        for id in &open {
            if let Some(runtime) = self.runtimes.get_mut(id) {
                if runtime.protocol == ProtocolGen::V1 && !runtime.cancel_sent {
                    runtime.cancel_sent = true;
                    let frame = runtime.cancel_frame();
                    let _ = runtime.session.submit_control(frame);
                }
            }
        }
        if self.cancel_evidence_at.is_none() {
            self.cancel_evidence_at = Some(self.clock.now().saturating_add(DurationMs::new(
                self.deps.policy.terminal_wait.as_millis() as u64,
            )));
        }
    }

    // ------------------------------------------------------------------
    // Reserve (plan §12.5, step before any provider frame)
    // ------------------------------------------------------------------

    async fn reserve(&mut self) {
        let price = {
            let catalog = self.deps.catalog.load();
            catalog.prices.get(&self.req.concrete_model).copied()
        };
        let Some(price) = price else {
            tracing::warn!(job = %self.req.job, "no price card for concrete model");
            self.feed_now(Event::ReserveFailed).await;
            return;
        };
        let params = reserve_params(&ReserveInputs {
            job: self.req.job,
            account: self.req.account,
            api_key: &self.req.api_key,
            public_model: &self.req.public_model,
            concrete_model: &self.req.concrete_model,
            price: &price,
            estimated_prompt_tokens: self.req.estimated_prompt_tokens,
            requested_max_tokens: self.req.requested_max_tokens,
            spend_cap: self.req.spend_cap,
            first_content_deadline_ms: self.first_content_deadline.get(),
            request_deadline_ms: self.total_deadline.get(),
            coordinator_epoch: self.deps.coordinator_epoch,
        });
        let Some(params) = params else {
            self.feed_now(Event::ReserveFailed).await;
            return;
        };
        match self.deps.ledger.reserve(params).await {
            Ok(_) => self.feed_now(Event::ReserveCommitted).await,
            Err(err) => {
                self.ledger_error = Some(err);
                self.feed_now(Event::ReserveFailed).await;
            }
        }
    }

    // ------------------------------------------------------------------
    // Effect execution (the only place I/O happens)
    // ------------------------------------------------------------------

    async fn execute(&mut self, effect: Effect) {
        match effect {
            Effect::RequestAdmission { exclude } => {
                let exclude: Vec<ProviderId> = exclude.into_iter().collect();
                self.admit(exclude).await;
            }
            Effect::SendPrepare { attempt, provider } => {
                self.dispatch_prepare(attempt, provider).await;
            }
            Effect::ReleasePermit { attempt } => self.release_permit(attempt),
            Effect::AbortLease { attempt, lease } => self.send_abort(attempt, lease),
            Effect::FundAndAuthorize {
                attempt,
                lease,
                facts,
            } => self.fund_and_authorize(attempt, lease, facts).await,
            Effect::SendStart { attempt, lease: _ } => self.send_start(attempt).await,
            Effect::SendCancel { attempt, lease: _ } => self.send_cancel(attempt),
            Effect::DiscardQueuedFrame { attempt } => {
                // The frame is already on the bounded writer lane; there is
                // nothing to unsend. The reducer has closed the attempt, so
                // any late evidence (a prepared lease) is disposed via the
                // late-lease path (plan §9.2.9).
                tracing::debug!(job = %self.req.job, %attempt, "queued frame discarded (attempt closed)");
            }
            Effect::ReturnHedgeOffer { attempt, provider } => {
                if let Some(token) = self.hedge_tokens.remove(&attempt) {
                    if let Ok(mut budget) = self.deps.hedge_budget.lock() {
                        budget.refund(token);
                    }
                }
                self.pending_grants.remove(&attempt);
                if let Some((_, permit)) = self.attempt_permits.remove(&attempt) {
                    let _ = self
                        .deps
                        .fleet
                        .commands
                        .try_send(FleetCommand::ReleasePermit { provider, permit });
                }
            }
            Effect::SettleJob {
                attempt,
                terminal: _,
                accepted_checkpoint,
            } => self.settle(attempt, accepted_checkpoint).await,
            Effect::ReleaseJob => self.release_job().await,
            Effect::EscalateReview { reason } => {
                let reason = format!("{reason:?}");
                self.move_to_review(reason).await;
            }
            Effect::RecordTerminalConflict {
                attempt,
                recorded: _,
                conflicting: _,
            } => {
                // Same attempt, different digest: no money moves; the
                // provider is reported for quarantine (plan §12.8).
                tracing::warn!(job = %self.req.job, %attempt, "terminal digest conflict");
                if let Some(runtime) = self.runtimes.get(&attempt) {
                    let _ = self.deps.fleet.commands.try_send(FleetCommand::Observe(
                        FleetObservation::ProviderFault {
                            provider: runtime.provider,
                            model: darkbloom_core::ids::ModelId::new(&*self.req.concrete_model),
                        },
                    ));
                }
            }
            Effect::CompleteRequest { outcome } => self.complete_request(outcome),
        }
    }

    async fn admit(&mut self, exclude: Vec<ProviderId>) {
        let req = AdmitRequest {
            job: self.req.job,
            model: darkbloom_core::ids::ModelId::new(&*self.req.concrete_model),
            traits: self.request_traits(),
            estimated_prompt_tokens: self.req.estimated_prompt_tokens,
            requested_max_tokens: self.req.requested_max_tokens,
            exclude,
            paid: self.req.paid,
        };
        match self.deps.fleet.admit(req).await {
            Ok(AdmitOutcome::Grant(grant)) => {
                if let Ok(mut budget) = self.deps.hedge_budget.lock() {
                    budget.on_admission();
                }
                let attempt = AttemptId::new(Uuid::new_v4());
                let provider = grant.provider;
                self.attempt_permits
                    .insert(attempt, provider, grant.permit_id);
                self.pending_grants.insert(attempt, grant);
                self.push(Event::AdmitGranted { attempt, provider });
            }
            Ok(AdmitOutcome::RetryAfter { reason, delay }) => {
                tracing::debug!(job = %self.req.job, %reason, "admission retry-after");
                self.push(Event::AdmitFailed {
                    retry_after: Some(DurationMs::new(delay.as_millis() as u64)),
                });
            }
            Ok(AdmitOutcome::Reject(reason)) => {
                tracing::debug!(job = %self.req.job, ?reason, "admission rejected");
                self.push(Event::AdmitFailed { retry_after: None });
            }
            Err(_) => {
                // Fleet mailbox full: shed fast (plan §14).
                self.push(Event::AdmitFailed {
                    retry_after: Some(self.deps.admission_config.saturated_delay),
                });
            }
        }
    }

    fn request_traits(&self) -> darkbloom_core::fleet::admission::RequestTraits {
        darkbloom_core::fleet::admission::RequestTraits {
            model: darkbloom_core::ids::ModelId::new(&*self.req.concrete_model),
            needs_vision: self.req.needs_vision,
            needs_tools: self.req.needs_tools,
            needs_media: false,
            paid: self.req.paid,
            // Rank on a bounded expectation, never the requested maximum
            // (plan §11.4).
            expected_output_tokens: Tokens::new(
                u32::try_from(self.req.requested_max_tokens.min(256)).unwrap_or(256),
            ),
        }
    }

    async fn dispatch_prepare(&mut self, attempt: AttemptId, provider: ProviderId) {
        let Some(grant) = self.pending_grants.remove(&attempt) else {
            self.push(Event::PrepareWriteFailed { attempt });
            return;
        };
        // Grant-carried key: frozen by the fleet from the registration that
        // owns the granted session, so key and session epoch always agree.
        let provider_key = grant.provider_public_key_b64.clone();
        if provider_key.is_empty() {
            tracing::warn!(job = %self.req.job, %provider, "no provider encryption key");
            self.push(Event::PrepareWriteFailed { attempt });
            return;
        }
        let session = grant.session.clone();
        let sealed = match session.protocol {
            ProtocolGen::V1 => AttemptCrypto::seal_v1(&provider_key, &self.req.body),
            ProtocolGen::V2 => AttemptCrypto::seal_v2(
                &provider_key,
                &self.deps.encryption.x25519_secret,
                &self.req.body,
            ),
        };
        let Ok((crypto, sealed)) = sealed else {
            self.push(Event::PrepareWriteFailed { attempt });
            return;
        };
        let scope = new_scope(
            self.req.job,
            attempt,
            session.epoch,
            self.deps.coordinator_epoch,
            sealed.digest,
        );
        let mut runtime = AttemptRuntime::new(attempt, provider, session.clone(), crypto, scope);
        runtime.predicted_first_content =
            DurationMs::new(grant.predicted_first_content.as_millis() as u64);
        runtime.price = grant.price;
        runtime.beneficiary = grant.beneficiary;
        runtime.permit_id = grant.permit_id;
        runtime.dispatched_at = self.clock.now();

        // Attach the sinks BEFORE the frame can reach the wire so no
        // provider reply is lost.
        let (event_tx, event_rx) = mpsc::channel::<AttemptEvent>(64);
        let (chunk_tx, chunk_rx) = crate::contracts::chunk_pipe(
            self.deps.policy.pipe_max_items,
            self.deps.policy.pipe_max_bytes,
        );
        let sinks = AttemptSinks {
            events: event_tx,
            chunks: chunk_tx,
        };
        if session
            .attach_attempt(runtime.wire_id.clone(), attempt, sinks)
            .await
            .is_err()
        {
            self.push(Event::PrepareWriteFailed { attempt });
            return;
        }
        self.spawn_attempt_pump(attempt, event_rx, chunk_rx);

        let now = self.clock.now();
        let frame = match session.protocol {
            ProtocolGen::V1 => Some(runtime.v1_inference_request(&sealed)),
            ProtocolGen::V2 => {
                let budget_ms = now.saturating_until(self.first_content_deadline).get();
                runtime
                    .v2_prepare_frame(
                        &self.req.concrete_model,
                        self.req.requested_max_tokens,
                        budget_ms,
                        &sealed,
                    )
                    .ok()
            }
        };
        let Some(frame) = frame else {
            self.push(Event::PrepareWriteFailed { attempt });
            return;
        };
        match session.submit_data(frame) {
            Ok(on_wire) => self.spawn_wire_pump(attempt, WireKind::Prepare, on_wire),
            Err(err) => {
                tracing::debug!(job = %self.req.job, %attempt, %err, "prepare submit failed");
                self.push(Event::PrepareWriteFailed { attempt });
                return;
            }
        }
        if session.protocol == ProtocolGen::V2 {
            // v2 prepare evidence is bounded by the prepare deadline; a v1
            // attempt's evidence is its first chunk, bounded by the shared
            // absolute first-content deadline instead.
            runtime.prepare_deadline_at = Some(now.saturating_add(DurationMs::new(
                self.deps.policy.prepare_deadline.as_millis() as u64,
            )));
            // Arm the prepare-latency hedge for the primary only
            // (plan §11.8). v1 dispatch generates immediately, so hedging a
            // v1 attempt would race two generations — never armed.
            if self.deps.policy.hedge_enabled
                && !self.hedge_fired
                && self.hedge_at.is_none()
                && self.runtimes.is_empty()
            {
                self.hedge_at = Some(now.saturating_add(DurationMs::new(
                    self.deps.policy.hedge_prepare_timeout.as_millis() as u64,
                )));
            }
        }
        self.runtimes.insert(attempt, runtime);
    }

    /// Echoes the fleet-minted permit id back (plan §9.2.10). The reducer
    /// emits the release effect exactly once per attempt, so removal here
    /// cannot orphan a live permit.
    fn release_permit(&mut self, attempt: AttemptId) {
        self.pending_grants.remove(&attempt);
        let Some((provider, permit)) = self.attempt_permits.remove(&attempt) else {
            return;
        };
        let _ = self
            .deps
            .fleet
            .commands
            .try_send(FleetCommand::ReleasePermit { provider, permit });
    }

    fn abort_reason(&self, attempt: AttemptId) -> AbortReason {
        if self.consumer_gone {
            AbortReason::ClientGone
        } else if matches!(self.outcome, Some(RequestOutcome::FundingFailed)) {
            AbortReason::FundingFailed
        } else if self
            .machine
            .funded_attempt()
            .is_some_and(|funded| funded != attempt)
        {
            AbortReason::HedgeLoss
        } else {
            AbortReason::DeadlineUnreachable
        }
    }

    fn send_abort(&mut self, attempt: AttemptId, _lease: LeaseId) {
        let reason = self.abort_reason(attempt);
        let Some(runtime) = self.runtimes.get_mut(&attempt) else {
            return;
        };
        runtime.cancel_sent = true;
        let frame = runtime.abort_frame(reason);
        let session = runtime.session.clone();
        let is_v1 = runtime.protocol == ProtocolGen::V1;
        match session.submit_control(frame) {
            Ok(on_wire) => self.spawn_wire_pump(attempt, WireKind::Abort, on_wire),
            Err(_) => {
                // A full/closed control lane is session-fencing evidence
                // (plan §9.4.3): treat as session loss for this attempt.
                self.push(Event::SessionLost { attempt });
                return;
            }
        }
        if is_v1 && self.cancel_evidence_at.is_none() {
            // v1 has no abort ack; bound the evidence wait.
            self.cancel_evidence_at = Some(self.clock.now().saturating_add(DurationMs::new(
                self.deps.policy.terminal_wait.as_millis() as u64,
            )));
        }
    }

    /// Funding leg (plan §12.5): the resize/freeze transaction with terms
    /// frozen from the grant's price card. v2 funds the prepared exact
    /// billable input; v1 funds the reserve-estimate facts — the hold is
    /// numerically unchanged (same rounding, same inputs as the reserve),
    /// but the leg still runs because it is what freezes terms and records
    /// the durable `start_authorized` transition the running/settlement
    /// states require (see the module-docs v1 mapping).
    async fn fund_and_authorize(
        &mut self,
        attempt: AttemptId,
        lease: LeaseId,
        facts: PreparedFacts,
    ) {
        let Some(runtime) = self.runtimes.get(&attempt) else {
            self.push(Event::FundFailed { attempt });
            return;
        };
        let catalog_version = self.deps.catalog.load().version;
        let params = resize_freeze_params(&FreezeInputs {
            job: self.req.job,
            attempt,
            lease,
            provider: runtime.provider,
            account: self.req.account,
            api_key: &self.req.api_key,
            public_model: &self.req.public_model,
            concrete_model: &self.req.concrete_model,
            price: &runtime.price,
            beneficiary: runtime.beneficiary,
            catalog_version,
            facts,
            provider_payout_ppm: self.deps.policy.provider_payout_ppm,
            session_epoch: SessionEpoch::new(runtime.scope.session_epoch.0),
            dispatch_nonce: runtime.scope.dispatch_nonce.0,
            request_digest: runtime.scope.request_digest.0,
            coordinator_epoch: self.deps.coordinator_epoch,
        });
        let Some(params) = params else {
            self.push(Event::FundFailed { attempt });
            return;
        };
        match self.deps.ledger.resize_freeze(params).await {
            Ok(()) => self.push(Event::FundAuthorized { attempt }),
            Err(err) => {
                self.ledger_error = Some(err);
                self.push(Event::FundFailed { attempt });
            }
        }
    }

    async fn send_start(&mut self, attempt: AttemptId) {
        let Some(runtime) = self.runtimes.get(&attempt) else {
            return;
        };
        if runtime.protocol == ProtocolGen::V1 {
            // v1 has no start frame: the inference_request was the start,
            // and the content already in hand proves emission. The reducer
            // still owns the transition.
            self.mark_running().await;
            self.push(Event::StartedAck { attempt });
            return;
        }
        let frame = runtime.start_frame();
        match runtime.session.submit_control(frame) {
            Ok(on_wire) => {
                self.spawn_wire_pump(attempt, WireKind::Start, on_wire);
                self.start_retry_at = Some(self.clock.now().saturating_add(START_RETRY_INTERVAL));
            }
            Err(_) => self.push(Event::SessionLost { attempt }),
        }
    }

    fn send_cancel(&mut self, attempt: AttemptId) {
        let Some(runtime) = self.runtimes.get_mut(&attempt) else {
            return;
        };
        runtime.cancel_sent = true;
        let frame = runtime.cancel_frame();
        let session = runtime.session.clone();
        match session.submit_control(frame) {
            Ok(on_wire) => self.spawn_wire_pump(attempt, WireKind::Cancel, on_wire),
            Err(_) => self.push(Event::SessionLost { attempt }),
        }
    }

    async fn mark_running(&mut self) {
        if self.mark_running_done {
            return;
        }
        self.mark_running_done = true;
        if let Err(err) = self.deps.ledger.mark_running(self.req.job).await {
            tracing::warn!(job = %self.req.job, %err, "mark_running failed");
        }
    }

    async fn settle(&mut self, attempt: AttemptId, accepted_checkpoint: Tokens) {
        let Some(runtime) = self.runtimes.get(&attempt) else {
            self.fatal = true;
            return;
        };
        let Some(receipt) = &runtime.receipt else {
            self.fatal = true;
            return;
        };
        // v2 terminals carry the epoch the attempt RAN under; v1 has no
        // origin field, so the dispatch session is the origin (plan §9.1.3).
        let origin_session_epoch = match receipt {
            crate::request_task::terminal::TerminalReceipt::V2 { frame, .. } => {
                SessionEpoch::new(frame.origin_session_epoch.0)
            }
            _ => runtime.session.epoch,
        };
        // v1 prompt billing basis is the frozen estimate (module docs): the
        // provider's self-reported count is receipt/audit material only.
        let frozen_prompt_override = (runtime.protocol == ProtocolGen::V1)
            .then(|| clamp_tokens(self.req.estimated_prompt_tokens));
        let params = settle_params(&crate::request_task::terminal::SettleInputs {
            job: self.req.job,
            attempt,
            receipt,
            accepted_sequence: runtime.accepted_sequence,
            accepted_checkpoint,
            frozen_prompt_override,
            origin_session_epoch,
            coordinator_epoch: self.deps.coordinator_epoch,
        });
        let usage = receipt.usage_out();
        let ack =
            if let crate::request_task::terminal::TerminalReceipt::V2 { frame, digest } = receipt {
                Some((frame.scope, *digest))
            } else {
                None
            };
        match self.deps.ledger.settle(params).await {
            Ok(_) => {
                self.usage_out = Some(usage);
                // ACK only after the durable disposition commit (plan §12.8).
                if let (Some((scope, digest)), Some(runtime)) = (ack, self.runtimes.get(&attempt)) {
                    let frame = runtime.terminal_ack_frame(scope, digest, AckDisposition::Recorded);
                    if runtime.session.submit_control(frame).is_err() {
                        tracing::debug!(job = %self.req.job, "terminal ack submit failed; provider will replay");
                    }
                }
                self.push(Event::SettlementRecorded);
            }
            Err(err) => {
                tracing::warn!(job = %self.req.job, %err, "settlement failed; escalating to review");
                self.ledger_error = Some(err);
                self.move_to_review("settlement_failed".to_owned()).await;
            }
        }
    }

    async fn release_job(&mut self) {
        let reason = self
            .outcome
            .map(|o| format!("{o:?}"))
            .unwrap_or_else(|| "released".to_owned());
        let params = release_params(self.req.job, &reason, self.deps.coordinator_epoch);
        match self.deps.ledger.release(params).await {
            Ok(()) => self.push(Event::ReleaseRecorded),
            Err(err) => {
                tracing::warn!(job = %self.req.job, %err, "release failed; escalating to review");
                self.ledger_error = Some(err);
                self.move_to_review("release_failed".to_owned()).await;
            }
        }
    }

    async fn move_to_review(&mut self, reason: String) {
        match self.deps.ledger.move_to_review(self.req.job, reason).await {
            Ok(()) => self.push(Event::ReviewRecorded),
            Err(err) => {
                // Every durable path failed: leave the reservation held for
                // the recovery sweepers (plan §18.1) and stop the task.
                tracing::error!(job = %self.req.job, %err, "review escalation failed; leaving job to recovery");
                self.fatal = true;
            }
        }
    }

    fn complete_request(&mut self, outcome: RequestOutcome) {
        self.outcome = Some(outcome);
        if self.machine.committed_attempt().is_none() {
            // Pre-content: the HTTP adapter maps the report; nothing was
            // written to the consumer (invisible failover, plan §7.8).
            return;
        }
        let event = match outcome {
            RequestOutcome::Completed => Some(ConsumerEvent::Completed(
                self.usage_out.clone().unwrap_or_default(),
            )),
            RequestOutcome::ProviderError { .. } => Some(ConsumerEvent::Failed {
                message: "provider error".to_owned(),
                error_type: "provider_error".to_owned(),
            }),
            RequestOutcome::ProviderLost => Some(ConsumerEvent::Failed {
                message: "provider ended without completion".to_owned(),
                error_type: "provider_error".to_owned(),
            }),
            RequestOutcome::DeadlineExceeded => Some(ConsumerEvent::Failed {
                message: "request timed out".to_owned(),
                error_type: "timeout".to_owned(),
            }),
            RequestOutcome::ConsumerBackpressure => Some(ConsumerEvent::Failed {
                message: "client too slow to consume stream".to_owned(),
                error_type: "consumer_backpressure".to_owned(),
            }),
            // The consumer is gone; there is nobody to answer.
            RequestOutcome::Cancelled => None,
            _ => None,
        };
        if let Some(event) = event {
            let _ = self.req.consumer.try_send(event);
        }
    }

    // ------------------------------------------------------------------
    // Provider event mapping
    // ------------------------------------------------------------------

    async fn on_attempt_event(&mut self, attempt: AttemptId, event: AttemptEvent) {
        match event {
            AttemptEvent::Prepared {
                lease,
                ttl,
                billable_prompt_tokens,
                queue_depth: _,
                prefill_can_start: _,
                frame,
            } => {
                // Provider-quoted input must stay within the coordinator's
                // request-shape upper bound (plan §12.5): bytes bound tokens
                // for every BPE tokenizer.
                if billable_prompt_tokens > self.req.body.len() as u64 {
                    self.quote_violation(attempt, lease).await;
                    return;
                }
                let now = self.clock.now();
                let predicted = self
                    .runtimes
                    .get(&attempt)
                    .map(|r| r.predicted_first_content)
                    .unwrap_or(DurationMs::new(0));
                if let Some(runtime) = self.runtimes.get_mut(&attempt) {
                    runtime.record_lease(lease);
                    runtime.prepare_deadline_at = None;
                    runtime.lease_expiry_at =
                        Some(now.saturating_add(DurationMs::new(ttl.as_millis() as u64)));
                }
                let eta = frame
                    .execution
                    .predicted_first_content_ms
                    .map(DurationMs::new)
                    .unwrap_or(predicted);
                let facts = PreparedFacts {
                    first_content_eta: eta,
                    billable_input_tokens: clamp_tokens(billable_prompt_tokens),
                    max_output_tokens: clamp_tokens(self.req.requested_max_tokens),
                };
                self.feed_now(Event::PreparedArrived {
                    attempt,
                    lease,
                    facts,
                    hedge_offer: None,
                })
                .await;
            }
            AttemptEvent::Started => {
                if let Some(runtime) = self.runtimes.get_mut(&attempt) {
                    runtime.lease_expiry_at = None;
                }
                self.mark_running().await;
                self.arm_idle_timer();
                self.feed_now(Event::StartedAck { attempt }).await;
            }
            AttemptEvent::Aborted { reason: _ } => {
                self.feed_now(Event::AbortAcked { attempt }).await;
            }
            AttemptEvent::Cancelled => {
                self.feed_now(Event::CancelAcked { attempt }).await;
            }
            AttemptEvent::Terminal(frame) => {
                // v2 has no dedicated prepare-rejection frame: a terminal
                // with `outcome=failed` arriving BEFORE a prepared lease IS
                // the rejection vehicle (plan §10.5). Map it to the typed
                // rejection so class semantics hold (capacity/draining take
                // the sequential alternate; invalid_request/security fail
                // deterministically) and the fleet observes it (plan §11.3
                // advisory invalidation, §11.6 health).
                if self.attempt_awaiting_prepare(attempt) {
                    if let darkbloom_protocol::json_v2::TerminalOutcome::Failed = frame.outcome {
                        let class = frame
                            .error_class
                            .unwrap_or(darkbloom_protocol::json_v2::ErrorClass::Fault);
                        self.observe_prepare_rejected(attempt, class);
                        self.feed_now(Event::PrepareRejected {
                            attempt,
                            class: core_error_class(class),
                        })
                        .await;
                        return;
                    }
                }
                let Some((receipt, summary)) = v2_receipt(frame) else {
                    tracing::warn!(job = %self.req.job, %attempt, "structurally invalid terminal dropped");
                    self.observe_fault(attempt);
                    return;
                };
                if let Some(runtime) = self.runtimes.get_mut(&attempt) {
                    runtime.receipt = Some(receipt);
                    runtime.lease_expiry_at = None;
                }
                self.feed_now(Event::TerminalArrived {
                    attempt,
                    terminal: summary,
                })
                .await;
            }
            AttemptEvent::AcceptedV1 => {
                // Liveness only; v1 commitment is first content (Go parity).
            }
            AttemptEvent::CompleteV1 {
                usage,
                se_signature,
                response_hash,
            } => {
                self.on_v1_complete(attempt, usage, se_signature, response_hash)
                    .await
            }
            AttemptEvent::ErrorV1 {
                status_code,
                message,
            } => self.on_v1_error(attempt, status_code, message).await,
            AttemptEvent::SessionLost => {
                self.feed_now(Event::SessionLost { attempt }).await;
            }
            AttemptEvent::PipeOverflow => {
                if !self.pipe_stalled {
                    self.pipe_stalled = true;
                    self.feed_now(Event::ConsumerPipeStalled).await;
                }
            }
        }
    }

    /// Out-of-bound prepared quote: abort the lease, fail the attempt as a
    /// security rejection, fence the provider (plan §12.5).
    async fn quote_violation(&mut self, attempt: AttemptId, lease: LeaseId) {
        if let Some(runtime) = self.runtimes.get_mut(&attempt) {
            runtime.record_lease(lease);
            let frame = runtime.abort_frame(AbortReason::DeadlineUnreachable);
            let _ = runtime.session.submit_control(frame);
            let provider = runtime.provider;
            let _ = self.deps.fleet.commands.try_send(FleetCommand::Observe(
                FleetObservation::SecurityFence { provider },
            ));
        }
        self.feed_now(Event::PrepareRejected {
            attempt,
            class: darkbloom_core::provider_error::ProviderErrorClass::Security,
        })
        .await;
    }

    async fn on_v1_complete(
        &mut self,
        attempt: AttemptId,
        usage: Option<UsageInfo>,
        se_signature: Option<String>,
        response_hash: Option<String>,
    ) {
        if self.machine.committed_attempt() == Some(attempt) {
            // Checkpoint promotion: every chunk preceding this terminal was
            // accepted into the consumer pipe in order, so the terminal's
            // claimed completion count is itself accepted output. Not
            // promoted under cancellation or backpressure — there the
            // chunk-count checkpoint caps the partial settle (plan §13.5,
            // §13.6).
            if !self.consumer_gone && !self.pipe_stalled {
                if let Some(u) = usage {
                    let cumulative = clamp_tokens(u.completion_tokens.max(0) as u64);
                    self.feed_now(Event::ContentAccepted {
                        attempt,
                        cumulative_tokens: cumulative,
                    })
                    .await;
                }
            }
            let (receipt, summary) =
                v1_complete_receipt(self.req.job, attempt, usage, se_signature, response_hash);
            if let Some(runtime) = self.runtimes.get_mut(&attempt) {
                runtime.receipt = Some(receipt);
            }
            self.feed_now(Event::TerminalArrived {
                attempt,
                terminal: summary,
            })
            .await;
            return;
        }
        // Complete before any content: zero-output stream. Mirrors the Go
        // "provider ended without completion" pre-commit failover.
        self.feed_now(Event::PrepareRejected {
            attempt,
            class: darkbloom_core::provider_error::ProviderErrorClass::Fault,
        })
        .await;
    }

    async fn on_v1_error(&mut self, attempt: AttemptId, status_code: u16, message: String) {
        let class = classify_v1_error(status_code, &message);
        self.observe_fault(attempt);
        if self.machine.committed_attempt() == Some(attempt) {
            let (receipt, summary) = v1_error_receipt(self.req.job, attempt, status_code, class);
            if let Some(runtime) = self.runtimes.get_mut(&attempt) {
                runtime.receipt = Some(receipt);
            }
            self.feed_now(Event::TerminalArrived {
                attempt,
                terminal: summary,
            })
            .await;
            return;
        }
        self.feed_now(Event::PrepareRejected { attempt, class })
            .await;
    }

    fn observe_fault(&mut self, attempt: AttemptId) {
        if let Some(runtime) = self.runtimes.get(&attempt) {
            let _ = self.deps.fleet.commands.try_send(FleetCommand::Observe(
                FleetObservation::ProviderFault {
                    provider: runtime.provider,
                    model: darkbloom_core::ids::ModelId::new(&*self.req.concrete_model),
                },
            ));
        }
    }

    /// True while the attempt has produced no prepared lease and no closure
    /// evidence — the window in which a failed terminal is a prepare
    /// rejection, not a run disposition.
    fn attempt_awaiting_prepare(&self, attempt: AttemptId) -> bool {
        self.machine.attempts().iter().any(|a| {
            a.id == attempt
                && matches!(
                    a.state,
                    AttemptState::QueuedToSocket | AttemptState::SentUnknown
                )
        })
    }

    /// Reports a structured prepare rejection to the fleet (plan §11.6;
    /// capacity classes also invalidate the provider's advisory capacity
    /// until fresh heartbeat state arrives, plan §11.3).
    fn observe_prepare_rejected(
        &mut self,
        attempt: AttemptId,
        class: darkbloom_protocol::json_v2::ErrorClass,
    ) {
        if let Some(runtime) = self.runtimes.get(&attempt) {
            let _ = self.deps.fleet.commands.try_send(FleetCommand::Observe(
                FleetObservation::PrepareRejected {
                    provider: runtime.provider,
                    model: darkbloom_core::ids::ModelId::new(&*self.req.concrete_model),
                    class,
                },
            ));
        }
    }

    // ------------------------------------------------------------------
    // Chunk handling (first-content commitment, plan §9.2.7, §10.6)
    // ------------------------------------------------------------------

    async fn on_chunk(&mut self, attempt: AttemptId, frame: ChunkFrame) {
        let Some(runtime) = self.runtimes.get(&attempt) else {
            return;
        };
        if self
            .machine
            .attempts()
            .iter()
            .find(|a| a.id == attempt)
            .is_none_or(|a| a.state.is_closed())
        {
            return;
        }
        let Some(plaintext) = runtime.crypto.open_chunk(&frame.payload) else {
            // Never log ciphertext or plaintext; lengths and ids only.
            tracing::warn!(job = %self.req.job, %attempt, len = frame.payload.len(), "chunk decrypt failed; dropped");
            return;
        };
        // Zero-copy strip: the bare payload is a subslice of the plaintext.
        let bare = plaintext.slice_ref(strip_sse_prefix(&plaintext));
        match classify(&bare) {
            ChunkClass::Done | ChunkClass::UsageOnly => {
                // Swallowed: the coordinator appends its own final usage
                // chunk and exactly one [DONE] (Go parity).
                self.arm_idle_timer();
            }
            ChunkClass::Preamble => {
                if let Some(runtime) = self.runtimes.get_mut(&attempt) {
                    runtime.held_preamble.push(bare);
                }
                self.feed_now(Event::PreambleAccepted { attempt }).await;
            }
            ChunkClass::Content => self.on_content_chunk(attempt, frame, bare).await,
        }
    }

    async fn on_content_chunk(&mut self, attempt: AttemptId, frame: ChunkFrame, bare: Bytes) {
        let is_v1 = self
            .runtimes
            .get(&attempt)
            .is_some_and(|r| r.protocol == ProtocolGen::V1);
        // v1 commit ladder: first content synthesizes the prepared → funded
        // → started sequence THROUGH the reducer (see module docs).
        if is_v1
            && self.machine.funded_attempt().is_none()
            && self.outcome.is_none()
            && self.machine.committed_attempt().is_none()
        {
            let lease = LeaseId::new(Uuid::new_v4());
            let facts = PreparedFacts {
                first_content_eta: DurationMs::ZERO,
                billable_input_tokens: clamp_tokens(self.req.estimated_prompt_tokens),
                max_output_tokens: clamp_tokens(self.req.requested_max_tokens),
            };
            self.feed_now(Event::PreparedArrived {
                attempt,
                lease,
                facts,
                hedge_offer: None,
            })
            .await;
        }
        if self.machine.funded_attempt() != Some(attempt) || !self.machine.is_start_authorized() {
            // Emission without start authorization is a protocol violation
            // (plan §22.3): fence, never forward, never bill.
            if !is_v1 {
                if let Some(runtime) = self.runtimes.get(&attempt) {
                    let _ = self.deps.fleet.commands.try_send(FleetCommand::Observe(
                        FleetObservation::SecurityFence {
                            provider: runtime.provider,
                        },
                    ));
                }
            }
            return;
        }
        let first_commit = self.machine.committed_attempt().is_none();
        let cumulative = if is_v1 {
            let count = self
                .runtimes
                .get(&attempt)
                .map(|r| r.content_chunks + 1)
                .unwrap_or(1);
            clamp_tokens(count)
        } else {
            clamp_tokens(frame.cumulative_tokens)
        };
        self.feed_now(Event::ContentAccepted {
            attempt,
            cumulative_tokens: cumulative,
        })
        .await;
        if self.machine.committed_attempt() != Some(attempt) {
            return; // a raced cancel refused the commit
        }
        if first_commit {
            self.observe_first_content(attempt);
        }
        let mut to_forward: Vec<Bytes> = Vec::new();
        if let Some(runtime) = self.runtimes.get_mut(&attempt) {
            runtime.content_chunks += 1;
            runtime.accepted_sequence = frame.sequence;
            to_forward.append(&mut runtime.held_preamble);
        }
        to_forward.push(bare);
        for chunk in to_forward {
            if !self.forward_chunk(chunk).await {
                break;
            }
        }
        self.arm_idle_timer();
    }

    fn observe_first_content(&mut self, attempt: AttemptId) {
        let Some(runtime) = self.runtimes.get(&attempt) else {
            return;
        };
        let actual = self.clock.now().saturating_since(runtime.dispatched_at);
        let _ = self.deps.fleet.commands.try_send(FleetCommand::Observe(
            FleetObservation::FirstContent {
                provider: runtime.provider,
                model: darkbloom_core::ids::ModelId::new(&*self.req.concrete_model),
                predicted: std::time::Duration::from_millis(runtime.predicted_first_content.get()),
                actual: std::time::Duration::from_millis(actual.get()),
            },
        ));
    }

    /// Forwards one committed chunk to the consumer. Returns false when the
    /// consumer is gone/stalled (the reducer takes over via the fed event).
    async fn forward_chunk(&mut self, chunk: Bytes) -> bool {
        let rewritten =
            rewrite_chunk_model(chunk, &self.req.concrete_model, &self.req.public_model);
        match self.req.consumer.try_send(ConsumerEvent::Chunk(rewritten)) {
            Ok(()) => true,
            Err(mpsc::error::TrySendError::Full(_)) => {
                // Bounded consumer channel full past the pipe grace window:
                // 13.6 — cancel the provider, fail the request, never drop
                // silently.
                if !self.pipe_stalled {
                    self.pipe_stalled = true;
                    self.feed_now(Event::ConsumerPipeStalled).await;
                }
                false
            }
            Err(mpsc::error::TrySendError::Closed(_)) => {
                if !self.consumer_gone {
                    self.on_consumer_gone().await;
                }
                false
            }
        }
    }

    async fn on_consumer_gone(&mut self) {
        self.consumer_gone = true;
        self.feed_now(Event::ConsumerCancelled).await;
    }

    // ------------------------------------------------------------------
    // Wire results
    // ------------------------------------------------------------------

    async fn on_wire(&mut self, attempt: AttemptId, kind: WireKind, result: WireOutcome) {
        let event = match (kind, result) {
            (WireKind::Prepare, WireOutcome::Confirmed) => {
                Some(Event::PrepareWriteConfirmed { attempt })
            }
            (WireKind::Prepare, WireOutcome::Failed) => Some(Event::PrepareWriteFailed { attempt }),
            (WireKind::Prepare, WireOutcome::Ambiguous) => {
                Some(Event::PrepareWriteUnknown { attempt })
            }
            (WireKind::Start, WireOutcome::Ambiguous) => Some(Event::StartWriteUnknown { attempt }),
            (WireKind::Start, WireOutcome::Failed) => Some(Event::SessionLost { attempt }),
            (WireKind::Abort | WireKind::Cancel, WireOutcome::Failed) => {
                Some(Event::SessionLost { attempt })
            }
            // Confirmed control writes and ambiguous abort/cancel resolve
            // through acks, terminals, or the evidence timers.
            _ => None,
        };
        if let Some(event) = event {
            self.feed_now(event).await;
        }
    }

    // ------------------------------------------------------------------
    // Timers
    // ------------------------------------------------------------------

    fn next_timer(&self) -> Option<(TimestampMs, TimerKind)> {
        let mut best: Option<(TimestampMs, TimerKind)> = None;
        let mut consider = |at: Option<TimestampMs>, kind: TimerKind| {
            if let Some(at) = at {
                if best.is_none_or(|(b, _)| at < b) {
                    best = Some((at, kind));
                }
            }
        };
        if !self.first_content_fired && self.machine.committed_attempt().is_none() {
            consider(Some(self.first_content_deadline), TimerKind::FirstContent);
        }
        if !self.total_fired {
            consider(Some(self.total_deadline), TimerKind::Total);
        }
        consider(self.hedge_at, TimerKind::Hedge);
        for (id, runtime) in &self.runtimes {
            consider(runtime.prepare_deadline_at, TimerKind::PrepareDeadline(*id));
            consider(runtime.lease_expiry_at, TimerKind::LeaseExpiry(*id));
        }
        if matches!(self.machine.phase(), Phase::Starting { .. }) {
            consider(self.start_retry_at, TimerKind::StartRetry);
        }
        consider(self.terminal_wait_at, TimerKind::TerminalWait);
        consider(self.cancel_evidence_at, TimerKind::CancelEvidence);
        if matches!(
            self.machine.phase(),
            Phase::AwaitingContent { .. } | Phase::Streaming { .. }
        ) {
            consider(self.idle_at, TimerKind::StreamIdle);
        }
        best
    }

    fn arm_idle_timer(&mut self) {
        self.idle_at = Some(self.clock.now().saturating_add(DurationMs::new(
            self.deps.policy.stream_idle_timeout.as_millis() as u64,
        )));
    }

    async fn on_timer(&mut self, kind: TimerKind) {
        match kind {
            TimerKind::FirstContent => {
                self.first_content_fired = true;
                self.feed_now(Event::FirstContentDeadlineElapsed).await;
            }
            TimerKind::Total => {
                self.total_fired = true;
                self.feed_now(Event::TotalDeadlineElapsed).await;
            }
            TimerKind::Hedge => {
                self.hedge_at = None;
                self.hedge_fired = true;
                self.fire_hedge().await;
            }
            TimerKind::PrepareDeadline(attempt) => {
                if let Some(runtime) = self.runtimes.get_mut(&attempt) {
                    runtime.prepare_deadline_at = None;
                }
                self.feed_now(Event::AttemptTimedOut { attempt }).await;
            }
            TimerKind::LeaseExpiry(attempt) => {
                if let Some(runtime) = self.runtimes.get_mut(&attempt) {
                    runtime.lease_expiry_at = None;
                }
                self.feed_now(Event::AttemptTimedOut { attempt }).await;
            }
            TimerKind::StartRetry => {
                self.start_retry_at = None;
                self.feed_now(Event::StartRetryTimerFired).await;
            }
            TimerKind::TerminalWait => {
                self.terminal_wait_at = None;
                self.feed_now(Event::TerminalWaitElapsed).await;
            }
            TimerKind::CancelEvidence => {
                self.cancel_evidence_at = None;
                let open: Vec<AttemptId> = self
                    .machine
                    .attempts()
                    .iter()
                    .filter(|a| !a.state.is_closed())
                    .map(|a| a.id)
                    .collect();
                for attempt in open {
                    self.feed_now(Event::AttemptTimedOut { attempt }).await;
                }
            }
            TimerKind::StreamIdle => {
                self.idle_at = None;
                if let Some(funded) = self.machine.funded_attempt() {
                    self.feed_now(Event::AttemptTimedOut { attempt: funded })
                        .await;
                }
            }
        }
    }

    /// The prepare-latency hedge trigger (plan §11.8): acquire a token from
    /// the global bounded budget, admit one alternate with the exclusion
    /// set, and hand the pre-authorized offer to the reducer — which either
    /// consumes it (SendPrepare) or returns it (ReturnHedgeOffer).
    async fn fire_hedge(&mut self) {
        if !matches!(self.machine.phase(), Phase::Preparing)
            || self.machine.funded_attempt().is_some()
        {
            self.feed_now(Event::HedgeTimerFired { offer: None }).await;
            return;
        }
        let token = match self.deps.hedge_budget.lock() {
            Ok(mut budget) => budget.try_acquire(),
            Err(_) => None,
        };
        let Some(token) = token else {
            // Budget exhausted: degrade to sequential-alternate behavior.
            self.feed_now(Event::HedgeTimerFired { offer: None }).await;
            return;
        };
        let exclude: Vec<ProviderId> = self.machine.attempts().iter().map(|a| a.provider).collect();
        let req = AdmitRequest {
            job: self.req.job,
            model: darkbloom_core::ids::ModelId::new(&*self.req.concrete_model),
            traits: self.request_traits(),
            estimated_prompt_tokens: self.req.estimated_prompt_tokens,
            requested_max_tokens: self.req.requested_max_tokens,
            exclude,
            paid: self.req.paid,
        };
        let offer = match self.deps.fleet.admit(req).await {
            Ok(AdmitOutcome::Grant(grant)) => {
                let attempt = AttemptId::new(Uuid::new_v4());
                let provider = grant.provider;
                self.attempt_permits
                    .insert(attempt, provider, grant.permit_id);
                self.pending_grants.insert(attempt, grant);
                self.hedge_tokens.insert(attempt, token);
                Some(HedgeOffer { attempt, provider })
            }
            _ => {
                if let Ok(mut budget) = self.deps.hedge_budget.lock() {
                    budget.refund(token);
                }
                None
            }
        };
        self.feed_now(Event::HedgeTimerFired { offer }).await;
    }

    // ------------------------------------------------------------------
    // Pumps (owned by the driver's JoinSet; aborted on drop)
    // ------------------------------------------------------------------

    /// One combined pump per attempt, biased toward the chunk pipe: the
    /// session enqueues a chunk into the pipe (synchronously) BEFORE it
    /// sends a subsequent control event, so draining chunks first preserves
    /// wire order — a terminal can never overtake the accepted chunks that
    /// precede it (the settlement checkpoint depends on this, plan §10.6).
    fn spawn_attempt_pump(
        &mut self,
        attempt: AttemptId,
        mut event_rx: mpsc::Receiver<AttemptEvent>,
        mut chunk_rx: crate::contracts::ChunkReceiver,
    ) {
        let tx = self.inputs_tx.clone();
        self.pumps.spawn(async move {
            let mut events_open = true;
            loop {
                tokio::select! {
                    biased;
                    chunk = chunk_rx.recv() => match chunk {
                        Some(frame) => {
                            if tx.send(TaskInput::Chunk(attempt, frame)).await.is_err() {
                                return;
                            }
                        }
                        // Chunk sender dropped: keep serving events.
                        None => {
                            while let Some(event) = event_rx.recv().await {
                                if tx.send(TaskInput::Attempt(attempt, event)).await.is_err() {
                                    return;
                                }
                            }
                            return;
                        }
                    },
                    event = event_rx.recv(), if events_open => match event {
                        Some(event) => {
                            if tx.send(TaskInput::Attempt(attempt, event)).await.is_err() {
                                return;
                            }
                        }
                        None => events_open = false,
                    },
                }
            }
        });
    }

    fn spawn_wire_pump(&mut self, attempt: AttemptId, kind: WireKind, on_wire: OnWire) {
        let tx = self.inputs_tx.clone();
        self.pumps.spawn(async move {
            let result = match on_wire.await {
                Ok(Ok(())) => WireOutcome::Confirmed,
                Ok(Err(WriteError::SessionClosed)) => WireOutcome::Failed,
                Ok(Err(WriteError::Ambiguous)) => WireOutcome::Ambiguous,
                // The session dropped the completion without reporting: the
                // write outcome is unknowable (plan §13.2).
                Err(_) => WireOutcome::Ambiguous,
            };
            let _ = tx
                .send(TaskInput::Wire {
                    attempt,
                    kind,
                    result,
                })
                .await;
        });
    }

    async fn teardown(&mut self) {
        self.pumps.abort_all();
        for runtime in self.runtimes.values() {
            let _ = runtime
                .session
                .detach_attempt(runtime.wire_id.clone())
                .await;
        }
        // Unused hedge grants/tokens cannot leak budget; tokens consumed by
        // a real dispatch stay spent.
        let leftover: Vec<(AttemptId, HedgeToken)> = self.hedge_tokens.drain().collect();
        for (attempt, token) in leftover {
            if self.runtimes.contains_key(&attempt) {
                continue;
            }
            if let Ok(mut budget) = self.deps.hedge_budget.lock() {
                budget.refund(token);
            }
        }
        // Any permit whose release effect never fired (fatal teardown) is
        // released now instead of waiting for hard expiry; release is
        // idempotent (plan §9.2.10). The PermitLedger Drop backstop covers
        // the dropped-future path where teardown never runs.
        self.attempt_permits.release_all();
    }
}
