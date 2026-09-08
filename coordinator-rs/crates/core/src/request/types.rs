//! Request-lifecycle value types: phases, attempts, facts, terminals,
//! outcomes (plan sections 7.2, 12.2).

use serde::{Deserialize, Serialize};

use crate::ids::{AttemptId, LeaseId, ProviderId, TerminalDigest};
use crate::money::Tokens;
use crate::provider_error::ProviderErrorClass;
use crate::settlement::ProviderClaimedUsage;
use crate::time::{DurationMs, TimestampMs};

/// Process-local request phase (plan section 7.2). Attempt-level detail
/// lives in [`AttemptRecord`]; the phase tracks the single funded pipeline.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Phase {
    /// Durable provisional reservation in flight.
    Reserving,
    /// Waiting on a fleet admission decision (initial or sequential
    /// alternate).
    Admitting,
    /// At least one prepare dispatched; none funded yet. Both the primary
    /// and a hedge may be outstanding here (plan 9.2.3).
    Preparing,
    /// The funding compare-and-swap fired for `attempt`; the resize/freeze
    /// transaction is in flight (plan 10.3).
    FundingPrepared {
        attempt: AttemptId,
    },
    /// `start_authorized` is durable; idempotent start is on the wire.
    Starting {
        attempt: AttemptId,
    },
    /// Started acknowledged; no content accepted yet.
    AwaitingContent {
        attempt: AttemptId,
    },
    /// First content committed the request (plan 9.2.7).
    Streaming {
        attempt: AttemptId,
    },
    /// Cancel sent after start; bounded terminal wait (plan 13.4/13.5).
    AwaitingTerminal {
        attempt: AttemptId,
    },
    /// The single money disposition was emitted; waiting for the durable
    /// record confirmation.
    Finalizing,
    Finished,
}

impl Phase {
    #[must_use]
    pub const fn name(self) -> &'static str {
        match self {
            Self::Reserving => "reserving",
            Self::Admitting => "admitting",
            Self::Preparing => "preparing",
            Self::FundingPrepared { .. } => "funding_prepared",
            Self::Starting { .. } => "starting",
            Self::AwaitingContent { .. } => "awaiting_content",
            Self::Streaming { .. } => "streaming",
            Self::AwaitingTerminal { .. } => "awaiting_terminal",
            Self::Finalizing => "finalizing",
            Self::Finished => "finished",
        }
    }
}

/// Durable attempt states (plan section 12.2).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AttemptState {
    /// Frame queued toward (or confirmed onto) the provider socket.
    QueuedToSocket,
    /// Socket write returned an ambiguous error: the provider may or may not
    /// have the frame. No release, no retry — await evidence (plan 13.2).
    SentUnknown,
    /// Prepared lease held; no emission possible (plan 10.3).
    Prepared,
    /// Provider acknowledged start; emission is authorized.
    Started,
    /// One terminal disposition recorded (plan 9.3).
    TerminalRecorded,
    /// Abort acknowledged, lease expired, write failed, or session lost —
    /// the attempt can never emit.
    Aborted,
    /// Terminal settlement/release durably recorded and acknowledged.
    Acknowledged,
}

impl AttemptState {
    /// Closed attempts can never produce output or hold live resources.
    #[must_use]
    pub const fn is_closed(self) -> bool {
        matches!(
            self,
            Self::TerminalRecorded | Self::Aborted | Self::Acknowledged
        )
    }
}

/// Why this attempt exists (plan 11.8: primary, at most one sequential
/// alternate, at most one concurrent prepare hedge).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AttemptKind {
    Primary,
    SequentialAlternate,
    Hedge,
}

/// Execution and billing facts returned with a prepared lease (plan 10.3).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct PreparedFacts {
    /// Provider-estimated time to first content from now.
    pub first_content_eta: DurationMs,
    /// Exact billable input from the provider's tokenization.
    pub billable_input_tokens: Tokens,
    /// Output bound the provider reserved for.
    pub max_output_tokens: Tokens,
}

/// Terminal outcome class carried by one signed terminal (plan 10.6).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TerminalOutcome {
    Completed,
    Cancelled,
    Error(ProviderErrorClass),
}

/// The reducer-relevant summary of one signed terminal. Signature and hash
/// verification happen in the durable settlement layer; the reducer needs
/// identity, digest, outcome, and claimed usage.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct TerminalSummary {
    pub digest: TerminalDigest,
    pub outcome: TerminalOutcome,
    pub usage: ProviderClaimedUsage,
}

/// A pre-authorized hedge dispatch: the caller already acquired the global
/// hedge-budget token (plan 11.8) and a fleet permit for `provider`. The
/// reducer either consumes it (emits `SendPrepare`) or returns it
/// (`ReturnHedgeOffer`); it can never conjure one itself.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct HedgeOffer {
    pub attempt: AttemptId,
    pub provider: ProviderId,
}

/// One provider dispatch owned by the machine.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AttemptRecord {
    pub id: AttemptId,
    pub provider: ProviderId,
    pub kind: AttemptKind,
    pub state: AttemptState,
    /// Whether the prepare frame write was confirmed on the wire.
    pub write_confirmed: bool,
    pub lease: Option<LeaseId>,
    pub facts: Option<PreparedFacts>,
    pub terminal: Option<TerminalSummary>,
    /// The prepare permit for this attempt was released (exactly once).
    pub permit_released: bool,
    /// An idempotent abort was emitted; awaiting acknowledgement.
    pub abort_requested: bool,
    /// An idempotent cancel was emitted; awaiting quiescence/terminal.
    pub cancel_requested: bool,
}

impl AttemptRecord {
    #[must_use]
    pub fn new(id: AttemptId, provider: ProviderId, kind: AttemptKind) -> Self {
        Self {
            id,
            provider,
            kind,
            state: AttemptState::QueuedToSocket,
            write_confirmed: false,
            lease: None,
            facts: None,
            terminal: None,
            permit_released: false,
            abort_requested: false,
            cancel_requested: false,
        }
    }
}

/// Consumer-facing final outcome, emitted exactly once per request via
/// `Effect::CompleteRequest`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RequestOutcome {
    /// Terminal received after committed content; settlement submitted.
    Completed,
    /// Consumer cancelled (or left) before completion.
    Cancelled,
    /// The provisional reservation transaction failed.
    ReserveFailed,
    /// Admission found no dispatchable capacity.
    NoCapacity { retry_after: Option<DurationMs> },
    /// The provider rejected the request with a non-retryable class.
    ProviderRejected { class: ProviderErrorClass },
    /// A provider terminal reported an error before any content.
    ProviderError { class: ProviderErrorClass },
    /// Provider session or lease was lost and no alternate was legal.
    ProviderLost,
    /// The absolute first-content or total deadline elapsed.
    DeadlineExceeded,
    /// The resize/freeze funding transaction failed.
    FundingFailed,
    /// The consumer output pipe stalled past its grace window (plan 13.6).
    ConsumerBackpressure,
}

/// Why the job was escalated to `review_pending` (plan 12.2): money stays
/// held until an explicit reconciler/operator decision.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ReviewReason {
    /// Bounded terminal wait elapsed after content was exposed (plan 10.6:
    /// never infer client delivery from provider generation).
    TerminalTimeoutAfterContent,
    /// Bounded terminal wait elapsed after start delivery but before any
    /// content; generation state is ambiguous (plan 13.4).
    TerminalTimeoutAfterStart,
    /// Provider session lost after content was exposed; terminal will
    /// replay through durable recovery.
    ProviderLostAfterContent,
    /// Provider session lost after start was possibly delivered but before
    /// content (plan 18: do not redispatch ambiguously; await replay).
    ProviderLostAfterStart,
}

/// Absolute deadlines fixed at ingress (plan 9.2.5, 16). They are shared by
/// every attempt and never reset; the machine stores them immutably.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Deadlines {
    pub first_content: TimestampMs,
    pub total: TimestampMs,
}
