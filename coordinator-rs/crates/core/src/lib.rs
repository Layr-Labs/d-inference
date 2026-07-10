//! Pure domain logic for the Rust coordinator.
//!
//! No I/O. Reducers and newtypes live here so property tests can exercise
//! invalid transitions without Tokio or PostgreSQL.

#![deny(unsafe_code)]

pub mod admission;
pub mod fleet;
pub mod health;
pub mod hedge;
pub mod ids;
pub mod lease;
pub mod request;
pub mod terminal_journal;

pub use admission::{AdmissionDecision, CapacityReason, DispatchPermit, RejectionReason};
pub use fleet::{AdmitRequest, FleetState, ProviderSnapshot};
pub use health::{HealthMachine, HealthState};
pub use hedge::{HedgeBudget, HedgePolicy};
pub use ids::{AttemptId, CoordinatorEpoch, JobId, LeaseId, MicroUsd, SessionEpoch};
pub use lease::{LeaseError, LeaseEvent, LeaseState};
pub use request::{RequestEvent, RequestState};
pub use terminal_journal::{JournalEntry, JournalError, TerminalJournal};
