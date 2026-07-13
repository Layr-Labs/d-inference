//! Request lifecycle aggregate and pure reducer.

mod reducer;
mod state;

pub use reducer::{
    ApplyOutcome, RecordedRequestEvent, Reduction, RequestError, RequestEvent, reduce,
};
pub use state::{
    Attempt, AttemptKind, AttemptReleaseReason, AttemptStatus, FundingReservation, InvariantError,
    ProviderFence, RequestContext, RequestState, ResourceAccounting,
};
