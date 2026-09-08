//! Outputs of the request reducer. Effects are descriptions of work for the
//! surrounding task — send this frame, run this transaction, release this
//! permit. Nothing is executed inside the reducer (plan 19.3).

use std::collections::BTreeSet;

use crate::ids::{AttemptId, LeaseId, ProviderId, TerminalDigest};
use crate::money::Tokens;
use crate::request::types::{PreparedFacts, RequestOutcome, ReviewReason, TerminalSummary};

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Effect {
    /// Ask the fleet for a candidate, excluding already-attempted providers
    /// so alternates and hedges never re-select them (plan 11.1).
    RequestAdmission { exclude: BTreeSet<ProviderId> },
    /// Send the prepare frame for an attempt through its provider session.
    SendPrepare {
        attempt: AttemptId,
        provider: ProviderId,
    },
    /// Release the attempt's coordinator-local prepare permit — emitted
    /// exactly once per attempt on every terminal path (plan 9.2.10).
    ReleasePermit { attempt: AttemptId },
    /// Send an idempotent abort for a prepared, not-started lease
    /// (plan 13.3). Also the losing-hedge path (plan 11.8).
    AbortLease { attempt: AttemptId, lease: LeaseId },
    /// Run the resize/freeze transaction and record `start_authorized`
    /// (plan 12.5). Emitted at most once per job — the funding CAS
    /// (plan 9.2.3, 9.2.6).
    FundAndAuthorize {
        attempt: AttemptId,
        lease: LeaseId,
        facts: PreparedFacts,
    },
    /// Send the idempotent start (or resend the same identity, plan 10.3).
    SendStart { attempt: AttemptId, lease: LeaseId },
    /// Send an idempotent cancel for a started attempt (plan 13.4/13.5).
    SendCancel { attempt: AttemptId, lease: LeaseId },
    /// Drop a queued prepare frame that never reached the socket (plan 13.1).
    DiscardQueuedFrame { attempt: AttemptId },
    /// Return an unused pre-authorized hedge: refund the budget token and
    /// release its fleet permit.
    ReturnHedgeOffer {
        attempt: AttemptId,
        provider: ProviderId,
    },
    /// Run the settlement transaction for the funded attempt's terminal,
    /// capping completion usage at the accepted-chunk checkpoint
    /// (plan 12.6, 13.6).
    SettleJob {
        attempt: AttemptId,
        terminal: TerminalSummary,
        accepted_checkpoint: Tokens,
    },
    /// Run the idempotent release transaction restoring the exact
    /// reservation provenance (plan 12.7).
    ReleaseJob,
    /// Move the durable job to `review_pending`: reservation stays debited
    /// until an explicit reconciler decision (plan 12.2).
    EscalateReview { reason: ReviewReason },
    /// Record a same-attempt different-digest terminal conflict — no money
    /// may move; the provider is quarantined by the caller (plan 10.6, 12.8).
    RecordTerminalConflict {
        attempt: AttemptId,
        recorded: TerminalDigest,
        conflicting: TerminalDigest,
    },
    /// Emit the single consumer-facing final outcome.
    CompleteRequest { outcome: RequestOutcome },
}
