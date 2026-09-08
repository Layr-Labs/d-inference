//! Protocol v2 frames (plan §10), one file per frame family.
//!
//! [`FrameV2`] is a serde internally-tagged enum on `"type"`. Unlike v1,
//! decoding is strict for required fields: v2 providers are a new dual-stack
//! release, so there is no legacy leniency to preserve. Unknown fields are
//! still ignored for additive forward compatibility.
//!
//! Every request-scoped frame carries the full [`RequestScope`] identity and
//! fencing set (plan §10.2). An acknowledgement (`started`, `aborted`,
//! `cancelled`, `terminal_ack`) proves the named state transition, not merely
//! receipt of the command.

mod abort_cancel;
mod envelope;
mod model_lifecycle;
mod prepare;
mod scope;
mod start;
mod terminal;

pub use abort_cancel::{AbortFrame, AbortReason, AbortedFrame, CancelFrame, CancelledFrame};
pub use envelope::{FrameV2, FrameV2Error};
pub use model_lifecycle::{ModelGoneFrame, ModelReadyFrame};
pub use prepare::{ExecutionFacts, PrepareFrame, PreparedFrame, ResourceFacts};
pub use scope::RequestScope;
pub use start::{StartFrame, StartedFrame};
pub use terminal::{
    AckDisposition, RollingHashCheckpoint, TerminalAckFrame, TerminalFrame, TerminalOutcome,
    TerminalUsage,
};
