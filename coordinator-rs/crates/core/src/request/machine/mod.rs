//! The request lifecycle reducer (plan sections 7.2, 9.2, 11.8, 13).
//!
//! One pure state machine owns one logical request. `apply` consumes an
//! observation and returns the next state plus effect descriptions; it never
//! performs I/O. Invariants this reducer makes unrepresentable or rejects:
//!
//! - The funding compare-and-swap fires at most once per job, ever: at most
//!   one `FundAndAuthorize` effect and therefore at most one funded,
//!   start-authorized attempt (9.2.3, 9.2.6).
//! - At most one sequential alternate and one concurrent prepare hedge,
//!   both only while funding is unchosen (9.2.4, 11.8).
//! - The absolute first-content and total deadlines are set at construction
//!   and never mutated (9.2.5).
//! - `sent_unknown` write ambiguity releases nothing and retries nothing;
//!   it waits for provider evidence, expiry, or session loss (12.2, 13.2).
//! - First accepted content commits the request; role/preamble does not;
//!   no failover after commitment (9.2.7, 9.2.8).
//! - Exactly one terminal disposition per attempt: duplicate same-digest
//!   terminals are idempotent, different digests raise a conflict effect
//!   and move no money (9.3, 10.6, 12.8).
//! - Exactly one money disposition per job (`SettleJob`, `ReleaseJob`, or
//!   `EscalateReview`) and exactly one `CompleteRequest`.
//! - Every attempt's prepare permit is released exactly once, and every
//!   prepared lease reaches an abort, cancel, terminal, expiry, or
//!   session-loss disposal on every path (9.2.9, 9.2.10).
//!
//! Handler groups live in focused submodules: [`admit`] (reserve/admission),
//! [`prepare`] (prepare stage and hedging), [`execute`] (fund, start,
//! content, terminals), [`closure`] (acks, expiry, session loss), [`cancel`]
//! (the 13.1-13.6 ladder), and [`shared`] (one-shot transitions and guards).

mod admit;
mod cancel;
mod closure;
mod execute;
mod prepare;
mod shared;

use std::collections::BTreeSet;

use crate::ids::{AttemptId, JobId, ProviderId};
use crate::money::Tokens;
use crate::request::effects::Effect;
use crate::request::errors::TransitionError;
use crate::request::events::Event;
use crate::request::types::{AttemptRecord, Deadlines, Phase, RequestOutcome};
use crate::time::TimestampMs;

/// Primary + at most one hedge + at most one sequential alternate (9.2.3/4).
pub const MAX_ATTEMPTS: usize = 3;

/// How an attempt was closed without a terminal or acknowledgement. The two
/// evidence kinds diverge for funded attempts: hard expiry proves no start
/// can ever succeed (release), while session loss after a possible start
/// only ends live capacity authority (review, plan 13.4).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ClosureEvidence {
    /// Permit or prepared-lease hard expiry (9.2.10).
    HardExpiry,
    /// Provider session torn down.
    SessionLost,
}

/// Financial state of the job as this machine has observed it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum MoneyState {
    /// No durable reservation exists (before `ReserveCommitted`).
    NotReserved,
    /// The provisional reservation is debited and undisposed.
    Held,
    /// The single disposition effect was emitted; awaiting the durable
    /// record confirmation.
    Disposing,
    /// The disposition is durably recorded.
    Disposed,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RequestMachine {
    job: JobId,
    phase: Phase,
    deadlines: Deadlines,
    attempts: Vec<AttemptRecord>,
    attempted_providers: BTreeSet<ProviderId>,
    /// One-shot funding CAS (9.2.3). Never cleared once set, even if the
    /// funding transaction later fails: a second `FundAndAuthorize` is
    /// unrepresentable.
    funding: Option<AttemptId>,
    start_authorized: bool,
    /// First-content commitment (9.2.7).
    committed: Option<AttemptId>,
    /// Cumulative completion tokens of the last chunk accepted into the
    /// consumer pipe — the billing boundary checkpoint (10.6, 13.6).
    accepted_checkpoint: Tokens,
    hedge_used: bool,
    alternate_used: bool,
    cancel_requested: bool,
    money: MoneyState,
    consumer_answered: bool,
}

impl RequestMachine {
    /// A new machine in `Reserving`. The deadlines are absolute and frozen
    /// here forever (9.2.5).
    #[must_use]
    pub fn new(job: JobId, deadlines: Deadlines) -> Self {
        Self {
            job,
            phase: Phase::Reserving,
            deadlines,
            attempts: Vec::new(),
            attempted_providers: BTreeSet::new(),
            funding: None,
            start_authorized: false,
            committed: None,
            accepted_checkpoint: Tokens::ZERO,
            hedge_used: false,
            alternate_used: false,
            cancel_requested: false,
            money: MoneyState::NotReserved,
            consumer_answered: false,
        }
    }

    #[must_use]
    pub fn job(&self) -> JobId {
        self.job
    }

    #[must_use]
    pub fn phase(&self) -> Phase {
        self.phase
    }

    #[must_use]
    pub fn deadlines(&self) -> Deadlines {
        self.deadlines
    }

    #[must_use]
    pub fn attempts(&self) -> &[AttemptRecord] {
        &self.attempts
    }

    #[must_use]
    pub fn funded_attempt(&self) -> Option<AttemptId> {
        self.funding
    }

    #[must_use]
    pub fn is_start_authorized(&self) -> bool {
        self.start_authorized
    }

    #[must_use]
    pub fn committed_attempt(&self) -> Option<AttemptId> {
        self.committed
    }

    #[must_use]
    pub fn accepted_checkpoint(&self) -> Tokens {
        self.accepted_checkpoint
    }

    #[must_use]
    pub fn is_finished(&self) -> bool {
        matches!(self.phase, Phase::Finished)
    }

    /// Reduce one event at `now`. On `Err` the machine is unchanged.
    pub fn apply(
        &self,
        event: Event,
        now: TimestampMs,
    ) -> Result<(Self, Vec<Effect>), TransitionError> {
        let mut next = self.clone();
        let mut effects = Vec::new();
        next.dispatch(event, now, &mut effects)?;
        Ok((next, effects))
    }

    fn dispatch(
        &mut self,
        event: Event,
        now: TimestampMs,
        effects: &mut Vec<Effect>,
    ) -> Result<(), TransitionError> {
        match event {
            Event::ReserveCommitted => self.on_reserve_committed(effects),
            Event::ReserveFailed => self.on_reserve_failed(effects),
            Event::AdmitGranted { attempt, provider } => {
                self.on_admit_granted(attempt, provider, effects)
            }
            Event::AdmitFailed { retry_after } => self.on_admit_failed(retry_after, effects),
            Event::PrepareWriteConfirmed { attempt } => self.on_write_confirmed(attempt),
            Event::PrepareWriteFailed { attempt } => self.on_write_failed(attempt, now, effects),
            Event::PrepareWriteUnknown { attempt } => self.on_write_unknown(attempt),
            Event::PreparedArrived {
                attempt,
                lease,
                facts,
                hedge_offer,
            } => self.on_prepared(attempt, lease, facts, hedge_offer, now, effects),
            Event::PrepareRejected { attempt, class } => {
                self.on_prepare_rejected(attempt, class, now, effects)
            }
            Event::HedgeTimerFired { offer } => self.on_hedge_timer(offer, now, effects),
            Event::FundAuthorized { attempt } => self.on_fund_authorized(attempt, effects),
            Event::FundFailed { attempt } => self.on_fund_failed(attempt, effects),
            Event::StartWriteUnknown { attempt } => self.on_start_write_unknown(attempt),
            Event::StartRetryTimerFired => self.on_start_retry(effects),
            Event::StartedAck { attempt } => self.on_started_ack(attempt),
            Event::PreambleAccepted { attempt } => self.on_preamble(attempt),
            Event::ContentAccepted {
                attempt,
                cumulative_tokens,
            } => self.on_content(attempt, cumulative_tokens),
            Event::TerminalArrived { attempt, terminal } => {
                self.on_terminal(attempt, terminal, now, effects)
            }
            Event::AbortAcked { attempt } => self.on_abort_acked(attempt, now, effects),
            Event::CancelAcked { attempt } => self.on_cancel_acked(attempt, effects),
            Event::AttemptTimedOut { attempt } => self.on_attempt_closed_by_evidence(
                attempt,
                ClosureEvidence::HardExpiry,
                now,
                effects,
            ),
            Event::SessionLost { attempt } => self.on_attempt_closed_by_evidence(
                attempt,
                ClosureEvidence::SessionLost,
                now,
                effects,
            ),
            Event::ConsumerCancelled => {
                self.initiate_cancel(RequestOutcome::Cancelled, effects);
                Ok(())
            }
            Event::ConsumerPipeStalled => {
                self.initiate_cancel(RequestOutcome::ConsumerBackpressure, effects);
                Ok(())
            }
            Event::FirstContentDeadlineElapsed => {
                if now < self.deadlines.first_content {
                    return Err(TransitionError::DeadlineNotElapsed);
                }
                if self.committed.is_none() {
                    self.initiate_cancel(RequestOutcome::DeadlineExceeded, effects);
                }
                Ok(())
            }
            Event::TotalDeadlineElapsed => {
                if now < self.deadlines.total {
                    return Err(TransitionError::DeadlineNotElapsed);
                }
                self.initiate_cancel(RequestOutcome::DeadlineExceeded, effects);
                Ok(())
            }
            Event::TerminalWaitElapsed => self.on_terminal_wait_elapsed(effects),
            Event::SettlementRecorded | Event::ReleaseRecorded | Event::ReviewRecorded => {
                self.on_disposition_recorded(matches!(event, Event::SettlementRecorded))
            }
        }
    }
}
