//! Request-execution failures with explicit ambiguity and backpressure states.

use std::sync::Arc;

use darkbloom_coordinator_core::request::RequestError;
use thiserror::Error;

/// Why the one request-scoped cancellation signal fired.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum CancellationReason {
    /// The HTTP request or equivalent caller explicitly cancelled.
    ClientCancelled,
    /// The response body was dropped before it was completely consumed.
    ConsumerDropped,
    /// The direct response pipe reached an item or byte bound.
    SlowConsumer,
    /// The immutable absolute request deadline elapsed.
    DeadlineExpired,
    /// A start send began but its delivery result is unknowable.
    SentUnknown,
    /// Provider output violated an authenticated request invariant.
    ProtocolViolation,
    /// The request task ended before its response body completed.
    RequestEnded,
}

/// Why a finite direct pipe closed.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum PipeCloseReason {
    /// The receiver disappeared while the producer could still publish.
    ConsumerDropped,
    /// A producer attempted to exceed the configured item bound.
    ItemOverflow,
    /// A producer attempted to exceed the configured byte bound.
    ByteOverflow,
    /// The request task explicitly cancelled the body.
    Cancelled,
    /// Provider output failed validation.
    ProtocolViolation,
    /// Provider returned a valid cancelled or error terminal.
    ProviderFailed,
    /// The immutable request deadline elapsed.
    DeadlineExpired,
    /// The request task disappeared without a graceful finish.
    ProducerDropped,
}

impl PipeCloseReason {
    #[must_use]
    pub const fn cancellation_reason(self) -> CancellationReason {
        match self {
            Self::ConsumerDropped => CancellationReason::ConsumerDropped,
            Self::ItemOverflow | Self::ByteOverflow => CancellationReason::SlowConsumer,
            Self::Cancelled => CancellationReason::ClientCancelled,
            Self::ProtocolViolation => CancellationReason::ProtocolViolation,
            Self::ProviderFailed => CancellationReason::RequestEnded,
            Self::DeadlineExpired => CancellationReason::DeadlineExpired,
            Self::ProducerDropped => CancellationReason::RequestEnded,
        }
    }
}

/// Invalid finite item/byte pipe configuration.
#[derive(Clone, Copy, Debug, Eq, Error, PartialEq)]
pub enum PipeConfigError {
    /// At least one item must fit.
    #[error("pipe item limit must be greater than zero")]
    ZeroItems,
    /// At least one payload byte must fit.
    #[error("pipe byte limit must be greater than zero")]
    ZeroBytes,
    /// The item limit exceeds the process hard bound.
    #[error("pipe item limit {actual} exceeds hard limit {maximum}")]
    TooManyItems {
        /// Supplied item limit.
        actual: usize,
        /// Process hard limit.
        maximum: usize,
    },
    /// The byte limit exceeds the process hard bound.
    #[error("pipe byte limit {actual} exceeds hard limit {maximum}")]
    TooManyBytes {
        /// Supplied byte limit.
        actual: usize,
        /// Process hard limit.
        maximum: usize,
    },
}

/// Immediate failure from the direct response pipe.
#[derive(Clone, Copy, Debug, Eq, Error, PartialEq)]
pub enum PipeError {
    /// The attempted item would exceed the finite item count.
    #[error("pipe item bound exceeded")]
    ItemOverflow,
    /// The attempted item would exceed the finite byte count.
    #[error("pipe byte bound exceeded")]
    ByteOverflow,
    /// The pipe had already closed.
    #[error("pipe is closed: {0:?}")]
    Closed(PipeCloseReason),
}

/// Strict authenticated-output validation failure.
#[derive(Clone, Debug, Eq, Error, PartialEq)]
pub enum OutputError {
    /// The binary frame is not a response chunk.
    #[error("binary frame is not a response chunk")]
    WrongFrameKind,
    /// Any attempt identity component differs.
    #[error("output attempt identity mismatch")]
    IdentityMismatch,
    /// Output did not begin at zero or had a gap/replay.
    #[error("output sequence {actual} does not equal expected sequence {expected}")]
    SequenceMismatch {
        /// Required next sequence.
        expected: u64,
        /// Received sequence.
        actual: u64,
    },
    /// Completion-token accounting moved backwards.
    #[error("cumulative tokens regressed from {previous} to {actual}")]
    CumulativeTokensRegressed {
        /// Last accepted count.
        previous: u64,
        /// Rejected count.
        actual: u64,
    },
    /// Provider output exceeded the prepared maximum.
    #[error("cumulative tokens {actual} exceed prepared maximum {maximum}")]
    CumulativeTokensExceeded {
        /// Rejected count.
        actual: u64,
        /// Prepared maximum.
        maximum: u64,
    },
    /// A frame carried a retransmission flag, which this strict path forbids.
    #[error("response retransmissions are not accepted")]
    RetransmitUnsupported,
    /// Per-frame plaintext exceeded the configured bound.
    #[error("output chunk has {actual} bytes; maximum is {maximum}")]
    ChunkTooLarge {
        /// Rejected payload size.
        actual: usize,
        /// Per-frame maximum.
        maximum: usize,
    },
    /// Total exact delivered output exceeded the configured bound.
    #[error("output has {actual} bytes; maximum is {maximum}")]
    OutputTooLarge {
        /// Attempted exact total.
        actual: usize,
        /// Request maximum.
        maximum: usize,
    },
    /// Too many provider chunks were received.
    #[error("output has more than {maximum} chunks")]
    TooManyChunks {
        /// Request maximum.
        maximum: usize,
    },
    /// Authenticated rolling digest differs from exact plaintext.
    #[error("output rolling digest mismatch")]
    RollingDigestMismatch,
    /// The FINAL flag was not attached exactly to `[DONE]`.
    #[error("FINAL flag and data: [DONE] framing disagree")]
    InvalidFinalFraming,
    /// `[DONE]` arrived before consumer-visible content.
    #[error("data: [DONE] arrived before content commitment")]
    DoneBeforeContent,
    /// No frame is legal after terminal framing.
    #[error("output frame arrived after data: [DONE]")]
    FrameAfterDone,
    /// A completed stream omitted terminal framing.
    #[error("completed provider terminal arrived before data: [DONE]")]
    MissingDone,
    /// Provider terminal identity differs from the selected attempt.
    #[error("provider terminal identity mismatch")]
    TerminalIdentityMismatch,
    /// Provider terminal's canonical digest or signature is invalid.
    #[error("provider terminal authentication failed: {0}")]
    TerminalAuthentication(Arc<str>),
    /// Terminal model differs from the prepared model.
    #[error("provider terminal model mismatch")]
    TerminalModelMismatch,
    /// Terminal prompt usage differs from prepared facts.
    #[error("terminal prompt tokens {actual} do not equal prepared count {expected}")]
    TerminalPromptTokens {
        /// Prepared prompt count.
        expected: u64,
        /// Terminal prompt count.
        actual: u64,
    },
    /// Terminal completion usage differs from delivered cumulative accounting.
    #[error("terminal completion tokens {actual} do not equal delivered count {expected}")]
    TerminalCompletionTokens {
        /// Last authenticated cumulative count.
        expected: u64,
        /// Terminal completion count.
        actual: u64,
    },
    /// Terminal usage fields violate prepared bounds.
    #[error("provider terminal usage is outside prepared bounds")]
    TerminalUsageBounds,
    /// Terminal exact response hash differs from delivered plaintext.
    #[error("provider terminal response hash mismatch")]
    TerminalResponseHash,
    /// Terminal rolling digest differs from the final chunk checkpoint.
    #[error("provider terminal rolling digest mismatch")]
    TerminalRollingDigest,
    /// Outcome and structured-error fields disagree.
    #[error("provider terminal outcome and error class disagree")]
    TerminalOutcomeMismatch,
    /// A second terminal was supplied.
    #[error("provider terminal was already accepted")]
    DuplicateTerminal,
}

/// Deferred commitment failure.
#[derive(Clone, Copy, Debug, Eq, Error, PartialEq)]
pub enum CommitmentError {
    /// Held preambles exceeded a finite item bound.
    #[error("held preambles exceed item bound {maximum}")]
    TooManyHeldItems {
        /// Configured bound.
        maximum: usize,
    },
    /// Held preambles or a nonstreaming body exceeded a finite byte bound.
    #[error("held output exceeds byte bound {maximum}")]
    TooManyHeldBytes {
        /// Configured bound.
        maximum: usize,
    },
    /// Output arrived after commitment had been finalized.
    #[error("output commitment is already finalized")]
    AlreadyFinished,
    /// A successful body cannot finish before content.
    #[error("successful response finished before content commitment")]
    NoContent,
}

/// Attempt-role or hedge schedule violation outside the pure reducer.
#[derive(Clone, Copy, Debug, Eq, Error, PartialEq)]
pub enum HedgeError {
    /// Only one sequential alternate can be considered.
    #[error("alternate was already consumed")]
    AlternateAlreadyConsumed,
    /// Only one speculative hedge can be launched.
    #[error("hedge was already launched")]
    HedgeAlreadyLaunched,
    /// Speculation/failover is forbidden once start has been authorized.
    #[error("attempt changes are forbidden after start authorization")]
    AfterAuthorization,
    /// Speculation/failover is forbidden once content has committed.
    #[error("attempt changes are forbidden after content commitment")]
    AfterContent,
    /// Schedule arithmetic overflowed.
    #[error("hedge schedule timestamp overflow")]
    TimestampOverflow,
}

/// Request task failure.
#[derive(Debug, Error)]
pub enum RequestExecutionError {
    /// Pure request aggregate rejected a transition.
    #[error(transparent)]
    Reducer(#[from] RequestError),
    /// The immutable absolute deadline elapsed.
    #[error("absolute request deadline elapsed")]
    DeadlineExpired,
    /// The request cancellation signal fired.
    #[error("request cancelled: {0:?}")]
    Cancelled(CancellationReason),
    /// Provider output failed authenticated validation.
    #[error(transparent)]
    Output(#[from] OutputError),
    /// Direct consumer output failed.
    #[error(transparent)]
    Pipe(#[from] PipeError),
    /// Deferred commitment failed.
    #[error(transparent)]
    Commitment(#[from] CommitmentError),
    /// Attempt scheduling exceeded its strict bounds.
    #[error(transparent)]
    Hedge(#[from] HedgeError),
    /// A provider control identity differed from the selected attempt.
    #[error("provider control identity mismatch")]
    IdentityMismatch,
    /// Provider prepared facts conflict with the request.
    #[error("provider prepared facts are invalid: {0}")]
    InvalidPrepared(Arc<str>),
    /// The attempt is unknown to this logical request.
    #[error("unknown request attempt")]
    UnknownAttempt,
    /// Attempt control arrived in an invalid lifecycle phase.
    #[error("attempt control arrived in invalid phase")]
    InvalidAttemptPhase,
    /// The outbound writer rejected the frame before queue admission.
    #[error("outbound frame was not queued: {0}")]
    OutboundRejected(Arc<str>),
    /// A queued frame definitely failed before wire completion.
    #[error("queued outbound frame failed: {0}")]
    OutboundFailed(Arc<str>),
    /// An outbound send began, but delivery is unknowable.
    #[error("outbound start delivery is unknown")]
    SentUnknown,
    /// Waiting for a finite delivery receipt failed.
    #[error("outbound delivery receipt failed: {0}")]
    DeliveryReceipt(Arc<str>),
    /// Event serialization used to identify reducer events failed.
    #[error("failed to identify reducer event: {0}")]
    EventEncoding(Arc<str>),
}
