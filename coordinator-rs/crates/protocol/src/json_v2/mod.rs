//! Protocol v2 frames and identity newtypes (plan §10).
//!
//! v2 keeps JSON WebSocket frames for control, lifecycle, and registration;
//! only the encrypted payload bodies move to binary frames ([`crate::binary`],
//! plan §15.3). Every request-scoped frame carries the full identity and
//! fencing set from plan §10.2 so stale epochs, replays, and substitutions
//! are rejectable at the frame boundary.

mod error_class;
mod frames;
mod ids;
mod registration;

pub use error_class::ErrorClass;
pub use frames::{
    AbortFrame, AbortReason, AbortedFrame, AckDisposition, CancelFrame, CancelledFrame,
    ExecutionFacts, FrameV2, FrameV2Error, ModelGoneFrame, ModelReadyFrame, PrepareFrame,
    PreparedFrame, RequestScope, ResourceFacts, RollingHashCheckpoint, StartFrame, StartedFrame,
    TerminalAckFrame, TerminalFrame, TerminalOutcome, TerminalUsage,
};
pub use ids::{
    AttemptId, CoordinatorEpoch, DispatchNonce, JobId, LeaseId, RequestDigest, ResponseHash,
    SessionEpoch, TerminalDigest,
};
pub use registration::{capability, RegistrationV2, REGISTER_EXTENSION_KEY};
