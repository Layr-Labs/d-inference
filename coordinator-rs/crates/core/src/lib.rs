//! Pure domain logic for the Rust coordinator.

#![deny(unsafe_code)]

pub mod admission;
pub mod calibration;
pub mod fleet;
pub mod health;
pub mod hedge;
pub mod ids;
pub mod lease;
pub mod placement;
pub mod request;
pub mod routing_replay;
pub mod terminal_journal;
pub mod trust;

pub use admission::{AdmissionDecision, CapacityReason, DispatchPermit, RejectionReason};
pub use calibration::TtftCalibrator;
pub use fleet::{AdmitRequest, FleetState, ProviderSnapshot};
pub use health::{HealthMachine, HealthState};
pub use hedge::{HedgeBudget, HedgePolicy};
pub use ids::{AttemptId, CoordinatorEpoch, JobId, LeaseId, MicroUsd, SessionEpoch};
pub use lease::{LeaseError, LeaseEvent, LeaseState};
pub use placement::{DesiredModel, PlacementController, PlacementVersion};
pub use request::{RequestEvent, RequestState};
pub use routing_replay::{score_replay, ReplayReport, ReplaySample};
pub use terminal_journal::{JournalEntry, JournalError, TerminalJournal};
pub use trust::{TrustEpoch, TrustEvidence, TrustLevel, TrustState};
