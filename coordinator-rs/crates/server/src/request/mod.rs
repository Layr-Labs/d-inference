//! Bounded request execution around the pure request reducer.
//!
//! This module deliberately contains no HTTP route or fleet selection policy.
//! One [`RequestTask`] owns one logical request, including its primary, sole
//! alternate, and sole optional hedge. Provider output flows synchronously
//! through strict validation, shared commitment, and a direct item/byte-bounded
//! response pipe.

mod byte_pipe;
mod commit;
mod error;
mod hedge;
mod output;
mod task;

pub use byte_pipe::{
    BytePipeLimits, BytePipeReceiver, BytePipeSender, BytePipeStats, MAX_PIPE_BYTES,
    MAX_PIPE_ITEMS, PipeItem, RequestCancellation, ResponseLifetimeGuard, byte_pipe,
};
pub use commit::{
    ChunkClass, CommitmentLimits, CommitmentOutput, OutputCommitment, OutputMode, classify_chunk,
};
pub use error::{
    CancellationReason, CommitmentError, HedgeError, OutputError, PipeCloseReason, PipeConfigError,
    PipeError, RequestExecutionError,
};
pub use hedge::{PreAuthorizationAction, PreAuthorizationPlanner};
pub use output::{
    OutputExpectations, OutputLimits, OutputVerifier, VerifiedChunk, VerifiedTerminal,
    next_rolling_digest,
};
pub use task::{
    AttemptPhase, DispatchState, DispatchTracker, InboundAttemptEvent, RequestTask,
    RequestTaskConfig, inbound_attempt_pipe, request_cancellation,
};
