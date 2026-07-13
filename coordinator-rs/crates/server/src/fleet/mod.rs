//! Supervised, bounded runtime owner for pure fleet policy.
//!
//! This module intentionally contains no prompt payloads, persistence, crypto,
//! or socket I/O. Provider adapters publish lifecycle/headroom facts and
//! request adapters atomically lease/release capacity through [`FleetHandle`].

mod actor;
mod message;
mod snapshot;

pub use actor::{
    FleetActor, FleetActorConfig, FleetActorError, FleetConfigError, FleetHandle,
    HeartbeatPublishError,
};
pub use message::{
    AdmissionRequest, FleetCommandError, FleetHandleError, HeartbeatPublishOutcome,
    LifecycleApplied, PermitLease, PermitRelease, PermitReleaseReason, ProviderCapacity,
    ProviderHeartbeat, ProviderLifecycle, WriterHeadroom, WriterHeadroomError,
};
pub use snapshot::{FleetActorStats, FleetSnapshot, ProviderRuntimeSnapshot};
