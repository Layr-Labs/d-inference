//! Inputs to the request reducer. Every event is an observation delivered by
//! the surrounding task (ledger results, fleet decisions, provider frames,
//! timers, consumer signals); the reducer itself never performs I/O.

use crate::ids::{AttemptId, LeaseId, ProviderId};
use crate::money::Tokens;
use crate::provider_error::ProviderErrorClass;
use crate::request::types::{HedgeOffer, PreparedFacts, TerminalSummary};
use crate::time::DurationMs;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Event {
    /// The provisional reservation committed (plan 12.5).
    ReserveCommitted,
    /// The provisional reservation failed; nothing was debited.
    ReserveFailed,
    /// Fleet admission granted a candidate; the caller holds a prepare
    /// permit for `attempt` on `provider`.
    AdmitGranted {
        attempt: AttemptId,
        provider: ProviderId,
    },
    /// Fleet admission returned `RetryAfter`/`Reject` (plan 11.1).
    AdmitFailed { retry_after: Option<DurationMs> },
    /// The prepare frame write completed on the wire.
    PrepareWriteConfirmed { attempt: AttemptId },
    /// The prepare frame was never written (session closed first).
    PrepareWriteFailed { attempt: AttemptId },
    /// The socket write outcome is ambiguous (plan 12.2 `sent_unknown`,
    /// 13.2: no release, no retry — await evidence).
    PrepareWriteUnknown { attempt: AttemptId },
    /// The provider returned a prepared lease with execution facts
    /// (plan 10.3). `hedge_offer` optionally carries a pre-authorized hedge
    /// the reducer may consume if the facts fail the first-content budget
    /// (plan 11.8).
    PreparedArrived {
        attempt: AttemptId,
        lease: LeaseId,
        facts: PreparedFacts,
        hedge_offer: Option<HedgeOffer>,
    },
    /// The provider rejected the prepare with a structured class (plan 10.5).
    PrepareRejected {
        attempt: AttemptId,
        class: ProviderErrorClass,
    },
    /// The caller-armed per-model prepare-latency timer fired while the
    /// primary prepare was still outstanding (plan 11.8). `offer` is absent
    /// when the global hedge budget was exhausted — the reducer then
    /// degrades to sequential-alternate behavior.
    HedgeTimerFired { offer: Option<HedgeOffer> },
    /// The resize/freeze transaction committed and `start_authorized` is
    /// durable (plan 12.5).
    FundAuthorized { attempt: AttemptId },
    /// The resize/freeze transaction definitively failed.
    FundFailed { attempt: AttemptId },
    /// The start frame write outcome is ambiguous. Never authorizes an
    /// alternate (plan 9.2.11).
    StartWriteUnknown { attempt: AttemptId },
    /// Caller timer: resend the same idempotent start (plan 10.3).
    StartRetryTimerFired,
    /// The provider acknowledged start (plan 10.3).
    StartedAck { attempt: AttemptId },
    /// Role/lifecycle preamble accepted into the pipe. Does NOT commit
    /// (plan 9.2.7).
    PreambleAccepted { attempt: AttemptId },
    /// A content-bearing chunk was accepted into the bounded consumer pipe —
    /// the billable-output linearization point (plan 10.6). The first one
    /// commits the request (plan 9.2.7).
    ContentAccepted {
        attempt: AttemptId,
        cumulative_tokens: Tokens,
    },
    /// A signed terminal arrived for an attempt (plan 10.6).
    TerminalArrived {
        attempt: AttemptId,
        terminal: TerminalSummary,
    },
    /// The provider acknowledged an abort: the lease is tombstoned
    /// (plan 10.3, 13.3).
    AbortAcked { attempt: AttemptId },
    /// The provider acknowledged a cancel: the attempt is durably quiescent
    /// and cannot later emit output (plan 10.2).
    CancelAcked { attempt: AttemptId },
    /// Hard expiry of the attempt's permit or prepared lease (plan 9.2.10).
    AttemptTimedOut { attempt: AttemptId },
    /// The provider session carrying this attempt was torn down.
    SessionLost { attempt: AttemptId },
    /// The consumer cancelled or disconnected (plan 13.1-13.5 ladder).
    ConsumerCancelled,
    /// The bounded consumer pipe stalled past its grace window (plan 13.6).
    ConsumerPipeStalled,
    /// Caller timer: the absolute first-content deadline elapsed
    /// (plan 9.2.5).
    FirstContentDeadlineElapsed,
    /// Caller timer: the absolute total request deadline elapsed.
    TotalDeadlineElapsed,
    /// Caller timer: the bounded post-cancel terminal wait elapsed
    /// (plan 13.5).
    TerminalWaitElapsed,
    /// The settlement transaction committed durably (plan 12.6).
    SettlementRecorded,
    /// The release transaction committed durably (plan 12.7).
    ReleaseRecorded,
    /// The review escalation was durably recorded (`review_pending`).
    ReviewRecorded,
}

impl Event {
    #[must_use]
    pub const fn name(&self) -> &'static str {
        match self {
            Self::ReserveCommitted => "reserve_committed",
            Self::ReserveFailed => "reserve_failed",
            Self::AdmitGranted { .. } => "admit_granted",
            Self::AdmitFailed { .. } => "admit_failed",
            Self::PrepareWriteConfirmed { .. } => "prepare_write_confirmed",
            Self::PrepareWriteFailed { .. } => "prepare_write_failed",
            Self::PrepareWriteUnknown { .. } => "prepare_write_unknown",
            Self::PreparedArrived { .. } => "prepared_arrived",
            Self::PrepareRejected { .. } => "prepare_rejected",
            Self::HedgeTimerFired { .. } => "hedge_timer_fired",
            Self::FundAuthorized { .. } => "fund_authorized",
            Self::FundFailed { .. } => "fund_failed",
            Self::StartWriteUnknown { .. } => "start_write_unknown",
            Self::StartRetryTimerFired => "start_retry_timer_fired",
            Self::StartedAck { .. } => "started_ack",
            Self::PreambleAccepted { .. } => "preamble_accepted",
            Self::ContentAccepted { .. } => "content_accepted",
            Self::TerminalArrived { .. } => "terminal_arrived",
            Self::AbortAcked { .. } => "abort_acked",
            Self::CancelAcked { .. } => "cancel_acked",
            Self::AttemptTimedOut { .. } => "attempt_timed_out",
            Self::SessionLost { .. } => "session_lost",
            Self::ConsumerCancelled => "consumer_cancelled",
            Self::ConsumerPipeStalled => "consumer_pipe_stalled",
            Self::FirstContentDeadlineElapsed => "first_content_deadline_elapsed",
            Self::TotalDeadlineElapsed => "total_deadline_elapsed",
            Self::TerminalWaitElapsed => "terminal_wait_elapsed",
            Self::SettlementRecorded => "settlement_recorded",
            Self::ReleaseRecorded => "release_recorded",
            Self::ReviewRecorded => "review_recorded",
        }
    }
}
