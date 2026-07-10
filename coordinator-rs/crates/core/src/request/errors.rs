//! Typed transition errors. An error means the event was rejected and the
//! machine state is unchanged; benign races (duplicate terminals, late acks)
//! are handled as no-ops, not errors.

use thiserror::Error;

use crate::ids::AttemptId;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Error)]
pub enum TransitionError {
    /// The event names an attempt this machine never created.
    #[error("unknown attempt {attempt}")]
    UnknownAttempt { attempt: AttemptId },
    /// An attempt id was reused (every dispatch needs a distinct identity,
    /// plan 9.2.2).
    #[error("duplicate attempt id {attempt}")]
    DuplicateAttempt { attempt: AttemptId },
    /// The event is not valid in the current phase.
    #[error("event {event} invalid in phase {phase}")]
    PhaseMismatch {
        phase: &'static str,
        event: &'static str,
    },
    /// A deadline event fired before its deadline actually elapsed —
    /// a caller timer bug the reducer refuses to absorb (plan 9.2.5).
    #[error("deadline event delivered before the deadline elapsed")]
    DeadlineNotElapsed,
    /// A cancel acknowledgement arrived for an attempt that was never sent
    /// a cancel.
    #[error("cancel ack for attempt {attempt} without outstanding cancel")]
    NoCancelOutstanding { attempt: AttemptId },
    /// An abort acknowledgement arrived for an attempt that was never sent
    /// an abort.
    #[error("abort ack for attempt {attempt} without outstanding abort")]
    NoAbortOutstanding { attempt: AttemptId },
    /// The bounded attempt set (primary + hedge + sequential alternate) is
    /// exhausted (plan 9.2.3, 9.2.4).
    #[error("attempt limit reached")]
    TooManyAttempts,
    /// An event tried to fund a second attempt. The funding compare-and-swap
    /// fires at most once per job, ever (plan 9.2.3, 9.2.6).
    #[error("funding already chosen for this job")]
    FundingAlreadyChosen,
}
