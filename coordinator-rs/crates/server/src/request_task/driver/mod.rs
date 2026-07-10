//! The per-request async driver around the pure core reducer
//! (`darkbloom_core::request`, plan §7.2).
//!
//! The reducer owns every lifecycle decision; this driver only:
//!
//! 1. delivers observations (ledger results, fleet decisions, provider
//!    frames, timers, consumer signals) as [`Event`]s, and
//! 2. executes the returned [`Effect`](darkbloom_core::request::Effect)s
//!    (send frames, run transactions, release permits, answer the consumer).
//!
//! No lifecycle transition is decided here (plan §19.3). All I/O helpers are
//! bounded; the pump tasks live in a [`JoinSet`] aborted when the driver
//! drops, so nothing detaches from the task's scope.
//!
//! This file owns the driver state and the main select loop; the sibling
//! modules own one concern each: [`effects`] (effect dispatch), [`dispatch`]
//! (admission/prepare/funding), [`events`] (provider event mapping),
//! [`chunks`] (first-content commitment), [`timers`], [`hedge`],
//! [`settlement`], [`cancel`], [`pumps`], and [`permits`].

mod cancel;
mod chunks;
mod dispatch;
mod effects;
mod events;
mod hedge;
mod permits;
mod pumps;
mod settlement;
mod timers;

use std::collections::{HashMap, VecDeque};

use tokio::sync::mpsc;
use tokio::task::JoinSet;

use darkbloom_core::fleet::hedge::HedgeToken;
use darkbloom_core::ids::AttemptId;
use darkbloom_core::request::{Deadlines, Event, RequestMachine, RequestOutcome};
use darkbloom_core::time::{DurationMs, TimestampMs};

use crate::contracts::LedgerError;
use crate::request_task::attempt::AttemptRuntime;
use crate::request_task::types::{Clock, TaskReport, UsageOut};
use crate::request_task::{NormalizedRequest, RequestTaskDeps};

use events::TaskInput;
use permits::PermitLedger;

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
