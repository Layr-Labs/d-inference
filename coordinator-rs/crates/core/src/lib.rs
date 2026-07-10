//! Pure domain logic for the Rust coordinator.
//!
//! No I/O. Reducers and newtypes live here so property tests can exercise
//! invalid transitions without Tokio or PostgreSQL.

#![deny(unsafe_code)]

pub mod admission;
pub mod fleet;
pub mod health;
pub mod ids;
pub mod lease;
pub mod request;

pub use admission::{AdmissionDecision, CapacityReason, RejectionReason};
pub use fleet::{AdmitRequest, FleetState, ProviderSnapshot};
pub use health::HealthState;
pub use ids::{AttemptId, CoordinatorEpoch, JobId, LeaseId, MicroUsd, SessionEpoch};
pub use lease::{LeaseError, LeaseEvent, LeaseState};
pub use request::{RequestEvent, RequestState};
